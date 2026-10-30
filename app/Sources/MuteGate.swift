import Foundation
import CoreAudio

// =====================================================================================
// MuteGate: mute-aware microphone capture (SPEC 18; MIC_MUTE_GATE=on).
//
// The microphone track records the default input device, so someone who mutes himself in Zoom / Teams / Meet is still recorded. With
// MIC_MUTE_GATE=on the microphone samples pass through a short delay line in front of the WavWriter; while a POSITIVE mute signal holds,
// the delay line hands the writer exact zeros instead of the audio. Nothing else changes: zeros are written where the audio would have
// been, so the timeline, the length of mic.wav and start_offset_sec are what they are without the gate, and the level meter and the
// no-speech auto-stop keep reading the audio BEFORE the gate (a muted microphone with speech behind it is not 'no speech').
//
//   signals      MuteSignalSource.read(at: host) -> muted | unmuted | unknown. Sources, in the order of SPEC 18: the input device
//                (kAudioDevicePropertyMute / VolumeScalar: no permission), the meeting app's IsRunningInput dropping while the call is on
//                (UNVERIFIED per app: docs/LIVE_TEST.md L-21..L-26 measure it) and the manual 'Pause Microphone' menu item, the one path that
//                is guaranteed. A real source keeps its own short history (PolledMuteSignal), so the answer is for the host time asked.
//   combination  any source says muted -> muted (a positive signal wins); else any says unmuted -> unmuted; else unknown. UNKNOWN = RECORD
//                (fail-open): a gate that cannot tell never loses speech, and the session.json aggregate says how long that was.
//   engage       the first chunk whose end reads muted: the zeros start engageBackdateSeconds (0.3 s) BEFORE that point, inside the 0.5 s
//                delay line (the signal lags the click and the polls have a period).
//   release      the first non-muted reading starts a run; when the run has held for releaseDebounceSeconds (0.2 s) the zeros end where
//                the run began. A muted reading inside the run cancels it (a flapping signal never releases early). unknown releases too.
//   delay line   releases samples 0.5 s late. stop() flushes it (the file has every frame it would have had), a gap fill flushes it first
//                and then advances the gate's timeline by the gap, a crash loses the last 0.5 s of microphone audio (accepted).
//
// The gate itself reads no clock: its time is the host time of the chunks it is given (virtual in the self test). The polling clock lives in
// PolledMuteSignal. Thread safety: filter / flush / the readers take one internal lock, so the recorder's work queue can feed it while the
// session.json writer reads the counters.
// =====================================================================================

// MARK: - Signals

enum MuteReading: Equatable { case muted, unmuted, unknown }

/// One opinion about 'is the microphone muted'. `host` = mach host time of the audio position the answer is for.
protocol MuteSignalSource {
    var name: String { get }
    func read(at host: UInt64) -> MuteReading
}

/// A source that polls on a thread of its own: the recorder starts it with the recording and stops it before the files are closed.
protocol MuteSignalLifecycle: AnyObject {
    func start()
    func stop()
}

/// A capture source that can describe the mute state of its own input device (MicCapture). A synthetic source does not.
protocol MuteSignalProviding: AnyObject {
    func muteSignals() -> [MuteSignalSource]
}

/// What the controller may use of a recorder for the microphone gate (an optional capability, like SessionRecordingPrivacy: a recorder
/// without it, a fake in a test, still records).
protocol SessionRecordingMicGate: AnyObject {
    /// Before start(): MIC_MUTE_GATE on or off for THIS recording. Never called, or false = no delay line, no `mic_gate` in session.json,
    /// the bytes of mic.wav are what they always were.
    func configureMuteGate(enabled: Bool)
    var muteGateEnabled: Bool { get }
    /// The menu item 'Pause Microphone': while true the gate sees a positive manual mute signal. false = not accepted (no gate, not recording).
    @discardableResult
    func setMicrophonePaused(_ paused: Bool) -> Bool
    var microphonePaused: Bool { get }
}

// MARK: - The gate

struct MuteGateConfig: Equatable {
    var enabled: Bool
    var delayLineSeconds = 0.5
    var engageBackdateSeconds = 0.3
    var releaseDebounceSeconds = 0.2
    /// The rate of the samples the gate is given (the Recorder's fixed file rate). Additive to the design's sketch: the gate has to turn
    /// seconds into frames, and it reads no clock to learn the rate from.
    var sampleRate = 48_000.0
}

