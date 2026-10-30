import Foundation
import AppKit

// =====================================================================================
// Detector: MeetingDetecting. One PlatformSignal per enabled platform per poll (SPEC 5 + 13.1, docs/DETECTION.md).
//
//   poll():  Core Audio process flags (AudioProcessMonitor) -> per family raw in/out -> smoothing (HysteresisFlag)
//            [+ Chrome tabs when Chrome has audio IO, + Zoom main-pid UDP count] -> platform formula -> PlatformSignal
//
//   Meet   tabMeet = a Chrome tab whose URL is a meeting code (several tabs: MeetTabChooser, by tab identity, sticky);
//            chromeIn/chromeOut = any com.google.Chrome* process.
//            tab info available : inCall = tabMeet && (in || out)           HIGH tier = in && out, MEDIUM = one of them
//            Automation denied / not asked / disabled / error: inCall = in && out, LOW (never `in` alone), no code/title
//            a Workspace nickname tab (not a code) counts like the fallback: in && out, LOW
//   Zoom   inCall = UDP sockets on the main zoom.us pid (>= 1) || input of us.zoom.xos / us.zoom.caphost
//          plus an evidence TIER (`tier=strong|weak` in the evidence, `PlatformSignal.evidenceTier`): STRONG = sockets >= ZOOM_STRONG_SOCKETS (6),
//          or input running, or output running with >= 3 sockets; WEAK = fewer sockets and no audio IO (what an idle, signed-in Zoom shows for
//          a few seconds about every 2 minutes). inCall is unchanged; DetectionStateMachine makes WEAK wait ZOOM_WEAK_DEBOUNCE_SECONDS (15).
//   Teams  inCall = input of com.microsoft.teams*   (output alone never counts; UDP is shown by `probe`, not used). No tiers: nothing in the
//          data or the SPEC supports a weak/strong split for Teams, and Teams signals read as STRONG.
//
//   Calls  every other call (platform .call, one signal per app): the known apps of CallApps.swift, EXTRA_MEETING_APPS, browser meeting tabs and the
//          generic rule, all through `CallTracker` (docs/DETECTION.md section 3b). Off unless the caller hands the detector a `CallDetectSettings` whose
//          mode is not `off` (production: CALL_DETECT, default known; off on a policy-managed Mac that does not set it). ENABLED_PLATFORMS does not bound it (it is the
//          list of Zoom / Teams / Meet), but an empty ENABLED_PLATFORMS switches it off too.
//
// Only platforms in ENABLED_PLATFORMS are evaluated (default zoom,teams; SPEC 15). With `meet` off the Meet branch of poll() is
// never reached, DetectorInputs.live builds no ChromeTabs (unless CALL_BROWSER_URLS asks for the meeting pages of other sites, and then it never
// keeps a Meet tab), and Chrome is never asked for anything.
//
// Start debounce, grace and the Meet split live in DetectionStateMachine. The formulas are pure static functions
// (evaluateMeet / evaluateZoom / evaluateTeams) so selftest-detector can exercise them without any device.
// =====================================================================================

/// Smoothing windows (seconds). At the 2 s default poll: input/UDP need 2 polls on, output needs 5 polls on
/// (a media tab or ringtone must not look like a call); a flag turns off after 3 s without it (bridges one missed poll).
enum DetectionTuning {
    static let inputRise: TimeInterval = 1.5
    static let outputRise: TimeInterval = 7.0
    static let udpRise: TimeInterval = 1.5
    static let fall: TimeInterval = 3.0
}

/// How much a Zoom in-call signal can be trusted on its own (docs/DETECTION.md section 3). Only Zoom has a WEAK tier.
enum EvidenceTier: String, Equatable {
    case strong, weak
}

/// The outcome of `Detector.classifyZoom`: the tier and the reason, as it appears in the evidence (`tier=weak (sockets=4<6, no input, no output)`).
struct ZoomTierVerdict: Equatable {
    var tier: EvidenceTier
    var reason: String
    var evidence: String { "tier=\(tier.rawValue) (\(reason))" }
}

