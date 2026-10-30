import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// =====================================================================================
// CaptureHAL.swift: shared Core Audio plumbing for SystemAudioTap and MicCapture.
//
//  * CaptureTrackSource  - what Recorder needs from a capture source (real or synthetic).
//  * CaptureHAL          - namespace: host clock, property helpers, buffer mixdown, resampler.
//  * HALCapture          - lifecycle engine: opens a device (via a closure), runs an IOProc, converts to
//                          mono Float32 at the session's fixed rate, and REBUILDS everything when the
//                          environment changes (default device switch, sample-rate change, stall...).
//
// Threads:
//   control queue : open / teardown / rebuild decisions, property-listener callbacks, 2 s health tick
//   io queue      : the IOProc block (Core Audio dispatches into it synchronously => keep it tiny:
//                   mix to mono, hand off, return)
//   work queue    : resampling and delivery to `handler` (Recorder), never blocks the IO thread
// =====================================================================================

/// A producer of mono Float32 audio at one fixed sample rate for the whole session.
/// `onSamples(samples, hostTime)`: hostTime = mach host time (mach_absolute_time units) of the FIRST sample.
protocol CaptureTrackSource: AnyObject {
    /// Sample rate of the samples delivered through `onSamples` (fixed for the lifetime of the source).
    var sampleRate: Double { get }
    /// session.json `source` value: "global-tap" | "app-tap" | "mic".
    var sourceLabel: String { get }
    /// Name of the device currently captured (may change after a device switch).
    var deviceName: String { get }
    var onSamples: (([Float], UInt64) -> Void)? { get set }
    var onWarning: ((String) -> Void)? { get set }
    /// Called (any queue) after the source re-opened on a different device / format.
    var onDeviceChange: ((String) -> Void)? { get set }
    func start() throws
    /// Idempotent; returns after no more samples will be delivered.
    func stop()
    /// The recorder saw sustained, regular gap fills of one size on this track: that is the signature of a SAMPLE-RATE
    /// MISMATCH (the device delivers `deliveredRatio` x the audio the source believes it does, e.g. 0.5 for 24 kHz audio
    /// labelled 48 kHz), not of dropouts. Called once per episode (any queue); a source that measures its own delivered
    /// rate re-checks it now (HALCapture.rateSuspected). Default: ignore.
    func timelineRateSuspected(deliveredRatio: Double)
}

extension CaptureTrackSource {
    func timelineRateSuspected(deliveredRatio: Double) {}
}

