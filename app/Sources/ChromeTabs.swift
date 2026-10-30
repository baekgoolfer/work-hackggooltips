import Foundation
import AppKit
import CoreServices   // AEDeterminePermissionToAutomateTarget

// =====================================================================================
// Google Meet tab detection (SPEC 13.1).
//
//   MeetURL            pure URL classifier: meeting code / Workspace nickname / lookup / other Meet page / not Meet
//   WebMeetingURL      (CallApps.swift) the same for the meeting pages of Whereby, Jitsi, Webex web, Teams web and the Zoom web client; only used when
//                      CALL_BROWSER_URLS is on, and it never matches Google Meet (Meet stays behind `meet` in ENABLED_PLATFORMS)
//   ChromeTab/parseTabs  tab list <- NSAppleEventDescriptor (pure, unit tested with synthetic descriptors)
//   Automation         Automation (Apple Events) permission state via AEDeterminePermissionToAutomateTarget
//   TabQueryPolicy     WHEN AppleScript may run at all (signed app launched by launchd / LaunchServices only; see below)
//   ChromeTabs         gate + cache in front of a ChromeBackend: never queries unless Chrome is running AND has
//                      audio IO AND the policy allows it AND Automation is already authorized. Cache 4 s (12 s once a
//                      call is established, 10 s after an error). `alwaysQuery` (probe --tabs-always only) skips the
//                      audio gate, nothing else.
//   LiveChromeBackend  NSRunningApplication / AE permission check / NSAppleScript on ONE dedicated serial queue
//                      (`with timeout of 3 seconds`, outer wait 5 s, never more than one query in flight)
//   MeetTabChooser     picks "the" Meet tab when several are open. Tabs are tracked by identity (window id + tab id),
//                      not by meeting code; a newly opened tab only takes over after it has been the front tab for the
//                      debounce time (so a second Meet tab in a lobby does not split a running call at once)
//   requestChromeAutomationPermission()   the only place that may show the macOS Automation prompt (from `setup`)
//
// SAFETY (SPEC 10, 14.4): AppleScript against the user's Chrome shows an Automation prompt for whatever app is the
// responsible process. So `TabQueryPolicy` only enables queries when `LaunchGuard.isSignedAppLaunch` (Types.swift):
// the bundle id is the app's own (AppInfo.bundleID) AND the process was started by launchd / LaunchServices (ppid 1, or
// __CFBundleIdentifier == the bundle id: the LaunchAgent, `open -a`, `open -n -a`). Exec'ing the in-bundle binary from
// a shell passes the bundle id test but not the launch test, so it can never run AppleScript or raise the Automation
// prompt. The only other way in is a deliberate manual diagnostic: `--tabs` AND MC_ALLOW_APPLESCRIPT=1. In every other
// context (agent shell, selftests) the live backend is never touched and the Meet rule falls back to the
// Automation-denied path (LOW confidence, chrome input AND output).
// =====================================================================================

// MARK: - URL classification (pure)

enum MeetURL {
    enum Kind: Equatable {
        case meeting(code: String)      // https://meet.google.com/abc-defg-hij[?...]
        case lookup                     // /lookup/<id>: Calendar redirect, transient
        case nonMeeting(String)         // landing, new, home (""), whoops, _meet, ... or a Workspace nickname (first path segment)
        case notMeet
    }

    /// Meet pages that are never a call (the first path segment).
    static let nonMeetingPaths: Set<String> = ["landing", "new", "lookup", "whoops", "_meet", "linkredirect", "tel",
                                               "calling", "u", "about", "check", ""]