extension PlatformSignal {
    /// The tier a Zoom signal carries in its evidence (`tier=strong ...` / `tier=weak ...`). PlatformSignal (Types.swift) has no field for
    /// it, so it travels in the evidence list, which `Detector.evaluateZoom` writes and this reads (a self-test pins both halves).
    /// Everything that is not a Zoom signal with a `tier=weak` entry reads as STRONG: Teams, Meet and manual are never held back, and a
    /// Zoom signal without a tier entry (a scripted test signal, an older format) behaves as it did before the tiers existed.
    var evidenceTier: EvidenceTier {
        guard platform == .zoom else { return .strong }
        for entry in evidence where entry.hasPrefix("tier=") {
            let word = entry.dropFirst("tier=".count).prefix { $0.isLetter }
            if word == EvidenceTier.weak.rawValue { return .weak }
            if word == EvidenceTier.strong.rawValue { return .strong }
        }
        return .strong
    }
}

/// Everything the detector reads from the machine, as closures, so tests can script a whole call.
struct DetectorInputs {
    var now: () -> Date
    var audioProcesses: (_ interesting: (String) -> Bool) -> [AudioProcessInfo]
    var audioObjectCount: () -> Int
    var audioError: () -> String?
    var udpCount: (_ pid: Int32) -> Int?
    var runningPIDs: (_ bundleID: String) -> [Int32]
    var tabs: (_ audioActive: Bool, _ now: Date, _ maxAge: TimeInterval) -> TabsInfo
    /// The call rule's read (`AudioProcessMonitor.pollCalls`): both flags of the processes that pass `interesting`, and with `scanOthers` the other
    /// processes that hold the microphone. Without a call rule nothing calls it.
    var callProcesses: (_ interesting: (String) -> Bool, _ scanOthers: Bool) -> [AudioProcessInfo] = { _, _ in [] }
    /// Name and "is it a GUI app" of the app with this main bundle id (nil = no such running app).
    var callAppInfo: (_ bundleID: String) -> CallAppInfo? = { _ in nil }
}

/// Short-lived cache for NSRunningApplication lookups (only used when a family has no Core Audio process object).
private final class RunningPIDCache {
    private var cache: [String: (pids: [Int32], at: Date)] = [:]
    private let ttl: TimeInterval
    init(ttl: TimeInterval) { self.ttl = ttl }

    func pids(for bundleID: String) -> [Int32] {
        let now = Date()
        if let c = cache[bundleID], now >= c.at, now.timeIntervalSince(c.at) < ttl { return c.pids }
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { $0.processIdentifier }
        cache[bundleID] = (pids, now)
        return pids
    }
}

extension DetectorInputs {
    /// `alwaysQueryTabs` is for `probe --tabs-always` only (tab list while Chrome has no audio IO); it never loosens the
    /// policy, so it does nothing outside a signed app launch / explicit --tabs + MC_ALLOW_APPLESCRIPT=1.
    /// `backend` is only replaced by the self test (a fake Chrome); production always talks to the real one.
    static func live(config: AppConfig, policy: TabQueryPolicy, alwaysQueryTabs: Bool = false,
                     backend: ChromeBackend = LiveChromeBackend(), calls: CallDetectSettings = .off) -> DetectorInputs {
        let monitor = AudioProcessMonitor()
        // SPEC 15: Meet is opt-in. Without `meet` in ENABLED_PLATFORMS there is no ChromeTabs object at all, so nothing in this
        // process can ask Chrome for its tabs (no AppleScript, no Apple Event, no Automation state lookup), whatever the policy says.
        // The one other reason to read the tabs is CALL_BROWSER_URLS (meeting pages of Whereby, Jitsi, ...): then the tabs are read
        // for those addresses only, and a Meet tab is dropped at once (`keepMeetTabs: false`).
        let meet = config.enabledPlatforms.contains(.meet)
        let web = calls.needsBrowserAutomation(for: config)
        let tabs: ChromeTabs? = meet || web
            ? ChromeTabs(policy: policy, browserBundleIDs: config.browserBundleIDs, backend: backend, alwaysQuery: alwaysQueryTabs,
                         keepMeetTabs: meet, matchWebMeetings: web)
            : nil
        let appInfo = LiveCallAppInfo()
        let micInUse = InputActivityGate()
        let running = RunningPIDCache(ttl: 10)
        return DetectorInputs(
            now: { Date() },
            audioProcesses: { monitor.poll(interesting: $0) },
            audioObjectCount: { monitor.totalObjects },
            audioError: { monitor.lastError },
            udpCount: { NetworkProbe.countedUDP(of: $0) },
            runningPIDs: { running.pids(for: $0) },
            tabs: { audioActive, now, maxAge in
                guard let tabs = tabs else { return TabsInfo(status: .disabled(Detector.meetDisabledReason)) }
                return tabs.info(audioActive: audioActive, now: now, maxAge: maxAge)
            },
            // The scan of the other processes (the generic rule) only runs while some input device is running at all: one cheap read per input device.
            callProcesses: { monitor.pollCalls(interesting: $0, scanOthers: $1 && micInUse.anyInputRunning()) },
            callAppInfo: { appInfo.info(for: $0) })
    }
}