enum CaptureHAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Host clock

    enum Clock {
        private static let timebase: mach_timebase_info_data_t = {
            var tb = mach_timebase_info_data_t()
            mach_timebase_info(&tb)
            return tb
        }()
        static func now() -> UInt64 { mach_absolute_time() }
        static func seconds(_ host: UInt64) -> Double {
            Double(host) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        static func ticks(seconds: Double) -> UInt64 {
            UInt64(max(0, seconds) * 1e9 * Double(timebase.denom) / Double(timebase.numer))
        }
    }

    // MARK: Errors

    /// "-12345 ('what')" style description of an OSStatus.
    static func describe(_ status: OSStatus) -> String {
        let u = UInt32(bitPattern: status)
        let bytes = [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "\(status) ('\(String(decoding: bytes, as: UTF8.self))')"
        }
        return "\(status)"
    }

    // MARK: Property access

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property (scalar or struct) into `value`.
    @discardableResult
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) -> OSStatus {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
    }

    /// Reads an array property of trivial elements (AudioObjectID, AudioStreamID...). Empty on any error.
    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var bytes = size
            let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &bytes, buffer.baseAddress!)
            initialized = status == noErr ? min(count, Int(bytes) / MemoryLayout<T>.stride) : 0
        }
    }

    /// Reads a CFString property (the HAL returns it retained, hence Unmanaged + takeRetainedValue).
    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let ref = ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    // MARK: Devices

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard get(systemObject, selector, into: &dev) == noErr, dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return dev
    }

    static func allDevices() -> [AudioObjectID] { getArray(systemObject, kAudioHardwarePropertyDevices) }
    static func deviceUID(_ dev: AudioObjectID) -> String? { getString(dev, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ dev: AudioObjectID) -> String? { getString(dev, kAudioObjectPropertyName) }

    static func nominalRate(_ dev: AudioObjectID) -> Double? {
        var rate: Float64 = 0
        guard get(dev, kAudioDevicePropertyNominalSampleRate, into: &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    static func transportType(_ dev: AudioObjectID) -> UInt32? {
        var t: UInt32 = 0
        guard get(dev, kAudioDevicePropertyTransportType, into: &t) == noErr else { return nil }
        return t
    }

    static func streams(_ dev: AudioObjectID, input: Bool) -> [AudioStreamID] {
        getArray(dev, kAudioDevicePropertyStreams, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
    }

    static func streamFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        guard get(stream, kAudioStreamPropertyVirtualFormat, into: &asbd) == noErr else { return nil }
        return asbd
    }

    /// The built-in output device (MacBook speakers), if any. Used by the optional MC_TAP_HOST=builtin mode.
    static func builtInOutputDevice() -> AudioObjectID? {
        allDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && !streams($0, input: false).isEmpty }
    }

    // MARK: Device description (what the tap host policy decides on; a plain value so the self-test can fake devices)

    struct DeviceDescription: Equatable {
        var name: String
        var transportType: UInt32?              // kAudioDevicePropertyTransportType ('blue', 'blea', 'bltn', 'usb ' ...), nil = unreadable
        var hasInputStreams: Bool

        var isBluetooth: Bool { CaptureHAL.isBluetooth(transportType) }
        var transportName: String { CaptureHAL.transportName(transportType) }
    }

    /// Classic Bluetooth and Bluetooth LE. A Bluetooth device's sample rate FOLLOWS ITS PROFILE (A2DP 44.1 / 48 kHz, but
    /// 16 / 24 kHz hands-free the moment any app, including us, opens its microphone), so it is a poor clock for the tap.
    static func isBluetooth(_ transport: UInt32?) -> Bool {
        guard let t = transport else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func transportName(_ transport: UInt32?) -> String {
        guard let t = transport else { return "unknown" }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypePCI: return "pci"
        default:
            let bytes = [UInt8((t >> 24) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 8) & 0xFF), UInt8(t & 0xFF)]
            return bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) ? "'\(String(decoding: bytes, as: UTF8.self))'" : "0x\(String(t, radix: 16))"
        }
    }

    static func describeDevice(_ dev: AudioObjectID) -> DeviceDescription {
        DeviceDescription(name: deviceName(dev) ?? deviceUID(dev) ?? "unknown", transportType: transportType(dev),
                          hasInputStreams: !streams(dev, input: true).isEmpty)
    }

    // MARK: Sample formats and mixdown

    enum SampleKind {
        case float32, int16, int32
        init?(_ asbd: AudioStreamBasicDescription) {
            guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            switch (isFloat, asbd.mBitsPerChannel) {
            case (true, 32): self = .float32
            case (false, 16): self = .int16
            case (false, 32): self = .int32
            default: return nil
            }
        }
        var bytesPerSample: Int {
            switch self {
            case .float32, .int32: return 4
            case .int16: return 2
            }
        }
    }

    /// Mixes HAL IOProc buffers down to mono. Pure functions (no device access), unit-tested with synthetic buffer lists.
    enum Mixer {
        /// Which buffers of the IOProc input list to read.
        /// `tailChannels == nil`: all buffers. Otherwise only the trailing buffers whose channels add up to
        /// `tailChannels` (the process tap is appended AFTER any sub-device input streams of the aggregate).
        static func selectBuffers(_ abl: UnsafeMutableAudioBufferListPointer, tailChannels: Int?) -> Range<Int> {
            let n = abl.count
            guard let want = tailChannels, want > 0 else { return 0..<n }
            var acc = 0
            var start = n
            while start > 0 && acc < want {
                start -= 1
                acc += Int(abl[start].mNumberChannels)
            }
            return start..<n
        }

        /// Appends the mono mix of `range` to `out` and returns the number of frames appended.
        /// Interleaved and one-channel-per-buffer layouts are both handled (each AudioBuffer carries its own
        /// channel count). At most `maxChannels` channels are averaged (L+R for stereo; for multi-channel
        /// microphones only the first two inputs, otherwise a single live mic would be diluted by silent inputs).
        @discardableResult
        static func mix(_ abl: UnsafeMutableAudioBufferListPointer, range: Range<Int>, kind: SampleKind,
                        maxChannels: Int, into out: inout [Float]) -> Int {
            struct Channel { let base: UnsafeRawPointer; let stride: Int; let index: Int }
            var channels: [Channel] = []
            channels.reserveCapacity(maxChannels)
            var frames = Int.max
            for i in range {
                let b = abl[i]
                guard let data = b.mData, b.mNumberChannels > 0, b.mDataByteSize > 0, channels.count < maxChannels else { continue }
                let c = Int(b.mNumberChannels)
                frames = min(frames, Int(b.mDataByteSize) / (c * kind.bytesPerSample))
                var ch = 0
                while ch < c && channels.count < maxChannels {
                    channels.append(Channel(base: UnsafeRawPointer(data), stride: c, index: ch))
                    ch += 1
                }
            }
            guard !channels.isEmpty, frames > 0, frames != Int.max else { return 0 }
            let scale = 1 / Float(channels.count)
            out.reserveCapacity(out.count + frames)
            for f in 0..<frames {
                var sum: Float = 0
                for ch in channels {
                    let idx = f * ch.stride + ch.index
                    switch kind {
                    case .float32: sum += ch.base.load(fromByteOffset: idx * 4, as: Float.self)
                    case .int16: sum += Float(ch.base.load(fromByteOffset: idx * 2, as: Int16.self)) / 32768
                    case .int32: sum += Float(ch.base.load(fromByteOffset: idx * 4, as: Int32.self)) / 2147483648
                    }
                }
                out.append(sum * scale)
            }
            return frames
        }
    }

    // MARK: Resampler (mono Float32, streaming)

    /// Streaming sample-rate converter on top of AVAudioConverter (keeps filter state between calls).
    /// Only used when the device's native rate differs from the session's fixed file rate.
    final class Resampler {
        let from: Double
        let to: Double
        private let converter: AVAudioConverter
        private let inFormat: AVAudioFormat
        private let outFormat: AVAudioFormat

        init?(from: Double, to: Double) {
            guard from > 0, to > 0,
                  let fin = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
                  let fout = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: fin, to: fout) else { return nil }
            conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.from = from
            self.to = to
            self.inFormat = fin
            self.outFormat = fout
            self.converter = conv
        }

        func process(_ input: [Float]) -> [Float] {
            guard !input.isEmpty,
                  let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(input.count)),
                  let inData = inBuf.floatChannelData else { return [] }
            inBuf.frameLength = AVAudioFrameCount(input.count)
            input.withUnsafeBufferPointer { inData[0].update(from: $0.baseAddress!, count: input.count) }

            let capacity = AVAudioFrameCount(Double(input.count) * to / from) + 256
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity),
                  let outData = outBuf.floatChannelData else { return [] }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow       // streaming: more may come with the next callback
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return inBuf
            }
            if status == .error {
                Log.warn("resampler \(from)->\(to) failed: \(error?.localizedDescription ?? "unknown")")
                return []
            }
            return Array(UnsafeBufferPointer(start: outData[0], count: Int(outBuf.frameLength)))
        }

        /// End of stream: returns the filter tail the converter still holds (16 to 96 frames at 48 kHz, i.e. 0.3 to 2 ms)
        /// that `process` never emits on its own. Call once, when no more input will come (teardown of one capture
        /// graph); a new graph builds a new Resampler.
        func flush() -> [Float] {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192),
                  let outData = outBuf.floatChannelData else { return [] }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                Log.warn("resampler \(from)->\(to) flush failed: \(error?.localizedDescription ?? "unknown")")
                return []
            }
            return Array(UnsafeBufferPointer(start: outData[0], count: Int(outBuf.frameLength)))
        }
    }

    // MARK: Delivered-rate measurement (pure value types; unit-tested on synthetic timestamps, no device)

    /// How fast does an IOProc REALLY deliver frames? Compares the frames of each callback with the HOST clock
    /// (AudioTimeStamp.mHostTime of consecutive callbacks), which no device property can lie about.
    ///
    /// Why this exists: a process tap inside a private aggregate device is delivered at the AGGREGATE's rate, which follows
    /// its clock (sub-)device. `kAudioTapPropertyFormat` keeps saying 48000 Hz while a Bluetooth headset whose microphone
    /// is open (hands-free profile) clocks the aggregate at 24 kHz: 24 kHz audio was written into the 48 kHz file at 2x speed
    /// and the recorder's gap filler padded the missing half with zeros (2026-10-10, AirPods Pro).
    ///
    /// One sample per IOProc callback: (host time of its first frame in seconds, number of frames). The interval between two
    /// consecutive callbacks is (frames, dt); consecutive intervals are summed into blocks of >= 50 ms of host time, and the rate of
    /// a block is frames/dt. Robust against stalls (an interval of >= 1 s is a restart, not a rate), hiccups and bursts (blocks whose
    /// rate is far from the median are dropped before the sums are formed) and against jitter of the stamps (block sums telescope).
    struct RateMeter {
        struct Estimate: Equatable {
            var rate: Double            // frames per host second over the kept blocks
            var coverage: Double        // host seconds the kept blocks add up to
            var intervals: Int          // number of kept blocks
            var stationary: Bool        // first and second half of the window agree (no rate change inside the window)
        }

        /// Callbacks further apart than this are a stall or a restart, not a rate sample.
        static let maxInterval = 1.0
        /// Consecutive intervals are summed into BLOCKS of at least this much host time before any outlier screening. Screening
        /// single intervals is biased by the jitter of the stamps (a rate is frames / dt, so a short dt weighs more than a long one and
        /// the 0.7x ... 1.4x band is lopsided): with +-3 ms of stamp noise on a 10.7 ms cadence a HEALTHY 48 kHz device measured
        /// 44 - 45 kHz and was "corrected" back and forth (review of 2026-10-10, scratch harness). Block sums telescope (the noise of
        /// the stamps inside a block cancels), a hiccup or a catch-up burst still spoils only the one block it falls into.
        static let blockSeconds = 0.05
        static let minBlocks = 4
        static let blockBand = 0.7...1.5

        private struct Interval { var end: Double; var frames: Double; var dt: Double }
        private var intervals: [Interval] = []
        private var lastHost: Double?
        private var lastFrames = 0
        let retention: Double

        init(retention: Double = 3.0) { self.retention = retention }

        /// `host` = host time (seconds) of the first frame of this callback, `frames` = frames in it.
        mutating func add(host: Double, frames: Int) {
            if let last = lastHost {
                let dt = host - last
                if abs(dt) <= 1e-6 {
                    // Two callbacks with the same stamp (a driver that stamps per wake-up, not per buffer): one bigger callback. Dropping the
                    // earlier one's frames would read as half the rate.
                    lastFrames += frames
                    return
                }
                if dt > 0, dt < Self.maxInterval, lastFrames > 0 {
                    intervals.append(Interval(end: host, frames: Double(lastFrames), dt: dt))
                }
            }
            lastHost = host
            lastFrames = frames
            let cutoff = host - retention
            if let first = intervals.first, first.end < cutoff {
                intervals.removeAll { $0.end < cutoff }
            }
        }

        /// Rate over (at most) the last `lastSeconds` of host time, nil if there are too few intervals to say anything.
        func estimate(lastSeconds: Double) -> Estimate? {
            guard let newest = intervals.last?.end else { return nil }
            let windowStart = newest - lastSeconds
            let window = intervals.filter { $0.end > windowStart }
            guard window.count >= 4 else { return nil }
            // Blocks of consecutive intervals (>= blockSeconds of host time each; a remainder joins the last block, so the sums stay
            // telescoping). Callbacks that are further apart than the block size are a block of their own.
            var blocks: [Interval] = []
            var cur = Interval(end: 0, frames: 0, dt: 0)
            for iv in window {
                cur.end = iv.end; cur.frames += iv.frames; cur.dt += iv.dt
                if cur.dt >= Self.blockSeconds { blocks.append(cur); cur = Interval(end: 0, frames: 0, dt: 0) }
            }
            if cur.dt > 0 {
                if var last = blocks.popLast() { last.end = cur.end; last.frames += cur.frames; last.dt += cur.dt; blocks.append(last) } else { blocks.append(cur) }
            }
            guard blocks.count >= Self.minBlocks else { return nil }
            let rates = blocks.map { $0.frames / $0.dt }.sorted()
            let median = rates[rates.count / 2]
            guard median > 0, median.isFinite else { return nil }
            let kept = blocks.filter { let r = $0.frames / $0.dt; return r >= Self.blockBand.lowerBound * median && r <= Self.blockBand.upperBound * median }
            guard kept.count >= Self.minBlocks else { return nil }
            let frames = kept.reduce(0) { $0 + $1.frames }
            let seconds = kept.reduce(0) { $0 + $1.dt }
            guard seconds > 0 else { return nil }
            // Stationarity: a rate change inside the window shows as different halves.
            let mid = windowStart + lastSeconds / 2
            let a = kept.filter { $0.end <= mid }, b = kept.filter { $0.end > mid }
            var stationary = false
            if a.count >= 2, b.count >= 2 {
                let sa = a.reduce(0) { $0 + $1.dt }, sb = b.reduce(0) { $0 + $1.dt }
                if sa > 0, sb > 0 {
                    let ra = a.reduce(0) { $0 + $1.frames } / sa, rb = b.reduce(0) { $0 + $1.frames } / sb
                    stationary = abs(ra / rb - 1) <= 0.03
                }
            }
            return Estimate(rate: frames / seconds, coverage: seconds, intervals: kept.count, stationary: stationary)
        }
    }

    /// Turns a measured rate into a decision: "the samples really are at X Hz".
    enum RateJudge {
        /// Rates audio devices really run at. A measurement within 2.5 % of one of them IS that rate (the measurement is
        /// good to well under 1 %, real device clocks are within ~100 ppm of nominal).
        static let standardRates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000]
        static let snapTolerance = 0.025
        /// Below this deviation from the assumed rate a (standard) rate is the same rate; above it (or > bigMismatch for a
        /// non-standard measurement) the samples are NOT at the assumed rate.
        static let sameRateTolerance = 0.03
        static let bigMismatch = 0.10
        static let plausibleRange = 4000.0...400_000.0

        struct Verdict: Equatable {
            var rate: Double            // the rate to resample from (== assumed when there is no mismatch)
            var mismatch: Bool
            var how: String
        }

        static func snap(_ measured: Double) -> (rate: Double, standard: Bool) {
            var best = standardRates[0], bestDistance = Double.infinity
            for s in standardRates {
                let d = abs(measured / s - 1)
                if d < bestDistance { best = s; bestDistance = d }
            }
            return bestDistance <= snapTolerance ? (best, true) : (measured.rounded(), false)
        }

        /// nil if the measurement is not usable. `hints` (exact nominal rates the HAL reports: aggregate, host, ...) are only read
        /// on a mismatch; one that agrees with the measurement is preferred over the snapped value.
        static func verdict(assumed: Double, measured: Double, hints: () -> [(name: String, rate: Double)]) -> Verdict? {
            guard assumed > 0, measured.isFinite, plausibleRange.contains(measured) else { return nil }
            let s = snap(measured)
            let off = abs(measured / assumed - 1)
            let snappedOff = abs(s.rate / assumed - 1)
            let mismatch = off > bigMismatch || (s.standard && snappedOff > sameRateTolerance)
            guard mismatch else {
                return Verdict(rate: assumed, mismatch: false, how: "measured \(Int(measured.rounded())) Hz matches the assumed \(Int(assumed)) Hz")
            }
            if let h = hints().first(where: { $0.rate > 0 && abs($0.rate / measured - 1) <= snapTolerance }) {
                return Verdict(rate: h.rate, mismatch: true,
                               how: "measured \(Int(measured.rounded())) Hz, agrees with \(h.name) \(Int(h.rate.rounded())) Hz")
            }
            return Verdict(rate: s.rate, mismatch: true,
                           how: "measured \(Int(measured.rounded())) Hz" + (s.standard ? "" : ", not a standard rate"))
        }
    }

    // MARK: Property listener (RAII)

    final class PropertyListener {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private var removed = false

        /// Returns nil if the HAL refuses the listener (object does not support the property).
        init?(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
              queue: DispatchQueue, handler: @escaping () -> Void) {
            self.object = object
            self.address = CaptureHAL.address(selector, scope: scope)
            self.queue = queue
            self.block = { _, _ in handler() }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
            guard status == noErr else { return nil }
        }

        func remove() {
            guard !removed else { return }
            removed = true
            _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }

        deinit { remove() }
    }

    // MARK: IOProc stream usage

    /// Tells the HAL which streams of `device` this IOProc wants (`isOn(streamIndex)`). Used to switch off
    /// output streams (we are input only) and, for the tap aggregate, the input streams of the host sub-device
    /// (so e.g. AirPods' microphone is never opened just because the aggregate contains them).
    /// Best effort: returns the OSStatus, failure is not fatal.
    @discardableResult
    static func setIOProcStreamUsage(device: AudioObjectID, procID: AudioDeviceIOProcID,
                                     scope: AudioObjectPropertyScope, isOn: (Int) -> Bool) -> OSStatus {
        var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        guard status == noErr else { return status }
        let header = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
        guard Int(size) >= header else { return kAudioHardwareBadPropertySizeError }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        memset(raw, 0, Int(size))
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        // mIOProc is an INPUT to the get call: it selects which IOProc's usage is returned.
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        var bytes = size
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &bytes, raw)
        guard status == noErr else { return status }
        let count = Int(usage.pointee.mNumberStreams)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn) ?? 12
        guard count > 0, flagsOffset + count * 4 <= Int(size) else { return noErr }
        for i in 0..<count {
            raw.storeBytes(of: isOn(i) ? 1 : 0, toByteOffset: flagsOffset + i * 4, as: UInt32.self)
        }
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, raw)
    }
}