final class MuteGate {
    /// One stretch of zeros, in seconds of the track's own timeline (mic.wav file time), and who asked for it.
    struct Span: Equatable {
        var start: Double
        var end: Double
        var signals: [String]
    }

    enum Event: Equatable {
        case engaged(at: Double, signals: [String])     // zeros from `at` (already backdated) until a release
        case released(Span)
    }

    let config: MuteGateConfig
    private let sources: [MuteSignalSource]
    private let rate: Double
    private let delayFrames: Int
    private let backdateFrames: Int64
    private let debounceFrames: Int64

    private let lock = NSLock()
    private var held: [Float] = []                      // frames [outEnd, inEnd): accepted, not yet handed to the writer
    private var inEnd: Int64 = 0
    private var outEnd: Int64 = 0
    private var openStart: Int64?                       // a mute is in force from this frame (the backdated start)
    private var openSignals: [String] = []
    private var unmutedRunStart: Int64?                 // the first non-muted reading of the current run while a mute is in force
    private var runUnknownFrames: Int64 = 0
    private var pending: [(start: Int64, end: Int64)] = []   // closed spans whose frames are not all handed out yet
    private var events: [Event] = []
    private var definite = Set<String>()                // sources that gave at least one muted / unmuted answer
    private var mutedFrames: Int64 = 0
    private var unknownFrames: Int64 = 0

    init(config: MuteGateConfig, signals: [MuteSignalSource]) {
        self.config = config
        self.sources = signals
        self.rate = max(config.sampleRate, 1)
        self.delayFrames = max(0, Int((config.delayLineSeconds * rate).rounded()))
        // The backdate has to fit inside the delay line, or the zeros could not reach back that far.
        self.backdateFrames = min(Int64((max(0, config.engageBackdateSeconds) * rate).rounded()), Int64(delayFrames))
        self.debounceFrames = Int64((max(0, config.releaseDebounceSeconds) * rate).rounded())
    }

    // MARK: audio path

    /// The chunk goes into the delay line and the same number of frames comes out again, oldest first, with the zeros of every span
    /// applied (the first calls return fewer: the line is still filling). `hostTime` = host time of the chunk's first sample. Disabled
    /// = the chunk itself, at once.
    func filter(_ samples: [Float], hostTime: UInt64) -> [Float] {
        guard config.enabled else { return samples }
        guard !samples.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        held.append(contentsOf: samples)
        inEnd += Int64(samples.count)
        // The answer is for the END of the chunk: that is the newest audio the gate has, and a mute that started in it is found now.
        let readHost = hostTime &+ CaptureHAL.Clock.ticks(seconds: Double(samples.count) / rate)
        let (reading, names) = pollLocked(at: readHost)
        advanceLocked(reading, names, chunk: samples.count)
        return releaseLocked(keeping: delayFrames)
    }

    /// Hands out everything still held (the state of the moment decides about the zeros). The recorder calls it before it writes a gap fill
    /// of `skipping` frames itself, so the order in the file stays right; the gate's timeline moves on by the gap.
    func flushForGap(skipping frames: Int) -> [Float] {
        guard config.enabled else { return [] }
        lock.lock(); defer { lock.unlock() }
        let tail = releaseLocked(keeping: 0)
        let n = Int64(max(0, frames))
        inEnd += n
        outEnd += n
        return tail
    }

    /// The end of the recording: everything still held is handed out and a mute that is still in force ends with the file.
    func finish() -> [Float] {
        guard config.enabled else { return [] }
        lock.lock(); defer { lock.unlock() }
        let tail = releaseLocked(keeping: 0)
        if let start = openStart { closeSpanLocked(start: start, end: inEnd) }
        return tail
    }

    // MARK: readers (any thread)

