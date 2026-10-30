import Foundation
import AppKit

// =====================================================================================
// `<short name> probe [--watch] [--json] [--all-platforms] [--interval S] [--minutes M] [--bench [N]] [--tabs] [--tabs-always]`
//
// Prints what the detector sees, with everything the live-test checklist (docs/DETECTION.md, L-01..L-20) needs:
//   per platform: inCall / confidence / evidence;  per family process: PID, bundle, IsRunningInput/Output, Chromium role;
//   raw vs smoothed in/out flags;  Zoom main-pid UDP sockets + every Zoom child process;  Teams UDP + relay-port
//   count + the "Microsoft Teams Audio" device;  Chrome running state, Automation/tab-query status and the
//   meet.google.com tabs (classified; other tabs are never printed);  non-family processes that hold audio IO.
// --watch refreshes every second (override with --interval) and prints a line only when something flipped,
// with the flips spelled out (highlighted on a terminal). It ends by itself after 90 minutes (--minutes M, 0 = never).
//
// Only the ENABLED_PLATFORMS are evaluated and shown (default zoom,teams; Meet is opt-in, SPEC 15). `--all-platforms` shows all
// three for one run (it changes no file; with Meet off in the config the production app still never queries Chrome tabs).
//
// `--tabs-always` (probe only) keeps querying the Chrome tab list while Chrome has NO audio IO, so the post-call page and
// the return-to-home page stay observable (live tests L-12 / L-13). The production Detector keeps its audio gate.
//
// SAFETY: tab queries (AppleScript) are disabled unless this runs as the signed app started by launchd / LaunchServices
// (`LaunchGuard.isSignedAppLaunch`: use `open -n -W -a ~/Applications/<short name>.app --args probe ...`), or `--tabs`
// is passed together with MC_ALLOW_APPLESCRIPT=1 (TabQueryPolicy). `--tabs-always` only skips the audio gate: it never
// enables tab queries by itself and keeps every other gate (policy, Chrome running, Automation already granted).
// Everything else here is permission-free (Core Audio process flags, libproc, NSRunningApplication).
// =====================================================================================

// MARK: - Report model

struct ProbeProcessRow: Codable {
    var family: Platform
    var pid: Int32
    var bundleID: String
    var input: Bool
    var output: Bool
    var role: String
    var udpCounted: Int?
    var udpDetail: String?
}

struct ProbeChildRow: Codable {
    var pid: Int32
    var name: String
    var role: String
    var udpCounted: Int?
    var udpDetail: String
    var meetingKeyArgument: Bool
}

struct ProbeOtherRow: Codable {
    var pid: Int32
    var bundleID: String
    var input: Bool
    var output: Bool
}

struct ProbeReport: Codable {
    var time: Date
    var tabQueriesEnabled: Bool
    var tabQueriesReason: String
    var tabQueriesForced = false          // --tabs-always was given (it only has an effect while tabQueriesEnabled)
    var chromeRunning: Bool
    var diagnostics: DetectorDiagnostics
    var rows: [ProbeProcessRow]
    var zoomChildren: [ProbeChildRow]
    var teamsRelayConnected: Int?
    var chromeNetwork: [ProbeChildRow]
    var otherActive: [ProbeOtherRow]
    var devices: [AudioDeviceInfo]
}

// MARK: - Collection

/// Holds the little state a probe session needs (role cache, a second monitor for the non-family sweep).
final class ProbeCollector {
    private let config: AppConfig
    private let matcher: FamilyMatcher
    private let detector: Detector
    private let sweep = AudioProcessMonitor()
    private var roles: [Int32: NetworkProbe.ChromiumRole] = [:]
    let policy: TabQueryPolicy

    let alwaysQueryTabs: Bool