    static func classify(_ url: String) -> Kind {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact host match: meet.google.com.evil.com must not match.
        guard let comps = URLComponents(string: trimmed),
              comps.scheme?.lowercased() == "https",
              comps.host?.lowercased() == "meet.google.com" else { return .notMeet }
        let segment = comps.path.split(separator: "/", omittingEmptySubsequences: true).first.map { String($0).lowercased() } ?? ""
        if segment.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: .regularExpression) != nil { return .meeting(code: segment) }
        if segment == "lookup" { return .lookup }
        return .nonMeeting(segment)
    }

    /// Workspace "meeting nicknames" look like meet.google.com/<slug>: an unknown single slug is a weak candidate.
    static func isNicknameCandidate(_ segment: String) -> Bool {
        guard !nonMeetingPaths.contains(segment) else { return false }
        return segment.range(of: "^[a-z0-9][a-z0-9_-]{2,62}$", options: .regularExpression) != nil
    }
}

// MARK: - Tabs

/// Chrome's own identity of a tab: the window id and the tab id (both text in Chrome's scripting dictionary).
struct TabIdentity: Hashable, Codable {
    var windowID: String
    var tabID: String
}

struct ChromeTab: Equatable {
    var windowID: String
    var isActive: Bool              // the active tab of ITS window (not necessarily of the front window)
    var url: String
    var title: String
    var incognito: Bool
    var tabID: String = ""          // Chrome's tab id; parseTabs never leaves it empty ("#<position>" when Chrome gave none)
    var windowOrder: Int = 0        // 0 = front window (Chrome `index of window` 1), 1 = the next one back, ...
}

/// A Chrome tab on a meeting page of the web meeting table (CallApps.swift, CALL_BROWSER_URLS). Only the site and the tab identity are kept: not the
/// address (a room name can be private) and not the title.
struct WebMeetingTab: Codable, Equatable {
    var siteID: String          // "whereby", "jitsi", "webex", "teams-web", "zoom-web"
    var name: String            // "Whereby", "Teams (web)", ...
    var isActive: Bool          // the active tab of its window
    var windowID: String = ""
    var tabID: String = ""
    var windowOrder: Int = 0    // 0 = front window

    var isFrontActive: Bool { isActive && windowOrder == 0 }
}

/// A tab on meet.google.com. Only these are ever kept or printed: URLs and titles of other tabs are dropped at once.
struct MeetTab: Codable, Equatable {
    enum Kind: String, Codable { case code, nickname, lookup, other }
    var kind: Kind
    var key: String             // meeting code, nickname slug, or the other page's first path segment
    var url: String             // https://meet.google.com/<key>  (query and fragment removed)
    var title: String?
    var isActive: Bool          // the active tab of its window
    var incognito: Bool
    var windowID: String = ""
    var tabID: String = ""
    var windowOrder: Int = 0    // 0 = front window

    var isCandidate: Bool { kind == .code || kind == .nickname }
    /// The tab the user is looking at in Chrome's front window.
    var isFrontActive: Bool { isActive && windowOrder == 0 }
    /// Identity of the tab itself, independent of the meeting code (the same code can be open in several tabs).
    var identity: TabIdentity { TabIdentity(windowID: windowID, tabID: tabID.isEmpty ? "code:\(key)" : tabID) }
}

enum ChromeTabParsing {
    /// `{windowID, activeTabIndex, urls, titles, mode, tabIDs, windowIndex}` per window, as returned by the tabs script.
    /// The last two items are optional (an older five-item shape still parses; ids then fall back to the tab position).
    static func parseTabs(_ d: NSAppleEventDescriptor) -> [ChromeTab] {
        var tabs: [ChromeTab] = []
        guard d.numberOfItems > 0 else { return tabs }
        for i in 1...d.numberOfItems {
            guard let w = d.atIndex(i), w.numberOfItems >= 5 else { continue }
            let windowID = w.atIndex(1)?.stringValue ?? ""
            let activeIndex = Int(w.atIndex(2)?.int32Value ?? 0)
            let urls = w.atIndex(3)
            let titles = w.atIndex(4)
            let incognito = (w.atIndex(5)?.stringValue ?? "normal").lowercased() == "incognito"
            let ids = w.numberOfItems >= 6 ? w.atIndex(6) : nil
            let frontToBack = w.numberOfItems >= 7 ? Int(w.atIndex(7)?.int32Value ?? 0) : 0
            let order = frontToBack > 0 ? frontToBack - 1 : i - 1          // Chrome's index is 1-based; else list position
            let n = urls?.numberOfItems ?? 0
            guard n > 0 else { continue }
            for t in 1...n {
                let id = (ids?.numberOfItems ?? 0) >= t ? (ids?.atIndex(t)?.stringValue ?? "") : ""
                tabs.append(ChromeTab(windowID: windowID,
                                      isActive: t == activeIndex,
                                      url: urls?.atIndex(t)?.stringValue ?? "",
                                      title: (titles?.numberOfItems ?? 0) >= t ? (titles?.atIndex(t)?.stringValue ?? "") : "",
                                      incognito: incognito,
                                      tabID: id.isEmpty ? "#\(t)" : id,
                                      windowOrder: order))
            }
        }
        return tabs
    }