// =====================================================================================
// Input mute state of a device (the first mute signal of MuteGate, SPEC 18; W7b)
//
// kAudioDevicePropertyMute (a mute switch: a USB microphone's hardware button, a headset's mute key, the system's own mute) and
// kAudioDevicePropertyVolumeScalar (the input volume slider: 0 means nothing is recorded) on the INPUT scope. Reading them needs no
// permission. A device may carry them on the main element or only per channel (1, 2, ...), and many (aggregate, virtual, some
// Bluetooth headsets) carry neither: that is `unknown` (the gate then records), never 'unmuted by default'.
// =====================================================================================

extension CaptureHAL {
    /// The four reads the rule below needs, as closures so the self test can stand in for the HAL (a device with only per-channel
    /// switches, a volume of 0, no property at all ...). `.live` is the Core Audio.
    struct InputMuteProperties {
        var supports: (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyElement) -> Bool
        var readUInt32: (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyElement) -> UInt32?
        var readFloat32: (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyElement) -> Float32?
        var inputChannels: (AudioObjectID) -> Int

        static let live = InputMuteProperties(
            supports: { device, selector, element in
                var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
                return AudioObjectHasProperty(device, &addr)
            },
            readUInt32: { device, selector, element in
                var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
                var value: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
            },
            readFloat32: { device, selector, element in
                var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
                var value: Float32 = 0
                var size = UInt32(MemoryLayout<Float32>.size)
                return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
            },
            inputChannels: { device in
                CaptureHAL.streams(device, input: true).reduce(0) { $0 + Int(CaptureHAL.streamFormat($1)?.mChannelsPerFrame ?? 0) }
            })
    }

    /// An input volume at or below this reads as muted (the slider at 0; a slider a hair above it still records).
    static let mutedInputVolume: Float32 = 0.001

    /// muted: the mute switch is on (all channels, when it is per channel) or the input volume is 0 (all channels). unmuted: at least one
    /// of the two properties could be read and neither says muted. unknown: the device offers neither (or they cannot be read).
    static func inputMuteReading(device: AudioObjectID, properties p: InputMuteProperties = .live) -> MuteReading {
        let main = kAudioObjectPropertyElementMain
        let channels = min(max(p.inputChannels(device), 0), 8)
        func perElement<T>(_ selector: AudioObjectPropertySelector, _ read: (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyElement) -> T?) -> [T] {
            if p.supports(device, selector, main) { return read(device, selector, main).map { [$0] } ?? [] }
            guard channels >= 1 else { return [] }
            return (1...channels).compactMap { channel in
                let element = AudioObjectPropertyElement(channel)
                return p.supports(device, selector, element) ? read(device, selector, element) : nil
            }
        }
        let switches: [UInt32] = perElement(kAudioDevicePropertyMute, p.readUInt32)
        let volumes: [Float32] = perElement(kAudioDevicePropertyVolumeScalar, p.readFloat32)
        if !switches.isEmpty && switches.allSatisfy({ $0 != 0 }) { return .muted }
        if !volumes.isEmpty && volumes.allSatisfy({ $0 <= mutedInputVolume }) { return .muted }
        return switches.isEmpty && volumes.isEmpty ? .unknown : .unmuted
    }
}

