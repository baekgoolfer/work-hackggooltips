import Foundation
import Darwin

// =====================================================================================
// Recorder: one meeting session = two mono 16-bit WAV tracks + session.json (SPEC 4.1, 4.2).
//
//   remote.wav  system audio (SystemAudioTap)         mic.wav  default microphone (MicCapture)
//
// Timeline rules
//  * t0 = Date() at start(), paired with a host time (mach_absolute_time) taken at the same instant.
//  * start_offset_sec of a track = host time of its FIRST sample - t0 (clamped >= 0). The WAV starts at that
//    sample; the Python pipeline pads the front with silence.
//  * Each later buffer carries the host time of its first sample. If the file is shorter than real time
//    would require (device change / rebuild / dropout) by more than gapTolerance, the difference is filled
//    with digital silence, so file time == session time for the whole recording. Drift in the other direction
//    (device clock faster than the host clock, tens of ppm) is tolerated, not trimmed.
//  * The WAV sample rate is fixed per file (fileSampleRate); sources convert to it, so the header rate always
//    equals session.json's sample_rate.
//  * Gap fills that repeat with the same size at the same spacing (GapPatternDetector) are not dropouts but a sample-rate
//    mismatch of the source (AirPods in the hands-free profile: 24 kHz audio labelled 48 kHz, 28 x 0.21 s every 0.42 s): one
//    warning instead of a log line per gap, and the source is asked once to re-measure (timelineRateSuspected).
//
// session.json additive fields (SPEC 4.1 stays valid, readers ignore unknown keys; SPEC 15):
//  * "warnings": [ "<ISO8601 time> <message>", ... ]  every warning of the recording (device change, stall, gap fill, a track that
//    could not start, remote track suspected silent ...), capped at 50, written as they happen and at stop(), so a crash keeps them;
//  * "remote_silent_suspected": true once the remote (system audio) track was digital silence for >= 3 minutes while the mic track
//    had activity (or, for an auto-detected meeting, while detection said inCall). Sticky for the rest of the recording;
//  * "local_only" (bool) and "local_only_source": ONLY after `setLocalOnly` was called (SessionRecordingPrivacy, SPEC 18.2): the controller
//    calls it for every real recording before start() and again for every toggle while the recording runs. A recorder that was never asked
//    writes exactly the keys it always wrote (the capture self test asserts the exact key set);
//  * "mic_gate": {enabled, signals, muted_seconds, unknown_seconds}: ONLY for a recording whose gate was switched on with
//    `configureMuteGate(enabled: true)` (MIC_MUTE_GATE=on). The aggregate only: the spans of zeros go to SUPPORT_DIR/session-private/<id>.json
//    (key mute_spans, Swift only, never Drive). A recorder that was never asked, or asked with false, has no such key and no delay line.
//
// Mute gate (MuteGate.swift): the microphone track's samples pass through a 0.5 s delay line in front of its WavWriter; while a positive
// mute signal holds the writer gets exact zeros. The timeline does not move: zeros are written where the audio would have been, a gap fill
// flushes the line first, stop() flushes it (the file is as long as without the gate), a crash loses its last 0.5 s. The level meter, and
// with it recentLevelsDB, the remote-silence rule and the controller's no-speech auto-stop, reads the samples BEFORE the gate.
//
// Concurrency: samples arrive on each source's own work queue and are appended to a track under that
// track's lock; WavWriter then moves them to its own writer queue. Recorder-level state is behind `lock`.
// Lock order: persistLock -> lock -> track.lock (never the reverse; stop() never holds a lock while stopping
// sources, because source.stop() waits for in-flight deliveries).
// =====================================================================================

final class Recorder: SessionRecording, SessionRecordingExtras, SessionRecordingPrivacy, SessionRecordingMicGate {
    /// Fixed WAV rate of both tracks. Native device rates are converted to this.
    static let fileSampleRate = 48000
    /// Silence is inserted only when the file lags real time by more than this (ignores scheduling jitter).
    static let gapTolerance: TimeInterval = 0.2
    /// Sanity cap for one gap fill (guards against a corrupt timestamp allocating hours of silence).
    static let maxGapFill: TimeInterval = 3600
    static let stallWarningSeconds: TimeInterval = 5
    /// A track whose source could not start while the other one did (Bluetooth switching profiles at call start, a device
    /// that is busy for a moment, a permission granted later) is started again in the background: after these delays, the
    /// last one repeating, for as long as the recording runs. The track then begins late (start_offset_sec says when).
    /// The watchdog ticks once per second, so a delay below 1 s means "at the next tick". (var: the self-test shortens it.)
    static var sourceRetrySchedule: [TimeInterval] = [10, 30, 60, 300]

