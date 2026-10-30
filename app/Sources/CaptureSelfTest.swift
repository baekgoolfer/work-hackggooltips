import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

// =====================================================================================
// CaptureSelfTest: `selftest-capture` (SPEC 6 / 12.1).
//
//   runSelftestCapture(config:seconds:outDir:)             SPEC signature. Synthetic if MC_SELFTEST_SYNTHETIC=1,
//                                                          otherwise LIVE, and live FAILS CLOSED (returns 2 before
//                                                          touching any device) unless MC_SELFTEST_LIVE=1 AND the signed
//                                                          app was started by launchd / LaunchServices
//                                                          (LaunchGuard.isSignedAppLaunch: bundle id AND parent, so the
//                                                          in-bundle binary exec'd from a shell is refused). The shell's
//                                                          main.swift maps --synthetic / --live onto those variables.
//   runSelftestCapture(config:seconds:outDir:synthetic:)   explicit switch; the same live guard applies.
//
// SYNTHETIC mode needs no permission and touches no audio device: it exercises WavWriter, the buffer mixdown,
// the resampler, the HALCapture engine (fake backend), Recorder (timeline, gap filling, session.json, levels,
// watchdog plumbing) with generated sine/noise sources, a simulated device change (gap + rate conversion), a
// simulated crash, the permission-probe logic and the fail-closed guards. The sample-rate fix (AirPods, 2026-10-10) has its
// own groups: RateMeter / RateJudge, GapPatternDetector, the tap host policy by transport type, the engine's delivered-rate
// verification, and end-to-end scenarios (a fake HAL device delivering a 1 kHz tone at an effective 24 / 16 / 44.1 kHz while
// its format says 48 kHz, mid-session switches, the control that reproduces the defect).
//
// The microphone mute gate has three groups: the state machine on a virtual clock with fake
// signals (delay line, backdate, release debounce, unknown = record, gaps, a random-script property test), the signal sources (manual,
// polled, the call app's input over a fake process list, the device's mute properties over a fake HAL), and real Recorders with synthetic
// sources running at once: the BUILT-IN MUTE SCRIPT (spans in seconds of mic.wav; MC_SELFTEST_MUTE_SCRIPT="1.6-3.0,4.4-5.2" replaces it)
// must come out as exact zeros in mic.wav with the file length and start_offset_sec unchanged against a control without the gate, with
// the aggregate in session.json (`mic_gate`) and the spans in the private sidecar; plus the manual pause, the meter before the gate, a gate
// that never hears a signal, a crash (the last 0.5 s of the microphone is lost) and a gap fill.
//
// LIVE mode records `seconds` from the real tap + microphone and plays a short `say` phrase through the
// speakers after ~1.5 s, so the remote track must contain speech. It prints a JSON report with a PASS/FAIL
// verdict. It shows permission prompts, so it only runs from the signed app (<short name>.app), started through
// LaunchServices (-n is required, see CapturePermissionGuard.openAppPrefix):
//   open -n -W -a ~/Applications/<short name>.app --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live ...
// =====================================================================================

func runSelftestCapture(config: AppConfig, seconds: Int, outDir: URL) -> Int32 {
    let synthetic = ProcessInfo.processInfo.environment["MC_SELFTEST_SYNTHETIC"] == "1"
    return runSelftestCapture(config: config, seconds: seconds, outDir: outDir, synthetic: synthetic)
}

/// Returns 0 / 1 = PASS / FAIL, 2 = live mode refused (nothing was touched).
func runSelftestCapture(config: AppConfig, seconds: Int, outDir: URL, synthetic: Bool) -> Int32 {
    let code = synthetic
        ? CaptureSelfTest.runSynthetic(config: config, outDir: outDir)
        : CaptureSelfTest.runLive(config: config, seconds: seconds, outDir: outDir)    // refuses (2) unless allowed, see runLive
    Log.flush()
    return code
}

// MARK: - Synthetic source

/// Generates a sine (+ optional noise) in real time with host timestamps, optionally at a different native rate
/// (converted through the real Resampler) and with simulated stalls (a device change: nothing is delivered for a
/// while, then delivery resumes with the true host time).
final class SyntheticCaptureSource: CaptureTrackSource {
    struct Stall { var start: Double; var duration: Double }   // seconds after start()

    let sampleRate: Double
    let sourceLabel: String
    var deviceName: String
    var onSamples: (([Float], UInt64) -> Void)?
    var onWarning: ((String) -> Void)?
    var onDeviceChange: ((String) -> Void)?

    private let nativeRate: Double
    private let frequency: Double
    private let amplitude: Float
    private let noiseAmplitude: Float
    private let startDelay: Double
    private let silentUntil: Double                     // seconds after start(): exact zeros before this (a muted tap)
    private let stalls: [Stall]
    private let deviceAfterStall: String?
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).synthetic")
    private var timer: DispatchSourceTimer?
    private var startSec = 0.0
    private var generated = 0
    private var phase = 0.0
    private var resampler: CaptureHAL.Resampler?
    private var stallsAnnounced = Set<Int>()

    init(label: String, device: String, sampleRate: Double, nativeRate: Double, frequency: Double,
         amplitude: Float, noise: Float = 0, startDelay: Double = 0, silentUntil: Double = 0,
         stalls: [Stall] = [], deviceAfterStall: String? = nil) {
        self.sourceLabel = label
        self.deviceName = device
        self.sampleRate = sampleRate
        self.nativeRate = nativeRate
        self.frequency = frequency
        self.amplitude = amplitude
        self.noiseAmplitude = noise
        self.startDelay = startDelay
        self.silentUntil = silentUntil
        self.stalls = stalls
        self.deviceAfterStall = deviceAfterStall
    }

    func start() throws {
        if abs(nativeRate - sampleRate) > 0.5 {
            guard let r = CaptureHAL.Resampler(from: nativeRate, to: sampleRate) else {
                throw RecorderError.failed("synthetic resampler unavailable")
            }
            resampler = r
        }
        startSec = CaptureHAL.Clock.seconds(CaptureHAL.Clock.now())
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.02, repeating: 0.02, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    private func tick() {
        let elapsed = CaptureHAL.Clock.seconds(CaptureHAL.Clock.now()) - startSec
        guard elapsed >= startDelay else { return }
        let live = elapsed - startDelay
        for (i, s) in stalls.enumerated() where elapsed >= s.start && elapsed < s.start + s.duration {
            generated = Int(live * nativeRate)            // the "device" is away: skip real time, deliver nothing
            stallsAnnounced.insert(i)
            return
        }
        for i in stallsAnnounced.sorted() {
            stallsAnnounced.remove(i)
            if let d = deviceAfterStall { deviceName = d; onDeviceChange?(d) }
        }
        let target = Int(live * nativeRate)
        let n = target - generated
        guard n > 0 else { return }
        let firstSec = startSec + startDelay + Double(generated) / nativeRate
        var native = [Float](repeating: 0, count: n)
        let step = 2 * Double.pi * frequency / nativeRate
        let audible = elapsed >= silentUntil
        for i in 0..<n {
            var v = audible ? amplitude * Float(sin(phase)) : 0
            if audible && noiseAmplitude > 0 { v += noiseAmplitude * Float.random(in: -1...1) }
            native[i] = v
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        generated = target
        let out = resampler?.process(native) ?? native
        guard !out.isEmpty else { return }
        onSamples?(out, CaptureHAL.Clock.ticks(seconds: firstSec))
    }
}

// MARK: - Mute gate support

/// The mute script of the synthetic run (`selftest-capture --synthetic`): when the scripted signal says 'muted', in seconds after the first frame
/// the microphone delivered. `MC_SELFTEST_MUTE_SCRIPT="1.6-3.0,4.4-5.2"` replaces the built-in one (main.swift is not involved: the variable
/// is read here). A usable script has spans in order, each at least 0.5 s after the one before (so every span is a span of its own, not a
/// merge through the 0.2 s release debounce) and ends within 60 s.
enum MuteScript {
    typealias Span = (from: Double, to: Double)
    static let environmentKey = "MC_SELFTEST_MUTE_SCRIPT"
    static let builtIn: [Span] = [(1.6, 3.0), (4.4, 5.2)]
    static let minimumGap = 0.5
    static let maximumEnd = 60.0

    /// nil = not usable (the caller falls back to the built-in script and says so).
    static func parse(_ text: String) -> [Span]? {
        var spans: [Span] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2, let from = Double(pieces[0]), let to = Double(pieces[1]),
                  from.isFinite, to.isFinite, from >= 0, to > from, to <= maximumEnd else { return nil }
            if let last = spans.last, from - last.to < minimumGap { return nil }
            spans.append((from, to))
        }
        return spans.isEmpty ? nil : spans
    }

    static func effective(environment: [String: String] = ProcessInfo.processInfo.environment) -> (spans: [Span], note: String) {
        guard let text = environment[environmentKey], !text.isEmpty else { return (builtIn, "built-in script") }
        if let spans = parse(text) { return (spans, "\(environmentKey)=\(text)") }
        return (builtIn, "\(environmentKey)=\(text.prefix(40)) is not a usable script (spans a-b in seconds, in order, 0.5 s apart, ending within 60 s): built-in script")
    }
}

/// Says muted inside the script's spans and unmuted outside (so it counts as an answer from the first chunk on). The time is the microphone
/// track's own: the origin is the host time of the first frame the microphone delivered (ObservedSource anchors it before the recorder sees
/// the frame), so the spans are seconds of mic.wav.
private final class ScriptedMuteSignal: MuteSignalSource {
    let name = "scripted"
    private let spans: [MuteScript.Span]
    private let lock = NSLock()
    private var origin: UInt64?

    init(spans: [MuteScript.Span]) { self.spans = spans }

    func anchor(at host: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if origin == nil { origin = host }
    }

    func read(at host: UInt64) -> MuteReading {
        lock.lock(); let o = origin; lock.unlock()
        guard let origin = o else { return .unmuted }
        let t = CaptureHAL.Clock.seconds(host) - CaptureHAL.Clock.seconds(origin)
        return spans.contains { t >= $0.from && t < $0.to } ? .muted : .unmuted
    }
}

/// Forwards a capture source and remembers what it delivered: the frames (so the length of a file can be compared with them exactly) and
/// the host time of the first one.
private final class ObservedSource: CaptureTrackSource {
    let inner: CaptureTrackSource
    private let lock = NSLock()
    private var firstHostTime: UInt64?
    private var deliveredFrames = 0
    private var downstream: (([Float], UInt64) -> Void)?
    private let onFirst: ((UInt64) -> Void)?

    init(_ inner: CaptureTrackSource, onFirst: ((UInt64) -> Void)? = nil) {
        self.inner = inner
        self.onFirst = onFirst
    }

    var sampleRate: Double { inner.sampleRate }
    var sourceLabel: String { inner.sourceLabel }
    var deviceName: String { inner.deviceName }
    var onWarning: ((String) -> Void)? { get { inner.onWarning } set { inner.onWarning = newValue } }
    var onDeviceChange: ((String) -> Void)? { get { inner.onDeviceChange } set { inner.onDeviceChange = newValue } }
    var onSamples: (([Float], UInt64) -> Void)? {
        get { downstream }
        set {
            downstream = newValue
            inner.onSamples = { [weak self] samples, host in self?.deliver(samples, host) }
        }
    }
    func start() throws { try inner.start() }
    func stop() { inner.stop() }

    var frames: Int { lock.lock(); defer { lock.unlock() }; return deliveredFrames }
    var firstHost: UInt64? { lock.lock(); defer { lock.unlock() }; return firstHostTime }

    private func deliver(_ samples: [Float], _ host: UInt64) {
        lock.lock()
        let first = firstHostTime == nil
        if first { firstHostTime = host }
        deliveredFrames += samples.count
        lock.unlock()
        if first { onFirst?(host) }                 // before the recorder sees the frame: the script's origin is set when the first chunk is read
        downstream?(samples, host)
    }
}

// MARK: Virtual-clock rig for the gate's state machine

/// Never 0, exact in Float: the expected value of frame `i`, so a zeroed frame cannot be mistaken for audio and a shifted one is found.
private func gateRamp(_ i: Int) -> Float { Float(i % 997 + 1) / 1024 }

/// A signal that follows a script of host time: muted in the spans, `otherwise` outside them, `after` from a time on (a source that stops
/// answering). Host time is turned into seconds since the rig's base and rounded to a millisecond (host ticks are not exact).
private struct ScriptSignal: MuteSignalSource {
    let name: String
    var spans: [(Double, Double)] = []
    var otherwise: MuteReading = .unmuted
    var after: (time: Double, reading: MuteReading)? = nil
    var roundsToMillisecond = true               // the random script cuts at arbitrary instants: no rounding there

    func read(at host: UInt64) -> MuteReading {
        let raw = CaptureHAL.Clock.seconds(host) - CaptureHAL.Clock.seconds(GateRig.base)
        let t = roundsToMillisecond ? (raw * 1000).rounded() / 1000 : raw
        if spans.contains(where: { t >= $0.0 && t < $0.1 }) { return .muted }
        if let a = after, t >= a.time { return a.reading }
        return otherwise
    }
}

/// Remembers the host times it is asked about.
private final class SpySignal: MuteSignalSource {
    let name = "spy"
    private(set) var asked: [UInt64] = []
    func read(at host: UInt64) -> MuteReading { asked.append(host); return .unknown }
}

/// Feeds a MuteGate chunk by chunk on a virtual clock (the host time of a chunk is its position on the timeline) and keeps what comes out.
private final class GateRig {
    static let rate = 48_000
    static let base: UInt64 = 5_000_000_000
    let gate: MuteGate
    private(set) var position = 0                   // frames of the timeline so far: audio and gap fills
    private(set) var out: [Float] = []
    private(set) var maxHeld = 0

    init(config: MuteGateConfig = MuteGateConfig(enabled: true), signals: [MuteSignalSource]) {
        gate = MuteGate(config: config, signals: signals)
    }

    static func frames(_ seconds: Double) -> Int { Int((seconds * Double(rate)).rounded()) }
    static func host(_ frame: Int) -> UInt64 { base &+ CaptureHAL.Clock.ticks(seconds: Double(frame) / Double(rate)) }

    func feed(seconds: Double, chunk: Double = 0.02) { feed(frames: Self.frames(seconds), chunkFrames: max(1, Self.frames(chunk))) }

    func feed(frames: Int, chunkFrames: Int) {
        var left = frames
        while left > 0 {
            let k = min(chunkFrames, left)
            let samples = (0..<k).map { gateRamp(position + $0) }
            out += gate.filter(samples, hostTime: Self.host(position))
            position += k
            left -= k
            maxHeld = max(maxHeld, gate.heldFrames)
        }
    }

    /// What the recorder does for a gap: the line's content first, then the silence, then the timeline goes on.
    func gap(frames: Int) {
        out += gate.flushForGap(skipping: frames)
        out += [Float](repeating: 0, count: frames)
        position += frames
    }

    func finish() { out += gate.finish() }

    /// Every frame of [from, to) seconds is exactly 0.
    func isZero(_ from: Double, _ to: Double) -> Bool {
        let a = Self.frames(from), b = min(Self.frames(to), out.count)
        return a < b && out[a..<b].allSatisfy { $0 == 0 }
    }

    /// Every frame of [from, to) seconds is the audio that went in (no gap fill in between).
    func isIntact(_ from: Double, _ to: Double) -> Bool {
        let a = Self.frames(from), b = min(Self.frames(to), out.count)
        guard a < b else { return false }
        for i in a..<b where out[i] != gateRamp(i) { return false }
        return true
    }

    var zeroFrames: Int { out.reduce(0) { $0 + ($1 == 0 ? 1 : 0) } }
}

// MARK: - Test harness

private final class Checker {
    var passes = 0
    var failures: [String] = []

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        let d = detail()
        if ok {
            passes += 1
            print("  PASS  \(name)" + (d.isEmpty ? "" : "   [\(d)]"))
        } else {
            failures.append(name)
            print("  FAIL  \(name)" + (d.isEmpty ? "" : "   [\(d)]"))
        }
    }
}

enum CaptureSelfTest {
    // MARK: helpers