    /// `backend` is only replaced by the self test (a fake Chrome); the probe always talks to the real one.
    init(config: AppConfig, policy: TabQueryPolicy, alwaysQueryTabs: Bool = false, backend: ChromeBackend = LiveChromeBackend(),
         zoomTier: ZoomTierSettings = ZoomTierSettings.current) {
        self.config = config
        self.policy = policy
        self.alwaysQueryTabs = alwaysQueryTabs
        self.matcher = FamilyMatcher(browserBundleIDs: config.browserBundleIDs, enabledPlatforms: config.enabledPlatforms)
        // The Zoom tier thresholds come from config.env (ZOOM_STRONG_SOCKETS), like the app; `zoomTier` is replaced by the self test only.
        self.detector = Detector(config: config, inputs: .live(config: config, policy: policy, alwaysQueryTabs: alwaysQueryTabs, backend: backend),
                                 zoomTier: zoomTier)
    }

    func collect() -> ProbeReport {
        _ = detector.poll()
        let diag = detector.lastDiagnostics() ?? DetectorDiagnostics(
            time: Date(), pollMillis: 0, audioObjectCount: 0, audioError: "no poll result", processes: [], flags: [],
            zoomMainPIDs: [], zoomUDPSockets: nil, zoomUDPStable: false, tabs: nil, signals: [])

        let rows: [ProbeProcessRow] = diag.processes.sorted { ($0.platform.rawValue, $0.pid) < ($1.platform.rawValue, $1.pid) }.map { p in
            var row = ProbeProcessRow(family: p.platform, pid: p.pid, bundleID: p.bundleID, input: p.input, output: p.output,
                                      role: "", udpCounted: nil, udpDetail: nil)
            switch p.platform {
            case .meet:
                row.role = role(of: p.pid).rawValue
            case .zoom:
                row.role = p.bundleID.lowercased() == FamilyMatcher.zoomMainBundleID ? "main" : "helper"
                fillUDP(&row)
            case .teams:
                row.role = p.bundleID.lowercased() == FamilyMatcher.teamsMainBundleID ? "main" : "helper"
                fillUDP(&row)
            case .manual, .call:
                break
            }
            return row
        }

        var zoomChildren: [ProbeChildRow] = []
        for pid in diag.zoomMainPIDs {
            for child in NetworkProbe.childPIDs(of: pid) { zoomChildren.append(childRow(child, role: "zoom-child")) }
        }

        var relay: Int?
        let teamsMain = diag.processes.filter { $0.platform == .teams && $0.bundleID.lowercased() == FamilyMatcher.teamsMainBundleID }
        if !teamsMain.isEmpty {
            relay = teamsMain.reduce(0) { total, p in
                total + NetworkProbe.connected(NetworkProbe.udpSockets(of: p.pid) ?? [], toPorts: NetworkProbe.teamsRelayPorts)
            }
        }

        // Chrome's network service (all WebRTC / QUIC sockets): logged, not used (SPEC 13.1 rejects it as a signal).
        var chromeNetwork: [ProbeChildRow] = []
        for main in diag.processes where main.platform == .meet && role(of: main.pid) == .main {
            for child in NetworkProbe.childPIDs(of: main.pid) where role(of: child) == .network {
                chromeNetwork.append(childRow(child, role: "network-service"))
            }
        }

        let other: [ProbeOtherRow] = sweep.pollAll().compactMap { p in
            guard p.isRunningInput || p.isRunningOutput, !matcher.isInteresting(p.bundleID),
                  !FamilyMatcher.isOwn(p.bundleID.lowercased()) else { return nil }
            return ProbeOtherRow(pid: p.pid, bundleID: p.bundleID.isEmpty ? "(no bundle id)" : p.bundleID, input: p.isRunningInput, output: p.isRunningOutput)
        }.sorted { $0.pid < $1.pid }

        let devices = AudioDeviceList.all().filter { $0.runningSomewhere || $0.name.lowercased().contains("teams") }
        // Chrome is only looked at when Meet is enabled (SPEC 15); otherwise the report says "no" without asking.
        let chromeRunning = config.enabledPlatforms.contains(.meet)
            && !NSRunningApplication.runningApplications(withBundleIdentifier: ChromeTabs.defaultBundleID).isEmpty

        return ProbeReport(time: diag.time, tabQueriesEnabled: policy.enabled, tabQueriesReason: policy.reason,
                           tabQueriesForced: alwaysQueryTabs,
                           chromeRunning: chromeRunning, diagnostics: diag, rows: rows, zoomChildren: zoomChildren,
                           teamsRelayConnected: relay, chromeNetwork: chromeNetwork, otherActive: other, devices: devices)
    }