/// Raw and smoothed values of the last poll, for `probe` (never used for decisions).
struct DetectorDiagnostics: Codable {
    struct Process: Codable {
        var platform: Platform
        var pid: Int32
        var bundleID: String
        var input: Bool
        var output: Bool
    }
    struct Flags: Codable {
        var platform: Platform
        var rawInput: Bool
        var rawOutput: Bool
        var stableInput: Bool
        var stableOutput: Bool
    }
    struct Tabs: Codable {
        var status: String
        var detail: String
        var fromCache: Bool
        var totalTabs: Int
        var meetTabs: [MeetTab]
        var chosenKey: String?
        var chosenTabID: TabIdentity?
    }

    var time: Date
    var pollMillis: Double
    var audioObjectCount: Int
    var audioError: String?
    var processes: [Process]
    var flags: [Flags]
    var zoomMainPIDs: [Int32]
    var zoomUDPSockets: Int?
    var zoomUDPStable: Bool
    var tabs: Tabs?
    var signals: [PlatformSignal]
    /// Zoom evidence tier of this poll ("strong" / "weak"; nil while Zoom shows no sockets and no input), why, and the two thresholds in use.
    var zoomTier: String? = nil
    var zoomTierReason: String? = nil
    var zoomStrongSockets: Int? = nil
    var zoomWeakDebounce: Double? = nil
    /// The apps the call rule tracks right now (known, extra, generic, web), empty without a call rule.
    var callApps: [CallAppDiagnostics] = []
}

// MARK: - Formula inputs

struct MeetEvaluationInput {
    var browserBundleID: String
    var audio: FamilyAudio
    var stableInput: Bool
    var stableOutput: Bool
    var tabs: TabsInfo
    var chosenTab: MeetTab?
}

struct ZoomEvaluationInput {
    var audio: FamilyAudio
    var stableInput: Bool
    var stableOutput: Bool
    var mainPIDs: [Int32]
    var udpSockets: Int?
    var stableUDP: Bool
    /// ZOOM_STRONG_SOCKETS: main-pid sockets at which the evidence is STRONG without any audio IO.
    var strongSockets: Int = ZoomTierSettings.defaultStrongSockets
}

struct TeamsEvaluationInput {
    var audio: FamilyAudio
    var stableInput: Bool
    var stableOutput: Bool
}

// MARK: - Detector

final class Detector: MeetingDetecting {
    /// Shown by `probe` as the tab-query status when `meet` is not in ENABLED_PLATFORMS.
    static let meetDisabledReason = "meet is not in ENABLED_PLATFORMS: Chrome tabs are never queried"

    private struct FamilyFlags {
        var input = HysteresisFlag(rise: DetectionTuning.inputRise, fall: DetectionTuning.fall)
        var output = HysteresisFlag(rise: DetectionTuning.outputRise, fall: DetectionTuning.fall)
    }

    private let config: AppConfig
    private let inputs: DetectorInputs
    private let zoomTier: ZoomTierSettings
    private let matcher: FamilyMatcher
    private let lock = NSLock()
    private let chooser: MeetTabChooser
    /// Chrome without audio IO for this long (about the Meet grace): the session is over, the tab choice is forgotten.
    private let forgetTabsAfterIdle: TimeInterval
    private var chromeIdleSince: Date?
    private var flags: [Platform: FamilyFlags] = [:]
    private var udpFlag = HysteresisFlag(rise: DetectionTuning.udpRise, fall: DetectionTuning.fall)
    private var lastInCall: [Platform: Bool] = [:]
    private var lastCallInCall: [String: Bool] = [:]
    /// nil = no call rule (CALL_DETECT=off, or the seam was built without settings).
    private let callTracker: CallTracker?
    private var lastTabsLabel: String?
    private var lastAudioError: String?
    private var diagnostics: DetectorDiagnostics?