    /// The tabs on a meeting page of the web meeting table (CALL_BROWSER_URLS), reduced to the site and the tab identity; everything else is discarded.
    static func webMeetingTabs(in tabs: [ChromeTab]) -> [WebMeetingTab] {
        return tabs.compactMap { tab -> WebMeetingTab? in
            guard let match = WebMeetingURL.classify(tab.url) else { return nil }
            return WebMeetingTab(siteID: match.siteID, name: match.name, isActive: tab.isActive, windowID: tab.windowID, tabID: tab.tabID, windowOrder: tab.windowOrder)
        }
    }

    /// All tabs on meet.google.com, classified; everything else is discarded.
    static func meetHostTabs(in tabs: [ChromeTab]) -> [MeetTab] {
        return tabs.compactMap { tab -> MeetTab? in
            let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            func make(_ kind: MeetTab.Kind, _ key: String) -> MeetTab {
                return MeetTab(kind: kind, key: key, url: "https://meet.google.com/\(key)",
                               title: title.isEmpty ? nil : title, isActive: tab.isActive, incognito: tab.incognito,
                               windowID: tab.windowID, tabID: tab.tabID, windowOrder: tab.windowOrder)
            }
            switch MeetURL.classify(tab.url) {
            case .notMeet: return nil
            case .meeting(let code): return make(.code, code)
            case .lookup: return make(.other, "lookup")
            case .nonMeeting(let segment):
                return make(MeetURL.isNicknameCandidate(segment) ? .nickname : .other, segment)
            }
        }
    }
}

// MARK: - Automation permission state (never prompts unless asked to)

enum AutomationState: Equatable {
    case authorized
    case denied                     // errAEEventNotPermitted (-1743)
    case notAsked                   // errAEEventWouldRequireUserConsent (-1744): `setup` has not been run
    case targetNotRunning           // procNotFound (-600)
    case other(OSStatus)
}

enum Automation {
    /// With `askUser: false` this reads the state without showing a prompt and without launching the target (a
    /// target that is not running yields procNotFound). Only `requestChromeAutomationPermission()` passes true.
    static func state(forBundleID bundleID: String, askUser: Bool) -> AutomationState {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBufferPointer { p -> OSErr in
            AECreateDesc(DescType(typeApplicationBundleID), p.baseAddress, p.count, &target)
        }
        guard created == noErr else { return .other(OSStatus(created)) }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
        switch status {
        case noErr: return .authorized
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .other(status)
        }
    }
}

// MARK: - Policy: when may AppleScript run at all?

struct TabQueryPolicy: Equatable {
    var enabled: Bool
    var reason: String