// =====================================================================================
// HALBackend: the only place where an IOProc is attached to / detached from a device. Injectable so the
// rebuild / stall / heal logic of HALCapture can be unit-tested with a fake (no devices, no permissions).
// =====================================================================================

protocol HALBackend: AnyObject {
    /// Attaches `block` to `opened.ioDevice` and starts IO. Throws on failure (nothing is left attached).
    func startIO(opened: HALCapture.Opened, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock, label: String) throws -> AnyObject
    /// Stops IO and detaches. Must not deliver anything to the block after it returns.
    func stopIO(opened: HALCapture.Opened, handle: AnyObject, label: String)
}

final class CoreAudioBackend: HALBackend {
    private final class Handle {
        let procID: AudioDeviceIOProcID
        init(_ p: AudioDeviceIOProcID) { procID = p }
    }

    func startIO(opened: HALCapture.Opened, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock, label: String) throws -> AnyObject {
        var procIDOut: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procIDOut, opened.ioDevice, queue, block)
        guard status == noErr, let procID = procIDOut else {
            throw RecorderError.failed("\(label): AudioDeviceCreateIOProcIDWithBlock failed: \(CaptureHAL.describe(status))")
        }
        applyStreamUsage(opened: opened, procID: procID, label: label)
        status = AudioDeviceStart(opened.ioDevice, procID)
        guard status == noErr else {
            _ = AudioDeviceDestroyIOProcID(opened.ioDevice, procID)
            throw RecorderError.failed("\(label): AudioDeviceStart failed: \(CaptureHAL.describe(status))")
        }
        return Handle(procID)
    }

    func stopIO(opened: HALCapture.Opened, handle: AnyObject, label: String) {
        guard let h = handle as? Handle else { return }
        let stopStatus = AudioDeviceStop(opened.ioDevice, h.procID)
        let destroyStatus = AudioDeviceDestroyIOProcID(opened.ioDevice, h.procID)
        if stopStatus != noErr || destroyStatus != noErr {
            Log.info("\(label): teardown statuses stop=\(CaptureHAL.describe(stopStatus)) destroy=\(CaptureHAL.describe(destroyStatus)) (expected if the device vanished)")
        }
    }

    private func applyStreamUsage(opened: HALCapture.Opened, procID: AudioDeviceIOProcID, label: String) {
        if opened.disableOutputStreams && !CaptureHAL.streams(opened.ioDevice, input: false).isEmpty {
            let st = CaptureHAL.setIOProcStreamUsage(device: opened.ioDevice, procID: procID, scope: kAudioObjectPropertyScopeOutput) { _ in false }
            if st != noErr { Log.info("\(label): could not switch off output streams (\(CaptureHAL.describe(st))); harmless") }
        }
        if let tail = opened.tailChannels {
            let streams = CaptureHAL.streams(opened.ioDevice, input: true)
            var keep = Set<Int>()
            var channels = 0
            var i = streams.count
            while i > 0 && channels < tail {
                i -= 1
                keep.insert(i)
                channels += Int(CaptureHAL.streamFormat(streams[i])?.mChannelsPerFrame ?? 0)
            }
            if streams.count > keep.count {
                let st = CaptureHAL.setIOProcStreamUsage(device: opened.ioDevice, procID: procID, scope: kAudioObjectPropertyScopeInput) { keep.contains($0) }
                Log.info("\(label): aggregate has \(streams.count) input streams, using last \(keep.count); stream usage status \(CaptureHAL.describe(st))")
            }
        }
    }
}

// =====================================================================================
// HALCapture: open -> IOProc -> mono Float32 at `targetRate` -> handler. Rebuilds on change.
// =====================================================================================

final class HALCapture {
    /// Everything `open()` produced for one build of the capture graph.
    struct Opened {
        var ioDevice: AudioObjectID                 // device the IOProc is attached to (aggregate or input device)
        var deviceName: String                      // human-readable name for logs / session.json
        var nativeRate: Double                      // rate of the buffers the IOProc receives
        var kind: CaptureHAL.SampleKind
        var maxChannels: Int                        // channels averaged into the mono mix
        var tailChannels: Int?                      // see CaptureHAL.Mixer.selectBuffers; nil = all buffers
        var disableOutputStreams: Bool              // IOProc is input-only
        var watched: [(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope)]
        /// Describes the environment this build was made for (default device UID, rates...).
        var signature: String
        /// Recomputes the same description now; a different value means "rebuild".
        var currentSignature: () -> String
        /// Destroys what open() created (aggregate device, tap). Called after the IOProc is gone.
        var cleanup: () -> Void
        /// Tap only: seconds of exact digital silence (while other apps have audio output open) after which THIS build is
        /// re-created, instead of waiting for `Timing.zeroHealAfter`. SystemAudioTap sets it for a host strategy that has
        /// not delivered audio yet and has an alternative, so a wrong clock-device choice costs seconds of the remote
        /// track, not 45 s. nil = the normal threshold.
        var quickSilenceHeal: TimeInterval? = nil
        /// Called (control queue) when the HAL refused to start IO on this build (AudioDeviceStart failed), before
        /// `cleanup`. SystemAudioTap uses it to try another host strategy next time.
        var onStartFailure: ((Error) -> Void)? = nil
        /// Exact nominal rates the HAL reports for this graph right now (aggregate, host device, ...). Read on the work queue,
        /// only when the measured delivered rate differs from `nativeRate`: a hint that agrees with the measurement is adopted
        /// as is (instead of the nearest standard rate) and named in the log.
        var rateHints: () -> [(name: String, rate: Double)] = { [] }
        /// What `nativeRate` came from, for the log ("tap format", "device format").
        var rateSourceName: String = "device format"
        /// Called (control queue) once per recorder report when the recorder saw a rate-like gap pattern and neither the measured
        /// delivered rate nor the recorder's own ratio could explain it. Return true to re-create the graph at once
        /// (SystemAudioTap: the next tap host strategy, once per output device).
        var onRateProblemUnresolved: (() -> Bool)? = nil
    }

    let label: String
    let targetRate: Double
    var handler: (([Float], UInt64) -> Void)?
    var onWarning: ((String) -> Void)?
    var onDeviceChange: ((String) -> Void)?
    /// Called once per build (control queue, within one health tick) when the graph delivered a non-zero sample for the
    /// first time: the proof that this build of the capture graph really captures something.
    var onFirstAudio: (() -> Void)?

    /// Timing knobs. Production uses the defaults; the self-test shrinks them to exercise the logic quickly.
    struct Timing {
        var tick: TimeInterval = 2                     // health tick
        var stallAfter: TimeInterval = 8               // no IOProc callbacks for this long => rebuild (backoff to 15x)
        var zeroHealAfter: TimeInterval = 45           // exact digital silence while others play => rebuild
        var zeroBackoffStart: TimeInterval = 60        // doubles per unproductive heal ...
        var zeroBackoffMax: TimeInterval = 600         // ... up to this
        var debounce: TimeInterval = 0.5               // collapses bursts of device events
        var retryDelays: [TimeInterval] = [1, 2, 5, 10, 30]
        // Delivered-rate verification (RateMeter / RateJudge). Off only in the self-test that reproduces the old defect.
        var rateMeasurement = true
        var rateInitialSeconds: TimeInterval = 0.8     // host-time coverage needed before the first audio of a build is delivered
        var rateInitialMax: TimeInterval = 2.0         // audio is never held back longer than this (decide with what there is)
        var rateConfirmSeconds: TimeInterval = 1.0     // window of the continuous re-measurement (a change needs 2 agreeing looks)
        var rateEvalInterval: TimeInterval = 0.25      // continuous re-measurement cadence (host time)
        var rateRetention: TimeInterval = 3.0          // sliding window kept by the meter
    }

    private let open: () throws -> Opened
    private let backend: HALBackend
    private let timing: Timing
    private let systemTriggers: [AudioObjectPropertySelector]
    private let healZeroRun: Bool
    private let outputActivity: (() -> Bool)?

    private let control: DispatchQueue
    private let ioQueue: DispatchQueue
    private let workQueue: DispatchQueue