    /// Production detector: real Core Audio / libproc / Chrome sources. AppleScript only runs when
    /// `TabQueryPolicy.current()` allows it (`LaunchGuard.isSignedAppLaunch`, or --tabs + MC_ALLOW_APPLESCRIPT=1).
    /// It always keeps the Chrome audio gate on the tab query (only `probe --tabs-always` builds its inputs otherwise).
    /// The call rule comes from config.env (CALL_DETECT, default known) and `callStore` (the person's decisions per app).
    convenience init(config: AppConfig, callStore: CallAppStore? = nil) {
        let calls = CallDetectSettings.current
        self.init(config: config, inputs: .live(config: config, policy: TabQueryPolicy.current(), calls: calls), zoomTier: ZoomTierSettings.current,
                  calls: calls, callStore: callStore)
    }

    /// `zoomTier` = the Zoom evidence-tier thresholds (ZOOM_STRONG_SOCKETS); tests and `probe` pass them explicitly. `calls` = the call rule
    /// (CALL_DETECT and friends): the seam keeps the old behaviour (`.off`: Zoom, Teams, Meet only) unless the caller asks for more.
    init(config: AppConfig, inputs: DetectorInputs, zoomTier: ZoomTierSettings = .defaults, calls: CallDetectSettings = .off, callStore: CallAppStore? = nil) {
        self.config = config
        self.inputs = inputs
        self.zoomTier = zoomTier
        self.callTracker = calls.mode == .off ? nil : CallTracker(settings: calls, browserBundleIDs: config.browserBundleIDs, store: callStore)
        self.matcher = FamilyMatcher(browserBundleIDs: config.browserBundleIDs, enabledPlatforms: config.enabledPlatforms)
        // A new Meet tab must be the front tab for the start debounce before it can take a running call over.
        self.chooser = MeetTabChooser(acceptAfter: config.startDebounce)
        self.forgetTabsAfterIdle = max(config.grace, 5)
    }

    /// Raw/smoothed values of the most recent poll (nil before the first poll).
    func lastDiagnostics() -> DetectorDiagnostics? {
        lock.lock(); defer { lock.unlock() }
        return diagnostics
    }