    /// The remote track must be digital silence this long before it is suspected (var: the self-test shortens it).
    static var remoteSilentSuspectSeconds: TimeInterval = 180
    /// Mic level (5 s RMS, dBFS) above which the microphone counts as "had activity" (speech; a quiet room is below this).
    static let micActivityDB: Float = -50
    /// The text every "remote track suspected silent" warning starts with (the controller recognises it: the menu has its own
    /// standing line for this, so the generic "latest warning" line is not used for it).
    static let remoteSilentWarningPrefix = "remote audio has been digital silence"
    /// Warnings kept per recording (session.json would otherwise grow without bound on a flapping device).
    static let maxWarnings = 50

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.2.0"
    }

    // MARK: SessionRecording

    var onWarning: ((String) -> Void)?

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recording
    }

    var startedAt: Date {
        lock.lock(); defer { lock.unlock() }
        return t0
    }

    var recentLevelsDB: (mic: Float, remote: Float) {
        lock.lock()
        let j = mic, r = remote
        lock.unlock()
        return (j?.meter.rmsDB() ?? -120, r?.meter.rmsDB() ?? -120)
    }

    // MARK: SessionRecordingExtras

    var onRemoteSilentSuspected: ((String) -> Void)?

    var remoteSilentSuspected: Bool {
        lock.lock(); defer { lock.unlock() }
        return remoteSuspected
    }

    /// A note for session.json `warnings` that is not a problem of the recording itself (the controller's "auto-stopped, no
    /// speech" line): timestamped, persisted, never shown in the menu as a recorder warning.
    func annotate(_ message: String) {
        lock.lock()
        let active = recording
        appendWarningLocked(message)
        lock.unlock()
        Log.info("recorder: note for session.json: \(message)")
        if active { persistQuietly() }
    }

    // MARK: SessionRecordingPrivacy

    /// The per-meeting flag as this recorder knows it; nil = `setLocalOnly` was never called (session.json carries no local_only key).
    var localOnly: Bool? {
        lock.lock(); defer { lock.unlock() }
        return localOnlyValue
    }

    /// `local_only_source` is 1-40 characters of [a-z0-9_:-] (the same rule SessionJSONPatch enforces after the stop).
    private static func isValidLocalOnlySource(_ source: String) -> Bool {
        return !source.isEmpty && source.utf8.count <= 40
            && source.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F || $0 == 0x3A }
    }

    /// Before start() it only remembers the value: the first session.json write carries it (true). While recording it rewrites
    /// session.json at once (atomic) and appends one line to the private history (SUPPORT_DIR/session-private/<id>.json, never Drive);
    /// a write that fails puts the earlier value back and answers false. After stop() session.json is final: false (the controller
    /// patches it then, SessionJSONPatch). No meeting content goes into the log or the history: only the value and its source.
    func setLocalOnly(_ value: Bool, source: String) -> Bool {
        guard Self.isValidLocalOnlySource(source) else {
            Log.warn("recorder: local_only source '\(source.prefix(40))' is not valid; the value was not set")
            return false
        }
        persistLock.lock()
        if sessionFileFinal { persistLock.unlock(); return false }
        lock.lock()
        let before = (value: localOnlyValue, source: localOnlySource)
        localOnlyValue = value
        localOnlySource = source
        let active = recording
        lock.unlock()
        var stored = true
        if active {
            do {
                try writeSessionJSONLocked(final: false)
            } catch {
                lock.lock(); localOnlyValue = before.value; localOnlySource = before.source; lock.unlock()
                stored = false
                Log.warn("recorder: cannot write local_only into session.json: \(error)")
            }
        }
        persistLock.unlock()
        guard stored else { return false }
        Log.info("recorder: local_only=\(value) (\(source))\(active ? "" : ", written with the first session.json")")
        let entry: [String: Any] = ["at": ShellUtil.iso8601(Date()), "value": value, "source": source, "phase": active ? "recording" : "start"]
        if active {
            SessionPrivateLog.append(session: sessionID, supportDir: config.supportDir, entry: entry)
        } else {
            // Before start(): the line is kept until start() has written the first session.json. A start that fails removes the folder, and a
            // history line for a session that never existed would only be left behind (and picked up by a retry that reuses the id).
            lock.lock(); pendingHistory.append(entry); lock.unlock()
        }
        return true
    }

    /// The history lines of `setLocalOnly` calls made before start(); start() writes them once the recording exists.
    private func flushPendingHistory() {
        lock.lock()
        let entries = pendingHistory
        pendingHistory.removeAll()
        lock.unlock()
        for entry in entries { SessionPrivateLog.append(session: sessionID, supportDir: config.supportDir, entry: entry) }
    }

    // MARK: SessionRecordingMicGate

    /// Before start() only: the gate (its delay line, its signals, the `mic_gate` key) exists for a recording that asked for it at the start.
    func configureMuteGate(enabled: Bool) {
        lock.lock()
        let late = started
        if !late { muteGateOn = enabled }
        lock.unlock()
        if late { Log.warn("recorder: configureMuteGate(\(enabled)) after start() is ignored (the delay line is built with the recording)") }
    }

    var muteGateEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return muteGateOn
    }

    var microphonePaused: Bool { manualMute.isPaused }

    /// 'Pause Microphone': the manual signal is muted from now on (the gate backdates the zeros like for any other signal) until it is
    /// resumed. Accepted only while a gated recording is running; nothing about the meeting goes into the log.
    @discardableResult
    func setMicrophonePaused(_ paused: Bool) -> Bool {
        lock.lock()
        let usable = muteGateOn && muteGate != nil && recording && summary == nil
        lock.unlock()
        guard usable else { return false }
        if manualMute.set(paused: paused) { Log.info("recorder: microphone \(paused ? "paused" : "resumed") from the menu") }
        return true
    }

    // MARK: State

    private let sessionDir: URL
    private let signal: PlatformSignal
    private let config: AppConfig
    private let sessionID: String
    private let sampleRate: Int
    private let injectedRemote: (() -> CaptureTrackSource)?
    private let injectedMic: (() -> CaptureTrackSource)?
    private let injectedMuteSignals: (() -> [MuteSignalSource])?
    /// Setup / self-test only: allow the microphone permission prompt. Unattended recording leaves this false.
    var promptForPermissions = false

    private let lock = NSLock()                    // guards the fields below
    private var started = false
    private var recording = false
    private var t0 = Date()
    private var t0Host: UInt64 = 0
    private var titleHint: String?
    private var meetingURL: String?
    private var warningLog: [(at: Date, text: String)] = []
    private var remoteSuspected = false
    private var localOnlyValue: Bool?               // nil until setLocalOnly: no local_only keys in session.json
    private var localOnlySource: String?
    private var pendingHistory: [[String: Any]] = []    // history lines of setLocalOnly calls before start()
    private var silenceTracker: RemoteSilenceTracker
    private var mic: Track?
    private var remote: Track?
    private var watchdog: DispatchSourceTimer?
    private var watchdogTicks = 0
    private var summary: RecorderSummary?
    private var muteGateOn = false                  // MIC_MUTE_GATE for this recording (configureMuteGate, before start())
    private var muteGate: MuteGate?                 // set by start() when it is on
    private var muteLifecycles: [MuteSignalLifecycle] = []
    private let manualMute = ManualMuteSignal()
    /// Spans of zeros go to the private sidecar from here, never on the audio thread (a read-modify-write of a small file).
    private let muteSpanQueue = DispatchQueue(label: "\(AppInfo.bundleID).recorder.mutespans", qos: .utility)

    private let stopLock = NSLock()                // serializes stop()
    private let persistLock = NSLock()             // serializes session.json writes
    private var sessionFileFinal = false           // guarded by persistLock
    private let watchdogQueue = DispatchQueue(label: "\(AppInfo.bundleID).recorder.watchdog", qos: .utility)

    /// Production initializer (SPEC 12.1).
    convenience init(sessionDir: URL, signal: PlatformSignal, config: AppConfig) {
        self.init(sessionDir: sessionDir, signal: signal, config: config, remote: nil, mic: nil)
    }

    /// Test initializer: inject synthetic sources (self-test) instead of the real tap / microphone. `muteSignals` replaces the device and
    /// app signals of a gated recording (the manual signal is always there); without it a synthetic microphone has no signal but that one.
    init(sessionDir: URL, signal: PlatformSignal, config: AppConfig,
         remote: (() -> CaptureTrackSource)?, mic: (() -> CaptureTrackSource)?, muteSignals: (() -> [MuteSignalSource])? = nil) {
        self.sessionDir = sessionDir
        self.signal = signal
        self.config = config
        self.sessionID = sessionDir.lastPathComponent
        self.sampleRate = Self.fileSampleRate
        self.injectedRemote = remote
        self.injectedMic = mic
        self.injectedMuteSignals = muteSignals
        self.titleHint = signal.titleHint
        self.meetingURL = signal.meetingURL
        self.silenceTracker = RemoteSilenceTracker(thresholdSeconds: Self.remoteSilentSuspectSeconds)
    }

    // MARK: start

    func start() throws {
        lock.lock()
        guard !started else { lock.unlock(); throw RecorderError.failed("Recorder.start() called twice") }
        started = true
        t0 = Date()
        t0Host = CaptureHAL.Clock.now()
        let t0Host = self.t0Host
        lock.unlock()

        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch {
            throw RecorderError.failed("cannot create session folder \(sessionDir.path): \(error.localizedDescription)")
        }

        // Create both WAV files first; a disk problem must fail before any device is opened.
        let micSource = injectedMic?() ?? defaultMic()
        let remoteSource = injectedRemote?() ?? defaultRemote()
        let gate = makeMuteGate(mic: micSource)
        let micTrack = try Track(name: "mic", label: "microphone", file: "mic.wav", dir: sessionDir, source: micSource, t0Host: t0Host, gate: gate)
        let remoteTrack: Track
        do {
            remoteTrack = try Track(name: "remote", label: "system audio", file: "remote.wav", dir: sessionDir, source: remoteSource, t0Host: t0Host)
        } catch {
            micTrack.writer.close()
            try? FileManager.default.removeItem(at: micTrack.writer.url)
            throw error
        }
        lock.lock(); mic = micTrack; remote = remoteTrack; muteGate = gate; lock.unlock()
        for track in [micTrack, remoteTrack] { wire(track) }

        // Microphone first: it makes our process known to Core Audio (so the tap can exclude it) and, for
        // Bluetooth headsets, negotiates the headset profile before the tap graph is built.
        var errors: [(Track, Error)] = []
        for track in [micTrack, remoteTrack] {
            do {
                try track.source.start()
                track.markStarted()
                Log.info("recorder: \(track.label) track started (\(track.source.sourceLabel), device '\(track.source.deviceName)')")
            } catch {
                track.failure = "\(error)"
                track.scheduleStartRetry(after: Self.sourceRetrySchedule[0])
                errors.append((track, error))
                warn("\(track.label) track could not start: \(error)")
            }
        }

        if errors.count == 2 {
            for track in [micTrack, remoteTrack] {
                track.writer.close()
                try? FileManager.default.removeItem(at: track.writer.url)
            }
            persistLock.lock(); sessionFileFinal = true; persistLock.unlock()
            try? FileManager.default.removeItem(at: sessionDir.appendingPathComponent("session.json"))
            // Surface the most actionable reason: a permission problem beats a device problem.
            let first = errors.first(where: { if case RecorderError.permissionDenied = $0.1 { return true } else { return false } }) ?? errors[0]
            let summary = errors.map { "\($0.0.label): \($0.1)" }.joined(separator: "; ")
            if case RecorderError.permissionDenied = first.1 { throw RecorderError.permissionDenied(summary) }
            if case RecorderError.deviceUnavailable = first.1 { throw RecorderError.deviceUnavailable(summary) }
            throw RecorderError.failed(summary)
        }

        lock.lock(); recording = true; lock.unlock()
        do {
            try writeSessionJSON(final: false)
        } catch {
            // Without session.json the recording is useless to the pipeline: undo everything and fail loudly.
            for track in [micTrack, remoteTrack] {
                if track.sourceStarted { track.source.stop() }
                track.writer.close()
                try? FileManager.default.removeItem(at: track.writer.url)
            }
            lock.lock(); recording = false; lock.unlock()
            persistLock.lock(); sessionFileFinal = true; persistLock.unlock()
            throw RecorderError.failed("cannot write session.json in \(sessionDir.path): \(error.localizedDescription)")
        }
        flushPendingHistory()
        startWatchdog()
        lock.lock(); let lifecycles = muteLifecycles; lock.unlock()
        for source in lifecycles { source.start() }
        Log.info("recorder: session \(sessionID) recording to \(sessionDir.path)"
                 + (gate.map { " (mic mute gate on: signals \($0.configuredSignals.joined(separator: ", ")))" } ?? ""))
    }

    /// The gate of this recording, or nil when MIC_MUTE_GATE is off for it (then the microphone track is the track it always was). The
    /// signals: the injected ones (self test) or, for the real microphone, its device's mute state and the call app's input, plus the
    /// manual signal in every case.
    private func makeMuteGate(mic: CaptureTrackSource) -> MuteGate? {
        lock.lock(); let on = muteGateOn; lock.unlock()
        guard on else { return nil }
        var signals: [MuteSignalSource] = []
        if let injected = injectedMuteSignals {
            signals = injected()
        } else {
            if let provider = mic as? MuteSignalProviding { signals += provider.muteSignals() }
            if injectedMic == nil, let probe = AppInputMuteProbe(signal: signal, config: config) {
                signals.append(PolledMuteSignal(name: "app", interval: 0.2) { probe.read() })
            }
        }
        signals.append(manualMute)
        lock.lock(); muteLifecycles = signals.compactMap { $0 as? MuteSignalLifecycle }; lock.unlock()
        return MuteGate(config: MuteGateConfig(enabled: true, sampleRate: Double(sampleRate)), signals: signals)
    }

    private func defaultMic() -> CaptureTrackSource {
        let mic = MicCapture(sampleRate: Double(sampleRate))
        mic.allowPermissionPrompt = promptForPermissions
        return mic
    }

    private func defaultRemote() -> CaptureTrackSource {
        SystemAudioTap(sampleRate: Double(sampleRate), mode: config.systemAudioMode, signal: signal, config: config)
    }

    /// Connects a track's source callbacks to the recorder.
    private func wire(_ track: Track) {
        track.source.onSamples = { [weak self, weak track] samples, host in
            guard let self = self, let track = track else { return }
            let result = track.ingest(samples, host: host)
            if result.first {
                Log.info(String(format: "recorder: first %@ frames arrived, start_offset %.3f s", track.label, track.startOffsetSeconds))
                self.persistQuietly()
            }
            if result.gapSeconds > 0 {
                let msg = String(format: "%@ track: filled a %.1f s gap with silence (device change or dropout)", track.label, result.gapSeconds)
                if result.gapSeconds >= 1 { self.warn(msg) } else if result.logGap { Log.info("recorder: " + msg) }
            }
            if let problem = result.rateProblem { self.reportRateProblem(track, problem) }
            if !result.gateEvents.isEmpty { self.handleGateEvents(result.gateEvents) }
        }
        track.source.onWarning = { [weak self, weak track] message in
            guard let self = self, let track = track else { return }
            self.warn("\(track.label): \(message)")
        }
        track.source.onDeviceChange = { [weak self, weak track] name in
            guard let self = self, let track = track else { return }
            track.noteDevice(name)
            Log.info("recorder: \(track.label) track now on '\(name)'")
            self.persistQuietly()
        }
    }

    /// Sustained, regular, equal gap fills (28 x 0.2 s every 0.42 s on the AirPods test) are the signature of a SAMPLE-RATE
    /// MISMATCH of the source, not of dropouts: ONE warning (session.json + menu) instead of one log line per gap, and the source
    /// is asked once to re-measure its delivered rate (HALCapture.rateSuspected). The warning is once per track and recording; a
    /// later episode on the same track only re-triggers the source and logs one line.
    private func reportRateProblem(_ track: Track, _ p: GapPatternDetector.RateProblem) {
        let eq = Int((p.deliveredRatio * Double(sampleRate)).rounded())
        let msg = String(format: "%@ track: %d gap fills of %.2f s every %.2f s: the source delivers only about %.0f%% of the audio it should "
                         + "(like %d Hz audio labelled %d Hz). That looks like a sample-rate mismatch rather than dropouts; the capture was asked to re-measure its rate",
                         track.label, p.count, p.gapSeconds, p.periodSeconds, p.deliveredRatio * 100, eq, sampleRate)
        if track.markRateProblemReported() { warn(msg) } else { Log.info("recorder: " + msg) }
        track.source.timelineRateSuspected(deliveredRatio: p.deliveredRatio)
    }

    /// What the mute gate did: a log line for each engage / release (seconds of mic.wav and signal names, no content), and for
    /// each finished span one entry in the private sidecar (SUPPORT_DIR/session-private/<id>.json, key mute_spans: start, end, signals) plus
    /// a fresh session.json (the aggregate). The sidecar is written on a queue of its own, never on the audio thread.
    private func handleGateEvents(_ events: [MuteGate.Event]) {
        var spans = 0
        for event in events {
            switch event {
            case .engaged(let at, let signals):
                Log.info(String(format: "recorder: microphone muted (%@): zeros in mic.wav from %.2f s", signals.joined(separator: "+"), at))
            case .released(let span):
                spans += 1
                Log.info(String(format: "recorder: microphone zeros in mic.wav %.2f - %.2f s (%@)", span.start, span.end, span.signals.joined(separator: "+")))
                let entry: [String: Any] = ["start": (span.start * 1000).rounded() / 1000, "end": (span.end * 1000).rounded() / 1000,
                                            "signals": span.signals, "at": ShellUtil.iso8601(Date())]
                let id = sessionID, support = config.supportDir
                muteSpanQueue.async {
                    SessionPrivateLog.append(session: id, supportDir: support, entry: entry, key: Self.muteSpansKey, maxEntries: Self.maxMuteSpans)
                }
            }
        }
        if spans > 0 { persistQuietly() }
    }

    /// The list in the private sidecar, and how many spans it keeps (a recording with a flapping signal must not grow it without bound).
    static let muteSpansKey = "mute_spans"
    static let maxMuteSpans = 500

    /// Gap fills so far per track (tests, diagnostics).
    var gapCounts: (mic: Int, remote: Int) {
        lock.lock()
        let j = mic, r = remote
        lock.unlock()
        return (j?.gapCount ?? 0, r?.gapCount ?? 0)
    }

    // MARK: stop

    func stop(reason: EndReason) -> RecorderSummary {
        stopLock.lock(); defer { stopLock.unlock() }
        lock.lock()
        if let s = summary { lock.unlock(); return s }
        let wasStarted = started
        let micTrack = mic, remoteTrack = remote
        let t0 = self.t0
        lock.unlock()

        guard wasStarted, let micTrack = micTrack, let remoteTrack = remoteTrack else {
            // Never (successfully) started: nothing to finalize.
            let s = RecorderSummary(sessionID: sessionID, sessionDir: sessionDir, durationSec: 0, micSeconds: 0, remoteSeconds: 0, warnings: currentWarnings())
            lock.lock(); summary = s; recording = false; lock.unlock()
            return s
        }

        watchdog?.cancel()
        watchdog = nil
        // Stop the sources first (waits for in-flight deliveries), then close the files. No locks held here.
        for track in [micTrack, remoteTrack] where track.sourceStarted { track.source.stop() }
        let endTime = Date()
        lock.lock(); let lifecycles = muteLifecycles; let gate = muteGate; lock.unlock()
        for source in lifecycles { source.stop() }
        var gateEvents: [MuteGate.Event] = []
        for track in [micTrack, remoteTrack] { gateEvents += track.closeWriter() }      // the microphone's delay line is flushed first
        handleGateEvents(gateEvents)
        muteSpanQueue.sync {}
        if let gate = gate {
            Log.info(String(format: "recorder: mic mute gate: %.1f s of zeros, %.1f s without any signal (recorded), signals that answered: %@",
                            gate.mutedSeconds, gate.unknownSeconds, gate.signalNames.isEmpty ? "none" : gate.signalNames.joined(separator: ", ")))
            if gate.signalNames.isEmpty {
                lock.lock(); appendWarningLocked("mic mute gate was on, but no signal ever said muted or unmuted: the microphone was recorded in full (fail-open)"); lock.unlock()
            }
        }

        // A track that never produced a frame is removed so every file listed in session.json exists and has audio.
        for track in [micTrack, remoteTrack] where track.frames == 0 {
            try? FileManager.default.removeItem(at: track.writer.url)
            if track.sourceStarted { warn("\(track.label) track produced no audio at all") }
        }

        do {
            try writeSessionJSON(final: true, endTime: endTime, reason: reason)
        } catch {
            Log.error("recorder: cannot write final session.json: \(error)")
            warn("could not write final session.json: \(error.localizedDescription)")
        }

        let s = RecorderSummary(sessionID: sessionID, sessionDir: sessionDir,
                                durationSec: max(0, endTime.timeIntervalSince(t0)),
                                micSeconds: micTrack.seconds, remoteSeconds: remoteTrack.seconds,
                                warnings: currentWarnings())
        lock.lock(); summary = s; recording = false; lock.unlock()
        Log.info(String(format: "recorder: stopped %@ reason=%@ duration=%.1fs mic=%.1fs remote=%.1fs gaps(mic=%d remote=%d) warnings=%d",
                        sessionID, reason.rawValue, s.durationSec, s.micSeconds, s.remoteSeconds,
                        micTrack.gapCount, remoteTrack.gapCount, s.warnings.count)
                 + (micTrack.foldedGapLines + remoteTrack.foldedGapLines > 0
                    ? " (gap log lines folded into the summary: mic \(micTrack.foldedGapLines), remote \(remoteTrack.foldedGapLines))" : ""))
        return s
    }

    /// TEST HOOK: behave like a killed process. Sources stop, WAV files are left with stale headers, session.json
    /// keeps end_time = null.
    func simulateCrashForTest() {
        stopLock.lock(); defer { stopLock.unlock() }
        lock.lock()
        let tracks = [mic, remote].compactMap { $0 }
        let lifecycles = muteLifecycles
        recording = false
        summary = RecorderSummary(sessionID: sessionID, sessionDir: sessionDir, durationSec: 0, micSeconds: 0, remoteSeconds: 0, warnings: [])
        lock.unlock()
        watchdog?.cancel(); watchdog = nil
        persistLock.lock(); sessionFileFinal = true; persistLock.unlock()   // nothing may touch session.json any more
        for track in tracks where track.sourceStarted { track.source.stop() }
        lifecycles.forEach { $0.stop() }
        for track in tracks { track.writer.abandonWithoutFinalizing() }     // the microphone's delay line is NOT flushed: the last 0.5 s are lost
    }

    // MARK: metadata

    func updateMeta(titleHint: String?, meetingURL: String?) {
        lock.lock()
        if let t = titleHint, !t.isEmpty { self.titleHint = t }
        if let u = meetingURL, !u.isEmpty { self.meetingURL = u }
        let active = recording
        lock.unlock()
        if active { persistQuietly() }
    }

    // MARK: warnings

    private func warn(_ message: String) {
        lock.lock()
        appendWarningLocked(message)
        let callback = onWarning
        let persist = recording                         // before start() finished the first session.json write covers it
        lock.unlock()
        Log.warn("recorder: \(message)")
        callback?(message)
        if persist { persistQuietly() }
    }

    /// Caller holds `lock`.
    private func appendWarningLocked(_ message: String) {
        if warningLog.count < Self.maxWarnings {
            warningLog.append((Date(), message))
        } else if warningLog.count == Self.maxWarnings {
            warningLog.append((Date(), "further warnings are not recorded (limit \(Self.maxWarnings))"))
        }
    }

    private func currentWarnings() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return warningLog.map { $0.text }
    }

    // MARK: session.json (atomic: Data.write(.atomic) writes a temp file and renames it over the target)

    private func persistQuietly() {
        do { try writeSessionJSON(final: false) } catch { Log.warn("recorder: cannot update session.json: \(error)") }
    }

    private func writeSessionJSON(final: Bool, endTime: Date? = nil, reason: EndReason? = nil) throws {
        persistLock.lock(); defer { persistLock.unlock() }
        try writeSessionJSONLocked(final: final, endTime: endTime, reason: reason)
    }

    /// The caller holds `persistLock`.
    private func writeSessionJSONLocked(final: Bool, endTime: Date? = nil, reason: EndReason? = nil) throws {
        if sessionFileFinal { return }
        let object = buildSessionObject(endTime: endTime, reason: reason)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: sessionDir.appendingPathComponent("session.json"), options: .atomic)
        if final { sessionFileFinal = true }
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current            // local offset, e.g. +09:00
        return f.string(from: date)
    }

    private func buildSessionObject(endTime: Date?, reason: EndReason?) -> [String: Any] {
        lock.lock()
        let t0 = self.t0
        let title = titleHint, url = meetingURL
        let tracks = [remote, mic].compactMap { $0 }
        let warnings = warningLog.map { "\(Self.iso($0.at)) \($0.text)" }
        let remoteSilent = remoteSuspected
        let flag = self.localOnlyValue, flagSource = self.localOnlySource
        let gateOn = self.muteGateOn, gate = self.muteGate
        lock.unlock()
        let finished = endTime != nil
        var trackObjects: [String: Any] = [:]
        for track in tracks {
            // While recording: every track whose source started. At the end: only tracks that have audio.
            guard finished ? track.frames > 0 : track.sourceStarted else { continue }
            trackObjects[track.name] = [
                "file": track.fileName,
                "sample_rate": track.writer.sampleRate,
                "channels": 1,
                "start_offset_sec": (track.startOffsetSeconds * 1000).rounded() / 1000,
                "source": track.source.sourceLabel,
                "device": track.deviceDescription,
            ] as [String: Any]
        }
        var object: [String: Any] = [
            "schema": 1,
            "session_id": sessionID,
            "platform": signal.platform.rawValue,
            "platform_label": signal.displayLabel,
            "title_hint": title.map { $0 as Any } ?? NSNull(),
            "meeting_url": url.map { $0 as Any } ?? NSNull(),
            "app_bundle_id": signal.bundleID.map { $0 as Any } ?? NSNull(),
            "start_time": Self.iso(t0),
            "end_time": endTime.map { Self.iso($0) as Any } ?? NSNull(),
            "end_reason": reason.map { $0.rawValue as Any } ?? NSNull(),
            "tracks": trackObjects,
            "app_version": Self.appVersion,
            "warnings": warnings,
            "remote_silent_suspected": remoteSilent,
        ]
        // A call of another app (platform "call", docs/DETECTION.md section 3b): the app's name and how it was found. Additive: the other platforms keep
        // exactly the keys above. `app_bundle_id` above is the app's main bundle id (the browser's for a meeting page), `platform_label` its name.
        if signal.platform == .call {
            object["app_name"] = signal.appName.map { $0 as Any } ?? NSNull()
            object["call_kind"] = signal.callKind.map { $0.rawValue as Any } ?? NSNull()
        }
        // Only after setLocalOnly (SPEC 18.2): a recorder that was never asked keeps writing exactly the keys above.
        if let flag = flag, let source = flagSource {
            object["local_only"] = flag
            object["local_only_source"] = source
        }
        // Only for a recording whose gate was switched on (MIC_MUTE_GATE=on): the aggregate, never the spans (those are in the private sidecar).
        if gateOn {
            func rounded(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
            object["mic_gate"] = ["enabled": true, "signals": gate?.signalNames ?? [],
                                  "muted_seconds": rounded(gate?.mutedSeconds ?? 0), "unknown_seconds": rounded(gate?.unknownSeconds ?? 0)] as [String: Any]
        }
        return object
    }

    // MARK: watchdog (1 Hz)

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    /// Watchdog queue: starts a track whose source could not start at the beginning, when its retry delay has passed.
    /// Runs under `stopLock`, so it can never overlap stop() (stop() would otherwise miss a source started a moment before).
    private func retryStart(of track: Track) {
        guard track.startRetryDue() else { return }
        stopLock.lock(); defer { stopLock.unlock() }
        lock.lock(); let running = recording && summary == nil; lock.unlock()
        guard running else { return }
        let attempt = track.noteStartAttempt()
        let schedule = Self.sourceRetrySchedule
        do {
            try track.source.start()
            track.failure = nil
            track.markStarted()
            let late = Date().timeIntervalSince(startedAt)
            Log.info(String(format: "recorder: %@ track started late, %.0f s into the recording (attempt %d, device '%@')",
                            track.label, late, attempt, track.source.deviceName))
        } catch {
            let delay = schedule[min(attempt, schedule.count - 1)]
            track.failure = "\(error)"
            track.scheduleStartRetry(after: delay)
            Log.info("recorder: \(track.label) track still cannot start (attempt \(attempt)): \(error); next try in \(Int(delay)) s")
        }
    }

    /// Once per tick: is the other side missing? (digital silence on the remote track for `remoteSilentSuspectSeconds`)
    private func checkRemoteSilence(_ tracks: [Track]) {
        let levels = recentLevelsDB
        let remoteTrack = tracks.first { $0.name == "remote" }
        // A remote source that never started (permission, device) records nothing either: counts as silent. -120 = digital silence.
        let remoteSilent = remoteTrack == nil || remoteTrack?.sourceStarted == false || levels.remote <= -119.5
        let fired = silenceTracker.update(now: ProcessInfo.processInfo.systemUptime,
                                          remoteSilent: remoteSilent,
                                          micActive: levels.mic > Self.micActivityDB,
                                          detectionInCall: signal.platform != .manual)
        guard fired else { return }
        let message = String(format: "%@ for %.0f s: the other side may not be recorded "
                             + "(check System Settings > Privacy & Security > System Audio Recording; ignore this if nobody else has spoken)",
                             Self.remoteSilentWarningPrefix, Self.remoteSilentSuspectSeconds)
        lock.lock()
        remoteSuspected = true
        let callback = onRemoteSilentSuspected
        lock.unlock()
        warn(message)                                   // timestamped into session.json together with the flag
        callback?(message)
    }

    private func watchdogTick() {
        lock.lock()
        let tracks = [mic, remote].compactMap { $0 }
        watchdogTicks += 1
        let ticks = watchdogTicks
        lock.unlock()
        for track in tracks where !track.sourceStarted && track.failure != nil { retryStart(of: track) }
        for track in tracks where track.sourceStarted {
            let idle = track.idleSeconds()
            if idle > Self.stallWarningSeconds {
                if track.markStalled() {
                    warn(String(format: "%@ track delivered no audio frames for %.0f s", track.label, idle))
                }
            } else if idle < 2, track.clearStalled() {
                Log.info("recorder: \(track.label) track delivers audio again")
            }
            if let message = track.takeWriterError() { warn("\(track.label) track: \(message)") }
        }
        checkRemoteSilence(tracks)
        if ticks % 30 == 0 {
            let l = recentLevelsDB
            let j = tracks.first { $0.name == "mic" }, r = tracks.first { $0.name == "remote" }
            Log.info(String(format: "recorder: levels mic %.1f dBFS remote %.1f dBFS | written mic %.0fs remote %.0fs | gaps mic %d remote %d",
                            l.mic, l.remote, j?.seconds ?? 0, r?.seconds ?? 0, j?.gapCount ?? 0, r?.gapCount ?? 0))
        }
    }
}