    /// `signedAppLaunch` is `LaunchGuard.isSignedAppLaunch` (bundle id AND started by launchd / LaunchServices); it is a
    /// parameter so the self test can inject both values. A bundle id alone is NOT enough (see the header).
    /// - signed app launch: enabled
    /// - anything else (terminal, agent shell, an in-bundle binary exec'd from a shell, scratch builds): disabled, unless
    ///   BOTH `--tabs` is passed and the environment variable MC_ALLOW_APPLESCRIPT=1 is set (a deliberate manual diagnostic).
    static func resolve(signedAppLaunch: Bool, args: [String], env: [String: String]) -> TabQueryPolicy {
        if signedAppLaunch {
            return TabQueryPolicy(enabled: true, reason: "running as \(AppInfo.shortName).app, started by launchd / LaunchServices")
        }
        if args.contains("--tabs"), env["MC_ALLOW_APPLESCRIPT"] == "1" {
            return TabQueryPolicy(enabled: true, reason: "explicit --tabs with MC_ALLOW_APPLESCRIPT=1 (Automation prompt goes to the calling app)")
        }
        return TabQueryPolicy(enabled: false,
                              reason: "tab queries are disabled unless \(AppInfo.shortName).app was started by launchd / LaunchServices (the LaunchAgent, or `open -n -a`); a shell would get the Automation prompt. Run via `open -n -W -a ~/Applications/\(AppInfo.shortName).app --args probe ...`, or pass --tabs together with MC_ALLOW_APPLESCRIPT=1")
    }

    static func current() -> TabQueryPolicy {
        return resolve(signedAppLaunch: LaunchGuard.isSignedAppLaunch, args: CommandLine.arguments, env: ProcessInfo.processInfo.environment)
    }

    /// May a function that can show the Automation prompt run in this process? Only a signed app launch, or the
    /// developer override MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY=1 (same override as the capture permission helper).
    static func promptAllowed(signedAppLaunch: Bool, env: [String: String]) -> Bool {
        return signedAppLaunch || env["MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY"] == "1"
    }

    /// nil = this process may show the Automation prompt, otherwise the status string `requestChromeAutomationPermission()`
    /// returns. Pure, so the self test can check the decision without ever calling the function that can prompt.
    static func promptRefusal(signedAppLaunch: Bool, env: [String: String]) -> String? {
        guard !promptAllowed(signedAppLaunch: signedAppLaunch, env: env) else { return nil }
        return "refused: not running as \(AppInfo.shortName).app started by launchd / LaunchServices (use open -n -W -a ~/Applications/\(AppInfo.shortName).app --args setup)"
    }
}

// MARK: - Query result model

enum TabsStatus: Equatable {
    case disabled(String)           // policy: no AppleScript in this context
    case unsupported(String)        // BROWSER_BUNDLE_IDS has no Google Chrome entry
    case idle                       // not queried: Chrome has no audio IO
    case chromeNotRunning
    case notAsked                   // Automation permission still undecided (run setup)
    case denied                     // Automation permission refused
    case error(String)              // timeout / script error
    case ok

    var isOK: Bool { if case .ok = self { return true } else { return false } }

    var label: String {
        switch self {
        case .disabled: return "disabled"
        case .unsupported: return "unsupported"
        case .idle: return "idle"
        case .chromeNotRunning: return "chrome-not-running"
        case .notAsked: return "automation-not-asked"
        case .denied: return "automation-denied"
        case .error: return "error"
        case .ok: return "ok"
        }
    }

    var detail: String {
        switch self {
        case .disabled(let s), .unsupported(let s), .error(let s): return s
        case .idle: return "not queried: Chrome has no audio IO"
        case .chromeNotRunning: return "Chrome is not running (a query would launch it, so none is made)"
        case .notAsked: return "Automation permission for Chrome not decided yet: run `\(AppInfo.shortName) setup` from the app"
        case .denied: return "Automation permission for Chrome was denied (System Settings > Privacy & Security > Automation)"
        case .ok: return "tabs read"
        }
    }
}

struct TabsInfo {
    var status: TabsStatus
    var meetHostTabs: [MeetTab] = []        // every meet.google.com tab, classified (empty unless Meet is enabled)
    var webTabs: [WebMeetingTab] = []       // the tabs of the web meeting table (empty unless CALL_BROWSER_URLS is on)
    var totalTabs = 0
    var queriedAt: Date? = nil
    var fromCache = false