    func poll() -> DetectionSnapshot {
        lock.lock(); defer { lock.unlock() }
        let started = DispatchTime.now().uptimeNanoseconds
        let now = inputs.now()

        let processes = inputs.audioProcesses(matcher.isInteresting)
        let groups = matcher.group(processes)
        let audioError = inputs.audioError()
        if audioError != lastAudioError {
            if let e = audioError { Log.warn("detect: core audio enumeration failed: \(e)") } else { Log.info("detect: core audio enumeration recovered") }
            lastAudioError = audioError
        }

        var signals: [PlatformSignal] = []
        var flagsDiag: [DetectorDiagnostics.Flags] = []
        var tabsDiag: DetectorDiagnostics.Tabs?
        var zoomPIDs: [Int32] = []
        var zoomSockets: Int?
        var zoomStableUDP = false
        var zoomVerdict: ZoomTierVerdict?
        var tabsThisPoll: TabsInfo?

        // Only enabled platforms are visited: `.meet` (and with it every Chrome tab query) is skipped unless it is enabled.
        for platform in config.enabledPlatforms where platform != .manual && platform != .call {
            let family = groups[platform] ?? FamilyAudio(platform: platform)
            var f = flags[platform] ?? FamilyFlags()
            let stableIn = f.input.update(raw: family.rawInput, now: now)
            let stableOut = f.output.update(raw: family.rawOutput, now: now)
            flags[platform] = f
            flagsDiag.append(.init(platform: platform, rawInput: family.rawInput, rawOutput: family.rawOutput,
                                   stableInput: stableIn, stableOutput: stableOut))

            switch platform {
            case .meet:
                // Tabs are only needed (and only queried) while Chrome has audio IO, which includes the smoothing hold.
                let audioActive = family.rawInput || family.rawOutput || stableIn || stableOut
                if audioActive {
                    chromeIdleSince = nil
                } else {
                    let since = min(chromeIdleSince ?? now, now)
                    chromeIdleSince = since
                    if now.timeIntervalSince(since) >= forgetTabsAfterIdle { chooser.forget() }
                }
                // Read the tab list often while looking for a call, rarely once one is established (but often again
                // while a newly opened tab is being timed as a possible next meeting).
                let steady = lastInCall[.meet] == true && !chooser.takeoverPending
                let maxAge = steady ? ChromeTabs.steadyCacheSeconds : ChromeTabs.cacheSeconds
                let tabs = inputs.tabs(audioActive, now, maxAge)
                tabsThisPoll = tabs
                let chosen: MeetTab? = tabs.status.isOK ? chooser.choose(from: tabs.candidates, observedAt: tabs.queriedAt ?? now) : nil
                noteTabsStatus(tabs)
                tabsDiag = .init(status: tabs.status.label, detail: tabs.status.detail, fromCache: tabs.fromCache,
                                 totalTabs: tabs.totalTabs, meetTabs: tabs.meetHostTabs, chosenKey: chosen?.key,
                                 chosenTabID: chosen?.identity)
                signals.append(Self.evaluateMeet(MeetEvaluationInput(
                    browserBundleID: config.browserBundleIDs.first ?? ChromeTabs.defaultBundleID,
                    audio: family, stableInput: stableIn, stableOutput: stableOut, tabs: tabs, chosenTab: chosen)))

            case .zoom:
                // Zoom MAIN pid only (helpers own unrelated QUIC sockets). The process object is normally listed even
                // when idle; NSRunningApplication is the fallback if it is not.
                var pids = family.pids(ofBundle: FamilyMatcher.zoomMainBundleID)
                if pids.isEmpty { pids = inputs.runningPIDs(FamilyMatcher.zoomMainBundleID).sorted() }
                var sockets: Int?
                for pid in pids {
                    if let n = inputs.udpCount(pid) { sockets = (sockets ?? 0) + n }
                }
                let stableUDP = udpFlag.update(raw: (sockets ?? 0) >= 1, now: now)
                zoomPIDs = pids
                zoomSockets = sockets
                zoomStableUDP = stableUDP
                if (sockets ?? 0) >= 1 || stableIn {
                    zoomVerdict = Self.classifyZoom(sockets: sockets, stableInput: stableIn, stableOutput: stableOut, strongSockets: zoomTier.strongSockets)
                }
                signals.append(Self.evaluateZoom(ZoomEvaluationInput(
                    audio: family, stableInput: stableIn, stableOutput: stableOut,
                    mainPIDs: pids, udpSockets: sockets, stableUDP: stableUDP, strongSockets: zoomTier.strongSockets)))

            case .teams:
                signals.append(Self.evaluateTeams(TeamsEvaluationInput(audio: family, stableInput: stableIn, stableOutput: stableOut)))

            case .manual, .call:
                break               // never in the loop: manual has no detector, calls of other apps are the CallTracker's (below)
            }
        }

        // Calls of other apps: one signal per tracked app, after the three platforms.
        var callDiag: [CallAppDiagnostics] = []
        if let tracker = callTracker, !config.enabledPlatforms.isEmpty {
            let callProcesses = inputs.callProcesses(tracker.isInteresting, tracker.genericOn)
            var tabsForCalls = tabsThisPoll
            if tracker.webOn, tabsForCalls == nil {
                // Meet is off but CALL_BROWSER_URLS is on: the tab list is read for the meeting pages of the table, and only while the browser has audio IO.
                let steady = lastCallInCall.values.contains(true)
                let tabs = inputs.tabs(tracker.browserAudioActive(callProcesses), now, steady ? ChromeTabs.steadyCacheSeconds : ChromeTabs.cacheSeconds)
                noteTabsStatus(tabs)
                tabsForCalls = tabs
            }
            let result = tracker.update(processes: callProcesses, now: now, tabs: tabsForCalls, appInfo: inputs.callAppInfo)
            signals += result.signals
            callDiag = result.diagnostics
        }

        logTransitions(signals)

        let millis = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        diagnostics = DetectorDiagnostics(
            time: now, pollMillis: millis, audioObjectCount: inputs.audioObjectCount(), audioError: audioError,
            processes: processes.compactMap { p in
                guard let platform = matcher.platform(of: p.bundleID) else { return nil }
                return .init(platform: platform, pid: p.pid, bundleID: p.bundleID, input: p.isRunningInput, output: p.isRunningOutput)
            },
            flags: flagsDiag, zoomMainPIDs: zoomPIDs, zoomUDPSockets: zoomSockets, zoomUDPStable: zoomStableUDP,
            tabs: tabsDiag, signals: signals,
            zoomTier: zoomVerdict?.tier.rawValue, zoomTierReason: zoomVerdict?.reason,
            zoomStrongSockets: config.enabledPlatforms.contains(.zoom) ? zoomTier.strongSockets : nil,
            zoomWeakDebounce: config.enabledPlatforms.contains(.zoom) ? zoomTier.weakDebounce : nil,
            callApps: callDiag)
        return DetectionSnapshot(time: now, signals: signals)
    }