    // control-queue state
    private var running = false
    private var active: Active?
    private var systemListeners: [CaptureHAL.PropertyListener] = []
    private var pendingCheck: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var failureCount = 0
    private var healthTimer: DispatchSourceTimer?
    private var stallBackoff: TimeInterval
    private var nextStallRebuildAt: TimeInterval = 0
    private var zeroBackoff: TimeInterval
    private var nextZeroHealAt: TimeInterval = 0
    private var zeroWarned = false

    private let stateLock = NSLock()
    private var _deviceName = ""
    private var _zeroHeals = 0
    private var _effectiveRate: Double = 0
    private var _rateChanges = 0
    private var rateWarned = Set<String>()          // control queue only: one warning per configured->effective pair
    private static let maxRateWarnings = 3

    /// How many times the zero-buffer workaround rebuilt the graph. SystemAudioTap uses it to alternate its
    /// host-device strategy when a rebuild did not bring audio back.
    var zeroHealCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _zeroHeals
    }

    /// The rate the samples of the running graph are interpreted at: the configured rate until the delivered rate has been
    /// verified against the host clock (first ~1 s of a build), then the measured one. 0 before the first build.
    var effectiveRate: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return _effectiveRate
    }

    /// How many times a delivered rate that differs from the configured / previous one was adopted (all builds).
    var rateChangeCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _rateChanges
    }

    private final class Active {
        let opened: Opened
        let handle: AnyObject
        let context: StreamContext
        var listeners: [CaptureHAL.PropertyListener] = []
        var audioReported = false
        init(opened: Opened, handle: AnyObject, context: StreamContext) {
            self.opened = opened
            self.handle = handle
            self.context = context
        }
    }

    init(label: String, targetRate: Double, systemTriggers: [AudioObjectPropertySelector],
         healZeroRun: Bool, outputActivity: (() -> Bool)? = nil, backend: HALBackend = CoreAudioBackend(),
         timing: Timing = Timing(), open: @escaping () throws -> Opened) {
        self.label = label
        self.targetRate = targetRate
        self.systemTriggers = systemTriggers
        self.healZeroRun = healZeroRun
        self.outputActivity = outputActivity
        self.backend = backend
        self.timing = timing
        self.stallBackoff = timing.stallAfter
        self.zeroBackoff = timing.zeroBackoffStart
        self.open = open
        let tag = label.replacingOccurrences(of: " ", with: "-")
        self.control = DispatchQueue(label: "\(AppInfo.bundleID).\(tag).control", qos: .userInitiated)
        self.ioQueue = DispatchQueue(label: "\(AppInfo.bundleID).\(tag).io", qos: .userInteractive)
        self.workQueue = DispatchQueue(label: "\(AppInfo.bundleID).\(tag).work", qos: .userInitiated)
    }

    var deviceName: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return _deviceName
    }

    // MARK: Start / stop

    /// First build happens synchronously so the caller gets a real error. Later failures retry in the background.
    func start() throws {
        var failure: Error?
        control.sync {
            guard !running else { return }
            do {
                try build()
                running = true
                failureCount = 0
                installSystemListeners()
                startHealthTimer()
            } catch {
                failure = error
            }
        }
        if let failure = failure { throw failure }
    }

    /// Asks for a rebuild now (ignores the signature check). Used by tests and for external events.
    func requestRebuild(reason: String) {
        control.async { [weak self] in
            guard let self = self, self.running, self.active != nil else { return }
            self.rebuild(reason: reason)
        }
    }

    func stop() {
        control.sync {
            guard running else { return }
            running = false
            pendingCheck?.cancel(); pendingCheck = nil
            retryWork?.cancel(); retryWork = nil
            healthTimer?.cancel(); healthTimer = nil
            systemListeners.forEach { $0.remove() }
            systemListeners = []
            if let a = active { teardown(a); active = nil }
        }
    }

    // MARK: Build / teardown (control queue)

    private func build() throws {
        let opened = try open()
        let resampler: CaptureHAL.Resampler?
        if abs(opened.nativeRate - targetRate) > 0.5 {
            guard let r = CaptureHAL.Resampler(from: opened.nativeRate, to: targetRate) else {
                opened.cleanup()
                throw RecorderError.failed("\(label): cannot create \(opened.nativeRate) -> \(targetRate) Hz resampler")
            }
            resampler = r
        } else {
            resampler = nil
        }
        let context = StreamContext(label: label, opened: opened, resampler: resampler, targetRate: targetRate, tuning: timing,
                                    workQueue: workQueue) { [weak self] samples, host in
            self?.handler?(samples, host)
        }
        context.onRateChange = { [weak self, weak context] change in
            // work queue -> control queue; a late event of a graph that has been replaced is dropped
            self?.control.async { [weak self] in
                guard let self = self, let context = context, let a = self.active, a.context === context else { return }
                self.rateChanged(change, opened: a.opened)
            }
        }
        context.onUnresolved = { [weak self, weak context] in
            self?.control.async { [weak self] in
                guard let self = self, let context = context, let a = self.active, a.context === context,
                      let wanted = a.opened.onRateProblemUnresolved, wanted() else { return }
                self.rebuild(reason: "periodic gap fills that neither the measured rate nor the recorder's ratio explain; the owner asked for a new graph")
            }
        }
        let handle: AnyObject
        do {
            handle = try backend.startIO(opened: opened, queue: ioQueue, block: context.makeIOBlock(), label: label)
        } catch {
            opened.onStartFailure?(error)
            opened.cleanup()
            throw error
        }
        let a = Active(opened: opened, handle: handle, context: context)
        for w in opened.watched {
            if let l = CaptureHAL.PropertyListener(object: w.object, selector: w.selector, scope: w.scope, queue: control,
                                                   handler: { [weak self] in self?.scheduleCheck(reason: "device property changed") }) {
                a.listeners.append(l)
            }
        }
        active = a
        stateLock.lock(); _deviceName = opened.deviceName; _effectiveRate = opened.nativeRate; stateLock.unlock()
        Log.info("\(label): capturing '\(opened.deviceName)' native \(Int(opened.nativeRate)) Hz -> \(Int(targetRate)) Hz"
                 + (resampler == nil ? " (no resampling)" : " (resampling)")
                 + (timing.rateMeasurement ? "; the delivered rate is verified against the host clock before the first audio is released" : ""))
    }

    // MARK: Rate events (control queue)

    /// The context measured a delivered rate that differs from the one it was using (first verification of a build, a change
    /// in the middle of it, or the recorder's hint). Logs it and raises ONE warning per configured -> effective pair (session.json).
    private func rateChanged(_ change: RateChange, opened: Opened) {
        guard running else { return }
        stateLock.lock(); _effectiveRate = change.to; _rateChanges += 1; stateLock.unlock()
        let to = Int(change.to.rounded()), configured = Int(change.configured.rounded())
        if change.gaveUp {
            // (the log line was written where the decision was made, see StreamContext.giveUp)
            if rateWarned.insert("gave up").inserted {
                onWarning?("the delivered-rate measurement kept changing its mind (\(change.how)); the track uses the \(opened.rateSourceName) \(configured) Hz again "
                           + "and is not re-measured until the capture is rebuilt")
            }
            return
        }
        if abs(change.to / change.configured - 1) <= CaptureHAL.RateJudge.sameRateTolerance {
            Log.info("\(label): effective rate is \(to) Hz again, the same as the \(opened.rateSourceName) \(configured) Hz (\(change.how))")
            return
        }
        let text = "effective rate \(to) Hz differs from \(opened.rateSourceName) \(configured) Hz: resampling from \(to)"
        Log.warn("\(label): \(text) (\(change.how)\(change.initial ? "; found while verifying a new graph, no audio was written at the wrong rate" : "; changed while recording"))")
        let key = "\(configured)->\(to)"
        if !rateWarned.contains(key), rateWarned.count < Self.maxRateWarnings {
            rateWarned.insert(key)
            onWarning?(text + " (e.g. Bluetooth hands-free profile); the track is converted to \(Int(targetRate)) Hz, not zero-filled")
        }
    }

    /// The recorder classified sustained equal gap fills as a rate problem (Track / GapPatternDetector): re-measure now.
    /// If the delivered rate cannot be measured, the recorder's own delivered/expected ratio is used when it lands on a
    /// standard rate.
    func rateSuspected(deliveredRatio: Double) {
        control.async { [weak self] in
            guard let self = self, self.running, let a = self.active else { return }
            Log.info("\(self.label): the recorder reports periodic gap fills (delivered/expected = \(String(format: "%.2f", deliveredRatio))); re-measuring the delivered rate")
            a.context.recheck(deliveredRatio: deliveredRatio)
        }
    }

    /// Order matters (an earlier version cleared `active` first and silently discarded every buffer still queued
    /// on the work queue, up to the whole backlog at stop / device change):
    ///   1. stop IO         -> the HAL calls the IOProc no more
    ///   2. ioQueue.sync    -> an IOProc block that was already running has finished and queued its buffer
    ///   3. workQueue.sync  -> every queued buffer is processed and DELIVERED (context.active is still true here),
    ///                         so the last audio before stop / rebuild is not lost
    ///   3b. finish         -> audio still held back for the delivered-rate verification (a graph younger than ~1 s) is decided
    ///                         with what was measured and delivered, then the resampler's tail (a few frames that only an
    ///                         end-of-stream call releases) is delivered too
    ///   4. active = false  -> nothing can run for this graph any more (belt and braces for a misbehaving backend)
    ///   5. listeners, cleanup (destroy aggregate + tap)
    /// When this returns, nothing from the old graph is delivered any more.
    private func teardown(_ a: Active) {
        backend.stopIO(opened: a.opened, handle: a.handle, label: label)
        ioQueue.sync {}
        workQueue.sync {}
        workQueue.sync { a.context.finish() }     // held-back audio + the converter's filter tail (0.3 to 2 ms) of the last buffer
        a.context.active = false
        a.listeners.forEach { $0.remove() }
        a.listeners = []
        a.opened.cleanup()
    }

    // MARK: Triggers (control queue)

    private func installSystemListeners() {
        // coreaudiod restarted: every AudioObjectID we hold is stale, rebuild even if the signature looks unchanged.
        if let l = CaptureHAL.PropertyListener(object: CaptureHAL.systemObject, selector: kAudioHardwarePropertyServiceRestarted,
                                               scope: kAudioObjectPropertyScopeGlobal, queue: control,
                                               handler: { [weak self] in self?.scheduleCheck(reason: "Core Audio service restarted", force: true) }) {
            systemListeners.append(l)
        }
        for selector in systemTriggers {
            if let l = CaptureHAL.PropertyListener(object: CaptureHAL.systemObject, selector: selector, scope: kAudioObjectPropertyScopeGlobal,
                                                   queue: control, handler: { [weak self] in self?.scheduleCheck(reason: "default device changed") }) {
                systemListeners.append(l)
            } else {
                Log.warn("\(label): could not install system property listener \(CaptureHAL.describe(OSStatus(bitPattern: selector))); relying on polling")
            }
        }
    }

    /// Debounced: bursts of events (AirPods connect fires several) collapse into one signature check.
    private func scheduleCheck(reason: String, force: Bool = false) {
        guard running else { return }
        pendingCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkEnvironment(reason: reason, force: force) }
        pendingCheck = item
        control.asyncAfter(deadline: .now() + timing.debounce, execute: item)
    }

    /// Rebuilds only if the environment really differs from what the current graph was built for (loop-proof).
    private func checkEnvironment(reason: String, force: Bool = false) {
        guard running else { return }
        guard let a = active else { return }          // already retrying
        let now = a.opened.currentSignature()
        if force {
            rebuild(reason: reason)
        } else if now != a.opened.signature {
            rebuild(reason: "\(reason): \(a.opened.signature) -> \(now)")
        }
    }

    private func rebuild(reason: String) {
        guard running else { return }
        pendingCheck?.cancel(); pendingCheck = nil
        retryWork?.cancel(); retryWork = nil
        Log.info("\(label): rebuilding capture (\(reason))")
        if let a = active { teardown(a); active = nil }
        do {
            try build()
            failureCount = 0
            onDeviceChange?(deviceName)
        } catch {
            handleBuildFailure(error)
        }
    }

    private func handleBuildFailure(_ error: Error) {
        failureCount += 1
        let delays = timing.retryDelays
        let delay = delays[min(failureCount - 1, delays.count - 1)]
        if failureCount == 1 {
            onWarning?("\(label) capture lost, retrying: \(error)")
        }
        Log.warn("\(label): rebuild failed (attempt \(failureCount)): \(error); retry in \(String(format: "%.1f", delay)) s")
        let item = DispatchWorkItem { [weak self] in self?.retryBuild() }
        retryWork = item
        control.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func retryBuild() {
        guard running, active == nil else { return }
        do {
            try build()
            Log.info("\(label): capture recovered after \(failureCount) failed attempt(s)")
            failureCount = 0
            onDeviceChange?(deviceName)
        } catch {
            handleBuildFailure(error)
        }
    }

    // MARK: Health tick (control queue, every 2 s)

    private func startHealthTimer() {
        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + timing.tick, repeating: timing.tick, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.healthTick() }
        t.resume()
        healthTimer = t
    }

    private func healthTick() {
        guard running, let a = active else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // 1. Environment polling: backup for property listeners that macOS did not deliver.
        if a.opened.currentSignature() != a.opened.signature {
            checkEnvironment(reason: "polling")
            return
        }

        // 2. Stall: the IOProc stopped being called (or never was after a build).
        let snap = a.context.snapshot()
        let idle = now - snap.lastFrameUptime
        if idle > timing.stallAfter {
            if now >= nextStallRebuildAt {
                nextStallRebuildAt = now + stallBackoff
                stallBackoff = min(stallBackoff * 2, timing.stallAfter * 15)
                rebuild(reason: String(format: "no audio callbacks for %.0f s", idle))
            }
            return
        }
        if snap.framesSeen > 0 { stallBackoff = timing.stallAfter }       // frames flow again: forget the backoff
        if snap.sawAudio && !a.audioReported {
            a.audioReported = true
            onFirstAudio?()
        }

        // 3. Zero-buffer workaround (tap only).
        guard healZeroRun else { return }
        let zeroSeconds = Double(snap.zeroRunFrames) / max(snap.rate, 1)
        if snap.sawAudio && zeroSeconds == 0 { zeroBackoff = timing.zeroBackoffStart }       // the tap demonstrably works: forget the backoff
        let healAfter = min(a.opened.quickSilenceHeal ?? timing.zeroHealAfter, timing.zeroHealAfter)
        guard zeroSeconds >= healAfter, now >= nextZeroHealAt, outputActivity?() == true else { return }
        let quick = healAfter < timing.zeroHealAfter
        nextZeroHealAt = now + zeroBackoff
        zeroBackoff = min(zeroBackoff * 2, timing.zeroBackoffMax)
        stateLock.lock(); _zeroHeals += 1; stateLock.unlock()
        // A quick heal (an unproven host strategy was silent for a few seconds) only goes to the log: a quiet start of a
        // call looks the same, and it is not worth a menu warning. The long-silence warning is once per recording.
        if !quick && !zeroWarned {
            zeroWarned = true
            onWarning?("\(label) has been digital silence for \(Int(zeroSeconds)) s while other apps have audio output open "
                       + "(quiet meeting, lost 'System Audio Recording' permission, or a stuck tap). Re-creating the tap.")
        }
        rebuild(reason: String(format: "digital silence for %.0f s while audio output is active%@", zeroSeconds,
                               quick ? " (early check of a host strategy that has not delivered audio yet)" : ""))
    }
}