// MARK: - Optional recorder capabilities

/// What the controller may use beyond the contract in Types.swift (main-owned, not touched): it asks `recorder as?
/// SessionRecordingExtras`, so a recorder without them (a fake in a test) still works.
protocol SessionRecordingExtras: AnyObject {
    /// Called (any queue) once per recording, when the remote track becomes suspected silent. The text is the warning.
    var onRemoteSilentSuspected: ((String) -> Void)? { get set }
    var remoteSilentSuspected: Bool { get }
    /// Adds a timestamped line to session.json `warnings` (no `onWarning`, nothing in the menu).
    func annotate(_ message: String)
}

// MARK: - Remote silence rule

/// "The other side is missing": the remote (system audio) track has been digital silence for `thresholdSeconds` while the
/// microphone track had activity during that stretch, or while detection says the call is on (an auto-detected meeting). One
/// sample per call, with the caller's monotonic clock, so the self-test runs it on virtual time. It never un-suspects: once the
/// rule fired, the recording is flagged (session.json `remote_silent_suspected`), even if audio comes back after a tap rebuild.
struct RemoteSilenceTracker {
    let thresholdSeconds: TimeInterval
    private(set) var silentSince: TimeInterval?
    private(set) var micActiveInStretch = false
    private(set) var suspected = false

