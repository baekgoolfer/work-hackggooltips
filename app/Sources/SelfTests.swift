import Foundation
import UserNotifications        // constants and option types only: no notification center is ever created here

// =====================================================================================
// `<short name> selftest-session`: device-free scenario tests for the app shell.
//
// No microphone, no Core Audio, no AppleScript, no permissions: SessionController runs against a fake
// detector / fake recorder / fake pipeline with a virtual clock, and PipelineLauncher runs against a fake
// "python" shell script. Everything happens in a temp directory (honours $TMPDIR); app.log is redirected there.
// Prints one line per check and a final PASS/FAIL; exit code 0 only if every check passed.
//
// Notifications (Korean content, click routing and validation, handler wiring, NOTIFY_RECORDING, start/stop notices) run against a
// fake notification center and a fake opener: neither UNUserNotificationCenter nor NSWorkspace is touched.
//
// SPEC 15 coverage in here: Meet off by default (setup skips Chrome Automation; scenarios enable Meet explicitly), the no-speech
// auto-stop, notifications (fake notifier, throttle), the retry sweep, the awake-time stall watchdog (virtual uptime), the new
// config keys and the menu warning lines.
//
// SPEC 18 (organisation policy, per-meeting local-only flag) coverage, S-LO-01 ... S-LO-20 (the sections at the
// end of this file): the policy core (runPolicySelfTests, hooked in), the start value of the flag, a real Recorder with synthetic sources,
// the menu toggle during and after the recording (state checks, atomic patch, read-back, appliedMaybeLate, tooLate), the lock, the pipeline
// contract, the recording kill switch (injected policy reader and virtual clock), the launcher's contract and runtime-trust refusals against
// a fake python with an injected version and file owner, the child environment, the notification texts, click routing, retry kinds, app.log
// without titles, the menu, completion texts, the start / stop notifications, policy problems and the policy watcher.
//
// SPEC 18, S-MG-01 ... S-MG-03 (after the S-LO sections): the microphone mute gate on the controller side:
// MIC_MUTE_GATE reaches every recording before start() (and the company baseline forces it on), the menu item 'Pause Microphone' and the paused
// status line, and the no-speech auto-stop reading the microphone before the gate (a real Recorder with synthetic sources).
//
// SPEC 18, S-CS-01 ... S-CS-07 (after the S-MG sections): 'Connect to Company Server...': the menu item exists only
// with an org consent in the policy or ASR_REMOTE_URL and is closed while the policy keeps the relay closed, the enrollment code reaches a fake
// python on stdin and never argv, the environment or a log, the app never reads the token (a child that prints one, a Keychain tool that is never
// called), the Korean success / failure notifications (title 40, subtitle 60, body 100), nothing starts without a policy-allowed relay, a trusted
// runtime and a new enough pipeline, the outcomes of the real child process (exit codes, timeout, busy), and the words of the pipeline's messages.
//
// Calendar auto-start, S-CW-01 ... S-CW-13 (the sections at the very end of this file): the OFFLINE_* keys, the pure start / skip rules with every reason and
// the window edges, the answer of `gcal upcoming` (good, ok:false, malformed, timeout, crash, refusal), a calendar day through the real controller (start,
// no second start, stop after the end, restart, a stop by hand), presence, other recordings (a recording that ended inside the window has covered the
// event), Pause, a failing start, the no-speech rule, error backoff (2 minutes at most) and wake, closed by the policy / the kill switch / local-only,
// a sleep or a quit is resumed while the event runs, the privacy of the event title, OFFLINE_AUTOSTART=off, one command at a time, the started-id
// store, the real child process against a fake python, the menu line and the notification texts.
//
// First run of the app installer (FirstRun.swift, Config.swift `bundledProjectDir`): the project folder inside the app (the config.env key still wins), the
// components record and its parsers, the verdict for every missing piece (cheap checks only), when the single alert may show (never under self tests, never
// without UI, never on a policy-managed Mac, once per launch), the copy of the helper script and first-run.env, the menu item and every text in en and ko. The
// AppKit alert and the Terminal start are the thin layer: here they are fakes that count their calls. Also: the speech model behind a Hugging Face cache link (stat follows
// links; a dangling link is missing), the facts of this Mac from a real config.env (ASR_ENGINE), the recording hold until the helper has finished (a dmg build without
// components-installed.json: no detection, no manual start, no calendar start, no Recorder is ever created; it ends by itself when the record appears), one helper at a
// time (the lock link), and the prompt that is never started inside a dispatch block of a serial main queue (the world below refuses re-entrancy like libdispatch).
//
// Settings window, S-ST-01 (hooked in before S-LO-01): runSettingsSelfTests (SettingsSelfTests.swift): the 20 keys the window edits and their value rules (the
// parsers of Config.swift / Policy.swift / CallApps.swift read what is written), the config.env editor (every other byte kept, quoting, comments, CRLF, refusals,
// both parsers read the result) and writer (atomic, 0600, five backups, failures leave the old file), API keys (security -i, hex on stdin, never argv / env /
// file / log, the names of the pipeline), the three read-only pipeline commands, the Terminal scripts for the consent and the Google sign-in (the consent is
// never written here), the restart guard, the privacy box (en / ko) and the menu-bar icon mapping.
//
// NOTE: the scenarios use the real DetectionStateMachine, but with tolerant timing windows, so they check
// "starts after about the debounce / stops after about the grace" rather than exact tick numbers.
// =====================================================================================

private var checksPassed = 0
private var checksFailed = 0

private func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        checksPassed += 1
        print("  ok    \(name)")
    } else {
        checksFailed += 1
        let d = detail()
        print("  FAIL  \(name)\(d.isEmpty ? "" : "  -> \(d)")")
    }
}

private func section(_ title: String) { print("\n== \(title)") }

/// app.log of this self-test run (Log.fileURL is redirected into the temp dir).
private func logText() -> String {
    Log.flush()
    return (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
}

private func logCount(_ needle: String) -> Int {
    return logText().components(separatedBy: needle).count - 1
}

// MARK: - Test doubles

private final class VirtualClock {
    private(set) var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private final class FakeDetector: MeetingDetecting {
    var signals: [PlatformSignal] = []
    var polls = 0
    private let clock: VirtualClock
    init(clock: VirtualClock) { self.clock = clock }
    func poll() -> DetectionSnapshot {
        polls += 1
        return DetectionSnapshot(time: clock.now, signals: signals)
    }
}

private final class FakeRecorder: SessionRecording, SessionRecordingExtras, SessionRecordingPrivacy, SessionRecordingMicGate {
    let dir: URL
    let signal: PlatformSignal
    private let clock: VirtualClock
    var isRecording = false
    private(set) var startedAt: Date
    var onWarning: ((String) -> Void)?
    var startError: Error?
    private(set) var stopReasons: [EndReason] = []
    private(set) var metaUpdates: [(title: String?, url: String?)] = []
    private var summary: RecorderSummary?
    /// Levels the controller sees (dBFS); a test sets them to simulate silence or speech.
    var levels: (mic: Float, remote: Float) = (-40, -40)
    var recentLevelsDB: (mic: Float, remote: Float) { levels }
    var onRemoteSilentSuspected: ((String) -> Void)?
    private(set) var remoteSilentSuspected = false
    private(set) var annotations: [String] = []
    func annotate(_ message: String) { annotations.append(message) }
    /// Behaves like Recorder when its remote-silence rule fires.
    func fireRemoteSilent() {
        remoteSilentSuspected = true
        let message = "\(Recorder.remoteSilentWarningPrefix) for 180 s: the other side may not be recorded"
        onWarning?(message)                          // the real Recorder warns first, then reports the suspicion
        onRemoteSilentSuspected?(message)
    }

    init(dir: URL, signal: PlatformSignal, clock: VirtualClock) {
        self.dir = dir
        self.signal = signal
        self.clock = clock
        self.startedAt = clock.now
    }

    // SessionRecordingPrivacy (SPEC 18): like Recorder, the keys are in session.json only after setLocalOnly was called.
    private(set) var localOnly: Bool?
    private(set) var localOnlySource: String?
    /// Every setLocalOnly call in order, accepted or not.
    private(set) var localOnlyCalls: [(value: Bool, source: String)] = []
    var failLocalOnly = false                       // a recorder that cannot write session.json

    func setLocalOnly(_ value: Bool, source: String) -> Bool {
        localOnlyCalls.append((value, source))
        if failLocalOnly { return false }
        localOnly = value
        localOnlySource = source
        if isRecording { writeSessionFile() }
        return true
    }

    // SessionRecordingMicGate: what the controller told the recorder, and a recorder that has no gate to switch on.
    private(set) var muteGateCalls: [Bool] = []
    private var gateOn = false
    var muteGateEnabled: Bool { gateOn }
    private(set) var pauseCalls: [Bool] = []
    private var pausedNow = false
    var microphonePaused: Bool { pausedNow }
    var failPause = false                           // a recorder that does not accept the pause
    var ignoresGate = false                         // a recorder without a gate: configureMuteGate has no effect

    func configureMuteGate(enabled: Bool) {
        muteGateCalls.append(enabled)
        if !ignoresGate { gateOn = enabled }
    }

    @discardableResult
    func setMicrophonePaused(_ paused: Bool) -> Bool {
        pauseCalls.append(paused)
        guard gateOn, isRecording, !failPause else { return false }
        pausedNow = paused
        return true
    }

    private func writeSessionFile() {
        var object: [String: Any] = ["schema": 1, "session_id": dir.lastPathComponent, "end_time": NSNull()]
        if let flag = localOnly, let source = localOnlySource { object["local_only"] = flag; object["local_only_source"] = source }
        try? ShellUtil.writeJSONAtomically(object, to: dir.appendingPathComponent("session.json"))
    }

    func start() throws {
        if let e = startError { throw e }
        isRecording = true
        startedAt = clock.now
        writeSessionFile()
        // Dummy audio so the blip log lines have file sizes to report.
        try? Data(count: 1024).write(to: dir.appendingPathComponent("mic.wav"))
        try? Data(count: 2048).write(to: dir.appendingPathComponent("remote.wav"))
    }

    func stop(reason: EndReason) -> RecorderSummary {
        if let s = summary { return s }                    // idempotent
        isRecording = false
        stopReasons.append(reason)
        let d = clock.now.timeIntervalSince(startedAt)
        let s = RecorderSummary(sessionID: dir.lastPathComponent, sessionDir: dir, durationSec: d,
                                micSeconds: d, remoteSeconds: d, warnings: [])
        summary = s
        return s
    }

    func updateMeta(titleHint: String?, meetingURL: String?) {
        metaUpdates.append((titleHint, meetingURL))
    }
}

private final class FakePipeline: PipelineRunning {
    var onEvent: ((PipelineEvent) -> Void)?
    private(set) var enqueued: [URL] = []
    private(set) var reprocessCalls = 0
    private(set) var shutdownCalls = 0
    private(set) var pendingCalls = 0
    private(set) var wakeCalls = 0
    var busy = Set<String>()                    // session dirs the launcher "is processing"
    var outcomes: [String: PipelineOutcome] = [:]    // what the launcher "read" for a session (notification texts)
    var version: String?                         // what the launcher "knows" of the pipeline version (nil = not asked yet)
    var pipelineVersion: String? { version }
    /// What the launcher answers once the controller asks (`probePipelineVersion`): "0.2.0" = at once and new enough (the default, so
    /// that the scenarios that do not care about the version keep working), another version = an old pipeline answers, nil = no answer.
    var probeAnswer: String? = "0.2.0"
    private(set) var probes = 0
    var onVersionKnown: (() -> Void)?
    /// A launcher that answers at once: the controller, which asked on its own queue, sees the version when it reads it again (so no
    /// `onVersionKnown`, which would queue a publish that can outlive the test). A test that wants the real, later answer sets `version` and
    /// calls `onVersionKnown` itself.
    func probePipelineVersion() {
        probes += 1
        guard version == nil, let answer = probeAnswer else { return }
        version = answer
    }
    var folder: URL?
    func enqueue(_ sessionDir: URL) { enqueued.append(sessionDir) }
    func reprocessLast() { reprocessCalls += 1 }
    func reprocessPending() { pendingCalls += 1 }
    func isProcessing(_ sessionDir: URL) -> Bool { busy.contains { ShellUtil.sameFile(URL(fileURLWithPath: $0), sessionDir) } }
    func systemDidWake() { wakeCalls += 1 }
    func lastMeetingFolder() -> URL? { folder }
    func shutdown() { shutdownCalls += 1 }
    func outcome(forSession session: String) -> PipelineOutcome? { outcomes[session] }
}

private final class FakeNotifier: NotificationPosting {
    private let lock = NSLock()
    private var items: [AppNotification] = []
    func post(_ notification: AppNotification) { lock.lock(); items.append(notification); lock.unlock() }
    var posted: [AppNotification] { lock.lock(); defer { lock.unlock() }; return items }
    func count(_ kind: AppNotification.Kind) -> Int { posted.filter { $0.kind == kind }.count }
}

private func meetSignal(code: String = "abc-defg-hij", title: String? = nil, url: String? = nil) -> PlatformSignal {
    return PlatformSignal(platform: .meet, inCall: true, confidence: .high, titleHint: title,
                          meetingURL: url ?? "https://meet.google.com/\(code)", meetingKey: code,
                          bundleID: "com.google.Chrome", evidence: ["selftest"])
}

/// What the detector reports when it cannot read the Meet tab (Automation denied / query timed out): low confidence,
/// no code, no URL, no title.
private func meetSignalUnknownCode() -> PlatformSignal {
    return PlatformSignal(platform: .meet, inCall: true, confidence: .low, titleHint: nil, meetingURL: nil,
                          meetingKey: nil, bundleID: "com.google.Chrome", evidence: ["selftest: tab unknown"])
}

private func zoomSignal() -> PlatformSignal {
    return PlatformSignal(platform: .zoom, inCall: true, confidence: .high, titleHint: nil, meetingURL: nil,
                          meetingKey: nil, bundleID: "us.zoom.xos", evidence: ["selftest"])
}

/// A Zoom signal made by the real formula, with its `tier=` evidence (`Detector.evaluateZoom`): what the Detector hands the controller.
/// sockets 0 and no input = not in a call.
private func zoomEvidence(sockets: Int, input: Bool = false, output: Bool = false) -> PlatformSignal {
    let family = FamilyAudio(platform: .zoom, processes: [AudioProcessInfo(objectID: 1, pid: 787, bundleID: "us.zoom.xos", isRunningInput: input, isRunningOutput: output)])
    return Detector.evaluateZoom(ZoomEvaluationInput(audio: family, stableInput: input, stableOutput: output, mainPIDs: [787],
                                                     udpSockets: sockets, stableUDP: sockets >= 1))
}

/// One controller wired to fakes, plus helpers to drive virtual time.
private final class Harness {
    let root: URL
    let clock: VirtualClock
    let detector: FakeDetector
    let pipeline = FakePipeline()
    let notifier = FakeNotifier()
    var config: AppConfig
    var recorders: [FakeRecorder] = []
    var startError: Error?
    /// A recorder made by the test instead of a FakeRecorder (a real Recorder with synthetic sources); `recorders` stays empty then.
    var recorderMaker: ((URL, PlatformSignal) -> SessionRecording)?
    var gateIgnored = false                         // the next FakeRecorders have no gate (they ignore configureMuteGate)
    var freeDisk: Double? = 100
    /// Rescans the controller asked for (the startup scan looks again at a session that may be a live recording).
    /// They are only recorded; a test runs `work()` itself once it has aged the files.
    var rescans: [(delay: TimeInterval, work: () -> Void)] = []
    private(set) var states: [ControllerState] = []
    private(set) var controller: SessionController!
    let policyBox: PolicyBox

    var state: ControllerState { states.last ?? ControllerState() }
    var sessionsDir: URL { config.sessionsDir }
    var current: FakeRecorder? { recorders.last }

    /// SPEC 18 inputs of the controller (a struct, so that the trailing `configure` closure stays the only closure parameter).
    struct PolicyInputs {
        var policy: OrgPolicy = OrgPolicy.absent()
        var privacy: PrivacySettings? = nil
        var policyReader: (() -> OrgPolicy)? = nil
        var sessionPatch: ((Bool, String, URL) throws -> Void)? = nil
    }

    init(_ name: String, in base: URL, zoomTier: ZoomTierSettings = .defaults, policy inputs: PolicyInputs = PolicyInputs(),
         callApps: CallAppStore? = nil, callSettings: CallDetectSettings = .defaults,
         configure: (inout AppConfig) -> Void = { _ in }) {
        root = base.appendingPathComponent(name, isDirectory: true)
        policyBox = PolicyBox(inputs.policy)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var c = AppConfig.defaults()
        c.supportDir = root.appendingPathComponent("support", isDirectory: true)
        c.startDebounce = 4
        c.grace = 20
        c.minRecordingSeconds = 30
        c.maxRecordingHours = 6
        c.minFreeDiskGB = 5
        c.enabledPlatforms = [.meet, .zoom, .teams]         // the product default is zoom,teams (SPEC 15): scenarios that use Meet enable it explicitly
        // The product default is NOTIFY_RECORDING=1 (a start / stop notification for every recording). The scenarios below were written for
        // the four warning / result notifications and count what was posted, so they run with it off; testRecordingNotifications switches
        // it on explicitly and checks both settings.
        c.notifyRecording = false
        configure(&c)
        config = c
        // 2026-10-07 14:00:00 local time, so session ids are predictable ("2026-10-07_1400_meet").
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 0, second: 0)) ?? Date()
        clock = VirtualClock(start)
        detector = FakeDetector(clock: clock)
        controller = SessionController(
            config: config,
            detector: detector,
            recorderFactory: { [unowned self] dir, signal in
                if let make = self.recorderMaker { return make(dir, signal) }
                let r = FakeRecorder(dir: dir, signal: signal, clock: self.clock)
                r.startError = self.startError
                r.ignoresGate = self.gateIgnored
                self.recorders.append(r)
                return r
            },
            pipeline: pipeline,
            clock: { [unowned self] in self.clock.now },
            freeDiskGB: { [unowned self] in self.freeDisk },
            deliver: { work in work() },
            scheduleRescan: { [unowned self] delay, work in self.rescans.append((delay, work)) },
            notifier: notifier,
            zoomTier: zoomTier,
            policy: policyBox,
            privacy: inputs.privacy,
            policyReader: inputs.policyReader,
            sessionPatch: inputs.sessionPatch,
            callApps: callApps,
            callSettings: callSettings)
        controller.onState = { [unowned self] s in self.states.append(s) }
    }

    /// Advance virtual time in `step`-second ticks, polling with `signals`.
    func run(_ seconds: Int, step: Int = 1, _ signals: [PlatformSignal]) {
        detector.signals = signals
        var elapsed = 0
        while elapsed < seconds {
            clock.advance(TimeInterval(step))
            controller.tick()
            elapsed += step
        }
    }

    /// Tick until `done()` is true or `limit` seconds passed. Returns the seconds it took, or nil on timeout.
    @discardableResult
    func run(until done: () -> Bool, limit: Int, step: Int = 1, _ signals: [PlatformSignal]) -> Int? {
        detector.signals = signals
        var elapsed = 0
        while elapsed < limit {
            clock.advance(TimeInterval(step))
            controller.tick()
            elapsed += step
            if done() { return elapsed }
        }
        return nil
    }

    func sync() { controller.flush() }

    func sessionDirNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)) ?? []
        return names.sorted()
    }
}

// MARK: - Entry

func runSelftestSession() -> Int32 {
    L10n.current = .ko                      // the assertions below are the Korean texts (UI_LANGUAGE=ko); the English texts have their own checks (S-LO-13)
    // NSTemporaryDirectory() ignores $TMPDIR on macOS; honour it explicitly so callers can steer the temp files.
    let tmpRoot = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
    // standardized: the macOS default $TMPDIR ends with "/" and `make test-swift` builds "$TMPDIR/mcap-test.XXXX", so the path can
    // contain "//" - which AppConfig / URL normalise away, and the path comparisons in the checks below would then differ.
    let base = URL(fileURLWithPath: tmpRoot, isDirectory: true).standardizedFileURL
        .appendingPathComponent("mcap-selftest-session-\(getpid())", isDirectory: true)
    let fm = FileManager.default
    try? fm.removeItem(at: base)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    Log.fileURL = base.appendingPathComponent("app.log")
    Log.echoToStderr = false
    print("selftest-session: temp dir \(base.path)")

    // SPEC 17: from here on nothing in this process can reach the real Keychain: the Keychain tool is a shim script in the temp dir.
    let securityShim = FakeSecurityTool.install(in: base)
    fakeSecurityTool = securityShim
    setenv(ApiKeyItem.securityBinEnv, securityShim.bin.path, 1)
    defer { unsetenv(ApiKeyItem.securityBinEnv); fakeSecurityTool = nil }

    testConfigParsing(base)
    testZoomTierConfig(base)
    testDetectionStartStop(base)
    testSplit(base)
    testUnknownMeetCode(base)
    testManualRecording(base)
    testBlipRule(base)
    testManualStopSuppression(base)
    testPause(base)
    testStartFailureThrottle(base)
    testStartBackoff(base)
    testMaxDuration(base)
    testDiskLow(base)
    testSleepAndShutdown(base)
    testPowerOff(base)
    testRecorderWarningsAndSelfStop(base)
    testCrashRecoveryScan(base)
    testStartupScanRules(base)
    testPipelineLauncher(base)
    testPipelineWatchdog(base)
    testPipelineSweepJob(base)
    testPipelineChildEnvironment(base)
    testNoSpeechAutoStop(base)
    testNotifications(base)
    testNotifier()
    testNotificationContent()
    testNotificationRouting(base)
    testNotifierWiring(base)
    testRecordingNotifications(base)
    testZoomTierNotifications(base)
    testCallController(base)
    testCallTexts()
    testCallRecorderKeys(base)
    testNotificationTexts(base)
    testPipelineFacts(base)
    testSweepClass()
    testRetrySweep(base)
    testReprocessWhileRecording(base)
    testPureHelpers()
    testLaunchArguments()
    testMenuText()
    testAboutText()
    testAppNames()
    testFirstRun(base)
    testInstallHold(base)
    testPermissionInterpretation()
    testSetupRun(base)
    testClaudeBilling(base)
    testFakeSecurityNeverAskedForSecret()

    // SPEC 18
    testLOStartValues(base)
    testLORecorderKeys(base)
    testLOToggleRecording(base)
    testLOLocked(base)
    testLOToggleAfterStop(base)
    testLOLateAndFailures(base)
    testLOPipelineAge(base)
    testLOKillSwitch(base)
    testLOLauncherContract(base)
    testLOLauncherTrust(base)
    testLOEnvironment(base)
    testLONotificationTexts()
    testLOClickRouting(base)
    testLORetryAndFailures(base)
    testLOLogLines(base)
    testLOControllerContentFree(base)
    testLOContentFreeHelpers()
    testLOMenu(base)
    testLOFinishedTexts(base)
    testLOStartNotifications(base)
    testLOPolicyProblems(base)
    // SPEC 18: the microphone mute gate, controller side (the gate itself: selftest-capture --synthetic)
    testMGController(base)
    testMGMenu()
    testMGPreGate(base)
    // SPEC 18: the menu item 'Connect to Company Server...' and the enrollment child
    testCSAvailability(base)
    testCSStdin(base)
    testCSToken(base)
    testCSNotifications()
    testCSCodeField()
    testCSNoRelay(base)
    testCSChild(base)
    testCSDriftGuard()
    // Calendar auto-start (OFFLINE_AUTOSTART): S-CW-01 ... S-CW-13
    testCalendarWatcher(base)
    // The Settings window's model and the menu-bar icon mapping (SettingsSelfTests.swift): the catalog and the value rules, the config.env editor and writer, the
    // Keychain store (a fake security tool: never the real Keychain), the pipeline commands, the Terminal scripts, the restart guard, the privacy box, the
    // icons. It has its own counters and its own temp folder; its checks count here.
    section("S-ST-01: Settings window model, config.env writer, key storage, Terminal commands, restart guard, privacy box and menu-bar icons (runSettingsSelfTests)")
    let settingsResult = runSettingsSelfTests()
    checksPassed += settingsResult.pass
    checksFailed += settingsResult.fail
    check(settingsResult.fail == 0 && settingsResult.pass >= 300, "S-ST-01: the Settings checks passed (\(settingsResult.pass) passed, \(settingsResult.fail) failed)")

    // S-LO-01 runs last: the organisation-policy core of Policy.swift / LogRotation.swift / Setup.swift (the shared corpus config/policy-fixtures,
    // PrivacySettings, PolicyLayers, the resolver, EffectiveLanes, the contract, the runtime trust, the session patch, log rotation, setup,
    // policy-status). It has its own counters and its own temp folder; its checks count here.
    section("S-LO-01: organisation policy core (runPolicySelfTests)")
    let core = runPolicySelfTests()
    checksPassed += core.pass
    checksFailed += core.fail
    check(core.fail == 0 && core.pass >= 100, "S-LO-01: the policy core passed all its checks (\(core.pass) passed, \(core.fail) failed)")

    Log.flush()
    print("")
    if checksFailed == 0 {
        print("selftest-session: PASS (\(checksPassed) checks)")
        try? fm.removeItem(at: base)
        return 0
    }
    print("selftest-session: FAIL (\(checksFailed) failed, \(checksPassed) passed); files kept in \(base.path)")
    return 1
}

// MARK: - Config

private func testConfigParsing(_ base: URL) {
    section("config.env parsing")
    let text = "\u{FEFF}# comment\r\n" + """

    ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-x@example.com/My Drive/Meetings   # inline comment
    PROJECT_DIR = /tmp/some project
    PYTHON_BIN="/opt/py thon/bin/python"
    SELF_NAME=Tester
    ENABLED_PLATFORMS=meet, zoom ,bogus
    BROWSER_BUNDLE_IDS=com.google.Chrome,com.google.Chrome.beta
    POLL_INTERVAL_SECONDS=abc
    START_DEBOUNCE_SECONDS=6
    GRACE_SECONDS=-5
    MIN_RECORDING_SECONDS=45 # trailing
    MAX_RECORDING_HOURS=3.5
    MIN_FREE_DISK_GB=2
    SYSTEM_AUDIO_MODE=APP        # global | app
    ASR_MODEL=whatever/unknown-to-swift
    NOTE_MODEL=opus
    URL_WITH_HASH=https://x.y/z#frag
    no_equals_line
    =novalue_key
    """
    let parsed = AppConfig.parseEnvText(text)
    check(parsed["ARCHIVE_DIR"] == "~/Library/CloudStorage/GoogleDrive-x@example.com/My Drive/Meetings", "inline comment stripped, spaces kept", parsed["ARCHIVE_DIR"] ?? "nil")
    check(parsed["PROJECT_DIR"] == "/tmp/some project", "spaces around '=' trimmed", parsed["PROJECT_DIR"] ?? "nil")
    check(parsed["PYTHON_BIN"] == "/opt/py thon/bin/python", "quotes removed", parsed["PYTHON_BIN"] ?? "nil")
    check(parsed["URL_WITH_HASH"] == "https://x.y/z#frag", "'#' without leading space is not a comment", parsed["URL_WITH_HASH"] ?? "nil")
    check(parsed["no_equals_line"] == nil && parsed[""] == nil, "lines without key/'=' ignored")

    let cfg = AppConfig.build(from: parsed, source: "selftest")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    check(cfg.archiveDir.path == home + "/Library/CloudStorage/GoogleDrive-x@example.com/My Drive/Meetings", "~ expanded in ARCHIVE_DIR", cfg.archiveDir.path)
    check(cfg.projectDir.path == "/tmp/some project", "PROJECT_DIR", cfg.projectDir.path)
    check(cfg.pythonBin.path == "/opt/py thon/bin/python", "PYTHON_BIN", cfg.pythonBin.path)
    check(cfg.enabledPlatforms == [.meet, .zoom], "ENABLED_PLATFORMS drops unknown names", "\(cfg.enabledPlatforms)")
    check(cfg.browserBundleIDs == ["com.google.Chrome", "com.google.Chrome.beta"], "BROWSER_BUNDLE_IDS list")
    check(cfg.pollInterval == 2, "invalid POLL_INTERVAL_SECONDS keeps default", "\(cfg.pollInterval)")
    check(cfg.startDebounce == 6, "START_DEBOUNCE_SECONDS parsed", "\(cfg.startDebounce)")
    check(cfg.grace == 20, "negative GRACE_SECONDS keeps default", "\(cfg.grace)")
    check(cfg.minRecordingSeconds == 45, "MIN_RECORDING_SECONDS with trailing comment", "\(cfg.minRecordingSeconds)")
    check(cfg.maxRecordingHours == 3.5 && cfg.minFreeDiskGB == 2, "MAX_RECORDING_HOURS / MIN_FREE_DISK_GB")
    check(cfg.systemAudioMode == .app, "SYSTEM_AUDIO_MODE case-insensitive", "\(cfg.systemAudioMode)")
    check(cfg.claudeBin.path == AppConfig.defaults().claudeBin.path, "missing CLAUDE_BIN keeps default")

    let empty = AppConfig.build(from: ["ENABLED_PLATFORMS": ""], source: "selftest")
    check(empty.enabledPlatforms.isEmpty, "empty ENABLED_PLATFORMS means no auto detection")
    let allBad = AppConfig.build(from: ["ENABLED_PLATFORMS": "bogus,manual"], source: "selftest")
    check(allBad.enabledPlatforms == AppConfig.defaults().enabledPlatforms, "all-invalid ENABLED_PLATFORMS keeps default")
    let rel = AppConfig.build(from: ["ARCHIVE_DIR": "relative/dir", "SYSTEM_AUDIO_MODE": "weird"], source: "selftest")
    check(rel.archiveDir.path == AppConfig.defaults().archiveDir.path, "relative ARCHIVE_DIR rejected")
    check(rel.systemAudioMode == .global && rel.maxRecordingHours == 6, "bad SYSTEM_AUDIO_MODE keeps the default")

    // MAX_RECORDING_HOURS is clamped to 0.01...12 (WavWriter stops at 4 GiB = 12.4 h), with a warning.
    for (value, expected) in [("48", 12.0), ("12.4", 12.0), ("12", 12.0), ("6", 6.0), ("0.5", 0.5), ("0", 0.01), ("-3", 0.01)] {
        let c = AppConfig.build(from: ["MAX_RECORDING_HOURS": value], source: "selftest")
        check(c.maxRecordingHours == expected, "MAX_RECORDING_HOURS=\(value) -> \(expected)", "\(c.maxRecordingHours)")
    }
    for bad in ["abc", "nan", "inf", ""] {
        let c = AppConfig.build(from: ["MAX_RECORDING_HOURS": bad], source: "selftest")
        check(c.maxRecordingHours == 6, "MAX_RECORDING_HOURS='\(bad)' keeps the default", "\(c.maxRecordingHours)")
    }
    check(logCount("MAX_RECORDING_HOURS=48 is outside 0.01...12") >= 1, "clamping MAX_RECORDING_HOURS is logged as a warning")

    // An empty ENABLED_PLATFORMS stays supported, but is never silent.
    let warnedBefore = logCount("ENABLED_PLATFORMS is empty")
    let typo = AppConfig.build(from: AppConfig.parseEnvText("ENABLED_PLATFORMS=   # meet,zoom\n"), source: "selftest")
    check(typo.enabledPlatforms.isEmpty, "'ENABLED_PLATFORMS=   # meet,zoom' (comment only) parses to no platforms")
    check(logCount("ENABLED_PLATFORMS is empty") == warnedBefore + 1, "an empty ENABLED_PLATFORMS logs a warning")
    let commentedOut = AppConfig.build(from: AppConfig.parseEnvText("# ENABLED_PLATFORMS=meet\n"), source: "selftest")
    check(commentedOut.enabledPlatforms == AppConfig.defaults().enabledPlatforms, "a commented-out line keeps the default platforms")
    let sup = AppConfig.build(from: ["SUPPORT_DIR": base.path + "/sup"], source: "selftest")
    check(sup.supportDir.path == base.path + "/sup" && sup.pythonBin.path == base.path + "/sup/venv/bin/python", "SUPPORT_DIR override moves default PYTHON_BIN")

    // SPEC 15: Meet is off by default and has to be switched on explicitly.
    let dflt = AppConfig.build(from: [:], source: "selftest")
    check(AppConfig.defaults().enabledPlatforms == [.zoom, .teams] && dflt.enabledPlatforms == [.zoom, .teams],
          "default ENABLED_PLATFORMS is zoom,teams (Meet is opt-in)", "\(dflt.enabledPlatforms)")
    let withMeet = AppConfig.build(from: ["ENABLED_PLATFORMS": "zoom,teams,meet"], source: "selftest")
    check(withMeet.enabledPlatforms == [.zoom, .teams, .meet], "ENABLED_PLATFORMS=zoom,teams,meet turns Meet back on", "\(withMeet.enabledPlatforms)")
    let legacy = AppConfig.build(from: ["ENABLED_PLATFORMS": "meet,zoom,teams"], source: "selftest")
    check(legacy.enabledPlatforms == [.meet, .zoom, .teams], "an old config with meet listed keeps Meet", "\(legacy.enabledPlatforms)")

    // SPEC 15: NO_SPEECH_STOP_MINUTES and RETRY_SWEEP_HOURS: 0 = off, negative = default, others clamped; always with a warning.
    check(dflt.noSpeechStopMinutes == 15 && dflt.retrySweepHours == 6, "defaults: NO_SPEECH_STOP_MINUTES=15, RETRY_SWEEP_HOURS=6", "\(dflt.noSpeechStopMinutes) \(dflt.retrySweepHours)")
    let noSpeechCases: [(String, Double)] = [("30", 30), ("15", 15), ("1", 1), ("0", 0), ("0.0", 0), ("0.4", 1), ("0.99", 1), ("600", 600), ("9999", 600),
                                             ("-5", 15), ("-0.5", 15), ("abc", 15), ("nan", 15), ("inf", 15), ("", 15)]
    for (value, expected) in noSpeechCases {
        let c = AppConfig.build(from: ["NO_SPEECH_STOP_MINUTES": value], source: "selftest")
        check(c.noSpeechStopMinutes == expected, "NO_SPEECH_STOP_MINUTES='\(value)' -> \(expected)", "\(c.noSpeechStopMinutes)")
    }
    let sweepCases: [(String, Double)] = [("12", 12), ("6", 6), ("0.25", 0.25), ("0", 0), ("0.01", 0.25), ("1000", 168), ("168", 168),
                                          ("-1", 6), ("x", 6), ("nan", 6), ("", 6)]
    for (value, expected) in sweepCases {
        let c = AppConfig.build(from: ["RETRY_SWEEP_HOURS": value], source: "selftest")
        check(c.retrySweepHours == expected, "RETRY_SWEEP_HOURS='\(value)' -> \(expected)", "\(c.retrySweepHours)")
    }
    check(logCount("NO_SPEECH_STOP_MINUTES=0.4 is outside 1.0...600.0") >= 1 && logCount("NO_SPEECH_STOP_MINUTES=-5 is negative") >= 1
          && logCount("RETRY_SWEEP_HOURS=1000 is outside 0.25...168.0") >= 1 && logCount("RETRY_SWEEP_HOURS=x is not a number") >= 1,
          "clamped, negative and non-numeric values of the two new keys are logged as warnings")
    let both = AppConfig.build(from: AppConfig.parseEnvText("NO_SPEECH_STOP_MINUTES=20   # minutes\nRETRY_SWEEP_HOURS = 3\n"), source: "selftest")
    check(both.noSpeechStopMinutes == 20 && both.retrySweepHours == 3, "both keys parse from config.env text with comments and spaces")

    // SPEC 17: CLAUDE_AUTH (api by default | subscription, case-insensitive, anything else = warning + subscription) and CLAUDE_KEY_SERVICE.
    check(dflt.claudeAuth == .api && dflt.claudeKeychainService == "MeetingCapture Anthropic API key",
          "defaults: CLAUDE_AUTH=api, CLAUDE_KEY_SERVICE='MeetingCapture Anthropic API key'", "\(dflt.claudeAuth) '\(dflt.claudeKeychainService)'")
    let authCases: [(String, ClaudeAuthMode)] = [("subscription", .subscription), ("api", .api), ("API", .api), ("Api", .api), ("aPi", .api),
                                                 ("SUBSCRIPTION", .subscription), ("Subscription", .subscription)]
    for (value, expected) in authCases {
        let c = AppConfig.build(from: ["CLAUDE_AUTH": value], source: "selftest")
        check(c.claudeAuth == expected, "CLAUDE_AUTH='\(value)' -> \(expected)", "\(c.claudeAuth)")
    }
    let authWarnedBefore = logCount("must be 'subscription' or 'api'")
    for bad in ["apikey", "api-key", "bedrock", "true", "1", "none", "sub", "console", "api,subscription"] {
        let c = AppConfig.build(from: ["CLAUDE_AUTH": bad], source: "selftest")
        check(c.claudeAuth == .subscription, "invalid CLAUDE_AUTH='\(bad)' -> subscription (never api)", "\(c.claudeAuth)")
    }
    check(logCount("must be 'subscription' or 'api'") == authWarnedBefore + 9, "every invalid CLAUDE_AUTH logs a warning", "\(logCount("must be 'subscription' or 'api'") - authWarnedBefore)")
    check(logCount("CLAUDE_AUTH=bedrock must be 'subscription' or 'api' (in selftest); using subscription") >= 1, "the warning names the key, the value and the fallback")
    let authEmpty = AppConfig.build(from: ["CLAUDE_AUTH": ""], source: "selftest")
    check(authEmpty.claudeAuth == .api && logCount("must be 'subscription' or 'api'") == authWarnedBefore + 9, "empty CLAUDE_AUTH means the default (api), without a warning")
    let authText = AppConfig.build(from: AppConfig.parseEnvText("CLAUDE_AUTH = API   # Console credits\nCLAUDE_KEY_SERVICE=My Team Key   # keychain item\n"), source: "selftest")
    check(authText.claudeAuth == .api && authText.claudeKeychainService == "My Team Key", "CLAUDE_AUTH / CLAUDE_KEY_SERVICE parse from config.env text with spaces and a comment",
          "\(authText.claudeAuth) '\(authText.claudeKeychainService)'")
    let authQuoted = AppConfig.build(from: AppConfig.parseEnvText("CLAUDE_AUTH=\"api\"\nCLAUDE_KEY_SERVICE=\"Quoted Item\"\n"), source: "selftest")
    check(authQuoted.claudeAuth == .api && authQuoted.claudeKeychainService == "Quoted Item", "quoted values work too")
    let svc = AppConfig.build(from: ["CLAUDE_KEY_SERVICE": "Other Item"], source: "selftest")
    check(svc.claudeKeychainService == "Other Item" && svc.claudeAuth == .api, "CLAUDE_KEY_SERVICE alone does not switch the mode")
    let svcEmpty = AppConfig.build(from: ["CLAUDE_KEY_SERVICE": ""], source: "selftest")
    check(svcEmpty.claudeKeychainService == AppConfig.defaults().claudeKeychainService, "empty CLAUDE_KEY_SERVICE keeps the default")
    let apiFile = base.appendingPathComponent("cfg-api.env")
    try? "CLAUDE_AUTH=api\nCLAUDE_KEY_SERVICE=File Item\n".write(to: apiFile, atomically: true, encoding: .utf8)
    let apiLoaded = AppConfig.load(from: apiFile)
    check(apiLoaded.claudeAuth == .api && apiLoaded.claudeKeychainService == "File Item", "load(from:) reads CLAUDE_AUTH=api and CLAUDE_KEY_SERVICE from a file")

    // NOTIFY_RECORDING: a start / stop notification for every recording; on by default; 1/0, true/false, yes/no, on/off; anything else keeps the default
    check(dflt.notifyRecording && AppConfig.defaults().notifyRecording, "default: NOTIFY_RECORDING is on")
    let switchCases: [(String, Bool)] = [("1", true), ("0", false), ("true", true), ("FALSE", false), ("False", false), ("yes", true), ("No", false), ("on", true), ("OFF", false), (" 0 ", false)]
    for (value, expected) in switchCases {
        let c = AppConfig.build(from: ["NOTIFY_RECORDING": value], source: "selftest")
        check(c.notifyRecording == expected, "NOTIFY_RECORDING='\(value)' -> \(expected ? "on" : "off")", "\(c.notifyRecording)")
    }
    let switchWarnedBefore = logCount("NOTIFY_RECORDING=")
    for bad in ["maybe", "2", "enabled", "y", "-1", "nan"] {
        let c = AppConfig.build(from: ["NOTIFY_RECORDING": bad], source: "selftest")
        check(c.notifyRecording, "invalid NOTIFY_RECORDING='\(bad)' keeps the default (on)", "\(c.notifyRecording)")
    }
    check(logCount("NOTIFY_RECORDING=") == switchWarnedBefore + 6 && logCount("NOTIFY_RECORDING=maybe must be 1 or 0") >= 1, "every invalid NOTIFY_RECORDING logs a warning naming the key and the value")
    check(AppConfig.build(from: ["NOTIFY_RECORDING": ""], source: "selftest").notifyRecording, "empty NOTIFY_RECORDING means the default, without a warning")
    let switchText = AppConfig.build(from: AppConfig.parseEnvText("NOTIFY_RECORDING = 0   # no start/stop banners\n"), source: "selftest")
    check(!switchText.notifyRecording, "NOTIFY_RECORDING parses from config.env text with spaces and a comment")

    let file = base.appendingPathComponent("cfg-test.env")
    try? "GRACE_SECONDS=33\nSELF_NAME=Tester\n".write(to: file, atomically: true, encoding: .utf8)
    let loaded = AppConfig.load(from: file)
    check(loaded.grace == 33 && loaded.selfName == "Tester", "load(from:) reads a file")
    let missing = AppConfig.load(from: base.appendingPathComponent("does-not-exist.env"))
    check(missing.grace == AppConfig.defaults().grace && missing.supportDir == AppConfig.defaults().supportDir, "missing file means defaults")
}

// MARK: - Controller scenarios

private func testDetectionStartStop(_ base: URL) {
    section("detection: debounce, session naming, metadata, grace, pipeline hand-off")
    let h = Harness("startstop", in: base)
    let meet = meetSignal()

    h.run(2, [meet])
    check(h.recorders.isEmpty, "no recording before the start debounce")
    check(h.state.status == .candidate(.meet), "status is 'meeting detected' while debouncing", "\(h.state.status)")

    let startedAfter = h.run(until: { !h.recorders.isEmpty }, limit: 12, [meet])
    let total = 2 + (startedAfter ?? 99)
    check(startedAfter != nil && total >= 3 && total <= 7, "recording starts about START_DEBOUNCE_SECONDS (4 s) after the call began", "after \(total)s")
    guard let rec = h.current else { return }
    check(rec.dir.lastPathComponent == "2026-10-07_1400_meet", "session id YYYY-MM-DD_HHMM_<platform>", rec.dir.lastPathComponent)
    check(FileManager.default.fileExists(atPath: rec.dir.path) && rec.dir.deletingLastPathComponent().lastPathComponent == "sessions",
          "session dir created under sessions/")
    check(rec.isRecording, "recorder started")
    if case .recording(let p, let since) = h.state.status {
        check(p == .meet && since == rec.startedAt, "status .recording(meet, since: recorder start)")
    } else {
        check(false, "status is recording", "\(h.state.status)")
    }

    h.run(2, [meetSignal(title: "Weekly Sync - Google Meet")])
    check(rec.metaUpdates.last?.title == "Weekly Sync - Google Meet", "newest title hint forwarded to recorder.updateMeta", "\(rec.metaUpdates)")
    check(rec.metaUpdates.last?.url == "https://meet.google.com/abc-defg-hij", "meeting URL forwarded", "\(rec.metaUpdates)")
    let metaCount = rec.metaUpdates.count
    h.run(2, [meetSignal(title: "Weekly Sync - Google Meet")])
    check(rec.metaUpdates.count == metaCount, "unchanged metadata is not re-sent")

    h.run(10, [])
    check(rec.isRecording, "10 s without call signal (< grace) keeps recording")
    h.run(5, [meet])
    check(h.recorders.count == 1 && rec.stopReasons.isEmpty, "signal returning within grace does not split or stop")

    let stoppedAfter = h.run(until: { !rec.isRecording }, limit: 40, [])
    check(stoppedAfter != nil && stoppedAfter! >= 17 && stoppedAfter! <= 25, "stops about GRACE_SECONDS (20 s) after the call ended", "after \(stoppedAfter ?? -1)s")
    check(rec.stopReasons == [.meetingEnded], "stop reason meeting-ended", "\(rec.stopReasons)")
    check(h.pipeline.enqueued.map { $0.lastPathComponent } == ["2026-10-07_1400_meet"], "session handed to the pipeline", "\(h.pipeline.enqueued)")
    check(h.state.status == .processing("Queued"), "status shows processing right after stop", "\(h.state.status)")

    let sid = "2026-10-07_1400_meet"
    h.pipeline.onEvent?(.progress(session: sid, text: "Transcribing remote 12/48")); h.sync()
    check(h.state.status == .processing("Transcribing remote 12/48"), "pipeline progress text reaches the menu", "\(h.state.status)")
    h.pipeline.onEvent?(.finished(session: sid, title: "Weekly Sync", finalDir: nil, discarded: false)); h.sync()
    check(h.state.status == .done("Weekly Sync"), "finished -> done(title)", "\(h.state.status)")
    h.run(12, [])
    check(h.state.status == .idle, "done is shown only briefly, then idle", "\(h.state.status)")

    h.pipeline.onEvent?(.failed(session: sid, message: "boom")); h.sync()
    if case .error(let text) = h.state.status {
        check(text.contains("boom") && text.contains(sid), "pipeline failure -> sticky error status", text)
    } else {
        check(false, "pipeline failure -> error status", "\(h.state.status)")
    }
    h.run(30, [])
    if case .error = h.state.status { check(true, "pipeline error stays visible") } else { check(false, "pipeline error stays visible", "\(h.state.status)") }
    h.pipeline.onEvent?(.finished(session: sid, title: nil, finalDir: nil, discarded: true)); h.sync()
    check(h.state.status == .idle, "a later success for that session clears the error; discarded sessions show no 'done'", "\(h.state.status)")

    h.controller.reprocessLast(); h.sync()
    check(h.pipeline.reprocessCalls == 1 && h.state.status == .processing("Queued: reprocess last meeting"), "Reprocess Last Meeting reaches the pipeline", "\(h.state.status)")
}

private func testSplit(_ base: URL) {
    section("back-to-back Meet meetings are split")
    let h = Harness("split", in: base)
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meetSignal(code: "aaa-bbbb-ccc")])
    h.run(10, [meetSignal(code: "aaa-bbbb-ccc")])
    guard let first = h.current else { check(false, "first recording started"); return }
    let secondAfter = h.run(until: { h.recorders.count >= 2 }, limit: 120, [meetSignal(code: "ddd-eeee-fff")])
    check(secondAfter != nil, "second session starts after the Meet code changed and stayed changed", "recorders=\(h.recorders.count)")
    check(first.stopReasons == [.meetingEnded] && !first.isRecording, "first session finalized", "\(first.stopReasons)")
    check(h.pipeline.enqueued == [first.dir], "first session enqueued, exactly once", "\(h.pipeline.enqueued)")
    if h.recorders.count >= 2 {
        let second = h.recorders[1]
        check(second.signal.meetingKey == "ddd-eeee-fff" && second.isRecording, "second recorder belongs to the new meeting")
        check(second.dir != first.dir, "second session has its own folder", second.dir.lastPathComponent)
        check(first.metaUpdates.allSatisfy { $0.url?.contains("ddd-eeee-fff") != true }, "new meeting's URL was not written into the old session")
    }
}

private func testUnknownMeetCode(_ base: URL) {
    section("a Meet session that starts without a meeting code learns it later (key nil -> code)")
    let h = Harness("unknowncode", in: base)
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meetSignalUnknownCode()])
    guard let rec = h.current else { check(false, "recording started from the low-confidence signal"); return }
    check(rec.isRecording && rec.metaUpdates.isEmpty, "recording started; the signal carried no title or URL yet", "\(rec.metaUpdates)")
    h.run(3, [meetSignal(code: "abc-defg-hij", title: "Weekly Sync - Google Meet")])
    check(rec.metaUpdates.last?.title == "Weekly Sync - Google Meet" && rec.metaUpdates.last?.url == "https://meet.google.com/abc-defg-hij",
          "title and URL that arrive with the real code reach recorder.updateMeta (session.json no longer stays null)", "\(rec.metaUpdates)")
    check(logCount("meeting code learned for the active session: meet:abc-defg-hij") == 1, "the adopted code is logged once")
    check(h.recorders.count == 1 && rec.isRecording, "learning the code does not split or stop the session")
    let n = rec.metaUpdates.count
    h.run(3, [meetSignal(code: "zzz-yyyy-xxx", title: "Other meeting")])
    check(rec.metaUpdates.count == n, "once the code is known, a different known code is not forwarded into this session", "\(rec.metaUpdates)")
    h.run(3, [meetSignalUnknownCode()])
    check(rec.isRecording && rec.metaUpdates.count == n, "a signal without a code afterwards changes nothing")

    // The reverse order: known code first, later signals without a code are the same meeting (no block, no crash).
    let r = Harness("knowncode-then-unknown", in: base)
    r.run(until: { !r.recorders.isEmpty }, limit: 15, [meetSignal(code: "abc-defg-hij")])
    r.run(3, [meetSignalUnknownCode()])
    check(r.recorders.count == 1 && r.current?.isRecording == true, "known code, then a code-less signal: still one session")

    // sameMeeting / keyIsUnknown
    check(SessionController.sameMeeting("meet:-", "meet:abc") && SessionController.sameMeeting("meet:abc", "meet:-"), "sameMeeting: unknown code matches any code")
    check(!SessionController.sameMeeting("meet:abc", "meet:def"), "sameMeeting: two known, different codes never match")
    check(!SessionController.sameMeeting("meet:-", "zoom:-"), "sameMeeting: different platforms never match")
    check(SessionController.sameMeeting("zoom:-", "zoom:-") && SessionController.keyIsUnknown("zoom:-") && !SessionController.keyIsUnknown("meet:abc"), "sameMeeting / keyIsUnknown basics")

    // The start-failure throttle is keyed more carefully than "unknown matches everything": a failure recorded WITHOUT a code
    // never delays a call that shows a real code (it used to, for up to 5 minutes), while a failure WITH a code still covers
    // the same call when its tab becomes unreadable.
    for (failed, key, expected) in [("meet:-", "meet:abc", false), ("meet:abc", "meet:-", true), ("meet:abc", "meet:abc", true),
                                    ("meet:abc", "meet:def", false), ("meet:-", "meet:-", true), ("zoom:-", "meet:-", false),
                                    ("zoom:-", "zoom:-", true), ("meet:-", "zoom:abc", false)] {
        check(SessionController.throttleApplies(failedKey: failed, to: key) == expected, "throttleApplies(failed \(failed), signal \(key)) == \(expected)")
    }
    let throttledBefore = logCount("start for meet:abc-defg-hij suppressed until")
    let f = Harness("unknowncode-throttle", in: base)
    f.startError = RecorderError.permissionDenied("microphone")
    f.run(until: { !f.recorders.isEmpty }, limit: 15, [meetSignalUnknownCode()])
    f.run(200, [meetSignal(code: "abc-defg-hij")])
    check(f.recorders.count == 2, "start failed without a code: the call that now shows a real code is NOT held back by it (one more attempt, then its own lockout)",
          "attempts=\(f.recorders.count)")
    check(logCount("start for meet:abc-defg-hij suppressed until") > throttledBefore, "... and that second failure starts its own 300 s lockout (no storm)")
    let g = Harness("knowncode-then-unreadable-throttle", in: base)
    g.startError = RecorderError.permissionDenied("microphone")
    g.run(until: { !g.recorders.isEmpty }, limit: 15, [meetSignal(code: "abc-defg-hij")])
    g.run(200, [meetSignalUnknownCode()])
    check(g.recorders.count == 1, "start failed WITH a code: the same call with an unreadable tab stays throttled", "attempts=\(g.recorders.count)")
    let w = Harness("unknowncode-newcall", in: base)
    w.startError = RecorderError.deviceUnavailable("busy")
    w.run(until: { !w.recorders.isEmpty }, limit: 15, [meetSignalUnknownCode()])        // fails, 10 s backoff for meet:-
    let attempt1 = w.clock.now
    w.run(until: { w.recorders.count >= 2 }, limit: 30, [meetSignal(code: "zzz-yyyy-xxx")])
    check(w.recorders.count >= 2 && w.clock.now.timeIntervalSince(attempt1) < 10, "a different call with a real code starts within the debounce, not after the 10 s backoff of the unknown-code failure",
          "attempts=\(w.recorders.count) after \(w.clock.now.timeIntervalSince(attempt1)) s")

    let u = Harness("unknowncode-userstop", in: base)
    u.run(until: { !u.recorders.isEmpty }, limit: 15, [meetSignalUnknownCode()])
    u.run(12, [meetSignalUnknownCode()])
    u.controller.stopRecordingNow(); u.sync()
    u.run(90, [meetSignal(code: "abc-defg-hij")])
    check(u.recorders.count == 1, "stopped by hand without a code: the same call, now with its code, is not auto-restarted", "recorders=\(u.recorders.count)")

    let v = Harness("knowncode-userstop", in: base)
    v.run(until: { !v.recorders.isEmpty }, limit: 15, [meetSignal(code: "abc-defg-hij")])
    v.run(12, [meetSignal(code: "abc-defg-hij")])
    v.controller.stopRecordingNow(); v.sync()
    v.run(90, [meetSignalUnknownCode()])
    check(v.recorders.count == 1, "stopped by hand with a code: the same call without a code is not auto-restarted", "recorders=\(v.recorders.count)")
    v.run(60, [])
    v.run(until: { v.recorders.count >= 2 }, limit: 20, [meetSignal(code: "abc-defg-hij")])
    check(v.recorders.count == 2, "after the meeting ended, the next call is recorded again", "recorders=\(v.recorders.count)")
}

private func testManualRecording(_ base: URL) {
    section("manual Start/Stop Recording Now")
    let h = Harness("manual", in: base)
    h.controller.startRecordingNow(); h.sync()
    guard let rec = h.current else { check(false, "manual start creates a recorder"); return }
    check(rec.isRecording && rec.signal.platform == .manual, "manual recording uses platform .manual")
    check(rec.dir.lastPathComponent == "2026-10-07_1400_manual", "manual session id", rec.dir.lastPathComponent)
    check(h.state.manualRecording, "state flags the manual recording")
    h.run(120, [])
    check(rec.isRecording && rec.stopReasons.isEmpty, "manual recording is never auto-stopped by the detector (no call for 120 s)")
    h.controller.startRecordingNow(); h.sync()
    check(h.recorders.count == 1, "second Start while recording is ignored")
    h.controller.stopRecordingNow(); h.sync()
    check(rec.stopReasons == [.manual], "Stop Recording Now stops with reason manual", "\(rec.stopReasons)")
    check(h.pipeline.enqueued == [rec.dir], "long manual session goes to the pipeline")

    // A short manual recording is an explicit user action: kept and processed (the pipeline discards no-speech sessions).
    let blip = Harness("manual-short", in: base)
    blip.controller.startRecordingNow(); blip.sync()
    blip.run(3, [])
    let dir = blip.current?.dir
    blip.controller.stopRecordingNow(); blip.sync()
    check(dir != nil && FileManager.default.fileExists(atPath: dir!.path), "a 3 s manual recording is kept, not deleted as a blip")
    check(blip.pipeline.enqueued == (dir.map { [$0] } ?? []), "a short manual recording is handed to the pipeline", "\(blip.pipeline.enqueued)")
    check(blip.state.status == .processing("Queued"), "status shows processing after a short manual stop", "\(blip.state.status)")

    let keep = Harness("manual-keep", in: base)
    keep.controller.startRecordingNow(); keep.sync()
    keep.run(12, [])
    let keepDir = keep.current?.dir
    keep.controller.stopRecordingNow(); keep.sync()
    check(keepDir != nil && FileManager.default.fileExists(atPath: keepDir!.path) && keep.pipeline.enqueued.count == 1,
          "12 s recording is kept and processed")
}

// MARK: - Blip rule

private func testBlipRule(_ base: URL) {
    section("blip rule: only a short AUTO session ended by meeting-ended / sleep / app-quit is deleted")
    let fm = FileManager.default
    let meet = meetSignal()

    // Table first.
    for (manual, reason, expected) in [(false, EndReason.meetingEnded, true), (false, .sleep, true), (false, .appQuit, true),
                                       (false, .manual, false), (false, .paused, false), (false, .diskLow, false),
                                       (false, .maxDuration, false), (false, .crashRecovered, false),
                                       (true, .meetingEnded, false), (true, .sleep, false), (true, .appQuit, false), (true, .manual, false)] {
        check(SessionController.mayDeleteBlip(manual: manual, reason: reason) == expected,
              "mayDeleteBlip(manual: \(manual), \(reason.rawValue)) == \(expected)")
    }

    // Start Recording Now, Stop 8 s later: kept (the bug: it used to be deleted).
    let a = Harness("blip-manual-8s", in: base)
    a.controller.startRecordingNow(); a.sync()
    a.run(8, [])
    let aDir = a.current?.dir
    a.controller.stopRecordingNow(); a.sync()
    check(aDir != nil && fm.fileExists(atPath: aDir!.path) && a.pipeline.enqueued == (aDir.map { [$0] } ?? []),
          "Start Recording Now + Stop 8 s later: folder kept and queued")

    // Pause 5 s after an AUTO start: kept (reason paused).
    let b = Harness("blip-pause", in: base)
    b.run(until: { !b.recorders.isEmpty }, limit: 15, [meet])
    b.run(5, [meet])
    let bRec = b.current
    b.controller.setPaused(true); b.sync()
    check(bRec?.stopReasons == [.paused] && bRec.map { fm.fileExists(atPath: $0.dir.path) } == true && b.pipeline.enqueued.count == 1,
          "Pause 5 s after an auto start: session kept and queued")

    // Stop Recording Now 4 s after an AUTO start: kept (reason manual).
    let c = Harness("blip-stopnow", in: base)
    c.run(until: { !c.recorders.isEmpty }, limit: 15, [meet])
    c.run(4, [meet])
    let cRec = c.current
    c.controller.stopRecordingNow(); c.sync()
    check(cRec?.stopReasons == [.manual] && cRec.map { fm.fileExists(atPath: $0.dir.path) } == true && c.pipeline.enqueued.count == 1,
          "Stop Recording Now 4 s after an auto start: session kept and queued")

    // Sleep 3 s after an AUTO start: deleted, and the log says which files went.
    let d = Harness("blip-sleep", in: base)
    d.run(until: { !d.recorders.isEmpty }, limit: 15, [meet])
    d.run(3, [meet])
    let dRec = d.current
    d.controller.systemWillSleep()
    check(dRec?.stopReasons == [.sleep] && dRec.map { !fm.fileExists(atPath: $0.dir.path) } == true && d.pipeline.enqueued.isEmpty,
          "sleep 3 s after an auto start: accidental blip, folder deleted, nothing queued")
    let log = logText()
    check(log.contains("accidental blip") && log.contains("mic.wav=1024 B") && log.contains("remote.wav=2048 B"),
          "the deletion log line lists the file sizes")

    // App quit 2 s after an AUTO start: deleted. The same at quit for a MANUAL recording: kept.
    let e = Harness("blip-quit-auto", in: base)
    e.run(until: { !e.recorders.isEmpty }, limit: 15, [meet])
    e.run(2, [meet])
    let eDir = e.current?.dir
    e.controller.shutdown(reason: .appQuit)
    check(eDir != nil && !fm.fileExists(atPath: eDir!.path), "app quit 2 s after an auto start: blip deleted")
    let f = Harness("blip-quit-manual", in: base)
    f.controller.startRecordingNow(); f.sync()
    f.run(2, [])
    let fDir = f.current?.dir
    f.controller.shutdown(reason: .appQuit)
    check(fDir != nil && fm.fileExists(atPath: fDir!.path), "app quit 2 s into a MANUAL recording: kept (picked up by the next launch)")

    // A recorder that dies by itself right after an auto start: reason meeting-ended, duration ~0: deleted.
    let g = Harness("blip-selfstop", in: base)
    g.run(until: { !g.recorders.isEmpty }, limit: 15, [meet])
    let gRec = g.current
    gRec?.isRecording = false
    g.run(1, [meet])
    check(gRec.map { !fm.fileExists(atPath: $0.dir.path) } == true && g.pipeline.enqueued.isEmpty,
          "an auto recorder that died within seconds is a blip: deleted")

    // MIN_RECORDING_SECONDS=0 disables deletion altogether.
    let h = Harness("blip-disabled", in: base) { $0.minRecordingSeconds = 0 }
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    h.run(2, [meet])
    let hRec = h.current
    h.controller.systemWillSleep()
    check(hRec.map { fm.fileExists(atPath: $0.dir.path) } == true && h.pipeline.enqueued.count == 1,
          "MIN_RECORDING_SECONDS=0: nothing is deleted as a blip")
}

private func testManualStopSuppression(_ base: URL) {
    section("stopping a detected meeting by hand does not restart it")
    let h = Harness("userstop", in: base)
    let meet = meetSignal()
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    h.run(15, [meet])
    h.controller.stopRecordingNow(); h.sync()
    check(h.current?.stopReasons == [.manual], "manual stop of an auto session")
    check(h.state.restartHold == .stoppedCall && h.controller.restartHold == .stoppedCall,
          "Stop Recording Now in a live call: the restart hold says a relaunch would record it again (the Settings window's armed restart must not fire)", "\(String(describing: h.state.restartHold))")
    h.run(90, [meet])
    check(h.recorders.count == 1, "same meeting is not auto-restarted while it is still running", "recorders=\(h.recorders.count)")
    check(h.state.restartHold == .stoppedCall, "... and the hold lasts as long as the call does")
    h.run(60, [])
    check(h.state.restartHold == nil && h.controller.restartHold == nil, "the call is over: nothing is held any more, the restart may go")
    h.run(until: { h.recorders.count >= 2 }, limit: 20, [meet])
    check(h.recorders.count == 2, "after the meeting ended, a new call is recorded again", "recorders=\(h.recorders.count)")
}

private func testPause(_ base: URL) {
    section("Pause Auto Recording")
    let h = Harness("pause", in: base)
    let meet = meetSignal()
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    h.run(20, [meet])
    guard let first = h.current else { check(false, "recording started"); return }
    h.controller.setPaused(true); h.sync()
    check(first.stopReasons == [.paused], "pausing while recording stops it with reason paused", "\(first.stopReasons)")
    check(h.pipeline.enqueued == [first.dir], "paused recording is kept and processed")
    check(h.state.paused, "state.paused is true")
    check(h.state.restartHold == .paused && h.controller.restartHold == .paused, "paused: the restart hold is published (a relaunch would forget the pause), also for the thread-safe reader")
    let polls = h.detector.polls
    h.run(40, [meet])
    check(h.recorders.count == 1, "no auto start while paused")
    check(h.detector.polls == polls, "detector is not polled while paused")
    h.controller.setPaused(false); h.sync()
    check(!h.state.paused, "state.paused cleared on resume")
    check(h.state.restartHold == nil && h.controller.restartHold == nil, "resumed: no restart hold")
    h.run(until: { h.recorders.count >= 2 }, limit: 15, [meet])
    check(h.recorders.count == 2 && h.current?.isRecording == true, "resuming picks the running meeting up again", "recorders=\(h.recorders.count)")

    // Pause is not persisted: a fresh controller starts unpaused.
    let fresh = Harness("pause-fresh", in: base)
    check(!fresh.state.paused, "a new controller starts unpaused (pause is not persisted)")
}

private func testStartFailureThrottle(_ base: URL) {
    section("Recorder.start() failure: actionable error, retry at most every 5 minutes")
    let h = Harness("startfail", in: base)
    h.startError = RecorderError.permissionDenied("microphone")
    let meet = meetSignal()
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    check(h.recorders.count == 1 && h.current?.isRecording == false, "start attempted once and failed")
    if case .error(let text) = h.state.status {
        check(text.contains("permission denied") && text.contains("System Settings"), "error says which permission and where to grant it", text)
        check(text.contains("Will retry in 5 min"), "permission failures lock out for the long 5 minutes", text)
    } else {
        check(false, "status is error after a failed start", "\(h.state.status)")
    }
    check(h.sessionDirNames().isEmpty, "empty session folder removed after failed start", "\(h.sessionDirNames())")
    h.run(240, [meet])
    check(h.recorders.count == 1, "no retry within 5 minutes (240 s later still 1 attempt)", "attempts=\(h.recorders.count)")
    if case .error = h.state.status { check(true, "error stays visible while suppressed") } else { check(false, "error stays visible while suppressed", "\(h.state.status)") }

    h.startError = nil
    h.run(until: { h.recorders.count >= 2 }, limit: 120, [meet])
    check(h.recorders.count == 2 && h.current?.isRecording == true, "retry after 5 minutes succeeds once permission is granted", "attempts=\(h.recorders.count)")
    if case .recording = h.state.status { check(true, "error cleared by the successful start") } else { check(false, "error cleared by the successful start", "\(h.state.status)") }

    // Manual start is an explicit user action: no throttle.
    let m = Harness("startfail-manual", in: base)
    m.startError = RecorderError.deviceUnavailable("no input")
    m.controller.startRecordingNow(); m.sync()
    if case .error(let text) = m.state.status { check(text.contains("no input"), "manual start failure shows the reason", text) } else { check(false, "manual start failure shows an error", "\(m.state.status)") }
    m.startError = nil
    m.controller.startRecordingNow(); m.sync()
    check(m.current?.isRecording == true && m.recorders.count == 2, "manual retry works immediately")
}

private func testStartBackoff(_ base: URL) {
    section("start failure backoff: 10 s, 30 s, 60 s, then 300 s (permission denied: 300 s at once)")
    let meet = meetSignal()
    let h = Harness("backoff", in: base)
    h.startError = RecorderError.deviceUnavailable("Bluetooth is switching profile")
    let candidatesBefore = logCount("meeting candidate")
    let suppressedBefore = logCount("suppressed until")
    h.run(until: { h.recorders.count >= 1 }, limit: 15, [meet])
    if case .error(let text) = h.state.status {
        check(text.contains("audio device unavailable") && text.contains("Will retry in 10 s"), "first transient failure: retry in 10 s", text)
    } else {
        check(false, "status is error after the first failed start", "\(h.state.status)")
    }
    h.run(3600, [meet])                                   // one hour of a call whose recorder never starts
    let times = h.recorders.map { $0.startedAt.timeIntervalSince(h.recorders[0].startedAt) }
    let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
    func gap(_ i: Int, _ delay: Double) -> Bool { i < gaps.count && gaps[i] >= delay && gaps[i] <= delay + 8 }
    check(gap(0, 10), "second attempt about 10 s after the first", "gaps=\(gaps.prefix(6).map { Int($0) })")
    check(gap(1, 30), "third attempt about 30 s after the second", "gaps=\(gaps.prefix(6).map { Int($0) })")
    check(gap(2, 60), "fourth attempt about 60 s after the third", "gaps=\(gaps.prefix(6).map { Int($0) })")
    check(gap(3, 300) && gap(4, 300), "from then on every 300 s", "gaps=\(gaps.prefix(6).map { Int($0) })")
    check(h.recorders.count >= 12 && h.recorders.count <= 18, "about 15 attempts in an hour, no retry storm", "attempts=\(h.recorders.count)")
    let candidateLines = logCount("meeting candidate") - candidatesBefore
    check(candidateLines <= h.recorders.count + 1, "'meeting candidate' is logged about once per attempt, not every cycle (was 601 per hour)",
          "\(candidateLines) lines for \(h.recorders.count) attempts")
    let suppressedLines = logCount("suppressed until") - suppressedBefore
    check(suppressedLines >= 3 && suppressedLines <= h.recorders.count, "the 'suppressed until' line is logged once per lockout window", "\(suppressedLines) lines for \(h.recorders.count) attempts")

    // The device comes back: recording starts; the failure memory is cleared, so a later failure begins at 10 s again.
    h.startError = nil
    let before = h.recorders.count
    h.run(until: { h.recorders.count > before && h.current?.isRecording == true }, limit: 400, [meet])
    check(h.current?.isRecording == true, "recording starts as soon as the device works again")
    h.run(60, [])                                          // call ends (grace), session stops
    h.startError = RecorderError.deviceUnavailable("busy again")
    let again = h.recorders.count
    h.run(until: { h.recorders.count > again }, limit: 30, [meet])
    let firstFail = h.clock.now
    h.run(until: { h.recorders.count > again + 1 }, limit: 40, [meet])
    let secondTry = h.recorders.last?.startedAt ?? firstFail
    let g = secondTry.timeIntervalSince(firstFail)
    check(h.recorders.count > again + 1 && g >= 10 && g <= 18, "after a success the backoff starts over at 10 s (not 300 s)", "gap=\(g) attempts=\(h.recorders.count - again)")

    // Permission problems lock out for 5 minutes immediately.
    let p = Harness("backoff-permission", in: base)
    p.startError = RecorderError.permissionDenied("system audio")
    p.run(until: { p.recorders.count >= 1 }, limit: 15, [meet])
    p.run(280, [meet])
    check(p.recorders.count == 1, "permission denied: no second attempt within 280 s", "attempts=\(p.recorders.count)")
    p.run(until: { p.recorders.count >= 2 }, limit: 60, [meet])
    check(p.recorders.count == 2, "permission denied: next attempt after the 5 minute lockout", "attempts=\(p.recorders.count)")

    // Manual starts are never throttled.
    let m = Harness("backoff-manual", in: base)
    m.startError = RecorderError.deviceUnavailable("busy")
    for _ in 0..<3 { m.controller.startRecordingNow(); m.sync() }
    check(m.recorders.count == 3, "manual starts are never throttled", "attempts=\(m.recorders.count)")
    check(SessionController.describeDelay(10) == "10 s" && SessionController.describeDelay(60) == "1 min" && SessionController.describeDelay(300) == "5 min", "describeDelay")
}

private func testMaxDuration(_ base: URL) {
    section("MAX_RECORDING_HOURS")
    let h = Harness("maxdur", in: base) { $0.maxRecordingHours = 1 }
    let meet = meetSignal()
    h.run(until: { !h.recorders.isEmpty }, limit: 30, step: 2, [meet])
    guard let first = h.current else { check(false, "recording started"); return }
    h.run(until: { !first.isRecording }, limit: 4000, step: 10, [meet])
    check(first.stopReasons == [.maxDuration], "stopped with max-duration", "\(first.stopReasons)")
    let ran = h.clock.now.timeIntervalSince(first.startedAt)
    check(ran >= 3600 && ran < 3640, "stopped at about 1 h", "\(ran)")
    check(h.pipeline.enqueued == [first.dir], "capped session is processed")
    h.run(until: { h.recorders.count >= 2 }, limit: 60, step: 2, [meet])
    check(h.recorders.count == 2 && h.current?.isRecording == true, "a meeting that is still running continues in a new session", "recorders=\(h.recorders.count)")
}

private func testDiskLow(_ base: URL) {
    section("MIN_FREE_DISK_GB")
    let h = Harness("disk", in: base)
    let meet = meetSignal()
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    h.run(35, [meet])
    guard let first = h.current else { check(false, "recording started"); return }
    check(first.isRecording, "recording while disk is fine")
    h.freeDisk = 1.5
    h.run(until: { !first.isRecording }, limit: 70, [meet])
    check(first.stopReasons == [.diskLow], "stopped with disk-low within the 30 s check interval", "\(first.stopReasons)")
    check(h.pipeline.enqueued == [first.dir], "the audio recorded so far is kept and processed")
    if case .error(let text) = h.state.status { check(text.contains("Disk space low"), "error explains low disk", text) } else { check(false, "error status for low disk", "\(h.state.status)") }
    h.run(120, [meet])
    check(h.recorders.count == 1, "no new recording while disk is low", "recorders=\(h.recorders.count)")
    h.freeDisk = 80
    h.run(until: { h.recorders.count >= 2 }, limit: 400, [meet])
    check(h.recorders.count == 2 && h.current?.isRecording == true, "recording resumes after space is freed (5 min retry)", "recorders=\(h.recorders.count)")
}

private func testSleepAndShutdown(_ base: URL) {
    section("system sleep and app quit always finalize")
    let h = Harness("sleep", in: base)
    let meet = meetSignal()
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    h.run(20, [meet])
    guard let first = h.current else { check(false, "recording started"); return }
    h.controller.systemWillSleep()
    check(first.stopReasons == [.sleep] && !first.isRecording, "willSleep stops synchronously with reason sleep", "\(first.stopReasons)")
    check(h.pipeline.enqueued == [first.dir], "slept session is processed")
    h.run(until: { h.recorders.count >= 2 }, limit: 15, [meet])
    check(h.recorders.count == 2, "after wake a still-running call starts a new session")

    let q = Harness("quit", in: base)
    q.run(until: { !q.recorders.isEmpty }, limit: 15, [meet])
    q.run(20, [meet])
    guard let rec = q.current else { check(false, "recording started"); return }
    q.controller.shutdown(reason: .appQuit)
    check(rec.stopReasons == [.appQuit] && !rec.isRecording, "shutdown finalizes the active recording with reason app-quit", "\(rec.stopReasons)")
    check(q.pipeline.enqueued.isEmpty, "shutdown does not start pipeline work (next launch resumes it)")
    check(q.pipeline.shutdownCalls == 1, "pipeline child is stopped on quit")
    q.controller.shutdown(reason: .appQuit)
    check(rec.stopReasons == [.appQuit], "shutdown is idempotent")
    q.run(30, [meet])
    check(q.recorders.count == 1, "no recording starts after shutdown")

}

private func testPowerOff(_ base: URL) {
    section("will power off: finalize the recording, keep running (the logout can still be cancelled)")
    let meet = meetSignal()
    let h = Harness("poweroff", in: base)
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    h.run(20, [meet])
    guard let first = h.current else { check(false, "recording started"); return }
    h.controller.systemWillPowerOff()
    check(first.stopReasons == [.appQuit] && !first.isRecording, "willPowerOff finalizes the active recording with reason app-quit", "\(first.stopReasons)")
    check(h.pipeline.enqueued == [first.dir], "the finalized session is kept and queued")
    check(h.pipeline.shutdownCalls == 0, "willPowerOff does not stop the pipeline (the app is not quitting yet)")
    // Logout cancelled by another app: the call is still running and the controller must still work.
    h.run(until: { h.recorders.count >= 2 }, limit: 15, [meet])
    check(h.recorders.count == 2 && h.current?.isRecording == true, "after a cancelled logout the controller still detects and records the ongoing call", "recorders=\(h.recorders.count)")
    h.controller.systemWillPowerOff()                      // asked twice (e.g. a second logout attempt)
    check(h.recorders[1].stopReasons == [.appQuit], "a second power-off request finalizes the new recording as well")
    h.run(until: { h.recorders.count >= 3 }, limit: 15, [meet])
    check(h.recorders.count == 3, "and the controller keeps running after that too", "recorders=\(h.recorders.count)")
    // The real termination (SIGTERM / Quit) still shuts everything down.
    h.controller.shutdown(reason: .appQuit)
    check(h.current?.stopReasons == [.appQuit] && !(h.current?.isRecording ?? true) && h.pipeline.shutdownCalls == 1, "the real quit afterwards finalizes and stops the pipeline")
    h.run(30, [meet])
    check(h.recorders.count == 3, "no recording starts after the real shutdown")

    let idle = Harness("poweroff-idle", in: base)
    idle.controller.systemWillPowerOff()
    idle.run(until: { !idle.recorders.isEmpty }, limit: 15, [meet])
    check(idle.recorders.count == 1, "power-off request while idle changes nothing: detection still works")
}

private func testRecorderWarningsAndSelfStop(_ base: URL) {
    section("recorder warnings and self-terminated recorders")
    let h = Harness("warn", in: base)
    let meet = meetSignal()
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meet])
    h.run(12, [meet])
    guard let rec = h.current else { check(false, "recording started"); return }
    rec.onWarning?("remote track is silent"); h.sync()
    check(h.state.warning == "remote track is silent", "non-fatal warning is published for the menu", "\(h.state.warning ?? "nil")")
    rec.isRecording = false      // simulate a recorder that died by itself
    h.run(2, [meet])
    check(!h.pipeline.enqueued.isEmpty && h.pipeline.enqueued[0] == rec.dir, "a recorder that stopped by itself is finalized and processed", "\(h.pipeline.enqueued)")
    h.run(until: { h.recorders.count >= 2 }, limit: 15, [meet])
    check(h.recorders.count == 2, "recording resumes for the ongoing call")

    let z = Harness("zoom", in: base)
    z.run(until: { !z.recorders.isEmpty }, limit: 15, [zoomSignal()])
    check(z.current?.dir.lastPathComponent == "2026-10-07_1400_zoom", "zoom session id", z.current?.dir.lastPathComponent ?? "nil")
    z.run(5, [zoomSignal()])
    check(z.current?.metaUpdates.isEmpty == true, "no metadata updates when the signal carries none")

    let collide = Harness("collide", in: base)
    try? FileManager.default.createDirectory(at: collide.sessionsDir.appendingPathComponent("2026-10-07_1400_meet"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: collide.sessionsDir.appendingPathComponent("2026-10-07_1400_meet-2"), withIntermediateDirectories: true)
    collide.run(until: { !collide.recorders.isEmpty }, limit: 15, [meet])
    check(collide.current?.dir.lastPathComponent == "2026-10-07_1400_meet-3", "name collision gets suffix -3 (after -2)", collide.current?.dir.lastPathComponent ?? "nil")

    let quiet = Harness("noplatforms", in: base) { $0.enabledPlatforms = [] }
    quiet.run(30, [meet])
    check(quiet.recorders.isEmpty && quiet.detector.polls == 0, "ENABLED_PLATFORMS empty: detector never polled, nothing recorded")
    let control = Harness("noplatforms-control", in: base)
    control.run(1, [])
    check(quiet.state.autoDetectionOff && !control.state.autoDetectionOff,
          "ENABLED_PLATFORMS empty: state.autoDetectionOff is set (and clear when platforms are enabled)")
}

// MARK: - Crash recovery

/// A crashed recorder's file: canonical 44-byte header whose RIFF/data sizes are STALE (0), followed by `dataBytes`
/// of silent 16-bit mono PCM. `headerRate` is what the header claims (a corrupt file may claim nonsense).
private func writeCrashedWav(_ url: URL, dataBytes: Int, headerRate: UInt32) {
    var h = [UInt8]()
    func tag(_ t: String) { h.append(contentsOf: Array(t.utf8)) }
    func u32(_ v: UInt32) { for i in 0..<4 { h.append(UInt8((v >> UInt32(8 * i)) & 0xFF)) } }
    func u16(_ v: UInt16) { h.append(UInt8(v & 0xFF)); h.append(UInt8(v >> 8)) }
    tag("RIFF"); u32(36); tag("WAVE")
    tag("fmt "); u32(16); u16(1); u16(1)
    u32(headerRate); u32(headerRate &* 2); u16(2); u16(16)
    tag("data"); u32(0)
    var data = Data(h)
    data.append(Data(count: dataBytes))
    try? data.write(to: url)
}

private func writeWav(_ url: URL, seconds: Int, rate: Int) {
    writeCrashedWav(url, dataBytes: seconds * rate * 2, headerRate: UInt32(rate))
}

/// Independent reader of the two size fields (does not use the code under test).
private func wavHeaderSizes(_ url: URL) -> (riff: UInt32, data: UInt32, fileSize: Int)? {
    guard let d = try? Data(contentsOf: url), d.count >= 44 else { return nil }
    let b = [UInt8](d)
    func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
    return (u32(4), u32(40), d.count)
}

private func testCrashRecoveryScan(_ base: URL) {
    section("startup crash-recovery scan")
    let h = Harness("recovery", in: base)
    let fm = FileManager.default
    try? fm.createDirectory(at: h.sessionsDir, withIntermediateDirectories: true)

    func makeSession(_ id: String, endTime: String?, state: String? = nil, wavs: Bool = false, corrupt: Bool = false) {
        let dir = h.sessionsDir.appendingPathComponent(id, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if corrupt {
            try? "{not json".write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
            return
        }
        let end = endTime.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema":1,"session_id":"\(id)","platform":"meet","platform_label":"Google Meet","title_hint":"Weekly",
         "meeting_url":"https://meet.google.com/abc-defg-hij","app_bundle_id":"com.google.Chrome",
         "start_time":"2026-10-07T14:00:00+09:00","end_time":\(end),"end_reason":null,
         "tracks":{"remote":{"file":"remote.wav","sample_rate":16000,"channels":1,"start_offset_sec":0.0,"source":"global-tap"},
                   "mic":{"file":"mic.wav","sample_rate":16000,"channels":1,"start_offset_sec":0.5,"source":"mic"}},
         "app_version":"0.1.0"}
        """
        try? json.write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        if wavs {
            writeWav(dir.appendingPathComponent("remote.wav"), seconds: 10, rate: 16000)
            writeWav(dir.appendingPathComponent("mic.wav"), seconds: 12, rate: 16000)
        }
        if let st = state {
            try? "{\"schema\":1,\"stage\":\"\(st)\"}".write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        }
    }

    makeSession("2026-10-07_0950_meet", endTime: nil)                                               // crashed; corrupt header rate
    writeCrashedWav(h.sessionsDir.appendingPathComponent("2026-10-07_0950_meet/mic.wav"), dataBytes: 3200, headerRate: 3_000_000_000)
    makeSession("2026-10-07_1000_meet", endTime: nil, wavs: true)                                   // crashed while recording
    makeSession("2026-10-07_1100_zoom", endTime: "2026-10-07T11:30:00+09:00")                       // finished, never processed
    makeSession("2026-10-07_1200_meet", endTime: "2026-10-07T12:30:00+09:00", state: "transcribing") // interrupted pipeline
    makeSession("2026-10-07_1300_meet", endTime: "2026-10-07T13:30:00+09:00", state: "done")
    makeSession("2026-10-07_1400_meet", endTime: "2026-10-07T14:30:00+09:00", state: "failed")
    makeSession("2026-10-07_1500_junk", endTime: nil, corrupt: false)                               // replaced below: no session.json
    try? fm.removeItem(at: h.sessionsDir.appendingPathComponent("2026-10-07_1500_junk/session.json"))
    makeSession("2026-10-07_1700_meet", endTime: nil, corrupt: true)
    try? "stray".write(to: h.sessionsDir.appendingPathComponent("stray-file.txt"), atomically: true, encoding: .utf8)
    let finishedBefore = (try? Data(contentsOf: h.sessionsDir.appendingPathComponent("2026-10-07_1100_zoom/session.json")))
    // These crashed a while ago: their WAVs are older than the live-recording window (otherwise the scan would not touch them).
    for name in ["2026-10-07_0950_meet", "2026-10-07_1000_meet"] {
        setWavAge(h.sessionsDir.appendingPathComponent(name), seconds: 600, now: h.clock.now)
    }

    let enqueued = h.controller.recoverSessions().map { $0.lastPathComponent }
    check(enqueued == ["2026-10-07_0950_meet", "2026-10-07_1000_meet", "2026-10-07_1100_zoom", "2026-10-07_1200_meet"],
          "enqueues crashed, unprocessed and interrupted sessions in order; skips done/failed/junk/corrupt", "\(enqueued)")
    check(h.pipeline.enqueued.map { $0.lastPathComponent } == enqueued, "same sessions reached the pipeline")

    let fixed = ShellUtil.readJSON(h.sessionsDir.appendingPathComponent("2026-10-07_1000_meet/session.json"))
    check(fixed?["end_reason"] as? String == "crash-recovered", "end_reason crash-recovered", "\(String(describing: fixed?["end_reason"]))")
    if let endText = fixed?["end_time"] as? String, let end = ShellUtil.parseISO8601(endText),
       let start = ShellUtil.parseISO8601("2026-10-07T14:00:00+09:00") {
        // mic.wav: 0.5 s offset + (bytes-44)/(2*16000) = 12 s -> 12.5 s (end_time has whole-second precision); remote: 10 s
        let delta = end.timeIntervalSince(start)
        check(delta >= 12 && delta <= 13, "end_time = start + longest track from WAV size (about 12.5 s)", "\(delta)")
    } else {
        check(false, "end_time written as ISO8601", "\(String(describing: fixed?["end_time"]))")
    }
    check(fixed?["platform"] as? String == "meet" && fixed?["title_hint"] as? String == "Weekly" && (fixed?["tracks"] as? [String: Any])?.count == 2,
          "other session.json fields preserved")
    check(!fm.fileExists(atPath: h.sessionsDir.appendingPathComponent("2026-10-07_1000_meet/session.json.tmp").path), "atomic rewrite leaves no temp file")

    // WAV headers of the crashed session are repaired (a crashed header says 0 bytes; afconvert / QuickTime would see nothing).
    for (name, seconds) in [("mic.wav", 12), ("remote.wav", 10)] {
        let sizes = wavHeaderSizes(h.sessionsDir.appendingPathComponent("2026-10-07_1000_meet/\(name)"))
        let dataBytes = seconds * 16000 * 2
        check(sizes?.data == UInt32(dataBytes) && sizes?.riff == UInt32(dataBytes + 36) && sizes?.fileSize == dataBytes + 44,
              "crash recovery repairs the WAV header of \(name) (data \(dataBytes) B)", "\(String(describing: sizes))")
    }
    check(logCount("repaired the WAV header of 2026-10-07_1000_meet/mic.wav") == 1, "the repair is logged")
    // A corrupt header (sample rate field 3e9) must neither crash the app nor be rewritten; the session is still recovered.
    let bad = wavHeaderSizes(h.sessionsDir.appendingPathComponent("2026-10-07_0950_meet/mic.wav"))
    check(bad?.data == 0 && bad?.fileSize == 44 + 3200, "a WAV with an implausible sample rate is left untouched (no trap)", "\(String(describing: bad))")
    check(logCount("2026-10-07_0950_meet/mic.wav has no plausible WAV sample rate") == 1, "...and says so in the log")
    let badMeta = ShellUtil.readJSON(h.sessionsDir.appendingPathComponent("2026-10-07_0950_meet/session.json"))
    check(badMeta?["end_reason"] as? String == "crash-recovered", "...while its session.json is still closed as crash-recovered")
    // Idempotent: a second scan does not touch the repaired file again.
    let micURL = h.sessionsDir.appendingPathComponent("2026-10-07_1000_meet/mic.wav")
    let micBefore = try? Data(contentsOf: micURL)
    _ = h.controller.recoverSessions()
    check(micBefore != nil && micBefore == (try? Data(contentsOf: micURL)), "a second scan leaves the repaired WAV as it is")
    check(SessionController.wavHeaderMatchesFileSize(micURL) && !SessionController.wavHeaderMatchesFileSize(h.sessionsDir.appendingPathComponent("2026-10-07_0950_meet/mic.wav")),
          "wavHeaderMatchesFileSize tells repaired from stale")
    let finishedAfter = (try? Data(contentsOf: h.sessionsDir.appendingPathComponent("2026-10-07_1100_zoom/session.json")))
    check(finishedBefore != nil && finishedBefore == finishedAfter, "finished sessions are not rewritten")
    check(fm.fileExists(atPath: h.sessionsDir.appendingPathComponent("2026-10-07_1700_meet/session.json").path), "unreadable session.json is left in place (audio kept)")
}

/// Sets the modification time of every WAV in `dir` to `seconds` before `now` (the controller's virtual clock).
private func setWavAge(_ dir: URL, seconds: TimeInterval, now: Date) {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.lowercased().hasSuffix(".wav") {
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-seconds)], ofItemAtPath: dir.appendingPathComponent(name).path)
    }
}

// MARK: - Startup scan rules (tombstones, retryable failures, live recordings)

private func testStartupScanRules(_ base: URL) {
    section("startup scan: tombstones and reserved folders are silent, retryable failures are retried once, a live recording is never touched")
    let fm = FileManager.default

    // The pure decision.
    func decide(_ json: String?) -> SessionController.ScanDecision {
        let obj = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return SessionController.scanDecision(state: obj)
    }
    let table: [(String?, SessionController.ScanDecision, String)] = [
        (nil, .enqueue, "no state.json"),
        ("{\"stage\":\"transcribing\"}", .enqueue, "interrupted run"),
        ("{\"stage\":\"queued\"}", .enqueue, "queued"),
        ("{\"stage\":\"done\"}", .skip, "done"),
        ("{\"stage\":\"failed\"}", .skip, "failed, nothing else said"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\"}", .retryFailed(kind: "archive_unavailable"), "archive unavailable, retryable"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"asr_failed\"}", .retryFailed(kind: "asr_failed"), "asr failed, retryable"),
        ("{\"stage\":\"failed\",\"retryable\":false,\"error_kind\":\"asr_failed\"}", .skip, "asr failed but NOT retryable"),
        ("{\"stage\":\"failed\",\"retryable\":false,\"error_kind\":\"archive_unavailable\"}", .skip, "archive unavailable but NOT retryable"),
        ("{\"stage\":\"failed\",\"retryable\":null,\"error_kind\":\"asr_failed\"}", .skip, "retryable null"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"audio_failed\"}", .skip, "audio failed (not a kind we retry)"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"usage_limit\"}", .skip, "note failure (mcap reprocess --pending, not the app)"),
        ("{\"stage\":\"failed\",\"retryable\":true}", .skip, "retryable but no error_kind"),
        ("{\"stage\":\"failed\",\"retryable\":\"yes\",\"error_kind\":\"asr_failed\"}", .skip, "retryable is not a boolean"),
        ("{\"retryable\":true,\"error_kind\":\"asr_failed\"}", .enqueue, "no stage at all"),
    ]
    for (json, expected, name) in table {
        check(decide(json) == expected, "scanDecision: \(name) -> \(expected)", "\(decide(json))")
    }

    let h = Harness("scanrules", in: base)
    try? fm.createDirectory(at: h.sessionsDir, withIntermediateDirectories: true)
    func folder(_ name: String) -> URL {
        let d = h.sessionsDir.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func put(_ text: String, _ url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }
    func session(_ name: String, state: String?, end: String? = "2026-10-07T10:30:00+09:00") {
        let d = folder(name)
        let endJSON = end.map { "\"\($0)\"" } ?? "null"
        put("""
            {"schema":1,"session_id":"\(name)","platform":"meet","start_time":"2026-10-07T10:00:00+09:00","end_time":\(endJSON),"end_reason":null,
             "tracks":{"remote":{"file":"remote.wav","sample_rate":16000,"channels":1,"start_offset_sec":0.0,"source":"global-tap"}}}
            """, d.appendingPathComponent("session.json"))
        if let st = state { put(st, d.appendingPathComponent("state.json")) }
    }
    let kinds = ["archive_unavailable", "asr_failed"]

    // (b) what the pipeline leaves in staging after publish / discard, and its reserved folders: silent.
    put("{\"stage\":\"done\",\"title\":\"Weekly\",\"final_dir\":\"/x/y\"}", folder("2026-10-07_0900_meet").appendingPathComponent("state.json"))
    put("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"usage_limit\",\"final_dir\":\"/x/z\",\"error\":\"Note failed: usage limit\"}",
        folder("2026-10-07_0910_meet").appendingPathComponent("state.json"))
    put("{\"stage\":\"done\",\"discarded\":true}", folder("2026-10-07_0915_meet").appendingPathComponent("state.json"))
    let parked = folder("_discarded/2026-10-07_0800_meet")
    put("{\"schema\":1,\"end_time\":null,\"start_time\":\"2026-10-07T08:00:00+09:00\",\"tracks\":{}}", parked.appendingPathComponent("session.json"))
    put("{\"stage\":\"done\",\"discarded\":true}", parked.appendingPathComponent("state.json"))
    put("stray", folder("2026-10-07_0920_junk").appendingPathComponent("notes.txt"))

    // (a) failed sessions: only retryable ones of a retryable kind
    session("2026-10-07_1000_meet", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"\(kinds[0])\",\"error\":\"archive unavailable\"}")
    session("2026-10-07_1010_meet", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"\(kinds[1])\"}")
    session("2026-10-07_1020_meet", state: "{\"stage\":\"failed\",\"retryable\":false,\"error_kind\":\"asr_failed\"}")
    session("2026-10-07_1030_meet", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"audio_failed\"}")
    session("2026-10-07_1040_meet", state: "{\"stage\":\"failed\",\"retryable\":true}")
    session("2026-10-07_1050_meet", state: "{\"stage\":\"done\"}")
    session("2026-10-07_1060_meet", state: "{\"stage\":\"transcribing\"}")

    let silentBefore = ["2026-10-07_0900_meet", "2026-10-07_0910_meet", "2026-10-07_0915_meet", "_discarded", "2026-10-07_0800_meet"]
        .map { logCount("startup scan: \($0) ") }
    let junkBefore = logCount("startup scan: 2026-10-07_0920_junk has no session.json")
    let first = h.controller.recoverSessions().map { $0.lastPathComponent }
    check(first == ["2026-10-07_1000_meet", "2026-10-07_1010_meet", "2026-10-07_1060_meet"],
          "scan enqueues the retryable failures (archive_unavailable, asr_failed) and the interrupted run; never non-retryable / other kinds / done", "\(first)")
    let silentAfter = ["2026-10-07_0900_meet", "2026-10-07_0910_meet", "2026-10-07_0915_meet", "_discarded", "2026-10-07_0800_meet"]
        .map { logCount("startup scan: \($0) ") }
    check(silentBefore == silentAfter, "tombstones (state.json only: done, discarded, note-failed) and sessions/_discarded/ are ignored silently: no log line", "\(silentBefore) -> \(silentAfter)")
    check(logCount("startup scan: 2026-10-07_0920_junk has no session.json") == junkBefore + 1, "a folder that is neither a session nor a tombstone is still mentioned in the log")
    check(h.pipeline.enqueued.map { $0.lastPathComponent } == first, "same sessions reached the pipeline")
    check(logCount("2026-10-07_1000_meet failed earlier (archive_unavailable, retryable); trying it once more") == 1, "a retried failure says why in the log")
    // once per app launch: a second scan in the same launch does not retry them again (the interrupted run is still re-enqueued, the launcher drops duplicates)
    let second = h.controller.recoverSessions().map { $0.lastPathComponent }
    check(second == ["2026-10-07_1060_meet"], "a second scan in the same launch does not retry the failed sessions again", "\(second)")
    // a new launch (new controller) retries them again, once
    let relaunch = Harness("scanrules-relaunch", in: base)
    try? fm.createDirectory(at: relaunch.sessionsDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: relaunch.sessionsDir)
    try? fm.copyItem(at: h.sessionsDir, to: relaunch.sessionsDir)
    let third = relaunch.controller.recoverSessions().map { $0.lastPathComponent }
    check(third == first, "the next app launch retries them once more", "\(third)")

    // (c) a session that may be the live recording
    let live = Harness("scanlive", in: base)
    try? fm.createDirectory(at: live.sessionsDir, withIntermediateDirectories: true)
    func liveSession(_ name: String, wavAge: TimeInterval?) -> URL {
        let d = live.sessionsDir.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        let text = """
            {"schema":1,"session_id":"\(name)","platform":"meet","start_time":"2026-10-07T14:00:00+09:00","end_time":null,"end_reason":null,
             "tracks":{"remote":{"file":"remote.wav","sample_rate":16000,"channels":1,"start_offset_sec":0.0,"source":"global-tap"}}}
            """
        try? text.write(to: d.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        if let age = wavAge {
            writeCrashedWav(d.appendingPathComponent("remote.wav"), dataBytes: 16000 * 2 * 5, headerRate: 16000)
            setWavAge(d, seconds: age, now: live.clock.now)
        }
        return d
    }
    let fresh = liveSession("2026-10-07_1400_meet", wavAge: 30)
    let old = liveSession("2026-10-07_1300_meet", wavAge: 600)
    let silent = liveSession("2026-10-07_1200_meet", wavAge: nil)
    let freshJSON = try? Data(contentsOf: fresh.appendingPathComponent("session.json"))
    let freshWAV = try? Data(contentsOf: fresh.appendingPathComponent("remote.wav"))
    let liveFirst = live.controller.recoverSessions().map { $0.lastPathComponent }
    check(liveFirst == ["2026-10-07_1200_meet", "2026-10-07_1300_meet"], "end_time null + WAV older than 2 min (or no WAV at all) is a crash: recovered and enqueued; the fresh one is not", "\(liveFirst)")
    check(freshJSON == (try? Data(contentsOf: fresh.appendingPathComponent("session.json"))) && freshWAV == (try? Data(contentsOf: fresh.appendingPathComponent("remote.wav"))),
          "end_time null + WAV written 30 s ago: session.json and WAV are not touched at all (no end_time, no header repair)")
    check(!SessionController.wavHeaderMatchesFileSize(fresh.appendingPathComponent("remote.wav")), "... its (stale) header is left as it is")
    check(logCount("2026-10-07_1400_meet has no end_time and its audio was written 30 s ago: it may be a live recording") == 1, "the log says why the session was left alone")
    check(ShellUtil.readJSON(old.appendingPathComponent("session.json"))?["end_reason"] as? String == "crash-recovered", "the old crashed session is closed as crash-recovered")
    check(ShellUtil.readJSON(silent.appendingPathComponent("session.json"))?["end_reason"] as? String == "crash-recovered", "a session without any WAV is not protected (nothing to lose)")
    check(live.rescans.count == 1 && live.rescans[0].delay >= 90 && live.rescans[0].delay <= 100,
          "a rescan is scheduled for when the 2 minute window is over (about 93 s: crash + launchd restart is the usual case)", "\(live.rescans.map { $0.delay })")
    // time passes: the "live" session turns out to be a crash -> the rescan recovers exactly that session
    setWavAge(fresh, seconds: 200, now: live.clock.now)
    let enqueuedBefore = live.pipeline.enqueued.count
    live.rescans[0].work()
    live.sync()
    check(live.pipeline.enqueued.map { $0.lastPathComponent }.suffix(live.pipeline.enqueued.count - enqueuedBefore) == ["2026-10-07_1400_meet"],
          "the rescan recovers and enqueues only the session it had skipped", "\(live.pipeline.enqueued.map { $0.lastPathComponent })")
    check(ShellUtil.readJSON(fresh.appendingPathComponent("session.json"))?["end_reason"] as? String == "crash-recovered" && SessionController.wavHeaderMatchesFileSize(fresh.appendingPathComponent("remote.wav")),
          "... closed as crash-recovered and its WAV header repaired")
    // a session that keeps being written is re-checked a bounded number of times, then left to the next launch
    let busy = Harness("scanbusy", in: base)
    try? fm.createDirectory(at: busy.sessionsDir, withIntermediateDirectories: true)
    let busyDir = busy.sessionsDir.appendingPathComponent("2026-10-07_1500_meet", isDirectory: true)
    try? fm.createDirectory(at: busyDir, withIntermediateDirectories: true)
    try? "{\"schema\":1,\"start_time\":\"2026-10-07T14:00:00+09:00\",\"end_time\":null,\"tracks\":{}}".write(to: busyDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    writeCrashedWav(busyDir.appendingPathComponent("remote.wav"), dataBytes: 3200, headerRate: 16000)
    var runs = 0
    setWavAge(busyDir, seconds: 1, now: busy.clock.now)
    _ = busy.controller.recoverSessions()
    while runs < 10, runs < busy.rescans.count {
        setWavAge(busyDir, seconds: 1, now: busy.clock.now)                    // still being written
        busy.rescans[runs].work()
        runs += 1
    }
    check(busy.rescans.count == SessionController.maxLiveRescans && busy.pipeline.enqueued.isEmpty && ShellUtil.readJSON(busyDir.appendingPathComponent("session.json"))?["end_reason"] == nil,
          "a session that stays live is re-checked \(SessionController.maxLiveRescans) times at most and never touched", "rescans=\(busy.rescans.count) enqueued=\(busy.pipeline.enqueued.count)")

    // the controller's own recording is never touched by a scan while it records
    let own = Harness("scanown", in: base)
    own.controller.startRecordingNow(); own.sync()
    let ownDir = own.current?.dir
    let ownJSON = ownDir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("session.json")) }
    let ownScan = own.controller.recoverSessions()
    check(ownDir != nil && ownScan.isEmpty && ownJSON == ownDir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("session.json")) } && own.pipeline.enqueued.isEmpty,
          "a scan while the controller is recording leaves the active session alone")
}

// MARK: - Reprocess Last Meeting while recording

private func testReprocessWhileRecording(_ base: URL) {
    section("Reprocess Last Meeting is refused while a recording is active (controller, menu item, launcher)")
    let h = Harness("reproc-rec", in: base)
    check(!h.controller.isRecordingActive, "idle: isRecordingActive is false")
    h.controller.reprocessLast(); h.sync()
    check(h.pipeline.reprocessCalls == 1, "idle: Reprocess Last Meeting reaches the pipeline")

    h.run(until: { !h.recorders.isEmpty }, limit: 15, [meetSignal()])
    check(h.controller.isRecordingActive, "recording: isRecordingActive is true (readable from any thread)")
    let stateBefore = h.state
    h.controller.reprocessLast(); h.sync()
    check(h.pipeline.reprocessCalls == 1, "recording: the controller refuses (the pipeline is not asked)", "calls=\(h.pipeline.reprocessCalls)")
    check(h.state == stateBefore, "recording: the status shown does not change")
    check(logCount("Reprocess Last Meeting refused: a recording is active") >= 1, "the refusal is logged")
    h.controller.stopRecordingNow(); h.sync()
    check(!h.controller.isRecordingActive, "after the stop: isRecordingActive is false again")
    h.controller.reprocessLast(); h.sync()
    check(h.pipeline.reprocessCalls == 2, "after the recording: Reprocess Last Meeting works again")
    h.controller.startRecordingNow(); h.sync()
    check(h.controller.isRecordingActive, "a manual recording counts as well")
    h.controller.shutdown(reason: .appQuit)
    check(!h.controller.isRecordingActive, "shutdown clears it")

    // The menu item: disabled while recording, with the reason in title and tooltip.
    let now = Date(timeIntervalSince1970: 1_000_000)
    var rec = ControllerState()
    rec.status = .recording(.meet, since: now)
    let r = StatusMenuController.reprocessItemState(for: rec)
    check(!r.enabled && r.title.contains("not while recording") && (r.tooltip ?? "").contains("recording is active"), "menu: disabled while recording, and it says why in the title and the tooltip", "\(r)")
    var manual = rec; manual.manualRecording = true
    check(!StatusMenuController.reprocessItemState(for: manual).enabled, "menu: disabled during a manual recording too")
    var enabledCount = 0
    for status: SessionStatus in [.idle, .candidate(.meet), .processing("Transcribing"), .done("Weekly"), .error("boom")] {
        var st = ControllerState(); st.status = status
        let item = StatusMenuController.reprocessItemState(for: st)
        if item.enabled && item.title == "Reprocess Last Meeting" && item.tooltip == nil { enabledCount += 1 }
    }
    check(enabledCount == 5, "menu: enabled with its normal title in every other state (idle, candidate, processing, done, error)", "\(enabledCount) of 5")
    var paused = ControllerState(); paused.paused = true
    check(StatusMenuController.reprocessItemState(for: paused).enabled, "menu: enabled while auto recording is paused (nothing is recording)")

    // PipelineLauncher: reprocessLast refuses while recording; a queued reprocess is dropped if a recording started meanwhile.
    let fm = FileManager.default
    let root = base.appendingPathComponent("launcher-rec", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try? fm.createDirectory(at: project.appendingPathComponent("pipeline/mcap"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: support.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let python = bin.appendingPathComponent("fakepython")
    try? fakePythonScript.write(to: python, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    var config = AppConfig.defaults()
    config.supportDir = support
    config.projectDir = project
    config.pythonBin = python
    config.archiveDir = root.appendingPathComponent("archive", isDirectory: true)
    let sessionDir = support.appendingPathComponent("sessions/2026-10-07_1400_ok2", isDirectory: true)
    try? fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    func calls() -> String { (try? String(contentsOf: bin.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }

    let launcher = PipelineLauncher(config: config, logDir: logs, statePollInterval: 0.1, stallTimeout: 600)
    let events = EventLog()
    launcher.onEvent = { events.add($0) }
    let recording = Locked(true)
    launcher.recordingActive = { recording.value }
    launcher.reprocessLast()
    Thread.sleep(forTimeInterval: 0.6)
    check(events.strings == ["failed:reprocess-last:\(PipelineLauncher.reprocessBlockedMessage)"] && !calls().contains("reprocess"),
          "launcher: reprocessLast while recording starts nothing and reports why (one failed event, no progress)", events.strings.joined(separator: " | "))
    recording.value = false
    launcher.reprocessLast()
    check(waitUntil(15) { events.strings.contains { $0.hasPrefix("finished:reprocess-last") } } && calls().contains("ARGS: -m mcap reprocess --last"),
          "launcher: the same call works once the recording is over", events.strings.joined(separator: " | "))

    // queued behind a running job, then a recording starts: dropped, not launched
    let launcher2 = PipelineLauncher(config: config, logDir: logs, statePollInterval: 0.1, stallTimeout: 600)
    let events2 = EventLog()
    launcher2.onEvent = { events2.add($0) }
    let recording2 = Locked(false)
    launcher2.recordingActive = { recording2.value }
    let callsBefore = calls().components(separatedBy: "ARGS: -m mcap reprocess --last").count
    launcher2.enqueue(sessionDir)                              // about 1.2 s
    _ = waitUntil(5) { events2.strings.contains { $0.hasPrefix("progress:") } }
    launcher2.reprocessLast()                                  // accepted: nothing is recording yet, queued behind the running job
    Thread.sleep(forTimeInterval: 0.25)                        // (let the launcher queue take it before the flag flips)
    recording2.value = true                                    // a recording starts while the job runs
    _ = waitUntil(15) { events2.strings.contains { $0.hasPrefix("finished:2026-10-07_1400_ok2") } }
    Thread.sleep(forTimeInterval: 0.8)
    check(calls().components(separatedBy: "ARGS: -m mcap reprocess --last").count == callsBefore
          && events2.strings.filter { $0.hasPrefix("failed:reprocess-last:") }.count == 1
          && !events2.strings.contains { $0.hasPrefix("progress:reprocess-last") || $0.hasPrefix("finished:reprocess-last") },
          "launcher: a reprocess that was queued before the recording started is dropped, not launched, and the drop is reported once", events2.strings.joined(separator: " | "))
    check(logCount("queued reprocess of the last meeting dropped: a recording is active") >= 1 && logCount("reprocess of the last meeting refused: a recording is active") >= 1,
          "launcher: both refusals are logged")

    // The race the two checks leave open: the controller sees no recording and shows "Queued: reprocess last meeting", then the
    // launcher (a moment later, on its own queue) sees one and refuses. The refusal has to reach the menu, otherwise
    // "Processing: Queued: reprocess last meeting" would stay on screen until some later job. The launcher's closure says
    // "recording" while the controller itself has none, which is exactly that window.
    do {
        let clock3 = VirtualClock(Date())
        let launcher3 = PipelineLauncher(config: config, logDir: logs, statePollInterval: 0.1, stallTimeout: 600)
        let seen = Locked<[SessionStatus]>([])
        let c3 = SessionController(config: config, detector: FakeDetector(clock: clock3),
                                   recorderFactory: { dir, signal in FakeRecorder(dir: dir, signal: signal, clock: clock3) },
                                   pipeline: launcher3, clock: { clock3.now }, freeDiskGB: { 100 }, deliver: { $0() },
                                   scheduleRescan: { _, _ in }, zoomTier: .defaults)
        c3.onState = { seen.value = seen.value + [$0.status] }
        launcher3.recordingActive = { true }
        c3.reprocessLast()
        let reported = waitUntil(5) {
            if case .error(let text)? = seen.value.last { return text.contains("recording is active") }
            return false
        }
        check(reported, "race (controller accepted, launcher refused): the menu gets the reason, not a stuck 'Queued: reprocess last meeting'",
              "\(seen.value)")
        check(!(seen.value.last == .processing("Queued: reprocess last meeting")), "... and the last status is not the optimistic 'Queued' text")
        c3.shutdown(reason: .appQuit, timeout: 3)
    }
}

/// Small thread-safe box for test flags read from another queue.
private final class Locked<T> {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// MARK: - PipelineLauncher against a fake python

private final class EventLog {
    private let lock = NSLock()
    private var items: [PipelineEvent] = []
    func add(_ e: PipelineEvent) { lock.lock(); items.append(e); lock.unlock() }
    var all: [PipelineEvent] { lock.lock(); defer { lock.unlock() }; return items }
    var strings: [String] {
        return all.map { e in
            switch e {
            case .progress(let s, let t): return "progress:\(s):\(t)"
            case .finished(let s, let title, _, let d): return "finished:\(s):\(title ?? "-"):\(d)"
            case .failed(let s, let m): return "failed:\(s):\(m)"
            case .nothingToReport(let s): return "nothing:\(s)"
            case .blocked(let s, let reason): return "blocked:\(s):\(reason.key)"
            }
        }
    }
}

private func realPath(_ url: URL) -> String {
    var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    return realpath(url.path, &buffer) != nil ? String(cString: buffer) : url.path
}

private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private let fakePythonScript = #"""
#!/bin/sh
# Fake "python" for selftest-session. Usage: fakepython -m mcap process <dir> | -m mcap reprocess --last
D="$(cd "$(dirname "$0")" && pwd)"
{ echo "ARGS: $*"; echo "CWD: $(pwd -P)"; env | sort | sed 's/^/ENV /'; echo "-----"; } >> "$D/calls.log"
echo "hello from fakepython"
if [ "$3" = "reprocess" ]; then
  if [ "$4" = "--pending" ]; then
    MODE="$(cat "$D/pending-mode" 2>/dev/null || echo none)"
    case "$MODE" in
      ok) ARCH="$D/../archive/2026-10/2026-10-06_0900_Retried-One"; mkdir -p "$ARCH"
          printf '# Retried One Title\n\n## Executive Summary\n' > "$ARCH/meeting-note.md"
          echo "retrying /x/y"; echo "  DONE: $ARCH"; echo "  DONE: None"; echo "DONE: pending: 1 session(s) retried, 1 ok, 0 failed, 0 busy"; exit 0 ;;
      fail) echo "retrying /x/y"; echo "  FAILED: archive unavailable: Drive is not mounted"; echo "retrying /x/z"; echo "  FAILED: Note failed: overloaded"
            echo "FAILED: pending: 2 session(s) retried, 0 ok, 2 failed, 0 busy"; exit 1 ;;
      hang) exec sleep 60 ;;
      *) echo "nothing pending: no failed session with a retryable error"; exit 0 ;;
    esac
  fi
  echo "reprocessing"; exit 0
fi
S="$4"
NAME="$(basename "$S")"
w() { # stage detail title final_dir error
  printf '{"schema":1,"stage":"%s","stage_detail":"%s","error":%s,"updated":"2026-10-07T15:10:02+09:00","done":{},"title":%s,"final_dir":%s}\n' \
    "$1" "$2" "${5:-null}" "${3:-null}" "${4:-null}" > "$S/state.json.tmp" && mv "$S/state.json.tmp" "$S/state.json"
}
case "$NAME" in
  *hangonce*) if [ ! -e "$S/.ran-once" ]; then touch "$S/.ran-once"; exec sleep 60; fi ;;
  *hang*) exec sleep 60 ;;
  *busy*) echo "BUSY: locked by another mcap process" >&2; exit 75 ;;
  *crash*) echo "Traceback (most recent call last):" >&2; echo "ValueError: bad thing" >&2; exit 3 ;;
  *fail*) w failed "" null null '"boom"'; exit 1 ;;
  *discard*) printf '{"schema":1,"stage":"done","discarded":true}\n' > "$S/state.json"; exit 0 ;;
  *moved*) # publish moved the whole folder into the archive and took state.json with it
    ARCH="$D/../archive/2026-10/2026-10-07_2100_Moved-Meeting"; mkdir -p "$ARCH"
    printf '# Moved Meeting Title\n\n## Executive Summary\n' > "$ARCH/meeting-note.md"; rm -rf "$S"; exit 0 ;;
esac
w audio ""; sleep 0.4
w transcribing "remote 12/48"; sleep 0.4
w noting ""; sleep 0.4
mkdir -p "$D/final"
w done "" '"Weekly Sync"' "\"$D/final\""
exit 0
"""#

private func testPipelineLauncher(_ base: URL) {
    section("PipelineLauncher with a fake python")
    let fm = FileManager.default
    let root = base.appendingPathComponent("launcher", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try? fm.createDirectory(at: project.appendingPathComponent("pipeline/mcap"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: support.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    let python = bin.appendingPathComponent("fakepython")
    try? fakePythonScript.write(to: python, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    var config = AppConfig.defaults()
    config.supportDir = support
    config.projectDir = project
    config.pythonBin = python
    config.archiveDir = archive

    func session(_ name: String) -> URL {
        let d = support.appendingPathComponent("sessions/\(name)", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    setenv("ANTHROPIC_API_KEY", "selftest-secret-value", 1)
    setenv("CLAUDE_CODE_OAUTH_TOKEN", "selftest-oauth", 1)
    defer { unsetenv("ANTHROPIC_API_KEY"); unsetenv("CLAUDE_CODE_OAUTH_TOKEN") }

    let launcher = PipelineLauncher(config: config, logDir: logs, statePollInterval: 0.1, stallTimeout: 600)
    let events = EventLog()
    launcher.onEvent = { events.add($0) }

    let ok1 = session("2026-10-07_1400_ok1")
    try? "{\"platform\":\"zoom\",\"start_time\":\"2026-10-07T14:00:12+09:00\",\"end_time\":\"2026-10-07T14:32:24+09:00\"}".write(to: ok1.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    let fail1 = session("2026-10-07_1500_fail1")
    let crash1 = session("2026-10-07_1600_crash1")
    let discard1 = session("2026-10-07_1700_discard1")
    let moved1 = session("2026-10-07_2100_moved1")
    launcher.enqueue(ok1)
    launcher.enqueue(ok1)                 // duplicate while queued/running: ignored
    launcher.enqueue(fail1)
    launcher.enqueue(crash1)
    launcher.enqueue(discard1)
    launcher.enqueue(moved1)
    launcher.reprocessLast()

    let finishedAll = waitUntil(30) { events.strings.contains { $0.hasPrefix("finished:reprocess-last") } }
    check(finishedAll, "all queued jobs ran", events.strings.joined(separator: " | "))
    let ev = events.strings

    func index(_ prefix: String) -> Int? { ev.firstIndex { $0.hasPrefix(prefix) } }
    let texts = ev.filter { $0.hasPrefix("progress:2026-10-07_1400_ok1:") }.map { String($0.split(separator: ":", maxSplits: 2).last ?? "") }
    check(texts.first == "Starting", "first progress is 'Starting'", "\(texts)")
    check(texts.contains("Transcribing remote 12/48"), "state.json stage text 'Transcribing remote 12/48'", "\(texts)")
    check(texts.contains("Creating note") && texts.contains("Preparing audio"), "other stage texts mapped", "\(texts)")
    check(ev.contains("finished:2026-10-07_1400_ok1:Weekly Sync:false"), "finished event carries the title", ev.joined(separator: " | "))
    let finishedOK = events.all.compactMap { e -> URL? in if case .finished(let s, _, let d, _) = e, s.hasSuffix("ok1") { return d }; return nil }.first
    check(finishedOK?.lastPathComponent == "final" && finishedOK.map { fm.fileExists(atPath: $0.path) } == true, "finished event carries final_dir", "\(String(describing: finishedOK))")
    check(ev.contains("failed:2026-10-07_1500_fail1:boom"), "state.json error used as failure message", ev.joined(separator: " | "))
    // what the launcher read for the notification texts (before it reported the end), no file I/O needed by the controller
    let okOutcome = launcher.outcome(forSession: "2026-10-07_1400_ok1")
    check(okOutcome?.folder?.lastPathComponent == "final" && okOutcome?.platform == .zoom && okOutcome?.durationSeconds == 1932 && okOutcome?.errorKind == nil,
          "outcome of a finished session: folder = final_dir, platform and length from session.json", "\(String(describing: okOutcome))")
    let failOutcome = launcher.outcome(forSession: "2026-10-07_1500_fail1")
    check(failOutcome?.folder.map { ShellUtil.sameFile($0, fail1) } == true && failOutcome?.logFile?.lastPathComponent == "pipeline-2026-10-07_1500_fail1.log",
          "outcome of a failed session: the staging folder and the job's pipeline log", "\(String(describing: failOutcome))")
    check(launcher.outcome(forSession: "no-such-session") == nil, "no outcome for a session it never ran")
    check(ev.contains { $0.hasPrefix("failed:2026-10-07_1600_crash1:") && $0.contains("ValueError: bad thing") }, "crash without state.json: last log line used as message", ev.joined(separator: " | "))
    let movedFinal = events.all.compactMap { e -> URL? in if case .finished(let s, _, let d, _) = e, s.hasSuffix("moved1") { return d }; return nil }.first
    check(ev.contains("finished:2026-10-07_2100_moved1:Moved Meeting Title:false") && movedFinal?.lastPathComponent == "2026-10-07_2100_Moved-Meeting",
          "folder moved to the archive (no state.json left): published folder and note title are found", ev.joined(separator: " | "))
    check(ev.contains("finished:2026-10-07_1700_discard1:-:true"), "discarded flag passed through", ev.joined(separator: " | "))
    if let a = index("finished:2026-10-07_1400_ok1"), let b = index("progress:2026-10-07_1500_fail1") {
        check(a < b, "jobs run one at a time, in order")
    } else {
        check(false, "serial ordering observable", ev.joined(separator: " | "))
    }

    let calls = (try? String(contentsOf: bin.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
    check(calls.components(separatedBy: "ARGS: -m mcap process \(ok1.path)").count == 2, "duplicate enqueue ran only once")
    check(calls.contains("ARGS: -m mcap reprocess --last"), "reprocessLast runs `mcap reprocess --last`")
    // `pwd -P` prints the physical path (/private/var/...); Foundation's resolvingSymlinksInPath() hides /private.
    let pipelineDir = realPath(project.appendingPathComponent("pipeline"))
    check(calls.contains("CWD: \(pipelineDir)"), "cwd is PROJECT_DIR/pipeline", pipelineDir)
    check(!calls.contains("ENV ANTHROPIC") && !calls.contains("ENV CLAUDE") && !calls.contains("selftest-secret-value"), "ANTHROPIC_*/CLAUDE_* never reach the child")
    check(calls.contains("ENV HOME=\(NSHomeDirectory())") && calls.contains("ENV LANG=en_US.UTF-8") && calls.contains("ENV PYTHONUNBUFFERED=1")
            && calls.contains("ENV HF_HUB_DISABLE_TELEMETRY=1") && calls.contains("ENV USER=\(NSUserName())"), "minimal environment present")
    check(calls.contains("/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"), "PATH includes ~/.local/bin and Homebrew")
    let logText = (try? String(contentsOf: logs.appendingPathComponent("pipeline-2026-10-07_1400_ok1.log"), encoding: .utf8)) ?? ""
    check(logText.contains("hello from fakepython"), "stdout appended to LOG_DIR/pipeline-<session>.log")

    check(launcher.lastMeetingFolder()?.lastPathComponent == "2026-10-07_2100_Moved-Meeting", "lastMeetingFolder() = folder of the last finished job",
          "\(String(describing: launcher.lastMeetingFolder()))")

    // lastMeetingFolder() without in-memory knowledge: newest archive folder, else the archive dir.
    var coldConfig = config
    coldConfig.supportDir = root.appendingPathComponent("support-cold", isDirectory: true)
    coldConfig.archiveDir = root.appendingPathComponent("archive-cold", isDirectory: true)
    let cold = PipelineLauncher(config: coldConfig, logDir: logs)
    check(cold.lastMeetingFolder() == nil, "nothing anywhere: no folder", "\(String(describing: cold.lastMeetingFolder()))")
    try? fm.createDirectory(at: coldConfig.sessionsDir, withIntermediateDirectories: true)
    check(cold.lastMeetingFolder()?.path == coldConfig.sessionsDir.path, "no archive at all: falls back to staging", "\(String(describing: cold.lastMeetingFolder()))")
    let coldArchive = coldConfig.archiveDir
    try? fm.createDirectory(at: coldArchive, withIntermediateDirectories: true)
    check(cold.lastMeetingFolder()?.path == coldArchive.path, "empty archive: falls back to ARCHIVE_DIR", "\(String(describing: cold.lastMeetingFolder()))")
    // a done state.json in staging that names an existing final_dir wins over the archive scan
    let stagedDone = coldConfig.sessionsDir.appendingPathComponent("2026-10-07_1000_meet", isDirectory: true)
    try? fm.createDirectory(at: stagedDone, withIntermediateDirectories: true)
    let finalDir = root.appendingPathComponent("elsewhere/final-folder", isDirectory: true)
    try? fm.createDirectory(at: finalDir, withIntermediateDirectories: true)
    try? "{\"stage\":\"done\",\"final_dir\":\"\(finalDir.path)\",\"updated\":\"2026-10-07T10:30:00+09:00\"}".write(to: stagedDone.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    check(cold.lastMeetingFolder()?.lastPathComponent == "final-folder", "done state.json in staging names the folder", "\(String(describing: cold.lastMeetingFolder()))")
    try? fm.removeItem(at: stagedDone)
    for name in ["2026-09/2026-09-30_0900_x", "2026-10/2026-10-02_1000_a", "2026-10/2026-10-05_1000_b"] {
        try? fm.createDirectory(at: coldArchive.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    check(cold.lastMeetingFolder()?.lastPathComponent == "2026-10-05_1000_b", "newest archive folder by name", "\(String(describing: cold.lastMeetingFolder()))")

    // Hung job is killed and reported.
    let hang = PipelineLauncher(config: config, logDir: logs, statePollInterval: 0.1, stallTimeout: 1.5)
    let hangEvents = EventLog()
    hang.onEvent = { hangEvents.add($0) }
    hang.enqueue(session("2026-10-07_1800_hang1"))
    let killed = waitUntil(20) { hangEvents.strings.contains { $0.hasPrefix("failed:") } }
    check(killed && hangEvents.strings.contains { $0.contains("stopped responding") }, "silent job is killed after the stall timeout", hangEvents.strings.joined(separator: " | "))

    // Shutdown terminates the child and stays quiet.
    let quit = PipelineLauncher(config: config, logDir: logs, statePollInterval: 0.1, stallTimeout: 600)
    let quitEvents = EventLog()
    quit.onEvent = { quitEvents.add($0) }
    quit.enqueue(session("2026-10-07_1900_hang2"))
    _ = waitUntil(5) { quitEvents.strings.contains { $0.hasPrefix("progress:") } }
    quit.shutdown()
    Thread.sleep(forTimeInterval: 0.5)
    check(!quitEvents.strings.contains { $0.hasPrefix("failed:") || $0.hasPrefix("finished:") }, "shutdown stops the child without reporting a failure", quitEvents.strings.joined(separator: " | "))

    // Missing interpreter: actionable message.
    var broken = config
    broken.pythonBin = bin.appendingPathComponent("no-such-python")
    let miss = PipelineLauncher(config: broken, logDir: logs)
    let missEvents = EventLog()
    miss.onEvent = { missEvents.add($0) }
    miss.enqueue(session("2026-10-07_2000_x"))
    _ = waitUntil(5) { !missEvents.all.isEmpty }
    check(missEvents.strings.contains { $0.hasPrefix("failed:") && $0.contains("setup_python.sh") }, "missing PYTHON_BIN gives an actionable failure", missEvents.strings.joined(separator: " | "))
}

// MARK: - Pure helpers

private func testPureHelpers() {
    section("helpers")
    check(PipelineLauncher.stageText(stage: "transcribing", detail: "remote 12/48") == "Transcribing remote 12/48", "stageText transcribing")
    check(PipelineLauncher.stageText(stage: "noting", detail: nil) == "Creating note", "stageText noting")
    check(PipelineLauncher.stageText(stage: "weird", detail: nil) == "Weird", "stageText unknown stage")

    let env = PipelineLauncher.sanitizedEnvironment(from: ["ANTHROPIC_API_KEY": "x", "MCAP_CONFIG": "/tmp/c.env", "PATH": "/evil", "HOME": "/evil"])
    check(env["ANTHROPIC_API_KEY"] == nil && env["PATH"] != "/evil" && env["HOME"] == NSHomeDirectory() && env["MCAP_CONFIG"] == "/tmp/c.env",
          "sanitizedEnvironment: nothing inherited except MCAP_CONFIG")

    let free = ShellUtil.freeDiskGB(near: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("does/not/exist/yet"))
    check((free ?? 0) > 0.05 && (free ?? 0) < 1_000_000, "free disk space readable (nearest existing parent)", "\(String(describing: free))")
    check(StatusMenuController.formatElapsed(723) == "12:03" && StatusMenuController.formatElapsed(3723) == "1:02:03", "elapsed time formatting")
    let wrapped = StatusMenuController.wrap("one two three four five six seven eight nine ten", width: 12, maxLines: 3)
    check(wrapped.count == 3 && wrapped.allSatisfy { $0.count <= 12 }, "menu text wrapping respects width and line limit", "\(wrapped)")
    let id = ShellUtil.sessionIDBase(at: Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4)) ?? Date(), platform: .teams)
    check(id == "2026-01-02_0304_teams", "session id formatting", id)
    let iso = ShellUtil.iso8601(Date(timeIntervalSince1970: 0))
    check(ShellUtil.parseISO8601(iso) == Date(timeIntervalSince1970: 0) && !iso.hasSuffix("Z"), "ISO8601 round trip with numeric offset", iso)
}

// MARK: - Launch arguments

private func testLaunchArguments() {
    section("system launch arguments are ignored")
    let cases: [([String], [String])] = [
        ([], []),
        (["-NSDocumentRevisionsDebugMode", "YES"], []),
        (["-ApplePersistenceIgnoreState", "YES"], []),
        (["-NSQuitAlwaysKeepsWindows", "NO", "-ApplePersistenceIgnoreState", "YES"], []),
        (["-AppleLanguages", "(en)"], []),
        (["-AppleLanguages", "(en)", "probe", "--watch"], ["probe", "--watch"]),
        (["-NSFoo", "probe"], ["probe"]),                        // value missing: our command is not swallowed
        (["-NSFoo", "YES", "--version"], ["--version"]),
        (["-NSFoo", "--help"], ["--help"]),
        (["-psn_0_12345"], []),
        (["-psn_0_12345", "setup"], ["setup"]),
        (["probe", "-NSFoo", "YES"], ["probe", "-NSFoo", "YES"]),   // only LEADING pairs are dropped
        (["selftest-capture", "--synthetic"], ["selftest-capture", "--synthetic"]),
        (["--version"], ["--version"]),
        (["bogus"], ["bogus"]),                                  // unknown commands still reach the dispatcher (exit 2)
    ]
    for (input, expected) in cases {
        let got = LaunchArguments.strip(input)
        check(got == expected, "strip(\(input)) == \(expected)", "\(got)")
    }
}

// MARK: - Menu text

private func testMenuText() {
    section("menu text: 'Auto-detection off' is visible")
    let now = Date(timeIntervalSince1970: 1_000_000)
    let off = "Auto-detection off (ENABLED_PLATFORMS empty)"

    var idleOff = ControllerState()
    idleOff.autoDetectionOff = true
    let t1 = StatusMenuController.menuText(for: idleOff, now: now)
    check(t1.headline == off && t1.lines.isEmpty, "idle with ENABLED_PLATFORMS empty: the status line says detection is off", "\(t1)")

    let t2 = StatusMenuController.menuText(for: ControllerState(), now: now)
    check(t2.headline == "Idle: waiting for a meeting" && t2.lines.isEmpty, "idle with detection on: the normal status line", "\(t2)")

    var rec = idleOff
    rec.status = .recording(.manual, since: now.addingTimeInterval(-65))
    rec.manualRecording = true
    let t3 = StatusMenuController.menuText(for: rec, now: now)
    check(t3.headline.hasPrefix("Recording (manual)") && t3.buttonTitle == "01:05" && t3.lines == [off], "manual recording: elapsed time, and the notice as an extra line", "\(t3)")

    var err = idleOff
    err.status = .error(String(repeating: "word ", count: 80))
    err.warning = nil
    let t4 = StatusMenuController.menuText(for: err, now: now)
    check(t4.lines.last == off && t4.lines.count <= 5, "a long error text plus the notice still fits the 5 detail lines", "\(t4.lines.count) lines")

    var paused = idleOff
    paused.paused = true
    let t5 = StatusMenuController.menuText(for: paused, now: now)
    check(t5.headline.hasPrefix("Paused") && t5.lines == [off], "paused with detection off: paused headline, notice below", "\(t5)")

    // SPEC 15: a warning line when the remote track looks silent (while recording) or the recording was auto-stopped (after).
    var silent = ControllerState()
    silent.status = .recording(.zoom, since: now.addingTimeInterval(-300))
    silent.remoteSilentSuspected = true
    let t6 = StatusMenuController.menuText(for: silent, now: now)
    let silentText = t6.lines.joined(separator: " ")
    check(t6.headline.hasPrefix("Recording Zoom") && silentText.hasPrefix("Warning: remote audio is silent") && silentText.contains("System Audio Recording"),
          "recording with a suspected silent remote track: a warning line says so and where to look", "\(t6)")
    check(t6.lines.allSatisfy { $0.count <= 58 }, "the remote-silent warning is wrapped to the menu width")

    var stopped = ControllerState()
    stopped.notice = "Recording stopped after 15 min without speech on either track. It starts again with the next call."
    let t7 = StatusMenuController.menuText(for: stopped, now: now)
    check(t7.headline == "Idle: waiting for a meeting" && t7.lines.joined(separator: " ").contains("stopped after 15 min without speech"),
          "idle after a no-speech stop: the notice is a line under the status", "\(t7)")

    var everything = idleOff
    everything.status = .error(String(repeating: "word ", count: 80))
    everything.remoteSilentSuspected = true
    everything.notice = String(repeating: "notice ", count: 60)
    let t8 = StatusMenuController.menuText(for: everything, now: now)
    check(t8.lines.count <= StatusMenuController.maxDetailLines && t8.lines.last == off,
          "error + remote-silent warning + notice + detection-off still fit the menu's detail lines", "\(t8.lines.count) of \(StatusMenuController.maxDetailLines)")
    check(StatusMenuController.menuText(for: ControllerState(), now: now).lines.isEmpty, "no warning, no notice: no extra lines")
}

// MARK: - First run of the app installer (FirstRun.swift)

/// The fakes of one scenario: every effect of FirstRunController counts its calls here.
private final class FirstRunWorld {
    var facts = FirstRun.Facts()
    var uiAllowed = true
    var policyManaged = false
    var bundlePath = "/Applications/\(AppInfo.shortName).app"
    var answers: [Bool] = []
    var asked = 0
    var misplacedShown = 0
    var opened: [URL] = []
    var openSucceeds = true
    var failures: [String] = []
    var logs: [String] = []
    var seenStatus: [FirstRun.Status] = []
    var language: UILanguage = L10n.current
    var shown: [FirstRun.AlertText] = []
    var shownMisplaced: [FirstRun.MisplacedText] = []
    var shownRunning: [FirstRun.RunningText] = []
    var helperRunning = false
    var holds: [Bool] = []
    var scheduled: [(seconds: TimeInterval, work: () -> Void)] = []
    /// A main queue that is serial and NOT re-entrant like libdispatch's: `serialMain` queues runOnMain blocks and runs them one after the other in `drain()`;
    /// `runOnRunLoop` blocks wait until the dispatch blocks are done. `askedInsideDispatchBlock` is what went wrong in the app: a modal started inside a block.
    var serialMain = false
    var loopOnMainQueue = false                     // the wiring the app had before: the prompt is handed to the dispatch queue (the negative control of the test)
    private var mainBlocks: [() -> Void] = []
    private var loopBlocks: [() -> Void] = []
    private var insideDispatchBlock = false
    var askedInsideDispatchBlock = 0
    let support: URL
    var mcap: URL?

    init(support: URL, mcap: URL?) {
        self.support = support
        self.mcap = mcap
    }

    func controller() -> FirstRunController {
        let env = FirstRunEnvironment(
            supportDir: support, mcapDir: { self.mcap }, bundlePath: { self.bundlePath }, facts: { self.facts },
            uiAllowed: { self.uiAllowed }, policyManaged: { self.policyManaged }, language: { self.language },
            ask: {
                if self.insideDispatchBlock { self.askedInsideDispatchBlock += 1 }
                self.shown.append($0); self.asked += 1; return self.answers.isEmpty ? false : self.answers.removeFirst()
            },
            tellMisplaced: { self.shownMisplaced.append($0); self.misplacedShown += 1 },
            tellRunning: { self.shownRunning.append($0) },
            openTerminal: { self.opened.append($0); return self.openSucceeds },
            installerRunning: { self.helperRunning },
            showFailure: { self.failures.append($0) },
            runInBackground: { $0() },
            runOnMain: { work in if self.serialMain { self.mainBlocks.append(work) } else { work() } },
            runOnRunLoop: { work in
                if self.serialMain && self.loopOnMainQueue { self.mainBlocks.append(work) }
                else if self.serialMain { self.loopBlocks.append(work) } else { work() }
            },
            runAfter: { seconds, work in self.scheduled.append((seconds, work)) },
            log: { self.logs.append($0) })
        let c = FirstRunController(env: env)
        c.onStatusChange = { self.seenStatus.append($0) }
        c.onHoldChange = { self.holds.append($0) }
        return c
    }

    /// Runs what the serial main queue and the run loop have been given: first the dispatch blocks (one at a time, none inside another), then the run-loop blocks.
    func drain() {
        while !mainBlocks.isEmpty || !loopBlocks.isEmpty {
            while !mainBlocks.isEmpty {
                let work = mainBlocks.removeFirst()
                insideDispatchBlock = true
                work()
                insideDispatchBlock = false
            }
            if !loopBlocks.isEmpty { loopBlocks.removeFirst()() }
        }
    }

    /// Fires what `runAfter` was given (the re-check while recording is held).
    func fireScheduled() {
        let due = scheduled
        scheduled = []
        due.forEach { $0.work() }
    }
}

private func testFirstRun(_ base: URL) {
    section("first run of the app installer: project folder inside the app, components check, one alert, installer copy, menu item")
    let fm = FileManager.default
    let savedLanguage = L10n.current
    defer { L10n.current = savedLanguage }
    let root = base.appendingPathComponent("first-run", isDirectory: true)
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)

    // ---- the project folder inside the app (Config.swift) ----
    let app = root.appendingPathComponent("app/\(AppInfo.shortName).app", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    let mcap = resources.appendingPathComponent("mcap", isDirectory: true)
    try? fm.createDirectory(at: mcap.appendingPathComponent("scripts", isDirectory: true), withIntermediateDirectories: true)
    let plainApp = root.appendingPathComponent("plain/\(AppInfo.shortName).app", isDirectory: true)
    try? fm.createDirectory(at: plainApp.appendingPathComponent("Contents/Resources", isDirectory: true), withIntermediateDirectories: true)
    check(AppConfig.bundledProjectDir(bundleURL: app, resourceURL: resources) == mcap, "an app with Contents/Resources/mcap: the project folder is that folder")
    check(AppConfig.bundledProjectDir(bundleURL: plainApp, resourceURL: plainApp.appendingPathComponent("Contents/Resources", isDirectory: true)) == nil,
          "an app without that folder (a build from source, the company package): nothing changes")
    check(AppConfig.bundledProjectDir(bundleURL: root.appendingPathComponent("bin", isDirectory: true), resourceURL: resources) == nil, "a bare binary (no .app bundle): nothing changes")
    check(AppConfig.bundledProjectDir(bundleURL: app, resourceURL: nil) == nil, "no resource folder: nothing changes")
    let fallback = AppConfig.defaults().projectDir
    check(AppConfig.build(from: [:], source: "t", bundledProject: mcap).projectDir == mcap, "no PROJECT_DIR in config.env: the folder inside the app is used")
    check(AppConfig.build(from: [:], source: "t", bundledProject: nil).projectDir == fallback, "no app folder, no key: the old default (~/Developer/meeting-capture)")
    check(AppConfig.build(from: ["PROJECT_DIR": "/Users/someone/checkout"], source: "t", bundledProject: mcap).projectDir.path == "/Users/someone/checkout",
          "the config.env key PROJECT_DIR still wins over the app's folder")
    check(AppConfig.build(from: ["PROJECT_DIR": "/Library/Application Support/MeetingCapture/releases/current"], source: "t", bundledProject: mcap).projectDir.path
          == "/Library/Application Support/MeetingCapture/releases/current", "a policy-managed Mac that pins PROJECT_DIR keeps its release folder")
    check(AppConfig.defaultsWithBundledProject(bundledProject: mcap).projectDir == mcap && AppConfig.defaultsWithBundledProject(bundledProject: nil).projectDir == fallback,
          "the defaults (used when config.env is missing) follow the same rule")

    // ---- the two records ----
    let h1 = String(repeating: "a", count: 64), h2 = String(repeating: "b", count: 64), h3 = String(repeating: "c", count: 64)
    func bundleJSON(_ runtime: String, _ lock: String) -> Data {
        return Data("{\"python_runtime\":{\"file\":\"../runtime/python-runtime.tar.gz\",\"sha256\":\"\(runtime)\"},\"requirements_lock_sha256\":\"\(lock)\"}\n".utf8)
    }
    check(FirstRun.parseBundleComponents(bundleJSON(h1, h2)) == FirstRun.Components(runtimeSHA256: h1, requirementsLockSHA256: h2), "components.json (the contract of build_dmg.sh) is read")
    check(FirstRun.parseBundleComponents(bundleJSON(h1.uppercased(), h2)) == FirstRun.Components(runtimeSHA256: h1, requirementsLockSHA256: h2), "hex digits in upper case are the same hash")
    check(FirstRun.parseBundleComponents(bundleJSON("abc", h2)) == nil && FirstRun.parseBundleComponents(bundleJSON(h1, String(repeating: "z", count: 64))) == nil,
          "a hash that is not 64 hex digits is refused")
    check(FirstRun.parseBundleComponents(Data("{\"python_runtime\":{\"sha256\":\"\(h1)\"}}".utf8)) == nil && FirstRun.parseBundleComponents(Data("not json".utf8)) == nil
          && FirstRun.parseBundleComponents(Data("[]".utf8)) == nil, "a missing key, text that is not JSON and a JSON array are refused")
    let installedJSON = "{\"python_runtime\":{\"sha256\":\"\(h1)\"},\"requirements_lock_sha256\":\"\(h2)\",\"app_version\":\"0.2.0\",\"installed_at\":\"2026-10-28T10:00:00Z\"}\n"
    check(FirstRun.parseInstalled(Data(installedJSON.utf8)) == FirstRun.Components(runtimeSHA256: h1, requirementsLockSHA256: h2),
          "components-installed.json as the helper writes it (no file key, two extra fields) is read")

    // ---- the verdict ----
    let good = FirstRun.Components(runtimeSHA256: h1, requirementsLockSHA256: h2)
    let f = FirstRun.Facts(bundle: good, installed: good, venvPythonExecutable: true, modelBytes: FirstRun.Pinned.current.modelBytes,
                           sileroBytes: FirstRun.Pinned.current.sileroBytes, needsLocalModel: true)
    check(FirstRun.evaluate(f) == .ready, "everything in place: ready")
    var x = f; x.bundle = nil
    check(FirstRun.evaluate(x) == .notApplicable, "no components.json in the app: not applicable (nothing is checked or offered)")
    x = f; x.installed = nil
    check(FirstRun.evaluate(x) == .needsInstall(.notInstalled), "no components-installed.json: not installed")
    x = f; x.installed = FirstRun.Components(runtimeSHA256: h3, requirementsLockSHA256: h2)
    check(FirstRun.evaluate(x) == .needsInstall(.outdated), "another Python runtime hash: outdated")
    x = f; x.installed = FirstRun.Components(runtimeSHA256: h1, requirementsLockSHA256: h3)
    check(FirstRun.evaluate(x) == .needsInstall(.outdated), "another requirements lock hash: outdated")
    x = f; x.venvPythonExecutable = false
    check(FirstRun.evaluate(x) == .needsInstall(.venvMissing), "the venv python is missing: incomplete")
    x = f; x.modelBytes = nil
    check(FirstRun.evaluate(x) == .needsInstall(.modelMissing), "the speech model file is missing")
    x = f; x.modelBytes = FirstRun.Pinned.current.modelBytes - 1
    check(FirstRun.evaluate(x) == .needsInstall(.modelMissing), "the speech model file has another size than the pinned one (a download that was cut)")
    x = f; x.modelBytes = nil; x.needsLocalModel = false
    check(FirstRun.evaluate(x) == .ready, "a cloud or company speech engine: the local model is not required")
    x = f; x.sileroBytes = nil
    check(FirstRun.evaluate(x) == .needsInstall(.vadModelMissing), "the Silero model is missing")
    x = f; x.installed = nil; x.venvPythonExecutable = false; x.modelBytes = nil
    check(FirstRun.evaluate(x) == .needsInstall(.notInstalled), "several things missing: the first reason (not installed) is reported")
    check(FirstRun.needsLocalModel(asrEngine: nil) && FirstRun.needsLocalModel(asrEngine: "") && FirstRun.needsLocalModel(asrEngine: " Whisper ") && FirstRun.needsLocalModel(asrEngine: "auto")
          && !FirstRun.needsLocalModel(asrEngine: "remote") && !FirstRun.needsLocalModel(asrEngine: "clova") && !FirstRun.needsLocalModel(asrEngine: "openai-compat"),
          "ASR_ENGINE whisper / auto / unset need the local model; remote, clova, azure, openai-compat do not")

    // ---- the facts from a real folder (the model files are tiny here: the pinned sizes are injected) ----
    var small = FirstRun.Pinned.current
    small.modelBytes = 12
    small.sileroBytes = 5
    let home = root.appendingPathComponent("home", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let venvPython = support.appendingPathComponent("venv/bin/python")
    try? fm.createDirectory(at: venvPython.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createDirectory(at: small.modelPath(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createDirectory(at: small.sileroPath(supportDir: support).deletingLastPathComponent(), withIntermediateDirectories: true)
    try? bundleJSON(h1, h2).write(to: mcap.appendingPathComponent("components.json"))
    try? Data(installedJSON.utf8).write(to: support.appendingPathComponent(FirstRun.installedFile))
    fm.createFile(atPath: venvPython.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    try? Data(count: 12).write(to: small.modelPath(home: home))
    try? Data(count: 5).write(to: small.sileroPath(supportDir: support))
    func gather(needsLocalModel: Bool = true, disk: FirstRun.Disk = FirstRun.Disk()) -> FirstRun.Status {
        return FirstRun.evaluate(FirstRun.gatherFacts(resources: resources, supportDir: support, pythonBin: venvPython, home: home, needsLocalModel: needsLocalModel, pinned: small, disk: disk), pinned: small)
    }
    check(gather() == .ready, "real files: components.json, the record, the venv python and both models in place: ready")
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: venvPython.path)
    check(gather() == .needsInstall(.venvMissing), "real files: a python that is not executable counts as missing")
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: venvPython.path)
    try? Data(count: 11).write(to: small.modelPath(home: home))
    check(gather() == .needsInstall(.modelMissing) && gather(needsLocalModel: false) == .ready, "real files: a speech model of another size is missing (unless a cloud engine is used)")
    try? Data(count: 12).write(to: small.modelPath(home: home))
    try? fm.removeItem(at: small.sileroPath(supportDir: support))
    check(gather() == .needsInstall(.vadModelMissing), "real files: the Silero model is missing")
    try? Data(count: 5).write(to: small.sileroPath(supportDir: support))
    try? Data("{\"python_runtime\":{\"sha256\":\"\(h3)\"},\"requirements_lock_sha256\":\"\(h2)\"}".utf8).write(to: support.appendingPathComponent(FirstRun.installedFile))
    check(gather() == .needsInstall(.outdated), "real files: a record with another runtime hash is outdated")
    try? Data("garbage".utf8).write(to: support.appendingPathComponent(FirstRun.installedFile))
    check(gather() == .needsInstall(.notInstalled), "real files: a record that cannot be read counts as not installed")
    try? fm.removeItem(at: support.appendingPathComponent(FirstRun.installedFile))
    check(gather() == .needsInstall(.notInstalled), "real files: no record: not installed")
    var reads: [String] = []
    var counting = FirstRun.Disk()
    let realRead = counting.read
    counting.read = { url in reads.append(url.lastPathComponent); return realRead(url) }
    let noComponents = FirstRun.evaluate(FirstRun.gatherFacts(resources: plainApp.appendingPathComponent("Contents/Resources", isDirectory: true), supportDir: support, pythonBin: venvPython,
                                                              home: home, needsLocalModel: true, pinned: small, disk: counting), pinned: small)
    check(noComponents == .notApplicable && reads == [FirstRun.componentsFile], "an app without components.json reads nothing else: not even the record", "\(reads)")
    check(FirstRun.evaluate(FirstRun.gatherFacts(resources: nil, supportDir: support, pythonBin: venvPython, home: home, needsLocalModel: true)) == .notApplicable, "no resource folder at all: not applicable")
    check(FirstRun.Pinned.current.modelPath(home: URL(fileURLWithPath: "/Users/someone")).path
          == "/Users/someone/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-mlx/snapshots/49e6aa286ad60c14352c404340ded53710378a11/weights.npz",
          "the pinned speech model sits where huggingface_hub puts it (default cache, pinned revision)")

    // ---- the speech model as huggingface_hub stores it: snapshots/<rev>/weights.npz is a relative LINK into blobs/<etag> (stat follows it, attributesOfItem did not) ----
    try? Data(installedJSON.utf8).write(to: support.appendingPathComponent(FirstRun.installedFile))
    let hfHome = root.appendingPathComponent("home-hf", isDirectory: true)
    let hfModel = small.modelPath(home: hfHome)
    let hfRepo = hfModel.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let hfBlob = hfRepo.appendingPathComponent("blobs/05ff79ab4c1d", isDirectory: false)
    try? fm.createDirectory(at: hfBlob.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createDirectory(at: hfModel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(count: 12).write(to: hfBlob)
    try? fm.createSymbolicLink(atPath: hfModel.path, withDestinationPath: "../../blobs/05ff79ab4c1d")
    func gatherHF(needsLocalModel: Bool = true) -> FirstRun.Status {
        return FirstRun.evaluate(FirstRun.gatherFacts(resources: resources, supportDir: support, pythonBin: venvPython, home: hfHome, needsLocalModel: needsLocalModel, pinned: small), pinned: small)
    }
    check((try? fm.attributesOfItem(atPath: hfModel.path))?[.type] as? FileAttributeType == .typeSymbolicLink, "the fixture is a link, as in a real cache (ls shows weights.npz -> ../../blobs/<etag>)")
    check(FirstRun.Disk().size(hfModel) == 12 && FirstRun.Disk().size(hfBlob) == 12, "Disk.size follows the link: the size of the file behind it (a regular file works as before)")
    check(gatherHF() == .ready, "a model behind a Hugging Face cache link counts: ready (the verdict was 'model missing' forever before)")
    try? Data(count: 11).write(to: hfBlob)
    check(gatherHF() == .needsInstall(.modelMissing), "... a blob of another size behind the link is missing")
    try? fm.removeItem(at: hfBlob)
    check(FirstRun.Disk().size(hfModel) == nil && gatherHF() == .needsInstall(.modelMissing), "... a dangling link (the blob is gone) is missing")
    let hfDir = hfRepo.appendingPathComponent("blobs/a-folder", isDirectory: true)
    try? fm.createDirectory(at: hfDir, withIntermediateDirectories: true)
    try? fm.removeItem(at: hfModel)
    try? fm.createSymbolicLink(atPath: hfModel.path, withDestinationPath: "../../blobs/a-folder")
    check(FirstRun.Disk().size(hfModel) == nil && FirstRun.Disk().size(hfDir) == nil, "... a link to a folder is not a regular file (nor is a folder)")
    check(FirstRun.Disk().size(root.appendingPathComponent("no-such-file")) == nil, "... and a path that does not exist is missing")

    // ---- the facts of this Mac from a real config.env: ASR_ENGINE says whether the 3 GB model is needed ----
    let liveSupport = root.appendingPathComponent("live-support", isDirectory: true)
    let liveHome = root.appendingPathComponent("live-home", isDirectory: true)            // no model in it
    let livePython = liveSupport.appendingPathComponent("venv/bin/python")
    try? fm.createDirectory(at: livePython.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createDirectory(at: liveSupport.appendingPathComponent("models", isDirectory: true), withIntermediateDirectories: true)
    fm.createFile(atPath: livePython.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    try? Data(count: Int(FirstRun.Pinned.current.sileroBytes)).write(to: FirstRun.Pinned.current.sileroPath(supportDir: liveSupport))
    try? Data(installedJSON.utf8).write(to: liveSupport.appendingPathComponent(FirstRun.installedFile))
    let liveConfig = root.appendingPathComponent("live-config.env")
    func live(_ text: String?) -> FirstRun.Status {
        if let text = text { try? Data(text.utf8).write(to: liveConfig) } else { try? fm.removeItem(at: liveConfig) }
        return FirstRun.evaluate(FirstRun.liveFacts(configFile: liveConfig, resources: resources, supportDir: liveSupport, pythonBin: livePython, home: liveHome))
    }
    check(live(nil) == .needsInstall(.modelMissing), "live facts, no config.env: the default engine needs the local model (missing here)")
    check(live("ASR_ENGINE=whisper\n") == .needsInstall(.modelMissing) && live("# a comment\nASR_ENGINE= Auto  \n") == .needsInstall(.modelMissing), "... whisper and auto need it too")
    check(live("ASR_ENGINE=clova\n") == .ready && live("ASR_ENGINE=remote # the company server\n") == .ready && live("ASR_ENGINE=openai-compat\n") == .ready,
          "ASR_ENGINE=clova / remote / openai-compat in config.env: the local model is not required (ready without it)")
    check(live("this is not a config\n\u{0}\n") == .needsInstall(.modelMissing), "... a config.env that says nothing about the engine changes nothing")

    // the live environment of the app (the closures the app really uses, minus the windows): in this test process the bundle has no components.json
    var appConfig = AppConfig.defaults()
    appConfig.supportDir = liveSupport
    let liveEnv = FirstRunEnvironment.live(config: appConfig)
    check(FirstRun.evaluate(liveEnv.facts()) == .notApplicable && liveEnv.mcapDir() == nil && !liveEnv.installerRunning() && liveEnv.supportDir == liveSupport && !liveEnv.bundlePath().isEmpty,
          "FirstRunEnvironment.live: a bundle without components.json is not applicable, has no mcap folder, no helper runs and the support folder is the config's")

    // ---- the hold, the lock ----
    check(FirstRun.holdsRecording(.needsInstall(.notInstalled)), "recording is held while there is no components-installed.json (the helper has not shown the legal notice)")
    check(!FirstRun.holdsRecording(.ready) && !FirstRun.holdsRecording(.notApplicable) && !FirstRun.holdsRecording(.needsInstall(.outdated)) && !FirstRun.holdsRecording(.needsInstall(.venvMissing))
          && !FirstRun.holdsRecording(.needsInstall(.modelMissing)) && !FirstRun.holdsRecording(.needsInstall(.vadModelMissing)),
          "... not when ready, not in a build without components.json, not for an older or incomplete install (the notice was accepted then)")
    let lockSupport = root.appendingPathComponent("lock-support", isDirectory: true)
    let lockLink = lockSupport.appendingPathComponent(FirstRun.lockName)
    try? fm.createDirectory(at: lockSupport, withIntermediateDirectories: true)
    check(FirstRun.lockName == ".first-run.lock" && !FirstRun.installerRunning(supportDir: lockSupport), "no lock link: no helper runs")
    try? fm.createSymbolicLink(atPath: lockLink.path, withDestinationPath: "\(getpid())")
    check(FirstRun.installerRunning(supportDir: lockSupport), "a lock link that names a live process: a helper runs")
    let gone = Process()
    gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? gone.run()
    gone.waitUntilExit()
    try? fm.removeItem(at: lockLink)
    try? fm.createSymbolicLink(atPath: lockLink.path, withDestinationPath: "\(gone.processIdentifier)")
    check(!FirstRun.installerRunning(supportDir: lockSupport), "a lock link that names a process that has ended (a crashed helper): not running")
    for junk in ["abc", "0", "-5", ""] {
        try? fm.removeItem(at: lockLink)
        try? fm.createSymbolicLink(atPath: lockLink.path, withDestinationPath: junk.isEmpty ? "x" : junk)
        check(!FirstRun.installerRunning(supportDir: lockSupport), "a lock link that names '\(junk.isEmpty ? "x" : junk)': not running")
    }
    check(!FirstRun.installerRunning(supportDir: lockSupport, destination: { _ in nil }, isAlive: { _ in true }) && FirstRun.installerRunning(supportDir: lockSupport, destination: { _ in "4242" }, isAlive: { $0 == 4242 }),
          "the pid is read from the link and asked about (injected)")

    // ---- when to ask ----
    let need = FirstRun.Status.needsInstall(.notInstalled)
    check(FirstRun.shouldPrompt(status: need, uiAllowed: true, policyManaged: false, alreadyPrompted: false), "missing components, UI allowed: ask")
    check(!FirstRun.shouldPrompt(status: need, uiAllowed: false, policyManaged: false, alreadyPrompted: false), "UI not allowed (the app was not started by LaunchServices): never ask")
    check(!FirstRun.shouldPrompt(status: need, uiAllowed: true, policyManaged: true, alreadyPrompted: false), "a policy-managed Mac: never ask")
    check(!FirstRun.shouldPrompt(status: need, uiAllowed: true, policyManaged: false, alreadyPrompted: true), "already asked in this launch: never again")
    check(!FirstRun.shouldPrompt(status: .ready, uiAllowed: true, policyManaged: false, alreadyPrompted: false) && !FirstRun.shouldPrompt(status: .notApplicable, uiAllowed: true, policyManaged: false, alreadyPrompted: false),
          "nothing missing, or not an installer build: never ask")
    check(FirstRun.isMisplaced(bundlePath: "/Volumes/\(AppInfo.displayName)/\(AppInfo.shortName).app") && FirstRun.isMisplaced(bundlePath: "/private/var/folders/ab/xy/T/AppTranslocation/0A1B/d/\(AppInfo.shortName).app")
          && !FirstRun.isMisplaced(bundlePath: "/Applications/\(AppInfo.shortName).app") && !FirstRun.isMisplaced(bundlePath: "/Users/someone/Applications/\(AppInfo.shortName).app"),
          "the disk image and a translocated copy are misplaced; Applications and ~/Applications are not")

    // ---- texts ----
    L10n.current = .en
    let en = FirstRun.alertText()
    check(en.message == "\(AppInfo.displayName) needs to install its components (about 4 GB download, needs internet). Start now?" && en.start == "Start" && en.later == "Later",
          "the alert in English: the sentence of the contract, [Start] [Later]", en.message)
    check(FirstRun.menuItem(for: need) == FirstRun.MenuItemState(title: "Components: not installed - run installer", visible: true, tooltip: FirstRun.menuItem(for: need).tooltip)
          && FirstRun.menuItem(for: need).tooltip?.isEmpty == false, "the menu item in English: 'Components: not installed - run installer'")
    check(FirstRun.menuItem(for: .needsInstall(.outdated)).title == "Components: update needed - run installer"
          && FirstRun.menuItem(for: .needsInstall(.modelMissing)).title == "Components: incomplete - run installer"
          && FirstRun.menuItem(for: .needsInstall(.venvMissing)).title == FirstRun.menuItem(for: .needsInstall(.vadModelMissing)).title, "outdated and incomplete have their own titles")
    check(!FirstRun.menuItem(for: .ready).visible && !FirstRun.menuItem(for: .notApplicable).visible, "nothing missing: the menu item is hidden")
    L10n.current = .ko
    let ko = FirstRun.alertText()
    check(hasHangul(ko.message) && ko.message.contains("4 GB") && ko.start == "시작" && ko.later == "나중에" && hasHangul(FirstRun.misplacedText().message) && hasHangul(FirstRun.menuItem(for: need).title)
          && hasHangul(FirstRun.failureText(.terminalFailed("/x")))  && FirstRun.failureText(.terminalFailed("/x")).contains("bash \"/x\""),
          "the alert, the misplaced notice, the menu item and the failure texts are Korean with UI_LANGUAGE=ko", ko.message)
    check(FirstRun.misplacedText().message != "" && en.message != ko.message, "the two languages differ")
    let runningKo = FirstRun.runningText(command: "bash \"/x/first-run-install.command\"")
    check(hasHangul(runningKo.message) && hasHangul(runningKo.info) && runningKo.info.contains("bash \"/x/first-run-install.command\""), "the 'already running' notice is Korean with UI_LANGUAGE=ko and names the command to run by hand")
    L10n.current = .en
    check(FirstRun.runningText(command: "bash x", lang: .en).info.contains("bash x") && !hasHangul(FirstRun.runningText(command: "bash x", lang: .en).message), "... and English with UI_LANGUAGE=en")
    L10n.current = .ko

    // ---- the copy of the helper ----
    let script = Data("#!/bin/bash\necho first run\n".utf8)
    let installMcap = root.appendingPathComponent("install-app/mcap", isDirectory: true)
    try? fm.createDirectory(at: installMcap.appendingPathComponent("scripts", isDirectory: true), withIntermediateDirectories: true)
    try? script.write(to: installMcap.appendingPathComponent(FirstRun.bundledScript))
    let installSupport = root.appendingPathComponent("install-support", isDirectory: true)
    func attrs(_ url: URL) -> (mode: Int, inode: Int)? {
        guard let a = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        return ((a[.posixPermissions] as? NSNumber)?.intValue ?? -1, (a[.systemFileNumber] as? NSNumber)?.intValue ?? -1)
    }
    var copy: URL?
    if case .success(let url) = FirstRun.prepareInstaller(mcapDir: installMcap, supportDir: installSupport) { copy = url }
    check(copy == installSupport.appendingPathComponent("first-run-install.command"), "the helper is copied to SUPPORT_DIR/first-run-install.command (the folder is created)", "\(String(describing: copy))")
    if let copy = copy {
        check(fm.contents(atPath: copy.path) == script && attrs(copy)?.mode == 0o755, "the copy is byte for byte the bundled script and mode 755")
        let env = installSupport.appendingPathComponent(FirstRun.envFileName)
        check(String(data: fm.contents(atPath: env.path) ?? Data(), encoding: .utf8) == "MCAP_BUNDLE_DIR=\(installMcap.path)\n" && attrs(env)?.mode == 0o600,
              "first-run.env has one line, the app's mcap folder, mode 600")
        let before = attrs(copy)?.inode
        _ = FirstRun.prepareInstaller(mcapDir: installMcap, supportDir: installSupport)
        check(attrs(copy)?.inode == before, "an identical copy is left alone")
        try? Data("tampered\n".utf8).write(to: copy)
        _ = FirstRun.prepareInstaller(mcapDir: installMcap, supportDir: installSupport)
        check(fm.contents(atPath: copy.path) == script, "a copy that differs from the bundled script is replaced")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        _ = FirstRun.prepareInstaller(mcapDir: installMcap, supportDir: installSupport)
        check(attrs(copy)?.mode == 0o755, "a copy that lost its executable bit gets it back")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: installSupport.path)) ?? []).sorted()
        check(leftovers == ["first-run-install.command", "first-run.env"], "nothing but those two files is written (no config.env, no consent, no temp file)", "\(leftovers)")
    }
    let emptyMcap = root.appendingPathComponent("empty-mcap", isDirectory: true)
    try? fm.createDirectory(at: emptyMcap, withIntermediateDirectories: true)
    if case .failure(let error) = FirstRun.prepareInstaller(mcapDir: emptyMcap, supportDir: root.appendingPathComponent("s2", isDirectory: true)) {
        check(error == .scriptMissing(emptyMcap.appendingPathComponent(FirstRun.bundledScript).path), "no bundled script: refused with its path")
    } else { check(false, "no bundled script: refused") }
    check(!fm.fileExists(atPath: root.appendingPathComponent("s2").path), "... and nothing is created")
    if case .failure(let error) = FirstRun.prepareInstaller(mcapDir: URL(fileURLWithPath: installMcap.path + "\nMCAP_EVIL=1", isDirectory: true), supportDir: root.appendingPathComponent("s3", isDirectory: true)) {
        check({ if case .scriptMissing = error { return true }; if case .writeFailed = error { return true }; return false }(), "a folder name with a line break can never reach first-run.env")
    } else { check(false, "a folder name with a line break is refused") }
    let blocked = root.appendingPathComponent("blocked-support")
    fm.createFile(atPath: blocked.path, contents: Data("a file where the folder should be".utf8))
    if case .failure(let error) = FirstRun.prepareInstaller(mcapDir: installMcap, supportDir: blocked) {
        check(error == .writeFailed(blocked.path), "SUPPORT_DIR is a file: refused as write failed")
    } else { check(false, "SUPPORT_DIR is a file: refused") }
    check(FirstRun.terminalArguments(for: URL(fileURLWithPath: "/x/first-run-install.command")) == ["-a", "Terminal", "/x/first-run-install.command"], "Terminal is opened with: open -a Terminal <the copy>")

    // ---- the controller: one alert, no alert, the menu ----
    func world(_ name: String, needs: Bool = true, mcap mcapDir: URL? = installMcap) -> FirstRunWorld {
        let w = FirstRunWorld(support: root.appendingPathComponent("w-\(name)", isDirectory: true), mcap: mcapDir)
        w.facts = FirstRun.Facts(bundle: good, installed: needs ? nil : good, venvPythonExecutable: true, modelBytes: FirstRun.Pinned.current.modelBytes,
                                 sileroBytes: FirstRun.Pinned.current.sileroBytes, needsLocalModel: true)
        return w
    }
    func supportFiles(_ w: FirstRunWorld) -> [String] { ((try? fm.contentsOfDirectory(atPath: w.support.path)) ?? []).sorted() }
    L10n.current = .en

    var w = world("notapplicable")
    w.facts.bundle = nil
    var c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 0 && w.opened.isEmpty && c.status == .notApplicable && w.seenStatus == [.notApplicable] && supportFiles(w).isEmpty, "not an installer build: no alert, no Terminal, nothing written")

    w = world("ready", needs: false)
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 0 && w.opened.isEmpty && c.status == .ready, "everything installed: no alert")

    w = world("noui")
    w.uiAllowed = false
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 0 && w.misplacedShown == 0 && w.opened.isEmpty && c.status == .needsInstall(.notInstalled), "UI not allowed: no alert, no window, the status is still known for the menu")

    w = world("policy")
    w.policyManaged = true
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 0 && w.opened.isEmpty && c.status.needsInstall, "a policy-managed Mac: no alert (the company package brings its runtime)")

    w = world("start")
    w.answers = [true]
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 1 && w.opened == [w.support.appendingPathComponent("first-run-install.command")] && supportFiles(w) == ["first-run-install.command", "first-run.env"],
          "Start: the helper is copied into SUPPORT_DIR and opened in Terminal", "\(w.asked) \(w.opened) \(supportFiles(w))")
    c.checkAtLaunch()
    c.checkAtLaunch()
    check(w.asked == 1 && w.opened.count == 1, "at most one alert per launch, however often the check runs")
    c.refreshStatus()
    check(w.asked == 1 && w.seenStatus.count == 4, "the menu refresh never asks (and reports the status)")

    w = world("later")
    w.answers = [false]
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 1 && w.opened.isEmpty && supportFiles(w).isEmpty && c.status.needsInstall, "Later: nothing is copied or opened, the status stays 'missing' for the menu")
    c.startInstaller()
    check(w.asked == 1 && w.opened.count == 1, "the menu item starts the helper without asking again")

    w = world("misplaced")
    w.bundlePath = "/Volumes/\(AppInfo.displayName)/\(AppInfo.shortName).app"
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 0 && w.misplacedShown == 1 && w.opened.isEmpty && supportFiles(w).isEmpty, "from the disk image: the notice 'move me to Applications', no installer")
    c.startInstaller()
    check(w.misplacedShown == 2 && w.opened.isEmpty, "the menu item says the same")

    w = world("terminal")
    w.answers = [true]
    w.openSucceeds = false
    c = w.controller()
    c.checkAtLaunch()
    check(w.failures.count == 1 && w.failures[0].contains("first-run-install.command") && w.failures[0].contains("bash"), "Terminal cannot be opened: the failure says how to run the copy by hand", "\(w.failures)")

    w = world("nobundle", mcap: nil)
    w.answers = [true]
    c = w.controller()
    c.checkAtLaunch()
    check(w.failures.count == 1 && w.opened.isEmpty, "no mcap folder in the app: a failure notice, nothing opened")

    w = world("noscript", mcap: emptyMcap)
    w.answers = [true]
    c = w.controller()
    c.checkAtLaunch()
    check(w.failures.count == 1 && w.failures[0].contains("first_run_install.sh") && w.opened.isEmpty && supportFiles(w).isEmpty, "the script is missing from the app: a failure notice naming it, nothing opened")

    L10n.current = .ko
    w = world("ko")
    w.answers = [true]
    w.openSucceeds = false
    c = w.controller()
    c.checkAtLaunch()
    check(w.failures.count == 1 && hasHangul(w.failures[0]), "the failure notice is Korean with UI_LANGUAGE=ko")
    check(!supportFiles(w).contains("config.env") && !supportFiles(w).contains("asr-consent.json"), "the first run never writes config.env or the consent file (consent stays a Terminal-only step)", "\(supportFiles(w))")

    // ---- the hold: the verdict is read before the controller starts; a re-check ends it without a click ----
    L10n.current = .en
    w = world("hold")
    w.uiAllowed = false
    c = w.controller()
    check(c.evaluateNow() == .needsInstall(.notInstalled) && c.status == .needsInstall(.notInstalled) && w.holds == [true] && w.asked == 0 && w.opened.isEmpty,
          "evaluateNow (before the session controller starts): not installed, the hold is announced, no alert and no window")
    check(w.scheduled.count == 1 && w.scheduled[0].seconds == FirstRun.holdRecheckSeconds, "... and one re-check is scheduled")
    c.checkAtLaunch()
    c.refreshStatus()
    check(w.scheduled.count == 1 && w.holds == [true, true, true], "more checks while the hold lasts never schedule a second re-check")
    w.facts.installed = FirstRun.Components(runtimeSHA256: h3, requirementsLockSHA256: h2)
    w.fireScheduled()
    check(c.status == .needsInstall(.outdated) && w.holds.last == false && w.scheduled.isEmpty, "the helper's record appears (even an outdated one): the hold ends, no more re-checks")
    w = world("hold-clear")
    w.uiAllowed = false
    c = w.controller()
    _ = c.evaluateNow()
    w.facts.installed = good
    w.fireScheduled()
    check(c.status == .ready && w.holds == [true, false] && w.scheduled.isEmpty, "the record that matches the app: ready, hold released by the re-check alone")
    w = world("hold-na")
    w.facts.bundle = nil
    c = w.controller()
    check(c.evaluateNow() == .notApplicable && w.holds == [false] && w.scheduled.isEmpty, "a build without components.json: no hold, no re-check")
    w = world("hold-ready", needs: false)
    c = w.controller()
    check(c.evaluateNow() == .ready && w.holds == [false] && w.scheduled.isEmpty, "everything installed: no hold")

    // ---- one helper at a time ----
    w = world("running")
    w.helperRunning = true
    c = w.controller()
    c.startInstaller()
    check(w.opened.isEmpty && w.shownRunning.count == 1 && w.failures.isEmpty && w.shownRunning[0].info.contains("first-run-install.command") && w.shownRunning[0].info.contains("bash"),
          "the helper already runs (its lock): no second Terminal window, a notice that says how to run the copy by hand")
    check(supportFiles(w) == ["first-run-install.command", "first-run.env"], "... the copy is in place for that hand start", "\(supportFiles(w))")
    w.helperRunning = false
    c.startInstaller()
    check(w.opened.count == 1 && w.shownRunning.count == 1, "the lock is gone: the helper starts")
    w = world("running-alert")
    w.helperRunning = true
    w.answers = [true]
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 1 && w.opened.isEmpty && w.shownRunning.count == 1, "Start in the launch alert while a helper runs: the notice, not a second window")

    // ---- the alert never starts inside a dispatch block of the serial main queue (libdispatch does not re-enter: the menu icon, the busy guard and notification clicks would wait) ----
    w = world("serial")
    w.serialMain = true
    w.answers = [true]
    c = w.controller()
    c.checkAtLaunch()
    check(w.asked == 0 && w.opened.isEmpty, "serial main queue: nothing runs before the queue is drained")
    w.drain()
    check(w.asked == 1 && w.askedInsideDispatchBlock == 0 && w.opened.count == 1 && c.status.needsInstall, "... the alert and the Terminal start come from the run loop, never from inside a dispatch block", "\(w.askedInsideDispatchBlock)")
    w = world("serial-old")
    w.serialMain = true
    w.loopOnMainQueue = true
    w.answers = [false]
    c = w.controller()
    c.checkAtLaunch()
    w.drain()
    check(w.asked == 1 && w.askedInsideDispatchBlock == 1, "negative control: wired through the dispatch queue (the old way) this world sees the alert inside a block")

    // ---- the language of the first launch: no config.env yet, so the macOS language decides (the controller passes it on to the alert, the notice and the menu item) ----
    check(FirstRun.systemLanguage(["ko-KR", "en-US"]) == .ko && FirstRun.systemLanguage(["KO"]) == .ko && FirstRun.systemLanguage(["en-US", "ko-KR"]) == .en
          && FirstRun.systemLanguage(["ja-JP"]) == .en && FirstRun.systemLanguage([]) == .en, "the macOS language: Korean only when the first preferred language is Korean")
    L10n.current = .en
    w = world("lang-ko")
    w.language = .ko
    w.answers = [false]
    c = w.controller()
    c.checkAtLaunch()
    check(w.shown.count == 1 && w.shown[0] == FirstRun.alertText(lang: .ko) && hasHangul(w.shown[0].message) && c.menuItem(for: c.status).title == "구성 요소: 설치 안 됨 - 설치 프로그램 실행",
          "the app still speaks English, but a Korean macOS gets the Korean alert and menu item at the first launch")
    w = world("lang-en")
    w.language = .en
    w.answers = [false]
    c = w.controller()
    c.checkAtLaunch()
    check(w.shown.count == 1 && w.shown[0] == FirstRun.alertText(lang: .en) && c.menuItem(for: c.status).title == "Components: not installed - run installer", "an English setting gets the English alert and menu item")
    w = world("lang-misplaced")
    w.language = .ko
    w.bundlePath = "/Volumes/\(AppInfo.displayName)/\(AppInfo.shortName).app"
    c = w.controller()
    c.checkAtLaunch()
    check(w.shownMisplaced == [FirstRun.misplacedText(lang: .ko)], "the 'move me to Applications' notice follows that language too")
    L10n.current = .ko
}

// MARK: - Recording held until the app installer has finished

private func testInstallHold(_ base: URL) {
    section("app installer: a dmg build without components-installed.json records nothing (no detection, no manual start, no calendar start, no Recorder) until the helper has finished")
    let savedLanguage = L10n.current
    defer { L10n.current = savedLanguage }
    L10n.current = .en

    // ---- the controller alone ----
    let h = Harness("install-hold", in: base)
    h.controller.setInstallHold(true)
    h.sync()
    h.run(40, [meetSignal()])
    check(h.recorders.isEmpty && h.sessionDirNames().isEmpty && h.detector.polls == 0, "held: a call that goes on for 40 s starts no recording and is not even looked at (no poll)", "\(h.recorders.count) \(h.detector.polls)")
    check(h.state.installHold && h.state.status == .idle && !h.state.paused, "... the state says so, and it is not the pause of the menu")
    h.controller.startRecordingNow()
    h.sync()
    check(h.recorders.isEmpty && h.sessionDirNames().isEmpty, "held: 'Start Recording Now' creates no Recorder and no session folder")
    check(h.controller.startRecordingFromCalendar(eventID: "ev-1", title: nil) == .held && h.recorders.isEmpty, "held: the calendar auto-start is refused with its own answer (the event is not marked as handled)")
    check(StatusMenuController.manualItemState(for: h.state).enabled == false && StatusMenuController.menuText(for: h.state, now: h.clock.now).headline == "Auto recording is off until the installer has finished"
          && StatusMenuController.menuIcon(for: h.state).names.first == "pause.circle", "held: the menu says 'Auto recording is off until the installer has finished', the manual item is off and the icon is the pause icon")
    L10n.current = .ko
    check(hasHangul(StatusMenuController.menuText(for: h.state, now: h.clock.now).headline) && hasHangul(StatusMenuController.manualItemState(for: h.state).title), "... in Korean with UI_LANGUAGE=ko")
    L10n.current = .en
    check(StatusMenuController.manualItemState(for: ControllerState()).enabled, "not held: the manual item is on as always")

    // ---- the first-run controller opens the gate: a dmg build, no record, then the record appears ----
    let good = FirstRun.Components(runtimeSHA256: String(repeating: "a", count: 64), requirementsLockSHA256: String(repeating: "b", count: 64))
    let support = base.appendingPathComponent("hold-support", isDirectory: true)
    let world = FirstRunWorld(support: support, mcap: nil)
    world.uiAllowed = false
    world.facts = FirstRun.Facts(bundle: good, installed: nil, venvPythonExecutable: true, modelBytes: FirstRun.Pinned.current.modelBytes,
                                 sileroBytes: FirstRun.Pinned.current.sileroBytes, needsLocalModel: true)
    let g = Harness("install-hold-launch", in: base)
    let first = world.controller()
    let recordHold = first.onHoldChange
    first.onHoldChange = { recordHold?($0); g.controller.setInstallHold($0) }      // what App.swift does (plus the world's own record)
    g.controller.setInstallHold(FirstRun.holdsRecording(first.evaluateNow()))
    g.sync()
    g.run(40, [meetSignal()])
    check(g.recorders.isEmpty && g.sessionDirNames().isEmpty && g.state.installHold, "a dmg build without the record: a call of 40 s starts no recording and creates no Recorder")
    g.controller.startRecordingNow()
    g.sync()
    check(g.recorders.isEmpty && g.controller.startRecordingFromCalendar(eventID: "ev-2", title: nil) == .held, "... neither by hand nor by calendar")
    world.facts.installed = good                                           // the helper has finished and written components-installed.json
    world.fireScheduled()
    g.sync()
    check(!g.state.installHold && world.holds.last == false, "the re-check finds the record: the hold ends by itself")
    g.run(30, [meetSignal()])
    check(g.recorders.count == 1 && g.recorders[0].isRecording, "... and the next call is recorded as always", "\(g.recorders.count)")

    // ---- a hold that comes later never ends a recording that runs ----
    g.controller.setInstallHold(true)
    g.sync()
    check(g.recorders.count == 1 && g.recorders[0].isRecording && g.state.installHold, "a hold set during a recording does not end it")
    g.controller.stopRecordingNow()
    g.sync()
    g.run(40, [])                                                          // the call is over (the stop by hand is forgotten after the grace time)
    g.run(30, [meetSignal(code: "zzz-yyyy-xxx")])
    check(g.recorders.count == 1 && g.recorders[0].isRecording == false, "... but after the stop a new call starts nothing while it lasts")
}

// MARK: - About panel text

/// The two names of the app (AppInfo.displayName, AppInfo.shortName): the constants a bare binary falls back to, the rules a declared value must follow (the same
/// as scripts/bundle_id.sh), and that the strings which name the app are built from them. A test that needs the name asserts AppInfo's, never a retyped literal.
private func testAppNames() {
    section("app names: AppInfo.displayName / shortName (fallbacks, the rules of MCAP_APP_NAME and MCAP_APP_SHORT_NAME, strings built from them)")
    check(AppInfo.defaultDisplayName == "Catch Everything" && AppInfo.defaultShortName == "CATE", "the fallbacks of a bare binary are the defaults of scripts/bundle_id.sh")
    check(AppInfo.resolveDisplayName(nil) == AppInfo.defaultDisplayName && AppInfo.resolveDisplayName("") == AppInfo.defaultDisplayName
          && AppInfo.resolveDisplayName("   ") == AppInfo.defaultDisplayName && AppInfo.resolveShortName(nil) == AppInfo.defaultShortName && AppInfo.resolveShortName("") == AppInfo.defaultShortName,
          "no value in Info.plist (a bare binary, a missing key) or an empty one: the default")
    let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    let bundleShort = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
    check(AppInfo.displayName == AppInfo.resolveDisplayName(bundleName) && AppInfo.shortName == AppInfo.resolveShortName(bundleShort),
          "the running app's names are the ones in its Info.plist (the way AppInfo.bundleID is), else the defaults", "\(AppInfo.displayName) / \(AppInfo.shortName)")
    check(AppInfo.resolveDisplayName("Example Recorder") == "Example Recorder" && AppInfo.resolveDisplayName("Rec-1.0 b") == "Rec-1.0 b" && AppInfo.resolveDisplayName("7 Eleven") == "7 Eleven"
          && AppInfo.resolveShortName("ExampleRecorder") == "ExampleRecorder" && AppInfo.resolveShortName("A1") == "A1", "a name that follows the rules is used as it is")
    let longName = String(repeating: "a", count: 40), longShort = String(repeating: "a", count: 32)
    check(AppInfo.resolveDisplayName(longName) == longName && AppInfo.resolveDisplayName(longName + "a") == AppInfo.defaultDisplayName
          && AppInfo.resolveShortName(longShort) == longShort && AppInfo.resolveShortName(longShort + "a") == AppInfo.defaultShortName, "40 and 32 characters are the longest names")
    let badNames = ["Bad&Name", "a<b>", "say \"hi\"", "it's", "a/b", "../x", "-lead", ".lead", " lead", "trail ", "line\nbreak", "50%", "Ünï", "名前", "tab\there"]
    check(badNames.allSatisfy { AppInfo.resolveDisplayName($0) == AppInfo.defaultDisplayName }, "a display name with a quote, an ampersand, angle brackets, a slash, a percent sign, a newline or non-ASCII characters, or that starts with a hyphen, a period or a space, or ends in a space: the default",
          badNames.first { AppInfo.resolveDisplayName($0) != AppInfo.defaultDisplayName } ?? "")
    let badShorts = ["a b", "1x", "a-b", "a.b", "a/b", "../x", "a&b", "a\nb", "Ünï", "-a", " a"]
    check(badShorts.allSatisfy { AppInfo.resolveShortName($0) == AppInfo.defaultShortName }, "a short name with a space, a hyphen, a period, a slash, a newline, non-ASCII characters or a leading digit: the default",
          badShorts.first { AppInfo.resolveShortName($0) != AppInfo.defaultShortName } ?? "")

    // the strings that name the app are built from the two names
    let open = CapturePermissionGuard.openAppPrefix
    check(open == "open -n -W -a ~/Applications/\(AppInfo.shortName).app --stdout \"$(tty)\" --stderr \"$(tty)\" --args" && CapturePermissionGuard.openAppCommand("setup") == open + " setup",
          "the open -n -W -a command hint names <short name>.app", open)
    let promptRefusal = CapturePermissionGuard.promptRefusal(signedAppLaunch: false, env: [:], launch: "x") ?? ""
    check(promptRefusal.contains("signed \(AppInfo.shortName).app") && promptRefusal.contains(open + " setup"), "the permission refusal names the app file and the command", promptRefusal)
    let savedLanguage = L10n.current                      // the later sections rely on the language they were left in
    defer { L10n.current = savedLanguage }
    L10n.current = .en
    let alertEn = FirstRun.alertText().message, movedEn = FirstRun.misplacedText().message
    L10n.current = .ko
    let alertKo = FirstRun.alertText().message, movedKo = FirstRun.misplacedText().message
    L10n.current = .en
    check(alertEn.hasPrefix(AppInfo.displayName) && alertKo.hasPrefix(AppInfo.displayName + " 앱이") && movedEn.contains(AppInfo.displayName) && movedKo.contains(AppInfo.displayName + " 앱을"),
          "the first-run alert and the misplaced notice name the human name (a fixed Korean noun follows it, so any name reads right)", alertKo)
    let tab = TabQueryPolicy.resolve(signedAppLaunch: false, args: [], env: [:]).reason
    check(tab.contains("\(AppInfo.shortName).app") && tab.contains("~/Applications/\(AppInfo.shortName).app"), "the tab-query policy text names the app file", tab)
    let permissionNext = interpretPermission(key: "chrome-automation", status: "denied").next ?? ""
    check(permissionNext.contains(AppInfo.displayName), "the Automation hint names the app the way System Settings lists it", permissionNext)
}

private func testAboutText() {
    section("menu: About <name> (version, optional builder; the name is AppInfo.displayName, none is hard-coded)")
    typealias M = StatusMenuController
    let limit = M.builtByMaxLength

    let none = M.aboutText(version: "0.2.0", builtBy: nil)
    check(none.version == "0.2.0" && none.builtBy == nil && none.credits.isEmpty && none.copyright == M.aboutCopyright,
          "no builder (MCAP_BUILT_BY empty): the version and the copyright only", "\(none)")
    check(M.aboutText(version: "0.2.0", builtBy: "").builtBy == nil && M.aboutText(version: "0.2.0", builtBy: "   \n\t ").builtBy == nil,
          "an empty value and a value of only whitespace and newlines name nobody")

    let set = M.aboutText(version: "0.2.0", builtBy: "Example Team, example.org")
    check(set.builtBy == "Example Team, example.org" && set.credits == "Built by Example Team, example.org" && set.version == "0.2.0",
          "a builder gives the line 'Built by <value>' next to the version", "\(set)")

    check(M.aboutText(version: "0.2.0", builtBy: "  Example Team  \n").credits == "Built by Example Team",
          "leading and trailing spaces and a trailing newline are dropped")
    let multi = M.aboutText(version: "0.2.0", builtBy: "Example\nTeam,\r\n\texample.org\u{0001}").credits
    check(multi == "Built by Example Team, example.org" && !multi.contains("\n") && !multi.contains("\r") && !multi.contains("\t"),
          "newlines, tabs and control characters inside the value become one space (the credits stay one line)", multi)

    let longValue = String(repeating: "a", count: 200)
    let cut = M.normalizedBuiltBy(longValue) ?? ""
    check(cut.count == limit && cut.hasSuffix("\u{2026}") && cut.hasPrefix(String(repeating: "a", count: limit - 1)),
          "a very long value is cut to \(limit) characters and ends in an ellipsis", "\(cut.count) characters")
    check(M.normalizedBuiltBy(String(repeating: "b", count: limit)) == String(repeating: "b", count: limit),
          "exactly \(limit) characters is kept whole")
    check((M.normalizedBuiltBy(String(repeating: "b", count: limit + 1)) ?? "").count == limit, "\(limit + 1) characters is cut")
    check((M.normalizedBuiltBy(String(repeating: "\u{AC00}", count: 100)) ?? "").count == limit, "Korean text is counted in characters, not bytes")
    let atSpace = M.normalizedBuiltBy(String(repeating: "x", count: limit - 2) + " " + String(repeating: "y", count: 10)) ?? ""
    check(atSpace == String(repeating: "x", count: limit - 2) + "\u{2026}", "a cut that lands on a space does not leave a space before the ellipsis", atSpace)
    check(M.normalizedBuiltBy("Example & Co <dev>") == "Example & Co <dev>", "markup characters are plain text")

    check(M.aboutText(version: nil, builtBy: nil).version == "unknown" && M.aboutText(version: "  ", builtBy: nil).version == "unknown", "no version: 'unknown', never an empty line")
    check(M.aboutText(version: " 1.2.3\n", builtBy: nil).version == "1.2.3", "the version is trimmed")

    // The built bundle must agree with this code (it only runs inside the signed app that scripts/build_app.sh made): the copyright line starts with
    // aboutCopyright, and a builder in Info.plist is already in the normalised form that normalizedBuiltBy would produce.
    if let info = Bundle.main.infoDictionary, info["CFBundleExecutable"] != nil {
        check((info["NSHumanReadableCopyright"] as? String)?.hasPrefix(M.aboutCopyright) == true, "Info.plist copyright line starts with the About panel's copyright",
              "\(String(describing: info["NSHumanReadableCopyright"]))")
        if let by = info["MCBuiltBy"] as? String {
            check(M.normalizedBuiltBy(by) == by && (info["NSHumanReadableCopyright"] as? String)?.hasSuffix("Built by \(by)") == true,
                  "the builder in Info.plist is already normalised and is the one named in the copyright line")
        } else {
            check(!((info["NSHumanReadableCopyright"] as? String) ?? "").contains("Built by"), "no MCBuiltBy in Info.plist: the copyright line names no builder")
        }
    }
}

// MARK: - Permission status interpretation

private func testPermissionInterpretation() {
    section("setup: permission status interpretation (unknown strings are WARN, never a silent OK)")
    typealias V = PermissionCheck.Verdict
    let cases: [(String, String, V)] = [
        // microphone (capture owner)
        ("microphone", "authorized", .ok),
        ("microphone", "denied", .fail),
        ("microphone", "restricted", .fail),
        ("microphone", "notDetermined", .fail),
        ("microphone", "ok", .warn),
        ("microphone", "granted", .warn),
        ("microphone", "", .warn),
        ("microphone", "error: refused to trigger macOS permission prompts from a process that is not the signed \(AppInfo.shortName).app", .fail),
        ("microphone", "error: something else", .fail),
        // system audio (capture owner): exactly "ok", failures start with "error" or contain denied / silence
        ("system_audio", "ok", .ok),
        ("system_audio", " OK\n", .ok),
        ("system_audio", "error: callbacks flowed but only digital silence (permission pending or denied; click Allow and re-run setup)", .fail),
        ("system_audio", "error: tap started but no audio callbacks arrived within 15 s (permission dialog still open, or the tap is not delivering)", .fail),
        ("system_audio", "error: refused to trigger macOS permission prompts from a process that is not the signed \(AppInfo.shortName).app", .fail),
        ("system_audio", "permission denied", .fail),
        ("system_audio", "ok but silence", .fail),
        ("system_audio", "granted", .warn),
        ("system_audio", "authorized", .warn),
        ("system_audio", "", .warn),
        ("system_audio", "???", .warn),
        // Chrome automation (detection owner)
        ("chrome-automation", "authorized", .ok),
        ("chrome-automation", "denied", .fail),
        ("chrome-automation", "denied: Automation permission for Google Chrome was refused (System Settings > Privacy & Security > Automation > \(AppInfo.displayName) > Google Chrome)", .fail),
        ("chrome-automation", "denied: the Automation prompt was not answered (run setup again and click OK)", .fail),
        ("chrome-automation", "not-running: open Google Chrome and re-run setup", .warn),
        ("chrome-automation", "refused: not running from \(AppInfo.shortName).app", .fail),
        ("chrome-automation", "denied (-1743: not authorized)", .fail),
        ("chrome-automation", "not-running (Google Chrome is not running)", .warn),
        ("chrome-automation", "not-running", .warn),
        ("chrome-automation", "granted", .warn),
        ("chrome-automation", "", .warn),
        ("chrome-automation", "authorised?", .warn),
        ("chrome-automation", "error: AEDeterminePermissionToAutomateTarget returned -600", .fail),
        // a key from a helper this build does not know
        ("future", "ok", .ok),
        ("future", "error: x", .fail),
        ("future", "maybe", .warn),
    ]
    for (key, status, expected) in cases {
        let c = interpretPermission(key: key, status: status)
        check(c.verdict == expected, "\(key): \"\(status.prefix(48))\" -> \(expected)", "got \(c.verdict): \(c.detail)")
        if expected != .ok {
            check(!(c.next ?? "").isEmpty, "\(key): \"\(status.prefix(30))\" has a next step", "no next step")
        } else {
            check(c.next == nil, "\(key): \"\(status.prefix(30))\" (ok) needs no next step")
        }
    }
    let denied = interpretPermission(key: "chrome-automation", status: "denied")
    check((denied.next ?? "").contains("Automation") && (denied.next ?? "").contains("Google Chrome"), "chrome denied: next step names Automation > Google Chrome", denied.next ?? "nil")
    let sys = interpretPermission(key: "system_audio", status: "error: callbacks flowed but only digital silence")
    check((sys.next ?? "").contains("System Audio Recording") && (sys.next ?? "").contains("run setup again"), "system audio failure: next step names the settings pane and to re-run", sys.next ?? "nil")
    let mic = interpretPermission(key: "microphone", status: "denied")
    check((mic.next ?? "").contains("Microphone"), "microphone denied: next step names Microphone", mic.next ?? "nil")
    let refused = interpretPermission(key: "microphone", status: "error: refused to trigger macOS permission prompts from a process that is not the signed \(AppInfo.shortName).app")
    let openSetup = "open -n -W -a ~/Applications/\(AppInfo.shortName).app --stdout \"$(tty)\" --stderr \"$(tty)\" --args setup"
    check((refused.next ?? "").contains(openSetup), "a refusal (not the signed app) tells how to run setup through the app: open -n -W -a ... --args setup", refused.next ?? "nil")
    let chromeRefused = interpretPermission(key: "chrome-automation", status: "refused: not running from \(AppInfo.shortName).app")
    check((chromeRefused.next ?? "").contains(openSetup), "chrome helper refusal: next step is the same open -n -W -a command", chromeRefused.next ?? "nil")
    // No next-step hint may show the old command without -n (it would hang forever with -W when an instance is running).
    var hints: [String] = []
    for (key, status) in [("microphone", "error: refused"), ("microphone", "error: x"), ("microphone", "denied"), ("microphone", "notDetermined"), ("microphone", "???"),
                          ("system_audio", "error: only digital silence"), ("system_audio", "???"), ("chrome-automation", "denied"), ("chrome-automation", "not-running"),
                          ("chrome-automation", "refused: not running from \(AppInfo.shortName).app"), ("future", "error: x")] {
        hints.append(interpretPermission(key: key, status: status).next ?? "")
    }
    check(!hints.contains { $0.contains("open -W") } && hints.filter { $0.contains("open ") }.allSatisfy { $0.contains("open -n -W -a") },
          "every next-step hint that shows an open command has -n", hints.filter { $0.contains("open ") }.first ?? "")
    for status in ["error: refused", "ERROR: failed", "  error: x", "Error", "error"] {
        let c = interpretPermission(key: "microphone", status: status)
        check(c.verdict == .fail, "microphone: status starting with error (\"\(status)\") is a FAIL, not a WARN", "got \(c.verdict)")
    }
    let notAnswered = interpretPermission(key: "chrome-automation", status: "denied: the Automation prompt was not answered (run setup again and click OK)")
    check((notAnswered.next ?? "").contains("click OK"), "chrome prompt not answered: next step is to click OK", notAnswered.next ?? "nil")
    let nr = interpretPermission(key: "chrome-automation", status: "not-running")
    check((nr.next ?? "").contains("start Google Chrome"), "chrome not running: next step is to start Chrome", nr.next ?? "nil")
}

// MARK: - setup (the whole checklist against fakes)

private func testSetupRun(_ base: URL) {
    section("setup: refuses a non-launchd exec before touching anything; with fakes the checklist and its hints are right")
    let fm = FileManager.default
    let root = base.appendingPathComponent("setup", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let archive = root.appendingPathComponent("archive/Meetings", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try? fm.createDirectory(at: support, withIntermediateDirectories: true)
    try? fm.createDirectory(at: project.appendingPathComponent("pipeline/mcap"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["vocabulary.txt", "note_prompt.md"] { try? "x".write(to: support.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let python = bin.appendingPathComponent("python")
    let claude = bin.appendingPathComponent("claude")
    try? "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try? "#!/bin/sh\necho '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"pro\"}'\n".write(to: claude, atomically: true, encoding: .utf8)
    for url in [python, claude] { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    let configFile = root.appendingPathComponent("config.env")
    try? "SELF_NAME=Tester\n".write(to: configFile, atomically: true, encoding: .utf8)
    setenv("MCAP_CONFIG", configFile.path, 1)             // Setup reads (read-only) the config file named by MCAP_CONFIG
    defer { unsetenv("MCAP_CONFIG") }

    var config = AppConfig.defaults()
    config.supportDir = support
    config.projectDir = project
    config.pythonBin = python
    config.claudeBin = claude
    config.claudeAuth = .subscription                     // this checklist test is about permissions; the default billing mode (api) needs a Keychain item
    config.archiveDir = archive
    config.enabledPlatforms = [.zoom, .teams, .meet]          // Meet is off by default (SPEC 15): the Chrome Automation checks below enable it explicitly

    let calls = Locked(0)
    let chromeCalls = Locked(0)
    func hooks(signed: Bool, env: [String: String] = [:], capture: [String: String], chrome: String,
               notification: NotificationAuthorization = .authorized) -> SetupHooks {
        return SetupHooks(signedAppLaunch: signed, environment: env,
                          capturePermissions: { calls.value += 1; return capture },
                          chromePermission: { calls.value += 1; chromeCalls.value += 1; return chrome },
                          notificationAuthorization: { calls.value += 1; return notification },
                          logDir: logs, echo: false)
    }
    func report() -> String { (try? String(contentsOf: logs.appendingPathComponent("setup-report.txt"), encoding: .utf8)) ?? "" }
    let good = ["microphone": "authorized", "system_audio": "ok"]
    let openSetup = "open -n -W -a ~/Applications/\(AppInfo.shortName).app --stdout \"$(tty)\" --stderr \"$(tty)\" --args setup"

    // 1. a non-launchd exec (the in-bundle binary run from a shell) is refused before anything is touched
    let refused = runSetup(config: config, hooks: hooks(signed: false, capture: good, chrome: "authorized"))
    check(refused == 2, "setup from a non-launchd exec exits 2", "exit \(refused)")
    check(calls.value == 0 && !fm.fileExists(atPath: archive.path) && !fm.fileExists(atPath: logs.path),
          "... without calling any permission helper, creating ARCHIVE_DIR or writing a report", "helper calls \(calls.value)")
    let text = setupRefusal(signedAppLaunch: false, env: [:], launch: "bundle id \(AppInfo.bundleID), parent pid 4242, __CFBundleIdentifier com.apple.Terminal") ?? ""
    check(text.contains(openSetup) && text.contains("parent pid 4242") && text.contains("Google Drive"),
          "the refusal text shows the open -n -W -a command, why, and what would be misattributed", text)
    check(setupRefusal(signedAppLaunch: true, env: [:]) == nil && setupRefusal(signedAppLaunch: false, env: ["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY": "1"]) == nil,
          "a launchd / LaunchServices start (or the explicit developer override) is allowed")

    // 2. everything good: exit 0, no WARN / FAIL, the next step is the live self-test with the right command
    let allOK = runSetup(config: config, hooks: hooks(signed: true, capture: good, chrome: "authorized"))
    var rep = report()
    check(allOK == 0 && calls.value == 3 && !rep.contains("[FAIL]") && !rep.contains("[WARN]") && rep.contains("Setup complete: all checks passed."),
          "all fakes good (Meet enabled): exit 0, all three helpers called (capture, Chrome, notifications), no [FAIL] / [WARN]", "exit \(allOK)\n\(rep)")
    check(rep.contains("[ OK ] notifications"), "the notification permission is reported as OK when allowed", rep)
    check(rep.contains("open -n -W -a ~/Applications/\(AppInfo.shortName).app --stdout \"$(tty)\" --stderr \"$(tty)\" --args selftest-capture --live --seconds 12"),
          "a successful setup points to the live self-test with open -n -W -a ... --args selftest-capture --live")
    check(fm.fileExists(atPath: archive.path), "ARCHIVE_DIR (temp) was created and probed")

    // 3. failures: statuses of every kind, hints with the command
    let bad = runSetup(config: config, hooks: hooks(signed: true,
                                                    capture: ["microphone": "error: something odd", "system_audio": "error: callbacks flowed but only digital silence"],
                                                    chrome: "denied: Automation permission for Google Chrome was refused"))
    rep = report()
    check(bad == 1 && rep.components(separatedBy: "[FAIL]").count - 1 == 3, "microphone 'error: ...', silent system audio and denied Chrome are three [FAIL]s, exit 1", "exit \(bad)\n\(rep)")
    check(rep.contains("[FAIL] permission microphone"), "a microphone status starting with 'error' is a FAIL (not a WARN)")
    check(rep.contains("To run setup again: \(openSetup)") && !rep.contains("open -W"), "the report ends with the open -n -W -a command to run setup again (never the old command without -n)")
    let warn = runSetup(config: config, hooks: hooks(signed: true, capture: ["microphone": "???", "system_audio": "ok"], chrome: "not-running: open Google Chrome and re-run setup"))
    rep = report()
    check(warn == 1 && rep.contains("[WARN] permission microphone") && rep.contains("[WARN] permission chrome-automation") && !rep.contains("Setup complete"),
          "unrecognized or unverifiable statuses are WARNs and never give exit 0", "exit \(warn)")
    let refusedStatus = runSetup(config: config, hooks: hooks(signed: true, capture: ["microphone": "error: refused to trigger macOS permission prompts", "system_audio": "error: refused to trigger macOS permission prompts"], chrome: "refused: not running from \(AppInfo.shortName).app"))
    rep = report()
    check(refusedStatus == 1 && rep.components(separatedBy: "next: run setup through LaunchServices").count - 1 == 3 && rep.contains(openSetup),
          "if a helper still reports a refusal, its next step is the open -n -W -a command (3 of 3)", "exit \(refusedStatus)")
    let overridden = runSetup(config: config, hooks: hooks(signed: false, env: ["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY": "1"], capture: good, chrome: "authorized"))
    check(overridden == 0, "the explicit developer override lets setup run from another host", "exit \(overridden)")

    // 4. SPEC 15: Meet is off by default: the Chrome Automation step is skipped (the helper is never called), and says why
    var noMeet = config
    noMeet.enabledPlatforms = AppConfig.defaults().enabledPlatforms
    check(noMeet.enabledPlatforms == [.zoom, .teams], "(the default platforms really are zoom,teams)")
    calls.value = 0; chromeCalls.value = 0
    let skipped = runSetup(config: noMeet, hooks: hooks(signed: true, capture: good, chrome: "denied: this must never be asked"))
    rep = report()
    check(skipped == 0 && chromeCalls.value == 0 && calls.value == 2, "Meet not enabled: the Chrome Automation helper is never called, setup still exits 0",
          "exit \(skipped), chrome calls \(chromeCalls.value), helper calls \(calls.value)\n\(rep)")
    check(rep.contains("skipped: meet not enabled") && !rep.contains("chrome-automation: denied") && !rep.contains("[FAIL]") && !rep.contains("[WARN]"),
          "... and the report says 'skipped: meet not enabled' (no FAIL, no WARN)", rep)
    calls.value = 0; chromeCalls.value = 0
    var onlyMeet = config
    onlyMeet.enabledPlatforms = [.meet]
    _ = runSetup(config: onlyMeet, hooks: hooks(signed: true, capture: good, chrome: "authorized"))
    check(chromeCalls.value == 1 && !report().contains("skipped: meet not enabled") && report().contains("[ OK ] permission chrome-automation"),
          "Meet enabled: the Chrome Automation helper is called once and reported", report())

    // 5. SPEC 15: notification permission is OK or WARN, never FAIL
    typealias NA = NotificationAuthorization
    let notificationCases: [(NA, Bool, String)] = [(.authorized, true, "allowed"), (.denied, false, "denied"), (.notDetermined, false, "not answered"),
                                                   (.unavailable("only the signed app can ask"), false, "unavailable")]
    for (status, isOK, name) in notificationCases {
        let code = runSetup(config: noMeet, hooks: hooks(signed: true, capture: good, chrome: "authorized", notification: status))
        rep = report()
        check(!rep.contains("[FAIL] notifications"), "notifications \(name): never a [FAIL]", rep)
        if isOK {
            check(code == 0 && rep.contains("[ OK ] notifications"), "notifications \(name): [ OK ] and exit 0", "exit \(code)\n\(rep)")
        } else {
            check(code == 1 && rep.contains("[WARN] notifications") && rep.contains("Setup finished with 1 warning(s)"),
                  "notifications \(name): [WARN] (exit 1 like every WARN) with a next step", "exit \(code)\n\(rep)")
            let c = interpretNotificationAuthorization(status)
            check(c.verdict == .warn && !(c.next ?? "").isEmpty && c.detail.contains("menu"), "notifications \(name): the WARN says what is lost and what to do", "\(c)")
        }
    }
    check(interpretNotificationAuthorization(.denied).next?.contains("System Settings > Notifications") == true, "denied: the next step names System Settings > Notifications")
    check(interpretNotificationAuthorization(.unavailable("x")).next?.contains("open -n -W -a") == true, "unavailable: the next step is the open -n -W -a command")
    // a shell exec never reaches the real notification center: the default hook answers .unavailable. (Not evaluated when this
    // self-test itself runs as the signed app: that would show the macOS prompt.)
    if !LaunchGuard.isSignedAppLaunch {
        check(Notifier().requestAuthorization(timeout: 1) == .unavailable("only the signed \(AppInfo.shortName).app started by launchd / LaunchServices can ask"),
              "outside the signed app the default notification hook answers 'unavailable' without touching macOS")
    }
}

// =====================================================================================
// SPEC 17: Claude billing mode (subscription | api)
// =====================================================================================

// MARK: - Fake Keychain tool

/// Stands for an API key. Nothing in this self-test ever handles a key; this canary is built from pieces so that a secret scanner does
/// not mistake the source for a leaked key. It must never show up in a report, a log or an argv.
private let canaryKey = "sk-" + "ant-api03-" + "CANARY-" + String(repeating: "0", count: 32)

private let fakeSecurityScript = #"""
#!/bin/sh
# Fake /usr/bin/security for selftest-session (selected through MCAP_SECURITY_BIN). Records its arguments in calls.log; the file `mode`
# says what it answers. Asked for the secret (an argument starting with -w or -g) it would print the canary key: it also writes
# SECRET-READ-ATTEMPT, and the self-test fails if that line ever appears.
D="$(cd "$(dirname "$0")" && pwd)"
echo "ARGV: $*" >> "$D/calls.log"
for a in "$@"; do
  case "$a" in
    -w*|-g*) echo "SECRET-READ-ATTEMPT: $*" >> "$D/calls.log"; echo "@CANARY@"; echo "password: \"@CANARY@\"" >&2; exit 0 ;;
  esac
done
case "$(cat "$D/mode" 2>/dev/null || echo missing)" in
  exists) echo 'keychain: "/fake/login.keychain-db"'; echo 'class: "genp"'; exit 0 ;;
  noisy-exists) echo "@CANARY@"; echo "@CANARY@" >&2; exit 0 ;;
  noisy-missing) echo "@CANARY@"; echo "@CANARY@" >&2; exit 44 ;;
  error) echo "security: something odd" >&2; exit 36 ;;
  *) echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44 ;;
esac
"""#

private struct FakeSecurityTool {
    let dir: URL
    var bin: URL { dir.appendingPathComponent("security") }

    static func install(in base: URL) -> FakeSecurityTool {
        let fm = FileManager.default
        let tool = FakeSecurityTool(dir: base.appendingPathComponent("fake-security", isDirectory: true))
        try? fm.createDirectory(at: tool.dir, withIntermediateDirectories: true)
        try? fakeSecurityScript.replacingOccurrences(of: "@CANARY@", with: canaryKey).write(to: tool.bin, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.bin.path)
        tool.setMode("missing")
        return tool
    }

    func setMode(_ mode: String) { try? mode.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }

    /// Every line the shim recorded so far: "ARGV: ..." per call, "SECRET-READ-ATTEMPT: ..." if it was ever asked for the secret.
    var calls: [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: { $0.isNewline }).map(String.init)
    }
}

/// Set by runSelftestSession for the whole run.
private var fakeSecurityTool: FakeSecurityTool?

/// A ToolRunner that records every call and answers with a fixed result (nil = "could not be started").
private final class FakeToolRunner {
    private(set) var calls: [(exe: URL, args: [String])] = []
    var result: ToolResult?
    init(_ result: ToolResult?) { self.result = result }
    func run(_ exe: URL, _ args: [String]) -> ToolResult? {
        calls.append((exe, args))
        return result
    }
}

private extension AppConfig {
    func withAuth(_ mode: ClaudeAuthMode) -> AppConfig { var c = self; c.claudeAuth = mode; return c }
}

// MARK: - Setup: Claude billing

private func testClaudeBilling(_ base: URL) {
    section("claude billing (SPEC 17): subscription as before; api only asks the Keychain whether the item exists")
    guard let shim = fakeSecurityTool else { check(false, "the fake Keychain tool is installed"); return }
    let fm = FileManager.default
    let root = base.appendingPathComponent("billing", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    let archive = root.appendingPathComponent("archive/Meetings", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try? fm.createDirectory(at: support, withIntermediateDirectories: true)
    try? fm.createDirectory(at: project.appendingPathComponent("pipeline/mcap"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["vocabulary.txt", "note_prompt.md"] { try? "x".write(to: support.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let python = bin.appendingPathComponent("python")
    let claude = bin.appendingPathComponent("claude")
    try? "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    /// What `claude auth status` prints (a shell snippet).
    func setClaudeStatus(_ body: String) {
        try? "#!/bin/sh\n\(body)\n".write(to: claude, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    }
    let loggedIn = "echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"pro\"}'"
    setClaudeStatus(loggedIn)
    let configFile = root.appendingPathComponent("config.env")
    try? "SELF_NAME=Tester\n".write(to: configFile, atomically: true, encoding: .utf8)
    setenv("MCAP_CONFIG", configFile.path, 1)
    defer { unsetenv("MCAP_CONFIG") }

    var subscription = AppConfig.defaults()
    subscription.claudeAuth = .subscription               // the default is api; this one is the opt-in mode
    subscription.supportDir = support
    subscription.projectDir = project
    subscription.pythonBin = python
    subscription.claudeBin = claude
    subscription.archiveDir = archive
    subscription.enabledPlatforms = [.zoom, .teams]           // no Chrome step
    let api = subscription.withAuth(.api)
    let service = AppConfig.defaults().claudeKeychainService
    let user = NSUserName()
    let fakeBin = URL(fileURLWithPath: "/fake/bin/security")

    let good = ["microphone": "authorized", "system_audio": "ok"]
    func hooks(_ runner: FakeToolRunner?) -> SetupHooks {
        var h = SetupHooks(signedAppLaunch: true, environment: [:], capturePermissions: { good }, chromePermission: { "authorized" },
                           notificationAuthorization: { .authorized }, logDir: logs, echo: false)
        h.policy = OrgPolicy.absent()                                  // a personal install, whatever this Mac has in /Library
        if let fake = runner { h.securityBin = fakeBin; h.runSecurity = fake.run }
        return h
    }
    func report() -> String { (try? String(contentsOf: logs.appendingPathComponent("setup-report.txt"), encoding: .utf8)) ?? "" }
    func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }
    var allArgv: [[String]] = []          // every argument list any fake runner saw: asserted at the end
    func run(_ config: AppConfig, _ runner: FakeToolRunner?) -> (code: Int32, report: String) {
        let code = runSetup(config: config, hooks: hooks(runner))
        if let fake = runner { allArgv += fake.calls.map { $0.args } }
        return (code, report())
    }
    let itemAttributes: ToolResult = (0, "keychain: \"/fake/login.keychain-db\"\nclass: \"genp\"\n", "")
    let notFound: ToolResult = (ApiKeyItem.itemNotFoundStatus, "", "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n")

    // ---- api mode, item exists ----
    let exists = FakeToolRunner(itemAttributes)
    var r = run(api, exists)
    check(r.code == 0 && r.report.contains("[ OK ] claude billing: API key in the Keychain (Console credits): item \(service)"),
          "api, item exists: [ OK ] 'API key in the Keychain (Console credits): item <service>' and exit 0", "exit \(r.code)\n\(r.report)")
    check(!r.report.contains("[FAIL]") && !r.report.contains("[WARN]") && r.report.contains("Setup complete: all checks passed."), "... no FAIL, no WARN, setup complete")
    check(exists.calls.count == 1 && exists.calls[0].exe == fakeBin && exists.calls[0].args == ["find-generic-password", "-s", service, "-a", user],
          "the lookup is exactly `security find-generic-password -s <service> -a <user>` (one call)", "\(exists.calls.map { $0.args })")
    check(r.report.contains("[ -- ] calendar lookup: the Google Calendar title lookup keeps using the claude.ai login, not the API key"),
          "api mode says that the Calendar title lookup keeps using the claude.ai login")
    check(r.report.contains("[ -- ] claude.ai login: logged in (pro), used for the Calendar title lookup only"), "... and reports the claude.ai login state as an informational [ -- ] line", r.report)
    check(!r.report.contains("subscription via claude.ai login"), "api mode does not print the subscription billing line")

    // ---- api mode, item missing / security error / security not startable ----
    let missing = FakeToolRunner(notFound)
    r = run(api, missing)
    check(r.code == 1 && r.report.contains("[FAIL] claude billing: no API key in the Keychain item \(service)\n"),
          "api, item missing (security exit 44): [FAIL] 'no API key in the Keychain item <service>', exit 1", "exit \(r.code)\n\(r.report)")
    check(r.report.contains("       next: make set-api-key\n       then: python -m mcap api-key check\n"), "... with next: 'make set-api-key' and then: 'python -m mcap api-key check'", r.report)
    check(count("[FAIL]", in: r.report) == 1 && r.report.contains("[ -- ] claude.ai login: logged in"), "... that is the only FAIL; the claude.ai login line is still informational")
    check(r.report.contains("Setup incomplete: 1 check(s) failed"), "... the report ends as incomplete")

    let odd = FakeToolRunner((36, "", "security: something odd\n"))
    r = run(api, odd)
    check(r.code == 1 && r.report.contains("[FAIL] claude billing: no API key in the Keychain item \(service) (security exited with status 36, so the item could not be confirmed)")
            && r.report.contains("next: make set-api-key"), "api, security exits 36: [FAIL] 'no API key ...' with the exit status, same next step", r.report)
    let one = FakeToolRunner((1, "", ""))
    r = run(api, one)
    check(r.code == 1 && r.report.contains("[FAIL] claude billing: no API key in the Keychain item \(service) (security exited with status 1"), "api, any non-zero status is a FAIL", r.report)

    let notRun = FakeToolRunner(nil)
    r = run(api, notRun)
    check(r.code == 1 && r.report.contains("[FAIL] claude billing: cannot check the Keychain item \(service): could not run /fake/bin/security")
            && r.report.contains("next: make sure /usr/bin/security exists and runs"), "api, security cannot be started: [FAIL] with a next step", r.report)

    // ---- api mode: the claude.ai login is information only, whatever it says ----
    for (name, body, expected) in [("another auth method", "echo '{\"loggedIn\":true,\"authMethod\":\"api_key\"}'", "authMethod is 'api_key', not claude.ai"),
                                   ("not logged in / unreadable", "echo 'Not logged in' >&2; exit 1", "not logged in or not readable"),
                                   ("garbage", "echo '???'", "not logged in or not readable"),
                                   ("claude.ai without a subscription type", "echo '{\"authMethod\":\"claude.ai\"}'", "[ -- ] claude.ai login: logged in, used for the Calendar title lookup only")] {
        setClaudeStatus(body)
        r = run(api, FakeToolRunner(itemAttributes))
        check(r.code == 0 && r.report.contains(expected) && r.report.contains("[ -- ] claude.ai login") && !r.report.contains("[FAIL]") && !r.report.contains("[WARN]"),
              "api: claude.ai login '\(name)' is a [ -- ] line, never FAIL or WARN (exit 0)", "exit \(r.code)\n\(r.report)")
    }
    setClaudeStatus(loggedIn)

    // ---- api mode without a claude binary, personal install (no policy): WARN for the CLI (audio and transcripts work without it), the Keychain is still checked ----
    var noClaude = api
    noClaude.claudeBin = bin.appendingPathComponent("no-such-claude")
    let stillAsked = FakeToolRunner(itemAttributes)
    r = run(noClaude, stillAsked)
    check(r.code == 1 && r.report.contains("[WARN] claude CLI: not found or not executable") && r.report.contains("audio and transcripts do not") && !r.report.contains("[FAIL]")
            && r.report.contains("[ OK ] claude billing: API key in the Keychain") && r.report.contains("[ -- ] claude.ai login: not checked") && stillAsked.calls.count == 1,
          "personal install, api without the claude CLI: [WARN] claude CLI (no [FAIL]), the Keychain item is still checked, the login line says 'not checked'", "exit \(r.code)\n\(r.report)")

    // ---- subscription mode: exactly as before, never touches the Keychain ----
    let never = FakeToolRunner(itemAttributes)
    r = run(subscription, never)
    check(r.code == 0 && r.report.contains("[ OK ] claude billing: subscription via claude.ai login (pro)") && !r.report.contains("[FAIL]") && !r.report.contains("[WARN]"),
          "subscription: [ OK ] 'subscription via claude.ai login (pro)', exit 0", "exit \(r.code)\n\(r.report)")
    check(never.calls.isEmpty, "subscription mode never calls the Keychain tool")
    check(!r.report.contains("calendar lookup") && !r.report.contains("Keychain"), "subscription mode prints no api-mode lines")
    setClaudeStatus("echo '{\"loggedIn\":true,\"authMethod\":\"api_key\"}'")
    r = run(subscription, never)
    check(r.code == 1 && r.report.contains("[FAIL] claude billing: WARNING: authMethod is 'api_key', which bills API credits, not your subscription."), "subscription with another auth method: still FAIL as before", r.report)
    setClaudeStatus("echo 'nothing useful'; exit 1")
    r = run(subscription, never)
    check(r.code == 1 && r.report.contains("[WARN] claude auth: could not read authMethod from `claude auth status` (exit 1). Run `claude auth login`.") && !r.report.contains("[FAIL]"),
          "personal install, subscription, unreadable status: [WARN], no [FAIL] (audio and transcripts do not need it)", r.report)
    r = run(noClaude.withAuth(.subscription), never)
    check(r.code == 1 && r.report.contains("[WARN] claude CLI: not found or not executable") && !r.report.contains("[FAIL]") && never.calls.isEmpty,
          "personal install, subscription without the claude CLI: [WARN], no [FAIL], the Keychain is not touched")
    setClaudeStatus(loggedIn)

    // ---- LOCAL_ONLY_DEFAULT=1 (every new meeting starts Local-Only, no Claude call): a missing or logged-out claude is a [WARN], never a [FAIL]
    //      (`make confirm-live-tested` refuses a report with [FAIL], so a transcript-only user could never switch on automatic start) ----
    try? "SELF_NAME=Tester\nLOCAL_ONLY_DEFAULT=1\n".write(to: configFile, atomically: true, encoding: .utf8)
    r = run(noClaude.withAuth(.subscription), never)
    check(r.code == 1 && r.report.contains("[WARN] claude CLI: not found or not executable") && r.report.contains("audio and transcripts do not") && !r.report.contains("[FAIL]"),
          "LOCAL_ONLY_DEFAULT=1, subscription without the claude CLI: [WARN] with the reason, no [FAIL]", "exit \(r.code)\n\(r.report)")
    setClaudeStatus("echo 'nothing useful'; exit 1")
    r = run(subscription, never)
    check(r.code == 1 && r.report.contains("[WARN] claude auth: could not read authMethod from `claude auth status` (exit 1)") && !r.report.contains("[FAIL]"),
          "LOCAL_ONLY_DEFAULT=1, subscription, unreadable `claude auth status`: [WARN], no [FAIL]", "exit \(r.code)\n\(r.report)")
    setClaudeStatus("echo '{\"loggedIn\":true,\"authMethod\":\"api_key\"}'")
    r = run(subscription, never)
    check(r.code == 1 && r.report.contains("[FAIL] claude billing: WARNING: authMethod is 'api_key'"), "LOCAL_ONLY_DEFAULT=1: the 'bills API credits' mismatch is still a [FAIL]", r.report)
    setClaudeStatus(loggedIn)
    let stillAskedLocal = FakeToolRunner(itemAttributes)
    r = run(noClaude, stillAskedLocal)
    check(r.code == 1 && r.report.contains("[WARN] claude CLI: not found or not executable") && r.report.contains("[ OK ] claude billing: API key in the Keychain") && !r.report.contains("[FAIL]") && stillAskedLocal.calls.count == 1,
          "LOCAL_ONLY_DEFAULT=1, api without the claude CLI: [WARN] for the CLI, the Keychain item is still checked", "exit \(r.code)\n\(r.report)")
    // LOCAL_ONLY_DEFAULT=1 and api: a missing API key item is a [WARN] too (no Claude call is made unless a meeting is switched to non-local)
    let keyMissingLocal = FakeToolRunner(notFound)
    r = run(api, keyMissingLocal)
    check(r.code == 1 && r.report.contains("[WARN] claude billing: no API key in the Keychain item \(service)") && r.report.contains("next: make set-api-key") && !r.report.contains("[FAIL]"),
          "LOCAL_ONLY_DEFAULT=1, api, no API key item: [WARN] with the next step, no [FAIL]", "exit \(r.code)\n\(r.report)")
    try? "SELF_NAME=Tester\n".write(to: configFile, atomically: true, encoding: .utf8)
    r = run(api, FakeToolRunner(notFound))
    check(r.code == 1 && r.report.contains("[FAIL] claude billing: no API key in the Keychain item \(service)"), "without LOCAL_ONLY_DEFAULT a missing API key item is still a [FAIL] (the default is api, the key is the next step)", r.report)

    // ---- a misspelt CLAUDE_AUTH: the app reads it as subscription (never api), the pipeline refuses every Claude call: setup must say so ----
    for typo in ["apikey", "api-key", "API KEY", "bedrock", "true", "1"] {
        try? "SELF_NAME=Tester\nCLAUDE_AUTH=\(typo)   # typo\n".write(to: configFile, atomically: true, encoding: .utf8)
        let untouched = FakeToolRunner(itemAttributes)
        r = run(subscription, untouched)               // what the app makes of the typo (AppConfig.load: subscription), on the temp dirs
        check(r.code == 1 && r.report.contains("[FAIL] claude billing: CLAUDE_AUTH=\(typo) in config.env is neither 'subscription' nor 'api': the pipeline makes no Claude call")
                && r.report.contains("       next: fix CLAUDE_AUTH in \(configFile.path), then run setup again")
                && !r.report.contains("[ OK ] claude billing") && !r.report.contains("[ -- ] calendar lookup") && untouched.calls.isEmpty,
              "CLAUDE_AUTH='\(typo)': setup FAILs the billing line with the fix, says nothing else about billing, never asks the Keychain", "exit \(r.code)\n\(r.report)")
        check(invalidClaudeAuthSetting(configFile: configFile) == typo, "invalidClaudeAuthSetting reports '\(typo)'")
    }
    for fine in ["api", "API", "Api", "subscription", "SUBSCRIPTION", ""] {
        try? "SELF_NAME=Tester\nCLAUDE_AUTH=\(fine)\n".write(to: configFile, atomically: true, encoding: .utf8)
        check(invalidClaudeAuthSetting(configFile: configFile) == nil, "CLAUDE_AUTH='\(fine)' is not reported as invalid")
    }
    try? "SELF_NAME=Tester\n".write(to: configFile, atomically: true, encoding: .utf8)
    check(invalidClaudeAuthSetting(configFile: configFile) == nil && invalidClaudeAuthSetting(configFile: root.appendingPathComponent("no-such.env")) == nil,
          "no CLAUDE_AUTH line, or no config file: nothing to report")
    r = run(subscription, FakeToolRunner(itemAttributes))
    check(r.code == 0 && r.report.contains("[ OK ] claude billing: subscription via claude.ai login (pro)"), "after the fix the normal subscription line is back")

    // ---- awkward service names can never turn into an option ----
    for bad in ["-w", "-g", "--help", "-wx", "-s"] {
        var c = api
        c.claudeKeychainService = bad
        let refused = FakeToolRunner(itemAttributes)
        r = run(c, refused)
        check(refused.calls.isEmpty && r.code == 1 && r.report.contains("[FAIL] claude billing: cannot check the Keychain item \(bad): the Keychain service name or the user name is empty or starts with '-'"),
              "CLAUDE_KEY_SERVICE='\(bad)' is refused before any tool is run", "calls \(refused.calls.map { $0.args })\n\(r.report)")
    }
    var spaced = api
    spaced.claudeKeychainService = "My Item - v2 (api)"
    let spacedRunner = FakeToolRunner(itemAttributes)
    r = run(spaced, spacedRunner)
    check(spacedRunner.calls.first?.args == ["find-generic-password", "-s", "My Item - v2 (api)", "-a", user] && r.code == 0,
          "a service name with spaces, dashes and parentheses is passed as one argument", "\(spacedRunner.calls.map { $0.args })")

    // ---- pure pieces ----
    check(ApiKeyItem.existenceArguments(service: "S", account: "u") == ["find-generic-password", "-s", "S", "-a", "u"], "existenceArguments: find-generic-password -s S -a u")
    check(ApiKeyItem.existenceArguments(service: "", account: "u") == nil && ApiKeyItem.existenceArguments(service: "S", account: "") == nil, "existenceArguments: empty values are refused")
    check(ApiKeyItem.existenceArguments(service: "-w", account: "u") == nil && ApiKeyItem.existenceArguments(service: "S", account: "-g") == nil, "existenceArguments: a value starting with '-' is refused")
    check(ApiKeyItem.securityBinary(env: [:]).path == "/usr/bin/security", "the Keychain tool defaults to /usr/bin/security")
    check(ApiKeyItem.securityBinary(env: ["MCAP_SECURITY_BIN": "/tmp/shim/security"]).path == "/tmp/shim/security", "MCAP_SECURITY_BIN selects a shim")
    check(ApiKeyItem.securityBinary(env: ["MCAP_SECURITY_BIN": "security"]).path == "/usr/bin/security" && ApiKeyItem.securityBinary(env: ["MCAP_SECURITY_BIN": ""]).path == "/usr/bin/security",
          "a relative or empty MCAP_SECURITY_BIN is ignored")
    check(SetupHooks().securityBin.path == shim.bin.path, "this self-test points the default hook at the fake tool (so no test can reach the real Keychain)", SetupHooks().securityBin.path)

    let okCheck = interpretApiKeyItem(.exists, service: "S")
    check(okCheck.verdict == .ok && okCheck.detail == "API key in the Keychain (Console credits): item S" && okCheck.next == nil && okCheck.then == nil, "interpret: exists -> OK", "\(okCheck)")
    let missingCheck = interpretApiKeyItem(.missing(status: 44), service: "S")
    check(missingCheck.verdict == .fail && missingCheck.detail == "no API key in the Keychain item S" && missingCheck.next == "make set-api-key" && missingCheck.then == "python -m mcap api-key check",
          "interpret: missing (44) -> FAIL with next and then", "\(missingCheck)")
    for status: Int32 in [1, 36, 51, 128, 255] {
        let c = interpretApiKeyItem(.missing(status: status), service: "S")
        check(c.verdict == .fail && c.detail.hasPrefix("no API key in the Keychain item S") && c.detail.contains("status \(status)") && c.next == "make set-api-key",
              "interpret: security exit \(status) -> FAIL (unconfirmed)", "\(c)")
    }
    let notRunCheck = interpretApiKeyItem(.notRun("could not run x"), service: "S")
    check(notRunCheck.verdict == .fail && notRunCheck.detail.contains("could not run x") && !(notRunCheck.next ?? "").isEmpty, "interpret: not run -> FAIL with a next step", "\(notRunCheck)")

    let jsonStatus = parseClaudeAuthStatus("{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"pro\"}")
    check(jsonStatus.method == "claude.ai" && jsonStatus.subscription == "pro", "parseClaudeAuthStatus: JSON")
    check(parseClaudeAuthStatus("{\"authMethod\":\"api_key\"}").method == "api_key" && parseClaudeAuthStatus("{\"authMethod\":\"api_key\"}").subscription == nil, "parseClaudeAuthStatus: JSON without a subscription")
    check(parseClaudeAuthStatus("Login method: x\nauthMethod: claude.ai\n").method == "claude.ai" && parseClaudeAuthStatus("authMethod=console").method == "console", "parseClaudeAuthStatus: loose text")
    check(parseClaudeAuthStatus("Not logged in").method == nil && parseClaudeAuthStatus("").method == nil && parseClaudeAuthStatus("{}").method == nil, "parseClaudeAuthStatus: nothing readable -> nil")

    // ---- a hostile tool that prints a key: nothing it writes reaches the report, the report file or app.log ----
    let noisy: ToolResult = (0, canaryKey + "\n", "password: \"" + canaryKey + "\"\n")
    let noisyMissing: ToolResult = (ApiKeyItem.itemNotFoundStatus, canaryKey + "\n", canaryKey + "\n")
    r = run(api, FakeToolRunner(noisy))
    let r2 = run(api, FakeToolRunner(noisyMissing))
    check(r.code == 0 && r2.code == 1 && !r.report.contains(canaryKey) && !r2.report.contains(canaryKey) && !r.report.contains("sk-ant") && !r2.report.contains("sk-ant"),
          "a tool that prints a key (stdout and stderr) does not get it into the setup report", "\(r.report)\n\(r2.report)")
    check(!logText().contains(canaryKey), "... nor into app.log")

    // ---- the default runner against the fake tool script (selected by MCAP_SECURITY_BIN): the real Process path, argv recorded by the script ----
    func viaShim(_ mode: String) -> (code: Int32, report: String) {
        shim.setMode(mode)
        let code = runSetup(config: api, hooks: SetupHooks(signedAppLaunch: true, environment: [:], capturePermissions: { good }, chromePermission: { "authorized" },
                                                           notificationAuthorization: { .authorized }, logDir: logs, echo: false))
        return (code, report())
    }
    let callsBefore = shim.calls.count
    let sExists = viaShim("exists")
    let sMissing = viaShim("missing")
    let sError = viaShim("error")
    let sNoisyOK = viaShim("noisy-exists")
    let sNoisyMissing = viaShim("noisy-missing")
    check(sExists.code == 0 && sExists.report.contains("[ OK ] claude billing: API key in the Keychain (Console credits): item \(service)"),
          "default runner + fake tool, item exists: OK", "exit \(sExists.code)\n\(sExists.report)")
    check(sMissing.code == 1 && sMissing.report.contains("[FAIL] claude billing: no API key in the Keychain item \(service)\n") && sMissing.report.contains("next: make set-api-key"),
          "default runner + fake tool, exit 44: FAIL with the next step", sMissing.report)
    check(sError.code == 1 && sError.report.contains("security exited with status 36"), "default runner + fake tool, exit 36: FAIL with the status", sError.report)
    check(sNoisyOK.code == 0 && sNoisyMissing.code == 1, "default runner + a tool that prints a key: only the exit status decides", "\(sNoisyOK.code) \(sNoisyMissing.code)")
    check(![sExists, sMissing, sError, sNoisyOK, sNoisyMissing].contains { $0.report.contains(canaryKey) || $0.report.contains("sk-ant") || $0.report.contains("CANARY") },
          "... the key the tool printed never appears in the report file")
    let newCalls = Array(shim.calls.dropFirst(callsBefore))
    let expectedLine = "ARGV: find-generic-password -s \(service) -a \(user)"
    check(newCalls.count == 5 && newCalls.allSatisfy { $0 == expectedLine }, "the fake tool script received exactly `find-generic-password -s <service> -a <user>` five times", "\(newCalls)")
    check(!shim.calls.contains { $0.hasPrefix("SECRET-READ-ATTEMPT") }, "the fake tool script was never asked for the secret (-w / -g)")
    shim.setMode("missing")

    // ---- no code path passes -w or -g (the argument lists the fake runners recorded) ----
    func asksForSecret(_ args: [String]) -> Bool { args.contains { $0.hasPrefix("-w") || $0.hasPrefix("-g") } }
    check(allArgv.count >= 9 && !allArgv.contains(where: asksForSecret), "no recorded `security` call ever carries -w or -g", "\(allArgv.count) calls recorded")
    check(allArgv.allSatisfy { $0.first == "find-generic-password" && $0.count == 5 && $0[1] == "-s" && $0[3] == "-a" && $0[4] == user },
          "every recorded call is `find-generic-password -s <service> -a <user>` and nothing else")
}

/// Runs last: over the whole self-test run the fake Keychain tool only ever saw existence lookups.
private func testFakeSecurityNeverAskedForSecret() {
    section("the fake Keychain tool saw only existence lookups during the whole self-test")
    guard let shim = fakeSecurityTool else { check(false, "the fake Keychain tool is installed"); return }
    let lines = shim.calls
    let argv = lines.filter { $0.hasPrefix("ARGV: ") }
    check(argv.count >= 5, "the tool was really used (so this check is not vacuous)", "\(argv.count) calls")
    check(!lines.contains { $0.hasPrefix("SECRET-READ-ATTEMPT") }, "nothing ever asked it for the secret (-w / -g)", lines.first { $0.hasPrefix("SECRET-READ-ATTEMPT") } ?? "")
    check(argv.allSatisfy { $0.hasPrefix("ARGV: find-generic-password -s ") && $0.contains(" -a ") }, "every call was a find-generic-password existence lookup",
          argv.first { !$0.hasPrefix("ARGV: find-generic-password -s ") } ?? "")
    check(!argv.contains { line in line.split(separator: " ").contains { $0 == "-w" || $0 == "-g" } }, "no call had -w or -g among its arguments")
    check(!logText().contains(canaryKey) && !logText().contains("sk-ant"), "app.log of the whole run contains no key")
}

// =====================================================================================
// SPEC 15: no-speech auto-stop, notifications, retry sweep, awake-time watchdog
// =====================================================================================

// MARK: - No-speech auto-stop

private func testNoSpeechAutoStop(_ base: URL) {
    section("no-speech auto-stop (SPEC 15): both tracks below -70 dBFS for NO_SPEECH_STOP_MINUTES while the call is detected")
    let zoom = zoomSignal()
    let fm = FileManager.default

    // A: a long silence ends an AUTO recording gracefully; the same meeting is not restarted until detection goes false once.
    let h = Harness("nospeech", in: base)
    check(h.config.noSpeechStopMinutes == 15, "the harness uses the default of 15 minutes")
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [zoom])
    guard let rec = h.current else { check(false, "recording started"); return }
    rec.levels = (-85, -120)                       // quiet room on the mic, digital silence on the system audio
    h.run(14 * 60, [zoom])
    check(rec.isRecording && rec.stopReasons.isEmpty && h.state.notice == nil, "14 minutes of silence on both tracks (less than 15): still recording")
    let stoppedAfter = h.run(until: { !rec.isRecording }, limit: 180, [zoom])
    check(stoppedAfter != nil && stoppedAfter! <= 75, "stops once the silence reaches 15 minutes", "after +\(stoppedAfter ?? -1) s on top of 14 min")
    check(rec.stopReasons == [.meetingEnded], "finalized like a normal end of the meeting (session.json end_reason: meeting-ended)", "\(rec.stopReasons)")
    check(h.pipeline.enqueued == [rec.dir] && fm.fileExists(atPath: rec.dir.path), "the recording is kept and handed to the pipeline (not deleted)", "\(h.pipeline.enqueued)")
    check(rec.annotations.count == 1 && rec.annotations[0].contains("no speech") && rec.annotations[0].contains("-70 dBFS") && rec.annotations[0].contains("15 min"),
          "session.json gets a warning line that says why it ended", "\(rec.annotations)")
    check(logCount("stop (no-speech): both tracks below -70 dBFS for 15 min") >= 1 && logCount("reason=no-speech") >= 1,
          "the log says reason no-speech (the line carries the levels and the detection snapshot)")
    check(h.state.status == .processing("Queued"), "the menu shows the normal processing state after the stop", "\(h.state.status)")
    check((h.state.notice ?? "").contains("stopped after 15 min without speech"), "a notice stays in the menu after the stop", "\(h.state.notice ?? "nil")")
    check(h.notifier.posted.isEmpty, "the no-speech stop itself posts no notification (it is not an error)", "\(h.notifier.posted.map { $0.title })")

    check(h.state.restartHold == .stoppedCall && h.controller.restartHold == .stoppedCall, "a no-speech stop in a live call holds the Settings window's restart too (a relaunch would record the call again)", "\(String(describing: h.state.restartHold))")
    h.run(300, [zoom])
    check(h.recorders.count == 1, "the call is still detected: the same meeting is NOT restarted", "recorders=\(h.recorders.count)")
    check(logCount("start for zoom:- suppressed: the last recording of this meeting was stopped for no speech") == 1, "the suppression is logged once, not every cycle")
    h.run(2, [])                                    // detection goes false once
    check(logCount("no-speech suppression for zoom:- lifted") == 1, "detection going false once lifts the suppression")
    // the first poll without the call lifts the stopped-call hold; inside the flicker tolerance the machine may still call the (re-appearing) call a candidate, and then the hold says 'about to be recorded'
    check(h.state.restartHold != .stoppedCall, "... and the stopped-call restart hold", "\(String(describing: h.state.restartHold))")
    h.run(60, [])
    check(h.state.restartHold == nil && h.controller.restartHold == nil, "the call stays gone: nothing is held, the restart may go", "\(String(describing: h.state.restartHold))")
    h.run(until: { h.recorders.count == 2 && h.current?.isRecording == true }, limit: 30, [zoom])
    check(h.recorders.count == 2 && h.current?.isRecording == true, "the next call of that platform records again")
    check(h.state.notice == nil, "a new recording clears the notice")
    h.controller.shutdown(reason: .appQuit)

    // B: it takes BOTH tracks; the threshold is strict; a blip of sound restarts the clock.
    let b = Harness("nospeech-both", in: base)
    b.run(until: { !b.recorders.isEmpty }, limit: 15, [zoom])
    guard let rb = b.current else { check(false, "recording B started"); return }
    rb.levels = (-120, -30)                        // muted microphone, the other side talking
    b.run(40 * 60, step: 2, [zoom])
    check(rb.isRecording, "microphone muted but the remote track has speech: never stopped (a muted mic is normal)")
    rb.levels = (-30, -120)                        // the other side silent, me talking
    b.run(40 * 60, step: 2, [zoom])
    check(rb.isRecording, "remote track silent but the microphone has speech: never stopped")
    rb.levels = (-70, -70)                         // exactly at the threshold: not below it
    b.run(40 * 60, step: 2, [zoom])
    check(rb.isRecording, "exactly -70 dBFS is not 'below -70': never stopped")
    rb.levels = (-71, -75)
    b.run(14 * 60, step: 2, [zoom])
    rb.levels = (-120, -50)                        // a little sound on one track
    b.run(2, [zoom])
    rb.levels = (-71, -75)
    b.run(14 * 60, step: 2, [zoom])
    check(rb.isRecording, "a short sound on either track restarts the 15 minute clock")
    let bStop = b.run(until: { !rb.isRecording }, limit: 4 * 60, step: 2, [zoom])
    check(bStop != nil, "... and 15 minutes of silence after the sound end the recording", "\(bStop ?? -1)")
    b.controller.shutdown(reason: .appQuit)

    // C: a manual recording is never stopped by silence.
    let m = Harness("nospeech-manual", in: base)
    m.controller.startRecordingNow(); m.sync()
    m.current?.levels = (-120, -120)
    m.run(90 * 60, step: 5, [])
    check(m.current?.isRecording == true && m.current?.annotations.isEmpty == true, "a manual recording is not stopped by silence (90 min)")
    m.controller.shutdown(reason: .appQuit)

    // D: 0 switches it off.
    let off = Harness("nospeech-off", in: base) { $0.noSpeechStopMinutes = 0 }
    off.run(until: { !off.recorders.isEmpty }, limit: 15, [zoom])
    off.current?.levels = (-120, -120)
    off.run(3 * 3600, step: 10, [zoom])
    check(off.current?.isRecording == true && off.recorders.count == 1, "NO_SPEECH_STOP_MINUTES=0: three hours of silence do not stop it")
    off.controller.shutdown(reason: .appQuit)

    // E: only while detection still says "in a call": otherwise the normal grace stop is in charge.
    let g = Harness("nospeech-grace", in: base) { $0.noSpeechStopMinutes = 5; $0.grace = 1800 }
    g.run(until: { !g.recorders.isEmpty }, limit: 15, [zoom])
    g.current?.levels = (-120, -120)
    g.run(120, [zoom])
    let stopBefore = logCount("stop (no-speech)")
    g.run(20 * 60, step: 5, [])                    // the call is over (detection false) but the 30 minute grace is still running
    check(g.current?.isRecording == true && logCount("stop (no-speech)") == stopBefore,
          "silence longer than the limit while detection says the call is over: no no-speech stop (the grace period decides)")
    let graceStop = g.run(until: { g.current?.isRecording == false }, limit: 20 * 60, step: 5, [])
    check(graceStop != nil && g.current?.annotations.isEmpty == true && logCount("stop (meeting-ended)") >= 1, "the grace period then ends it as an ordinary meeting-ended stop")

    // F: a stop the app chose itself is never dropped as a blip, however short.
    let tiny = Harness("nospeech-tiny", in: base) { $0.noSpeechStopMinutes = 0.1 }
    tiny.run(until: { !tiny.recorders.isEmpty }, limit: 15, [zoom])
    tiny.current?.levels = (-120, -120)
    let tinyStop = tiny.run(until: { tiny.current?.isRecording == false }, limit: 30, [zoom])
    check(tinyStop != nil && tiny.pipeline.enqueued.count == 1 && tiny.current.map { fm.fileExists(atPath: $0.dir.path) } == true,
          "a no-speech stop after 6 s is kept and queued (the blip rule does not apply)", "stop \(tinyStop ?? -1) enqueued \(tiny.pipeline.enqueued.count)")

    // G: Pause / Resume is an explicit user action: it ends the suppression.
    let p = Harness("nospeech-pause", in: base) { $0.noSpeechStopMinutes = 2 }
    p.run(until: { !p.recorders.isEmpty }, limit: 15, [zoom])
    p.current?.levels = (-120, -120)
    p.run(until: { p.current?.isRecording == false }, limit: 300, [zoom])
    p.run(30, [zoom])
    check(p.recorders.count == 1, "suppressed while the call goes on")
    p.controller.setPaused(true); p.sync()
    p.controller.setPaused(false); p.sync()
    p.run(until: { p.recorders.count == 2 }, limit: 30, [zoom])
    check(p.recorders.count == 2, "Pause + Resume clears the suppression: the call is recorded again", "recorders=\(p.recorders.count)")
    p.controller.shutdown(reason: .appQuit)
}

// MARK: - Notifications

private func testNotifications(_ base: URL) {
    section("notifications (SPEC 15): remote silent, recording could not start (throttled), processing failed, note ready; nothing for ordinary start/stop")
    let zoom = zoomSignal()

    // ordinary start / stop / progress post nothing; "note ready" carries the title
    let h = Harness("notify", in: base)
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [zoom])
    h.run(30, [zoom])
    h.run(until: { h.current?.isRecording == false }, limit: 80, [])
    let sid = h.current?.dir.lastPathComponent ?? "2026-10-07_1400_zoom"
    h.pipeline.onEvent?(.progress(session: sid, text: "Transcribing remote 3/9")); h.sync()
    check(h.notifier.posted.isEmpty, "start, stop and pipeline progress post nothing")
    h.pipeline.onEvent?(.finished(session: sid, title: "Weekly Sync", finalDir: nil, discarded: false)); h.sync()
    check(h.notifier.posted.count == 1 && h.notifier.posted[0].kind == .noteReady && h.notifier.posted[0].title == "회의록이 준비됐어요" && h.notifier.posted[0].subtitle == "Weekly Sync",
          "a finished note posts '회의록이 준비됐어요' with the meeting title as the subtitle", "\(h.notifier.posted.map { "\($0.title) | \($0.subtitle)" })")
    h.pipeline.onEvent?(.finished(session: "s-discarded", title: nil, finalDir: nil, discarded: true)); h.sync()
    h.pipeline.onEvent?(.nothingToReport(session: "retry-sweep")); h.sync()
    check(h.notifier.posted.count == 1, "a discarded session and an empty sweep post nothing")
    h.pipeline.onEvent?(.finished(session: "s-untitled", title: nil, finalDir: nil, discarded: false)); h.sync()
    check(h.notifier.posted.last?.title == "회의록이 준비됐어요" && h.notifier.posted.last?.subtitle == "제목 없는 회의",
          "no title: the same notification with the subtitle '제목 없는 회의'", "\(h.notifier.posted.last?.subtitle ?? "nil")")

    // pipeline failure: reason in the body, the same session is not repeated for 12 hours
    h.pipeline.onEvent?(.failed(session: "s1", message: "Note failed: Claude usage limit reached")); h.sync()
    check(h.notifier.count(.pipelineFailed) == 1 && h.notifier.posted.last?.body.contains("usage limit reached") == true && h.notifier.posted.last?.title == "회의록 생성 실패",
          "a pipeline failure posts the reason", "\(h.notifier.posted.last?.body ?? "nil")")
    h.pipeline.onEvent?(.failed(session: "s1", message: "Note failed: Claude usage limit reached")); h.sync()
    check(h.notifier.count(.pipelineFailed) == 1, "the same failure again right away: not repeated (throttled)")
    h.pipeline.onEvent?(.failed(session: "s2", message: "archive unavailable")); h.sync()
    check(h.notifier.count(.pipelineFailed) == 2, "another session's failure is a different story: posted")
    h.clock.advance(13 * 3600)
    h.pipeline.onEvent?(.failed(session: "s1", message: "Note failed: Claude usage limit reached")); h.sync()
    check(h.notifier.count(.pipelineFailed) == 3, "12+ hours later the same failure is reported again (the sweep keeps failing: the user should hear it)")
    h.pipeline.onEvent?(.failed(session: "reprocess-last", message: PipelineLauncher.reprocessBlockedMessage)); h.sync()
    check(h.notifier.count(.pipelineFailed) == 3, "'Reprocess Last Meeting' refused during a recording is the user's own click: no notification")

    // remote silent
    let r = Harness("notify-remote", in: base)
    r.run(until: { !r.recorders.isEmpty }, limit: 15, [zoom])
    r.run(10, [zoom])
    check(!r.state.remoteSilentSuspected && r.notifier.posted.isEmpty, "healthy recording: no warning, no notification")
    r.current?.fireRemoteSilent(); r.sync()
    check(r.state.remoteSilentSuspected && r.notifier.count(.remoteSilent) == 1, "remote silent suspected: state flag set and ONE notification", "\(r.notifier.posted.map { $0.kind })")
    check(r.state.warning == nil, "the generic 'latest warning' line does not repeat it (the standing line covers it)", "\(r.state.warning ?? "nil")")
    check(r.notifier.posted.last?.title == "상대방 소리가 녹음되지 않는 것 같아요" && r.notifier.posted.last?.body.contains("시스템 오디오 녹음 권한") == true
          && r.notifier.posted.last?.subtitle == "Zoom 녹음 중", "the notification says what to check", "\(r.notifier.posted.last.map { "\($0.title) | \($0.subtitle) | \($0.body)" } ?? "nil")")
    r.current?.fireRemoteSilent(); r.sync()
    check(r.notifier.count(.remoteSilent) == 1, "a second report in the same recording does not notify again")
    let lines = StatusMenuController.menuText(for: r.state, now: r.clock.now).lines.joined(separator: " ")
    check(lines.contains("remote audio is silent"), "the menu shows the warning line while recording", lines)
    r.controller.stopRecordingNow(); r.sync()
    check(!r.state.remoteSilentSuspected && (r.state.notice ?? "").contains("Remote audio was silent"), "after the stop the menu keeps a notice about it", "\(r.state.notice ?? "nil")")
    r.run(2 * 3600 + 60, step: 10, [])
    check(r.state.notice == nil, "... for about two hours")

    // recording could not start: one notification per 30 minutes, whatever the retry rhythm
    let f = Harness("notify-fail", in: base)
    f.startError = RecorderError.permissionDenied("system audio")
    f.run(until: { f.recorders.count >= 1 }, limit: 15, [zoom])
    check(f.notifier.count(.recordingFailed) == 1 && f.notifier.posted.last?.body.contains("시스템 오디오 녹음에서 \(AppInfo.displayName) 앱을 켜 주세요") == true
          && f.notifier.posted.last?.title == "녹음을 시작하지 못했어요" && f.notifier.posted.last?.action == .openSettings(NotificationSettingsPane.systemAudio()),
          "a recording that cannot start posts the actionable reason (which permission, click opens that pane)", "\(f.notifier.posted.last?.body ?? "nil")")
    f.run(25 * 60, step: 2, [zoom])
    check(f.recorders.count >= 4 && f.notifier.count(.recordingFailed) == 1, "five-minute retries for 25 minutes: still ONE notification", "attempts \(f.recorders.count), posted \(f.notifier.count(.recordingFailed))")
    f.controller.startRecordingNow(); f.sync()
    check(f.notifier.count(.recordingFailed) == 1, "a manual start failing inside the same window does not add another")
    f.run(10 * 60, step: 2, [zoom])
    check(f.notifier.count(.recordingFailed) == 2, "after 30 minutes it is reported again", "posted \(f.notifier.count(.recordingFailed))")

    let d = Harness("notify-device", in: base)
    d.startError = RecorderError.deviceUnavailable("Bluetooth is switching profile")
    d.run(3600, step: 2, [zoom])
    check(d.recorders.count >= 10 && d.notifier.count(.recordingFailed) >= 1 && d.notifier.count(.recordingFailed) <= 3,
          "an hour of failing retries (10 s, 30 s, 60 s, 5 min ...): at most 3 notifications, not one per attempt", "attempts \(d.recorders.count), posted \(d.notifier.count(.recordingFailed))")

    // a controller without a notifier still works (NullNotifier)
    let quiet = SessionController(config: h.config, detector: FakeDetector(clock: h.clock), recorderFactory: { dir, sig in FakeRecorder(dir: dir, signal: sig, clock: h.clock) },
                                  pipeline: FakePipeline(), clock: { h.clock.now }, deliver: { $0() }, zoomTier: .defaults)
    quiet.tick()
    check(true, "SessionController works without a notifier")
}

// MARK: - Notifier (fake notification center)

private final class FakeCenter: NotificationCenterBackend {
    var status: NotificationAuthorization
    var requestAnswer: NotificationAuthorization?       // nil: the user never answers
    var addError: String?
    private(set) var statusCalls = 0
    private(set) var requestCalls = 0
    private(set) var added: [AppNotification] = []
    private(set) var installs = 0                            // installClickHandler calls
    private(set) var installedRouter: NotificationClickRouter?
    private(set) var order: [String] = []                    // "install" / "add", in the order they happened
    init(status: NotificationAuthorization) { self.status = status }
    func installClickHandler(_ router: NotificationClickRouter) { installs += 1; installedRouter = router; order.append("install") }
    func authorizationStatus(_ completion: @escaping (NotificationAuthorization) -> Void) { statusCalls += 1; completion(status) }
    func requestAuthorization(_ completion: @escaping (NotificationAuthorization) -> Void) {
        requestCalls += 1
        if let a = requestAnswer { completion(a) }
    }
    func add(_ notification: AppNotification, completion: @escaping (String?) -> Void) { added.append(notification); order.append("add"); completion(addError) }
}

private func testNotifier() {
    section("Notifier: only in the signed app, fail-soft, fake center, messages, throttle")
    let note = AppNotification.noteReady(title: "Weekly Sync", session: "s1")

    let inactiveCenter = FakeCenter(status: .authorized)
    let inactive = Notifier(active: false, backend: inactiveCenter)
    let beforeInactive = logCount("notification not delivered: not running as the signed \(AppInfo.shortName).app")
    inactive.post(note)
    check(!inactive.isActive && inactiveCenter.statusCalls == 0 && inactiveCenter.added.isEmpty && inactiveCenter.requestCalls == 0,
          "not the signed app: the center is never touched (a bare binary would trap on UNUserNotificationCenter)")
    check(logCount("notification not delivered: not running as the signed \(AppInfo.shortName).app") == beforeInactive + 1, "... only a log line is written")
    check(inactive.requestAuthorization(timeout: 0.2) == .unavailable("only the signed \(AppInfo.shortName).app started by launchd / LaunchServices can ask") && inactiveCenter.requestCalls == 0,
          "... and the authorization request answers 'unavailable' without asking macOS")
    check(Notifier().isActive == LaunchGuard.isSignedAppLaunch, "the default Notifier is active exactly when LaunchGuard.isSignedAppLaunch says so")

    let ok = FakeCenter(status: .authorized)
    Notifier(active: true, backend: ok).post(note)
    check(ok.added == [note], "active and authorized: delivered once", "\(ok.added.count)")

    for status: NotificationAuthorization in [.denied, .notDetermined, .unavailable("no bundle")] {
        let c = FakeCenter(status: status)
        let before = logCount("notification not delivered: macOS notifications are \(status.label)")
        Notifier(active: true, backend: c).post(note)
        check(c.added.isEmpty && logCount("notification not delivered: macOS notifications are \(status.label)") == before + 1,
              "\(status.label): not delivered, one log line (fail-soft)")
    }
    let failing = FakeCenter(status: .authorized)
    failing.addError = "delivery refused"
    let beforeErr = logCount("notification could not be delivered: delivery refused")
    Notifier(active: true, backend: failing).post(note)
    check(logCount("notification could not be delivered: delivery refused") == beforeErr + 1, "an error while delivering is logged, nothing is thrown")

    let ask = FakeCenter(status: .notDetermined)
    ask.requestAnswer = .authorized
    check(Notifier(active: true, backend: ask).requestAuthorization(timeout: 1) == .authorized && ask.requestCalls == 1, "setup: the center's answer is returned")
    let silent = FakeCenter(status: .notDetermined)
    check(Notifier(active: true, backend: silent).requestAuthorization(timeout: 0.2) == .notDetermined, "setup: an unanswered prompt comes back as 'not determined' after the timeout")

    // the messages (the full content tests are in testNotificationContent)
    let silentMsg = AppNotification.remoteSilent(platformLabel: "Zoom", session: "s1")
    let failMsg = AppNotification.recordingFailed(reason: "Cannot record: permission denied (microphone).\nAllow it in System Settings.", kind: .other)
    let pipeMsg = AppNotification.pipelineFailed(session: "s1", reason: String(repeating: "x", count: 500))
    check(silentMsg.title == "상대방 소리가 녹음되지 않는 것 같아요" && silentMsg.subtitle.contains("Zoom") && silentMsg.body.contains("시스템 오디오 녹음 권한") && silentMsg.sound, "remote silent message")
    check(failMsg.title == "녹음을 시작하지 못했어요" && !failMsg.body.contains("\n") && failMsg.body.contains("permission denied"), "recording failed message (cause unknown): one line, shows the reason")
    check(pipeMsg.title == "회의록 생성 실패" && pipeMsg.body.count <= 100 && pipeMsg.body.hasPrefix("원인: "), "pipeline failed message: reason, bounded length", "\(pipeMsg.body.count)")
    check(note.title == "회의록이 준비됐어요" && note.subtitle == "Weekly Sync" && !note.sound && AppNotification.noteReady(title: "  ", session: "x").subtitle == "제목 없는 회의", "note ready message")
    check(Set([silentMsg.identifier, failMsg.identifier, pipeMsg.identifier, note.identifier]).count == 4, "identifiers differ per kind (a newer one replaces only its own kind)")

    // throttle
    var t = NotificationThrottle()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check(t.allow(key: "a", now: t0, interval: 60) && !t.allow(key: "a", now: t0.addingTimeInterval(59), interval: 60) && t.allow(key: "a", now: t0.addingTimeInterval(60), interval: 60),
          "throttle: once per interval per key")
    check(t.allow(key: "b", now: t0.addingTimeInterval(1), interval: 60), "throttle: another key is independent")
    check(t.allow(key: "c", now: t0, interval: 60) && t.allow(key: "c", now: t0.addingTimeInterval(-5), interval: 60), "throttle: a clock that moved backwards does not lock a key out")
}

// MARK: - Notification content (Korean, informative, never empty)

private func hasHangul(_ text: String) -> Bool {
    return text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
}

/// One of every kind and variant, built the way the app builds them.
private func sampleNotifications(folder: URL, log: URL) -> [(name: String, n: AppNotification)] {
    let later = Date(timeIntervalSince1970: 1_800_000_000)
    let longTitle = String(repeating: "아주 긴 회의 제목 ", count: 30)
    var out: [(name: String, n: AppNotification)] = [
        ("noteReady full", .noteReady(title: "Weekly Sync", session: "s1", platformLabel: "Zoom", durationSeconds: 1932, folder: folder)),
        ("noteReady bare", .noteReady(title: nil, session: "s2")),
        ("noteReady long title", .noteReady(title: longTitle, session: "s3", platformLabel: "Google Meet", durationSeconds: 7500, folder: folder)),
        ("pipelineFailed usage_limit", .pipelineFailed(session: "s1", reason: "Note failed: Claude usage limit reached", kind: "usage_limit", retryable: true,
                                                       resetsAt: later, folder: folder, logFile: log)),
        ("pipelineFailed unknown 600 chars", .pipelineFailed(session: "s2", reason: String(repeating: "x", count: 600))),
        ("pipelineFailed asr", .pipelineFailed(session: "s3", reason: "boom", kind: "asr_failed", retryable: false, folder: folder, logFile: log)),
        ("pipelineFailed log only", .pipelineFailed(session: "retry-sweep", reason: "archive unavailable", logFile: log)),
        ("remoteSilent", .remoteSilent(platformLabel: "Zoom", session: "s1")),
        ("recordingStarted auto", .recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "s1", folder: folder)),
        ("recordingStarted manual titled", .recordingStarted(platformLabel: "수동", manual: true, titleHint: longTitle, session: "s2", folder: folder)),
    ]
    for kind in [StartFailureKind.microphonePermission, .systemAudioPermission, .permission, .device, .disk, .folder, .other] {
        out.append(("recordingFailed \(kind)", .recordingFailed(reason: String(repeating: "r", count: 400), kind: kind, platformLabel: "Zoom", logFile: log)))
    }
    out.append(("recordingFailed no log", .recordingFailed(reason: "boom")))
    for note in [StopNote.normal, .diskLow, .maxDuration, .sleep, .noSpeech(minutes: 15)] {
        out.append(("recordingStopped \(note)", .recordingStopped(platformLabel: "Teams", manual: false, durationSeconds: 3720, titleHint: nil, session: "s1", folder: folder, note: note)))
    }
    out.append(("recordingStopped manual", .recordingStopped(platformLabel: "수동", manual: true, durationSeconds: 9, titleHint: longTitle, session: "s2", folder: nil)))
    return out
}

private func testNotificationContent() {
    section("notification content: Korean, informative, never empty, bounded, no secrets; payload = validated action + path")
    let folder = URL(fileURLWithPath: "/tmp/mcap-sample/archive/2026-10/2026-10-07_1400_weekly", isDirectory: true)
    let log = URL(fileURLWithPath: "/tmp/mcap-sample/logs/app.log")
    let later = Date(timeIntervalSince1970: 1_800_000_000)
    let samples = sampleNotifications(folder: folder, log: log)

    var problems: [String] = []
    for (name, n) in samples {
        if n.title.isEmpty || n.subtitle.isEmpty || n.body.isEmpty { problems.append("\(name): an empty part") }
        if !hasHangul(n.title) || !hasHangul(n.body) { problems.append("\(name): title or body is not Korean: \(n.title) | \(n.body)") }
        if n.title.count > NotificationText.titleLimit || n.subtitle.count > NotificationText.subtitleLimit || n.body.count > NotificationText.bodyLimit {
            problems.append("\(name): too long (title \(n.title.count), subtitle \(n.subtitle.count), body \(n.body.count))")
        }
        if (n.title + n.subtitle + n.body + n.summary).contains(where: { $0.isNewline }) { problems.append("\(name): contains a line break") }
        if n.summary.isEmpty { problems.append("\(name): no English log summary") }
        let info = n.userInfo
        if let extra = info.keys.first(where: { !["action", "path", "url"].contains($0) }) { problems.append("\(name): userInfo has the extra key \(extra)") }
        if !NotificationClickAction.knownActions.contains(info["action"] ?? "") { problems.append("\(name): unknown action \(info["action"] ?? "nil")") }
        switch n.action {
        case .none: if info.count != 1 { problems.append("\(name): action none carries more than the action") }
        case .openFolder(let p), .openLog(let p): if info["path"] != p || info["url"] != nil || !p.hasPrefix("/") { problems.append("\(name): path payload is wrong \(info)") }
        case .openSettings(let u): if info["url"] != u || info["path"] != nil || !NotificationSettingsPane.isAllowed(u) { problems.append("\(name): settings payload is wrong \(info)") }
        }
    }
    check(problems.isEmpty, "all \(samples.count) sample notifications: title + subtitle + body (Korean, non-empty, <= \(NotificationText.titleLimit)/\(NotificationText.subtitleLimit)/\(NotificationText.bodyLimit) characters), one line, an English log summary, userInfo = action + path | url only",
          problems.joined(separator: "\n      "))

    // exact content of the messages the task names
    let ready = AppNotification.noteReady(title: "Weekly Sync", session: "s1", platformLabel: "Zoom", durationSeconds: 1932, folder: folder)
    check(ready.title == "회의록이 준비됐어요" && ready.subtitle == "Weekly Sync" && ready.body == "Zoom · 32분 녹음 · 클릭하면 폴더가 열립니다"
          && !ready.sound && ready.level == .active && ready.action == .openFolder(folder.path) && ready.kind == .noteReady,
          "note ready: '회의록이 준비됐어요', subtitle = meeting title, body '<platform> · <duration> 녹음 · 클릭하면 폴더가 열립니다', click opens the folder, no sound", "\(ready)")
    let readyBare = AppNotification.noteReady(title: nil, session: "s2")
    check(readyBare.subtitle == "제목 없는 회의" && readyBare.body == "회의 폴더에 저장했어요" && readyBare.action == .none, "note ready without facts: still a full text, no folder promised")

    let usage = AppNotification.pipelineFailed(session: "s1", reason: "Note failed: Claude usage limit reached", kind: "usage_limit", retryable: true, resetsAt: later, folder: folder, logFile: log)
    check(usage.title == "회의록 생성 실패" && usage.subtitle == "전사본·녹음은 안전하게 보관됨" && usage.body.contains("Claude 사용 한도") && usage.body.contains("\(NotificationText.clock(later)) 이후")
          && usage.body.contains("mcap reprocess") && usage.body.contains("자동 재시도") && usage.sound && usage.action == .openFolder(folder.path),
          "processing failed: '회의록 생성 실패', transcript/recording are safe, the reason, the reprocess hint, sound, click opens the folder", "\(usage.body)")
    let manualRetry = AppNotification.pipelineFailed(session: "s3", reason: "boom", kind: "asr_failed", retryable: false, folder: folder, logFile: log)
    check(manualRetry.subtitle == "녹음은 안전하게 보관됨" && manualRetry.body.contains("mcap reprocess --last") && !manualRetry.body.contains("자동 재시도"),
          "a failure before the transcript exists only promises the recording; not retryable: the manual reprocess command")
    let kindWords: [(String, String)] = [("usage_limit", "Claude 사용 한도"), ("credit_exhausted", "크레딧"), ("budget_daily", "예산"), ("auth", "인증"), ("billing_mode_violation", "과금"),
                                         ("overloaded", "과부하"), ("rate_limited", "과부하"), ("timeout", "과부하"), ("overage_guard", "초과 사용"), ("config", "설정 오류"),
                                         ("archive_unavailable", "Google Drive"), ("asr_failed", "전사"), ("audio_failed", "오디오"), ("publish_failed", "저장"), ("stalled", "멈춰")]
    for (kind, word) in kindWords {
        let n = AppNotification.pipelineFailed(session: "s", reason: "English text", kind: kind)
        check(n.body.contains(word) && !n.body.contains("English text") && hasHangul(n.body) && n.body.count <= NotificationText.bodyLimit, "failure kind \(kind): Korean cause mentioning '\(word)'", n.body)
    }
    let weird = AppNotification.pipelineFailed(session: "s", reason: "weird thing happened", kind: "brand_new_kind")
    check(weird.body.hasPrefix("원인: weird thing happened"), "an unknown failure kind shows the raw one-line message", weird.body)
    check(AppNotification.pipelineFailed(session: "s", reason: "x", folder: nil, logFile: log).action == .openLog(log.path)
          && AppNotification.pipelineFailed(session: "s", reason: "x").action == .none, "failure click: the folder, else the pipeline log, else nothing")

    let silent = AppNotification.remoteSilent(platformLabel: "Zoom", session: "s1")
    check(silent.title == "상대방 소리가 녹음되지 않는 것 같아요" && silent.subtitle == "Zoom 녹음 중" && silent.body.contains("혼자 발표") && silent.body.contains("시스템 오디오 녹음 권한") && silent.body.contains("AirPods")
          && silent.sound && silent.level == .timeSensitive && silent.action == .openSettings(NotificationSettingsPane.systemAudio()),
          "remote silent: the three likely causes (alone / permission / AirPods), sound, time sensitive, click opens the System Audio Recording pane", "\(silent.body)")

    let startFailures: [(StartFailureKind, NotificationClickAction, String)] = [
        (.microphonePermission, .openSettings(NotificationSettingsPane.microphone), "마이크"),
        (.systemAudioPermission, .openSettings(NotificationSettingsPane.systemAudio()), "시스템 오디오 녹음"),
        (.permission, .openSettings(NotificationSettingsPane.privacy), "권한"),
        (.device, .openLog(log.path), "오디오 장치"),
        (.disk, .openLog(log.path), "저장 공간"),
        (.folder, .openLog(log.path), "세션 폴더"),
        (.other, .openLog(log.path), "원인"),
    ]
    for (kind, action, word) in startFailures {
        let n = AppNotification.recordingFailed(reason: "Cannot record: something", kind: kind, platformLabel: "Zoom", logFile: log)
        check(n.title == "녹음을 시작하지 못했어요" && (n.subtitle + n.body).contains(word) && n.action == action && n.sound && n.level == .timeSensitive,
              "recording could not start (\(kind)): actionable Korean text, sound, click -> \(action.name)", "\(n.subtitle) | \(n.body) | \(n.action)")
    }
    check(AppNotification.recordingFailed(reason: "Cannot record: boom", kind: .other).body.contains("Cannot record: boom"), "an unknown start failure shows the English reason")

    let started = AppNotification.recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "s1", folder: folder)
    check(started.title == "녹음 시작 · Zoom" && started.body == "Zoom 회의 녹음을 시작했어요. 메뉴바 아이콘이 가려져 있어도 이 알림으로 확인할 수 있어요"
          && !started.sound && started.level == .active && started.action == .openFolder(folder.path),
          "recording started: '녹음 시작 · Zoom' + the sentence about the hidden menu-bar icon, banner without sound", "\(started.body)")
    let startedManual = AppNotification.recordingStarted(platformLabel: "수동", manual: true, titleHint: "주간 회의", session: "s2", folder: folder)
    check(startedManual.title == "녹음 시작 · 수동" && startedManual.subtitle == "주간 회의" && startedManual.body.hasPrefix("수동으로 녹음을 시작했어요"), "manual start: its own wording, a known title becomes the subtitle")
    let stopped = AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 1932, titleHint: nil, session: "s1", folder: folder)
    check(stopped.title == "녹음 종료 · 전사 시작" && stopped.subtitle == "Zoom · 32분" && stopped.body.contains("32분") && stopped.body.contains("회의록이 준비되면") && !stopped.sound
          && stopped.action == .openFolder(folder.path), "recording ended: '녹음 종료 · 전사 시작' with the duration, no sound", "\(stopped.subtitle) | \(stopped.body)")
    let diskStop = AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 600, titleHint: nil, session: "s1", folder: folder, note: .diskLow)
    check(diskStop.sound && diskStop.level == .timeSensitive && diskStop.body.contains("저장 공간이 부족"), "a stop caused by a full disk is a warning: sound, time sensitive, says why")
    check(AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 900, titleHint: nil, session: "s1", folder: folder, note: .noSpeech(minutes: 15)).body.contains("15분 동안 소리가 없어"),
          "a no-speech stop says why")
    check(Set(samples.map { $0.n.identifier }).count >= 12, "identifiers are per kind and per session (a newer notification replaces only its own)")

    // levels and sounds: failures and warnings make a sound, everything else is a quiet banner; nothing is passive (no banner)
    for (name, n) in samples {
        let isFailure = [.remoteSilent, .recordingFailed, .pipelineFailed].contains(n.kind) || name.contains("diskLow")
        check(n.sound == isFailure && (n.level == .timeSensitive) == ([.remoteSilent, .recordingFailed].contains(n.kind) || name.contains("diskLow")),
              "\(name): sound only for failures, time sensitive only for what costs a recording", "sound \(n.sound) level \(n.level)")
    }

    // no secrets: an API key that reaches an error text never reaches a banner or the log summary
    let secret = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV"
    let leaky: [AppNotification] = [
        .noteReady(title: "Budget \(secret)", session: "s1", platformLabel: secret, durationSeconds: 60, folder: folder),
        .pipelineFailed(session: "s1", reason: "401 invalid x-api-key \(secret)", kind: nil),
        .pipelineFailed(session: "s1", reason: "x", kind: "brand_new_kind"),
        .recordingFailed(reason: "failed with \(secret)", kind: .other),
        .recordingStarted(platformLabel: "Zoom", manual: false, titleHint: secret, session: "s1", folder: nil),
    ]
    let leaks = leaky.filter { ($0.title + $0.subtitle + $0.body + $0.summary).contains("sk-ant") }
    check(leaks.isEmpty, "an API key inside an error text or title is masked everywhere", "\(leaks.map { $0.body })")
    check(NotificationText.redact("a sk-ant-api03-AAAABBBBCCCC b").contains("sk-\u{2026}") && !NotificationText.redact("sk-ant-api03-AAAABBBBCCCC").contains("AAAA"), "redact keeps no part of the key")

    // helpers
    let durations: [(Double, String)] = [(0, "1초"), (45, "45초"), (60, "1분"), (89, "1분"), (90, "2분"), (1932, "32분"), (3599, "1시간"), (3720, "1시간 02분"), (7200, "2시간"), (9000, "2시간 30분")]
    for (seconds, text) in durations { check(NotificationText.duration(seconds) == text, "duration \(Int(seconds)) s -> \(text)", NotificationText.duration(seconds)) }
    check(NotificationText.platformName(.zoom) == "Zoom" && NotificationText.platformName(.teams) == "Teams" && NotificationText.platformName(.meet) == "Google Meet" && NotificationText.platformName(.manual) == "수동",
          "platform names")
    check(NotificationText.clip("a\nb   c", 50) == "a b   c" && NotificationText.clip(String(repeating: "가", count: 30), 10).count == 10 && NotificationText.clip(String(repeating: "가", count: 30), 10).hasSuffix("\u{2026}"),
          "clip: one line, at most the limit, ellipsis")

    // review hardening: a title can come from someone else's calendar invite; a crash here would take the app (and a recording) down
    check(NotificationText.clip("a\u{07}b\u{1B}[31mred\u{1B}[0m", 50) == "ab[31mred[0m" && NotificationText.clip("\u{202E}evil\u{202C} meeting\u{2067}!", 50) == "evil meeting!",
          "clip: control characters and bidi overrides are dropped (no ESC sequence, no right-to-left override in a banner or the log)", NotificationText.clip("a\u{07}b\u{1B}[31mred", 50))
    check(NotificationText.clip("tab\tstays, line\u{2028}break\u{85}becomes a space", 80) == "tab\tstays, line break becomes a space", "clip: a tab stays, Unicode line breaks become a space", NotificationText.clip("tab\tstays, line\u{2028}break\u{85}becomes a space", 80))
    check(NotificationText.clip("key sk-ant-api03-AAAA\u{07}BBBBCCCC\u{202E}DDDD end", 80) == "key sk-\u{2026} end", "clip: a control character inside an API key does not split it into two pieces the mask misses",
          NotificationText.clip("key sk-ant-api03-AAAA\u{07}BBBBCCCC\u{202E}DDDD end", 80))
    check(NotificationText.clip("가족 👨‍👩‍👧‍👦 회의 🇰🇷", 50) == "가족 👨‍👩‍👧‍👦 회의 🇰🇷", "clip: Hangul, ZWJ emoji and flags are untouched")
    let cut = NotificationText.clip(String(repeating: "👨‍👩‍👧‍👦", count: 60), 10)
    check(cut.count == 10 && cut.hasSuffix("\u{2026}") && cut.dropLast().allSatisfy { $0 == "👨‍👩‍👧‍👦" }, "clip: cuts between grapheme clusters, never inside a family emoji", "\(cut)")
    check(NotificationText.wholeSeconds(.nan) == 0 && NotificationText.wholeSeconds(.infinity) == 0 && NotificationText.wholeSeconds(-.infinity) == 0 && NotificationText.wholeSeconds(-5) == 0
          && NotificationText.wholeSeconds(1e300) == 1_000_000_000 && NotificationText.wholeSeconds(89.6) == 90, "wholeSeconds: NaN / infinity / negative -> 0, huge -> 10^9 (Int(Double) would trap)")
    check(NotificationText.duration(.nan) == "1초" && NotificationText.duration(.infinity) == "1초" && NotificationText.duration(1e300).contains("시간"), "duration: no trap on NaN, infinity or a huge value")
    let nanStop = AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: .nan, titleHint: nil, session: "s", folder: nil)
    let infStop = AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: .infinity, titleHint: nil, session: "s", folder: nil, note: .diskLow)
    check(nanStop.subtitle == "Zoom · 1초" && nanStop.summary.contains("0 s") && !infStop.body.isEmpty, "recordingStopped with a NaN / infinite length still builds a complete notification")

    // Korean grammar: the particle after "32분" / "1시간" is 은 / 을 (a final consonant), after "45초" 는 / 를: the texts avoid the particle after a number
    var particle: [String] = []
    var particleSamples: [(name: String, n: AppNotification)] = samples
    particleSamples.append((name: "stop 45 s", n: AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 45, titleHint: nil, session: "s", folder: nil, note: .diskLow)))
    particleSamples.append((name: "stop 1 h", n: AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 3600, titleHint: nil, session: "s", folder: nil, note: .noSpeech(minutes: 15))))
    for (name, n) in particleSamples {
        let text = n.title + n.subtitle + n.body
        for bad in ["분는", "분를", "간는", "간를", "초은", "초을"] where text.contains(bad) { particle.append("\(name): '\(bad)' in \(n.body)") }
    }
    check(particle.isEmpty, "no wrong particle after a duration (분는 / 분를 / 간는 / 간를 / 초은 / 초을)", particle.joined(separator: "; "))
    check(diskStop.body == "저장 공간이 부족해 녹음을 멈췄어요. 녹음(10분)은 저장됐고 전사를 시작합니다", "disk-full stop: the body reads '녹음(10분)은 저장됐고'", diskStop.body)

    // settings panes: a fixed allow-list; the System Audio Recording pane depends on the macOS version
    check(NotificationSettingsPane.allowList.count == 5 && NotificationSettingsPane.allowList.allSatisfy { $0.hasPrefix("\(NotificationSettingsPane.scheme):") },
          "settings panes: five fixed x-apple.systempreferences: URLs")
    check(NotificationSettingsPane.systemAudio(osMajorVersion: 26) == NotificationSettingsPane.systemAudioRecording && NotificationSettingsPane.systemAudio(osMajorVersion: 26).hasSuffix("Privacy_AudioCapture")
          && NotificationSettingsPane.systemAudio(osMajorVersion: 15) == NotificationSettingsPane.screenAndSystemAudio && NotificationSettingsPane.systemAudio(osMajorVersion: 14).hasSuffix("Privacy_ScreenCapture")
          && NotificationSettingsPane.isAllowed(NotificationSettingsPane.systemAudio()), "System Audio Recording: Privacy_AudioCapture on macOS 26+, Privacy_ScreenCapture before; both allowed")

    // permission classification of a failed start
    typealias K = StartFailureKind
    let permCases: [(String, K)] = [
        ("microphone: permission denied: microphone access was not granted (denied); system audio: recorder failed: AudioHardwareCreateProcessTap failed: 560947818", .microphonePermission),
        ("system audio: permission denied: system audio access denied; microphone: device unavailable: no default audio input device (microphone)", .systemAudioPermission),
        ("microphone: permission denied: microphone access is denied; system audio: permission denied: tap denied", .permission),
        ("system audio", .systemAudioPermission),
        ("microphone permission has not been granted yet; run `\(AppInfo.shortName) setup` once", .microphonePermission),
        ("something else entirely", .permission),
    ]
    for (text, expected) in permCases {
        check(SessionController.permissionKind(text) == expected, "permission kind of '\(text.prefix(48))...' is \(expected)", "\(SessionController.permissionKind(text))")
    }
    check(SessionController.startFailureKind(RecorderError.deviceUnavailable("x")) == .device && SessionController.startFailureKind(RecorderError.failed("cannot create session folder /x")) == .folder
          && SessionController.startFailureKind(RecorderError.failed("tap boom")) == .other && SessionController.startFailureKind(NSError(domain: "x", code: 1)) == .other
          && SessionController.startFailureKind(RecorderError.permissionDenied("microphone: permission denied: x")) == .microphonePermission, "start errors map to a failure kind")
}

// MARK: - Notification clicks: routing and validation

private final class FakeOpener: NotificationOpening {
    private(set) var opened: [URL] = []
    var refuse: Set<String> = []                          // absolute strings the fake "cannot open"
    func open(_ url: URL) -> Bool { opened.append(url); return !refuse.contains(url.absoluteString) }
}

private func testNotificationRouting(_ base: URL) {
    section("notification clicks: validated routing (fake opener; paths, symlinks, '..', URLs, unknown actions); the completion handler is always called")
    let fm = FileManager.default
    let root = base.appendingPathComponent("clicks", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)
    let month = archive.appendingPathComponent("2026-10", isDirectory: true)
    let meeting = month.appendingPathComponent("2026-10-07_1400_weekly", isDirectory: true)
    let staging = support.appendingPathComponent("sessions/2026-10-07_1400_zoom", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    for d in [meeting, staging, logs, outside, archive.appendingPathComponent("Evil.app", isDirectory: true)] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    for (dir, name) in [(logs, "app.log"), (logs, "pipeline-x.log"), (logs, "evil.sh"), (outside, "secret.txt"), (meeting, "meeting-note.md"), (archive, "x.log")] {
        try? "text\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try? fm.createSymbolicLink(at: archive.appendingPathComponent("link-out"), withDestinationURL: outside)
    try? fm.createSymbolicLink(at: logs.appendingPathComponent("link.log"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
    var config = AppConfig.defaults()
    config.supportDir = support
    config.archiveDir = archive
    let policy = NotificationPathPolicy(config: config, logDir: logs)
    func canon(_ url: URL) -> String { NotificationPathPolicy.canonical(url.path) }

    struct Click { var opened: [URL]; var completions: Int; var names: [String] }
    func click(_ info: [AnyHashable: Any], id: String = UNNotificationDefaultActionIdentifier, refuse: Set<String> = []) -> Click {
        let opener = FakeOpener()
        opener.refuse = refuse
        let router = NotificationClickRouter(policy: policy, opener: opener, dispatch: { $0() })
        var names: [String] = []
        router.observer = { names.append($0) }
        var completions = 0
        router.handle(actionIdentifier: id, userInfo: info, completion: { completions += 1 })
        return Click(opened: opener.opened, completions: completions, names: names)
    }
    func folder(_ path: String) -> [AnyHashable: Any] { ["action": "openFolder", "path": path] }
    func logFile(_ path: String) -> [AnyHashable: Any] { ["action": "openLog", "path": path] }
    func settings(_ url: String) -> [AnyHashable: Any] { ["action": "openSettings", "url": url] }

    // openFolder: valid targets
    let beforeFolder = logCount("notification clicked: openFolder")
    let c1 = click(folder(meeting.path))
    check(c1.opened.map { $0.path } == [canon(meeting)] && c1.completions == 1 && c1.names == ["openFolder"], "openFolder: a published meeting folder is opened (completion called once)", "\(c1)")
    check(logCount("notification clicked: openFolder") == beforeFolder + 1, "the click is logged: 'notification clicked: openFolder <path>'")
    for (name, dir) in [("the archive root", archive), ("a session folder", staging), ("the log folder", logs)] {
        let c = click(folder(dir.path))
        check(c.opened.map { $0.path } == [canon(dir)] && c.completions == 1, "openFolder: \(name) is allowed", "\(c)")
    }

    // openFolder: rejected targets
    let evil = archive.path + "/2026-10/../../outside"
    let rejected: [(String, String)] = [
        ("path traversal with '..'", evil),
        ("'..' that stays inside is refused too", archive.path + "/2026-10/../2026-10"),
        ("a symlink inside the archive that points outside", archive.appendingPathComponent("link-out").path),
        ("a file behind that symlink", archive.appendingPathComponent("link-out/secret.txt").path),
        ("a path that does not exist yet behind that symlink", archive.appendingPathComponent("link-out/new-folder").path),
        ("a folder outside every root", outside.path),
        ("/etc", "/etc"), ("/", "/"), ("a relative path", "archive/2026-10"), ("an empty path", ""),
        ("a file: URL", "file://" + archive.path), ("a NUL character", archive.path + "/\0x"),
    ]
    for (name, path) in rejected {
        let before = logCount("notification clicked: openFolder rejected")
        let c = click(folder(path))
        check(c.opened.isEmpty && c.completions == 1 && logCount("notification clicked: openFolder rejected") == before + 1, "openFolder rejected: \(name) (nothing opened, completion called, logged)", "\(c)")
    }
    // review hardening: a path longer than PATH_MAX is never a real folder, and must not cost one realpath() per component for minutes
    // (a forged payload of 2000 components took ~40 s, 200k components ~200 s before the bound)
    /// CPU seconds this process has used (user + system). The legitimate-deep-path bound below limits the work a path costs, not how long the
    /// machine kept the process waiting for a core.
    func cpuSeconds() -> Double {
        var ts = timespec()
        return clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0 ? Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9 : .infinity
    }
    func timedClick(_ path: String) -> (click: Click, seconds: Double, cpu: Double) {
        let started = Date(), cpuStarted = cpuSeconds()
        let c = click(folder(path))
        return (c, Date().timeIntervalSince(started), cpuSeconds() - cpuStarted)
    }
    for (name, path) in [("2000 components under the archive", archive.path + String(repeating: "/a", count: 2000)),
                         ("200000 two-byte components", "/" + String(repeating: "a/", count: 200_000)),
                         ("a 1 MB component", "/" + String(repeating: "a", count: 1_000_000)),
                         ("one byte over PATH_MAX", archive.path + "/" + String(repeating: "a", count: NotificationPathPolicy.maxPathBytes - archive.path.utf8.count))] {
        let before = logCount("notification clicked: openFolder rejected")
        let t = timedClick(path)
        check(t.click.opened.isEmpty && t.click.completions == 1 && t.seconds < 3 && logCount("notification clicked: openFolder rejected") == before + 1,
              "openFolder rejected: \(name) is refused at once (\(String(format: "%.2f", t.seconds)) s), completion called, logged", "\(t.click) \(t.seconds)")
    }
    // the largest path the kernel could hold still works, and a deep legitimate path is fast
    let deepBase = archive.path + String(repeating: "/d", count: (NotificationPathPolicy.maxPathBytes - archive.path.utf8.count) / 2)
    let deep = timedClick(deepBase)
    // fast = a bounded amount of CPU work plus a wall-clock ceiling that still catches a walk that blocks. The walk costs ~1.7 s unloaded; both
    // limits sit an order of magnitude above that so a loaded machine (4.2 s wall seen next to the full Python suite) cannot fail the check,
    // while the unbounded form (minutes) still does
    check(deep.click.completions == 1 && deep.click.opened.map { $0.path } == [canon(archive)] && deep.cpu < 20 && deep.seconds < 60,
          "a path of PATH_MAX bytes under the archive (500 components, none exists): the archive is shown, fast (\(String(format: "%.2f", deep.cpu)) s CPU, \(String(format: "%.2f", deep.seconds)) s wall)",
          "\(deep.click) \(deep.cpu) \(deep.seconds) \(deepBase.utf8.count)")
    check(policy.folderRoots.map { $0.path } == [config.sessionsDir.path, logs.path, config.archiveDir.path],
          "the local roots (sessions, logs) are looked at before ARCHIVE_DIR: a start / stop notice on the controller's queue never touches the cloud drive")

    let noPath = click(["action": "openFolder"])
    let wrongType = click(["action": "openFolder", "path": 42])
    check(noPath.opened.isEmpty && noPath.completions == 1 && wrongType.opened.isEmpty && wrongType.completions == 1, "openFolder without a path / with a non-string path: rejected")

    // openFolder: what a click does when the folder is gone, is a file or is a bundle
    let file = click(folder(meeting.appendingPathComponent("meeting-note.md").path))
    check(file.opened.map { $0.path } == [canon(meeting)], "a file inside the archive: its folder is opened, never the file", "\(file.opened)")
    let gone = click(folder(month.appendingPathComponent("moved-away/deeper").path))
    check(gone.opened.map { $0.path } == [canon(month)], "a folder that is gone (the pipeline moved it): the nearest existing parent inside the archive", "\(gone.opened)")
    let goneFar = click(folder(archive.path + "/2099-01/x/y"))
    check(goneFar.opened.map { $0.path } == [canon(archive)], "... up to the archive root", "\(goneFar.opened)")
    let bundle = click(folder(archive.appendingPathComponent("Evil.app").path))
    check(bundle.opened.map { $0.path } == [canon(archive)] && bundle.completions == 1, "a .app bundle is never opened (that would launch it): its parent folder is shown instead", "\(bundle.opened)")

    // openLog
    for name in ["app.log", "pipeline-x.log"] {
        let c = click(logFile(logs.appendingPathComponent(name).path))
        check(c.opened.map { $0.path } == [canon(logs.appendingPathComponent(name))] && c.completions == 1 && c.names == ["openLog"], "openLog: \(name) is opened with its default handler", "\(c)")
    }
    let missingLog = click(logFile(logs.appendingPathComponent("missing.log").path))
    check(missingLog.opened.map { $0.path } == [canon(logs)], "openLog: a log that does not exist: the log folder is shown instead", "\(missingLog.opened)")
    let script = click(logFile(logs.appendingPathComponent("evil.sh").path))
    check(script.opened.map { $0.path } == [canon(logs)], "openLog: only .log / .txt files are ever opened (a script in the log folder is not)", "\(script.opened)")
    for (name, path) in [("a log outside LOG_DIR (inside the archive)", archive.appendingPathComponent("x.log").path), ("a symlink in LOG_DIR to a file outside", logs.appendingPathComponent("link.log").path),
                         ("'..'", logs.path + "/../outside/secret.txt"), ("a relative path", "app.log")] {
        let c = click(logFile(path))
        check(c.opened.isEmpty && c.completions == 1, "openLog rejected: \(name)", "\(c)")
    }

    // openSettings: allow-list only
    for url in NotificationSettingsPane.allowList.sorted() {
        let c = click(settings(url))
        check(c.opened.map { $0.absoluteString } == [url] && c.completions == 1 && c.names == ["openSettings"], "openSettings: \(url.split(separator: "?").last ?? "") is opened", "\(c)")
    }
    for (name, url) in [("https", "https://example.com/privacy"), ("file", "file:///etc/passwd"), ("javascript", "javascript:alert(1)"), ("x-apple-reminderkit", "x-apple-reminderkit://x"),
                        ("the right scheme but a pane that is not in the list", "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"),
                        ("the allowed pane with a suffix", NotificationSettingsPane.microphone + "&x=1"), ("an empty URL", ""), ("a custom app scheme", "mcap://open?path=/etc")] {
        let c = click(settings(url))
        check(c.opened.isEmpty && c.completions == 1, "openSettings rejected: \(name) is not in the allow-list", "\(c)")
    }
    let fallback = click(settings(NotificationSettingsPane.systemAudioRecording), refuse: [NotificationSettingsPane.systemAudioRecording])
    check(fallback.opened.map { $0.absoluteString } == [NotificationSettingsPane.systemAudioRecording, NotificationSettingsPane.privacy] && fallback.completions == 1,
          "a pane macOS cannot open falls back to Privacy & Security", "\(fallback.opened)")
    let nothingWorks = click(settings(NotificationSettingsPane.systemAudioRecording), refuse: [NotificationSettingsPane.systemAudioRecording, NotificationSettingsPane.privacy])
    check(nothingWorks.completions == 1 && nothingWorks.opened.count == 2, "... and when that fails too, only a log line and the completion handler")

    // unknown / missing / none / dismiss
    let beforeUnknown = logCount("notification clicked: unknown(openApp) rejected")
    let unknown = click(["action": "openApp", "path": "/Applications/Calculator.app"])
    check(unknown.opened.isEmpty && unknown.completions == 1 && logCount("notification clicked: unknown(openApp) rejected") == beforeUnknown + 1 && unknown.names == ["unknown(openApp)"], "an unknown action is rejected and logged by name")
    for (name, info) in [("no action", ["path": archive.path] as [AnyHashable: Any]), ("an action that is not a string", ["action": 7, "path": archive.path]), ("an empty userInfo", [:]),
                         ("an action with a line break", ["action": "openFolder\nopenApp", "path": archive.path])] {
        let c = click(info)
        check(c.opened.isEmpty && c.completions == 1, "\(name): nothing opened, completion called", "\(c)")
    }
    let none = click(["action": "none"])
    check(none.opened.isEmpty && none.completions == 1 && none.names == ["none"], "action none: nothing to open, completion called, logged as 'none'")
    let dismissBefore = logCount("notification clicked:")
    let dismiss = click(folder(archive.path), id: UNNotificationDismissActionIdentifier)
    let custom = click(folder(archive.path), id: "com.example.evil-action")
    check(dismiss.opened.isEmpty && dismiss.completions == 1 && custom.opened.isEmpty && custom.completions == 1 && logCount("notification clicked:") == dismissBefore,
          "a dismissal or a foreign action identifier opens nothing (completion called, not counted as a click)")

    // what the builders emit survives the sanitizing and routes to the same place
    let router = NotificationClickRouter(policy: policy, opener: FakeOpener(), dispatch: { $0() })
    var drift: [String] = []
    for (name, n) in sampleNotifications(folder: meeting, log: logs.appendingPathComponent("app.log")) {
        let safe = router.sanitized(n)
        if case .rejected(let why) = router.decide(safe.userInfo).route { drift.append("\(name): \(why)") }
        if n.action.name != safe.action.name { drift.append("\(name): the action changed from \(n.action.name) to \(safe.action.name)") }
    }
    check(drift.isEmpty, "every notification the app builds passes the sanitizing (same action) and routes to an allowed target", drift.joined(separator: "; "))
    let bad: [(String, NotificationClickAction)] = [
        ("a folder outside", .openFolder(outside.path)), ("'..'", .openFolder(evil)), ("a symlink out", .openFolder(archive.appendingPathComponent("link-out").path)),
        ("a log in the archive", .openLog(archive.appendingPathComponent("x.log").path)), ("a web URL", .openSettings("https://evil.example")),
        ("a pane that is not listed", .openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")),
    ]
    for (name, action) in bad {
        var n = AppNotification.noteReady(title: "t", session: "s")
        n.action = action
        let safe = router.sanitized(n)
        check(safe.action == .none && safe.userInfo == ["action": "none"], "before posting: \(name) is dropped, the payload is only {action: none}", "\(safe.action)")
    }
}

// MARK: - Notifier wiring (fake center)

private func testNotifierWiring(_ base: URL) {
    section("notification click handler: installed once at startup (fake center), never before it is needed, willPresent options, delivery results")
    let fm = FileManager.default
    let root = base.appendingPathComponent("wiring", isDirectory: true)
    var config = AppConfig.defaults()
    config.supportDir = root.appendingPathComponent("support", isDirectory: true)
    config.archiveDir = root.appendingPathComponent("archive", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    for d in [config.archiveDir, config.sessionsDir, logs] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    let note = AppNotification.noteReady(title: "Weekly Sync", session: "s1", platformLabel: "Zoom", durationSeconds: 600, folder: config.archiveDir)

    // the same helper applicationDidFinishLaunching uses
    let beforeInstalled = logCount("notification click handler installed")
    let center = FakeCenter(status: .authorized)
    let notifier = NotificationStartup.make(config: config, logDir: logs, active: true, backend: center)
    check(center.installs == 1 && center.installedRouter != nil && center.order == ["install"] && logCount("notification click handler installed") == beforeInstalled + 1,
          "startup: the click handler is installed once, before any notification exists", "installs \(center.installs) order \(center.order)")
    notifier.start()
    notifier.start()
    check(center.installs == 1, "start() again (and again) installs nothing more", "\(center.installs)")
    notifier.post(note)
    notifier.post(AppNotification.recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "s1", folder: config.sessionsDir))
    check(center.installs == 1 && center.order == ["install", "add", "add"], "posting afterwards does not install again; the handler was there before the first delivery", "\(center.order)")
    let sent = center.added[0]
    check(sent.userInfo["action"] == "openFolder" && sent.userInfo["path"].map { $0.hasPrefix(NotificationPathPolicy.canonical(config.archiveDir.path)) } == true && Set(sent.userInfo.keys) == ["action", "path"],
          "what reaches the center carries action + the validated path and nothing else", "\(sent.userInfo)")

    // a process that is not the signed app never touches the center
    let off = FakeCenter(status: .authorized)
    let inactive = NotificationStartup.make(config: config, logDir: logs, active: false, backend: off)
    inactive.start()
    inactive.post(note)
    check(!inactive.isActive && off.installs == 0 && off.statusCalls == 0 && off.added.isEmpty, "not the signed app: no handler installed, the center is never touched")

    // safety net: a notifier whose start() was forgotten still has its handler before the first delivery, once
    let late = FakeCenter(status: .authorized)
    let router = NotificationClickRouter(policy: NotificationPathPolicy(config: config, logDir: logs), opener: FakeOpener(), dispatch: { $0() })
    let forgetful = Notifier(active: true, backend: late, router: router)
    forgetful.post(note)
    forgetful.post(note)
    check(late.installs == 1 && late.order == ["install", "add", "add"], "safety net: start() was never called: the handler is installed before the first add, once", "\(late.order)")

    // without a router (the `setup` command): nothing to install, notifications carry no click target
    let bare = FakeCenter(status: .authorized)
    let noRouter = Notifier(active: true, backend: bare)
    noRouter.start()
    noRouter.post(note)
    check(bare.installs == 0 && bare.added.count == 1 && bare.added[0].action == .none && bare.added[0].userInfo == ["action": "none"], "no router: no handler, and the notification promises no click action")

    // a click target that is not allowed is dropped before delivery
    let guarded = FakeCenter(status: .authorized)
    let g = NotificationStartup.make(config: config, logDir: logs, active: true, backend: guarded)
    let beforeRefused = logCount("click target /etc refused")
    g.post(.noteReady(title: "t", session: "s", platformLabel: nil, durationSeconds: nil, folder: URL(fileURLWithPath: "/etc")))
    check(guarded.added.count == 1 && guarded.added[0].action == .none && logCount("click target /etc refused") == beforeRefused + 1, "a target outside the allowed roots is refused at post time (logged), the banner still appears")

    // delivery results (selftest-notify prints them)
    func result(_ status: NotificationAuthorization, addError: String? = nil, active: Bool = true) -> Notifier.Delivery? {
        let c = FakeCenter(status: status)
        c.addError = addError
        var got: Notifier.Delivery?
        Notifier(active: active, backend: c, router: router).post(note) { got = $0 }
        return got
    }
    check(result(.authorized) == .delivered && result(.denied) == .notAllowed("denied") && result(.notDetermined) == .notAllowed("not determined")
          && result(.authorized, addError: "refused") == .failed("refused") && result(.authorized, active: false) == .inactive, "post(completion:): delivered / not allowed / failed / inactive")

    // willPresent: banner + list + sound, also while the app is active
    let options = LiveNotificationCenter.presentationOptions
    check(options.contains(.banner) && options.contains(.list) && options.contains(.sound), "willPresent shows the banner (and list entry and sound) even while the app is active")

    // the log lines stay English
    let line = "notification (noteReady): meeting note ready: Weekly Sync (s1) [click: openFolder]"
    check(logText().contains(line), "the log line of a posted notification is the English summary + the click action", String(logText().suffix(400)))

    // selftest-notify: refuses outside the signed app (before it creates anything)
    check(notifySelftestRefusal(signedAppLaunch: false)?.contains("open -n -W -a ~/Applications/\(AppInfo.shortName).app") == true && notifySelftestRefusal(signedAppLaunch: false)?.contains("--args selftest-notify") == true
          && notifySelftestRefusal(signedAppLaunch: true) == nil, "selftest-notify: refused from a shell with the open -n -W -a command, allowed in the signed app")
    check(runSelftestNotify(config: config, logDir: logs, waitSeconds: 0, signedAppLaunch: false) == 2, "selftest-notify from a shell: exit code 2 before anything is created")
}

// MARK: - Recording start / stop notifications (NOTIFY_RECORDING)

private func testRecordingNotifications(_ base: URL) {
    section("recording start / stop notifications (NOTIFY_RECORDING): on, off, never throttled away, not on quit, failures always")
    let zoom = zoomSignal()

    // on: one notification at the start, one at the end of an automatically recorded call
    let on = Harness("rec-notify", in: base) { $0.notifyRecording = true }
    on.run(until: { !on.recorders.isEmpty }, limit: 15, [zoom])
    on.sync()
    guard let rec = on.current else { check(false, "recording started"); return }
    check(on.notifier.posted.count == 1 && on.notifier.posted[0].kind == .recordingStarted, "a started recording posts ONE notification", "\(on.notifier.posted.map { $0.kind })")
    let s = on.notifier.posted[0]
    check(s.title == "녹음 시작 · Zoom" && s.body.contains("메뉴바 아이콘이 가려져 있어도") && !s.sound && s.level == .active && s.action == .openFolder(rec.dir.path) && s.identifier.hasSuffix(rec.dir.lastPathComponent),
          "start: '녹음 시작 · Zoom', the hidden-icon sentence, no sound, click opens the session folder", "\(s.title) | \(s.body) | \(s.action)")
    // 70 s: a call with 60 s or more of inCall announces its end at once; a shorter one waits for the pipeline (testZoomTierNotifications).
    on.run(70, [zoom])
    check(on.notifier.posted.count == 1, "no repeat while the call goes on")
    on.run(until: { !rec.isRecording }, limit: 80, [])
    on.sync()
    let stops = on.notifier.posted.filter { $0.kind == .recordingStopped }
    check(stops.count == 1 && stops[0].title == "녹음 종료 · 전사 시작" && stops[0].subtitle.hasPrefix("Zoom · ") && hasHangul(stops[0].body) && !stops[0].sound && stops[0].action == .openFolder(rec.dir.path),
          "end: '녹음 종료 · 전사 시작' with the length, no sound, click opens the session folder", "\(stops.map { "\($0.title) | \($0.subtitle)" })")
    check(on.notifier.posted.count == 2 && s.identifier != stops[0].identifier, "start and end are two notifications with different identifiers (the end does not replace the start)")

    // off: the same call posts nothing; the harness default is off
    let off = Harness("rec-notify-off", in: base)
    check(!off.config.notifyRecording, "(the harness runs with NOTIFY_RECORDING off unless a test turns it on)")
    off.run(until: { !off.recorders.isEmpty }, limit: 15, [zoom])
    off.run(30, [zoom])
    off.run(until: { off.current?.isRecording == false }, limit: 80, [])
    check(off.recorders.count == 1 && off.current?.isRecording == false && off.notifier.posted.isEmpty, "NOTIFY_RECORDING=0: a whole recorded call posts no start / stop notification", "\(off.notifier.posted.map { $0.kind })")
    let offFail = Harness("rec-notify-off-fail", in: base)
    offFail.startError = RecorderError.deviceUnavailable("Bluetooth is switching profile")
    offFail.run(until: { offFail.recorders.count >= 1 }, limit: 15, [zoom])
    check(offFail.notifier.count(.recordingFailed) == 1, "NOTIFY_RECORDING=0 never silences a failure (recording could not start)")

    // manual start / stop, four notifications within the same second: none is throttled away (each recording has its own session)
    let m = Harness("rec-notify-manual", in: base) { $0.notifyRecording = true }
    m.controller.startRecordingNow(); m.sync()
    let manualStart = m.notifier.posted.last
    check(manualStart?.title == "녹음 시작 · 수동" && manualStart?.subtitle == "수동으로 시작했어요" && manualStart?.body.hasPrefix("수동으로 녹음을 시작했어요") == true, "manual start: its own wording")
    m.clock.advance(125)
    m.controller.stopRecordingNow(); m.sync()
    check(m.notifier.posted.last?.kind == .recordingStopped && m.notifier.posted.last?.subtitle == "수동 · 2분", "manual stop: '수동 · 2분'", "\(m.notifier.posted.last?.subtitle ?? "nil")")
    m.controller.startRecordingNow(); m.sync()
    m.controller.stopRecordingNow(); m.sync()
    check(m.notifier.count(.recordingStarted) == 2 && m.notifier.count(.recordingStopped) == 2 && m.recorders.count == 2,
          "start, stop, start, stop within a second: all four are posted (distinct recordings are never throttled away)", "\(m.notifier.posted.map { $0.kind.rawValue })")
    var t = NotificationThrottle()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let key = "recording-started:2026-10-07_1400_zoom"
    check(t.allow(key: key, now: t0, interval: SessionController.recordingNoticeRepeatSeconds) && !t.allow(key: key, now: t0.addingTimeInterval(SessionController.recordingNoticeRepeatSeconds - 1), interval: SessionController.recordingNoticeRepeatSeconds)
          && t.allow(key: key, now: t0.addingTimeInterval(SessionController.recordingNoticeRepeatSeconds), interval: SessionController.recordingNoticeRepeatSeconds)
          && SessionController.recordingNoticeRepeatSeconds <= 10, "only an identical repeat (same kind, same session) inside a few seconds is dropped")

    // quitting the app does not announce an end (nothing is processed, the process is going away)
    let q = Harness("rec-notify-quit", in: base) { $0.notifyRecording = true }
    q.run(until: { !q.recorders.isEmpty }, limit: 15, [zoom])
    q.run(20, [zoom])
    q.controller.shutdown(reason: .appQuit)
    check(q.notifier.count(.recordingStarted) == 1 && q.notifier.count(.recordingStopped) == 0, "app quit: no 'recording ended' notification", "\(q.notifier.posted.map { $0.kind.rawValue })")

    // an accidental blip (deleted) announces its start only: documented limitation, the session is gone
    let b = Harness("rec-notify-blip", in: base) { $0.notifyRecording = true }
    b.run(until: { !b.recorders.isEmpty }, limit: 15, [zoom])
    b.controller.systemWillSleep()
    check(b.notifier.count(.recordingStarted) == 1 && b.notifier.count(.recordingStopped) == 0 && b.current.map { !FileManager.default.fileExists(atPath: $0.dir.path) } == true,
          "a blip that is deleted (a few seconds, ended by sleep) posts no 'ended' notification", "\(b.notifier.posted.map { $0.kind.rawValue })")

    // why it ended
    let ds = Harness("rec-notify-disk", in: base) { $0.notifyRecording = true }
    ds.run(until: { !ds.recorders.isEmpty }, limit: 15, [zoom])
    ds.freeDisk = 1
    ds.run(until: { ds.current?.isRecording == false }, limit: 120, [zoom])
    let diskNote = ds.notifier.posted.last
    check(diskNote?.kind == .recordingStopped && diskNote?.body.contains("저장 공간이 부족") == true && diskNote?.sound == true && diskNote?.level == .timeSensitive, "stopped by a full disk: says so, with sound", "\(diskNote?.body ?? "nil")")
    let ns = Harness("rec-notify-nospeech", in: base) { $0.notifyRecording = true; $0.noSpeechStopMinutes = 1 }
    ns.run(until: { !ns.recorders.isEmpty }, limit: 15, [zoom])
    ns.current?.levels = (-120, -120)
    ns.run(until: { ns.current?.isRecording == false }, limit: 200, [zoom])
    check(ns.notifier.posted.last?.kind == .recordingStopped && ns.notifier.posted.last?.body.contains("1분 동안 소리가 없어") == true, "stopped for no speech: says so", "\(ns.notifier.posted.last?.body ?? "nil")")
    let mx = Harness("rec-notify-max", in: base) { $0.notifyRecording = true; $0.maxRecordingHours = 0.01 }
    mx.run(until: { !mx.recorders.isEmpty }, limit: 15, [zoom])
    mx.run(until: { mx.current?.isRecording == false }, limit: 120, [zoom])
    check(mx.notifier.posted.last?.kind == .recordingStopped && mx.notifier.posted.last?.body.contains("최대 녹음 시간") == true, "stopped by MAX_RECORDING_HOURS: says so", "\(mx.notifier.posted.last?.body ?? "nil")")
    let sl = Harness("rec-notify-sleep", in: base) { $0.notifyRecording = true }
    sl.run(until: { !sl.recorders.isEmpty }, limit: 15, [zoom])
    sl.run(25, [zoom])
    sl.controller.systemWillSleep()
    check(sl.notifier.posted.last?.kind == .recordingStopped && sl.notifier.posted.last?.body.contains("잠자기") == true, "stopped by sleep: says so", "\(sl.notifier.posted.last?.body ?? "nil")")

    // a recording that cannot start: the text depends on the cause, each cause is reported once per 30 minutes
    func failure(_ error: Error, disk: Double? = nil) -> AppNotification? {
        let h = Harness("rec-notify-failure-\(UUID().uuidString.prefix(6))", in: base) { $0.notifyRecording = true }
        h.startError = error
        if let d = disk { h.freeDisk = d }
        h.run(until: { h.recorders.count >= 1 || h.notifier.count(.recordingFailed) >= 1 }, limit: 15, [zoom])
        h.sync()
        return h.notifier.posted.last { $0.kind == .recordingFailed }
    }
    let mic = failure(RecorderError.permissionDenied("microphone: permission denied: microphone access is denied; system audio: recorder failed: tap failed"))
    check(mic?.action == .openSettings(NotificationSettingsPane.microphone) && mic?.subtitle == "마이크 권한이 필요해요", "microphone denied: the microphone pane", "\(mic.map { "\($0.subtitle) \($0.action)" } ?? "nil")")
    let both = failure(RecorderError.permissionDenied("microphone: permission denied: a; system audio: permission denied: b"))
    check(both?.action == .openSettings(NotificationSettingsPane.privacy), "both denied: Privacy & Security", "\(both?.action.name ?? "nil")")
    let device = failure(RecorderError.deviceUnavailable("no default audio input device (microphone)"))
    check(device?.action == .openLog(Log.fileURL.path) && device?.subtitle == "오디오 장치를 쓸 수 없어요", "device unavailable: the click opens app.log", "\(device.map { "\($0.subtitle) \($0.action)" } ?? "nil")")
    let full = failure(RecorderError.failed("unused"), disk: 1)
    check(full?.subtitle == "저장 공간이 부족해요" && full?.action == .openLog(Log.fileURL.path), "disk full: says so, the click opens app.log", "\(full?.subtitle ?? "nil")")

    // each cause has its own 30 minute window: a device problem does not hide the permission problem that follows it
    let kinds = Harness("rec-notify-kinds", in: base) { $0.notifyRecording = true }
    kinds.startError = RecorderError.deviceUnavailable("Bluetooth is switching profile")
    kinds.run(until: { kinds.notifier.count(.recordingFailed) >= 1 }, limit: 15, [zoom])
    kinds.startError = RecorderError.permissionDenied("microphone: permission denied: microphone access is denied")
    kinds.run(until: { kinds.notifier.count(.recordingFailed) >= 2 }, limit: 600, [zoom])
    let causes = kinds.notifier.posted.filter { $0.kind == .recordingFailed }
    check(causes.count == 2 && causes[0].subtitle == "오디오 장치를 쓸 수 없어요" && causes[1].subtitle == "마이크 권한이 필요해요",
          "a different cause inside the 30 minutes is reported (device first, then the microphone permission)", "\(causes.map { $0.subtitle })")
    kinds.run(25 * 60, step: 2, [zoom])
    check(kinds.notifier.count(.recordingFailed) == 2 && kinds.recorders.count >= 4, "... and the same cause again inside the window is not repeated", "attempts \(kinds.recorders.count), posted \(kinds.notifier.count(.recordingFailed))")
}

// MARK: - Calls of other apps: controller, texts, menu, session.json (docs/DETECTION.md section 3b)

private func callSignal(_ id: String, name: String, kind: CallKind = .known, conf: Confidence = .high, on: Bool = true) -> PlatformSignal {
    var s = PlatformSignal(platform: .call, inCall: on, confidence: conf, titleHint: nil, meetingURL: nil, meetingKey: id.lowercased(), bundleID: id, evidence: ["selftest"])
    s.appName = name
    s.callKind = kind
    return s
}

private let slackName = "Slack huddle"
private let slackBundle = "com.tinyspeck.slackmacgap"
private let voiceBundle = "com.example.voicechat"

private func testCallController(_ base: URL) {
    section("calls of other apps: the controller (start, notifications, never record, no double start)")
    let now = Date(timeIntervalSince1970: 1_000_000)

    // a known app: the normal start / stop notifications with the app's name
    let knownStore = CallAppStore(file: nil)
    let known = Harness("call-known", in: base, callApps: knownStore) { $0.notifyRecording = true }
    let slack = callSignal(slackBundle, name: slackName)
    known.run(until: { !known.recorders.isEmpty }, limit: 15, [slack])
    known.sync()
    guard let rec = known.current else { check(false, "a known call app starts a recording"); return }
    check(rec.dir.lastPathComponent == "2026-10-07_1400_call" && rec.signal.platform == .call && rec.signal.bundleID == slackBundle && rec.signal.displayLabel == slackName,
          "the staging folder is YYYY-MM-DD_HHMM_call; the recorder gets the call signal", rec.dir.lastPathComponent)
    let started = known.notifier.posted.first
    check(known.notifier.posted.count == 1 && started?.kind == .recordingStarted && started?.title == "녹음 시작 · \(slackName)" && started?.body.contains("\(slackName) 회의 녹음을 시작했어요") == true,
          "a known app posts the normal start notification with its name", "\(started.map { "\($0.title) | \($0.body)" } ?? "nil")")
    check(known.state.callApp == CallAppView(name: slackName, bundleID: slackBundle, generic: false, key: slackBundle), "the state names the app (not generic) and carries its decision key")
    let menu = StatusMenuController.menuText(for: known.state, now: known.clock.now)
    let knownNever = StatusMenuController.neverRecordItemState(for: known.state)
    check(menu.headline.hasPrefix("Recording \(slackName)") && knownNever.visible && knownNever.title == "Never record \(slackName)" && knownNever.tooltip?.contains(slackName) == true,
          "the menu says 'Recording Slack huddle' and offers 'Never record Slack huddle' for a NAMED app too", "\(menu.headline) | \(knownNever)")
    check(knownStore.decision(for: slackBundle) == .allowed && knownStore.entries().first?.name == slackName, "a known app is listed as allowed after its first recording (the Call Apps submenu can flip it)")
    known.run(70, [slack])                  // 60 s or more of inCall: the end is announced at once (a shorter call waits for the pipeline, testZoomTierNotifications)
    known.run(until: { !rec.isRecording }, limit: 90, [callSignal(slackBundle, name: slackName, on: false)])
    known.sync()
    let stop = known.notifier.posted.last { $0.kind == .recordingStopped }
    check(rec.stopReasons == [.meetingEnded] && stop?.subtitle.hasPrefix("\(slackName) · ") == true, "the call ends after the grace; the end notification names the app", "\(rec.stopReasons) \(stop?.subtitle ?? "nil")")
    check(known.state.callApp == nil, "the app is gone from the state after the recording")
    check(known.pipeline.enqueued.count == 1, "the session is queued for the pipeline like any other")

    // 'Never record' on a NAMED app: denied, stopped like Stop Recording Now, and not started again
    let namedStore = CallAppStore(file: nil)
    let named = Harness("call-named-never", in: base, callApps: namedStore) { $0.notifyRecording = true }
    named.run(until: { !named.recorders.isEmpty }, limit: 15, [slack])
    let namedRec = named.current
    named.run(10, [slack])
    named.controller.neverRecordCurrentCallApp(); named.sync()
    check(namedStore.isDenied(slackBundle) && namedRec?.isRecording == false && namedRec?.stopReasons == [.manual] && named.pipeline.enqueued.count == 1,
          "'Never record' on a known app (Slack huddle): denied, the recording is stopped like Stop Recording Now (kept and queued)", "\(namedStore.decision(for: slackBundle).map { $0.rawValue } ?? "nil") \(namedRec?.stopReasons ?? [])")
    named.run(300, step: 2, [slack])
    check(named.recorders.count == 1, "... and the huddle that is still on is not recorded again")
    named.controller.setCallDecision(bundleID: slackBundle, decision: .allowed); named.sync()
    named.run(60, [])                                           // the huddle ends (the stop by hand holds until the meeting has ended once)
    named.run(until: { named.recorders.count == 2 }, limit: 30, [slack])
    check(named.recorders.count == 2, "... until the Call Apps submenu allows it again (and the next huddle is recorded)", "\(named.recorders.count)")

    // a call app in a browser tab: the decision is kept per SITE (the browser's own id is never denied)
    let webStore = CallAppStore(file: nil)
    let web = Harness("call-web-never", in: base, callApps: webStore)
    var whereby = PlatformSignal(platform: .call, inCall: true, confidence: .high, meetingKey: "web:whereby", bundleID: "com.google.Chrome", evidence: ["selftest"])
    whereby.appName = "Whereby"
    whereby.callKind = .web
    web.run(until: { !web.recorders.isEmpty }, limit: 15, [whereby])
    check(web.state.callApp == CallAppView(name: "Whereby", bundleID: "com.google.Chrome", generic: false, key: "web:whereby") && webStore.decision(for: "web:whereby") == .allowed && webStore.decision(for: "com.google.Chrome") == nil,
          "a meeting page is listed under web:whereby, not under Chrome's bundle id", "\(webStore.entries().map { $0.id })")
    web.controller.neverRecordCurrentCallApp(); web.sync()
    check(webStore.isDenied("web:whereby") && !webStore.isDenied("com.google.Chrome") && web.current?.isRecording == false, "'Never record' for a meeting page denies the site and stops the recording")
    web.run(120, step: 2, [whereby])
    check(web.recorders.count == 1, "... and the page is not recorded again")

    // a generic app: one explaining notification, even with NOTIFY_RECORDING=0
    let store = CallAppStore(file: nil)
    let generic = Harness("call-generic", in: base, callApps: store) { $0.notifyRecording = false }
    let voice = callSignal(voiceBundle, name: "Voice Chat", kind: .generic, conf: .low)
    generic.run(until: { !generic.recorders.isEmpty }, limit: 15, [voice])
    generic.sync()
    let n = generic.notifier.posted
    check(generic.recorders.count == 1 && n.count == 1 && n[0].kind == .recordingStarted, "a generic call posts its notification although NOTIFY_RECORDING=0 (it is the one sign of a guess)", "\(n.map { $0.kind.rawValue })")
    check(n[0].title == "녹음 시작 · Voice Chat" && n[0].subtitle.contains("Voice Chat") && n[0].subtitle.contains("통화로 보여 녹음을 시작했어요") && n[0].body.contains("> Never record Voice Chat") && !n[0].sound,
          "it names the app and says how to stop it for good", "\(n[0].title) | \(n[0].subtitle) | \(n[0].body)")
    check(generic.state.callApp == CallAppView(name: "Voice Chat", bundleID: voiceBundle, generic: true, key: voiceBundle), "the state marks the app as generic")
    let never = StatusMenuController.neverRecordItemState(for: generic.state)
    check(never.visible && never.title == "Never record Voice Chat" && never.tooltip?.isEmpty == false, "the menu offers 'Never record Voice Chat' while it records", "\(never)")
    check(store.decision(for: voiceBundle) == .allowed && store.entries().first?.name == "Voice Chat", "the app is listed as allowed in the decisions after its first recording")

    // 'Never record': denied, stopped like Stop Recording Now (kept), never started again
    let rec2 = generic.current
    generic.run(10, [voice])
    generic.controller.neverRecordCurrentCallApp(); generic.sync()
    check(store.isDenied(voiceBundle) && rec2?.isRecording == false && rec2?.stopReasons == [.manual] && generic.pipeline.enqueued.count == 1, "'Never record' denies the app and ends the recording like Stop Recording Now (it is kept and queued)",
          "\(store.decision(for: voiceBundle).map { $0.rawValue } ?? "nil") \(rec2?.stopReasons ?? [])")
    generic.run(300, step: 2, [voice])
    check(generic.recorders.count == 1, "... and the app that is still in its 'call' is not recorded again", "\(generic.recorders.count)")
    check(logText().contains("never record") || logText().contains("'never record'"), "the log says why")
    generic.run(60, [])
    generic.run(120, step: 2, [voice])
    check(generic.recorders.count == 1, "... not even after a pause: the decision is kept")

    // a decision made while idle (the submenu), and flipping back
    let idle = Harness("call-decide", in: base, callApps: CallAppStore(file: nil))
    idle.controller.setCallDecision(bundleID: voiceBundle, decision: .denied); idle.sync()
    idle.run(60, [voice])
    check(idle.recorders.isEmpty, "an app denied while idle never starts, even when the detector reports it (second line of defence)")
    idle.controller.setCallDecision(bundleID: voiceBundle, decision: .allowed); idle.sync()
    idle.run(until: { !idle.recorders.isEmpty }, limit: 30, [voice])
    check(idle.recorders.count == 1, "allowed again: it starts")
    let noStore = Harness("call-nostore", in: base)
    noStore.run(until: { !noStore.recorders.isEmpty }, limit: 30, [voice])
    noStore.controller.neverRecordCurrentCallApp(); noStore.controller.setCallDecision(bundleID: voiceBundle, decision: .denied); noStore.sync()
    check(noStore.current?.isRecording == true, "without a decision store 'never record' changes nothing and does not crash")

    // never while another recording runs, never twice
    let manual = Harness("call-manual", in: base) { $0.notifyRecording = true }
    manual.controller.startRecordingNow(); manual.sync()
    manual.run(120, step: 2, [slack, callSignal(voiceBundle, name: "Voice Chat", kind: .generic, conf: .low)])
    check(manual.recorders.count == 1 && manual.state.manualRecording && manual.notifier.count(.recordingStarted) == 1, "a manual recording is running: no call app starts a second one", "\(manual.recorders.count)")
    let zoom = Harness("call-zoom", in: base)
    zoom.run(until: { !zoom.recorders.isEmpty }, limit: 15, [zoomSignal(), slack])
    zoom.run(200, step: 2, [zoomSignal(), slack])
    check(zoom.recorders.count == 1 && zoom.current?.signal.platform == .zoom, "a Zoom recording is running: a Slack huddle at the same time starts nothing", "\(zoom.recorders.map { $0.signal.platform.rawValue })")
    let one = Harness("call-one", in: base)
    one.run(1200, step: 2, [slack, callSignal("com.hnc.Discord", name: "Discord")])
    check(one.recorders.count == 1 && one.sessionDirNames().count == 1, "20 minutes with two call apps in their calls: one recording, one session folder", "\(one.recorders.count) \(one.sessionDirNames())")
    let again = Harness("call-flicker", in: base)
    again.run(until: { !again.recorders.isEmpty }, limit: 15, [slack])
    for _ in 0..<40 {
        again.run(2, [callSignal(slackBundle, name: slackName, on: false)])
        again.run(8, [slack])
    }
    check(again.recorders.count == 1 && again.current?.isRecording == true, "dropouts of a few seconds inside the grace never split the recording")

    // A call app never blocks Zoom / Teams: Slack first, then Zoom joins: the huddle recording ends and the Zoom meeting is recorded
    let pre = Harness("call-preempt", in: base)
    pre.run(until: { !pre.recorders.isEmpty }, limit: 15, [slack])
    let huddle = pre.current
    pre.run(60, step: 2, [slack])
    pre.run(until: { pre.recorders.count == 2 }, limit: 40, [slack, zoomSignal()])
    pre.sync()
    check(pre.recorders.count == 2 && huddle?.isRecording == false && huddle?.stopReasons == [.meetingEnded] && pre.current?.signal.platform == .zoom && pre.current?.isRecording == true && pre.pipeline.enqueued.count == 1,
          "Zoom joins while a Slack huddle is recorded: the huddle recording is ended (kept and queued) and Zoom is recorded", "\(pre.recorders.count) \(huddle?.stopReasons ?? []) \(pre.current?.signal.platform.rawValue ?? "-")")
    check(logCount("split: meeting changed (call:\(slackBundle) -> zoom:") >= 1, "the log names the split")
    pre.run(300, step: 2, [slack, zoomSignal()])
    check(pre.recorders.count == 2, "... and the huddle that is still on never starts a third recording during the Zoom meeting", "\(pre.recorders.count)")
    // the other direction: one line in the log for the meeting that is not recorded separately (once, not once per poll)
    let before = logCount("is in a call while the recording zoom:- runs")
    let ignored = Harness("call-ignored", in: base)
    ignored.run(until: { !ignored.recorders.isEmpty }, limit: 15, [zoomSignal(), slack])
    ignored.run(200, step: 2, [zoomSignal(), slack])
    check(logCount("detect: call:\(slackBundle) is in a call while the recording zoom:") >= 1 && logCount("is in a call while the recording zoom:- runs") - before <= 1,
          "a call app that is on while Zoom is recorded gets ONE log line (it is not recorded separately), not one per poll", "\(logCount("is in a call while the recording zoom:- runs") - before)")

    // the kill switch (recording.enabled=false) and a call app: nothing starts, nothing is announced as a failure (log only); Zoom keeps the banner
    let kill = loHarness("call-kill", in: base, policy: loPolicy(["recording": ["enabled": false]]))
    kill.run(150, step: 2, [slack])
    check(kill.recorders.isEmpty && kill.notifier.count(.recordingFailed) == 0 && logCount("call:\(slackBundle) skipped: recording is switched off by the organisation policy") >= 1,
          "recording.enabled=false: a call app does not start and raises no 'Recording failed' banner (one log line)", "recorders \(kill.recorders.count), failures \(kill.notifier.count(.recordingFailed))")
    check(logCount("call:\(slackBundle) skipped: recording is switched off by the organisation policy") <= 2, "... and it is asked again only after the long lockout, not every few seconds", "\(logCount("call:\(slackBundle) skipped: recording is switched off by the organisation policy"))")
    let killZoom = loHarness("call-kill-zoom", in: base, policy: loPolicy(["recording": ["enabled": false]]))
    killZoom.run(60, step: 2, [zoomSignal()])
    check(killZoom.recorders.isEmpty && killZoom.notifier.count(.recordingFailed) >= 1, "(control: a Zoom meeting under the same policy still raises the failure notification)", "failures \(killZoom.notifier.count(.recordingFailed))")

    // the menu text of a candidate
    var cand = ControllerState()
    cand.status = .candidate(.call)
    cand.callApp = CallAppView(name: "Voice Chat", bundleID: voiceBundle, generic: true)
    check(StatusMenuController.menuText(for: cand, now: now).headline == "Meeting detected: Voice Chat" && !StatusMenuController.neverRecordItemState(for: cand).visible, "a call app candidate: 'Meeting detected: Voice Chat'")
    var plain = ControllerState()
    plain.status = .candidate(.call)
    check(StatusMenuController.menuText(for: plain, now: now).headline == "Meeting detected: Call", "without an app name the label is 'Call'")
    var other = ControllerState()
    other.status = .recording(.zoom, since: now)
    other.callApp = CallAppView(name: "Voice Chat", bundleID: voiceBundle, generic: true)
    check(StatusMenuController.menuText(for: other, now: now).headline.hasPrefix("Recording Voice Chat"), "(the headline follows the app name whenever the state carries one)")
    check(StatusMenuController.menuText(for: { var z = ControllerState(); z.status = .recording(.zoom, since: now); return z }(), now: now).headline.hasPrefix("Recording Zoom"), "Zoom's headline is unchanged")
}

private func testCallTexts() {
    section("calls of other apps: notification texts, the Call Apps menu")
    func call(_ name: String?) -> PlatformSignal {
        var s = PlatformSignal(platform: .call, inCall: true)
        s.appName = name
        return s
    }
    check(NotificationText.platformName(call("Slack huddle")) == "Slack huddle" && NotificationText.platformName(call(nil)) == "통화" && NotificationText.platformName(call("")) == "통화"
          && NotificationText.platformName(PlatformSignal(platform: .zoom, inCall: true)) == "Zoom" && NotificationText.platformName(PlatformSignal(platform: .manual, inCall: true)) == "수동",
          "platformName(signal): the app's name for a call, the platform's words for everything else")
    check(NotificationText.platformName(call(String(repeating: "N", count: 200))).count <= CallApps.maxNameLength, "a long app name is cut")
    for name in ["Slack huddle", "A", String(repeating: "N", count: 40), "한국어 앱 이름", "Evil \u{1B}[31mName"] {
        let n = AppNotification.genericCallStarted(appName: name, session: "2026-10-07_1400_call", folder: URL(fileURLWithPath: "/tmp/x"))
        check(!n.title.isEmpty && !n.subtitle.isEmpty && !n.body.isEmpty && n.title.count <= NotificationText.titleLimit && n.subtitle.count <= NotificationText.subtitleLimit && n.body.count <= NotificationText.bodyLimit
              && !n.sound && n.kind == .recordingStarted && n.identifier == "mcap.recording-started.2026-10-07_1400_call" && n.action == .openFolder("/tmp/x"),
              "generic notification for '\(name.prefix(12))': complete, within the banner limits, no sound, same identifier as the normal start", "\(n.title) | \(n.subtitle) | \(n.body)")
        check(n.body.contains("> Never record") && !n.title.unicodeScalars.contains { NotificationText.isStrippedScalar($0) }, "... says where 'Never record' is, and carries no control character")
    }
    check(AppNotification.genericCallStarted(appName: "Slack", session: "s", folder: nil).summary == "Slack looks like a call: recording started. Not a call? Menu > Never record Slack (s)", "the log line is the sentence of the task, in English")
    let saved = L10n.current
    L10n.current = .en
    let en = AppNotification.genericCallStarted(appName: "Slack", session: "s", folder: nil)
    check(en.subtitle == "Slack looks like a call: recording started" && en.body == "Not a call? Menu > Never record Slack" && en.title == "Recording started · Slack", "English: 'Slack looks like a call: recording started' / 'Not a call? Menu > Never record Slack'", "\(en.title) | \(en.subtitle) | \(en.body)")
    L10n.current = saved

    // the submenu
    let entries = [CallAppEntry(id: "com.example.a", name: "Alpha", decision: .allowed), CallAppEntry(id: "com.example.b", name: "Beta", decision: .denied)]
    let allowed = StatusMenuController.callAppItemState(entries[0])
    let denied = StatusMenuController.callAppItemState(entries[1])
    check(allowed.title == "Alpha" && allowed.checked && allowed.tooltip.contains("com.example.a") && denied.title == "Beta (녹음 안 함)" && !denied.checked && denied.tooltip.contains("com.example.b"),
          "the submenu rows: allowed = checked, denied = 'never record'", "\(allowed) \(denied)")
    check(StatusMenuController.callAppItemState(CallAppEntry(id: "x.y", name: String(repeating: "N", count: 100), decision: .allowed)).title.count <= 40, "a long name is cut in the menu")
    check(StatusMenuController.callAppsMenuHeader(entries: [], problem: nil).count == 1 && StatusMenuController.callAppsMenuHeader(entries: entries, problem: nil).count == 1
          && StatusMenuController.callAppsMenuHeader(entries: [], problem: "call-apps.json is not valid JSON").count == 2 && StatusMenuController.callAppsMenuHeader(entries: [], problem: "call-apps.json is not valid JSON")[0].contains("call-apps.json"),
          "the submenu header: empty, normal, and the unreadable-file warning")
    var rec = ControllerState()
    rec.status = .recording(.call, since: Date())
    rec.callApp = CallAppView(name: "Voice Chat", bundleID: voiceBundle, generic: true)
    var idle = rec
    idle.status = .idle
    var manual = rec
    manual.callApp = nil
    check(StatusMenuController.neverRecordItemState(for: rec).visible && !StatusMenuController.neverRecordItemState(for: idle).visible && !StatusMenuController.neverRecordItemState(for: manual).visible,
          "'Never record <App>' shows only while a call of another app is recording")
    var named = rec
    named.callApp = CallAppView(name: "Slack huddle", bundleID: slackBundle, generic: false, key: slackBundle)
    let namedNever = StatusMenuController.neverRecordItemState(for: named)
    check(namedNever.visible && namedNever.title == "Never record Slack huddle" && namedNever.tooltip?.isEmpty == false && namedNever.tooltip != StatusMenuController.neverRecordItemState(for: rec).tooltip,
          "... for a named app as well, with its own tooltip (it is not described as a guess)")
    check(CallAppView(name: "A", bundleID: "Com.Example.A", generic: false).decisionKey == "com.example.a" && CallAppView(name: "W", bundleID: "com.google.Chrome", generic: false, key: "web:whereby").decisionKey == "web:whereby",
          "the decision key: the lower case bundle id, or the explicit key (a meeting page)")

    // the rows of the Call Apps submenu: the table, the extra apps and the sites are there before any recording
    let settings = CallDetectSettings(mode: .known, extraApps: [ExtraCallApp(id: "com.example.talk", name: "Example Talk")], browserURLs: true)
    let rows = StatusMenuController.callAppRows(entries: [CallAppEntry(id: "net.whatsapp.whatsapp", name: "WhatsApp", decision: .denied), CallAppEntry(id: "com.other.app", name: "Other", decision: .allowed)], settings: settings)
    let ids = rows.map { $0.id }
    check(CallApps.known.allSatisfy { ids.contains($0.id.lowercased()) } && ids.contains("com.example.talk") && ids.contains("com.other.app") && ids.contains("web:whereby") && ids.contains("web:jitsi")
          && rows.count == CallApps.known.count + 1 + 1 + WebMeetingURL.sites.count, "every app of the table, every extra app, every meeting-page site and every stored app is a row (no duplicates)", "\(rows.count) rows")
    check(rows.first { $0.id == "net.whatsapp.whatsapp" }?.decision == .denied && rows.first { $0.id == "cisco-systems.spark" }?.decision == .allowed && rows.first { $0.id == "cisco-systems.spark" }?.name == "Cisco Webex",
          "a stored decision wins over the table (WhatsApp stays denied); an app without a decision is shown as recorded, with the table's name")
    let sortKeys = rows.map { $0.name.lowercased() + "\u{0}" + $0.id }
    check(sortKeys == sortKeys.sorted(), "the rows are sorted by name, then id")
    let noWeb = StatusMenuController.callAppRows(entries: [], settings: CallDetectSettings(mode: .known))
    check(noWeb.count == CallApps.known.count && !noWeb.contains { $0.id.hasPrefix("web:") }, "meeting-page rows only appear with CALL_BROWSER_URLS on")
    check(StatusMenuController.neverRecordItemState(for: { var r = rec; r.callApp = CallAppView(name: String(repeating: "N", count: 100), bundleID: "a.b", generic: true); return r }()).title.count <= 13 + 30, "... with a cut name")
}

private func testCallRecorderKeys(_ base: URL) {
    section("calls of other apps: session.json of a real Recorder (synthetic sources)")
    let fm = FileManager.default
    let root = base.appendingPathComponent("call-recorder", isDirectory: true)
    var cfg = AppConfig.defaults()
    cfg.supportDir = root.appendingPathComponent("support", isDirectory: true)
    let baseKeys: Set<String> = ["schema", "session_id", "platform", "platform_label", "title_hint", "meeting_url", "app_bundle_id",
                                 "start_time", "end_time", "end_reason", "tracks", "app_version", "warnings", "remote_silent_suspected"]
    func make(_ id: String, _ signal: PlatformSignal) -> (Recorder, URL) {
        let dir = root.appendingPathComponent("sessions/\(id)", isDirectory: true)
        try? fm.removeItem(at: dir)
        let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: 0.3)
        let mic = SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200, amplitude: 0.1)
        return (Recorder(sessionDir: dir, signal: signal, config: cfg, remote: { remote }, mic: { mic }), dir)
    }
    func json(_ dir: URL) -> [String: Any] { ShellUtil.readJSON(dir.appendingPathComponent("session.json")) ?? [:] }

    var call = PlatformSignal(platform: .call, inCall: true, confidence: .high, titleHint: nil, meetingURL: nil, meetingKey: slackBundle, bundleID: slackBundle, evidence: [])
    call.appName = slackName
    call.callKind = .known
    let (a, aDir) = make("2026-10-07_1400_call", call)
    do { try a.start() } catch { check(false, "call recorder start()", "\(error)"); return }
    Thread.sleep(forTimeInterval: 0.4)
    _ = a.stop(reason: .meetingEnded)
    let j = json(aDir)
    check(Set(j.keys) == baseKeys.union(["app_name", "call_kind"]), "a call's session.json has the SPEC 4.1 keys plus app_name and call_kind", "\(Set(j.keys).symmetricDifference(baseKeys))")
    check(j["platform"] as? String == "call" && j["platform_label"] as? String == slackName && j["app_bundle_id"] as? String == slackBundle && j["app_name"] as? String == slackName && j["call_kind"] as? String == "known"
          && j["session_id"] as? String == "2026-10-07_1400_call" && j["end_reason"] as? String == "meeting-ended" && j["title_hint"] is NSNull && j["meeting_url"] is NSNull,
          "platform call, the app's name as label, bundle id, name and kind; no title and no address", "\(j["platform"] ?? "") \(j["platform_label"] ?? "") \(j["call_kind"] ?? "")")
    check(PipelineFacts.recording(in: aDir)?.platform == .call, "the launcher reads the platform of a call session")

    var web = PlatformSignal(platform: .call, inCall: true, confidence: .high, meetingKey: "web:whereby", bundleID: "com.google.Chrome", evidence: [])
    web.appName = "Whereby"
    web.callKind = .web
    let (w, wDir) = make("2026-10-07_1500_call", web)
    do { try w.start() } catch { check(false, "web call recorder start()", "\(error)"); return }
    _ = w.stop(reason: .manual)
    check(json(wDir)["call_kind"] as? String == "web" && json(wDir)["app_bundle_id"] as? String == "com.google.Chrome" && json(wDir)["platform_label"] as? String == "Whereby", "a browser meeting page: kind web, the browser's id, the site's name")

    // the other platforms keep exactly their keys
    let zoom = PlatformSignal(platform: .zoom, inCall: true, confidence: .high, titleHint: nil, meetingURL: nil, meetingKey: nil, bundleID: "us.zoom.xos", evidence: [])
    let (z, zDir) = make("2026-10-07_1600_zoom", zoom)
    do { try z.start() } catch { check(false, "zoom recorder start()", "\(error)"); return }
    _ = z.stop(reason: .manual)
    check(Set(json(zDir).keys) == baseKeys && json(zDir)["platform_label"] as? String == "Zoom", "a Zoom session.json has exactly the keys it always had (no app_name, no call_kind)")
    var odd = call
    odd.appName = nil
    odd.callKind = nil
    let (o, oDir) = make("2026-10-07_1700_call", odd)
    do { try o.start() } catch { check(false, "odd recorder start()", "\(error)"); return }
    _ = o.stop(reason: .manual)
    check(json(oDir)["platform_label"] as? String == "Call" && json(oDir)["app_name"] is NSNull && json(oDir)["call_kind"] is NSNull, "a call signal without a name still writes a label ('Call') and null name / kind")
}

// MARK: - Zoom evidence tiers: config keys

private func testZoomTierConfig(_ base: URL) {
    section("ZOOM_STRONG_SOCKETS / ZOOM_WEAK_DEBOUNCE_SECONDS: defaults, parsing, validation")
    let d = ZoomTierSettings.defaults
    check(d.strongSockets == 6 && d.weakDebounce == 15 && ZoomTierSettings.defaultStrongSockets == 6 && ZoomTierSettings.defaultWeakDebounce == 15, "defaults: 6 sockets, 15 s")
    let none = ZoomTierSettings.build(from: [:], source: "selftest")
    check(none == d, "no keys -> the defaults")
    check(ZoomTierSettings.build(from: ["ZOOM_STRONG_SOCKETS": "8", "ZOOM_WEAK_DEBOUNCE_SECONDS": "20"], source: "selftest") == ZoomTierSettings(strongSockets: 8, weakDebounce: 20), "both keys parsed")
    check(ZoomTierSettings.build(from: ["ZOOM_STRONG_SOCKETS": "8.0"], source: "selftest").strongSockets == 8, "a whole number written as 8.0 is accepted")
    check(ZoomTierSettings.build(from: ["ZOOM_STRONG_SOCKETS": "1"], source: "selftest").strongSockets == 1 && ZoomTierSettings.build(from: ["ZOOM_STRONG_SOCKETS": "64"], source: "selftest").strongSockets == 64, "ZOOM_STRONG_SOCKETS 1 and 64 are the limits")
    for bad in ["0", "-2", "65", "6.5", "abc", "nan", "inf", "1e9"] {
        let before = logCount("ZOOM_STRONG_SOCKETS=\(bad) must be a whole number")
        let c = ZoomTierSettings.build(from: ["ZOOM_STRONG_SOCKETS": bad], source: "selftest")
        check(c.strongSockets == 6 && logCount("ZOOM_STRONG_SOCKETS=\(bad) must be a whole number") == before + 1, "ZOOM_STRONG_SOCKETS='\(bad)' keeps the default and logs a warning", "\(c.strongSockets)")
    }
    check(ZoomTierSettings.build(from: ["ZOOM_STRONG_SOCKETS": ""], source: "selftest").strongSockets == 6, "an empty ZOOM_STRONG_SOCKETS is the default (no warning needed)")

    check(ZoomTierSettings.build(from: ["ZOOM_WEAK_DEBOUNCE_SECONDS": "0"], source: "selftest").weakDebounce == 0, "ZOOM_WEAK_DEBOUNCE_SECONDS=0 switches the extra wait off")
    check(ZoomTierSettings.build(from: ["ZOOM_WEAK_DEBOUNCE_SECONDS": "7.5"], source: "selftest").weakDebounce == 7.5 && ZoomTierSettings.build(from: ["ZOOM_WEAK_DEBOUNCE_SECONDS": "300"], source: "selftest").weakDebounce == 300, "fractions and the upper limit are accepted")
    for (value, expected) in [("0.5", 1.0), ("1000", 300.0), ("301", 300.0)] {
        let before = logCount("ZOOM_WEAK_DEBOUNCE_SECONDS=\(value) is outside")
        let c = ZoomTierSettings.build(from: ["ZOOM_WEAK_DEBOUNCE_SECONDS": value], source: "selftest")
        check(c.weakDebounce == expected && logCount("ZOOM_WEAK_DEBOUNCE_SECONDS=\(value) is outside") == before + 1, "ZOOM_WEAK_DEBOUNCE_SECONDS=\(value) is clamped to \(expected) with a warning", "\(c.weakDebounce)")
    }
    for bad in ["-5", "abc", "nan", "inf"] {
        let c = ZoomTierSettings.build(from: ["ZOOM_WEAK_DEBOUNCE_SECONDS": bad], source: "selftest")
        check(c.weakDebounce == 15, "ZOOM_WEAK_DEBOUNCE_SECONDS='\(bad)' keeps the default", "\(c.weakDebounce)")
    }
    check(logCount("ZOOM_WEAK_DEBOUNCE_SECONDS=-5 is negative") >= 1 && logCount("ZOOM_WEAK_DEBOUNCE_SECONDS=abc is not a number") >= 1, "invalid ZOOM_WEAK_DEBOUNCE_SECONDS values are logged as warnings")

    // the same keys through a config.env file; an unreadable file means the defaults; the rest of the config is not affected
    let dir = base.appendingPathComponent("tier-config", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.env")
    try? "# Zoom\nZOOM_STRONG_SOCKETS=5   # inline comment\nZOOM_WEAK_DEBOUNCE_SECONDS=25\nSTART_DEBOUNCE_SECONDS=6\n".write(to: file, atomically: true, encoding: .utf8)
    check(ZoomTierSettings.load(from: file) == ZoomTierSettings(strongSockets: 5, weakDebounce: 25), "load(from:) reads both keys from config.env (inline comments stripped)")
    check(AppConfig.load(from: file).startDebounce == 6, "AppConfig.load ignores the Zoom tier keys and still reads its own")
    check(ZoomTierSettings.load(from: dir.appendingPathComponent("missing.env")) == .defaults, "a missing config.env means the defaults")
    let summary = ZoomTierSettings.defaults.summary
    check(summary.contains("sockets >= 6") && summary.contains("input running") && summary.contains("15 s"), "the log summary names the thresholds", summary)
    check(ZoomTierSettings(strongSockets: 6, weakDebounce: 0).summary.contains("no extra wait"), "the summary says so when the extra wait is off")
}

// MARK: - Zoom evidence tiers: notifications and the pipeline outcome

private func testZoomTierNotifications(_ base: URL) {
    section("zoom evidence tiers: no banner for a non-meeting (weak flicker, unconfirmed weak start, discarded short call)")
    let none = zoomEvidence(sockets: 0)
    let weak3 = zoomEvidence(sockets: 3), weak4 = zoomEvidence(sockets: 4)
    let strong = zoomEvidence(sockets: 7)
    let strongInput = zoomEvidence(sockets: 4, input: true)
    func isCandidate(_ s: ControllerState) -> Bool { if case .candidate = s.status { return true }; return false }

    // The observed flicker for two hours of virtual time (4 / 6 / 10 / 14 s every 120 s): nothing happens, nothing is announced.
    let flick = Harness("tier-flicker", in: base) { $0.notifyRecording = true }
    let endedBefore = logCount("weak evidence ended after")
    let lengths = [4, 6, 10, 14]
    for cycle in 0..<60 {
        let d = lengths[cycle % lengths.count]
        flick.run(d, step: 2, [weak4])
        flick.run(120 - d, step: 2, [none])
    }
    flick.sync()
    check(flick.recorders.isEmpty && flick.sessionDirNames().isEmpty && flick.pipeline.enqueued.isEmpty && flick.notifier.posted.isEmpty,
          "2 h of idle Zoom flicker (sockets 4, no audio IO): no recording, no session folder, no pipeline job, no notification", "recorders \(flick.recorders.count), posted \(flick.notifier.posted.map { $0.kind.rawValue })")
    check(!flick.states.contains(where: isCandidate) && flick.state.status == .idle, "... and the menu never says 'meeting detected' for it")
    check(logCount("weak evidence ended after") - endedBefore >= 58, "... each flicker leaves one log line saying it ended without a recording", "\(logCount("weak evidence ended after") - endedBefore)")

    // The control: with ZOOM_WEAK_DEBOUNCE_SECONDS=0 (the behaviour before the tiers) the same flicker records and announces.
    let legacy = Harness("tier-flicker-legacy", in: base, zoomTier: ZoomTierSettings(strongSockets: 6, weakDebounce: 0)) { $0.notifyRecording = true }
    legacy.run(14, step: 2, [weak4])
    legacy.run(120, step: 2, [none])
    legacy.sync()
    check(legacy.recorders.count == 1 && legacy.notifier.count(.recordingStarted) == 1, "(control: with ZOOM_WEAK_DEBOUNCE_SECONDS=0 a 14 s flicker starts a recording and announces it, as before)", "\(legacy.recorders.count)")

    // A strong start announces itself at once.
    let st = Harness("tier-strong", in: base) { $0.notifyRecording = true }
    st.run(until: { !st.recorders.isEmpty }, limit: 15, [strong])
    st.sync()
    check(st.notifier.count(.recordingStarted) == 1 && st.notifier.posted.count == 1, "a recording that starts on strong evidence posts the start notification at once", "\(st.notifier.posted.map { $0.kind.rawValue })")
    let sti = Harness("tier-strong-input", in: base) { $0.notifyRecording = true }
    sti.run(until: { !sti.recorders.isEmpty }, limit: 15, [strongInput])
    sti.sync()
    check(sti.notifier.count(.recordingStarted) == 1, "... also when the strength is the input (4 sockets + input running)")

    // A weak start that persists is recorded after the weak debounce, announced only once confirmed (20 s of sustained inCall).
    let wk = Harness("tier-weak-start", in: base) { $0.notifyRecording = true }
    let weakStart = wk.run(until: { !wk.recorders.isEmpty }, limit: 40, [weak3])
    wk.sync()
    check(weakStart != nil && (weakStart ?? 0) >= 15 && (weakStart ?? 0) <= 18, "3 sockets without audio IO: recording starts after the 15 s weak debounce", "after \(String(describing: weakStart)) s")
    check(wk.notifier.posted.isEmpty && wk.state.status != .idle, "... and the start notification is held back (recording, not confirmed)", "\(wk.notifier.posted.map { $0.kind.rawValue })")
    wk.run(15, [weak3])
    wk.sync()
    check(wk.notifier.posted.isEmpty, "... still nothing 15 s after the start", "\(wk.notifier.posted.map { $0.kind.rawValue })")
    let confirmedAfter = wk.run(until: { wk.notifier.count(.recordingStarted) >= 1 }, limit: 20, [weak3])
    wk.sync()
    check(confirmedAfter != nil && (confirmedAfter ?? 0) <= 8 && wk.notifier.count(.recordingStarted) == 1, "... posted once 20 s of inCall have passed since the recording started", "\(String(describing: confirmedAfter))")
    check(wk.notifier.posted[0].title == "녹음 시작 · Zoom" && wk.notifier.posted[0].action == .openFolder(wk.current?.dir.path ?? ""), "... with the normal text and click target")
    wk.run(60, [weak3])
    check(wk.notifier.count(.recordingStarted) == 1, "... and it is not repeated")
    wk.run(until: { wk.current?.isRecording == false }, limit: 80, [none])
    wk.sync()
    check(wk.notifier.count(.recordingStopped) == 1 && wk.notifier.posted.last?.kind == .recordingStopped, "a confirmed weak recording of more than 60 s of inCall announces its end at once", "\(wk.notifier.posted.map { $0.kind.rawValue })")

    // A STRONG observation confirms a weak start at once.
    let up = Harness("tier-weak-then-strong", in: base) { $0.notifyRecording = true }
    up.run(until: { !up.recorders.isEmpty }, limit: 40, [weak3])
    up.run(3, [weak3])
    up.sync()
    check(up.notifier.posted.isEmpty, "(setup) weak start, 3 s later, still not announced")
    up.run(1, [strongInput])
    up.sync()
    check(up.notifier.count(.recordingStarted) == 1, "a strong observation (input running) confirms the weak start: the start notification is posted", "\(up.notifier.posted.map { $0.kind.rawValue })")

    // A weak start that is not confirmed (the signal ends first) announces neither its start nor its end.
    let un = Harness("tier-weak-unconfirmed", in: base) { $0.notifyRecording = true }
    un.run(until: { !un.recorders.isEmpty }, limit: 40, [weak3])
    un.run(2, [weak3])
    un.run(until: { un.current?.isRecording == false }, limit: 100, [none])
    un.sync()
    check(un.recorders.count == 1 && un.pipeline.enqueued.count == 1 && un.notifier.posted.isEmpty,
          "a weak recording that ends before it is confirmed: kept for the pipeline, but no start and no end notification", "\(un.notifier.posted.map { $0.kind.rawValue }) enqueued \(un.pipeline.enqueued.count)")
    let unSession = un.current?.dir.lastPathComponent ?? ""
    un.pipeline.onEvent?(.finished(session: unSession, title: nil, finalDir: nil, discarded: true)); un.sync()
    check(un.notifier.posted.isEmpty && logText().contains("no 'recording ended' notification for \(unSession)"), "... and the pipeline discarding it later posts nothing either, the log says why")

    // A weak recording that is deleted as an accidental blip (ended by sleep within 10 s of its start): no banner at all, no leftovers.
    let blip = Harness("tier-weak-blip", in: base) { $0.notifyRecording = true }
    blip.run(until: { !blip.recorders.isEmpty }, limit: 40, [weak3])
    blip.run(3, [weak3])
    blip.controller.systemWillSleep()
    blip.sync()
    check(blip.notifier.posted.isEmpty && blip.pipeline.enqueued.isEmpty && blip.current.map { !FileManager.default.fileExists(atPath: $0.dir.path) } == true,
          "a weak recording deleted as a blip (a few seconds, ended by sleep): no start and no end notification, the folder is gone", "\(blip.notifier.posted.map { $0.kind.rawValue })")

    // A strong session with less than 60 s of inCall: the end notification waits for the pipeline.
    func shortCall(_ name: String) -> (h: Harness, session: String)? {
        let h = Harness(name, in: base) { $0.notifyRecording = true }
        h.run(until: { !h.recorders.isEmpty }, limit: 15, [strong])
        h.run(30, [strong])
        h.run(until: { h.current?.isRecording == false }, limit: 80, [none])
        h.sync()
        guard let rec = h.current else { return nil }
        return (h, rec.dir.lastPathComponent)
    }
    guard let discarded = shortCall("tier-short-discarded"), let kept = shortCall("tier-short-kept"), let failed = shortCall("tier-short-failed") else { check(false, "short strong calls recorded"); return }
    check(discarded.h.notifier.count(.recordingStarted) == 1 && discarded.h.notifier.count(.recordingStopped) == 0 && discarded.h.pipeline.enqueued.count == 1,
          "a short call (30 s of inCall) that started strong: the start was announced, the end waits for the pipeline (session handed over as usual)", "\(discarded.h.notifier.posted.map { $0.kind.rawValue })")
    check(logText().contains("'recording ended' notification for \(discarded.session) held back"), "... the log says it was held back")
    discarded.h.pipeline.onEvent?(.finished(session: discarded.session, title: nil, finalDir: nil, discarded: true)); discarded.h.sync()
    check(discarded.h.notifier.posted.map { $0.kind } == [.recordingStarted] && logText().contains("'recording ended' notification for \(discarded.session) dropped"),
          "... when the pipeline discards the session (no speech) the end notification is dropped: no 'ended' banner for a non-meeting", "\(discarded.h.notifier.posted.map { $0.kind.rawValue })")
    kept.h.pipeline.onEvent?(.finished(session: kept.session, title: "Quick sync", finalDir: nil, discarded: false)); kept.h.sync()
    check(kept.h.notifier.posted.map { $0.kind } == [.recordingStarted, .recordingStopped, .noteReady],
          "... when the pipeline keeps it, the end notification follows, then the note-ready one", "\(kept.h.notifier.posted.map { $0.kind.rawValue })")
    failed.h.pipeline.onEvent?(.failed(session: failed.session, message: "boom")); failed.h.sync()
    check(failed.h.notifier.posted.map { $0.kind } == [.recordingStarted, .recordingStopped, .pipelineFailed], "... when the pipeline fails, the end notification is released before the failure notice", "\(failed.h.notifier.posted.map { $0.kind.rawValue })")
    kept.h.pipeline.onEvent?(.finished(session: kept.session, title: "Quick sync", finalDir: nil, discarded: false)); kept.h.sync()
    check(kept.h.notifier.count(.recordingStopped) == 1, "... and a second outcome event does not post it again")

    // A long strong call (60 s or more of inCall) announces its end at once; so do the explicit stops.
    let long = Harness("tier-long", in: base) { $0.notifyRecording = true }
    long.run(until: { !long.recorders.isEmpty }, limit: 15, [strong])
    long.run(75, [strong])
    long.run(until: { long.current?.isRecording == false }, limit: 80, [none])
    long.sync()
    check(long.notifier.posted.map { $0.kind } == [.recordingStarted, .recordingStopped], "a call with more than 60 s of inCall: the end is announced at once", "\(long.notifier.posted.map { $0.kind.rawValue })")
    let byHand = Harness("tier-stop-now", in: base) { $0.notifyRecording = true }
    byHand.run(until: { !byHand.recorders.isEmpty }, limit: 15, [strong])
    byHand.run(10, [strong])
    byHand.controller.stopRecordingNow(); byHand.sync()
    check(byHand.notifier.posted.map { $0.kind } == [.recordingStarted, .recordingStopped], "Stop Recording Now on a short call: announced at once (the user did it)", "\(byHand.notifier.posted.map { $0.kind.rawValue })")

    // A held notification nobody answers for is dropped after 30 minutes.
    guard let lost = shortCall("tier-short-lost") else { check(false, "short call recorded"); return }
    lost.h.run(31 * 60, step: 30, [none])
    lost.h.pipeline.onEvent?(.finished(session: lost.session, title: "Late", finalDir: nil, discarded: false)); lost.h.sync()
    check(lost.h.notifier.count(.recordingStopped) == 0 && logText().contains("'recording ended' notification for \(lost.session) dropped: no pipeline outcome"),
          "a held end notification the pipeline never answers is dropped after 30 minutes")

    // The pure decision.
    typealias D = SessionController.StopNoticeDecision
    func decide(_ inCall: Double, manual: Bool = false, sent: Bool = true, reason: EndReason = .meetingEnded, label: String? = nil) -> D {
        return SessionController.stopNoticeDecision(manual: manual, startNoticeSent: sent, reason: reason, label: label, inCallSeconds: inCall)
    }
    check(decide(59.9) == .deferUntilOutcome && decide(60) == .post && decide(600) == .post && decide(0) == .deferUntilOutcome, "decision: a normal end with < 60 s of inCall waits, 60 s or more is announced")
    check(decide(600, sent: false) == .skipUnconfirmed && decide(5, sent: false, reason: .manual) == .skipUnconfirmed, "decision: an auto recording whose start was never announced never announces its end")
    check(decide(3, manual: true, sent: false, reason: .manual) == .post && decide(3, manual: true) == .post, "decision: a manual recording always does")
    check(decide(10, reason: .sleep) == .post && decide(10, reason: .diskLow) == .post && decide(10, reason: .maxDuration) == .post && decide(10, reason: .paused) == .post && decide(10, reason: .manual) == .post,
          "decision: sleep, disk low, max duration, Pause and Stop Recording Now are announced at once")
    check(decide(10, label: "no-speech") == .post, "decision: the no-speech stop (a long recording) is announced at once")

    // The menu: a weak candidate is not 'meeting detected', a strong one is.
    let menu = Harness("tier-menu", in: base)
    menu.run(6, [weak4])
    check(menu.state.status == .idle && !menu.states.contains(where: isCandidate), "menu: weak evidence is not 'meeting detected'", "\(menu.state.status)")
    menu.run(1, [strongInput])
    check(menu.recorders.count == 1 && menu.state.status == .recording(.zoom, since: menu.current?.startedAt ?? Date()), "menu: a strong poll turns that run into a meeting at once (it is already older than the start debounce): recording", "\(menu.state.status)")
    let m2 = Harness("tier-menu-strong", in: base)
    m2.run(2, [strong])
    check(isCandidate(m2.state), "menu: a strong candidate shows 'meeting detected' while debouncing", "\(m2.state.status)")

    // A flicker during the grace of a real call does not move the stop; after it nothing starts.
    func stopAfterLast(flicker: Bool) -> Int? {
        let h = Harness("tier-grace-\(flicker)", in: base) { $0.notifyRecording = true }
        h.run(until: { !h.recorders.isEmpty }, limit: 15, [strong])
        h.run(70, [strong])
        var elapsed = 0
        if flicker {
            h.run(10, [none])
            h.run(10, [weak4])
            elapsed = 20
            if h.current?.isRecording == false { return nil }
        }
        let more = h.run(until: { h.current?.isRecording == false }, limit: 120, [none])
        return more.map { $0 + elapsed }
    }
    let plain = stopAfterLast(flicker: false), flickered = stopAfterLast(flicker: true)
    check(plain != nil && plain == flickered && (plain ?? 0) >= 29 && (plain ?? 0) <= 31, "a 10 s weak flicker 10 s after the end of a call: the recording stops exactly when it would have (30 s)", "plain \(String(describing: plain)) flicker \(String(describing: flickered))")
    let after = Harness("tier-after-stop", in: base) { $0.notifyRecording = true }
    after.run(until: { !after.recorders.isEmpty }, limit: 15, [strong])
    after.run(80, [strong])
    after.run(until: { after.current?.isRecording == false }, limit: 80, [none])
    after.run(14, [weak4])
    after.run(120, [none])
    after.sync()
    check(after.recorders.count == 1 && after.notifier.count(.recordingStarted) == 1, "a 14 s flicker right after the stop does not start a new recording or announce one", "recorders \(after.recorders.count)")

    // A Zoom that reconnects inside a real meeting (live 2026-10-10 17:19: no sockets for ~26 s): it comes back WEAK (4 sockets, audio IO not up yet) and
    // the call goes on. One recording, one 'started' notice, no 'ended' notice in the middle of the meeting, no second folder.
    for gap in [14, 20, 26, 28] {
        let rc = Harness("tier-reconnect-\(gap)", in: base) { $0.notifyRecording = true }
        rc.run(until: { !rc.recorders.isEmpty }, limit: 15, [strong])
        rc.run(60, step: 2, [strong])
        rc.run(gap, step: 2, [none])
        rc.run(6, step: 2, [weak4])
        rc.run(60, step: 2, [strong])
        rc.sync()
        check(rc.recorders.count == 1 && rc.current?.isRecording == true && rc.pipeline.enqueued.isEmpty && rc.sessionDirNames().count == 1
              && rc.notifier.posted.map { $0.kind } == [.recordingStarted],
              "Zoom reconnect (\(gap) s without signal, back weak for 6 s, then strong): still one recording, no 'ended' notice, nothing handed to the pipeline", "recorders \(rc.recorders.count) posted \(rc.notifier.posted.map { $0.kind.rawValue }) enqueued \(rc.pipeline.enqueued.count)")
        rc.run(until: { rc.current?.isRecording == false }, limit: 80, step: 2, [none])
        rc.sync()
        check(rc.notifier.posted.map { $0.kind } == [.recordingStarted, .recordingStopped] && rc.pipeline.enqueued.count == 1,
              "... and the real end of that meeting announces one 'ended' notice and hands over one session", "\(rc.notifier.posted.map { $0.kind.rawValue }) enqueued \(rc.pipeline.enqueued.count)")
    }

    // ZOOM_WEAK_DEBOUNCE_SECONDS=0: weak evidence is as good as strong again, announced at once (the old behaviour).
    let legacyStart = Harness("tier-legacy-start", in: base, zoomTier: ZoomTierSettings(strongSockets: 6, weakDebounce: 0)) { $0.notifyRecording = true }
    let legacyAfter = legacyStart.run(until: { !legacyStart.recorders.isEmpty }, limit: 15, [weak3])
    legacyStart.sync()
    check(legacyAfter != nil && (legacyAfter ?? 99) <= 6 && legacyStart.notifier.count(.recordingStarted) == 1, "ZOOM_WEAK_DEBOUNCE_SECONDS=0: weak evidence starts after the start debounce and is announced at once", "\(String(describing: legacyAfter))")
}

// MARK: - Notification texts from what the pipeline left behind

private func testNotificationTexts(_ base: URL) {
    section("notification texts from the launcher's outcome (platform, length, folder, error kind, reset time)")
    let zoom = zoomSignal()
    let fm = FileManager.default

    let h = Harness("notify-outcome", in: base)
    h.run(until: { !h.recorders.isEmpty }, limit: 15, [zoom])
    h.run(40, [zoom])
    h.run(until: { h.current?.isRecording == false }, limit: 80, [])
    let sid = h.current?.dir.lastPathComponent ?? "2026-10-07_1400_zoom"
    let folder = base.appendingPathComponent("outcome-folder", isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

    // with the launcher's outcome
    h.pipeline.outcomes[sid] = PipelineOutcome(platform: .teams, durationSeconds: 3720, folder: folder)
    h.pipeline.onEvent?(.finished(session: sid, title: "Board Review", finalDir: nil, discarded: false)); h.sync()
    var n = h.notifier.posted.last
    check(n?.kind == .noteReady && n?.subtitle == "Board Review" && n?.body == "Teams · 1시간 02분 녹음 · 클릭하면 폴더가 열립니다" && n?.action == .openFolder(folder.path),
          "note ready: platform and length from session.json, the folder from the outcome", "\(n?.body ?? "nil") \(n?.action.name ?? "")")
    // the event's own final_dir wins
    let published = base.appendingPathComponent("outcome-published", isDirectory: true)
    h.pipeline.onEvent?(.finished(session: sid, title: "Board Review", finalDir: published, discarded: false)); h.sync()
    check(h.notifier.posted.last?.action == .openFolder(published.path), "the final_dir of the finished event is the click target")
    // without an outcome: what this launch recorded, the archive as the folder
    h.pipeline.outcomes.removeAll()
    h.pipeline.onEvent?(.finished(session: sid, title: nil, finalDir: nil, discarded: false)); h.sync()
    n = h.notifier.posted.last
    check(n?.body.hasPrefix("Zoom · ") == true && n?.body.contains("녹음 · 클릭하면 폴더가 열립니다") == true && n?.action == .openFolder(h.config.archiveDir.path),
          "without an outcome: platform and length of this launch's recording, the archive folder", "\(n?.body ?? "nil") \(n?.action.name ?? "")")
    h.pipeline.onEvent?(.finished(session: "unknown-session", title: "x", finalDir: nil, discarded: false)); h.sync()
    check(h.notifier.posted.last?.body == "클릭하면 폴더가 열립니다" && h.notifier.posted.last?.action == .openFolder(h.config.archiveDir.path), "nothing known at all: still a complete text with a working click")

    // failures
    let log = base.appendingPathComponent("outcome-pipeline.log")
    try? "x\n".write(to: log, atomically: true, encoding: .utf8)
    let later = h.clock.now.addingTimeInterval(3600)
    h.pipeline.outcomes["f1"] = PipelineOutcome(folder: folder, errorKind: "usage_limit", retryable: true, resetsAt: later, logFile: log)
    h.pipeline.onEvent?(.failed(session: "f1", message: "Note failed: Claude usage limit reached")); h.sync()
    n = h.notifier.posted.last
    check(n?.kind == .pipelineFailed && n?.subtitle == "전사본·녹음은 안전하게 보관됨" && n?.body.contains("Claude 사용 한도에 도달했어요 (\(NotificationText.clock(later)) 이후 가능)") == true
          && n?.body.contains("자동 재시도") == true && n?.action == .openFolder(folder.path), "failure with state.json facts: Korean cause with the reset time, automatic retry, click opens the folder", "\(n?.body ?? "nil")")
    h.pipeline.outcomes["f2"] = PipelineOutcome(errorKind: "asr_failed", retryable: false, logFile: log)
    h.pipeline.onEvent?(.failed(session: "f2", message: "asr crashed")); h.sync()
    n = h.notifier.posted.last
    check(n?.subtitle == "녹음은 안전하게 보관됨" && n?.body.contains("mcap reprocess --last") == true && n?.action == .openLog(log.path), "no folder: the pipeline log is the click target", "\(n?.action.name ?? "")")
    h.pipeline.outcomes["f3"] = PipelineOutcome(logFile: base.appendingPathComponent("does-not-exist.log"))
    h.pipeline.onEvent?(.failed(session: "f3", message: "boom")); h.sync()
    check(h.notifier.posted.last?.action == .openLog(Log.fileURL.path), "a pipeline log that does not exist: app.log")
    h.pipeline.onEvent?(.failed(session: "f4", message: "boom")); h.sync()
    check(h.notifier.posted.last?.action == .openLog(Log.fileURL.path) && h.notifier.posted.last?.body.contains("원인: boom") == true, "no outcome at all: the message and app.log")
}

// MARK: - What the launcher reads (session.json, state.json)

private func testPipelineFacts(_ base: URL) {
    section("PipelineFacts: platform, length, folder, error kind, reset time from session.json / state.json (read-only)")
    let fm = FileManager.default
    let root = base.appendingPathComponent("facts", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let staging = sessions.appendingPathComponent("2026-10-07_1400_zoom", isDirectory: true)
    let published = root.appendingPathComponent("archive/2026-10/2026-10-07_1400_Weekly", isDirectory: true)
    for d in [staging, published, logs] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    let sessionJSON = "{\"platform\":\"zoom\",\"start_time\":\"2026-10-07T14:00:12+09:00\",\"end_time\":\"2026-10-07T14:32:24+09:00\"}"
    try? sessionJSON.write(to: published.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    let resets = "2026-10-07T20:00:00+09:00"
    let stateJSON = "{\"stage\":\"failed\",\"error_kind\":\"usage_limit\",\"retryable\":true,\"resets_at\":\"\(resets)\",\"final_dir\":\"\(published.path)\"}"
    try? stateJSON.write(to: staging.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)

    var o = PipelineFacts.outcome(session: staging.lastPathComponent, sessionsDir: sessions, finalDir: nil, logDir: logs)
    check(o.folder.map { NotificationPathPolicy.canonical($0.path) == NotificationPathPolicy.canonical(published.path) } == true && o.platform == .zoom && o.durationSeconds == 1932
          && o.errorKind == "usage_limit" && o.retryable == true && o.resetsAt == ShellUtil.parseISO8601(resets) && o.logFile?.lastPathComponent == "pipeline-2026-10-07_1400_zoom.log",
          "tombstone state.json: final_dir is the folder; platform and length from the published session.json; kind, retryable, reset time", "\(o)")
    try? fm.removeItem(at: published)
    o = PipelineFacts.outcome(session: staging.lastPathComponent, sessionsDir: sessions, finalDir: nil, logDir: logs)
    check(o.folder.map { NotificationPathPolicy.canonical($0.path) == NotificationPathPolicy.canonical(staging.path) } == true && o.platform == nil && o.errorKind == "usage_limit",
          "the published folder is gone: the staging folder is the target (nothing is invented)", "\(o)")
    try? fm.createDirectory(at: published, withIntermediateDirectories: true)
    try? "{\"platform\":\"manual\",\"start_time\":\"2026-10-07T14:00:12+09:00\",\"end_time\":null}".write(to: staging.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
    o = PipelineFacts.outcome(session: staging.lastPathComponent, sessionsDir: sessions, finalDir: published, logDir: logs)
    check(o.folder?.path == published.path && o.platform == .manual && o.durationSeconds == nil, "finalDir of the event wins; an open-ended session.json has a platform and no length (staging session.json is the fallback)", "\(o)")
    check(PipelineFacts.recording(in: root.appendingPathComponent("nothing-here")) == nil, "no session.json: no facts")

    let sweep = PipelineFacts.outcome(session: SessionController.sweepJobName, sessionsDir: sessions, finalDir: nil, logDir: logs)
    check(sweep.folder == nil && sweep.logFile?.lastPathComponent == "pipeline-retry-sweep.log" && sweep.errorKind == nil, "the retry sweep has no folder, only its log")
    let last = PipelineFacts.outcome(session: "reprocess-last", sessionsDir: sessions, finalDir: nil, logDir: logs)
    check(last.folder == nil && last.logFile == nil, "reprocess --last: a timestamped log name nobody can know: no log file")
    let evil = PipelineFacts.outcome(session: "../2026-10-07_1400_zoom", sessionsDir: sessions, finalDir: nil, logDir: logs)
    check(evil.folder == nil && evil.errorKind == nil && evil.logFile == nil, "a session name with '..' / '/' never reads outside the sessions folder")
    check(PipelineLauncher.logFileName(forSession: "retry-sweep") == "pipeline-retry-sweep.log" && PipelineLauncher.logFileName(forSession: "2026-10-07_1400_zoom") == "pipeline-2026-10-07_1400_zoom.log"
          && PipelineLauncher.logFileName(forSession: "reprocess-last") == nil, "log names of the jobs")
}

// MARK: - Retry sweep

private func testSweepClass() {
    section("retry sweep: what a staging folder means (pure)")
    let now = Date(timeIntervalSince1970: 2_000_000)
    func state(_ json: String?) -> [String: Any]? { json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
    let future = ShellUtil.iso8601(now.addingTimeInterval(3600)), past = ShellUtil.iso8601(now.addingTimeInterval(-60))
    typealias C = SessionController.SweepClass
    let table: [(String?, Bool, C, String)] = [
        ("{\"stage\":\"done\"}", true, .ignore, "done"),
        ("{\"stage\":\"done\",\"discarded\":true}", false, .ignore, "done tombstone"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\"}", true, .failedDue, "failed, retryable"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"usage_limit\"}", false, .failedDue, "note-failed tombstone (no session.json), retryable, no reset time"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"resets_at\":\"\(past)\"}", false, .failedDue, "reset time already passed"),
        ("{\"stage\":\"failed\",\"retryable\":false,\"error_kind\":\"auth\"}", true, .ignore, "failed, not retryable"),
        ("{\"stage\":\"failed\",\"retryable\":null}", true, .ignore, "retryable null"),
        ("{\"stage\":\"failed\",\"retryable\":\"yes\"}", true, .ignore, "retryable is not a boolean"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"attempts\":5}", true, .failedDue, "5 failed runs: still tried"),
        ("{\"stage\":\"failed\",\"retryable\":true,\"attempts\":6}", true, .failedExhausted, "6 failed runs: not automatically any more"),
        ("{\"stage\":\"transcribing\"}", true, .interrupted, "interrupted run"),
        ("{\"stage\":\"queued\"}", true, .interrupted, "queued"),
        (nil, true, .interrupted, "finished recording, never processed"),
        (nil, false, .ignore, "no state and no finished session"),
        ("{\"stage\":\"transcribing\"}", false, .ignore, "state without a finished session (live recording)"),
    ]
    for (json, finished, expected, name) in table {
        let got = SessionController.sweepClass(state: state(json), hasFinishedSession: finished, now: now)
        check(got == expected, "sweepClass: \(name) -> \(expected)", "\(got)")
    }
    let waiting = SessionController.sweepClass(state: state("{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"usage_limit\",\"resets_at\":\"\(future)\"}"), hasFinishedSession: true, now: now)
    check(waiting == .failedWaiting(until: now.addingTimeInterval(3600)), "a Claude usage-limit reset in the future: waiting until exactly that time (never retried before it)", "\(waiting)")
    check(SessionController.sweepClass(state: state("{\"stage\":\"failed\",\"retryable\":true,\"resets_at\":\"garbage\"}"), hasFinishedSession: true, now: now) == .failedDue,
          "an unreadable reset time does not block the retry forever")
}

private func testRetrySweep(_ base: URL) {
    section("retry sweep (SPEC 15): at launch + every RETRY_SWEEP_HOURS, serial, never during a recording, never before a usage-limit reset")
    let fm = FileManager.default
    let zoom = zoomSignal()

    func stage(_ h: Harness, _ name: String, state: String?, end: String? = "2026-10-07T10:30:00+09:00", session: Bool = true) {
        let d = h.sessionsDir.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        if session {
            let endJSON = end.map { "\"\($0)\"" } ?? "null"
            try? "{\"schema\":1,\"session_id\":\"\(name)\",\"platform\":\"zoom\",\"start_time\":\"2026-10-07T10:00:00+09:00\",\"end_time\":\(endJSON),\"tracks\":{}}"
                .write(to: d.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        }
        if let st = state { try? st.write(to: d.appendingPathComponent("state.json"), atomically: true, encoding: .utf8) }
    }

    let h = Harness("sweep", in: base)
    let t0 = h.clock.now
    let reset = ShellUtil.iso8601(t0.addingTimeInterval(3600)), long = ShellUtil.iso8601(t0.addingTimeInterval(-3600))
    stage(h, "2026-10-07_0900_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\",\"attempts\":1}")
    stage(h, "2026-10-07_0910_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"usage_limit\",\"resets_at\":\"\(reset)\"}")
    stage(h, "2026-10-07_0920_zoom", state: "{\"stage\":\"failed\",\"retryable\":false,\"error_kind\":\"auth\"}")
    stage(h, "2026-10-07_0930_zoom", state: "{\"stage\":\"done\"}")
    stage(h, "2026-10-07_0940_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"asr_failed\",\"attempts\":6}")
    stage(h, "2026-10-07_0950_zoom", state: "{\"stage\":\"transcribing\"}")
    stage(h, "2026-10-07_0960_zoom", state: nil)
    stage(h, "2026-10-07_0970_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"usage_limit\",\"resets_at\":\"\(long)\"}", session: false)
    stage(h, "2026-10-07_0980_zoom", state: nil, end: nil)                       // a live (or crashed) recording: not the sweep's business
    stage(h, "_discarded/2026-10-07_0800_zoom", state: "{\"stage\":\"transcribing\"}")
    h.controller.armRetrySweep()

    h.run(119, [])
    check(h.pipeline.pendingCalls == 0 && h.pipeline.enqueued.isEmpty, "no sweep during the first two minutes after launch (Google Drive may still be mounting)")
    h.run(5, [])
    check(h.pipeline.pendingCalls == 1, "the first sweep runs about two minutes after launch: `mcap reprocess --pending` is queued once", "\(h.pipeline.pendingCalls)")
    check(h.pipeline.enqueued.map { $0.lastPathComponent } == ["2026-10-07_0950_zoom", "2026-10-07_0960_zoom"],
          "interrupted sessions are enqueued; done, non-retryable, exhausted, waiting, live and _discarded folders are not", "\(h.pipeline.enqueued.map { $0.lastPathComponent })")
    check(logCount("retry sweep: 2 failed retryable session(s) -> mcap reprocess --pending; 2 interrupted session(s) enqueued; 1 waiting for a Claude usage-limit reset") >= 1
          && logCount("2026-10-07_0940_zoom already failed 6 times; not retrying it automatically") >= 1, "the sweep logs what it found and why it skipped the rest")

    // the next sweep is scheduled for just after the usage-limit reset (not 6 hours later), and the waiting session is due then
    let secondAt = h.run(until: { h.pipeline.pendingCalls == 2 }, limit: 4000, step: 5, [])
    let elapsed = 124 + (secondAt ?? 99_999)
    check(secondAt != nil && elapsed >= 3655 && elapsed <= 3680, "the next sweep comes right after the Claude usage limit reset time (reset + 1 min), not before and not 6 h later", "after \(elapsed) s")
    check(h.pipeline.enqueued.count == 4, "the interrupted sessions are enqueued again by each sweep", "\(h.pipeline.enqueued.count)")
    // afterwards every 6 hours
    let thirdAt = h.run(until: { h.pipeline.pendingCalls == 3 }, limit: 7 * 3600, step: 30, [])
    check(thirdAt != nil && thirdAt! >= 6 * 3600 - 60 && thirdAt! <= 6 * 3600 + 60, "then every RETRY_SWEEP_HOURS (6 h)", "after \(thirdAt ?? -1) s")
    h.run(6 * 3600 + 60, step: 30, [])
    check(h.pipeline.pendingCalls == 4, "and again", "\(h.pipeline.pendingCalls)")
    let perSession = Dictionary(grouping: h.pipeline.enqueued, by: { $0.lastPathComponent }).mapValues { $0.count }
    check(perSession["2026-10-07_0950_zoom"] == SessionController.maxSweepEnqueues && perSession["2026-10-07_0960_zoom"] == SessionController.maxSweepEnqueues,
          "an interrupted session is enqueued at most \(SessionController.maxSweepEnqueues) times per launch (a job that hangs every time cannot loop forever)", "\(perSession)")

    // a session the launcher is working on is not queued again
    let busy = Harness("sweep-busy", in: base)
    stage(busy, "2026-10-07_1000_zoom", state: "{\"stage\":\"transcribing\"}")
    stage(busy, "2026-10-07_1010_zoom", state: "{\"stage\":\"transcribing\"}")
    busy.pipeline.busy = [busy.sessionsDir.appendingPathComponent("2026-10-07_1000_zoom").path]
    busy.controller.armRetrySweep()
    busy.run(125, [])
    check(busy.pipeline.enqueued.map { $0.lastPathComponent } == ["2026-10-07_1010_zoom"], "a session that is queued or running in the launcher is skipped (no second pipeline job for it)", "\(busy.pipeline.enqueued.map { $0.lastPathComponent })")

    // the startup scan's own retry (archive_unavailable / asr_failed) is not repeated by the first sweep right behind it
    let startup = Harness("sweep-startup", in: base)
    stage(startup, "2026-10-07_1050_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\"}")
    let launchScan = startup.controller.recoverSessions().map { $0.lastPathComponent }
    check(launchScan == ["2026-10-07_1050_zoom"], "(the startup scan retried it once)", "\(launchScan)")
    startup.controller.armRetrySweep()
    startup.run(125, [])
    check(startup.pipeline.pendingCalls == 0, "the first sweep leaves a session alone that the startup scan has just retried", "\(startup.pipeline.pendingCalls)")
    startup.run(6 * 3600 + 60, step: 30, [])
    check(startup.pipeline.pendingCalls == 1, "... but the next sweep (6 h later) retries it if it is still failed", "\(startup.pipeline.pendingCalls)")
    // a failed session that is queued or running in the launcher is not counted (its result is not known yet)
    try? "{\"stage\":\"done\"}".write(to: startup.sessionsDir.appendingPathComponent("2026-10-07_1050_zoom/state.json"), atomically: true, encoding: .utf8)
    stage(startup, "2026-10-07_1060_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"usage_limit\"}")
    startup.pipeline.busy = [startup.sessionsDir.appendingPathComponent("2026-10-07_1060_zoom").path]
    startup.run(6 * 3600 + 60, step: 30, [])
    check(startup.pipeline.pendingCalls == 1, "a failed session that is queued or running in the launcher is not counted (no sweep for it)", "\(startup.pipeline.pendingCalls)")
    startup.pipeline.busy = []
    startup.run(6 * 3600 + 60, step: 30, [])
    check(startup.pipeline.pendingCalls == 2, "... and when it is not, the next sweep takes it (note failures are the sweep's job, not the startup scan's)", "\(startup.pipeline.pendingCalls)")

    // never while a recording is active: it stays due and runs right after
    let rec = Harness("sweep-recording", in: base)
    stage(rec, "2026-10-07_1100_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\"}")
    rec.controller.armRetrySweep()
    rec.run(until: { !rec.recorders.isEmpty }, limit: 15, [zoom])
    rec.run(600, [zoom])
    check(rec.current?.isRecording == true && rec.pipeline.pendingCalls == 0, "a recording is active when the sweep is due: it waits (no heavy job next to the recorder)")
    rec.run(until: { rec.current?.isRecording == false }, limit: 60, [])
    rec.run(5, [])
    check(rec.pipeline.pendingCalls == 1, "right after the recording ended the overdue sweep runs", "\(rec.pipeline.pendingCalls)")

    // off
    let off = Harness("sweep-off", in: base) { $0.retrySweepHours = 0 }
    stage(off, "2026-10-07_1200_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\"}")
    stage(off, "2026-10-07_1210_zoom", state: "{\"stage\":\"transcribing\"}")
    off.controller.armRetrySweep()
    off.run(24 * 3600, step: 60, [])
    check(off.pipeline.pendingCalls == 0 && off.pipeline.enqueued.isEmpty, "RETRY_SWEEP_HOURS=0: no sweep at all (24 h)")

    // nothing to do: quiet
    let none = Harness("sweep-none", in: base)
    none.controller.armRetrySweep()
    let nothingBefore = logCount("retry sweep: nothing pending")
    none.run(130, [])
    check(none.pipeline.pendingCalls == 0 && none.pipeline.enqueued.isEmpty && logCount("retry sweep: nothing pending") == nothingBefore + 1, "nothing failed: no Python is started, the log says so")

    // wake from sleep: the watchdog is re-armed and the sweep is held back
    let wake = Harness("sweep-wake", in: base)
    stage(wake, "2026-10-07_1300_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\"}")
    wake.controller.armRetrySweep()
    wake.run(100, [])
    wake.controller.systemDidWake(); wake.sync()
    check(wake.pipeline.wakeCalls == 1, "didWake reaches the launcher (re-arms the stall watchdog)")
    wake.run(100, [])
    check(wake.pipeline.pendingCalls == 0, "a sweep that became due during sleep waits two minutes after the wake (Wi-Fi and Drive are not back yet)")
    wake.run(30, [])
    check(wake.pipeline.pendingCalls == 1, "... and then runs", "\(wake.pipeline.pendingCalls)")

    // shutdown: no sweep afterwards
    let down = Harness("sweep-down", in: base)
    stage(down, "2026-10-07_1400_zoom", state: "{\"stage\":\"failed\",\"retryable\":true,\"error_kind\":\"archive_unavailable\"}")
    down.controller.armRetrySweep()
    down.controller.shutdown(reason: .appQuit)
    down.run(300, [])
    check(down.pipeline.pendingCalls == 0, "after shutdown no sweep is started")
}

// MARK: - Pipeline launcher: awake-time watchdog, requeue once, sweep job

private struct LauncherWorld {
    let root: URL
    let bin: URL
    let logs: URL
    let archive: URL
    let support: URL
    let config: AppConfig

    init(_ name: String, in base: URL, script: String = fakePythonScript) {
        let fm = FileManager.default
        root = base.appendingPathComponent(name, isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        archive = root.appendingPathComponent("archive", isDirectory: true)
        logs = root.appendingPathComponent("logs", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: project.appendingPathComponent("pipeline/mcap"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: support.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let python = bin.appendingPathComponent("fakepython")
        try? script.write(to: python, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        var c = AppConfig.defaults()
        c.supportDir = support
        c.projectDir = project
        c.pythonBin = python
        c.archiveDir = archive
        config = c
    }

    func session(_ name: String) -> URL {
        let d = support.appendingPathComponent("sessions/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    var callsLog: String { (try? String(contentsOf: bin.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }
    func runs(of args: String) -> Int { callsLog.components(separatedBy: "ARGS: \(args)").count - 1 }
    func setPendingMode(_ mode: String) { try? mode.write(to: bin.appendingPathComponent("pending-mode"), atomically: true, encoding: .utf8) }
}

/// A clock that only moves when the test moves it: "awake time" (ProcessInfo.systemUptime stands still while the Mac sleeps).
private final class VirtualUptime {
    private let box = Locked<Double>(10_000)
    var now: () -> TimeInterval { { [box] in box.value } }
    func advance(_ seconds: Double) { box.value += seconds }
}

private func testPipelineWatchdog(_ base: URL) {
    section("pipeline stall watchdog (SPEC 15): awake time, re-armed on wake, killed job queued once, then left for the sweep")
    let w = LauncherWorld("watchdog", in: base)
    func progressSeen(_ e: EventLog) -> Bool { e.strings.contains { $0.hasPrefix("progress:") } }
    func failedEvents(_ e: EventLog) -> [String] { e.strings.filter { $0.hasPrefix("failed:") } }

    // A: awake time decides, not the wall clock; wake re-arms.
    let up = VirtualUptime()
    let a = PipelineLauncher(config: w.config, logDir: w.logs, statePollInterval: 0.05, stallTimeout: 600, uptime: up.now)
    let aEvents = EventLog()
    a.onEvent = { aEvents.add($0) }
    let hang = w.session("2026-10-07_1100_hang3")
    a.enqueue(hang)
    _ = waitUntil(5) { progressSeen(aEvents) }
    Thread.sleep(forTimeInterval: 0.6)                              // the child's first output has landed: that is the last "activity"
    check(a.isProcessing(hang) && a.isProcessing(URL(fileURLWithPath: hang.path, isDirectory: true)) && !a.isProcessing(w.session("2026-10-07_1111_other")),
          "isProcessing: true while the job runs (whatever form the folder URL has), false for another session")
    // Real time passes (a sleeping Mac: the wall clock runs, the awake clock does not).
    Thread.sleep(forTimeInterval: 1.0)
    check(a.isProcessing(hang) && failedEvents(aEvents).isEmpty, "wall-clock time alone (the Mac was asleep) does not count: the job is alive although more than 1 s of real time passed with a 600 s limit in awake time")
    up.advance(599); Thread.sleep(forTimeInterval: 0.4)
    check(a.isProcessing(hang) && failedEvents(aEvents).isEmpty && !aEvents.strings.contains("progress:2026-10-07_1100_hang3:Restarting after a stall"),
          "599 s of awake time without output: not killed")
    a.systemDidWake(); Thread.sleep(forTimeInterval: 0.2)
    up.advance(599); Thread.sleep(forTimeInterval: 0.4)
    check(a.isProcessing(hang) && failedEvents(aEvents).isEmpty && !aEvents.strings.contains("progress:2026-10-07_1100_hang3:Restarting after a stall"),
          "wake from sleep re-arms the watchdog: another 599 s after the wake is still not a stall (1198 s since the last output)")
    check(logText().contains("wake from sleep: stall watchdog re-armed for 2026-10-07_1100_hang3"), "the re-arm is logged")
    up.advance(2)
    let requeued = waitUntil(10) { aEvents.strings.contains("progress:2026-10-07_1100_hang3:Restarting after a stall") }
    check(requeued, "601 s of awake time since the wake: killed, and queued once more", aEvents.strings.joined(separator: " | "))
    check(failedEvents(aEvents).isEmpty, "the first kill is not reported as a failure")
    // the second run hangs too: killed again, now reported and left for the retry sweep
    let secondStart = waitUntil(10) { aEvents.strings.filter { $0 == "progress:2026-10-07_1100_hang3:Starting" }.count >= 2 }
    check(secondStart, "the job is started a second time", aEvents.strings.joined(separator: " | "))
    Thread.sleep(forTimeInterval: 0.6)
    up.advance(601)
    let failedTwice = waitUntil(10) { !failedEvents(aEvents).isEmpty }
    check(failedTwice && failedEvents(aEvents).first?.contains("stopped responding again") == true && failedEvents(aEvents).first?.contains("left for the automatic retry sweep") == true,
          "the second stall is reported as failed and says it is left for the retry sweep", failedEvents(aEvents).joined(separator: " | "))
    check(w.runs(of: "-m mcap process \(hang.path)") == 2, "the session was run exactly twice (one re-queue, no loop)", "\(w.runs(of: "-m mcap process \(hang.path)"))")
    Thread.sleep(forTimeInterval: 0.3)
    check(!a.isProcessing(hang), "afterwards the launcher is idle again")

    // B: killed once, then it works: no failure at all.
    let up2 = VirtualUptime()
    let b = PipelineLauncher(config: w.config, logDir: w.logs, statePollInterval: 0.05, stallTimeout: 600, uptime: up2.now)
    let bEvents = EventLog()
    b.onEvent = { bEvents.add($0) }
    let once = w.session("2026-10-07_1200_hangonce")
    b.enqueue(once)
    _ = waitUntil(5) { progressSeen(bEvents) }
    Thread.sleep(forTimeInterval: 0.6)
    up2.advance(601)
    let finished = waitUntil(20) { bEvents.strings.contains { $0.hasPrefix("finished:2026-10-07_1200_hangonce") } }
    check(finished && failedEvents(bEvents).isEmpty, "a job that hung once and works the second time finishes normally, with no failure reported", bEvents.strings.joined(separator: " | "))
    check(w.runs(of: "-m mcap process \(once.path)") == 2, "it ran twice")

    // C: only session jobs are re-queued: a hanging sweep is reported at once.
    w.setPendingMode("hang")
    let up3 = VirtualUptime()
    let c = PipelineLauncher(config: w.config, logDir: w.logs, statePollInterval: 0.05, stallTimeout: 600, uptime: up3.now)
    let cEvents = EventLog()
    c.onEvent = { cEvents.add($0) }
    c.reprocessPending()
    _ = waitUntil(5) { progressSeen(cEvents) }
    Thread.sleep(forTimeInterval: 0.6)
    up3.advance(601)
    let sweepFailed = waitUntil(10) { !failedEvents(cEvents).isEmpty }
    check(sweepFailed && failedEvents(cEvents).first?.hasPrefix("failed:retry-sweep:Pipeline stopped responding and was killed") == true && w.runs(of: "-m mcap reprocess --pending") == 1,
          "a hanging retry sweep is killed and reported once (not re-queued: the next sweep is the retry)", cEvents.strings.joined(separator: " | "))
}

private func testPipelineSweepJob(_ base: URL) {
    section("pipeline launcher: the retry sweep job (`mcap reprocess --pending`)")
    let w = LauncherWorld("sweepjob", in: base)
    func run(_ mode: String) -> (events: [String], all: [PipelineEvent]) {
        w.setPendingMode(mode)
        let l = PipelineLauncher(config: w.config, logDir: w.logs, statePollInterval: 0.05, stallTimeout: 600)
        let e = EventLog()
        l.onEvent = { e.add($0) }
        l.reprocessPending()
        _ = waitUntil(20) { e.strings.contains { $0.hasPrefix("nothing:") || $0.hasPrefix("failed:") || $0.hasPrefix("finished:") } }
        Thread.sleep(forTimeInterval: 0.3)
        return (e.strings, e.all)
    }

    let none = run("none")
    check(w.runs(of: "-m mcap reprocess --pending") == 1, "the sweep runs `python -m mcap reprocess --pending` (cwd PROJECT_DIR/pipeline, minimal environment)")
    check(none.events.first == "progress:retry-sweep:Starting" && none.events.contains("progress:retry-sweep:Retrying failed meetings") && none.events.last == "nothing:retry-sweep",
          "nothing pending: progress 'Retrying failed meetings', then a quiet 'nothing to report'", none.events.joined(separator: " | "))
    check(!none.events.contains { $0.hasPrefix("failed:") || $0.hasPrefix("finished:") }, "... no failure and no 'done'")

    let ok = run("ok")
    check(ok.events.contains("finished:2026-10-06_0900_Retried-One:Retried One Title:false") && ok.events.last == "nothing:retry-sweep",
          "a retried session that is now done: a finished event with the note title (so the user hears 'Meeting note ready'), then the sweep's own all-clear", ok.events.joined(separator: " | "))
    let finalDir = ok.all.compactMap { e -> URL? in if case .finished(_, _, let d, _) = e { return d }; return nil }.first
    check(finalDir?.lastPathComponent == "2026-10-06_0900_Retried-One", "the finished event carries the folder (\"DONE: None\" of a discarded session is ignored)", "\(String(describing: finalDir))")
    check(!ok.events.contains { $0.hasPrefix("finished:") && $0.contains(":-:") }, "no event for the 'DONE: None' line")

    let fail = run("fail")
    check(fail.events.contains("failed:retry-sweep:archive unavailable: Drive is not mounted (and 1 more; see pipeline-retry-sweep.log)") && !fail.events.contains("nothing:retry-sweep"),
          "failed sessions: ONE failed event with the first reason and how many more", fail.events.joined(separator: " | "))
    let logText = (try? String(contentsOf: w.logs.appendingPathComponent("pipeline-retry-sweep.log"), encoding: .utf8)) ?? ""
    check(logText.components(separatedBy: "===== ").count - 1 == 3, "every sweep appends to the same pipeline-retry-sweep.log", "\(logText.components(separatedBy: "===== ").count - 1) runs")

    // exit 75: another mcap process holds the session: not a failure
    let busyLauncher = PipelineLauncher(config: w.config, logDir: w.logs, statePollInterval: 0.05, stallTimeout: 600)
    let busyEvents = EventLog()
    busyLauncher.onEvent = { busyEvents.add($0) }
    busyLauncher.enqueue(w.session("2026-10-07_1500_busy1"))
    _ = waitUntil(20) { busyEvents.strings.contains { $0.hasPrefix("nothing:") || $0.hasPrefix("failed:") } }
    check(busyEvents.strings.contains("nothing:2026-10-07_1500_busy1") && !busyEvents.strings.contains { $0.hasPrefix("failed:") },
          "exit 75 (the session is locked by another mcap process) is not reported as a failure", busyEvents.strings.joined(separator: " | "))

    // pure parsing
    let lines = ["retrying /a/b", "  DONE: /x/y z/2026-10-06_0900_One", "  FAILED: first reason", "  BUSY: locked", "  DONE: None", "DONE: pending: 1 session(s) retried, 1 ok, 0 failed, 0 busy",
                 "  FAILED: second reason", "FAILED: pending: 2 session(s) retried", "DONE: /last/folder"]
    check(PipelineLauncher.doneFolders(in: lines).map { $0.path } == ["/x/y z/2026-10-06_0900_One", "/last/folder"], "doneFolders: absolute paths only, spaces kept, summary and None ignored", "\(PipelineLauncher.doneFolders(in: lines).map { $0.path })")
    check(PipelineLauncher.failedReasons(in: lines) == ["first reason", "second reason"], "failedReasons: the indented lines only, not the summary", "\(PipelineLauncher.failedReasons(in: lines))")

    // serial: a session job and the sweep never run at the same time
    w.setPendingMode("none")
    let l = PipelineLauncher(config: w.config, logDir: w.logs, statePollInterval: 0.05, stallTimeout: 600)
    let e = EventLog()
    l.onEvent = { e.add($0) }
    let ok1 = w.session("2026-10-07_1400_ok1")
    l.enqueue(ok1)
    l.reprocessPending()
    l.reprocessPending()                                           // duplicate: ignored
    _ = waitUntil(30) { e.strings.contains("nothing:retry-sweep") }
    let ev = e.strings
    if let done = ev.firstIndex(where: { $0.hasPrefix("finished:2026-10-07_1400_ok1") }), let sweepStart = ev.firstIndex(of: "progress:retry-sweep:Starting") {
        check(done < sweepStart, "the sweep starts only after the session job finished (one pipeline job at a time)")
    } else {
        check(false, "serial ordering observable", ev.joined(separator: " | "))
    }
    Thread.sleep(forTimeInterval: 0.3)
    check(w.runs(of: "-m mcap reprocess --pending") == 4,
          "a duplicate sweep request while one is queued is ignored (4 runs in total over this test: none, ok, fail, serial)", "\(w.runs(of: "-m mcap reprocess --pending"))")
}

// MARK: - Pipeline launcher: the child environment never carries a key (SPEC 17, both billing modes)

private func testPipelineChildEnvironment(_ base: URL) {
    section("pipeline child environment is key-free in both Claude billing modes (the Python side reads the key from the Keychain itself)")
    let poison: [String: String] = [
        "ANTHROPIC_API_KEY": canaryKey, "ANTHROPIC_AUTH_TOKEN": canaryKey, "ANTHROPIC_BASE_URL": "https://evil.invalid", "ANTHROPIC_CUSTOM_HEADERS": "x-evil: 1",
        "CLAUDE_API_KEY": canaryKey, "CLAUDE_CODE_OAUTH_TOKEN": canaryKey, "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_USE_VERTEX": "1", "CLAUDECODE": "1",
    ]
    for (k, v) in poison { setenv(k, v, 1) }
    defer { for k in poison.keys { unsetenv(k) } }

    /// KEY of every "ENV KEY=VALUE" line the fake python recorded, one dictionary per call.
    func childEnvironments(_ w: LauncherWorld) -> [[String: String]] {
        return w.callsLog.components(separatedBy: "-----\n").map { block in
            var env: [String: String] = [:]
            for line in block.split(separator: "\n") where line.hasPrefix("ENV ") {
                let pair = line.dropFirst(4)
                guard let eq = pair.firstIndex(of: "=") else { continue }
                env[String(pair[pair.startIndex..<eq])] = String(pair[pair.index(after: eq)...])
            }
            return env
        }.filter { !$0.isEmpty }
    }
    // What the fake python's own shell adds on top of what the launcher gave it.
    let shellAdds: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"]
    let launcherKeys: Set<String> = launcherOwnKeys.union(["MCAP_CONFIG", ApiKeyItem.securityBinEnv])

    var keysByMode: [ClaudeAuthMode: Set<String>] = [:]
    for mode in [ClaudeAuthMode.subscription, .api] {
        let w = LauncherWorld("childenv-\(mode.rawValue)", in: base)
        let launcher = PipelineLauncher(config: w.config.withAuth(mode), logDir: w.logs, statePollInterval: 0.05, stallTimeout: 600)
        let events = EventLog()
        launcher.onEvent = { events.add($0) }
        launcher.enqueue(w.session("2026-10-09_1000_discard\(mode.rawValue)"))
        launcher.reprocessLast()
        launcher.reprocessPending()
        let finished = waitUntil(30) { events.strings.contains { $0.hasPrefix("finished:reprocess-last") } && events.strings.contains("nothing:retry-sweep") }
        check(finished, "\(mode.rawValue): all three job kinds ran (session, reprocess --last, reprocess --pending)", events.strings.joined(separator: " | "))
        let envs = childEnvironments(w)
        check(envs.count == 3, "\(mode.rawValue): the fake python recorded three child environments", "\(envs.count)")
        let keys = Set(envs.flatMap { $0.keys })
        keysByMode[mode] = keys
        check(!keys.contains { $0.uppercased().hasPrefix("ANTHROPIC") || $0.uppercased().hasPrefix("CLAUDE") },
              "\(mode.rawValue): no ANTHROPIC_* / CLAUDE* variable reaches the child", keys.sorted().joined(separator: " "))
        check(!keys.contains { k in ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { k.uppercased().contains($0) } },
              "\(mode.rawValue): no variable that looks like a key, token or secret", keys.sorted().joined(separator: " "))
        check(!w.callsLog.contains(canaryKey) && !w.callsLog.contains("evil.invalid"), "\(mode.rawValue): no value of the poisoned parent environment reaches the child")
        check(keys.subtracting(launcherKeys).subtracting(shellAdds).isEmpty, "\(mode.rawValue): the child environment holds only the launcher's own variables",
              keys.subtracting(launcherKeys).subtracting(shellAdds).sorted().joined(separator: " "))
        check(["HOME", "PATH", "USER", "LANG"].allSatisfy { keys.contains($0) }, "\(mode.rawValue): HOME, PATH, USER and LANG are present (claude needs all four)")
        check(w.callsLog.contains("ENV MCAP_APP_NAME=\(AppInfo.displayName)\n") && w.callsLog.contains("ENV MCAP_APP_SHORT_NAME=\(AppInfo.shortName)\n"),
              "\(mode.rawValue): the child that really ran got the app's two names (the pipeline names the app the way the app does)")
    }
    check(keysByMode[.subscription] == keysByMode[.api] && keysByMode[.api] != nil,
          "the child environment has the same variables in subscription and api mode (the mode never puts a key into it)",
          "subscription \((keysByMode[.subscription] ?? []).sorted()) api \((keysByMode[.api] ?? []).sorted())")

    // the pure function: exact variable sets
    var hostile = poison
    hostile["HOME"] = "/evil"
    hostile["PATH"] = "/evil"
    hostile["AWS_SECRET_ACCESS_KEY"] = "x"
    hostile["OPENAI_API_KEY"] = "x"
    let plain = PipelineLauncher.sanitizedEnvironment(from: hostile)
    check(Set(plain.keys) == launcherOwnKeys,
          "sanitizedEnvironment: exactly the eight launcher variables (the six and the two app names), nothing inherited", plain.keys.sorted().joined(separator: " "))
    check(plain["HOME"] == NSHomeDirectory() && plain["PATH"] != "/evil" && !plain.values.contains { $0.contains(canaryKey) }, "... with the real HOME and no poisoned value")
    check(plain["MCAP_APP_NAME"] == AppInfo.displayName && plain["MCAP_APP_SHORT_NAME"] == AppInfo.shortName,
          "... and the app's own two names for the pipeline (the Google sign-in page names the app the way the app does)", "\(plain["MCAP_APP_NAME"] ?? "nil") / \(plain["MCAP_APP_SHORT_NAME"] ?? "nil")")
    var hostileNames = hostile
    hostileNames["MCAP_APP_NAME"] = "Evil"
    hostileNames["MCAP_APP_SHORT_NAME"] = "Evil"
    let fromAppNotCaller = PipelineLauncher.sanitizedEnvironment(from: hostileNames)
    check(fromAppNotCaller["MCAP_APP_NAME"] == AppInfo.displayName && fromAppNotCaller["MCAP_APP_SHORT_NAME"] == AppInfo.shortName,
          "... the names come from the app, not from the caller's environment")
    var withTestHooks = hostile
    withTestHooks["MCAP_CONFIG"] = "/tmp/c.env"
    withTestHooks["MCAP_SECURITY_BIN"] = "/tmp/fake/security"
    let forwarded = PipelineLauncher.sanitizedEnvironment(from: withTestHooks)
    check(Set(forwarded.keys) == Set(plain.keys).union(["MCAP_CONFIG", "MCAP_SECURITY_BIN"]) && forwarded["MCAP_CONFIG"] == "/tmp/c.env" && forwarded["MCAP_SECURITY_BIN"] == "/tmp/fake/security",
          "sanitizedEnvironment: MCAP_CONFIG and the test-only MCAP_SECURITY_BIN are the only things forwarded", forwarded.keys.sorted().joined(separator: " "))
    withTestHooks["MCAP_SECURITY_BIN"] = ""
    check(PipelineLauncher.sanitizedEnvironment(from: withTestHooks)["MCAP_SECURITY_BIN"] == nil, "sanitizedEnvironment: an empty MCAP_SECURITY_BIN is not forwarded")
}

// =====================================================================================
// SPEC 18: S-LO-01 ... S-LO-20. The per-meeting local-only flag, the organisation policy in the shell, the
// launcher's contract and trust checks, the notification texts. Device-free like everything above: fake recorder, fake pipeline, a fake
// python, an injected pipeline version and file owner, a virtual clock. No Keychain (the fake security shim is still in place), no network.
// =====================================================================================

private let loContact = "IT 헬프데스크 #it-help"

/// A policy through the real strict parser (the same one the app reads policy.json with): `extra` replaces or adds top-level keys.
private func loPolicy(profile: String = "company", _ extra: [String: Any] = [:]) -> OrgPolicy {
    var object: [String: Any] = ["schema": 1, "profile": profile, "revision": 12, "support": ["contact": loContact]]
    for (key, value) in extra { object[key] = value }
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return OrgPolicy.parse(data)
}

private func loSessionJSON(_ dir: URL) -> [String: Any]? { ShellUtil.readJSON(dir.appendingPathComponent("session.json")) }
private func loKeys(_ dir: URL) -> Set<String> { Set((loSessionJSON(dir) ?? [:]).keys) }
private func loFlag(_ dir: URL) -> Bool? { SessionController.sessionLocalOnly(in: dir) }
private func loSource(_ dir: URL) -> String? { loSessionJSON(dir)?["local_only_source"] as? String }

private func loWriteState(_ dir: URL, _ json: String) {
    try? Data(json.utf8).write(to: dir.appendingPathComponent("state.json"))
}

/// The private history (SUPPORT_DIR/session-private/<id>.json) of a session as a list of dictionaries.
private func loHistory(_ support: URL, _ session: String) -> [[String: Any]] {
    return (SessionPrivateLog.read(session: session, supportDir: support)?[SessionPrivateLog.historyKey] as? [[String: Any]]) ?? []
}

private func loPrivacy(_ values: [String: String] = [:], in base: URL) -> PrivacySettings {
    return PrivacySettings.build(from: values, supportDir: base.appendingPathComponent("lo-support", isDirectory: true), source: "selftest")
}

private func loHarness(_ name: String, in base: URL, policy: OrgPolicy = OrgPolicy.absent(), privacy: PrivacySettings? = nil,
                       reader: (() -> OrgPolicy)? = nil, patch: ((Bool, String, URL) throws -> Void)? = nil,
                       configure: (inout AppConfig) -> Void = { _ in }) -> Harness {
    return Harness(name, in: base, policy: Harness.PolicyInputs(policy: policy, privacy: privacy, policyReader: reader, sessionPatch: patch), configure: configure)
}

// MARK: S-LO-01 .. S-LO-02: the policy core and the start value of the flag

private func testLOStartValues(_ base: URL) {
    section("S-LO-02: the start value of the flag in every new recording (policy x settings matrix) and its restrictive parsing")
    func started(_ name: String, policy: OrgPolicy, settings: PrivacySettings) -> (Harness, FakeRecorder)? {
        let h = loHarness(name, in: base, policy: policy, privacy: settings)
        h.controller.startRecordingNow(); h.sync()
        guard let rec = h.current else { return nil }
        return (h, rec)
    }
    let cases: [(String, OrgPolicy, [String: String], Bool, String)] = [
        ("no policy, defaults", OrgPolicy.absent(), [:], false, "default"),
        ("no policy, LOCAL_ONLY_DEFAULT=1", OrgPolicy.absent(), ["LOCAL_ONLY_DEFAULT": "1"], true, "config-default"),
        ("no policy, LOCAL_ONLY_DEFAULT=maybe (not understood: fail closed)", OrgPolicy.absent(), ["LOCAL_ONLY_DEFAULT": "maybe"], true, "config-default"),
        ("company policy, flag default off", loPolicy(), [:], false, "default"),
        ("policy local_only.default", loPolicy(["local_only": ["default": true]]), [:], true, "policy-default"),
        ("policy local_only.locked", loPolicy(["local_only": ["locked": true]]), [:], true, "policy-lock"),
        ("a policy that cannot be read (locked)", OrgPolicy.parse(Data(#"{"schema":2}"#.utf8)), [:], true, "policy-invalid"),
        ("policy default beats a user setting that says off", loPolicy(["local_only": ["default": true]]), ["LOCAL_ONLY_DEFAULT": "0"], true, "policy-default"),
    ]
    for (i, c) in cases.enumerated() {
        guard let (h, rec) = started("lo-start-\(i)", policy: c.1, settings: loPrivacy(c.2, in: base)) else { check(false, "\(c.0): a recorder was created"); continue }
        check(rec.localOnlyCalls.count == 1 && rec.localOnlyCalls[0].value == c.3 && rec.localOnlyCalls[0].source == c.4,
              "\(c.0): setLocalOnly(\(c.3), \(c.4)) once, before start()", "\(rec.localOnlyCalls)")
        check(loFlag(rec.dir) == c.3 && loSource(rec.dir) == c.4, "\(c.0): the first session.json carries local_only=\(c.3) and local_only_source=\(c.4)",
              "\(String(describing: loFlag(rec.dir))) \(loSource(rec.dir) ?? "nil")")
        check(h.state.localOnly?.value == c.3 && h.state.localOnly?.targetSession == rec.dir.lastPathComponent, "\(c.0): the menu view says \(c.3) for this recording", "\(String(describing: h.state.localOnly))")
    }
    // a recorder that does not know the flag (an older fake) still records: nothing is called, nothing breaks
    let plain = Harness("lo-start-plain", in: base)
    plain.controller.startRecordingNow(); plain.sync()
    check(plain.current?.isRecording == true, "a recorder without SessionRecordingPrivacy support still records")

    // PrivacySettings: every switch is read to the restrictive value of ITS key
    let ps = { (values: [String: String]) in loPrivacy(values, in: base) }
    check(ps([:]).localOnlyDefault == false && ps([:]).logContent == true && ps([:]).micMuteGate == "off" && ps([:]).appLogMaxMB == 0,
          "settings without any new key reproduce today's behaviour (flag off, LOG_CONTENT 1, no mute gate, no rotation)")
    check(ps(["LOCAL_ONLY_DEFAULT": "maybe"]).localOnlyDefault && !ps(["LOCAL_ONLY_DEFAULT": "0"]).localOnlyDefault && ps(["LOCAL_ONLY_DEFAULT": "ON"]).localOnlyDefault,
          "LOCAL_ONLY_DEFAULT: unknown text is on; 0 is off; ON is on")
    check(!ps(["LOG_CONTENT": "banana"]).logContent && ps(["LOG_CONTENT": "1"]).logContent && !ps(["LOG_CONTENT": "no"]).logContent,
          "LOG_CONTENT: unknown text is off (no content in the log)")
    check(ps(["MIC_MUTE_GATE": "banana"]).micMuteGate == "on" && ps(["MIC_MUTE_GATE": "off"]).micMuteGate == "off", "MIC_MUTE_GATE: unknown text is on")
}

// MARK: S-LO-03: a real Recorder

/// A source that cannot start (no permission): a recorder whose two sources fail does not start at all.
private final class LOFailingSource: CaptureTrackSource {
    let sampleRate: Double = 48000
    let sourceLabel: String
    let deviceName = "none"
    var onSamples: (([Float], UInt64) -> Void)?
    var onWarning: ((String) -> Void)?
    var onDeviceChange: ((String) -> Void)?
    init(_ label: String) { sourceLabel = label }
    func start() throws { throw RecorderError.permissionDenied("selftest: \(sourceLabel) cannot start") }
    func stop() {}
}

private func testLORecorderKeys(_ base: URL) {
    section("S-LO-03: a real Recorder (synthetic sources): no local_only keys until set, the keys after, a private history, nothing after the stop")
    let fm = FileManager.default
    let root = base.appendingPathComponent("lo-recorder", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    var cfg = AppConfig.defaults()
    cfg.supportDir = support
    let secretTitle = "Secret Roadmap Review"
    let signal = PlatformSignal(platform: .zoom, inCall: true, confidence: .high, titleHint: secretTitle, meetingURL: nil, meetingKey: nil,
                                bundleID: "us.zoom.xos", evidence: [])
    func make(_ id: String) -> (Recorder, URL) {
        let dir = root.appendingPathComponent("sessions/\(id)", isDirectory: true)
        try? fm.removeItem(at: dir)
        let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: 0.3)
        let mic = SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200, amplitude: 0.1)
        return (Recorder(sessionDir: dir, signal: signal, config: cfg, remote: { remote }, mic: { mic }), dir)
    }
    // the keys of CaptureSelfTest's exact-key assertion (SPEC 4.1 plus warnings and remote_silent_suspected)
    let baseKeys: Set<String> = ["schema", "session_id", "platform", "platform_label", "title_hint", "meeting_url", "app_bundle_id",
                                 "start_time", "end_time", "end_reason", "tracks", "app_version", "warnings", "remote_silent_suspected"]

    // A: never asked
    let (a, aDir) = make("2026-10-07_1400_zoom")
    do { try a.start() } catch { check(false, "A: start()", "\(error)"); return }
    Thread.sleep(forTimeInterval: 0.5)
    check(loKeys(aDir) == baseKeys, "A: while recording, session.json has exactly the keys it always had (no local_only before setLocalOnly)",
          "\(loKeys(aDir).symmetricDifference(baseKeys))")
    _ = a.stop(reason: .manual)
    check(loKeys(aDir) == baseKeys && a.localOnly == nil, "A: the final session.json still has exactly those keys (the capture self test's assertion stays true)")
    check(SessionPrivateLog.read(session: aDir.lastPathComponent, supportDir: support) == nil, "A: a recorder that was never asked writes no private history either")

    // B: asked before start() (what the controller does), toggled while recording, asked again after the stop
    let (b, bDir) = make("2026-10-07_1500_zoom")
    check(b.setLocalOnly(true, source: "config-default") && b.localOnly == true, "B: setLocalOnly before start() is accepted")
    check(b.setLocalOnly(true, source: "Bad Source!") == false && b.setLocalOnly(true, source: "") == false && b.setLocalOnly(true, source: String(repeating: "a", count: 41)) == false,
          "B: a source outside [a-z0-9_:-]{1,40} is refused")
    do { try b.start() } catch { check(false, "B: start()", "\(error)"); return }
    check(loFlag(bDir) == true && loSource(bDir) == "config-default" && loKeys(bDir) == baseKeys.union(["local_only", "local_only_source"]),
          "B: the first session.json carries the value set before start() and exactly two more keys", "\(loKeys(bDir).symmetricDifference(baseKeys))")
    check(b.setLocalOnly(false, source: "menu") && loFlag(bDir) == false && loSource(bDir) == "menu" && b.localOnly == false,
          "B: while recording, setLocalOnly rewrites session.json at once (read back: false, menu)")
    check(b.setLocalOnly(true, source: "menu") && loFlag(bDir) == true, "B: ... and back to true")
    Thread.sleep(forTimeInterval: 0.3)
    _ = b.stop(reason: .manual)
    check(loFlag(bDir) == true && loSource(bDir) == "menu" && loSessionJSON(bDir)?["end_reason"] as? String == "manual", "B: the final session.json keeps the flag and has its end_reason")
    check(b.setLocalOnly(false, source: "menu") == false && loFlag(bDir) == true, "B: after the stop session.json is final: false, unchanged (the controller patches it, SessionJSONPatch)")
    let history = loHistory(support, bDir.lastPathComponent)
    check(history.count == 3 && history.map { $0["value"] as? Bool } == [true, false, true] && history.map { $0["source"] as? String } == ["config-default", "menu", "menu"]
          && history.map { $0["phase"] as? String } == ["start", "recording", "recording"] && history.allSatisfy { ($0["at"] as? String)?.isEmpty == false },
          "B: the private history has the three accepted calls (value, source, phase, time), none of the refused ones", "\(history)")
    let sidecar = (try? String(contentsOf: SessionPrivateLog.file(session: bDir.lastPathComponent, supportDir: support) ?? URL(fileURLWithPath: "/nonexistent"), encoding: .utf8)) ?? ""
    check(!sidecar.contains(secretTitle) && !logText().contains(secretTitle), "B: neither the private history nor app.log carries the meeting title")
    check(!bDir.path.hasPrefix(support.appendingPathComponent("session-private").path) && SessionPrivateLog.file(session: bDir.lastPathComponent, supportDir: support)?.deletingLastPathComponent().lastPathComponent == "session-private",
          "B: the history lives in SUPPORT_DIR/session-private, not in the session folder that goes to Drive")

    // C: a recorder that cannot start leaves nothing behind: no session.json, and no history line for a session that never existed
    let cDir = root.appendingPathComponent("sessions/2026-10-07_1600_zoom", isDirectory: true)
    try? fm.removeItem(at: cDir)
    let failing = Recorder(sessionDir: cDir, signal: signal, config: cfg, remote: { LOFailingSource("global-tap") }, mic: { LOFailingSource("mic") })
    check(failing.setLocalOnly(true, source: "policy-lock"), "C: setLocalOnly before a start that is going to fail")
    var startFailed = false
    do { try failing.start() } catch { startFailed = true }
    check(startFailed && !fm.fileExists(atPath: cDir.appendingPathComponent("session.json").path), "C: start() fails (no source can start) and leaves no session.json")
    check(SessionPrivateLog.read(session: cDir.lastPathComponent, supportDir: support) == nil, "C: ... and no private history line for the session that never existed")
    check(failing.setLocalOnly(false, source: "menu") == false, "C: ... and a later setLocalOnly is refused (the session file is final)")
}

// MARK: S-LO-04: toggle during the recording

private func testLOToggleRecording(_ base: URL) {
    section("S-LO-04: toggle during the recording (both ways, read back from session.json, notifications, the menu item)")
    let h = loHarness("lo-toggle-rec", in: base)
    h.controller.startRecordingNow(); h.sync()
    guard let rec = h.current else { check(false, "a recording started"); return }
    let name = rec.dir.lastPathComponent
    check(h.state.localOnly == LocalOnlyView(value: false, locked: false, targetSession: name, canRelax: true, pipelineTooOld: false), "the menu view of a new recording: off, can be turned on",
          "\(String(describing: h.state.localOnly))")
    var item = StatusMenuController.localOnlyItemState(for: h.state)
    check(item.title == "Local-Only Meeting" && !item.checked && item.enabled && item.tooltip?.contains("이 회의만 적용") == true, "the menu item: enabled, unchecked, Korean tooltip says it is for this meeting only", "\(item)")

    let on = h.controller.toggleLocalOnly()
    check(on == .applied(LocalOnlyValue(value: true, source: "menu", locked: false)), "toggle: applied(true, menu)", "\(on)")
    check(loFlag(rec.dir) == true && loSource(rec.dir) == "menu" && rec.localOnlyCalls.last?.value == true, "the recorder wrote it and session.json reads back true / menu")
    let n1 = h.notifier.posted.last
    check(n1?.kind == .localOnlyChanged && n1?.title == "로컬 전용 회의" && n1?.subtitle == "수동 · 이 회의만 적용"
          && n1?.body == "전사는 이 Mac에서만 처리해요. 회의록(Claude), 캘린더 조회, Drive 업로드는 하지 않아요. 전사본과 녹음은 이 Mac의 로컬 폴더에 저장돼요",
          "ON posts the design text: title, 'platform · 이 회의만 적용', body", "\(n1.map { "\($0.title) | \($0.subtitle) | \($0.body)" } ?? "nil")")
    check(h.state.localOnly?.value == true && h.state.localOnly?.canRelax == true, "the menu view follows: on, can still be turned off")
    item = StatusMenuController.localOnlyItemState(for: h.state)
    check(item.checked && item.enabled, "the menu item is checked and still enabled")

    let before = h.notifier.posted.count
    check(h.controller.toggleLocalOnly(to: true) == .applied(LocalOnlyValue(value: true, source: "menu", locked: false)) && h.notifier.posted.count == before
          && rec.localOnlyCalls.count == 2, "asking for the value it already has changes nothing: no write, no notification")

    let off = h.controller.toggleLocalOnly()
    check(off == .applied(LocalOnlyValue(value: false, source: "menu", locked: false)) && loFlag(rec.dir) == false, "toggle again: applied(false)", "\(off)")
    let n2 = h.notifier.posted.last
    check(n2?.title == "로컬 전용 해제" && n2?.subtitle == "이 회의: 전사=이 Mac · 회의록=켜짐 · 보관=Google Drive" && n2?.body == "민감한 내용이 있었다면 처리 전에 다시 켜세요",
          "OFF posts the design text: the lanes that are true now and the reminder", "\(n2.map { "\($0.title) | \($0.subtitle) | \($0.body)" } ?? "nil")")
    check(rec.localOnlyCalls.map { "\($0.value):\($0.source)" } == ["false:default", "true:menu", "false:menu"], "the recorder saw default, menu, menu", "\(rec.localOnlyCalls)")

    // a recorder that cannot write session.json: nothing changes, and the user is told
    rec.failLocalOnly = true
    let failed = h.controller.toggleLocalOnly()
    var failedKind = false
    if case .writeFailed = failed { failedKind = true }
    check(failedKind, "a recorder that cannot write session.json: .writeFailed", "\(failed)")
    check(loFlag(rec.dir) == false && h.state.localOnly?.value == false, "... the flag and the menu keep the old value")
    check(h.notifier.posted.last?.title == "로컬 전용을 저장하지 못했어요" && h.notifier.posted.last?.action == .openLog(Log.fileURL.path), "... and the notification says it was not saved (click opens the log)")
    rec.failLocalOnly = false

    // nothing is recording and nothing was recorded: no target
    let idle = loHarness("lo-toggle-idle", in: base)
    check(idle.controller.toggleLocalOnly() == .noTarget && idle.notifier.posted.isEmpty, "no recording and no recent session: .noTarget, no notification")
    check(idle.state.localOnly == nil || idle.state.localOnly?.targetSession == nil, "idle: the menu view has no target")
    idle.controller.tick()
    check(idle.state.localOnly?.targetSession == nil && StatusMenuController.localOnlyItemState(for: idle.state).enabled == false, "idle menu item: disabled")
}

// MARK: S-LO-05: locked

private func testLOLocked(_ base: URL) {
    section("S-LO-05: the policy locks the flag: the recording starts on, OFF is refused (during and after the recording), the menu says why")
    let policy = loPolicy(["local_only": ["locked": true]])
    check(policy.isValid && policy.forcesLocalOnly && policy.supportContact == loContact, "the test policy is valid, locks the flag and has a contact")
    let h = loHarness("lo-locked", in: base, policy: policy)
    h.controller.startRecordingNow(); h.sync()
    guard let rec = h.current else { check(false, "a recording started"); return }
    check(loFlag(rec.dir) == true && loSource(rec.dir) == "policy-lock", "the recording starts local-only (policy-lock)")
    check(h.state.localOnly == LocalOnlyView(value: true, locked: true, targetSession: rec.dir.lastPathComponent, canRelax: false, pipelineTooOld: false), "the view: on, locked, cannot be relaxed", "\(String(describing: h.state.localOnly))")
    let item = StatusMenuController.localOnlyItemState(for: h.state)
    check(!item.enabled && item.checked && item.title.contains("조직 정책으로 고정") && item.tooltip == "조직 정책으로 고정", "the menu item is checked, disabled and says '조직 정책으로 고정'", "\(item)")
    let result = h.controller.toggleLocalOnly()
    check(result == .refusedLocked && loFlag(rec.dir) == true && rec.localOnlyCalls.count == 1, "OFF is refused (.refusedLocked): session.json and the recorder are untouched")
    let n = h.notifier.posted.last
    check(n?.kind == .localOnlyChanged && n?.title == "로컬 전용은 조직 정책으로 고정돼 있어요" && n?.body == "해제할 수 없어요 · 문의: \(loContact)", "the refusal posts the design text with the support contact", "\(n.map { "\($0.title) | \($0.body)" } ?? "nil")")
    let again = h.notifier.posted.count
    check(h.controller.toggleLocalOnly(to: true) == .applied(LocalOnlyValue(value: true, source: "policy-lock", locked: true)) && h.notifier.posted.count == again,
          "asking for ON while it is locked on: nothing to do, no notification")
    // after the stop
    h.controller.stopRecordingNow(); h.sync()
    check(h.controller.toggleLocalOnly() == .refusedLocked && loFlag(rec.dir) == true, "after the stop OFF is still refused and session.json still says true")

    // the policy locks the flag in the middle of a recording (a new revision): the view and the toggle follow the live policy
    let live = loHarness("lo-locked-live", in: base)
    live.controller.startRecordingNow(); live.sync()
    live.policyBox.policy = policy
    live.controller.tick()
    check(live.state.localOnly?.locked == true && live.state.localOnly?.value == true && live.controller.toggleLocalOnly() == .refusedLocked,
          "a policy that locks the flag while a recording runs: the view says locked and on, OFF is refused", "\(String(describing: live.state.localOnly))")
    // a policy that cannot be read behaves like a lock
    let broken = loHarness("lo-locked-invalid", in: base, policy: OrgPolicy.parse(Data("not json".utf8)))
    broken.controller.startRecordingNow(); broken.sync()
    check(broken.state.localOnly?.locked == true && broken.controller.toggleLocalOnly() == .refusedLocked, "a policy that cannot be read (locked) forces the flag on like a lock")
}

// MARK: S-LO-06 .. S-LO-08: toggle after the stop

private func testLOToggleAfterStop(_ base: URL) {
    section("S-LO-06: toggle after the stop: state checks, atomic patch with the other keys kept, read-back, history, too late")
    func recorded(_ name: String) -> (Harness, FakeRecorder)? {
        let h = loHarness(name, in: base)
        h.controller.startRecordingNow(); h.sync()
        h.clock.advance(60)
        guard let rec = h.current else { return nil }
        h.controller.stopRecordingNow(); h.sync()
        return (h, rec)
    }
    // a) no state.json yet: ON and OFF are possible, the other keys survive, the history is in the private sidecar
    guard let (h, rec) = recorded("lo-after-a") else { check(false, "a session was recorded"); return }
    let name = rec.dir.lastPathComponent
    let keysBefore = loKeys(rec.dir)
    check(h.state.localOnly?.targetSession == name && h.state.localOnly?.canRelax == true && h.state.localOnly?.value == false,
          "after the stop the menu view still targets the session (no state.json: ON and OFF possible)", "\(String(describing: h.state.localOnly))")
    let on = h.controller.toggleLocalOnly()
    check(on == .applied(LocalOnlyValue(value: true, source: "menu-after-stop", locked: false)), "ON after the stop: applied(true, menu-after-stop)", "\(on)")
    check(loFlag(rec.dir) == true && loSource(rec.dir) == "menu-after-stop" && keysBefore.isSubset(of: loKeys(rec.dir))
          && loSessionJSON(rec.dir)?["session_id"] as? String == name, "session.json reads back true / menu-after-stop and every other key is still there")
    check(h.notifier.posted.last?.title == "로컬 전용 회의", "the success notification is the same ON text")
    let history = loHistory(h.config.supportDir, name)
    check(history.count == 1 && history[0]["phase"] as? String == "after-stop" && history[0]["value"] as? Bool == true && history[0]["source"] as? String == "menu-after-stop",
          "the controller appended one history line to the private sidecar", "\(history)")
    check(!((try? String(contentsOf: rec.dir.appendingPathComponent("session.json"), encoding: .utf8)) ?? "").contains("local_only_history"),
          "the history is NOT in session.json (that folder goes to Drive)")
    let off = h.controller.toggleLocalOnly()
    check(off == .applied(LocalOnlyValue(value: false, source: "menu-after-stop", locked: false)) && loFlag(rec.dir) == false, "OFF with no state.json: applied(false)", "\(off)")
    check(h.notifier.posted.last?.title == "로컬 전용 해제" && loHistory(h.config.supportDir, name).count == 2, "... with the OFF text and a second history line")

    // b) the pipeline is running (state.json, stage before publishing): ON still works, OFF is too late
    guard let (b, bRec) = recorded("lo-after-b") else { check(false, "session b"); return }
    loWriteState(bRec.dir, #"{"schema":1,"stage":"transcribing","stage_detail":"remote 3/9"}"#)
    check(b.controller.toggleLocalOnly(to: true) == .applied(LocalOnlyValue(value: true, source: "menu-after-stop", locked: false)) && loFlag(bRec.dir) == true,
          "stage transcribing: ON is still applied")
    b.controller.tick()
    check(b.state.localOnly?.canRelax == false && b.state.localOnly?.targetSession != nil && b.state.localOnly?.value == true, "the view: on, cannot be relaxed any more", "\(String(describing: b.state.localOnly))")
    let bItem = StatusMenuController.localOnlyItemState(for: b.state)
    check(bItem.checked && !bItem.enabled && bItem.tooltip == "처리가 이미 시작돼 더 이상 끌 수 없어요", "the menu item is checked and disabled, with the reason", "\(bItem)")
    check(b.controller.toggleLocalOnly(to: false) == .tooLate && loFlag(bRec.dir) == true && b.notifier.posted.last?.title == "로컬 전용을 바꿀 수 없어요",
          "stage transcribing: OFF is .tooLate, session.json stays true, the user is told")
    loWriteState(bRec.dir, #"{"schema":1,"stage":"noting"}"#)
    check(b.controller.toggleLocalOnly(to: true) == .applied(LocalOnlyValue(value: true, source: "menu-after-stop", locked: false)), "stage noting: asking for ON (already on) is fine")

    // c) publishing and later: too late for both, then the session is forgotten
    for stage in ["publishing", "done", "failed"] {
        guard let (c, cRec) = recorded("lo-after-c-\(stage)") else { check(false, "session c \(stage)"); continue }
        loWriteState(cRec.dir, "{\"schema\":1,\"stage\":\"\(stage)\"}")
        check(c.controller.toggleLocalOnly() == .tooLate && loFlag(cRec.dir) == false, "stage \(stage): ON is .tooLate and session.json is not touched")
        check(c.state.localOnly?.targetSession == nil && StatusMenuController.localOnlyItemState(for: c.state).enabled == false, "stage \(stage): the menu item has no target any more")
        check(c.controller.toggleLocalOnly() == .noTarget, "stage \(stage): afterwards the session is forgotten (.noTarget)")
    }
    // an unreadable state.json counts as 'started, stage unknown'
    guard let (u, uRec) = recorded("lo-after-unknown") else { check(false, "session unknown stage"); return }
    try? Data("{ not json".utf8).write(to: uRec.dir.appendingPathComponent("state.json"))
    check(u.controller.toggleLocalOnly() == .tooLate && loFlag(uRec.dir) == false, "a state.json that cannot be read: never claim the flag can still change (.tooLate)")

    // d) the folder is gone (the pipeline published it)
    guard let (g, gRec) = recorded("lo-after-gone") else { check(false, "session gone"); return }
    try? FileManager.default.removeItem(at: gRec.dir)
    check(g.controller.toggleLocalOnly() == .tooLate, "the staging folder is gone: .tooLate")
    check(g.controller.toggleLocalOnly() == .noTarget, "... and forgotten")

    // e) a new recording takes the menu item over
    guard let (n, nRec) = recorded("lo-after-new") else { check(false, "session new"); return }
    n.clock.advance(30)
    n.controller.startRecordingNow(); n.sync()
    guard n.recorders.count == 2, let second = n.current else { check(false, "a second recording started"); return }
    check(n.state.localOnly?.targetSession == second.dir.lastPathComponent, "a new recording takes the menu item over from the earlier session")
    check(n.controller.toggleLocalOnly() == .applied(LocalOnlyValue(value: true, source: "menu", locked: false)) && loFlag(second.dir) == true && loFlag(nRec.dir) == false,
          "the toggle changes the new recording only; the earlier session keeps its value")

    // f) a session folder the controller deletes (an accidental blip) takes its private history with it, and is never a toggle target
    let blip = loHarness("lo-after-blip", in: base)
    blip.run(until: { !blip.recorders.isEmpty }, limit: 15, [meetSignal()])
    if let br = blip.current {
        SessionPrivateLog.append(session: br.dir.lastPathComponent, supportDir: blip.config.supportDir, entry: ["value": false, "source": "default", "phase": "start"])
        check(loHistory(blip.config.supportDir, br.dir.lastPathComponent).count == 1, "(a private history line exists for the recording)")
        blip.controller.systemWillSleep()
        check(!FileManager.default.fileExists(atPath: br.dir.path) && loHistory(blip.config.supportDir, br.dir.lastPathComponent).isEmpty
              && !FileManager.default.fileExists(atPath: SessionPrivateLog.file(session: br.dir.lastPathComponent, supportDir: blip.config.supportDir)?.path ?? "/nonexistent"),
              "a blip deleted by the controller: the folder and its private history are gone")
        check(blip.controller.toggleLocalOnly() == .noTarget, "... and there is nothing to toggle")
    } else { check(false, "a blip session started") }
}

private func testLOLateAndFailures(_ base: URL) {
    section("S-LO-07: write -> read back -> state again: appliedMaybeLate, a failing patch, a patch that lies")
    func recorded(_ name: String, patch: @escaping (Bool, String, URL) throws -> Void) -> (Harness, FakeRecorder)? {
        let h = loHarness(name, in: base, patch: patch)
        h.controller.startRecordingNow(); h.sync()
        h.clock.advance(60)
        guard let rec = h.current else { return nil }
        h.controller.stopRecordingNow(); h.sync()
        return (h, rec)
    }
    let real: (Bool, String, URL) throws -> Void = { value, source, dir in try SessionJSONPatch.apply(localOnly: value, source: source, to: dir) }

    // the pipeline reaches publishing while the file is written
    if let (h, rec) = recorded("lo-late-publishing", patch: { value, source, dir in
        try real(value, source, dir)
        loWriteState(dir, #"{"schema":1,"stage":"publishing"}"#)
    }) {
        let r = h.controller.toggleLocalOnly()
        check(r == .appliedMaybeLate && loFlag(rec.dir) == true, "ON written, stage publishing right after: .appliedMaybeLate (the value is written)", "\(r)")
        let n = h.notifier.posted.last
        check(n?.kind == .localOnlyChanged && n?.title == "로컬 전용 적용을 확인하세요" && n?.body == "처리가 이미 끝나는 중이라 적용되지 않았을 수 있어요" && n?.sound == true,
              "... the warning replaces the success notification (design text)", "\(n.map { "\($0.title) | \($0.body)" } ?? "nil")")
        check(!h.notifier.posted.contains { $0.title == "로컬 전용 회의" }, "... and no success notification was posted")
    } else { check(false, "session late publishing") }

    // the folder disappears while the file is written
    if let (h, rec) = recorded("lo-late-gone", patch: { value, source, dir in
        try real(value, source, dir)
        try? FileManager.default.removeItem(at: dir)
    }) {
        check(h.controller.toggleLocalOnly() == .appliedMaybeLate, "ON written, folder gone right after: .appliedMaybeLate", "\(rec.dir.lastPathComponent)")
    } else { check(false, "session late gone") }

    // an OFF that meets a state.json that was not there before
    var calls = 0
    if let (h, rec) = recorded("lo-late-off", patch: { value, source, dir in
        calls += 1
        try real(value, source, dir)
        if calls == 2 { loWriteState(dir, #"{"schema":1,"stage":"queued"}"#) }
    }) {
        check(h.controller.toggleLocalOnly() == .applied(LocalOnlyValue(value: true, source: "menu-after-stop", locked: false)), "first toggle (ON) is applied")
        let off = h.controller.toggleLocalOnly()
        check(off == .appliedMaybeLate && loFlag(rec.dir) == false, "OFF while the pipeline started in the meantime: .appliedMaybeLate (a ratchet may have seen the ON)", "\(off)")
    } else { check(false, "session late off") }

    // the patch throws: nothing changed, the user is told
    struct Boom: Error {}
    if let (h, rec) = recorded("lo-fail-throw", patch: { _, _, _ in throw Boom() }) {
        let r = h.controller.toggleLocalOnly()
        if case .writeFailed = r {} else { check(false, "a patch that throws: .writeFailed", "\(r)") }
        check(loFlag(rec.dir) == false && h.notifier.posted.last?.title == "로컬 전용을 저장하지 못했어요" && loHistory(h.config.supportDir, rec.dir.lastPathComponent).isEmpty,
              "... session.json is unchanged, no history line, the user is told")
        check(h.state.localOnly?.value == false, "... and the menu view keeps the old value")
    } else { check(false, "session fail throw") }

    // the patch claims success but the file says something else: the read-back catches it
    if let (h, rec) = recorded("lo-fail-lie", patch: { _, _, _ in }) {
        let r = h.controller.toggleLocalOnly()
        if case .writeFailed(let why) = r { check(why.contains("does not say true"), "a patch that did nothing: .writeFailed from the read-back", why) } else { check(false, "a patch that lies: .writeFailed", "\(r)") }
        check(loFlag(rec.dir) == false && h.state.localOnly?.value == false, "... nothing is claimed")
    } else { check(false, "session fail lie") }

    // the real patch (default): the other keys are kept and the file is written atomically (no temp file is left behind)
    let h = loHarness("lo-real-patch", in: base)
    h.controller.startRecordingNow(); h.sync(); h.clock.advance(60)
    guard let rec = h.current else { check(false, "session real patch"); return }
    h.controller.stopRecordingNow(); h.sync()
    let before = loKeys(rec.dir)
    check(h.controller.toggleLocalOnly() == .applied(LocalOnlyValue(value: true, source: "menu-after-stop", locked: false)), "the real SessionJSONPatch works through the controller")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: rec.dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    check(before == loKeys(rec.dir) && !files.contains { $0.contains("tmp") }, "... keys unchanged, no temporary file left", "\(files)")
}

private func testLOPipelineAge(_ base: URL) {
    section("S-LO-08: the pipeline contract in the toggle and in the menu (new Swift + old pipeline)")
    // a policy needs 0.2.0 for every value
    let company = loPolicy()
    let old = loHarness("lo-age-policy", in: base, policy: company)
    old.pipeline.version = "0.1.0"
    old.controller.startRecordingNow(); old.sync()
    old.controller.tick()
    check(old.state.localOnly?.pipelineTooOld == true, "policy + pipeline 0.1.0: the view says pipelineTooOld", "\(String(describing: old.state.localOnly))")
    let oldItem = StatusMenuController.localOnlyItemState(for: old.state)
    check(!oldItem.enabled && oldItem.title.contains("파이프라인이 오래됨") && oldItem.tooltip == "파이프라인이 오래돼 로컬 전용을 지원하지 않아요", "the menu item is disabled with the design text", "\(oldItem)")
    check(old.controller.toggleLocalOnly() == .pipelineTooOld && old.notifier.posted.last?.body == "파이프라인이 오래돼 로컬 전용을 지원하지 않아요" && loFlag(old.current!.dir) == false,
          ".pipelineTooOld, the text, session.json untouched")
    old.pipeline.version = "0.2.0"
    old.controller.tick()
    check(old.state.localOnly?.pipelineTooOld == false && old.controller.toggleLocalOnly() == .applied(LocalOnlyValue(value: true, source: "menu", locked: false)), "pipeline 0.2.0: allowed")
    // min_pipeline_version raises the bar
    let raised = loHarness("lo-age-min", in: base, policy: loPolicy(["min_pipeline_version": "0.3.0"]))
    raised.pipeline.version = "0.2.5"
    raised.controller.startRecordingNow(); raised.sync()
    check(raised.controller.toggleLocalOnly() == .pipelineTooOld, "policy.min_pipeline_version 0.3.0 and pipeline 0.2.5: refused")
    // the personal install (no policy): only ON needs the new pipeline; OFF is the way out
    let owner = loHarness("lo-age-owner", in: base, privacy: loPrivacy(["LOCAL_ONLY_DEFAULT": "1"], in: base))
    owner.pipeline.version = "0.1.0"
    owner.controller.startRecordingNow(); owner.sync()
    check(loFlag(owner.current!.dir) == true && owner.state.localOnly?.pipelineTooOld == false, "no policy, flag on by default, pipeline 0.1.0: OFF stays possible (it is the way out)", "\(String(describing: owner.state.localOnly))")
    check(owner.controller.toggleLocalOnly() == .applied(LocalOnlyValue(value: false, source: "menu", locked: false)), "... and works")
    check(owner.controller.toggleLocalOnly() == .pipelineTooOld && owner.state.localOnly?.pipelineTooOld == true, "... but ON again is refused with pipeline 0.1.0")
    let plain = loHarness("lo-age-owner-ok", in: base)
    plain.pipeline.version = "0.1.0"
    plain.controller.startRecordingNow(); plain.sync()
    check(plain.state.localOnly?.pipelineTooOld == true && plain.controller.toggleLocalOnly() == .pipelineTooOld, "no policy, flag off, pipeline 0.1.0: turning it ON is refused (it could not be honoured)")
    // an unknown version is NOT 'new enough': the menu waits for the launcher's answer, nothing is claimed in the meantime
    let unknown = loHarness("lo-age-unknown", in: base, policy: company)
    unknown.pipeline.probeAnswer = nil                                  // the launcher has not answered (python still running, or it cannot run)
    unknown.controller.startRecordingNow(); unknown.sync()
    check(unknown.pipeline.probes >= 1, "version not known: the launcher is asked for it (a background `python -m mcap --version`)", "\(unknown.pipeline.probes)")
    check(unknown.state.localOnly?.pipelineTooOld == true && !StatusMenuController.localOnlyItemState(for: unknown.state).enabled,
          "version not known: the menu item waits (disabled): nothing is claimed that cannot be honoured", "\(String(describing: unknown.state.localOnly))")
    check(unknown.controller.toggleLocalOnly() == .pipelineTooOld && loFlag(unknown.current!.dir) == false && !unknown.notifier.posted.contains { $0.title == "로컬 전용 회의" },
          "version not known: a toggle ON is refused, session.json is untouched, and no 'local-only ON' text was posted")
    unknown.pipeline.version = "0.2.0"                                  // the answer arrives
    unknown.pipeline.onVersionKnown?(); unknown.sync()
    check(unknown.state.localOnly?.pipelineTooOld == false, "the answer arrives (onVersionKnown): the controller computes the menu again and the item is enabled", "\(String(describing: unknown.state.localOnly))")
    check(unknown.controller.toggleLocalOnly() == .applied(LocalOnlyValue(value: true, source: "menu", locked: false)), "... and the toggle works")

    // the reviewer's case: the personal install (no policy, flag off), an OLD pipeline that was never asked for its version and has started on the session
    let stale = loHarness("lo-age-stale", in: base)
    stale.pipeline.probeAnswer = "0.1.0"                                // asked at the first menu state that needs it, answers: old
    stale.controller.startRecordingNow(); stale.sync(); stale.clock.advance(60)
    guard let staleRec = stale.current else { check(false, "stale: a recording started"); return }
    stale.controller.stopRecordingNow(); stale.sync()
    loWriteState(staleRec.dir, #"{"schema":1,"stage":"transcribing","stage_detail":"remote 3/9"}"#)           // the old pipeline is running on it
    check(stale.pipeline.version == "0.1.0" && stale.pipeline.probes >= 1, "the personal install: the version was asked when the menu first needed it (not at app start)", "\(String(describing: stale.pipeline.version)) \(stale.pipeline.probes)")
    let before = loSessionJSON(staleRec.dir).map { NSDictionary(dictionary: $0) }
    check(stale.controller.toggleLocalOnly() == .pipelineTooOld && loFlag(staleRec.dir) == false, "old pipeline already started on the session: ON is refused (.pipelineTooOld), session.json says false")
    check(!stale.notifier.posted.contains { $0.title == "로컬 전용 회의" || $0.summary.contains("local-only ON") } && stale.notifier.posted.last?.body == "파이프라인이 오래돼 로컬 전용을 지원하지 않아요",
          "... the user hears that the pipeline is too old, never that the meeting is local-only")
    check(before == loSessionJSON(staleRec.dir).map { NSDictionary(dictionary: $0) } && StatusMenuController.localOnlyItemState(for: stale.state).enabled == false, "... session.json is untouched and the menu item is disabled")
    // a pipeline that never answers (python cannot run) is never taken as new enough
    let silent = loHarness("lo-age-silent", in: base)
    silent.pipeline.probeAnswer = nil
    silent.controller.startRecordingNow(); silent.sync()
    for _ in 0..<3 { silent.controller.tick() }
    check(silent.controller.toggleLocalOnly() == .pipelineTooOld && loFlag(silent.current!.dir) == false, "no answer at all: the toggle stays refused however often it is asked")
    // nothing is asked when nothing is required: the flag is on by default and the click turns it OFF
    let off = loHarness("lo-age-noask", in: base, privacy: loPrivacy(["LOCAL_ONLY_DEFAULT": "1"], in: base))
    off.pipeline.probeAnswer = nil
    off.controller.startRecordingNow(); off.sync()
    check(off.pipeline.probes == 0 && off.state.localOnly?.pipelineTooOld == false, "flag on by default: the click would set OFF, which needs no new pipeline: the version is not asked for", "\(off.pipeline.probes)")
    check(off.controller.toggleLocalOnly() == .applied(LocalOnlyValue(value: false, source: "menu", locked: false)), "... and the OFF click works without it (the version is not needed to turn it off)")
    off.sync()
    check(off.pipeline.probes >= 1 && off.state.localOnly?.pipelineTooOld == true, "(afterwards the next click would set ON: then the version is needed and asked for, and the item waits)", "\(off.pipeline.probes)")
    let idle = loHarness("lo-age-idle", in: base)
    idle.pipeline.probeAnswer = nil
    idle.controller.tick(); idle.sync()
    check(idle.pipeline.probes == 0, "idle (no recording, no recent session): the version is not asked for either")
}

// MARK: S-LO-09: the recording kill switch

private func testLOKillSwitch(_ base: URL) {
    section("S-LO-09: policy recording.enabled=false: a running recording ends within the 60 s poll, nothing starts, it resumes when allowed again")
    var current = loPolicy()
    var reads = 0
    let h = loHarness("lo-kill", in: base, policy: current, reader: { reads += 1; return current })
    let startedAt = h.clock.now
    h.controller.startRecordingNow(); h.sync()
    guard let rec = h.current else { check(false, "a recording started"); return }
    h.run(61, [])
    check(rec.isRecording && reads == 1, "61 s of virtual time: still recording, the policy was read once (every 60 s, not every tick)", "reads \(reads)")
    current = loPolicy(["recording": ["enabled": false]])
    check(current.isValid && !current.recordingEnabled, "(the new policy is valid and switches recording off)")
    let took = h.run(until: { !rec.isRecording }, limit: 130, [])
    check(took != nil && took! <= 61, "the recording ended within one poll interval of the change (\(took.map(String.init) ?? "never") s)")
    check(rec.stopReasons == [.manual], "end_reason is manual", "\(rec.stopReasons)")
    check(logCount("policy-kill-switch") >= 1, "the log names policy-kill-switch")
    check(h.pipeline.enqueued == [rec.dir], "the audio is kept and handed to the pipeline like any other stop")
    let stop = h.notifier.posted.last { $0.kind == .recordingStopped }
    check(stop?.body.contains("조직 정책에 따라 녹음을 멈췄어요") == true && stop?.sound == true && !h.config.notifyRecording,
          "the user is told (with sound), although NOTIFY_RECORDING is off", "\(stop?.body ?? "nil")")
    check(h.state.recordingBlockedByPolicy, "the state flags the kill switch")
    check(!StatusMenuController.manualItemState(for: h.state).enabled && StatusMenuController.manualItemState(for: h.state).title.contains("조직 정책으로 꺼짐"),
          "the menu's start item is disabled and says why")
    check(StatusMenuController.menuText(for: h.state, now: h.clock.now).lines.contains(StatusMenuController.policyBlockedText), "the menu has the standing line '조직 정책으로 녹음이 꺼져 있어요'")

    // refused starts: manual and automatic
    h.controller.startRecordingNow(); h.sync()
    check(h.recorders.count == 1, "a manual start is refused while recording is off")
    if case .error(let text) = h.state.status { check(text.contains("switched off by the organisation policy"), "the status is an error that says so", text) } else { check(false, "the status says why", "\(h.state.status)") }
    let failure = h.notifier.posted.last { $0.kind == .recordingFailed }
    check(failure?.subtitle == "조직 정책으로 녹음이 꺼져 있어요" && failure?.body.contains(loContact) == true && (failure?.body.count ?? 999) <= 100,
          "... and posts the policy notification with the contact (<= 100 characters)", "\(failure.map { "\($0.subtitle) | \($0.body)" } ?? "nil")")
    h.run(90, [meetSignal()])
    check(h.recorders.count == 1, "an automatically detected meeting is not recorded either (90 s of an active call)", "recorders \(h.recorders.count)")

    // allowed again
    current = loPolicy()
    let back = h.run(until: { !h.state.recordingBlockedByPolicy }, limit: 70, [meetSignal()])
    check(back != nil && back! <= 61, "the policy is read again within the interval and recording is allowed again (\(back.map(String.init) ?? "never") s)")
    h.run(until: { h.recorders.count >= 2 }, limit: 40, [meetSignal()])
    check(h.recorders.count == 2 && h.current?.isRecording == true, "the meeting that is still running is recorded now (the refusal does not keep holding it back)", "recorders \(h.recorders.count)")
    let elapsed = Int(h.clock.now.timeIntervalSince(startedAt))
    check(reads <= elapsed / 60 + 1, "the policy file was read \(reads) times in \(elapsed) s of virtual time (once per minute, not once per tick)")

    // an AUTO recording is ended too (no restart while it is off), also while auto recording is paused
    var live = loPolicy()
    let a = loHarness("lo-kill-auto", in: base, policy: live, reader: { live })
    a.run(until: { !a.recorders.isEmpty }, limit: 15, [meetSignal()])
    guard let autoRec = a.current else { check(false, "an auto recording started"); return }
    a.run(61, [meetSignal()])
    live = loPolicy(["recording": ["enabled": false]])
    let autoTook = a.run(until: { !autoRec.isRecording }, limit: 130, [meetSignal()])
    check(autoTook != nil && autoTook! <= 61 && autoRec.stopReasons == [.manual], "an auto-detected recording ends within one poll too (end_reason manual)", "\(autoTook.map(String.init) ?? "never") \(autoRec.stopReasons)")
    a.run(120, [meetSignal()])
    check(a.recorders.count == 1, "the call that goes on is not restarted while recording is switched off", "recorders \(a.recorders.count)")
    var live2 = loPolicy()
    let paused = loHarness("lo-kill-paused", in: base, policy: live2, reader: { live2 })
    paused.controller.setPaused(true); paused.sync()
    paused.controller.startRecordingNow(); paused.sync()          // a manual start works while auto recording is paused
    check(paused.current?.isRecording == true, "(a manual recording while auto recording is paused)")
    live2 = loPolicy(["recording": ["enabled": false]])
    paused.run(until: { paused.current?.isRecording == false }, limit: 130, [])
    check(paused.current?.isRecording == false, "the kill switch also works while auto recording is paused (the poll does not depend on detection)")
}

// MARK: S-LO-10 .. S-LO-12, S-LO-16: the launcher (contract, trust, environment, log lines)

/// A fake "python" for the SPEC 18 launcher tests: records its arguments and environment, finishes a session with a done state.json whose
/// title and folder name carry a recognisable slug; a session named *localonly* finishes as a local-only meeting (state.json local_only
/// and lanes). `reprocess --pending` reports the folders listed in the file pending-done (one "  DONE: <folder>" line each).
private let fakePythonPolicyScript = #"""
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
{ echo "ARGS: $*"; env | sort | sed 's/^/ENV /'; echo "-----"; } >> "$D/calls.log"
echo "hello from fakepython"
if [ "$3" = "reprocess" ]; then
  if [ "$4" = "--pending" ] && [ -f "$D/pending-done" ]; then
    cat "$D/pending-done"
    if grep -q FAILED "$D/pending-done"; then exit 1; fi
    exit 0
  fi
  echo "nothing pending: no failed session with a retryable error"; exit 0
fi
S="$4"
NAME="$(basename "$S")"
w() { printf '%s\n' "$1" > "$S/state.json.tmp" && mv "$S/state.json.tmp" "$S/state.json"; }
case "$NAME" in
  *failhide*)
    w "{\"schema\":1,\"stage\":\"failed\",\"error\":\"cannot move session to $D/local-archive/2026-10/2026-10-07_1400_Secret-Slug-Roadmap: No space left on device\",\"retryable\":false,\"local_only\":true}"
    exit 1 ;;
  *failplain*)
    w "{\"schema\":1,\"stage\":\"failed\",\"error\":\"cannot move session to $D/archive/2026-10/2026-10-07_1400_Weekly-Sync: No space left on device\",\"retryable\":false}"
    exit 1 ;;
  *localonly*)
    FINAL="$D/local-archive/2026-10/2026-10-07_1400_Secret-Slug-Roadmap"; mkdir -p "$FINAL"
    w "{\"schema\":1,\"stage\":\"done\",\"error\":null,\"title\":\"Secret Roadmap Review\",\"final_dir\":\"$FINAL\",\"local_only\":true,\"local_only_source\":\"menu\",\"lanes\":{\"llm\":\"skipped:local_only\",\"calendar\":\"skipped:local_only\",\"drive\":\"skipped:local_only\"}}"
    exit 0 ;;
esac
FINAL="$D/archive/2026-10/2026-10-07_1400_Weekly-Sync"; mkdir -p "$FINAL"
printf '# Weekly Sync\n' > "$FINAL/meeting-note.md"
w "{\"schema\":1,\"stage\":\"done\",\"error\":null,\"title\":\"Weekly Sync\",\"final_dir\":\"$FINAL\"}"
exit 0
"""#

/// One launcher over a fake python with an injected pipeline version and file owner (no real python is asked, no real owner is needed).
private final class LOLauncher {
    let world: LauncherWorld
    let launcher: PipelineLauncher
    let events = EventLog()
    private let versionCalls = Locked<Int>(0)
    var versionAsked: Int { versionCalls.value }

    init(_ name: String, in base: URL, policy: OrgPolicy, version: String?, privacy: PrivacySettings? = nil,
         fileInfo: @escaping (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile) {
        world = LauncherWorld(name, in: base, script: fakePythonPolicyScript)
        let counter = versionCalls
        launcher = PipelineLauncher(config: world.config, logDir: world.logs, statePollInterval: 0.05, stallTimeout: 600, policy: PolicyBox(policy), privacy: privacy,
                                    versionProbe: PipelineVersionProbe(),
                                    versionRunner: { _, _ in counter.value += 1; return version.map { "mcap \($0)" } },
                                    fileInfo: fileInfo)
        launcher.onEvent = { [events] in events.add($0) }
    }

    /// A staging session with a session.json (`localOnly` is written as given: a bool, a string, NSNull ...).
    func session(_ name: String, localOnly: Any? = nil) -> URL {
        let dir = world.session(name)
        var json: [String: Any] = ["schema": 1, "platform": "zoom", "start_time": "2026-10-07T14:00:12+09:00", "end_time": "2026-10-07T14:32:24+09:00"]
        if let flag = localOnly { json["local_only"] = flag }
        try? ShellUtil.writeJSONAtomically(json, to: dir.appendingPathComponent("session.json"))
        return dir
    }

    /// Queues the session and waits until the launcher said something final about it.
    @discardableResult
    func process(_ dir: URL, timeout: TimeInterval = 20) -> Bool {
        let name = dir.lastPathComponent
        launcher.enqueue(dir)
        return waitUntil(timeout) { events.strings.contains { $0.hasPrefix("finished:\(name):") || $0.hasPrefix("failed:\(name):") || $0.hasPrefix("blocked:\(name):") } }
    }

    var blocked: [(session: String, reason: PipelineBlock)] {
        return events.all.compactMap { if case .blocked(let s, let r) = $0 { return (s, r) } else { return nil } }
    }
    func finished(_ name: String) -> Bool { events.strings.contains { $0.hasPrefix("finished:\(name):") } }
}

private let rootOwned = OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: 0, mode: 0o755, size: 0)

private func testLOLauncherContract(_ base: URL) {
    section("S-LO-10: launch refusal: new Swift + old pipeline with a policy (nothing runs, nothing is written); accepted without a policy")
    let fm = FileManager.default

    // a policy and pipeline 0.1.0: refused, the session stays exactly as it was
    let a = LOLauncher("lo-contract-a", in: base, policy: loPolicy(), version: "0.1.0")
    let aDir = a.session("2026-10-07_1400_old1")
    check(a.process(aDir), "policy + pipeline 0.1.0: the launcher answers", a.events.strings.joined(separator: " | "))
    Thread.sleep(forTimeInterval: 0.2)
    check(a.events.strings == ["blocked:2026-10-07_1400_old1:pipeline-too-old"], "the only event is blocked(pipeline-too-old): no progress, no failure", a.events.strings.joined(separator: " | "))
    check(a.blocked.first?.reason == .pipelineTooOld(have: "0.1.0", required: "0.2.0"), "... it carries the version it found and the one it needs", "\(String(describing: a.blocked.first?.reason))")
    check(a.world.callsLog.isEmpty, "python was never started (no ARGS line in the fake's log)")
    check((try? fm.contentsOfDirectory(atPath: aDir.path))?.sorted() == ["session.json"], "the session folder holds only its session.json: no state.json, no attempt counted", "\((try? fm.contentsOfDirectory(atPath: aDir.path)) ?? [])")
    check(!fm.fileExists(atPath: a.world.logs.appendingPathComponent("pipeline-2026-10-07_1400_old1.log").path), "no pipeline log was created")
    check(a.launcher.pipelineVersion == "0.1.0", "the launcher remembers the version it saw (the menu reads it)")
    check(PipelineLauncher.logFileName(forSession: "x") == "pipeline-x.log", "(the log file name of a job is unchanged)")

    // 0.2.0: runs
    let b = LOLauncher("lo-contract-b", in: base, policy: loPolicy(), version: "0.2.0")
    check(b.process(b.session("2026-10-07_1400_ok2")) && b.finished("2026-10-07_1400_ok2") && b.blocked.isEmpty && b.world.callsLog.contains("ARGS: -m mcap process"), "policy + pipeline 0.2.0: the pipeline runs", b.events.strings.joined(separator: " | "))
    check(b.versionAsked == 1, "the version is asked once for the first launch (python -m mcap --version, cached by the probe)", "\(b.versionAsked)")
    _ = b.process(b.session("2026-10-07_1500_ok3"))
    check(b.versionAsked == 1, "... and not again for the next launch", "\(b.versionAsked)")

    // min_pipeline_version raises the bar; an unreadable answer is not enough
    let c = LOLauncher("lo-contract-c", in: base, policy: loPolicy(["min_pipeline_version": "0.3.0"]), version: "0.2.0")
    _ = c.process(c.session("2026-10-07_1400_min"))
    check(c.blocked.first?.reason == .pipelineTooOld(have: "0.2.0", required: "0.3.0"), "policy.min_pipeline_version 0.3.0 with pipeline 0.2.0: refused, the required version is the policy's", "\(String(describing: c.blocked.first?.reason))")
    let d = LOLauncher("lo-contract-d", in: base, policy: loPolicy(), version: nil)
    _ = d.process(d.session("2026-10-07_1400_nover"))
    check(d.blocked.first?.reason == .pipelineTooOld(have: nil, required: "0.2.0") && d.world.callsLog.isEmpty, "no readable version: refused (the policy cannot be honoured by an unknown pipeline)", "\(String(describing: d.blocked.first?.reason))")
    let personal = LOLauncher("lo-contract-personal", in: base, policy: loPolicy(profile: "personal"), version: "0.1.0")
    _ = personal.process(personal.session("2026-10-07_1400_pers"))
    check(personal.blocked.first?.reason == .pipelineTooOld(have: "0.1.0", required: "0.2.0"), "a personal-profile policy needs the new pipeline too")
    // a locked policy that still says personal (no runtime pin): 0.1.0 refused, 0.2.0 runs the local pipeline
    let lockedPersonal = OrgPolicy.parse(Data(#"{"schema":1,"profile":"personal","revision":1,"bogus":1}"#.utf8))
    check(lockedPersonal.isLocked && lockedPersonal.pinnedRuntimeRoot == nil, "(a locked policy whose file says personal has no runtime pin)")
    let lockedOld = LOLauncher("lo-contract-locked-old", in: base, policy: lockedPersonal, version: "0.1.0")
    _ = lockedOld.process(lockedOld.session("2026-10-07_1400_lk1"))
    check(lockedOld.blocked.count == 1, "a locked policy with pipeline 0.1.0: refused")
    let lockedNew = LOLauncher("lo-contract-locked-new", in: base, policy: lockedPersonal, version: "0.2.0")
    check(lockedNew.process(lockedNew.session("2026-10-07_1400_lk2")) && lockedNew.finished("2026-10-07_1400_lk2"), "a locked policy with pipeline 0.2.0: local processing continues (a lock closes lanes, not the app)")

    // the personal install: no policy
    let own = LOLauncher("lo-contract-owner", in: base, policy: OrgPolicy.absent(), version: "0.1.0")
    check(own.process(own.session("2026-10-07_1400_plain")) && own.finished("2026-10-07_1400_plain") && own.versionAsked == 0,
          "no policy, flag unset, pipeline 0.1.0: accepted, and python is not even asked for its version", "\(own.events.strings) asked \(own.versionAsked)")
    check(own.process(own.session("2026-10-07_1400_off", localOnly: false)) && own.finished("2026-10-07_1400_off") && own.versionAsked == 0, "... local_only=false: accepted")
    check(own.process(own.session("2026-10-07_1400_null", localOnly: NSNull())) && own.finished("2026-10-07_1400_null") && own.versionAsked == 0, "... local_only=null: accepted")
    _ = own.process(own.session("2026-10-07_1400_on", localOnly: true))
    check(own.blocked.contains { $0.session == "2026-10-07_1400_on" && $0.reason == .pipelineTooOld(have: "0.1.0", required: "0.2.0") }, "no policy but local_only=true with pipeline 0.1.0: refused (an old pipeline would send it to Claude and Drive)")
    _ = own.process(own.session("2026-10-07_1400_str", localOnly: "false"))
    check(own.blocked.contains { $0.session == "2026-10-07_1400_str" }, "local_only that is not a boolean (\"false\") counts as true: refused with an old pipeline")
    _ = own.process(own.session("2026-10-07_1400_num", localOnly: 0))
    check(own.blocked.contains { $0.session == "2026-10-07_1400_num" }, "local_only=0 (a number) counts as true too (Python reads it as fail-closed)")
    check(own.finished("2026-10-07_1400_plain") && own.finished("2026-10-07_1400_off") && own.blocked.count == 3, "a refused session does not stall the queue: the others were processed", own.events.strings.joined(separator: " | "))
    let ownNew = LOLauncher("lo-contract-owner-new", in: base, policy: OrgPolicy.absent(), version: "0.2.0")
    check(ownNew.process(ownNew.session("2026-10-07_1400_lo", localOnly: true)) && ownNew.finished("2026-10-07_1400_lo"), "no policy, local_only=true, pipeline 0.2.0: runs")

    // reprocess jobs pick their sessions themselves: an old pipeline must not get a local-only session in staging
    let sweepOld = LOLauncher("lo-contract-sweep-old", in: base, policy: OrgPolicy.absent(), version: "0.1.0")
    _ = sweepOld.session("2026-10-07_1400_lo", localOnly: true)
    sweepOld.launcher.reprocessPending()
    check(waitUntil(10) { !sweepOld.events.all.isEmpty } && sweepOld.blocked.first?.session == SessionController.sweepJobName && sweepOld.world.callsLog.isEmpty,
          "reprocess --pending with a local-only session in staging and pipeline 0.1.0: refused", sweepOld.events.strings.joined(separator: " | "))
    let sweepOk = LOLauncher("lo-contract-sweep-ok", in: base, policy: OrgPolicy.absent(), version: "0.1.0")
    _ = sweepOk.session("2026-10-07_1400_plain")
    sweepOk.launcher.reprocessPending()
    check(waitUntil(10) { sweepOk.events.strings.contains("nothing:\(SessionController.sweepJobName)") } && sweepOk.blocked.isEmpty && sweepOk.versionAsked == 0,
          "reprocess --pending with no local-only session and no policy: runs with an old pipeline, no version asked", sweepOk.events.strings.joined(separator: " | "))
    let sweepPolicy = LOLauncher("lo-contract-sweep-policy", in: base, policy: loPolicy(), version: "0.1.0")
    sweepPolicy.launcher.reprocessLast()
    check(waitUntil(10) { !sweepPolicy.events.all.isEmpty } && sweepPolicy.blocked.first?.session == "reprocess-last", "reprocess --last with a policy and pipeline 0.1.0: refused")

    // the launcher asks for the version in the background at app start only when something requires one
    let warm = LOLauncher("lo-contract-warm", in: base, policy: loPolicy(), version: "0.2.0")
    check(warm.launcher.pipelineVersion == nil, "before the warm-up the version is not known")
    warm.launcher.prepareContractCheck(localOnlyDefault: false)
    check(waitUntil(10) { warm.launcher.pipelineVersion == "0.2.0" }, "prepareContractCheck with a policy: the version is known in the background (the menu can say 'too old' before the first meeting)")
    let cold = LOLauncher("lo-contract-cold", in: base, policy: OrgPolicy.absent(), version: "0.2.0")
    cold.launcher.prepareContractCheck(localOnlyDefault: false)
    Thread.sleep(forTimeInterval: 0.3)
    check(cold.versionAsked == 0 && cold.launcher.pipelineVersion == nil, "the personal install (no policy, flag off by default): nothing is started at app start")
    let coldOn = LOLauncher("lo-contract-cold-on", in: base, policy: OrgPolicy.absent(), version: "0.2.0")
    coldOn.launcher.prepareContractCheck(localOnlyDefault: true)
    check(waitUntil(10) { coldOn.launcher.pipelineVersion == "0.2.0" }, "LOCAL_ONLY_DEFAULT=1 makes the warm-up run")

    // the controller asks when the toggle needs the version (the personal install: nothing was asked at start): once, in the background
    let probe = LOLauncher("lo-contract-probe", in: base, policy: OrgPolicy.absent(), version: "0.1.0")
    let answered = Locked<Int>(0)
    probe.launcher.onVersionKnown = { answered.value += 1 }
    probe.launcher.probePipelineVersion()
    check(waitUntil(10) { answered.value == 1 } && probe.launcher.pipelineVersion == "0.1.0" && probe.versionAsked == 1, "probePipelineVersion: one `python -m mcap --version` in the background, then onVersionKnown",
          "answered \(answered.value) version \(String(describing: probe.launcher.pipelineVersion)) asked \(probe.versionAsked)")
    probe.launcher.probePipelineVersion(); probe.launcher.probePipelineVersion()
    Thread.sleep(forTimeInterval: 0.3)
    check(probe.versionAsked == 1 && answered.value == 1, "... asked once, however often the menu asks (a known version is not asked for again)", "asked \(probe.versionAsked) answered \(answered.value)")
    check(probe.world.callsLog.isEmpty, "... and the pipeline itself was not started")
    let mute = LOLauncher("lo-contract-probe-mute", in: base, policy: OrgPolicy.absent(), version: nil)
    let muteAnswers = Locked<Int>(0)
    mute.launcher.onVersionKnown = { muteAnswers.value += 1 }
    mute.launcher.probePipelineVersion()
    check(waitUntil(10) { muteAnswers.value == 1 } && mute.launcher.pipelineVersion == nil, "a python that gives no version: the answer is 'not known' and the menu is told")
    mute.launcher.probePipelineVersion()
    Thread.sleep(forTimeInterval: 0.3)
    check(mute.versionAsked == 1 && muteAnswers.value == 1, "... and the question is not repeated in a loop (one more try at the next launch of a job)", "asked \(mute.versionAsked) answered \(muteAnswers.value)")
    let untrusted: (URL) -> OrgPolicy.FileInfo? = { _ in OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: 501, mode: 0o755, size: 0) }
    let bad = LOLauncher("lo-contract-probe-untrusted", in: base, policy: loPolicy(["runtime": ["root": base.appendingPathComponent("lo-contract-probe-untrusted", isDirectory: true).path]]), version: "0.2.0", fileInfo: untrusted)
    let badAnswers = Locked<Int>(0)
    bad.launcher.onVersionKnown = { badAnswers.value += 1 }
    bad.launcher.probePipelineVersion()
    check(waitUntil(10) { badAnswers.value == 1 } && bad.versionAsked == 0 && bad.launcher.pipelineVersion == nil, "an untrusted python is never started for the controller's question either")
}

private func testLOLauncherTrust(_ base: URL) {
    section("S-LO-11: runtime-untrusted refusal (company runtime.root, root-owned python and pipeline), checked before python is started")
    func root(_ name: String) -> String { base.appendingPathComponent(name, isDirectory: true).path }
    func policy(root path: String) -> OrgPolicy { loPolicy(["runtime": ["root": path]]) }
    let allRoot: (URL) -> OrgPolicy.FileInfo? = { _ in rootOwned }

    let a = LOLauncher("lo-trust-a", in: base, policy: policy(root: root("lo-trust-a")), version: "0.2.0", fileInfo: allRoot)
    check(policy(root: root("lo-trust-a")).isValid && policy(root: root("lo-trust-a")).pinnedRuntimeRoot != nil, "(the test policy is a valid company policy with a runtime root)")
    check(a.process(a.session("2026-10-07_1400_t1")) && a.finished("2026-10-07_1400_t1") && a.blocked.isEmpty, "python and pipeline inside the root, everything root-owned: runs", a.events.strings.joined(separator: " | "))

    // python's folder belongs to the user
    let userOwned: (URL) -> OrgPolicy.FileInfo? = { url in
        OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: url.path.contains("/bin") ? 501 : 0, mode: 0o755, size: 0)
    }
    let b = LOLauncher("lo-trust-b", in: base, policy: policy(root: root("lo-trust-b")), version: "0.2.0", fileInfo: userOwned)
    _ = b.process(b.session("2026-10-07_1400_t2"))
    if case .runtimeUntrusted(let why)? = b.blocked.first?.reason { check(why.hasPrefix("python:") && why.contains("not owned by root"), "python not owned by root: blocked(runtimeUntrusted)", why) }
    else { check(false, "python not owned by root: blocked(runtimeUntrusted)", "\(String(describing: b.blocked.first?.reason))") }
    check(b.versionAsked == 0 && b.world.callsLog.isEmpty && b.launcher.pipelineVersion == nil, "... an untrusted python is never started, not even for its version")
    check((try? FileManager.default.contentsOfDirectory(atPath: b.world.support.appendingPathComponent("sessions/2026-10-07_1400_t2").path))?.sorted() == ["session.json"], "... and the session folder is as it was")

    // writable by the group
    let groupWritable: (URL) -> OrgPolicy.FileInfo? = { _ in OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: 0, mode: 0o775, size: 0) }
    let g = LOLauncher("lo-trust-g", in: base, policy: policy(root: root("lo-trust-g")), version: "0.2.0", fileInfo: groupWritable)
    _ = g.process(g.session("2026-10-07_1400_t3"))
    if case .runtimeUntrusted(let why)? = g.blocked.first?.reason { check(why.contains("writable by group or others"), "a group-writable path: blocked", why) } else { check(false, "a group-writable path: blocked") }

    // the runtime is somewhere else
    let c = LOLauncher("lo-trust-c", in: base, policy: policy(root: root("lo-trust-elsewhere")), version: "0.2.0", fileInfo: allRoot)
    _ = c.process(c.session("2026-10-07_1400_t4"))
    if case .runtimeUntrusted(let why)? = c.blocked.first?.reason { check(why == "python: outside the runtime root", "python outside runtime.root: blocked", why) } else { check(false, "python outside runtime.root: blocked") }

    // a policy that cannot be read keeps the requirement: the release folder is the only runtime it accepts
    let lockedUnknown = OrgPolicy.parse(Data("not json".utf8))
    check(lockedUnknown.isLocked && lockedUnknown.pinnedRuntimeRoot == OrgPolicy.defaultRuntimeRoot, "(a locked policy of unknown profile pins the default release folder)")
    let l = LOLauncher("lo-trust-locked", in: base, policy: lockedUnknown, version: "0.2.0", fileInfo: allRoot)
    _ = l.process(l.session("2026-10-07_1400_t5"))
    check(l.blocked.first.map { if case .runtimeUntrusted = $0.reason { return true } else { return false } } == true && l.world.callsLog.isEmpty,
          "a locked policy of unknown profile with a python outside the release folder: blocked")

    // no requirement: the personal install, a personal profile and a company policy without a runtime root
    let owner = LOLauncher("lo-trust-owner", in: base, policy: OrgPolicy.absent(), version: "0.1.0", fileInfo: userOwned)
    check(owner.process(owner.session("2026-10-07_1400_t6")) && owner.finished("2026-10-07_1400_t6"), "no policy: python in a user-owned folder runs (the personal install)")
    let pers = LOLauncher("lo-trust-personal", in: base, policy: loPolicy(profile: "personal"), version: "0.2.0", fileInfo: userOwned)
    check(pers.process(pers.session("2026-10-07_1400_t7")) && pers.finished("2026-10-07_1400_t7"), "a personal policy has no runtime requirement")
    let noRoot = LOLauncher("lo-trust-noroot", in: base, policy: loPolicy(), version: "0.2.0", fileInfo: userOwned)
    check(noRoot.process(noRoot.session("2026-10-07_1400_t8")) && noRoot.finished("2026-10-07_1400_t8"), "a company policy without runtime.root has no runtime requirement")

    // the warm-up never asks an untrusted python
    let warm = LOLauncher("lo-trust-warm", in: base, policy: policy(root: root("lo-trust-warm")), version: "0.2.0", fileInfo: userOwned)
    warm.launcher.prepareContractCheck(localOnlyDefault: false)
    Thread.sleep(forTimeInterval: 0.4)
    check(warm.versionAsked == 0 && warm.launcher.pipelineVersion == nil, "prepareContractCheck does not ask an untrusted python for its version")
}

/// What PipelineLauncher.sanitizedEnvironment always gives the child: the six launcher variables and the app's own two names (the names are the Info.plist
/// values of the app, never the caller's).
private let launcherOwnKeys: Set<String> = ["HOME", "PATH", "USER", "LANG", "PYTHONUNBUFFERED", "HF_HUB_DISABLE_TELEMETRY", "MCAP_APP_NAME", "MCAP_APP_SHORT_NAME"]

/// The "ENV MCAP_..." lines a fake python recorded, without the two app names.
private func mcapVariables(besidesTheAppNamesIn calls: String) -> [String] {
    return calls.split(separator: "\n").filter { $0.hasPrefix("ENV MCAP_") && !$0.hasPrefix("ENV MCAP_APP_NAME=") && !$0.hasPrefix("ENV MCAP_APP_SHORT_NAME=") }.map(String.init)
}

private func testLOEnvironment(_ base: URL) {
    section("S-LO-12: sanitizedEnvironment under a policy: no MCAP_*, a shorter PATH; unchanged without one")
    let hostile = ["MCAP_CONFIG": "/tmp/c.env", "MCAP_SECURITY_BIN": "/tmp/fake/security", "MCAP_LOG_DIR": "/tmp/x", "MCAP_POLICY_PATH": "/tmp/p.json",
                   "ANTHROPIC_API_KEY": "x", "PATH": "/evil", "HOME": "/evil"]
    for (name, policy) in [("a valid company policy", loPolicy()), ("a valid personal policy", loPolicy(profile: "personal")),
                           ("a policy that cannot be read (locked)", OrgPolicy.parse(Data("not json".utf8)))] {
        let env = PipelineLauncher.sanitizedEnvironment(from: hostile, policy: policy)
        check(Set(env.keys) == launcherOwnKeys && env["MCAP_APP_NAME"] == AppInfo.displayName && env["MCAP_APP_SHORT_NAME"] == AppInfo.shortName,
              "\(name): exactly the eight launcher variables, no MCAP_* of the caller (only the app's own two names)", env.keys.sorted().joined(separator: " "))
        check(env["PATH"] == "/usr/bin:/bin" && env["HOME"] == NSHomeDirectory(), "\(name): PATH is /usr/bin:/bin (no ~/.local/bin, no /opt/homebrew/bin)", env["PATH"] ?? "nil")
    }
    let none = PipelineLauncher.sanitizedEnvironment(from: hostile, policy: OrgPolicy.absent())
    check(none == PipelineLauncher.sanitizedEnvironment(from: hostile) && none["MCAP_CONFIG"] == "/tmp/c.env" && none["MCAP_SECURITY_BIN"] == "/tmp/fake/security"
          && none["PATH"]?.contains("/.local/bin") == true && none["PATH"]?.contains("/opt/homebrew/bin") == true && none["MCAP_LOG_DIR"] == nil,
          "no policy (absent): exactly what it always was: MCAP_CONFIG and MCAP_SECURITY_BIN forwarded, the long PATH")

    // the child that really runs
    let managed = LOLauncher("lo-env-policy", in: base, policy: loPolicy(), version: "0.2.0")
    check(managed.process(managed.session("2026-10-07_1400_env1")) && managed.finished("2026-10-07_1400_env1"), "(a session ran under the policy)")
    let calls = managed.world.callsLog
    check(mcapVariables(besidesTheAppNamesIn: calls).isEmpty && calls.contains("ENV PATH=/usr/bin:/bin\n") && calls.contains("ENV MCAP_APP_NAME=\(AppInfo.displayName)\n"),
          "the child under a policy sees no MCAP_* variable but the app's own names, and PATH=/usr/bin:/bin", String(calls.prefix(300)))
    let open = LOLauncher("lo-env-open", in: base, policy: OrgPolicy.absent(), version: "0.2.0")
    check(open.process(open.session("2026-10-07_1400_env2")), "(a session ran without a policy)")
    check(open.world.callsLog.contains("ENV MCAP_SECURITY_BIN=") && open.world.callsLog.contains("/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"),
          "the same launcher without a policy still forwards MCAP_SECURITY_BIN and the long PATH (nothing changed for the personal install)")
}

private func testLOLogLines(_ base: URL) {
    section("S-LO-16: app.log lines without a meeting title or folder name under LOG_CONTENT=0 and for a local-only meeting; today's lines otherwise")
    func logSince(_ offset: Int) -> String { String(logText().dropFirst(offset)) }

    // default: today's line
    let d = LOLauncher("lo-log-default", in: base, policy: OrgPolicy.absent(), version: "0.2.0")
    let m1 = logText().count
    check(d.process(d.session("2026-10-07_1400_plain1")), "(a session finished, default settings)")
    check(logSince(m1).contains("pipeline: 2026-10-07_1400_plain1 finished title=Weekly Sync final_dir="), "default: the finish line keeps its title and folder (nothing changed)", String(logSince(m1).suffix(300)))

    // LOG_CONTENT=0
    let z = LOLauncher("lo-log-zero", in: base, policy: OrgPolicy.absent(), version: "0.2.0", privacy: loPrivacy(["LOG_CONTENT": "0"], in: base))
    let m2 = logText().count
    check(z.process(z.session("2026-10-07_1400_plain2")), "(a session finished, LOG_CONTENT=0)")
    let zLog = logSince(m2)
    check(zLog.contains("pipeline: 2026-10-07_1400_plain2 finished (title and folder omitted from the log: LOG_CONTENT=0)"), "LOG_CONTENT=0: the finish line says that the title and folder are omitted", String(zLog.suffix(300)))
    check(!zLog.contains("Weekly Sync") && !zLog.contains("Weekly-Sync") && !zLog.contains("final_dir="), "LOG_CONTENT=0: no title, no folder name, no final_dir in the new log lines", zLog)
    let zEvent = z.events.strings.first { $0.hasPrefix("finished:") } ?? ""
    check(zEvent.contains("Weekly Sync"), "(the event itself still carries the title: the menu and the controller decide what to show)", zEvent)

    // a local-only meeting, default LOG_CONTENT
    let l = LOLauncher("lo-log-local", in: base, policy: OrgPolicy.absent(), version: "0.2.0")
    let m3 = logText().count
    check(l.process(l.session("2026-10-07_1400_localonly1", localOnly: true)), "(a local-only session finished)")
    let lLog = logSince(m3)
    check(lLog.contains("finished (title and folder omitted from the log: local-only)"), "local-only: the finish line says that the title and folder are omitted", String(lLog.suffix(300)))
    check(!lLog.contains("Secret") && !lLog.contains("local-archive") && !lLog.contains("final_dir="), "local-only: no title, no slug, no path of the local archive in the new log lines", lLog)
    let o = l.launcher.outcome(forSession: "2026-10-07_1400_localonly1")
    check(o?.localOnly == true && o?.lanesSkipped == ["calendar", "drive", "llm"] && o?.folder?.lastPathComponent == "2026-10-07_1400_Secret-Slug-Roadmap",
          "the outcome (what the controller reads) has local_only, the skipped lanes and the folder", "\(String(describing: o))")

    // the retry sweep lists finished folders: the same rule
    for (name, privacy, local) in [("lo-log-sweep-plain", nil as PrivacySettings?, false), ("lo-log-sweep-zero", loPrivacy(["LOG_CONTENT": "0"], in: base), false), ("lo-log-sweep-local", nil, true)] {
        let s = LOLauncher(name, in: base, policy: OrgPolicy.absent(), version: "0.2.0", privacy: privacy)
        let folder = s.world.archive.appendingPathComponent("2026-10/2026-10-06_0900_Secret-Sweep-Slug", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "# Secret Sweep Title\n".write(to: folder.appendingPathComponent("meeting-note.md"), atomically: true, encoding: .utf8)
        if local { try? #"{"schema":1,"stage":"done","local_only":true}"#.write(to: folder.appendingPathComponent("state.json"), atomically: true, encoding: .utf8) }
        try? "  DONE: \(folder.path)\n".write(to: s.world.bin.appendingPathComponent("pending-done"), atomically: true, encoding: .utf8)
        let mark = logText().count
        s.launcher.reprocessPending()
        _ = waitUntil(10) { s.events.strings.contains { $0.hasPrefix("finished:") } }
        let text = logSince(mark)
        if privacy == nil && !local {
            check(text.contains("retry sweep finished 2026-10-06_0900_Secret-Sweep-Slug title=Secret Sweep Title"), "retry sweep, default: the finish line keeps the folder and the title", String(text.suffix(300)))
        } else {
            check(text.contains("retry sweep finished a session (title and folder omitted from the log)") && !text.contains("Secret"), "retry sweep, \(local ? "local-only" : "LOG_CONTENT=0"): no title and no folder name in the log", text)
        }
    }

    // a failure text names the folder the session was being moved to (the slug carries the title): same rule for the failed event and the log
    func failedMessage(_ l: LOLauncher, _ session: String) -> String? {
        for case .failed(let s, let message) in l.events.all where s == session { return message }
        return nil
    }
    for (label, privacy, session, local, secretName, shouldHide) in [
        ("default settings, a session that is not local-only", nil as PrivacySettings?, "2026-10-07_1400_failplain1", nil as Bool?, "Weekly-Sync", false),
        ("LOG_CONTENT=0", loPrivacy(["LOG_CONTENT": "0"], in: base), "2026-10-07_1400_failplain2", nil, "Weekly-Sync", true),
        ("a local-only session (session.json)", nil, "2026-10-07_1400_failhide1", true, "Secret-Slug", true),
    ] {
        let f = LOLauncher("lo-log-fail-\(session)", in: base, policy: OrgPolicy.absent(), version: "0.2.0", privacy: privacy)
        let mark = logText().count
        let ended = f.process(f.session(session, localOnly: local))
        let message = failedMessage(f, session) ?? "<no failed event>"
        let text = logSince(mark)
        check(ended, "(\(label): the session failed)", f.events.strings.joined(separator: " | "))
        if shouldHide {
            check(!message.contains(secretName) && !message.contains("/") && message.contains("No space left on device"), "\(label): the failed event's text has no folder name and no path, and keeps the cause", message)
            check(!text.contains(secretName) && !text.contains("local-archive"), "\(label): app.log has no folder name and no path of the failure", text)
        } else {
            check(message.contains(secretName) && text.contains(secretName), "\(label): today's text and log line, with the folder (nothing changed)", message)
        }
    }

    // the retry sweep says which sessions failed in one line without naming them: a local-only session in staging makes the text path-free
    for (label, privacy, localInStaging, shouldHide) in [("default settings, nothing local-only", nil as PrivacySettings?, false, false),
                                                         ("a local-only session is still in staging", nil, true, true),
                                                         ("LOG_CONTENT=0", loPrivacy(["LOG_CONTENT": "0"], in: base), false, true)] {
        let w = LOLauncher("lo-log-sweepfail-\(label.prefix(6))", in: base, policy: OrgPolicy.absent(), version: "0.2.0", privacy: privacy)
        if localInStaging { _ = w.session("2026-10-07_1400_waiting", localOnly: true) }
        try? "  FAILED: cannot move session to \(w.world.archive.path)/2026-10/2026-10-06_0900_Secret-Sweep-Slug: No space left on device\n"
            .write(to: w.world.bin.appendingPathComponent("pending-done"), atomically: true, encoding: .utf8)
        let mark = logText().count
        w.launcher.reprocessPending()
        _ = waitUntil(10) { w.events.strings.contains { $0.hasPrefix("failed:") } }
        let message = failedMessage(w, SessionController.sweepJobName) ?? "<no failed event>"
        let text = logSince(mark)
        let outcome = w.launcher.outcome(forSession: SessionController.sweepJobName)
        if shouldHide {
            check(!message.contains("Secret-Sweep-Slug") && !message.contains("/") && message.contains("No space left on device") && !text.contains("Secret-Sweep-Slug"),
                  "retry sweep failure, \(label): no folder name and no path in the event or in app.log", "\(message) | \(text)")
            check(localInStaging ? outcome?.localOnly == true : true, "... the sweep's outcome says that a local-only meeting was involved (the controller scrubs too)", "\(String(describing: outcome))")
        } else {
            check(message.contains("Secret-Sweep-Slug") && text.contains("Secret-Sweep-Slug") && outcome?.localOnly == nil, "retry sweep failure, \(label): today's text, with the folder (nothing changed)", message)
        }
    }
}

// MARK: S-LO-16b: the controller keeps slug-bearing names and paths out of app.log, the menu and the notification

private func testLOControllerContentFree(_ base: URL) {
    section("S-LO-16b: a session named by its published folder and a failure text with a path: not in app.log, the menu line or the notification for a local-only meeting or LOG_CONTENT=0")
    let slug = "2026-10-06_0900_Secret-Roadmap-Review"
    let folder = URL(fileURLWithPath: "/tmp/mcap-lo-ctl/local-meetings/2026-10/\(slug)", isDirectory: true)
    let failure = "cannot move session to \(folder.path): No space left on device"
    for (label, privacy, local, hides) in [("default settings, not local-only", nil as PrivacySettings?, false, false),
                                           ("a local-only meeting", nil, true, true),
                                           ("LOG_CONTENT=0", loPrivacy(["LOG_CONTENT": "0"], in: base), false, true)] {
        let h = loHarness("lo-ctl-\(label.prefix(6))", in: base, privacy: privacy)
        let outcome = PipelineOutcome(folder: folder, localOnly: local ? true : nil)
        h.pipeline.outcomes[slug] = outcome
        h.pipeline.outcomes[SessionController.sweepJobName] = PipelineOutcome(localOnly: local ? true : nil)
        let mark = logText().count
        // what the retry sweep reports: a finished session named by its published folder, then a failure of the sweep itself
        h.pipeline.onEvent?(.finished(session: slug, title: "Secret Roadmap Review", finalDir: folder, discarded: false)); h.sync()
        h.pipeline.onEvent?(.failed(session: SessionController.sweepJobName, message: failure)); h.sync()
        let text = String(logText().dropFirst(mark))
        let posted = h.notifier.posted
        let finished = posted.first { $0.kind == .noteReady || $0.kind == .transcriptReady }
        let failed = posted.first { $0.kind == .pipelineFailed }
        check(finished != nil && failed != nil, "(\(label): both notifications were posted)", "\(posted.map { $0.kind.rawValue })")
        var menuText = ""
        if case .error(let t) = h.state.status { menuText = t }
        let everything = text + "\n" + posted.map { [$0.title, $0.subtitle, $0.body, $0.identifier, $0.summary].joined(separator: " | ") }.joined(separator: "\n") + "\n" + menuText
        if hides {
            check(!everything.contains("Secret") && !everything.contains("mcap-lo-ctl") && !everything.contains("local-meetings"),
                  "\(label): nothing of the slug, the title or the folder path is in app.log, the notifications (text, identifier, log summary) or the menu line", everything)
            check(finished?.identifier == "mcap.\(finished?.kind == .noteReady ? "note-ready" : "transcript-ready").2026-10-06_0900" && finished?.summary.contains("(2026-10-06_0900)") == true,
                  "\(label): the notification is named by date and time only", "\(finished?.identifier ?? "nil") | \(finished?.summary ?? "nil")")
            check(failed?.summary.contains("No space left on device") == true && menuText.contains("No space left on device"), "\(label): the cause is kept", "\(failed?.summary ?? "nil") | \(menuText)")
        } else {
            check(text.contains(slug) && failed?.summary.contains(folder.path) == true && menuText.contains(folder.path) && finished?.identifier.contains(slug) == true,
                  "\(label): today's behaviour: the slug and the path are shown as before (nothing changed for the personal install)", String(text.suffix(300)))
        }
    }
}

// MARK: S-LO-16c: the helpers that make a name and a text content-free

private func testLOContentFreeHelpers() {
    section("S-LO-16c: contentFreeSession and withoutPaths")
    let names: [(String, String)] = [
        ("2026-10-07_1400_meet", "2026-10-07_1400_meet"), ("2026-10-07_1400_zoom", "2026-10-07_1400_zoom"), ("2026-10-07_1400_manual", "2026-10-07_1400_manual"),
        ("2026-10-06_0900_Secret-Roadmap-Review", "2026-10-06_0900"), ("2026-10-06_0900_a_b_c", "2026-10-06_0900"), ("2026-10-06_0900", "2026-10-06_0900"),
        ("2026-10-07_1400_meet-2", "2026-10-07_1400"), (SessionController.sweepJobName, SessionController.sweepJobName), ("reprocess-last", "reprocess-last"),
        ("Secret Roadmap Review", "a session"), ("", "a session"), ("2026-1-6_0900_x", "a session"), ("2026-10-06_09_x", "a session"), ("20261006_0900_x", "a session"),
        ("../../2026-10-06_0900_x", "a session"),
    ]
    for (name, expected) in names {
        check(NotificationText.contentFreeSession(name) == expected, "contentFreeSession(\"\(name)\") == \"\(expected)\"", NotificationText.contentFreeSession(name))
        check(NotificationText.contentFreeSession(NotificationText.contentFreeSession(name)) == NotificationText.contentFreeSession(name), "... and it is idempotent: \"\(name)\"")
    }
    let texts: [(String, String)] = [
        ("cannot move session to /Users/alice/Library/Application Support/MeetingCapture/local-meetings/2026-10/2026-10-07_1400_Secret-Roadmap-Review: No space left on device",
         "cannot move session to <path>: No space left on device"),
        ("Python not found at /Users/alice/Library/Application Support/MeetingCapture/venv/bin/python. Run scripts/setup_python.sh.", "Python not found at <path>"),
        ("cannot read ~/Library/Logs/x.log: permission denied", "cannot read <path>: permission denied"),
        ("failed: publish of 2026-10-07_1400_Secret-Roadmap-Review (disk full)", "failed: publish of 2026-10-07_1400_<folder> (disk full)"),
        ("session 2026-10-07_1400_meet failed", "session 2026-10-07_1400_meet failed"),
        ("read stdout/stderr and and/or 1/2 of it", "read stdout/stderr and and/or 1/2 of it"),
        ("exit status 1", "exit status 1"), ("", ""),
        ("two paths /a/b/Secret-One: and /c/d/Secret-Two: end", "two paths <path>: and <path>: end"),
        ("folder \"/Users/alice/Secret Folder/y\" is full", "folder \"<path>\" is full"),
    ]
    for (text, expected) in texts {
        let got = NotificationText.withoutPaths(text)
        check(got == expected && !got.contains("Secret"), "withoutPaths(\"\(text.prefix(60))...\")", got)
    }
}

// MARK: S-LO-13: notification texts

private func testLONotificationTexts() {
    section("S-LO-13: the new notification texts: Korean, at most 100 characters, no meeting title for a local-only meeting, the contact never cuts the cause")
    let secret = "비밀 로드맵 검토"
    let folder = URL(fileURLWithPath: "/tmp/mcap-lo-folder", isDirectory: true)
    let log = URL(fileURLWithPath: "/tmp/mcap-lo-app.log")
    let long60 = String(repeating: "문", count: 60)
    let codes = ["bom", "not-utf8", "bad-json", "duplicate-key", "not-object", "bad-schema", "no-profile", "bad-profile", "bad-revision", "unknown-key", "forbidden-key",
                 "bad-type", "bad-value", "not-regular-file", "bad-owner", "group-or-other-writable", "parent-bad-owner", "parent-writable", "parent-unreadable",
                 "too-large", "unreadable", "required-missing", "pipeline-too-old", "internal-error", "a-code-nobody-knows"]
    check(codes.allSatisfy { OrgPolicy.reasonText(forCode: $0).count <= 20 && hasHangul(OrgPolicy.reasonText(forCode: $0)) }, "every lock reason has a Korean phrase of at most 20 characters (the contact must fit behind it)")

    func buildAll() -> [(String, AppNotification)] {
    let manual = NotificationText.platformName(.manual)
    let longContact = String(repeating: L10n.current == .ko ? "문" : "x", count: 60)
    let sampleContact = L10n.current == .ko ? loContact : "IT helpdesk, it-help@example.com"
    var all: [(String, AppNotification)] = []
    for platform in [nil, "Zoom", manual, "Google Meet"] as [String?] { all.append(("localOnlyOn \(platform ?? "nil")", .localOnlyOn(platformLabel: platform, session: "s1"))) }
    all.append(("localOnlyOff", .localOnlyOff(summary: tr("This meeting: transcription=company server · note=on · archive=team drive", ko: "이 회의: 전사=회사 서버 · 회의록=켜짐 · 보관=팀 드라이브"), session: "s1")))
    for contact in [nil, sampleContact, longContact] as [String?] {
        all.append(("locked \(contact ?? "nil")", .localOnlyLocked(contact: contact, session: "s1")))
        all.append(("recordingFailed policy \(contact ?? "nil")", .recordingFailed(reason: "off", kind: .policy, contact: contact)))
        all.append(("asr_policy_blocked \(contact ?? "nil")", .pipelineFailed(session: "s1", reason: "x", kind: "asr_policy_blocked", retryable: false, folder: folder, logFile: log, contact: contact)))
        for block in [PipelineBlock.pipelineTooOld(have: "0.1.0", required: "0.2.0"), .runtimeUntrusted("python: not owned by root")] {
            all.append(("blocked \(block.key) \(contact ?? "nil")", .pipelineBlocked(block, session: "s1", contact: contact, logFile: log)))
        }
        for code in codes { all.append(("policyProblem \(code) \(contact ?? "nil")", .policyProblem(reasonText: OrgPolicy.reasonText(forCode: code), contact: contact, logFile: log))) }
    }
    for problem in [AppNotification.LocalOnlyProblem.tooLate, .maybeLate, .pipelineTooOld, .writeFailed] { all.append(("problem \(problem)", .localOnlyProblem(problem, session: "s1", logFile: log))) }
    for local in [true, false] {
        all.append(("transcriptReady \(local)", .transcriptReady(localOnly: local, session: "s1", platformLabel: "Google Meet", durationSeconds: 7500, folder: folder)))
        all.append(("transcriptReady bare \(local)", .transcriptReady(localOnly: local, session: "s2")))
    }
    all.append(("waitingForServer", .waitingForServer(session: "s1", folder: folder)))
    all.append(("pipelineFailed local_archive_unsafe", .pipelineFailed(session: "s1", reason: "x", kind: "local_archive_unsafe", retryable: false, folder: folder, logFile: log)))
    all.append(("recordingStopped policy kill switch", .recordingStopped(platformLabel: manual, manual: true, durationSeconds: 3720, titleHint: nil, session: "s1", folder: folder, note: .policyKillSwitch)))
    for tail in [nil, NotificationText.localOnlyTail(on: true, policyExists: true), NotificationText.localOnlyTail(on: false, policyExists: true)] {
        for (platform, manual) in [("Google Meet", false), ("Microsoft Teams", false), (manual, true)] {
            all.append(("recordingStarted \(platform) \(tail ?? "nil")", .recordingStarted(platformLabel: platform, manual: manual, titleHint: secret, session: "s1", folder: folder, localOnlyTail: tail, hideTitle: true)))
        }
    }
    return all
    }
    let all = buildAll()
    let offenders = all.filter { _, n in
        n.title.isEmpty || n.subtitle.isEmpty || n.body.isEmpty || n.title.count > NotificationText.titleLimit || n.subtitle.count > NotificationText.subtitleLimit
            || n.body.count > NotificationText.bodyLimit || !hasHangul(n.title + n.body)
    }.map { $0.0 }
    check(offenders.isEmpty, "all \(all.count) new / extended notification texts fit (title 40, subtitle 60, body 100), are Korean and are never empty", offenders.joined(separator: " | "))
    L10n.current = .en                                       // the same texts with UI_LANGUAGE=en: they fit too, are never empty and hold no Hangul
    let allEn = buildAll()
    let offendersEn = allEn.filter { _, n in
        n.title.isEmpty || n.subtitle.isEmpty || n.body.isEmpty || n.title.count > NotificationText.titleLimit || n.subtitle.count > NotificationText.subtitleLimit
            || n.body.count > NotificationText.bodyLimit || hasHangul(n.title + n.subtitle + n.body)
    }.map { $0.0 }
    check(allEn.count == all.count && offendersEn.isEmpty, "the same \(allEn.count) notification texts in English fit (title 40, subtitle 60, body 100), are never empty and hold no Hangul", offendersEn.joined(separator: " | "))
    check(codes.allSatisfy { OrgPolicy.reasonText(forCode: $0).count <= 20 && !hasHangul(OrgPolicy.reasonText(forCode: $0)) }, "every lock reason has an English phrase of at most 20 characters")
    for kind in ["usage_limit", "credit_exhausted", "budget_daily", "auth", "overloaded", "overage_guard", "config", "archive_unavailable", "asr_failed", "asr_policy_blocked", "local_archive_unsafe", "audio_failed", "publish_failed", "stalled", "nothing-known"] {
        check(!hasHangul(AppNotification.failureReason(kind: kind, message: "m", resetsAt: Date())), "failure reason '\(kind)' in English has no Hangul")
    }
    check(NotificationText.duration(45) == "45 s" && NotificationText.duration(32 * 60) == "32 min" && NotificationText.duration(3600) == "1 h" && NotificationText.duration(3900) == "1 h 05 min", "durations in English")
    L10n.current = .ko
    check(all.allSatisfy { _, n in !n.title.contains(secret) && !n.subtitle.contains(secret) && !n.body.contains(secret) && !n.summary.contains(secret) },
          "no text carries the meeting title when the caller says to hide it (and the new kinds never take one)")
    let visible = AppNotification.recordingStarted(platformLabel: "Zoom", manual: false, titleHint: secret, session: "s1", folder: nil)
    check(visible.subtitle == secret, "(control: without hideTitle the title is shown, as it always was)")

    // the design texts
    let on = AppNotification.localOnlyOn(platformLabel: "Zoom", session: "s1")
    check(on.kind == .localOnlyChanged && on.title == "로컬 전용 회의" && on.subtitle == "Zoom · 이 회의만 적용"
          && on.body == "전사는 이 Mac에서만 처리해요. 회의록(Claude), 캘린더 조회, Drive 업로드는 하지 않아요. 전사본과 녹음은 이 Mac의 로컬 폴더에 저장돼요" && !on.sound && on.action == .none, "ON: the design text", "\(on.body.count)")
    let off = AppNotification.localOnlyOff(summary: "이 회의: 전사=이 Mac · 회의록=켜짐 · 보관=팀 드라이브", session: "s1")
    check(off.title == "로컬 전용 해제" && off.subtitle == "이 회의: 전사=이 Mac · 회의록=켜짐 · 보관=팀 드라이브" && off.body == "민감한 내용이 있었다면 처리 전에 다시 켜세요", "OFF: the design text")
    let locked = AppNotification.localOnlyLocked(contact: loContact, session: "s1")
    check(locked.title == "로컬 전용은 조직 정책으로 고정돼 있어요" && locked.body == "해제할 수 없어요 · 문의: \(loContact)", "locked: the design text with the contact")
    check(AppNotification.localOnlyLocked(contact: nil, session: "s1").body == "해제할 수 없어요", "locked without a contact: no dangling '문의:'")
    let cause = "안전을 위해 외부 전송을 막고 로컬 전사만 해요 · 정책 파일 권한 오류"
    let pp = AppNotification.policyProblem(reasonText: "정책 파일 권한 오류", contact: loContact)
    check(pp.kind == .policyProblem && pp.title == "조직 정책을 읽을 수 없어요" && pp.body == "\(cause) · 문의: \(loContact)" && pp.sound, "policy problem: the design text (cause, short reason, contact)", pp.body)
    let ppLong = AppNotification.policyProblem(reasonText: "정책 파일 권한 오류", contact: long60)
    check(ppLong.body.hasPrefix(cause + " · 문의: ") && ppLong.body.count <= 100 && ppLong.body.hasSuffix("…") && !ppLong.body.contains(long60), "a long contact is the part that is shortened: the cause and the reason stay intact", ppLong.body)
    let blockedText = "이 Mac에서는 로컬 전사를 할 수 없고 외부 전송도 금지돼 전사하지 못했어요 (녹음은 보관됨)"
    let ab = AppNotification.pipelineFailed(session: "s1", reason: "x", kind: "asr_policy_blocked", retryable: false, folder: folder, logFile: log, contact: loContact)
    check(ab.body == "\(blockedText) · 문의: \(loContact)" && ab.title == "회의록 생성 실패", "asr_policy_blocked: the design text with the contact", ab.body)
    check(AppNotification.pipelineFailed(session: "s1", reason: "x", kind: "asr_policy_blocked", contact: long60).body.hasPrefix(blockedText), "asr_policy_blocked with a long contact: the cause is intact")
    check(!AppNotification.pipelineFailed(session: "s1", reason: "x", kind: "asr_policy_blocked", contact: loContact).body.contains("mcap reprocess"), "asr_policy_blocked: no 'mcap reprocess' hint (the policy decides, not a retry)")
    let wait = AppNotification.waitingForServer(session: "s1")
    check(wait.kind == .waitingForServer && wait.title == "서버에 연결할 수 없어요" && wait.body == "연결되면 자동으로 처리해요" && !wait.sound && wait.level == .active, "waiting for the server: quiet, the design text")
    let trDone = AppNotification.transcriptReady(localOnly: true, session: "s1", platformLabel: "Zoom", durationSeconds: 1932, folder: folder)
    check(trDone.kind == .transcriptReady && trDone.title == "전사본이 준비됐어요 (로컬 전용)" && trDone.body.hasPrefix("회의록·캘린더·Drive 업로드는 건너뛰었어요") && trDone.subtitle == "Zoom · 32분 녹음" && trDone.action == .openFolder(folder.path) && !trDone.sound,
          "local-only completion: the design text, platform and length instead of a title, click opens the folder", "\(trDone.title) | \(trDone.subtitle) | \(trDone.body)")
    check(AppNotification.transcriptReady(localOnly: false, session: "s1").body == "회의록은 조직 정책에 따라 건너뛰었어요", "completion without a note because of the policy: says so")
    check(AppNotification.recordingStopped(platformLabel: "수동", manual: true, durationSeconds: 3720, titleHint: nil, session: "s1", folder: nil, note: .policyKillSwitch).body.contains("조직 정책에 따라 녹음을 멈췄어요")
          && AppNotification.recordingStopped(platformLabel: "수동", manual: true, durationSeconds: 3720, titleHint: nil, session: "s1", folder: nil, note: .policyKillSwitch).sound, "kill switch stop: the text, with sound")
    let tail0 = NotificationText.localOnlyTail(on: false, policyExists: false)
    let tail1 = NotificationText.localOnlyTail(on: true, policyExists: false)
    let tail2 = NotificationText.localOnlyTail(on: false, policyExists: true)
    check(tail0 == nil && tail1 == " · 로컬 전용: 켜짐" && tail2 == " · 로컬 전용: 꺼짐 (민감한 회의면 메뉴에서 켜세요)" && NotificationText.localOnlyTail(on: true, policyExists: true) == tail1,
          "the start-notification tail: nothing without a policy and with the flag off; 켜짐 when on; 꺼짐 (...) when a policy exists")
    let plain = AppNotification.recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "s1", folder: folder)
    check(AppNotification.recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "s1", folder: folder, localOnlyTail: tail0).body == plain.body
          && AppNotification.recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "s1", folder: folder, localOnlyTail: tail1).body == plain.body + " · 로컬 전용: 켜짐",
          "the personal default keeps today's start text exactly; the tail is appended to it")
    // the noteReady / recordingStopped variants without a title
    check(!AppNotification.noteReady(title: secret, session: "s1", platformLabel: "Zoom", durationSeconds: 600, folder: folder, hideTitle: true).subtitle.contains(secret)
          && AppNotification.noteReady(title: secret, session: "s1", platformLabel: "Zoom", durationSeconds: 600, folder: folder, hideTitle: true).subtitle == "Zoom · 10분 녹음"
          && AppNotification.noteReady(title: secret, session: "s1", folder: nil, hideTitle: false).subtitle == secret, "noteReady with hideTitle: platform and length instead of the title; without it the title as before")
    check(!AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 600, titleHint: secret, session: "s1", folder: nil, hideTitle: true).subtitle.contains(secret)
          && AppNotification.recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 600, titleHint: secret, session: "s1", folder: nil).subtitle.contains(secret), "recordingStopped with hideTitle: no title; without it as before")
}

// MARK: S-LO-14: click routing

private func testLOClickRouting(_ base: URL) {
    section("S-LO-14: a click opens the local archive (LOCAL_ARCHIVE_DIR) and still rejects every other path; paths of local meetings stay out of the log")
    let fm = FileManager.default
    let root = base.appendingPathComponent("lo-click", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let archive = root.appendingPathComponent("archive", isDirectory: true)
    let local = support.appendingPathComponent("local-meetings", isDirectory: true)
    let localMeeting = local.appendingPathComponent("2026-10/2026-10-07_1400_Secret-Slug-Roadmap", isDirectory: true)
    let driveMeeting = archive.appendingPathComponent("2026-10/2026-10-07_1400_Drive-Slug-Weekly", isDirectory: true)
    let staging = support.appendingPathComponent("sessions/2026-10-07_1400_zoom", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    for d in [localMeeting, driveMeeting, staging, logs, outside] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
    try? fm.createSymbolicLink(at: local.appendingPathComponent("link-out"), withDestinationURL: outside)
    var config = AppConfig.defaults()
    config.supportDir = support
    config.archiveDir = archive
    func canon(_ url: URL) -> String { NotificationPathPolicy.canonical(url.path) }
    func click(_ policy: NotificationPathPolicy, _ path: String) -> (opened: [URL], completions: Int) {
        let opener = FakeOpener()
        let router = NotificationClickRouter(policy: policy, opener: opener, dispatch: { $0() })
        var completions = 0
        router.handle(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["action": "openFolder", "path": path], completion: { completions += 1 })
        return (opener.opened, completions)
    }
    let withLocal = NotificationPathPolicy(config: config, logDir: logs, extraFolderRoots: [local])
    let without = NotificationPathPolicy(config: config, logDir: logs)
    check(withLocal.folderRoots.map { $0.path } == [config.sessionsDir.path, logs.path, local.path, archive.path],
          "the local archive is a folder root, looked at before ARCHIVE_DIR (the cloud drive stays last)", "\(withLocal.folderRoots.map { $0.path })")
    check(without.folderRoots.map { $0.path } == [config.sessionsDir.path, logs.path, archive.path], "without extra roots the list is what it always was")

    let mark = logText().count
    let c1 = click(withLocal, localMeeting.path)
    check(c1.opened.map { $0.path } == [canon(localMeeting)] && c1.completions == 1, "a click on a local-only meeting folder opens it", "\(c1)")
    check(click(withLocal, local.path).opened.map { $0.path } == [canon(local)], "... the local archive itself is allowed too")
    let afterClick = String(logText().dropFirst(mark))
    check(afterClick.contains("notification clicked: openFolder <folder omitted from the log>") && !afterClick.contains("Secret-Slug") && !afterClick.contains(local.path),
          "the click is logged without the folder name (its slug carries the meeting title)", String(afterClick.suffix(300)))
    check(click(without, localMeeting.path).opened.isEmpty, "(control: without the extra root the same click is refused)")

    let rejected: [(String, String)] = [
        ("outside every root", outside.path), ("the support folder itself", support.path), ("the home folder", NSHomeDirectory()),
        ("'..' out of the local archive", local.path + "/2026-10/../../outside"), ("a symlink in the local archive that points outside", local.appendingPathComponent("link-out").path),
        ("/etc", "/etc"), ("a relative path", "local-meetings/2026-10"),
    ]
    for (name, path) in rejected {
        let before = logCount("notification clicked: openFolder rejected")
        let c = click(withLocal, path)
        check(c.opened.isEmpty && c.completions == 1 && logCount("notification clicked: openFolder rejected") == before + 1, "still rejected with the extra root: \(name)", "\(c)")
    }

    // the notification as posted: a click target inside the local archive is kept, one outside is dropped
    let ready = AppNotification.transcriptReady(localOnly: true, session: "s1", platformLabel: "Zoom", durationSeconds: 600, folder: localMeeting)
    check(NotificationClickRouter(policy: withLocal).sanitized(ready).action == .openFolder(canon(localMeeting)), "a local-only 'transcript ready' keeps its click target (the local meeting folder)")
    let mark2 = logText().count
    check(NotificationClickRouter(policy: without).sanitized(ready).action == .none, "(control: without the local root the target is dropped)")
    let refusal = String(logText().dropFirst(mark2))
    check(refusal.contains("refused"), "(control: and the refusal is logged with its path, as before)", refusal)
    let mark3 = logText().count
    let outsideReady = AppNotification.transcriptReady(localOnly: true, session: "s1", folder: outside)
    check(NotificationClickRouter(policy: withLocal).sanitized(outsideReady).action == .none, "a target outside every root is dropped")
    check(!String(logText().dropFirst(mark3)).contains("Secret-Slug"), "(and the log of that refusal has no local-archive name)")

    // LOG_CONTENT=0: archive paths stay out of the log, the staging folder and the log folder still show
    let hidden = NotificationPathPolicy(config: config, logDir: logs, extraFolderRoots: [local], hideArchivePaths: true)
    let mark4 = logText().count
    check(click(hidden, driveMeeting.path).opened.map { $0.path } == [canon(driveMeeting)], "(LOG_CONTENT=0) a click on an archive meeting still opens it")
    check(click(hidden, staging.path).opened.map { $0.path } == [canon(staging)], "(LOG_CONTENT=0) a click on a staging folder opens it")
    let hiddenLog = String(logText().dropFirst(mark4))
    check(!hiddenLog.contains("Drive-Slug") && hiddenLog.contains("<folder omitted from the log>") && hiddenLog.contains(staging.lastPathComponent),
          "(LOG_CONTENT=0) the archive meeting folder is not in the log, the staging session id is", String(hiddenLog.suffix(400)))
}

// MARK: S-LO-15: retry kinds and the two new failure texts

private func testLORetryAndFailures(_ base: URL) {
    section("S-LO-15: retryable kinds (asr_unreachable yes; asr_policy_blocked and local_archive_unsafe never), the waiting text, the policy-blocked failure")
    let fm = FileManager.default
    check(SessionController.retryableFailureKinds == ["archive_unavailable", "asr_failed", "asr_unreachable"], "retryableFailureKinds: asr_unreachable added, asr_policy_blocked and local_archive_unsafe are not in it", "\(SessionController.retryableFailureKinds)")
    func decide(_ json: String) -> SessionController.ScanDecision {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return SessionController.scanDecision(state: obj)
    }
    check(decide(#"{"stage":"failed","retryable":true,"error_kind":"asr_unreachable"}"#) == .retryFailed(kind: "asr_unreachable"), "scan: a retryable asr_unreachable failure is retried once per launch")
    check(decide(#"{"stage":"failed","retryable":true,"error_kind":"asr_policy_blocked"}"#) == .skip && decide(#"{"stage":"failed","retryable":false,"error_kind":"asr_policy_blocked"}"#) == .skip,
          "scan: asr_policy_blocked is never retried (even if a state.json said retryable)")
    check(decide(#"{"stage":"failed","retryable":true,"error_kind":"local_archive_unsafe"}"#) == .skip, "scan: local_archive_unsafe is never retried")
    check(decide(#"{"stage":"failed","retryable":false,"error_kind":"asr_unreachable"}"#) == .skip, "scan: asr_unreachable that is not retryable is skipped")

    let h = loHarness("lo-retry", in: base)
    func staged(_ name: String, state: String) {
        let dir = h.sessionsDir.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? #"{"schema":1,"session_id":"x","start_time":"2026-10-07T10:00:00+09:00","end_time":"2026-10-07T10:30:00+09:00","tracks":{}}"#.write(to: dir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)
        try? state.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }
    staged("2026-10-07_1000_zoom", state: #"{"stage":"failed","retryable":true,"error_kind":"asr_unreachable"}"#)
    staged("2026-10-07_1010_zoom", state: #"{"stage":"failed","retryable":true,"error_kind":"asr_policy_blocked"}"#)
    staged("2026-10-07_1020_zoom", state: #"{"stage":"failed","retryable":true,"error_kind":"local_archive_unsafe"}"#)
    staged("2026-10-07_1030_zoom", state: #"{"stage":"failed","retryable":true,"error_kind":"archive_unavailable"}"#)
    let first = h.controller.recoverSessions().map { $0.lastPathComponent }
    check(first == ["2026-10-07_1000_zoom", "2026-10-07_1030_zoom"], "startup scan: the unreachable-server and the archive failure are enqueued; the policy-blocked and unsafe-archive sessions are left alone", "\(first)")
    check(h.controller.recoverSessions().isEmpty, "... and each only once per app launch")

    // the transcription server could not be reached: a quiet notice, not a failure
    let w = loHarness("lo-waiting", in: base, policy: loPolicy())
    let folder = w.sessionsDir.appendingPathComponent("2026-10-07_1000_zoom", isDirectory: true)
    w.pipeline.outcomes["2026-10-07_1000_zoom"] = PipelineOutcome(folder: folder, errorKind: "asr_unreachable", retryable: true)
    w.pipeline.onEvent?(.failed(session: "2026-10-07_1000_zoom", message: "no chunk reached the server")); w.sync()
    let waiting = w.notifier.posted
    check(waiting.count == 1 && waiting[0].kind == .waitingForServer && waiting[0].title == "서버에 연결할 수 없어요" && waiting[0].body == "연결되면 자동으로 처리해요" && !waiting[0].sound,
          "asr_unreachable: ONE quiet notification (no sound), not a failure", "\(waiting.map { "\($0.kind.rawValue) \($0.title)" })")
    check(!w.notifier.posted.contains { $0.kind == .pipelineFailed }, "... and no 'processing failed' notification")
    if case .error = w.state.status { check(false, "asr_unreachable is not an error status", "\(w.state.status)") } else { check(true, "asr_unreachable does not turn the menu status into an error") }
    check(w.state.notice == SessionController.waitingForServerNotice, "the menu keeps a standing notice that it waits for the server", "\(w.state.notice ?? "nil")")
    w.pipeline.onEvent?(.failed(session: "2026-10-07_1000_zoom", message: "again")); w.sync()
    check(w.notifier.count(.waitingForServer) == 1, "the same session again: not repeated within 12 hours")
    w.pipeline.onEvent?(.finished(session: "2026-10-07_1000_zoom", title: nil, finalDir: nil, discarded: false)); w.sync()
    check(w.state.notice == nil, "when it finishes the waiting notice is gone", "\(w.state.notice ?? "nil")")

    // the policy forbids both the local and an external transcription
    let b = loHarness("lo-blocked", in: base, policy: loPolicy())
    b.pipeline.outcomes["2026-10-07_1100_zoom"] = PipelineOutcome(folder: b.sessionsDir, errorKind: "asr_policy_blocked", retryable: false)
    b.pipeline.onEvent?(.failed(session: "2026-10-07_1100_zoom", message: "policy blocked")); b.sync()
    let blocked = b.notifier.posted.last
    check(blocked?.kind == .pipelineFailed && blocked?.body == "이 Mac에서는 로컬 전사를 할 수 없고 외부 전송도 금지돼 전사하지 못했어요 (녹음은 보관됨) · 문의: \(loContact)" && blocked?.sound == true,
          "asr_policy_blocked: the failure says why, that the recording is kept, and who to ask", "\(blocked?.body ?? "nil")")
    if case .error(let text) = b.state.status { check(text.contains("2026-10-07_1100_zoom"), "... the menu shows it as an error", text) } else { check(false, "the menu shows an error", "\(b.state.status)") }
}

// MARK: S-LO-17: the menu

private func testLOMenu(_ base: URL) {
    section("S-LO-17: the menu: the local-only item in every state, the manual item, the idle lines from EffectiveLanes")
    func state(_ view: LocalOnlyView?) -> ControllerState { var s = ControllerState(); s.localOnly = view; return s }
    func view(_ value: Bool, locked: Bool = false, target: String? = "s1", relax: Bool = true, old: Bool = false) -> LocalOnlyView {
        LocalOnlyView(value: value, locked: locked, targetSession: target, canRelax: relax, pipelineTooOld: old)
    }
    typealias M = StatusMenuController
    let none = M.localOnlyItemState(for: state(nil))
    check(none.title == "Local-Only Meeting" && !none.checked && !none.enabled && none.tooltip?.contains("녹음 중이거나") == true, "no view yet: disabled")
    let idle = M.localOnlyItemState(for: state(view(false, target: nil, relax: false)))
    check(!idle.enabled && !idle.checked && idle.title == "Local-Only Meeting", "nothing to change (no target): disabled, unchecked")
    let idleOn = M.localOnlyItemState(for: state(view(true, target: nil, relax: false)))
    check(!idleOn.enabled && idleOn.checked, "no target but the next meeting starts on (config default): checked, disabled")
    let canOn = M.localOnlyItemState(for: state(view(false)))
    check(canOn.enabled && !canOn.checked && canOn.tooltip?.contains("이 회의만 적용") == true && canOn.title == "Local-Only Meeting", "recording, off: enabled, unchecked, the tooltip says it applies to this meeting only")
    let canOff = M.localOnlyItemState(for: state(view(true)))
    check(canOff.enabled && canOff.checked && canOff.tooltip?.contains("끄면") == true, "on and can be relaxed: enabled, checked")
    let cannotOff = M.localOnlyItemState(for: state(view(true, relax: false)))
    check(!cannotOff.enabled && cannotOff.checked && cannotOff.tooltip == "처리가 이미 시작돼 더 이상 끌 수 없어요", "on and the pipeline started: checked, disabled, the reason")
    let locked = M.localOnlyItemState(for: state(view(true, locked: true, relax: false)))
    check(!locked.enabled && locked.checked && locked.title == "Local-Only Meeting (조직 정책으로 고정)" && locked.tooltip == "조직 정책으로 고정", "locked: checked, disabled, '조직 정책으로 고정'")
    let old = M.localOnlyItemState(for: state(view(false, old: true)))
    check(!old.enabled && old.title == "Local-Only Meeting (파이프라인이 오래됨)" && old.tooltip == "파이프라인이 오래돼 로컬 전용을 지원하지 않아요", "pipeline too old: disabled, the design text")
    check(M.localOnlyItemState(for: state(view(true, locked: true, old: true))).title.contains("조직 정책으로 고정"), "locked wins over pipeline too old")
    // every combination: a locked item is never enabled; an enabled item always has a target
    var bad: [String] = []
    for value in [false, true] { for locked in [false, true] { for target in [nil, "s"] as [String?] { for relax in [false, true] { for oldFlag in [false, true] {
        let item = M.localOnlyItemState(for: state(view(value, locked: locked, target: target, relax: relax, old: oldFlag)))
        if item.enabled && (locked || oldFlag || target == nil || (value && !relax)) { bad.append("\(value) \(locked) \(String(describing: target)) \(relax) \(oldFlag)") }
        if locked && !item.checked { bad.append("locked but not checked") }
        if item.title.isEmpty { bad.append("empty title") }
    } } } } }
    check(bad.isEmpty, "all 32 view combinations: never enabled when locked, too old, without a target or when OFF is no longer possible", bad.joined(separator: " | "))

    var rec = ControllerState(); rec.status = .recording(.zoom, since: Date(timeIntervalSince1970: 0))
    check(M.manualItemState(for: rec) == M.ManualItemState(title: "Stop Recording Now", enabled: true, tooltip: nil), "manual item while recording: Stop")
    var blockedState = ControllerState(); blockedState.recordingBlockedByPolicy = true
    check(M.manualItemState(for: ControllerState()) == M.ManualItemState(title: "Start Recording Now", enabled: true, tooltip: nil), "manual item idle: Start, enabled (today's item)")
    check(!M.manualItemState(for: blockedState).enabled && M.manualItemState(for: blockedState).title == "Start Recording Now (조직 정책으로 꺼짐)", "manual item when the policy switched recording off: disabled with the reason")
    var recBlocked = rec; recBlocked.recordingBlockedByPolicy = true
    check(M.manualItemState(for: recBlocked).enabled, "... a recording that is still running can always be stopped")

    // the idle lines come from EffectiveLanes (what is true), through the controller
    let now = Date(timeIntervalSince1970: 1_000_000)
    let owner = loHarness("lo-menu-owner", in: base)
    owner.controller.tick()
    check(owner.state.infoLines == ["전사: 이 Mac에서 처리 (외부 전사 없음)", "보관: Google Drive(동기화)"], "the personal install: '전사: 이 Mac에서 처리 (외부 전사 없음)' and '보관: Google Drive(동기화)'", "\(owner.state.infoLines)")
    check(M.menuText(for: owner.state, now: now).lines == owner.state.infoLines, "the menu shows exactly those two lines while idle")
    check(!owner.state.infoLines.joined().contains("떠나지 않"), "no sentence that the audio never leaves this Mac (Drive archives the m4a)")
    let localDefault = loHarness("lo-menu-local", in: base, privacy: loPrivacy(["LOCAL_ONLY_DEFAULT": "1"], in: base))
    localDefault.controller.tick()
    check(localDefault.state.infoLines == ["전사: 로컬 전용", "보관: 이 Mac 전용"], "LOCAL_ONLY_DEFAULT=1: '전사: 로컬 전용' and '보관: 이 Mac 전용'", "\(localDefault.state.infoLines)")
    let company = loHarness("lo-menu-company", in: base, policy: loPolicy())
    company.controller.tick()
    check(company.state.infoLines == ["전사: 이 Mac에서 처리 (외부 전사 없음)", "보관: 이 Mac 전용"], "a company policy without a lane: transcription here, kept on this Mac", "\(company.state.infoLines)")
    let driveRoot = AppConfig.defaults().archiveDir.path
    let drive = loPolicy(["lanes": ["drive": "allow"], "approvals": ["drive": "TICKET-1"], "archive": ["allowed_roots": [driveRoot]]])
    check(drive.isValid && drive.laneAllowed("drive"), "(a company policy that allows Drive for the archive folder)")
    let withDrive = loHarness("lo-menu-drive", in: base, policy: drive, privacy: loPrivacy(["ARCHIVE_DIR": driveRoot], in: base))
    withDrive.controller.tick()
    // comparing ARCHIVE_DIR with the policy roots touches the disk (a cloud mount): the controller queue does not wait for it
    check(waitUntil(10) { withDrive.sync(); return withDrive.state.infoLines.count == 2 }, "the lines that need the archive path are computed in the background and published when ready", "\(withDrive.state.infoLines)")
    check(withDrive.state.infoLines == ["전사: 이 Mac에서 처리 (외부 전사 없음)", "보관: 팀 드라이브(동기화)"], "the team drive is named only when the policy allows it for this folder", "\(withDrive.state.infoLines)")
    // a new policy revision changes the lines (the cache follows the policy)
    withDrive.policyBox.policy = loPolicy()
    withDrive.controller.tick()
    check(withDrive.state.infoLines.last == "보관: 이 Mac 전용", "after the policy changed the lines follow", "\(withDrive.state.infoLines)")
    // not while recording
    owner.controller.startRecordingNow(); owner.sync()
    check(M.menuText(for: owner.state, now: now).lines.isEmpty || !M.menuText(for: owner.state, now: now).lines.contains("보관: Google Drive(동기화)"), "the idle lines are not shown while recording")
    check(M.menuText(for: ControllerState(), now: now).lines.isEmpty, "a state without info lines adds none (today's menu)")
}

// MARK: S-LO-18: what the pipeline left behind, and the completion texts

private func testLOFinishedTexts(_ base: URL) {
    section("S-LO-18: state.json local_only and lanes, the completion notification and the 'Done' line (no title for local-only)")
    let fm = FileManager.default
    let root = base.appendingPathComponent("lo-facts", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    func make(_ name: String, state: String?) -> URL {
        let d = sessions.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        if let s = state { try? s.write(to: d.appendingPathComponent("state.json"), atomically: true, encoding: .utf8) }
        return d
    }
    _ = make("a", state: #"{"stage":"done","local_only":true,"lanes":{"llm":"skipped:local_only","calendar":"skipped:local_only","drive":"skipped:local_only"}}"#)
    let a = PipelineFacts.outcome(session: "a", sessionsDir: sessions, finalDir: nil, logDir: logs)
    check(a.localOnly == true && a.lanesSkipped == ["calendar", "drive", "llm"], "local_only true and three skipped lanes are read from state.json", "\(a)")
    _ = make("b", state: #"{"stage":"done","local_only":false,"lanes":{"llm":"skipped:lane-denied","calendar":"ok","drive":"done"}}"#)
    let b = PipelineFacts.outcome(session: "b", sessionsDir: sessions, finalDir: nil, logDir: logs)
    check(b.localOnly == false && b.lanesSkipped == ["llm"], "only the lanes whose value starts with 'skipped' count", "\(b)")
    for (name, state) in [("c", #"{"stage":"done","local_only":"true","lanes":"x"}"#), ("d", #"{"stage":"done","local_only":1}"#), ("e", #"{"stage":"done"}"#), ("f", #"{"stage":"done","local_only":null,"lanes":[1,2]}"#)] {
        _ = make(name, state: state)
        let o = PipelineFacts.outcome(session: name, sessionsDir: sessions, finalDir: nil, logDir: logs)
        check(o.localOnly == nil && o.lanesSkipped.isEmpty, "state.json \(state): not a boolean / not an object: no statement (nil, no lanes)", "\(o)")
    }
    // a published folder carries the state.json (a restricted folder keeps it)
    let published = root.appendingPathComponent("local-archive/2026-10/2026-10-07_1400_x", isDirectory: true)
    try? fm.createDirectory(at: published, withIntermediateDirectories: true)
    try? #"{"stage":"done","local_only":true,"lanes":{"llm":"skipped:local_only"}}"#.write(to: published.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    let p = PipelineFacts.outcome(session: "gone-from-staging", sessionsDir: sessions, finalDir: published, logDir: logs)
    check(p.localOnly == true && p.lanesSkipped == ["llm"] && p.folder?.lastPathComponent == "2026-10-07_1400_x", "the state.json of the published folder is used when staging has none", "\(p)")

    // the controller: which notification, which 'Done' line
    let secret = "Secret Roadmap Review"
    func finish(_ h: Harness, session: String, outcome: PipelineOutcome?, title: String? = secret) {
        if let o = outcome { h.pipeline.outcomes[session] = o }
        h.pipeline.onEvent?(.finished(session: session, title: title, finalDir: URL(fileURLWithPath: "/tmp/mcap-lo-final", isDirectory: true), discarded: false)); h.sync()
    }
    func everything(_ h: Harness) -> String {
        let n = h.notifier.posted.map { "\($0.title) | \($0.subtitle) | \($0.body) | \($0.summary)" }.joined(separator: "\n")
        return n + "\n" + "\(h.state.status)"
    }
    let local = loHarness("lo-done-local", in: base)
    finish(local, session: "s1", outcome: PipelineOutcome(platform: .zoom, durationSeconds: 1932, localOnly: true, lanesSkipped: ["llm", "calendar", "drive"]))
    let n1 = local.notifier.posted.last
    check(n1?.kind == .transcriptReady && n1?.title == "전사본이 준비됐어요 (로컬 전용)" && n1?.subtitle == "Zoom · 32분 녹음" && n1?.body.hasPrefix("회의록·캘린더·Drive 업로드는 건너뛰었어요") == true,
          "a local-only session: 'transcript ready (local-only)' with platform and length", "\(n1.map { "\($0.title) | \($0.subtitle) | \($0.body)" } ?? "nil")")
    check(!everything(local).contains(secret) && local.state.status == .done("Transcript ready (local-only)"), "... no meeting title in the notification, the summary or the menu's Done line", "\(local.state.status)")
    check(!local.notifier.posted.contains { $0.kind == .noteReady }, "... and no 'meeting note ready'")

    let denied = loHarness("lo-done-denied", in: base)
    finish(denied, session: "s2", outcome: PipelineOutcome(platform: .teams, durationSeconds: 600, localOnly: false, lanesSkipped: ["llm"]))
    let n2 = denied.notifier.posted.last
    check(n2?.kind == .transcriptReady && n2?.title == "전사본이 준비됐어요" && n2?.body.hasPrefix("회의록은 조직 정책에 따라 건너뛰었어요") == true && denied.state.status == .done("Transcript ready (note skipped by policy)"),
          "a session whose note lane the organisation denied: 'transcript ready', says the note was skipped by policy", "\(n2.map { "\($0.title) | \($0.body)" } ?? "nil") \(denied.state.status)")

    let normal = loHarness("lo-done-normal", in: base)
    finish(normal, session: "s3", outcome: PipelineOutcome(platform: .zoom, durationSeconds: 1932, localOnly: false), title: "Weekly Sync")
    let n3 = normal.notifier.posted.last
    check(n3?.kind == .noteReady && n3?.title == "회의록이 준비됐어요" && n3?.subtitle == "Weekly Sync" && normal.state.status == .done("Weekly Sync"), "a normal session: 'meeting note ready' with the title, as always", "\(n3.map { "\($0.title) | \($0.subtitle)" } ?? "nil")")
    let noOutcome = loHarness("lo-done-none", in: base)
    finish(noOutcome, session: "s4", outcome: nil, title: "Weekly Sync")
    check(noOutcome.notifier.posted.last?.kind == .noteReady, "no outcome known: the note-ready text (nothing is assumed)")

    let quiet = loHarness("lo-done-logcontent", in: base, privacy: loPrivacy(["LOG_CONTENT": "0"], in: base))
    finish(quiet, session: "s5", outcome: PipelineOutcome(platform: .zoom, durationSeconds: 600, localOnly: false))
    check(quiet.notifier.posted.last?.kind == .noteReady && !everything(quiet).contains(secret) && quiet.state.status == .done("Meeting note ready"),
          "LOG_CONTENT=0: the note-ready notification and the Done line carry no meeting title", "\(quiet.state.status) \(quiet.notifier.posted.last?.subtitle ?? "nil")")
}

// MARK: S-LO-19: the start and stop notifications

private func testLOStartNotifications(_ base: URL) {
    section("S-LO-19: start / stop notifications: the flag at the end of the start text, no title for a local-only meeting or LOG_CONTENT=0")
    let secret = "Secret Roadmap Review"
    let zoom = PlatformSignal(platform: .zoom, inCall: true, confidence: .high, titleHint: secret, meetingURL: nil, meetingKey: nil, bundleID: "us.zoom.xos", evidence: ["selftest"])
    func run(_ name: String, policy: OrgPolicy = OrgPolicy.absent(), settings: [String: String] = [:], toggleOnAfterStart: Bool = false) -> (Harness, FakeRecorder)? {
        let h = loHarness(name, in: base, policy: policy, privacy: loPrivacy(settings, in: base), configure: { $0.notifyRecording = true })
        h.run(until: { !h.recorders.isEmpty }, limit: 15, [zoom])
        h.sync()
        guard let rec = h.current else { return nil }
        if toggleOnAfterStart { _ = h.controller.toggleLocalOnly(to: true) }
        h.run(70, [zoom])
        h.run(until: { !rec.isRecording }, limit: 80, [])
        h.sync()
        return (h, rec)
    }
    let today = "Zoom 회의 녹음을 시작했어요. 메뉴바 아이콘이 가려져 있어도 이 알림으로 확인할 수 있어요"
    // 1. the personal install: exactly today's text, the title shown
    if let (h, _) = run("lo-start-owner") {
        let s = h.notifier.posted.first { $0.kind == .recordingStarted }
        check(s?.body == today && s?.subtitle == secret, "no policy, flag off: today's start text, the meeting title shown", "\(s?.body ?? "nil") | \(s?.subtitle ?? "nil")")
        check(h.notifier.posted.first { $0.kind == .recordingStopped }?.subtitle.hasPrefix(secret) == true, "... and today's stop text (title first)")
    } else { check(false, "owner session") }
    // 2. flag on by default: the tail says on, no title anywhere
    if let (h, _) = run("lo-start-on", settings: ["LOCAL_ONLY_DEFAULT": "1"]) {
        let s = h.notifier.posted.first { $0.kind == .recordingStarted }
        check(s?.body == today + " · 로컬 전용: 켜짐" && s?.subtitle == "회의를 감지해 자동으로 시작했어요", "local-only on: the tail '로컬 전용: 켜짐' and no meeting title", "\(s?.body ?? "nil") | \(s?.subtitle ?? "nil")")
        let all = h.notifier.posted.map { "\($0.title) \($0.subtitle) \($0.body) \($0.summary)" }.joined(separator: "\n")
        check(!all.contains(secret) && h.notifier.posted.contains { $0.kind == .recordingStopped }, "local-only on: neither the start nor the stop notification carries the title", all)
    } else { check(false, "local-only session") }
    // 3. a policy exists, flag off: the tail says off, the title is shown (LOG_CONTENT is on)
    if let (h, _) = run("lo-start-policy", policy: loPolicy()) {
        let s = h.notifier.posted.first { $0.kind == .recordingStarted }
        check(s?.body == today + " · 로컬 전용: 꺼짐 (민감한 회의면 메뉴에서 켜세요)" && (s?.body.count ?? 999) <= 100 && s?.subtitle == secret,
              "a policy exists, flag off: the tail '꺼짐 (민감한 회의면 메뉴에서 켜세요)', still within 100 characters", "\(s?.body ?? "nil") (\(s?.body.count ?? 0))")
    } else { check(false, "policy session") }
    // 4. LOG_CONTENT=0 alone hides the title but adds no tail
    if let (h, _) = run("lo-start-nolog", settings: ["LOG_CONTENT": "0"]) {
        let s = h.notifier.posted.first { $0.kind == .recordingStarted }
        check(s?.body == today && s?.subtitle == "회의를 감지해 자동으로 시작했어요" && !h.notifier.posted.map { $0.subtitle + $0.body }.joined().contains(secret), "LOG_CONTENT=0: no title in the start and stop texts, no tail without a policy", "\(s?.subtitle ?? "nil")")
    } else { check(false, "LOG_CONTENT=0 session") }
    // 5. switched ON during the recording: the stop notification leaves the title out (the start one showed it while the flag was off)
    if let (h, _) = run("lo-start-toggled", toggleOnAfterStart: true) {
        let s = h.notifier.posted.first { $0.kind == .recordingStarted }
        let e = h.notifier.posted.first { $0.kind == .recordingStopped }
        check(s?.subtitle == secret && e != nil && e?.subtitle.contains(secret) == false && h.notifier.posted.contains { $0.kind == .localOnlyChanged },
              "ON during the recording: the stop text has no title (the start text, posted while the flag was off, had it)", "\(e?.subtitle ?? "nil")")
    } else { check(false, "toggled session") }
}

// MARK: S-LO-20: policy problems, the watcher, the commands

private func testLOPolicyProblems(_ base: URL) {
    section("S-LO-20: a policy that cannot be read is announced once; the watcher reads the file only when it changed; the new commands")
    let lockedJSON = #"{"schema":1,"profile":"company","revision":3,"support":{"contact":"IT 헬프데스크 #it-help"},"bogus":1}"#
    let locked = OrgPolicy.parse(Data(lockedJSON.utf8))
    check(locked.isLocked && locked.supportContact == loContact && locked.lockedCode == "unknown-key", "(the test policy is locked: unknown key, with a contact)", "\(String(describing: locked.lockedReason))")

    // at start
    let h = loHarness("lo-problem", in: base, policy: locked)
    h.controller.start(); h.sync()
    h.controller.shutdown(timeout: 5)
    let n = h.notifier.posted.filter { $0.kind == .policyProblem }
    check(n.count == 1 && n[0].title == "조직 정책을 읽을 수 없어요" && n[0].body == "안전을 위해 외부 전송을 막고 로컬 전사만 해요 · 정책 내용 오류 · 문의: \(loContact)" && n[0].body.count <= 100,
          "a locked policy at start: ONE notification with the short Korean reason and the contact (<= 100 characters)", "\(n.map { $0.body })")
    check(!n.map { $0.body }.joined().contains("unknown-key") && !n.map { $0.body }.joined().contains("bogus"), "... without the English reason code or the policy text")
    // a quiet start without a problem
    let calm = loHarness("lo-problem-none", in: base, policy: loPolicy())
    calm.controller.start(); calm.sync(); calm.controller.shutdown(timeout: 5)
    check(calm.notifier.count(.policyProblem) == 0, "a valid policy at start: no policy notification")
    let owner = loHarness("lo-problem-owner", in: base)
    owner.controller.start(); owner.sync(); owner.controller.shutdown(timeout: 5)
    check(owner.notifier.posted.isEmpty, "the personal install (no policy): nothing is posted at start")

    // the watcher inside the controller: a new revision that locks, the same reason again, a different reason
    var live = loPolicy()
    let w = loHarness("lo-problem-watch", in: base, policy: live, reader: { live })
    w.run(61, [])
    check(w.notifier.count(.policyProblem) == 0, "(a valid policy is read, nothing is said)")
    live = locked
    w.run(61, [])
    check(w.notifier.count(.policyProblem) == 1 && w.policyBox.policy.isLocked, "the policy becomes unreadable while the app runs: one notification, the shared policy is locked now")
    live = OrgPolicy.parse(Data(lockedJSON.replacingOccurrences(of: "\"revision\":3", with: "\"revision\":4").utf8))
    w.run(61, [])
    check(w.notifier.count(.policyProblem) == 1, "the same reason in a newer file: not announced again")
    live = OrgPolicy.parse(Data("{".utf8))
    w.run(61, [])
    check(w.notifier.count(.policyProblem) == 2 && w.notifier.posted.last?.body.contains("정책 파일 형식 오류") == true, "a different reason is announced", "\(w.notifier.posted.last?.body ?? "nil")")
    live = loPolicy()
    w.run(61, [])
    check(!w.policyBox.policy.isLocked && w.state.localOnly?.locked == false, "a valid policy again: the lock is gone")

    // PolicyWatcher: no read, no log line, while nothing changed
    var loads = 0
    var fingerprint = "a"
    var next = loPolicy()
    let watcher = PolicyWatcher(initial: loPolicy(), load: { loads += 1; return next }, fingerprint: { fingerprint })
    _ = watcher.current(); _ = watcher.current()
    check(loads == 0, "PolicyWatcher: the file is not parsed while its fingerprint is unchanged", "loads \(loads)")
    fingerprint = "b"
    next = loPolicy(["recording": ["enabled": false]])
    check(watcher.current() == next && loads == 1, "PolicyWatcher: a changed fingerprint is one read", "loads \(loads)")
    _ = watcher.current()
    check(loads == 1, "... and not again")
    fingerprint = "c"
    next = locked
    check(watcher.current().isLocked && loads == 2, "PolicyWatcher: a changed file that is now locked")
    _ = watcher.current(); _ = watcher.current()
    check(loads == 4, "PolicyWatcher: while the policy is locked it is read every time (a repair of a parent folder is not in the fingerprint)", "loads \(loads)")
    // a file that changed between the first read and the watcher's creation is seen at the first poll
    var earlyLoads = 0
    let early = PolicyWatcher(initial: loPolicy(), initialFingerprint: "before", load: { earlyLoads += 1; return loPolicy() }, fingerprint: { "after" })
    _ = early.current()
    check(earlyLoads == 1, "PolicyWatcher: the fingerprint taken before the first read is the baseline (a change in between is not missed)", "loads \(earlyLoads)")
    // the real fingerprint
    let dir = base.appendingPathComponent("lo-fingerprint", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("policy.json")
    let marker = dir.appendingPathComponent("policy.required")
    func fp() -> String { PolicyWatcher.systemFingerprint(paths: [file, marker]) }
    let none = fp()
    check(none == "absent|absent", "fingerprint of two missing files", none)
    try? "one".write(to: file, atomically: true, encoding: .utf8)
    let one = fp()
    check(one != none && one == fp(), "a new file changes the fingerprint; the same file gives the same one")
    try? "three!".write(to: file, atomically: true, encoding: .utf8)
    let three = fp()
    check(three != one, "a rewrite (size, time) changes it")
    chmod(file.path, 0o600)
    check(fp() != three, "a chmod changes it (ctime, mode)")
    try? "x".write(to: marker, atomically: true, encoding: .utf8)
    let withMarker = fp()
    check(withMarker.split(separator: "|").count == 2 && !withMarker.hasSuffix("absent") && withMarker != three, "the marker file is part of it")
    try? FileManager.default.removeItem(at: file)
    check(fp().hasPrefix("absent|"), "a removed policy file: absent")

    // the new commands
    check(LaunchArguments.commands.contains("policy-status") && LaunchArguments.commands.contains("selftest-policy") && LaunchArguments.commands.contains("selftest-firstrun"), "LaunchArguments.commands knows policy-status, selftest-policy and selftest-firstrun")
    check(LaunchArguments.strip(["-NSFoo", "YES", "policy-status", "--json"]) == ["policy-status", "--json"] && LaunchArguments.strip(["-NSFoo", "policy-status"]) == ["policy-status"]
          && LaunchArguments.strip(["-NSFoo", "selftest-policy"]) == ["selftest-policy"], "strip keeps the new commands (a missing value never swallows them)")

    // the launcher refused: the controller says why
    let b = loHarness("lo-blockedevent", in: base, policy: loPolicy())
    b.pipeline.onEvent?(.blocked(session: "2026-10-07_1400_zoom", reason: .pipelineTooOld(have: "0.1.0", required: "0.2.0"))); b.sync()
    let t = b.notifier.posted.last
    check(t?.kind == .policyProblem && t?.title == "파이프라인 업데이트가 필요해요" && t?.body.contains(loContact) == true && (t?.body.count ?? 999) <= 100 && t?.sound == true,
          "blocked (pipeline too old): '파이프라인 업데이트가 필요해요' with the contact", "\(t.map { "\($0.title) | \($0.body)" } ?? "nil")")
    if case .error(let text) = b.state.status { check(text.contains("2026-10-07_1400_zoom") && text.contains("older than the required 0.2.0"), "... the menu shows an error that names the versions", text) } else { check(false, "the menu shows an error", "\(b.state.status)") }
    b.pipeline.onEvent?(.blocked(session: "2026-10-07_1500_zoom", reason: .pipelineTooOld(have: "0.1.0", required: "0.2.0"))); b.sync()
    check(b.notifier.count(.policyProblem) == 1, "the same cause for another session within 12 hours: not announced again")
    b.pipeline.onEvent?(.blocked(session: "2026-10-07_1500_zoom", reason: .runtimeUntrusted("python: not owned by root"))); b.sync()
    check(b.notifier.count(.policyProblem) == 2 && b.notifier.posted.last?.title == "신뢰할 수 없는 실행 환경이에요", "an untrusted runtime is its own notification", "\(b.notifier.posted.last?.title ?? "nil")")
}

// =====================================================================================
// SPEC 18: the microphone mute gate, controller side. The gate itself (state machine, signals, mic.wav with
// zeros, session.json mic_gate, the private sidecar) is tested by `selftest-capture --synthetic`; here: MIC_MUTE_GATE reaches the recorder, the
// company baseline forces it on, the menu item 'Pause Microphone', and the controller's no-speech auto-stop reads the audio before the gate.
// =====================================================================================

// MARK: S-MG-01: the controller and the gate

private func testMGController(_ base: URL) {
    section("S-MG-01: MIC_MUTE_GATE reaches every recording before start(); the company baseline forces it on; Pause Microphone")
    let fm = FileManager.default

    // off (today's default): nothing new anywhere
    let off = Harness("mg-off", in: base)
    check(off.controller.toggleMicrophonePause() == .noRecording, "off, idle: Pause Microphone has no recording to act on (.noRecording)")
    off.controller.startRecordingNow(); off.sync()
    let offRec = off.current
    check(offRec?.muteGateCalls == [false], "MIC_MUTE_GATE off (the default): the recorder is told 'off' once, before it starts", "\(String(describing: offRec?.muteGateCalls))")
    check(off.state.micGate == nil && !StatusMenuController.micPauseItemState(for: off.state).visible, "off: the controller publishes no gate view, so the menu has no 'Pause Microphone' item at all")
    check(off.controller.toggleMicrophonePause() == .notAvailable && offRec?.pauseCalls.isEmpty == true, "off: Pause Microphone is .notAvailable and never reaches the recorder")
    check(!StatusMenuController.menuText(for: off.state, now: Date(timeIntervalSince1970: 0)).headline.contains("마이크"), "off: the status line says nothing about the microphone")
    off.controller.shutdown(reason: .appQuit)

    // on
    let on = loHarness("mg-on", in: base, privacy: loPrivacy(["MIC_MUTE_GATE": "on"], in: base))
    on.controller.tick()
    check(on.state.micGate == MicGateView(recording: false, paused: false), "on, idle: the gate view exists (the item is in the menu) but nothing is recording", "\(String(describing: on.state.micGate))")
    var item = StatusMenuController.micPauseItemState(for: on.state)
    check(item.visible && !item.enabled && item.title == "Pause Microphone", "on, idle: the item is visible and disabled", "\(item)")
    check(on.controller.toggleMicrophonePause() == .noRecording, "on, idle: .noRecording")
    on.controller.startRecordingNow(); on.sync()
    guard let rec = on.current else { check(false, "on: a recording started"); return }
    check(rec.muteGateCalls == [true], "MIC_MUTE_GATE=on: the recorder is told 'on' once, before start()", "\(rec.muteGateCalls)")
    check(on.state.micGate == MicGateView(recording: true, paused: false), "on, recording: the gate view says a recording can be paused", "\(String(describing: on.state.micGate))")
    item = StatusMenuController.micPauseItemState(for: on.state)
    check(item.visible && item.enabled && !item.checked && item.title == "Pause Microphone", "on, recording: 'Pause Microphone', enabled, not checked", "\(item)")

    let paused = on.controller.toggleMicrophonePause()
    check(paused == .applied(paused: true) && rec.microphonePaused && rec.pauseCalls == [true], "toggle: applied(paused: true), the recorder was told", "\(paused) \(rec.pauseCalls)")
    check(on.state.micGate == MicGateView(recording: true, paused: true), "the gate view follows: paused")
    item = StatusMenuController.micPauseItemState(for: on.state)
    check(item.title == "Resume Microphone" && item.checked && item.enabled, "the item now reads 'Resume Microphone', checked, enabled", "\(item)")
    let headline = StatusMenuController.menuText(for: on.state, now: on.clock.now).headline
    check(headline.hasPrefix("Recording") && headline.hasSuffix("마이크 일시중지"), "the status line (and the icon's tooltip) says the microphone is paused", headline)
    let again = on.controller.toggleMicrophonePause(to: true)
    check(again == .applied(paused: true) && rec.pauseCalls == [true], "asking for the value it already has changes nothing (the recorder is not called again)")
    let resumed = on.controller.toggleMicrophonePause()
    check(resumed == .applied(paused: false) && !rec.microphonePaused && rec.pauseCalls == [true, false] && on.state.micGate?.paused == false, "toggle again: resumed", "\(resumed) \(rec.pauseCalls)")
    check(!StatusMenuController.menuText(for: on.state, now: on.clock.now).headline.contains("마이크"), "resumed: the status line is the normal one again")

    rec.failPause = true
    check(on.controller.toggleMicrophonePause() == .notAvailable && on.state.micGate?.paused == false && !rec.microphonePaused, "a recorder that does not accept the pause: .notAvailable, nothing changed in the menu state")
    check(logText().contains("microphone pause was not accepted by the recorder"), "... and the log says so")
    rec.failPause = false

    // the pause ends with the recording; the next one starts unpaused
    _ = on.controller.toggleMicrophonePause()
    check(on.state.micGate?.paused == true, "paused again")
    on.controller.stopRecordingNow(); on.sync()
    check(on.state.micGate == MicGateView(recording: false, paused: false), "after the stop: nothing is paused any more and the item is disabled", "\(String(describing: on.state.micGate))")
    check(!StatusMenuController.micPauseItemState(for: on.state).enabled, "... the item is disabled")
    on.controller.startRecordingNow(); on.sync()
    check(on.recorders.count == 2 && on.current?.muteGateCalls == [true] && on.current?.microphonePaused == false && on.state.micGate == MicGateView(recording: true, paused: false),
          "the next recording is told 'on' again and starts unpaused", "\(on.recorders.count)")
    on.controller.shutdown(reason: .appQuit)

    // a recorder that has no gate (it ignores the setting): the item stays disabled, the pause is refused
    let none = loHarness("mg-nogate", in: base, privacy: loPrivacy(["MIC_MUTE_GATE": "on"], in: base))
    none.gateIgnored = true
    none.controller.startRecordingNow(); none.sync()
    check(none.state.micGate == MicGateView(recording: false, paused: false) && none.controller.toggleMicrophonePause() == .notAvailable,
          "a recorder that cannot gate: the view says nothing can be paused, the toggle is .notAvailable", "\(String(describing: none.state.micGate))")
    none.controller.shutdown(reason: .appQuit)

    // the company baseline: MIC_MUTE_GATE=on, whatever config.env says; an explicit enforced entry is the only way to lower it
    let root = base.appendingPathComponent("mg-baseline", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    var cfg = AppConfig.defaults()
    cfg.supportDir = root.appendingPathComponent("support", isDirectory: true)
    let envFile = root.appendingPathComponent("config.env")
    try? Data("MIC_MUTE_GATE=off\nSELF_NAME=Tester\n".utf8).write(to: envFile)
    let missing = root.appendingPathComponent("no-such-config.env")
    func gate(_ policy: OrgPolicy, file: URL = envFile) -> String { PrivacySettings.load(config: cfg, policy: policy, file: file).micMuteGate }
    check(gate(OrgPolicy.absent()) == "off", "no policy, config.env says off: off (the personal install)")
    check(gate(loPolicy()) == "on", "company profile: the baseline forces MIC_MUTE_GATE=on over a config.env that says off", gate(loPolicy()))
    check(gate(loPolicy(), file: missing) == "on", "company profile without any config.env: on")
    check(gate(loPolicy(profile: "personal")) == "off", "personal profile: no baseline, off")
    check(gate(loPolicy(["enforced": ["MIC_MUTE_GATE": "off"]])) == "off", "company profile with MIC_MUTE_GATE named in enforced: the only way to lower it")
    check(PrivacySettings.build(from: ["MIC_MUTE_GATE": "banana"], supportDir: cfg.supportDir, source: "selftest").micMuteGate == "on", "an unknown text is read as on (the restrictive value)")
    let company = loHarness("mg-company", in: base, policy: loPolicy(), privacy: PrivacySettings.load(config: cfg, policy: loPolicy(), file: envFile))
    company.controller.startRecordingNow(); company.sync()
    check(company.current?.muteGateCalls == [true] && company.state.micGate?.recording == true,
          "a company Mac: the recording is told 'on' and the menu item works, although config.env says off", "\(String(describing: company.current?.muteGateCalls))")
    company.controller.shutdown(reason: .appQuit)
}

// MARK: S-MG-02: the menu

private func testMGMenu() {
    section("S-MG-02: the Pause Microphone item in every state, the paused status line")
    typealias M = StatusMenuController
    func state(_ view: MicGateView?) -> ControllerState { var s = ControllerState(); s.micGate = view; return s }
    let none = M.micPauseItemState(for: state(nil))
    check(!none.visible && !none.enabled && !none.checked && none.title == "Pause Microphone", "no gate view (MIC_MUTE_GATE off): not visible, not enabled (today's menu)", "\(none)")
    let idle = M.micPauseItemState(for: state(MicGateView(recording: false, paused: false)))
    check(idle.visible && !idle.enabled && !idle.checked && idle.tooltip?.contains("녹음 중인 회의에서만") == true, "gate on, nothing recording: visible, disabled, the tooltip says why", "\(idle)")
    let ready = M.micPauseItemState(for: state(MicGateView(recording: true, paused: false)))
    check(ready.visible && ready.enabled && !ready.checked && ready.title == "Pause Microphone" && ready.tooltip?.contains("회의 앱의 음소거 신호와 상관없이") == true,
          "recording: 'Pause Microphone', enabled, the tooltip says it works whatever the meeting app says", "\(ready)")
    let held = M.micPauseItemState(for: state(MicGateView(recording: true, paused: true)))
    check(held.visible && held.enabled && held.checked && held.title == "Resume Microphone" && held.tooltip?.contains("기록되지 않아요") == true, "paused: 'Resume Microphone', checked, enabled, the tooltip says what is not recorded", "\(held)")
    var bad: [String] = []
    for view in [nil, MicGateView(recording: false, paused: false), MicGateView(recording: false, paused: true), MicGateView(recording: true, paused: false), MicGateView(recording: true, paused: true)] {
        let item = M.micPauseItemState(for: state(view))
        if item.visible != (view != nil) { bad.append("visible \(String(describing: view))") }
        if item.enabled && view?.recording != true { bad.append("enabled without a recording \(String(describing: view))") }
        if item.checked != (view?.recording == true && view?.paused == true) { bad.append("checked \(String(describing: view))") }
        if item.title.isEmpty { bad.append("empty title") }
    }
    check(bad.isEmpty, "all five view combinations: visible exactly when the gate is on, enabled only while recording, checked only while paused", bad.joined(separator: " | "))

    var rec = ControllerState(); rec.status = .recording(.zoom, since: Date(timeIntervalSince1970: 0))
    let plain = M.menuText(for: rec, now: Date(timeIntervalSince1970: 75)).headline
    rec.micGate = MicGateView(recording: true, paused: true)
    let pausedLine = M.menuText(for: rec, now: Date(timeIntervalSince1970: 75)).headline
    check(plain == "Recording Zoom  01:15" && pausedLine == "Recording Zoom  01:15" + M.micPausedSuffix && pausedLine.count <= 64, "the status line while paused: the normal line plus ' · 마이크 일시중지'", pausedLine)
    var manual = rec; manual.manualRecording = true
    check(M.menuText(for: manual, now: Date(timeIntervalSince1970: 75)).headline == "Recording (manual)  01:15" + M.micPausedSuffix, "... also for a manual recording")
    rec.micGate = MicGateView(recording: true, paused: false)
    check(M.menuText(for: rec, now: Date(timeIntervalSince1970: 75)).headline == plain && M.menuText(for: rec, now: Date(timeIntervalSince1970: 75)).buttonTitle == "01:15", "gate on but not paused: today's line, the icon's elapsed time unchanged")
    check(M.menuText(for: state(MicGateView(recording: false, paused: false)), now: Date(timeIntervalSince1970: 0)).lines.isEmpty, "an idle menu with the gate on has no extra lines")
}

// MARK: S-MG-03: the meter and the no-speech auto-stop read the audio BEFORE the gate

private func testMGPreGate(_ base: URL) {
    section("S-MG-03: the controller's no-speech auto-stop reads the microphone before the gate (a real Recorder with synthetic sources)")
    let zoom = zoomSignal()
    func isRecording(_ h: Harness) -> Bool { if case .recording = h.state.status { return true } else { return false } }
    func harness(_ name: String, micAmplitude: Float) -> Harness {
        let h = loHarness(name, in: base, privacy: loPrivacy(["MIC_MUTE_GATE": "on"], in: base))
        h.recorderMaker = { [unowned h] dir, signal in
            let mic = SyntheticCaptureSource(label: "mic", device: "Synthetic Mic", sampleRate: 48000, nativeRate: 48000, frequency: 200, amplitude: micAmplitude)
            let remote = SyntheticCaptureSource(label: "global-tap", device: "Synthetic Speakers", sampleRate: 48000, nativeRate: 48000, frequency: 440, amplitude: 0)
            return Recorder(sessionDir: dir, signal: signal, config: h.config, remote: { remote }, mic: { mic }, muteSignals: { [] })
        }
        return h
    }

    // A: the person talks, the microphone is paused (zeros in the file): the controller must still see speech
    let h = harness("mg-pregate", micAmplitude: 0.3)
    h.run(until: { isRecording(h) }, limit: 20, [zoom])
    check(isRecording(h) && h.state.micGate == MicGateView(recording: true, paused: false), "a real Recorder was started by the controller with the gate on", "\(h.state.status) \(String(describing: h.state.micGate))")
    Thread.sleep(forTimeInterval: 0.5)
    check(h.controller.toggleMicrophonePause() == .applied(paused: true), "Pause Microphone on the real recorder is accepted")
    Thread.sleep(forTimeInterval: 0.5)
    let stops = logCount("stop (no-speech)")
    h.run(20 * 60, step: 2, [zoom])
    check(isRecording(h) && logCount("stop (no-speech)") == stops && h.state.micGate?.paused == true,
          "20 minutes (virtual) with the microphone paused and the other side silent: NOT stopped for no speech (the meter sees the speech behind the gate)")
    h.controller.stopRecordingNow(); h.sync()
    if let dir = h.pipeline.enqueued.last, let mic = CaptureSelfTest.readSamples(dir.appendingPathComponent("mic.wav")) {
        let from = Int(0.6 * Double(mic.info.sampleRate))
        check(mic.samples.count > from && mic.samples[from...].allSatisfy { $0 == 0 }, "... while mic.wav of the same recording is digital silence from the pause on (\(String(format: "%.1f", mic.info.seconds)) s)")
    } else {
        check(false, "the paused recording was kept and queued, and mic.wav can be read", "\(h.pipeline.enqueued.map { $0.lastPathComponent })")
    }

    // B: the person is really silent and the gate is on (a gate does not hide real silence): the auto-stop still works
    let q = harness("mg-silent", micAmplitude: 0)
    q.run(until: { isRecording(q) }, limit: 20, [zoom])
    Thread.sleep(forTimeInterval: 0.4)
    q.run(14 * 60, step: 2, [zoom])
    check(isRecording(q), "a silent microphone and a silent remote track with the gate on: still recording after 14 minutes")
    let stopped = q.run(until: { !isRecording(q) }, limit: 4 * 60, step: 2, [zoom])
    check(stopped != nil && q.pipeline.enqueued.count == 1, "... and stopped and queued once the silence reaches 15 minutes (the rule works as before)", "\(stopped ?? -1)")
}

// MARK: - S-CS-01 ... S-CS-07: Connect to Company Server

private let csURL = "https://asr.example.test:8443"
/// The enrollment code the tests type: unique, so that finding it anywhere but on the child's stdin is a leak.
private let csCode = "K7Q2-ZETA-4491-canary"
/// What a token looks like (mcap1_<id8>_<secret32>): a child that printed one must not get it into a log or a notification.
private let csToken = "mcap1_a1b2c3d4_Zk3Jx9QwErTyUiOpAsDfGhJkLzXcVbNm"
private let csEnrolled = "Enrolled: the token for asr.example.test:8443 is stored in the macOS Keychain and valid until 2027-01-08T10:00:00+09:00 (90 days). Check it with: mcap asr-engines check remote --live"
private let csConsent: [String: Any] = [
    "engine": "remote", "host": "asr.example.test", "port": 8443, "protocol": "mcap-asr/1", "backend_kind": "server",
    "ca_sha256": String(repeating: "a", count: 64), "attest_build_sha256": [String(repeating: "b", count: 64)], "use": "both", "expires": "2027-10-14"]

/// A valid company policy that lets this Mac use the company-server relay (lane allow, engine list with remote, host list with the server, one
/// org consent); each parameter takes one piece away (a company policy without a host list allows NO host: SPEC 18, decision table A2).
/// `extra` adds top-level keys.
private func csPolicy(consent: Bool = true, lane: String = "allow", engines: [String]? = ["whisper", "remote"], hosts: [String]? = ["asr.example.test"],
                      localOnlyLocked: Bool = false, _ extra: [String: Any] = [:]) -> OrgPolicy {
    var asr: [String: Any] = [:]
    if let engines = engines { asr["allowed_engines"] = engines }
    if let hosts = hosts { asr["allowed_hosts"] = hosts }
    if consent { asr["org_consents"] = [csConsent] }
    var object: [String: Any] = ["lanes": ["asr_remote": lane]]
    if !asr.isEmpty { object["asr"] = asr }
    if localOnlyLocked { object["local_only"] = ["locked": true] }
    for (key, value) in extra { object[key] = value }
    return loPolicy(object)
}

/// Fake "python" of the enrollment tests: records argv, cwd and environment (calls.log) and the first stdin line (stdin.txt), then answers like the
/// real command: the text of `enroll-output` (@CODE@ = the line it read) on stdout for exit status 0, on stderr otherwise, status from `enroll-status`.
/// `enroll-nostdin` = exits at once without reading, `enroll-hang` = never answers.
private let fakePythonEnrollScript = #"""
#!/bin/sh
D="$(cd "$(dirname "$0")" && pwd)"
{ echo "ARGS: $*"; echo "CWD: $(pwd -P)"; env | sort | sed 's/^/ENV /'; echo "-----"; } >> "$D/calls.log"
[ -e "$D/enroll-nostdin" ] && exit 0
[ -e "$D/enroll-hang" ] && exec sleep 60
IFS= read -r LINE
printf '%s\n' "$LINE" >> "$D/stdin.txt"
STATUS="$(cat "$D/enroll-status" 2>/dev/null || echo 0)"
OUT="$(cat "$D/enroll-output" 2>/dev/null)"
if [ "$STATUS" = "0" ]; then printf '%s\n' "$OUT" | sed "s|@CODE@|$LINE|g"; else printf '%s\n' "$OUT" | sed "s|@CODE@|$LINE|g" >&2; fi
exit "$STATUS"
"""#

/// One connector over the fake python, built by the launcher's own factory (policy box, runtime trust and version probe shared), with a fake
/// notifier, an injected pipeline version and file owner, and an injected ASR_REMOTE_URL.
private final class CSWorld {
    let world: LauncherWorld
    let launcher: PipelineLauncher
    let connector: CompanyServerConnect
    let notifier = FakeNotifier()
    private let versionCalls = Locked<Int>(0)
    var versionAsked: Int { versionCalls.value }

    init(_ name: String, in base: URL, policy: OrgPolicy, url: String? = csURL, version: String? = "0.2.0",
         fileInfo: @escaping (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile, timeout: TimeInterval = 30) {
        world = LauncherWorld(name, in: base, script: fakePythonEnrollScript)
        let counter = versionCalls
        launcher = PipelineLauncher(config: world.config, logDir: world.logs, statePollInterval: 0.05, stallTimeout: 600, policy: PolicyBox(policy),
                                    versionProbe: PipelineVersionProbe(),
                                    versionRunner: { _, _ in counter.value += 1; return version.map { "mcap \($0)" } },
                                    fileInfo: fileInfo)
        connector = launcher.companyServerConnect(notifier: notifier, remoteURL: { _ in url }, timeout: timeout)
        setChild(status: 0, output: csEnrolled)
    }

    func setChild(status: Int32, output: String) {
        try? "\(status)".write(to: world.bin.appendingPathComponent("enroll-status"), atomically: true, encoding: .utf8)
        try? output.write(to: world.bin.appendingPathComponent("enroll-output"), atomically: true, encoding: .utf8)
    }

    func flag(_ name: String) { try? "x".write(to: world.bin.appendingPathComponent("enroll-\(name)"), atomically: true, encoding: .utf8) }

    /// Types `code` and waits for the outcome (the notification was posted by then).
    func connect(_ code: String = csCode, wait: TimeInterval = 30) -> CompanyServerConnect.Outcome? {
        let box = Locked<CompanyServerConnect.Outcome?>(nil)
        connector.connect(code: code) { box.value = $0 }
        _ = waitUntil(wait) { box.value != nil }
        return box.value
    }

    var calls: String { world.callsLog }
    var stdin: String { (try? String(contentsOf: world.bin.appendingPathComponent("stdin.txt"), encoding: .utf8)) ?? "" }
    var childLog: String? { try? String(contentsOf: world.logs.appendingPathComponent(CompanyServerConnect.logFileName), encoding: .utf8) }
    var posted: [AppNotification] { notifier.posted }
    var postedText: String { posted.map { "\($0.title) \($0.subtitle) \($0.body) \($0.summary) \($0.action.userInfo.values.joined())" }.joined(separator: "\n") }
}

// MARK: S-CS-01: when the item exists

private func testCSAvailability(_ base: URL) {
    section("S-CS-01: 'Connect to Company Server...' exists only with an org consent in the policy or ASR_REMOTE_URL; a policy that keeps the relay closed leaves it disabled")
    typealias C = CompanyServerConnect
    typealias M = StatusMenuController
    let owner = OrgPolicy.absent()
    check(C.availability(policy: owner, remoteURL: nil) == .hidden && C.availability(policy: owner, remoteURL: "") == .hidden && C.availability(policy: owner, remoteURL: " \n ") == .hidden,
          "the personal install (no policy, no ASR_REMOTE_URL, or a blank one): no item")
    check(C.availability(policy: owner, remoteURL: csURL) == .ready, "no policy but ASR_REMOTE_URL set: the item is there and works")
    check(C.availability(policy: csPolicy(consent: false), remoteURL: nil) == .hidden, "a company policy that allows the relay but has no org consent and no ASR_REMOTE_URL: no item")
    check(csPolicy().isValid && csPolicy().orgConsentHosts == ["asr.example.test"], "(the test policy is a valid company policy with one org consent)", "\(String(describing: csPolicy().lockedReason))")
    check(C.availability(policy: csPolicy(), remoteURL: nil) == .ready, "an org consent in the policy: the item is there without ASR_REMOTE_URL")
    check(C.availability(policy: csPolicy(consent: false), remoteURL: csURL) == .ready, "ASR_REMOTE_URL without an org consent in the policy: the item is there")
    check(C.availability(policy: loPolicy(profile: "personal"), remoteURL: csURL) == .ready, "a personal-profile policy with ASR_REMOTE_URL (no engine list = no restriction): ready")

    let locked = OrgPolicy.parse(Data("not json".utf8))
    let denials: [(String, OrgPolicy, String?, C.Denial)] = [
        ("lanes.asr_remote deny", csPolicy(lane: "deny"), nil, .laneDenied),
        ("an engine list without remote", csPolicy(engines: ["whisper"]), nil, .engineNotAllowed),
        ("a company policy without an engine list (= no engine allowed)", csPolicy(engines: nil), nil, .engineNotAllowed),
        ("local_only.locked", csPolicy(localOnlyLocked: true), nil, .localOnlyLocked),
        ("a company policy WITHOUT a host list (omitted = empty = no server is allowed)", csPolicy(hosts: nil), nil, .hostNotAllowed),
        ("the same with ASR_REMOTE_URL set", csPolicy(hosts: nil), csURL, .hostNotAllowed),
        ("an EMPTY host list", csPolicy(hosts: []), csURL, .hostNotAllowed),
        ("a host list that does not name the consent's host", csPolicy(hosts: ["other.example.test"]), nil, .hostNotAllowed),
        ("a host list that does not name the host of ASR_REMOTE_URL", csPolicy(hosts: ["other.example.test"]), csURL, .hostNotAllowed),
        ("a host list that names the consent's host but ASR_REMOTE_URL points elsewhere (the URL decides, like in the pipeline)", csPolicy(), "https://other.example.test", .hostNotAllowed),
        ("ASR_REMOTE_URL that is not https (the pipeline never uses it)", csPolicy(), "http://asr.example.test", .hostNotAllowed),
        ("ASR_REMOTE_URL with credentials", csPolicy(), "https://user:secret@asr.example.test", .hostNotAllowed),
        ("ASR_REMOTE_URL with an IP address, even one the list names", csPolicy(hosts: ["10.1.2.3"]), "https://10.1.2.3", .hostNotAllowed),
        ("a policy that cannot be read (locked) and ASR_REMOTE_URL set", locked, csURL, .policyLocked)]
    for (name, policy, url, why) in denials {
        let verdict = C.availability(policy: policy, remoteURL: url)
        check(verdict == .denied(why), "\(name): the item is there but closed (\(why))", "\(verdict)")
    }
    check(C.availability(policy: locked, remoteURL: nil) == .hidden, "a locked policy has no org consent: without ASR_REMOTE_URL no item")
    // the host dimension from the other side: what is allowed is ready (the same words the pipeline reads: lower case, the host without the port)
    check(C.availability(policy: csPolicy(hosts: ["ASR.Example.Test"]), remoteURL: "https://ASR.example.TEST:8443/path") == .ready, "a host list and a URL that differ only in case: ready (policy hosts are lower-cased when read)")
    check(C.availability(policy: csPolicy(hosts: ["asr.example.test", "other.example.test"]), remoteURL: csURL) == .ready, "a host list with the server among others: ready")
    check(C.availability(policy: csPolicy(consent: false), remoteURL: csURL) == .ready && C.availability(policy: csPolicy(consent: false, hosts: ["other.example.test"]), remoteURL: csURL) == .denied(.hostNotAllowed),
          "a user consent (no org consent): the URL's host has to be on the list all the same")
    let hostTable: [(String, String?)] = [("https://asr.example.test:8443", "asr.example.test"), (" HTTPS://Asr.Example.TEST/x?y=1 ", "asr.example.test"), ("http://asr.example.test", nil),
                                          ("https://user@asr.example.test", nil), ("https://asr.example.test.", nil), ("https://10.0.0.1", nil), ("https://[::1]:8443", nil),
                                          ("asr.example.test", nil), ("", nil), ("https://", nil)]
    for (url, expected) in hostTable { check(C.remoteHost(of: url) == expected, "the host the pipeline would use for '\(url)': \(expected ?? "none")", "\(String(describing: C.remoteHost(of: url)))") }

    // the menu item for each verdict (pure)
    let hidden = M.connectItemState(for: .hidden)
    check(!hidden.visible && !hidden.enabled && hidden.tooltip == nil && hidden.title == "Connect to Company Server\u{2026}", "hidden: not visible, not enabled")
    let ready = M.connectItemState(for: .ready)
    check(ready.visible && ready.enabled && ready.title == "Connect to Company Server\u{2026}" && hasHangul(ready.tooltip ?? "") && ready.tooltip?.contains("앱은 보지 못해요") == true,
          "ready: 'Connect to Company Server…', enabled, the tooltip says the app never sees the credential", "\(ready)")
    let busy = M.connectItemState(for: .ready, busy: true)
    check(busy.visible && !busy.enabled && busy.title == "Connect to Company Server\u{2026} (연결 중)", "an enrollment under way: disabled, 'Connecting' in the title", "\(busy)")
    for why in [C.Denial.policyLocked, .laneDenied, .engineNotAllowed, .localOnlyLocked, .hostNotAllowed] {
        let item = M.connectItemState(for: .denied(why))
        check(item.visible && !item.enabled && item.title == "Connect to Company Server\u{2026} (조직 정책으로 막힘)" && item.tooltip == why.reasonText && hasHangul(why.reasonText) && why.reasonText.count <= 60,
              "closed by the policy (\(why)): visible, disabled, the reason in Korean as the tooltip", "\(item)")
    }
    var bad: [String] = []
    for verdict in [C.Availability.hidden, .denied(.laneDenied), .ready] { for flag in [false, true] {
        let item = M.connectItemState(for: verdict, busy: flag)
        if item.enabled != (verdict == .ready && !flag) { bad.append("enabled \(verdict) \(flag)") }
        if item.visible != (verdict != .hidden) { bad.append("visible \(verdict) \(flag)") }
    } }
    check(bad.isEmpty, "every verdict x busy: enabled only when ready and idle, visible except when hidden", bad.joined(separator: " | "))
    check(M.menuText(for: ControllerState(), now: Date(timeIntervalSince1970: 0)).lines.isEmpty && M.manualItemState(for: ControllerState()).enabled, "(the other menu items are as they were)")

    // ASR_REMOTE_URL as the app reads it: config.env with the policy layers
    let dir = base.appendingPathComponent("cs-config", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func env(_ text: String?) -> URL {
        let file = dir.appendingPathComponent("config-\(UUID().uuidString).env")
        if let text = text { try? text.write(to: file, atomically: true, encoding: .utf8) }
        return file
    }
    check(C.configuredRemoteURL(policy: owner, file: env(nil)) == nil, "no config.env: no ASR_REMOTE_URL")
    check(C.configuredRemoteURL(policy: owner, file: env("SELF_NAME=x\nASR_REMOTE_URL=\n")) == nil, "an empty ASR_REMOTE_URL is not set")
    check(C.configuredRemoteURL(policy: owner, file: env("ASR_REMOTE_URL=\"\(csURL)\"  # the company server\n")) == csURL, "ASR_REMOTE_URL in config.env (quotes and a trailing comment as the parser reads them)")
    let layered = loPolicy(["defaults": ["ASR_REMOTE_URL": "https://default.example.test"]])
    check(C.configuredRemoteURL(policy: layered, file: env("SELF_NAME=x\n")) == "https://default.example.test", "a policy default fills an unset key")
    check(C.configuredRemoteURL(policy: layered, file: env("ASR_REMOTE_URL=\(csURL)\n")) == csURL, "... and does not replace the user's value")
    let enforced = loPolicy(["enforced": ["ASR_REMOTE_URL": "https://corp.example.test"]])
    check(C.configuredRemoteURL(policy: enforced, file: env("ASR_REMOTE_URL=\(csURL)\n")) == "https://corp.example.test", "an enforced value of the policy wins over config.env")

    // SystemPolicyReader: the menu may ask on every opening; the policy files are read when they change
    var loads = 0
    var fingerprint = "a"
    var clock = Date(timeIntervalSince1970: 1_000)
    var next = csPolicy()
    let reader = SystemPolicyReader(load: { loads += 1; return next }, fingerprint: { fingerprint }, now: { clock })
    check(loads == 0, "the reader reads nothing until it is asked")
    _ = reader.current(); _ = reader.current(); _ = reader.current()
    check(loads == 1, "... then once, however often it is asked while the files are unchanged", "loads \(loads)")
    fingerprint = "b"; next = csPolicy(lane: "deny")
    check(reader.current() == next && loads == 2, "a changed fingerprint is one read", "loads \(loads)")
    fingerprint = "c"; next = locked
    check(reader.current().isLocked && loads == 3, "a policy that became unreadable is read")
    _ = reader.current(); _ = reader.current()
    check(loads == 3, "... a locked policy is not read again within a minute (its confirming read waits half a second)", "loads \(loads)")
    clock = clock.addingTimeInterval(SystemPolicyReader.lockedRecheckSeconds + 1)
    _ = reader.current()
    check(loads == 4, "... but after a minute it is", "loads \(loads)")

    // the personal install: a connector that is only asked what it is does nothing at all
    let w = CSWorld("cs-owner", in: base, policy: OrgPolicy.absent(), url: nil)
    check(w.connector.availability() == .hidden && w.connector.precheck() == .notConfigured, "the personal install: the connector says 'hidden' and 'not configured'")
    check(w.calls.isEmpty && w.versionAsked == 0 && w.posted.isEmpty && w.childLog == nil && !w.connector.isBusy,
          "... and starts nothing, asks for no version, posts nothing, writes no log")
    let ready1 = CSWorld("cs-ready", in: base, policy: csPolicy())
    check(ready1.connector.availability() == .ready && ready1.connector.precheck() == nil && ready1.calls.isEmpty, "a company Mac with an org consent: ready, and checking it starts no enrollment")
}

// MARK: S-CS-02: the code goes to stdin

private func testCSStdin(_ base: URL) {
    section("S-CS-02: the code reaches the child on stdin and never goes into argv, the environment or a log")
    typealias C = CompanyServerConnect
    let pipelineArgs = ["-m", "mcap", "asr-engines", "enroll", "remote", "--code-stdin"]

    // 1. what the connector hands to the runner
    struct Call { var python: URL; var args: [String]; var env: [String: String]; var cwd: URL; var stdin: Data; var timeout: TimeInterval }
    func recording(_ calls: Locked<[Call]>, status: Int32 = 0) -> C.Runner {
        return { python, args, env, cwd, input, timeout in
            calls.value.append(Call(python: python, args: args, env: env, cwd: cwd, stdin: input, timeout: timeout))
            return C.RunResult(launched: true, status: status, timedOut: false, output: csEnrolled)
        }
    }
    let parent = ["MCAP_CONFIG": "/tmp/x.env", "MCAP_SECURITY_BIN": "/tmp/fake/security", "ANTHROPIC_API_KEY": "nope", "PATH": "/evil"]
    for (name, policy) in [("no policy", OrgPolicy.absent()), ("a company policy", csPolicy())] {
        let w = LauncherWorld("cs-api-\(name.hasPrefix("no") ? "owner" : "company")", in: base)
        let calls = Locked<[Call]>([])
        let notifier = FakeNotifier()
        let connector = C(config: w.config, logDir: w.logs, policy: { policy }, remoteURL: { _ in csURL }, notifier: notifier, versionProbe: PipelineVersionProbe(),
                          versionRunner: { _, _ in "mcap 0.2.0" }, runner: recording(calls), timeout: 77, environment: parent)
        let done = Locked<C.Outcome?>(nil)
        connector.connect(code: csCode) { done.value = $0 }
        check(waitUntil(10) { done.value != nil } && done.value == .connected, "\(name): the runner is asked once and the enrollment ends connected", "\(String(describing: done.value))")
        guard let call = calls.value.first, calls.value.count == 1 else { check(false, "\(name): exactly one call", "\(calls.value.count)"); continue }
        check(call.args == pipelineArgs && !call.args.contains { $0.contains(csCode) }, "\(name): argv is exactly `-m mcap asr-engines enroll remote --code-stdin`, without the code", "\(call.args)")
        check(call.stdin == Data((csCode + "\n").utf8), "\(name): stdin is the code and one newline", "\(String(decoding: call.stdin, as: UTF8.self).debugDescription)")
        check(!call.env.values.contains { $0.contains(csCode) } && !call.env.keys.contains { $0.contains(csCode) && !$0.isEmpty }, "\(name): no environment variable carries the code")
        if policy.isEnforced {
            check(Set(call.env.keys) == launcherOwnKeys && call.env["PATH"] == "/usr/bin:/bin", "\(name): the managed environment: eight variables, no MCAP_* but the app's own names, PATH without ~/.local/bin and Homebrew", call.env.keys.sorted().joined(separator: " "))
        } else {
            check(Set(call.env.keys) == launcherOwnKeys.union(["MCAP_CONFIG", "MCAP_SECURITY_BIN"]) && call.env["MCAP_SECURITY_BIN"] == "/tmp/fake/security" && call.env["PATH"]?.hasSuffix("/usr/bin:/bin") == true,
                  "\(name): the personal environment as the launcher gives it (the test hooks forwarded), no ANTHROPIC_*", call.env.keys.sorted().joined(separator: " "))
        }
        check(call.python == w.config.pythonBin && call.cwd.path == w.config.projectDir.appendingPathComponent("pipeline").path && call.timeout == 77,
              "\(name): the configured python, in PROJECT_DIR/pipeline, with the connector's timeout")
        check(!logText().contains(csCode), "\(name): app.log does not contain the code")
        check(!notifier.posted.map { "\($0.title) \($0.subtitle) \($0.body) \($0.summary)" }.joined().contains(csCode), "\(name): no notification contains the code")
    }

    // 2. a real child process (the fake python records what it was given)
    var n = 0
    for (name, policy) in [("no policy", OrgPolicy.absent()), ("a company policy", csPolicy())] {
        n += 1
        let w = CSWorld("cs-stdin-\(n)", in: base, policy: policy)
        let outcome = w.connect()
        check(outcome == .connected, "\(name), real child: connected", "\(String(describing: outcome))")
        check(w.calls.components(separatedBy: "ARGS: ").count == 2 && w.calls.contains("ARGS: -m mcap asr-engines enroll remote --code-stdin\n"), "\(name): the child was started once with exactly that command line", w.calls)
        check(w.stdin == csCode + "\n", "\(name): the child read the code on its stdin", w.stdin.debugDescription)
        check(!w.calls.contains(csCode), "\(name): neither the child's argv nor its environment holds the code")
        check(w.calls.contains("CWD: \(realPath(w.world.config.projectDir.appendingPathComponent("pipeline")))"), "\(name): the child runs in PROJECT_DIR/pipeline")
        check(!w.calls.contains("ENV ANTHROPIC") && !w.calls.contains("ENV CLAUDE"), "\(name): no ANTHROPIC_* / CLAUDE_* reaches the child")
        if policy.isEnforced { check(mcapVariables(besidesTheAppNamesIn: w.calls).isEmpty && w.calls.contains("ENV PATH=/usr/bin:/bin\n"), "\(name): no MCAP_* variable but the app's own names, and the shorter PATH") }
        check(!logText().contains(csCode) && !(w.childLog ?? "").contains(csCode), "\(name): app.log and the child's log have no code", w.childLog ?? "(no log)")
    }
    let spaced = CSWorld("cs-stdin-trim", in: base, policy: OrgPolicy.absent())
    check(spaced.connect("  \(csCode)\n") == .connected && spaced.stdin == csCode + "\n", "a code with surrounding blanks or a newline is trimmed: one line, the code only", spaced.stdin.debugDescription)

    // 3. nothing but one printable line can reach stdin
    let hostile = ["", "   ", "line1\nline2", "\(csCode)\nINJECTED", "tab\tinside", String(repeating: "x", count: 65), "한글코드", "ctrl\u{07}char", "a\u{0}b"]
    let m = CSWorld("cs-stdin-malformed", in: base, policy: OrgPolicy.absent())
    var malformed = 0
    for text in hostile where m.connect(text) == .failed(.malformedCode) { malformed += 1 }
    check(malformed == hostile.count && m.calls.isEmpty && m.stdin.isEmpty, "empty, blank, multi-line, control-character, non-ASCII and 65-character codes are refused before the child is started (\(malformed) of \(hostile.count))", "\(malformed) \(m.calls)")
    check(m.posted.count == hostile.count && m.posted.allSatisfy { $0.subtitle == "등록 코드 형식이 맞지 않아요" && hasHangul($0.body) }, "... each with the Korean 'malformed' notification")
    check(m.connect(String(repeating: "x", count: 64)) == .connected && m.stdin == String(repeating: "x", count: 64) + "\n", "a 64-character code is accepted")
    check(C.normalizedCode("a b") == "a b" && C.normalizedCode(" ab ") == "ab" && C.normalizedCode("~!") == "~!" && C.normalizedCode("\u{7F}") == nil, "normalizedCode: inner blanks stay, edge blanks go, 0x20...0x7E only")
}

// MARK: S-CS-03: the app never reads the token

private func testCSToken(_ base: URL) {
    section("S-CS-03: the app never reads the token: a child that prints one (and the code) leaves neither in app.log, the child's log or a notification; no Keychain tool is called")
    typealias C = CompanyServerConnect
    guard let shim = fakeSecurityTool else { check(false, "the fake Keychain tool is installed"); return }
    let keychainCalls = shim.calls.count

    for (status, stream) in [(Int32(0), "stdout"), (Int32(1), "stderr")] {
        let w = CSWorld("cs-token-\(status)", in: base, policy: OrgPolicy.absent())
        w.setChild(status: status, output: "got @CODE@ and \(csToken)\nanother line with \(csToken) and sk-ant-api03-abcdefghijklmnop on \(stream)")
        let outcome = w.connect()
        check(outcome == (status == 0 ? .connected : .failed(.other)), "a child that prints the token and the code (exit \(status)): the outcome comes from the exit status", "\(String(describing: outcome))")
        let everything = [logText(), w.childLog ?? "", w.postedText].joined(separator: "\n")
        check(!everything.contains(csToken) && !everything.contains("Zk3Jx9QwErTy") && !everything.contains(csCode) && !everything.contains("sk-ant-api03-abcdefghijklmnop"),
              "... neither the token, the code nor a key is in app.log, the child's log or the notification (exit \(status))")
        check((w.childLog ?? "").contains("mcap1_\u{2026}") && (w.childLog ?? "").contains("***") && (w.childLog ?? "").contains("exit status \(status)"),
              "... the child's log says what happened with the secrets cut out", w.childLog ?? "(none)")
        check(w.posted.count == 1 && w.posted[0].kind == .waitingForServer && hasHangul(w.posted[0].title), "... and there is exactly one Korean notification")
    }
    check(shim.calls.count == keychainCalls, "the Keychain tool (`security`) was never called by the app during these runs", "\(shim.calls.count - keychainCalls) calls")

    // a child that printed a normal success text: the log keeps it (the host and the expiry are not secrets)
    let ok = CSWorld("cs-token-ok", in: base, policy: OrgPolicy.absent())
    _ = ok.connect()
    check((ok.childLog ?? "").contains("Enrolled: the token for asr.example.test:8443 is stored in the macOS Keychain") && (ok.childLog ?? "").contains("exit status 0"),
          "a normal answer is kept in LOG_DIR/company-server-connect.log for diagnosis", ok.childLog ?? "(none)")
    check(ok.postedText.contains("asr.example.test") == false && ok.postedText.contains("2027") == false, "... but the notification repeats nothing of it (no host, no date)")
    let overwritten = CSWorld("cs-token-overwrite", in: base, policy: OrgPolicy.absent())
    overwritten.setChild(status: 1, output: "FAILED: first attempt")
    _ = overwritten.connect()
    overwritten.setChild(status: 1, output: "FAILED: second attempt")
    _ = overwritten.connect()
    check((overwritten.childLog ?? "").contains("second attempt") && !(overwritten.childLog ?? "").contains("first attempt"), "the child's log holds the last attempt only (it does not grow)")

    // the scrubber itself
    check(C.scrubbed("a \(csCode) b \(csCode)", code: csCode) == "a *** b ***", "scrubbed: every occurrence of the code goes")
    check(C.scrubbed("x \(csToken) y mcap1_AAAA_BBBB-cc_dd z", code: csCode) == "x mcap1_\u{2026} y mcap1_\u{2026} z", "scrubbed: token-shaped text goes (url-safe characters included)")
    check(!C.scrubbed("key sk-ant-api03-abcdefghijklmnop", code: csCode).contains("abcdefghijklmnop"), "scrubbed: an API key goes too")
    check(C.scrubbed(String(repeating: "y", count: 20_000), code: csCode).count == 8_000 && C.scrubbed("text", code: "") == "text", "scrubbed: cut to 8000 characters; an empty code replaces nothing")
}

// MARK: S-CS-04: the Korean notifications

private func testCSNotifications() {
    section("S-CS-04: success and failure notifications: Korean, title 40 / subtitle 60 / body 100 characters, no host, code or child text; the contact only where the administrator can help")
    typealias C = CompanyServerConnect
    let long60 = String(repeating: "문", count: 60)
    let log = URL(fileURLWithPath: "/tmp/mcap-cs/company-server-connect.log")
    let outcomes: [(String, C.Outcome)] = [
        ("connected", .connected), ("notConfigured", .refused(.notConfigured)),
        ("laneDenied", .refused(.relayDenied(.laneDenied))), ("engineNotAllowed", .refused(.relayDenied(.engineNotAllowed))),
        ("policyLocked", .refused(.relayDenied(.policyLocked))), ("localOnlyLocked", .refused(.relayDenied(.localOnlyLocked))),
        ("runtimeUntrusted", .refused(.runtimeUntrusted("python: not owned by root"))), ("pipelineTooOld", .refused(.pipelineTooOld(have: "0.1.0", required: "0.2.0"))),
        ("pythonMissing", .refused(.pythonMissing)), ("busy", .refused(.busy)),
        ("malformedCode", .failed(.malformedCode)), ("codeRefused", .failed(.codeRefused)), ("throttled", .failed(.throttled)), ("unreachable", .failed(.unreachable)),
        ("notAllowed", .failed(.notAllowed)), ("noConsent", .failed(.noConsent)), ("hostNotAllowed", .refused(.relayDenied(.hostNotAllowed))),
        ("timedOut", .failed(.timedOut)), ("couldNotStart", .failed(.couldNotStart)), ("other", .failed(.other))]
    var all: [(String, AppNotification)] = []
    for contact in [nil, loContact, long60] as [String?] {
        for (name, outcome) in outcomes {
            for logFile in [nil, log] as [URL?] { all.append(("\(name) contact=\(contact ?? "nil") log=\(logFile != nil)", C.notification(for: outcome, contact: contact, logFile: logFile))) }
        }
    }
    let offenders = all.filter { _, n in
        n.title.isEmpty || n.subtitle.isEmpty || n.body.isEmpty || n.title.count > NotificationText.titleLimit || n.subtitle.count > NotificationText.subtitleLimit
            || n.body.count > NotificationText.bodyLimit || !hasHangul(n.title) || !hasHangul(n.subtitle) || !hasHangul(n.body)
    }.map { $0.0 }
    check(offenders.isEmpty, "all \(all.count) texts fit (title 40, subtitle 60, body 100), are Korean and are never empty", offenders.prefix(4).joined(separator: " | "))
    check(all.allSatisfy { _, n in n.kind == .waitingForServer && n.identifier == C.notificationIdentifier && !n.summary.isEmpty && n.summary.hasPrefix("company server enrollment: ") },
          "one identifier (a newer result replaces the older one), the server-status kind, an English line for app.log")
    let leaks = all.filter { _, n in
        let text = [n.title, n.subtitle, n.body, n.summary].joined(separator: " ")
        return text.contains("asr.example.test") || text.contains(csCode) || text.contains("mcap1_") || text.contains("FAILED") || text.contains("Enrolled")
    }.map { $0.0 }
    check(leaks.isEmpty, "no host, code, token or child text in any notification", leaks.prefix(4).joined(separator: " | "))
    check(all.filter { $0.0.hasPrefix("connected") }.allSatisfy { !$0.1.sound && $0.1.action == .none }, "success makes no sound and has no click target")
    check(all.filter { !$0.0.hasPrefix("connected") && !$0.0.hasPrefix("busy") }.allSatisfy { $0.1.sound }, "every failure and refusal makes a sound (the person is waiting for the answer)")

    let ok = C.notification(for: .connected, contact: loContact)
    check(ok.title == "회사 서버에 연결했어요" && ok.subtitle == "등록이 끝났어요" && ok.body == "인증 정보는 이 Mac의 키체인에만 저장돼요. 앱은 그 값을 읽지 않아요",
          "success: the design text (connected, credential only in the Keychain, the app does not read it)", ok.body)
    let refused = C.notification(for: .failed(.codeRefused), contact: loContact)
    check(refused.title == "회사 서버 연결 실패" && refused.subtitle == "등록 코드를 확인하세요" && refused.body == "코드가 맞지 않거나 이미 썼거나 만료됐어요. 관리자에게 새 코드를 요청하세요",
          "a refused code: wrong, used or expired, ask for a new one (no contact: the administrator is who to ask)", refused.body)
    let withContact: [C.Outcome] = [.refused(.relayDenied(.laneDenied)), .refused(.relayDenied(.policyLocked)), .refused(.pipelineTooOld(have: "0.1.0", required: "0.2.0")),
                                    .refused(.notConfigured), .refused(.runtimeUntrusted("python: not owned by root")), .failed(.notAllowed), .failed(.noConsent),
                                    .refused(.relayDenied(.hostNotAllowed))]
    let withoutContact: [C.Outcome] = [.connected, .failed(.codeRefused), .failed(.throttled), .failed(.unreachable), .failed(.malformedCode), .refused(.busy)]
    for (name, outcome) in outcomes where withContact.contains(outcome) {
        let with = C.notification(for: outcome, contact: loContact)
        check(with.body.hasSuffix("문의: \(loContact)") && with.body.count <= 100, "\(name): the support contact is named", with.body)
        let without = C.notification(for: outcome, contact: nil)
        check(!without.body.contains("문의") && with.body.hasPrefix(without.body), "\(name): without a contact no dangling '문의:', and the cause stays intact in front of it", without.body)
        let cut = C.notification(for: outcome, contact: long60)
        check(cut.body.hasPrefix(without.body) && cut.body.count <= 100, "\(name): a long contact is the part that is shortened", cut.body)
    }
    for (name, outcome) in outcomes where withoutContact.contains(outcome) {
        check(!C.notification(for: outcome, contact: loContact).body.contains("문의"), "\(name): no contact (the administrator who issued the code is who to ask)")
    }
    // a refusal for want of a CONSENT does not send the person to "the organisation policy": a Mac without a managed policy has no organisation to ask
    let noConsent = C.notification(for: .failed(.noConsent), contact: nil)
    let notAllowed = C.notification(for: .failed(.notAllowed), contact: nil)
    check(noConsent.subtitle == "이 서버에 대한 동의가 없어요" && noConsent.body.contains("동의") && noConsent.body.contains("mcap asr-engines consent remote") && !noConsent.body.contains("조직 정책"),
          "no consent: the text says the consent is missing and how to give it (not 'organisation policy')", noConsent.body)
    check(notAllowed.body.contains("동의") && notAllowed.body.contains("조직 정책") && notAllowed.body.contains("CA"), "the general 'not allowed' text names the policy, the consent and the CA", notAllowed.body)
    check(C.notification(for: .refused(.relayDenied(.hostNotAllowed)), contact: nil).body == C.Denial.hostNotAllowed.reasonText, "a host the policy does not list: the reason in Korean")
    check(C.notification(for: .failed(.other), contact: nil, logFile: log).action == .openLog(log.path) && C.notification(for: .failed(.other), contact: nil, logFile: nil).action == .none
          && C.notification(for: .failed(.codeRefused), contact: nil, logFile: log).action == .none, "an unknown failure points at the child's log when there is one; a known cause needs no log")

    // the kind of failure from what the child says (pipeline/mcap/cli.py, asr_remote.py), and what the exit status alone says
    func run(_ status: Int32, _ text: String, launched: Bool = true, timedOut: Bool = false) -> C.Outcome {
        return C.classify(C.RunResult(launched: launched, status: status, timedOut: timedOut, output: text), printed: text)
    }
    check(run(0, "") == .connected && run(0, "FAILED: whatever") == .connected, "exit 0 is connected, whatever was printed")
    let table: [(Int32, String, C.Failure)] = [
        (2, "error: the enrollment code is empty or malformed", .malformedCode),
        (1, "FAILED: the enrollment code was refused (wrong, already used or expired): ask the administrator for a new one", .codeRefused),
        (1, "FAILED: too many enrollment attempts from this Mac: wait a while and try again", .throttled),
        (1, "FAILED: the server could not be reached for enrollment (if the code was used up, ask the administrator for a new one)", .unreachable),
        (1, "FAILED: enrollment is not allowed for this server (policy-lane)", .notAllowed),
        (1, "FAILED: enrollment is not allowed for this server (policy-host)", .notAllowed),
        (1, "FAILED: enrollment is not allowed for this server (not-configured)", .notAllowed),
        (1, "FAILED: enrollment is not allowed for this server (no-consent)", .noConsent),
        (1, "FAILED: enrollment is not allowed for this server (consent-mismatch)", .noConsent),
        (1, "FAILED: enrollment is not allowed for this server (consent-expired)", .noConsent),
        (1, "FAILED: enrollment is not allowed for this server (consent-tampered)", .noConsent),
        (1, "FAILED: the private CA of the server is not bound (ASR_REMOTE_CA_FILE and the consent's ca_sha256)", .notAllowed),
        (1, "FAILED: the enrollment answer could not be used (ask the administrator for a new code)", .other),
        (1, "", .other), (3, "Traceback (most recent call last):\nValueError: bad thing", .other), (2, "usage: mcap [-h] ...", .other)]
    for (status, text, expected) in table { check(run(status, text) == .failed(expected), "exit \(status) '\(text.prefix(44))': \(expected)", "\(run(status, text))") }
    check(run(1, "FAILED: THE ENROLLMENT CODE WAS REFUSED") == .failed(.codeRefused), "the match ignores case")
    check(run(-1, "", launched: false) == .failed(.couldNotStart) && run(15, "x", timedOut: true) == .failed(.timedOut) && run(0, "", timedOut: true) == .failed(.timedOut),
          "a child that could not be started, and one stopped after the timeout, are their own kinds (a timeout is never 'connected')")
    check(C.Refusal.busy.logText.contains("already") && C.Refusal.pipelineTooOld(have: nil, required: "0.2.0").logText == "pipeline of unknown version is older than the required 0.2.0"
          && C.Refusal.relayDenied(.laneDenied).logText.contains("laneDenied"), "the English log texts of the refusals say what and why")
}

// MARK: S-CS-05: no effect without a policy-allowed relay

private func testCSNoRelay(_ base: URL) {
    section("S-CS-05: nothing is started without a policy-allowed relay, a trusted runtime and a new enough pipeline (no process, no version question, no log)")
    typealias C = CompanyServerConnect
    let locked = OrgPolicy.parse(Data("not json".utf8))
    let refusals: [(String, OrgPolicy, String?, C.Refusal)] = [
        ("no org consent and no ASR_REMOTE_URL", csPolicy(consent: false), nil, .notConfigured),
        ("the personal install without a server", OrgPolicy.absent(), nil, .notConfigured),
        ("lanes.asr_remote deny", csPolicy(lane: "deny"), csURL, .relayDenied(.laneDenied)),
        ("a lane that is not even named in a company policy", loPolicy(["asr": ["allowed_engines": ["remote"], "org_consents": [csConsent]]]), nil, .relayDenied(.laneDenied)),
        ("an engine list without remote", csPolicy(engines: ["whisper"]), csURL, .relayDenied(.engineNotAllowed)),
        ("local_only.locked", csPolicy(localOnlyLocked: true), csURL, .relayDenied(.localOnlyLocked)),
        // the fourth dimension, the one the pipeline's decision table asks last (A2 policy-host): a company policy without a host list allows none
        ("a company policy that omits asr.allowed_hosts", csPolicy(hosts: nil), csURL, .relayDenied(.hostNotAllowed)),
        ("an empty asr.allowed_hosts", csPolicy(hosts: []), csURL, .relayDenied(.hostNotAllowed)),
        ("an asr.allowed_hosts that names another server", csPolicy(hosts: ["other.example.test"]), csURL, .relayDenied(.hostNotAllowed)),
        ("a policy that cannot be read", locked, csURL, .relayDenied(.policyLocked))]
    var n = 0
    for (name, policy, url, expected) in refusals {
        n += 1
        let w = CSWorld("cs-norelay-\(n)", in: base, policy: policy, url: url)
        check(w.connector.precheck() == expected, "\(name): precheck says \(expected)", "\(String(describing: w.connector.precheck()))")
        let outcome = w.connect()
        check(outcome == .refused(expected), "\(name): connect is refused (\(expected))", "\(String(describing: outcome))")
        check(w.calls.isEmpty && w.stdin.isEmpty && w.versionAsked == 0 && w.childLog == nil, "\(name): no process was started (not even for its version) and no log was written", "calls: \(w.calls)")
        check(w.posted.count == 1 && hasHangul(w.posted[0].body) && w.posted[0].summary == "company server enrollment: not started", "\(name): the person gets one Korean 'not started' notification", w.postedText)
        check(!w.connector.isBusy, "\(name): the connector is idle again")
    }
    // no effect even with a code that is fine and a runtime that is fine
    let lane = CSWorld("cs-norelay-code", in: base, policy: csPolicy(lane: "deny"))
    _ = lane.connect(csCode)
    check(lane.stdin.isEmpty && !logText().contains(csCode), "the code of a refused attempt went nowhere")

    // the runtime of SPEC 18
    func root(_ name: String) -> String { base.appendingPathComponent(name, isDirectory: true).path }
    let userOwned: (URL) -> OrgPolicy.FileInfo? = { url in OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: url.path.contains("/bin") ? 501 : 0, mode: 0o755, size: 0) }
    let rootOwned: (URL) -> OrgPolicy.FileInfo? = { _ in OrgPolicy.FileInfo(isRegular: true, isSymlink: false, uid: 0, mode: 0o755, size: 0) }
    let bad = CSWorld("cs-trust-bad", in: base, policy: csPolicy(["runtime": ["root": root("cs-trust-bad")]]), fileInfo: userOwned)
    let badOutcome = bad.connect()
    if case .refused(.runtimeUntrusted(let why))? = badOutcome { check(why.hasPrefix("python:") && why.contains("not owned by root"), "an untrusted runtime (python in a user-owned folder): refused", why) }
    else { check(false, "an untrusted runtime: refused", "\(String(describing: badOutcome))") }
    check(bad.calls.isEmpty && bad.versionAsked == 0 && bad.stdin.isEmpty, "... python was not started, not even for its version")
    let good = CSWorld("cs-trust-good", in: base, policy: csPolicy(["runtime": ["root": root("cs-trust-good")]]), fileInfo: rootOwned)
    check(good.connect() == .connected && good.stdin == csCode + "\n", "a root-owned runtime inside runtime.root: the enrollment runs")

    // the contract: the enroll command is there from pipeline 0.2.0 (policy.min_pipeline_version raises the bar)
    let old = CSWorld("cs-old", in: base, policy: csPolicy(), version: "0.1.0")
    check(old.connect() == .refused(.pipelineTooOld(have: "0.1.0", required: "0.2.0")) && old.calls.isEmpty && old.versionAsked == 1, "pipeline 0.1.0: refused, python was asked for its version once and not started otherwise")
    let ownerOld = CSWorld("cs-old-owner", in: base, policy: OrgPolicy.absent(), version: "0.1.0")
    check(ownerOld.connect() == .refused(.pipelineTooOld(have: "0.1.0", required: "0.2.0")) && ownerOld.calls.isEmpty, "the personal install with ASR_REMOTE_URL and pipeline 0.1.0: refused too (the command needs 0.2.0)")
    let none = CSWorld("cs-old-none", in: base, policy: csPolicy(), version: nil)
    check(none.connect() == .refused(.pipelineTooOld(have: nil, required: "0.2.0")) && none.calls.isEmpty, "a python that gives no version: refused")
    let min3 = CSWorld("cs-old-min", in: base, policy: csPolicy(["min_pipeline_version": "0.3.0"]), version: "0.2.0")
    check(min3.connect() == .refused(.pipelineTooOld(have: "0.2.0", required: "0.3.0")), "policy.min_pipeline_version 0.3.0 with pipeline 0.2.0: refused, the required version is the policy's")
    let fine = CSWorld("cs-old-fine", in: base, policy: csPolicy(["min_pipeline_version": "0.2.0"]), version: "0.10.0")
    check(fine.connect() == .connected && fine.versionAsked == 1, "pipeline 0.10.0 (tuple compare): runs")
    _ = fine.connect()
    check(fine.versionAsked == 1, "... and the version is not asked again (cached by the probe)", "\(fine.versionAsked)")

    // python is not there
    let missing = CSWorld("cs-missing", in: base, policy: csPolicy())
    try? FileManager.default.removeItem(at: missing.world.config.pythonBin)
    check(missing.connect() == .refused(.pythonMissing) && missing.versionAsked == 0 && missing.posted.count == 1, "no python at PYTHON_BIN: refused with a Korean notification")
    let noPackage = CSWorld("cs-nopackage", in: base, policy: csPolicy())
    try? FileManager.default.removeItem(at: noPackage.world.config.projectDir.appendingPathComponent("pipeline/mcap"))
    check(noPackage.connect() == .refused(.pythonMissing) && noPackage.calls.isEmpty, "no pipeline package in PROJECT_DIR: refused")

    // the policy of the moment counts: the box is shared with the controller's watcher
    let box = PolicyBox(csPolicy())
    let live = LauncherWorld("cs-live", in: base, script: fakePythonEnrollScript)
    let liveNotifier = FakeNotifier()
    let liveLauncher = PipelineLauncher(config: live.config, logDir: live.logs, policy: box, versionProbe: PipelineVersionProbe(), versionRunner: { _, _ in "mcap 0.2.0" })
    let connector = liveLauncher.companyServerConnect(notifier: liveNotifier, remoteURL: { _ in csURL })
    check(connector.availability() == .ready, "(a connector over the launcher's policy box: ready)")
    box.policy = csPolicy(lane: "deny")
    check(connector.availability() == .denied(.laneDenied) && connector.precheck() == .relayDenied(.laneDenied), "the box changed (the controller's 60 s watcher): the verdict changed with it")
    let done = Locked<C.Outcome?>(nil)
    connector.connect(code: csCode) { done.value = $0 }
    check(waitUntil(10) { done.value != nil } && done.value == .refused(.relayDenied(.laneDenied)) && live.callsLog.isEmpty, "a click after the policy closed the lane starts nothing")
}

// MARK: S-CS-06: the child, end to end

private func testCSChild(_ base: URL) {
    section("S-CS-06: the real child process: success, every kind of failure, a hang, a child that never reads stdin, busy, a python that cannot start")
    typealias C = CompanyServerConnect
    let w = CSWorld("cs-child-ok", in: base, policy: csPolicy())
    check(w.connect() == .connected, "success: connected")
    check(w.posted.count == 1 && w.posted[0].title == "회사 서버에 연결했어요" && !w.posted[0].sound, "... one 'connected' notification", w.postedText)
    check(logText().contains("company server: enrollment started") && logText().contains("company server: enrollment finished (exit 0)"), "... app.log has the two lines (no code, no host)")
    check(!logText().contains("asr.example.test"), "... and no host name")
    check(w.connector.availability() == .ready && !w.connector.isBusy, "... the connector is ready again")

    let kinds: [(Int32, String, C.Failure)] = [
        (1, "FAILED: the enrollment code was refused (wrong, already used or expired): ask the administrator for a new one", .codeRefused),
        (1, "FAILED: too many enrollment attempts from this Mac: wait a while and try again", .throttled),
        (1, "FAILED: the server could not be reached for enrollment (if the code was used up, ask the administrator for a new one)", .unreachable),
        (1, "FAILED: enrollment is not allowed for this server (policy-lane)", .notAllowed),
        (1, "FAILED: enrollment is not allowed for this server (no-consent)", .noConsent),
        (2, "error: the enrollment code is empty or malformed", .malformedCode),
        (3, "Traceback (most recent call last):\nValueError: bad thing", .other)]
    var n = 0
    for (status, text, expected) in kinds {
        n += 1
        let k = CSWorld("cs-child-fail-\(n)", in: base, policy: OrgPolicy.absent())
        k.setChild(status: status, output: text + " [@CODE@]")
        let outcome = k.connect()
        check(outcome == .failed(expected), "exit \(status): \(expected)", "\(String(describing: outcome))")
        let note = k.posted.first
        check(k.posted.count == 1 && note?.title == "회사 서버 연결 실패" && hasHangul(note?.subtitle ?? "") && !k.postedText.contains("FAILED") && !k.postedText.contains("ValueError"),
              "exit \(status): one Korean failure notification, no text of the child", k.postedText)
        check((k.childLog ?? "").contains("exit status \(status)") && !(k.childLog ?? "").contains(csCode) && (k.childLog ?? "").contains("[***]"),
              "exit \(status): the child's log has the status and the output with the code cut out", k.childLog ?? "(none)")
    }

    // a child that never answers is stopped after the timeout
    let hang = CSWorld("cs-child-hang", in: base, policy: OrgPolicy.absent(), timeout: 1.5)
    hang.flag("hang")
    let started = Date()
    let outcome = hang.connect(wait: 30)
    check(outcome == .failed(.timedOut) && Date().timeIntervalSince(started) < 20, "a child that never answers is stopped after the timeout (1.5 s here)", "\(String(describing: outcome)) after \(Date().timeIntervalSince(started)) s")
    check(hang.posted.count == 1 && hang.posted[0].subtitle == "서버가 응답하지 않아요" && (hang.childLog ?? "").contains("stopped after"), "... with the Korean 'no answer' notification and a log line")

    // busy: a second click while one runs is answered at once
    let busy = CSWorld("cs-child-busy", in: base, policy: OrgPolicy.absent(), timeout: 3)
    busy.flag("hang")
    let first = Locked<C.Outcome?>(nil)
    busy.connector.connect(code: csCode) { first.value = $0 }
    check(busy.connector.isBusy, "while an enrollment runs the connector says it is busy")
    let second = Locked<C.Outcome?>(nil)
    busy.connector.connect(code: csCode) { second.value = $0 }
    check(waitUntil(2) { second.value != nil } && second.value == .refused(.busy) && first.value == nil, "a second call is refused at once (it does not wait for the first)", "\(String(describing: second.value)) \(String(describing: first.value))")
    check(waitUntil(30) { first.value != nil } && first.value == .failed(.timedOut) && !busy.connector.isBusy, "... the first one ends on its own, then the connector is idle")
    check(busy.calls.components(separatedBy: "ARGS: ").count == 2, "... and only one child was ever started", busy.calls)
    busy.setChild(status: 0, output: csEnrolled)
    try? FileManager.default.removeItem(at: busy.world.bin.appendingPathComponent("enroll-hang"))
    check(busy.connect() == .connected, "... and after that a new enrollment runs")

    // a child that exits without reading its stdin must not kill the app (SIGPIPE) or hang it
    let quick = CSWorld("cs-child-nostdin", in: base, policy: OrgPolicy.absent())
    quick.flag("nostdin")
    check(quick.connect() == .connected, "a child that exits at once without reading stdin: the app is alive and takes the exit status")

    // a python that cannot be started
    let broken = CSWorld("cs-child-broken", in: base, policy: OrgPolicy.absent())
    try? "#!/no/such/interpreter\n".write(to: broken.world.config.pythonBin, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.world.config.pythonBin.path)
    check(broken.connect() == .failed(.couldNotStart) && broken.posted.first?.subtitle == "Python을 시작하지 못했어요", "a python that cannot be launched: couldNotStart, with a Korean notification")

    // the connector's own queue: five enrollments one after the other all end (the busy flag is released every time)
    let again = CSWorld("cs-child-again", in: base, policy: OrgPolicy.absent())
    var ended = 0
    for _ in 0..<5 where again.connect() == .connected { ended += 1 }
    check(ended == 5 && again.posted.count == 5 && again.calls.components(separatedBy: "ARGS: ").count == 6, "five enrollments in a row: five children, five notifications, never 'busy'", "\(ended)")
}

// MARK: S-CS-08: the code can be pasted

private func testCSCodeField() {
    section("S-CS-08: the code prompt answers Cmd-V, C, X, A and Z itself (an accessory app has no Edit menu to route them)")
    typealias F = EnrollmentCodeField
    // (key, command, shift, option, control) -> the command, nil = not ours (the key is passed on)
    let table: [(String, Bool, Bool, Bool, Bool, F.EditCommand?)] = [
        ("v", true, false, false, false, .paste), ("V", true, false, false, false, .paste), ("c", true, false, false, false, .copy), ("x", true, false, false, false, .cut),
        ("a", true, false, false, false, .selectAll), ("z", true, false, false, false, .undo), ("z", true, true, false, false, .redo), ("Z", true, true, false, false, .redo),
        ("v", false, false, false, false, nil), ("v", false, true, false, false, nil), ("v", false, false, false, true, nil), ("v", false, false, true, false, nil),
        ("v", true, false, true, false, nil), ("v", true, false, false, true, nil), ("v", true, true, false, false, nil), ("z", true, true, true, false, nil),
        ("q", true, false, false, false, nil), ("w", true, false, false, false, nil), ("s", true, false, false, false, nil), ("\r", true, false, false, false, nil), ("", true, false, false, false, nil)]
    for (key, command, shift, option, control, expected) in table {
        let got = F.editCommand(key: key, command: command, shift: shift, option: option, control: control)
        let chord = (command ? "Command-" : "") + (shift ? "Shift-" : "") + (option ? "Option-" : "") + (control ? "Control-" : "") + (key == "\r" ? "return" : "'\(key)'")
        check(got == expected, "\(chord): \(expected.map { "\($0)" } ?? "not ours (passed on)")", "\(String(describing: got))")
    }
    check(F.editCommand(key: nil, command: true, shift: false, option: false, control: false) == nil, "a key without characters: not ours")
    // the prompt really uses the field, in the one place that builds it (a drift guard: a plain NSTextField would bring the problem back)
    guard let repo = csRepoRoot(), let menu = try? String(contentsOf: repo.appendingPathComponent("app/Sources/StatusMenu.swift"), encoding: .utf8) else {
        check(false, "app/Sources/StatusMenu.swift is readable from the working directory or the app")
        return
    }
    check(menu.contains("let field = EnrollmentCodeField(frame:") && !menu.contains("let field = NSTextField(frame:"), "askEnrollmentCode builds an EnrollmentCodeField, not a plain NSTextField")
    check(menu.contains("override func performKeyEquivalent(with event: NSEvent) -> Bool") && menu.contains("currentEditor() as? NSTextView") && menu.contains("editor.paste(nil)"),
          "the field answers the keys through its field editor (a key while the field is not being edited goes on to super)")
}

// MARK: S-CS-07: the pipeline's words

private func csRepoRoot() -> URL? {
    let env = ProcessInfo.processInfo.environment
    var candidates: [URL] = []
    if let explicit = env["MC_POLICY_FIXTURES"], !explicit.isEmpty {
        candidates.append(URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true).deletingLastPathComponent().deletingLastPathComponent())
    }
    candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    var exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    for _ in 0..<5 { exe.deleteLastPathComponent() }                      // <repo>/build/<short name>.app/Contents/MacOS/<short name> -> <repo>
    candidates.append(exe)
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pipeline/mcap/cli.py").path) }
}

/// The app starts the command and reads its messages by their words: when the pipeline changes them the person would only see 'unknown failure'.
private func testCSDriftGuard() {
    section("S-CS-07: the command line, the shape of the code and the messages the app relies on are still the pipeline's (pipeline/mcap/cli.py, asr_remote.py)")
    guard let repo = csRepoRoot() else {
        check(false, "the repo is found next to the working directory or the app (pipeline/mcap/cli.py)", "cwd \(FileManager.default.currentDirectoryPath)")
        return
    }
    let cli = (try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/cli.py"), encoding: .utf8)) ?? ""
    let remote = (try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/asr_remote.py"), encoding: .utf8)) ?? ""
    check(!cli.isEmpty && !remote.isEmpty, "cli.py and asr_remote.py are readable", repo.path)
    check(cli.contains("add_parser(\"asr-engines\"") && cli.contains("add_parser(\"enroll\"") && cli.contains("add_argument(\"engine\", choices=[\"remote\"])") && cli.contains("\"--code-stdin\""),
          "`asr-engines enroll remote --code-stdin` is a command of the pipeline")
    check(cli.contains("sys.stdin.readline()"), "--code-stdin reads ONE line from stdin (the app writes the code and a newline)")
    check(remote.contains(#"_CODE_SHAPE = re.compile(r"[\x21-\x7e]([\x20-\x7e]{0,62}[\x21-\x7e])?\Z")"#), "the code shape (printable ASCII, 1 to 64, no edge blanks) is the one CompanyServerConnect.normalizedCode checks")
    let words = ["the enrollment code is empty or malformed", "the enrollment code was refused", "too many enrollment attempts", "could not be reached for enrollment",
                 "enrollment is not allowed for this server", "the private ca of the server is not bound"]
    let text = (cli + remote).lowercased()
    for word in words { check(text.contains(word), "the pipeline still says '\(word)'") }
    // the reason in the brackets of "not allowed for this server (<reason>)" is the decision table's: the app tells a missing consent from the rest by it
    let policyPy = (try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/policy.py"), encoding: .utf8)) ?? ""
    check(cli.contains("enrollment is not allowed for this server ({decision.reason})"), "the refusal prints the reason of the decision in brackets")
    for reason in ["no-consent", "consent-mismatch", "consent-expired", "consent-tampered", "policy-host", "not-configured"] {
        check(policyPy.contains("\"\(reason)\""), "the decision table still has the reason '\(reason)'")
    }
    check(cli.contains("EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_NOT_FOUND, EXIT_BUSY = 0, 1, 2, 3, 75"), "exit codes: 0 ok, 1 failed, 2 usage (the app reads 0 as connected, anything else by the message)")
}

// =====================================================================================
// Calendar auto-start (CalendarWatcher.swift, OFFLINE_AUTOSTART): S-CW-01 ... S-CW-12.
//
// Device-free like everything above: the real SessionController with fake recorders and a virtual clock, a fake command (a closure that
// answers with a JSON text, or a fake python script for the real child process), a virtual presence provider, a fake notifier, a store in a temp
// folder. No Google, no Keychain, no network, no real calendar. The event title below is a canary: it must never reach app.log, the store file or
// a menu text.
// =====================================================================================

private let cwCanaryTitle = "Confidential board strategy"
private let cwT0: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 0, second: 0)) ?? Date()

/// `minutes` after 14:00:00 of the harness day.
private func cwAt(_ minutes: Double) -> Date { cwT0.addingTimeInterval(minutes * 60) }

private func cwAuto(_ mutate: (inout OfflineAutostartSettings) -> Void = { _ in }) -> OfflineAutostartSettings {
    var s = OfflineAutostartSettings()
    s.mode = .auto
    mutate(&s)
    return s
}

private func cwEvent(_ id: String, title: String = cwCanaryTitle, start: Double, end: Double, allDay: Bool = false, declined: Bool = false,
                     type: String = "default", guests: Int = 2, conference: Bool = false) -> CalendarEvent {
    return CalendarEvent(id: id, title: title, start: cwAt(start), end: cwAt(end), allDay: allDay, declined: declined, eventType: type, guests: guests, hasConference: conference)
}

private func cwJSON(_ e: CalendarEvent) -> [String: Any] {
    return ["id": e.id, "title": e.title, "start": ShellUtil.iso8601(e.start), "end": ShellUtil.iso8601(e.end), "all_day": e.allDay, "declined": e.declined,
            "event_type": e.eventType, "guests": e.guests, "has_conference": e.hasConference, "location": ""]
}

private func cwText(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// The answer of `gcal upcoming` (ok: true).
private func cwAnswer(_ events: [CalendarEvent], now: Date = cwT0) -> String {
    return cwText(["schema": 1, "ok": true, "now": ShellUtil.iso8601(now), "events": events.map { cwJSON($0) }])
}

/// The answer of `gcal upcoming` (ok: false).
private func cwError(_ code: String, _ message: String = "short message") -> String {
    return cwText(["schema": 1, "ok": false, "error": code, "message": message])
}

private func cwResult(_ output: String, status: Int32 = 0) -> CalendarCommandResult {
    return CalendarCommandResult(launched: true, status: status, timedOut: false, output: output)
}

/// A fake `gcal upcoming`: answers with `output` (or `override`), records every call with the virtual time and the thread it ran on.
private final class CWRunner {
    private let lock = NSLock()
    private var storedOutput = cwAnswer([])
    private var storedOverride: CalendarCommandResult?
    private var storedCalls: [(from: Int, to: Int, at: Date, onMain: Bool)] = []
    private var inFlight = 0
    private var storedMax = 0
    var clock: () -> Date = { Date() }
    var delay: TimeInterval = 0
    var onCall: (() -> Void)?
    /// A real command (the fake python of S-CW-11) instead of the canned answer.
    var real: ((Int, Int) -> CalendarCommandResult)?

    var output: String { get { lock.lock(); defer { lock.unlock() }; return storedOutput } set { lock.lock(); storedOutput = newValue; lock.unlock() } }
    var override: CalendarCommandResult? { get { lock.lock(); defer { lock.unlock() }; return storedOverride } set { lock.lock(); storedOverride = newValue; lock.unlock() } }
    var calls: [(from: Int, to: Int, at: Date, onMain: Bool)] { lock.lock(); defer { lock.unlock() }; return storedCalls }
    var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return storedMax }
    /// Seconds after 14:00:00 of every call.
    var callTimes: [Int] { calls.map { Int($0.at.timeIntervalSince(cwT0).rounded()) } }

    func run(_ from: Int, _ to: Int) -> CalendarCommandResult {
        lock.lock()
        inFlight += 1
        storedMax = max(storedMax, inFlight)
        storedCalls.append((from, to, clock(), Thread.isMainThread))
        let result = storedOverride ?? cwResult(storedOutput)
        let realRun = real
        lock.unlock()
        if let realRun = realRun {
            let answer = realRun(from, to)
            lock.lock(); inFlight -= 1; lock.unlock()
            return answer
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        onCall?()
        lock.lock(); inFlight -= 1; lock.unlock()
        return result
    }
}

/// The real controller (fake recorder, virtual clock) with a watcher on top: everything the app wires together in App.swift, minus the timer.
private final class CWWorld {
    let h: Harness
    let runner = CWRunner()
    let notifier = FakeNotifier()
    let store: CalendarStartedStore
    let watcher: CalendarWatcher
    private let presenceBox = Locked<CalendarPresence>(CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 5))
    private let statusBox = Locked<[CalendarStatus]>([])
    private let scheduledBox = Locked<[TimeInterval]>([])

    var presence: CalendarPresence { get { presenceBox.value } set { presenceBox.value = newValue } }
    var statuses: [CalendarStatus] { statusBox.value }
    var scheduled: [TimeInterval] { scheduledBox.value }
    var support: URL { h.config.supportDir }
    var rec: FakeRecorder? { h.current }

    init(_ name: String, in base: URL, settings: OfflineAutostartSettings = cwAuto(), policy: OrgPolicy = OrgPolicy.absent(), privacy: PrivacySettings? = nil,
         reader: (() -> OrgPolicy)? = nil, store existing: CalendarStartedStore? = nil, beat: (delay: TimeInterval, interval: TimeInterval)? = nil,
         configure: (inout AppConfig) -> Void = { _ in }) {
        let harness = Harness(name, in: base, policy: Harness.PolicyInputs(policy: policy, privacy: privacy, policyReader: reader)) { c in
            c.notifyRecording = true
            configure(&c)
        }
        h = harness
        let virtual = harness.clock
        store = existing ?? CalendarStartedStore(supportDir: harness.config.supportDir, clock: { virtual.now })
        let r = runner
        r.clock = { virtual.now }
        let box = presenceBox, statuses = statusBox, scheduled = scheduledBox
        watcher = CalendarWatcher(settings: settings, control: harness.controller, runner: { from, to in r.run(from, to) },
                                  presence: { box.value }, clock: { virtual.now }, store: store, notifier: notifier,
                                  logFile: URL(fileURLWithPath: "/tmp/mcap-cw-app.log"), deliver: { work in work() },
                                  schedule: { delay, _ in scheduled.value.append(delay) }, beatDelay: beat?.delay ?? 5, beatInterval: beat?.interval ?? CalendarWatcher.pollSeconds)
        watcher.onState = { statuses.value.append($0) }
        watcher.attach()                       // what start() does besides the timer: the test drives the beat itself
    }

    /// One beat of the watcher now.
    func tickNow() { watcher.tick(); h.sync(); watcher.flush() }

    /// `seconds` of virtual time in `step`-second beats: the controller's housekeeping and the watcher's tick.
    func advance(_ seconds: Int, step: Int = 60) {
        var done = 0
        while done < seconds {
            h.clock.advance(TimeInterval(step))
            done += step
            h.controller.tick()
            watcher.tick()
            h.sync()
            watcher.flush()
        }
    }

    /// Advance to `minutes` after 14:00:00 in one-minute beats.
    func advance(toMinute minutes: Int) {
        let target = cwAt(Double(minutes))
        let seconds = Int(target.timeIntervalSince(h.clock.now).rounded())
        if seconds > 0 { advance(seconds) }
    }
}

// MARK: S-CW-01: the keys

private func testCWConfig(_ base: URL) {
    section("S-CW-01: OFFLINE_* keys: off by default, a typo never switches it on, invalid numbers keep the defaults")
    let src = "selftest"
    let d = OfflineAutostartSettings.build(from: [:], source: src)
    check(d == OfflineAutostartSettings.defaults && d.mode == .off && !d.isOn, "no key: off")
    check(d.startBeforeMinutes == 2 && d.startAfterMinutes == 15 && d.stopAfterEndMinutes == 10 && d.idleMaxMinutes == 5 && d.requireGuests && d.minMinutes == 10 && d.maxMinutes == 240,
          "the defaults: 2 / 15 / 10 / 5 minutes, another attendee needed, events of 10 to 240 minutes")
    check(OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": "auto"], source: src).isOn, "OFFLINE_AUTOSTART=auto: on")
    check(OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": " AUTO "], source: src).isOn, "... any case, blanks around it do not matter")
    check(!OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": "off"], source: src).isOn && !OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": ""], source: src).isOn, "off and an empty value: off")
    let before = logCount("OFFLINE_AUTOSTART=")
    for typo in ["1", "on", "true", "yes", "automatic", "aut0"] {
        check(!OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": typo], source: src).isOn, "OFFLINE_AUTOSTART=\(typo): not a mode, stays off")
    }
    check(logCount("OFFLINE_AUTOSTART=") - before == 6 && logText().contains("calendar auto-start stays off"), "... and every typo is said in app.log")

    let custom = OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": "auto", "OFFLINE_START_BEFORE_MINUTES": "5", "OFFLINE_START_AFTER_MINUTES": "0", "OFFLINE_STOP_AFTER_END_MINUTES": "30",
                                                       "OFFLINE_IDLE_MAX_MINUTES": "12", "OFFLINE_REQUIRE_GUESTS": "0", "OFFLINE_MIN_MINUTES": "20", "OFFLINE_MAX_MINUTES": "90"], source: src)
    check(custom.startBeforeMinutes == 5 && custom.startAfterMinutes == 0 && custom.stopAfterEndMinutes == 30 && custom.idleMaxMinutes == 12 && !custom.requireGuests
          && custom.minMinutes == 20 && custom.maxMinutes == 90, "every number and OFFLINE_REQUIRE_GUESTS=0 are read")
    let bad = OfflineAutostartSettings.build(from: ["OFFLINE_START_BEFORE_MINUTES": "abc", "OFFLINE_START_AFTER_MINUTES": "-1", "OFFLINE_STOP_AFTER_END_MINUTES": "1000", "OFFLINE_IDLE_MAX_MINUTES": "0",
                                                    "OFFLINE_MIN_MINUTES": "2.5", "OFFLINE_MAX_MINUTES": "99999", "OFFLINE_REQUIRE_GUESTS": "maybe"], source: src)
    check(bad.startBeforeMinutes == 2 && bad.startAfterMinutes == 15 && bad.stopAfterEndMinutes == 10 && bad.idleMaxMinutes == 5 && bad.minMinutes == 10 && bad.maxMinutes == 240 && bad.requireGuests,
          "not a number, negative, out of range, zero idle limit, a fraction, a typo in the guest switch: the defaults stay (the guest check stays on)")
    check(OfflineAutostartSettings.build(from: ["OFFLINE_MIN_MINUTES": "300", "OFFLINE_MAX_MINUTES": "100"], source: src).minMinutes == 10
          && OfflineAutostartSettings.build(from: ["OFFLINE_MIN_MINUTES": "300", "OFFLINE_MAX_MINUTES": "100"], source: src).maxMinutes == 240, "MIN above MAX: both defaults")
    check(OfflineAutostartSettings.build(from: ["OFFLINE_MIN_MINUTES": "4.0"], source: src).minMinutes == 4, "a whole number written with a decimal point is accepted")

    // from a file, like ZOOM_STRONG_SOCKETS: the comment rules of config.env, a missing file, no policy layers needed
    let dir = base.appendingPathComponent("cw-config", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("config.env")
    try? "OFFLINE_AUTOSTART=auto   # on\nOFFLINE_IDLE_MAX_MINUTES=7\n".write(to: file, atomically: true, encoding: .utf8)
    let fromFile = OfflineAutostartSettings.load(from: file, policy: OrgPolicy.absent())
    check(fromFile.isOn && fromFile.idleMaxMinutes == 7 && fromFile.startAfterMinutes == 15, "load(from:): read from config.env")
    check(OfflineAutostartSettings.load(from: dir.appendingPathComponent("missing.env"), policy: OrgPolicy.absent()) == OfflineAutostartSettings.defaults, "a missing config.env: off")
    check(OfflineAutostartSettings.defaults.summary.contains("off") && fromFile.summary.contains("auto") && fromFile.summary.contains("idle limit 7 min"), "the one-line summary says what is in force")
    check(!PolicyLayers.whitelist.contains("OFFLINE_AUTOSTART"), "(a company policy cannot switch the feature on: the keys are not on the layer whitelist)")
}

// MARK: S-CW-02: the pure rules

private func testCWRules() {
    section("S-CW-02: CalendarRules.decide: every qualifying and skipping rule, the window edges, presence (pure: injected clock and presence)")
    let ok = CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 5)
    let asked = Locked<Int>(0)
    func decide(_ e: CalendarEvent, at minutes: Double = 10, _ settings: OfflineAutostartSettings = cwAuto(), recording: Bool = false, userStopped: Set<String> = [],
                started: Set<String> = [], resumable: Set<String> = [], presence p: CalendarPresence = CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 5)) -> CalendarDecision {
        return CalendarRules.decide(e, now: cwAt(minutes), settings: settings, presence: { asked.value += 1; return p }, recordingActive: recording, userStopped: userStopped, started: started,
                                    resumable: resumable)
    }
    let e = cwEvent("e1", start: 10, end: 40)
    check(decide(e) == .start, "a 30 minute event with two attendees, at its start, somebody at the Mac: start")
    asked.value = 0
    _ = decide(e)
    check(asked.value == 1, "the presence provider is asked once for a start")

    // the event itself
    check(decide(cwEvent("e", start: 10, end: 40, allDay: true)) == .skip(.allDay), "all-day: skip")
    check(decide(cwEvent("e", start: 10, end: 40, declined: true)) == .skip(.declined), "declined: skip")
    for type in ["focusTime", "outOfOffice", "workingLocation", "birthday", "fromGmail", "somethingNew"] {
        check(decide(cwEvent("e", start: 10, end: 40, type: type)) == .skip(.eventType(type)), "event_type \(type): skip")
    }
    check(decide(cwEvent("e", start: 10, end: 40, conference: true)) == .skip(.hasConference), "a video-conference link: skip")
    check(decide(cwEvent("e", start: 10, end: 40, guests: 0)) == .skip(.noGuests), "no other attendee with OFFLINE_REQUIRE_GUESTS=1: skip")
    check(decide(cwEvent("e", start: 10, end: 40, guests: 0), cwAuto { $0.requireGuests = false }) == .start, "... and start with OFFLINE_REQUIRE_GUESTS=0")
    check(decide(cwEvent("e", start: 10, end: 40, guests: 1)) == .start, "one other attendee is enough")
    check(decide(cwEvent("e", start: 40, end: 10), at: 40) == .skip(.badTimes) && decide(cwEvent("e", start: 10, end: 10)) == .skip(.badTimes), "an end that is not after the start: skip")
    check(decide(cwEvent("e", start: 10, end: 19)) == .skip(.tooShort) && decide(cwEvent("e", start: 10, end: 20)) == .start, "length: 9 minutes is too short, exactly 10 is fine")
    check(decide(cwEvent("e", start: 10, end: 10 + 241)) == .skip(.tooLong) && decide(cwEvent("e", start: 10, end: 10 + 240)) == .start, "length: 241 minutes is too long, exactly 240 is fine")
    check(decide(cwEvent("e", start: 10, end: 30), cwAuto { $0.minMinutes = 30 }) == .skip(.tooShort) && decide(cwEvent("e", start: 10, end: 100), cwAuto { $0.maxMinutes = 60 }) == .skip(.tooLong),
          "OFFLINE_MIN_MINUTES / OFFLINE_MAX_MINUTES move the limits")

    // the window: [start - 2 min, start + 15 min] and before the end
    let s1 = 1.0 / 60
    check(decide(e, at: 8) == .start && decide(e, at: 8 - s1) == .skip(.notYet), "window start: exactly 2 minutes before is in, one second earlier is not yet")
    check(decide(e, at: 25) == .start && decide(e, at: 25 + s1) == .skip(.windowPassed), "window end: exactly 15 minutes after the start is in, one second later the window has passed")
    check(decide(e, at: 0) == .skip(.notYet) && decide(e, at: 30) == .skip(.windowPassed) && decide(e, at: 40) == .skip(.ended) && decide(e, at: 90) == .skip(.ended), "far before, late, at the end and long after it")
    let short = cwEvent("s", start: 10, end: 20)
    check(decide(short, at: 19.9) == .start && decide(short, at: 20) == .skip(.ended), "a 10 minute event: inside the 15 minute window but over at its end: skip")
    check(decide(e, at: 10 - 0.0001, cwAuto { $0.startBeforeMinutes = 0 }) == .skip(.notYet) && decide(e, at: 10, cwAuto { $0.startBeforeMinutes = 0 }) == .start, "OFFLINE_START_BEFORE_MINUTES=0: not before the start")
    check(decide(e, at: 10 + s1, cwAuto { $0.startAfterMinutes = 0 }) == .skip(.windowPassed) && decide(e, at: 10, cwAuto { $0.startAfterMinutes = 0 }) == .start, "OFFLINE_START_AFTER_MINUTES=0: not after the start")
    check(decide(e, at: 5, cwAuto { $0.startBeforeMinutes = 5 }) == .start && decide(e, at: 28, cwAuto { $0.startAfterMinutes = 20 }) == .start, "the window follows both settings")

    // what already happened
    check(decide(e, userStopped: ["e1"]) == .skip(.userStopped), "the user stopped this event's recording: skip")
    check(decide(e, started: ["e1"]) == .skip(.alreadyStarted), "this event id was started before: skip")
    check(decide(e, recording: true) == .skip(.alreadyRecording), "a recording is running (any platform): skip")
    check(decide(e, userStopped: ["e1"], started: ["e1"]) == .skip(.userStopped) && decide(e, recording: true, started: ["e1"]) == .skip(.alreadyStarted), "the reason of a stop by hand wins over 'already started', that wins over 'already recording'")
    check(decide(e, userStopped: ["other"], started: ["other"]) == .start, "another event's id does not matter")

    // an interrupted recording (sleep, quit) is picked up again while the event runs: no start window, no 'already started'; everything else still counts
    check(decide(e, at: 30, started: ["e1"], resumable: ["e1"]) == .start && decide(e, at: 39, resumable: ["e1"]) == .start,
          "resumable: 30 minutes after the start (window passed) and in the store: start, until the end of the event")
    check(decide(e, at: 30, resumable: ["other"]) == .skip(.windowPassed) && decide(e, at: 30, started: ["e1"]) == .skip(.windowPassed), "... only for the id that was interrupted")
    check(decide(e, at: 40, resumable: ["e1"]) == .skip(.ended) && decide(e, at: 41, started: ["e1"], resumable: ["e1"]) == .skip(.ended), "... but never at or after the end of the event")
    check(decide(e, at: 30, userStopped: ["e1"], resumable: ["e1"]) == .skip(.userStopped) && decide(e, at: 30, recording: true, resumable: ["e1"]) == .skip(.alreadyRecording),
          "... not over a stop by hand, not over another recording")
    check(decide(e, at: 30, resumable: ["e1"], presence: CalendarPresence(screenLocked: true, onConsole: true, secondsSinceInput: 1)) == .skip(.screenLocked)
          && decide(e, at: 30, resumable: ["e1"], presence: CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 301)) == .skip(.idle), "... and only with somebody at the Mac")
    check(decide(cwEvent("e1", start: 10, end: 40, conference: true), at: 30, resumable: ["e1"]) == .skip(.hasConference) && decide(cwEvent("e1", start: 10, end: 40, declined: true), at: 30, resumable: ["e1"]) == .skip(.declined),
          "... and the event must still qualify (a conference link, a decline)")

    // presence
    check(decide(e, presence: CalendarPresence(screenLocked: true, onConsole: true, secondsSinceInput: 1)) == .skip(.screenLocked), "screen locked: skip")
    check(decide(e, presence: CalendarPresence(screenLocked: false, onConsole: false, secondsSinceInput: 1)) == .skip(.notOnConsole), "another user is on the console: skip")
    check(decide(e, presence: CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 300)) == .start && decide(e, presence: CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 300.5)) == .skip(.idle),
          "the last input exactly OFFLINE_IDLE_MAX_MINUTES ago is still fine, a bit longer is idle")
    check(decide(e, cwAuto { $0.idleMaxMinutes = 1 }, presence: CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 61)) == .skip(.idle), "OFFLINE_IDLE_MAX_MINUTES moves the limit")
    check(decide(e, presence: CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: nil)) == .skip(.idleUnknown), "an input age that cannot be told counts as away")
    check(decide(e, presence: CalendarPresence(screenLocked: true, onConsole: true, secondsSinceInput: 9999)) == .skip(.screenLocked), "locked and idle: the lock is named")
    asked.value = 0
    for bad in [cwEvent("e", start: 10, end: 40, allDay: true), cwEvent("e", start: 10, end: 40, conference: true), cwEvent("e", start: 10, end: 40, guests: 0)] { _ = decide(bad) }
    _ = decide(e, at: 0); _ = decide(e, started: ["e1"]); _ = decide(e, recording: true)
    check(asked.value == 0, "the presence provider is not asked while anything cheaper already says no")
    check(CalendarSkip.eventType("focusTime").code == "event-type:focusTime" && CalendarSkip.idle.code == "idle" && CalendarSkip.userStopped.code == "stopped-by-user", "stable codes for app.log")

    // choose: the earliest qualifying event; the presence provider once
    let late = cwEvent("late", start: 12, end: 50), early = cwEvent("early", start: 9, end: 45), blocked = cwEvent("conf", start: 10, end: 40, conference: true)
    asked.value = 0
    let sel = CalendarRules.choose([late, blocked, early], now: cwAt(10), settings: cwAuto(), presence: { asked.value += 1; return ok }, recordingActive: false, userStopped: [], started: [])
    check(sel.start?.id == "early" && sel.skips["late"] == .alreadyRecording && sel.skips["conf"] == .hasConference && sel.skips["early"] == nil, "choose: the earliest qualifying event starts, a second one waits, the others say why",
          "\(String(describing: sel.start?.id)) \(sel.skips)")
    check(asked.value == 1, "choose asks for the presence once for all events", "\(asked.value)")
    let busy = CalendarRules.choose([early], now: cwAt(10), settings: cwAuto(), presence: { ok }, recordingActive: true, userStopped: [], started: [])
    check(busy.start == nil && busy.skips["early"] == .alreadyRecording, "choose: nothing starts while a recording runs")
    check(CalendarRules.choose([], now: cwAt(10), settings: cwAuto(), presence: { ok }, recordingActive: false, userStopped: [], started: []) == CalendarRules.Selection(start: nil, skips: [:]), "choose: no events, nothing")
}

// MARK: S-CW-03: the answer of the command

private func testCWParser() {
    section("S-CW-03: the answer of `gcal upcoming`: success, every ok:false error, malformed text, timeout, crash, refusal")
    func parse(_ text: String, status: Int32 = 0) -> CalendarPoll { CalendarCommandParser.parse(cwResult(text, status: status)) }
    let a = cwEvent("evt-a", start: 10, end: 40), b = cwEvent("evt-b", title: "", start: 50, end: 80, guests: 0, conference: true)
    if case .events(let list, let dropped) = parse(cwAnswer([a, b])) {
        check(dropped == 0 && list.count == 2 && list[0].id == "evt-a" && list[0].title == cwCanaryTitle && abs(list[0].start.timeIntervalSince(cwAt(10))) < 1 && abs(list[0].end.timeIntervalSince(cwAt(40))) < 1
              && list[0].guests == 2 && !list[0].hasConference && list[0].eventType == "default" && !list[0].allDay && !list[0].declined && list[1].title.isEmpty && list[1].hasConference && list[1].guests == 0,
              "a good answer: every field is read")
    } else { check(false, "a good answer is parsed") }
    if case .events(let none, let dropped) = parse(cwAnswer([])) { check(none.isEmpty && dropped == 0, "an empty list is fine") } else { check(false, "an empty list is fine") }
    if case .events(let list, _) = parse(#"{"schema":1,"ok":true,"events":[{"id":"z1","title":"x","start":"2026-10-07T05:10:00Z","end":"2026-10-07T05:40:00.000+00:00","all_day":false,"declined":false,"event_type":"default","guests":1,"has_conference":false}]}"#) {
        check(list.count == 1 && list[0].end.timeIntervalSince(list[0].start) == 1800, "ISO 8601 with Z and with fractional seconds and offsets")
    } else { check(false, "ISO 8601 variants are parsed") }

    func problem(_ poll: CalendarPoll) -> CalendarProblem? { if case .problem(let p) = poll { return p } else { return nil } }
    for (code, kind) in [("not_configured", CalendarProblemKind.notConfigured), ("auth_required", .authRequired), ("network", .network), ("lane_denied", .laneDenied), ("policy", .policy), ("api_error", .apiError)] {
        let p = problem(parse(cwError(code, "msg \(code)")))
        check(p?.kind == kind && p?.message == "msg \(code)", "ok:false \(code): \(kind)", "\(String(describing: p))")
    }
    check(problem(parse(cwError("something_new", "x")))?.kind == .apiError && problem(parse(cwError("timeout", "x")))?.kind == .apiError && problem(parse(cwError("")))?.kind == .apiError,
          "an error code that is not in the contract: api_error (a code of the app's own is not accepted from the command)")
    let longMessage = String(repeating: "x", count: 500) + "\u{1B}[31m"
    check((problem(parse(cwError("network", longMessage)))?.message.count ?? 999) <= 120, "a long message is clipped (no content, no secrets, no escape sequence in the menu)")
    check(!(problem(parse(cwError("network", "a\u{1B}[31mb\u{202E}c")))?.message.unicodeScalars.contains(where: NotificationText.isStrippedScalar) ?? true), "control and bidi characters are stripped from the message")

    for (name, text) in [("garbage", "not json at all"), ("empty", ""), ("only blanks", "  \n "), ("an array", "[1,2]"), ("truncated", #"{"schema":1,"ok":tr"#),
                         ("two objects", cwAnswer([]) + cwAnswer([])), ("trailing text", cwAnswer([]) + "\nDone"), ("a number", "42")] {
        check(problem(parse(text))?.kind == .malformed, "malformed output (\(name)): an error state, no crash")
    }
    check(problem(parse(#"{"schema":2,"ok":true,"events":[]}"#))?.kind == .malformed && problem(parse(#"{"ok":true,"events":[]}"#))?.kind == .malformed
          && problem(parse(#"{"schema":true,"ok":true,"events":[]}"#))?.kind == .malformed, "an unknown or missing schema: malformed")
    check(problem(parse(#"{"schema":1,"events":[]}"#))?.kind == .malformed && problem(parse(#"{"schema":1,"ok":"yes","events":[]}"#))?.kind == .malformed
          && problem(parse(#"{"schema":1,"ok":1,"events":[]}"#))?.kind == .malformed, "no ok flag, or one that is not a boolean: malformed")
    check(problem(parse(#"{"schema":1,"ok":true}"#))?.kind == .malformed && problem(parse(#"{"schema":1,"ok":true,"events":{}}"#))?.kind == .malformed, "ok without an event list: malformed")

    // an event that lacks a field of the contract is dropped and counted (fail closed), the others stay
    let good = cwJSON(a)
    func without(_ key: String) -> [String: Any] { var o = good; o.removeValue(forKey: key); return o }
    func with(_ key: String, _ value: Any) -> [String: Any] { var o = good; o[key] = value; return o }
    let damaged: [[String: Any]] = [without("id"), without("start"), without("end"), without("all_day"), without("declined"), without("has_conference"), without("event_type"), without("guests"),
                                    with("id", ""), with("start", "tomorrow"), with("guests", true), with("guests", -1), with("guests", 1.5), with("has_conference", 0), with("declined", "no"),
                                    with("id", "a\u{1B}b"), with("event_type", 7)]
    if case .events(let list, let dropped) = parse(cwText(["schema": 1, "ok": true, "events": damaged + [good]])) {
        check(list.count == 1 && list[0].id == "evt-a" && dropped == damaged.count, "events lacking or damaging a field are dropped and counted (\(damaged.count)); the good one stays", "kept \(list.count) dropped \(dropped)")
    } else { check(false, "damaged events do not fail the whole answer") }
    if case .events(let list, let dropped) = parse(cwText(["schema": 1, "ok": true, "events": ["a string", 5, good]])) { check(list.count == 1 && dropped == 2, "an item that is not an object is dropped") } else { check(false, "non-object items") }
    var allDay = cwJSON(cwEvent("day", start: 0, end: 1440, allDay: true))
    allDay["start"] = "2026-10-07"; allDay["end"] = "2026-10-08"
    if case .events(let list, let dropped) = parse(cwText(["schema": 1, "ok": true, "events": [allDay]])) { check(list.isEmpty && dropped == 0, "an all-day event with plain dates is ignored without a count") } else { check(false, "all-day plain dates") }
    var noTitle = good; noTitle.removeValue(forKey: "title"); noTitle["title"] = NSNull()
    if case .events(let list, _) = parse(cwText(["schema": 1, "ok": true, "events": [noTitle]])) { check(list.count == 1 && list[0].title.isEmpty, "a missing or null title is an empty title") } else { check(false, "null title") }

    // how the child ended
    check(problem(CalendarCommandParser.parse(CalendarCommandResult(launched: true, status: -1, timedOut: true, output: "")))?.kind == .timeout, "timed out: .timeout")
    check(problem(CalendarCommandParser.parse(CalendarCommandResult(launched: true, status: 3, timedOut: false, output: cwAnswer([]))))?.kind == .crashed, "a non-zero exit is a crash, whatever it printed")
    check(problem(CalendarCommandParser.parse(CalendarCommandResult(launched: true, status: 2, timedOut: false, output: "")))?.message.contains("too old") == true, "exit 2 (an unknown command): says the pipeline may be too old")
    check(problem(CalendarCommandParser.parse(CalendarCommandResult(launched: false, status: -1, timedOut: false, output: "", refusal: "python is missing")))?.kind == .helperMissing, "refused (no python): .helperMissing")
    check(problem(CalendarCommandParser.parse(CalendarCommandResult(launched: false, status: -1, timedOut: false, output: "")))?.kind == .helperMissing, "not launched: .helperMissing")
    check(CalendarProblemKind.notConfigured.needsOwner && CalendarProblemKind.authRequired.needsOwner && CalendarProblemKind.laneDenied.needsOwner && CalendarProblemKind.policy.needsOwner && CalendarProblemKind.helperMissing.needsOwner
          && !CalendarProblemKind.network.needsOwner && !CalendarProblemKind.apiError.needsOwner && !CalendarProblemKind.timeout.needsOwner && !CalendarProblemKind.crashed.needsOwner && !CalendarProblemKind.malformed.needsOwner,
          "which problems only the owner can fix")
    check(CalendarWatcher.backoffSeconds(failures: 1, kind: .network) == 60 && CalendarWatcher.backoffSeconds(failures: 2, kind: .network) == 120 && CalendarWatcher.backoffSeconds(failures: 3, kind: .network) == 120
          && CalendarWatcher.backoffSeconds(failures: 4, kind: .network) == 120 && CalendarWatcher.backoffSeconds(failures: 50, kind: .network) == 120
          && [CalendarProblemKind.apiError, .timeout, .crashed, .malformed].allSatisfy { CalendarWatcher.backoffSeconds(failures: 9, kind: $0) == 120 }
          && CalendarWatcher.backoffSeconds(failures: 1, kind: .authRequired) == 900 && CalendarWatcher.backoffSeconds(failures: 0, kind: .apiError) == 60,
          "backoff: 1 minute, then 2 minutes at most (shorter than the 17 minute start window); 15 minutes at once when the owner has to act")
    check(PipelineLauncher.calendarCommandArguments(fromMinutes: 15, toMinutes: 3) == ["-m", "mcap", "gcal", "upcoming", "--from-minutes", "15", "--to-minutes", "3"]
          && PipelineLauncher.calendarCommandTimeout == 20, "the command line of the contract, and the 20 s hard limit")
}

// MARK: S-CW-04: a calendar day through the real controller

private func testCWDay(_ base: URL) {
    section("S-CW-04: an event starts a manual-platform recording, is not started twice, stops after its end; the id survives a restart")
    let fm = FileManager.default
    let w = CWWorld("cw-day", in: base)
    let event = cwEvent("dayevt01-Aa1", start: 10, end: 40)
    w.runner.output = cwAnswer([event])
    w.tickNow()
    check(w.runner.calls.count == 1 && w.runner.calls[0].from == 15 && w.runner.calls[0].to == 3, "the first poll asks for --from-minutes 15 --to-minutes 3 (START_AFTER, START_BEFORE + 1)", "\(w.runner.calls.map { "\($0.from)/\($0.to)" })")
    check(w.runner.calls.allSatisfy { !$0.onMain }, "the command runs off the main thread")
    check(w.h.recorders.isEmpty && w.watcher.status == .on, "at 14:00 the event (14:10) is not due: nothing starts, the status is on")
    w.advance(toMinute: 7)
    check(w.h.recorders.isEmpty, "14:07: still two minutes too early")
    w.advance(60)
    guard let rec = w.rec else { check(false, "14:08 (2 minutes before the start): a recorder was made"); return }
    check(rec.isRecording && rec.signal.platform == .manual && rec.dir.lastPathComponent == "2026-10-07_1408_manual", "14:08: the recording starts on the manual platform (the path of 'Start Recording Now')", rec.dir.lastPathComponent)
    check(rec.signal.titleHint == cwCanaryTitle, "the event title is the title hint of the session (LOG_CONTENT is on)")
    check(w.h.state.manualRecording && w.h.state.calendarRecording, "the state says: a manual-path recording that the calendar started")
    check(StatusMenuController.menuText(for: w.h.state, now: w.h.clock.now).headline.hasPrefix("Recording (calendar)"), "the menu headline says 'Recording (calendar)'", StatusMenuController.menuText(for: w.h.state, now: w.h.clock.now).headline)
    let started = w.h.notifier.posted.filter { $0.kind == .recordingStarted }
    check(started.count == 1 && started[0].title == "녹음 시작 · 캘린더" && started[0].subtitle == cwCanaryTitle && started[0].body.contains("캘린더 일정"), "the existing start notification says it came from the calendar",
          started.map { "\($0.title) | \($0.subtitle) | \($0.body)" }.joined(separator: " ; "))
    check(started.first?.summary == "recording started from the calendar (2026-10-07_1408_manual)", "the log summary of the notification has no title", started.first?.summary ?? "nil")
    check(w.store.contains("dayevt01-Aa1"), "the id is remembered")
    let storeFile = w.store.file
    let attrs = try? fm.attributesOfItem(atPath: storeFile.path)
    let mode = ((attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
    let stored = (try? String(contentsOf: storeFile, encoding: .utf8)) ?? ""
    check(mode == 0o600 && stored.contains("dayevt01-Aa1") && !stored.contains("board") && !stored.contains(cwCanaryTitle) && stored.contains("\"schema\""), "calendar-autostart.json: mode 0600, the id and an end time, no title", "mode \(String(mode, radix: 8)) \(stored)")
    check(storeFile.lastPathComponent == "calendar-autostart.json" && ShellUtil.sameFile(storeFile.deletingLastPathComponent(), w.support), "... in SUPPORT_DIR")
    let leftovers = ((try? fm.contentsOfDirectory(atPath: w.support.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    check(leftovers.isEmpty, "no temp file is left behind by the atomic write", "\(leftovers)")
    check(logText().contains("calendar: recording started for event dayevt01"), "the log says which event (a short id), never the title")

    // not started twice, however often the poll sees it; the controller keeps one recording
    w.advance(toMinute: 39)
    check(w.h.recorders.count == 1 && rec.isRecording && w.runner.calls.count >= 39, "14:39: polled every minute, still one recording (no second start)", "recorders \(w.h.recorders.count), polls \(w.runner.calls.count)")
    w.advance(toMinute: 50)
    check(rec.isRecording && rec.stopReasons.isEmpty, "14:50:00: exactly 10 minutes after the end is not 'later than': still recording")
    w.advance(60)
    check(!rec.isRecording && rec.stopReasons == [.meetingEnded], "14:51: more than 10 minutes after the end: stopped with end reason meeting-ended", "\(rec.stopReasons)")
    check(logCount("reason=calendar-end") == 1 && logText().contains("the event is over; stopping the recording it started"), "app.log names the cause: calendar-end")
    check(w.h.pipeline.enqueued == [rec.dir] && fm.fileExists(atPath: rec.dir.path), "the recording is kept and handed to the pipeline")
    check(!w.h.state.calendarRecording && !w.h.state.manualRecording, "the state no longer says recording")
    let stopped = w.h.notifier.posted.filter { $0.kind == .recordingStopped }
    check(stopped.count == 1 && stopped[0].title == "녹음 종료 · 전사 시작", "the normal 'recording ended' notification follows")
    w.advance(10 * 60)
    check(w.h.recorders.count == 1, "the event is still in the answer but over: never started again")

    // a new app run: the same answer, the id comes from the file
    let again = CWWorld("cw-day-restart", in: base, store: CalendarStartedStore(supportDir: w.support, clock: { w.h.clock.now }))
    again.runner.output = cwAnswer([event])
    again.advance(toMinute: 12)
    check(again.h.recorders.isEmpty, "after a restart of the app the same event id is not started again (read from calendar-autostart.json)")
    check(logText().contains("skipped: already-started"), "... and the skip is logged with its reason")
    let restartStore = CalendarStartedStore(supportDir: w.support, clock: { w.h.clock.now })
    check(restartStore.contains("dayevt01-Aa1") && restartStore.ids == ["dayevt01-Aa1"], "(a new store object reads the id back)")

    // a stretched event: the end is read again from every poll
    let s = CWWorld("cw-stretch", in: base)
    s.runner.output = cwAnswer([cwEvent("stretch01", start: 5, end: 40)])
    s.advance(toMinute: 4)
    guard let sr = s.rec else { check(false, "the stretch scenario started"); return }
    s.runner.output = cwAnswer([cwEvent("stretch01", start: 5, end: 70)])
    s.advance(toMinute: 79)
    check(sr.isRecording, "the event was stretched to 15:10 while it ran: still recording at 15:19 (the old end + 10 minutes was 14:50)", "\(sr.stopReasons)")
    s.advance(120)
    check(!sr.isRecording && sr.stopReasons == [.meetingEnded], "... and stopped once the new end + 10 minutes had passed")

    // the user stops it by hand: this event is never recorded again
    let u = CWWorld("cw-user", in: base)
    u.runner.output = cwAnswer([cwEvent("userevt1", start: 5, end: 60)])
    u.advance(toMinute: 4)
    guard let ur = u.rec else { check(false, "the user scenario started"); return }
    u.advance(toMinute: 8)
    u.h.controller.stopRecordingNow(); u.h.sync(); u.watcher.flush()
    check(!ur.isRecording && ur.stopReasons == [.manual], "'Stop Recording Now' ends it with reason manual")
    u.advance(toMinute: 30)
    check(u.h.recorders.count == 1, "the event is still running and in the window, and it is not started again")
    check(logText().contains("event userevt1 skipped: stopped-by-user") && logText().contains("was stopped by hand"), "the reason is logged: stopped-by-user")

    // a recording of the user's own is never stopped by the calendar
    let m = CWWorld("cw-manual-own", in: base)
    m.runner.output = cwAnswer([cwEvent("ownevt01", start: 5, end: 30)])
    m.h.controller.startRecordingNow(); m.h.sync()
    m.advance(toMinute: 90)
    check(m.rec?.isRecording == true && m.h.recorders.count == 1 && logText().contains("event ownevt01 skipped: already-recording"), "a recording the user started by hand is not touched by the calendar (not started over it, not stopped by it)")
    check(m.h.controller.stopRecordingFromCalendar(eventID: "ownevt01") == false && m.rec?.isRecording == true, "stopRecordingFromCalendar only ends the recording of that event id")
    m.h.controller.shutdown(reason: .appQuit)
}

// MARK: S-CW-05: presence, other recordings, pause, failures, no speech

private func testCWSkips(_ base: URL) {
    section("S-CW-05: locked screen, idle, already recording, 'Pause Auto Recording', a failing start, the no-speech rule")
    // locked screen and idle: skip, and start later in the window once somebody is there
    let p = CWWorld("cw-presence", in: base)
    p.runner.output = cwAnswer([cwEvent("presnce1", start: 5, end: 60)])
    p.presence = CalendarPresence(screenLocked: true, onConsole: true, secondsSinceInput: 1)
    p.advance(toMinute: 6)
    check(p.h.recorders.isEmpty && logText().contains("event presnce1 skipped: screen-locked"), "locked screen: no start (logged once with the reason)")
    p.presence = CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 301)
    p.advance(toMinute: 9)
    check(p.h.recorders.isEmpty && logText().contains("event presnce1 skipped: idle"), "no input for more than 5 minutes: no start")
    p.presence = CalendarPresence(screenLocked: false, onConsole: false, secondsSinceInput: 1)
    p.advance(toMinute: 10)
    check(p.h.recorders.isEmpty && logText().contains("event presnce1 skipped: not-on-console"), "another user at the console: no start")
    p.presence = CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: nil)
    p.advance(toMinute: 11)
    check(p.h.recorders.isEmpty && logText().contains("event presnce1 skipped: input-age-unknown"), "input age unknown: no start")
    check(logCount("event presnce1 skipped: screen-locked") == 1, "a reason is logged once, not at every poll")
    p.presence = CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 20)
    p.advance(toMinute: 15)
    check(p.h.recorders.count == 1 && p.rec?.isRecording == true, "somebody is back at 14:15 (the window runs to 14:20): the recording starts then")
    p.h.controller.shutdown(reason: .appQuit)
    let late = CWWorld("cw-presence-late", in: base)
    late.runner.output = cwAnswer([cwEvent("latevt01", start: 5, end: 60)])
    late.presence = CalendarPresence(screenLocked: true, onConsole: true, secondsSinceInput: 1)
    late.advance(toMinute: 21)
    late.presence = CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 1)
    late.advance(toMinute: 30)
    check(late.h.recorders.isEmpty && logText().contains("event latevt01 skipped: start-window-passed"), "back after the window (more than 15 minutes after the start): no late start")

    // a recording of any platform is running
    let zoom = zoomSignal()
    let z = CWWorld("cw-zoom", in: base)
    z.runner.output = cwAnswer([cwEvent("zoomevt1", start: 1, end: 60)])
    z.h.run(until: { !z.h.recorders.isEmpty }, limit: 15, [zoom])
    check(z.h.current?.signal.platform == .zoom && z.h.controller.isRecordingActive, "(a Zoom call is being recorded)")
    z.h.detector.signals = [zoom]
    z.h.clock.advance(60)
    z.tickNow()
    z.h.clock.advance(60)
    z.tickNow()
    check(z.h.recorders.count == 1 && z.h.recorders.allSatisfy { $0.signal.platform == .zoom } && logText().contains("event zoomevt1 skipped: already-recording"), "a Zoom recording is running: the calendar event is skipped (already-recording)")
    check(z.store.contains("zoomevt1") && logText().contains("event zoomevt1 is covered by another recording"), "... and the event is covered by it: the id is marked as started, the log says so")
    // the Zoom call ends inside the event's start window: the event is not started in its place a minute later
    z.h.detector.signals = []
    z.advance(2 * 60)
    check(z.h.current?.isRecording == false, "(the Zoom call is over and its recording ended)")
    z.advance(toMinute: 14)
    check(z.h.recorders.count == 1 && logText().contains("event zoomevt1 skipped: already-started"), "the Zoom recording ended at about 14:04, the event runs until 15:00 and its window is open until 14:16: still no calendar recording")
    z.h.controller.shutdown(reason: .appQuit)

    // the user's own recording ends inside the event's start window (a start by hand at 13:58 or 14:02, a stop at 14:08): the event is not started in its place
    let cov = CWWorld("cw-covered", in: base)
    cov.runner.output = cwAnswer([cwEvent("covered1", start: 5, end: 60)])
    cov.advance(toMinute: 2)
    cov.h.controller.startRecordingNow(); cov.h.sync()
    cov.advance(toMinute: 8)
    check(cov.h.recorders.count == 1 && cov.rec?.isRecording == true && cov.store.contains("covered1"), "a recording started by hand at 14:02 is running when the event comes due (14:03): it covers the event")
    cov.h.controller.stopRecordingNow(); cov.h.sync(); cov.watcher.flush()
    check(cov.rec?.isRecording == false, "(stopped by hand at 14:08)")
    cov.advance(toMinute: 20)
    check(cov.h.recorders.count == 1 && logText().contains("event covered1 is covered by another recording"), "14:20: still one recording, the event is not started after the manual one ended inside its window")
    cov.advance(toMinute: 40)
    check(cov.h.recorders.count == 1, "and not later either")

    // back to back: a recording that the CALENDAR started for the first event does not cover the second one, which starts when the first one has been stopped
    let b2b = CWWorld("cw-back-to-back", in: base)
    b2b.runner.output = cwAnswer([cwEvent("first001", start: 5, end: 30), cwEvent("second01", start: 30, end: 60)])
    b2b.advance(toMinute: 29)
    check(b2b.h.recorders.count == 1 && b2b.rec?.isRecording == true && !b2b.store.contains("second01"), "14:29: the first event is recorded, the second one (14:30) waits and is not marked as covered")
    b2b.advance(toMinute: 43)
    check(b2b.h.recorders.count == 2 && b2b.h.recorders[0].isRecording == false && b2b.h.recorders[0].stopReasons == [.meetingEnded] && b2b.rec?.isRecording == true && b2b.store.contains("second01"),
          "the first recording ends 10 minutes after its end (14:40) and the second event starts then, inside its own window (until 14:45)", "recorders \(b2b.h.recorders.count)")
    check(!logText().contains("event second01 is covered by another recording"), "(the second event was never called covered)")
    b2b.h.controller.shutdown(reason: .appQuit)

    // Pause Auto Recording
    let q = CWWorld("cw-paused", in: base)
    q.runner.output = cwAnswer([cwEvent("pausevt1", start: 5, end: 60)])
    q.h.controller.setPaused(true); q.h.sync()
    q.advance(toMinute: 8)
    check(q.h.recorders.isEmpty && logCount("event pausevt1 not started: 'Pause Auto Recording' is on") == 1, "'Pause Auto Recording' is on: not started, said once")
    check(q.h.controller.startRecordingFromCalendar(eventID: "x", title: nil) == .paused, "the controller answers .paused")
    q.h.controller.setPaused(false); q.h.sync()
    q.advance(toMinute: 10)
    check(q.h.recorders.count == 1 && q.rec?.isRecording == true, "resumed: the event (still in the window) starts")
    q.h.controller.shutdown(reason: .appQuit)

    // a start that fails: held back, one notification, then it works
    let f = CWWorld("cw-failing", in: base)
    f.runner.output = cwAnswer([cwEvent("failevt1", start: 5, end: 120)])
    f.h.startError = RecorderError.deviceUnavailable("test microphone")
    f.advance(toMinute: 11)
    check(f.h.recorders.allSatisfy { !$0.isRecording } && !f.store.contains("failevt1"), "the recorder cannot start: no recording, and the event is not marked as started")
    check(logText().contains("event failevt1 could not be started (attempt 1)") && logText().contains("attempt 2"), "every failed attempt is logged with its number")
    check(f.h.notifier.count(.recordingFailed) == 1, "the person hears about it once (the controller's own throttle), not at every retry", "\(f.h.notifier.count(.recordingFailed))")
    let attempts = f.h.recorders.count
    f.advance(toMinute: 12)
    check(f.h.recorders.count <= attempts + 1, "the retries slow down (10, 30, 60, 300 s), they are not one per beat forever", "\(attempts) -> \(f.h.recorders.count)")
    f.h.startError = nil
    f.advance(toMinute: 19)
    check(f.rec?.isRecording == true && f.store.contains("failevt1"), "the device works again: the event is started within the window (14:19 of 14:20)", "recorders \(f.h.recorders.count)")
    f.h.controller.shutdown(reason: .appQuit)

    // the no-speech rule covers a calendar recording
    let n = CWWorld("cw-nospeech", in: base)
    n.runner.output = cwAnswer([cwEvent("quietev1", start: 5, end: 120)])
    n.advance(toMinute: 4)
    guard let nr = n.rec else { check(false, "the quiet scenario started"); return }
    nr.levels = (-85, -120)
    n.advance(14 * 60, step: 30)
    check(nr.isRecording, "14 minutes of silence on both tracks (less than 15): still recording")
    n.advance(3 * 60, step: 30)
    check(!nr.isRecording && nr.stopReasons == [.meetingEnded], "15 minutes of silence: stopped by NO_SPEECH_STOP_MINUTES (meeting-ended)", "\(nr.stopReasons)")
    check(logText().contains("the recording was started from the calendar") && logCount("reason=no-speech") >= 1, "the log says no-speech and that it came from the calendar")
    check(n.h.notifier.posted.contains { $0.kind == .recordingStopped && $0.body.contains("15") }, "the stop notification names the 15 minutes of silence")
    check((n.h.state.notice ?? "").contains("calendar event"), "the menu notice says the next calendar event starts a new one", "\(n.h.state.notice ?? "nil")")
    n.advance(toMinute: 24)
    check(n.h.recorders.count == 1, "the same event is not started again after a no-speech stop")
    // a user's own manual recording stays exempt from the rule
    let own = Harness("cw-nospeech-own", in: base)
    own.controller.startRecordingNow(); own.sync()
    own.current?.levels = (-120, -120)
    own.run(90 * 60, step: 30, [])
    check(own.current?.isRecording == true, "a recording the user started by hand is still not stopped by silence")
    own.controller.shutdown(reason: .appQuit)
}

// MARK: S-CW-06: errors, backoff, wake, the menu state

private func testCWErrors(_ base: URL) {
    section("S-CW-06: ok:false and broken answers: visible, backed off (2 minutes; 15 when only the owner can act), retried at once after a wake, one notification per 12 hours")
    // transient: 1 minute, then 2 minutes at most
    let e = CWWorld("cw-backoff", in: base)
    e.runner.output = cwError("network", "no route")
    e.tickNow()
    e.advance(60 * 60)
    check(e.runner.callTimes == [0, 60] + Array(stride(from: 180, through: 3600, by: 120)), "network errors: polls at 0, 1, 3, 5, 7, ... minutes (a 1 minute gap, then 2 minute gaps, never longer)", "\(e.runner.callTimes)")
    check(e.watcher.status == .error(CalendarProblem(kind: .network, message: "no route")), "the status is the error (visible in the menu)", "\(e.watcher.status)")
    check(e.statuses == [.error(CalendarProblem(kind: .network, message: "no route"))] && logCount("calendar: network: no route") == 1,
          "the menu hears about it once and app.log has one line, not one per failed poll", "\(e.statuses.count) statuses, \(logCount("calendar: network: no route")) lines")
    check(e.notifier.posted.isEmpty, "a network problem makes no notification")
    e.runner.output = cwAnswer([])
    e.advance(15 * 60)
    check(e.watcher.status == .on && e.statuses.last == .on && logText().contains("calendar: working again"), "the next good answer clears the error: status on, said once")
    let afterGood = e.runner.callTimes.count
    e.advance(5 * 60)
    check(e.runner.callTimes.count - afterGood == 5 && zip(e.runner.callTimes.suffix(6), e.runner.callTimes.suffix(6).dropFirst()).allSatisfy { $1 - $0 == 60 }, "after success the poll is every 60 s again")

    // after a wake: at once, whatever the backoff
    let wk = CWWorld("cw-wake", in: base)
    wk.runner.output = cwError("network", "offline")
    wk.advance(8 * 60)
    let before = wk.runner.calls.count
    wk.advance(60)
    check(wk.runner.calls.count == before, "(inside the backoff nothing is polled)")
    wk.runner.output = cwAnswer([])
    wk.watcher.systemDidWake(); wk.watcher.flush()
    check(wk.scheduled == [CalendarWatcher.wakeDelaySeconds], "a wake schedules the retry in \(Int(CalendarWatcher.wakeDelaySeconds)) s", "\(wk.scheduled)")
    wk.h.clock.advance(2)
    wk.tickNow()
    check(wk.runner.calls.count == before + 1 && wk.watcher.status == .on, "the retry after the wake polls at once (no waiting for the backoff) and succeeds")

    // a Mac that is offline around the start of an event: the polls keep coming every 2 minutes, so the event is still started inside its 15 minute window
    let off = CWWorld("cw-offline-start", in: base)
    off.runner.output = cwError("network", "offline")
    off.advance(toMinute: 16)
    check(off.h.recorders.isEmpty, "(offline until 14:16: nothing can start)")
    off.runner.output = cwAnswer([cwEvent("offline1", start: 5, end: 60)])
    off.advance(toMinute: 19)
    check(off.rec?.isRecording == true && off.h.recorders.count == 1, "the network is back at 14:16: the next poll (14:18) starts the event inside its window (it ends at 14:20); with the old 15 minute backoff the next poll came at 14:30",
          "\(off.runner.callTimes)")
    off.h.controller.shutdown(reason: .appQuit)

    // problems that only the owner can fix: 15 minutes at once, one notification per 12 hours
    for (code, kind) in [("auth_required", CalendarProblemKind.authRequired), ("not_configured", .notConfigured)] {
        let a = CWWorld("cw-\(code)", in: base)
        a.runner.output = cwError(code, "owner action")
        a.tickNow()
        a.advance(30 * 60)
        check(a.runner.callTimes == [0, 900, 1800], "\(code): one poll every 15 minutes from the first failure on", "\(a.runner.callTimes)")
        check(a.watcher.status == .error(CalendarProblem(kind: kind, message: "owner action")), "\(code): a visible error state")
        let notes = a.notifier.posted
        check(notes.count == 1 && notes[0].kind == .calendarProblem && notes[0].title == "캘린더 자동 시작을 확인하세요" && notes[0].body.contains("mcap gcal auth"), "\(code): exactly one notification in half an hour, with the command to run", "\(notes.map { $0.title })")
        a.h.clock.advance(12 * 3600 + 1)
        a.tickNow()
        check(a.notifier.count(.calendarProblem) == 2, "\(code): the next one comes after 12 hours", "\(a.notifier.count(.calendarProblem))")
    }
    let lane = CWWorld("cw-lane", in: base)
    lane.runner.output = cwError("lane_denied", "policy says no")
    lane.tickNow()
    lane.advance(20 * 60)
    check(lane.watcher.status == .error(CalendarProblem(kind: .laneDenied, message: "policy says no")) && lane.notifier.posted.isEmpty && lane.runner.callTimes == [0, 900],
          "lane_denied: a menu state, no notification, 15 minute polls", "\(lane.runner.callTimes) \(lane.notifier.posted.count)")
    let pol = CWWorld("cw-policy-err", in: base)
    pol.runner.output = cwError("policy", "blocked")
    pol.advance(2 * 60)
    check(pol.watcher.status == .error(CalendarProblem(kind: .policy, message: "blocked")) && pol.notifier.posted.isEmpty, "policy: a menu state, no notification")

    // broken answers
    for (name, result, kind) in [("malformed JSON", cwResult("this is not json"), CalendarProblemKind.malformed),
                                 ("empty output", cwResult(""), .malformed),
                                 ("a timeout", CalendarCommandResult(launched: true, status: -1, timedOut: true, output: ""), .timeout),
                                 ("a crash", CalendarCommandResult(launched: true, status: 1, timedOut: false, output: "Traceback"), .crashed),
                                 ("no python", CalendarCommandResult(launched: false, status: -1, timedOut: false, output: "", refusal: "python is missing"), .helperMissing)] {
        let b = CWWorld("cw-broken", in: base)
        b.runner.override = result
        b.advance(3 * 60)
        guard case .error(let problem) = b.watcher.status else { check(false, "\(name): the status is an error", "\(b.watcher.status)"); continue }
        check(problem.kind == kind && b.h.recorders.isEmpty && b.notifier.posted.isEmpty, "\(name): \(kind) in the menu, no crash, nothing recorded, no notification")
        let item = StatusMenuController.calendarItemState(for: b.watcher.status)
        check(item.title.hasPrefix("캘린더 자동 시작: 오류: ") && item.enabled && !item.checked, "\(name): the menu line says error and offers 'try again'", item.title)
    }
    // a click on an error state means 'try again now'
    let r = CWWorld("cw-retry", in: base)
    r.runner.output = cwError("auth_required", "sign in")
    r.advance(60)
    let polls = r.runner.calls.count
    r.runner.output = cwAnswer([])
    r.watcher.menuClicked(); r.watcher.flush()
    r.tickNow()
    check(r.runner.calls.count == polls + 1 && r.watcher.status == .on && r.scheduled.last == 0.2, "a click in the error state polls again at once and clears it when it works")
}

// MARK: S-CW-07: closed by the policy, kill switch, sleep

private func testCWGate(_ base: URL) {
    section("S-CW-07: the feature is closed by the policy (kill switch, locked, lane), by local-only as the start value, and honours what ends a recording (sleep and quit are resumed)")
    let event = cwEvent("gateevt1", start: 5, end: 60)
    var off = OrgPolicy.absent()
    off.recordingEnabled = false
    var noLane = OrgPolicy.absent()
    noLane.lanes["calendar"] = "deny"
    let cases: [(String, OrgPolicy, PrivacySettings?, CalendarBlock)] = [
        ("recording off", off, nil, .recordingOff), ("locked", OrgPolicy.parse(Data("not json".utf8)), nil, .policyLocked),
        ("lane denied", noLane, nil, .laneDenied), ("local-only default", OrgPolicy.absent(), loPrivacy(["LOCAL_ONLY_DEFAULT": "1"], in: base), .localOnlyDefault)]
    for (name, policy, privacy, expected) in cases {
        let w = CWWorld("cw-gate", in: base, policy: policy, privacy: privacy)
        w.runner.output = cwAnswer([event])
        w.advance(toMinute: 8)
        check(w.runner.calls.isEmpty && w.h.recorders.isEmpty && w.watcher.status == .blocked(expected), "\(name): nothing is asked from Google and nothing starts; the status says why", "\(w.watcher.status) calls \(w.runner.calls.count)")
        check(logText().contains("calendar auto-start is off: \(expected.logText)"), "\(name): one log line with the reason")
        let item = StatusMenuController.calendarItemState(for: w.watcher.status)
        check(!item.enabled && !item.checked && item.title.hasPrefix("캘린더 자동 시작: 꺼짐 (") , "\(name): the menu line is disabled and says why", item.title)
        let direct = w.h.controller.startRecordingFromCalendar(eventID: "gateevt1", title: nil)
        if case .blocked = direct { check(w.h.recorders.isEmpty, "\(name): the controller refuses a start itself (second line of defence)") } else { check(false, "\(name): the controller refuses a start itself", "\(direct)") }
    }
    // the gate opens again with the policy
    let box = Locked<OrgPolicy>(off)
    let w = CWWorld("cw-gate-open", in: base, policy: off, reader: { box.value })
    w.runner.output = cwAnswer([event])
    w.advance(toMinute: 6)
    check(w.h.recorders.isEmpty && w.watcher.status == .blocked(.recordingOff), "recording switched off by the policy: closed")
    box.value = OrgPolicy.absent()
    w.advance(toMinute: 9)
    check(w.rec?.isRecording == true && w.watcher.status == .on && logText().contains("may run again"), "the policy allows recording again: the event (still in its window) starts")
    // the kill switch while it records: the controller ends it, the calendar does not start it again
    box.value = off
    w.advance(toMinute: 12)
    check(w.rec?.isRecording == false && w.rec?.stopReasons == [.manual] && logText().contains("policy-kill-switch"), "the kill switch ends the recording (reason manual, label policy-kill-switch)", "\(String(describing: w.rec?.stopReasons))")
    box.value = OrgPolicy.absent()
    w.advance(toMinute: 16)
    check(w.h.recorders.count == 1 && logText().contains("event gateevt1 skipped: already-started") && !logText().contains("event gateevt1 skipped: stopped-by-user"),
          "after the policy relents the event is not recorded again (already started, and not counted as a stop by hand)")
    w.h.controller.shutdown(reason: .appQuit)

    // what counts as 'the user stopped it'
    check(CalendarWatcher.endedByUser(reason: .manual, label: nil) && CalendarWatcher.endedByUser(reason: .paused, label: nil), "Stop Recording Now and Pause Auto Recording are the user's stops")
    check(!CalendarWatcher.endedByUser(reason: .manual, label: "policy-kill-switch") && !CalendarWatcher.endedByUser(reason: .meetingEnded, label: "calendar-end") && !CalendarWatcher.endedByUser(reason: .meetingEnded, label: "no-speech")
          && ![EndReason.sleep, .appQuit, .diskLow, .maxDuration, .crashRecovered, .meetingEnded].contains { CalendarWatcher.endedByUser(reason: $0, label: nil) }, "the policy, the calendar, no speech, sleep, a full disk, the time limit and a quit are not")

    // sleep in the middle of the event ('pick up the laptop and walk to the room'): the recording ends with reason sleep, and after the wake the event is
    // picked up again for as long as it runs: its start window (14:03 to 14:20) does not matter, the id is not 'already started'
    let s = CWWorld("cw-sleep", in: base)
    s.runner.output = cwAnswer([cwEvent("sleepev1", start: 5, end: 90)])             // 14:05 - 15:30
    s.advance(toMinute: 6)
    let sr = s.rec
    check(sr?.isRecording == true && s.store.contains("sleepev1"), "(the event was started at 14:03 and is in the store)")
    s.h.controller.systemWillSleep(); s.h.sync(); s.watcher.flush()
    check(sr?.stopReasons == [.sleep], "the Mac goes to sleep: the recording ends with reason sleep", "\(String(describing: sr?.stopReasons))")
    check(!s.store.contains("sleepev1") && logText().contains("event sleepev1 was interrupted (sleep); it is picked up again while the event runs"), "an interruption takes the id out of the store and says so in app.log")
    s.h.clock.advance(24 * 60)                                                       // asleep until 14:30: nothing runs meanwhile
    s.watcher.systemDidWake(); s.watcher.flush()
    s.tickNow()
    check(s.h.recorders.count == 2 && s.rec?.isRecording == true && s.store.contains("sleepev1"), "woken at 14:30, 25 minutes after the start (the window is over): a second recording of the same event starts",
          "recorders \(s.h.recorders.count)")
    check(s.watcher.status == .on, "(the status stays on)")
    // the screen lock after a wake still holds it back, as for any start
    let lockedWake = CWWorld("cw-sleep-locked", in: base)
    lockedWake.runner.output = cwAnswer([cwEvent("sleeplk1", start: 5, end: 90)])
    lockedWake.advance(toMinute: 6)
    lockedWake.h.controller.systemWillSleep(); lockedWake.h.sync(); lockedWake.watcher.flush()
    lockedWake.h.clock.advance(24 * 60)
    lockedWake.presence = CalendarPresence(screenLocked: true, onConsole: true, secondsSinceInput: 2)
    lockedWake.tickNow()
    check(lockedWake.h.recorders.count == 1 && logText().contains("event sleeplk1 skipped: screen-locked"), "after the wake the screen is locked: no recording yet")
    lockedWake.presence = CalendarPresence(screenLocked: false, onConsole: true, secondsSinceInput: 2)
    lockedWake.advance(60)
    check(lockedWake.h.recorders.count == 2 && lockedWake.rec?.isRecording == true, "unlocked: the event is picked up")
    lockedWake.h.controller.shutdown(reason: .appQuit)
    // never after the event is over
    let overWake = CWWorld("cw-sleep-over", in: base)
    overWake.runner.output = cwAnswer([cwEvent("sleepov1", start: 5, end: 30)])
    overWake.advance(toMinute: 6)
    overWake.h.controller.systemWillSleep(); overWake.h.sync(); overWake.watcher.flush()
    overWake.h.clock.advance(40 * 60)
    overWake.tickNow()
    check(overWake.h.recorders.count == 1, "woken at 14:46, after the end (14:30): nothing starts")
    // at most 3 times per event
    let many = CWWorld("cw-sleep-many", in: base)
    many.runner.output = cwAnswer([cwEvent("manysl01", start: 5, end: 200)])
    many.advance(toMinute: 4)
    for n in 1...4 {
        many.advance(60)
        many.h.controller.systemWillSleep(); many.h.sync(); many.watcher.flush()
        many.h.clock.advance(60)
        many.watcher.systemDidWake(); many.watcher.flush()
        many.tickNow()
        check(many.h.recorders.count == min(n + 1, 4), "interruption \(n): \(n <= CalendarWatcher.maxResumes ? "picked up again" : "not picked up again (at most \(CalendarWatcher.maxResumes) resumes per event)")", "recorders \(many.h.recorders.count)")
    }
    check(many.store.contains("manysl01") && logText().contains("event manysl01 was interrupted (sleep); it was interrupted more than 3 times"), "after the third resume the event stays in the store (one-shot again), and the log says why")
    many.advance(10 * 60)
    check(many.h.recorders.count == 4, "... and it is not started again")
    // a stop that was a decision stays final, with a start window that is wide open (OFFLINE_START_AFTER_MINUTES=120): no speech
    let quiet = CWWorld("cw-nospeech-final", in: base, settings: cwAuto { $0.startAfterMinutes = 120 })
    quiet.runner.output = cwAnswer([cwEvent("quietfn1", start: 5, end: 200)])
    quiet.advance(toMinute: 4)
    quiet.rec?.levels = (-85, -120)
    quiet.advance(17 * 60, step: 30)
    check(quiet.h.recorders.count == 1 && quiet.rec?.isRecording == false && quiet.rec?.stopReasons == [.meetingEnded], "(15 minutes of silence ended the recording)")
    quiet.advance(30 * 60)
    check(quiet.h.recorders.count == 1 && logText().contains("event quietfn1 skipped: already-started"), "no speech is a decision: the event (window open for 2 hours) is not started again, a sleep rule does not change that")
    // the power-off notice that is never retracted (a logout that another app cancels): the recording ends with app-quit and the app runs on
    let po = CWWorld("cw-poweroff", in: base)
    po.runner.output = cwAnswer([cwEvent("pwroff01", start: 5, end: 90)])
    po.advance(toMinute: 6)
    po.h.controller.systemWillPowerOff(); po.h.sync(); po.watcher.flush()
    check(po.rec?.stopReasons == [.appQuit], "a power-off request ends the recording with reason app-quit")
    po.advance(2 * 60)
    check(po.h.recorders.count == 2 && po.rec?.isRecording == true, "the logout was cancelled and the app runs on: the event is picked up again")
    po.h.controller.shutdown(reason: .appQuit)
    // a real quit: the id leaves the store file at once (synchronously), and a new run inside the start window starts the event again
    let q1 = CWWorld("cw-quit-1", in: base)
    q1.runner.output = cwAnswer([cwEvent("quitevt1", start: 5, end: 90)])
    q1.advance(toMinute: 6)
    check(q1.store.contains("quitevt1") && ((try? String(contentsOf: q1.store.file, encoding: .utf8)) ?? "").contains("quitevt1"), "(the id is in the store file)")
    q1.h.controller.shutdown(reason: .appQuit)
    check(!q1.store.contains("quitevt1") && !((try? String(contentsOf: q1.store.file, encoding: .utf8)) ?? "").contains("quitevt1"), "a quit of the app: the id is out of the store file when shutdown returns")
    let q2 = CWWorld("cw-quit-2", in: base, store: CalendarStartedStore(supportDir: q1.support, clock: { q1.h.clock.now }))
    q2.runner.output = cwAnswer([cwEvent("quitevt1", start: 5, end: 90)])
    q2.advance(toMinute: 12)
    check(q2.h.recorders.count == 1 && q2.rec?.isRecording == true, "the new run of the app, inside the start window (14:12 of 14:20): the event is started again")
    q2.h.controller.shutdown(reason: .appQuit)
    check(CalendarWatcher.interruptedFromOutside(reason: .sleep) && CalendarWatcher.interruptedFromOutside(reason: .appQuit)
          && ![EndReason.manual, .paused, .meetingEnded, .diskLow, .maxDuration, .crashRecovered].contains { CalendarWatcher.interruptedFromOutside(reason: $0) },
          "only sleep and a quit are interruptions; the user, the calendar and no speech (meeting-ended), a full disk, the time limit are decisions")

    // the controller's own API
    let c = Harness("cw-controller-api", in: base)
    check(c.controller.calendarGate() == nil, "no gate on the personal install")
    check(c.controller.startRecordingFromCalendar(eventID: "apievt01", title: "t") == .started && c.controller.startRecordingFromCalendar(eventID: "apievt02", title: "t") == .alreadyRecording, "the first start works, a second one while recording is refused")
    check(c.controller.stopRecordingFromCalendar(eventID: "apievt02") == false && c.current?.isRecording == true, "another event id does not stop it")
    let ends = Locked<[CalendarRecordingEnd]>([])
    c.controller.onCalendarRecordingEnded = { end in ends.value.append(end) }
    check(c.controller.stopRecordingFromCalendar(eventID: "apievt01") == true && c.current?.stopReasons == [.meetingEnded], "the right id stops it with meeting-ended")
    check(ends.value == [CalendarRecordingEnd(eventID: "apievt01", reason: .meetingEnded, label: "calendar-end")], "the controller reports the end with its label", "\(ends.value)")
    check(c.controller.stopRecordingFromCalendar(eventID: "apievt01") == false, "nothing to stop twice")
    c.controller.shutdown(reason: .appQuit)
    check(c.controller.startRecordingFromCalendar(eventID: "apievt03", title: nil) == .shutDown, "after shutdown nothing starts")
    let fail = Harness("cw-controller-fail", in: base)
    fail.startError = RecorderError.permissionDenied("microphone")
    if case .failed(let message) = fail.controller.startRecordingFromCalendar(eventID: "apievt04", title: nil) { check(message.contains("permission denied") && fail.current?.isRecording != true, "a recorder that cannot start: .failed with the actionable text") }
    else { check(false, "a recorder that cannot start: .failed") }
}

// MARK: S-CW-08: privacy of the title

private func testCWPrivacy(_ base: URL) {
    section("S-CW-08: the event title: only a title hint with LOG_CONTENT on, never in app.log, the store, the menu or a notification of a hidden meeting")
    let hidden = CWWorld("cw-logcontent-off", in: base, privacy: loPrivacy(["LOG_CONTENT": "0"], in: base))
    hidden.runner.output = cwAnswer([cwEvent("hideevt1", start: 5, end: 60)])
    hidden.advance(toMinute: 6)
    check(hidden.rec?.isRecording == true && hidden.rec?.signal.titleHint == nil, "LOG_CONTENT=0: the recording starts without a title hint")
    check(hidden.h.notifier.posted.contains { $0.kind == .recordingStarted && $0.subtitle == "캘린더 일정으로 시작했어요" } && !hidden.h.notifier.posted.contains { ($0.title + $0.subtitle + $0.body).contains("board") },
          "... and the start notification has no title")
    hidden.h.controller.shutdown(reason: .appQuit)

    let odd = "Quarterly \u{1B}[31mred\u{202E}team " + String(repeating: "x", count: 300)
    let c = Harness("cw-title", in: base)
    check(c.controller.startRecordingFromCalendar(eventID: "titleev1", title: odd) == .started, "(a recording with an unruly title)")
    let hint = c.current?.signal.titleHint ?? ""
    check(!hint.isEmpty && hint.count <= SessionController.calendarTitleLimit && !hint.unicodeScalars.contains(where: NotificationText.isStrippedScalar) && hint.hasPrefix("Quarterly"),
          "the title hint has no control or bidi characters and is cut to \(SessionController.calendarTitleLimit)", "\(hint.count) characters")
    c.controller.shutdown(reason: .appQuit)
    let none = Harness("cw-notitle", in: base)
    _ = none.controller.startRecordingFromCalendar(eventID: "titleev2", title: "  \n ")
    check(none.current?.signal.titleHint == nil, "a blank title is no title hint")
    none.controller.shutdown(reason: .appQuit)

    check(!logText().contains("board strategy") && !logText().contains("Confidential"), "app.log of this whole self test never held the event title")
    let menuTexts = [CalendarStatus.on, .off, .blocked(.laneDenied), .error(CalendarProblem(kind: .network, message: "x"))].map { StatusMenuController.calendarItemState(for: $0).title }
    check(menuTexts.allSatisfy { !$0.contains("board") }, "no menu text holds a title")
}

// MARK: S-CW-09: OFFLINE_AUTOSTART=off, one run at a time, the real start()

private func testCWOffAndThreads(_ base: URL) {
    section("S-CW-09: OFFLINE_AUTOSTART=off runs nothing; one command at a time, never on the main thread; the session switch")
    let off = CWWorld("cw-off", in: base, settings: OfflineAutostartSettings.defaults)
    off.runner.output = cwAnswer([cwEvent("offevt01", start: 0, end: 60)])
    let logBefore = logText().count
    off.watcher.start(); off.watcher.attach()
    off.watcher.tick(); off.watcher.systemDidWake(); off.watcher.menuClicked(); off.watcher.setEnabled(false); off.watcher.setEnabled(true)
    off.advance(10 * 60)
    off.watcher.flush()
    check(off.runner.calls.isEmpty && off.h.recorders.isEmpty && off.statuses.isEmpty && off.scheduled.isEmpty, "off: no command, no recording, no status, nothing scheduled")
    check(off.h.controller.onCalendarRecordingEnded == nil && logText().count == logBefore, "off: no hook into the controller, no log line")
    check(!FileManager.default.fileExists(atPath: off.store.file.path), "off: no calendar-autostart.json")

    // start(): the hook, the warning, no timer is needed to check that; shutdown() cancels before the first beat
    let on = CWWorld("cw-start", in: base)
    on.watcher.start()
    on.watcher.shutdown()
    on.watcher.flush()
    check(on.h.controller.onCalendarRecordingEnded != nil && logText().contains("calendar auto-start is ON") && logText().contains("without their consent"), "on: start() hooks the controller and says in app.log that a recording starts without a button press (consent warning)")
    on.runner.output = cwAnswer([cwEvent("downevt1", start: 0, end: 60)])
    on.advance(5 * 60)
    check(on.runner.calls.isEmpty && on.h.recorders.isEmpty, "after shutdown() nothing is polled and nothing starts")

    // the real timer of start(): beats on the watcher's own queue, one command at a time, never on the main thread
    let timed = CWWorld("cw-timer", in: base, beat: (0.02, 0.02))
    let timedClock = timed.h.clock
    timed.runner.onCall = { timedClock.advance(61) }
    timed.runner.output = cwAnswer([])
    timed.watcher.start()
    let beats = waitUntil(10) { timed.runner.calls.count >= 3 }
    timed.watcher.shutdown(); timed.watcher.flush()
    let beatCount = timed.runner.calls.count
    Thread.sleep(forTimeInterval: 0.2)
    check(beats && timed.runner.calls.allSatisfy { !$0.onMain } && timed.runner.maxInFlight == 1, "start(): the timer beats on the watcher's own queue (3+ polls), never on the main thread, one command at a time", "calls \(timed.runner.calls.count)")
    check(timed.runner.calls.count - beatCount <= 1, "shutdown() stops the timer (at most the beat that was already running finishes)", "\(beatCount) -> \(timed.runner.calls.count)")

    // one run at a time, off the main thread
    let t = CWWorld("cw-threads", in: base)
    let clock = t.h.clock
    t.runner.delay = 0.03
    t.runner.onCall = { clock.advance(61) }
    t.runner.output = cwAnswer([])
    let group = DispatchGroup()
    for _ in 0..<4 {
        DispatchQueue.global().async(group: group) { for _ in 0..<3 { t.watcher.tick() } }
    }
    _ = group.wait(timeout: .now() + 30)
    check(t.runner.calls.count == 12 && t.runner.maxInFlight == 1, "four threads ticking at once: 12 polls, never two commands at the same time", "calls \(t.runner.calls.count), max in flight \(t.runner.maxInFlight)")
    check(t.runner.calls.allSatisfy { !$0.onMain }, "none of them ran on the main thread (the self test calls tick() from the main thread and from workers)")

    // the session switch: writes nothing to config.env
    let s = CWWorld("cw-switch", in: base)
    s.runner.output = cwAnswer([cwEvent("switchev1", start: 2, end: 60)])
    s.watcher.setEnabled(false); s.watcher.flush()
    check(s.watcher.status == .off && s.statuses.last == .off, "switched off from the menu: status off")
    s.advance(toMinute: 5)
    check(s.runner.calls.isEmpty && s.h.recorders.isEmpty, "off for this session: no poll, no start")
    s.watcher.menuClicked(); s.watcher.flush()
    check(s.watcher.status == .on && s.scheduled.last == 0.2, "a click switches it on again and polls at once")
    s.advance(60)
    check(s.rec?.isRecording == true, "on again: the event (14:02, window until 14:17) starts")
    s.watcher.setEnabled(false); s.watcher.flush()
    s.advance(toMinute: 46)
    check(s.rec?.isRecording == true, "switching it off does not stop the recording that runs ...")
    s.advance(toMinute: 71)
    check(s.rec?.isRecording == false && s.rec?.stopReasons == [.meetingEnded], "... which still ends after the event (the stop never depends on the switch)", "\(String(describing: s.rec?.stopReasons))")
    s.watcher.setEnabled(true); s.watcher.flush()
    check(s.watcher.status == .on, "(and it can be switched on again)")
    check(!FileManager.default.fileExists(atPath: s.support.appendingPathComponent("config.env").path), "the switch writes no config.env")
}

// MARK: S-CW-10: the started ids

private func testCWStore(_ base: URL) {
    section("S-CW-10: SUPPORT_DIR/calendar-autostart.json: 0600, ids and end times only, pruned, survives a restart, bad files and bad folders do not hurt")
    let fm = FileManager.default
    let dir = base.appendingPathComponent("cw-store", isDirectory: true)
    let clock = VirtualClock(cwT0)
    func mode(_ url: URL) -> Int { (((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 }
    let store = CalendarStartedStore(supportDir: dir, clock: { clock.now })
    check(store.ids.isEmpty && !fm.fileExists(atPath: store.file.path), "a new store is empty and writes nothing until there is something to say")
    store.record(id: "a1", end: cwAt(30))
    store.record(id: "b2", end: cwAt(60))
    let json = ShellUtil.readJSON(store.file)
    let started = json?["started"] as? [String: Any]
    check(json?["schema"] as? Int == 1 && Set((started ?? [:]).keys) == ["a1", "b2"] && started?["a1"] as? String == ShellUtil.iso8601(cwAt(30)), "the file: schema 1 and id -> end time (ISO 8601)", "\(String(describing: json))")
    check(Set((json ?? [:]).keys) == ["schema", "started"], "nothing else is in the file (no title, no account, no location)", "\((json ?? [:]).keys.sorted())")
    check(mode(store.file) == 0o600, "mode 0600", String(mode(store.file), radix: 8))
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
    store.record(id: "c3", end: cwAt(90))
    check(mode(store.file) == 0o600 && ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".tmp") }.isEmpty, "a file somebody opened up is 0600 again after the next write; no temp file stays")
    let reread = CalendarStartedStore(supportDir: dir, clock: { clock.now })
    check(reread.ids == ["a1", "b2", "c3"] && reread.contains("b2") && !reread.contains("zz"), "a restart reads the ids back")

    // pruned by the end time, a day later
    clock.advance(26 * 3600)
    reread.record(id: "d4", end: clock.now.addingTimeInterval(1800))
    check(reread.ids == ["d4"], "entries whose event ended more than a day ago are pruned when the next one is written", "\(reread.ids.sorted())")
    check(CalendarStartedStore(supportDir: dir, clock: { clock.now }).ids == ["d4"], "... and the file says so")
    let late = VirtualClock(cwT0.addingTimeInterval(3 * 24 * 3600))
    check(CalendarStartedStore(supportDir: dir, clock: { late.now }).ids.isEmpty, "a file read three days later drops what is old on load")

    // a cap
    let capDir = base.appendingPathComponent("cw-store-cap", isDirectory: true)
    let cap = CalendarStartedStore(supportDir: capDir, clock: { cwT0 })
    for i in 0..<(CalendarStartedStore.maxEntries + 20) { cap.record(id: "id-\(i)", end: cwAt(Double(i) / 10)) }
    check(cap.ids.count == CalendarStartedStore.maxEntries && cap.contains("id-\(CalendarStartedStore.maxEntries + 19)") && !cap.contains("id-0"), "at most \(CalendarStartedStore.maxEntries) entries: the oldest go first")

    // damaged and strange files
    let bad = base.appendingPathComponent("cw-store-bad", isDirectory: true)
    try? fm.createDirectory(at: bad, withIntermediateDirectories: true)
    try? "this is not json".write(to: bad.appendingPathComponent("calendar-autostart.json"), atomically: true, encoding: .utf8)
    let warnsBefore = logCount("calendar-autostart.json cannot be read")
    let fromBad = CalendarStartedStore(supportDir: bad, clock: { cwT0 })
    check(fromBad.ids.isEmpty && logCount("calendar-autostart.json cannot be read") == warnsBefore + 1, "an unreadable file: an empty list and one warning")
    fromBad.record(id: "after-bad", end: cwAt(30))
    check(CalendarStartedStore(supportDir: bad, clock: { cwT0 }).ids == ["after-bad"], "... and the next write replaces it")
    let soon = ShellUtil.iso8601(cwAt(30))
    let strange = """
    {"schema":1,"started":{"":"\(soon)","ok-id":"\(soon)","bad-date":"yesterday","a-number":5,"\(String(repeating: "x", count: 2000))":"\(soon)"}}
    """
    try? strange.write(to: bad.appendingPathComponent("calendar-autostart.json"), atomically: true, encoding: .utf8)
    check(CalendarStartedStore(supportDir: bad, clock: { cwT0 }).ids == ["ok-id"], "entries with an empty or huge id, a date that is not one or a value that is not text are ignored")

    // a folder that cannot be written: remembered in memory, said once
    let blocker = base.appendingPathComponent("cw-store-blocker")
    try? "x".write(to: blocker, atomically: true, encoding: .utf8)
    let unwritable = CalendarStartedStore(supportDir: blocker.appendingPathComponent("sub", isDirectory: true), clock: { cwT0 })
    let before = logCount("cannot write calendar-autostart.json")
    unwritable.record(id: "mem-only", end: cwAt(30))
    check(unwritable.contains("mem-only") && logCount("cannot write calendar-autostart.json") == before + 1, "a folder that cannot be written: the id is kept for this run, with a warning")
}

// MARK: S-CW-11: the real command

private let fakePythonCalendarScript = #"""
#!/bin/sh
# Fake "python" for the calendar command. Usage: fakepython -m mcap gcal upcoming --from-minutes N --to-minutes M
D="$(cd "$(dirname "$0")" && pwd)"
{ echo "ARGS: $*"; echo "CWD: $(pwd -P)"; env | sort | sed 's/^/ENV /'; echo "-----"; } >> "$D/calls.log"
echo "a library warning that must never reach the answer" >&2
MODE="$(cat "$D/mode" 2>/dev/null || echo ok)"
case "$MODE" in
  hang) exec sleep 60 ;;
  crash) echo "Traceback (most recent call last):" >&2; exit 3 ;;
  garbage) echo "not json at all"; exit 0 ;;
  flood) yes "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" | head -c 3000000; exit 0 ;;
  *) cat "$D/answer.json"; exit 0 ;;
esac
"""#

private func testCWCommand(_ base: URL) {
    section("S-CW-11: the real command: arguments, working directory, clean environment, stdout only, 20 s limit, refusals; end to end with a fake python")
    let w = LauncherWorld("cw-proc", in: base, script: fakePythonCalendarScript)
    let answer = cwAnswer([cwEvent("procevt1", start: 1, end: 40)])
    try? answer.write(to: w.bin.appendingPathComponent("answer.json"), atomically: true, encoding: .utf8)
    func setMode(_ mode: String) { try? mode.write(to: w.bin.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
    let hostile = ["ANTHROPIC_API_KEY": canaryKey, "CLAUDE_CODE_OAUTH_TOKEN": canaryKey, "HOME": "/evil", "PATH": "/evil", "MCAP_CONFIG": "/tmp/mcap-cw-test.env", "AWS_SECRET_ACCESS_KEY": "x"]

    let r = PipelineLauncher.runCalendarCommand(config: w.config, policy: OrgPolicy.absent(), fromMinutes: 15, toMinutes: 3, environment: hostile)
    check(r.launched && r.status == 0 && !r.timedOut && r.refusal == nil, "a good run: launched, exit 0, not stopped")
    check(r.output == answer, "stdout is the answer, byte for byte; what the child wrote to stderr is not in it", String(r.output.prefix(120)))
    let log = w.callsLog
    check(log.contains("ARGS: -m mcap gcal upcoming --from-minutes 15 --to-minutes 3"), "the command line of the contract", String(log.prefix(200)))
    check(log.contains("CWD: \(realPath(w.config.projectDir.appendingPathComponent("pipeline")))"), "the working directory is PROJECT_DIR/pipeline like every pipeline job")
    var env: [String: String] = [:]
    for line in log.split(separator: "\n") where line.hasPrefix("ENV ") {
        let pair = line.dropFirst(4)
        if let eq = pair.firstIndex(of: "=") { env[String(pair[pair.startIndex..<eq])] = String(pair[pair.index(after: eq)...]) }
    }
    let shellAdds: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"]
    check(Set(env.keys).subtracting(shellAdds) == launcherOwnKeys.union(["MCAP_CONFIG"]), "the child gets the launcher's clean environment (and MCAP_CONFIG), nothing inherited",
          env.keys.sorted().joined(separator: " "))
    check(env["HOME"] == NSHomeDirectory() && env["PATH"] != "/evil" && !log.contains(canaryKey) && env["MCAP_CONFIG"] == "/tmp/mcap-cw-test.env", "no ANTHROPIC_* / CLAUDE_* value, the real HOME and PATH, the test config forwarded")
    if case .events(let list, let dropped) = CalendarCommandParser.parse(r) { check(list.count == 1 && list[0].id == "procevt1" && dropped == 0, "(and the parser reads it)") } else { check(false, "the parser reads the real output") }

    // the hard limit
    setMode("hang")
    let started = Date()
    let hung = PipelineLauncher.runCalendarCommand(config: w.config, policy: OrgPolicy.absent(), fromMinutes: 15, toMinutes: 3, timeout: 1, environment: [:])
    let took = Date().timeIntervalSince(started)
    check(hung.launched && hung.timedOut && took < 10, "a child that never answers is stopped after the limit (1 s here; 20 s in the app)", "timedOut \(hung.timedOut) after \(String(format: "%.1f", took)) s")
    if case .problem(let p) = CalendarCommandParser.parse(hung) { check(p.kind == .timeout, "... and the parser calls it a timeout") } else { check(false, "timeout is a problem") }

    setMode("crash")
    let crashed = PipelineLauncher.runCalendarCommand(config: w.config, policy: OrgPolicy.absent(), fromMinutes: 15, toMinutes: 3, environment: [:])
    check(crashed.launched && crashed.status == 3 && !crashed.timedOut && crashed.output.isEmpty, "a crash: its status, and no stderr in the output", "\(crashed.status) '\(crashed.output)'")
    if case .problem(let p) = CalendarCommandParser.parse(crashed) { check(p.kind == .crashed, "... a crash for the parser") } else { check(false, "crash is a problem") }
    setMode("garbage")
    if case .problem(let p) = CalendarCommandParser.parse(PipelineLauncher.runCalendarCommand(config: w.config, policy: OrgPolicy.absent(), fromMinutes: 15, toMinutes: 3, environment: [:])) { check(p.kind == .malformed, "text that is not JSON: malformed") } else { check(false, "garbage is a problem") }
    setMode("flood")
    let flood = PipelineLauncher.runCalendarCommand(config: w.config, policy: OrgPolicy.absent(), fromMinutes: 15, toMinutes: 3, timeout: 20, environment: [:])
    check(flood.launched && !flood.timedOut && flood.output.utf8.count <= PipelineLauncher.calendarOutputLimit, "3 MB of output: read to the end (the child is never stuck on a full pipe) and kept to \(PipelineLauncher.calendarOutputLimit) bytes", "\(flood.output.utf8.count) bytes, timedOut \(flood.timedOut)")
    setMode("ok")

    // refusals: nothing is started
    let callsBefore = w.callsLog
    var noPython = w.config
    noPython.pythonBin = w.bin.appendingPathComponent("no-such-python")
    let a = PipelineLauncher.runCalendarCommand(config: noPython, policy: OrgPolicy.absent(), fromMinutes: 15, toMinutes: 3, environment: [:])
    check(!a.launched && a.refusal == "python is missing", "no python: refused, with a path-free reason", "\(String(describing: a.refusal))")
    var noPipeline = w.config
    noPipeline.projectDir = base.appendingPathComponent("cw-no-pipeline", isDirectory: true)
    let b = PipelineLauncher.runCalendarCommand(config: noPipeline, policy: OrgPolicy.absent(), fromMinutes: 15, toMinutes: 3, environment: [:])
    check(!b.launched && b.refusal == "the pipeline package is missing", "no pipeline package: refused")
    let elsewhere = loPolicy(["runtime": ["root": base.appendingPathComponent("cw-elsewhere", isDirectory: true).path]])
    let c = PipelineLauncher.runCalendarCommand(config: w.config, policy: elsewhere, fromMinutes: 15, toMinutes: 3, environment: [:], fileInfo: { _ in rootOwned })
    check(!c.launched && (c.refusal ?? "").hasPrefix("the runtime is not trusted (python:") && !(c.refusal ?? "").contains(base.path), "a policy-managed Mac whose python is outside the runtime root: refused before it starts, no path in the reason", "\(String(describing: c.refusal))")
    check(w.callsLog == callsBefore, "none of the three refusals started a process")
    if case .problem(let p) = CalendarCommandParser.parse(c) { check(p.kind == .helperMissing, "a refusal is .helperMissing for the parser") } else { check(false, "refusal is a problem") }

    // a policy-managed Mac: the same python rules as the pipeline jobs (no MCAP_* variable, a PATH without the user's folders)
    let m = LauncherWorld("cw-proc-managed", in: base, script: fakePythonCalendarScript)
    try? answer.write(to: m.bin.appendingPathComponent("answer.json"), atomically: true, encoding: .utf8)
    let managed = loPolicy(["runtime": ["root": m.root.path]])
    let mr = PipelineLauncher.runCalendarCommand(config: m.config, policy: managed, fromMinutes: 15, toMinutes: 3, environment: hostile, fileInfo: { _ in rootOwned })
    check(mr.launched && mr.status == 0 && !m.callsLog.contains("ENV MCAP_CONFIG=") && m.callsLog.contains("ENV PATH=/usr/bin:/bin\n"), "a managed Mac: trusted runtime runs, no MCAP_CONFIG, PATH is /usr/bin:/bin")

    // end to end: the watcher with the real command and a fake python that answers with an event
    let e2e = CWWorld("cw-e2e", in: base)
    let e2eWorld = LauncherWorld("cw-e2e-proc", in: base, script: fakePythonCalendarScript)
    try? cwAnswer([cwEvent("e2eevt01", title: "Design review", start: 1, end: 40)]).write(to: e2eWorld.bin.appendingPathComponent("answer.json"), atomically: true, encoding: .utf8)
    e2e.runner.real = { from, to in PipelineLauncher.runCalendarCommand(config: e2eWorld.config, policy: OrgPolicy.absent(), fromMinutes: from, toMinutes: to, environment: [:]) }
    e2e.tickNow()
    check(e2e.rec?.isRecording == true && e2e.rec?.signal.platform == .manual && e2e.rec?.signal.titleHint == "Design review" && e2e.watcher.status == .on,
          "end to end: the fake python answers, the watcher decides, the controller records (manual platform, title hint)")
    check(e2eWorld.runs(of: "-m mcap gcal upcoming --from-minutes 15 --to-minutes 3") == 1, "... after exactly one run of the command", e2eWorld.callsLog)
    e2e.h.controller.shutdown(reason: .appQuit)
}

// MARK: S-CW-12: menu line and notification texts

private func testCWMenuAndTexts() {
    section("S-CW-12: the menu line 'Calendar auto-start: on / off / error: ...', the start notification and the problem notification")
    let saved = L10n.current
    defer { L10n.current = saved }
    L10n.current = .en
    let on = StatusMenuController.calendarItemState(for: .on)
    check(on.title == "Calendar auto-start: on" && on.checked && on.enabled && (on.tooltip ?? "").contains("config.env is not changed"), "on: the English line, checked, a click switches it off for this session", on.title)
    let off = StatusMenuController.calendarItemState(for: .off)
    check(off.title == "Calendar auto-start: off" && !off.checked && off.enabled && (off.tooltip ?? "").contains("this session only"), "off: unchecked, a click switches it on again (this session only)")
    let err = StatusMenuController.calendarItemState(for: .error(CalendarProblem(kind: .authRequired, message: "token expired")))
    check(err.title == "Calendar auto-start: error: sign in again (run mcap gcal auth)" && !err.checked && err.enabled && (err.tooltip ?? "").hasPrefix("token expired"), "error: names the problem and the command; the tooltip has the helper's message and 'try again'", err.title)
    let blocked = StatusMenuController.calendarItemState(for: .blocked(.recordingOff))
    check(blocked.title == "Calendar auto-start: off (recording is off by policy)" && !blocked.enabled && !blocked.checked, "blocked by the policy: off, disabled, says why", blocked.title)
    check(CalendarProblemKind.allCases.allSatisfy { !$0.menuText.isEmpty && !StatusMenuController.calendarItemState(for: .error(CalendarProblem(kind: $0, message: ""))).title.isEmpty }, "every kind of problem has a menu phrase")
    check(StatusMenuController.menuText(for: { var s = ControllerState(); s.status = .recording(.manual, since: cwT0); s.manualRecording = true; s.calendarRecording = true; return s }(), now: cwT0.addingTimeInterval(65)).headline == "Recording (calendar)  01:05",
          "the headline of a calendar recording")
    check(!ControllerState().calendarRecording, "a new state is not a calendar recording")
    L10n.current = .ko
    check(StatusMenuController.calendarItemState(for: .on).title == "캘린더 자동 시작: 켜짐" && StatusMenuController.calendarItemState(for: .off).title == "캘린더 자동 시작: 꺼짐", "the Korean lines (UI_LANGUAGE=ko)")

    // the notifications: bounded, never empty, Korean in ko, no Hangul in en, no title when it has to stay out
    let folder = URL(fileURLWithPath: "/tmp/mcap-cw-folder", isDirectory: true)
    let log = URL(fileURLWithPath: "/tmp/mcap-cw-app.log")
    let longTitle = String(repeating: "아주 긴 회의 제목 ", count: 30)
    func build() -> [(String, AppNotification)] {
        var all: [(String, AppNotification)] = []
        for (tail, hide) in [(nil, false), (NotificationText.localOnlyTail(on: true, policyExists: true), false), (NotificationText.localOnlyTail(on: false, policyExists: true), true)] as [(String?, Bool)] {
            all.append(("started calendar tail=\(tail ?? "nil") hide=\(hide)", .recordingStarted(platformLabel: NotificationText.platformName(.manual), manual: true, titleHint: longTitle, session: "s1", folder: folder, localOnlyTail: tail, hideTitle: hide, fromCalendar: true)))
        }
        all.append(("started calendar bare", .recordingStarted(platformLabel: NotificationText.platformName(.manual), manual: true, titleHint: nil, session: "s2", folder: nil, fromCalendar: true)))
        for attention in [AppNotification.CalendarAttention.notConfigured, .authRequired] {
            all.append(("problem \(attention)", .calendarProblem(attention, logFile: log)))
            all.append(("problem \(attention) no log", .calendarProblem(attention)))
        }
        return all
    }
    let ko = build()
    check(ko.allSatisfy { _, n in !n.title.isEmpty && !n.subtitle.isEmpty && !n.body.isEmpty && n.title.count <= NotificationText.titleLimit && n.subtitle.count <= NotificationText.subtitleLimit && n.body.count <= NotificationText.bodyLimit
                                  && hasHangul(n.title + n.body) && !n.summary.isEmpty && !(n.title + n.subtitle + n.body).contains(where: { $0.isNewline }) },
          "Korean: all \(ko.count) texts fit (title 40, subtitle 60, body 100), are never empty and are Korean")
    L10n.current = .en
    let en = build()
    check(en.allSatisfy { _, n in !n.title.isEmpty && !n.subtitle.isEmpty && !n.body.isEmpty && n.title.count <= NotificationText.titleLimit && n.subtitle.count <= NotificationText.subtitleLimit && n.body.count <= NotificationText.bodyLimit
                                  && !hasHangul(n.title + n.body) },
          "English: the same texts fit and hold no Hangul")
    let started = en[0].1
    check(started.kind == .recordingStarted && started.title == "Recording started · calendar" && started.body.hasPrefix("Started from the calendar event.") && started.body.contains("anyone here has not agreed"), "the start notification says it came from the calendar and how to stop it", "\(started.title) | \(started.body)")
    check(en[2].1.subtitle == "Started from the calendar event" && !(en[2].1.title + en[2].1.subtitle + en[2].1.body).contains("회의"), "a hidden title (local-only or LOG_CONTENT=0) is not in the text")
    check(started.identifier == "mcap.recording-started.s1" && started.action == .openFolder(folder.path) && !started.sound, "same identifier scheme, click opens the folder, no sound")
    let plain = AppNotification.recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "s9", folder: folder)
    check(plain.title == "Recording started · Zoom" && plain.summary == "recording started: Zoom (s9)", "a recording that did not come from the calendar reads as before")
    let auth = AppNotification.calendarProblem(.authRequired, logFile: log)
    check(auth.kind == .calendarProblem && auth.title == "Calendar auto-start needs you" && auth.subtitle == "Sign in to Google again" && auth.body.contains("mcap gcal auth") && auth.sound && auth.action == .openLog(log.path)
          && auth.identifier == "mcap.calendar-problem", "the problem notification names the command to run; a click opens the log", "\(auth.title) | \(auth.subtitle) | \(auth.body)")
    check(AppNotification.calendarProblem(.notConfigured).subtitle == "Google Calendar is not set up" && AppNotification.calendarProblem(.notConfigured).action == .none, "not configured: its own subtitle; no log, no click action")
    check(!(auth.title + auth.subtitle + auth.body + auth.summary).contains("@") && !auth.summary.contains("http"), "no account, address or URL in any text")
}

/// The command line the app starts is the one the pipeline's `gcal` command takes (only checked once the pipeline tree has the command).
private func testCWDriftGuard() {
    section("S-CW-13: the contract: `gcal upcoming --from-minutes N --to-minutes M` is a command of the pipeline (when this tree has it)")
    guard let repo = csRepoRoot() else {
        check(false, "the repo is found next to the working directory or the app (pipeline/mcap/cli.py)", "cwd \(FileManager.default.currentDirectoryPath)")
        return
    }
    let cli = (try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/cli.py"), encoding: .utf8)) ?? ""
    let gcalFiles = ((try? FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("pipeline/mcap").path)) ?? []).filter { $0.hasPrefix("gcal") }
    let text = cli + gcalFiles.compactMap { try? String(contentsOf: repo.appendingPathComponent("pipeline/mcap/\($0)"), encoding: .utf8) }.joined()
    guard text.contains("\"gcal\"") else {
        check(true, "(this tree has no `gcal` command yet: nothing to compare; this check starts to bite when the calendar client is merged)")
        return
    }
    for needle in ["\"upcoming\"", "--from-minutes", "--to-minutes", "not_configured", "auth_required", "lane_denied", "api_error", "has_conference", "event_type"] {
        check(text.contains(needle), "the pipeline's gcal command still has '\(needle)'")
    }
}

/// All of the calendar auto-start checks, in this order.
private func testCalendarWatcher(_ base: URL) {
    testCWConfig(base)
    testCWRules()
    testCWParser()
    testCWDay(base)
    testCWSkips(base)
    testCWErrors(base)
    testCWGate(base)
    testCWPrivacy(base)
    testCWOffAndThreads(base)
    testCWStore(base)
    testCWCommand(base)
    testCWMenuAndTexts()
    testCWDriftGuard()
}