// MARK: - Per-build IO context

/// A change of the rate the samples of one graph are interpreted at (work queue -> HALCapture, control queue).
private struct RateChange {
    var from: Double                // rate used until now
    var to: Double                  // rate used from now on
    var configured: Double          // what the graph claimed (Opened.nativeRate)
    var measured: Double            // measured frames per host second (0 = taken from the recorder's ratio)
    var how: String
    var initial: Bool               // found by the verification of a new graph, before any audio was released
    var gaveUp = false              // the measurement flapped: back to the graph's configured rate, no more re-measuring in this graph
}

/// State of one build of the capture graph. The IOProc block only touches this object.
///
/// Delivered-rate verification: the first audio of a build is HELD BACK (up to rateInitialSeconds of host time, at most
/// rateInitialMax) until the RateMeter says at which rate the IOProc really delivers frames; the held audio is then released
/// through a resampler for THAT rate. So no audio is ever written at a wrong rate at the start of a build. Afterwards the
/// meter keeps measuring (sliding window); a stable change (device switched profile without any property notification) swaps
/// the resampler in place. If the graph is torn down before the verification is done, the held audio is released with the
/// best available estimate (or the configured rate).
private final class StreamContext {
    let label: String
    let kind: CaptureHAL.SampleKind
    let maxChannels: Int
    let tailChannels: Int?
    let configuredRate: Double
    let targetRate: Double
    let tuning: HALCapture.Timing
    let workQueue: DispatchQueue
    let deliver: ([Float], UInt64) -> Void
    let hints: () -> [(name: String, rate: Double)]
    /// Work queue. HALCapture hops to its control queue.
    var onRateChange: ((RateChange) -> Void)?
    /// Work queue: the recorder's gap pattern could not be explained (see recheck).
    var onUnresolved: (() -> Void)?
    /// Cleared by HALCapture.teardown AFTER IO stopped and both queues were drained (queued buffers are delivered
    /// first). From then on any late block does nothing. Only written when no block can be running.
    var active = true