    init(thresholdSeconds: TimeInterval) { self.thresholdSeconds = thresholdSeconds }

    /// Returns true exactly once: when the remote track becomes suspected.
    mutating func update(now: TimeInterval, remoteSilent: Bool, micActive: Bool, detectionInCall: Bool) -> Bool {
        guard remoteSilent else {                       // any sound on the remote track restarts the stretch
            silentSince = nil
            micActiveInStretch = false
            return false
        }
        if silentSince == nil {
            silentSince = now
            micActiveInStretch = false
        }
        if micActive { micActiveInStretch = true }
        guard !suspected, let since = silentSince, now - since >= thresholdSeconds, micActiveInStretch || detectionInCall else { return false }
        suspected = true
        return true
    }
}

// MARK: - Gap pattern detector

/// Is a series of gap fills a SAMPLE-RATE problem? A device that delivers `ratio` x the audio it should (24 kHz audio labelled
/// 48 kHz: ratio 0.5) makes the timeline lag by the same amount every second, so the recorder's gap filler fires again and again
/// with the same size at the same spacing (AirPods test: 28 x 0.21 s every 0.42 s in 12 s; each fill followed by exactly as much
/// audio as the gap is long). A real dropout or a device change is a single, large, irregular gap. Pure value type; the self-test
/// feeds it virtual time.
///
/// `add` returns whether this fill deserves its own log line (the first two fills of a burst do, later ones are folded into the
/// count) and, once per episode, the verdict. An episode ends after `episodeQuiet` seconds without a fill.
struct GapPatternDetector {
    struct Fill {
        var at: Double               // host time of the buffer that triggered the fill, seconds
        var gapSeconds: Double       // size of the fill
        var audioBefore: Double      // seconds of real audio written since the previous fill (or since the start)
    }