    var candidates: [MeetTab] { meetHostTabs.filter { $0.isCandidate } }

    /// Short text for the evidence list.
    func summary(chosen: MeetTab?) -> String {
        switch status {
        case .ok:
            let list = candidates.map { ($0.identity == chosen?.identity ? "*" : "") + $0.key }.joined(separator: ",")
            return "ok tabs=\(totalTabs) meet=[\(list)]"
        case .error(let message): return "error(\(message))"
        default: return status.label
        }
    }
}

enum TabQueryResult {
    case ok([ChromeTab])
    case noPermission
    case notRunning
    case error(Int, String)
}

// MARK: - Backend (the only code that talks to Chrome)

protocol ChromeBackend: AnyObject {
    func isRunning(bundleID: String) -> Bool
    func automationState(bundleID: String) -> AutomationState
    /// Blocking, at most a few seconds. Never throws.
    func listTabs(bundleID: String) -> TabQueryResult
}

private final class ResultBox<T> {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { value = initial }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

final class LiveChromeBackend: ChromeBackend {
    /// The ONE queue NSAppleScript is ever used on.
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).chrome-tabs")
    private let lock = NSLock()
    private var inFlight = false

    func isRunning(bundleID: String) -> Bool {
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func automationState(bundleID: String) -> AutomationState {
        return Automation.state(forBundleID: bundleID, askUser: false)
    }

    func listTabs(bundleID: String) -> TabQueryResult {
        lock.lock()
        if inFlight {
            lock.unlock()
            return .error(-2, "previous tab query is still running")
        }
        inFlight = true
        lock.unlock()

        let box = ResultBox<TabQueryResult>(.error(-3, "no result"))
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            box.set(runScript(bundleID: bundleID))
            lock.lock(); inFlight = false; lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut { return .error(-3, "tab query timed out after 5 s") }
        return box.get()
    }

    private func runScript(bundleID: String) -> TabQueryResult {
        guard let source = ChromeTabs.tabsScript(bundleID: bundleID), let script = NSAppleScript(source: source) else {
            return .error(-1, "cannot build tab script for \(bundleID)")
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let e = info {
            let code = (e[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { return .noPermission }                       // errAEEventNotPermitted
            if code == -600 { return .notRunning }                          // procNotFound
            return .error(code, (e[NSAppleScript.errorMessage] as? String) ?? "script error")
        }
        return .ok(ChromeTabParsing.parseTabs(result))
    }
}

// MARK: - ChromeTabs: gate + cache

final class ChromeTabs {
    static let defaultBundleID = "com.google.Chrome"
    /// Refresh interval for the tab list while looking for a call.
    static let cacheSeconds: TimeInterval = 4
    /// Refresh interval once a Meet call is established (fewer Apple Events into the user's Chrome during an hour-long call).
    static let steadyCacheSeconds: TimeInterval = 12
    static let errorCacheSeconds: TimeInterval = 10

    private let policy: TabQueryPolicy
    private let backend: ChromeBackend
    /// `probe --tabs-always` only: query the tab list even while Chrome has no audio IO (so the post-call page and the
    /// return-to-home page can be observed, live-test rows L-12 / L-13). Every other gate stays in place, including the
    /// policy: without a signed app launch (or --tabs + MC_ALLOW_APPLESCRIPT=1) this changes nothing. The production
    /// Detector never sets it.
    private let alwaysQuery: Bool
    /// Keep the tabs on meet.google.com (Meet is enabled) / match the web meeting table (CALL_BROWSER_URLS). With both off the tab list is read and
    /// dropped: nothing about any tab is kept. A Chrome that is queried for the web table only never hands Google Meet tabs to anyone.
    private let keepMeetTabs: Bool
    private let matchWebMeetings: Bool
    /// Chrome bundle id to talk to (first com.google.Chrome* entry of BROWSER_BUNDLE_IDS); nil = no Chrome configured.
    let bundleID: String?
    private var cache: (info: TabsInfo, at: Date, ttl: TimeInterval)?

    init(policy: TabQueryPolicy, browserBundleIDs: [String], backend: ChromeBackend = LiveChromeBackend(), alwaysQuery: Bool = false,
         keepMeetTabs: Bool = true, matchWebMeetings: Bool = false) {
        self.policy = policy
        self.backend = backend
        self.alwaysQuery = alwaysQuery
        self.keepMeetTabs = keepMeetTabs
        self.matchWebMeetings = matchWebMeetings
        self.bundleID = browserBundleIDs.first { $0.lowercased().hasPrefix("com.google.chrome") }
    }

    /// Safe to call every poll. Order of the gates (each one avoids touching Chrome):
    /// policy -> Chrome configured -> Chrome audio IO (unless `alwaysQuery`) -> cache -> Chrome running -> Automation already granted.
    func info(audioActive: Bool, now: Date, maxAge: TimeInterval = ChromeTabs.cacheSeconds) -> TabsInfo {
        guard policy.enabled else { return TabsInfo(status: .disabled(policy.reason)) }
        guard let bid = bundleID else {
            return TabsInfo(status: .unsupported("BROWSER_BUNDLE_IDS has no Google Chrome entry; tab queries are only implemented for Chrome"))
        }
        guard audioActive || alwaysQuery else { return TabsInfo(status: .idle) }
        if let c = cache, now >= c.at, now.timeIntervalSince(c.at) < (c.info.status.isOK ? min(maxAge, Self.steadyCacheSeconds) : c.ttl) {
            var cached = c.info
            cached.fromCache = true
            return cached
        }
        // A `tell application` would LAUNCH Chrome: verify it is running first.
        guard backend.isRunning(bundleID: bid) else {
            cache = nil
            return TabsInfo(status: .chromeNotRunning)
        }
        switch backend.automationState(bundleID: bid) {
        case .authorized: break
        case .denied: return store(TabsInfo(status: .denied, queriedAt: now), now: now, ttl: Self.cacheSeconds)
        case .notAsked: return store(TabsInfo(status: .notAsked, queriedAt: now), now: now, ttl: Self.cacheSeconds)
        case .targetNotRunning:
            cache = nil
            return TabsInfo(status: .chromeNotRunning)
        case .other(let code):
            return store(TabsInfo(status: .error("automation state check failed (OSStatus \(code))"), queriedAt: now),
                         now: now, ttl: Self.errorCacheSeconds)
        }
        switch backend.listTabs(bundleID: bid) {
        case .ok(let tabs):
            return store(TabsInfo(status: .ok, meetHostTabs: keepMeetTabs ? ChromeTabParsing.meetHostTabs(in: tabs) : [],
                                  webTabs: matchWebMeetings ? ChromeTabParsing.webMeetingTabs(in: tabs) : [],
                                  totalTabs: tabs.count, queriedAt: now), now: now, ttl: Self.steadyCacheSeconds)
        case .noPermission:
            return store(TabsInfo(status: .denied, queriedAt: now), now: now, ttl: Self.cacheSeconds)
        case .notRunning:
            cache = nil
            return TabsInfo(status: .chromeNotRunning)
        case .error(let code, let message):
            return store(TabsInfo(status: .error("\(message) (\(code))"), queriedAt: now), now: now, ttl: Self.errorCacheSeconds)
        }
    }

    private func store(_ info: TabsInfo, now: Date, ttl: TimeInterval) -> TabsInfo {
        cache = (info, now, ttl)
        return info
    }

    /// Reads only window id / index / mode and per tab: id, URL, title, so "Allow JavaScript from Apple Events" is NOT
    /// needed. The result per window is `{window id, active tab index, URLs, titles, mode, tab ids, window index}`
    /// (ChromeTabParsing.parseTabs). A window that cannot be read (closed meanwhile) is skipped, and the tab ids / window
    /// index fall back to `{}` / 0 (parseTabs then uses positions), but a TIMEOUT (-1712) is always re-raised so a hung
    /// Chrome fails the whole query instead of returning a partial list that reads as "no Meet tab".
    /// The bundle id is restricted to a safe alphabet because it is pasted into the script text.
    static func tabsScript(bundleID: String) -> String? {
        guard !bundleID.isEmpty, bundleID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        return """
        with timeout of 3 seconds
          tell application id "\(bundleID)"
            set out to {}
            repeat with w in windows
              try
                set winID to (id of w) as text
                set activeIdx to (active tab index of w)
                set theURLs to (URL of every tab of w)
                set theTitles to (title of every tab of w)
                set theMode to (mode of w) as text
                set tabIdList to {}
                set winIdx to 0
                try
                  set tabIdList to (id of every tab of w)
                  set winIdx to (index of w)
                on error errText number errNum
                  if errNum is -1712 then error errText number errNum
                end try
                set end of out to {winID, activeIdx, theURLs, theTitles, theMode, tabIdList, winIdx}
              on error errText number errNum
                if errNum is -1712 then error errText number errNum
              end try
            end repeat
            return out
          end tell
        end timeout
        """
    }
}

// MARK: - Choosing the Meet tab

/// Several Meet tabs can be open (a stale post-call page, the next meeting's lobby, the same recurring code twice).
/// Chrome gives no per-tab audio state, so the choice is made from tab IDENTITY (window id + tab id), never from the
/// meeting code alone:
///
///   - first sight (nothing chosen yet, or the state was forgotten): meeting codes before nicknames, then the active tab
///     of Chrome's FRONT window, then any window's active tab, then window order, then tab order;
///   - afterwards the choice is STICKY: the chosen tab stays chosen while it is open, and the meeting code it carries
///     is what the state machine follows. Only a tab that was opened after the choice was made (or that was chosen
///     before) can take over, and only after it has been the front window's active tab in observations at least
///     `acceptAfter` (the start debounce) apart. A background tab, a stale post-call page, or an old tab nobody
///     chose never takes over. That is what keeps a second Meet tab in a lobby from splitting a call at once;
///   - when the chosen tab is closed, a tab with the SAME meeting code wins (closing a stale duplicate cannot change the
///     code), otherwise the first-sight ranking runs again over what is left;
///   - the state is forgotten (`forget()`) by the detector once Chrome has had no audio for about a grace period: the
///     session is over, the next call is a first sight again;
///
/// An observation is one tab-list query (`observedAt` = its time, not the poll time): the detector polls more often than
/// the list is refreshed, and focus is only ever timed between observations, never from a cached answer. Feeding the same
/// observation again changes nothing.
final class MeetTabChooser {
    private struct Record {
        var late: Bool                  // first seen while a call tab was already chosen = a newly opened tab
        var wasChosen = false
        var frontSince: Date?           // front window's active tab since (first observation of the current run)
    }

    let acceptAfter: TimeInterval
    private var records: [TabIdentity: Record] = [:]
    private var chosen: TabIdentity?
    private var chosenKey: String?
    /// True while a tab that could take over is the front tab and is being timed: the detector then refreshes the tab
    /// list at the fast rate instead of the steady rate so the decision does not wait 12 s per observation.
    private(set) var takeoverPending = false

    init(acceptAfter: TimeInterval = 4) {
        self.acceptAfter = max(0, acceptAfter)
    }

    func choose(from candidates: [MeetTab], observedAt now: Date) -> MeetTab? {
        guard !candidates.isEmpty else {
            forget()
            return nil
        }

        let present = Set(candidates.map { $0.identity })
        let established = chosen != nil
        records = records.filter { present.contains($0.key) }
        for tab in candidates {
            var r = records[tab.identity] ?? Record(late: established)
            if tab.isFrontActive { r.frontSince = min(r.frontSince ?? now, now) } else { r.frontSince = nil }
            records[tab.identity] = r
        }

        if let id = chosen, let current = candidates.first(where: { $0.identity == id }) {
            let challenger = candidates.first { tab in
                guard tab.identity != id, canTakeOver(tab), let since = records[tab.identity]?.frontSince,
                      now.timeIntervalSince(since) >= acceptAfter else { return false }
                return tab.kind == .code || current.kind != .code       // a nickname never replaces a meeting code
            }
            if let challenger = challenger { select(challenger) }
        } else if let best = bestFirstSight(candidates) {
            select(best)
        }
        takeoverPending = candidates.contains { $0.identity != chosen && canTakeOver($0) && records[$0.identity]?.frontSince != nil }
        return candidates.first { $0.identity == chosen }
    }

    /// Forget everything: the next observation is a first sight again.
    func forget() {
        records = [:]
        chosen = nil
        chosenKey = nil
        takeoverPending = false
    }

    private func canTakeOver(_ tab: MeetTab) -> Bool {
        guard let r = records[tab.identity] else { return false }
        return r.late || r.wasChosen
    }

    private func select(_ tab: MeetTab) {
        chosen = tab.identity
        chosenKey = tab.key
        records[tab.identity]?.wasChosen = true
    }

    private func bestFirstSight(_ candidates: [MeetTab]) -> MeetTab? {
        let previousKey = chosenKey
        return candidates.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.kind != y.kind { return x.kind == .code }
            if (x.key == previousKey) != (y.key == previousKey) { return x.key == previousKey }   // the meeting we were in
            if x.isFrontActive != y.isFrontActive { return x.isFrontActive }
            if x.isActive != y.isActive { return x.isActive }
            if x.windowOrder != y.windowOrder { return x.windowOrder < y.windowOrder }
            return a.offset < b.offset
        }.first?.element
    }
}

// MARK: - Setup: the only function that may show the Automation prompt

/// Returns exactly "authorized", "denied: <how to fix>", "not-running: open Google Chrome and re-run setup", or
/// "refused: ..." (this process was not started as the signed app by launchd / LaunchServices). May block while the
/// macOS prompt is on screen, so call it from a background thread (the setup command does). Refuses unless
/// `LaunchGuard.isSignedAppLaunch` (or MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY=1), so an agent shell can never raise the
/// prompt by accident, not even by exec'ing the binary inside the app bundle.
///
/// The four parameters are test seams with production defaults (the only caller, Setup.swift, passes none): the self test
/// injects `signedAppLaunch: false` and a recording `automation` closure to prove that a closed guard returns before the
/// Apple Event permission call is ever made, and a fake answer per AutomationState to check the returned strings.
func requestChromeAutomationPermission(
    signedAppLaunch: Bool = LaunchGuard.isSignedAppLaunch,
    env: [String: String] = ProcessInfo.processInfo.environment,
    chromeRunning: () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: ChromeTabs.defaultBundleID).isEmpty },
    automation: (_ bundleID: String, _ askUser: Bool) -> AutomationState = { Automation.state(forBundleID: $0, askUser: $1) }
) -> String {
    if let refusal = TabQueryPolicy.promptRefusal(signedAppLaunch: signedAppLaunch, env: env) {
        return refusal
    }
    let bundleID = ChromeTabs.defaultBundleID
    guard chromeRunning() else {
        return "not-running: open Google Chrome and re-run setup"
    }
    switch automation(bundleID, true) {
    case .authorized:
        Log.info("chrome automation: authorized")
        return "authorized"
    case .denied:
        Log.warn("chrome automation: denied")
        return "denied: Automation permission for Google Chrome was refused (System Settings > Privacy & Security > Automation > \(AppInfo.displayName) > Google Chrome)"
    case .notAsked:
        return "denied: the Automation prompt was not answered (run setup again and click OK)"
    case .targetNotRunning:
        return "not-running: open Google Chrome and re-run setup"
    case .other(let status):
        Log.warn("chrome automation: AEDeterminePermissionToAutomateTarget returned OSStatus \(status)")
        return "denied: AEDeterminePermissionToAutomateTarget returned OSStatus \(status)"
    }
}