    private func role(of pid: Int32) -> NetworkProbe.ChromiumRole {
        if let r = roles[pid] { return r }
        let r = NetworkProbe.arguments(of: pid).map { NetworkProbe.chromiumRole(arguments: $0) } ?? .main
        roles[pid] = r
        return r
    }

    private func fillUDP(_ row: inout ProbeProcessRow) {
        if let sockets = NetworkProbe.udpSockets(of: row.pid) {
            row.udpCounted = NetworkProbe.counted(sockets)
            row.udpDetail = NetworkProbe.describe(sockets)
        } else {
            row.udpDetail = "cannot inspect"
        }
    }

    private func childRow(_ pid: Int32, role: String) -> ProbeChildRow {
        let sockets = NetworkProbe.udpSockets(of: pid)
        return ProbeChildRow(pid: pid, name: NetworkProbe.executableName(of: pid), role: role,
                             udpCounted: sockets.map(NetworkProbe.counted),
                             udpDetail: sockets.map(NetworkProbe.describe) ?? "cannot inspect",
                             meetingKeyArgument: NetworkProbe.arguments(of: pid).map(NetworkProbe.hasMeetingKeyArgument) ?? false)
    }
}

// MARK: - Rendering

enum ProbeRender {
    /// Every platform the detector knows, in display order. `probe` shows the enabled ones; `--all-platforms` shows all of them.
    static let allPlatforms: [Platform] = [.zoom, .teams, .meet]

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    private static func b(_ v: Bool) -> String { v ? "1" : "0" }

    /// "w123/t45": Chrome's window id and tab id.
    private static func tabPosition(_ m: MeetTab) -> String { "w\(m.windowID)/t\(m.tabID)" }

    /// "current tier: weak (sockets=4<6, no input, no output)" / "current tier: none (no sockets, no input)".
    static func zoomTierLine(_ d: DetectorDiagnostics) -> String {
        guard let tier = d.zoomTier else { return "  current tier: none (no sockets on the main pid, no input)" }
        return "  current tier: \(tier)\(d.zoomTierReason.map { " (\($0))" } ?? "")"
    }

    private static func zoomWeakText(_ seconds: Double?) -> String {
        guard let s = seconds else { return "? s" }
        return s > 0 ? "\(fmt(s)) s" : "no extra wait (switched off with 0)"
    }