    // MARK: Logging (state-transition snapshots; SessionController logs the recording transitions)

    private func logTransitions(_ signals: [PlatformSignal]) {
        for s in signals {
            if s.platform == .call {
                // One signal per app: the state is per app (the key), and the line names the app.
                let key = s.meetingKey ?? s.bundleID ?? "?"
                let was = lastCallInCall[key] ?? false
                if s.inCall != was {
                    Log.info("detect: call \(NotificationText.clip(s.displayLabel, 40)) [\(s.callKind?.rawValue ?? "?") \(s.bundleID ?? "?")] inCall \(was)->\(s.inCall) conf=\(s.confidence.rawValue) [\(s.evidence.joined(separator: "; "))]")
                }
                lastCallInCall[key] = s.inCall
                continue
            }
            let was = lastInCall[s.platform] ?? false
            if s.inCall != was {
                Log.info("detect: \(s.platform.rawValue) inCall \(was)->\(s.inCall) conf=\(s.confidence.rawValue) [\(s.evidence.joined(separator: "; "))]")
            }
            lastInCall[s.platform] = s.inCall
        }
        // An app that has no signal any more is over (its entry must not stay "in a call" for the next time it shows up).
        let present = Set(signals.filter { $0.platform == .call }.map { $0.meetingKey ?? $0.bundleID ?? "?" })
        for (key, value) in lastCallInCall where !present.contains(key) {
            if value { Log.info("detect: call \(key) inCall true->false (no audio IO of that app any more)") }
            lastCallInCall.removeValue(forKey: key)
        }
    }

    /// Logs tab-query status changes (denied / not asked / error ...), not the normal idle <-> ok churn.
    private func noteTabsStatus(_ tabs: TabsInfo) {
        guard tabs.status != .idle else { return }
        let label = tabs.status.label
        if label != lastTabsLabel {
            let message = "detect: chrome tab query status -> \(label): \(tabs.status.detail)"
            switch tabs.status {
            case .denied, .notAsked, .error: Log.warn(message)          // the Meet rule is running on its LOW fallback
            default: Log.info(message)
            }
            lastTabsLabel = label
        }
    }

    // MARK: Formulas (pure)

    private static func b(_ v: Bool) -> String { v ? "1" : "0" }

    private static func audioEvidence(_ name: String, _ audio: FamilyAudio, _ stableIn: Bool, _ stableOut: Bool) -> String {
        return "\(name) in=\(b(stableIn)) out=\(b(stableOut)) raw=\(b(audio.rawInput))/\(b(audio.rawOutput)) io=\(audio.ioSummary)"
    }