    struct RateProblem: Equatable {
        var deliveredRatio: Double   // audio delivered / audio expected (0.5 for 24 kHz in a 48 kHz file)
        var gapSeconds: Double
        var periodSeconds: Double
        var count: Int
    }

    struct Outcome {
        var logIndividually: Bool
        var problem: RateProblem?
    }

    static let minRepeats = 4              // fills needed before a pattern is claimed
    static let clusterWindow = 12.0        // seconds: fills older than this are not part of the cluster
    static let episodeQuiet = 10.0         // seconds without a fill: the episode is over
    static let smallGap = 1.0              // a fill of this size or more is an outage, never part of a pattern
    static let evenness = 0.35             // every gap / period / ratio within +-35 % of the median

    private var fills: [Fill] = []
    private(set) var episodeActive = false
    private(set) var folded = 0            // fills whose log line was folded

    mutating func add(_ fill: Fill) -> Outcome {
        if let last = fills.last, fill.at - last.at > Self.episodeQuiet {
            fills = []
            episodeActive = false
        }
        guard fill.gapSeconds < Self.smallGap else {
            fills = []
            return Outcome(logIndividually: true, problem: nil)
        }
        fills.append(fill)
        fills.removeAll { fill.at - $0.at > Self.clusterWindow }
        if fills.count > 8 { fills.removeFirst(fills.count - 8) }
        if episodeActive {
            folded += 1
            return Outcome(logIndividually: false, problem: nil)
        }
        let log = fills.count <= 2
        if !log { folded += 1 }
        guard fills.count >= Self.minRepeats, let problem = classify() else { return Outcome(logIndividually: log, problem: nil) }
        episodeActive = true
        return Outcome(logIndividually: false, problem: problem)
    }