    /// Frames accepted by the gate and not yet handed to the writer (the recorder's timeline is writer.framesWritten + this).
    var heldFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return held.count
    }

    /// Seconds of zeros handed out because of a mute (no more than the muted time, plus the backdates).
    var mutedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(mutedFrames) / rate
    }

    /// Seconds recorded while no source gave an answer at all (fail-open). A device that says 'not muted' is an answer.
    var unknownSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(unknownFrames) / rate
    }

    /// The sources that gave at least one muted / unmuted answer, in the order they were configured.
    var signalNames: [String] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return sources.map { $0.name }.filter { definite.contains($0) && seen.insert($0).inserted }
    }

    /// Every source the gate asks, answered or not.
    var configuredSignals: [String] { sources.map { $0.name } }

    /// A mute is in force right now.
    var isEngaged: Bool {
        lock.lock(); defer { lock.unlock() }
        return openStart != nil
    }

    /// What happened since the last call: an engage, a release with its span. Drains.
    func takeEvents() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        defer { events.removeAll() }
        return events
    }

    // MARK: state machine (lock held)

    private func pollLocked(at host: UInt64) -> (MuteReading, [String]) {
        var muted: [String] = []
        var anyUnmuted = false
        for source in sources {
            switch source.read(at: host) {
            case .muted:
                muted.append(source.name)
                definite.insert(source.name)
            case .unmuted:
                anyUnmuted = true
                definite.insert(source.name)
            case .unknown:
                break
            }
        }
        if !muted.isEmpty { return (.muted, muted) }
        return (anyUnmuted ? .unmuted : .unknown, [])
    }

    private func seconds(_ frame: Int64) -> Double { Double(frame) / rate }

    private func advanceLocked(_ reading: MuteReading, _ names: [String], chunk: Int) {
        let now = inEnd
        switch reading {
        case .muted:
            unmutedRunStart = nil
            runUnknownFrames = 0
            if openStart == nil {
                // Never before what was already handed out, and never into the span that just ended (spans do not overlap: a frame is
                // zeroed, and counted, once).
                let start = max(outEnd, pending.last?.end ?? 0, now - backdateFrames)
                openStart = start
                openSignals = names
                events.append(.engaged(at: seconds(start), signals: names))
            } else {
                for name in names where !openSignals.contains(name) { openSignals.append(name) }
            }
        case .unmuted, .unknown:
            guard let start = openStart else {
                if reading == .unknown { unknownFrames += Int64(chunk) }
                return
            }
            let runStart = unmutedRunStart ?? now
            if unmutedRunStart == nil { unmutedRunStart = runStart }
            if reading == .unknown { runUnknownFrames += Int64(chunk) }
            if now - runStart >= debounceFrames {
                unknownFrames += runUnknownFrames
                closeSpanLocked(start: start, end: runStart)
            }
        }
    }

    private func closeSpanLocked(start: Int64, end: Int64) {
        let last = max(start, end)
        pending.append((start, last))
        events.append(.released(Span(start: seconds(start), end: seconds(last), signals: openSignals)))
        openStart = nil
        openSignals = []
        unmutedRunStart = nil
        runUnknownFrames = 0
    }

    /// Hands out all but the newest `keep` frames, zeros applied. The spans are ordered and do not overlap, so no frame is counted twice.
    private func releaseLocked(keeping keep: Int) -> [Float] {
        let n = held.count - keep
        guard n > 0 else { return [] }
        var out = Array(held.prefix(n))
        held.removeFirst(n)
        let from = outEnd, to = outEnd + Int64(n)
        func zero(_ s: Int64, _ e: Int64) {
            let a = max(s, from), b = min(e, to)
            guard a < b else { return }
            let lo = Int(a - from), hi = Int(b - from)
            out.replaceSubrange(lo..<hi, with: repeatElement(0, count: hi - lo))
            mutedFrames += Int64(hi - lo)
        }
        for span in pending { zero(span.start, span.end) }
        if let start = openStart { zero(start, Int64.max) }
        outEnd = to
        pending.removeAll { $0.end <= to }
        return out
    }
}

// MARK: - Manual signal (the guaranteed path)

/// The menu item 'Pause Microphone': muted from the click to the resume, nothing otherwise (a person who has not paused says nothing about
/// the meeting app's own mute, so the answer is unknown, not unmuted). The intervals are kept with their host times, so a chunk that is
/// processed late is judged by when it was recorded, not by the state of the moment.
final class ManualMuteSignal: MuteSignalSource {
    let name = "manual"
    private static let maxIntervals = 200
    private let lock = NSLock()
    private var intervals: [(from: UInt64, to: UInt64?)] = []

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return !intervals.isEmpty && intervals[intervals.count - 1].to == nil
    }

    /// False = already in that state, nothing changed.
    @discardableResult
    func set(paused: Bool, at host: UInt64 = CaptureHAL.Clock.now()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let open = !intervals.isEmpty && intervals[intervals.count - 1].to == nil
        if paused == open { return false }
        if paused {
            intervals.append((host, nil))
            if intervals.count > Self.maxIntervals { intervals.removeFirst(intervals.count - Self.maxIntervals) }
        } else {
            intervals[intervals.count - 1].to = max(host, intervals[intervals.count - 1].from)
        }
        return true
    }

    func read(at host: UInt64) -> MuteReading {
        lock.lock(); defer { lock.unlock() }
        for interval in intervals.reversed() where host >= interval.from && (interval.to.map { host < $0 } ?? true) { return .muted }
        return .unknown
    }
}