    private var loggedLayout = false                       // io queue only

    // work queue only
    private var sourceRate: Double
    private var resampler: CaptureHAL.Resampler?
    private var meter: CaptureHAL.RateMeter
    private var live = false                               // false while the first audio of this build is held back
    private var held: [(samples: [Float], host: UInt64)] = []
    private var heldSince = 0.0                            // meter host seconds of the first held buffer
    private var heldFrames = 0                             // frames held back: the hold also ends by SIZE (stamps that do not advance)
    private var lastEvaluation = -Double.infinity
    private var pendingRate: Double?
    private var liveSwitches = 0                           // in-place rate changes of this graph (after the verification)
    private var gaveUp = false                             // the measurement flapped: configured rate, no more re-measuring
    /// A rate that is adopted and dropped again this many times inside ONE graph is a measurement problem, not a device (a profile
    /// switch rebuilds the graph, a silent one is one or two changes): the graph then goes back to its configured rate for good.
    static let maxLiveSwitches = 6
    private var endHost: UInt64?                           // host time just after the last delivered buffer

    private let lock = NSLock()
    private var lastFrameUptime = ProcessInfo.processInfo.systemUptime
    private var zeroRunFrames: Int64 = 0
    private var framesSeen: Int64 = 0
    private var sawAudio = false
    private var rateNow: Double

    init(label: String, opened: HALCapture.Opened, resampler: CaptureHAL.Resampler?, targetRate: Double, tuning: HALCapture.Timing,
         workQueue: DispatchQueue, deliver: @escaping ([Float], UInt64) -> Void) {
        self.label = label
        self.kind = opened.kind
        self.maxChannels = opened.maxChannels
        self.tailChannels = opened.tailChannels
        self.configuredRate = opened.nativeRate
        self.targetRate = targetRate
        self.tuning = tuning
        self.sourceRate = opened.nativeRate
        self.rateNow = opened.nativeRate
        self.resampler = resampler
        self.meter = CaptureHAL.RateMeter(retention: tuning.rateRetention)
        self.hints = opened.rateHints
        self.workQueue = workQueue
        self.deliver = deliver
    }

    func snapshot() -> (lastFrameUptime: TimeInterval, zeroRunFrames: Int64, framesSeen: Int64, sawAudio: Bool, rate: Double) {
        lock.lock(); defer { lock.unlock() }
        return (lastFrameUptime, zeroRunFrames, framesSeen, sawAudio, rateNow)
    }

    func makeIOBlock() -> AudioDeviceIOBlock {
        return { [self] _, inInput, inInputTime, _, _ in
            ioCallback(inInput, inInputTime)
        }
    }