    private func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[s.count / 2]
    }

    private func classify() -> RateProblem? {
        let recent = Array(fills.suffix(8))
        guard recent.count >= Self.minRepeats else { return nil }
        let gap = median(recent.map { $0.gapSeconds })
        guard gap > 0, recent.allSatisfy({ abs($0.gapSeconds / gap - 1) <= Self.evenness }) else { return nil }
        var periods: [Double] = []
        for i in 1..<recent.count { periods.append(recent[i].at - recent[i - 1].at) }
        let period = median(periods)
        guard period > 0, periods.allSatisfy({ abs($0 / period - 1) <= Self.evenness }) else { return nil }
        let ratios = recent.map { $0.audioBefore / max($0.audioBefore + $0.gapSeconds, 1e-9) }
        let ratio = median(ratios)
        guard ratio > 0.05, ratio < 0.97, ratios.allSatisfy({ abs($0 / ratio - 1) <= Self.evenness }) else { return nil }
        return RateProblem(deliveredRatio: ratio, gapSeconds: gap, periodSeconds: period, count: recent.count)
    }
}

// MARK: - Track

/// One output file with its timeline bookkeeping. Samples arrive from the source's work queue.
private final class Track {
    let name: String               // "mic" | "remote" (key in session.json)
    let label: String              // for messages
    let fileName: String
    let source: CaptureTrackSource
    let writer: WavWriter
    let meter = LevelMeter()
    var failure: String?
    private var started = false
    private var startAttempts = 0                      // background restarts so far
    private var retryAtUptime: TimeInterval?

