import Foundation
import Darwin
import CoreAudio

// =====================================================================================
// `<short name> selftest-detector`: device-free scripted scenarios for the detection stack (SPEC 5 / 13.1).
//
// No microphone, no AppleScript / Apple Event to any app, no permissions, no Chrome contact (every tab query goes to a
// FakeChromeBackend). A virtual clock drives
//   DetectionStateMachine (pure),  the platform formulas (pure),  and the whole Detector.poll() ->
//   state machine pipeline against scripted Core Audio / libproc / Chrome inputs (SimWorld, FakeChromeBackend).
// The only "real" system access: a loopback UDP socket in this very process (libproc socket reader), and the probe
// collector check, which reads Core Audio process / device properties and the libproc tables like `probe` does
// (read-only, no device is opened, nothing prompts). The function that can raise the Automation prompt is only ever called
// with injected seams (a recording closure instead of the Apple Event permission call, never its real defaults); its pure
// decision (TabQueryPolicy.promptRefusal) and the real LaunchGuard value of this process are checked too.
// app.log is redirected into a temp dir for the duration of the run. Exit code 0 only if every check passed.
// =====================================================================================

private var passed = 0
private var failed = 0

private func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
        print("  ok    \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  FAIL  \(name)\(d.isEmpty ? "" : "  -> \(d)")")
    }
}

private func section(_ title: String) { print("\n== \(title)") }

// MARK: - Builders

private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

private func sig(_ platform: Platform, _ on: Bool = true, key: String? = nil, conf: Confidence = .high, title: String? = nil) -> PlatformSignal {
    return PlatformSignal(platform: platform, inCall: on, confidence: conf, titleHint: title,
                          meetingURL: key.map { "https://meet.google.com/\($0)" }, meetingKey: key, bundleID: nil, evidence: ["selftest"])
}

private func proc(_ pid: Int32, _ bundle: String, `in` i: Bool = false, out o: Bool = false) -> AudioProcessInfo {
    return AudioProcessInfo(objectID: UInt32(pid) + 1000, pid: pid, bundleID: bundle, isRunningInput: i, isRunningOutput: o)
}

private func chromeProcs(inp: Bool = false, out: Bool = false) -> [AudioProcessInfo] {
    return [proc(764, "com.google.Chrome"), proc(4214, "com.google.Chrome.helper", in: inp, out: out), proc(4215, "com.google.Chrome.helper")]
}

private func zoomProcs(inp: Bool = false, out: Bool = false) -> [AudioProcessInfo] {
    return [proc(787, "us.zoom.xos", in: inp, out: out), proc(1455, "us.zoom.caphost")]
}

private func teamsProcs(inp: Bool = false, out: Bool = false) -> [AudioProcessInfo] {
    return [proc(5000, "com.microsoft.teams2", in: inp, out: out), proc(5001, "com.microsoft.teams2.helper")]
}

/// Deterministic tab id for a URL (a different URL is a different tab; pass `id:` to model two tabs on one URL).
private func stableID(_ s: String) -> String {
    return "t" + String(s.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) } % 1_000_000)
}

private func tab(_ url: String, title: String = "", active: Bool = false, incognito: Bool = false,
                 id: String? = nil, window: String = "1", order: Int = 0) -> ChromeTab {
    return ChromeTab(windowID: window, isActive: active, url: url, title: title, incognito: incognito,
                     tabID: id ?? stableID(url), windowOrder: order)
}

private func meetTab(_ code: String, kind: MeetTab.Kind = .code, id: String? = nil, active: Bool = false,
                     window: String = "1", order: Int = 0) -> MeetTab {
    return MeetTab(kind: kind, key: code, url: "https://meet.google.com/\(code)", title: nil, isActive: active, incognito: false,
                   windowID: window, tabID: id ?? "t-\(code)", windowOrder: order)
}

private func kind(_ a: StateAction) -> String? {
    switch a {
    case .none: return nil
    case .start: return "start"
    case .split: return "split"
    case .stop(let r): return "stop:\(r.rawValue)"
    }
}

// MARK: - State machine harness (virtual clock)

private final class MachineRun {
    var machine: DetectionStateMachine
    var now = epoch
    private(set) var t = 0
    private(set) var events: [(t: Int, kind: String)] = []
    private(set) var started: PlatformSignal?

    init(debounce: TimeInterval = 4, grace: TimeInterval = 20, weakDebounce: TimeInterval = 0) {
        machine = DetectionStateMachine(startDebounce: debounce, grace: grace, weakDebounce: weakDebounce)
    }

    @discardableResult
    func tick(_ signals: [PlatformSignal], step: Int = 1) -> StateAction {
        now = now.addingTimeInterval(TimeInterval(step))
        t += step
        let action = machine.step(now: now, snapshot: DetectionSnapshot(time: now, signals: signals))
        if let k = kind(action) { events.append((t, k)) }
        if case .start(let s) = action { started = s }
        return action
    }

    func run(_ seconds: Int, step: Int = 1, _ signals: [PlatformSignal]) {
        var elapsed = 0
        while elapsed < seconds { tick(signals, step: step); elapsed += step }
    }

    func run(_ seconds: Int, step: Int = 1, _ generate: (Int) -> [PlatformSignal]) {
        var elapsed = 0
        while elapsed < seconds { tick(generate(t + step), step: step); elapsed += step }
    }

    func first(_ prefix: String, after: Int = 0) -> Int? {
        return events.first { $0.kind.hasPrefix(prefix) && $0.t > after }?.t
    }

    func count(_ prefix: String) -> Int { events.filter { $0.kind.hasPrefix(prefix) }.count }
}

// MARK: - Detector harness (virtual world)

private final class FakeChromeBackend: ChromeBackend {
    var running = true
    var automation: AutomationState = .authorized
    var result: TabQueryResult = .ok([])
    private(set) var runningCalls = 0
    private(set) var automationCalls = 0
    private(set) var listCalls = 0

    var totalCalls: Int { runningCalls + automationCalls + listCalls }

    func isRunning(bundleID: String) -> Bool { runningCalls += 1; return running }
    func automationState(bundleID: String) -> AutomationState { automationCalls += 1; return automation }
    func listTabs(bundleID: String) -> TabQueryResult { listCalls += 1; return result }
}

private final class SimWorld {
    var now = epoch
    var processes: [AudioProcessInfo] = []
    var udp: [Int32: Int] = [:]
    var running: [String: [Int32]] = [:]            // NSRunningApplication answers
    var apps: [String: CallAppInfo] = [:]           // the name / "is a GUI app" of a call app, by main bundle id
    var guiByDefault = true                         // an app without an entry above is a GUI app named after the last part of its bundle id
    let backend = FakeChromeBackend()
}

private final class DetectSim {
    let world = SimWorld()
    let detector: Detector
    var machine: DetectionStateMachine
    private(set) var events: [(t: Int, kind: String)] = []
    private(set) var t = 0
    private(set) var lastSnapshot: DetectionSnapshot?
    /// How often each platform's signal turned inCall (rising edges), and the signals the machine started on.
    private(set) var rises: [Platform: Int] = [:]
    private(set) var started: [PlatformSignal] = []
    /// The signals the machine split to (a meeting that took a running recording over).
    private(set) var splitTo: [PlatformSignal] = []
    private var wasInCall: [Platform: Bool] = [:]

    init(platforms: [Platform] = [.meet, .zoom, .teams], grace: TimeInterval = 20, debounce: TimeInterval = 4,
         policy: TabQueryPolicy = TabQueryPolicy(enabled: true, reason: "selftest"), browsers: [String] = ["com.google.Chrome"],
         alwaysQueryTabs: Bool = false, weakDebounce: TimeInterval = 0, zoomTier: ZoomTierSettings = .defaults,
         calls: CallDetectSettings = .off, callStore: CallAppStore? = nil) {
        var cfg = AppConfig.defaults()
        cfg.enabledPlatforms = platforms
        cfg.browserBundleIDs = browsers
        cfg.grace = grace
        cfg.startDebounce = debounce
        let world = self.world
        // The same wiring as DetectorInputs.live: Meet tabs only when Meet is enabled, the web meeting table only when CALL_BROWSER_URLS asks for it.
        let chromeTabs = ChromeTabs(policy: policy, browserBundleIDs: browsers, backend: world.backend, alwaysQuery: alwaysQueryTabs,
                                    keepMeetTabs: platforms.contains(.meet), matchWebMeetings: calls.needsBrowserAutomation(for: cfg))
        detector = Detector(config: cfg, inputs: DetectorInputs(
            now: { world.now },
            audioProcesses: { interesting in world.processes.filter { interesting($0.bundleID) } },
            audioObjectCount: { world.processes.count },
            audioError: { nil },
            udpCount: { world.udp[$0] },
            runningPIDs: { world.running[$0] ?? [] },
            tabs: { chromeTabs.info(audioActive: $0, now: $1, maxAge: $2) },
            callProcesses: { interesting, scanOthers in
                world.processes.filter { interesting($0.bundleID) || (scanOthers && $0.isRunningInput && !$0.bundleID.isEmpty) }
            },
            callAppInfo: { id in
                world.apps[id] ?? (world.guiByDefault ? CallAppInfo(name: id.split(separator: ".").last.map(String.init) ?? id, isGUI: true) : nil)
            }), zoomTier: zoomTier, calls: calls, callStore: callStore)
        machine = DetectionStateMachine(startDebounce: debounce, grace: grace, weakDebounce: weakDebounce)
    }

    func run(_ seconds: Int, step: Int = 2) {
        var elapsed = 0
        while elapsed < seconds {
            world.now = world.now.addingTimeInterval(TimeInterval(step))
            t += step
            let snapshot = detector.poll()
            lastSnapshot = snapshot
            for sg in snapshot.signals {
                if sg.inCall && wasInCall[sg.platform] != true { rises[sg.platform, default: 0] += 1 }
                wasInCall[sg.platform] = sg.inCall
            }
            let action = machine.step(now: world.now, snapshot: snapshot)
            if let k = kind(action) { events.append((t, k)) }
            if case .start(let sg) = action { started.append(sg) }
            if case .split(let sg) = action { splitTo.append(sg) }
            elapsed += step
        }
    }

    func first(_ prefix: String, after: Int = 0) -> Int? { events.first { $0.kind.hasPrefix(prefix) && $0.t > after }?.t }
    func count(_ prefix: String) -> Int { events.filter { $0.kind.hasPrefix(prefix) }.count }
    func signal(_ p: Platform) -> PlatformSignal? { lastSnapshot?.signals.first { $0.platform == p } }
    /// The call signals of the last poll (one per tracked app) and the one of an app (main bundle id, any case).
    func callSignals() -> [PlatformSignal] { lastSnapshot?.signals.filter { $0.platform == .call } ?? [] }
    func callSignal(_ bundleID: String) -> PlatformSignal? { callSignals().first { $0.bundleID?.lowercased() == bundleID.lowercased() } }
}

// MARK: - Entry point

func runSelftestDetector() -> Int32 {
    passed = 0
    failed = 0

    // Keep the run out of the real app.log (and quiet unless MC_LOG_STDERR=1).
    let env = ProcessInfo.processInfo.environment
    let savedLogFile = Log.fileURL
    let savedEcho = Log.echoToStderr
    let tmpBase = (env["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 }) ?? NSTemporaryDirectory()
    let logDir = URL(fileURLWithPath: tmpBase, isDirectory: true).appendingPathComponent("mcap-selftest-detector-\(getpid())", isDirectory: true)
    Log.fileURL = logDir.appendingPathComponent("app.log")
    Log.echoToStderr = env["MC_LOG_STDERR"] == "1"
    defer {
        Log.flush()
        Log.fileURL = savedLogFile
        Log.echoToStderr = savedEcho
        try? FileManager.default.removeItem(at: logDir)
    }

    testHysteresis()
    testFamilyMatcher()
    testAudioMonitorCache()
    testMeetURLAndTabs()
    testTabChooser()
    testPolicyAndSafety()
    testChromeTabsGate()
    testFormulas()
    testNetworkProbe()
    testStateMachineDebounce()
    testStateMachineGrace()
    testStateMachineSplit()
    testStateMachineManualAndReset()
    testStateMachineClock()
    testDetectorMeet()
    testDetectorMeetFallbacks()
    testDetectorMeetSplit()
    testDetectorZoomTeams()
    testZoomEvidenceTiers()
    testZoomTierMachine()
    testZoomTierPipeline()
    testDetectorIgnoresOthers()
    testMeetOffByDefault()
    testCallKnownApps()
    testCallHelpers()
    testCallExtraApps()
    testCallSettings()
    testCallGeneric()
    testCallDenyList()
    testCallDecisions()
    testCallNoDoubleStart()
    testCallModes()
    testCallMeetExclusion()
    testWebMeetingURLs()
    testWebMeetingPipeline()
    testCallStateMachine()
    testCallMonitorAndCompat()
    testProbeRendering()

    print("")
    if failed == 0 {
        print("PASS (\(passed) checks)")
        return 0
    }
    print("FAIL (\(failed) of \(passed + failed) checks failed)")
    return 1
}

// MARK: - Smoothing

private func testHysteresis() {
    section("smoothing (HysteresisFlag)")
    func at(_ s: Double) -> Date { epoch.addingTimeInterval(s) }

    var input = HysteresisFlag(rise: DetectionTuning.inputRise, fall: DetectionTuning.fall)
    check(!input.update(raw: true, now: at(0)), "input: first poll on is not yet stable")
    check(input.update(raw: true, now: at(2)), "input: on for 2 polls (2 s) is stable")
    check(input.update(raw: false, now: at(4)), "input: one missed poll is bridged")
    check(input.update(raw: true, now: at(6)), "input: back on after a blip stays stable")
    check(input.update(raw: false, now: at(8)), "input: still bridged 2 s after the last true")
    check(!input.update(raw: false, now: at(10)), "input: off after 3+ s without it")

    var output = HysteresisFlag(rise: DetectionTuning.outputRise, fall: DetectionTuning.fall)
    var results: [Bool] = []
    for s in stride(from: 0.0, through: 8.0, by: 2.0) { results.append(output.update(raw: true, now: at(s))) }
    check(results == [false, false, false, false, true], "output: needs 5 polls (8 s span) at 2 s polling", "\(results)")
    var shortRun = HysteresisFlag(rise: DetectionTuning.outputRise, fall: DetectionTuning.fall)
    for s in stride(from: 0.0, through: 6.0, by: 2.0) { _ = shortRun.update(raw: true, now: at(s)) }
    check(!shortRun.update(raw: false, now: at(8)), "output: a 4-poll burst (ringtone, chime) never turns on")
    check(!shortRun.update(raw: true, now: at(10)), "output: a broken run restarts from zero")
    check(shortRun.update(raw: true, now: at(18)), "output: and turns on 7+ s after the restart")

    var immediate = HysteresisFlag(rise: 0, fall: 0)
    check(immediate.update(raw: true, now: at(0)) && !immediate.update(raw: false, now: at(1)), "rise 0 / fall 0 follows the raw value")
    var backwards = HysteresisFlag(rise: 1.5, fall: 3)
    _ = backwards.update(raw: true, now: at(100))
    _ = backwards.update(raw: true, now: at(102))
    check(backwards.update(raw: false, now: at(0)), "a clock that moves backwards re-anchors the hold instead of crashing")
    check(!backwards.update(raw: false, now: at(10)), "after a backwards jump the flag still turns off (does not wait for the old clock)")
}

// MARK: - Families

private func testFamilyMatcher() {
    section("family mapping by bundle id")
    let m = FamilyMatcher(browserBundleIDs: ["com.google.Chrome"], enabledPlatforms: [.meet, .zoom, .teams])
    check(m.platform(of: "com.google.Chrome") == .meet, "chrome main -> meet")
    check(m.platform(of: "com.google.Chrome.helper") == .meet, "chrome audio-service helper -> meet")
    check(m.platform(of: "com.google.Chrome.helper.Renderer") == .meet, "chrome renderer helper -> meet")
    check(m.platform(of: "com.google.chrome") == .meet, "bundle ids compare case-insensitively")
    check(m.platform(of: "us.zoom.xos") == .zoom, "zoom main -> zoom")
    check(m.platform(of: "us.zoom.caphost") == .zoom, "zoom caphost -> zoom")
    check(m.platform(of: "us.zoom.ZoomClips") == nil, "other us.zoom.* apps are not the call")
    check(m.platform(of: "com.microsoft.teams2") == .teams, "new Teams -> teams")
    check(m.platform(of: "com.microsoft.teams2.helper") == .teams, "new Teams helper -> teams")
    check(m.platform(of: "com.microsoft.teams") == .teams, "classic Teams -> teams")
    check(m.platform(of: AppInfo.bundleID) == nil, "our own app is excluded")
    check(m.platform(of: AppInfo.bundleID + ".helper") == nil, "our own helpers are excluded")
    check(AppInfo.resolveBundleID(nil) == "org.meetingcapture.app" && AppInfo.resolveBundleID("") == AppInfo.defaultBundleID && AppInfo.resolveBundleID("com.example.mine") == "com.example.mine",
          "bundle id: a bare binary (no Info.plist) falls back to the neutral default, the identifier of a bundle wins")
    check(AppInfo.bundleID == (Bundle.main.bundleIdentifier ?? AppInfo.defaultBundleID), "bundle id: the running app's identifier is the one in its Info.plist when there is one")
    check(FamilyMatcher.ownBundlePrefix == AppInfo.bundleID.lowercased() && SystemAudioTap.aggregateUIDPrefix == AppInfo.bundleID + ".tap." && LaunchGuard.bundleID == AppInfo.bundleID,
          "bundle id: the own-process prefix, the aggregate-device prefix and the launch guard derive from it")
    check(CallApps.isBuiltInDenied(AppInfo.bundleID) && CallApps.isBuiltInDenied(AppInfo.bundleID + ".helper"), "bundle id: the generic call rule denies our own id, whatever it is")
    // the own id is matched at a dot: an id that only starts with the same characters is another app (a short id of ours must not blind the detector to it)
    let ownLower = AppInfo.bundleID.lowercased()
    let lookalike = FamilyMatcher(browserBundleIDs: [ownLower + "x"], enabledPlatforms: [.meet])
    check(FamilyMatcher.isOwn(ownLower) && FamilyMatcher.isOwn(ownLower + ".helper") && !FamilyMatcher.isOwn(ownLower + "x") && !FamilyMatcher.isOwn(ownLower + "-two") && !FamilyMatcher.isOwn(""),
          "bundle id: our own id and its children are ours, an id that merely starts with it is not")
    check(lookalike.platform(of: ownLower + "x.helper") == .meet && lookalike.platform(of: ownLower + ".helper") == nil, "bundle id: the detector still sees an app whose id starts with ours, and never our own helper")
    check(!CallApps.isBuiltInDenied(AppInfo.bundleID + "x") && ExtraMeetingApps.parse(AppInfo.bundleID + "x").apps.count == 1 && ExtraMeetingApps.parse(AppInfo.bundleID + ".x").apps.isEmpty,
          "bundle id: the generic call rule and EXTRA_MEETING_APPS refuse our own children and accept a look-alike")
    check(m.platform(of: "com.apple.VoiceMemos") == nil && m.platform(of: "com.openai.chat") == nil && m.platform(of: "com.tinyspeck.slackmacgap") == nil,
          "dictation / voice memo / chat apps are ignored")
    check(m.platform(of: "") == nil, "non-bundled processes (empty bundle id) are ignored")
    let ownRoot = String(AppInfo.bundleID.prefix(while: { $0 != "." }))        // the first label of our id: a browser prefix that would match our own id
    let overlapping = FamilyMatcher(browserBundleIDs: [ownRoot], enabledPlatforms: [.meet])
    check(overlapping.platform(of: AppInfo.bundleID) == nil && overlapping.platform(of: ownRoot + ".other") == .meet,
          "our own bundle id is excluded even when a family prefix would match it")
    let onlyZoom = FamilyMatcher(browserBundleIDs: ["com.google.Chrome"], enabledPlatforms: [.zoom])
    check(onlyZoom.platform(of: "com.google.Chrome.helper") == nil && onlyZoom.platform(of: "us.zoom.xos") == .zoom, "disabled platforms never match")
    let arc = FamilyMatcher(browserBundleIDs: ["company.thebrowser.Browser"], enabledPlatforms: [.meet])
    check(arc.platform(of: "company.thebrowser.Browser.helper") == .meet && arc.platform(of: "com.google.Chrome") == nil, "BROWSER_BUNDLE_IDS drives the Meet family")

    let procs = chromeProcs(inp: true) + zoomProcs() + [proc(9, "com.apple.Music", out: true)]
    let groups = m.group(procs)
    check(groups[.meet]?.processes.count == 3 && groups[.meet]?.rawInput == true && groups[.meet]?.rawOutput == false, "group: chrome processes aggregate (any in)")
    check(groups[.zoom]?.pids == [787, 1455] && groups[.teams] == nil, "group: zoom pids, no teams entry")
    check(groups[.meet]?.ioSummary == "4214:in", "ioSummary names the pid that carries the flag", groups[.meet]?.ioSummary ?? "nil")
}

private func testAudioMonitorCache() {
    section("audio process monitor: identity cache across a failed enumeration")
    var listing: [AudioObjectID]? = [10, 11]
    var identities: [AudioObjectID: (pid: pid_t, bundleID: String)] = [10: (100, "com.google.Chrome.helper"), 11: (101, "com.apple.Music")]
    var reads = 0
    let monitor = AudioProcessMonitor(source: AudioProcessMonitor.Source(
        list: { listing },
        identity: { id in reads += 1; return identities[id] },
        flags: { _ in (input: true, output: false) }))
    var r = monitor.poll { $0.hasPrefix("com.google.Chrome") }
    check(r.count == 1 && r[0].pid == 100 && r[0].isRunningInput && !r[0].isRunningOutput && monitor.totalObjects == 2, "monitor: family process read with its flags", "\(r)")
    _ = monitor.poll { $0.hasPrefix("com.google.Chrome") }
    check(reads == 2, "monitor: identities are cached (each object id read once)", "reads \(reads)")

    listing = nil                                                   // coreaudiod restarts: the list call fails ...
    r = monitor.poll { _ in true }
    check(r.isEmpty && monitor.lastError != nil, "monitor: a failed enumeration returns nothing and records the error")
    listing = [10]                                                  // ... and comes back with object id 10 owned by another process
    identities[10] = (200, "us.zoom.xos")
    r = monitor.poll { _ in true }
    check(r.count == 1 && r[0].pid == 200 && r[0].bundleID == "us.zoom.xos" && monitor.lastError == nil,
          "monitor: after a failed list the identity cache is dropped, so a recycled object id is not attributed to the old process", "\(r)")
}

// MARK: - Meet URLs and tabs

private func testMeetURLAndTabs() {
    section("Meet URL classifier and tab parsing")
    check(MeetURL.classify("https://meet.google.com/abc-defg-hij") == .meeting(code: "abc-defg-hij"), "meeting code")
    check(MeetURL.classify("https://meet.google.com/abc-defg-hij?authuser=1&hs=179") == .meeting(code: "abc-defg-hij"), "code with query")
    check(MeetURL.classify("https://meet.google.com/ABC-DEFG-HIJ/") == .meeting(code: "abc-defg-hij"), "code upper case + trailing slash")
    check(MeetURL.classify("https://meet.google.com/abc-defg-hij#fragment") == .meeting(code: "abc-defg-hij"), "code with fragment")
    check(MeetURL.classify("  https://meet.google.com/abc-defg-hij \n") == .meeting(code: "abc-defg-hij"), "surrounding whitespace")
    check(MeetURL.classify("https://meet.google.com/lookup/abcd1234") == .lookup, "calendar lookup redirect")
    check(MeetURL.classify("https://meet.google.com/landing") == .nonMeeting("landing"), "landing page")
    check(MeetURL.classify("https://meet.google.com/new") == .nonMeeting("new"), "new meeting page")
    check(MeetURL.classify("https://meet.google.com/") == .nonMeeting(""), "home")
    check(MeetURL.classify("https://meet.google.com/?authuser=1") == .nonMeeting(""), "home with query")
    check(MeetURL.classify("https://meet.google.com/_meet/xyz") == .nonMeeting("_meet"), "_meet internal path")
    check(MeetURL.classify("https://example.com/abc-defg-hij") == .notMeet, "other host")
    check(MeetURL.classify("https://meet.google.com.evil.com/abc-defg-hij") == .notMeet, "look-alike host is rejected")
    check(MeetURL.classify("https://evil.com/meet.google.com/abc-defg-hij") == .notMeet, "host in path is rejected")
    check(MeetURL.classify("http://meet.google.com/abc-defg-hij") == .notMeet, "plain http is not Meet")
    check(MeetURL.classify("") == .notMeet && MeetURL.classify("not a url") == .notMeet, "garbage never crashes")
    check(MeetURL.classify("https://meet.google.com/abc-defg") == .nonMeeting("abc-defg"), "malformed code is not a code")
    check(MeetURL.isNicknameCandidate("team-standup"), "nickname slug is a weak candidate")
    check(!MeetURL.isNicknameCandidate("landing") && !MeetURL.isNicknameCandidate("") && !MeetURL.isNicknameCandidate("ab"), "reserved / empty / tiny slugs are not")

    func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
        let l = NSAppleEventDescriptor.list()
        for (i, it) in items.enumerated() { l.insert(it, at: i + 1) }
        return l
    }
    let urls = list([NSAppleEventDescriptor(string: "https://example.com/private"), NSAppleEventDescriptor(string: "https://meet.google.com/abc-defg-hij?authuser=2")])
    let titles = list([NSAppleEventDescriptor(string: "Secret doc"), NSAppleEventDescriptor(string: "Meet \u{2013} Weekly sync")])
    let tabIDs1 = list([NSAppleEventDescriptor(string: "9001"), NSAppleEventDescriptor(string: "9002")])
    // Current shape: {window id, active tab index, URLs, titles, mode, tab ids, window index (1 = front)}.
    let w1 = list([NSAppleEventDescriptor(string: "123"), NSAppleEventDescriptor(int32: 2), urls, titles, NSAppleEventDescriptor(string: "normal"),
                   tabIDs1, NSAppleEventDescriptor(int32: 1)])
    let urls2 = list([NSAppleEventDescriptor(string: "https://meet.google.com/new"), NSAppleEventDescriptor(string: "https://meet.google.com/team-standup")])
    let titles2 = list([NSAppleEventDescriptor(string: "Meet"), NSAppleEventDescriptor(string: "")])
    // Older five-item shape (no ids, no window index): positions are the fallback.
    let w2 = list([NSAppleEventDescriptor(string: "456"), NSAppleEventDescriptor(int32: 1), urls2, titles2, NSAppleEventDescriptor(string: "incognito")])
    let parsed = ChromeTabParsing.parseTabs(list([w1, w2, NSAppleEventDescriptor(string: "garbage window")]))
    check(parsed.count == 4, "parseTabs: 4 tabs from 2 windows, malformed entry skipped", "\(parsed.count)")
    check(parsed.count == 4 && parsed[1].isActive && !parsed[0].isActive && parsed[2].isActive, "parseTabs: active tab index per window")
    check(parsed.count == 4 && parsed[2].incognito && !parsed[0].incognito, "parseTabs: window mode")
    check(ChromeTabParsing.parseTabs(NSAppleEventDescriptor.list()).isEmpty && ChromeTabParsing.parseTabs(NSAppleEventDescriptor(string: "x")).isEmpty, "parseTabs: empty / wrong shape")
    check(parsed.count == 4 && parsed[0].tabID == "9001" && parsed[1].tabID == "9002" && parsed[0].windowID == "123",
          "parseTabs: window id and tab ids are read", "\(parsed.map { $0.tabID })")
    check(parsed.count == 4 && parsed[2].tabID == "#1" && parsed[3].tabID == "#2" && parsed[2].windowID == "456",
          "parseTabs: a window without ids falls back to the tab position (never an empty id)", "\(parsed.map { $0.tabID })")
    check(parsed.count == 4 && parsed[0].windowOrder == 0 && parsed[1].windowOrder == 0 && parsed[2].windowOrder == 1,
          "parseTabs: window index 1 = front window (order 0); no index = list position", "\(parsed.map { $0.windowOrder })")
    let shortIDs = list([NSAppleEventDescriptor(string: "7001")])
    let wShort = list([NSAppleEventDescriptor(string: "9"), NSAppleEventDescriptor(int32: 1), urls, titles, NSAppleEventDescriptor(string: "normal"), shortIDs, NSAppleEventDescriptor(int32: 0)])
    let partial = ChromeTabParsing.parseTabs(list([wShort]))
    check(partial.count == 2 && partial[0].tabID == "7001" && partial[1].tabID == "#2" && partial[0].windowOrder == 0,
          "parseTabs: fewer ids than tabs / unreadable window index -> position fallbacks", "\(partial.map { $0.tabID }) \(partial.map { $0.windowOrder })")
    check(Set(parsed.map { TabIdentity(windowID: $0.windowID, tabID: $0.tabID) }).count == 4, "parseTabs: every tab gets a distinct identity")
    let wBack = list([NSAppleEventDescriptor(string: "10"), NSAppleEventDescriptor(int32: 1), urls, titles, NSAppleEventDescriptor(string: "normal"), tabIDs1, NSAppleEventDescriptor(int32: 2)])
    let wFront = list([NSAppleEventDescriptor(string: "20"), NSAppleEventDescriptor(int32: 1), urls, titles, NSAppleEventDescriptor(string: "normal"), tabIDs1, NSAppleEventDescriptor(int32: 1)])
    let ordered = ChromeTabParsing.parseTabs(list([wBack, wFront]))
    check(ordered.count == 4 && ordered[0].windowOrder == 1 && ordered[2].windowOrder == 0,
          "parseTabs: the window order comes from Chrome's window index, not from the position in the list", "\(ordered.map { $0.windowOrder })")

    let hosts = ChromeTabParsing.meetHostTabs(in: parsed)
    check(hosts.count == 3, "meetHostTabs: only meet.google.com tabs survive", "\(hosts.count)")
    check(!hosts.contains { $0.url.contains("example.com") || ($0.title ?? "").contains("Secret") }, "meetHostTabs: other tabs' URLs and titles are dropped")
    check(hosts.first?.kind == .code && hosts.first?.url == "https://meet.google.com/abc-defg-hij" && hosts.first?.title == "Meet \u{2013} Weekly sync",
          "meetHostTabs: code tab, query stripped, title kept")
    check(hosts.first?.identity == TabIdentity(windowID: "123", tabID: "9002") && hosts.first?.isFrontActive == true && hosts.last?.isFrontActive == false,
          "meetHostTabs: identity carried over; only the active tab of the front window is front-active")
    check(hosts.count == 3 && hosts[1].kind == .other && hosts[2].kind == .nickname && hosts[2].title == nil, "meetHostTabs: /new is not a candidate, nickname is weak, empty title -> nil")
}

private func testTabChooser() {
    section("Meet tab choice (several tabs, by tab identity)")
    func at(_ s: Double) -> Date { epoch.addingTimeInterval(s) }
    let R = "rrr-rrrr-rrr", S = "sss-ssss-sss", A = "aaa-bbbb-ccc", B = "ddd-eeee-fff"

    // --- first sight
    let c0 = MeetTabChooser(acceptAfter: 4)
    check(c0.choose(from: [], observedAt: at(0)) == nil, "no tabs -> none")
    check(c0.choose(from: [meetTab(A)], observedAt: at(2))?.key == A, "single tab")

    func first(_ tabs: [MeetTab]) -> MeetTab? { return MeetTabChooser().choose(from: tabs, observedAt: at(0)) }
    check(first([meetTab(A, active: true, window: "1", order: 1), meetTab(B, active: true, window: "2", order: 0)])?.key == B,
          "first sight: the active tab of the FRONT window beats another window's active tab")
    check(first([meetTab(A), meetTab(B, active: true)])?.key == B, "first sight: the active tab beats a background tab in the same window")
    check(first([meetTab(A, window: "1", order: 1), meetTab(B, window: "2", order: 0)])?.key == B, "first sight, nothing active: the front window wins")
    check(first([meetTab(A), meetTab(B)])?.key == A, "first sight, no difference at all: tab order")
    check(first([meetTab("team-standup", kind: .nickname, active: true), meetTab(A)])?.key == A, "first sight: a meeting code beats a nickname tab, even a front one")
    check(first([meetTab("team-standup", kind: .nickname)])?.kind == .nickname, "a nickname tab alone is chosen")
    let dup = first([meetTab(R, id: "old"), meetTab(R, id: "new", active: true)])
    check(dup?.tabID == "new", "the same code in two tabs: the front active one is the chosen tab (identity, not code)", dup?.tabID ?? "nil")

    // --- sticky choice and take-over by a NEW tab
    let c1 = MeetTabChooser(acceptAfter: 4)
    check(c1.choose(from: [meetTab(A, active: true)], observedAt: at(0))?.key == A, "call tab chosen at first sight")
    check(c1.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(4))?.key == A, "a new tab that is front for 0 s does not take over")
    check(c1.takeoverPending, "...but it is being timed (the detector refreshes the tab list fast)")
    check(c1.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(4))?.key == A, "the same observation again changes nothing")
    check(c1.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(7))?.key == A, "front for 3 s is still not enough")
    check(c1.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(8))?.key == B, "front for the debounce time (4 s): the new tab takes over")
    check(!c1.takeoverPending, "no take-over pending after the switch")
    check(c1.choose(from: [meetTab(A), meetTab(B)], observedAt: at(12))?.key == B, "the new choice is sticky even when the user looks at another tab")
    check(c1.choose(from: [meetTab(A, active: true), meetTab(B)], observedAt: at(16))?.key == B, "the previous call tab needs the same 4 s to win it back")
    check(c1.choose(from: [meetTab(A, active: true), meetTab(B)], observedAt: at(20))?.key == A, "a tab that was chosen before can take the choice back (peek and return)")

    let c2 = MeetTabChooser(acceptAfter: 4)
    _ = c2.choose(from: [meetTab(A, active: true)], observedAt: at(0))
    var keys: [String] = []
    for t in stride(from: 4.0, through: 60.0, by: 4.0) { keys.append(c2.choose(from: [meetTab(A, active: true), meetTab(B)], observedAt: at(t))?.key ?? "nil") }
    check(Set(keys) == [A] && !c2.takeoverPending, "a new tab in the background (never the active tab) never takes over")

    let c3 = MeetTabChooser(acceptAfter: 4)
    _ = c3.choose(from: [meetTab(A, active: true)], observedAt: at(0))
    _ = c3.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(4))     // B front, timer starts
    _ = c3.choose(from: [meetTab(A, active: true), meetTab(B)], observedAt: at(6))     // user is back on A: the timer resets
    check(c3.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(10))?.key == A, "a peek of under the debounce restarts the timer")
    check(c3.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(14))?.key == B, "...and only continuous front time counts")

    let c4 = MeetTabChooser(acceptAfter: 4)
    _ = c4.choose(from: [meetTab(A, active: true), meetTab(B)], observedAt: at(0))      // both open at first sight: A is the call
    var old: [String] = []
    for t in stride(from: 4.0, through: 40.0, by: 4.0) { old.append(c4.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(t))?.key ?? "nil") }
    check(Set(old) == [A], "an old tab nobody chose never takes over, even when it is looked at for a long time")

    let c5 = MeetTabChooser(acceptAfter: 0)
    _ = c5.choose(from: [meetTab(A, active: true)], observedAt: at(0))
    check(c5.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(2))?.key == B, "START_DEBOUNCE 0: a new front tab takes over at once")

    let c6 = MeetTabChooser(acceptAfter: 4)
    _ = c6.choose(from: [meetTab(A, active: true)], observedAt: at(0))
    check(c6.choose(from: [meetTab(A), meetTab("team-standup", kind: .nickname, active: true)], observedAt: at(4))?.key == A
          && c6.choose(from: [meetTab(A), meetTab("team-standup", kind: .nickname, active: true)], observedAt: at(12))?.key == A,
          "a new nickname tab never replaces a meeting code")

    // --- closing tabs
    let c7 = MeetTabChooser(acceptAfter: 4)
    check(c7.choose(from: [meetTab(R, id: "old"), meetTab(R, id: "new", active: true)], observedAt: at(0))?.tabID == "new", "recurring code open twice: the front tab")
    check(c7.choose(from: [meetTab(R, id: "old"), meetTab(S, id: "s1", active: true)], observedAt: at(4))?.key == R,
          "the chosen tab is closed: the other tab with the SAME code carries on, even when another meeting's tab is now the active one")
    let c8 = MeetTabChooser(acceptAfter: 4)
    _ = c8.choose(from: [meetTab(A, active: true), meetTab(B)], observedAt: at(0))
    check(c8.choose(from: [meetTab(B)], observedAt: at(4))?.key == B, "the chosen tab is closed and another meeting is left: that one is chosen")
    check(c8.choose(from: [], observedAt: at(8)) == nil, "all Meet tabs closed: none")
    check(c8.choose(from: [meetTab(A)], observedAt: at(10))?.key == A, "...and the next call starts from a clean slate")

    // --- forgetting
    let c9 = MeetTabChooser(acceptAfter: 4)
    _ = c9.choose(from: [meetTab(A, active: true)], observedAt: at(0))
    c9.forget()
    check(c9.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(35))?.key == B,
          "after forget() (the detector calls it once Chrome audio was idle for a grace period: the session is over) the next call is a first sight again (the front tab wins at once)")
    let c9b = MeetTabChooser(acceptAfter: 4)
    _ = c9b.choose(from: [meetTab(A, active: true)], observedAt: at(0))
    check(c9b.choose(from: [meetTab(A), meetTab(B, active: true)], observedAt: at(35))?.key == A, "(control) without forget() the same new front tab has to wait, however long ago the last observation was")

    let c10 = MeetTabChooser(acceptAfter: 4)
    _ = c10.choose(from: [meetTab(A, active: true, window: "1", order: 0)], observedAt: at(0))
    var behind: [String] = []
    for t in stride(from: 4.0, through: 40.0, by: 4.0) {
        behind.append(c10.choose(from: [meetTab(A, window: "1", order: 0), meetTab(B, active: true, window: "2", order: 1)], observedAt: at(t))?.key ?? "nil")
    }
    check(Set(behind) == [A], "a new tab that is the active tab of a window BEHIND the front window never takes over")

    // --- the reviewer's scenario: recurring code R, one-off tab S, state that lives for days (Chrome audio never idle)
    let day: Double = 86_400
    for forgetBetweenCalls in [true, false] {
        let chooser = MeetTabChooser(acceptAfter: 4)
        let label = forgetBetweenCalls ? "state forgotten between calls" : "state kept for days"
        func betweenCalls() { if forgetBetweenCalls { chooser.forget() } }
        check(chooser.choose(from: [meetTab(R, id: "r1", active: true)], observedAt: at(0))?.tabID == "r1", "Monday: the standup tab R is chosen (\(label))")
        betweenCalls()
        _ = chooser.choose(from: [meetTab(R, id: "r1"), meetTab(S, id: "s1", active: true)], observedAt: at(2 * day))
        let wed = chooser.choose(from: [meetTab(R, id: "r1"), meetTab(S, id: "s1", active: true)], observedAt: at(2 * day + 4))
        check(wed?.key == S, "Wednesday: the one-off tab S the user joined is chosen (\(label))", wed?.key ?? "nil")
        let monday = at(7 * day)
        betweenCalls()
        _ = chooser.choose(from: [meetTab(R, id: "r1"), meetTab(S, id: "s1"), meetTab(R, id: "r2", active: true)], observedAt: monday)
        let next = chooser.choose(from: [meetTab(R, id: "r1"), meetTab(S, id: "s1"), meetTab(R, id: "r2", active: true)], observedAt: monday.addingTimeInterval(4))
        check(next?.key == R && next?.tabID == "r2", "next Monday: R and S still open, the user joins R in a NEW active tab: that tab is chosen, not S (\(label))", "\(next?.key ?? "nil") \(next?.tabID ?? "nil")")
        let closed = chooser.choose(from: [meetTab(R, id: "r1"), meetTab(R, id: "r2", active: true)], observedAt: monday.addingTimeInterval(30))
        check(closed?.key == R && closed?.tabID == "r2", "closing the stale tab S during the call changes nothing (\(label))", "\(closed?.key ?? "nil") \(closed?.tabID ?? "nil")")
    }
}