    static func table(_ r: ProbeReport, config: AppConfig) -> String {
        var out: [String] = []
        let d = r.diagnostics
        out.append("\(AppInfo.shortName) probe  \(time(r.time))   poll \(String(format: "%.1f", d.pollMillis)) ms   core-audio process objects: \(d.audioObjectCount)")
        if let e = d.audioError { out.append("!! core audio enumeration failed: \(e)") }
        out.append("enabled: \(config.enabledPlatforms.map { $0.rawValue }.joined(separator: ","))   app poll \(fmt(config.pollInterval)) s   start-debounce \(fmt(config.startDebounce)) s   grace meet \(fmt(config.grace)) s / zoom+teams \(fmt(max(config.grace, DetectionStateMachine.zoomTeamsMinGrace))) s")
        let notEnabled = ProbeRender.allPlatforms.filter { !config.enabledPlatforms.contains($0) }
        if !notEnabled.isEmpty {
            out.append("not enabled: \(notEnabled.map { $0.rawValue }.joined(separator: ","))   (not evaluated and not shown below; add them to ENABLED_PLATFORMS, or run `probe --all-platforms` to look at them once)")
        }
        out.append("tab queries: \(r.tabQueriesEnabled ? "ENABLED" : "DISABLED") - \(r.tabQueriesReason)")
        if r.tabQueriesForced {
            out.append(r.tabQueriesEnabled
                       ? "             --tabs-always: the tab list is queried even while Chrome has no audio IO (probe only; the app keeps its audio gate)"
                       : "             --tabs-always was given but has NO effect: tab queries are disabled (see the reason above)")
        }

        out.append("")
        out.append("PLATFORM SIGNALS (what the state machine sees)")
        for s in d.signals {
            out.append("  \(pad(s.platform.rawValue, 6)) inCall=\(s.inCall ? "YES" : "no ")  conf=\(s.confidence.rawValue)  bundle=\(s.bundleID ?? "-")" +
                       (s.meetingKey.map { "  meetingKey=\($0)" } ?? "") + (s.titleHint.map { "  title=\"\($0)\"" } ?? ""))
            for e in s.evidence { out.append("           \(e)") }
        }

        out.append("")
        out.append("FLAGS (raw = this poll, stable = smoothed: in >= \(fmt(DetectionTuning.inputRise)) s on, out >= \(fmt(DetectionTuning.outputRise)) s on, off after \(fmt(DetectionTuning.fall)) s)")
        for f in d.flags {
            var line = "  \(pad(f.platform.rawValue, 6)) in raw=\(b(f.rawInput)) stable=\(b(f.stableInput))   out raw=\(b(f.rawOutput)) stable=\(b(f.stableOutput))"
            if f.platform == .zoom {
                line += "   udp main-pid sockets=\(d.zoomUDPSockets.map(String.init) ?? "n/a") stable=\(b(d.zoomUDPStable))"
            }
            out.append(line)
        }

        out.append("")
        out.append("FAMILY PROCESSES (Core Audio process objects; in/out = IsRunningInput/IsRunningOutput)")
        if r.rows.isEmpty {
            out.append("  (none: none of the enabled apps has a Core Audio client right now)")
        } else {
            out.append("  \(pad("family", 7))\(pad("pid", 8))\(pad("in", 4))\(pad("out", 5))\(pad("bundle id", 36))\(pad("role", 14))udp")
            for p in r.rows {
                out.append("  \(pad(p.family.rawValue, 7))\(pad(String(p.pid), 8))\(pad(b(p.input), 4))\(pad(b(p.output), 5))\(pad(p.bundleID, 36))\(pad(p.role, 14))\(p.udpDetail ?? "")")
            }
        }

        if config.enabledPlatforms.contains(.zoom) {
            out.append("")
            out.append("ZOOM (L-01 / L-02 / L-05: main pid must hold UDP sockets in a meeting and none when idle)")
            out.append("  main pid(s): \(d.zoomMainPIDs.isEmpty ? "none" : d.zoomMainPIDs.map(String.init).joined(separator: ","))   UDP sockets counted: \(d.zoomUDPSockets.map(String.init) ?? "n/a")")
            out.append(zoomTierLine(d))
            out.append("  tiers: STRONG = sockets >= \(d.zoomStrongSockets.map(String.init) ?? "?") (ZOOM_STRONG_SOCKETS) | input running | output running + >= \(ZoomTierSettings.outputSockets) sockets;  WEAK = fewer sockets and no audio IO")
            out.append("         STRONG records after the start debounce (\(fmt(config.startDebounce)) s); WEAK counts only after \(zoomWeakText(d.zoomWeakDebounce)) (ZOOM_WEAK_DEBOUNCE_SECONDS), so the idle UDP flicker (4 sockets, no audio IO, 4-14 s) never records")
            if r.zoomChildren.isEmpty {
                out.append("  child processes: none")
            } else {
                for c in r.zoomChildren {
                    out.append("  child \(pad(String(c.pid), 7))\(pad(c.name, 32)) udp: \(c.udpDetail)" + (c.meetingKeyArgument ? "   argv has `-key <digits>` (meeting id, not shown)" : ""))
                }
            }
        }

        if config.enabledPlatforms.contains(.teams) {
            out.append("")
            out.append("TEAMS (L-06 / L-20: which bundle carries in/out; are there connected UDP sockets to relay ports 3478-3481?)")
            let teamsRows = r.rows.filter { $0.family == .teams }
            if teamsRows.isEmpty { out.append("  Teams has no Core Audio client right now (not running, or never opened audio)") }
            out.append("  connected UDP sockets to relay ports 3478-3481 on the main process: \(r.teamsRelayConnected.map(String.init) ?? "n/a (main process not listed)")   (information only, not used by the call rule)")
        }

        if config.enabledPlatforms.contains(.meet) {
            out.append("")
            out.append("CHROME / MEET (L-10..L-17)")
            out.append("  Chrome running: \(r.chromeRunning ? "yes" : "no")   tab query: \(d.tabs?.status ?? "n/a")\(d.tabs.map { $0.fromCache ? " (cached)" : "" } ?? "")")
            if let t = d.tabs {
                out.append("  \(t.detail)")
                if t.status == "ok" {
                    out.append("  tabs total: \(t.totalTabs)   meet.google.com tabs: \(t.meetTabs.count)   chosen: \(t.chosenKey ?? "none")")
                    for m in t.meetTabs {
                        out.append("    \(m.identity == t.chosenTabID ? "*" : " ") \(pad(m.kind.rawValue, 9))\(pad(m.url, 44))\(pad(tabPosition(m), 20))\(m.isFrontActive ? "front " : (m.isActive ? "active " : "       "))\(m.incognito ? "incognito " : "")\(m.title.map { "\"\($0)\"" } ?? "")")
                    }
                    out.append("    (* = chosen tab; front = active tab of Chrome's front window; w/t = window id / tab id; the chooser is sticky and only a new tab that has been front for \(fmt(config.startDebounce)) s takes over)")
                }
            }
            for c in r.chromeNetwork { out.append("  chrome network service pid \(c.pid): UDP \(c.udpDetail)  (logged only)") }
        }