    /// The microphone track's mute gate (nil = the track is exactly what it always was).
    private let gate: MuteGate?
    private let t0Host: UInt64
    private let lock = NSLock()
    private var firstHost: UInt64?
    private var offset: Double = 0
    private var lastFrameUptime = ProcessInfo.processInfo.systemUptime
    private var gaps = 0
    private var realFramesSinceFill: Int64 = 0              // audio (not silence) frames appended since the previous gap fill
    private var gapDetector = GapPatternDetector()
    private var rateProblemReported = false
    private var devices: [String] = []
    private var stalled = false
    private var writerError: String?

    init(name: String, label: String, file: String, dir: URL, source: CaptureTrackSource, t0Host: UInt64, gate: MuteGate? = nil) throws {
        self.name = name
        self.label = label
        self.fileName = file
        self.source = source
        self.t0Host = t0Host
        self.gate = gate
        self.writer = try WavWriter(url: dir.appendingPathComponent(file), sampleRate: Int(source.sampleRate))
        self.writer.onError = { [weak self] message in
            guard let self = self else { return }
            self.lock.lock(); self.writerError = message; self.lock.unlock()
        }
    }

    var sourceStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func scheduleStartRetry(after delay: TimeInterval) {
        lock.lock(); retryAtUptime = ProcessInfo.processInfo.systemUptime + delay; lock.unlock()
    }

    func startRetryDue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started, let at = retryAtUptime else { return false }
        return ProcessInfo.processInfo.systemUptime >= at
    }

    /// Counts a background start attempt and returns its number (1 = the first retry).
    func noteStartAttempt() -> Int {
        lock.lock(); defer { lock.unlock() }
        startAttempts += 1
        retryAtUptime = nil
        return startAttempts
    }

    func markStarted() {
        lock.lock()
        started = true
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        noteDevice(source.deviceName)
    }

    func noteDevice(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if !name.isEmpty && devices.last != name { devices.append(name) }
    }

    var deviceDescription: String {
        lock.lock(); defer { lock.unlock() }
        return devices.isEmpty ? source.deviceName : devices.joined(separator: " -> ")
    }

    var startOffsetSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return offset
    }

    var gapCount: Int {
        lock.lock(); defer { lock.unlock() }
        return gaps
    }

    /// Gap fills whose log line was folded into the summary (a burst of small fills, see GapPatternDetector).
    var foldedGapLines: Int {
        lock.lock(); defer { lock.unlock() }
        return gapDetector.folded
    }

    /// True the first time (the warning for a rate problem is raised once per track and recording).
    func markRateProblemReported() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rateProblemReported { return false }
        rateProblemReported = true
        return true
    }

    var frames: Int64 { writer.framesWritten }
    var seconds: Double { Double(frames) / Double(writer.sampleRate) }

    /// Flushes the mute gate's delay line (when there is one: the file gets every frame it would have had) and closes the file. Returns
    /// what the gate did at the end (a mute still in force ends with the file).
    @discardableResult
    func closeWriter() -> [MuteGate.Event] {
        var events: [MuteGate.Event] = []
        if let gate = gate {
            lock.lock()
            let tail = gate.finish()
            events = gate.takeEvents()
            lock.unlock()
            writer.appendSamples(tail)
        }
        writer.close()
        return events
    }

    func idleSeconds() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastFrameUptime
    }

    /// Returns true the first time a stall is flagged (so the warning is raised once per episode).
    func markStalled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stalled { return false }
        stalled = true
        return true
    }

    func clearStalled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if !stalled { return false }
        stalled = false
        return true
    }

    func takeWriterError() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { writerError = nil }
        return writerError
    }

    /// Appends samples, first filling any gap since the previous buffer with silence (see header comment). With a mute gate the samples
    /// go through its delay line on the way to the file; the meter below still sees them before the gate.
    func ingest(_ samples: [Float], host: UInt64)
        -> (first: Bool, gapSeconds: Double, logGap: Bool, rateProblem: GapPatternDetector.RateProblem?, gateEvents: [MuteGate.Event]) {
        lock.lock(); defer { lock.unlock() }
        let rate = Double(writer.sampleRate)
        var first = false
        var gapSeconds = 0.0
        var logGap = true
        var rateProblem: GapPatternDetector.RateProblem?
        if let fh = firstHost {
            let expected = Int64(((CaptureHAL.Clock.seconds(host) - CaptureHAL.Clock.seconds(fh)) * rate).rounded())
            // The delay line holds frames that are already part of the timeline (accepted, not yet in the writer).
            let deficit = expected - (writer.framesWritten + Int64(gate?.heldFrames ?? 0))
            if Double(deficit) > Recorder.gapTolerance * rate {
                let fill = min(deficit, Int64(Recorder.maxGapFill * rate))
                if let gate = gate { writer.appendSamples(gate.flushForGap(skipping: Int(fill))) }     // what the line holds goes in front of the gap
                writer.appendSilence(frames: Int(fill))
                gaps += 1
                gapSeconds = Double(fill) / rate
                let outcome = gapDetector.add(.init(at: CaptureHAL.Clock.seconds(host), gapSeconds: gapSeconds,
                                                    audioBefore: Double(realFramesSinceFill) / rate))
                realFramesSinceFill = 0
                logGap = outcome.logIndividually
                rateProblem = outcome.problem
            }
        } else {
            firstHost = host
            first = true
            offset = max(0, CaptureHAL.Clock.seconds(host) - CaptureHAL.Clock.seconds(t0Host))
        }
        var gateEvents: [MuteGate.Event] = []
        if let gate = gate {
            writer.appendSamples(gate.filter(samples, hostTime: host))
            gateEvents = gate.takeEvents()
        } else {
            writer.appendSamples(samples)
        }
        realFramesSinceFill += Int64(samples.count)
        meter.add(samples)
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        return (first, gapSeconds, logGap, rateProblem, gateEvents)
    }
}

// MARK: - Level meter