// MARK: - Safety

private func testPolicyAndSafety() {
    section("AppleScript / permission-prompt safety (LaunchGuard.isSignedAppLaunch)")
    // `signedAppLaunch` stands for LaunchGuard.isSignedAppLaunch = bundle id AND started by launchd / LaunchServices.
    // false is also what an in-bundle binary exec'd from a shell gets (right bundle id, wrong parent): that was the bug.
    check(TabQueryPolicy.resolve(signedAppLaunch: true, args: [], env: [:]).enabled, "signed app launch: tab queries enabled")
    check(!TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe"], env: [:]).enabled,
          "not started by launchd / LaunchServices (shell, terminal, in-bundle binary exec'd from a shell): disabled")
    check(!TabQueryPolicy.resolve(signedAppLaunch: false, args: ["setup"], env: [:]).enabled && !TabQueryPolicy.resolve(signedAppLaunch: false, args: [], env: [:]).enabled,
          "disabled for every subcommand, including setup and the bare app")
    check(!TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe", "--tabs"], env: [:]).enabled, "--tabs alone does not enable")
    check(!TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe"], env: ["MC_ALLOW_APPLESCRIPT": "1"]).enabled, "MC_ALLOW_APPLESCRIPT alone does not enable")
    check(!TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe", "--tabs"], env: ["MC_ALLOW_APPLESCRIPT": "0"]).enabled, "MC_ALLOW_APPLESCRIPT=0 does not enable")
    check(TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe", "--tabs"], env: ["MC_ALLOW_APPLESCRIPT": "1"]).enabled, "--tabs + MC_ALLOW_APPLESCRIPT=1 enables (deliberate manual diagnostic)")
    check(!TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe", "--tabs-always"], env: [:]).enabled
          && !TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe", "--tabs-always"], env: ["MC_ALLOW_APPLESCRIPT": "1"]).enabled,
          "--tabs-always never enables anything by itself (not even with MC_ALLOW_APPLESCRIPT=1)")
    check(!TabQueryPolicy.resolve(signedAppLaunch: false, args: [], env: [:]).reason.isEmpty
          && TabQueryPolicy.resolve(signedAppLaunch: false, args: [], env: [:]).reason.contains("open -n"), "the disabled reason is explained and names the open -n command")

    check(TabQueryPolicy.promptAllowed(signedAppLaunch: true, env: [:]), "prompts allowed from a signed app launch")
    check(!TabQueryPolicy.promptAllowed(signedAppLaunch: false, env: [:]), "prompts refused from a shell, also for an in-bundle binary exec'd from a shell")
    check(!TabQueryPolicy.promptAllowed(signedAppLaunch: false, env: ["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY": "0"]), "override must be exactly 1")
    check(TabQueryPolicy.promptAllowed(signedAppLaunch: false, env: ["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY": "1"]), "explicit developer override allows prompts")

    // A closed policy keeps the whole stack away from Chrome: no backend call of any kind, also with `--tabs-always`.
    let closed = TabQueryPolicy.resolve(signedAppLaunch: false, args: ["probe", "--tabs-always"], env: [:])
    for always in [false, true] {
        let backend = FakeChromeBackend()
        backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
        let info = ChromeTabs(policy: closed, browserBundleIDs: ["com.google.Chrome"], backend: backend, alwaysQuery: always).info(audioActive: true, now: epoch)
        check(info.status.label == "disabled" && backend.totalCalls == 0, "closed policy\(always ? " + alwaysQuery" : ""): Chrome is never touched (0 backend calls)", "\(info.status.label) \(backend.totalCalls)")
    }
    let shellSim = DetectSim(platforms: [.meet], policy: closed, alwaysQueryTabs: true)
    shellSim.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
    shellSim.world.processes = chromeProcs(inp: true, out: true)
    shellSim.run(40)
    check(shellSim.world.backend.totalCalls == 0, "whole detector under a closed policy (not launched by launchd): 0 backend calls even with the probe-only switch")

    // The real guard of THIS process. Run from a shell (also: the in-bundle binary exec'd by `make test-swift`) it must be false,
    // and then the live policy must be closed and the real prompt function must refuse.
    let env = ProcessInfo.processInfo.environment
    let shellLaunched = getppid() != 1 && env["__CFBundleIdentifier"] != LaunchGuard.bundleID
    if shellLaunched {
        check(!LaunchGuard.isSignedAppLaunch, "this process was not started by launchd / LaunchServices: isSignedAppLaunch is false (bundle id \(Bundle.main.bundleIdentifier ?? "nil"))")
        if !CommandLine.arguments.contains("--tabs") {
            check(!TabQueryPolicy.current().enabled, "TabQueryPolicy.current() is closed in this process")
        }
    } else {
        print("  skip  real-guard checks (this process was started by launchd / LaunchServices)")
    }
    // Real, harmless system calls: a bundle id nobody runs (no app is addressed, askUser is false: cannot prompt or launch).
    let ghost = "com.example.mcap.selftest.not-running"
    check(Automation.state(forBundleID: ghost, askUser: false) == .targetNotRunning, "AE permission query for a target that is not running returns procNotFound")
    check(LiveChromeBackend().isRunning(bundleID: ghost) == false, "NSRunningApplication check for a missing app is false")
    // The pure decision behind the function that can raise the Automation prompt (the function itself is exercised below
    // with injected seams only: it is never called here with its real defaults).
    check(TabQueryPolicy.promptRefusal(signedAppLaunch: false, env: [:])?.hasPrefix("refused:") == true,
          "requestChromeAutomationPermission() decision: refused unless started as the signed app (this is the string setup shows)")
    check(TabQueryPolicy.promptRefusal(signedAppLaunch: true, env: [:]) == nil && TabQueryPolicy.promptRefusal(signedAppLaunch: false, env: ["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY": "1"]) == nil,
          "...and allowed for a signed app launch or the explicit developer override")
    check(TabQueryPolicy.promptRefusal(signedAppLaunch: false, env: [:])?.contains("open -n -W -a") == true, "the refusal names the open -n -W -a command")

    // The function itself, with injected seams (guard value, environment, "is Chrome running", the Apple Event permission call).
    // Nothing real is touched: `automation` is a recording closure, so these checks show WHETHER the permission call would have
    // been made (and with askUser: true, the only place that may ask), without ever making it.
    var asked: [Bool] = []
    func request(signed: Bool, env: [String: String] = [:], running: Bool = true, state: AutomationState = .authorized) -> String {
        return requestChromeAutomationPermission(signedAppLaunch: signed, env: env, chromeRunning: { running },
                                                 automation: { _, askUser in asked.append(askUser); return state })
    }
    let refused = request(signed: false)
    check(refused.hasPrefix("refused:") && asked.isEmpty,
          "requestChromeAutomationPermission(): not a signed app launch (a shell, an in-bundle binary exec'd from a shell) -> refused, the permission call is never made", "\(refused) asked=\(asked)")
    let refusedZero = request(signed: false, env: ["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY": "0"])
    check(refusedZero.hasPrefix("refused:") && asked.isEmpty, "...also with the developer override set to anything but 1, and also while Chrome is running and would answer 'authorized'", "\(refusedZero) asked=\(asked)")
    check(request(signed: false, env: ["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY": "1"]) == "authorized" && asked == [true], "explicit developer override: proceeds, and asks with askUser: true")
    asked = []
    check(request(signed: true) == "authorized" && asked == [true], "signed app launch: asks once, with askUser: true (the only place in the app that may show the prompt)", "asked=\(asked)")
    asked = []
    check(request(signed: true, state: .denied).hasPrefix("denied:") && request(signed: true, state: .notAsked).hasPrefix("denied:")
          && request(signed: true, state: .other(-50)).hasPrefix("denied:") && request(signed: true, state: .targetNotRunning).hasPrefix("not-running:"),
          "answers are mapped to the strings Setup.swift understands (denied: / not-running:)")
    asked = []
    check(request(signed: true, running: false).hasPrefix("not-running:") && asked.isEmpty, "Chrome not running: not-running, and no permission call (it would launch Chrome)")
}

private func testChromeTabsGate() {
    section("ChromeTabs gate (when Chrome may be touched)")
    let enabled = TabQueryPolicy(enabled: true, reason: "test")
    func tabs(_ backend: FakeChromeBackend, policy: TabQueryPolicy = enabled, browsers: [String] = ["com.google.Chrome"]) -> ChromeTabs {
        return ChromeTabs(policy: policy, browserBundleIDs: browsers, backend: backend)
    }

    let b0 = FakeChromeBackend()
    let disabled = tabs(b0, policy: TabQueryPolicy(enabled: false, reason: "shell")).info(audioActive: true, now: epoch)
    check(disabled.status == .disabled("shell") && b0.totalCalls == 0, "policy disabled: no backend call of any kind")

    let b1 = FakeChromeBackend()
    check(tabs(b1, browsers: ["org.mozilla.firefox"]).info(audioActive: true, now: epoch).status.label == "unsupported" && b1.totalCalls == 0, "no Chrome in BROWSER_BUNDLE_IDS: unsupported, no call")

    let b2 = FakeChromeBackend()
    check(tabs(b2).info(audioActive: false, now: epoch).status == .idle && b2.totalCalls == 0, "no Chrome audio IO: not queried, Chrome untouched")

    let b3 = FakeChromeBackend()
    b3.running = false
    b3.automation = .authorized
    let notRunning = tabs(b3).info(audioActive: true, now: epoch)
    check(notRunning.status == .chromeNotRunning && b3.listCalls == 0 && b3.automationCalls == 0, "Chrome not running: no automation check and NO script (a tell would launch Chrome)")

    let b4 = FakeChromeBackend()
    b4.automation = .notAsked
    check(tabs(b4).info(audioActive: true, now: epoch).status == .notAsked && b4.listCalls == 0, "Automation not asked yet: no script (it would raise the prompt)")
    let b5 = FakeChromeBackend()
    b5.automation = .denied
    check(tabs(b5).info(audioActive: true, now: epoch).status == .denied && b5.listCalls == 0, "Automation denied: no script")
    let b6 = FakeChromeBackend()
    b6.automation = .other(-50)
    check(tabs(b6).info(audioActive: true, now: epoch).status.label == "error" && b6.listCalls == 0, "unknown automation status: no script")
    let b7 = FakeChromeBackend()
    b7.automation = .targetNotRunning
    check(tabs(b7).info(audioActive: true, now: epoch).status == .chromeNotRunning && b7.listCalls == 0, "procNotFound: Chrome not running")

    let b8 = FakeChromeBackend()
    b8.result = .ok([tab("https://example.com/private", title: "Private"), tab("https://meet.google.com/abc-defg-hij?authuser=1", title: "Meet", active: true), tab("https://meet.google.com/landing")])
    let t8 = tabs(b8)
    let first = t8.info(audioActive: true, now: epoch)
    check(first.status.isOK && first.totalTabs == 3 && first.meetHostTabs.count == 2 && first.candidates.count == 1, "authorized: tabs read, Meet tabs classified")
    check(!first.meetHostTabs.contains { $0.url.contains("example.com") }, "non-Meet tabs are not retained")
    let second = t8.info(audioActive: true, now: epoch.addingTimeInterval(2))
    check(b8.listCalls == 1 && second.fromCache, "second poll within 4 s uses the cache")
    _ = t8.info(audioActive: true, now: epoch.addingTimeInterval(5))
    check(b8.listCalls == 2, "after the cache expires the tabs are read again")
    _ = t8.info(audioActive: true, now: epoch.addingTimeInterval(11), maxAge: ChromeTabs.steadyCacheSeconds)
    check(b8.listCalls == 2, "steady state (call established): the cache is kept for 12 s")
    _ = t8.info(audioActive: true, now: epoch.addingTimeInterval(18), maxAge: ChromeTabs.steadyCacheSeconds)
    check(b8.listCalls == 3, "and refreshed after that")
    check(t8.info(audioActive: false, now: epoch.addingTimeInterval(19)).status == .idle && b8.listCalls == 3, "audio inactive again: idle, no read")

    let b9 = FakeChromeBackend()
    b9.result = .error(-1712, "timed out")
    let t9 = tabs(b9)
    check(t9.info(audioActive: true, now: epoch).status.label == "error", "script error is reported")
    _ = t9.info(audioActive: true, now: epoch.addingTimeInterval(6))
    check(b9.listCalls == 1, "errors are cached 10 s (a hung Chrome is not hammered)")
    _ = t9.info(audioActive: true, now: epoch.addingTimeInterval(11))
    check(b9.listCalls == 2, "and retried afterwards")

    let b10 = FakeChromeBackend()
    b10.result = .noPermission
    check(tabs(b10).info(audioActive: true, now: epoch).status == .denied, "-1743 from the script maps to denied")

    let script = ChromeTabs.tabsScript(bundleID: "com.google.Chrome") ?? ""
    check(script.contains("with timeout of 3 seconds") && script.contains("application id \"com.google.Chrome\""), "script: app id form + 3 s timeout")
    check(script.contains("URL of every tab of w") && script.contains("title of every tab of w") && !script.lowercased().contains("javascript"), "script: bulk URL/title only, no JavaScript from Apple Events")
    check(ChromeTabs.tabsScript(bundleID: "x\" & (do shell script \"id\") & \"") == nil && ChromeTabs.tabsScript(bundleID: "") == nil, "script: bundle id is restricted to a safe alphabet")
    check(script.contains("id of every tab of w") && script.contains("index of w") && script.contains("(id of w) as text") && script.contains("(mode of w) as text"),
          "script: reads window id, tab ids and window index next to URL / title / mode")
    check(script.components(separatedBy: "if errNum is -1712 then error errText number errNum").count - 1 == 2,
          "script: a timeout (-1712) is re-raised from both try blocks, so a hung Chrome is an error and not a partial 'no Meet tab' answer")

    // --- probe --tabs-always: the audio gate is skipped, every other gate stays
    let meetList: [ChromeTab] = [tab("https://meet.google.com/abc-defg-hij", title: "You left the meeting", active: true)]
    let a1 = FakeChromeBackend()
    a1.result = .ok(meetList)
    let always = ChromeTabs(policy: enabled, browserBundleIDs: ["com.google.Chrome"], backend: a1, alwaysQuery: true).info(audioActive: false, now: epoch)
    check(always.status.isOK && always.candidates.first?.title == "You left the meeting" && a1.listCalls == 1,
          "alwaysQuery (probe --tabs-always): the tab list is read while Chrome has NO audio IO (post-call page observable, L-12)")
    let a0 = FakeChromeBackend()
    a0.result = .ok(meetList)
    let production = tabs(a0).info(audioActive: false, now: epoch)
    check(production.status == .idle && a0.totalCalls == 0, "production default: still gated on Chrome audio IO (idle, no call)")
    let a2 = FakeChromeBackend()
    a2.running = false
    check(ChromeTabs(policy: enabled, browserBundleIDs: ["com.google.Chrome"], backend: a2, alwaysQuery: true).info(audioActive: false, now: epoch).status == .chromeNotRunning
          && a2.listCalls == 0 && a2.automationCalls == 0, "alwaysQuery: Chrome not running -> no script")
    for state in [AutomationState.denied, .notAsked, .other(-50)] {
        let a3 = FakeChromeBackend()
        a3.automation = state
        _ = ChromeTabs(policy: enabled, browserBundleIDs: ["com.google.Chrome"], backend: a3, alwaysQuery: true).info(audioActive: false, now: epoch)
        check(a3.listCalls == 0, "alwaysQuery: Automation \(state) -> no script (the prompt can never be raised by a query)")
    }
    let a4 = FakeChromeBackend()
    check(ChromeTabs(policy: TabQueryPolicy(enabled: false, reason: "shell"), browserBundleIDs: ["com.google.Chrome"], backend: a4, alwaysQuery: true)
            .info(audioActive: false, now: epoch).status == .disabled("shell") && a4.totalCalls == 0, "alwaysQuery: policy disabled -> nothing at all")
    let a5 = FakeChromeBackend()
    check(ChromeTabs(policy: enabled, browserBundleIDs: ["org.mozilla.firefox"], backend: a5, alwaysQuery: true).info(audioActive: false, now: epoch).status.label == "unsupported"
          && a5.totalCalls == 0, "alwaysQuery: no Chrome in BROWSER_BUNDLE_IDS -> unsupported, no call")

    // The production wiring (DetectorInputs.live, what Detector(config:) uses) keeps the audio gate; only the probe asks for more.
    var cfg = AppConfig.defaults()
    cfg.enabledPlatforms = [.meet]
    let w0 = FakeChromeBackend()
    w0.result = .ok(meetList)
    let production0 = DetectorInputs.live(config: cfg, policy: enabled, backend: w0)
    check(production0.tabs(false, epoch, 4).status == .idle && w0.totalCalls == 0, "production wiring (DetectorInputs.live): no tab query while Chrome has no audio IO")
    check(production0.tabs(true, epoch, 4).status.isOK && w0.listCalls == 1, "production wiring: tabs are read while Chrome has audio IO")
    let w1 = FakeChromeBackend()
    w1.result = .ok(meetList)
    let probeWiring = DetectorInputs.live(config: cfg, policy: enabled, alwaysQueryTabs: true, backend: w1)
    check(probeWiring.tabs(false, epoch, 4).status.isOK && w1.listCalls == 1, "probe wiring (alwaysQueryTabs): tabs are read with no Chrome audio IO")
}

// MARK: - Formulas

private func family(_ platform: Platform, _ procs: [AudioProcessInfo]) -> FamilyAudio {
    return FamilyAudio(platform: platform, processes: procs)
}

private func testFormulas() {
    section("platform formulas (pure)")
    func meet(rawIn: Bool, rawOut: Bool, stableIn: Bool? = nil, stableOut: Bool? = nil, tabs: TabsInfo, chosen: MeetTab? = nil) -> PlatformSignal {
        return Detector.evaluateMeet(MeetEvaluationInput(browserBundleID: "com.google.Chrome",
                                                         audio: family(.meet, chromeProcs(inp: rawIn, out: rawOut)),
                                                         stableInput: stableIn ?? rawIn, stableOutput: stableOut ?? rawOut,
                                                         tabs: tabs, chosenTab: chosen))
    }
    let codeTab = MeetTab(kind: .code, key: "abc-defg-hij", url: "https://meet.google.com/abc-defg-hij", title: "Meet \u{2013} Weekly", isActive: true, incognito: false)
    let nickTab = MeetTab(kind: .nickname, key: "team-standup", url: "https://meet.google.com/team-standup", title: nil, isActive: true, incognito: false)
    let okTabs = TabsInfo(status: .ok, meetHostTabs: [codeTab], totalTabs: 5, queriedAt: epoch)
    let noMeetTabs = TabsInfo(status: .ok, meetHostTabs: [], totalTabs: 5, queriedAt: epoch)
    let nickTabs = TabsInfo(status: .ok, meetHostTabs: [nickTab], totalTabs: 5, queriedAt: epoch)

    let idle = meet(rawIn: false, rawOut: false, tabs: TabsInfo(status: .idle))
    check(!idle.inCall && idle.evidence.contains { $0.contains("no chrome audio IO") }, "meet: idle Chrome -> not in call")
    let high = meet(rawIn: true, rawOut: true, tabs: okTabs, chosen: codeTab)
    check(high.inCall && high.confidence == .high && high.meetingKey == "abc-defg-hij" && high.titleHint == "Meet \u{2013} Weekly"
          && high.meetingURL == "https://meet.google.com/abc-defg-hij" && high.bundleID == "com.google.Chrome", "meet: code tab + in + out -> HIGH with key/url/title")
    check(high.evidence.contains { $0.contains("tier=HIGH") } && high.evidence.contains { $0.contains("meet=[*abc-defg-hij]") }, "meet: evidence names the tier and the chosen tab")
    let mediumIn = meet(rawIn: true, rawOut: false, tabs: okTabs, chosen: codeTab)
    check(mediumIn.inCall && mediumIn.confidence == .high && mediumIn.evidence.contains { $0.contains("MEDIUM") && $0.contains("in only") }, "meet: code tab + input only -> MEDIUM, in call")
    let mediumOut = meet(rawIn: false, rawOut: true, tabs: okTabs, chosen: codeTab)
    check(mediumOut.inCall && mediumOut.evidence.contains { $0.contains("MEDIUM") && $0.contains("out only") }, "meet: code tab + output only -> MEDIUM (listen-only attendee)")
    let notStable = meet(rawIn: true, rawOut: true, stableIn: false, stableOut: false, tabs: okTabs, chosen: codeTab)
    check(!notStable.inCall, "meet: raw flags that are not yet stable do not start a call")
    check(!meet(rawIn: true, rawOut: true, tabs: noMeetTabs).inCall, "meet: tabs known, no Meet code tab -> not in call even with in+out")
    check(!meet(rawIn: true, rawOut: false, tabs: nickTabs, chosen: nickTab).inCall, "meet: nickname tab + input only -> not in call")
    let nick = meet(rawIn: true, rawOut: true, tabs: nickTabs, chosen: nickTab)
    check(nick.inCall && nick.confidence == .low && nick.meetingKey == "team-standup", "meet: nickname tab + in + out -> LOW, keyed by the nickname")

    let unavailable: [(String, TabsStatus)] = [("denied", .denied), ("not asked", .notAsked), ("disabled", .disabled("shell")),
                                               ("unsupported", .unsupported("x")), ("error", .error("timeout")), ("chrome not running", .chromeNotRunning)]
    for (name, status) in unavailable {
        let info = TabsInfo(status: status)
        check(!meet(rawIn: true, rawOut: false, tabs: info).inCall, "meet fallback (\(name)): input alone never counts")
        check(!meet(rawIn: false, rawOut: true, tabs: info).inCall, "meet fallback (\(name)): output alone never counts")
        let both = meet(rawIn: true, rawOut: true, tabs: info)
        check(both.inCall && both.confidence == .low && both.meetingKey == nil && both.titleHint == nil && both.meetingURL == nil,
              "meet fallback (\(name)): in + out -> LOW, no code/title")
    }

    func zoom(udp: Int?, stableUDP: Bool, rawIn: Bool = false, stableIn: Bool? = nil, rawOut: Bool = false, pids: [Int32] = [787]) -> PlatformSignal {
        return Detector.evaluateZoom(ZoomEvaluationInput(audio: family(.zoom, zoomProcs(inp: rawIn, out: rawOut)),
                                                         stableInput: stableIn ?? rawIn, stableOutput: rawOut, mainPIDs: pids,
                                                         udpSockets: udp, stableUDP: stableUDP))
    }
    check(!zoom(udp: 0, stableUDP: false).inCall, "zoom: idle -> not in call")
    check(zoom(udp: 4, stableUDP: true).inCall && zoom(udp: 4, stableUDP: true).evidence.contains { $0.contains("via=udp") }, "zoom: main-pid UDP -> in call")
    check(!zoom(udp: 4, stableUDP: false).inCall, "zoom: a UDP socket seen once is not yet stable")
    check(zoom(udp: 0, stableUDP: false, rawIn: true).inCall, "zoom: input alone -> in call (joined by UDP-less path)")
    check(!zoom(udp: 0, stableUDP: false, rawOut: true).inCall, "zoom: output alone (chime, webinar) does not count")
    check(zoom(udp: nil, stableUDP: false, pids: []).evidence.contains { $0.contains("main-pid=none") && $0.contains("sockets=n/a") }, "zoom: no main pid is reported as such")

    func teams(rawIn: Bool, rawOut: Bool, stableOut: Bool? = nil) -> PlatformSignal {
        return Detector.evaluateTeams(TeamsEvaluationInput(audio: family(.teams, teamsProcs(inp: rawIn, out: rawOut)), stableInput: rawIn, stableOutput: stableOut ?? rawOut))
    }
    check(teams(rawIn: true, rawOut: false).inCall, "teams: input -> in call")
    check(!teams(rawIn: false, rawOut: true).inCall && !teams(rawIn: false, rawOut: true, stableOut: true).inCall, "teams: output only never counts, even sustained")
    check(!teams(rawIn: false, rawOut: false).inCall, "teams: idle")
}

// MARK: - libproc

private func testNetworkProbe() {
    section("libproc UDP sockets and process inspection")
    let sockets = [UDPSocketInfo(localPort: 5353, remotePort: 0, isIPv4: true), UDPSocketInfo(localPort: 50000, remotePort: 8801, isIPv4: true),
                   UDPSocketInfo(localPort: 50001, remotePort: 0, isIPv4: false), UDPSocketInfo(localPort: 50002, remotePort: 3479, isIPv4: true)]
    check(NetworkProbe.counted(sockets) == 3, "mDNS (5353) is not counted")
    check(NetworkProbe.connected(sockets, toPorts: NetworkProbe.teamsRelayPorts) == 1, "relay-port count only includes connected sockets in 3478-3481")
    check(NetworkProbe.describe(sockets).contains("8801x1") && NetworkProbe.describe(sockets).contains("total=4"), "describe: remote port histogram")

    check(NetworkProbe.chromiumRole(arguments: ["Google Chrome Helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"]) == .audioService, "role: audio service")
    check(NetworkProbe.chromiumRole(arguments: ["h", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]) == .network, "role: network service")
    check(NetworkProbe.chromiumRole(arguments: ["h", "--type=utility", "--utility-sub-type=video_capture.mojom.VideoCaptureService"]) == .videoCapture, "role: video capture")
    check(NetworkProbe.chromiumRole(arguments: ["h", "--type=renderer"]) == .renderer && NetworkProbe.chromiumRole(arguments: ["h", "--type=gpu-process"]) == .gpu, "role: renderer / gpu")
    check(NetworkProbe.chromiumRole(arguments: ["Google Chrome"]) == .main, "role: main")
    check(NetworkProbe.hasMeetingKeyArgument(["CptHost", "-pid", "1", "-key", "123456789"]), "argv: -key <digits> detected")
    check(!NetworkProbe.hasMeetingKeyArgument(["caphost", "-pid", "787", "-evtname", "caphost787", "-key", "rpc"]), "argv: -key rpc is not a meeting id")
    check(!NetworkProbe.hasMeetingKeyArgument(["x", "-key", "123"]) && !NetworkProbe.hasMeetingKeyArgument(["x", "-key"]), "argv: short digits / dangling -key")

    check(NetworkProbe.udpSockets(of: 0) == nil && NetworkProbe.udpSockets(of: -5) == nil, "invalid pids are refused")
    check(NetworkProbe.udpSockets(of: 2_000_000) == nil, "a pid that does not exist returns nil, not a crash")
    check(NetworkProbe.childPIDs(of: 2_000_000).isEmpty, "children of a missing pid: empty")
    check(NetworkProbe.arguments(of: getpid())?.isEmpty == false, "argv of our own process is readable")
    check(NetworkProbe.executableName(of: getpid()) != "?", "executable name of our own process")

    // Real libproc round trip on this process: one bound UDP socket and one connected UDP socket on loopback.
    let me = getpid()
    let before = NetworkProbe.udpSockets(of: me)
    check(before != nil, "libproc can inspect our own process")
    let a = socket(AF_INET, SOCK_DGRAM, 0)
    let b = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(a); close(b) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(a, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var peer = addr
    peer.sin_port = UInt16(8801).bigEndian
    let connected = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(b, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    check(a >= 0 && b >= 0 && bound == 0 && connected == 0, "loopback test sockets created")
    let after = NetworkProbe.udpSockets(of: me) ?? []
    check(after.count == (before?.count ?? 0) + 2, "libproc sees the two new UDP sockets", "before \(before?.count ?? -1) after \(after.count)")
    check(after.contains { $0.isConnected && $0.remotePort == 8801 && $0.isIPv4 }, "connected socket: remote port 8801 read back correctly")
    check(NetworkProbe.countedUDP(of: me) == NetworkProbe.counted(after), "countedUDP agrees with the socket list")
}

// MARK: - State machine

private func testStateMachineDebounce() {
    section("state machine: debounce and flicker tolerance")
    let a = MachineRun()
    a.run(10, [sig(.zoom)])
    check(a.first("start") == 5 && a.count("start") == 1, "start fires START_DEBOUNCE (4 s) after the first inCall poll", "\(a.events)")
    check(a.machine.isRecording && !a.machine.isCandidate, "recording, no longer a candidate")
    check(a.started?.platform == .zoom, "start carries the platform signal")

    let b = MachineRun()
    b.run(3, [sig(.zoom)])
    check(b.machine.isCandidate && !b.machine.isRecording, "inside the debounce the machine is a candidate (menu: Meeting detected)")
    b.run(10, [sig(.zoom, false)])
    check(b.events.isEmpty && !b.machine.isCandidate, "3 s of signal then gone: never starts, candidate cleared")

    let c = MachineRun()
    c.run(2, [sig(.zoom)])
    c.run(1, [sig(.zoom, false)])
    c.run(10, [sig(.zoom)])
    check(c.first("start") == 5, "a one-poll flicker inside the debounce does not restart it", "\(c.events)")

    let d = MachineRun()
    d.run(2, [sig(.zoom)])
    d.run(5, [sig(.zoom, false)])
    d.run(10, [sig(.zoom)])
    check(d.first("start") == 12, "a gap longer than the flicker tolerance restarts the debounce", "\(d.events)")

    let e = MachineRun()
    e.run(2, [sig(.zoom)])
    e.run(10, [sig(.teams)])
    check(e.first("start") == 7 && e.started?.platform == .teams, "a different platform restarts the debounce", "\(e.events)")

    let f = MachineRun()
    f.run(2, [sig(.meet, key: "aaa-bbbb-ccc")])
    f.run(10, [sig(.meet, key: "ddd-eeee-fff")])
    check(f.first("start") == 7, "a different Meet code restarts the debounce", "\(f.events)")

    let g = MachineRun()
    g.run(1, [sig(.meet, conf: .low)])
    g.run(10, [sig(.meet, key: "aaa-bbbb-ccc")])
    check(g.first("start") == 5 && g.started?.meetingKey == "aaa-bbbb-ccc", "an unknown code becoming known does not restart the debounce, and start carries the newest signal", "\(g.events)")

    let h = MachineRun(debounce: 0)
    h.run(1, [sig(.zoom)])
    check(h.first("start") == 1, "START_DEBOUNCE 0 starts on the first poll")

    let i = MachineRun()
    i.run(8, [sig(.meet, conf: .low), sig(.zoom)])
    check(i.started?.platform == .zoom, "best signal: a high-confidence platform is preferred over a low one")

    let j = MachineRun()
    j.run(8, [sig(.meet, conf: .low)])
    check(j.first("start") == 5 && j.started?.confidence == .low, "a LOW-confidence (fallback) signal still starts a recording")

    let k = MachineRun()
    k.run(20, [])
    check(k.events.isEmpty && !k.machine.isCandidate && !k.machine.isRecording, "empty snapshots (nothing enabled) do nothing")
}

private func testStateMachineGrace() {
    section("state machine: grace, flicker, effective grace per platform")
    let a = MachineRun()
    a.run(10, [sig(.meet, key: "abc-defg-hij")])
    a.run(40, [sig(.meet, false)])
    check(a.first("stop") == 30 && a.events.last?.kind == "stop:meeting-ended", "meet: stops exactly GRACE (20 s) after the last inCall poll", "\(a.events)")
    check(!a.machine.isRecording && !a.machine.isCandidate, "after stop the machine is idle")

    let b = MachineRun()
    b.run(10, [sig(.meet, key: "abc-defg-hij")])
    b.run(19, [sig(.meet, false)])
    check(b.count("stop") == 0 && b.machine.isRecording, "19 s without a signal: still recording")
    b.run(30, [sig(.meet, key: "abc-defg-hij")])
    check(b.count("stop") == 0, "signal back inside the grace: the session continues, grace is re-armed")

    let c = MachineRun()
    c.run(10, [sig(.zoom)])
    var flips = 0
    c.run(900) { t in
        flips += 1
        return [sig(.zoom, t % 17 == 0)]       // on for 1 s out of every 17 s: never 20 s of silence
    }
    check(c.count("stop") == 0 && c.machine.isRecording, "a signal that keeps flipping inside the grace never stops the session", "flips=\(flips) \(c.events)")
    c.run(100, [sig(.zoom, false)])
    check(c.count("stop") == 1, "and it stops once the silence finally exceeds the grace")

    func stopTime(_ platform: Platform, grace: TimeInterval) -> Int? {
        let m = MachineRun(grace: grace)
        m.run(8, [sig(platform)])
        let lastOn = m.t
        m.run(200, [sig(platform, false)])
        return m.first("stop").map { $0 - lastOn }
    }
    check(stopTime(.meet, grace: 20) == 20, "meet grace 20 -> 20 s", "\(String(describing: stopTime(.meet, grace: 20)))")
    check(stopTime(.meet, grace: 5) == 5 && stopTime(.meet, grace: 0) == 1, "meet uses the config value as is (5 s, 0 s)")
    check(stopTime(.zoom, grace: 20) == 30, "zoom: effective grace = max(20, 30) = 30 s")
    check(stopTime(.teams, grace: 20) == 30, "teams: effective grace = max(20, 30) = 30 s")
    check(stopTime(.zoom, grace: 0) == 30, "zoom with config 0 still waits 30 s")
    check(stopTime(.zoom, grace: 45) == 45 && stopTime(.teams, grace: 45) == 45, "zoom/teams honour a config grace above 30 s")
    let m = DetectionStateMachine(startDebounce: 4, grace: 20)
    check(m.effectiveGrace(for: .meet) == 20 && m.effectiveGrace(for: .zoom) == 30 && m.effectiveGrace(for: .teams) == 30 && m.effectiveGrace(for: .manual) == 20,
          "effectiveGrace(for:)")

    let d = MachineRun()
    d.run(10, [sig(.meet, key: "abc-defg-hij")])
    d.run(60, [sig(.meet, false), sig(.zoom)])
    check(d.first("stop") == 30, "another platform's call does not keep a Meet session alive", "\(d.events)")
    check(d.count("start") == 2 && d.started?.platform == .zoom, "after the stop the zoom call starts a fresh session after its own debounce", "\(d.events)")

    let e = MachineRun()
    e.run(10, [sig(.meet, key: "abc-defg-hij")])
    e.run(100, [sig(.meet, key: nil, conf: .low)])
    check(e.count("stop") == 0 && e.count("split") == 0, "a missing code (tab query failed) neither stops nor splits")
}

private func testStateMachineSplit() {
    section("state machine: Meet split (back-to-back meetings)")
    let a = MachineRun()
    a.run(10, [sig(.meet, key: "aaa-bbbb-ccc")])
    let changeAt = a.t + 1
    a.run(40, [sig(.meet, key: "ddd-eeee-fff")])
    check(a.first("split") == changeAt + 20 && a.count("stop") == 0, "a new code that persists for GRACE splits exactly then", "change at \(changeAt): \(a.events)")
    check(a.machine.isRecording, "still recording after the split (the caller starts the new session)")
    a.run(100, [sig(.meet, false)])
    check(a.count("stop") == 1, "the new meeting stops normally after its grace")

    let b = MachineRun()
    b.run(10, [sig(.meet, key: "aaa-bbbb-ccc")])
    b.run(10, [sig(.meet, key: "ddd-eeee-fff")])
    b.run(5, [sig(.meet, key: "aaa-bbbb-ccc")])
    check(b.count("split") == 0, "flipping back to the old code cancels the pending split")
    let secondChange = b.t + 1
    b.run(40, [sig(.meet, key: "ddd-eeee-fff")])
    check(b.first("split") == secondChange + 20, "the split window restarts from the second change", "\(b.events)")

    let c = MachineRun()
    c.run(10, [sig(.meet, key: "aaa-bbbb-ccc")])
    c.run(10, [sig(.meet, key: "ddd-eeee-fff")])
    c.run(1, [sig(.meet, false)])
    c.run(30, [sig(.meet, key: "ddd-eeee-fff")])
    check(c.count("split") == 1 && c.count("stop") == 0, "a one-poll gap inside the pending split is tolerated", "\(c.events)")

    let d = MachineRun()
    d.run(10, [sig(.meet, key: "aaa-bbbb-ccc")])
    d.run(10, [sig(.meet, key: "ddd-eeee-fff")])
    d.run(10, [sig(.meet, false)])
    d.run(15, [sig(.meet, key: "ddd-eeee-fff")])
    check(d.count("split") == 0 && d.count("stop") == 0, "a longer gap cancels the pending split; the session stays alive", "\(d.events)")

    let e = MachineRun()
    e.run(10, [sig(.meet, key: "aaa-bbbb-ccc")])
    e.run(10, [sig(.meet, key: "ddd-eeee-fff")])
    let lastSeenNew = e.t
    e.run(60, [sig(.meet, false)])
    check(e.count("split") == 0 && e.first("stop") == lastSeenNew + 20, "new code disappears before the split: stop GRACE after its last poll", "\(e.events)")

    let f = MachineRun()
    f.run(10, [sig(.meet, key: nil, conf: .low)])
    f.run(30, [sig(.meet, key: "aaa-bbbb-ccc")])
    check(f.count("split") == 0, "a session that started without a code adopts the first known one (no split)")
    f.run(30, [sig(.meet, key: "ddd-eeee-fff")])
    check(f.count("split") == 1, "...and splits when a different code then persists")

    let g = MachineRun(grace: 0)
    g.run(5, [sig(.meet, key: "aaa-bbbb-ccc")])
    g.run(3, [sig(.meet, key: "ddd-eeee-fff")])
    check(g.count("split") == 1, "grace 0: a changed code splits on the first poll")

    let h = MachineRun()
    h.run(10, [sig(.zoom)])
    h.run(60, [sig(.zoom)])
    check(h.count("split") == 0, "zoom never splits")
}

private func testStateMachineManualAndReset() {
    section("state machine: manual recording and reset()")
    var m = DetectionStateMachine(startDebounce: 4, grace: 20)
    m.adoptManualRecording()
    check(m.isRecording && !m.isCandidate, "adopted manual recording counts as recording")
    var t = epoch
    var actions = 0
    for i in 1...1200 {                                       // 20 minutes of silence, then other meetings
        t = t.addingTimeInterval(1)
        let signals = i < 600 ? [sig(.meet, false)] : [sig(.meet, key: "aaa-bbbb-ccc"), sig(.zoom)]
        if kind(m.step(now: t, snapshot: DetectionSnapshot(time: t, signals: signals))) != nil { actions += 1 }
    }
    check(actions == 0 && m.isRecording, "a manual session is never stopped, split or restarted by the detector")
    m.reset()
    check(!m.isRecording && !m.isCandidate, "reset() ends the manual session")

    let r = MachineRun()
    r.run(10, [sig(.zoom)])
    r.machine.reset()
    check(!r.machine.isRecording && !r.machine.isCandidate, "reset() during recording -> idle")
    r.run(3, [sig(.zoom)])
    check(r.count("start") == 1 && r.machine.isCandidate, "after reset a running meeting is a fresh candidate (debounce again)")
    r.run(5, [sig(.zoom)])
    check(r.count("start") == 2, "...and starts again after the debounce")

    let s = MachineRun()
    s.run(2, [sig(.zoom)])
    check(s.machine.isCandidate, "candidate before reset")
    s.machine.reset()
    check(!s.machine.isCandidate, "reset() clears a candidate")
    s.run(3, [sig(.zoom)])
    check(s.count("start") == 0, "debounce restarts from the reset, not from the old candidate")

    let u = MachineRun()
    u.run(10, [sig(.meet, key: "aaa-bbbb-ccc")])
    u.run(10, [sig(.meet, key: "ddd-eeee-fff")])
    u.machine.reset()
    u.run(10, [sig(.meet, key: "ddd-eeee-fff")])
    check(u.count("split") == 0 && u.count("start") == 2, "reset() clears a pending split (the caller restarted on the new code)", "\(u.events)")
}

private func testStateMachineClock() {
    section("state machine: wall clock jumps")
    let a = MachineRun()
    a.run(10, [sig(.zoom)])
    a.now = a.now.addingTimeInterval(-3600)                 // clock set back one hour (NTP, manual change)
    a.run(60, [sig(.zoom, false)])
    check(a.count("stop") == 1 && (a.first("stop") ?? 0) <= a.t, "clock moved back while recording: the grace timer re-anchors and the session still stops", "\(a.events)")

    let b = MachineRun()
    b.run(2, [sig(.zoom)])
    b.now = b.now.addingTimeInterval(-3600)
    b.run(10, [sig(.zoom)])
    check(b.count("start") == 1, "clock moved back during a debounce: still starts")

    let c = MachineRun()
    c.run(10, [sig(.zoom)])
    c.now = c.now.addingTimeInterval(7 * 24 * 3600)         // laptop slept for a week without the app noticing
    c.tick([sig(.zoom, false)])
    check(c.count("stop") == 1, "a long forward jump with no signal ends the session immediately")
}

// MARK: - Detector pipeline (virtual world)

private func testDetectorMeet() {
    section("detector pipeline: Meet call, Chrome + tabs")
    let sim = DetectSim(platforms: [.meet])
    sim.world.backend.result = .ok([tab("https://mail.google.com/mail/u/0", title: "Inbox"), tab("https://meet.google.com/abc-defg-hij?authuser=1", title: "Meet \u{2013} Weekly sync", active: true)])
    sim.world.processes = chromeProcs()
    sim.run(20)
    check(sim.events.isEmpty && sim.world.backend.totalCalls == 0, "Chrome idle for 20 s: no start and Chrome is never touched (0 backend calls)")
    check(sim.signal(.meet)?.inCall == false, "meet signal present every poll, inCall false")

    sim.world.processes = chromeProcs(inp: true, out: true)
    sim.run(16)
    let start = sim.first("start")
    check(start != nil && (start ?? 0) >= 24 && (start ?? 0) <= 34, "joins the call: start after smoothing + debounce (about 8 s)", "start at \(String(describing: start)); \(sim.events)")
    let s = sim.signal(.meet)
    check(s?.inCall == true && s?.meetingKey == "abc-defg-hij" && s?.titleHint == "Meet \u{2013} Weekly sync" && s?.confidence == .high,
          "signal carries code, URL and title; HIGH with in + out")
    check(s?.meetingURL == "https://meet.google.com/abc-defg-hij", "meeting URL has no query string (authuser etc. removed)")
    check(sim.world.backend.listCalls >= 1 && sim.world.backend.listCalls <= 6, "tabs read only while Chrome has audio IO and cached 4 s", "listCalls \(sim.world.backend.listCalls)")
    let callsBefore = sim.world.backend.listCalls
    sim.run(120)
    check(sim.world.backend.listCalls - callsBefore <= 11, "established call: tabs re-read about every 12 s, not every 4 s", "reads in 120 s: \(sim.world.backend.listCalls - callsBefore)")

    // Muted + remote silent: Chrome keeps the streams open; nothing changes.
    sim.run(60)
    check(sim.count("stop") == 0, "a long stretch with streams open keeps the session")

    // Leave the call: streams close, the (stale) post-call tab stays open.
    let leftAt = sim.t
    sim.world.processes = chromeProcs()
    sim.run(40)
    let stop = sim.first("stop")
    check(stop != nil && (stop ?? 0) - leftAt >= 20 && (stop ?? 0) - leftAt <= 28, "leaves the call: stops about GRACE after the streams closed", "left \(leftAt) stop \(String(describing: stop))")
    sim.run(60)
    check(sim.count("start") == 1, "stale post-call tab with idle Chrome audio does not restart a recording")

    // Flicker: the audio service restarts for one poll mid-call.
    let flick = DetectSim(platforms: [.meet])
    flick.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
    flick.world.processes = chromeProcs(inp: true, out: true)
    flick.run(30)
    for _ in 0..<20 {
        flick.world.processes = chromeProcs()
        flick.run(2)
        flick.world.processes = chromeProcs(inp: true, out: true)
        flick.run(8)
    }
    check(flick.count("start") == 1 && flick.count("stop") == 0, "single-poll audio dropouts every 10 s never end the session", "\(flick.events)")

    // Stale tab + media playing (documented limitation: Chrome has no per-tab audio state).
    let media = DetectSim(platforms: [.meet])
    media.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet")])
    media.world.processes = chromeProcs(inp: false, out: true)
    media.run(30)
    check(media.count("start") == 1, "KNOWN LIMITATION (L-11): stale Meet tab + sustained Chrome output starts a MEDIUM session")
    let chime = DetectSim(platforms: [.meet])
    chime.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet")])
    for _ in 0..<10 {
        chime.world.processes = chromeProcs(inp: false, out: true)
        chime.run(6)
        chime.world.processes = chromeProcs()
        chime.run(30)
    }
    check(chime.events.isEmpty, "a 6 s output burst (notification, chime) with a stale Meet tab never starts")

    let noTab = DetectSim(platforms: [.meet])
    noTab.world.backend.result = .ok([tab("https://www.youtube.com/watch?v=x", title: "video")])
    noTab.world.processes = chromeProcs(inp: true, out: true)
    noTab.run(60)
    check(noTab.events.isEmpty, "mic + output in Chrome with NO Meet tab (voice typing, YouTube) is not a meeting")
    let home = DetectSim(platforms: [.meet])
    home.world.backend.result = .ok([tab("https://meet.google.com/landing"), tab("https://meet.google.com/new"), tab("https://meet.google.com/lookup/abc123")])
    home.world.processes = chromeProcs(inp: true, out: true)
    home.run(60)
    check(home.events.isEmpty, "Meet landing / new / lookup pages are not meetings")
}

private func testDetectorMeetFallbacks() {
    section("detector pipeline: Automation denied / disabled / Chrome closed")
    let denied = DetectSim(platforms: [.meet])
    denied.world.backend.automation = .denied
    denied.world.processes = chromeProcs(inp: true, out: false)
    denied.run(60)
    check(denied.events.isEmpty, "Automation denied: chrome input alone never starts")
    denied.world.processes = chromeProcs(inp: false, out: true)
    denied.run(60)
    check(denied.events.isEmpty, "Automation denied: chrome output alone never starts")
    denied.world.processes = chromeProcs(inp: true, out: true)
    denied.run(30)
    let sig = denied.signal(.meet)
    check(denied.count("start") == 1 && sig?.confidence == .low && sig?.meetingKey == nil && sig?.titleHint == nil, "Automation denied: in + out starts a LOW session with no title/code")
    check(denied.world.backend.listCalls == 0, "Automation denied: the tab script is never run")
    denied.world.processes = chromeProcs()
    denied.run(60)
    check(denied.count("stop") == 1, "and it stops after the grace")

    let notAsked = DetectSim(platforms: [.meet])
    notAsked.world.backend.automation = .notAsked
    notAsked.world.processes = chromeProcs(inp: true, out: true)
    notAsked.run(30)
    check(notAsked.count("start") == 1 && notAsked.world.backend.listCalls == 0, "Automation not asked yet (setup not run): LOW fallback, no script, no prompt")

    let shell = DetectSim(platforms: [.meet], policy: TabQueryPolicy(enabled: false, reason: "shell"))
    shell.world.processes = chromeProcs(inp: true, out: true)
    shell.run(60)
    check(shell.world.backend.totalCalls == 0, "tab queries disabled (shell): Chrome is never touched, not even NSRunningApplication")
    check(shell.count("start") == 1 && shell.signal(.meet)?.confidence == .low, "tab queries disabled: LOW fallback still detects a call")
    check(shell.signal(.meet)?.evidence.contains { $0.contains("disabled") } == true, "the evidence says tab queries are disabled")

    let closed = DetectSim(platforms: [.meet])
    closed.world.backend.running = false
    closed.world.processes = chromeProcs()
    closed.run(30)
    check(closed.world.backend.listCalls == 0 && closed.world.backend.automationCalls == 0, "Chrome not running: no script, no automation check")

    let broken = DetectSim(platforms: [.meet])
    broken.world.backend.result = .error(-1712, "AppleEvent timed out")
    broken.world.processes = chromeProcs(inp: true, out: true)
    broken.run(60)
    check(broken.count("start") == 1 && broken.signal(.meet)?.confidence == .low, "script keeps timing out: falls back to LOW and still records")
    check(broken.world.backend.listCalls <= 7, "a failing script is retried at most every 10 s", "listCalls \(broken.world.backend.listCalls)")

    let nick = DetectSim(platforms: [.meet])
    nick.world.backend.result = .ok([tab("https://meet.google.com/team-standup", title: "Meet")])
    nick.world.processes = chromeProcs(inp: true, out: false)
    nick.run(60)
    check(nick.events.isEmpty, "nickname tab + input only: no")
    nick.world.processes = chromeProcs(inp: true, out: true)
    nick.run(30)
    check(nick.count("start") == 1 && nick.signal(.meet)?.meetingKey == "team-standup" && nick.signal(.meet)?.confidence == .low, "nickname tab + in + out: LOW session keyed by the nickname")
}

private func testDetectorMeetSplit() {
    section("detector pipeline: back-to-back Meet calls, several tabs")
    let A = "https://meet.google.com/aaa-bbbb-ccc", B = "https://meet.google.com/ddd-eeee-fff"
    let codeA = "aaa-bbbb-ccc", codeB = "ddd-eeee-fff"

    // Next meeting opened in a new tab (it becomes the front tab) while the first tab stays open as the post-call page.
    let sim = DetectSim(platforms: [.meet])
    sim.world.backend.result = .ok([tab(A, title: "Meet", active: true)])
    sim.world.processes = chromeProcs(inp: true, out: true)
    sim.run(40)
    check(sim.count("start") == 1 && sim.signal(.meet)?.meetingKey == codeA, "first meeting recorded")
    sim.world.backend.result = .ok([tab(A, title: "Meet"), tab(B, title: "Meet", active: true)])
    let switchedAt = sim.t
    sim.run(60)
    let split = sim.first("split")
    check(sim.signal(.meet)?.meetingKey == codeB, "the new tab is reported once it has been the front tab for the debounce time")
    check(split != nil && (split ?? 0) - switchedAt >= 26 && (split ?? 0) - switchedAt <= 40,
          "split = tab list refresh (up to 12 s) + 4 s as front tab + GRACE (20 s) after the new tab appeared", "switched \(switchedAt) split \(String(describing: split))")
    sim.world.processes = chromeProcs()
    sim.run(60)
    check(sim.count("stop") == 1 && sim.count("start") == 1, "second meeting then ends normally")

    // The first tab is closed and the next meeting is opened: nothing to wait for, only the grace.
    let closed = DetectSim(platforms: [.meet])
    closed.world.backend.result = .ok([tab(A, title: "Meet", active: true)])
    closed.world.processes = chromeProcs(inp: true, out: true)
    closed.run(40)
    closed.world.backend.result = .ok([tab(B, title: "Meet", active: true)])
    let closedAt = closed.t
    closed.run(60)
    let closedSplit = closed.first("split")
    check(closedSplit != nil && (closedSplit ?? 0) - closedAt >= 22 && (closedSplit ?? 0) - closedAt <= 36, "chosen tab closed, next meeting open: splits one grace after the list shows it", "switched \(closedAt) split \(String(describing: closedSplit))")

    // Leave, wait until the session is over, join the next meeting in a new tab: a fresh start keyed by the NEW tab.
    let gap = DetectSim(platforms: [.meet])
    gap.world.backend.result = .ok([tab(A, title: "Meet", active: true)])
    gap.world.processes = chromeProcs(inp: true, out: true)
    gap.run(40)
    gap.world.processes = chromeProcs()
    gap.run(40)
    check(gap.count("stop") == 1, "first call over")
    gap.world.backend.result = .ok([tab(A, title: "Meet"), tab(B, title: "Meet", active: true)])
    gap.world.processes = chromeProcs(inp: true, out: true)
    gap.run(30)
    check(gap.count("start") == 2 && gap.signal(.meet)?.meetingKey == codeB && gap.count("split") == 0,
          "next call after a gap: the stale post-call tab is not chosen again, the front tab is (new session, no split)", "\(gap.events) \(gap.signal(.meet)?.meetingKey ?? "nil")")

    // The tab choice survives a Chrome audio pause shorter than the grace and is forgotten after a longer one.
    func firstKeyAfterIdle(_ idleSeconds: Int) -> String? {
        let s = DetectSim(platforms: [.meet])
        s.world.backend.result = .ok([tab(A, title: "Meet", active: true)])
        s.world.processes = chromeProcs(inp: true, out: true)
        s.run(40)
        s.world.processes = chromeProcs()
        s.run(idleSeconds)
        s.world.backend.result = .ok([tab(A, title: "Meet"), tab(B, title: "Meet", active: true)])
        s.world.processes = chromeProcs(inp: true, out: true)
        for _ in 0..<12 {
            s.run(2)
            if let sig = s.signal(.meet), sig.inCall { return sig.meetingKey }
        }
        return nil
    }
    check(firstKeyAfterIdle(10) == codeA, "Chrome audio paused for 10 s (under the grace): the choice is kept, a new tab still has to earn it")
    check(firstKeyAfterIdle(40) == codeB, "Chrome audio idle for 40 s (session over): forgotten, the front tab is chosen at first sight")

    // Review finding: recurring code R, one-off tab S, state that lives for days; then S is closed during the call.
    let R = "https://meet.google.com/rrr-rrrr-rrr", S = "https://meet.google.com/sss-ssss-sss"
    let days = DetectSim(platforms: [.meet])
    let day: TimeInterval = 86_400
    days.world.backend.result = .ok([tab(R, title: "Standup", active: true, id: "r1")])
    days.world.processes = chromeProcs(inp: true, out: true)
    days.run(40)
    days.world.processes = chromeProcs()
    days.run(40)
    days.world.now = days.world.now.addingTimeInterval(2 * day)                                   // Wednesday: a one-off meeting
    days.world.backend.result = .ok([tab(R, title: "Standup", id: "r1"), tab(S, title: "One-off", active: true, id: "s1")])
    days.world.processes = chromeProcs(inp: true, out: true)
    days.run(40)
    check(days.signal(.meet)?.meetingKey == "sss-ssss-sss", "Wednesday: the one-off tab S the user joined is the meeting")
    days.world.processes = chromeProcs()
    days.run(40)
    days.world.now = days.world.now.addingTimeInterval(5 * day)                                   // next Monday: the standup again
    days.world.backend.result = .ok([tab(R, title: "Standup", id: "r1"), tab(S, title: "One-off", id: "s1"), tab(R, title: "Standup", active: true, id: "r2")])
    days.world.processes = chromeProcs(inp: true, out: true)
    days.run(40)
    check(days.signal(.meet)?.meetingKey == "rrr-rrrr-rrr" && days.lastSnapshot?.best?.meetingKey == "rrr-rrrr-rrr",
          "next Monday: R and S still open, R joined in a new active tab: the session carries code R, not the stale S", days.signal(.meet)?.meetingKey ?? "nil")
    check(days.detector.lastDiagnostics()?.tabs?.chosenTabID?.tabID == "r2", "...keyed by the tab the user is in (r2)")
    let splitsBefore = days.count("split")
    days.world.backend.result = .ok([tab(R, title: "Standup", id: "r1"), tab(R, title: "Standup", active: true, id: "r2")])        // S closed mid-call
    days.run(100)
    check(days.count("split") == splitsBefore && days.count("stop") == 2 && days.signal(.meet)?.meetingKey == "rrr-rrrr-rrr",
          "closing the stale tab S during the call causes no split and no stop", "\(days.events)")

    // Second Meet tab while the call goes on (the lobby of the next meeting, a calendar link).
    func established() -> DetectSim {
        let lobby = DetectSim(platforms: [.meet])
        lobby.world.backend.result = .ok([tab(A, title: "Meet", active: true)])
        lobby.world.processes = chromeProcs(inp: true, out: true)
        lobby.run(40)
        return lobby
    }
    /// Polls until the next tab-list query has happened (its answer is what the detector just learned).
    func untilNextQuery(_ sim: DetectSim) {
        let before = sim.world.backend.listCalls
        var guardCount = 0
        while sim.world.backend.listCalls == before, guardCount < 20 { sim.run(2); guardCount += 1 }
    }

    let background = established()
    background.world.backend.result = .ok([tab(A, title: "Meet", active: true), tab(B, title: "Meet")])
    background.run(180)
    check(background.count("split") == 0 && background.signal(.meet)?.meetingKey == codeA,
          "a second Meet tab opened in the BACKGROUND (never the front tab) never splits the call", "\(background.events)")

    let peek = established()
    peek.world.backend.result = .ok([tab(A, title: "Meet"), tab(B, title: "Meet", active: true)])
    untilNextQuery(peek)                                                                         // the detector has now seen B in front once
    peek.world.backend.result = .ok([tab(A, title: "Meet", active: true), tab(B, title: "Meet")])  // the user is back on the call
    peek.run(160)
    check(peek.count("split") == 0 && peek.signal(.meet)?.meetingKey == codeA, "a quick look at the next meeting's tab (not front for the debounce time) does not split", "\(peek.events)")

    // Start debounce 2 s is shorter than the 4 s tab-list cache: a cached answer must not be counted as more focus time.
    let quick = DetectSim(platforms: [.meet], debounce: 2)
    quick.world.backend.result = .ok([tab(A, title: "Meet", active: true)])
    quick.world.processes = chromeProcs(inp: true, out: true)
    quick.run(40)
    quick.world.backend.result = .ok([tab(A, title: "Meet"), tab(B, title: "Meet", active: true)])
    untilNextQuery(quick)
    quick.world.backend.result = .ok([tab(A, title: "Meet", active: true), tab(B, title: "Meet")])
    var quickKeys: [String] = []
    for _ in 0..<60 { quick.run(2); quickKeys.append(quick.signal(.meet)?.meetingKey ?? "nil") }
    check(!quickKeys.contains(codeB) && quick.count("split") == 0,
          "a tab seen in front by ONE tab-list query is not taken over from the cached answer (focus is timed between queries, not polls)", "\(quickKeys.prefix(6))")

    let stay = established()
    stay.world.backend.result = .ok([tab(A, title: "Meet"), tab(B, title: "Meet", active: true)])
    stay.run(100)
    check(stay.count("split") == 1 && stay.signal(.meet)?.meetingKey == codeB,
          "KNOWN LIMITATION: a second Meet tab that stays the front tab longer than debounce + grace splits the call (no per-tab audio state)")

    let regret = established()
    regret.world.backend.result = .ok([tab(A, title: "Meet"), tab(B, title: "Meet", active: true)])
    var waited = 0
    while regret.signal(.meet)?.meetingKey != codeB, waited < 40 { regret.run(2); waited += 1 }
    check(regret.signal(.meet)?.meetingKey == codeB, "the new front tab was accepted after the debounce")
    regret.world.backend.result = .ok([tab(A, title: "Meet", active: true)])                     // the user closes the lobby tab before the grace is over
    regret.run(160)
    check(regret.count("split") == 0 && regret.count("stop") == 0 && regret.signal(.meet)?.meetingKey == codeA,
          "closing that tab again before the grace is over cancels the pending split (the code flips back)", "\(regret.events)")

    // probe --tabs-always: the tab list stays observable after the call (L-12 / L-13); the call decision is unchanged.
    let post = DetectSim(platforms: [.meet], alwaysQueryTabs: true)
    post.world.backend.result = .ok([tab(A, title: "Weekly - Meet", active: true)])
    post.world.processes = chromeProcs(inp: true, out: true)
    post.run(30)
    post.world.processes = chromeProcs()
    post.world.backend.result = .ok([tab(A, title: "You left the meeting", active: true)])
    post.run(40)
    let afterLeave = post.detector.lastDiagnostics()?.tabs
    check(afterLeave?.status == "ok" && afterLeave?.meetTabs.first?.title == "You left the meeting" && afterLeave?.meetTabs.first?.url == A,
          "--tabs-always: after Leave (Chrome audio idle) the post-call page URL and title are still read (L-12)", "\(afterLeave?.status ?? "nil") \(afterLeave?.meetTabs.first?.title ?? "nil")")
    post.world.backend.result = .ok([tab("https://meet.google.com/landing", title: "Google Meet", active: true)])
    post.run(30)
    check(post.detector.lastDiagnostics()?.tabs?.meetTabs.first?.kind == .other && post.signal(.meet)?.inCall == false, "--tabs-always: return to home is visible too")
    check(post.count("start") == 1 && post.count("stop") == 1, "--tabs-always: forced tab queries never change the call decision (no new start, one stop)", "\(post.events)")
    let gated = DetectSim(platforms: [.meet])
    gated.world.backend.result = .ok([tab(A, title: "You left the meeting", active: true)])
    gated.world.processes = chromeProcs()
    gated.run(30)
    check(gated.detector.lastDiagnostics()?.tabs?.status == "idle" && gated.world.backend.totalCalls == 0, "production detector (no --tabs-always): still idle with no Chrome audio, Chrome untouched")
}

private func testDetectorZoomTeams() {
    section("detector pipeline: Zoom and Teams")
    let zoom = DetectSim(platforms: [.zoom])
    zoom.world.processes = zoomProcs()
    zoom.run(30)
    check(zoom.events.isEmpty, "zoom idle (no UDP, no input): nothing")
    zoom.world.processes = zoomProcs(out: true)
    zoom.run(120)
    check(zoom.events.isEmpty, "zoom output alone (chimes, webinar audio) for 2 minutes: nothing")
    zoom.world.udp[787] = 4
    zoom.run(20)
    check(zoom.count("start") == 1 && zoom.signal(.zoom)?.evidence.contains { $0.contains("via=udp") } == true, "meeting starts: main-pid UDP sockets -> recording")
    zoom.world.processes = zoomProcs(inp: true, out: true)
    zoom.run(30)
    // Leave: UDP gone, input gone. Zoom grace is 30 s even though GRACE_SECONDS is 20.
    let leftAt = zoom.t
    zoom.world.udp[787] = 0
    zoom.world.processes = zoomProcs()
    zoom.run(26)
    check(zoom.count("stop") == 0, "zoom: still recording 26 s after leaving (effective grace 30 s, not 20)")
    zoom.run(20)
    let stop = zoom.first("stop")
    check(stop != nil && (stop ?? 0) - leftAt >= 30 && (stop ?? 0) - leftAt <= 38, "zoom: stops about 30 s after leaving", "left \(leftAt) stop \(String(describing: stop))")

    let blip = DetectSim(platforms: [.zoom])
    blip.world.udp[787] = 5
    blip.world.processes = zoomProcs(inp: true)
    blip.run(20)
    for _ in 0..<5 {                                        // breakout-room style media rebuild: 24 s without UDP and input
        blip.world.udp[787] = 0
        blip.world.processes = zoomProcs()
        blip.run(24)
        blip.world.udp[787] = 5
        blip.world.processes = zoomProcs(inp: true)
        blip.run(20)
    }
    check(blip.count("start") == 1 && blip.count("stop") == 0, "zoom media rebuild gaps under 30 s do not split the recording", "\(blip.events)")

    let udpOnly = DetectSim(platforms: [.zoom])
    udpOnly.world.processes = zoomProcs()
    udpOnly.world.udp[787] = 3
    udpOnly.run(20)
    check(udpOnly.count("start") == 1, "zoom joined without computer audio (UDP, no input): detected")
    let noObject = DetectSim(platforms: [.zoom])
    noObject.world.processes = []                            // Zoom has no Core Audio process object...
    noObject.world.running["us.zoom.xos"] = [787]            // ...but NSRunningApplication knows the main pid
    noObject.world.udp[787] = 4
    noObject.run(20)
    check(noObject.count("start") == 1, "zoom main pid is found through NSRunningApplication when it has no Core Audio object")
    let helper = DetectSim(platforms: [.zoom])
    helper.world.processes = zoomProcs()
    helper.world.udp[56404] = 1                              // ZoomCefHelper QUIC socket: not the main pid
    helper.run(60)
    check(helper.events.isEmpty, "zoom helper-process UDP sockets are not counted")
    let micTest = DetectSim(platforms: [.zoom])
    micTest.world.processes = zoomProcs(inp: true)
    micTest.run(20)
    check(micTest.count("start") == 1, "KNOWN LIMITATION (L-08): Zoom input alone (Test Mic) starts a session")

    let teams = DetectSim(platforms: [.teams])
    teams.world.processes = teamsProcs()
    teams.run(30)
    teams.world.processes = teamsProcs(out: true)
    teams.run(180)
    check(teams.events.isEmpty, "teams: ringtone / notification output for 3 minutes never starts")
    teams.world.processes = teamsProcs(inp: true, out: true)
    teams.run(20)
    check(teams.count("start") == 1, "teams: input starts a session")
    let leftTeams = teams.t
    teams.world.processes = teamsProcs(out: true)           // output keeps playing after the call
    teams.run(24)
    check(teams.count("stop") == 0, "teams: 24 s after input ended still recording (grace 30)")
    teams.run(30)
    let teamsStop = teams.first("stop")
    check(teamsStop != nil && (teamsStop ?? 0) - leftTeams >= 30 && (teamsStop ?? 0) - leftTeams <= 38, "teams: output alone does not keep the session alive; stops about 30 s after input ended", "left \(leftTeams) stop \(String(describing: teamsStop))")
}

// MARK: - Zoom evidence tiers (STRONG / WEAK): docs/DETECTION.md section 3

/// A Zoom signal made by the real formula (evidence text, tier and all); the stable flags equal the raw ones, sockets >= 1 are stable.
private func zoomSig(sockets: Int, input: Bool = false, output: Bool = false, strongSockets: Int = ZoomTierSettings.defaultStrongSockets) -> PlatformSignal {
    let family = FamilyAudio(platform: .zoom, processes: zoomProcs(inp: input, out: output))
    return Detector.evaluateZoom(ZoomEvaluationInput(audio: family, stableInput: input, stableOutput: output, mainPIDs: [787],
                                                     udpSockets: sockets, stableUDP: sockets >= 1, strongSockets: strongSockets))
}

private func testZoomEvidenceTiers() {
    section("zoom evidence tiers: classification, evidence text, parsing")
    func verdict(_ sockets: Int?, input: Bool = false, output: Bool = false, strong: Int = 6) -> ZoomTierVerdict {
        return Detector.classifyZoom(sockets: sockets, stableInput: input, stableOutput: output, strongSockets: strong)
    }
    check(verdict(4).tier == .weak, "tier: 4 sockets, no input, no output (the idle flicker of the log) -> weak")
    check(verdict(1).tier == .weak && verdict(5).tier == .weak, "tier: 1 and 5 sockets without audio IO -> weak")
    check(verdict(6).tier == .strong && verdict(7).tier == .strong && verdict(12).tier == .strong, "tier: sockets >= ZOOM_STRONG_SOCKETS (6) -> strong")
    check(verdict(4, input: true).tier == .strong && verdict(0, input: true).tier == .strong, "tier: Zoom input running -> strong, with or without sockets (Test Mic is `via=input`)")
    check(verdict(3, output: true).tier == .strong && verdict(5, output: true).tier == .strong, "tier: output running with >= 3 sockets -> strong")
    check(verdict(2, output: true).tier == .weak && verdict(nil, output: true).tier == .weak, "tier: output running with fewer than 3 sockets stays weak")
    check(verdict(nil).tier == .weak && verdict(0).tier == .weak, "tier: no sockets at all (a smoothing hold-over poll) is weak")
    check(verdict(3, strong: 3).tier == .strong && verdict(2, strong: 3).tier == .weak && verdict(1, strong: 1).tier == .strong,
          "tier: ZOOM_STRONG_SOCKETS moves the threshold (3: 3 sockets are strong, 2 are not; 1: any socket)")
    check(verdict(7, input: true).reason == "sockets=7>=6, input" && verdict(4).reason == "sockets=4<6, no input, no output",
          "tier: the reason names every strong cause / what is missing", "\(verdict(7, input: true).reason) | \(verdict(4).reason)")

    // The exact strings of the real log (the user's Mac, 2026-10-10): the old three entries are unchanged, the tier is a fourth one.
    let flicker = zoomSig(sockets: 4)
    check(flicker.inCall && flicker.confidence == .high && flicker.evidence == [
        "zoom-audio in=0 out=0 raw=0/0 io=-", "udp main-pid=787 sockets=4 stable=1", "via=udp", "tier=weak (sockets=4<6, no input, no output)"],
          "the observed idle flicker reads: in=0 out=0 raw=0/0, sockets=4, via=udp, tier=weak", "\(flicker.evidence)")
    let join = Detector.evaluateZoom(ZoomEvaluationInput(audio: FamilyAudio(platform: .zoom, processes: zoomProcs(inp: true, out: true)),
                                                         stableInput: false, stableOutput: false, mainPIDs: [787], udpSockets: 7, stableUDP: true))
    check(join.inCall && join.evidence == [
        "zoom-audio in=0 out=0 raw=1/1 io=787:in+out", "udp main-pid=787 sockets=7 stable=1", "via=udp", "tier=strong (sockets=7>=6)"],
          "the observed real join reads: raw=1/1 io=787:in+out, sockets=7, via=udp, tier=strong", "\(join.evidence)")
    let joinInput = zoomSig(sockets: 7, input: true)
    check(joinInput.evidence.contains("via=udp+input") && joinInput.evidence.last == "tier=strong (sockets=7>=6, input)", "udp + input: via=udp+input, tier=strong (sockets, input)", "\(joinInput.evidence)")
    check(zoomSig(sockets: 0, input: true).evidence.contains("via=input") && zoomSig(sockets: 0, input: true).evidenceTier == .strong, "input without sockets: via=input, strong")
    let idle = zoomSig(sockets: 0)
    check(!idle.inCall && idle.evidence.count == 2 && !idle.evidence.contains { $0.hasPrefix("tier=") }, "an idle Zoom keeps its two old evidence entries (audio, udp) and names no tier", "\(idle.evidence)")
    let outputOnly = zoomSig(sockets: 0, output: true)
    check(!outputOnly.inCall && !outputOnly.evidence.contains { $0.hasPrefix("tier=") }, "output alone: not in call, no tier entry")

    // The tier travels in the evidence text: the writer (evaluateZoom) and the reader (evidenceTier) agree.
    check(flicker.evidenceTier == .weak && join.evidenceTier == .strong && joinInput.evidenceTier == .strong && zoomSig(sockets: 3, output: true).evidenceTier == .strong,
          "PlatformSignal.evidenceTier reads back what evaluateZoom wrote")
    check(sig(.zoom).evidenceTier == .strong, "a Zoom signal without a tier entry (scripted, old format) reads as strong")
    var teamsLookalike = sig(.teams)
    teamsLookalike.evidence = ["tier=weak (x)"]
    check(teamsLookalike.evidenceTier == .strong, "only Zoom signals can read weak: a Teams signal with a tier=weak entry is still strong")
    var meetTier = sig(.meet)
    meetTier.evidence = ["chrome-audio in=1 out=1 raw=1/1 io=4214:in+out", "tier=HIGH (code tab + in + out)"]
    check(meetTier.evidenceTier == .strong, "Meet's own `tier=HIGH` entry is not a Zoom tier")
    var garbled = sig(.zoom)
    garbled.evidence = ["tier=WEAK", "tier=", "tier=?"]
    check(garbled.evidenceTier == .strong, "an unknown tier word reads as strong (fail open to the old behaviour)")

    // Teams: no tiers (the data does not support them): the formula output has no tier entry and reads strong in every state.
    func teamsFamily(inp: Bool, out: Bool) -> FamilyAudio { FamilyAudio(platform: .teams, processes: teamsProcs(inp: inp, out: out)) }
    for (inp, out) in [(true, true), (true, false), (false, true), (false, false)] {
        let t = Detector.evaluateTeams(TeamsEvaluationInput(audio: teamsFamily(inp: inp, out: out), stableInput: inp, stableOutput: out))
        check(t.evidenceTier == .strong && !t.evidence.contains { $0.hasPrefix("tier=") }, "teams (in=\(inp) out=\(out)): no tier entry, reads strong")
    }
}

private func testZoomTierMachine() {
    section("zoom evidence tiers: state machine (start, keep, end, preference)")
    let weak = zoomSig(sockets: 4), strong = zoomSig(sockets: 7), idle = zoomSig(sockets: 0)

    // start
    let w = MachineRun(weakDebounce: 15)
    w.run(40, [weak])
    check(w.first("start") == 16 && w.count("start") == 1, "weak only: the recording starts after the weak debounce (15 s), not after the 4 s start debounce", "\(w.events)")
    check(w.machine.sessionStartedStrong == false, "... and the machine says it started on weak evidence")
    let s = MachineRun(weakDebounce: 15)
    s.run(10, [strong])
    check(s.first("start") == 5 && s.machine.sessionStartedStrong == true, "strong: the recording starts after the start debounce (4 s) as before, started on strong evidence", "\(s.events)")
    let lowSocketsInput = MachineRun(weakDebounce: 15)
    lowSocketsInput.run(10, [zoomSig(sockets: 3, input: true)])
    check(lowSocketsInput.first("start") == 5, "3 sockets + input running: strong, starts after the start debounce")
    let off = MachineRun(weakDebounce: 0)
    off.run(10, [weak])
    check(off.first("start") == 5 && !off.machine.candidateIsWeakOnly && off.machine.weakWait == 0, "ZOOM_WEAK_DEBOUNCE_SECONDS=0: weak evidence behaves like strong (the behaviour before the tiers)", "\(off.events)")
    let legacy = MachineRun()
    legacy.run(10, [weak])
    check(legacy.first("start") == 5, "the two-argument machine (the Types.swift contract) never waits for weak evidence")
    let tiny = MachineRun(weakDebounce: 2)
    tiny.run(10, [weak])
    check(tiny.first("start") == 5 && tiny.machine.weakWait == 4, "a weak debounce below the start debounce still waits the start debounce", "\(tiny.events) \(tiny.machine.weakWait)")
    check(MachineRun(weakDebounce: 15).machine.weakWait == 15, "weakWait reports max(start debounce, weak debounce)")

    // a flicker never starts
    for d in [4, 6, 10, 14] {
        let f = MachineRun(weakDebounce: 15)
        f.run(d, [weak])
        check(f.machine.isCandidate && f.machine.candidateIsWeakOnly, "a weak candidate is not 'a meeting detected' (\(d) s in)")
        f.run(200, [idle])
        check(f.count("start") == 0 && !f.machine.isRecording && !f.machine.isCandidate, "a \(d) s weak flicker never starts a recording")
        let control = MachineRun(weakDebounce: 0)
        control.run(d, [weak]); control.run(200, [idle])
        check(d < 5 ? control.count("start") == 0 : control.count("start") == 1, "(control: without the weak wait a \(d) s flicker \(d < 5 ? "is too short anyway" : "does start a recording")", "\(control.events)")
    }
    let strongFirst = MachineRun(weakDebounce: 15)
    strongFirst.run(10, [weak]); strongFirst.run(10, [strong])
    check(strongFirst.first("start") == 11 && strongFirst.machine.sessionStartedStrong == true, "weak that turns strong: starts at the first strong poll (the run is already older than the start debounce)", "\(strongFirst.events)")

    // end / keep: a flicker during the grace of a call that ended must not move the stop
    func stopTime(flickerAt: Int?, flicker: Int, weakDebounce: TimeInterval = 15) -> (stop: Int?, starts: Int) {
        let m = MachineRun(weakDebounce: weakDebounce)
        m.run(60, [strong])                                     // start at 5, last strong poll at 60
        let gap = flickerAt ?? 0
        if gap > 0 { m.run(gap, [idle]) }
        if flickerAt != nil { m.run(flicker, [weak]) }
        m.run(200, [idle])
        return (m.first("stop"), m.count("start"))
    }
    let base = stopTime(flickerAt: nil, flicker: 0)
    check(base.stop == 90 && base.starts == 1, "a call that ends: stop 30 s (zoom grace) after the last poll", "\(base)")
    for d in [4, 6, 10, 14] {
        let r = stopTime(flickerAt: 10, flicker: d)
        check(r.stop == base.stop && r.starts == 1, "a \(d) s weak flicker 10 s after the end does not move the stop and starts nothing", "\(r) vs \(base)")
    }
    let straddle = stopTime(flickerAt: 25, flicker: 14)
    check(straddle.stop == 100 && straddle.starts == 1,
          "a weak flicker that is still on when the grace runs out: the stop waits for its end (the first poll without a signal, 1 s after it), not 30 s more", "\(straddle) vs \(base)")
    check((straddle.stop ?? 0) <= (base.stop ?? 0) + 14 + 1, "... so the flicker delays the stop by its own length at most (never re-arms the 30 s grace)", "\(straddle) vs \(base)")
    let moved = stopTime(flickerAt: 10, flicker: 10, weakDebounce: 0)
    check((moved.stop ?? 0) > (base.stop ?? 0) + 4, "(control: without the weak wait the same flicker moves the stop later: the observed bug)", "\(moved)")
    let longWeak = stopTime(flickerAt: 10, flicker: 40)
    check(longWeak.stop == 60 + 10 + 40 + 30 && longWeak.starts == 1, "weak evidence that lasts past the weak debounce counts again and keeps the session (stop 30 s after it ended)", "\(longWeak)")

    // A Zoom that reconnects inside a real meeting (sockets gone for ~26 s, seen live on 2026-10-10 17:19) comes back WEAK for its first polls
    // (1, 2, 4 ... sockets, audio IO not up yet). That is one meeting: the weak return must not end the recording at the very poll that shows the
    // call is back (a stop there split the meeting in two recordings and lost ~15 s of it). 2 s polls, as in the app.
    func reconnect(gap: Int, back: [PlatformSignal], steady: PlatformSignal, weakDebounce: TimeInterval = 15) -> (starts: Int, stops: Int) {
        let m = MachineRun(weakDebounce: weakDebounce)
        m.run(40, step: 2, [strong])
        m.run(gap, step: 2, [idle])
        for s in back { m.run(2, step: 2, [s]) }
        m.run(120, step: 2, [steady])
        return (m.count("start"), m.count("stop"))
    }
    for gap in [12, 14, 16, 20, 24, 26, 28] {
        for (name, back, steady) in [("steady 4 sockets, no audio IO", [PlatformSignal](), weak),
                                     ("1/2/4 sockets for 6 s, then 7", [zoomSig(sockets: 1), zoomSig(sockets: 2), zoomSig(sockets: 4)], strong),
                                     ("4 sockets for 14 s, then 7", Array(repeating: weak, count: 7), strong),
                                     ("2 sockets, no audio IO", [PlatformSignal](), zoomSig(sockets: 2))] {
            let r = reconnect(gap: gap, back: back, steady: steady)
            let old = reconnect(gap: gap, back: back, steady: steady, weakDebounce: 0)
            check(r.starts == 1 && r.stops == 0 && r.starts == old.starts && r.stops == old.stops,
                  "Zoom reconnect inside a meeting: \(gap) s without signal, back with \(name): one recording, no split (as before the tiers)", "\(r) old \(old)")
        }
    }
    let longGap = reconnect(gap: 36, back: [], steady: weak)
    check(longGap.starts == 2 && longGap.stops == 1, "a gap longer than the grace still ends the recording (the meeting is over; weak evidence then needs the weak debounce for a new one)", "\(longGap)")
    // The stop never happens on a poll that still carries the signal (a weak run that has not counted yet cannot end the session).
    let hold = MachineRun(weakDebounce: 15)
    hold.run(40, step: 2, [strong]); hold.run(28, step: 2, [idle])      // last strong poll at 40, the 30 s grace is over at 70
    hold.run(6, step: 2, [weak])                                       // weak polls at 70, 72, 74: the first one is exactly at the grace
    check(hold.count("stop") == 0 && hold.machine.isRecording, "a weak run that follows a gap keeps the session while it is on (a poll with a signal never ends it)", "\(hold.events)")
    hold.run(10, step: 2, [idle])
    check(hold.first("stop") == 76 && hold.count("start") == 1, "... and the first poll without a signal ends it (the weak run did not re-arm the grace)", "\(hold.events)")
    let holdLong = MachineRun(weakDebounce: 15)
    holdLong.run(40, step: 2, [strong]); holdLong.run(28, step: 2, [idle]); holdLong.run(60, step: 2, [weak])
    check(holdLong.count("stop") == 0 && holdLong.machine.isRecording, "... a weak run that lasts the weak debounce counts again: the recording goes on (one meeting)", "\(holdLong.events)")

    // after the stop a flicker starts nothing; a persistent weak run does (after the weak debounce)
    let after = MachineRun(weakDebounce: 15)
    after.run(60, [strong]); after.run(100, [idle])
    check(after.count("stop") == 1, "(setup) the call stopped")
    after.run(14, [weak]); after.run(100, [idle])
    check(after.count("start") == 1, "a 14 s flicker right after the stop does not start a new recording")
    let persistAt = after.t
    after.run(40, [weak])
    check(after.count("start") == 2 && (after.first("start", after: persistAt) ?? 0) - persistAt == 16, "weak evidence that persists after the stop starts a new recording after the weak debounce", "\(after.events)")

    // a short strong call: stop 30 s after its last poll, however young the run was (strong polls always count)
    let shortStrong = MachineRun(weakDebounce: 15)
    shortStrong.run(8, [strong]); shortStrong.run(100, [idle])
    check(shortStrong.first("stop") == 38, "a short strong call (8 s) stops 30 s after its last poll", "\(shortStrong.events)")
    // a weak debounce longer than the grace: the continuous run that showed strong evidence is still alive
    let wide = MachineRun(weakDebounce: 120)
    wide.run(10, [strong]); wide.run(100, [weak])
    check(wide.count("start") == 1 && wide.count("stop") == 0, "weak debounce 120 s (longer than the grace): a call that started strong and shrinks stays recorded (continuous run with strong evidence)", "\(wide.events)")
    let wideFlicker = MachineRun(weakDebounce: 120)
    wideFlicker.run(60, [strong]); wideFlicker.run(10, [idle]); wideFlicker.run(100, [weak]); wideFlicker.run(100, [idle])
    check(wideFlicker.first("stop") == 171 && wideFlicker.count("start") == 1,
          "... a weak run that begins after a gap does not count until it has lasted 120 s: it re-arms nothing, and the session ends at the first poll without a signal after it", "\(wideFlicker.events)")

    // strong start, then fewer sockets and no audio IO for a long time (continuous): kept alive as before
    let drop = MachineRun(weakDebounce: 15)
    drop.run(10, [strong]); drop.run(600, [weak])
    check(drop.count("start") == 1 && drop.count("stop") == 0 && drop.machine.isRecording, "a call that started strong and drops to a few sockets (continuous) stays recorded", "\(drop.events)")
    let blink = MachineRun(weakDebounce: 15)
    blink.run(10, [strong]); blink.run(1, [idle]); blink.run(600, [weak])
    check(blink.count("stop") == 0, "... also across a single missed poll")

    // a weak-only candidate gives way to a strong signal of another platform (a Zoom flicker never delays a real Teams call)
    let teams = sig(.teams)
    let both = MachineRun(weakDebounce: 15)
    both.run(10, [weak, teams])
    check(both.first("start") == 5 && both.started?.platform == .teams, "weak Zoom + strong Teams at the same time: Teams starts after its own debounce", "\(both.events) \(String(describing: both.started?.platform))")
    let later = MachineRun(weakDebounce: 15)
    later.run(3, [weak]); later.run(10, [weak, teams])
    check(later.first("start") == 8 && later.started?.platform == .teams, "a weak Zoom candidate gives way to a Teams call that appears later", "\(later.events)")
    let strongZoom = MachineRun(weakDebounce: 15)
    strongZoom.run(3, [strong]); strongZoom.run(10, [strong, teams])
    check(strongZoom.first("start") == 5 && strongZoom.started?.platform == .zoom, "a strong Zoom candidate is kept (no change to the old rule)", "\(strongZoom.events)")
    let teamsOnly = MachineRun(weakDebounce: 15)
    teamsOnly.run(10, [teams])
    check(teamsOnly.first("start") == 5 && teamsOnly.machine.sessionStartedStrong == true, "Teams is unchanged: start after the start debounce")
    let teamsEnd = MachineRun(weakDebounce: 15)
    teamsEnd.run(10, [teams]); teamsEnd.run(100, [sig(.teams, false)])
    check(teamsEnd.first("stop") == 40, "Teams is unchanged: stop 30 s after the last poll", "\(teamsEnd.events)")
    let manual = DetectionStateMachine(startDebounce: 4, grace: 20, weakDebounce: 15)
    var manualMachine = manual
    manualMachine.adoptManualRecording()
    check(manualMachine.sessionStartedStrong == true && manual.sessionStartedStrong == nil, "a manual recording counts as started on strong evidence; no session -> nil")
}

private func testZoomTierPipeline() {
    section("zoom evidence tiers: whole pipeline (Core Audio flags + libproc sockets -> Detector -> state machine), observed flicker and real meetings")

    // The observed idle flicker: sockets=4, no audio IO, for 4 / 6 / 10 / 14 s, every 120 s, for 2 hours of virtual time.
    func twoHours(weakDebounce: TimeInterval) -> DetectSim {
        let sim = DetectSim(platforms: [.zoom], weakDebounce: weakDebounce)
        sim.world.processes = zoomProcs()
        let lengths = [4, 6, 10, 14]
        for cycle in 0..<60 {
            let d = lengths[cycle % lengths.count]
            sim.world.udp[787] = 4
            sim.run(d)
            sim.world.udp[787] = 0
            sim.run(120 - d)
        }
        return sim
    }
    let day = twoHours(weakDebounce: 15)
    check(day.t == 7200 && (day.rises[.zoom] ?? 0) >= 60, "2 h of flicker (4/6/10/14 s every 120 s): the detector saw it 60 times", "t=\(day.t) rises=\(day.rises[.zoom] ?? 0)")
    check(day.count("start") == 0 && !day.machine.isRecording, "... and not one recording started under the defaults (15 s weak debounce)", "\(day.events)")
    let oldDay = twoHours(weakDebounce: 0)
    check(oldDay.count("start") >= 30, "(control: with ZOOM_WEAK_DEBOUNCE_SECONDS=0 the same two hours start many false recordings)", "starts \(oldDay.count("start"))")

    // A weak signal that persists is a meeting after the weak debounce (the first seconds are lost).
    for sockets in [4, 3, 5, 1] {
        let slow = DetectSim(platforms: [.zoom], weakDebounce: 15)
        slow.world.processes = zoomProcs()
        slow.run(30)
        slow.world.udp[787] = sockets
        let t0 = slow.t
        slow.run(60)
        let start = slow.first("start")
        check(start != nil && (start ?? 0) - t0 >= 15 && (start ?? 0) - t0 <= 22 && slow.count("start") == 1,
              "\(sockets) sockets without audio IO, sustained: the recording starts after the 15 s weak debounce (15-22 s after the sockets appeared)", "t0=\(t0) \(slow.events)")
        check(slow.signal(.zoom)?.evidenceTier == .weak && slow.machine.isRecording && slow.machine.sessionStartedStrong == false, "... on weak evidence")
        slow.run(600)
        check(slow.count("stop") == 0, "... and a continuing weak call keeps the recording (\(sockets) sockets, 10 more minutes)")
        let left = slow.t
        slow.world.udp[787] = 0
        slow.run(60)
        let stop = slow.first("stop")
        check(stop != nil && (stop ?? 0) - left >= 30 && (stop ?? 0) - left <= 38, "... and ends about 30 s after the sockets are gone", "left \(left) stop \(String(describing: stop))")
    }

    // Real meetings keep starting within the normal debounce, whatever the weak debounce is.
    func joinStart(weakDebounce: TimeInterval, sockets: Int, input: Bool, output: Bool = false) -> (start: Int?, tier: EvidenceTier?) {
        let sim = DetectSim(platforms: [.zoom], weakDebounce: weakDebounce)
        sim.world.processes = zoomProcs()
        sim.run(20)
        sim.world.udp[787] = sockets
        sim.world.processes = zoomProcs(inp: input, out: output)
        let t0 = sim.t
        sim.run(40)
        return (sim.first("start").map { $0 - t0 }, sim.started.first?.evidenceTier)
    }
    for (name, sockets, input, output) in [("7 sockets, input and output (the observed join)", 7, true, true), ("7 sockets without input", 7, false, false),
                                           ("7 sockets with input", 7, true, false), ("4 sockets with input", 4, true, false),
                                           ("6 sockets (the threshold)", 6, false, false), ("3 sockets with output", 3, false, true)] {
        let now = joinStart(weakDebounce: 15, sockets: sockets, input: input, output: output)
        let old = joinStart(weakDebounce: 0, sockets: sockets, input: input, output: output)
        let limit = output && !input && sockets < 6 ? 12 : 10
        check(now.start != nil && (now.start ?? 99) <= limit && now.tier == .strong, "real meeting, \(name): strong, starts within \(limit) s", "\(now) (without the rule: \(old))")
        if !(output && !input && sockets < 6) {
            check(now.start == old.start, "real meeting, \(name): starts exactly when it did before the tiers", "\(now) vs \(old)")
        }
    }
    let weakCall = joinStart(weakDebounce: 15, sockets: 3, input: false)
    check((weakCall.start ?? 0) >= 15 && weakCall.tier == .weak, "1:1 call with 3 sockets and no audio IO: starts only after the weak debounce", "\(weakCall)")

    // The sockets of a real join ramp up (1, 2, 4, 7 ...): the first inCall poll may read WEAK, but the evidence of a call is the strongest poll of its
    // run, not the first one: the recording starts exactly when it did before the tiers (or at the first strong poll when that comes later).
    func rampStart(weakDebounce: TimeInterval, ramp: [Int], input: Bool = false) -> (start: Int?, tier: EvidenceTier?) {
        let sim = DetectSim(platforms: [.zoom], weakDebounce: weakDebounce)
        sim.world.processes = zoomProcs()
        sim.run(20)
        let t0 = sim.t
        sim.world.processes = zoomProcs(inp: input, out: input)
        for n in ramp { sim.world.udp[787] = n; sim.run(2) }
        sim.run(40)
        return (sim.first("start").map { $0 - t0 }, sim.started.first?.evidenceTier)
    }
    for ramp in [[1, 2, 4, 7], [1, 4, 7], [2, 3, 5, 6], [4, 7], [3, 4, 7, 7, 7]] {
        let now = rampStart(weakDebounce: 15, ramp: ramp), old = rampStart(weakDebounce: 0, ramp: ramp)
        check(now.start != nil && now.start == old.start, "join with sockets ramping \(ramp): starts exactly when it did before the tiers", "\(now) vs \(old)")
    }
    for ramp in [[1, 2, 3, 4, 5, 6, 7], [4, 4, 4, 4, 7], [4, 4, 4, 4, 4, 4, 4, 4, 7]] {
        let now = rampStart(weakDebounce: 15, ramp: ramp)
        let firstStrongPoll = 2 * ((ramp.firstIndex { $0 >= 6 } ?? 0) + 1)
        check(now.start != nil && (now.start ?? 99) <= max(8, firstStrongPoll), "join with a slow ramp \(ramp): starts at the first strong poll (\(firstStrongPoll) s) at the latest, not after the weak debounce", "\(now)")
    }

    // A Zoom that reconnects inside a real meeting (sockets gone for a while, then 1/2/4 ... sockets and no audio IO yet): one recording, as before the tiers.
    func reconnect(gap: Int, ramp: [Int], steady: Int, weakDebounce: TimeInterval = 15) -> (starts: Int, stops: Int) {
        let sim = DetectSim(platforms: [.zoom], weakDebounce: weakDebounce)
        sim.world.udp[787] = 7
        sim.world.processes = zoomProcs(inp: true, out: true)
        sim.run(60)
        sim.world.udp[787] = 0
        sim.world.processes = zoomProcs()
        sim.run(gap)
        for n in ramp { sim.world.udp[787] = n; sim.run(2) }
        sim.world.udp[787] = steady
        sim.run(120)
        return (sim.count("start"), sim.count("stop"))
    }
    for gap in [10, 14, 18, 22, 26, 28] {
        for (name, ramp, steady) in [("1/2/4 then 7", [1, 2, 4], 7), ("steady 4, no audio IO", [], 4), ("4 for 8 s then 7", [4, 4, 4, 4], 7),
                                     ("1/2/4 then 4, no audio IO", [1, 2, 4], 4), ("steady 2, no audio IO", [], 2)] {
            let r = reconnect(gap: gap, ramp: ramp, steady: steady)
            let old = reconnect(gap: gap, ramp: ramp, steady: steady, weakDebounce: 0)
            check(r.starts == 1 && r.stops == 0 && r.starts == old.starts && r.stops == old.stops,
                  "Zoom reconnect inside a meeting (detector pipeline): \(gap) s without sockets, back with \(name): one recording, no split", "\(r) old \(old)")
        }
    }
    let reconnectOver = reconnect(gap: 36, ramp: [], steady: 4)
    check(reconnectOver.starts == 2 && reconnectOver.stops == 1, "a gap beyond the grace (36 s) ends the recording as before; the weak return then waits for the weak debounce", "\(reconnectOver)")

    // A flicker during the grace of a real meeting must not move the stop; after the stop it starts nothing.
    func ending(flickerAfter gap: Int?, length: Int = 0, weakDebounce: TimeInterval = 15) -> (stop: Int?, left: Int, starts: Int) {
        let sim = DetectSim(platforms: [.zoom], weakDebounce: weakDebounce)
        sim.world.udp[787] = 7
        sim.world.processes = zoomProcs(inp: true, out: true)
        sim.run(60)
        let left = sim.t
        sim.world.udp[787] = 0
        sim.world.processes = zoomProcs()
        if let g = gap {
            sim.run(g)
            sim.world.udp[787] = 4
            sim.run(length)
            sim.world.udp[787] = 0
        }
        sim.run(200)
        return (sim.first("stop"), left, sim.count("start"))
    }
    let plain = ending(flickerAfter: nil)
    check(plain.starts == 1 && plain.stop != nil && (plain.stop ?? 0) - plain.left >= 30 && (plain.stop ?? 0) - plain.left <= 40, "real meeting ends: stop about 30 s later", "\(plain)")
    for d in [4, 6, 10, 14] {
        let r = ending(flickerAfter: 10, length: d)
        check(r.stop == plain.stop && r.starts == 1, "flicker of \(d) s starting 10 s after the meeting ended: the stop does not move and nothing new starts", "\(r) vs \(plain)")
    }
    let late = ending(flickerAfter: 24, length: 14)
    check(late.starts == 1 && late.stop != nil && (late.stop ?? 0) >= (plain.stop ?? 0) && (late.stop ?? 0) <= (plain.stop ?? 0) + 14 + 4,
          "flicker that starts 24 s after the end and is still on at the stop: the stop waits for its end (14 s at most), nothing new starts", "\(late) vs \(plain)")
    check((late.stop ?? 0) < (ending(flickerAfter: 24, length: 14, weakDebounce: 0).stop ?? 0), "... and it is still earlier than without the tiers (the old behaviour re-armed the whole 30 s grace)")
    let sensitive = ending(flickerAfter: 10, length: 10, weakDebounce: 0)
    check((sensitive.stop ?? 0) > (plain.stop ?? 0) + 4, "(control: without the weak wait the flicker 10 s after the end moves the stop later)", "\(sensitive) vs \(plain)")
    let afterStop = DetectSim(platforms: [.zoom], weakDebounce: 15)
    afterStop.world.udp[787] = 7
    afterStop.world.processes = zoomProcs(inp: true, out: true)
    afterStop.run(60)
    afterStop.world.udp[787] = 0
    afterStop.world.processes = zoomProcs()
    afterStop.run(120)
    check(afterStop.count("stop") == 1, "(setup) the real meeting stopped")
    afterStop.world.udp[787] = 4
    afterStop.run(14)
    afterStop.world.udp[787] = 0
    afterStop.run(120)
    check(afterStop.count("start") == 1, "a 14 s flicker right after the stop does not start a new recording", "\(afterStop.events)")

    // Strong start, then the call has fewer sockets and no audio IO for a long time: continuous evidence keeps the session.
    let shrink = DetectSim(platforms: [.zoom], weakDebounce: 15)
    shrink.world.udp[787] = 7
    shrink.world.processes = zoomProcs(inp: true, out: true)
    shrink.run(30)
    shrink.world.udp[787] = 3
    shrink.world.processes = zoomProcs()
    shrink.run(900)
    check(shrink.count("start") == 1 && shrink.count("stop") == 0 && shrink.signal(.zoom)?.evidenceTier == .weak,
          "a call that started strong and shrinks to 3 sockets without audio IO for 15 minutes is still recorded (as today)", "\(shrink.events)")

    // Teams: unchanged, also next to a Zoom flicker.
    let teamsAlone = DetectSim(platforms: [.teams], weakDebounce: 15)
    teamsAlone.world.processes = teamsProcs()
    teamsAlone.run(20)
    teamsAlone.world.processes = teamsProcs(inp: true, out: true)
    let tt0 = teamsAlone.t
    teamsAlone.run(30)
    let teamsOld = DetectSim(platforms: [.teams], weakDebounce: 0)
    teamsOld.world.processes = teamsProcs()
    teamsOld.run(20)
    teamsOld.world.processes = teamsProcs(inp: true, out: true)
    teamsOld.run(30)
    check(teamsAlone.first("start") == teamsOld.first("start") && (teamsAlone.first("start") ?? 0) - tt0 <= 10, "teams: starts exactly as without the tier rule (no weak tier for Teams)", "\(teamsAlone.events) vs \(teamsOld.events)")
    check(teamsAlone.signal(.teams)?.evidence.contains { $0.hasPrefix("tier=") } == false, "teams: the evidence has no tier entry")
    let mixed = DetectSim(platforms: [.zoom, .teams], weakDebounce: 15)
    mixed.world.processes = zoomProcs() + teamsProcs()
    mixed.run(20)
    mixed.world.processes = zoomProcs() + teamsProcs(inp: true)
    mixed.world.udp[787] = 4
    let mt0 = mixed.t
    mixed.run(10)
    mixed.world.udp[787] = 0
    mixed.run(30)
    let teamsStartAlone = DetectSim(platforms: [.teams], weakDebounce: 15)
    teamsStartAlone.world.processes = teamsProcs()
    teamsStartAlone.run(20)
    teamsStartAlone.world.processes = teamsProcs(inp: true)
    teamsStartAlone.run(40)
    check(mixed.count("start") == 1 && mixed.started.first?.platform == .teams && mixed.first("start") == teamsStartAlone.first("start"),
          "a Zoom flicker during a Teams join does not delay or replace the Teams recording", "\(mixed.events) vs \(teamsStartAlone.events) (t0=\(mt0))")

    // ZOOM_STRONG_SOCKETS reaches the formula.
    let custom = DetectSim(platforms: [.zoom], weakDebounce: 15, zoomTier: ZoomTierSettings(strongSockets: 3, weakDebounce: 15))
    custom.world.processes = zoomProcs()
    custom.run(10)
    custom.world.udp[787] = 3
    let ct0 = custom.t
    custom.run(30)
    check(custom.signal(.zoom)?.evidenceTier == .strong && (custom.first("start") ?? 99) - ct0 <= 10, "ZOOM_STRONG_SOCKETS=3: 3 sockets are strong and start at once", "\(custom.events) \(custom.signal(.zoom)?.evidence ?? [])")
    check(custom.detector.lastDiagnostics()?.zoomStrongSockets == 3 && custom.detector.lastDiagnostics()?.zoomTier == "strong", "diagnostics carry the threshold and the tier of the last poll")
    let tiering = DetectSim(platforms: [.zoom], weakDebounce: 15)
    tiering.world.processes = zoomProcs()
    tiering.run(4)
    check(tiering.detector.lastDiagnostics()?.zoomTier == nil && tiering.detector.lastDiagnostics()?.zoomStrongSockets == 6 && tiering.detector.lastDiagnostics()?.zoomWeakDebounce == 15,
          "diagnostics of an idle Zoom: no tier, thresholds 6 and 15 s")
    tiering.world.udp[787] = 4
    tiering.run(6)
    check(tiering.detector.lastDiagnostics()?.zoomTier == "weak" && tiering.detector.lastDiagnostics()?.zoomTierReason == "sockets=4<6, no input, no output", "diagnostics of a flicker: tier weak with the reason")
}

private func testDetectorIgnoresOthers() {
    section("detector pipeline: unrelated apps, self, snapshot shape")
    let sim = DetectSim()
    sim.world.processes = [proc(10, "com.apple.VoiceMemos", in: true), proc(11, "com.openai.chat", in: true, out: true),
                           proc(12, AppInfo.bundleID, in: true, out: true), proc(13, "com.tinyspeck.slackmacgap", in: true),
                           proc(14, "", in: true)] + chromeProcs() + zoomProcs() + teamsProcs()
    sim.run(60)
    check(sim.events.isEmpty, "dictation / chat / voice memos / our own recorder / Slack huddle: ignored")
    check(sim.lastSnapshot?.signals.map { $0.platform } == [.meet, .zoom, .teams], "one signal per enabled platform, in enabled order")
    check(sim.lastSnapshot?.signals.allSatisfy { !$0.evidence.isEmpty } == true, "every signal carries evidence")

    let some = DetectSim(platforms: [.zoom])
    some.world.processes = chromeProcs(inp: true, out: true) + zoomProcs()
    some.run(40)
    check(some.lastSnapshot?.signals.map { $0.platform } == [.zoom] && some.events.isEmpty, "disabled platforms produce no signal and are never evaluated")
    check(some.world.backend.totalCalls == 0, "Meet disabled: Chrome is never touched")

    let none = DetectSim(platforms: [])
    none.run(10)
    check(none.lastSnapshot?.signals.isEmpty == true && none.events.isEmpty, "no enabled platform: empty snapshot, no crash")

    let diag = sim.detector.lastDiagnostics()
    check(diag != nil && diag?.flags.count == 3 && diag?.signals.count == 3, "diagnostics expose raw/smoothed flags for the probe")
}

// MARK: - Meet off by default (SPEC 15)

private func testMeetOffByDefault() {
    section("Meet is off by default (SPEC 15): no Chrome tab query, no AppleScript, probe shows the enabled platforms only")
    let defaults = AppConfig.defaults()
    check(defaults.enabledPlatforms == [.zoom, .teams], "the built-in default is zoom,teams", "\(defaults.enabledPlatforms)")

    // The detector with the DEFAULT platforms while Chrome makes noise (in + out, as in a Meet call): Chrome is never touched.
    let sim = DetectSim(platforms: defaults.enabledPlatforms)
    sim.world.processes = chromeProcs(inp: true, out: true) + zoomProcs() + teamsProcs()
    sim.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
    sim.run(60)
    check(sim.world.backend.totalCalls == 0, "default platforms, Chrome with in + out for 60 s: 0 calls to Chrome (no running check, no Automation state, no tab list)", "\(sim.world.backend.totalCalls)")
    check(sim.lastSnapshot?.signals.map { $0.platform } == [.zoom, .teams] && sim.signal(.meet) == nil && sim.events.isEmpty,
          "... the snapshot has zoom and teams only, a Meet tab does not start a recording")
    check(sim.detector.lastDiagnostics()?.flags.map { $0.platform } == [.zoom, .teams] && sim.detector.lastDiagnostics()?.tabs == nil,
          "... diagnostics carry no Meet flags and no tab information")
    sim.world.processes = zoomProcs(inp: true) + chromeProcs(inp: true, out: true)
    sim.run(20)
    check(sim.first("start") != nil && sim.world.backend.totalCalls == 0, "Zoom is still detected with the default platforms (and Chrome is still not asked)")

    // A hand-wired detector whose tab closure must never run.
    final class Spy { var tabCalls = 0 }
    let spy = Spy()
    let world = SimWorld()
    world.processes = chromeProcs(inp: true, out: true) + zoomProcs()
    let wired = Detector(config: defaults, inputs: DetectorInputs(
        now: { world.now }, audioProcesses: { interesting in world.processes.filter { interesting($0.bundleID) } }, audioObjectCount: { 0 },
        audioError: { nil }, udpCount: { _ in nil }, runningPIDs: { _ in [] },
        tabs: { _, _, _ in spy.tabCalls += 1; return TabsInfo(status: .idle) }))
    for _ in 0..<30 { world.now = world.now.addingTimeInterval(2); _ = wired.poll() }
    check(spy.tabCalls == 0, "the tab closure of the detector inputs is never called when Meet is not enabled", "\(spy.tabCalls)")

    // The production wiring (DetectorInputs.live) builds no ChromeTabs at all without Meet: the policy cannot matter.
    let enabled = TabQueryPolicy(enabled: true, reason: "selftest")
    let liveBackend = FakeChromeBackend()
    let live = DetectorInputs.live(config: defaults, policy: enabled, alwaysQueryTabs: true, backend: liveBackend)
    check(live.tabs(true, epoch, 4).status == .disabled(Detector.meetDisabledReason) && liveBackend.totalCalls == 0,
          "DetectorInputs.live without Meet: the tab query answers 'disabled' and the backend is untouched, even with an open policy and --tabs-always", "\(live.tabs(true, epoch, 4).status)")
    let liveDetector = Detector(config: defaults, inputs: DetectorInputs.live(config: defaults, policy: enabled, backend: liveBackend))
    let snap = liveDetector.poll()
    check(liveBackend.totalCalls == 0 && snap.signals.map { $0.platform } == [.zoom, .teams], "the real detector (live Core Audio reads) with the default platforms never touches Chrome", "\(liveBackend.totalCalls)")
    var meetCfg = defaults
    meetCfg.enabledPlatforms = [.zoom, .teams, .meet]
    let meetBackend = FakeChromeBackend()
    meetBackend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
    let meetLive = DetectorInputs.live(config: meetCfg, policy: enabled, backend: meetBackend)
    check(meetLive.tabs(true, epoch, 4).status.isOK && meetBackend.listCalls == 1, "with Meet enabled explicitly the same wiring reads the tabs (Meet coverage is intact)")

    // probe: the config and the output
    check(probeConfig(defaults, args: [AppInfo.shortName, "probe"]).enabledPlatforms == [.zoom, .teams], "probe: the enabled platforms are what the config says")
    check(probeConfig(defaults, args: [AppInfo.shortName, "probe", "--all-platforms"]).enabledPlatforms == [.zoom, .teams, .meet], "probe --all-platforms shows all three")
    check(probeConfig(defaults, args: ["probe", "--all-platforms"]).selfName == defaults.selfName && defaults.enabledPlatforms == [.zoom, .teams], "... and changes nothing else (the caller's config is untouched)")
    var zoomOnly = defaults
    zoomOnly.enabledPlatforms = [.zoom]
    check(probeConfig(zoomOnly, args: ["probe", "--all-platforms"]).enabledPlatforms == [.zoom, .teams, .meet], "--all-platforms overrides any ENABLED_PLATFORMS for the run")

    let chrome = FakeChromeBackend()
    chrome.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
    let report = ProbeCollector(config: defaults, policy: enabled, backend: chrome, zoomTier: .defaults).collect()
    check(chrome.totalCalls == 0 && !report.chromeRunning, "probe with Meet off: Chrome is not queried and not even looked for (chromeRunning=false)", "calls \(chrome.totalCalls)")
    check(report.diagnostics.signals.map { $0.platform } == [.zoom, .teams] && report.diagnostics.flags.map { $0.platform } == [.zoom, .teams] && !report.rows.contains { $0.family == .meet },
          "probe with Meet off: signals, flags and process rows are for the enabled platforms only")
    let table = ProbeRender.table(report, config: defaults)
    check(table.contains("not enabled: meet") && table.contains("probe --all-platforms") && !table.contains("CHROME / MEET") && table.contains("ZOOM") && table.contains("TEAMS"),
          "probe table with Meet off: says 'not enabled: meet', no Chrome / Meet section, Zoom and Teams sections present", table)
    let allCfg = probeConfig(defaults, args: ["probe", "--all-platforms"])
    let allReport = ProbeCollector(config: allCfg, policy: enabled, backend: FakeChromeBackend(), zoomTier: .defaults).collect()
    let allTable = ProbeRender.table(allReport, config: allCfg)
    check(allReport.diagnostics.signals.map { $0.platform } == [.zoom, .teams, .meet] && allTable.contains("CHROME / MEET") && !allTable.contains("not enabled:"),
          "probe --all-platforms: all three platforms evaluated and shown, no 'not enabled' line", "\(allReport.diagnostics.signals.map { $0.platform })")
}

// MARK: - Calls of other apps (docs/DETECTION.md section 3b)

/// A call app's processes the way an Electron app has them: the main process (no IO) and a helper that holds the IO (`onMain` puts the IO on the main one).
private func appProcs(_ id: String, pid: Int32 = 7000, `in` i: Bool = false, out o: Bool = false, onMain: Bool = false) -> [AudioProcessInfo] {
    return onMain ? [proc(pid, id, in: i, out: o), proc(pid + 1, id + ".helper")]
                  : [proc(pid, id), proc(pid + 1, id + ".helper", in: i, out: o)]
}

private let knownMode = CallDetectSettings(mode: .known)
private let genericMode = CallDetectSettings(mode: .generic)
private let slackID = "com.tinyspeck.slackmacgap"
private let discordID = "com.hnc.Discord"
private let voiceChatID = "com.example.voicechat"

private func callSig(_ id: String, _ on: Bool = true, kind: CallKind = .known, conf: Confidence = .high) -> PlatformSignal {
    var s = PlatformSignal(platform: .call, inCall: on, confidence: conf, meetingKey: id.lowercased(), bundleID: id, evidence: ["selftest"])
    s.appName = id
    s.callKind = kind
    return s
}

private func testCallKnownApps() {
    section("calls of other apps: the known table, every app through the detector")
    let table = CallApps.known
    check(table.count == 14, "the table has 14 apps", "\(table.count)")
    check(Set(table.map { $0.id.lowercased() }).count == table.count, "bundle ids are unique (case-insensitive)")
    check(table.allSatisfy { !$0.name.isEmpty && $0.name.count <= CallApps.maxNameLength && ExtraMeetingApps.isValidBundleID($0.id) }, "names are short and ids are valid bundle ids")
    check(!table.contains { $0.id.lowercased().hasPrefix("us.zoom") || $0.id.lowercased().hasPrefix("com.microsoft.teams") || CallApps.isBrowser($0.id) },
          "no entry overlaps Zoom, Teams or a browser")
    let wanted = ["Cisco Webex", "Slack huddle", "Discord", "FaceTime", "Skype", "GoTo", "Amazon Chime", "BlueJeans", "KakaoTalk", "JANDI", "WhatsApp"]
    check(wanted.allSatisfy { w in table.contains { $0.name == w } }, "the apps of the task whose bundle id could be verified are in the table")
    check(table.filter { $0.source == .installed }.map { $0.id }.sorted() == ["com.apple.FaceTime", "com.kakao.KakaoTalkMac", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp"],
          "the ids read from an installed app are exactly FaceTime, KakaoTalk, Slack and WhatsApp (the rest come from public listings)")
    check(CallApps.known(forBundle: "COM.TINYSPECK.SLACKMACGAP")?.name == "Slack huddle" && CallApps.known(forBundle: "com.tinyspeck.slackmacgapx") == nil
          && CallApps.known(forBundle: "com.tinyspeck.slackmacgap.helper.Renderer")?.id == slackID && CallApps.known(forBundle: "") == nil,
          "lookup: any case, helpers of the app, never a longer sibling id, never the empty id")

    for app in table {
        let sim = DetectSim(platforms: [.zoom], calls: knownMode)
        sim.world.processes = appProcs(app.id)
        sim.run(20)
        check(sim.callSignals().isEmpty && sim.events.isEmpty, "\(app.name): an idle app has no signal")
        sim.world.processes = appProcs(app.id, in: true, out: true)
        let t0 = sim.t
        sim.run(30)
        let start = sim.first("start")
        let s = sim.callSignal(app.id)
        check(start != nil && (start ?? 0) - t0 >= 8 && (start ?? 0) - t0 <= 22, "\(app.name): input + output start the call after smoothing + debounce", "start \(String(describing: start)) t0 \(t0)")
        check(s?.inCall == true && s?.callKind == .known && s?.appName == app.name && s?.bundleID == app.id && s?.confidence == .high && s?.meetingKey == app.id.lowercased(),
              "\(app.name): the signal names the app (known, high, key = bundle id)", "\(String(describing: s))")
        check(sim.started.first?.platform == .call && sim.started.first?.evidenceTier == .strong, "\(app.name): the state machine starts a call platform session (strong)")
        let leftAt = sim.t
        sim.world.processes = appProcs(app.id)
        sim.run(60)
        let stop = sim.first("stop")
        check(stop != nil && (stop ?? 0) - leftAt >= 30 && (stop ?? 0) - leftAt <= 45, "\(app.name): it stops after the 30 s grace of calls", "left \(leftAt) stop \(String(describing: stop))")
        for (i, o) in [(true, false), (false, true)] {
            let alone = DetectSim(platforms: [.zoom], calls: knownMode)
            alone.world.processes = appProcs(app.id, in: i, out: o)
            alone.run(180)
            check(alone.events.isEmpty && alone.callSignal(app.id)?.inCall != true, "\(app.name): \(i ? "input" : "output") alone never starts")
        }
    }

    let upper = DetectSim(platforms: [.zoom], calls: knownMode)
    upper.world.processes = appProcs("COM.TINYSPECK.SLACKMACGAP", in: true, out: true)
    upper.run(30)
    check(upper.count("start") == 1 && upper.callSignal(slackID)?.bundleID == slackID, "a process id in other letters is the same app, reported with the table's spelling")

    // keep rule: the microphone closes (muted) or the output stops while the other one stays: the call goes on.
    let keep = DetectSim(platforms: [.zoom], calls: knownMode)
    keep.world.processes = appProcs(slackID, in: true, out: true)
    keep.run(30)
    keep.world.processes = appProcs(slackID, in: false, out: true)
    keep.run(300)
    keep.world.processes = appProcs(slackID, in: true, out: false)
    keep.run(300)
    check(keep.count("start") == 1 && keep.count("stop") == 0, "keep rule: output alone or input alone keeps a running call (a muted microphone that the app closes does not end it)", "\(keep.events)")
    keep.world.processes = appProcs(slackID)
    keep.run(60)
    check(keep.count("stop") == 1, "... and when both close the call ends")
    let evidence = keep.callSignal(slackID)?.evidence ?? []
    check(evidence.isEmpty, "an app without any audio IO has no signal at all", "\(evidence)")
}

private func testCallHelpers() {
    section("calls of other apps: helper processes belong to the app")
    check(CallApps.mainBundleID(of: "com.tinyspeck.slackmacgap.helper") == slackID && CallApps.mainBundleID(of: "com.tinyspeck.slackmacgap.helper.Renderer") == slackID
          && CallApps.mainBundleID(of: "com.tinyspeck.slackmacgap.helper.GPU") == slackID && CallApps.mainBundleID(of: "com.tinyspeck.slackmacgap.Helper.Plugin") == slackID,
          "helper ids (.helper, .helper.Renderer, .helper.GPU, any case) map to the main app")
    check(CallApps.mainBundleID(of: "com.example.app") == "com.example.app" && CallApps.mainBundleID(of: "com.foo.helperapp") == "com.foo.helperapp"
          && CallApps.mainBundleID(of: "helper.app.x") == "helper.app.x" && CallApps.mainBundleID(of: "") == "" && CallApps.mainBundleID(of: "a.helper") == "a.helper",
          "an id without a `helper` component stays as it is (also a short one, and `helperapp`)")
    check(CallApps.mainBundleID(of: "com.foo.app.helper.x.y") == "com.foo.app", "everything from the first helper component on is dropped")

    let split = DetectSim(platforms: [.zoom], calls: knownMode)
    split.world.processes = [proc(7000, slackID), proc(7001, slackID + ".helper", in: true), proc(7002, slackID + ".helper.GPU", out: true), proc(7003, slackID + ".helper.Renderer")]
    split.run(30)
    let s = split.callSignal(slackID)
    check(split.callSignals().count == 1 && s?.inCall == true && split.count("start") == 1, "main + three helpers are ONE app: input in one helper and output in another make one call", "\(split.callSignals().count)")
    check(s?.evidence.first?.contains("7001:in") == true && s?.evidence.first?.contains("7002:out") == true, "the evidence names the pids that carry the IO", "\(s?.evidence ?? [])")

    let onlyHelper = DetectSim(platforms: [.zoom], calls: knownMode)
    onlyHelper.world.processes = [proc(7001, slackID + ".helper", in: true, out: true)]
    onlyHelper.run(30)
    check(onlyHelper.count("start") == 1 && onlyHelper.callSignal(slackID)?.bundleID == slackID, "a helper alone (no main process object) still counts for its app")

    let sibling = DetectSim(platforms: [.zoom], calls: knownMode)
    sibling.world.processes = [proc(7001, "com.tinyspeck.slackmacgapx.helper", in: true, out: true)]
    sibling.run(60)
    check(sibling.callSignals().isEmpty, "a similar id that is not Slack's helper is not Slack")

    // generic: a helper of an unknown app folds into its main app, whose name comes from the running app
    let generic = DetectSim(platforms: [.zoom], calls: genericMode)
    generic.world.apps[voiceChatID] = CallAppInfo(name: "Voice Chat", isGUI: true)
    generic.world.processes = [proc(8000, voiceChatID + ".helper.Renderer", in: true, out: true)]
    generic.run(80)
    let g = generic.callSignal(voiceChatID)
    check(generic.callSignals().count == 1 && g?.bundleID == voiceChatID && g?.appName == "Voice Chat" && g?.callKind == .generic, "generic: a helper folds into the main app, named after the running app", "\(String(describing: g))")
}

private func testCallExtraApps() {
    section("EXTRA_MEETING_APPS: parsing")
    func ids(_ r: ExtraMeetingApps.Result) -> [String] { r.apps.map { $0.id } }
    check(ExtraMeetingApps.parse("") == ExtraMeetingApps.Result() && ExtraMeetingApps.parse("   ").apps.isEmpty, "empty value: nothing, no problem")
    check(ExtraMeetingApps.parse("com.example.talk").apps == [ExtraCallApp(id: "com.example.talk", name: "talk")], "an id alone is named after its last part")
    let two = ExtraMeetingApps.parse("com.example.talk=Example Talk, org.foo.bar = Foo Bar ")
    check(two.apps == [ExtraCallApp(id: "com.example.talk", name: "Example Talk"), ExtraCallApp(id: "org.foo.bar", name: "Foo Bar")] && two.problems.isEmpty, "id=Name, with spaces around", "\(two)")
    check(ExtraMeetingApps.parse("com.a.b=A=B").apps.first?.name == "A=B", "the name may contain '='")

    let garbage = ExtraMeetingApps.parse(",,, ,nodot, a b.c, com.x.y=, =Name, \u{E9}.\u{E9}.\u{E9}, com.good.app")
    check(ids(garbage) == ["com.x.y", "com.good.app"] && garbage.apps.first?.name == "y" && garbage.problems.count == 4, "garbage entries are dropped one by one, the good ones kept", "\(garbage)")
    check(ExtraMeetingApps.parse("com.a.b\ncom.c.d").apps.isEmpty, "a newline is not a separator (the comma is)")
    check(!ExtraMeetingApps.isValidBundleID("") && !ExtraMeetingApps.isValidBundleID("nodot") && !ExtraMeetingApps.isValidBundleID(".a.b") && !ExtraMeetingApps.isValidBundleID("a b.c")
          && !ExtraMeetingApps.isValidBundleID("a/b.c") && !ExtraMeetingApps.isValidBundleID(String(repeating: "a", count: 200) + ".b") && ExtraMeetingApps.isValidBundleID("Cisco-Systems.Spark")
          && ExtraMeetingApps.isValidBundleID("com.a_b.c-d1"), "bundle id syntax")

    let dup = ExtraMeetingApps.parse("com.a.b=One, COM.A.B=Two, com.a.b")
    check(ids(dup) == ["com.a.b"] && dup.apps.first?.name == "One" && dup.problems.count == 2, "duplicates (any case): the first entry counts", "\(dup)")

    let refused = ExtraMeetingApps.parse("\(AppInfo.bundleID).x, us.zoom.xos, com.microsoft.teams2, com.google.Chrome, com.apple.Safari, org.mozilla.firefox, \(slackID), org.example.browser.app",
                                         browserPrefixes: ["org.example.browser"])
    check(refused.apps.isEmpty && refused.problems.count == 6 && refused.problems.last?.contains("3 more problem") == true,
          "our own app, Zoom, Teams, browsers (also BROWSER_BUNDLE_IDS) and apps of the table are refused; the problem list is cut at 5 lines plus a count", "\(refused)")
    check(ExtraMeetingApps.parse("us.zoom.xos").problems.first?.contains("Zoom") == true && ExtraMeetingApps.parse("com.google.Chrome").problems.first?.contains("browser") == true,
          "each refusal says why")

    var huge = ""
    for i in 0..<10_000 { huge += "com.example.app\(i),"}
    let many = ExtraMeetingApps.parse(huge)
    check(many.apps.count == ExtraMeetingApps.maxEntries && many.problems.contains { $0.contains("more than \(ExtraMeetingApps.maxEntries)") }, "10 000 entries: the first 64 are kept, one problem line says so", "\(many.apps.count)")
    let started = Date()
    let noise = ExtraMeetingApps.parse(String(repeating: "x,", count: 500_000))
    check(noise.apps.isEmpty && noise.problems.count <= ExtraMeetingApps.maxProblems + 2 && Date().timeIntervalSince(started) < 5, "a megabyte of garbage: nothing kept, few problem lines, no hang", "\(noise.problems.count) problems, \(Date().timeIntervalSince(started)) s")
    let longName = ExtraMeetingApps.parse("com.a.b=" + String(repeating: "N", count: 10_000)).apps.first?.name ?? ""
    check(longName.count <= CallApps.maxNameLength && !longName.isEmpty, "a 10 000 character name is cut to 40")
    let evil = ExtraMeetingApps.parse("com.a.b=Evil\u{1B}[31m \u{202E}Name\u{0}").apps.first?.name ?? ""
    check(!evil.unicodeScalars.contains { NotificationText.isStrippedScalar($0) } && evil.contains("Name"), "control and bidi characters never reach a name", "\(evil.unicodeScalars.map { $0.value })")
    check(ExtraMeetingApps.parse("com.a.b=" + "\u{1F600}".repeated(100)).apps.first?.name.count ?? 99 <= CallApps.maxNameLength, "emoji names are cut by characters, not bytes")
    let sixtyFive = ExtraMeetingApps.parse((0..<65).map { "com.e.a\($0)" }.joined(separator: ","))
    check(sixtyFive.apps.count == 64 && sixtyFive.problems.count == 1, "65 valid entries: 64 kept")

    // through the detector
    let sim = DetectSim(platforms: [.zoom], calls: CallDetectSettings(mode: .known, extraApps: [ExtraCallApp(id: "com.naver.works.mac", name: "Naver Works")]))
    sim.world.processes = appProcs("com.naver.works.mac", in: true, out: true)
    sim.run(30)
    let s = sim.callSignal("com.naver.works.mac")
    check(sim.count("start") == 1 && s?.callKind == .extra && s?.appName == "Naver Works" && s?.confidence == .high, "an EXTRA_MEETING_APPS app is detected like a known one (kind extra, its name)", "\(String(describing: s))")
    let bypass = DetectSim(platforms: [.zoom], calls: CallDetectSettings(mode: .known, extraApps: [ExtraCallApp(id: "com.apple.mobilephone", name: "Phone")]))
    bypass.world.processes = appProcs("com.apple.mobilephone", in: true, out: true)
    bypass.run(30)
    check(bypass.count("start") == 1 && bypass.callSignal("com.apple.mobilephone")?.appName == "Phone", "an extra app is named on purpose: the deny list (Apple's apps) does not apply to it")
}

private func testCallSettings() {
    section("CALL_DETECT, CALL_GENERIC_SECONDS, CALL_BROWSER_URLS: parsing")
    let d = CallDetectSettings.build(from: [:], source: "test")
    check(d.mode == .known && d.genericSeconds == 45 && d.extraApps.isEmpty && !d.browserURLs && d == CallDetectSettings.defaults, "defaults: known (the named apps, NO guessing), 45 s, no extra apps, browser addresses off")
    check(CallDetectSettings.build(from: [:], source: "test", unsetMode: .off).mode == .off && CallDetectSettings.build(from: ["CALL_DETECT": "generic"], source: "test", unsetMode: .off).mode == .generic
          && CallDetectSettings.build(from: ["CALL_DETECT": ""], source: "test", unsetMode: .off).mode == .off, "unsetMode is what a missing or empty CALL_DETECT means (a managed Mac: off); a written value always wins")
    check(CallDetectSettings.off.mode == .off, "`.off` is the seam default of the detector")
    for (raw, want) in [("known", CallDetectSettings.Mode.known), ("generic", .generic), ("off", .off), ("OFF", .off), (" Known ", .known), ("GENERIC", .generic)] {
        check(CallDetectSettings.build(from: ["CALL_DETECT": raw], source: "test").mode == want, "CALL_DETECT=\(raw) is \(want.rawValue)")
    }
    check(CallDetectSettings.build(from: ["CALL_DETECT": "genric"], source: "test").mode == .known && CallDetectSettings.build(from: ["CALL_DETECT": "on"], source: "test").mode == .known,
          "an unknown CALL_DETECT text reads as known (never as guessing, never as off)")
    check(CallDetectSettings.build(from: ["CALL_DETECT": ""], source: "test").mode == .known, "an empty value keeps the default")
    check(CallDetectSettings.build(from: [:], source: "test").mode != .generic && CallDetectSettings().mode != .generic, "guessing is never the default: an upgrade without CALL_DETECT in config.env does not start recording apps nobody named")
    for (raw, want) in [("20", 20.0), ("5", 10), ("9999", 600), ("abc", 45), ("nan", 45), ("inf", 45), ("-3", 10), ("", 45), (" 30 ", 30), ("12.5", 12.5)] {
        check(CallDetectSettings.build(from: ["CALL_GENERIC_SECONDS": raw], source: "test").genericSeconds == want, "CALL_GENERIC_SECONDS=\(raw) -> \(want)")
    }
    for (raw, want) in [("on", true), ("1", true), ("TRUE", true), ("off", false), ("0", false), ("maybe", false), ("", false)] {
        check(CallDetectSettings.build(from: ["CALL_BROWSER_URLS": raw], source: "test").browserURLs == want, "CALL_BROWSER_URLS=\(raw) -> \(want)")
    }
    let withExtra = CallDetectSettings.build(from: ["EXTRA_MEETING_APPS": "com.example.talk=Talk, com.google.Chrome, org.example.browser.app", "BROWSER_BUNDLE_IDS": "org.example.browser"], source: "test")
    check(withExtra.extraApps == [ExtraCallApp(id: "com.example.talk", name: "Talk")], "EXTRA_MEETING_APPS reaches the settings (browsers of BROWSER_BUNDLE_IDS refused)", "\(withExtra.extraApps)")

    var cfg = AppConfig.defaults()
    var on = CallDetectSettings.defaults
    check(!on.needsBrowserAutomation(for: cfg), "browser addresses off (the default): no Chrome Automation needed")
    on.browserURLs = true
    check(on.needsBrowserAutomation(for: cfg), "CALL_BROWSER_URLS=on: Chrome Automation is needed")
    on.mode = .off
    check(!on.needsBrowserAutomation(for: cfg), "... but not with CALL_DETECT=off")
    on.mode = .known
    cfg.enabledPlatforms = []
    check(!on.needsBrowserAutomation(for: cfg), "... and not with an empty ENABLED_PLATFORMS (no automatic detection at all)")
    check(CallDetectSettings(mode: .generic).summary.contains("generic") && CallDetectSettings.off.summary.contains("off") && CallDetectSettings.defaults.summary.contains("no guessing"), "the log line says the mode")

    // ENABLED_PLATFORMS never takes `call`
    let plat = AppConfig.build(from: ["ENABLED_PLATFORMS": "zoom,call,teams"], source: "test")
    check(plat.enabledPlatforms == [.zoom, .teams], "ENABLED_PLATFORMS=zoom,call,teams: `call` is ignored (CALL_DETECT switches it)", "\(plat.enabledPlatforms)")
    check(AppConfig.build(from: ["ENABLED_PLATFORMS": "call"], source: "test").enabledPlatforms == [.zoom, .teams], "ENABLED_PLATFORMS=call alone: no valid platform, the default stays")

    // the file reader
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("mcap-callcfg-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("config.env")
    try? "CALL_DETECT=off   # comment\nCALL_GENERIC_SECONDS=60\nEXTRA_MEETING_APPS=com.example.talk=Talk # x\nCALL_BROWSER_URLS=1\n".write(to: file, atomically: true, encoding: .utf8)
    let loaded = CallDetectSettings.load(from: file, policy: OrgPolicy.absent())
    check(loaded.mode == .off && loaded.genericSeconds == 60 && loaded.extraApps.first?.id == "com.example.talk" && loaded.browserURLs, "config.env is read (inline comments, all four keys)", "\(loaded)")
    check(CallDetectSettings.load(from: dir.appendingPathComponent("missing.env"), policy: OrgPolicy.absent()) == .defaults, "a missing file means the defaults")
}

private func testCallGeneric() {
    section("generic rule: thresholds, gaps, GUI check")
    func sim(_ seconds: TimeInterval = 45, extra: CallDetectSettings? = nil) -> DetectSim {
        let s = DetectSim(platforms: [.zoom], calls: extra ?? CallDetectSettings(mode: .generic, genericSeconds: seconds))
        s.world.apps[voiceChatID] = CallAppInfo(name: "Voice Chat", isGUI: true)
        return s
    }
    let a = sim()
    a.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    a.run(36)
    check(a.callSignal(voiceChatID)?.inCall == false && a.events.isEmpty, "36 s of microphone + output: not yet a call")
    check(a.callSignal(voiceChatID)?.evidence.contains { $0.hasPrefix("generic: in+out held") } == true, "the evidence says how long the app has held both", "\(a.callSignal(voiceChatID)?.evidence ?? [])")
    a.run(30)
    let start = a.first("start")
    check(start != nil && (start ?? 0) >= 50 && (start ?? 0) <= 66, "after ~45 s (+ smoothing and the start debounce) it starts", "start \(String(describing: start))")
    let g = a.callSignal(voiceChatID)
    check(g?.inCall == true && g?.callKind == .generic && g?.confidence == .low && g?.appName == "Voice Chat" && g?.bundleID == voiceChatID && g?.meetingKey == voiceChatID,
          "the signal is generic, LOW confidence, named after the running app", "\(String(describing: g))")
    check(a.started.first?.callKind == .generic && a.started.first?.platform == .call, "the start signal carries the kind (the controller words its notification from it)")

    let fast = sim(20)
    fast.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    fast.run(60)
    check((fast.first("start") ?? 0) >= 28 && (fast.first("start") ?? 99) <= 42, "CALL_GENERIC_SECONDS=20 starts earlier", "\(String(describing: fast.first("start")))")
    let slow = sim(120)
    slow.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    slow.run(120)
    check(slow.events.isEmpty, "CALL_GENERIC_SECONDS=120: nothing after 120 s of hold")

    let gap = sim()
    gap.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    gap.run(30)
    gap.world.processes = []
    gap.run(8)
    gap.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    gap.run(30)
    check(gap.events.isEmpty, "a gap of 8 s restarts the hold: 30 s + gap + 30 s is no call", "\(gap.events)")

    let blip = sim()
    blip.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    blip.run(20)
    blip.world.processes = []
    blip.run(2)
    blip.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    blip.run(60)
    check(blip.first("start") == a.first("start") || abs((blip.first("start") ?? 0) - (a.first("start") ?? 0)) <= 2, "a single missed poll is bridged: the hold goes on", "\(String(describing: blip.first("start"))) vs \(String(describing: a.first("start")))")

    for (i, o) in [(true, false), (false, true)] {
        let alone = sim()
        alone.world.processes = [proc(8000, voiceChatID, in: i, out: o)]
        alone.run(600)
        check(alone.events.isEmpty && alone.callSignal(voiceChatID)?.inCall != true, "generic: \(i ? "microphone" : "output") alone for 10 minutes is never a call")
    }
    let split = sim()
    split.world.processes = [proc(8000, voiceChatID, in: true), proc(8100, "com.example.music", out: true)]
    split.run(300)
    check(split.events.isEmpty, "microphone in one app and output in another app are not a call")

    let near = sim()
    near.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    near.run(40)
    near.world.processes = []
    near.run(60)
    check(near.events.isEmpty && near.callSignals().isEmpty, "40 s of hold, then silence: nothing started, and the app is forgotten after a minute")

    // the keep rule of a GUESSED call: the microphone keeps it; output keeps it for two minutes after the microphone closed (a mute); output alone for longer never does.
    // An app that keeps playing sound without the microphone must not keep a recording of a non-call (and its microphone track) going for hours.
    let keep = sim()
    keep.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    keep.run(70)
    check(keep.count("start") == 1 && keep.callSignal(voiceChatID)?.inCall == true, "(the generic call is on)")
    keep.world.processes = [proc(8000, voiceChatID, in: false, out: true)]
    keep.run(90)
    check(keep.count("stop") == 0 && keep.callSignal(voiceChatID)?.inCall == true, "generic keep rule: the microphone closing (a mute) while output goes on keeps the call for a while (the output flag of a watched app is read)", "\(keep.events)")
    keep.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    keep.run(30)
    check(keep.count("stop") == 0 && keep.callSignal(voiceChatID)?.inCall == true, "... and the microphone coming back keeps the same recording (no second one)", "\(keep.events)")
    let closedAt = keep.t
    keep.world.processes = [proc(8000, voiceChatID, in: false, out: true)]
    keep.run(6 * 3600)
    check(keep.count("start") == 1 && keep.count("stop") == 1 && (keep.first("stop") ?? 0) - closedAt >= Int(CallTracker.genericOutputKeepSeconds) && (keep.first("stop") ?? 0) - closedAt <= 180,
          "output alone for 6 hours: the recording ends about \(Int(CallTracker.genericOutputKeepSeconds)) s + grace after the microphone closed, and nothing starts again (output never starts a call)",
          "\(keep.events.map { "\($0.kind)@\($0.t)" }) closed \(closedAt)")
    check(CallTracker.inCall(kind: .generic, stableInput: false, stableOutput: true, heldSeconds: nil, genericSeconds: 45, wasActive: true, secondsSinceInput: 60)
          && !CallTracker.inCall(kind: .generic, stableInput: false, stableOutput: true, heldSeconds: nil, genericSeconds: 45, wasActive: true, secondsSinceInput: CallTracker.genericOutputKeepSeconds + 1)
          && !CallTracker.inCall(kind: .generic, stableInput: false, stableOutput: true, heldSeconds: nil, genericSeconds: 45, wasActive: true)
          && CallTracker.inCall(kind: .generic, stableInput: true, stableOutput: false, heldSeconds: nil, genericSeconds: 45, wasActive: true)
          && CallTracker.inCall(kind: .known, stableInput: false, stableOutput: true, heldSeconds: nil, genericSeconds: 45, wasActive: true, secondsSinceInput: 99_999)
          && CallTracker.inCall(kind: .extra, stableInput: true, stableOutput: false, heldSeconds: nil, genericSeconds: 45, wasActive: true)
          && !CallTracker.inCall(kind: .known, stableInput: false, stableOutput: true, heldSeconds: nil, genericSeconds: 45, wasActive: false),
          "inCall (pure): a guessed call is kept by the input, and by the output only within the bounded time after the input; a named app by input or output; output alone never starts anything")
    let namedKeep = DetectSim(platforms: [.zoom], calls: knownMode)
    namedKeep.world.processes = appProcs(slackID, in: true, out: true)
    namedKeep.run(60)
    namedKeep.world.processes = appProcs(slackID, out: true)
    namedKeep.run(600)
    check(namedKeep.count("start") == 1 && namedKeep.count("stop") == 0 && namedKeep.callSignal(slackID)?.inCall == true, "a known app is still kept by output alone, however long (an app that closes the microphone on mute)", "\(namedKeep.events)")

    // GUI check and names
    let daemon = sim()
    daemon.world.apps[voiceChatID] = CallAppInfo(name: "x", isGUI: false)
    daemon.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    daemon.run(120)
    check(daemon.events.isEmpty && daemon.callSignals().isEmpty, "not a GUI app (daemon, background agent): never guessed")
    let unknown = sim()
    unknown.world.guiByDefault = false
    unknown.world.apps = [:]
    unknown.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    unknown.run(120)
    check(unknown.events.isEmpty, "no running app with that id: never guessed")
    let named = sim()
    named.world.apps[voiceChatID] = CallAppInfo(name: "Evil\u{1B}[31m \u{202E}App\nLine two " + String(repeating: "x", count: 100), isGUI: true)
    named.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    named.run(12)
    let nm = named.callSignal(voiceChatID)?.appName ?? ""
    check(!nm.isEmpty && nm.count <= CallApps.maxNameLength && !nm.unicodeScalars.contains { NotificationText.isStrippedScalar($0) } && !nm.contains("\n"), "an app's name is one clean line of at most 40 characters", nm)
    let noName = sim()
    noName.world.apps[voiceChatID] = CallAppInfo(name: "", isGUI: true)
    noName.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    noName.run(12)
    check(noName.callSignal(voiceChatID)?.appName == "voicechat", "an empty name falls back to the last part of the bundle id")
    let wake = sim()
    wake.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    wake.run(6)
    let first = wake.callSignal(voiceChatID)?.evidence.first ?? ""
    check(first.contains("in=") && first.contains("out=") && first.contains("raw=1/1"), "the evidence shows smoothed and raw flags", first)

    // backwards clock never crashes or freezes
    let clock = sim()
    clock.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    clock.run(60)
    clock.world.now = clock.world.now.addingTimeInterval(-3600)
    clock.run(10)
    check(clock.callSignal(voiceChatID) != nil, "a wall clock that jumps back an hour does not crash the tracker")
}

private func testCallDenyList() {
    section("generic rule: built-in deny list, user decisions, extra apps")
    let denied = ["com.apple.Music", "com.apple.podcasts", "com.apple.VoiceMemos", "com.apple.QuickTimePlayerX", "com.apple.Safari", "com.apple.WebKit.WebContent", "com.apple.Terminal",
                  "com.apple.dt.Xcode", "com.apple.siri.xyz", "com.apple.garageband10", "com.google.Chrome", "com.google.Chrome.helper", "com.google.Chrome.canary", "com.google.Chrome.app.abcdef",
                  "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.googlecode.iterm2", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                  "com.jetbrains.intellij", "com.obsproject.obs-studio", "com.nuance.dragon", "com.nuance.mobility.speech", "com.anthropic.claudefordesktop",
                  "com.openai.chat", "com.openai.codex", "com.google.GeminiMacOS", "com.spotify.client", "us.zoom.xos", "us.zoom.caphost", "com.microsoft.teams2", "com.microsoft.teams",
                  AppInfo.bundleID, AppInfo.bundleID + ".helper", "com.movist.Movist", "com.rogueamoeba.audiohijack", ""]
    check(denied.allSatisfy { CallApps.isBuiltInDenied($0) }, "the deny list names media players, music, podcasts, Voice Memos, QuickTime, recorders, dictation, assistants, browsers, terminals, IDEs, system apps, Zoom, Teams and this app",
          "\(denied.filter { !CallApps.isBuiltInDenied($0) })")
    let allowed = [slackID, voiceChatID, "net.whatsapp.WhatsApp", "com.kakao.KakaoTalkMac", "com.microsoft.SkypeForBusiness", "com.microsoftx.foo", "com.googleplex.app", "org.mozillax.app"]
    check(allowed.filter { CallApps.isBuiltInDenied($0) }.isEmpty, "other apps (and ids that merely start with a denied name) are not on the deny list", "\(allowed.filter { CallApps.isBuiltInDenied($0) })")
    check(CallApps.isBuiltInDenied("org.example.browser.helper", extraBrowserPrefixes: ["org.example.browser"]) && !CallApps.isBuiltInDenied("org.example.browser.helper"), "BROWSER_BUNDLE_IDS adds browsers to the deny list")

    // the whole list in one world, plus one real app
    // Zoom and Teams are denied for the generic rule because they have detectors of their own: they are left out of this world (their detectors would start).
    let busy = denied.filter { !$0.isEmpty && !$0.hasPrefix("us.zoom") && !$0.hasPrefix("com.microsoft.teams") }
    let sim = DetectSim(platforms: [.zoom], calls: genericMode)
    sim.world.processes = busy.enumerated().flatMap { appProcs($0.element, pid: Int32(9000 + $0.offset * 2), in: true, out: true) } + [proc(8000, voiceChatID, in: true, out: true)]
    sim.world.apps[voiceChatID] = CallAppInfo(name: "Voice Chat", isGUI: true)
    sim.run(180)
    check(sim.callSignals().map { $0.bundleID } == [voiceChatID], "\(busy.count) denied apps with microphone + output for 3 minutes produce no signal; the one app that is not denied does", "\(sim.callSignals().map { $0.bundleID ?? "?" })")
    check(sim.count("start") == 1 && sim.started.first?.bundleID == voiceChatID, "... and only that app starts a recording")

    let own = DetectSim(platforms: [.zoom], calls: CallDetectSettings(mode: .known, extraApps: [ExtraCallApp(id: "org.example.other", name: "X")]))
    own.world.processes = [proc(1, AppInfo.bundleID, in: true, out: true), proc(2, AppInfo.bundleID + ".helper", in: true, out: true)]
    own.run(120)
    check(own.callSignals().isEmpty, "our own recorder is never a call")

    // FaceTime is under com.apple (denied) but in the table: the table is looked at first, in generic mode too
    let ft = DetectSim(platforms: [.zoom], calls: genericMode)
    ft.world.processes = appProcs("com.apple.FaceTime", in: true, out: true)
    ft.run(60)
    check(ft.count("start") == 1 && ft.callSignal("com.apple.FaceTime")?.callKind == .known, "FaceTime is a known app although Apple's other apps are denied")

    // custom browser
    let browser = DetectSim(platforms: [.zoom], browsers: ["org.example.browser"], calls: genericMode)
    browser.world.processes = appProcs("org.example.browser", in: true, out: true)
    browser.run(120)
    check(browser.callSignals().isEmpty, "a browser named in BROWSER_BUNDLE_IDS is never guessed")

    // the person's decisions
    let store = CallAppStore(file: nil)
    let user = DetectSim(platforms: [.zoom], calls: genericMode, callStore: store)
    user.world.apps[voiceChatID] = CallAppInfo(name: "Voice Chat", isGUI: true)
    store.set(slackID, decision: .denied, name: "Slack huddle")
    store.set(voiceChatID, decision: .denied, name: "Voice Chat")
    user.world.processes = appProcs(slackID, in: true, out: true) + [proc(8000, voiceChatID, in: true, out: true)]
    user.run(120)
    check(user.events.isEmpty && user.callSignals().isEmpty, "apps denied by the person (a known one and a generic one) are never recorded")
    store.set(slackID, decision: .allowed, name: nil)
    user.run(40)
    check(user.count("start") == 1 && user.started.first?.bundleID == slackID, "allowing the app again makes it detectable at once (the store is read every poll)")
    store.set("com.apple.Music", decision: .allowed, name: "Music")
    let music = DetectSim(platforms: [.zoom], calls: genericMode, callStore: store)
    music.world.processes = appProcs("com.apple.Music", in: true, out: true)
    music.run(120)
    check(music.callSignals().isEmpty, "'allowed' never lifts the built-in deny list (EXTRA_MEETING_APPS does)")
    let deniedExtra = DetectSim(platforms: [.zoom], calls: CallDetectSettings(mode: .known, extraApps: [ExtraCallApp(id: "com.example.talk", name: "Talk")]), callStore: store)
    store.set("com.example.talk", decision: .denied, name: "Talk")
    deniedExtra.world.processes = appProcs("com.example.talk", in: true, out: true)
    deniedExtra.run(60)
    check(deniedExtra.callSignals().isEmpty, "an EXTRA_MEETING_APPS app that the person denied is not recorded either")
}

private func testCallDecisions() {
    section("call-apps.json: persistence, permissions, corruption")
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("mcap-callapps-\(getpid())", isDirectory: true)
    try? fm.removeItem(at: dir)
    defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent("sub/call-apps.json")

    let store = CallAppStore(file: file)
    check(store.entries().isEmpty && store.problem == nil && store.allowsCalls && !fm.fileExists(atPath: file.path), "a missing file: no decisions, no problem, nothing is created yet")
    check(store.set("com.example.voicechat", decision: .allowed, name: "Voice Chat", now: epoch), "a decision is saved (the folder is created)")
    check(fm.fileExists(atPath: file.path) && ((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "the file is mode 0600")
    check(!fm.fileExists(atPath: file.path + ".tmp"), "no temp file is left behind")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let top = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    let apps = top?["apps"] as? [String: Any]
    let entry = apps?["com.example.voicechat"] as? [String: Any]
    check(top?["version"] as? Int == 1 && Set(entry?.keys.map { $0 } ?? []) == ["decision", "name", "updated"] && entry?["decision"] as? String == "allowed" && entry?["name"] as? String == "Voice Chat",
          "the file holds version, bundle id, decision, name and time: nothing else (no titles)", text)
    check(!text.lowercased().contains("title") && !text.contains("http"), "no title and no address anywhere in the file")

    store.set("COM.Example.Other", decision: .denied, name: "Other\u{1B}[31m \n App", now: epoch)
    let again = CallAppStore(file: file)
    check(again.entries().map { $0.id } == ["com.example.other", "com.example.voicechat"].sorted { a, b in (again.entries().first { $0.id == a }?.name.lowercased() ?? "", a) < (again.entries().first { $0.id == b }?.name.lowercased() ?? "", b) },
          "a second store reads the same entries back (ids in lower case)", "\(again.entries())")
    check(again.decision(for: "Com.Example.Other") == .denied && again.isDenied("com.example.other") && again.decision(for: "com.example.voicechat") == .allowed && again.decision(for: "com.nobody.x") == nil, "decisions survive a restart, any case")
    check(!(again.entries().first { $0.id == "com.example.other" }?.name ?? "").contains("\n"), "a stored name is one clean line")
    again.noteRecorded("com.example.other", name: "Other")
    again.noteRecorded("com.example.new", name: "New")
    check(again.decision(for: "com.example.other") == .denied && again.decision(for: "com.example.new") == .allowed, "noteRecorded lists a new app as allowed and never changes a decision")
    check(!again.set("not a bundle id", decision: .denied, name: nil) && !again.set("", decision: .denied, name: nil) && !again.set("nodot", decision: .denied, name: nil), "a bad bundle id is refused")
    check(CallAppStore(file: file).entries().count == 3, "the refused ids were not written")

    // an existing file with a wide mode is replaced by a 0600 one
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    again.set("com.example.voicechat", decision: .denied, name: nil)
    check(((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o600 && CallAppStore(file: file).decision(for: "com.example.voicechat") == .denied, "rewriting leaves a 0600 file")

    // corruption: nothing overwrites a file the store cannot read
    let bad = dir.appendingPathComponent("bad/call-apps.json")
    try? fm.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
    let garbage = Data("not json {{{ \u{0}\u{1}".utf8)
    try? garbage.write(to: bad)
    let corrupt = CallAppStore(file: bad)
    check(corrupt.problem != nil && !corrupt.allowsCalls && corrupt.entries().isEmpty, "a corrupt file: a problem is reported, no call of another app is allowed")
    check(!corrupt.set("com.example.a", decision: .denied, name: "A") && (try? Data(contentsOf: bad)) == garbage, "... no decision can be changed and the file is byte for byte as it was")
    let sim = DetectSim(platforms: [.zoom], calls: genericMode, callStore: corrupt)
    sim.world.apps[voiceChatID] = CallAppInfo(name: "Voice Chat", isGUI: true)
    sim.world.processes = appProcs(slackID, in: true, out: true) + [proc(8000, voiceChatID, in: true, out: true)]
    sim.run(120)
    check(sim.callSignals().isEmpty && sim.events.isEmpty, "with a corrupt file nothing of another app is detected: the guessed app AND the known one are paused (their denials are unknown)", "\(sim.callSignals().map { $0.bundleID ?? "?" })")
    try? Data("{\"apps\": {\"com.example.voicechat\": {\"decision\": \"denied\"}}}".utf8).write(to: bad)
    corrupt.reload()
    check(corrupt.problem == nil && corrupt.allowsCalls && corrupt.isDenied(voiceChatID), "fixing the file and reloading brings the decisions back")
    sim.run(60)
    check(sim.callSignal(voiceChatID) == nil && sim.started.first?.bundleID == slackID, "... the app that was denied is still not recorded, and the known app is recorded again")

    for (name, content) in [("empty", ""), ("array", "[1, 2]"), ("apps not an object", "{\"apps\": []}"), ("no apps", "{\"version\": 1}"), ("a string", "\"x\"")] {
        let f = dir.appendingPathComponent("v-\(name.replacingOccurrences(of: " ", with: "-")).json")
        try? Data(content.utf8).write(to: f)
        let st = CallAppStore(file: f)
        check(st.problem != nil && !st.allowsCalls, "an unusable file (\(name)) is a problem, never silently 'no decisions'")
    }
    let mixed = dir.appendingPathComponent("mixed.json")
    try? Data("{\"apps\": {\"com.a.b\": {\"decision\": \"maybe\"}, \"com.c.d\": {\"decision\": \"denied\", \"name\": 5}, \"bad id\": {\"decision\": \"denied\"}, \"com.e.f\": 5, \"com.g.h\": {\"decision\": \"allowed\", \"name\": \"Gee\"}}}".utf8).write(to: mixed)
    let m = CallAppStore(file: mixed)
    check(m.problem == nil && Set(m.entries().map { $0.id }) == ["com.a.b", "com.c.d", "com.e.f", "com.g.h"] && m.skippedEntries == 1 && m.readAsDeniedEntries == 2 && m.entries().first { $0.id == "com.c.d" }?.name == "d",
          "only a key that is not a bundle id is skipped (1); an entry with a decision that is not allowed / denied is read as denied (2); a non-text name falls back to the id", "\(m.entries()) skipped \(m.skippedEntries) denied-by-default \(m.readAsDeniedEntries)")
    check(m.isDenied("com.a.b") && m.isDenied("com.c.d") && m.isDenied("com.e.f") && m.decision(for: "com.g.h") == .allowed, "'maybe', a number and a missing decision are all 'never record'; only 'allowed' allows")

    // fail closed: a mistyped decision is 'denied' (never record), and the next save writes the word that was meant
    let typo = dir.appendingPathComponent("typo.json")
    try? Data("{\"apps\": {\"com.t.one\": {\"decision\": \"Denied\", \"name\": \"One\"}, \"com.t.two\": {\"decision\": \"deny\", \"name\": \"Two\"}, \"com.t.three\": \"denied\", \"com.t.four\": {\"decision\": \" ALLOWED \"}, \"com.t.five\": {}}}".utf8).write(to: typo)
    let t = CallAppStore(file: typo)
    check(t.problem == nil && t.isDenied("com.t.one") && t.isDenied("com.t.two") && t.isDenied("com.t.three") && t.decision(for: "com.t.four") == .allowed && t.isDenied("com.t.five") && t.readAsDeniedEntries == 2,
          "\"Denied\", \"deny\", the shorthand \"com.x\": \"denied\" and an empty entry are denied; ' ALLOWED ' allows; the app that was typed wrongly is NOT recordable", "\(t.entries().map { "\($0.id)=\($0.decision.rawValue)" })")
    check(t.set("com.t.six", decision: .allowed, name: "Six"), "(a decision is saved next to them)")
    let typoText = (try? String(contentsOf: typo, encoding: .utf8)) ?? ""
    let typoApps = ((try? JSONSerialization.jsonObject(with: Data(typoText.utf8))) as? [String: Any])?["apps"] as? [String: Any] ?? [:]
    check(Set(typoApps.keys) == ["com.t.one", "com.t.two", "com.t.three", "com.t.four", "com.t.five", "com.t.six"] && typoApps.values.allSatisfy { ["allowed", "denied"].contains(($0 as? [String: Any])?["decision"] as? String ?? "") }
          && (typoApps["com.t.two"] as? [String: Any])?["decision"] as? String == "denied", "the save keeps every entry and writes 'allowed' or 'denied' for each (the typo is not erased)", typoText)
    let typoSim = DetectSim(platforms: [.zoom], calls: knownMode, callStore: t)
    t.set(slackID, decision: .denied, name: nil)
    typoSim.world.processes = appProcs(slackID, in: true, out: true)
    typoSim.run(60)
    check(typoSim.callSignals().isEmpty, "(and a denied known app is not detected)")
    let caseFile = dir.appendingPathComponent("case.json")
    try? Data("{\"apps\": {\"com.Case.App\": {\"decision\": \"allowed\"}, \"com.case.app\": {\"decision\": \"denied\"}, \"COM.CASE.APP\": {\"decision\": \"allowed\"}}}".utf8).write(to: caseFile)
    check(CallAppStore(file: caseFile).entries().map { "\($0.id)=\($0.decision.rawValue)" } == ["com.case.app=denied"], "keys that differ only in case: one entry, and denied wins (not the dictionary order)")
    var capped = "{\"apps\": {"
    for i in 0..<510 { capped += "\"com.a.allowed\(i)\": {\"decision\": \"allowed\"}," }
    for i in 0..<20 { capped += "\"com.z.denied\(i)\": {\"decision\": \"denied\"}\(i == 19 ? "" : ",")" }
    capped += "}}"
    let cappedFile = dir.appendingPathComponent("capped.json")
    try? Data(capped.utf8).write(to: cappedFile)
    let c = CallAppStore(file: cappedFile)
    check(c.entries().count == CallAppStore.maxEntries && (0..<20).allSatisfy { c.isDenied("com.z.denied\($0)") }, "past 500 entries the denials are kept first: an allowance never pushes a denial out")
    check(CallAppStore.isValidKey("web:whereby") && CallAppStore.isValidKey("web:zoom-web") && !CallAppStore.isValidKey("web:") && !CallAppStore.isValidKey("web:Bad Site") && !CallAppStore.isValidKey("web:a:b") && CallAppStore.isValidKey("com.a.b") && !CallAppStore.isValidKey("nodot"),
          "a meeting page is stored under web:<site> (the browser's own bundle id is never denied)")
    let webStore = CallAppStore(file: nil)
    check(webStore.set("web:Whereby", decision: .denied, name: "Whereby") && webStore.isDenied("web:whereby") && !webStore.set("web:", decision: .denied, name: nil), "a web key is accepted by set (any case), an empty one is refused")

    // an unreadable file: nothing is overwritten, nothing is recorded, the old denials are back once it can be read again
    if getuid() != 0 {
        let locked = dir.appendingPathComponent("locked/call-apps.json")
        try? fm.createDirectory(at: locked.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockedBytes = Data("{\"apps\": {\"com.l.app\": {\"decision\": \"denied\", \"name\": \"L\"}}}".utf8)
        try? lockedBytes.write(to: locked)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let l = CallAppStore(file: locked)
        check(l.problem != nil && !l.allowsCalls && l.entries().isEmpty, "a file that exists but cannot be read (mode 000) is a problem, not 'no decisions'", "\(l.problem ?? "nil")")
        check(!l.set("com.other.app", decision: .denied, name: "Other"), "... no decision can be added")
        let lockedSim = DetectSim(platforms: [.zoom], calls: genericMode, callStore: l)
        lockedSim.world.processes = appProcs("com.l.app", in: true, out: true) + appProcs(slackID, pid: 7100, in: true, out: true)
        lockedSim.run(120)
        check(lockedSim.callSignals().isEmpty && lockedSim.events.isEmpty, "... and the app that is in the file (and denied there) is not recorded, nor is any other call app")
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
        check((try? Data(contentsOf: locked)) == lockedBytes, "the file is byte for byte as it was (the failed set() did not replace it)")
        l.reload()
        check(l.problem == nil && l.isDenied("com.l.app") && l.set("com.other.app", decision: .denied, name: "Other") && CallAppStore(file: locked).isDenied("com.l.app"), "readable again: the denial is back and a decision keeps the old entry in the file")
    }
    // a directory where the file should be
    let asDirectory = dir.appendingPathComponent("isdir/call-apps.json")
    try? fm.createDirectory(at: asDirectory, withIntermediateDirectories: true)
    let dstore = CallAppStore(file: asDirectory)
    var isDir: ObjCBool = false
    check(dstore.problem != nil && !dstore.allowsCalls && !dstore.set("com.d.app", decision: .denied, name: nil) && fm.fileExists(atPath: asDirectory.path, isDirectory: &isDir) && isDir.boolValue,
          "a directory in place of the file is a problem too, and it stays a directory", "\(dstore.problem ?? "nil")")
    // a file that goes bad AFTER the last read is not replaced by the next decision
    let late = dir.appendingPathComponent("late/call-apps.json")
    try? fm.createDirectory(at: late.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("{\"apps\": {\"com.late.app\": {\"decision\": \"denied\"}}}".utf8).write(to: late)
    let lateStore = CallAppStore(file: late)
    let lateGarbage = Data("{ half a file".utf8)
    try? lateGarbage.write(to: late)
    check(!lateStore.set("com.new.app", decision: .denied, name: nil) && (try? Data(contentsOf: late)) == lateGarbage && lateStore.problem != nil, "a file that went bad since the last read is detected by set() and is never overwritten")
    // a failed write: the decision holds across reload() (the menu reloads every time it opens) and is written once the folder allows it
    if getuid() != 0 {
        let ro = dir.appendingPathComponent("ro", isDirectory: true)
        try? fm.createDirectory(at: ro, withIntermediateDirectories: true)
        let roFile = ro.appendingPathComponent("call-apps.json")
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.path)
        let rs = CallAppStore(file: roFile)
        check(rs.set("com.ro.app", decision: .denied, name: "RO") && rs.isDenied("com.ro.app") && !fm.fileExists(atPath: roFile.path), "a folder that cannot be written: the decision holds for this run, nothing is in the file")
        rs.reload()
        check(rs.problem == nil && rs.isDenied("com.ro.app"), "reload() (every menu open) does NOT forget it: the app stays denied", "\(rs.entries())")
        let roSim = DetectSim(platforms: [.zoom], calls: knownMode, callStore: rs)
        rs.set(slackID, decision: .denied, name: "Slack huddle")
        roSim.world.processes = appProcs(slackID, in: true, out: true)
        roSim.run(60)
        rs.reload()
        roSim.run(60)
        check(roSim.callSignals().isEmpty && roSim.events.isEmpty, "a denied known app stays unrecorded across a reload() after a failed write (no 'recorded again' without a log line)")
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.path)
        rs.reload()
        check(fm.fileExists(atPath: roFile.path) && CallAppStore(file: roFile).isDenied("com.ro.app") && CallAppStore(file: roFile).isDenied(slackID), "once the folder can be written the pending decisions are saved at the next read")
    }

    var many = "{\"apps\": {"
    for i in 0..<600 { many += "\"com.e.a\(i)\": {\"decision\": \"denied\"}\(i == 599 ? "" : ",")" }
    many += "}}"
    let big = dir.appendingPathComponent("big.json")
    try? Data(many.utf8).write(to: big)
    let b = CallAppStore(file: big)
    check(b.entries().count == CallAppStore.maxEntries && !b.set("com.new.app", decision: .denied, name: nil) && b.set(b.entries()[0].id, decision: .allowed, name: nil), "600 entries: 500 are kept; a new app is refused, an existing one can still be changed")

    // an unwritable place: the decision holds for this run
    let nowhere = CallAppStore(file: URL(fileURLWithPath: "/dev/null/x/call-apps.json"))
    check(nowhere.set("com.example.a", decision: .denied, name: "A") && nowhere.isDenied("com.example.a"), "a file that cannot be written: the decision still holds until the app quits (and a warning is logged)")
    let memory = CallAppStore(file: nil)
    check(memory.set("com.example.a", decision: .denied, name: "A") && memory.isDenied("com.example.a") && memory.problem == nil, "a store without a file is memory only")
}

private func testCallNoDoubleStart() {
    section("calls: one recording per call, never a second one while one runs")
    let long = DetectSim(platforms: [.zoom], calls: knownMode)
    long.world.processes = appProcs(slackID, in: true, out: true)
    long.run(900)
    check(long.count("start") == 1 && long.count("stop") == 0 && long.rises[.call] == 1, "15 minutes of one call: one start, no stop, one rising edge", "\(long.events)")

    let flick = DetectSim(platforms: [.zoom], calls: knownMode)
    flick.world.processes = appProcs(slackID, in: true, out: true)
    flick.run(30)
    for _ in 0..<30 {
        flick.world.processes = appProcs(slackID)
        flick.run(2)
        flick.world.processes = appProcs(slackID, in: true, out: true)
        flick.run(8)
    }
    check(flick.count("start") == 1 && flick.count("stop") == 0, "single-poll dropouts every 10 s never end or restart the recording", "\(flick.events)")

    let two = DetectSim(platforms: [.zoom], calls: knownMode)
    two.world.processes = appProcs(slackID, in: true, out: true) + appProcs(discordID, pid: 7100, in: true, out: true)
    two.run(120)
    check(two.count("start") == 1 && two.callSignals().count == 2 && two.callSignals().allSatisfy { $0.inCall }, "two apps in a call at once: one recording, both are in a call", "\(two.events)")
    let firstApp = two.started.first?.bundleID
    // the app of the recording leaves; the other one is a different call and starts after the stop (never together)
    two.world.processes = appProcs(firstApp == slackID ? discordID : slackID, pid: 7100, in: true, out: true)
    two.run(120)
    check(two.count("stop") == 1 && two.count("start") == 2 && two.started.last?.bundleID != firstApp, "the session follows ITS app: when it ends the other app's call is a new recording, after the stop", "\(two.events)")

    let generic = DetectSim(platforms: [.zoom], calls: genericMode)
    generic.world.processes = appProcs(slackID, in: true, out: true)
    generic.run(120)
    check(generic.callSignals().count == 1 && generic.callSignal(slackID)?.callKind == .known && generic.count("start") == 1, "known and generic rules never double up on one app")

    // a call platform recording never starts while another platform's recording runs
    let zoomFirst = DetectSim(platforms: [.zoom], calls: knownMode)
    zoomFirst.world.udp[787] = 7
    zoomFirst.world.processes = zoomProcs(inp: true, out: true) + appProcs(slackID, in: true, out: true)
    zoomFirst.run(120)
    check(zoomFirst.count("start") == 1 && zoomFirst.started.first?.platform == .zoom, "a Zoom call and a Slack huddle at once: one recording (Zoom, the one that was seen first)", "\(zoomFirst.events) \(zoomFirst.started.map { $0.platform.rawValue })")

    // ... but a call app that was there first never costs the real meeting: Slack, then Zoom joins (the first Zoom STRONG poll is the join)
    let slackThenZoom = DetectSim(platforms: [.zoom], calls: knownMode)
    slackThenZoom.world.processes = appProcs(slackID, in: true, out: true)
    slackThenZoom.run(120)
    check(slackThenZoom.count("start") == 1 && slackThenZoom.started.first?.platform == .call, "(a Slack huddle is being recorded)")
    slackThenZoom.world.udp[787] = 7
    slackThenZoom.world.processes = zoomProcs(inp: true, out: true) + appProcs(slackID, in: true, out: true)
    slackThenZoom.run(60)
    check(slackThenZoom.count("split") == 1 && slackThenZoom.splitTo.first?.platform == .zoom && slackThenZoom.count("stop") == 0 && slackThenZoom.machine.isRecording,
          "Zoom joins while the huddle is still on: the huddle recording is split to Zoom (no Zoom meeting is lost to a huddle that was left open)", "\(slackThenZoom.events)")
    slackThenZoom.run(600)
    check(slackThenZoom.count("start") == 1 && slackThenZoom.count("split") == 1 && slackThenZoom.count("stop") == 0, "... and the huddle does not start a second recording during the Zoom meeting", "\(slackThenZoom.events)")

    let slackThenTeams = DetectSim(platforms: [.zoom, .teams], calls: knownMode)
    slackThenTeams.world.processes = appProcs(slackID, in: true, out: true)
    slackThenTeams.run(120)
    slackThenTeams.world.processes = teamsProcs(inp: true, out: true) + appProcs(slackID, in: true, out: true)
    slackThenTeams.run(60)
    check(slackThenTeams.count("split") == 1 && slackThenTeams.splitTo.first?.platform == .teams, "Teams joins while a Slack huddle is on: the recording is split to Teams", "\(slackThenTeams.events)")

    let genericThenZoom = DetectSim(platforms: [.zoom], calls: genericMode)
    genericThenZoom.world.apps[voiceChatID] = CallAppInfo(name: "Voice Chat", isGUI: true)
    genericThenZoom.world.processes = [proc(8000, voiceChatID, in: true, out: true)]
    genericThenZoom.run(120)
    check(genericThenZoom.started.first?.callKind == .generic, "(a guessed call is being recorded)")
    genericThenZoom.world.udp[787] = 7
    genericThenZoom.world.processes = zoomProcs(inp: true, out: true) + [proc(8000, voiceChatID, in: true, out: true)]
    genericThenZoom.run(60)
    check(genericThenZoom.count("split") == 1 && genericThenZoom.splitTo.first?.platform == .zoom, "a false positive of the generic rule cannot hold back a real Zoom meeting either", "\(genericThenZoom.events)")

    let flickerOnly = DetectSim(platforms: [.zoom], weakDebounce: 15, calls: knownMode)
    flickerOnly.world.processes = appProcs(slackID, in: true, out: true)
    flickerOnly.run(120)
    flickerOnly.world.udp[787] = 4
    flickerOnly.world.processes = zoomProcs() + appProcs(slackID, in: true, out: true)
    flickerOnly.run(10)
    flickerOnly.world.udp[787] = nil
    flickerOnly.world.processes = appProcs(slackID, in: true, out: true)
    flickerOnly.run(120)
    check(flickerOnly.count("split") == 0 && flickerOnly.count("stop") == 0 && flickerOnly.count("start") == 1, "the idle Zoom flicker (4 sockets, no audio) during a huddle changes nothing", "\(flickerOnly.events)")
}

private func testCallModes() {
    section("CALL_DETECT off / known / generic")
    func world(_ sim: DetectSim) {
        sim.world.apps[voiceChatID] = CallAppInfo(name: "Voice Chat", isGUI: true)
        sim.world.processes = appProcs(slackID, in: true, out: true) + [proc(8000, voiceChatID, in: true, out: true)]
    }
    let off = DetectSim(platforms: [.zoom, .teams], calls: .off)
    world(off)
    off.run(120)
    check(off.events.isEmpty && off.lastSnapshot?.signals.map { $0.platform } == [.zoom, .teams] && off.detector.lastDiagnostics()?.callApps.isEmpty == true, "off: nothing beyond the three platforms, the snapshot has no call signal")
    let known = DetectSim(platforms: [.zoom, .teams], calls: knownMode)
    world(known)
    known.run(120)
    check(known.count("start") == 1 && known.callSignals().map { $0.bundleID } == [slackID] && known.lastSnapshot?.signals.map { $0.platform } == [.zoom, .teams, .call], "known: only the app of the table; call signals come after the platforms")
    let generic = DetectSim(platforms: [.zoom, .teams], calls: genericMode)
    world(generic)
    generic.run(120)
    check(generic.callSignals().count == 2 && generic.started.first?.bundleID == slackID, "generic: both apps are tracked; the known app (high confidence) is the one that starts first", "\(generic.callSignals().count)")
    check(generic.detector.lastDiagnostics()?.callApps.map { $0.id }.sorted() == [slackID, voiceChatID].sorted() && generic.detector.lastDiagnostics()?.callApps.allSatisfy { $0.active } == true, "diagnostics list the tracked apps")

    let none = DetectSim(platforms: [], calls: genericMode)
    world(none)
    none.run(120)
    check(none.lastSnapshot?.signals.isEmpty == true && none.events.isEmpty, "an empty ENABLED_PLATFORMS switches the call rule off too (manual recording only)")
    let noMeet = DetectSim(platforms: [.zoom, .teams], calls: genericMode)
    noMeet.world.processes = chromeProcs(inp: true, out: true)
    noMeet.run(60)
    check(noMeet.world.backend.totalCalls == 0 && noMeet.events.isEmpty, "the call rule without browser addresses never touches Chrome")
    let zoomStill = DetectSim(platforms: [.zoom, .teams], calls: genericMode)
    zoomStill.world.udp[787] = 7
    zoomStill.world.processes = zoomProcs(inp: true, out: true)
    zoomStill.run(40)
    check(zoomStill.count("start") == 1 && zoomStill.started.first?.platform == .zoom && zoomStill.callSignals().isEmpty, "Zoom is still Zoom (never a generic call), the call rule leaves it alone")
}

private func testCallMeetExclusion() {
    section("Google Meet stays behind `meet`: no call rule records it")
    let urls = DetectSim(platforms: [.zoom, .teams], calls: CallDetectSettings(mode: .generic, browserURLs: true))
    urls.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
    urls.world.processes = chromeProcs(inp: true, out: true)
    urls.run(180)
    check(urls.events.isEmpty && urls.callSignals().isEmpty && urls.signal(.meet) == nil, "Meet disabled, browser addresses ON, a Meet tab and Chrome in + out for 3 minutes: nothing is recorded", "\(urls.events)")
    check(urls.detector.lastDiagnostics()?.tabs == nil, "... and the Meet section of the diagnostics stays absent")

    let backend = FakeChromeBackend()
    backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Secret planning", active: true), tab("https://whereby.com/my-room", title: "Room title", active: true), tab("https://mail.google.com/", title: "Inbox")])
    let tabs = ChromeTabs(policy: TabQueryPolicy(enabled: true, reason: "selftest"), browserBundleIDs: ["com.google.Chrome"], backend: backend, keepMeetTabs: false, matchWebMeetings: true)
    let info = tabs.info(audioActive: true, now: epoch)
    check(info.status.isOK && info.meetHostTabs.isEmpty && info.webTabs.map { $0.siteID } == ["whereby"] && info.totalTabs == 3, "a Chrome read for the web table keeps the Whereby tab and drops the Meet tab at once", "\(info.meetHostTabs.count) \(info.webTabs)")
    let encoded = String(data: (try? JSONEncoder().encode(info.webTabs)) ?? Data(), encoding: .utf8) ?? ""
    check(!encoded.contains("my-room") && !encoded.contains("Room title") && !encoded.contains("http"), "a web meeting tab keeps the site and the tab identity only: no address, no room name, no title", encoded)
    let off = ChromeTabs(policy: TabQueryPolicy(enabled: true, reason: "selftest"), browserBundleIDs: ["com.google.Chrome"], backend: backend, keepMeetTabs: false, matchWebMeetings: false)
    let offInfo = off.info(audioActive: true, now: epoch)
    check(offInfo.meetHostTabs.isEmpty && offInfo.webTabs.isEmpty, "with both off a tab read keeps nothing about any tab")

    for id in ["com.google.Chrome.helper", "com.google.Chrome.app.abcdef", "com.apple.Safari", "com.apple.WebKit.WebContent", "org.mozilla.firefox", "company.thebrowser.Browser.helper", "com.microsoft.edgemac.helper"] {
        let sim = DetectSim(platforms: [.zoom], calls: genericMode)
        sim.world.processes = [proc(5000, id, in: true, out: true)]
        sim.run(180)
        check(sim.callSignals().isEmpty && sim.events.isEmpty, "generic: \(id) holding the microphone and output is a browser, never a call")
    }
    // the production wiring (DetectorInputs.live) with fake Chrome: the web table reads tabs only when CALL_BROWSER_URLS asks for it
    let policy = TabQueryPolicy(enabled: true, reason: "selftest")
    let defaults = AppConfig.defaults()
    let liveWeb = FakeChromeBackend()
    liveWeb.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true), tab("https://meet.jit.si/standup", title: "Jitsi")])
    let withUrls = DetectorInputs.live(config: defaults, policy: policy, backend: liveWeb, calls: CallDetectSettings(mode: .known, browserURLs: true))
    let webInfo = withUrls.tabs(true, epoch, 4)
    check(webInfo.status.isOK && webInfo.meetHostTabs.isEmpty && webInfo.webTabs.map { $0.siteID } == ["jitsi"] && liveWeb.listCalls == 1,
          "DetectorInputs.live with CALL_BROWSER_URLS on and Meet off: the Jitsi tab is kept, the Meet tab is dropped at once", "\(webInfo.status) \(webInfo.meetHostTabs.count) \(webInfo.webTabs)")
    for (label, calls, platforms) in [("CALL_BROWSER_URLS off", knownMode, defaults.enabledPlatforms), ("CALL_DETECT=off", CallDetectSettings(mode: .off, browserURLs: true), defaults.enabledPlatforms),
                                      ("an empty ENABLED_PLATFORMS", CallDetectSettings(mode: .generic, browserURLs: true), [])] {
        var cfg = defaults
        cfg.enabledPlatforms = platforms
        let backend = FakeChromeBackend()
        let live = DetectorInputs.live(config: cfg, policy: policy, alwaysQueryTabs: true, backend: backend, calls: calls)
        check(live.tabs(true, epoch, 4).status == .disabled(Detector.meetDisabledReason) && backend.totalCalls == 0, "DetectorInputs.live with \(label): Chrome is never asked for anything, not even with --tabs-always")
    }
    let realRead = DetectorInputs.live(config: defaults, policy: policy, backend: FakeChromeBackend(), calls: genericMode)
    let nothing = realRead.callProcesses({ _ in false }, false)
    let scanned = realRead.callProcesses({ _ in false }, true)
    check(nothing.isEmpty && scanned.allSatisfy { $0.isRunningInput }, "the live call read (real Core Audio, read-only): without the scan nothing, with it only processes that hold the microphone", "\(scanned.map { $0.bundleID })")
    check(CallApps.known.allSatisfy { realRead.callAppInfo($0.id) == nil || realRead.callAppInfo($0.id)?.name.isEmpty == false }, "the live app info (NSRunningApplication): an app that is not running is nil, a running one has a name")
    check(WebMeetingURL.classify("https://meet.google.com/abc-defg-hij") == nil && WebMeetingURL.classify("https://meet.google.com.evil.com/x") == nil && WebMeetingURL.classify("https://meet.google.com/lookup/abc") == nil,
          "the web meeting table does not know Google Meet")
    check(ExtraMeetingApps.parse("com.google.Chrome").apps.isEmpty && ExtraMeetingApps.parse("com.google.Chrome.app.x").apps.isEmpty, "Chrome cannot be added as an extra app")

    // with `meet` enabled explicitly Meet is exactly what it was, next to a web meeting
    let both = DetectSim(platforms: [.meet, .zoom, .teams], calls: CallDetectSettings(mode: .known, browserURLs: true))
    both.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true), tab("https://meet.jit.si/standup", title: "Jitsi")])
    both.world.processes = chromeProcs(inp: true, out: true)
    both.run(60)
    check(both.signal(.meet)?.meetingKey == "abc-defg-hij" && both.signal(.meet)?.inCall == true && both.callSignal("com.google.Chrome")?.appName == "Jitsi Meet", "meet enabled + browser addresses on: the Meet tab and the Jitsi tab are both seen (Meet unchanged)", "\(both.callSignals().map { $0.appName ?? "?" })")
    check(both.count("start") == 1, "... and only one recording starts")
}

private func testWebMeetingURLs() {
    section("browser meeting pages: the URL table")
    func site(_ url: String) -> String? { WebMeetingURL.classify(url)?.siteID }
    let yes: [(String, String)] = [
        ("https://acme.webex.com/meet/jane.doe", "webex"), ("https://acme.webex.com/acme/j.php?MTID=m123", "webex"), ("https://webex.com/wbxmjs/joinservice/sites/acme/meeting/download/abc", "webex"),
        ("https://acme.webex.com/webappng/sites/acme/meeting/info/123", "webex"), ("https://whereby.com/my-room", "whereby"), ("https://acme.whereby.com/team-standup?minimal", "whereby"),
        ("https://meet.jit.si/StandupRoom", "jitsi"), ("https://meet.jit.si/StandupRoom#config.startWithVideoMuted=true", "jitsi"),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=%7b%7d", "teams-web"), ("https://teams.microsoft.com/dl/launcher/launcher.html?url=%2f_%23%2fl%2fmeetup-join", "teams-web"),
        ("https://teams.live.com/meet/9876543210", "teams-web"), ("https://teams.microsoft.com/v2/?meetingjoin=true", "teams-web"), ("https://teams.cloud.microsoft/l/meetup-join/x", "teams-web"),
        ("https://zoom.us/wc/123456789/join", "zoom-web"), ("https://app.zoom.us/wc/123456789/start?pwd=x", "zoom-web"), ("https://acme.zoom.com/wc/join/123456789", "zoom-web"),
        ("  https://WHEREBY.com/Room  ", "whereby"),
    ]
    for (url, want) in yes { check(site(url) == want, "\(url) -> \(want)", "\(String(describing: site(url)))") }
    let no = ["https://meet.google.com/abc-defg-hij", "http://whereby.com/my-room", "https://whereby.com/", "https://whereby.com/pricing", "https://www.whereby.com/room", "https://whereby.com.evil.com/room",
              "https://evilwhereby.com/room", "https://webex.com/", "https://acme.webex.com/", "https://acme.webex.com/meet", "https://acme.webex.com/mc/something", "https://meet.jit.si/", "https://meet.jit.si/static/x.js",
              "https://jit.si/room", "https://teams.microsoft.com/", "https://teams.microsoft.com/v2/", "https://teams.microsoft.com/v2/?meetingjoin=false", "https://teams.microsoft.com.evil.com/l/meetup-join/x",
              "https://zoom.us/j/123456789", "https://zoom.us/", "https://zoom.us/profile", "https://evilzoom.us/wc/1/join", "https://zoom.us.evil.com/wc/1/join", "ftp://zoom.us/wc/1/join", "", "not a url", "https://",
              "https://teams.live.com/", "https://example.com/meet/room", String(repeating: "https://whereby.com/a", count: 400)]
    for url in no { check(site(url) == nil, "no match: \(url.count > 60 ? String(url.prefix(40)) + "..." : url)") }
    check(WebMeetingURL.sites.map { $0.siteID } == ["webex", "whereby", "jitsi", "teams-web", "zoom-web"] && Set(WebMeetingURL.sites.map { $0.name }).count == 5 && WebMeetingURL.sites.allSatisfy { $0.name.count <= CallApps.maxNameLength },
          "five sites with distinct short names")
}

private func testWebMeetingPipeline() {
    section("browser meeting pages: through the detector (Chrome tabs, never Google Meet)")
    let web = CallDetectSettings(mode: .known, browserURLs: true)
    func whereby() -> DetectSim {
        let sim = DetectSim(platforms: [.zoom, .teams], calls: web)
        sim.world.backend.result = .ok([tab("https://mail.google.com/mail/u/0", title: "Inbox"), tab("https://whereby.com/my-private-room?x=1", title: "My private room", active: true)])
        return sim
    }
    let idle = whereby()
    idle.world.processes = chromeProcs()
    idle.run(60)
    check(idle.events.isEmpty && idle.world.backend.totalCalls == 0, "Chrome without audio IO: no start and Chrome is not touched (0 backend calls)")
    idle.world.processes = chromeProcs(inp: true, out: true)
    let t0 = idle.t
    idle.run(40)
    let s = idle.callSignal("com.google.Chrome")
    let start = idle.first("start")
    check(start != nil && (start ?? 0) - t0 >= 8 && (start ?? 0) - t0 <= 24, "a Whereby tab + Chrome microphone + output start a call", "start \(String(describing: start)) t0 \(t0); \(idle.events)")
    check(s?.callKind == .web && s?.appName == "Whereby" && s?.meetingKey == "web:whereby" && s?.bundleID == "com.google.Chrome" && s?.titleHint == nil && s?.meetingURL == nil && s?.confidence == .high,
          "the signal: web, 'Whereby', key web:whereby, the browser's id, no title and no address", "\(String(describing: s))")
    check(!(s?.evidence.joined(separator: " ") ?? "").contains("my-private-room") && !(s?.evidence.joined(separator: " ") ?? "").contains("private room"), "the evidence never carries the room name or the title")
    check(idle.world.backend.listCalls >= 1 && idle.world.backend.listCalls <= 8, "the tab list is read only while Chrome has audio IO", "\(idle.world.backend.listCalls)")
    idle.run(300)
    check(idle.count("start") == 1 && idle.count("stop") == 0, "an established web call stays one recording", "\(idle.events)")

    // the tab closes: the call ends after the grace
    idle.world.backend.result = .ok([tab("https://mail.google.com/mail/u/0", title: "Inbox", active: true)])
    let closedAt = idle.t
    idle.run(120)
    check(idle.count("stop") == 1 && (idle.first("stop") ?? 0) - closedAt >= 30, "closing the tab ends the call after the 30 s grace even while Chrome keeps playing", "closed \(closedAt) \(idle.events)")

    // the tab list fails mid-call: nothing ends
    let flaky = whereby()
    flaky.world.processes = chromeProcs(inp: true, out: true)
    flaky.run(40)
    flaky.world.backend.result = .error(-1712, "AppleEvent timed out")
    flaky.run(5)
    flaky.world.backend.automation = .denied
    flaky.run(240)
    check(flaky.count("start") == 1 && flaky.count("stop") == 0, "the tab list failing or the permission going away mid-call never ends it", "\(flaky.events)")

    // media: output only, or a tab list without the page
    let media = whereby()
    media.world.processes = chromeProcs(inp: false, out: true)
    media.run(180)
    check(media.events.isEmpty, "a Whereby tab and Chrome playing sound only (YouTube) is not a call")
    let noTab = whereby()
    noTab.world.backend.result = .ok([tab("https://www.youtube.com/watch?v=x", title: "video")])
    noTab.world.processes = chromeProcs(inp: true, out: true)
    noTab.run(180)
    check(noTab.events.isEmpty && noTab.callSignals().isEmpty, "microphone + output in Chrome with no meeting page is nothing (voice typing, a video)")

    // permissions
    let denied = whereby()
    denied.world.backend.automation = .denied
    denied.world.processes = chromeProcs(inp: true, out: true)
    denied.run(180)
    check(denied.events.isEmpty && denied.world.backend.listCalls == 0, "Automation denied: no start, no LOW fallback (Chrome audio alone is never a call here), the script never runs")
    let notAsked = whereby()
    notAsked.world.backend.automation = .notAsked
    notAsked.world.processes = chromeProcs(inp: true, out: true)
    notAsked.run(120)
    check(notAsked.events.isEmpty && notAsked.world.backend.listCalls == 0, "Automation not asked yet: nothing starts and no prompt is raised")
    let closed = whereby()
    closed.world.backend.running = false
    closed.world.processes = chromeProcs(inp: true, out: true)
    closed.run(60)
    check(closed.events.isEmpty && closed.world.backend.listCalls == 0, "Chrome not running: no script")
    let shell = DetectSim(platforms: [.zoom, .teams], policy: TabQueryPolicy(enabled: false, reason: "shell"), calls: web)
    shell.world.processes = chromeProcs(inp: true, out: true)
    shell.run(120)
    check(shell.events.isEmpty && shell.world.backend.totalCalls == 0, "tab queries disabled (a shell, a self test): Chrome is never touched")

    // the switch: browser addresses off is the default and touches nothing
    let off = DetectSim(platforms: [.zoom, .teams], calls: knownMode)
    off.world.backend.result = .ok([tab("https://whereby.com/room", active: true)])
    off.world.processes = chromeProcs(inp: true, out: true)
    off.run(180)
    check(off.events.isEmpty && off.world.backend.totalCalls == 0, "CALL_BROWSER_URLS off (default): the same world records nothing and Chrome is never asked for anything")

    // several sites
    let sites = DetectSim(platforms: [.zoom, .teams], calls: web)
    sites.world.backend.result = .ok([tab("https://whereby.com/room-a", active: true), tab("https://meet.jit.si/room-b", id: "t2", window: "2", order: 1)])
    sites.world.processes = chromeProcs(inp: true, out: true)
    sites.run(60)
    check(Set(sites.callSignals().compactMap { $0.appName }) == ["Whereby", "Jitsi Meet"] && sites.count("start") == 1, "two meeting tabs: two signals, one recording")

    // known app + web page at once: still one recording
    let mixed = whereby()
    mixed.world.processes = chromeProcs(inp: true, out: true) + appProcs(slackID, in: true, out: true)
    mixed.run(60)
    check(mixed.count("start") == 1 && mixed.callSignals().count == 2, "a Slack huddle and a Whereby tab: both seen, one recording")

    // the Teams web launcher page next to the native Teams: separate platforms
    let teamsWeb = DetectSim(platforms: [.zoom, .teams], calls: web)
    teamsWeb.world.backend.result = .ok([tab("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0", title: "Teams", active: true)])
    teamsWeb.world.processes = chromeProcs(inp: true, out: true)
    teamsWeb.run(60)
    check(teamsWeb.started.first?.appName == "Teams (web)" && teamsWeb.signal(.teams)?.inCall == false, "Teams in a browser is a `call` named 'Teams (web)'; the native Teams detector is not involved")

    // 'Never record' for a meeting page is kept per site (web:<site>); the browser's own bundle id is never denied
    let denyStore = CallAppStore(file: nil)
    denyStore.set("web:whereby", decision: .denied, name: "Whereby")
    let siteDenied = DetectSim(platforms: [.zoom, .teams], calls: web, callStore: denyStore)
    siteDenied.world.backend.result = .ok([tab("https://whereby.com/my-private-room", title: "Room", active: true), tab("https://meet.jit.si/SomeRoom", title: "Jitsi")])
    siteDenied.world.processes = chromeProcs(inp: true, out: true)
    siteDenied.run(120)
    check(siteDenied.callSignals().map { $0.meetingKey ?? "" } == ["web:jitsi"] && siteDenied.started.first?.meetingKey == "web:jitsi", "a denied site is not recorded; the other sites, and Chrome itself, still are", "\(siteDenied.callSignals().map { $0.meetingKey ?? "?" })")
    denyStore.set("web:whereby", decision: .allowed, name: nil)
    denyStore.set("web:jitsi", decision: .denied, name: nil)
    siteDenied.world.processes = []
    siteDenied.run(60)
    siteDenied.world.processes = chromeProcs(inp: true, out: true)
    siteDenied.run(120)
    check(siteDenied.callSignals().contains { $0.meetingKey == "web:whereby" } && !siteDenied.callSignals().contains { $0.meetingKey == "web:jitsi" }, "allowing a site again brings it back", "\(siteDenied.callSignals().map { $0.meetingKey ?? "?" })")
    let browserDenied = CallAppStore(file: nil)
    browserDenied.set("com.google.Chrome", decision: .denied, name: "Chrome")
    let chromeSim = DetectSim(platforms: [.zoom, .teams], calls: web, callStore: browserDenied)
    chromeSim.world.backend.result = .ok([tab("https://whereby.com/my-private-room", title: "Room", active: true)])
    chromeSim.world.processes = chromeProcs(inp: true, out: true)
    chromeSim.run(60)
    check(chromeSim.count("start") == 1, "a denial stored under the browser's own bundle id does not touch meeting pages (the site key web:<site> does)")
}

private func testCallStateMachine() {
    section("state machine: calls of other apps")
    let startup = MachineRun()
    startup.run(10, [callSig("com.a.app")])
    check(startup.first("start") == 5 && startup.started?.bundleID == "com.a.app", "a call signal starts after the start debounce like any platform", "\(startup.events)")
    let leave = MachineRun(grace: 20)
    leave.run(10, [callSig("com.a.app")])
    let at = leave.t
    leave.run(60, [callSig("com.a.app", false)])
    check((leave.first("stop") ?? 0) - at >= 30 && (leave.first("stop") ?? 0) - at <= 33, "its grace is at least 30 s (breakouts and reconnects rebuild media)", "left \(at) \(leave.events)")
    let longGrace = MachineRun(grace: 60)
    longGrace.run(10, [callSig("com.a.app")])
    let at2 = longGrace.t
    longGrace.run(120, [callSig("com.a.app", false)])
    check((longGrace.first("stop") ?? 0) - at2 >= 60 && (longGrace.first("stop") ?? 0) - at2 <= 63, "a configured grace above 30 s is kept")
    check(DetectionStateMachine(startDebounce: 4, grace: 20).effectiveGrace(for: .call) == 30 && DetectionStateMachine(startDebounce: 4, grace: 20).effectiveGrace(for: .meet) == 20, "effectiveGrace: call 30, meet 20")

    // one session follows its own app
    let own = MachineRun()
    own.run(10, [callSig("com.a.app"), callSig("com.b.app", false)])
    check(own.count("start") == 1 && own.started?.bundleID == "com.a.app", "A starts the session")
    own.run(20, [callSig("com.a.app", false), callSig("com.b.app")])
    own.run(10, [callSig("com.a.app"), callSig("com.b.app")])
    check(own.count("stop") == 0, "B's call does not end A's session during A's grace, and A coming back keeps it", "\(own.events)")
    own.run(40, [callSig("com.a.app", false), callSig("com.b.app")])
    check(own.count("stop") == 1, "B's call does not keep A's session alive: it ends after A's grace", "\(own.events)")
    own.run(10, [callSig("com.a.app", false), callSig("com.b.app")])
    check(own.count("start") == 2 && own.started?.bundleID == "com.b.app", "B, still in its call, is a new recording after the stop")

    let switchCandidate = MachineRun()
    switchCandidate.run(2, [callSig("com.a.app"), callSig("com.b.app", false)])
    switchCandidate.run(8, [callSig("com.a.app", false), callSig("com.b.app")])
    check(switchCandidate.first("start") == 7 && switchCandidate.started?.bundleID == "com.b.app", "a candidate for A does not carry over to B: B waits its own debounce", "\(switchCandidate.events)")

    let preferred = MachineRun()
    preferred.run(10, [callSig("com.g.app", kind: .generic, conf: .low), callSig("com.k.app")])
    check(preferred.started?.bundleID == "com.k.app", "with a known and a generic app in a call the known one (high confidence) is recorded")
    var weakText = callSig("com.a.app")
    weakText.evidence = ["tier=weak (sockets=4<6)"]
    check(weakText.evidenceTier == .strong, "a call signal is always STRONG evidence (the Zoom weak tier does not exist for it)")

    // A call of another app never blocks Zoom, Teams or Meet: a STRONG, high-confidence meeting that lasts the start debounce takes the call recording over.
    let zoomOn = zoomSig(sockets: 7)
    let pre = MachineRun()
    pre.run(30, [callSig("com.a.app")])
    check(pre.count("start") == 1 && pre.machine.isRecording, "(a call app recording is running)")
    pre.run(3, [callSig("com.a.app"), zoomOn])
    check(pre.count("split") == 0, "a Zoom meeting that has lasted less than the start debounce does not take the call over yet", "\(pre.events)")
    pre.run(3, [callSig("com.a.app"), zoomOn])
    check(pre.count("split") == 1 && pre.count("stop") == 0 && pre.machine.isRecording, "after the start debounce the call recording is split to Zoom: one split, no stop, the machine keeps recording", "\(pre.events)")
    pre.run(120, [callSig("com.a.app"), zoomOn])
    check(pre.count("split") == 1 && pre.count("start") == 1 && pre.count("stop") == 0, "... the call app that is still in its call neither starts nor ends anything during the Zoom meeting", "\(pre.events)")
    pre.run(40, [callSig("com.a.app"), zoomSig(sockets: 0)])
    check(pre.count("stop") == 1, "the Zoom meeting ends after its grace like any other session", "\(pre.events)")
    pre.run(10, [callSig("com.a.app"), zoomSig(sockets: 0)])
    check(pre.count("start") == 2 && pre.started?.bundleID == "com.a.app", "the call app, still in its call, is a new recording after the Zoom meeting")

    let teamsOver = MachineRun()
    teamsOver.run(20, [callSig("com.a.app", kind: .generic, conf: .low)])
    teamsOver.run(8, [callSig("com.a.app", kind: .generic, conf: .low), sig(.teams)])
    check(teamsOver.count("start") == 1 && teamsOver.count("split") == 1 && teamsOver.count("stop") == 0, "a Teams call takes a generic call recording over", "\(teamsOver.events)")
    let meetOver = MachineRun()
    meetOver.run(20, [callSig("web:whereby", kind: .web)])
    meetOver.run(8, [callSig("web:whereby", kind: .web), sig(.meet, key: "abc-defg-hij")])
    check(meetOver.count("split") == 1, "a Google Meet call (high confidence) takes a web call recording over", "\(meetOver.events)")
    let meetLow = MachineRun()
    meetLow.run(20, [callSig("com.a.app")])
    meetLow.run(60, [callSig("com.a.app"), sig(.meet, key: "abc-defg-hij", conf: .low)])
    check(meetLow.count("split") == 0, "a LOW confidence Meet signal never takes a call recording over", "\(meetLow.events)")

    let flicker = MachineRun()
    flicker.run(20, [callSig("com.a.app")])
    flicker.run(2, [callSig("com.a.app"), zoomOn])
    flicker.run(1, [callSig("com.a.app")])
    flicker.run(1, [callSig("com.a.app"), zoomOn])
    check(flicker.count("split") == 0, "a one second gap (inside the flicker tolerance) in the Zoom signal: the debounce has not passed yet", "\(flicker.events)")
    flicker.run(1, [callSig("com.a.app"), zoomOn])
    check(flicker.count("split") == 1, "... and the gap did not restart it: the take-over comes one start debounce after the FIRST Zoom poll", "\(flicker.events)")
    let gap = MachineRun()
    gap.run(20, [callSig("com.a.app")])
    gap.run(3, [callSig("com.a.app"), zoomOn])
    gap.run(6, [callSig("com.a.app")])
    gap.run(3, [callSig("com.a.app"), zoomOn])
    check(gap.count("split") == 0, "a gap longer than the flicker tolerance starts the debounce again", "\(gap.events)")

    let weakZoom = MachineRun(weakDebounce: 15)
    weakZoom.run(20, [callSig("com.a.app")])
    weakZoom.run(12, [callSig("com.a.app"), zoomSig(sockets: 4)])
    check(weakZoom.count("split") == 0 && weakZoom.count("stop") == 0, "the idle Zoom flicker (WEAK evidence) never takes a call over", "\(weakZoom.events)")
    let strongWithTiers = MachineRun(weakDebounce: 15)
    strongWithTiers.run(20, [callSig("com.a.app")])
    strongWithTiers.run(8, [callSig("com.a.app"), zoomSig(sockets: 7)])
    check(strongWithTiers.count("split") == 1, "a STRONG Zoom does (the weak tier is on)", "\(strongWithTiers.events)")

    let zoomFirst = MachineRun()
    zoomFirst.run(20, [zoomOn])
    zoomFirst.run(60, [zoomOn, callSig("com.a.app")])
    check(zoomFirst.count("start") == 1 && zoomFirst.count("split") == 0 && zoomFirst.started?.platform == .zoom, "the other way round nothing is preempted: a call app never takes a Zoom recording over", "\(zoomFirst.events)")
    let manual = MachineRun()
    manual.machine.adoptManualRecording()
    manual.run(30, [zoomOn, callSig("com.a.app")])
    check(manual.events.isEmpty, "a manual recording is never taken over")
    let reset = MachineRun()
    reset.run(20, [callSig("com.a.app")])
    reset.run(3, [callSig("com.a.app"), zoomOn])
    reset.machine.reset()
    reset.run(2, [callSig("com.a.app"), zoomOn])
    check(reset.count("split") == 0, "reset() forgets a pending take-over")
}

private func testCallMonitorAndCompat() {
    section("audio monitor read for calls; old sessions and old data")
    var identities: [AudioObjectID: (pid: pid_t, bundleID: String)] = [1: (100, "com.example.a"), 2: (101, "com.example.b"), 3: (102, slackID), 4: (103, ""), 5: (104, "com.example.c")]
    let flagsByObject: [AudioObjectID: (input: Bool, output: Bool)] = [1: (true, true), 2: (false, true), 3: (false, false), 4: (true, true), 5: (true, false)]
    let monitor = AudioProcessMonitor(source: AudioProcessMonitor.Source(list: { [1, 2, 3, 4, 5] }, identity: { identities[$0] }, flags: { flagsByObject[$0] ?? (false, false) }))
    let withScan = monitor.pollCalls(interesting: { $0 == slackID }, scanOthers: true).map { $0.pid }.sorted()
    check(withScan == [100, 102, 104], "pollCalls: the interesting app (idle) and every other process with the microphone running; no output-only process, no empty id", "\(withScan)")
    let noScan = monitor.pollCalls(interesting: { $0 == slackID }, scanOthers: false).map { $0.pid }
    check(noScan == [102], "pollCalls without the scan: only the interesting processes")
    let flags = monitor.pollCalls(interesting: { _ in false }, scanOthers: true)
    check(flags.first { $0.pid == 100 }?.isRunningOutput == true && flags.first { $0.pid == 104 }?.isRunningOutput == false, "a scanned process carries both flags")
    identities[6] = (105, "com.example.d")
    check(monitor.poll(interesting: { $0 == "com.example.a" }).count == 1, "poll() is unchanged")

    // the gate of the scan: the real devices of this Mac, read-only (no stream is opened, nothing prompts)
    let gate = InputActivityGate(refreshSeconds: 0.05)
    let gateStart = Date()
    let first = gate.anyInputRunning(now: gateStart)
    check(gate.inputDeviceCount >= 0 && Date().timeIntervalSince(gateStart) < 2 && first == gate.anyInputRunning(now: gateStart.addingTimeInterval(0.01)),
          "InputActivityGate: reads the input devices of this Mac (\(gate.inputDeviceCount)) and says whether one runs (\(first)); the second poll uses the cached list")
    let backwards = gate.anyInputRunning(now: gateStart.addingTimeInterval(-100))
    check(backwards == gate.anyInputRunning(now: gateStart.addingTimeInterval(-99.99)), "InputActivityGate: a clock that moves back refreshes the list and keeps answering")

    // compatibility
    check(Platform(rawValue: "meet") == .meet && Platform(rawValue: "zoom") == .zoom && Platform(rawValue: "teams") == .teams && Platform(rawValue: "manual") == .manual && Platform(rawValue: "call") == .call && Platform(rawValue: "slack") == nil,
          "platform raw values: the old four unchanged, `call` added")
    check(Platform.allCases.map { $0.rawValue } == ["meet", "zoom", "teams", "manual", "call"] && Platform.call.label == "Call", "the call platform is a pure addition")
    let old = Data("{\"platform\":\"zoom\",\"inCall\":true,\"confidence\":\"high\",\"evidence\":[\"x\"],\"bundleID\":\"us.zoom.xos\"}".utf8)
    let decoded = try? JSONDecoder().decode(PlatformSignal.self, from: old)
    check(decoded?.platform == .zoom && decoded?.appName == nil && decoded?.callKind == nil && decoded?.displayLabel == "Zoom", "a signal written before the call platform still decodes (no app name, no kind)")
    var named = callSig("com.a.app")
    named.appName = "Slack huddle"
    let round = (try? JSONEncoder().encode(named)).flatMap { try? JSONDecoder().decode(PlatformSignal.self, from: $0) }
    check(round?.appName == "Slack huddle" && round?.callKind == .known && round?.displayLabel == "Slack huddle", "a call signal survives a JSON round trip")
    check(PlatformSignal(platform: .meet, inCall: true, appName: "ignored").displayLabel == "Google Meet", "only a call takes its label from the app name")

    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("mcap-callcompat-\(getpid())", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    defer { try? FileManager.default.removeItem(at: root) }
    func session(_ name: String, _ json: String) -> URL {
        let d = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: d.appendingPathComponent("session.json"))
        return d
    }
    let times = "\"start_time\":\"2026-10-07T14:00:00+09:00\",\"end_time\":\"2026-10-07T14:10:00+09:00\""
    check(PipelineFacts.recording(in: session("old-zoom", "{\"schema\":1,\"platform\":\"zoom\",\"platform_label\":\"Zoom\",\(times)}"))?.platform == .zoom, "an old session.json (zoom) reads as before")
    let call = PipelineFacts.recording(in: session("new-call", "{\"schema\":1,\"platform\":\"call\",\"platform_label\":\"Slack huddle\",\"app_name\":\"Slack huddle\",\"call_kind\":\"known\",\"app_bundle_id\":\"\(slackID)\",\(times)}"))
    check(call?.platform == .call && call?.durationSeconds == 600, "a call session.json reads as platform call with its length")
    check(PipelineFacts.recording(in: session("future", "{\"schema\":1,\"platform\":\"somethingnew\",\(times)}"))?.platform == nil, "an unknown platform value reads as nil, never as a crash")
    check(PipelineFacts.recording(in: session("junk", "not json")) == nil, "an unreadable session.json reads as nothing")
    check(NotificationText.contentFreeSession("2026-10-07_1400_call") == "2026-10-07_1400_call" && NotificationText.contentFreeSession("2026-10-07_1400_slack-huddle") == "2026-10-07_1400",
          "a staging id of a call is content-free (platform call); a published folder with a title slug keeps only date and time")
    check(ShellUtil.sessionIDBase(at: epoch, platform: .call).hasSuffix("_call"), "the staging folder of a call is YYYY-MM-DD_HHMM_call")
}

private extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}

// MARK: - Probe rendering

private func testProbeRendering() {
    section("probe output")
    let sim = DetectSim()
    sim.world.processes = chromeProcs(inp: true, out: true) + zoomProcs() + teamsProcs()
    sim.world.backend.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "Meet", active: true)])
    sim.run(30)
    guard let diag = sim.detector.lastDiagnostics() else {
        check(false, "probe: diagnostics available")
        return
    }
    let report = ProbeReport(time: diag.time, tabQueriesEnabled: true, tabQueriesReason: "enabled in test", tabQueriesForced: true, chromeRunning: true, diagnostics: diag,
                             rows: diag.processes.map { ProbeProcessRow(family: $0.platform, pid: $0.pid, bundleID: $0.bundleID, input: $0.input, output: $0.output, role: "main", udpCounted: nil, udpDetail: nil) },
                             zoomChildren: [ProbeChildRow(pid: 9, name: "ZoomCefHelper", role: "zoom-child", udpCounted: 1, udpDetail: "total=1", meetingKeyArgument: true)],
                             teamsRelayConnected: 0, chromeNetwork: [], otherActive: [ProbeOtherRow(pid: 77, bundleID: "com.apple.VoiceMemos", input: true, output: false)],
                             devices: [AudioDeviceInfo(id: 1, name: "Microsoft Teams Audio", uid: "u", runningSomewhere: false)])
    var cfg = AppConfig.defaults()
    cfg.enabledPlatforms = [.meet, .zoom, .teams]
    // The collector end to end with a fake Chrome (real Core Audio / libproc reads, no Apple Event): --tabs-always shows the
    // tab list although Chrome may have no audio IO.
    let fakeChrome = FakeChromeBackend()
    fakeChrome.result = .ok([tab("https://meet.google.com/abc-defg-hij", title: "You left the meeting", active: true)])
    var collectorConfig = AppConfig.defaults()
    collectorConfig.enabledPlatforms = [.meet]
    let forced = ProbeCollector(config: collectorConfig, policy: TabQueryPolicy(enabled: true, reason: "selftest"), alwaysQueryTabs: true, backend: fakeChrome, zoomTier: .defaults).collect()
    check(forced.tabQueriesForced && forced.diagnostics.tabs?.status == "ok" && forced.diagnostics.tabs?.meetTabs.first?.title == "You left the meeting",
          "probe collector with --tabs-always: the tab list is part of the report", "\(forced.diagnostics.tabs?.status ?? "nil")")
    let closedChrome = FakeChromeBackend()
    let closedReport = ProbeCollector(config: collectorConfig, policy: TabQueryPolicy(enabled: false, reason: "shell"), alwaysQueryTabs: true, backend: closedChrome, zoomTier: .defaults).collect()
    check(closedChrome.totalCalls == 0 && closedReport.diagnostics.tabs?.status == "disabled" && closedReport.tabQueriesForced,
          "probe collector with --tabs-always under a closed policy: Chrome untouched, the report still records that the flag was given")
    check(ProbeRender.table(closedReport, config: collectorConfig).contains("has NO effect"), "table: --tabs-always under a closed policy says it has no effect")

    let table = ProbeRender.table(report, config: cfg)
    for needle in ["PLATFORM SIGNALS", "FLAGS", "FAMILY PROCESSES", "ZOOM", "TEAMS", "CHROME / MEET", "OTHER PROCESSES", "AUDIO DEVICES", "tab queries: ENABLED", "--tabs-always", "abc-defg-hij", "com.google.Chrome.helper", "4214", "w1/t", "front"] {
        check(table.contains(needle), "table shows \"\(needle)\"")
    }
    check(table.contains("argv has `-key <digits>`") && !table.contains("123456789"), "table flags a -key argument without printing digits")
    let line = ProbeRender.summaryLine(report)
    check(line.contains("meet[") && line.contains("zoom[") && line.contains("teams["), "summary line covers every platform", line)

    // Zoom evidence tiers in the probe output: the tier of this poll and the two thresholds.
    func zoomReport(sockets: Int?) -> ProbeReport {
        let z = DetectSim(platforms: [.zoom])
        z.world.processes = zoomProcs()
        if let n = sockets { z.world.udp[787] = n }
        z.run(6)
        let d = z.detector.lastDiagnostics()!
        return ProbeReport(time: d.time, tabQueriesEnabled: false, tabQueriesReason: "selftest", chromeRunning: false, diagnostics: d,
                           rows: [], zoomChildren: [], teamsRelayConnected: nil, chromeNetwork: [], otherActive: [], devices: [])
    }
    var zoomCfg = AppConfig.defaults()
    zoomCfg.enabledPlatforms = [.zoom]
    let flickerReport = zoomReport(sockets: 4)
    let flickerTable = ProbeRender.table(flickerReport, config: zoomCfg)
    check(flickerTable.contains("current tier: weak (sockets=4<6, no input, no output)") && flickerTable.contains("tier=weak (sockets=4<6, no input, no output)"),
          "probe table: the flicker shows 'current tier: weak' with the reason (and the evidence line)", flickerTable)
    check(flickerTable.contains("ZOOM_STRONG_SOCKETS") && flickerTable.contains("sockets >= 6") && flickerTable.contains("ZOOM_WEAK_DEBOUNCE_SECONDS") && flickerTable.contains("15 s"),
          "probe table: names both thresholds and their keys (6 sockets, 15 s)")
    let idleTable = ProbeRender.table(zoomReport(sockets: nil), config: zoomCfg)
    check(idleTable.contains("current tier: none") && idleTable.contains("ZOOM_STRONG_SOCKETS"), "probe table: an idle Zoom says 'current tier: none' and still shows the thresholds")
    check(ProbeRender.flatten(flickerReport)["zoom.tier"] == "weak" && ProbeRender.flatten(zoomReport(sockets: 7))["zoom.tier"] == "strong" && ProbeRender.flatten(zoomReport(sockets: nil))["zoom.tier"] == "none",
          "probe --watch: the tier is a flip key (weak / strong / none)")
    check(ProbeRender.summaryLine(flickerReport).contains("tier weak") && !ProbeRender.summaryLine(zoomReport(sockets: nil)).contains("tier"), "probe summary line: 'tier weak' for the flicker, nothing for an idle Zoom", ProbeRender.summaryLine(flickerReport))
    var offReport = zoomReport(sockets: 4)
    offReport.diagnostics.zoomWeakDebounce = 0
    check(ProbeRender.table(offReport, config: zoomCfg).contains("no extra wait (switched off with 0)"), "probe table: ZOOM_WEAK_DEBOUNCE_SECONDS=0 is said in words")
    let reportJSON = (try? { () -> String in let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return String(data: try e.encode(flickerReport), encoding: .utf8) ?? "" }()) ?? ""
    check(reportJSON.contains("\"zoomTier\"") && reportJSON.contains("\"zoomStrongSockets\"") && reportJSON.contains("\"zoomWeakDebounce\""), "probe --json carries the tier and both thresholds")

    var unforced = report
    unforced.tabQueriesForced = false
    check(!ProbeRender.table(unforced, config: cfg).contains("--tabs-always"), "table: no --tabs-always note when the switch is not used")
    let old = ProbeRender.flatten(report)
    check(old.keys.contains { $0.hasPrefix("chrome.meet.tab w1/t") }, "flip keys: one entry per Meet tab (a title / URL change of the post-call page shows up as a flip)", "\(old.keys.sorted().filter { $0.hasPrefix("chrome") })")
    var retitled = old
    if let k = old.keys.first(where: { $0.hasPrefix("chrome.meet.tab w1/t") }) { retitled[k] = (old[k] ?? "") + " title=changed" }
    check(!ProbeRender.flips(from: old, to: retitled).isEmpty, "flip diff: a tab title change is reported")
    var changed = old
    changed["meet.in.raw"] = "0"
    changed["zoom.udp.main"] = "4"
    changed["pid 1 new"] = "in=1 out=0"
    changed.removeValue(forKey: "meet.out.raw")
    let flips = ProbeRender.flips(from: old, to: changed)
    check(flips.contains("meet.in.raw: 1 -> 0") && flips.contains { $0.hasPrefix("zoom.udp.main:") } && flips.contains("pid 1 new: - -> in=1 out=0") && flips.contains("meet.out.raw: 1 -> -"),
          "flip diff names what changed, with - for appeared/disappeared keys", "\(flips)")
    check(ProbeRender.flips(from: old, to: old).isEmpty, "no flips when nothing changed")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(json.contains("\"signals\"") && json.contains("\"evidence\"") && json.contains("abc-defg-hij"), "probe --json encodes the report")
}