    /// Runs on the IO queue (Core Audio dispatch_syncs into it): mix to mono and hand off. No disk, no locks held long.
    private func ioCallback(_ inInput: UnsafePointer<AudioBufferList>, _ inTime: UnsafePointer<AudioTimeStamp>) {
        guard active else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
        guard abl.count > 0 else { return }
        if !loggedLayout {
            loggedLayout = true
            let layout = abl.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ", ")
            Log.info("\(label): first IO callback, input buffers: [\(layout)], format \(kind), tail=\(tailChannels.map(String.init) ?? "all")")
        }
        let range = CaptureHAL.Mixer.selectBuffers(abl, tailChannels: tailChannels)
        var mono: [Float] = []
        let frames = CaptureHAL.Mixer.mix(abl, range: range, kind: kind, maxChannels: maxChannels, into: &mono)
        guard frames > 0 else { return }
        let host: UInt64
        var meterSeconds: Double
        if inTime.pointee.mFlags.contains(.hostTimeValid) && inTime.pointee.mHostTime != 0 {
            host = inTime.pointee.mHostTime
            meterSeconds = CaptureHAL.Clock.seconds(host)
        } else {
            // No usable timestamp: assume the buffer just ended now. (The rate meter then uses the arrival time: a callback
            // cadence is still a rate, just a noisier one.)
            host = CaptureHAL.Clock.now() &- CaptureHAL.Clock.ticks(seconds: Double(frames) / configuredRate)
            meterSeconds = CaptureHAL.Clock.seconds(CaptureHAL.Clock.now())
        }
        workQueue.async { [self] in process(mono, host, meterSeconds) }
    }

    // MARK: work queue

    private func process(_ mono: [Float], _ host: UInt64, _ meterSeconds: Double) {
        guard active else { return }
        var peak: Float = 0
        for s in mono { peak = max(peak, abs(s)) }
        lock.lock()
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        framesSeen += Int64(mono.count)
        if peak == 0 {
            zeroRunFrames += Int64(mono.count)
        } else {
            zeroRunFrames = 0
            sawAudio = true
        }
        lock.unlock()

        guard tuning.rateMeasurement else {
            live = true
            emit(mono, host)
            return
        }
        meter.add(host: meterSeconds, frames: mono.count)
        if !live {
            if held.isEmpty { heldSince = meterSeconds }
            held.append((mono, host))
            heldFrames += mono.count
            decideInitial(now: meterSeconds, final: false)
            return
        }
        emit(mono, host)
        reevaluate(now: meterSeconds)
    }

    /// Resample (if needed) and hand to the recorder, stamped with the host time of the first frame.
    private func emit(_ mono: [Float], _ host: UInt64) {
        let out = resampler?.process(mono) ?? mono
        endHost = host &+ CaptureHAL.Clock.ticks(seconds: Double(mono.count) / sourceRate)
        guard !out.isEmpty else { return }
        deliver(out, host)
    }

    /// First verdict of this graph. Ready when the meter has a stationary estimate over `rateInitialSeconds`, or after
    /// `rateInitialMax` of holding (decide with what there is), or at teardown (`final`).
    private func decideInitial(now: Double, final: Bool) {
        guard !live else { return }
        var estimate = meter.estimate(lastSeconds: tuning.rateInitialSeconds)
        var ready = false
        if let e = estimate, e.coverage >= 0.6 * tuning.rateInitialSeconds, e.stationary {
            ready = true
        } else if final {
            ready = true
            if let e = estimate, e.coverage < 0.3 { estimate = nil }
        } else if now - heldSince >= tuning.rateInitialMax {
            ready = true
            estimate = meter.estimate(lastSeconds: tuning.rateConfirmSeconds)
            if let e = estimate, e.coverage < 0.4 { estimate = nil }
        } else if heldFrames >= Int(1.5 * tuning.rateInitialMax * max(configuredRate, 8000)) {
            // The deadline above is measured on the very clock under test. A driver whose stamps do not advance (or run backwards)
            // would hold the audio of the whole recording for ever: so the hold also ends by size, at 3x the longest normal hold.
            ready = true
            estimate = meter.estimate(lastSeconds: tuning.rateConfirmSeconds)
            if let e = estimate, e.coverage < 0.4 { estimate = nil }
            Log.warn("\(label): \(heldFrames) frames were held for the delivered-rate verification without the host time stamps allowing a verdict "
                     + "(unusable stamps?); releasing them at \(estimate == nil ? "the graph's \(Int(configuredRate)) Hz" : "the measured rate")")
        }
        guard ready else { return }

        // One diagnostic line per build: what was measured against what the graph claims and what the HAL says now (IO is running,
        // so an aggregate's actual rate is meaningful here, unlike at open time).
        let figures = hints().map { "\($0.name) \(Int($0.rate.rounded())) Hz" }.joined(separator: ", ")
        if let e = estimate {
            Log.info("\(label): delivered rate verified over \(String(format: "%.2f", e.coverage)) s of host time: \(Int(e.rate.rounded())) Hz "
                     + "(the graph claims \(Int(configuredRate)) Hz); HAL figures now: \(figures.isEmpty ? "none" : figures)")
        } else {
            Log.info("\(label): delivered rate could not be measured yet; using the graph's \(Int(configuredRate)) Hz; HAL figures now: \(figures.isEmpty ? "none" : figures)")
        }

        var change: RateChange?
        if let e = estimate, let v = CaptureHAL.RateJudge.verdict(assumed: configuredRate, measured: e.rate, hints: hints), v.mismatch,
           switchRate(to: v.rate) {
            change = RateChange(from: configuredRate, to: v.rate, configured: configuredRate, measured: e.rate, how: v.how, initial: true)
        }
        live = true
        let pending = held
        held = []
        heldFrames = 0
        for item in pending { emit(item.samples, item.host) }
        if let c = change { onRateChange?(c) }
    }

    /// Continuous re-measurement of a live graph: a change needs two agreeing looks of a stationary window.
    private func reevaluate(now: Double) {
        guard !gaveUp, now - lastEvaluation >= tuning.rateEvalInterval else { return }
        lastEvaluation = now
        guard let e = meter.estimate(lastSeconds: tuning.rateConfirmSeconds), e.coverage >= 0.6 * tuning.rateConfirmSeconds, e.stationary,
              let v = CaptureHAL.RateJudge.verdict(assumed: sourceRate, measured: e.rate, hints: hints) else { return }
        guard v.mismatch else { pendingRate = nil; return }
        if let p = pendingRate, abs(p / v.rate - 1) < CaptureHAL.RateJudge.sameRateTolerance {
            pendingRate = nil
            let from = sourceRate
            if liveSwitches >= Self.maxLiveSwitches {
                giveUp(measured: e.rate)
            } else if switchRate(to: v.rate) {
                onRateChange?(RateChange(from: from, to: v.rate, configured: configuredRate, measured: e.rate, how: v.how, initial: false))
            }
        } else {
            pendingRate = v.rate
        }
    }

    /// Work queue. The measured rate has been adopted and dropped again `maxLiveSwitches` times inside this graph: that is a measurement
    /// that cannot be trusted here (stamps that jitter, a clock that wanders), not a device that switches profile that often. Back to what
    /// the graph claims (the behaviour from before the measurement existed), no more re-measuring, ONE warning.
    private func giveUp(measured: Double) {
        gaveUp = true
        pendingRate = nil
        let from = sourceRate
        Log.warn("\(label): the measured delivered rate changed \(liveSwitches) times inside one capture graph; that is not a device switching profile, "
                 + "the measurement is unreliable here. Going back to the graph's \(Int(configuredRate)) Hz and measuring no more until the graph is rebuilt")
        if switchRate(to: configuredRate) {
            onRateChange?(RateChange(from: from, to: configuredRate, configured: configuredRate, measured: measured,
                                     how: "the rate measurement flapped (\(liveSwitches) changes in one graph)", initial: false, gaveUp: true))
        }
    }

    /// Work queue: the recorder says the timeline lags in a regular pattern. The meter has the last word when it can measure.
    func recheck(deliveredRatio: Double) {
        workQueue.async { [self] in
            guard active, live else { return }
            if gaveUp {
                Log.info("\(label): the recorder reports periodic gap fills, but the rate measurement of this graph was given up (it flapped); keeping \(Int(sourceRate)) Hz")
                return
            }
            let from = sourceRate
            // The FRESHEST window that holds ONE rate and has enough regular callbacks to decide on (dropouts, a bad cable: 0.25 s lost
            // every 0.5 s, leave only half of a window as usable intervals, so a thin short window gives way to a longer one). A window
            // that spans a rate change must never be averaged: the engine had already followed a silent switch to 24 kHz when the
            // recorder's report came in, the 3 s window then said 48 kHz (the older, more numerous callbacks) and the graph was switched
            // BACK to a rate it no longer had (scratch harness, review of 2026-10-10).
            var estimate: CaptureHAL.RateMeter.Estimate?       // stationary and >= 0.8 s of coverage: decides
            var thin: CaptureHAL.RateMeter.Estimate?           // stationary, but too little coverage to decide on
            for window in [tuning.rateConfirmSeconds, 1.5, 2.0, meter.retention] where window <= meter.retention {
                guard let e = meter.estimate(lastSeconds: window), e.stationary else { continue }
                if e.coverage >= 0.8 { estimate = e; break }
                if thin == nil || e.coverage > thin!.coverage { thin = e }
            }
            if estimate == nil, thin == nil, let mixed = meter.estimate(lastSeconds: meter.retention), mixed.coverage >= 0.3 {
                Log.info("\(label): the recorder reports periodic gap fills while the delivered rate is changing (the callbacks of the last "
                         + "\(String(format: "%.0f", meter.retention)) s do not agree on one rate); the continuous measurement decides, keeping \(Int(sourceRate)) Hz for now")
                return
            }
            if let e = estimate,
               let v = CaptureHAL.RateJudge.verdict(assumed: sourceRate, measured: e.rate, hints: hints) {
                if v.mismatch, switchRate(to: v.rate) {
                    onRateChange?(RateChange(from: from, to: v.rate, configured: configuredRate, measured: e.rate,
                                             how: v.how + "; re-measured on the recorder's request", initial: false))
                } else if !v.mismatch {
                    Log.info("\(label): the recorder's periodic gap fills do not come from a rate mismatch: the IOProc delivers "
                             + "\(Int(e.rate.rounded())) Hz as assumed (\(Int(sourceRate)) Hz): treating them as dropouts")
                }
                return
            }
            if let e = estimate ?? thin, e.coverage >= 0.3 {
                Log.info("\(label): the recorder reports periodic gap fills, but only \(String(format: "%.1f", e.coverage)) s of regular callbacks could be measured "
                         + "(\(Int(e.rate.rounded())) Hz): not conclusive, keeping \(Int(sourceRate)) Hz")
                onUnresolved?()
                return
            }
            // Nothing measurable at all (no callbacks cadence): the recorder's ratio of delivered to expected audio, if it is a standard rate.
            let implied = CaptureHAL.RateJudge.snap(sourceRate * deliveredRatio)
            if implied.standard, abs(implied.rate / sourceRate - 1) > CaptureHAL.RateJudge.sameRateTolerance, switchRate(to: implied.rate) {
                onRateChange?(RateChange(from: from, to: implied.rate, configured: configuredRate, measured: 0,
                                         how: "the recorder's delivered/expected ratio \(String(format: "%.2f", deliveredRatio)) points to \(Int(implied.rate)) Hz; "
                                         + "the delivered rate could not be measured", initial: false))
            } else {
                Log.info("\(label): the recorder's delivered/expected ratio \(String(format: "%.2f", deliveredRatio)) does not match a standard rate; "
                         + "not changing the source rate (\(Int(sourceRate)) Hz)")
                onUnresolved?()
            }
        }
    }

    /// Work queue. Swaps the resampler for one from `rate`; the old one's tail is delivered first (a live graph).
    @discardableResult
    private func switchRate(to rate: Double) -> Bool {
        guard rate > 0, abs(rate - sourceRate) > 0.5 else { return false }
        var newResampler: CaptureHAL.Resampler?
        if abs(rate - targetRate) > 0.5 {
            guard let r = CaptureHAL.Resampler(from: rate, to: targetRate) else {
                Log.warn("\(label): cannot create a \(Int(rate)) -> \(Int(targetRate)) Hz resampler; keeping \(Int(sourceRate)) Hz")
                return false
            }
            newResampler = r
        }
        if live, let old = resampler, let host = endHost {
            let tail = old.flush()
            if !tail.isEmpty { deliver(tail, host) }
        }
        resampler = newResampler
        sourceRate = rate
        pendingRate = nil
        if live { liveSwitches += 1 }
        lock.lock(); rateNow = rate; lock.unlock()
        return true
    }

    /// Work queue only (HALCapture.teardown calls it through workQueue.sync): releases audio that is still held back for the
    /// verification, then delivers the resampler's end-of-stream tail, stamped with the host time at which the last
    /// delivered buffer ended.
    func finish() {
        guard active else { return }
        if !live { decideInitial(now: heldSince, final: true) }
        guard let r = resampler, let host = endHost else { return }
        let tail = r.flush()
        guard !tail.isEmpty else { return }
        deliver(tail, host)
    }
}