/// RMS in dBFS over roughly the last 5 s, from 0.5 s buckets. Thread-safe.
private final class LevelMeter {
    private static let bucketSeconds = 0.5
    private static let bucketCount = 12
    private static let windowBuckets = 10

    private let lock = NSLock()
    private var keys = [Int](repeating: Int.min, count: LevelMeter.bucketCount)
    private var sumSquares = [Double](repeating: 0, count: LevelMeter.bucketCount)
    private var counts = [Int](repeating: 0, count: LevelMeter.bucketCount)

    private static func currentKey() -> Int { Int(ProcessInfo.processInfo.systemUptime / bucketSeconds) }

    func add(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        let key = Self.currentKey()
        let slot = key % Self.bucketCount
        lock.lock(); defer { lock.unlock() }
        if keys[slot] != key {
            keys[slot] = key
            sumSquares[slot] = 0
            counts[slot] = 0
        }
        sumSquares[slot] += sum
        counts[slot] += samples.count
    }

    /// -120 when there is no data or the data is digital silence.
    func rmsDB() -> Float {
        let now = Self.currentKey()
        lock.lock(); defer { lock.unlock() }
        var sum = 0.0
        var n = 0
        for i in 0..<Self.bucketCount where keys[i] > now - Self.windowBuckets && keys[i] <= now {
            sum += sumSquares[i]
            n += counts[i]
        }
        guard n > 0, sum > 0 else { return -120 }
        return Float(max(-120, 20 * log10((sum / Double(n)).squareRoot())))
    }
}

// MARK: - Permissions (SPEC 12.1)

/// Who may make macOS show a permission dialog or go live. A prompt is attributed to the "responsible" process: raised
/// from a shell (an agent, Terminal, CI) it would ask the user to grant Microphone / System Audio Recording to the PARENT
/// app instead of the signed app, and that grant is wrong and hard to notice. The in-bundle binary exec'd from a
/// shell has the right bundle id but the wrong parent, so the bundle id alone is NOT enough: the single source of truth
/// is `LaunchGuard.isSignedAppLaunch` (Types.swift: bundle id AND started by launchd / LaunchServices). Every
/// prompt-triggering entry point fails closed unless it is true. The decision functions take that verdict as a Bool, so
/// the self-test can feed both answers without touching a device.
enum CapturePermissionGuard {
    /// Escape hatch for a developer who knowingly wants prompts from another host (not for agents).
    static let allowAnyEnv = "MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY"
    /// Set by `selftest-capture --live` (the shell's main.swift); also required, so a stray run never goes live.
    static let liveSelfTestEnv = "MC_SELFTEST_LIVE"

    /// Prefix of every command we print for the user. `-n` is required: without it `open` only activates an already
    /// running instance, drops the arguments and `-W` waits forever (SPEC 14.4).
    /// The app file is `<short name>.app` (AppInfo.shortName: build input MCAP_APP_SHORT_NAME), never a retyped name.
    static var openAppPrefix: String { "open -n -W -a ~/Applications/\(AppInfo.shortName).app --stdout \"$(tty)\" --stderr \"$(tty)\" --args" }

    static func openAppCommand(_ subcommand: String) -> String { "\(openAppPrefix) \(subcommand)" }

    /// What this process looks like, for the refusal text: "bundle id <the app's id>, parent pid 4242,
    /// __CFBundleIdentifier com.apple.Terminal".
    static func launchDescription(bundleID: String? = Bundle.main.bundleIdentifier, parentPID: pid_t = getppid(),
                                  env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        return "bundle id \(bundleID ?? "none"), parent pid \(parentPID), __CFBundleIdentifier \(env["__CFBundleIdentifier"] ?? "unset")"
    }

    /// nil = prompts allowed. Otherwise an "error: ..." status (never "ok"/"authorized", so setup cannot read it as success).
    static func promptRefusal(signedAppLaunch: Bool, env: [String: String], launch: String = launchDescription()) -> String? {
        if signedAppLaunch || env[allowAnyEnv] == "1" { return nil }
        return "error: refused to trigger macOS permission prompts: this process was not started by launchd / LaunchServices as the signed "
             + "\(AppInfo.shortName).app (\(launch)), so macOS would ask for the permission on the parent app. Run it as the app: \(openAppCommand("setup"))"
    }

    /// nil = live self-test allowed: needs MC_SELFTEST_LIVE=1 AND a launchd / LaunchServices start of the signed app (no override).
    static func liveSelfTestRefusal(signedAppLaunch: Bool, env: [String: String], launch: String = launchDescription()) -> String? {
        var problems: [String] = []
        if env[liveSelfTestEnv] != "1" { problems.append("\(liveSelfTestEnv)=1 is not set (`selftest-capture --live` sets it)") }
        if !signedAppLaunch { problems.append("this process was not started by launchd / LaunchServices as the signed app (\(launch))") }
        guard !problems.isEmpty else { return nil }
        return "selftest-capture: refusing live mode (\(problems.joined(separator: "; "))).\n"
             + "Live mode opens the microphone and the system-audio tap and shows macOS permission prompts, so it only runs when the signed app was started through LaunchServices:\n"
             + "  \(openAppCommand("selftest-capture --live --seconds 12 --out DIR"))\n"
             + "From a shell use --synthetic (no devices, no permissions)."
    }
}

/// Setup path ONLY (shows system prompts): requests Microphone access and starts a throwaway process tap once,
/// which triggers the "System Audio Recording" prompt (only AudioDeviceStart triggers it, so the probe runs the
/// tap for a moment and plays a short sound, because a tap without permission delivers silence instead of an
/// error). Returns e.g. ["microphone": "authorized|denied|restricted|notDetermined",
/// "system_audio": "ok|error: ..."].
///
/// Refuses (both entries "error: refused ...", no device touched, no dialog) unless this process is the signed
/// app (`AppInfo.shortName`.app) started by launchd / LaunchServices (`LaunchGuard.isSignedAppLaunch`) or
/// MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY=1 is set.
func requestCapturePermissions() -> [String: String] {
    return requestCapturePermissions(signedAppLaunch: LaunchGuard.isSignedAppLaunch,
                                     env: ProcessInfo.processInfo.environment,
                                     microphone: { MicCapture.requestAuthorization(timeout: 120) },
                                     systemAudio: { SystemAudioTap.probePermission(config: AppConfig.defaults()) })
}

/// The injectable core of `requestCapturePermissions()`: the two closures are the only code that can show a dialog and
/// are NOT called when the guard refuses (the self-test passes closures that fail the test if they run).
func requestCapturePermissions(signedAppLaunch: Bool, env: [String: String],
                               microphone: () -> String, systemAudio: () -> String) -> [String: String] {
    if let refusal = CapturePermissionGuard.promptRefusal(signedAppLaunch: signedAppLaunch, env: env) {
        Log.warn("requestCapturePermissions: \(refusal)")
        return ["microphone": refusal, "system_audio": refusal]
    }
    var result: [String: String] = [:]
    result["microphone"] = microphone()
    result["system_audio"] = systemAudio()
    return result
}