// MARK: - Polled signal (device, app)

/// A source whose value has to be asked for: it samples `probe` every `interval` seconds on a queue of its own and keeps the last
/// `historySeconds` of (host time, reading), so `read(at:)` answers for the audio position it is asked about even when the chunk is
/// processed late. No sample within `staleSeconds` before the position (the poll thread is stuck, or not started): unknown.
final class PolledMuteSignal: MuteSignalSource, MuteSignalLifecycle {
    let name: String
    private let interval: TimeInterval
    private let probe: () -> MuteReading
    private let clock: () -> UInt64
    private let staleTicks: UInt64
    private let historyTicks: UInt64
    private let beforeFirstTicks: UInt64
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var history: [(host: UInt64, reading: MuteReading)] = []
    private var timer: DispatchSourceTimer?

    init(name: String, interval: TimeInterval, staleSeconds: Double = 1.5, historySeconds: Double = 8,
         clock: @escaping () -> UInt64 = { CaptureHAL.Clock.now() }, probe: @escaping () -> MuteReading) {
        self.name = name
        self.interval = max(interval, 0.01)
        self.probe = probe
        self.clock = clock
        self.staleTicks = CaptureHAL.Clock.ticks(seconds: staleSeconds)
        self.historyTicks = CaptureHAL.Clock.ticks(seconds: historySeconds)
        self.beforeFirstTicks = CaptureHAL.Clock.ticks(seconds: 0.5)
        self.queue = DispatchQueue(label: "\(AppInfo.bundleID).mutesignal.\(name)", qos: .userInitiated)
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        queue.sync {}
    }

    /// One poll, stamped with the clock as it was when the question was asked (the self test calls the second form with virtual stamps).
    func sample() { sample(at: clock()) }

    func sample(at host: UInt64) {
        let reading = probe()
        lock.lock(); defer { lock.unlock() }
        history.append((host, reading))
        if let newest = history.last?.host, newest > historyTicks {
            let cutoff = newest - historyTicks
            if let keepFrom = history.firstIndex(where: { $0.host >= cutoff }), keepFrom > 0 { history.removeFirst(keepFrom) }
        }
    }

    func read(at host: UInt64) -> MuteReading {
        lock.lock(); defer { lock.unlock() }
        guard let first = history.first else { return .unknown }
        // A chunk from just before the first poll (the recording started a moment earlier): the first answer is the best there is.
        if host < first.host { return first.host - host <= beforeFirstTicks ? first.reading : .unknown }
        var lo = 0, hi = history.count - 1                  // the last entry that is not newer than `host`
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if history[mid].host <= host { lo = mid } else { hi = mid - 1 }
        }
        let entry = history[lo]
        return host - entry.host > staleTicks ? .unknown : entry.reading
    }
}

// MARK: - The meeting app's own mute (IsRunningInput)

/// The call app's audio processes (the same family the detector and the tap use) and whether one of them has the microphone open. While
/// the call is on, an app that closes its input when its user mutes shows as IsRunningInput dropping to false. UNVERIFIED per app (Zoom,
/// Teams and Meet differ; docs/LIVE_TEST.md L-21..L-26), so the rule only ever says 'muted' after it has SEEN the input running in this
/// recording and the app's process objects are still there; before that, and when no process of the app exists, it says unknown (record).
/// Reading the properties needs no permission. One probe per recording (it remembers whether the input was seen).
final class AppInputMuteProbe {
    private let platform: Platform
    private let matcher: FamilyMatcher
    private let monitor: AudioProcessMonitor
    private var sawInput = false

    /// nil for a manual recording: there is no call app to ask.
    init?(signal: PlatformSignal, config: AppConfig, monitor: AudioProcessMonitor = AudioProcessMonitor()) {
        guard signal.platform != .manual else { return nil }
        self.platform = signal.platform
        self.matcher = FamilyMatcher(browserBundleIDs: config.browserBundleIDs, enabledPlatforms: [signal.platform])
        self.monitor = monitor
    }

    func read() -> MuteReading {
        let processes = monitor.poll(interesting: { [matcher, platform] in matcher.platform(of: $0) == platform })
        guard !processes.isEmpty else { return .unknown }
        if processes.contains(where: { $0.isRunningInput }) {
            sawInput = true
            return .unmuted
        }
        return sawInput ? .muted : .unknown
    }
}