        out.append("")
        out.append("OTHER PROCESSES WITH AUDIO IO (not part of any enabled family; ignored by the detector)")
        if r.otherActive.isEmpty {
            out.append("  (none)")
        } else {
            for o in r.otherActive { out.append("  pid \(pad(String(o.pid), 7)) in=\(b(o.input)) out=\(b(o.output))  \(o.bundleID)") }
        }

        out.append("")
        out.append("AUDIO DEVICES RUNNING SOMEWHERE (plus any Teams virtual device)")
        if r.devices.isEmpty {
            out.append("  (none)")
        } else {
            for dev in r.devices { out.append("  running=\(b(dev.runningSomewhere))  \(dev.name)  [\(dev.uid)]") }
        }
        return out.joined(separator: "\n")
    }

    /// One line per poll: raw in/out per platform and the verdict.
    static func summaryLine(_ r: ProbeReport) -> String {
        let d = r.diagnostics
        let parts = d.signals.map { s -> String in
            let f = d.flags.first { $0.platform == s.platform }
            var text = "\(s.platform.rawValue)[\(s.inCall ? "IN/\(s.confidence.rawValue)" : "no") in \(b(f?.rawInput ?? false))/\(b(f?.stableInput ?? false)) out \(b(f?.rawOutput ?? false))/\(b(f?.stableOutput ?? false))"
            if s.platform == .zoom { text += " udp \(d.zoomUDPSockets.map(String.init) ?? "n/a")\(d.zoomTier.map { " tier \($0)" } ?? "")" }
            if s.platform == .meet { text += " tab \(d.tabs.map { $0.chosenKey ?? $0.status } ?? "n/a")" }
            return text + "]"
        }
        return "\(time(r.time))  " + parts.joined(separator: " ")
    }

    /// Everything that can flip, as key -> value, so --watch can say exactly what changed.
    static func flatten(_ r: ProbeReport) -> [String: String] {
        var m: [String: String] = [:]
        let d = r.diagnostics
        for s in d.signals {
            m["\(s.platform.rawValue).inCall"] = b(s.inCall)
            m["\(s.platform.rawValue).confidence"] = s.confidence.rawValue
            if let k = s.meetingKey { m["\(s.platform.rawValue).meetingKey"] = k }
        }
        for f in d.flags {
            let p = f.platform.rawValue
            m["\(p).in.raw"] = b(f.rawInput)
            m["\(p).in.stable"] = b(f.stableInput)
            m["\(p).out.raw"] = b(f.rawOutput)
            m["\(p).out.stable"] = b(f.stableOutput)
        }
        for p in r.rows { m["pid \(p.pid) \(p.bundleID) (\(p.role))"] = "in=\(b(p.input)) out=\(b(p.output))" + (p.udpCounted.map { " udp=\($0)" } ?? "") }
        m["zoom.udp.main"] = d.zoomUDPSockets.map(String.init) ?? "n/a"
        m["zoom.tier"] = d.zoomTier ?? "none"
        for c in r.zoomChildren { m["zoom child \(c.pid) \(c.name)"] = "udp=\(c.udpCounted.map(String.init) ?? "n/a")" }
        if let n = r.teamsRelayConnected { m["teams.udp.relay-connected"] = String(n) }
        if let t = d.tabs {
            m["chrome.tabs.status"] = t.status
            m["chrome.meet.tabs"] = t.meetTabs.map { "\($0.kind.rawValue):\($0.key)" }.joined(separator: ",")
            m["chrome.meet.chosen"] = t.chosenKey ?? "none"
            // One entry per Meet tab, so a title / URL change of the post-call page (L-12) or a tab switch shows up as a flip.
            for tab in t.meetTabs {
                m["chrome.meet.tab w\(tab.windowID)/t\(tab.tabID)"] =
                    "\(tab.kind.rawValue) \(tab.url)\(tab.isFrontActive ? " front" : (tab.isActive ? " active" : "")) title=\(tab.title.map { "\"\($0)\"" } ?? "-")"
            }
        }
        for o in r.otherActive { m["other pid \(o.pid) \(o.bundleID)"] = "in=\(b(o.input)) out=\(b(o.output))" }
        for dev in r.devices { m["device \(dev.name)"] = "running=\(b(dev.runningSomewhere))" }
        return m
    }

    /// "key: old -> new" lines, sorted; a key that appears or disappears shows "-" on the missing side.
    static func flips(from old: [String: String], to new: [String: String]) -> [String] {
        var lines: [String] = []
        for key in Set(old.keys).union(new.keys).sorted() where old[key] != new[key] {
            lines.append("\(key): \(old[key] ?? "-") -> \(new[key] ?? "-")")
        }
        return lines
    }

    private static func fmt(_ v: TimeInterval) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