    static func evaluateMeet(_ i: MeetEvaluationInput) -> PlatformSignal {
        var s = PlatformSignal(platform: .meet, inCall: false, confidence: .high, bundleID: i.browserBundleID)
        s.evidence.append(audioEvidence("chrome-audio", i.audio, i.stableInput, i.stableOutput))
        guard i.audio.rawInput || i.audio.rawOutput || i.stableInput || i.stableOutput else {
            s.evidence.append("no chrome audio IO")
            return s
        }
        s.evidence.append("tabs: " + i.tabs.summary(chosen: i.chosenTab))

        let io = i.stableInput || i.stableOutput
        let both = i.stableInput && i.stableOutput

        guard i.tabs.status.isOK else {
            // Tab list unavailable (Automation denied / not asked / disabled / error): never `in` alone.
            s.confidence = .low
            s.inCall = both
            s.evidence.append(both ? "tier=LOW (no tab info: chrome in+out)" : "no tab info: needs chrome in+out")
            return s
        }
        guard let tab = i.chosenTab else {
            s.evidence.append("no Meet tab with a meeting code")
            return s
        }
        s.meetingKey = tab.key
        s.meetingURL = tab.url
        s.titleHint = tab.title
        if tab.kind == .nickname {
            s.confidence = .low
            s.inCall = both
            s.evidence.append(both ? "tier=LOW (nickname tab \(tab.key) + in+out)" : "nickname tab \(tab.key) needs in+out")
        } else if both {
            s.inCall = true
            s.evidence.append("tier=HIGH (code tab + in + out)")
        } else if io {
            s.inCall = true
            s.evidence.append("tier=MEDIUM (code tab + \(i.stableInput ? "in" : "out") only)")
        } else {
            s.evidence.append("code tab \(tab.key) but chrome audio not yet sustained")
        }
        return s
    }

    /// The Zoom evidence tier (docs/DETECTION.md section 3). Uses the smoothed (stable) input / output flags, the same `in=` / `out=` the log
    /// shows, so a one-poll glitch of a raw flag never upgrades a weak signal.
    ///   STRONG  sockets >= strongSockets, or input running, or output running with >= ZoomTierSettings.outputSockets sockets
    ///   WEAK    anything else that still reads as a call (a few sockets, no input, no output)
    static func classifyZoom(sockets: Int?, stableInput: Bool, stableOutput: Bool, strongSockets: Int) -> ZoomTierVerdict {
        let n = sockets ?? 0
        var strongReasons: [String] = []
        if n >= strongSockets { strongReasons.append("sockets=\(n)>=\(strongSockets)") }
        if stableInput { strongReasons.append("input") }
        if stableOutput && n >= ZoomTierSettings.outputSockets { strongReasons.append("output+sockets=\(n)>=\(ZoomTierSettings.outputSockets)") }
        if !strongReasons.isEmpty { return ZoomTierVerdict(tier: .strong, reason: strongReasons.joined(separator: ", ")) }
        let io = stableOutput ? "output but sockets<\(ZoomTierSettings.outputSockets)" : "no input, no output"
        return ZoomTierVerdict(tier: .weak, reason: "sockets=\(n)<\(strongSockets), \(io)")
    }

    static func evaluateZoom(_ i: ZoomEvaluationInput) -> PlatformSignal {
        var s = PlatformSignal(platform: .zoom, inCall: false, confidence: .high, bundleID: FamilyMatcher.zoomMainBundleID)
        s.evidence.append(audioEvidence("zoom-audio", i.audio, i.stableInput, i.stableOutput))
        let pidText = i.mainPIDs.isEmpty ? "none" : i.mainPIDs.map(String.init).joined(separator: ",")
        let socketText = i.udpSockets.map(String.init) ?? "n/a"
        s.evidence.append("udp main-pid=\(pidText) sockets=\(socketText) stable=\(b(i.stableUDP))")
        if i.stableUDP {
            s.inCall = true
            s.evidence.append(i.stableInput ? "via=udp+input" : "via=udp")
        } else if i.stableInput {
            s.inCall = true
            s.evidence.append("via=input")
        } else if i.stableOutput || i.audio.rawOutput {
            s.evidence.append("output alone does not count")
        }
        // The tier is named whenever Zoom shows sockets or input (an idle Zoom keeps the three entries above and nothing else).
        if s.inCall || (i.udpSockets ?? 0) >= 1 || i.stableInput {
            s.evidence.append(classifyZoom(sockets: i.udpSockets, stableInput: i.stableInput, stableOutput: i.stableOutput,
                                           strongSockets: i.strongSockets).evidence)
        }
        return s
    }

    static func evaluateTeams(_ i: TeamsEvaluationInput) -> PlatformSignal {
        var s = PlatformSignal(platform: .teams, inCall: false, confidence: .high, bundleID: FamilyMatcher.teamsMainBundleID)
        s.evidence.append(audioEvidence("teams-audio", i.audio, i.stableInput, i.stableOutput))
        if i.stableInput {
            s.inCall = true
            s.evidence.append("via=input")
        } else if i.stableOutput || i.audio.rawOutput {
            s.evidence.append("output alone does not count")
        }
        return s
    }
}