    static func readSamples(_ url: URL) -> (samples: [Float], info: WavFileInfo)? {
        guard let info = WavFileInfo.read(url), info.channels == 1, info.bitsPerSample == 16,
              let data = try? Data(contentsOf: url), data.count >= info.dataOffset else { return nil }
        let bytes = data.count - info.dataOffset
        let count = bytes / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = Float(raw.loadUnaligned(fromByteOffset: info.dataOffset + i * 2, as: Int16.self).littleEndian) / 32768
            }
        }
        return (out, info)
    }

    static func rmsDB(_ s: ArraySlice<Float>) -> Double {
        guard !s.isEmpty else { return -120 }
        var sum = 0.0
        for x in s { sum += Double(x) * Double(x) }
        let rms = (sum / Double(s.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }

    /// Loudest 100 ms window RMS (a short spoken phrase inside a long silent file).
    static func peakWindowDB(_ s: [Float], rate: Int) -> Double {
        let w = max(1, rate / 10)
        var best = -120.0
        var i = 0
        while i + w <= s.count {
            best = max(best, rmsDB(s[i..<i + w]))
            i += w
        }
        return best
    }

    static func sine(_ freq: Double, rate: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { amp * Float(sin(2 * Double.pi * freq * Double($0) / rate)) }
    }

    static func upwardZeroCrossings(_ s: ArraySlice<Float>) -> Int {
        var count = 0
        var prev: Float = 0
        var first = true
        for x in s {
            if !first && prev < 0 && x >= 0 { count += 1 }
            prev = x
            first = false
        }
        return count
    }

    static func isoHasOffset(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2}|Z)$"#, options: .regularExpression) != nil
    }

    // MARK: synthetic suite

    static func runSynthetic(config: AppConfig, outDir: URL) -> Int32 {
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let c = Checker()
        print("== capture self-test (synthetic, no devices, no permissions) ==")
        print("output: \(outDir.path)")
        testEnvironmentReadOnly(c, config: config)
        testWavWriter(c, dir: outDir)
        testCrashRecoveryWriter(c, dir: outDir)
        testWavRobustness(c, dir: outDir)
        testResampler(c)
        testMixer(c)
        testPermissionPrecheck(c)
        testPermissionGuards(c, config: config, dir: outDir)
        testProbeLogic(c)
        testEngineLogic(c)
        testResamplerTail(c)
        testEngineHooks(c)
        testTapHostStrategy(c)
        testRateMeter(c)
        testRateJudge(c)
        testGapPatternDetector(c)
        testBluetoothHostPolicy(c)
        testRateHold(c)
        testRateRobustness(c)
        testRecorder(c, config: config, dir: outDir)
        testRateMismatchScenarios(c, config: config, dir: outDir)
        testRecorderCrash(c, config: config, dir: outDir)
        testStartFailure(c, config: config, dir: outDir)
        testRemoteSilenceRule(c)
        testRemoteSilenceRecorders(c, config: config, dir: outDir)
        testMuteGateMachine(c)
        testMuteSignals(c)
        testMuteGateRecorders(c, config: config, dir: outDir)
        print("== result: \(c.passes) passed, \(c.failures.count) failed ==")
        if !c.failures.isEmpty { print("FAILED: " + c.failures.joined(separator: "; ")) }
        return c.failures.isEmpty ? 0 : 1
    }

    // Read-only: process list, default devices, pattern matching. No tap, no mic, no prompt.
    private static func testEnvironmentReadOnly(_ c: Checker, config: AppConfig) {
        print("-- environment (read-only queries)")
        let out = CaptureHAL.defaultDevice(input: false)
        let inp = CaptureHAL.defaultDevice(input: true)
        print("  default output: \(out.flatMap { CaptureHAL.deviceName($0) } ?? "none") @ \(out.flatMap { CaptureHAL.nominalRate($0) }.map { String(Int($0)) } ?? "?") Hz")
        print("  default input : \(inp.flatMap { CaptureHAL.deviceName($0) } ?? "none") @ \(inp.flatMap { CaptureHAL.nominalRate($0) }.map { String(Int($0)) } ?? "?") Hz")
        let procs = SystemAudioTap.listProcesses()
        print("  audio process objects: \(procs.count), running output: \(procs.filter { $0.runningOutput }.count)")
        print("  own process object: \(SystemAudioTap.ownProcessObject().map(String.init) ?? "none (not registered with the audio system yet)")")
        print("  leaked aggregate devices with our prefix visible: \(CaptureHAL.allDevices().filter { (CaptureHAL.deviceUID($0) ?? "").hasPrefix(SystemAudioTap.aggregateUIDPrefix) }.count)")

        c.check("bundle id prefix match: chrome helper", SystemAudioTap.matches("com.google.Chrome.helper.Renderer", ["com.google.Chrome"]))
        c.check("bundle id prefix match: zoom", SystemAudioTap.matches("us.zoom.xos", ["us.zoom."]))
        c.check("bundle id prefix match: teams2", SystemAudioTap.matches("com.microsoft.teams2.helper", ["com.microsoft.teams"]))
        c.check("bundle id prefix no-match: safari / empty", !SystemAudioTap.matches("com.apple.Safari", ["com.google.Chrome"]) && !SystemAudioTap.matches("", ["x"]))
        let zoomSignal = PlatformSignal(platform: .zoom, inCall: true)
        let manualSignal = PlatformSignal(platform: .manual, inCall: true)
        c.check("family prefixes per platform",
                SystemAudioTap.familyPrefixes(signal: zoomSignal, config: config).contains("us.zoom.")
                && SystemAudioTap.familyPrefixes(signal: PlatformSignal(platform: .meet, inCall: true), config: config) == config.browserBundleIDs
                && SystemAudioTap.familyPrefixes(signal: manualSignal, config: config).isEmpty)
    }

    private static func testWavWriter(_ c: Checker, dir: URL) {
        print("-- WavWriter basic")
        let url = dir.appendingPathComponent("t1_basic.wav")
        guard let w = try? WavWriter(url: url, sampleRate: 48000) else { c.check("create writer", false); return }
        w.appendSamples(sine(440, rate: 48000, seconds: 1.0))                                 // Float path
        w.appendSilence(frames: 24000)                                                        // 0.5 s silence
        w.appendSamples((0..<48000).map { Int16(truncatingIfNeeded: ($0 % 200) * 100 - 10000) }) // Int16 path
        c.check("framesWritten counts accepted frames", w.framesWritten == 120_000, "\(w.framesWritten)")
        let closed = w.close()
        w.appendSamples([1, 2, 3] as [Int16])                                                 // ignored after close
        _ = w.close()                                                                         // idempotent
        c.check("close() returns total frames and later appends are ignored", closed == 120_000 && w.framesWritten == 120_000)
        let info = WavFileInfo.read(url)
        c.check("header consistent after close", info?.headerIsConsistent == true && info?.frames == 120_000,
                "frames=\(info?.frames ?? -1) header=\(info?.headerDataBytes ?? 0) actual=\(info?.actualDataBytes ?? 0)")
        c.check("format 48000 Hz mono 16-bit", info?.sampleRate == 48000 && info?.channels == 1 && info?.bitsPerSample == 16)
        if let (s, _) = readSamples(url) {
            let sinePeak = s[0..<48000].map { abs($0) }.max() ?? 0
            let silent = s[48000..<72000].allSatisfy { $0 == 0 }
            c.check("content: sine, exact silence, int16 ramp", sinePeak > 0.49 && sinePeak < 0.51 && silent && s.count == 120_000,
                    "peak=\(sinePeak) silent=\(silent)")
        } else {
            c.check("read back samples", false)
        }
        // float clipping / NaN safety
        let u2 = dir.appendingPathComponent("t1_clip.wav")
        if let w2 = try? WavWriter(url: u2, sampleRate: 16000) {
            w2.appendSamples([2.0, -2.0, Float.nan, 0.5] as [Float])
            w2.close()
            let s2 = readSamples(u2)?.samples ?? []
            c.check("float clipping and NaN to 0", s2.count == 4 && s2[0] > 0.999 && s2[1] < -0.999 && s2[2] == 0 && abs(s2[3] - 0.5) < 0.001, "\(s2)")
        }
    }

    private static func testCrashRecoveryWriter(_ c: Checker, dir: URL) {
        print("-- WavWriter crash recovery (header never finalized)")
        let url = dir.appendingPathComponent("t2_crash.wav")
        guard let w = try? WavWriter(url: url, sampleRate: 48000) else { c.check("create writer", false); return }
        let chunk = sine(300, rate: 48000, seconds: 0.1)
        for _ in 0..<30 { w.appendSamples(chunk) }                                            // 3.0 s
        w.abandonWithoutFinalizing()
        let before = WavFileInfo.read(url)
        c.check("stale header after crash (header says 0 bytes)", before?.headerDataBytes == 0 && before?.headerIsConsistent == false,
                "header=\(before?.headerDataBytes ?? 99) actual=\(before?.actualDataBytes ?? 0)")
        c.check("lenient parse recovers the true length", before?.frames == 144_000, "frames=\(before?.frames ?? -1) seconds=\(before?.seconds ?? -1)")
        // torn final sample: append one stray byte, as a killed process could leave
        if let fh = try? FileHandle(forWritingTo: url) {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Data([0x7F]))
            try? fh.close()
        }
        let torn = WavFileInfo.read(url)
        c.check("torn odd byte is ignored by frame count", torn?.frames == 144_000, "frames=\(torn?.frames ?? -1)")
        c.check("repairHeader fixes the file", WavWriter.repairHeader(at: url))
        let after = WavFileInfo.read(url)
        c.check("header consistent after repair", after?.headerIsConsistent == true && after?.frames == 144_000,
                "frames=\(after?.frames ?? -1) header=\(after?.headerDataBytes ?? 0)")
    }

    /// Corrupt headers must never crash the app (crash recovery runs unattended at launch); descriptors must not leak
    /// into child processes (the Python pipeline of the previous meeting runs while the next one records).
    private static func testWavRobustness(_ c: Checker, dir: URL) {
        print("-- WavWriter robustness (corrupt sample rate, O_CLOEXEC)")
        let url = dir.appendingPathComponent("t3_robust.wav")
        guard let w = try? WavWriter(url: url, sampleRate: 48000) else { c.check("create writer", false); return }
        w.appendSamples(sine(440, rate: 48000, seconds: 0.2))

        // O_CLOEXEC: every descriptor this process has open on the file is close-on-exec, and a child does not see it.
        var fdsOnFile: [Int32] = []
        var cloexecOnAll = true
        for fd in 3..<1024 {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(Int32(fd), F_GETPATH, &buf) == 0, String(cString: buf).hasSuffix("/t3_robust.wav") else { continue }
            fdsOnFile.append(Int32(fd))
            if fcntl(Int32(fd), F_GETFD) & FD_CLOEXEC == 0 { cloexecOnAll = false }
        }
        c.check("WAV descriptor is close-on-exec (FD_CLOEXEC)", !fdsOnFile.isEmpty && cloexecOnAll, "fds=\(fdsOnFile)")
        if let fd = fdsOnFile.first {
            // A raw posix_spawn child inherits every descriptor that is not close-on-exec (Foundation's Process happens to
            // close them itself, but other spawn paths do not).
            var pid: pid_t = 0
            let words: [String] = ["sh", "-c", "[ -e /dev/fd/\(fd) ]"]
            var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
            argv.append(nil)
            defer { argv.forEach { free($0) } }
            var status: Int32 = -1
            if posix_spawn(&pid, "/bin/sh", nil, nil, argv, environ) == 0 {
                var raw: Int32 = 0
                waitpid(pid, &raw, 0)
                status = (raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : -3         // exit status, or -3 if killed by a signal
            }
            c.check("a spawned child process does not inherit the WAV descriptor", status == 1, "fd \(fd) in child: exit status \(status) (0 = still open, 1 = closed)")
        }
        w.close()

        // makeHeader never traps, whatever the rate field says.
        for rate in [Int.max, Int.min, -1, 0, Int(UInt32.max), 3_655_000_000, 48000] {
            _ = WavWriter.makeHeader(sampleRate: rate, dataBytes: UInt64.max)
        }
        c.check("makeHeader clamps instead of trapping (Int.max, negative, > UInt32 rates)",
                WavWriter.makeHeader(sampleRate: Int.max, dataBytes: 0).count == WavWriter.headerSize
                && WavWriter.makeHeader(sampleRate: -1, dataBytes: 0).count == WavWriter.headerSize)

        // repairHeader on a file whose sample-rate field is corrupt: false, file untouched, no trap.
        func patchedCopy(rate: UInt32, name: String) -> URL? {
            let copy = dir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: copy)
            guard var bytes = (try? Data(contentsOf: url)).map({ [UInt8]($0) }), bytes.count > 44 else { return nil }
            for i in 0..<4 { bytes[24 + i] = UInt8((rate >> UInt32(8 * i)) & 0xFF) }   // fmt: sample rate
            bytes[40] = 0; bytes[41] = 0; bytes[42] = 0; bytes[43] = 0                   // data size 0: looks like a crashed file
            do { try Data(bytes).write(to: copy) } catch { return nil }
            return copy
        }
        for rate: UInt32 in [0xD9E5_BB80, 0xFFFF_FFFF, 0, 7999, 192_001] {
            guard let copy = patchedCopy(rate: rate, name: "t3_badrate_\(rate).wav") else { c.check("patch copy", false); continue }
            let before = try? Data(contentsOf: copy)
            let repaired = WavWriter.repairHeader(at: copy)
            c.check("repairHeader rejects sample rate \(rate) without trapping and leaves the file alone",
                    !repaired && (try? Data(contentsOf: copy)) == before)
        }
        if let ok = patchedCopy(rate: 44100, name: "t3_goodrate.wav") {
            c.check("repairHeader still repairs a plausible rate (44100)", WavWriter.repairHeader(at: ok) && WavFileInfo.read(ok)?.headerIsConsistent == true)
        }
    }

    /// The fail-closed rules for anything that can pop a macOS permission dialog. The input is the verdict of
    /// `LaunchGuard.isSignedAppLaunch` (bundle id AND started by launchd / LaunchServices), fed as a Bool so both answers
    /// can be tested without a device. A "non-launchd exec" is exactly the verdict `false`, whatever the bundle id says.
    private static func testPermissionGuards(_ c: Checker, config: AppConfig, dir: URL) {
        print("-- permission-prompt guards (fail closed unless the signed app was started by launchd / LaunchServices)")
        let any = CapturePermissionGuard.allowAnyEnv, live = CapturePermissionGuard.liveSelfTestEnv
        let shellLaunch = "bundle id \(AppInfo.bundleID), parent pid 4242, __CFBundleIdentifier com.apple.Terminal"
        let hint = CapturePermissionGuard.openAppPrefix

        // 1. the decision functions
        let promptShell = CapturePermissionGuard.promptRefusal(signedAppLaunch: false, env: [:], launch: shellLaunch)
        c.check("prompts refused for a non-launchd exec (in-bundle binary run from a shell: right bundle id, wrong parent)",
                promptShell?.hasPrefix("error: refused") == true && promptShell?.contains("parent pid 4242") == true, promptShell ?? "allowed")
        c.check("prompt refusal tells how to run the app: open -n -W -a ... --args setup",
                promptShell?.contains(hint + " setup") == true, promptShell ?? "")
        c.check("prompts allowed for a launchd / LaunchServices start of the signed app", CapturePermissionGuard.promptRefusal(signedAppLaunch: true, env: [:]) == nil)
        c.check("prompts: MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY=1 is the only override (0 / true are not)",
                CapturePermissionGuard.promptRefusal(signedAppLaunch: false, env: [any: "1"]) == nil
                && CapturePermissionGuard.promptRefusal(signedAppLaunch: false, env: [any: "0"]) != nil
                && CapturePermissionGuard.promptRefusal(signedAppLaunch: false, env: [any: "true"]) != nil)
        c.check("live self-test refused with neither the env variable nor a signed-app launch",
                CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: false, env: [:], launch: shellLaunch) != nil)
        c.check("live self-test refused from the signed app without MC_SELFTEST_LIVE=1",
                CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: true, env: [:]) != nil)
        c.check("live self-test refused for a non-launchd exec even with MC_SELFTEST_LIVE=1 (and with the prompt override)",
                CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: false, env: [live: "1"]) != nil
                && CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: false, env: [live: "1", any: "1"]) != nil)
        c.check("live self-test allowed only for a signed-app launch WITH MC_SELFTEST_LIVE=1",
                CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: true, env: [live: "1"]) == nil)
        let msg = CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: false, env: [:], launch: shellLaunch) ?? ""
        c.check("live refusal text names the open -n -W -a command, --live and --synthetic",
                msg.contains(hint + " selftest-capture --live") && msg.contains("--synthetic") && !msg.contains("open -W -a"), msg)
        c.check("open command helper: -n present, stdout/stderr to the tty",
                CapturePermissionGuard.openAppCommand("setup") == hint + " setup" && hint.contains(" -n "))
        let desc = CapturePermissionGuard.launchDescription(bundleID: nil, parentPID: 1, env: [:])
        c.check("launch description is readable for a bare binary", desc == "bundle id none, parent pid 1, __CFBundleIdentifier unset", desc)

        // 2. requestCapturePermissions: the closures that could show a dialog never run when refused
        var called = 0
        let refused = requestCapturePermissions(signedAppLaunch: false, env: [:],
                                                microphone: { called += 1; return "authorized" }, systemAudio: { called += 1; return "ok" })
        c.check("requestCapturePermissions refuses a non-launchd exec: neither prompt-capable step ran, both entries 'error: refused'",
                called == 0 && refused.count == 2 && (refused["microphone"] ?? "").hasPrefix("error: refused") && (refused["system_audio"] ?? "").hasPrefix("error: refused"),
                "called=\(called) \(refused.mapValues { String($0.prefix(40)) })")
        let granted = requestCapturePermissions(signedAppLaunch: true, env: [:],
                                                microphone: { called += 1; return "authorized" }, systemAudio: { called += 1; return "ok" })
        c.check("requestCapturePermissions for a launchd start runs both steps and passes their status through",
                called == 2 && granted["microphone"] == "authorized" && granted["system_audio"] == "ok", "called=\(called) \(granted)")
        let overridden = requestCapturePermissions(signedAppLaunch: false, env: [any: "1"],
                                                   microphone: { called += 1; return "authorized" }, systemAudio: { called += 1; return "ok" })
        c.check("requestCapturePermissions with the explicit override runs the steps", called == 4 && overridden["microphone"] == "authorized")

        // 3. runLive: refuses before anything is created, whatever the bundle id says
        let neverCreated = dir.appendingPathComponent("never_created_live_seam")
        try? FileManager.default.removeItem(at: neverCreated)
        let exec1 = runLive(config: config, seconds: 6, outDir: neverCreated, signedAppLaunch: false, env: [live: "1"])
        c.check("runLive(non-launchd exec, MC_SELFTEST_LIVE=1) returns 2 and creates nothing",
                exec1 == 2 && !FileManager.default.fileExists(atPath: neverCreated.path), "exit \(exec1)")
        let exec2 = runLive(config: config, seconds: 6, outDir: neverCreated, signedAppLaunch: true, env: [:])
        c.check("runLive(signed app without MC_SELFTEST_LIVE=1) returns 2 and creates nothing",
                exec2 == 2 && !FileManager.default.fileExists(atPath: neverCreated.path), "exit \(exec2)")

        // 4. the real entry points, only if THIS process would be refused (never exercised when they could prompt or go live)
        let env = ProcessInfo.processInfo.environment
        let verdict = LaunchGuard.isSignedAppLaunch
        print("  info  LaunchGuard.isSignedAppLaunch in this process: \(verdict) (\(CapturePermissionGuard.launchDescription()))")
        if CapturePermissionGuard.promptRefusal(signedAppLaunch: verdict, env: env) != nil {
            let r = requestCapturePermissions()
            c.check("requestCapturePermissions() refuses here: both entries 'error: refused', nothing touched",
                    r.count == 2 && (r["microphone"] ?? "").hasPrefix("error: refused") && (r["system_audio"] ?? "").hasPrefix("error: refused"), "\(r.mapValues { String($0.prefix(40)) })")
        } else {
            print("  SKIP  requestCapturePermissions() refusal (this process is allowed to prompt)")
        }
        if CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: verdict, env: env) != nil {
            let code = runSelftestCapture(config: config, seconds: 6, outDir: dir.appendingPathComponent("never_created_live"), synthetic: false)
            c.check("runSelftestCapture(live) returns 2 here without creating anything",
                    code == 2 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("never_created_live").path), "exit \(code)")
        } else {
            print("  SKIP  live refusal (this process is the signed app started by LaunchServices with MC_SELFTEST_LIVE=1)")
        }
    }

    /// The permission probe must not report success for a tap that only delivers zeros.
    private static func testProbeLogic(_ c: Checker) {
        print("-- permission probe logic (synthetic sources, content-based)")
        func source(amp: Float, silentUntil: Double = 0, delay: Double = 0) -> SyntheticCaptureSource {
            SyntheticCaptureSource(label: "global-tap", device: "Synthetic", sampleRate: 48000, nativeRate: 48000, frequency: 440,
                                   amplitude: amp, startDelay: delay, silentUntil: silentUntil)
        }
        let audible = SystemAudioTap.probe(source: source(amp: 0.2), window: 3, sound: nil)
        c.check("probe: audible samples => exactly \"ok\"", audible == "ok", audible)

        let t0 = ProcessInfo.processInfo.systemUptime
        let silent = SystemAudioTap.probe(source: source(amp: 0), window: 0.8, sound: nil)
        let waited = ProcessInfo.processInfo.systemUptime - t0
        c.check("probe: callbacks of exact zeros (permission pending/denied) => error, waits the whole window",
                silent.hasPrefix("error") && silent.contains("only digital silence") && silent.contains("click Allow") && waited >= 0.75, "\(silent) after \(waited) s")

        let late = SystemAudioTap.probe(source: source(amp: 0.2, silentUntil: 0.7), window: 3, sound: nil)
        c.check("probe: user clicks Allow late (silence, then audio inside the window) => ok", late == "ok", late)

        let none = SystemAudioTap.probe(source: source(amp: 0.2, delay: 10), window: 0.5, sound: nil)
        c.check("probe: no callbacks at all => error", none.hasPrefix("error") && none.contains("no audio callbacks"), none)

        final class Throwing: CaptureTrackSource {
            let sampleRate = 48000.0, sourceLabel = "global-tap", deviceName = "none"
            var onSamples: (([Float], UInt64) -> Void)?
            var onWarning: ((String) -> Void)?
            var onDeviceChange: ((String) -> Void)?
            func start() throws { throw RecorderError.permissionDenied("tap refused") }
            func stop() {}
        }
        let failed = SystemAudioTap.probe(source: Throwing(), window: 0.5, sound: nil)
        c.check("probe: start() failure => error", failed.hasPrefix("error") && failed.contains("tap refused"), failed)

        // Contract with Setup.interpretPermission("system_audio", ...): exactly "ok" is success; failures start with "error"
        // (and the silence case also says "silence"), so they can never be mistaken for success.
        c.check("probe strings: success is exactly \"ok\"; every failure starts with \"error\"; the zeros case says \"silence\"",
                audible == "ok" && [silent, none, failed].allSatisfy { $0.hasPrefix("error") } && silent.lowercased().contains("silence"))

        // The sound player: never two at once, honours the interval, stop() terminates. (/bin/sleep, /usr/bin/true: silent.)
        let slow = SystemAudioTap.ProbeSound(executable: "/bin/sleep", arguments: ["30"], interval: 0.1)
        for _ in 0..<12 { slow.tick(); Thread.sleep(forTimeInterval: 0.1) }
        let oneAtATime = slow.launches == 1
        slow.stop()
        c.check("probe sound: a still-playing sound is not started a second time; stop() ends it", oneAtATime, "launches=\(slow.launches)")
        let quick = SystemAudioTap.ProbeSound(executable: "/usr/bin/true", arguments: [], interval: 0.35)
        for _ in 0..<12 { quick.tick(); Thread.sleep(forTimeInterval: 0.1) }
        quick.stop()
        c.check("probe sound: repeats about every interval (1.2 s at 0.35 s => 2..4 launches)", quick.launches >= 2 && quick.launches <= 4, "launches=\(quick.launches)")
        let broken = SystemAudioTap.ProbeSound(executable: "/nonexistent/player", arguments: [], interval: 0.1)
        broken.tick(); broken.stop()
        c.check("probe sound: a missing player is logged, not fatal", broken.launches == 0)
    }

    private static func testResampler(_ c: Checker) {
        print("-- Resampler (AVAudioConverter, streaming)")
        for (from, to) in [(44100.0, 48000.0), (16000.0, 48000.0), (96000.0, 48000.0), (24000.0, 48000.0)] {
            guard let r = CaptureHAL.Resampler(from: from, to: to) else { c.check("create \(from)->\(to)", false); continue }
            let chunk = Int(from / 100)                                                       // 10 ms callbacks
            let total = sine(440, rate: from, seconds: 3.0, amp: 0.5)
            var out: [Float] = []
            var i = 0
            while i < total.count {
                out += r.process(Array(total[i..<min(i + chunk, total.count)]))
                i += chunk
            }
            let expected = Int(3.0 * to)
            let mid = out.count > 96_000 ? out[48_000..<96_000] : out[0..<0]                   // 1 s in the middle
            let hz = Double(upwardZeroCrossings(mid))                                         // crossings per second
            c.check("resample \(Int(from)) -> \(Int(to)): length and pitch",
                    abs(out.count - expected) < 2400 && abs(hz - 440) <= 3,
                    "out=\(out.count) expected~\(expected) pitch=\(hz) Hz peak=\(out.map { abs($0) }.max() ?? 0)")
        }
    }

    // MARK: mixer

    private static func withList<T>(_ buffers: [(channels: Int, samples: [Float])], _ body: (UnsafeMutableAudioBufferListPointer) -> T) -> T {
        let abl = AudioBufferList.allocate(maximumBuffers: max(1, buffers.count))       // 0 buffers is not allocatable
        abl.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        for (i, b) in buffers.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, b.samples.count))
            for (j, v) in b.samples.enumerated() { p[j] = v }
            storage.append(p)
            abl[i] = AudioBuffer(mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(b.samples.count * 4), mData: b.samples.isEmpty ? nil : UnsafeMutableRawPointer(p))
        }
        defer {
            storage.forEach { $0.deallocate() }
            free(abl.unsafeMutablePointer)
        }
        return body(abl)
    }

    private static func mix(_ buffers: [(channels: Int, samples: [Float])], tail: Int?, maxChannels: Int = 2) -> [Float] {
        withList(buffers) { abl in
            var out: [Float] = []
            let range = CaptureHAL.Mixer.selectBuffers(abl, tailChannels: tail)
            CaptureHAL.Mixer.mix(abl, range: range, kind: .float32, maxChannels: maxChannels, into: &out)
            return out
        }
    }

    private static func near(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 }
    }

    private static func testMixer(_ c: Checker) {
        print("-- Mixer (IOProc buffer lists -> mono)")
        // interleaved stereo (L,R,L,R) -> mean
        c.check("interleaved stereo", near(mix([(2, [0.8, 0.4, 0.2, 0.0])], tail: nil), [0.6, 0.1]))
        // one channel per buffer
        c.check("non-interleaved stereo", near(mix([(1, [0.8, 0.2]), (1, [0.4, 0.0])], tail: nil), [0.6, 0.1]))
        // aggregate with a sub-device input stream (1 ch, 0.9) in front of the interleaved stereo tap
        c.check("tail: interleaved tap behind a sub-device stream",
                near(mix([(1, [0.9, 0.9]), (2, [0.8, 0.4, 0.2, 0.0])], tail: 2), [0.6, 0.1]))
        c.check("tail: split tap behind a sub-device stream",
                near(mix([(1, [0.9, 0.9]), (1, [0.8, 0.2]), (1, [0.4, 0.0])], tail: 2), [0.6, 0.1]))
        c.check("tail: tap only", near(mix([(2, [0.8, 0.4])], tail: 2), [0.6]))
        // microphone with 4 interleaved channels: only the first two are averaged
        c.check("4-channel mic: first two channels", near(mix([(4, [0.5, 0.1, 9, 9, 0.5, 0.1, 9, 9])], tail: nil, maxChannels: 2), [0.3, 0.3]))
        // disabled stream (NULL data) is skipped, frames follow the used buffer
        c.check("disabled stream with NULL data is skipped", near(mix([(1, []), (2, [0.8, 0.4])], tail: nil), [0.6]))
        c.check("empty list yields no frames", mix([], tail: nil).isEmpty)
        // Int16 mono
        let int16Result: [Float] = {
            let abl = AudioBufferList.allocate(maximumBuffers: 1)
            let p = UnsafeMutablePointer<Int16>.allocate(capacity: 2)
            p[0] = 16384; p[1] = -32768
            abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: UnsafeMutableRawPointer(p))
            defer { p.deallocate(); free(abl.unsafeMutablePointer) }
            var out: [Float] = []
            CaptureHAL.Mixer.mix(abl, range: 0..<1, kind: .int16, maxChannels: 2, into: &out)
            return out
        }()
        c.check("int16 samples", near(int16Result, [0.5, -1.0]), "\(int16Result)")
        // sample-kind detection from ASBD
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                               mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        c.check("ASBD float32 detected", CaptureHAL.SampleKind(asbd) == .float32)
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger; asbd.mBitsPerChannel = 24
        c.check("ASBD 24-bit int rejected (explicit error instead of garbage)", CaptureHAL.SampleKind(asbd) == nil)
        c.check("OSStatus fourcc description", CaptureHAL.describe(OSStatus(bitPattern: 0x6E6F7065)).contains("nope"))
    }

    // Read-only: the authorization STATUS query never prompts and no device is opened.
    private static func testPermissionPrecheck(_ c: Checker) {
        print("-- microphone permission pre-check (status query only)")
        let status = MicCapture.authorizationStatusString()
        var threw = false
        var kind = ""
        do { try MicCapture.ensureAuthorized(allowPrompt: false) } catch RecorderError.permissionDenied(let m) { threw = true; kind = m } catch { threw = true; kind = "other: \(error)" }
        print("  microphone status for this process: \(status)")
        c.check("unattended mode: throws permissionDenied unless authorized", (status == "authorized") != threw, "status=\(status) threw=\(threw) \(kind)")
    }


    // MARK: HALCapture engine logic with a fake backend (no device is opened, no IO is started)

    /// Plays the role of Core Audio: records start/stop calls and lets the test push buffers through the
    /// IOProc block the engine registered, on the engine's IO queue like the HAL does (dispatch_sync).
    private final class FakeBackend: HALBackend {
        private let lock = NSLock()
        private var block: AudioDeviceIOBlock?
        private var queue: DispatchQueue?
        private(set) var events: [String] = []
        var failStarts = 0                                   // the next N startIO calls throw (AudioDeviceStart refused)

        func startIO(opened: HALCapture.Opened, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock, label: String) throws -> AnyObject {
            lock.lock(); defer { lock.unlock() }
            if failStarts > 0 {
                failStarts -= 1
                events.append("start-failed")
                throw RecorderError.failed("fake AudioDeviceStart failure")
            }
            events.append("start")
            self.block = block
            self.queue = queue
            return NSObject()
        }

        func stopIO(opened: HALCapture.Opened, handle: AnyObject, label: String) {
            lock.lock(); defer { lock.unlock() }
            events.append("stop")
            block = nil
        }

        var eventLog: [String] { lock.lock(); defer { lock.unlock() }; return events }

        /// Pushes one interleaved-stereo Float32 buffer (L = R = value). No-op while no IOProc is attached.
        func deliver(frames: Int, value: Float, host: UInt64) {
            lock.lock(); let b = block, q = queue; lock.unlock()
            guard let b = b, let q = q else { return }
            let abl = AudioBufferList.allocate(maximumBuffers: 1)
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<(frames * 2) { data[i] = value }
            abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: UnsafeMutableRawPointer(data))
            let out = AudioBufferList.allocate(maximumBuffers: 1)
            out.unsafeMutablePointer.pointee.mNumberBuffers = 0
            var t1 = AudioTimeStamp(), t2 = AudioTimeStamp(), t3 = AudioTimeStamp()
            t2.mHostTime = host
            t2.mFlags = .hostTimeValid
            q.sync { b(&t1, abl.unsafePointer, &t2, out.unsafeMutablePointer, &t3) }
            data.deallocate()
            free(abl.unsafeMutablePointer)
            free(out.unsafeMutablePointer)
        }

        /// Pushes one buffer of a mono signal as interleaved stereo (L = R = sample), stamped with `host` (the host time of its
        /// first frame, like the HAL's AudioTimeStamp). No-op while no IOProc is attached (a device that is being rebuilt).
        func deliverMono(_ samples: [Float], host: UInt64) {
            lock.lock(); let b = block, q = queue; lock.unlock()
            guard let b = b, let q = q, !samples.isEmpty else { return }
            let frames = samples.count
            let abl = AudioBufferList.allocate(maximumBuffers: 1)
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
            for i in 0..<frames { data[2 * i] = samples[i]; data[2 * i + 1] = samples[i] }
            abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: UnsafeMutableRawPointer(data))
            let out = AudioBufferList.allocate(maximumBuffers: 1)
            out.unsafeMutablePointer.pointee.mNumberBuffers = 0
            var t1 = AudioTimeStamp(), t2 = AudioTimeStamp(), t3 = AudioTimeStamp()
            t2.mHostTime = host
            t2.mFlags = .hostTimeValid
            q.sync { b(&t1, abl.unsafePointer, &t2, out.unsafeMutablePointer, &t3) }
            data.deallocate()
            free(abl.unsafeMutablePointer)
            free(out.unsafeMutablePointer)
        }
    }

    private final class EngineProbe {
        let backend = FakeBackend()
        let lock = NSLock()
        var opens = 0, goodOpens = 0, cleanups = 0
        var signature = "A"
        var openFailures = 0
        var warnings: [String] = []
        var changeTimes: [Double] = []
        var frames = 0
        var peak: Float = 0
        var outputActive = false
        var firstAudioCalls = 0
        var startFailureCalls = 0
        var engine: HALCapture!
        private var feeder: DispatchSourceTimer?
        private var feedValue: Float = 0.5

        /// `consumerDelay` makes the handler slow (like a session.json write at the first frame), so buffers pile up
        /// on the engine's work queue.
        init(nativeRate: Double = 48000, heal: Bool = false, consumerDelay: TimeInterval = 0, quickHeal: TimeInterval? = nil, timing: HALCapture.Timing) {
            engine = HALCapture(label: "fake", targetRate: 48000, systemTriggers: [], healZeroRun: heal,
                                outputActivity: { [unowned self] in self.lock.lock(); defer { self.lock.unlock() }; return self.outputActive },
                                backend: backend, timing: timing, open: { [unowned self] in
                self.lock.lock(); defer { self.lock.unlock() }
                self.opens += 1
                if self.openFailures > 0 {
                    self.openFailures -= 1
                    throw RecorderError.deviceUnavailable("fake device unplugged")
                }
                self.goodOpens += 1
                let n = self.goodOpens
                return HALCapture.Opened(ioDevice: AudioObjectID(kAudioObjectUnknown), deviceName: "Fake \(n)", nativeRate: nativeRate,
                                         kind: .float32, maxChannels: 2, tailChannels: nil, disableOutputStreams: false, watched: [],
                                         signature: self.signature, currentSignature: { [unowned self] in
                                             self.lock.lock(); defer { self.lock.unlock() }; return self.signature },
                                         cleanup: { [unowned self] in self.lock.lock(); self.cleanups += 1; self.lock.unlock() },
                                         quickSilenceHeal: quickHeal,
                                         onStartFailure: { [unowned self] _ in self.lock.lock(); self.startFailureCalls += 1; self.lock.unlock() })
            })
            engine.onFirstAudio = { [unowned self] in self.lock.lock(); self.firstAudioCalls += 1; self.lock.unlock() }
            engine.handler = { [unowned self] samples, _ in
                if consumerDelay > 0 { Thread.sleep(forTimeInterval: consumerDelay) }
                self.lock.lock(); self.frames += samples.count; self.peak = max(self.peak, samples.map { abs($0) }.max() ?? 0); self.lock.unlock()
            }
            engine.onWarning = { [unowned self] m in self.lock.lock(); self.warnings.append(m); self.lock.unlock() }
            engine.onDeviceChange = { [unowned self] _ in self.lock.lock(); self.changeTimes.append(ProcessInfo.processInfo.systemUptime); self.lock.unlock() }
        }

        func set(_ body: () -> Void) { lock.lock(); body(); lock.unlock() }
        func get<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

        func startFeeder(value: Float) {
            feedValue = value
            feeder?.cancel()
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fake.feeder"))
            t.schedule(deadline: .now(), repeating: 0.01)
            t.setEventHandler { [unowned self] in self.backend.deliver(frames: 480, value: self.feedValue, host: CaptureHAL.Clock.now()) }
            t.resume()
            feeder = t
        }
        func stopFeeder() { feeder?.cancel(); feeder = nil }
    }

    private static func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return cond()
    }

    private static func testEngineLogic(_ c: Checker) {
        print("-- HALCapture engine logic (fake backend, accelerated timing)")
        var timing = HALCapture.Timing()
        timing.tick = 0.05; timing.stallAfter = 0.4; timing.zeroHealAfter = 0.4
        timing.zeroBackoffStart = 0.5; timing.zeroBackoffMax = 2; timing.debounce = 0.05; timing.retryDelays = [0.05, 0.1, 0.2]

        // 1. delivery, mono mix, no resampling at the target rate
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            p.startFeeder(value: 0.5)
            Thread.sleep(forTimeInterval: 0.5)
            p.stopFeeder(); p.engine.stop()
            let (frames, peak) = p.get { (p.frames, p.peak) }
            c.check("engine delivers mono audio (L=R=0.5 -> 0.5), ~48000 frames/s", frames > 20_000 && frames < 28_000 && abs(peak - 0.5) < 0.001, "frames=\(frames) peak=\(peak)")
            c.check("stop() destroys what open() created exactly once", p.get { (p.opens, p.cleanups) } == (1, 1) && p.backend.eventLog == ["start", "stop"], "\(p.backend.eventLog)")
            p.engine.stop()
        }
        // 1b. resampling path through the engine (44.1 kHz device -> 48 kHz file)
        do {
            let p = EngineProbe(nativeRate: 44100, timing: timing)
            try? p.engine.start()
            p.startFeeder(value: 0.25)
            Thread.sleep(forTimeInterval: 1.0)
            p.stopFeeder(); p.engine.stop()
            let frames = p.get { p.frames }
            // feeder pushes 480 frames per 10 ms at the *device* rate => about 48000 device frames/s -> ~52000 output
            c.check("engine converts the device rate to the file rate", frames > 40_000 && frames < 62_000, "frames=\(frames)")
        }
        // 2/3. environment change => teardown then rebuild; unchanged environment => nothing
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            p.startFeeder(value: 0.5)
            Thread.sleep(forTimeInterval: 0.5)
            c.check("unchanged environment does not rebuild", p.get { p.opens } == 1)
            p.set { p.signature = "B" }                                   // e.g. default output device changed
            let rebuilt = waitUntil(1.5) { p.get { p.goodOpens } == 2 }
            c.check("environment change rebuilds (stop -> cleanup -> start order)", rebuilt && p.backend.eventLog == ["start", "stop", "start"] && p.get { p.cleanups } == 1,
                    "\(p.backend.eventLog) cleanups=\(p.get { p.cleanups })")
            Thread.sleep(forTimeInterval: 0.4)
            c.check("onDeviceChange fired once, no rebuild loop afterwards", p.get { p.changeTimes.count } == 1 && p.get { p.opens } == 2)
            p.engine.requestRebuild(reason: "test")
            c.check("requestRebuild forces a rebuild", waitUntil(1.0) { p.get { p.goodOpens } == 3 })
            p.stopFeeder(); p.engine.stop()
            c.check("every open was cleaned up exactly once", p.get { p.cleanups } == p.get { p.goodOpens }, "\(p.get { (p.goodOpens, p.cleanups) })")
        }
        // 4. stall: callbacks stop => rebuild with growing backoff; recovery resets it
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            p.startFeeder(value: 0.5)
            Thread.sleep(forTimeInterval: 0.3)
            p.stopFeeder()                                                // the "device" dies silently
            let t0 = ProcessInfo.processInfo.systemUptime
            _ = waitUntil(4.0) { p.get { p.changeTimes.count } >= 3 }
            let times = p.get { p.changeTimes }
            if times.count >= 3 {
                let g1 = times[1] - times[0], g2 = times[2] - times[1]
                c.check("stall rebuilds back off exponentially", g2 > g1 * 1.3, String(format: "first at +%.2fs, gaps %.2fs then %.2fs", times[0] - t0, g1, g2))
            } else {
                c.check("stall triggers rebuilds", false, "rebuilds=\(times.count)")
            }
            p.engine.stop()
        }
        // 5. zero-buffer workaround: only when another process is playing; warns once; backs off; stops after audio returns
        do {
            let p = EngineProbe(heal: true, timing: timing)
            try? p.engine.start()
            p.startFeeder(value: 0)
            Thread.sleep(forTimeInterval: 1.0)
            c.check("digital silence alone (nobody playing) does not rebuild", p.get { p.opens } == 1 && p.engine.zeroHealCount == 0)
            p.set { p.outputActive = true }
            let healed = waitUntil(2.0) { p.engine.zeroHealCount >= 1 }
            c.check("silence while another process plays => rebuild", healed, "heals=\(p.engine.zeroHealCount)")
            let again = waitUntil(3.0) { p.engine.zeroHealCount >= 2 }
            c.check("repeated heals continue with backoff, warning raised only once", again && p.get { p.warnings.filter { $0.contains("digital silence") }.count } == 1,
                    "heals=\(p.engine.zeroHealCount) warnings=\(p.get { p.warnings.count })")
            p.startFeeder(value: 0.3)                                     // audio is back
            Thread.sleep(forTimeInterval: 0.5)
            let heals = p.engine.zeroHealCount
            Thread.sleep(forTimeInterval: 1.2)
            c.check("no more heals once audio flows", p.engine.zeroHealCount == heals, "\(heals) -> \(p.engine.zeroHealCount)")
            p.stopFeeder(); p.engine.stop()
        }
        // 6. initial open failure surfaces as an error; later failures retry in the background and recover
        do {
            let p = EngineProbe(timing: timing)
            p.set { p.openFailures = 1 }
            var threw = false
            do { try p.engine.start() } catch { threw = true }
            c.check("first open failure is thrown to the caller (no background retry)", threw && p.get { p.opens } == 1)
            Thread.sleep(forTimeInterval: 0.4)
            c.check("... and nothing keeps retrying after a failed start", p.get { p.opens } == 1)

            let q = EngineProbe(timing: timing)
            try? q.engine.start()
            q.startFeeder(value: 0.5)
            Thread.sleep(forTimeInterval: 0.2)
            q.set { q.openFailures = 3; q.signature = "B" }
            let recovered = waitUntil(3.0) { q.get { q.goodOpens } == 2 }
            c.check("failed rebuild retries (3 failures) and recovers", recovered && q.get { q.opens } == 5,
                    "opens=\(q.get { q.opens }) warnings=\(q.get { q.warnings })")
            c.check("one 'capture lost' warning for the whole outage", q.get { q.warnings.filter { $0.contains("capture lost") }.count } == 1)
            q.stopFeeder(); q.engine.stop()
        }
        // 7. stop while retrying cancels the retries; stop is idempotent
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            p.set { p.openFailures = 1000; p.signature = "B" }
            _ = waitUntil(1.0) { p.get { p.opens } >= 3 }
            p.engine.stop()
            let opens = p.get { p.opens }
            Thread.sleep(forTimeInterval: 0.6)
            p.engine.stop()
            c.check("stop() during an outage cancels retries; second stop is harmless", p.get { p.opens } == opens && p.get { p.cleanups } == p.get { p.goodOpens },
                    "opens=\(opens)->\(p.get { p.opens }) good=\(p.get { p.goodOpens }) cleanups=\(p.get { p.cleanups })")
        }
        // 8. teardown order: buffers that were captured but still queued behind a slow consumer are DELIVERED, not discarded.
        //    (Regression: teardown used to clear `active` before draining, which dropped the whole backlog, e.g. 240 ms of 250 ms.)
        do {
            let p = EngineProbe(consumerDelay: 0.02, timing: timing)
            try? p.engine.start()
            let fed = 25                                                  // 25 x 10 ms = 250 ms captured while the consumer lags
            for _ in 0..<fed { p.backend.deliver(frames: 480, value: 0.5, host: CaptureHAL.Clock.now()) }
            p.engine.stop()
            let delivered = p.get { p.frames }
            c.check("stop() delivers every buffer captured before it (slow consumer): 250 ms in, 250 ms out",
                    delivered == fed * 480, "delivered \(delivered) of \(fed * 480) frames, \(String(format: "%.0f", Double(fed * 480 - delivered) / 48.0)) ms lost")
            Thread.sleep(forTimeInterval: 0.25)
            c.check("nothing is delivered after stop() returned", p.get { p.frames } == delivered, "\(delivered) -> \(p.get { p.frames })")
        }
        // 9. the same on a rebuild (device change): the old graph's backlog arrives before the new graph starts.
        do {
            let p = EngineProbe(consumerDelay: 0.02, timing: timing)
            try? p.engine.start()
            let fed = 25
            for _ in 0..<fed { p.backend.deliver(frames: 480, value: 0.5, host: CaptureHAL.Clock.now()) }
            p.engine.requestRebuild(reason: "test: backlog on rebuild")
            let rebuilt = waitUntil(3.0) { p.get { p.goodOpens } == 2 }
            let delivered = p.get { p.frames }
            c.check("rebuild delivers the old graph's backlog first (nothing lost at a device change)", rebuilt && delivered == fed * 480,
                    "rebuilt=\(rebuilt) delivered \(delivered) of \(fed * 480) frames")
            p.engine.stop()
        }
    }

    // MARK: resampler tail, engine hooks (first audio, early silence heal, start failure)

    /// The converter holds a few frames (16 to 96 at 48 kHz) that only an end-of-stream call releases; they used to be dropped
    /// at every stop and rebuild.
    private static func testResamplerTail(_ c: Checker) {
        print("-- Resampler tail: flushed at end of stream, delivered at stop / rebuild")
        for (from, to) in [(44100.0, 48000.0), (16000.0, 48000.0), (24000.0, 48000.0), (96000.0, 48000.0)] {
            guard let r = CaptureHAL.Resampler(from: from, to: to) else { c.check("create \(from)->\(to)", false); continue }
            let chunk = Int(from / 100)
            let total = sine(440, rate: from, seconds: 3.0, amp: 0.5)
            var out = 0
            var i = 0
            while i < total.count {
                out += r.process(Array(total[i..<min(i + chunk, total.count)])).count
                i += chunk
            }
            let tail = r.flush()
            let expected = Double(total.count) * to / from
            c.check("resample \(Int(from)) -> \(Int(to)): without the tail \(Int(expected) - out) frames are missing, with flush() the count is exact",
                    !tail.isEmpty && abs(Double(out + tail.count) - expected) <= 1 && Double(out) < expected - 1,
                    "chunks \(out) + tail \(tail.count) vs expected \(expected)")
            c.check("resample \(Int(from)) -> \(Int(to)): a second flush() delivers nothing and does not crash", r.flush().isEmpty)
        }

        var timing = HALCapture.Timing()
        timing.tick = 0.05; timing.stallAfter = 5; timing.zeroHealAfter = 5; timing.debounce = 0.05
        func feedAndStop(rebuild: Bool) -> (delivered: Int, expected: Double) {
            let p = EngineProbe(nativeRate: 44100, timing: timing)
            try? p.engine.start()
            let fed = 25                                              // 25 x 480 native frames at 44.1 kHz
            for _ in 0..<fed { p.backend.deliver(frames: 480, value: 0.5, host: CaptureHAL.Clock.now()) }
            if rebuild {
                p.engine.requestRebuild(reason: "test: tail on rebuild")
                _ = waitUntil(3.0) { p.get { p.goodOpens } == 2 }
            }
            p.engine.stop()
            return (p.get { p.frames }, Double(fed * 480) * 48000 / 44100)
        }
        let atStop = feedAndStop(rebuild: false)
        c.check("stop() delivers the resampler tail: 44.1 kHz in, within 1 frame of the exact 48 kHz length out",
                abs(Double(atStop.delivered) - atStop.expected) <= 1.0, "delivered \(atStop.delivered) of \(atStop.expected)")
        let atRebuild = feedAndStop(rebuild: true)
        c.check("a rebuild delivers the old graph's resampler tail too",
                abs(Double(atRebuild.delivered) - atRebuild.expected) <= 1.0, "delivered \(atRebuild.delivered) of \(atRebuild.expected)")
    }

    private static func testEngineHooks(_ c: Checker) {
        print("-- HALCapture hooks: first audio, early silence heal, start failure")
        var timing = HALCapture.Timing()
        timing.tick = 0.05; timing.stallAfter = 5; timing.zeroHealAfter = 1.5
        timing.zeroBackoffStart = 0.4; timing.zeroBackoffMax = 1; timing.debounce = 0.05; timing.retryDelays = [0.05, 0.1]

        // onFirstAudio: once per build, only for non-zero samples
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            p.startFeeder(value: 0)
            Thread.sleep(forTimeInterval: 0.4)
            c.check("onFirstAudio is not called for digital silence", p.get { p.firstAudioCalls } == 0)
            p.startFeeder(value: 0.3)
            c.check("onFirstAudio fires when audio arrives", waitUntil(1.0) { p.get { p.firstAudioCalls } == 1 })
            Thread.sleep(forTimeInterval: 0.4)
            c.check("... and only once for that build", p.get { p.firstAudioCalls } == 1)
            p.engine.requestRebuild(reason: "test: new graph")
            c.check("a rebuilt graph reports its own first audio", waitUntil(2.0) { p.get { p.firstAudioCalls } == 2 }, "calls=\(p.get { p.firstAudioCalls })")
            p.stopFeeder(); p.engine.stop()
        }
        // early silence heal: an unproven host strategy is re-created after quickSilenceHeal, long before zeroHealAfter, and without a menu warning
        do {
            let p = EngineProbe(heal: true, quickHeal: 0.25, timing: timing)
            try? p.engine.start()
            p.set { p.outputActive = true }
            p.startFeeder(value: 0)
            let t0 = ProcessInfo.processInfo.systemUptime
            let healed = waitUntil(1.2) { p.engine.zeroHealCount >= 1 }
            let after = ProcessInfo.processInfo.systemUptime - t0
            c.check("quickSilenceHeal: silence while another app plays rebuilds after ~0.25 s, not after zeroHealAfter (1.5 s)",
                    healed && after < 1.0, "healed=\(healed) after \(String(format: "%.2f", after)) s")
            c.check("an early heal is only logged: no menu warning", p.get { p.warnings.isEmpty }, "\(p.get { p.warnings })")
            p.stopFeeder(); p.engine.stop()

            let q = EngineProbe(heal: true, timing: timing)           // the same without a quick threshold
            try? q.engine.start()
            q.set { q.outputActive = true }
            q.startFeeder(value: 0)
            Thread.sleep(forTimeInterval: 0.9)
            c.check("without quickSilenceHeal the normal threshold applies (no rebuild after 0.9 s of silence)", q.engine.zeroHealCount == 0)
            q.stopFeeder(); q.engine.stop()

            let r = EngineProbe(heal: true, quickHeal: 0.25, timing: timing)   // quick, but nobody else is playing
            try? r.engine.start()
            r.startFeeder(value: 0)
            Thread.sleep(forTimeInterval: 0.9)
            c.check("a quiet start (nobody has audio output open) is never rebuilt, quick threshold or not", r.engine.zeroHealCount == 0)
            r.stopFeeder(); r.engine.stop()
        }
        // start failure hook
        do {
            let p = EngineProbe(timing: timing)
            p.backend.failStarts = 1
            var threw = false
            do { try p.engine.start() } catch { threw = true }
            c.check("AudioDeviceStart refused: start() throws, onStartFailure called once, the build was cleaned up once",
                    threw && p.get { p.startFailureCalls } == 1 && p.get { p.cleanups } == 1 && p.backend.eventLog == ["start-failed"],
                    "threw=\(threw) failures=\(p.get { p.startFailureCalls }) cleanups=\(p.get { p.cleanups }) \(p.backend.eventLog)")
        }
    }

    // MARK: tap host strategy (pure logic, no device)

    private static func testTapHostStrategy(_ c: Checker) {
        print("-- tap host strategy: policy, chooser scenarios, memory (no device)")
        typealias E = TapHostPolicy.Environment
        c.check("MacBook speakers (no input streams): just the default output",
                TapHostPolicy.candidates(E(defaultHasInputStreams: false, builtInDistinctFromDefault: false)) == [.defaultOutput])
        c.check("HDMI / USB DAC (no input streams, built-in exists, not Bluetooth): still just the default output",
                TapHostPolicy.candidates(E(defaultHasInputStreams: false, builtInDistinctFromDefault: true)) == [.defaultOutput])
        c.check("USB / Bluetooth speakerphone or headset: built-in output as clock first (no input streams of the device), then tap-only, "
                + "then the device itself as the last resort so a wrong assumption can never leave the remote track empty",
                TapHostPolicy.candidates(E(defaultHasInputStreams: true, builtInDistinctFromDefault: true)) == [.builtInOutput, .tapOnly, .defaultOutput])
        c.check("the speakerphone itself is never the FIRST choice (its input streams would be in the aggregate)",
                TapHostPolicy.candidates(E(defaultHasInputStreams: true, builtInDistinctFromDefault: true)).first == .builtInOutput)
        c.check("speakerphone and no other output to borrow a clock from: default output, then tap-only",
                TapHostPolicy.candidates(E(defaultHasInputStreams: true, builtInDistinctFromDefault: false)) == [.defaultOutput, .tapOnly])
        for (value, expected) in [("builtin", TapHost.builtInOutput), ("DEFAULT", .defaultOutput), ("tap-only", .tapOnly), ("none", .tapOnly)] as [(String, TapHost)] {
            c.check("MC_TAP_HOST=\(value) pins \(expected.rawValue)", TapHostPolicy.parseOverride(value) == expected)
        }
        c.check("MC_TAP_HOST unset or unknown = automatic", TapHostPolicy.parseOverride(nil) == nil && TapHostPolicy.parseOverride("weird") == nil && TapHostPolicy.parseOverride("") == nil)

        let usb = TapHostPolicy.candidates(E(defaultHasInputStreams: true, builtInDistinctFromDefault: true))
        c.check("scenario input: the real speakerphone candidate list has three entries", usb == [.builtInOutput, .tapOnly, .defaultOutput], "\(usb)")
        // 1. a speakerphone whose first strategies stay silent: every candidate is tried (nothing is a dead end), and a strategy that proved itself stays
        var ch = TapHostChooser()
        let first = ch.choose(deviceUID: "usb", candidates: usb, healCount: 0, remembered: nil)
        c.check("speakerphone: the built-in output clocks the first build", first.host == .builtInOutput && first.why.contains("first choice"), "\(first)")
        let same = ch.choose(deviceUID: "usb", candidates: usb, healCount: 0, remembered: nil)
        c.check("a rebuild for another reason (device event) keeps the strategy", same.host == .builtInOutput, "\(same)")
        let flipped = ch.choose(deviceUID: "usb", candidates: usb, healCount: 1, remembered: nil)
        c.check("silence heal of a strategy that never delivered audio -> the next candidate, with the reason",
                flipped.host == .tapOnly && flipped.why.contains("built-in-output delivered only digital silence"), "\(flipped)")
        let last = ch.choose(deviceUID: "usb", candidates: usb, healCount: 2, remembered: nil)
        c.check("silent again -> the speakerphone's own output clocks the tap (last resort: if a tap were bound to its device, this is the one that works)",
                last.host == .defaultOutput && last.why.contains("tap-only delivered only digital silence"), "\(last)")
        let wrapped = ch.choose(deviceUID: "usb", candidates: usb, healCount: 3, remembered: nil)
        c.check("silent once more -> back to the first candidate (alternation, no dead end)", wrapped.host == .builtInOutput, "\(wrapped)")
        ch.noteAudio()
        let kept = ch.choose(deviceUID: "usb", candidates: usb, healCount: 4, remembered: .builtInOutput)
        c.check("a strategy that delivered audio is kept on a later silence heal (a rebuild is the cure for a stuck tap)",
                kept.host == .builtInOutput && kept.why.contains("kept"), "\(kept)")
        let twice = ch.choose(deviceUID: "usb", candidates: usb, healCount: 5, remembered: .builtInOutput)
        c.check("... but not forever: two silence heals in a row without audio in between switch anyway", twice.host == .tapOnly, "\(twice)")

        // The worst case, the one the 3rd candidate exists for: only the speakerphone's own clock delivers audio. Starting from a
        // fresh chooser, three consecutive silent graphs reach it, it is then remembered, and a later silence heal keeps it.
        var worst = TapHostChooser()
        var hosts: [TapHost] = []
        for heals in 0..<3 { hosts.append(worst.choose(deviceUID: "usb2", candidates: usb, healCount: heals, remembered: nil).host) }
        c.check("only the device's own clock works: built-in output, tap-only, then the device (3 builds)", hosts == [.builtInOutput, .tapOnly, .defaultOutput], "\(hosts)")
        worst.noteAudio()
        TapHostMemory.forgetAll()
        TapHostMemory.remember(.defaultOutput, for: "usb2")
        let stays = worst.choose(deviceUID: "usb2", candidates: usb, healCount: 3, remembered: TapHostMemory.recall("usb2"))
        c.check("... and once it delivered audio it stays (the next meeting on this device starts with it)", stays.host == .defaultOutput && stays.why.contains("kept"), "\(stays)")
        var nextMeeting = TapHostChooser()
        let resumed = nextMeeting.choose(deviceUID: "usb2", candidates: usb, healCount: 0, remembered: TapHostMemory.recall("usb2"))
        c.check("a new recording (new chooser) on that device starts with the proven strategy, not the first candidate",
                resumed.host == .defaultOutput && resumed.why.contains("delivered audio earlier"), "\(resumed)")
        TapHostMemory.forgetAll()

        // 2. start failures
        var f = TapHostChooser()
        _ = f.choose(deviceUID: "usb", candidates: usb, healCount: 0, remembered: nil)
        f.noteStartFailure()
        let afterFail = f.choose(deviceUID: "usb", candidates: usb, healCount: 0, remembered: nil)
        c.check("a build that could not be started -> the next candidate", afterFail.host == .tapOnly && afterFail.why.contains("could not be started"), "\(afterFail)")
        let noMore = f.choose(deviceUID: "usb", candidates: usb, healCount: 0, remembered: nil)
        c.check("... and the failure flag is consumed (no flip without a new failure)", noMore.host == .tapOnly, "\(noMore)")
        f.noteStartFailure()
        let third = f.choose(deviceUID: "usb", candidates: usb, healCount: 0, remembered: nil)
        c.check("tap-only cannot be built either (no sub-device allowed) -> straight on to the device's own clock, no waiting",
                third.host == .defaultOutput && third.why.contains("tap-only could not be started"), "\(third)")
        var single = TapHostChooser()
        _ = single.choose(deviceUID: "mac", candidates: [.defaultOutput], healCount: 0, remembered: nil)
        single.noteStartFailure()
        let s1 = single.choose(deviceUID: "mac", candidates: [.defaultOutput], healCount: 2, remembered: nil)
        c.check("a single candidate (MacBook speakers) never changes", s1.host == .defaultOutput)

        // 3. another output device: remembered strategy first, healCount baseline adopted (no spurious flip)
        var d = TapHostChooser()
        _ = d.choose(deviceUID: "usb", candidates: usb, healCount: 0, remembered: nil)
        let other = d.choose(deviceUID: "airpods", candidates: usb, healCount: 5, remembered: .tapOnly)
        c.check("new default output device: starts with the strategy that delivered audio there before",
                other.host == .tapOnly && other.why.contains("delivered audio earlier"), "\(other)")
        let noFlip = d.choose(deviceUID: "airpods", candidates: usb, healCount: 5, remembered: .tapOnly)
        c.check("the heal counter of the previous device is not read as a new silence", noFlip.host == .tapOnly, "\(noFlip)")
        let fresh = d.choose(deviceUID: "buds", candidates: usb, healCount: 5, remembered: nil)
        c.check("an unknown device starts with its first candidate", fresh.host == .builtInOutput)

        // 4. pinned by MC_TAP_HOST
        var p = TapHostChooser()
        let pinned = p.choose(deviceUID: "usb", candidates: [.defaultOutput], healCount: 0, remembered: nil, forced: true)
        c.check("a pinned strategy says so", pinned.host == .defaultOutput && pinned.why == "pinned by MC_TAP_HOST", "\(pinned)")

        // 5. process-wide memory
        TapHostMemory.forgetAll()
        c.check("memory: empty at first", TapHostMemory.recall("usb") == nil)
        TapHostMemory.remember(.tapOnly, for: "usb")
        c.check("memory: remembers per device UID", TapHostMemory.recall("usb") == .tapOnly && TapHostMemory.recall("other") == nil)
        TapHostMemory.forgetAll()

        // 6. the labels that reach session.json / app.log
        c.check("strategy titles are readable", TapHost.defaultOutput.title == "default output" && TapHost.builtInOutput.title == "built-in output" && TapHost.tapOnly.title.contains("tap only"))
        c.check("strategy raw values are the log tokens", TapHost.allCases.map { $0.rawValue } == ["default-output", "built-in-output", "tap-only"])
    }

    // MARK: delivered-rate measurement (RateMeter / RateJudge): pure, synthetic callback timestamps

    /// Callbacks of a device that delivers `rate` frames per second in buffers of `frames`, stamped with the device clock
    /// (the way AudioTimeStamp.mHostTime is). `jitter` perturbs the stamps deterministically, `stallAt` makes one hiccup.
    @discardableResult
    private static func feedMeter(_ meter: inout CaptureHAL.RateMeter, rate: Double, frames: Int, from t0: Double, seconds: Double,
                                  jitter: Double = 0, stallAt: Double? = nil, stall: Double = 0) -> Double {
        var t = t0
        var i = 0
        var hiccuped = false
        while t < t0 + seconds {
            if let s = stallAt, !hiccuped, t >= t0 + s { t += stall; hiccuped = true }
            meter.add(host: t + jitter * sin(Double(i) * 12.9898), frames: frames)
            t += Double(frames) / rate
            i += 1
        }
        return t
    }

    private static func testRateMeter(_ c: Checker) {
        print("-- RateMeter: the rate an IOProc really delivers, measured against the host clock (synthetic callback stamps)")
        for (rate, frames) in [(48000.0, 480), (44100.0, 441), (24000.0, 480), (24000.0, 240), (16000.0, 320), (96000.0, 960)] {
            var m = CaptureHAL.RateMeter()
            feedMeter(&m, rate: rate, frames: frames, from: 100, seconds: 1.2)
            let e = m.estimate(lastSeconds: 1.0)
            c.check("meter: \(Int(rate)) Hz in \(frames)-frame callbacks measures \(Int(rate)) Hz within 0.3 %, covers ~1 s, stationary",
                    e != nil && abs(e!.rate / rate - 1) < 0.003 && e!.coverage > 0.9 && e!.stationary,
                    e.map { String(format: "%.1f Hz, coverage %.2f s, stationary %@", $0.rate, $0.coverage, "\($0.stationary)") } ?? "nil")
        }
        do {
            var m = CaptureHAL.RateMeter()
            feedMeter(&m, rate: 24000, frames: 480, from: 5, seconds: 1.5, jitter: 0.003)         // +-3 ms of stamp noise on 20 ms buffers
            let e = m.estimate(lastSeconds: 1.0)
            c.check("meter: +-3 ms stamp jitter on 20 ms callbacks still measures 24 kHz within 3 %", e != nil && abs(e!.rate / 24000 - 1) < 0.03,
                    e.map { String(format: "%.0f Hz", $0.rate) } ?? "nil")
        }
        do {
            var m = CaptureHAL.RateMeter()
            feedMeter(&m, rate: 24000, frames: 480, from: 5, seconds: 1.5, stallAt: 0.5, stall: 0.3)   // a 300 ms hiccup inside the window
            let e = m.estimate(lastSeconds: 1.2)
            c.check("meter: a 300 ms hiccup of the callbacks inside the window is not a rate (outlier interval dropped)",
                    e != nil && abs(e!.rate / 24000 - 1) < 0.005, e.map { String(format: "%.0f Hz", $0.rate) } ?? "nil")
            var s = CaptureHAL.RateMeter()
            feedMeter(&s, rate: 48000, frames: 480, from: 5, seconds: 0.5)
            s.add(host: 5.5 + 1.6, frames: 480)                                                        // 1.6 s without a callback (restart)
            feedMeter(&s, rate: 48000, frames: 480, from: 7.1 + 0.01, seconds: 0.5)
            let after = s.estimate(lastSeconds: 3.0)
            c.check("meter: a restart (>= 1 s without callbacks) is excluded, not averaged in (still 48 kHz)",
                    after != nil && abs(after!.rate / 48000 - 1) < 0.005, after.map { String(format: "%.0f Hz", $0.rate) } ?? "nil")
        }
        do {
            var m = CaptureHAL.RateMeter()
            let t = feedMeter(&m, rate: 48000, frames: 480, from: 10, seconds: 1.0)
            feedMeter(&m, rate: 24000, frames: 480, from: t, seconds: 0.5)
            let mixed = m.estimate(lastSeconds: 1.0)
            c.check("meter: a rate change inside the window is not stationary (no verdict from a half-and-half window)", mixed != nil && !mixed!.stationary,
                    mixed.map { String(format: "%.0f Hz stationary %@", $0.rate, "\($0.stationary)") } ?? "nil")
            let t2 = feedMeter(&m, rate: 24000, frames: 480, from: t + 0.5, seconds: 1.3)
            let settled = m.estimate(lastSeconds: 1.0)
            c.check("meter: one window after the change it is stationary again and says 24 kHz",
                    settled != nil && settled!.stationary && abs(settled!.rate / 24000 - 1) < 0.005 && t2 > 0, settled.map { String(format: "%.0f Hz", $0.rate) } ?? "nil")
        }
        do {
            var m = CaptureHAL.RateMeter()
            for i in 0..<25 { m.add(host: 50 + Double(i) * 0.0001, frames: 480) }                      // a burst: 25 buffers in 2.4 ms
            let e = m.estimate(lastSeconds: 1.0)
            // (review of 2026-10-10: the estimate works on blocks of >= 50 ms now, so a burst that covers 2.4 ms gives NO estimate at all;
            // the point of the check is unchanged: nobody acts on a burst)
            c.check("meter: a burst of buffers covers almost no host time: no estimate, or one with coverage < 0.01 s whose absurd rate is implausible (nobody acts on it)",
                    e == nil || (e!.coverage < 0.01 && CaptureHAL.RateJudge.verdict(assumed: 48000, measured: e!.rate, hints: { [] }) == nil),
                    e.map { String(format: "%.0f Hz over %.4f s", $0.rate, $0.coverage) } ?? "nil")
            var few = CaptureHAL.RateMeter()
            for i in 0..<3 { few.add(host: 1 + Double(i) * 0.01, frames: 480) }
            c.check("meter: too few callbacks say nothing (nil)", few.estimate(lastSeconds: 1.0) == nil)
            var long = CaptureHAL.RateMeter()
            feedMeter(&long, rate: 48000, frames: 480, from: 0, seconds: 10)
            let le = long.estimate(lastSeconds: 10)
            c.check("meter: the window slides (3 s retained out of 10 s fed)", le != nil && le!.coverage < 3.1 && le!.coverage > 2.8, le.map { String(format: "%.2f s", $0.coverage) } ?? "nil")
        }

        // Review of 2026-10-10: the stamps of a real device are not perfect. A HEALTHY 48 kHz device with +-3 ms of noise on its 10.7 ms
        // cadence used to measure 44 - 45 kHz (the per-interval screen was lopsided), which RateJudge reads as "44.1 kHz": the graph was
        // resampled from 44.1 kHz and back, over and over. Blocks of >= 50 ms (sums telescope) measure it right. Every look of 20 s is judged.
        typealias J = CaptureHAL.RateJudge
        func looks(rate: Double, frames: Int, seconds: Double, assumed: Double, noise: (inout NoiseRNG, Int) -> Double) -> (worst: Double, mismatches: Int, looks: Int) {
            var m = CaptureHAL.RateMeter()
            var rng = NoiseRNG(seed: 42)
            var t = 100.0, i = 0, worst = 0.0, mismatches = 0, n = 0
            while t < 100 + seconds {
                m.add(host: t + noise(&rng, i), frames: frames)
                t += Double(frames) / rate
                i += 1
                if i % 25 == 0, let e = m.estimate(lastSeconds: 1.0), e.coverage >= 0.6, e.stationary {
                    n += 1
                    worst = max(worst, abs(e.rate / rate - 1))
                    if let v = J.verdict(assumed: assumed, measured: e.rate, hints: { [] }), v.mismatch { mismatches += 1 }
                }
            }
            return (worst, mismatches, n)
        }
        func text(_ r: (worst: Double, mismatches: Int, looks: Int)) -> String { String(format: "worst deviation %.2f %%, %d of %d looks said mismatch", r.worst * 100, r.mismatches, r.looks) }
        let uniform3 = looks(rate: 48000, frames: 512, seconds: 20, assumed: 48000) { r, _ in (r.next() - 0.5) * 0.006 }
        c.check("meter: healthy 48 kHz, 512-frame callbacks (10.7 ms), +-3 ms of random stamp noise: every look within 3 %, never a mismatch (was 44 - 45 kHz and flapping)",
                uniform3.looks > 20 && uniform3.worst < 0.03 && uniform3.mismatches == 0, text(uniform3))
        let uniform5 = looks(rate: 48000, frames: 512, seconds: 20, assumed: 48000) { r, _ in (r.next() - 0.5) * 0.010 }
        c.check("meter: ... even +-5 ms (half the cadence)", uniform5.looks > 20 && uniform5.worst < 0.03 && uniform5.mismatches == 0, text(uniform5))
        let tiny = looks(rate: 48000, frames: 64, seconds: 10, assumed: 48000) { r, _ in (r.next() - 0.5) * 0.001 }
        c.check("meter: ... 64-frame callbacks (1.3 ms) with +-0.5 ms of noise", tiny.looks > 20 && tiny.worst < 0.03 && tiny.mismatches == 0, text(tiny))
        let paired = looks(rate: 48000, frames: 480, seconds: 10, assumed: 48000) { _, i in i % 2 == 0 ? 0 : 0.009 }
        c.check("meter: ... callbacks stamped in pairs (9 ms / 1 ms apart, a bursty driver)", paired.looks > 10 && paired.worst < 0.03 && paired.mismatches == 0, text(paired))
        let alternating = looks(rate: 48000, frames: 480, seconds: 10, assumed: 48000) { _, i in i % 2 == 0 ? 0.0025 : -0.0025 }
        c.check("meter: ... stamps alternating +-2.5 ms (5 ms / 15 ms apart)", alternating.looks > 10 && alternating.worst < 0.03 && alternating.mismatches == 0, text(alternating))
        do {
            var m = CaptureHAL.RateMeter()
            var t = 100.0
            for _ in 0..<150 { m.add(host: t, frames: 480); m.add(host: t, frames: 480); t += 0.02 }      // two callbacks per wake-up, one stamp
            let e = m.estimate(lastSeconds: 1.0)
            c.check("meter: two callbacks with the SAME stamp count as one bigger callback (960 frames per 20 ms = 48 kHz, not 24 kHz)",
                    e != nil && abs(e!.rate / 48000 - 1) < 0.003, e.map { String(format: "%.0f Hz", $0.rate) } ?? "nil")
        }
        let hfp = looks(rate: 24000, frames: 480, seconds: 20, assumed: 48000) { r, _ in (r.next() - 0.5) * 0.008 }
        c.check("meter: the defect itself through the same noise: 24 kHz hands-free callbacks with +-4 ms stamp noise are within 3 % of 24 kHz and EVERY look says mismatch",
                hfp.looks > 20 && hfp.worst < 0.03 && hfp.mismatches == hfp.looks, text(hfp))
    }

    /// Deterministic noise for the robustness checks (no system RNG: a failure must be reproducible).
    private struct NoiseRNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFFFF) / Double(0x1000000)
        }
    }

    private static func testRateJudge(_ c: Checker) {
        print("-- RateJudge: measured rate -> decision (snap to standard rates, 3 % / 10 % thresholds, HAL hints)")
        typealias J = CaptureHAL.RateJudge
        c.check("snap: 23950 -> 24000, 44080 -> 44100, 47000 -> 48000, 16100 -> 16000, 95500 -> 96000 (standard)",
                J.snap(23950) == (24000, true) && J.snap(44080) == (44100, true) && J.snap(47000) == (48000, true) && J.snap(16100) == (16000, true) && J.snap(95500) == (96000, true))
        c.check("snap: 31000 and 8500 are not standard rates and stay as measured", J.snap(31000) == (31000, false) && J.snap(8500) == (8500, false))
        func v(_ assumed: Double, _ measured: Double, hints: [(name: String, rate: Double)] = []) -> J.Verdict? { J.verdict(assumed: assumed, measured: measured, hints: { hints }) }
        let half = v(48000, 23990)
        c.check("48000 assumed, 23990 measured -> mismatch, resample from 24000", half?.mismatch == true && half?.rate == 24000, "\(String(describing: half))")
        let cd = v(48000, 44100.5)
        c.check("48000 assumed, 44100 measured (8 %) -> mismatch, resample from 44100 (8 % is below the 10 % line, the standard-rate rule catches it)",
                cd?.mismatch == true && cd?.rate == 44100, "\(String(describing: cd))")
        c.check("16 kHz measured vs 48000 assumed -> mismatch 16000", v(48000, 15980)?.mismatch == true && v(48000, 15980)?.rate == 16000)
        c.check("48000 assumed, 47900 / 47000 / 48100 measured -> same rate, no mismatch", [47900.0, 47000, 48100].allSatisfy { v(48000, $0)?.mismatch == false && v(48000, $0)?.rate == 48000 })
        c.check("48000 assumed, 46000 measured (4 % off, no standard rate there) -> not claimed as a mismatch", v(48000, 46000)?.mismatch == false)
        let odd = v(48000, 31000)
        c.check("48000 assumed, 31000 measured (35 % off, not a standard rate) -> mismatch, resample from the measured 31000",
                odd?.mismatch == true && odd?.rate == 31000 && odd!.how.contains("not a standard rate"), "\(String(describing: odd))")
        c.check("24000 assumed (the device format is right), 48000 measured -> mismatch the other way", v(24000, 48000)?.mismatch == true && v(24000, 48000)?.rate == 48000)
        c.check("implausible measurements (2 kHz, 4.8 MHz, NaN, infinity) give no verdict", v(48000, 2000) == nil && v(48000, 4.8e6) == nil && v(48000, .nan) == nil && v(48000, .infinity) == nil)
        let hinted = v(48000, 23700, hints: [(name: "aggregate nominal rate", rate: 24000)])
        c.check("a HAL figure that agrees with the measurement is adopted and named", hinted?.rate == 24000 && hinted!.how.contains("aggregate nominal rate"), "\(String(describing: hinted))")
        let ignored = v(48000, 24000, hints: [(name: "default output nominal rate", rate: 22050), (name: "x", rate: 0)])
        c.check("a HAL figure that disagrees with the measurement is ignored", ignored?.rate == 24000 && !(ignored?.how.contains("default output") ?? true), "\(String(describing: ignored))")
        var hintCalls = 0
        _ = J.verdict(assumed: 48000, measured: 48010, hints: { hintCalls += 1; return [] })
        c.check("the HAL is not asked for hints when there is no mismatch", hintCalls == 0)
    }

    // MARK: gap pattern detector (Recorder, SPEC 15 wave E)

    private static func testGapPatternDetector(_ c: Checker) {
        print("-- GapPatternDetector: sustained equal gap fills = a rate problem, ONE verdict, not 28 log lines")
        typealias F = GapPatternDetector.Fill
        func run(_ fills: [F]) -> (problems: [(index: Int, p: GapPatternDetector.RateProblem)], logged: Int, folded: Int) {
            var d = GapPatternDetector()
            var problems: [(Int, GapPatternDetector.RateProblem)] = []
            var logged = 0
            for (i, f) in fills.enumerated() {
                let o = d.add(f)
                if o.logIndividually { logged += 1 }
                if let p = o.problem { problems.append((i, p)) }
            }
            return (problems, logged, d.folded)
        }
        // the AirPods test: 28 fills of 0.21 s every 0.42 s, each after 0.21 s of audio (24 kHz audio labelled 48 kHz)
        let mic = (0..<28).map { F(at: 10 + Double($0) * 0.42, gapSeconds: 0.21, audioBefore: 0.21) }
        let r = run(mic)
        c.check("AirPods pattern (28 x 0.21 s every 0.42 s): exactly ONE rate verdict, at the 4th fill",
                r.problems.count == 1 && r.problems[0].index == 3, "verdicts at \(r.problems.map { $0.index })")
        if let p = r.problems.first?.p {
            c.check("... delivered/expected ratio 0.5, gap 0.21 s, period 0.42 s", abs(p.deliveredRatio - 0.5) < 0.02 && abs(p.gapSeconds - 0.21) < 0.01 && abs(p.periodSeconds - 0.42) < 0.01,
                    "ratio \(p.deliveredRatio) gap \(p.gapSeconds) period \(p.periodSeconds) count \(p.count)")
        }
        c.check("... only the first two fills get a log line of their own (26 folded, not 28 lines)", r.logged == 2 && r.folded == 26, "logged \(r.logged) folded \(r.folded)")
        // 44.1 kHz audio labelled 48 kHz: 0.2 s every ~2.47 s
        let cd = (0..<8).map { F(at: 3 + Double($0) * 2.47, gapSeconds: 0.2, audioBefore: 2.27) }
        let rc = run(cd)
        c.check("44.1 kHz in a 48 kHz file (0.2 s every 2.47 s): classified too, ratio ~0.92",
                rc.problems.count == 1 && abs(rc.problems[0].p.deliveredRatio - 0.919) < 0.02, "\(rc.problems.map { ($0.index, $0.p.deliveredRatio) })")
        // real outages and irregular dropouts are not a rate problem
        c.check("one 1.5 s outage (device change): no verdict, logged", run([F(at: 5, gapSeconds: 1.5, audioBefore: 5)]).problems.isEmpty && run([F(at: 5, gapSeconds: 1.5, audioBefore: 5)]).logged == 1)
        let irregular = run([F(at: 1.1, gapSeconds: 0.25, audioBefore: 1.1), F(at: 3.5, gapSeconds: 0.9, audioBefore: 2.2),
                             F(at: 4.0, gapSeconds: 0.3, audioBefore: 0.4), F(at: 9.2, gapSeconds: 0.7, audioBefore: 5.0),
                             F(at: 9.9, gapSeconds: 0.22, audioBefore: 0.5)])
        c.check("irregular dropouts (different sizes and spacing): no verdict", irregular.problems.isEmpty, "\(irregular.problems.map { $0.index })")
        c.check("three equal fills are not yet a pattern (needs 4)", run(Array(mic.prefix(3))).problems.isEmpty)
        let withOutage = mic.prefix(3) + [F(at: 12, gapSeconds: 1.2, audioBefore: 0.3)] + mic.dropFirst(5).prefix(3).map { F(at: $0.at + 3, gapSeconds: $0.gapSeconds, audioBefore: $0.audioBefore) }
        c.check("an outage in the middle (>= 1 s) restarts the count: no verdict from 3 + outage + 3", run(Array(withOutage)).problems.isEmpty)
        // a second episode after a quiet period is classified again (the engine may be asked once more); the same episode never twice
        let again = mic + (0..<8).map { F(at: 10 + 28 * 0.42 + 30 + Double($0) * 0.42, gapSeconds: 0.21, audioBefore: 0.21) }
        let ra = run(again)
        c.check("a new episode after 30 quiet seconds gets its own verdict (2 in total), the first one is not repeated", ra.problems.count == 2 && ra.problems[1].index == 28 + 3, "\(ra.problems.map { $0.index })")
        let dropouts = run((0..<10).map { F(at: 2 + Double($0) * 0.5, gapSeconds: 0.25, audioBefore: 0.25) })
        c.check("regular dropouts (0.25 s every 0.5 s) look the same as a rate problem to the recorder: classified; the engine overrules it when the IOProc rate is right",
                dropouts.problems.count == 1)
    }

    // MARK: Bluetooth tap host policy (fake device descriptions, no device)

    private static func testBluetoothHostPolicy(_ c: Checker) {
        print("-- tap host policy by transport type (fake device descriptions): Bluetooth is clocked by the built-in output")
        typealias D = CaptureHAL.DeviceDescription
        func candidates(_ d: D, builtIn: Bool = true) -> [TapHost] {
            TapHostPolicy.candidates(TapHostPolicy.environment(defaultOutput: d, builtInDistinctFromDefault: builtIn))
        }
        let speakers = D(name: "MacBook Pro Speakers", transportType: kAudioDeviceTransportTypeBuiltIn, hasInputStreams: false)
        let airpods = D(name: "AirPods Pro", transportType: kAudioDeviceTransportTypeBluetooth, hasInputStreams: false)          // output device: no input streams
        let airpodsLE = D(name: "LE Buds", transportType: kAudioDeviceTransportTypeBluetoothLE, hasInputStreams: false)
        let btHeadset = D(name: "BT Headset", transportType: kAudioDeviceTransportTypeBluetooth, hasInputStreams: true)
        let usbHeadset = D(name: "USB Speakerphone", transportType: kAudioDeviceTransportTypeUSB, hasInputStreams: true)
        let usbDac = D(name: "USB DAC", transportType: kAudioDeviceTransportTypeUSB, hasInputStreams: false)
        let hdmi = D(name: "LG HDR", transportType: kAudioDeviceTransportTypeHDMI, hasInputStreams: false)
        let unknown = D(name: "Mystery", transportType: nil, hasInputStreams: false)

        c.check("transport helpers: 'blue' and 'blea' are Bluetooth, nothing else is",
                airpods.isBluetooth && airpodsLE.isBluetooth && btHeadset.isBluetooth && !speakers.isBluetooth && !usbHeadset.isBluetooth && !unknown.isBluetooth)
        c.check("transport names for the log: bluetooth, bluetooth-le, built-in, usb, unknown",
                airpods.transportName == "bluetooth" && airpodsLE.transportName == "bluetooth-le" && speakers.transportName == "built-in"
                && usbDac.transportName == "usb" && unknown.transportName == "unknown")
        c.check("AirPods (Bluetooth, NO input streams on the output device): built-in output clocks the tap first, then the AirPods themselves, then tap-only",
                candidates(airpods) == [.builtInOutput, .defaultOutput, .tapOnly], "\(candidates(airpods))")
        c.check("Bluetooth LE output: the same", candidates(airpodsLE) == [.builtInOutput, .defaultOutput, .tapOnly])
        c.check("Bluetooth headset that also shows input streams: the same Bluetooth order", candidates(btHeadset) == [.builtInOutput, .defaultOutput, .tapOnly])
        c.check("Bluetooth output and no built-in output to borrow a clock from: its own clock, then tap-only (the delivered rate is measured)",
                candidates(airpods, builtIn: false) == [.defaultOutput, .tapOnly])
        c.check("MacBook speakers, HDMI, USB DAC and an unreadable transport: just the default output (unchanged)",
                candidates(speakers, builtIn: false) == [.defaultOutput] && candidates(hdmi) == [.defaultOutput] && candidates(usbDac) == [.defaultOutput] && candidates(unknown) == [.defaultOutput])
        c.check("USB speakerphone (input streams, not Bluetooth): built-in, tap-only, device (unchanged order)", candidates(usbHeadset) == [.builtInOutput, .tapOnly, .defaultOutput])
        c.check("the AirPods are never the FIRST choice (their rate follows the Bluetooth profile)", candidates(airpods).first == .builtInOutput)

        let btEnv = TapHostPolicy.environment(defaultOutput: airpods, builtInDistinctFromDefault: true)
        let why = TapHostPolicy.explain(btEnv, transport: airpods.transportName)
        c.check("the log explains why: Bluetooth, hands-free rate, built-in output clocks the tap, global tap wherever routed",
                why.contains("Bluetooth") && why.contains("hands-free") && why.contains("built-in output clocks the tap") && why.contains("wherever it is routed"), why)
        c.check("the explanation for a plain output says it clocks the tap itself",
                TapHostPolicy.explain(TapHostPolicy.environment(defaultOutput: speakers, builtInDistinctFromDefault: false), transport: "built-in").contains("clocks the tap itself"))
        c.check("MC_TAP_HOST overrides still parse (builtin / default / tap-only / taponly) and win over the policy",
                TapHostPolicy.parseOverride("builtin") == .builtInOutput && TapHostPolicy.parseOverride("default") == .defaultOutput
                && TapHostPolicy.parseOverride("tap-only") == .tapOnly && TapHostPolicy.parseOverride("TapOnly") == .tapOnly)

        // the alternation after a failed heal still walks the Bluetooth list: built-in -> AirPods (known to deliver audio) -> tap-only -> built-in
        let list = candidates(airpods)
        var ch = TapHostChooser()
        let a = ch.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 0, remembered: nil)
        c.check("Bluetooth, first build: built-in output, 'first choice for this output device'", a.host == .builtInOutput && a.why.contains("first choice"), "\(a)")
        let b = ch.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 1, remembered: nil)
        c.check("silent for the quick-heal period -> the AirPods' own clock (the configuration that delivered audio on the AirPods test)",
                b.host == .defaultOutput && b.why.contains("built-in-output delivered only digital silence"), "\(b)")
        let d = ch.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 2, remembered: nil)
        c.check("silent again -> tap-only; once more -> back to the built-in output (alternation, never a dead end)",
                d.host == .tapOnly && ch.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 3, remembered: nil).host == .builtInOutput, "\(d)")
        var m = TapHostChooser()
        let remembered = m.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 0, remembered: .defaultOutput)
        c.check("a strategy that delivered audio on these AirPods earlier in the run is used first (remembered per device)", remembered.host == .defaultOutput && remembered.why.contains("delivered audio earlier"), "\(remembered)")

        // a rate-like gap pattern that nothing explained (the engine's last resort): ONE new graph per output device; an unproven strategy
        // with alternatives moves on, a proven one or a single / pinned candidate is only re-created
        var trouble = TapHostChooser()
        c.check("rate trouble before any graph exists: nothing to re-create", !trouble.noteRateTrouble())
        _ = trouble.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 0, remembered: nil)
        c.check("rate trouble on the unproven first strategy: a new graph is wanted", trouble.noteRateTrouble())
        let moved = trouble.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 0, remembered: nil)
        c.check("... with the NEXT strategy (the AirPods' own clock), reason given", moved.host == .defaultOutput && moved.why.contains("periodic gap pattern"), "\(moved)")
        c.check("... and only once per output device (no loop)", !trouble.noteRateTrouble()
                && trouble.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 0, remembered: nil).host == .defaultOutput)
        var provenTrouble = TapHostChooser()
        _ = provenTrouble.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 0, remembered: .builtInOutput)
        let kept = provenTrouble.noteRateTrouble() ? provenTrouble.choose(deviceUID: "AA:BB:output", candidates: list, healCount: 0, remembered: .builtInOutput) : nil
        c.check("rate trouble on a strategy that delivered audio: re-created with the SAME strategy", kept?.host == .builtInOutput, "\(String(describing: kept))")
        var pinned = TapHostChooser()
        _ = pinned.choose(deviceUID: "AA:BB:output", candidates: [.defaultOutput], healCount: 0, remembered: nil, forced: true)
        let pinnedAgain = pinned.noteRateTrouble() ? pinned.choose(deviceUID: "AA:BB:output", candidates: [.defaultOutput], healCount: 0, remembered: nil, forced: true) : nil
        c.check("a pinned (MC_TAP_HOST) or single candidate is never switched", pinnedAgain?.host == .defaultOutput)
        _ = trouble.choose(deviceUID: "other-device", candidates: list, healCount: 0, remembered: nil)
        c.check("another output device gets its own one-time allowance", trouble.noteRateTrouble())

        // read-only look at the real default output (information only; the policy runs on what the HAL says)
        if let out = CaptureHAL.defaultDevice(input: false) {
            let real = CaptureHAL.describeDevice(out)
            print("  info  default output: '\(real.name)' transport \(real.transportName), input streams \(real.hasInputStreams) -> candidates \(candidates(real).map { $0.rawValue })")
            c.check("describeDevice reads the default output (non-empty name)", !real.name.isEmpty)
        } else {
            print("  SKIP  no default output device here")
        }
    }

    // MARK: rate mismatch end to end (fake HAL device -> HALCapture -> Recorder -> WAV)

    /// A simulated HAL device that delivers a 1 kHz tone at its EFFECTIVE rate (a schedule over time: the Bluetooth profile
    /// switches) while the rate it ADVERTISES (`Opened.nativeRate`, the tap format) stays what the scenario says: the AirPods
    /// defect (24 kHz audio, tap format 48000 Hz). It runs through the real HALCapture engine on the fake backend, with host
    /// stamps taken from the device clock; a "restart" is a stall of the callbacks plus a changed environment signature (the
    /// engine's own rebuild path).
    private final class RateScenarioSource: CaptureTrackSource {
        struct Phase { var from: Double; var rate: Double }              // seconds after start()
        struct Restart { var at: Double; var stall: Double; var rebuild = true }   // rebuild: the environment signature changes too (a profile switch); false = a plain dropout

        let sampleRate = 48000.0
        let sourceLabel = "global-tap"
        var deviceName = "Fake Bluetooth Output"
        var onSamples: (([Float], UInt64) -> Void)?
        var onWarning: ((String) -> Void)?
        var onDeviceChange: ((String) -> Void)?

        private let backend = FakeBackend()
        private var engine: HALCapture?
        private let phases: [Phase]
        private let restarts: [Restart]
        private let claimedRate: Double
        private let measure: Bool
        private let honorHint: Bool
        private let feederQueue = DispatchQueue(label: "fake.rate.feeder")
        private var feeder: DispatchSourceTimer?
        private let lock = NSLock()
        private var signature = "A"
        private var hintsReceived = 0
        private var opensDone = 0
        private var unresolvedCalls = 0
        // feeder queue only
        private var startSec = 0.0
        private var emittedSeconds = 0.0
        private var tonePhase = 0.0
        private var restartsDone = 0
        private var stallEnd = 0.0

        init(phases: [Phase], restarts: [Restart] = [], claimed: Double, measure: Bool = true, honorHint: Bool = true) {
            self.phases = phases
            self.restarts = restarts
            self.claimedRate = claimed
            self.measure = measure
            self.honorHint = honorHint
        }

        var hints: Int { lock.lock(); defer { lock.unlock() }; return hintsReceived }
        var opens: Int { lock.lock(); defer { lock.unlock() }; return opensDone }
        /// How often the engine reported a rate-like gap pattern it could not explain (the owner's hook); the first call asks for a new graph.
        var unresolved: Int { lock.lock(); defer { lock.unlock() }; return unresolvedCalls }
        var effectiveRate: Double { engine?.effectiveRate ?? 0 }
        var rateChanges: Int { engine?.rateChangeCount ?? 0 }
        /// Seconds of device timeline emitted (valid after stop()).
        var emitted: Double { feederQueue.sync { emittedSeconds } }

        func start() throws {
            var timing = HALCapture.Timing()
            timing.tick = 0.2; timing.debounce = 0.1
            timing.rateMeasurement = measure
            let e = HALCapture(label: "fake rate device", targetRate: 48000, systemTriggers: [], healZeroRun: false, backend: backend, timing: timing) { [weak self] in
                guard let self = self else { throw RecorderError.failed("fake device released") }
                self.lock.lock(); let sig = self.signature; self.opensDone += 1; self.lock.unlock()
                return HALCapture.Opened(ioDevice: AudioObjectID(kAudioObjectUnknown), deviceName: self.deviceName, nativeRate: self.claimedRate,
                                         kind: .float32, maxChannels: 2, tailChannels: nil, disableOutputStreams: false, watched: [],
                                         signature: sig, currentSignature: { [weak self] in
                                             guard let self = self else { return "gone" }
                                             self.lock.lock(); defer { self.lock.unlock() }
                                             return self.signature },
                                         cleanup: {}, rateHints: { [] }, rateSourceName: "tap format",
                                         onRateProblemUnresolved: { [weak self] in
                                             guard let self = self else { return false }
                                             self.lock.lock(); defer { self.lock.unlock() }
                                             self.unresolvedCalls += 1
                                             return self.unresolvedCalls == 1 })      // the owner (SystemAudioTap) asks for ONE new graph
            }
            e.handler = { [weak self] samples, host in self?.onSamples?(samples, host) }
            e.onWarning = { [weak self] message in self?.onWarning?(message) }
            e.onDeviceChange = { [weak self] name in self?.onDeviceChange?(name) }
            engine = e
            try e.start()
            feederQueue.sync { startSec = CaptureHAL.Clock.seconds(CaptureHAL.Clock.now()) }
            let t = DispatchSource.makeTimerSource(queue: feederQueue)
            t.schedule(deadline: .now() + 0.01, repeating: 0.01, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            feeder = t
        }

        func stop() {
            feeder?.cancel()
            feeder = nil
            feederQueue.sync {}
            engine?.stop()                                                // delivers whatever is held or queued
        }

        func timelineRateSuspected(deliveredRatio: Double) {
            lock.lock(); hintsReceived += 1; lock.unlock()
            if honorHint { engine?.rateSuspected(deliveredRatio: deliveredRatio) }
        }

        private func rate(at t: Double) -> Double {
            var r = phases[0].rate
            for p in phases where p.from <= t + 1e-9 { r = p.rate }
            return r
        }

        private func nextBoundary(after t: Double) -> Double {
            phases.map { $0.from }.filter { $0 > t + 1e-9 }.min() ?? .infinity
        }

        private func tick() {
            let t = CaptureHAL.Clock.seconds(CaptureHAL.Clock.now()) - startSec
            if restartsDone < restarts.count, t >= restarts[restartsDone].at {
                let r = restarts[restartsDone]
                restartsDone += 1
                stallEnd = r.at + r.stall
                if r.rebuild { lock.lock(); signature = "restart \(restartsDone)"; lock.unlock() }
            }
            if t < stallEnd { return }                                     // the device is restarting: no callbacks
            var cursor = max(emittedSeconds, stallEnd)
            while cursor < t {
                let r = rate(at: cursor)
                let boundary = nextBoundary(after: cursor)
                var n = Int((min(t, boundary) - cursor) * r)
                if n <= 0 {
                    if boundary <= t { cursor = boundary; continue }       // less than one frame left before the switch
                    break
                }
                n = min(n, 1024)
                var buffer = [Float](repeating: 0, count: n)
                let step = 2 * Double.pi * 1000 / r                        // the tone is 1 kHz in the real world at every rate
                for i in 0..<n {
                    buffer[i] = 0.5 * Float(sin(tonePhase))
                    tonePhase += step
                    if tonePhase > 2 * Double.pi { tonePhase -= 2 * Double.pi }
                }
                backend.deliverMono(buffer, host: CaptureHAL.Clock.ticks(seconds: startSec + cursor))
                cursor += Double(n) / r
            }
            emittedSeconds = cursor
        }
    }

    private struct RateRun {
        var samples: [Float] = []
        var fileSeconds = 0.0
        var emitted = 0.0
        var offset = 0.0
        var warnings: [String] = []
        var effectiveRate = 0.0
        var rateChanges = 0
        var hints = 0
        var opens = 0
        var unresolved = 0
        var remoteGaps = 0
        var headerRate = 0              // sample rate in the WAV header of remote.wav
        var jsonRate = 0                // tracks.remote.sample_rate of session.json
        var headerConsistent = false
        var ok = false
    }

    private static func runRateScenario(name: String, phases: [(from: Double, rate: Double)], restarts: [(at: Double, stall: Double, rebuild: Bool)] = [],
                                        claimed: Double, measure: Bool = true, honorHint: Bool = true, seconds: Double,
                                        config: AppConfig, dir: URL) -> RateRun {
        let sessionDir = dir.appendingPathComponent("2026-10-10_1200_rate_\(name)")
        try? FileManager.default.removeItem(at: sessionDir)
        let remote = RateScenarioSource(phases: phases.map { .init(from: $0.from, rate: $0.rate) }, restarts: restarts.map { .init(at: $0.at, stall: $0.stall, rebuild: $0.rebuild) },
                                        claimed: claimed, measure: measure, honorHint: honorHint)
        let mic = SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200, amplitude: 0.05)
        let rec = Recorder(sessionDir: sessionDir, signal: PlatformSignal(platform: .manual, inCall: true), config: config, remote: { remote }, mic: { mic })
        do { try rec.start() } catch { return RateRun() }
        Thread.sleep(forTimeInterval: seconds)
        _ = rec.stop(reason: .manual)
        var run = RateRun()
        guard let wav = readSamples(sessionDir.appendingPathComponent("remote.wav")) else { return run }
        run.samples = wav.samples
        run.headerRate = wav.info.sampleRate
        run.headerConsistent = wav.info.headerIsConsistent
        run.fileSeconds = wav.info.seconds
        run.emitted = remote.emitted
        run.effectiveRate = remote.effectiveRate
        run.rateChanges = remote.rateChanges
        run.hints = remote.hints
        run.opens = remote.opens
        run.unresolved = remote.unresolved
        run.remoteGaps = rec.gapCounts.remote
        if let obj = (try? Data(contentsOf: sessionDir.appendingPathComponent("session.json"))).flatMap({ (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }) {
            run.warnings = (obj["warnings"] as? [String]) ?? []
            run.offset = ((obj["tracks"] as? [String: Any])?["remote"] as? [String: Any])?["start_offset_sec"] as? Double ?? 0
            run.jsonRate = ((obj["tracks"] as? [String: Any])?["remote"] as? [String: Any])?["sample_rate"] as? Int ?? 0
        }
        run.ok = true
        return run
    }

    /// Upward zero crossings per second inside [from, to) seconds of the file (a pure tone: its frequency).
    private static func toneHz(_ s: [Float], from: Double, to: Double, rate: Int = 48000) -> Double {
        let a = max(0, Int(from * Double(rate))), b = min(s.count, Int(to * Double(rate)))
        guard b > a else { return 0 }
        return Double(upwardZeroCrossings(s[a..<b])) / (Double(b - a) / Double(rate))
    }

    /// Runs of exact digital zeros of at least `minLength` frames (a 1 kHz tone of amplitude 0.5 never has one), as (start, length) in seconds.
    private static func zeroRuns(_ s: [Float], minLength: Int, rate: Int = 48000) -> [(start: Double, length: Double)] {
        var out: [(Double, Double)] = []
        var i = 0
        while i < s.count {
            if s[i] == 0 {
                var j = i
                while j < s.count && s[j] == 0 { j += 1 }
                if j - i >= minLength { out.append((Double(i) / Double(rate), Double(j - i) / Double(rate))) }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    /// Frequency of the first burst of tone (>= 0.1 s long, ended by >= 1 ms of exact zeros) in the file: the pitch of the audio
    /// that really got written, independent of the silence around it.
    private static func firstBurstHz(_ s: [Float], rate: Int = 48000) -> Double {
        var i = 0
        while i < s.count {
            guard abs(s[i]) > 0.05 else { i += 1; continue }
            var j = i, zeros = 0
            while j < s.count && zeros < 48 { zeros = s[j] == 0 ? zeros + 1 : 0; j += 1 }
            let end = j - zeros
            if end - i >= rate / 10 { return Double(upwardZeroCrossings(s[i..<end])) / (Double(end - i) / Double(rate)) }
            i = j
        }
        return 0
    }

    private static func testRateMismatchScenarios(_ c: Checker, config: AppConfig, dir: URL) {
        print("-- rate mismatch end to end: a fake HAL device delivers a 1 kHz tone at its effective rate while its format says 48000 Hz (11 scenarios in parallel, up to 10 s)")
        struct Scenario { var name: String; var phases: [(from: Double, rate: Double)]; var restarts: [(at: Double, stall: Double, rebuild: Bool)] = []
                          var claimed = 48000.0; var measure = true; var honorHint = true; var seconds: Double }
        let scenarios = [
            Scenario(name: "24k_in_48k", phases: [(0, 24000)], seconds: 6.5),
            Scenario(name: "16k_in_48k", phases: [(0, 16000)], seconds: 6.5),
            Scenario(name: "44k1_in_48k", phases: [(0, 44100)], seconds: 6.5),
            Scenario(name: "healthy_48k", phases: [(0, 48000)], seconds: 6.5),
            Scenario(name: "consistent_24k", phases: [(0, 24000)], claimed: 24000, seconds: 6.5),
            Scenario(name: "switch_restart", phases: [(0, 48000), (3.0, 24000), (6.5, 48000)], restarts: [(3.0, 0.3, true), (6.5, 0.3, true)], seconds: 10),
            Scenario(name: "switch_silent", phases: [(0, 48000), (3.0, 24000)], seconds: 8),
            Scenario(name: "defect_unfixed", phases: [(0, 24000)], measure: false, honorHint: false, seconds: 5),
            Scenario(name: "recorder_rescue", phases: [(0, 24000)], measure: false, seconds: 7),
            // a device at the RIGHT rate that drops 0.25 s every 0.5 s (a bad cable): the same gap pattern, but the IOProc rate is fine
            // 31 kHz audio in a 48 kHz format with the measurement off: a rate-like pattern no standard rate explains
            Scenario(name: "unexplained_31k", phases: [(0, 31000)], measure: false, seconds: 5),
            Scenario(name: "dropouts_48k", phases: [(0, 48000)], restarts: (0..<9).map { (1.0 + Double($0) * 0.5, 0.25, false) }, seconds: 7),
        ]
        let group = DispatchGroup()
        let lock = NSLock()
        var runs: [String: RateRun] = [:]
        for sc in scenarios {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let r = runRateScenario(name: sc.name, phases: sc.phases, restarts: sc.restarts, claimed: sc.claimed, measure: sc.measure,
                                        honorHint: sc.honorHint, seconds: sc.seconds, config: config, dir: dir)
                lock.lock(); runs[sc.name] = r; lock.unlock()
                group.leave()
            }
        }
        group.wait()

        func durationOK(_ r: RateRun) -> Bool { r.emitted > 1 && abs(r.fileSeconds - r.emitted) / r.emitted < 0.01 }
        func durationText(_ r: RateRun) -> String { String(format: "file %.3f s, device timeline %.3f s (%.2f %%)", r.fileSeconds, r.emitted, (r.fileSeconds / max(r.emitted, 1e-9) - 1) * 100) }
        func rateWarnings(_ r: RateRun) -> [String] { r.warnings.filter { $0.contains("effective rate") } }
        func hz(_ r: RateRun, _ from: Double, _ to: Double) -> String { String(format: "%.0f", toneHz(r.samples, from: from, to: to)) }
        func toneOK(_ r: RateRun, _ windows: [(Double, Double)]) -> Bool { windows.allSatisfy { abs(toneHz(r.samples, from: $0.0, to: $0.1) / 1000 - 1) < 0.01 } }
        func windowsText(_ r: RateRun, _ windows: [(Double, Double)]) -> String { windows.map { hz(r, $0.0, $0.1) + " Hz" }.joined(separator: ", ") }

        // 24 / 16 / 44.1 kHz audio in a 48000 Hz format: the AirPods defect, fixed
        for (name, eff, win) in [("24k_in_48k", 24000, "24000"), ("16k_in_48k", 16000, "16000"), ("44k1_in_48k", 44100, "44100")] {
            guard let r = runs[name], r.ok else { c.check("\(name): scenario ran", false); continue }
            let tone = [(0.5, 1.5), (2.5, 3.5), (4.5, 5.5)]
            let zeros = zeroRuns(Array(r.samples.dropFirst(4800)), minLength: 480)
            let warns = rateWarnings(r)
            c.check("\(eff) Hz audio, format 48000 Hz: the recorded track holds a 1 kHz tone (not 2 kHz / 3 kHz) in every second I look at",
                    toneOK(r, tone), windowsText(r, tone))
            c.check("\(eff) Hz: duration within 1 % of the device timeline", durationOK(r), durationText(r))
            c.check("\(eff) Hz: no periodic zero runs, no gap fill at all (the mismatch is converted, not zero-filled)", zeros.isEmpty && r.remoteGaps == 0,
                    "zero runs \(zeros.count), gap fills \(r.remoteGaps)")
            c.check("\(eff) Hz: exactly one rate warning in session.json, with the documented wording",
                    warns.count == 1 && warns[0].contains("system audio: effective rate \(win) Hz differs from tap format 48000 Hz: resampling from \(win)"), "\(warns)")
            c.check("\(eff) Hz: the engine reports the effective rate; the recorder never needed to ask (no gap pattern)", abs(r.effectiveRate - Double(eff)) < 1 && r.hints == 0,
                    "effective \(r.effectiveRate) hints \(r.hints)")
            c.check("\(eff) Hz: start offset not delayed by the verification (first sample's own host time)", r.offset >= 0 && r.offset < 0.45, "offset \(r.offset)")
        }
        // whatever rate the device was measured at, the FILE rate is the recorder's fixed one: WAV header == session.json == 48000, header sizes consistent
        do {
            let names = ["24k_in_48k", "16k_in_48k", "44k1_in_48k", "healthy_48k", "consistent_24k", "switch_restart", "switch_silent"]
            let bad = names.filter { n in
                guard let r = runs[n], r.ok else { return true }
                return !(r.headerRate == 48000 && r.jsonRate == 48000 && r.headerConsistent)
            }
            c.check("every scenario (24 / 16 / 44.1 kHz in a 48 kHz format, healthy, consistent 24 kHz, both switches): WAV header rate == session.json sample_rate == 48000 and the header sizes match the file",
                    bad.isEmpty, "inconsistent: \(bad)")
        }
        // no mismatch: unchanged behaviour
        if let r = runs["healthy_48k"], r.ok {
            let tone = [(0.5, 1.5), (3, 4), (5, 6)]
            c.check("no mismatch (48000 Hz device, 48000 Hz format): 1 kHz tone, duration within 1 %, no gap, no rate warning, nothing adopted",
                    toneOK(r, tone) && durationOK(r) && r.remoteGaps == 0 && rateWarnings(r).isEmpty && r.rateChanges == 0 && abs(r.effectiveRate - 48000) < 1
                    && zeroRuns(Array(r.samples.dropFirst(4800)), minLength: 480).isEmpty,
                    "\(windowsText(r, tone)); \(durationText(r)); gaps \(r.remoteGaps); warnings \(rateWarnings(r)); changes \(r.rateChanges)")
        } else { c.check("healthy_48k: scenario ran", false) }
        if let r = runs["consistent_24k"], r.ok {
            let tone = [(0.5, 1.5), (3, 4), (5, 6)]
            c.check("a device whose format is right (24000 Hz, format 24000 Hz): converted through the configured resampler as before, no warning, tone and duration right",
                    toneOK(r, tone) && durationOK(r) && r.remoteGaps == 0 && rateWarnings(r).isEmpty && r.rateChanges == 0,
                    "\(windowsText(r, tone)); \(durationText(r)); warnings \(rateWarnings(r)); changes \(r.rateChanges)")
        } else { c.check("consistent_24k: scenario ran", false) }

        // mid-session switch 48k -> 24k -> 48k, device restarts at each switch (profile switch: IO stops, the environment signature changes)
        if let r = runs["switch_restart"], r.ok {
            let tone = [(1.0, 2.0), (5.0, 6.0), (8.5, 9.5)]
            let zeros = zeroRuns(Array(r.samples.dropFirst(4800)), minLength: 480)
            c.check("48k -> 24k -> 48k with a restart at each switch: 1 kHz tone before, between and after the switches", toneOK(r, tone), windowsText(r, tone))
            c.check("... duration within 1 % of the device timeline (the timeline is continuous)", durationOK(r), durationText(r))
            c.check("... the only zero runs are the two restart stalls (<= 0.5 s each, near 3.0 s and 6.5 s), no periodic zeros",
                    zeros.count <= 2 && zeros.allSatisfy { $0.length < 0.5 && (abs($0.start - 3.0) < 0.5 || abs($0.start - 6.5) < 0.5) },
                    "zero runs \(zeros.map { String(format: "%.2f s at %.2f s", $0.length, $0.start) })")
            c.check("... ONE rate warning (48000 -> 24000); the return to the format rate is only logged", rateWarnings(r).count == 1 && rateWarnings(r)[0].contains("resampling from 24000"), "\(rateWarnings(r))")
        } else { c.check("switch_restart: scenario ran", false) }

        // the switch happens with NO notification at all (no signature change, no stall): the continuous measurement notices it
        if let r = runs["switch_silent"], r.ok {
            let tone = [(1.0, 2.0), (5.3, 6.3), (6.6, 7.6)]
            let zeros = zeroRuns(Array(r.samples.dropFirst(4800)), minLength: 480)
            c.check("48k -> 24k with no notification: after the re-measurement (<= ~2.3 s) the tone is 1 kHz again (before, and from 5.3 s on)", toneOK(r, tone), windowsText(r, tone))
            c.check("... duration within 1 % + the recorder's 0.2 s gap tolerance of the device timeline (the transition may leave the file up to 0.2 s short, "
                    + "the recorder only pads gaps bigger than that)", abs(r.fileSeconds - r.emitted) <= 0.01 * r.emitted + Recorder.gapTolerance, durationText(r))
            c.check("... zero runs only inside the transition (3.0 to 5.3 s), never after it", zeros.allSatisfy { $0.start < 5.3 }, "\(zeros.map { String(format: "%.2f s at %.2f s", $0.length, $0.start) })")
            c.check("... one rate warning; the engine now uses 24000 Hz", rateWarnings(r).count == 1 && abs(r.effectiveRate - 24000) < 1, "\(rateWarnings(r)) effective \(r.effectiveRate)")
        } else { c.check("switch_silent: scenario ran", false) }

        // the defect itself, reproduced: no measurement, the recorder's hint ignored (what the app did before)
        if let r = runs["defect_unfixed"], r.ok {
            let zeros = zeroRuns(Array(r.samples.dropFirst(4800)), minLength: 480)
            let burst = firstBurstHz(r.samples)
            c.check("control: WITHOUT the rate measurement the defect reproduces: the tone is written an octave up (2 kHz) ...", abs(burst / 2000 - 1) < 0.03, String(format: "%.0f Hz", burst))
            c.check("... with a periodic zero run every ~0.4 s (>= 6 in 5 s) and a gap fill each time", zeros.count >= 6 && r.remoteGaps >= 6, "zero runs \(zeros.count), gap fills \(r.remoteGaps)")
            c.check("... the recorder classifies the pattern: ONE sample-rate warning (not one line per gap), the source is asked exactly once",
                    r.warnings.filter { $0.contains("sample-rate mismatch") }.count == 1 && r.hints == 1 && r.warnings.filter { $0.contains("filled a") }.isEmpty,
                    "warnings \(r.warnings.count), hints \(r.hints)")
        } else { c.check("defect_unfixed: scenario ran", false) }

        // the recorder's own trigger: no measurement, but the gap detector asks the source to re-check: the ratio 0.5 snaps to 24 kHz
        if let r = runs["recorder_rescue"], r.ok {
            let tone = [(3.5, 4.5), (5, 6)]
            let afterFix = zeroRuns(Array(r.samples.dropFirst(Int(3.2 * 48000))), minLength: 480)
            c.check("recorder trigger (measurement off): the gap pattern is classified, the source re-checks once, and from ~3 s on the tone is 1 kHz", toneOK(r, tone) && r.hints == 1,
                    "\(windowsText(r, tone)); hints \(r.hints)")
            c.check("... no zero runs after the correction, duration within 1 %", afterFix.isEmpty && durationOK(r), "\(afterFix.count) zero runs; \(durationText(r))")
            c.check("... ONE sample-rate warning from the recorder and ONE effective-rate warning from the capture",
                    r.warnings.filter { $0.contains("sample-rate mismatch") }.count == 1 && rateWarnings(r).count == 1 && abs(r.effectiveRate - 24000) < 1, "\(r.warnings)")
        } else { c.check("recorder_rescue: scenario ran", false) }

        // a rate-like pattern nothing can explain (no measurement, 0.65 is no standard rate): the source is not changed, the owner is asked ONCE for a new graph
        if let r = runs["unexplained_31k"], r.ok {
            c.check("unexplained pattern (31 kHz audio, format 48 kHz, no measurement): the recorder asks once, the capture finds no standard rate and keeps 48000 Hz",
                    r.hints == 1 && r.rateChanges == 0 && abs(r.effectiveRate - 48000) < 1 && rateWarnings(r).isEmpty, "hints \(r.hints), changes \(r.rateChanges), effective \(r.effectiveRate)")
            c.check("... the owner's hook is called once and its 'new graph' answer re-creates the graph exactly once (2 opens), no loop",
                    r.unresolved == 1 && r.opens == 2, "unresolved \(r.unresolved), opens \(r.opens)")
        } else { c.check("unexplained_31k: scenario ran", false) }

        // the same gap pattern from a device that delivers the right rate: the recorder suspects, the capture measures and says NO
        if let r = runs["dropouts_48k"], r.ok {
            c.check("regular dropouts of a 48000 Hz device: the recorder asks once, the capture measures 48000 Hz and keeps it (a rate change would garble the audio)",
                    r.hints == 1 && r.rateChanges == 0 && abs(r.effectiveRate - 48000) < 1 && rateWarnings(r).isEmpty,
                    "hints \(r.hints), changes \(r.rateChanges), effective \(r.effectiveRate), warnings \(r.warnings.count)")
            c.check("... the tone that was recorded is still 1 kHz, the timeline is continuous (duration within 1 % + 0.2 s)",
                    abs(firstBurstHz(r.samples) / 1000 - 1) < 0.02 && abs(r.fileSeconds - r.emitted) <= 0.01 * r.emitted + Recorder.gapTolerance,
                    String(format: "%.0f Hz; ", firstBurstHz(r.samples)) + durationText(r))
        } else { c.check("dropouts_48k: scenario ran", false) }
    }

    // MARK: delivered-rate verification at the engine level (fake backend, virtual host stamps fed faster than real time)

    private static func testRateHold(_ c: Checker) {
        print("-- delivered-rate verification in the engine: first audio held back ~0.5 s of host time, never lost")
        var timing = HALCapture.Timing()
        timing.tick = 0.05; timing.stallAfter = 30; timing.zeroHealAfter = 30; timing.debounce = 0.05
        let base = CaptureHAL.Clock.seconds(CaptureHAL.Clock.now())
        func feed(_ p: EngineProbe, buffers: Int, frames: Int, spacing: Double) {
            for i in 0..<buffers { p.backend.deliver(frames: frames, value: 0.5, host: CaptureHAL.Clock.ticks(seconds: base + Double(i) * spacing)) }
        }
        // 1. a healthy 48 kHz stream: everything arrives, nothing is adopted
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, buffers: 100, frames: 480, spacing: 0.01)                     // 1 s of device time, fed at once
            let all = waitUntil(1.0) { p.get { p.frames } >= 48_000 }
            p.engine.stop()
            c.check("healthy stream (stamps say 48 kHz): all 48000 frames delivered once verified, nothing adopted, no warning",
                    all && p.get { p.frames } == 48_000 && p.engine.rateChangeCount == 0 && p.get { p.warnings.isEmpty }, "frames \(p.get { p.frames }) changes \(p.engine.rateChangeCount)")
        }
        // 2. stamps say 24 kHz (20 ms per 480 frames) while the format says 48 kHz: converted, exact length
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, buffers: 100, frames: 480, spacing: 0.02)                     // 2 s of device time at 24 kHz
            let verified = waitUntil(1.0) { p.engine.effectiveRate == 24000 }
            p.engine.stop()
            let frames = p.get { p.frames }
            c.check("stamps say 24 kHz, format 48 kHz: verified within the first buffers, resampled, 2 s in -> 96000 frames out (+-2, tail flushed at stop)",
                    verified && abs(frames - 96_000) <= 2, "verified \(verified) frames \(frames)")
            c.check("... one warning with the documented wording, one adoption", p.get { p.warnings.count } == 1 && p.get { p.warnings[0] }.contains("effective rate 24000 Hz differs from device format 48000 Hz: resampling from 24000")
                    && p.engine.rateChangeCount == 1, "\(p.get { p.warnings }) changes \(p.engine.rateChangeCount)")
        }
        // 3. stop() while the verification is still running: nothing held is lost, the best estimate is used
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, buffers: 20, frames: 480, spacing: 0.02)                      // only 0.4 s of host coverage: the verification is not done yet
            Thread.sleep(forTimeInterval: 0.1)
            let beforeStop = p.get { p.frames }
            p.engine.stop()
            let frames = p.get { p.frames }
            c.check("stop() during the verification: the held audio is released (24 kHz estimate from 0.4 s of host time -> 19200 frames, +-2), none lost",
                    beforeStop == 0 && abs(frames - 19_200) <= 2, "before stop \(beforeStop), after \(frames)")
        }
        // 4. too little to measure: the configured rate is used, every frame comes out
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, buffers: 3, frames: 480, spacing: 0.02)
            p.engine.stop()
            c.check("three buffers only (nothing to measure): delivered unchanged at the configured rate, no adoption", p.get { p.frames } == 1440 && p.engine.rateChangeCount == 0,
                    "frames \(p.get { p.frames })")
        }
        // 5. real time: the first audio is released after ~0.5 s, never immediately and never late
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            let t0 = ProcessInfo.processInfo.systemUptime
            p.startFeeder(value: 0.5)
            let got = waitUntil(3.0) { p.get { p.frames } > 0 }
            let dt = ProcessInfo.processInfo.systemUptime - t0
            p.stopFeeder(); p.engine.stop()
            c.check("real-time 48 kHz feed: first audio released after the ~0.5 s verification (0.3 s ... 1.3 s)", got && dt > 0.3 && dt < 1.3, String(format: "%.2f s", dt))
        }
    }

    // MARK: delivered-rate measurement under stress (review of 2026-10-10): the engine level, fake backend, virtual host stamps

    private static func testRateRobustness(_ c: Checker) {
        print("-- delivered-rate measurement under stress: jittery stamps, unusable stamps, a silent switch plus the recorder's report, a flapping device")
        var timing = HALCapture.Timing()
        timing.tick = 0.05; timing.stallAfter = 60; timing.zeroHealAfter = 60; timing.debounce = 0.05
        let base = CaptureHAL.Clock.seconds(CaptureHAL.Clock.now()) + 100
        struct Stage { var seconds: Double; var rate: Double; var frames: Int }
        /// Feeds device time faster than real time: callbacks of `frames` at `rate` for `seconds`, stamped with the device clock plus `noise`.
        /// Returns the device time after the last callback (the next call continues from there).
        @discardableResult
        func feed(_ p: EngineProbe, _ stages: [Stage], from t0: Double = 0, seed: UInt64 = 5, noise: Double = 0, value: Float = 0.5, stamp: ((Int, Double) -> Double)? = nil) -> Double {
            var t = t0
            var rng = NoiseRNG(seed: seed)
            var i = 0
            for s in stages {
                let end = t + s.seconds
                while t < end {
                    let host = stamp?(i, t) ?? (t + (rng.next() - 0.5) * 2 * noise)
                    p.backend.deliver(frames: s.frames, value: value, host: CaptureHAL.Clock.ticks(seconds: base + host))
                    t += Double(s.frames) / s.rate
                    i += 1
                }
            }
            return t
        }
        /// Waits until the engine has processed everything that was fed (frames stop growing) and its control queue has caught up.
        func settle(_ p: EngineProbe) {
            var last = -1
            let end = Date().addingTimeInterval(10)
            while Date() < end {
                Thread.sleep(forTimeInterval: 0.15)
                let now = p.get { p.frames }
                if now == last { break }
                last = now
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // 1. a HEALTHY 48 kHz device whose stamps jitter by +-3 ms (30 s): nothing is adopted, no warning, every frame arrives
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, [Stage(seconds: 30, rate: 48000, frames: 512)], noise: 0.003)
            settle(p)
            let changes = p.engine.rateChangeCount, effective = p.engine.effectiveRate
            p.engine.stop()
            let frames = p.get { p.frames }
            c.check("healthy 48 kHz device, stamps jittering +-3 ms for 30 s: no rate adopted, no warning, 48000 Hz at the end (was: flapping through 44.1 kHz)",
                    changes == 0 && effective == 48000 && p.get { p.warnings.isEmpty }, "changes \(changes) effective \(effective) warnings \(p.get { p.warnings })")
            c.check("... and no frame is lost or duplicated by it (30 s -> 1 440 000 frames, +-0.1 %)", abs(Double(frames) / 1_440_000 - 1) < 0.001, "frames \(frames)")
        }
        // 2. a healthy device that changes its callback size (512 / 1024 / 256 / 480) and whose output is digital silence
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            var t = feed(p, [Stage(seconds: 5, rate: 48000, frames: 512)])
            t = feed(p, [Stage(seconds: 5, rate: 48000, frames: 1024)], from: t)
            t = feed(p, [Stage(seconds: 5, rate: 48000, frames: 256)], from: t)
            t = feed(p, [Stage(seconds: 5, rate: 48000, frames: 480)], from: t)
            // sleep / wake: the host clock jumps by 40 s between two callbacks (a restart, not a rate), then the stream goes on
            feed(p, [Stage(seconds: 5, rate: 48000, frames: 512)], from: t + 40)
            settle(p)
            let changes = p.engine.rateChangeCount
            p.engine.stop()
            c.check("healthy 48 kHz device that changes its callback size 512 -> 1024 -> 256 -> 480 and wakes from sleep (a 40 s jump of the host clock): nothing adopted, 25 s of frames out (+-0.1 %)",
                    changes == 0 && abs(Double(p.get { p.frames }) / 1_200_000 - 1) < 0.001, "changes \(changes) frames \(p.get { p.frames })")
        }
        // 2b. quiet system output (digital silence, nobody talks): the measurement does not care about content
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, [Stage(seconds: 20, rate: 48000, frames: 512)], noise: 0.0005, value: 0)
            settle(p)
            let changes = p.engine.rateChangeCount, effective = p.engine.effectiveRate
            p.engine.stop()
            c.check("quiet system output (20 s of exact digital silence on a healthy 48 kHz device): nothing adopted, no warning, every frame delivered",
                    changes == 0 && effective == 48000 && p.get { p.warnings.isEmpty } && abs(Double(p.get { p.frames }) / 960_000 - 1) < 0.001, "changes \(changes) effective \(effective) frames \(p.get { p.frames })")
        }
        // 3. stamps that cannot be used (a driver that stamps every callback with the same time / runs backwards): the audio is NOT held for ever
        for (name, stamp) in [("constant", { (_: Int, _: Double) -> Double in 0 }), ("backwards", { (_: Int, t: Double) -> Double in -t })] {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, [Stage(seconds: 6, rate: 48000, frames: 480)], stamp: stamp)
            settle(p)
            let before = p.get { p.frames }, changes = p.engine.rateChangeCount
            p.engine.stop()
            c.check("unusable stamps (\(name)): the first audio is released by SIZE (3 s of audio at most), the recording is not swallowed (before stop \(before) of 288 480 frames), nothing adopted",
                    before >= 144_000 && changes == 0 && p.get { p.frames } == 288_480, "before stop \(before), after \(p.get { p.frames }), changes \(changes)")
        }
        // 4. a silent switch 48 -> 24 kHz, then the recorder reports its gap pattern (ratio 0.5): the report must never turn the graph back
        for (name, lastSeconds, expectChanges) in [("1.15 s after the switch, before the engine's own two looks", 1.15, 1), ("1.9 s after the switch, the engine has followed already", 1.9, 1)] {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, [Stage(seconds: 5, rate: 48000, frames: 480), Stage(seconds: lastSeconds, rate: 24000, frames: 480)])
            settle(p)
            p.engine.rateSuspected(deliveredRatio: 0.5)
            let followed = waitUntil(3.0) { p.engine.effectiveRate == 24000 }
            settle(p)
            let effective = p.engine.effectiveRate, changes = p.engine.rateChangeCount
            p.engine.stop()
            c.check("silent switch to 24 kHz + the recorder's report \(name): the graph ends at 24000 Hz with exactly one adoption (a window that spans the switch is never averaged)",
                    followed && effective == 24000 && changes == expectChanges, "effective \(effective) changes \(changes)")
        }
        // 5. a device that really flaps between 24 and 16 kHz every 1.6 s: the engine follows six times, then goes back to the configured rate and says so once
        do {
            let p = EngineProbe(timing: timing)
            try? p.engine.start()
            feed(p, (0..<14).map { Stage(seconds: 1.6, rate: $0 % 2 == 0 ? 24000 : 16000, frames: $0 % 2 == 0 ? 480 : 320) })
            settle(p)
            let changes = p.engine.rateChangeCount, effective = p.engine.effectiveRate
            let gaveUp = p.get { p.warnings.filter { $0.contains("kept changing its mind") } }
            p.engine.stop()
            c.check("a graph whose measured rate flips 7 times is not followed for ever: back to the configured 48000 Hz, ONE warning that says so, at most 8 changes in total",
                    effective == 48000 && changes <= 8 && changes >= 7 && gaveUp.count == 1, "effective \(effective) changes \(changes) gave-up warnings \(gaveUp.count)")
        }
    }

    // MARK: Recorder with synthetic sources

    private static func testRecorder(_ c: Checker, config: AppConfig, dir: URL) {
        print("-- Recorder with synthetic sources (8 s, simulated device change on remote at 2.0-3.5 s, 44.1 kHz native)")
        let sessionDir = dir.appendingPathComponent("2026-10-07_1400_meet")
        try? FileManager.default.removeItem(at: sessionDir)
        let signal = PlatformSignal(platform: .meet, inCall: true, confidence: .high, titleHint: "Meet - abc-defg-hij",
                                    meetingURL: "https://meet.google.com/abc-defg-hij", meetingKey: "abc-defg-hij",
                                    bundleID: "com.google.Chrome", evidence: [])
        let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 44100,
                                            frequency: 440, amplitude: 0.3, startDelay: 0.25,
                                            stalls: [.init(start: 2.0, duration: 1.5)], deviceAfterStall: "Synthetic AirPods")
        let mic = SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000,
                                         frequency: 200, amplitude: 0.1, noise: 0.01, startDelay: 0.1)
        let rec = Recorder(sessionDir: sessionDir, signal: signal, config: config, remote: { remote }, mic: { mic })
        let lock = NSLock()
        var warnings: [String] = []
        rec.onWarning = { lock.lock(); warnings.append($0); lock.unlock() }
        do { try rec.start() } catch { c.check("start()", false, "\(error)"); return }
        let t0 = rec.startedAt
        c.check("isRecording after start", rec.isRecording)
        Thread.sleep(forTimeInterval: 1.2)
        let early = rec.recentLevelsDB
        c.check("recentLevelsDB reflects the signals (remote ~ -13.5 dB, mic ~ -23 dB)",
                abs(early.remote - (-13.5)) < 4 && early.mic < -15 && early.mic > -32, "mic=\(early.mic) remote=\(early.remote)")
        Thread.sleep(forTimeInterval: 1.0)
        rec.updateMeta(titleHint: "Weekly Sync", meetingURL: nil)               // nil keeps the earlier URL
        Thread.sleep(forTimeInterval: 5.8)
        let summary = rec.stop(reason: .manual)
        let wall = Date().timeIntervalSince(t0)
        let again = rec.stop(reason: .meetingEnded)                              // idempotent: same summary, same reason
        c.check("stop() is idempotent", again.durationSec == summary.durationSec && !rec.isRecording)

        // session.json
        let jsonURL = sessionDir.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: jsonURL), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            c.check("session.json parses", false); return
        }
        // SPEC 4.1 keys + the two additive wave-D keys (SPEC 15): warnings (timestamped strings) and remote_silent_suspected.
        let expectedKeys: Set<String> = ["schema", "session_id", "platform", "platform_label", "title_hint", "meeting_url", "app_bundle_id",
                                         "start_time", "end_time", "end_reason", "tracks", "app_version", "warnings", "remote_silent_suspected"]
        c.check("session.json has exactly the SPEC 4.1 keys plus warnings and remote_silent_suspected", Set(obj.keys) == expectedKeys, "\(Set(obj.keys).symmetricDifference(expectedKeys))")
        let persistedWarnings = (obj["warnings"] as? [String]) ?? []
        c.check("session.json warnings: the gap warning is persisted with an ISO8601 timestamp prefix",
                persistedWarnings.contains { $0.contains("filled a 1.") && $0.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2} "#, options: .regularExpression) != nil },
                "\(persistedWarnings)")
        c.check("session.json remote_silent_suspected is false for a healthy recording", (obj["remote_silent_suspected"] as? Bool) == false)
        c.check("session.json scalar values",
                (obj["schema"] as? Int) == 1 && (obj["session_id"] as? String) == "2026-10-07_1400_meet" && (obj["platform"] as? String) == "meet"
                && (obj["platform_label"] as? String) == "Google Meet" && (obj["end_reason"] as? String) == "manual"
                && (obj["app_bundle_id"] as? String) == "com.google.Chrome",
                "\(obj["session_id"] ?? "") \(obj["end_reason"] ?? "")")
        c.check("title/url: updateMeta applied, nil kept the old URL",
                (obj["title_hint"] as? String) == "Weekly Sync" && (obj["meeting_url"] as? String) == "https://meet.google.com/abc-defg-hij")
        let start = obj["start_time"] as? String ?? "", end = obj["end_time"] as? String ?? ""
        c.check("start_time / end_time ISO8601 with local offset", isoHasOffset(start) && isoHasOffset(end), "\(start) .. \(end)")
        guard let tracks = obj["tracks"] as? [String: Any], let tr = tracks["remote"] as? [String: Any], let tj = tracks["mic"] as? [String: Any] else {
            c.check("tracks present", false); return
        }
        let trKeys: Set<String> = ["file", "sample_rate", "channels", "start_offset_sec", "source", "device"]
        c.check("track entries have the SPEC key names", Set(tr.keys) == trKeys && Set(tj.keys) == trKeys)
        let offR = (tr["start_offset_sec"] as? Double) ?? -1, offJ = (tj["start_offset_sec"] as? Double) ?? -1
        c.check("start_offset_sec >= 0 and matches the source start delays (0.25 / 0.10)",
                offR >= 0 && offJ >= 0 && abs(offR - 0.25) < 0.12 && abs(offJ - 0.10) < 0.12, "remote=\(offR) mic=\(offJ)")
        c.check("track sources and devices",
                (tr["source"] as? String) == "global-tap" && (tj["source"] as? String) == "mic"
                && (tr["device"] as? String) == "Synthetic Speakers -> Synthetic AirPods" && (tj["device"] as? String) == "Synthetic Mic",
                "\(tr["device"] ?? "") | \(tj["device"] ?? "")")

        // WAV files
        guard let rw = readSamples(sessionDir.appendingPathComponent("remote.wav")), let jw = readSamples(sessionDir.appendingPathComponent("mic.wav")) else {
            c.check("read WAVs", false); return
        }
        c.check("WAV header rate == session.json sample_rate (48000, both tracks)",
                rw.info.sampleRate == (tr["sample_rate"] as? Int) && jw.info.sampleRate == (tj["sample_rate"] as? Int) && rw.info.sampleRate == 48000)
        c.check("WAV headers finalized", rw.info.headerIsConsistent && jw.info.headerIsConsistent)
        let expectRemote = wall - offR, expectMic = wall - offJ
        c.check("remote.wav length == elapsed real time (gap filled with silence)",
                abs(rw.info.seconds - expectRemote) < 0.4, String(format: "file=%.2fs expected~%.2fs (wall %.2f, offset %.2f)", rw.info.seconds, expectRemote, wall, offR))
        c.check("mic.wav length == elapsed real time", abs(jw.info.seconds - expectMic) < 0.4, String(format: "file=%.2fs expected~%.2fs", jw.info.seconds, expectMic))
        c.check("summary seconds match the files", abs(summary.remoteSeconds - rw.info.seconds) < 0.01 && abs(summary.micSeconds - jw.info.seconds) < 0.01 && summary.durationSec > 7.5,
                String(format: "remote=%.2f mic=%.2f duration=%.2f", summary.remoteSeconds, summary.micSeconds, summary.durationSec))
        // the simulated outage is 2.0 .. 3.5 s of session time = file time minus the start offset
        func window(_ s: [Float], _ from: Double, _ to: Double, offset: Double) -> Double {
            let a = max(0, Int((from - offset) * 48000)), b = min(s.count, Int((to - offset) * 48000))
            return rmsDB(s[a..<max(a, b)])
        }
        let before = window(rw.samples, 0.6, 1.8, offset: offR), gap = window(rw.samples, 2.3, 3.2, offset: offR), after = window(rw.samples, 4.0, 7.0, offset: offR)
        c.check("remote timeline: signal, then ~1.5 s digital silence, then signal again (continuous timeline)",
                before > -20 && before < -8 && gap < -100 && after > -20 && after < -8,
                String(format: "before=%.1f dB gap=%.1f dB after=%.1f dB", before, gap, after))
        let micLevel = window(jw.samples, 0.6, 7.0, offset: offJ)
        c.check("mic track has signal throughout (no gap)", micLevel > -30 && micLevel < -15, String(format: "%.1f dB", micLevel))
        let pitch = Double(upwardZeroCrossings(rw.samples[Int(5.0 * 48000)..<Int(6.0 * 48000)]))
        c.check("remote pitch survives 44.1 -> 48 kHz conversion (440 Hz)", abs(pitch - 440) <= 3, "\(pitch) Hz")
        lock.lock(); let w = warnings; lock.unlock()
        c.check("long gap reported through onWarning", w.contains { $0.contains("filled a 1.") && $0.contains("gap") }, "\(w)")
        c.check("no stall/permission warnings for healthy tracks", !w.contains { $0.contains("delivered no audio") }, "\(w)")
        print("  files: \(sessionDir.path)")
    }

    private static func testRecorderCrash(_ c: Checker, config: AppConfig, dir: URL) {
        print("-- Recorder crash simulation (6.5 s, then killed without finalizing; header refresh every 4 s, checked at 4.6 s)")
        let sessionDir = dir.appendingPathComponent("2026-10-07_1500_zoom_crash")
        try? FileManager.default.removeItem(at: sessionDir)
        let signal = PlatformSignal(platform: .zoom, inCall: true, bundleID: "us.zoom.xos")
        let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 330, amplitude: 0.3)
        let mic = SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 220, amplitude: 0.2)
        let rec = Recorder(sessionDir: sessionDir, signal: signal, config: config, remote: { remote }, mic: { mic })
        do { try rec.start() } catch { c.check("start()", false, "\(error)"); return }
        let t0 = rec.startedAt
        // SPEC 4.2: the header may be at most 5 s stale. The writer refreshes every 4 s (+100 ms leeway), so at 4.6 s
        // the header must already count the data up to the 4 s refresh (an older 5 s + 500 ms leeway timer had not fired yet).
        Thread.sleep(forTimeInterval: 4.6)
        for name in ["remote.wav", "mic.wav"] {
            let info = WavFileInfo.read(sessionDir.appendingPathComponent(name))
            let headerSeconds = Double(info?.headerDataBytes ?? 0) / 96000
            c.check("\(name): header refreshed within 5 s of recording (SPEC 4.2): at 4.6 s it counts >= 3.5 s",
                    headerSeconds >= 3.5 && headerSeconds <= 4.6, String(format: "header says %.2f s, file has %.2f s", headerSeconds, info?.seconds ?? -1))
        }
        Thread.sleep(forTimeInterval: 1.9)
        let wall = Date().timeIntervalSince(t0)
        rec.simulateCrashForTest()
        let obj = (try? Data(contentsOf: sessionDir.appendingPathComponent("session.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        c.check("session.json after a crash: end_time and end_reason are null, tracks listed",
                obj != nil && obj?["end_time"] is NSNull && obj?["end_reason"] is NSNull && (obj?["tracks"] as? [String: Any])?.count == 2)
        for name in ["remote.wav", "mic.wav"] {
            let url = sessionDir.appendingPathComponent(name)
            let info = WavFileInfo.read(url)
            c.check("\(name): stale but nonzero header (periodic refresh happened), true length recovered from the file size",
                    info != nil && !(info!.headerIsConsistent) && info!.headerDataBytes > 0 && info!.headerDataBytes < info!.actualDataBytes && abs(info!.seconds - wall) < 0.5,
                    String(format: "header=%.1fs actual=%.2fs wall=%.2fs", Double(info?.headerDataBytes ?? 0) / 96000, info?.seconds ?? -1, wall))
            // keep an un-repaired copy so afinfo / Python can be pointed at a genuinely crashed file
            let keep = sessionDir.appendingPathComponent(name.replacingOccurrences(of: ".wav", with: ".crashed.wav.keep"))
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.copyItem(at: url, to: keep)
            c.check("\(name): repaired", WavWriter.repairHeader(at: url) && WavFileInfo.read(url)?.headerIsConsistent == true)
        }
        print("  files: \(sessionDir.path)")
    }

    // MARK: remote silence (SPEC 15)

    /// RemoteSilenceTracker on virtual time (one sample per second, like the watchdog).
    private static func testRemoteSilenceRule(_ c: Checker) {
        print("-- remote silence rule (virtual time): >= 3 min of digital silence on the remote track, with mic activity or an auto-detected call")
        typealias Step = (t: Double, silent: Bool, mic: Bool)
        func seconds(_ from: Int, _ to: Int, silent: Bool, mic: Bool = false) -> [Step] { (from...to).map { (Double($0), silent, mic) } }
        func fired(_ steps: [Step], inCall: Bool, threshold: Double = 180) -> [Double] {
            var tracker = RemoteSilenceTracker(thresholdSeconds: threshold)
            return steps.compactMap { tracker.update(now: $0.t, remoteSilent: $0.silent, micActive: $0.mic, detectionInCall: inCall) ? $0.t : nil }
        }
        c.check("auto-detected call: remote silent for 3 min fires once, at exactly 180 s", fired(seconds(0, 600, silent: true), inCall: true) == [180], "\(fired(seconds(0, 600, silent: true), inCall: true))")
        c.check("179 s of silence is not enough", fired(seconds(0, 179, silent: true), inCall: true).isEmpty)
        c.check("a sound on the remote track restarts the stretch (silent 0..169, sound at 170, silent again from 171: fires at 351)",
                fired(seconds(0, 169, silent: true) + seconds(170, 170, silent: false) + seconds(171, 700, silent: true), inCall: true) == [351])
        c.check("manual recording with a quiet microphone: never (nobody is known to be talking)", fired(seconds(0, 600, silent: true), inCall: false).isEmpty)
        c.check("manual recording, mic active at 100 s inside the stretch: fires at 180",
                fired(seconds(0, 99, silent: true) + seconds(100, 100, silent: true, mic: true) + seconds(101, 600, silent: true), inCall: false) == [180])
        c.check("manual recording, mic first active at 250 s: fires at 250 (>= 180 s of silence and activity)",
                fired(seconds(0, 249, silent: true) + seconds(250, 300, silent: true, mic: true), inCall: false) == [250])
        c.check("mic activity BEFORE the remote stretch does not count for it",
                fired(seconds(0, 50, silent: false, mic: true) + seconds(51, 600, silent: true), inCall: false).isEmpty)
        c.check("fires only once: sound, then another 400 s of silence, does not fire again",
                fired(seconds(0, 200, silent: true) + seconds(201, 210, silent: false) + seconds(211, 700, silent: true), inCall: true) == [180])
        c.check("a shorter threshold (the test setting) works the same", fired(seconds(0, 10, silent: true), inCall: true, threshold: 2.5) == [3])
        var t = RemoteSilenceTracker(thresholdSeconds: 180)
        _ = t.update(now: 0, remoteSilent: true, micActive: false, detectionInCall: true)
        c.check("not suspected before the threshold, sticky after it", !t.suspected && t.update(now: 180, remoteSilent: true, micActive: false, detectionInCall: true) && t.suspected
                && !t.update(now: 181, remoteSilent: false, micActive: false, detectionInCall: true) && t.suspected)
    }

    /// Real Recorders (synthetic sources) with the threshold shortened to 2.5 s: what ends up in session.json, in the callbacks.
    private static func testRemoteSilenceRecorders(_ c: Checker, config: AppConfig, dir: URL) {
        print("-- Recorder: remote silence is persisted (session.json warnings + remote_silent_suspected), 5 recorders for 5.5 s, threshold 2.5 s")
        let saved = Recorder.remoteSilentSuspectSeconds
        Recorder.remoteSilentSuspectSeconds = 2.5
        defer { Recorder.remoteSilentSuspectSeconds = saved }

        struct Case { var name: String; var platform: Platform; var remoteAmp: Float; var micAmp: Float; var expectFlag: Bool; var explain: String }
        let cases = [
            Case(name: "auto-silent-remote", platform: .zoom, remoteAmp: 0, micAmp: 0.1, expectFlag: true, explain: "auto-detected, remote digital silence, mic active"),
            Case(name: "auto-quiet-mic", platform: .teams, remoteAmp: 0, micAmp: 0, expectFlag: true, explain: "auto-detected, remote silence alone (detection says in a call)"),
            Case(name: "manual-mic-active", platform: .manual, remoteAmp: 0, micAmp: 0.1, expectFlag: true, explain: "manual, remote silence while the mic had activity"),
            Case(name: "manual-quiet-mic", platform: .manual, remoteAmp: 0, micAmp: 0, expectFlag: false, explain: "manual, nobody known to be talking"),
            Case(name: "healthy", platform: .zoom, remoteAmp: 0.3, micAmp: 0.1, expectFlag: false, explain: "audio on both tracks"),
        ]
        struct Run { var rec: Recorder; var dir: URL; var warnings: Locked2<[String]>; var silentCalls: Locked2<Int>; var c: Case }
        var runs: [Run] = []
        for cs in cases {
            let sessionDir = dir.appendingPathComponent("2026-10-07_1700_\(cs.name)")
            try? FileManager.default.removeItem(at: sessionDir)
            let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: cs.remoteAmp)
            let mic = SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200, amplitude: cs.micAmp)
            let signal = PlatformSignal(platform: cs.platform, inCall: true, bundleID: cs.platform == .manual ? nil : "us.zoom.xos")
            let rec = Recorder(sessionDir: sessionDir, signal: signal, config: config, remote: { remote }, mic: { mic })
            let w = Locked2<[String]>([]), n = Locked2<Int>(0)
            rec.onWarning = { m in w.mutate { $0.append(m) } }
            rec.onRemoteSilentSuspected = { _ in n.mutate { $0 += 1 } }
            do { try rec.start() } catch { c.check("\(cs.name): start()", false, "\(error)"); return }
            runs.append(Run(rec: rec, dir: sessionDir, warnings: w, silentCalls: n, c: cs))
        }
        Thread.sleep(forTimeInterval: 5.5)
        let isoPrefix = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2} "#
        for r in runs {
            let live = (try? Data(contentsOf: r.dir.appendingPathComponent("session.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let liveWarnings = (live?["warnings"] as? [String]) ?? []
            c.check("\(r.c.name) (\(r.c.explain)): remote_silent_suspected == \(r.c.expectFlag) while recording",
                    r.rec.remoteSilentSuspected == r.c.expectFlag && (live?["remote_silent_suspected"] as? Bool) == r.c.expectFlag,
                    "recorder=\(r.rec.remoteSilentSuspected) json=\(String(describing: live?["remote_silent_suspected"]))")
            if r.c.expectFlag {
                c.check("\(r.c.name): the persisted warning is timestamped and names the remote silence (session.json is updated while recording, a crash would keep it)",
                        liveWarnings.contains { $0.range(of: isoPrefix, options: .regularExpression) != nil && $0.contains("remote audio has been digital silence") }, "\(liveWarnings)")
                c.check("\(r.c.name): onRemoteSilentSuspected fired once and onWarning got the same text",
                        r.silentCalls.get { $0 } == 1 && r.warnings.get { $0.contains { $0.contains("remote audio has been digital silence") } }, "calls \(r.silentCalls.get { $0 })")
            } else {
                c.check("\(r.c.name): no warning, no callback", liveWarnings.isEmpty && r.silentCalls.get { $0 } == 0 && r.warnings.get { $0.isEmpty }, "\(liveWarnings)")
            }
        }
        // annotate(): a note for session.json only
        if let healthy = runs.first(where: { $0.c.name == "healthy" }) {
            healthy.rec.annotate("auto-stopped: no speech on either track")
            let obj = (try? Data(contentsOf: healthy.dir.appendingPathComponent("session.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let w = (obj?["warnings"] as? [String]) ?? []
            c.check("annotate(): the line is in session.json (timestamped) without calling onWarning",
                    w.count == 1 && w[0].hasSuffix("auto-stopped: no speech on either track") && w[0].range(of: isoPrefix, options: .regularExpression) != nil && healthy.warnings.get { $0.isEmpty },
                    "\(w)")
        }
        for r in runs {
            _ = r.rec.stop(reason: .manual)
            let final = (try? Data(contentsOf: r.dir.appendingPathComponent("session.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            c.check("\(r.c.name): the final session.json keeps the flag and the warnings and has an end_time",
                    (final?["remote_silent_suspected"] as? Bool) == r.c.expectFlag && final?["end_time"] is String && (final?["warnings"] is [String]),
                    "\(String(describing: final?["remote_silent_suspected"]))")
        }
    }

    /// Tiny lock box (the callbacks run on recorder queues).
    private final class Locked2<T> {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&value); lock.unlock() }
        func get<R>(_ body: (T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(value) }
    }

    /// Both tracks unable to start: start() must throw a clear error and leave no half-written session behind.
    private static func testStartFailure(_ c: Checker, config: AppConfig, dir: URL) {
        print("-- Recorder start failure paths")
        final class Failing: CaptureTrackSource {
            let sampleRate = 48000.0
            let sourceLabel: String
            let deviceName = "none"
            let error: RecorderError
            var onSamples: (([Float], UInt64) -> Void)?
            var onWarning: ((String) -> Void)?
            var onDeviceChange: ((String) -> Void)?
            init(label: String, error: RecorderError) { sourceLabel = label; self.error = error }
            func start() throws { throw error }
            func stop() {}
        }
        let signal = PlatformSignal(platform: .manual, inCall: true)

        let dirA = dir.appendingPathComponent("fail_both")
        try? FileManager.default.removeItem(at: dirA)
        let both = Recorder(sessionDir: dirA, signal: signal, config: config,
                            remote: { Failing(label: "global-tap", error: .failed("tap boom")) },
                            mic: { Failing(label: "mic", error: .permissionDenied("microphone denied")) })
        var thrown: RecorderError?
        do { try both.start() } catch { thrown = error as? RecorderError }
        var isPermission = false
        if case .permissionDenied = thrown { isPermission = true }
        c.check("both tracks failing throws, permission problem is preferred", isPermission, "\(thrown.map { "\($0)" } ?? "no error")")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dirA.path)) ?? []
        c.check("no half-written files left behind", leftovers.isEmpty, "\(leftovers)")
        let s = both.stop(reason: .manual)
        c.check("stop() after a failed start is harmless", s.micSeconds == 0 && s.remoteSeconds == 0)

        let dirB = dir.appendingPathComponent("fail_mic_only")
        try? FileManager.default.removeItem(at: dirB)
        let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: 0.3)
        let one = Recorder(sessionDir: dirB, signal: signal, config: config, remote: { remote },
                           mic: { Failing(label: "mic", error: .permissionDenied("microphone denied")) })
        let lock = NSLock()
        var warned: [String] = []
        one.onWarning = { lock.lock(); warned.append($0); lock.unlock() }
        var started = true
        do { try one.start() } catch { started = false }
        c.check("one track failing: recording continues with the other", started && one.isRecording)
        Thread.sleep(forTimeInterval: 1.0)
        let s2 = one.stop(reason: .manual)
        lock.lock(); let w = warned; lock.unlock()
        let obj = (try? Data(contentsOf: dirB.appendingPathComponent("session.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let tracks = obj?["tracks"] as? [String: Any]
        c.check("failed track: warned, no mic entry in session.json, no empty mic.wav",
                w.contains { $0.contains("microphone") && $0.contains("could not start") } && tracks?["mic"] == nil && tracks?["remote"] != nil
                && !FileManager.default.fileExists(atPath: dirB.appendingPathComponent("mic.wav").path),
                "\(w) tracks=\(tracks?.keys.sorted() ?? [])")
        c.check("working track recorded", s2.remoteSeconds > 0.7 && s2.micSeconds == 0, String(format: "remote=%.2f", s2.remoteSeconds))

        // A source that could not start at the beginning (Bluetooth switching profile, device busy) is started again in the
        // background and joins late: its start_offset_sec says when. (Used to be: no microphone for the whole meeting.)
        final class Flaky: CaptureTrackSource {
            let inner: SyntheticCaptureSource
            private let lock = NSLock()
            private var failuresLeft: Int
            private var attemptCount = 0
            var attempts: Int { lock.lock(); defer { lock.unlock() }; return attemptCount }
            var sampleRate: Double { inner.sampleRate }
            var sourceLabel: String { inner.sourceLabel }
            var deviceName: String { inner.deviceName }
            var onSamples: (([Float], UInt64) -> Void)? { get { inner.onSamples } set { inner.onSamples = newValue } }
            var onWarning: ((String) -> Void)? { get { inner.onWarning } set { inner.onWarning = newValue } }
            var onDeviceChange: ((String) -> Void)? { get { inner.onDeviceChange } set { inner.onDeviceChange = newValue } }
            init(failures: Int, inner: SyntheticCaptureSource) { failuresLeft = failures; self.inner = inner }
            func start() throws {
                lock.lock()
                attemptCount += 1
                let fail = failuresLeft > 0
                if fail { failuresLeft -= 1 }
                lock.unlock()
                if fail { throw RecorderError.deviceUnavailable("Bluetooth is switching profile") }
                try inner.start()
            }
            func stop() { inner.stop() }
        }
        let savedSchedule = Recorder.sourceRetrySchedule
        defer { Recorder.sourceRetrySchedule = savedSchedule }
        Recorder.sourceRetrySchedule = [0.5, 0.5]
        do {
            let dirC = dir.appendingPathComponent("flaky_mic")
            try? FileManager.default.removeItem(at: dirC)
            let flaky = Flaky(failures: 2, inner: SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200, amplitude: 0.1))
            let remoteC = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: 0.3)
            let late = Recorder(sessionDir: dirC, signal: signal, config: config, remote: { remoteC }, mic: { flaky })
            let lockC = NSLock()
            var warnedC: [String] = []
            late.onWarning = { lockC.lock(); warnedC.append($0); lockC.unlock() }
            do { try late.start() } catch { c.check("flaky mic: recording starts with the remote track", false, "\(error)"); return }
            let startC = late.startedAt
            let joined = waitUntil(6.0) { flaky.attempts >= 3 && late.recentLevelsDB.mic > -80 }
            Thread.sleep(forTimeInterval: 1.0)
            let wallC = Date().timeIntervalSince(startC)
            let sC = late.stop(reason: .manual)
            let objC = (try? Data(contentsOf: dirC.appendingPathComponent("session.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let micC = (objC?["tracks"] as? [String: Any])?["mic"] as? [String: Any]
            let offC = (micC?["start_offset_sec"] as? Double) ?? -1
            lockC.lock(); let wC = warnedC; lockC.unlock()
            c.check("flaky mic: started again in the background (third attempt) and the track joined the recording", joined && flaky.attempts == 3 && micC != nil, "attempts=\(flaky.attempts) joined=\(joined)")
            c.check("... with a late start_offset_sec (about 2 s) and a mic.wav as long as the time it was running",
                    offC > 1.0 && offC < 4.0 && abs(sC.micSeconds - (wallC - offC)) < 0.5 && sC.micSeconds > 0.8,
                    String(format: "offset %.2f s, mic %.2f s, wall %.2f s", offC, sC.micSeconds, wallC))
            c.check("... and the first failure was reported once (no warning per retry)", wC.filter { $0.contains("microphone track could not start") }.count == 1, "\(wC)")
        }
        // A source that never starts: retried while recording, never after stop(), never leaves a file.
        do {
            Recorder.sourceRetrySchedule = [0]
            let dirD = dir.appendingPathComponent("dead_mic")
            try? FileManager.default.removeItem(at: dirD)
            let dead = Flaky(failures: 1_000_000, inner: SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200, amplitude: 0.1))
            let remoteD = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: 0.3)
            let recD = Recorder(sessionDir: dirD, signal: signal, config: config, remote: { remoteD }, mic: { dead })
            do { try recD.start() } catch { c.check("dead mic: recording starts with the remote track", false, "\(error)"); return }
            Thread.sleep(forTimeInterval: 3.4)
            _ = recD.stop(reason: .manual)
            let atStop = dead.attempts
            Thread.sleep(forTimeInterval: 2.2)
            c.check("dead mic: retried on the watchdog ticks while recording (>= 3 attempts in 3.4 s)", atStop >= 3, "attempts at stop \(atStop)")
            c.check("... never again after stop() returned, and no empty mic.wav", dead.attempts == atStop && !FileManager.default.fileExists(atPath: dirD.appendingPathComponent("mic.wav").path),
                    "\(atStop) -> \(dead.attempts)")
        }
    }

    // MARK: mute gate

    /// The state machine on a virtual clock: nothing here is real time and nothing touches a device. Frame numbers are exact (48 kHz, 20 ms
    /// chunks unless said otherwise): a chunk is read at its END, the zeros start 0.3 s before the chunk that first reads muted, and end where
    /// the first non-muted reading began once it has held for 0.2 s.
    private static func testMuteGateMachine(_ c: Checker) {
        print("-- MuteGate state machine (virtual clock, fake signals): delay line, backdate, debounce, unknown = record, gaps")
        func f(_ seconds: Double) -> Int { GateRig.frames(seconds) }
        func names(_ events: [MuteGate.Event]) -> String {
            events.map { e -> String in
                switch e {
                case .engaged(let at, let s): return "engaged@\(at) \(s)"
                case .released(let span): return "released \(span.start)-\(span.end) \(span.signals)"
                }
            }.joined(separator: " | ")
        }
        let defaults = MuteGateConfig(enabled: true)
        c.check("config defaults are the design's: delay line 0.5 s, backdate 0.3 s, release debounce 0.2 s (48 kHz)",
                defaults.delayLineSeconds == 0.5 && defaults.engageBackdateSeconds == 0.3 && defaults.releaseDebounceSeconds == 0.2 && defaults.sampleRate == 48_000)

        // A. disabled: the chunk itself, at once, nothing held
        do {
            let gate = MuteGate(config: MuteGateConfig(enabled: false), signals: [ScriptSignal(name: "s", spans: [(0, 100)])])
            let chunk = (0..<960).map { gateRamp($0) }
            c.check("a disabled gate is the identity: the same samples out at once, nothing held, no zeros, nothing at finish",
                    gate.filter(chunk, hostTime: GateRig.host(0)) == chunk && gate.heldFrames == 0 && gate.flushForGap(skipping: 100).isEmpty
                    && gate.finish().isEmpty && gate.mutedSeconds == 0 && gate.takeEvents().isEmpty)
        }

        // B. the delay line: 0.5 s late, every frame comes out in order and unchanged
        do {
            let rig = GateRig(signals: [])
            rig.feed(seconds: 0.48)
            c.check("delay line: nothing comes out while it fills (0.48 s in, 0 out)", rig.out.isEmpty && rig.gate.heldFrames == f(0.48))
            rig.feed(seconds: 0.02)
            c.check("... exactly 0.5 s in: still nothing (the line is full, not over-full)", rig.out.isEmpty)
            rig.feed(seconds: 0.02)
            c.check("... the first output is the oldest chunk, 0.5 s late", rig.out.count == f(0.02) && rig.isIntact(0, 0.02))
            rig.feed(seconds: 2.5)
            c.check("... then output trails input by exactly 0.5 s (24000 frames held)", rig.out.count == rig.position - 24_000 && rig.gate.heldFrames == 24_000, "out \(rig.out.count) in \(rig.position)")
            rig.finish()
            c.check("finish() hands out the rest: as many frames as went in, in order, unchanged (no signal = no zeros)",
                    rig.out.count == f(3.02) && rig.isIntact(0, 3.02) && rig.gate.heldFrames == 0)
        }

        // C. engage backdate and release, to the frame
        do {
            let rig = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.0, 4.0)])])
            rig.feed(seconds: 6.0)
            rig.finish()
            c.check("engage: muted from 2.0 s -> zeros start 0.3 s earlier, at frame 81600 (1.7 s), inside the 0.5 s line",
                    rig.isIntact(0, 1.7) && rig.out[f(1.7) - 1] != 0 && rig.out[f(1.7)] == 0, "frame before: \(rig.out[f(1.7) - 1]) at: \(rig.out[f(1.7)])")
            c.check("zeros run to 4.0 s and the audio is back at frame 192000 (release effective where the unmuted run began, not 0.2 s later)",
                    rig.isZero(1.7, 4.0) && rig.out[f(4.0)] == gateRamp(f(4.0)) && rig.isIntact(4.0, 6.0))
            c.check("length unchanged: 6.0 s in, 6.0 s out", rig.out.count == f(6.0))
            c.check("mutedSeconds is exactly the zeros (2.3 s), nothing unknown, the signal answered",
                    abs(rig.gate.mutedSeconds - 2.3) < 1e-9 && rig.gate.unknownSeconds == 0 && rig.gate.signalNames == ["s"] && rig.zeroFrames == f(2.3))
            let events = rig.gate.takeEvents()
            c.check("events: engaged at 1.7 s, released as the span 1.7-4.0 s with the signal's name",
                    events == [.engaged(at: 1.7, signals: ["s"]), .released(MuteGate.Span(start: 1.7, end: 4.0, signals: ["s"]))], names(events))
            c.check("takeEvents drains", rig.gate.takeEvents().isEmpty)
        }

        // D. the backdate fits inside the line whatever the chunk size
        do {
            let r1 = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.05, 4.0)])])
            r1.feed(seconds: 6.0, chunk: 0.1)
            r1.finish()
            c.check("100 ms chunks: the first chunk that reads muted ends at 2.1 s, so the zeros start at 1.8 s and end at 4.0 s",
                    r1.isIntact(0, 1.8) && r1.out[f(1.8)] == 0 && r1.isZero(1.8, 4.0) && r1.isIntact(4.0, 6.0))
            let r2 = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.1, 3.0)])])
            r2.feed(seconds: 6.0, chunk: 0.25)
            r2.finish()
            c.check("250 ms chunks (a late work queue): found at the chunk that ends at 2.25 s, zeros 1.95 s - 3.0 s, nothing lost around them",
                    r2.isIntact(0, 1.95) && r2.isZero(1.95, 3.0) && r2.isIntact(3.0, 6.0) && r2.out.count == f(6.0))
        }

        // E. release debounce: a short unmuted blip does not release; 0.2 s does
        do {
            let blip = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.0, 4.0), (4.1, 5.0)])])
            blip.feed(seconds: 7.0)
            blip.finish()
            let events = blip.gate.takeEvents()
            c.check("an unmuted run of 0.1 s inside a mute (less than the 0.2 s debounce) does not release: one span 1.7-5.0 s, zeros all through",
                    blip.isZero(1.7, 5.0) && blip.isIntact(5.0, 7.0) && events.count == 2, names(events))
            let held = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.0, 4.0), (4.22, 5.0)])])
            held.feed(seconds: 7.0)
            held.finish()
            let events2 = held.gate.takeEvents()
            let released = events2.filter { if case .released = $0 { return true } else { return false } }.count
            c.check("an unmuted run of 0.2 s IS a release (and the next mute is a span of its own that does not reach back into it)",
                    released == 2 && held.isZero(1.7, 5.0) && held.isIntact(5.0, 7.0) && abs(held.gate.mutedSeconds - 3.3) < 1e-9, "\(names(events2)) muted \(held.gate.mutedSeconds)")
            let edge = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.0, 4.0), (4.20, 5.0)])])
            edge.feed(seconds: 7.0)
            edge.finish()
            let edgeReleased = edge.gate.takeEvents().filter { if case .released = $0 { return true } else { return false } }.count
            c.check("... 0.18 s of unmuted (the chunk that ends at 4.20 s already reads muted again) is not enough: one span", edgeReleased == 1)
        }

        // F. unknown = record (fail-open)
        do {
            let rig = GateRig(signals: [ScriptSignal(name: "s", otherwise: .unknown)])
            rig.feed(seconds: 5.0)
            rig.finish()
            c.check("every source unknown: the audio is recorded in full (no zeros), 5.0 s counted as unknown, no signal ever answered",
                    rig.isIntact(0, 5.0) && rig.out.count == f(5.0) && rig.gate.mutedSeconds == 0 && abs(rig.gate.unknownSeconds - 5.0) < 1e-9 && rig.gate.signalNames.isEmpty)
            let none = GateRig(signals: [])
            none.feed(seconds: 2.0)
            none.finish()
            c.check("no source at all: the same (a gate without opinions never silences)", none.isIntact(0, 2.0) && none.gate.mutedSeconds == 0 && abs(none.gate.unknownSeconds - 2.0) < 1e-9)
        }

        // G. the sources are combined: any muted wins, an unmuted one is an answer, unknown says nothing
        do {
            let two = GateRig(signals: [ScriptSignal(name: "device", otherwise: .unmuted), ScriptSignal(name: "app", spans: [(2.0, 3.0)], otherwise: .unmuted)])
            two.feed(seconds: 5.0)
            two.finish()
            let events = two.gate.takeEvents()
            c.check("one source muted, the other unmuted: muted (a positive signal wins); the span names the source that said it",
                    two.isZero(1.7, 3.0) && two.isIntact(3.0, 5.0)
                    && events == [.engaged(at: 1.7, signals: ["app"]), .released(MuteGate.Span(start: 1.7, end: 3.0, signals: ["app"]))] && two.gate.signalNames == ["device", "app"], names(events))
            let answer = GateRig(signals: [ScriptSignal(name: "a", otherwise: .unknown), ScriptSignal(name: "b", otherwise: .unmuted)])
            answer.feed(seconds: 2.0)
            answer.finish()
            c.check("one unknown, one unmuted: unmuted (not counted as unknown), only the one that answered is listed", answer.gate.unknownSeconds == 0 && answer.gate.signalNames == ["b"] && answer.isIntact(0, 2.0))
            let both = GateRig(signals: [ScriptSignal(name: "a", spans: [(2.0, 3.0)]), ScriptSignal(name: "b", spans: [(2.5, 3.5)])])
            both.feed(seconds: 5.0)
            both.finish()
            let events2 = both.gate.takeEvents()
            c.check("two sources muted one after the other: one span from the first engage to the last release, both names on it",
                    both.isZero(1.7, 3.5) && both.isIntact(3.5, 5.0) && events2.last == .released(MuteGate.Span(start: 1.7, end: 3.5, signals: ["a", "b"])), names(events2))
        }

        // H. a source that stops answering in the middle of a mute: released after the debounce (fail-open)
        do {
            let rig = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.0, 3.0)], otherwise: .unmuted, after: (3.0, .unknown))])
            rig.feed(seconds: 6.0)
            rig.finish()
            c.check("muted, then the source goes unknown: the zeros end where it stopped answering (the audio is recorded again)",
                    rig.isZero(1.7, 3.0) && rig.isIntact(3.0, 6.0))
            c.check("... and the unknown time is counted (about 3.0 s: from the moment it stopped answering to the end)", abs(rig.gate.unknownSeconds - 3.0) < 0.05, "\(rig.gate.unknownSeconds)")
        }

        // I. a gap fill: the line is flushed in front of the silence, the timeline goes on, a later mute lands in the right place
        do {
            let rig = GateRig(signals: [ScriptSignal(name: "s", spans: [(3.0, 3.6)])])
            rig.feed(seconds: 2.0)
            rig.gap(frames: f(0.5))
            rig.feed(seconds: 2.0)
            rig.finish()
            c.check("gap: everything before it is in the file before the silence (frames 0-2.0 s are the audio, 2.0-2.5 s the gap)",
                    rig.isIntact(0, 2.0) && rig.isZero(2.0, 2.5) && rig.out.count == f(4.5))
            c.check("... a mute after the gap starts 0.3 s before it was seen (2.7 s of the file) and ends at 3.6 s; the audio around it is intact",
                    rig.isIntact(2.5, 2.7) && rig.out[f(2.7)] == 0 && rig.isZero(2.7, 3.6) && rig.isIntact(3.6, 4.5))
            let held = GateRig(signals: [ScriptSignal(name: "s", spans: [(1.0, 1.5)])])
            held.feed(seconds: 1.3)
            c.check("flushForGap returns what the line holds (and nothing more): 0.5 s at that moment", held.gate.flushForGap(skipping: 100).count == f(0.5) && held.gate.heldFrames == 0)
        }

        // J. muted from the very start: the backdate cannot reach before the file
        do {
            let rig = GateRig(signals: [ScriptSignal(name: "s", spans: [(0, 1.0)])])
            rig.feed(seconds: 3.0)
            rig.finish()
            let events = rig.gate.takeEvents()
            c.check("muted from the first chunk: zeros from frame 0 (the backdate is clamped to the start of the file), the audio back at 1.0 s",
                    rig.isZero(0, 1.0) && rig.isIntact(1.0, 3.0) && events.first == .engaged(at: 0.0, signals: ["s"]), names(events))
        }

        // K. the recording ends while muted
        do {
            let rig = GateRig(signals: [ScriptSignal(name: "s", spans: [(2.0, 100)])])
            rig.feed(seconds: 3.0)
            let before = rig.gate.takeEvents()
            rig.finish()
            let events = before + rig.gate.takeEvents()
            c.check("a mute still in force at the end: the tail is zeros, the span ends with the file (3.0 s), the length is unchanged",
                    rig.isZero(1.7, 3.0) && rig.out.count == f(3.0) && events.last == .released(MuteGate.Span(start: 1.7, end: 3.0, signals: ["s"])), names(events))
            c.check("... and the gate says it was muted when asked while the mute lasted", { () -> Bool in
                let live = GateRig(signals: [ScriptSignal(name: "s", spans: [(1.0, 100)])])
                live.feed(seconds: 2.0)
                return live.gate.isEngaged
            }())
        }

        // L. the question is for the END of the chunk (the newest audio the gate has)
        do {
            let spy = SpySignal()
            let rig = GateRig(signals: [spy])
            rig.feed(frames: 960 * 3, chunkFrames: 960)
            let expected = (0..<3).map { GateRig.host($0 * 960) &+ CaptureHAL.Clock.ticks(seconds: Double(960) / 48_000.0) }
            c.check("each source is asked once per chunk, for the host time of the chunk's end", spy.asked == expected, "\(spy.asked.count) asks")
        }

        // M. a backdate longer than the line is cut to the line
        do {
            var config = MuteGateConfig(enabled: true)
            config.engageBackdateSeconds = 0.9
            let rig = GateRig(config: config, signals: [ScriptSignal(name: "s", spans: [(3.0, 4.0)])])
            rig.feed(seconds: 6.0)
            rig.finish()
            c.check("backdate 0.9 s with a 0.5 s line: the zeros reach back 0.5 s, not further (they could not)",
                    rig.isIntact(0, 2.5) && rig.out[f(2.5)] == 0 && rig.isZero(2.5, 4.0) && rig.isIntact(4.0, 6.0))
            var none = MuteGateConfig(enabled: true)
            none.engageBackdateSeconds = 0
            none.releaseDebounceSeconds = 0
            let flat = GateRig(config: none, signals: [ScriptSignal(name: "s", spans: [(3.0, 4.0)])])
            flat.feed(seconds: 6.0)
            flat.finish()
            c.check("backdate 0 and debounce 0: the zeros are exactly the chunks that read muted (3.0 s - 4.0 s)", flat.isIntact(0, 3.0) && flat.isZero(3.0, 4.0) && flat.isIntact(4.0, 6.0))
        }

        // N. properties over random chunk sizes and random scripts
        do {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next(_ bound: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(bound))
            }
            var failures: [String] = []
            var totalSpans = 0
            for round in 0..<40 {
                var spans: [(Double, Double)] = []
                var t = 0.3 + Double(next(1500)) / 1000
                for _ in 0..<6 {
                    let length = 0.1 + Double(next(2900)) / 1000
                    spans.append((t, t + length))
                    t += length + 0.5 + Double(next(1500)) / 1000
                }
                let device = ScriptSignal(name: "device", otherwise: round % 3 == 0 ? .unknown : .unmuted, roundsToMillisecond: false)
                let rig = GateRig(signals: [device, ScriptSignal(name: "app", spans: spans, otherwise: round % 2 == 0 ? .unmuted : .unknown, roundsToMillisecond: false)])
                var left = GateRig.frames(t + 1.0)
                let total = left
                while left > 0 {
                    let k = min(left, 1 + next(3000))
                    rig.feed(frames: k, chunkFrames: k)
                    left -= k
                }
                rig.finish()
                totalSpans += spans.count
                let events = rig.gate.takeEvents()
                var ordered = true
                var lastEnd = -1.0
                for case .released(let s) in events {
                    if s.start < lastEnd || s.end < s.start { ordered = false }
                    lastEnd = s.end
                }
                let coversScript = spans.allSatisfy { rig.isZero($0.0, $0.1) }
                var intact = true
                for (i, v) in rig.out.enumerated() where v != 0 && v != gateRamp(i) { intact = false; break }
                let zeros = rig.zeroFrames
                if rig.out.count != total { failures.append("round \(round): length \(rig.out.count) != \(total)") }
                if !intact { failures.append("round \(round): a frame was changed that was not zeroed") }
                if !coversScript { failures.append("round \(round): a muted span is not all zeros") }
                if !ordered { failures.append("round \(round): spans overlap or are out of order: \(names(events))") }
                if abs(Double(zeros) - rig.gate.mutedSeconds * 48_000) > 0.5 { failures.append("round \(round): zeros \(zeros) != mutedSeconds x rate \(rig.gate.mutedSeconds * 48_000)") }
                if rig.maxHeld > 24_000 + 3000 { failures.append("round \(round): the line held \(rig.maxHeld) frames") }
            }
            c.check("40 random scripts, random chunk sizes (1-3000 frames), two sources: the file is as long as the input, every frame is the audio or a zero, every muted span is all zeros, spans do not overlap, mutedSeconds is exactly the zeros, the line never holds more than 0.5 s + a chunk (\(totalSpans) spans)",
                    failures.isEmpty, failures.prefix(3).joined(separator: "; "))
        }
    }

    /// The sources of the gate: the manual one, a polled one (virtual stamps, then a real timer), the app's input (a fake process list), the
    /// device's mute properties (a fake HAL) and, read-only, the real default input device.
    private static func testMuteSignals(_ c: Checker) {
        print("-- mute signals: manual, polled (virtual stamps, real timer), the app's input, the device's mute properties")
        func at(_ seconds: Double) -> UInt64 { GateRig.base &+ CaptureHAL.Clock.ticks(seconds: seconds) }

        // manual: intervals with host times
        do {
            let m = ManualMuteSignal()
            c.check("manual: before any click it says unknown (it knows nothing about the meeting app's own mute), name 'manual'",
                    m.read(at: at(1)) == .unknown && !m.isPaused && m.name == "manual")
            c.check("manual: pausing at 2.0 s is a change, pausing again is not", m.set(paused: true, at: at(2.0)) && !m.set(paused: true, at: at(2.5)) && m.isPaused)
            c.check("manual: muted from the click on, judged by the host time asked about (a chunk that is processed late is judged by when it was recorded)",
                    m.read(at: at(1.99)) == .unknown && m.read(at: at(2.0)) == .muted && m.read(at: at(50)) == .muted)
            c.check("manual: resuming at 4.0 s ends it exactly there; resuming twice changes nothing",
                    m.set(paused: false, at: at(4.0)) && !m.set(paused: false, at: at(4.1)) && !m.isPaused && m.read(at: at(3.99)) == .muted && m.read(at: at(4.0)) == .unknown)
            c.check("manual: a second pause is a second interval, the first is still remembered",
                    m.set(paused: true, at: at(6.0)) && m.read(at: at(3.0)) == .muted && m.read(at: at(5.0)) == .unknown && m.read(at: at(6.5)) == .muted)
            let many = ManualMuteSignal()
            for i in 0..<250 {
                many.set(paused: true, at: at(Double(i) * 2))
                many.set(paused: false, at: at(Double(i) * 2 + 1))
            }
            c.check("manual: 250 pause / resume pairs are kept within a bound and the newest is still answered",
                    many.read(at: at(2 * 249 + 0.5)) == .muted && many.read(at: at(2 * 249 + 1.5)) == .unknown)
        }

        // polled, virtual stamps
        do {
            final class Box { var reading: MuteReading = .unmuted }
            let box = Box()
            let sig = PolledMuteSignal(name: "device", interval: 0.1) { box.reading }
            c.check("polled: nothing sampled yet: unknown", sig.read(at: at(1)) == .unknown && sig.name == "device")
            sig.sample(at: at(10.0))
            box.reading = .muted
            sig.sample(at: at(10.1))
            box.reading = .unmuted
            sig.sample(at: at(10.2))
            c.check("polled: the answer is the last sample that is not newer than the position asked about",
                    sig.read(at: at(10.05)) == .unmuted && sig.read(at: at(10.1)) == .muted && sig.read(at: at(10.15)) == .muted && sig.read(at: at(10.2)) == .unmuted)
            c.check("polled: a position just before the first poll (the recording began a moment earlier) gets the first answer, further back it is unknown",
                    sig.read(at: at(9.7)) == .unmuted && sig.read(at: at(9.4)) == .unknown)
            c.check("polled: the poll thread is stuck (no sample for more than 1.5 s before the position): unknown, not the old value",
                    sig.read(at: at(11.5)) == .unmuted && sig.read(at: at(11.8)) == .unknown)
            for i in 0..<100 { sig.sample(at: at(10.3 + Double(i) * 0.1)) }
            c.check("polled: the history is about 8 s: an old position is unknown, a recent one is answered", sig.read(at: at(10.5)) == .unknown && sig.read(at: at(19.0)) == .unmuted)
        }

        // polled, real timer
        do {
            final class Probe {
                private let lock = NSLock()
                private var polls = 0
                private var muted = false
                func poll() -> MuteReading { lock.lock(); defer { lock.unlock() }; polls += 1; return muted ? .muted : .unmuted }
                func setMuted(_ value: Bool) { lock.lock(); muted = value; lock.unlock() }
                var count: Int { lock.lock(); defer { lock.unlock() }; return polls }
            }
            let probe = Probe()
            let live = PolledMuteSignal(name: "live", interval: 0.02) { probe.poll() }
            live.start()
            live.start()                                              // idempotent
            Thread.sleep(forTimeInterval: 0.35)
            let polls = probe.count
            c.check("polled (real timer): about every 20 ms from the start (the first poll at once), and it answers for now", polls >= 8 && polls <= 25 && live.read(at: CaptureHAL.Clock.now()) == .unmuted, "polls \(polls)")
            probe.setMuted(true)
            Thread.sleep(forTimeInterval: 0.12)
            c.check("... a change is answered within a few polls", live.read(at: CaptureHAL.Clock.now()) == .muted)
            live.stop()
            let atStop = probe.count
            Thread.sleep(forTimeInterval: 0.15)
            c.check("... stop() ends the polling for good (not one poll after it returned)", probe.count == atStop, "\(atStop) -> \(probe.count)")
        }

        // the call app's input
        do {
            final class World {
                var processes: [AudioObjectID: (pid: pid_t, bundle: String)] = [:]
                var input: [AudioObjectID: Bool] = [:]
            }
            let w = World()
            func probe(_ platform: Platform) -> AppInputMuteProbe? {
                let source = AudioProcessMonitor.Source(list: { w.processes.keys.sorted() },
                                                        identity: { id in w.processes[id].map { (pid: $0.pid, bundleID: $0.bundle) } },
                                                        flags: { id in (input: w.input[id] ?? false, output: false) })
                return AppInputMuteProbe(signal: PlatformSignal(platform: platform, inCall: true), config: AppConfig.defaults(), monitor: AudioProcessMonitor(source: source))
            }
            c.check("app input: a manual recording has no call app to ask (no probe)", probe(.manual) == nil)
            guard let zoom = probe(.zoom) else { c.check("app input: a probe for Zoom", false); return }
            c.check("app input: no audio process of the app: unknown (record)", zoom.read() == .unknown)
            w.processes[1] = (100, "us.zoom.xos")
            c.check("app input: the app is there but its input has never been seen running: unknown (record) - joining muted never zeros the start",
                    zoom.read() == .unknown)
            w.input[1] = true
            c.check("app input: the input is running: unmuted", zoom.read() == .unmuted)
            w.input[1] = false
            c.check("app input: the input stops while the app is still there (after it was seen running): muted", zoom.read() == .muted)
            w.input[1] = true
            c.check("app input: running again: unmuted", zoom.read() == .unmuted)
            w.processes[2] = (200, "us.zoom.caphost")
            w.input[1] = false
            c.check("app input: any process of the family with the input running is enough for unmuted", { () -> Bool in w.input[2] = true; defer { w.input[2] = false }; return zoom.read() == .unmuted }())
            w.processes[3] = (300, FamilyMatcher.ownBundlePrefix)
            w.input[3] = true
            c.check("app input: our own app's process is not the call app (it never counts as input)", zoom.read() == .muted)
            w.processes.removeAll()
            c.check("app input: the process objects are gone (the call ended): unknown, not muted", zoom.read() == .unknown)
            w.processes[1] = (100, "us.zoom.xos")
            w.input[1] = false
            c.check("app input: it is remembered for the rest of the recording that the input was seen: the app back without input is muted", zoom.read() == .muted)
            guard let teams = probe(.teams) else { c.check("app input: a probe for Teams", false); return }
            c.check("app input: another family's process (Zoom, for a Teams probe) says nothing: unknown", teams.read() == .unknown)
            w.processes = [5: (500, "com.google.Chrome.helper")]
            w.input = [5: true]
            guard let meet = probe(.meet) else { c.check("app input: a probe for Meet", false); return }
            c.check("app input: Meet's family is the browser (a Chrome helper with the input running: unmuted, input dropped: muted)",
                    meet.read() == .unmuted && { () -> Bool in w.input[5] = false; return meet.read() == .muted }())
        }

        // the device's mute properties (a fake HAL)
        do {
            typealias Props = CaptureHAL.InputMuteProperties
            let main = kAudioObjectPropertyElementMain
            func props(mute: [UInt32: UInt32] = [:], volume: [UInt32: Float32] = [:], channels: Int = 2) -> Props {
                Props(supports: { _, selector, element in
                          (selector == kAudioDevicePropertyMute && mute[element] != nil) || (selector == kAudioDevicePropertyVolumeScalar && volume[element] != nil) },
                      readUInt32: { _, selector, element in selector == kAudioDevicePropertyMute ? mute[element] : nil },
                      readFloat32: { _, selector, element in selector == kAudioDevicePropertyVolumeScalar ? volume[element] : nil },
                      inputChannels: { _ in channels })
            }
            func reading(_ p: Props) -> MuteReading { CaptureHAL.inputMuteReading(device: 7, properties: p) }
            c.check("device: the mute switch on (main element): muted", reading(props(mute: [main: 1])) == .muted)
            c.check("device: switch off and volume 0.8: unmuted", reading(props(mute: [main: 0], volume: [main: 0.8])) == .unmuted)
            c.check("device: only a switch, and off: unmuted", reading(props(mute: [main: 0])) == .unmuted)
            c.check("device: input volume 0: muted (nothing is recorded)", reading(props(volume: [main: 0])) == .muted)
            c.check("device: input volume at the 0.001 threshold: muted, a hair above it: unmuted",
                    reading(props(volume: [main: 0.001])) == .muted && reading(props(volume: [main: 0.0011])) == .unmuted)
            c.check("device: switch off but volume 0: muted (either one is enough)", reading(props(mute: [main: 0], volume: [main: 0])) == .muted)
            c.check("device: per-channel switches (no main element): both channels muted: muted; one channel only: unmuted",
                    reading(props(mute: [1: 1, 2: 1])) == .muted && reading(props(mute: [1: 1, 2: 0])) == .unmuted)
            c.check("device: per-channel volumes: both 0: muted; one above 0: unmuted", reading(props(volume: [1: 0, 2: 0])) == .muted && reading(props(volume: [1: 0, 2: 0.5])) == .unmuted)
            c.check("device: neither property (an aggregate, a virtual device): unknown, never 'unmuted'", reading(props()) == .unknown && reading(props(channels: 0)) == .unknown)
            let unreadable = Props(supports: { _, selector, _ in selector == kAudioDevicePropertyMute }, readUInt32: { _, _, _ in nil },
                                   readFloat32: { _, _, _ in nil }, inputChannels: { _ in 2 })
            c.check("device: a property that is there but cannot be read: unknown", reading(unreadable) == .unknown)
            if let device = CaptureHAL.defaultDevice(input: true) {
                let live = CaptureHAL.inputMuteReading(device: device)
                print("  info  default input '\(CaptureHAL.deviceName(device) ?? "?")': mute reading right now = \(live) (read-only, no permission)")
                c.check("device: the real default input device answers with one of the three values (read-only query)", [.muted, .unmuted, .unknown].contains(live))
            } else {
                print("  SKIP  real default input device (none on this Mac)")
            }
        }

        // the production wiring that a synthetic recorder never uses (nothing is started, nothing needs a permission)
        do {
            let mic = MicCapture(sampleRate: 48000)
            let offered = mic.muteSignals()
            c.check("MicCapture offers its device's mute state as the 'device' signal; before start() no device is open, so it says unknown",
                    offered.count == 1 && offered[0].name == "device" && offered[0].read(at: CaptureHAL.Clock.now()) == .unknown && mic.currentInputDevice == nil)
            if let live = AppInputMuteProbe(signal: PlatformSignal(platform: .zoom, inCall: true), config: AppConfig.defaults()) {
                let reading = live.read()
                print("  info  Zoom's input on this Mac right now (read-only process list): \(reading)")
                c.check("the app probe reads the real Core Audio process list without a permission and answers with one of the three values", [.muted, .unmuted, .unknown].contains(reading))
            }
        }

        // the script of the synthetic run
        do {
            let ok = MuteScript.parse(" 1.6-3.0 , 4.4-5.2 ")
            c.check("mute script: 'a-b,c-d' in seconds, spaces allowed", ok?.count == 2 && ok?[0].from == 1.6 && ok?[0].to == 3.0 && ok?[1].from == 4.4 && ok?[1].to == 5.2)
            c.check("mute script: a single span", MuteScript.parse("0.8-1.4")?.count == 1)
            let bad = ["", "abc", "3-1", "1-1", "-1-2", "1.0-2.0,2.2-3.0", "1.0-2.0,0.5-0.9", "1-2-3", "1-70", "1-2,", "nan-3", "1-inf"]
            c.check("mute script: reversed, empty, negative, overlapping, too close (< 0.5 s apart), out of range and garbage scripts are refused",
                    bad.allSatisfy { MuteScript.parse($0) == nil }, bad.filter { MuteScript.parse($0) != nil }.joined(separator: " | "))
            let builtIn = MuteScript.effective(environment: [:])
            let override = MuteScript.effective(environment: [MuteScript.environmentKey: "0.8-1.4"])
            let broken = MuteScript.effective(environment: [MuteScript.environmentKey: "oops"])
            c.check("mute script: built-in without the variable, the variable replaces it, an unusable value falls back with a note",
                    builtIn.spans.count == 2 && builtIn.note == "built-in script" && override.spans.count == 1 && override.spans[0].to == 1.4
                    && override.note.contains(MuteScript.environmentKey) && broken.spans.count == 2 && broken.note.contains("not a usable script"))
        }
    }

    /// Real Recorders with synthetic sources, running at the same time: the built-in mute script (or MC_SELFTEST_MUTE_SCRIPT) through the
    /// whole path (delay line, WavWriter, session.json, private sidecar), against a control without the gate; the manual pause; the meter
    /// before the gate; a gate that never hears a signal; a crash; a gap fill.
    private static func testMuteGateRecorders(_ c: Checker, config baseConfig: AppConfig, dir: URL) {
        let script = MuteScript.effective()
        print("-- mute gate in real Recorders (synthetic sources, 7 recorders at once; \(script.note))")
        let fm = FileManager.default
        var config = baseConfig
        let support = dir.appendingPathComponent("mute_support", isDirectory: true)
        try? fm.removeItem(at: support)
        config.supportDir = support
        let spans = script.spans
        let duration = max(6.0, (spans.last?.to ?? 0) + 1.6)
        let baseKeys: Set<String> = ["schema", "session_id", "platform", "platform_label", "title_hint", "meeting_url", "app_bundle_id",
                                     "start_time", "end_time", "end_reason", "tracks", "app_version", "warnings", "remote_silent_suspected"]
        let rate = 48_000

        struct Run { var name: String; var rec: Recorder; var dir: URL; var mic: ObservedSource; var scripted: ScriptedMuteSignal? }
        func make(_ name: String, gate: Bool, scripted useScript: Bool = false, stalls: [SyntheticCaptureSource.Stall] = []) -> Run {
            let sessionDir = dir.appendingPathComponent("2026-10-07_1800_\(name)")
            try? fm.removeItem(at: sessionDir)
            let scripted = useScript ? ScriptedMuteSignal(spans: spans) : nil
            let mic = ObservedSource(SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200,
                                                            amplitude: 0.3, startDelay: 0.1, stalls: stalls),
                                     onFirst: { scripted?.anchor(at: $0) })
            let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: 0.3)
            let signal = PlatformSignal(platform: .zoom, inCall: true, bundleID: "us.zoom.xos")
            let list: [MuteSignalSource] = scripted.map { [$0 as MuteSignalSource] } ?? []
            let rec = Recorder(sessionDir: sessionDir, signal: signal, config: config, remote: { remote }, mic: { mic }, muteSignals: { list })
            rec.configureMuteGate(enabled: gate)
            return Run(name: name, rec: rec, dir: sessionDir, mic: mic, scripted: scripted)
        }
        let scripted = make("scripted", gate: true, scripted: true)
        let control = make("control", gate: false)
        let manual = make("manual", gate: true)
        let meter = make("meter", gate: true)
        let failOpen = make("failopen", gate: true)
        let crash = make("crash", gate: true)
        let gapGate = make("gap-gate", gate: true, stalls: [.init(start: 1.0, duration: 1.0)])
        let gapControl = make("gap-control", gate: false, stalls: [.init(start: 1.0, duration: 1.0)])
        let runs = [scripted, control, manual, meter, failOpen, crash, gapGate, gapControl]

        c.check("setMicrophonePaused before start() is refused (nothing is recording)", manual.rec.setMicrophonePaused(true) == false && !manual.rec.microphonePaused)
        c.check("a recorder that was asked for the gate reports it; one that was not does not",
                scripted.rec.muteGateEnabled && manual.rec.muteGateEnabled && !control.rec.muteGateEnabled && !gapControl.rec.muteGateEnabled)
        for r in runs {
            do { try r.rec.start() } catch { c.check("\(r.name): start()", false, "\(error)"); return }
        }
        let startedAt = Date()
        func wait(until t: Double) { let d = t - Date().timeIntervalSince(startedAt); if d > 0 { Thread.sleep(forTimeInterval: d) } }

        c.check("setMicrophonePaused without a gate (the control) is refused: no gate, no pause", control.rec.setMicrophonePaused(true) == false && !control.rec.microphonePaused)
        // meter: paused as soon as the first audio is there, never resumed
        _ = waitUntil(2.0) { meter.mic.frames > 4800 }
        c.check("manual pause is accepted while a gated recording runs", meter.rec.setMicrophonePaused(true) && meter.rec.microphonePaused)
        // manual: paused 1.0 s .. 3.0 s
        wait(until: 1.0)
        let pauseHost = CaptureHAL.Clock.now()
        let pauseAccepted = manual.rec.setMicrophonePaused(true)
        c.check("manual: Pause Microphone is accepted and shows as paused", pauseAccepted && manual.rec.microphonePaused)
        wait(until: 3.0)
        let meterLevel = Double(meter.rec.recentLevelsDB.mic)
        let manualLevel = Double(manual.rec.recentLevelsDB.mic)
        let resumeHost = CaptureHAL.Clock.now()
        c.check("manual: Resume Microphone is accepted", manual.rec.setMicrophonePaused(false) && !manual.rec.microphonePaused)
        // crash: killed at 3.0 s
        let crashDelivered = crash.mic.frames
        crash.rec.simulateCrashForTest()
        wait(until: duration)
        for r in runs where r.name != "crash" { _ = r.rec.stop(reason: .manual) }
        c.check("setMicrophonePaused after stop() is refused", manual.rec.setMicrophonePaused(true) == false)

        func json(_ r: Run) -> [String: Any]? {
            (try? Data(contentsOf: r.dir.appendingPathComponent("session.json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
        func mic(_ r: Run) -> (samples: [Float], info: WavFileInfo)? { readSamples(r.dir.appendingPathComponent("mic.wav")) }
        func offset(_ r: Run) -> Double { (((json(r)?["tracks"] as? [String: Any])?["mic"] as? [String: Any])?["start_offset_sec"] as? Double) ?? -1 }
        func gateObject(_ r: Run) -> [String: Any]? { json(r)?["mic_gate"] as? [String: Any] }
        func keys(_ o: [String: Any]?) -> Set<String> { Set((o ?? [:]).keys) }
        func window(_ s: [Float], _ from: Double, _ to: Double) -> Double {
            let a = max(0, Int(from * Double(rate))), b = min(s.count, Int(to * Double(rate)))
            return rmsDB(s[a..<max(a, b)])
        }
        func allZero(_ s: [Float], _ from: Double, _ to: Double) -> Bool {
            let a = max(0, Int((from * Double(rate)).rounded())), b = min(s.count, Int((to * Double(rate)).rounded()))
            return a < b && s[a..<b].allSatisfy { $0 == 0 }
        }
        func sidecarSpans(_ r: Run) -> [[String: Any]] {
            (SessionPrivateLog.read(session: r.dir.lastPathComponent, supportDir: support)?[Recorder.muteSpansKey] as? [[String: Any]]) ?? []
        }
        let tone: ClosedRange<Double> = -16 ... -11            // amplitude 0.3: RMS -13.5 dBFS

        // --- the scripted run against the control
        guard let sj = mic(scripted), let cj = mic(control) else { c.check("scripted and control mic.wav can be read", false); return }
        print("  info  script: \(spans.map { String(format: "%.2f-%.2f", $0.from, $0.to) }.joined(separator: ", ")) s; mic.wav \(String(format: "%.2f", sj.info.seconds)) s (control \(String(format: "%.2f", cj.info.seconds)) s)")
        c.check("scripted: mic.wav is as long as the audio that was delivered (every frame, to the sample: the delay line was flushed at stop())",
                scripted.rec.gapCounts.mic == 0 ? sj.info.frames == Int64(scripted.mic.frames) : sj.info.frames >= Int64(scripted.mic.frames),
                "file \(sj.info.frames) delivered \(scripted.mic.frames) gaps \(scripted.rec.gapCounts.mic)")
        c.check("scripted: the same length as the control without the gate (within 60 ms: both started within a few ms of each other)", abs(sj.info.seconds - cj.info.seconds) < 0.06,
                String(format: "%.3f vs %.3f", sj.info.seconds, cj.info.seconds))
        c.check("scripted: start_offset_sec is the control's (the gate does not move the timeline) and about the source's start delay of 0.1 s",
                abs(offset(scripted) - offset(control)) < 0.05 && abs(offset(scripted) - 0.10) < 0.12, "\(offset(scripted)) vs \(offset(control))")
        for (i, s) in spans.enumerated() {
            c.check(String(format: "scripted: span %d (%.2f - %.2f s) is EXACTLY zero in mic.wav (every sample)", i + 1, s.from, s.to), allZero(sj.samples, s.from, s.to))
            // a neighbouring span closer than 0.9 s would put its own zeros into the window: that side is not judged then
            let nearBefore = i > 0 && s.from - spans[i - 1].to < 0.9, nearAfter = i + 1 < spans.count && spans[i + 1].from - s.to < 0.9
            let before = window(sj.samples, s.from - 0.40, s.from - 0.34), after = window(sj.samples, s.to + 0.20, s.to + 0.30)
            c.check(String(format: "scripted: span %d: the audio right before (%.2f s) and after (%.2f s) it is intact: the zeros do not run on", i + 1, s.from - 0.4, s.to + 0.2),
                    (nearBefore || tone.contains(before)) && (nearAfter || tone.contains(after)), String(format: "before %.1f dB after %.1f dB", before, after))
            c.check(String(format: "control: the same span is audio (%.1f dB): without the gate nothing is zeroed", window(cj.samples, s.from, s.to)), tone.contains(window(cj.samples, s.from, s.to)))
        }
        c.check("scripted: the audio before the first span is intact", tone.contains(window(sj.samples, 0.20, (spans.first?.from ?? 1) - 0.40)) || (spans.first?.from ?? 1) < 0.65)

        let sObj = json(scripted)
        c.check("scripted: session.json has exactly the keys it always had plus mic_gate (the capture self test's exact-key assertion, extended only for mic_gate)",
                keys(sObj) == baseKeys.union(["mic_gate"]), "\(keys(sObj).symmetricDifference(baseKeys))")
        let sGate = gateObject(scripted)
        let totalSpan = spans.reduce(0) { $0 + ($1.to - $1.from) }
        let muted = (sGate?["muted_seconds"] as? Double) ?? -1
        c.check("scripted: mic_gate holds exactly enabled / signals / muted_seconds / unknown_seconds",
                keys(sGate) == ["enabled", "signals", "muted_seconds", "unknown_seconds"] && (sGate?["enabled"] as? Bool) == true && (sGate?["signals"] as? [String]) == ["scripted"],
                "\(String(describing: sGate))")
        c.check(String(format: "scripted: muted_seconds = the spans (%.1f s) plus the 0.3 s backdate of each (%d spans) and up to a chunk of release", totalSpan, spans.count),
                muted >= totalSpan + Double(spans.count) * 0.29 && muted <= totalSpan + Double(spans.count) * 0.55, "muted_seconds \(muted)")
        c.check("scripted: unknown_seconds is 0 (the signal answered all the time) and session.json has no warnings",
                ((sGate?["unknown_seconds"] as? Double) ?? -1) < 0.05 && ((sObj?["warnings"] as? [String]) ?? ["?"]).isEmpty, "\(String(describing: sObj?["warnings"]))")
        let side = sidecarSpans(scripted)
        c.check("scripted: the private sidecar (SUPPORT_DIR/session-private) has one entry per span, each covering its span, naming the signal",
                side.count == spans.count && zip(side, spans).allSatisfy { e, s in
                    (e["start"] as? Double ?? 99) <= s.from && (e["end"] as? Double ?? -1) >= s.to && (e["start"] as? Double ?? -99) >= s.from - 0.35
                        && (e["end"] as? Double ?? 99) <= s.to + 0.25 && (e["signals"] as? [String]) == ["scripted"] && (e["at"] as? String)?.isEmpty == false },
                "\(side)")
        let folder = ((try? fm.contentsOfDirectory(atPath: scripted.dir.path)) ?? []).sorted()
        var spansInFolder = false
        for name in folder { if let text = try? String(contentsOf: scripted.dir.appendingPathComponent(name), encoding: .isoLatin1), text.contains(Recorder.muteSpansKey) { spansInFolder = true } }
        c.check("scripted: the spans are not in the session folder that goes to Drive (only the aggregate is)", !spansInFolder && folder == ["mic.wav", "remote.wav", "session.json"], "\(folder)")

        let cObj = json(control)
        c.check("control (no gate): exactly the old keys, no mic_gate, no sidecar at all", keys(cObj) == baseKeys && SessionPrivateLog.read(session: control.dir.lastPathComponent, supportDir: support) == nil)

        // --- the manual pause: guaranteed, needs no signal
        if let mj = mic(manual) {
            let first = manual.mic.firstHost.map { CaptureHAL.Clock.seconds($0) } ?? 0
            let pausedAt = CaptureHAL.Clock.seconds(pauseHost) - first, resumedAt = CaptureHAL.Clock.seconds(resumeHost) - first
            c.check(String(format: "manual: mic.wav is EXACTLY zero from the click (%.2f s) to the resume (%.2f s)", pausedAt, resumedAt), allZero(mj.samples, pausedAt, resumedAt))
            c.check("manual: the audio before the pause (up to 0.4 s earlier) and after the resume (from 0.25 s later) is intact",
                    tone.contains(window(mj.samples, 0.2, pausedAt - 0.40)) && tone.contains(window(mj.samples, resumedAt + 0.25, resumedAt + 0.9)),
                    String(format: "before %.1f after %.1f", window(mj.samples, 0.2, pausedAt - 0.40), window(mj.samples, resumedAt + 0.25, resumedAt + 0.9)))
            let mg = gateObject(manual)
            let m = (mg?["muted_seconds"] as? Double) ?? -1
            c.check(String(format: "manual: mic_gate says signals ['manual'], muted_seconds about the pause (%.1f s + 0.3 s backdate)", resumedAt - pausedAt),
                    (mg?["signals"] as? [String]) == ["manual"] && m >= resumedAt - pausedAt + 0.2 && m <= resumedAt - pausedAt + 0.6, "\(String(describing: mg))")
            c.check("manual: while nothing is paused the gate has no opinion: the rest is unknown_seconds (recorded)", ((mg?["unknown_seconds"] as? Double) ?? 0) > 1.5, "\(String(describing: mg?["unknown_seconds"]))")
            let ms = sidecarSpans(manual)
            c.check("manual: one span in the sidecar, from the pause to the resume, signal 'manual'", ms.count == 1 && (ms.first?["signals"] as? [String]) == ["manual"], "\(ms)")
            c.check("manual: the meter still shows the tone during the pause (\(String(format: "%.1f", manualLevel)) dB)", tone.contains(manualLevel))
        } else { c.check("manual: mic.wav can be read", false) }

        // --- the meter before the gate: paused all along, the level is still the microphone's
        if let tj = mic(meter) {
            c.check("meter: paused from the first audio on: mic.wav is zero all through", allZero(tj.samples, 0, tj.info.seconds))
            c.check(String(format: "meter: recentLevelsDB reads the microphone BEFORE the gate (%.1f dB while the file is digital silence): the no-speech auto-stop and the remote-silence rule see the audio", meterLevel),
                    tone.contains(meterLevel), String(format: "%.1f dB", meterLevel))
            c.check("meter: the recorder did not call this a missing microphone (no 'no audio' warning)", !((json(meter)?["warnings"] as? [String]) ?? []).contains { $0.contains("produced no audio") || $0.contains("delivered no audio") })
        } else { c.check("meter: mic.wav can be read", false) }

        // --- a gate that never hears anything: fail-open
        if let fj = mic(failOpen) {
            let fg = gateObject(failOpen)
            c.check("fail-open: no signal, nobody paused: mic.wav is the audio in full (nothing zeroed)", tone.contains(window(fj.samples, 0.2, fj.info.seconds - 0.1)) && !allZero(fj.samples, 1.0, 1.5))
            c.check("fail-open: mic_gate says so: no signal answered, nothing muted, the whole recording is unknown_seconds",
                    (fg?["signals"] as? [String]) == [] && (fg?["muted_seconds"] as? Double) == 0 && abs(((fg?["unknown_seconds"] as? Double) ?? 0) - fj.info.seconds) < 0.1, "\(String(describing: fg))")
            let warnings = (json(failOpen)?["warnings"] as? [String]) ?? []
            c.check("fail-open: session.json carries a timestamped warning that the microphone was recorded in full", warnings.contains { $0.contains("recorded in full (fail-open)") }, "\(warnings)")
            c.check("fail-open: no sidecar (there was no span)", sidecarSpans(failOpen).isEmpty)
        } else { c.check("fail-open: mic.wav can be read", false) }

        // --- a crash loses the last 0.5 s of the microphone, nothing else
        do {
            let info = WavFileInfo.read(crash.dir.appendingPathComponent("mic.wav"))
            let lost = Double(Int64(crashDelivered) - (info?.frames ?? 0)) / Double(rate)
            let remoteInfo = WavFileInfo.read(crash.dir.appendingPathComponent("remote.wav"))
            let obj = json(crash)
            c.check(String(format: "crash: the microphone file ends 0.5 s early (%.2f s of what was delivered is lost: the delay line), the remote file does not", lost),
                    lost >= 0.40 && lost <= 0.62 && (remoteInfo?.seconds ?? 0) > 2.5, String(format: "lost %.3f s, remote %.2f s", lost, remoteInfo?.seconds ?? -1))
            c.check("crash: session.json was left as a crash leaves it (end_time null) and already carries mic_gate",
                    obj?["end_time"] is NSNull && (obj?["mic_gate"] as? [String: Any]) != nil, "\(String(describing: obj?["end_time"]))")
        }

        // --- a gap fill: the line is flushed in front of the silence, the length stays what it is without the gate
        if let gj = mic(gapGate), let gc = mic(gapControl) {
            c.check("gap: the gated microphone has the same length as the control (within 60 ms) and one gap fill each",
                    abs(gj.info.seconds - gc.info.seconds) < 0.06 && gapGate.rec.gapCounts.mic == 1 && gapControl.rec.gapCounts.mic == 1,
                    String(format: "%.3f vs %.3f, gaps %d / %d", gj.info.seconds, gc.info.seconds, gapGate.rec.gapCounts.mic, gapControl.rec.gapCounts.mic))
            c.check("gap: the audio before the gap is where it was (a tone up to 0.85 s), the gap itself is digital silence (0.95 - 1.85 s), the audio after it is back (2.1 s on)",
                    tone.contains(window(gj.samples, 0.2, 0.85)) && allZero(gj.samples, 0.95, 1.85) && tone.contains(window(gj.samples, 2.1, 2.8)),
                    String(format: "before %.1f gap-zero %@ after %.1f", window(gj.samples, 0.2, 0.85), allZero(gj.samples, 0.95, 1.85) ? "yes" : "no", window(gj.samples, 2.1, 2.8)))
            c.check("gap: the same picture without the gate (control)", tone.contains(window(gc.samples, 0.2, 0.85)) && allZero(gc.samples, 0.95, 1.85) && tone.contains(window(gc.samples, 2.1, 2.8)))
        } else { c.check("gap: mic.wav can be read", false) }
        print("  files: \(dir.path)/2026-10-07_1800_*")
    }

    // MARK: live mode (real devices; needs permissions; run from the signed app only)

    /// FAILS CLOSED: before anything is created or opened it requires MC_SELFTEST_LIVE=1 AND a launchd / LaunchServices start
    /// of the signed app (`LaunchGuard.isSignedAppLaunch`); otherwise it prints why (and how to run it properly) to stderr
    /// and returns 2. The two parameters are the test seam; production uses the defaults.
    static func runLive(config: AppConfig, seconds: Int, outDir: URL,
                        signedAppLaunch: Bool = LaunchGuard.isSignedAppLaunch,
                        env: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        if let refusal = CapturePermissionGuard.liveSelfTestRefusal(signedAppLaunch: signedAppLaunch, env: env) {
            FileHandle.standardError.write(Data((refusal + "\n").utf8))
            Log.warn("selftest-capture: live mode refused (not the signed app started by LaunchServices, or MC_SELFTEST_LIVE not set)")
            return 2
        }
        let duration = max(6, seconds)
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let sessionDir = outDir.appendingPathComponent("selftest_\(stamp)")
        let signal = PlatformSignal(platform: .manual, inCall: true, titleHint: "capture self-test", bundleID: Bundle.main.bundleIdentifier)
        let rec = Recorder(sessionDir: sessionDir, signal: signal, config: config)
        rec.promptForPermissions = true                      // self-test is a setup-like path: prompts are allowed
        let lock = NSLock()
        var warnings: [String] = []
        rec.onWarning = { lock.lock(); warnings.append($0); lock.unlock() }

        func emit(_ report: [String: Any]) {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) { print(text) }
        }

        do {
            try rec.start()
        } catch {
            emit(["verdict": "FAIL", "reasons": ["Recorder.start() failed: \(error)"], "session_dir": sessionDir.path])
            return 1
        }

        // Make the remote track non-silent: speak through the default output after ~1.5 s, and keep speaking (phrase, one second
        // of pause, phrase ...) until the recording is over. One phrase is not enough to exercise the tap host strategy of a
        // USB / Bluetooth speakerphone: an unproven strategy is re-created after 10 s of digital silence, but only while some
        // other process has audio output open, so there has to be sound playing around that moment (use --seconds 30 for it).
        let speakUntil = Date().addingTimeInterval(TimeInterval(duration) - 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            while Date() < speakUntil {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                p.arguments = ["Meeting capture audio test. One, two, three, four, five. Acme A I Read."]
                do { try p.run(); p.waitUntilExit() } catch { Log.warn("selftest: cannot run say: \(error)"); return }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        Thread.sleep(forTimeInterval: TimeInterval(duration))
        let endLevels = rec.recentLevelsDB
        let summary = rec.stop(reason: .manual)

        var reasons: [String] = []
        var report: [String: Any] = ["session_dir": sessionDir.path, "requested_seconds": duration]
        var offsets: [String: Double] = [:]
        if let data = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json")),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tracks = obj["tracks"] as? [String: Any] {
            for (k, v) in tracks { if let t = v as? [String: Any], let o = t["start_offset_sec"] as? Double { offsets[k] = o } }
            report["devices"] = tracks.mapValues { ($0 as? [String: Any])?["device"] ?? "" }
        }
        report["offsets"] = offsets

        func analyze(_ name: String) -> (seconds: Double, rms: Double, peakWindow: Double, digitalSilence: Bool)? {
            guard let (s, info) = readSamples(sessionDir.appendingPathComponent("\(name).wav")) else { return nil }
            return (info.seconds, rmsDB(s[0..<s.count]), peakWindowDB(s, rate: info.sampleRate), (s.map { abs($0) }.max() ?? 0) == 0)
        }
        let remote = analyze("remote"), mic = analyze("mic")
        report["remote_seconds"] = remote?.seconds ?? 0
        report["mic_seconds"] = mic?.seconds ?? 0
        report["remote_rms_db"] = remote?.rms ?? -120
        report["mic_rms_db"] = mic?.rms ?? -120
        report["remote_peak_window_db"] = remote?.peakWindow ?? -120
        report["mic_peak_window_db"] = mic?.peakWindow ?? -120
        report["recent_levels_at_end_db"] = ["mic": endLevels.mic, "remote": endLevels.remote]
        report["warnings"] = summary.warnings

        let minSeconds = Double(duration) * 0.85
        if let r = remote {
            if r.seconds < minSeconds { reasons.append(String(format: "remote.wav too short: %.1f s < %.1f s", r.seconds, minSeconds)) }
            if r.peakWindow < -50 {
                reasons.append(String(format: "remote track is silent (loudest 100 ms window %.1f dBFS): the 'say' phrase was not captured. "
                                      + "Check System Settings > Privacy & Security > System Audio Recording for \(AppInfo.displayName), "
                                      + "NSAudioCaptureUsageDescription in Info.plist, and that the output volume is not muted. "
                                      + "The 'tap host strategy' lines in app.log say how the tap was clocked, and `devices.remote` above shows it too (a USB / "
                                      + "Bluetooth speakerphone as default output uses the built-in output first, then tap-only, then the device itself, "
                                      + "switching after silence: run with --seconds 30, or pin one with "
                                      + "`open --env MC_TAP_HOST=builtin|default|tap-only`)", r.peakWindow))
            }
        } else {
            reasons.append("remote.wav missing or empty (system audio tap did not start)")
        }
        if let j = mic {
            if j.seconds < minSeconds { reasons.append(String(format: "mic.wav too short: %.1f s < %.1f s", j.seconds, minSeconds)) }
            if j.digitalSilence { reasons.append("mic.wav is digital silence (microphone muted or permission not effective)") }
        } else {
            reasons.append("mic.wav missing or empty (microphone did not start)")
        }
        report["verdict"] = reasons.isEmpty ? "PASS" : "FAIL"
        report["reasons"] = reasons
        emit(report)
        return reasons.isEmpty ? 0 : 1
    }
}