// MARK: - Entry point

private func optionValue(_ flag: String, in args: [String]) -> String? {
    for (i, a) in args.enumerated() {
        if a == flag, i + 1 < args.count, !args[i + 1].hasPrefix("--") { return args[i + 1] }
        if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
    }
    return nil
}

/// The config `probe` works with: ENABLED_PLATFORMS as configured, or every platform with `--all-platforms` (a one-off look
/// for diagnostics; it changes nothing on disk, and Chrome tab queries still follow TabQueryPolicy).
func probeConfig(_ config: AppConfig, args: [String]) -> AppConfig {
    guard args.contains("--all-platforms") else { return config }
    var all = config
    all.enabledPlatforms = ProbeRender.allPlatforms
    return all
}

func runProbe(config baseConfig: AppConfig, watch: Bool, json: Bool) -> Int32 {
    let args = CommandLine.arguments
    let config = probeConfig(baseConfig, args: args)
    let policy = TabQueryPolicy.current()
    let collector = ProbeCollector(config: config, policy: policy, alwaysQueryTabs: args.contains("--tabs-always"))

    if args.contains("--bench") {
        return runProbeBench(config: config, policy: policy, count: optionValue("--bench", in: args).flatMap { Int($0) } ?? 100)
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = watch ? [.sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    func emitJSON(_ report: ProbeReport) {
        if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) { print(text) }
    }

    guard watch else {
        let report = collector.collect()
        if json { emitJSON(report) } else { print(ProbeRender.table(report, config: config)) }
        return 0
    }

    // --watch: Ctrl-C ends it.
    signal(SIGINT) { _ in
        fflush(stdout)
        _exit(0)
    }
    let interval = max(0.2, optionValue("--interval", in: args).flatMap { Double($0) } ?? 1.0)
    // Safety net: a watch started through `open -a` cannot be stopped with Ctrl-C, so it ends by itself.
    let minutes = optionValue("--minutes", in: args).flatMap { Double($0) } ?? 90
    let deadline: Date? = minutes > 0 ? Date().addingTimeInterval(minutes * 60) : nil
    let color = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    func hot(_ text: String) -> String { color ? "\u{1B}[1;33m\(text)\u{1B}[0m" : ">>> \(text)" }
    func good(_ text: String) -> String { color ? "\u{1B}[1;32m\(text)\u{1B}[0m" : text }

    var previous: [String: String]?
    var lastPrinted = Date.distantPast
    var first = true
    while deadline.map({ Date() < $0 }) ?? true {
        let report = collector.collect()
        let flat = ProbeRender.flatten(report)
        if json {
            if previous != flat || report.time.timeIntervalSince(lastPrinted) >= 30 { emitJSON(report); lastPrinted = report.time }
        } else if first {
            print(ProbeRender.table(report, config: config))
            print("")
            print("watching every \(interval) s; a line is printed whenever something flips. in/out columns are raw/stable. Stop: Ctrl-C, or `pkill -f 'probe --watch'` if started through `open`; ends by itself after \(minutes > 0 ? "\(Int(minutes)) min" : "never").")
            lastPrinted = report.time
        } else if let old = previous, old != flat {
            let changes = ProbeRender.flips(from: old, to: flat)
            print(ProbeRender.summaryLine(report))
            for c in changes { print("    " + (c.contains("inCall") ? good(c) : hot(c))) }
            // Say why a platform flipped.
            for s in report.diagnostics.signals where old["\(s.platform.rawValue).inCall"] != flat["\(s.platform.rawValue).inCall"] {
                for e in s.evidence { print("      \(s.platform.rawValue): \(e)") }
            }
            lastPrinted = report.time
        } else if report.time.timeIntervalSince(lastPrinted) >= 30 {
            print("= " + ProbeRender.summaryLine(report) + String(format: "   (no change, poll %.1f ms)", report.diagnostics.pollMillis))
            lastPrinted = report.time
        }
        first = false
        previous = flat
        fflush(stdout)
        Thread.sleep(forTimeInterval: interval)
    }
    print("watch ended after \(Int(minutes)) minutes (--minutes 0 = no limit)")
    return 0
}

/// `probe --bench [N]`: how long poll() takes (first poll = cold caches, then steady state).
private func runProbeBench(config: AppConfig, policy: TabQueryPolicy, count: Int) -> Int32 {
    let detector = Detector(config: config, inputs: .live(config: config, policy: policy), zoomTier: ZoomTierSettings.current)
    func timeOnce() -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = detector.poll()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }
    let first = timeOnce()
    let samples = (0..<max(count, 1)).map { _ in timeOnce() }.sorted()
    func pct(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
    print(String(format: "poll() with the configured platforms, tab queries %@: first %.1f ms; steady state over %d polls: min %.2f  median %.2f  p95 %.2f  max %.2f ms",
                 policy.enabled ? "ENABLED" : "disabled", first, samples.count, samples[0], pct(0.5), pct(0.95), samples[samples.count - 1]))
    return 0
}
