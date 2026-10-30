import Foundation
import AppKit
import Darwin

// =====================================================================================
// Calls of other apps (docs/DETECTION.md section 3b): everything beyond Zoom, Teams and Google Meet.
//
//   CallApps             the built-in table of known call apps (bundle id + name + where the id comes from), the deny list of the generic rule,
//                        the helper -> main app mapping ("<app>.helper.Renderer" belongs to "<app>"), display names
//   ExtraMeetingApps     EXTRA_MEETING_APPS parsing (garbage, duplicates, huge values) into more known apps
//   WebMeetingURL        the table of meeting pages in a browser tab (Whereby, Jitsi, Webex web, Teams web launcher, Zoom web client); never Google Meet
//   CallAppStore         SUPPORT_DIR/call-apps.json: the decision per bundle id (allowed / denied; `web:<site>` for a meeting page), 0600, no titles;
//                        fails closed (an unreadable file pauses every call of another app, an unknown decision word reads as denied)
//   CallTracker          per app: input / output smoothing (the same HysteresisFlag as Zoom and Teams), the start rule, the keep rule, one PlatformSignal
//                        per app (platform .call); the DetectionStateMachine then debounces and keeps them like any other platform
//   LiveCallAppInfo      NSRunningApplication: the name of an app and whether it is a GUI app (the generic rule only guesses GUI apps)
//
// The rule, per app (main bundle id; the helper processes of an app are folded into it):
//   known / EXTRA_MEETING_APPS / browser meeting tab   start: smoothed input AND smoothed output           (the output needs 7 s, the input 1.5 s)
//   generic (CALL_DETECT=generic)                      start: input AND output held together for CALL_GENERIC_SECONDS (45), any gap of 3 s ends it
//   known / extra / web                                keep : smoothed input OR output (a muted microphone that the app closes does not end the call;
//                                                      the grace period of the state machine, at least 30 s, covers the rest)
//   generic                                            keep : smoothed input, or output for at most `genericOutputKeepSeconds` (120) after the input was last on (a mute that
//                                                      closes the microphone); output alone for longer never keeps a guessed call (a game's or a player's sound)
// Output alone never starts anything, and neither does input alone. Nothing here starts a recording: the DetectionStateMachine, the controller and the
// recorder do, exactly as for Zoom.
// =====================================================================================

// MARK: - Known apps

struct KnownCallApp: Equatable {
    /// Where the bundle id comes from (docs/DETECTION.md section 3b, "verified"). Nothing about the app's audio behaviour is verified for any of them.
    enum Source: String, Equatable {
        case installed = "read from an app installed on the reference Mac"
        case listing = "from a public app listing (Info.plist excerpt or MDM catalog)"
    }
    var id: String
    var name: String
    var source: Source
}

enum CallApps {
    /// The built-in table. Only ids that could be read from an installed app or from a public listing are in it; everything else goes through
    /// EXTRA_MEETING_APPS. A helper process of an app ("<id>.helper", "<id>.helper.Renderer", ...) belongs to the app: the match is the id or `<id>.`.
    /// Naver Works is not here: no public source for its bundle id could be found.
    static let known: [KnownCallApp] = [
        KnownCallApp(id: "Cisco-Systems.Spark", name: "Cisco Webex", source: .listing),
        KnownCallApp(id: "com.tinyspeck.slackmacgap", name: "Slack huddle", source: .installed),
        KnownCallApp(id: "com.hnc.Discord", name: "Discord", source: .listing),
        KnownCallApp(id: "com.apple.FaceTime", name: "FaceTime", source: .installed),
        KnownCallApp(id: "com.skype.s4l", name: "Skype", source: .listing),
        KnownCallApp(id: "com.microsoft.SkypeForBusiness", name: "Skype for Business", source: .listing),
        KnownCallApp(id: "com.logmein.goto", name: "GoTo", source: .listing),
        KnownCallApp(id: "com.amazon.Amazon-Chime", name: "Amazon Chime", source: .listing),
        KnownCallApp(id: "com.bluejeansnet.Blue", name: "BlueJeans", source: .listing),
        KnownCallApp(id: "com.electron.lark", name: "Lark / Feishu", source: .listing),
        KnownCallApp(id: "com.larksuite.larkApp", name: "Lark", source: .listing),
        KnownCallApp(id: "com.kakao.KakaoTalkMac", name: "KakaoTalk", source: .installed),
        KnownCallApp(id: "net.whatsapp.WhatsApp", name: "WhatsApp", source: .installed),
        KnownCallApp(id: "com.jandi.osx.JANDI", name: "JANDI", source: .listing),
    ]

    private static let knownLower: [(id: String, app: KnownCallApp)] = known.map { ($0.id.lowercased(), $0) }

    /// The known app a Core Audio bundle id belongs to (the id itself or one of its helpers), nil for anything else. Case-insensitive.
    static func known(forBundle bundleID: String) -> KnownCallApp? {
        let b = bundleID.lowercased()
        return knownLower.first { b == $0.id || b.hasPrefix($0.id + ".") }?.app
    }

    /// Browsers: never an app of the generic rule, never an EXTRA_MEETING_APPS entry (Chrome's audio belongs to Google Meet / the web meeting table).
    /// Each entry is a bundle id root: the id itself or `<root>.` ...; an entry ending in `*` is a plain prefix.
    static let browserRoots: [String] = [
        "com.google.chrome*", "org.mozilla", "com.microsoft.edgemac*", "com.brave.browser*", "company.thebrowser.browser*", "com.operasoftware",
        "com.vivaldi.vivaldi*", "org.chromium.chromium*", "com.duckduckgo.macos.browser*", "org.torproject", "com.apple.safari", "com.apple.webkit",
    ]

    /// The built-in deny list of the generic rule (never applies to a known app or an EXTRA_MEETING_APPS entry: they are named on purpose). Same notation as
    /// `browserRoots`. Categories: this app; the platforms that have their own detector; Apple's own apps and system processes (FaceTime is in the known
    /// table, which is looked at first); media players, music and podcasts; screen and audio recorders; dictation and speech tools; voice assistants;
    /// audio production and routing; terminals; IDEs.
    static let denyRoots: [String] = [
        // this app, the platforms with their own detectors
        FamilyMatcher.ownBundlePrefix, "us.zoom", "com.microsoft.teams*",
        // Apple: Music, Podcasts, TV, QuickTime, Voice Memos, Safari / WebKit, Siri and dictation, Terminal, Xcode, GarageBand, Logic ... and every system process
        "com.apple",
        // media players, music
        "org.videolan.vlc", "com.colliderli.iina", "io.mpv", "com.movist", "com.spotify.client", "com.plexapp", "tv.plex", "com.tidal",
        // screen and audio recorders
        "com.obsproject.obs-studio", "com.wulkano.kap", "pl.maketheweb.cleanshotx", "com.loom.desktop", "com.telestream", "com.techsmith",
        "com.timpler.screenstudio",
        // dictation, speech to text
        "com.nuance", "com.goodsnooze.macwhisper", "com.talonvoice",
        // voice assistants (voice mode holds the microphone and plays sound, and is not a call)
        "com.anthropic.claudefordesktop", "com.openai", "com.google.geminimacos",
        // audio production and routing
        "com.ableton.live", "org.audacityteam.audacity", "com.cockos.reaper", "com.avid", "com.rogueamoeba", "com.existentialaudio",
        // terminals
        "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
        "com.github.wez.wezterm",
        // IDEs and editors
        "com.microsoft.vscode*", "com.jetbrains", "com.todesktop.230313mzl4w4u92", "dev.zed.zed*", "com.sublimetext.4", "com.sublimetext.3",
        "com.visualstudio.code.oss", "org.vim.macvim",
    ]

    private static func matches(_ lowerBundle: String, root: String) -> Bool {
        if root.hasSuffix("*") { return lowerBundle.hasPrefix(String(root.dropLast())) }
        return lowerBundle == root || lowerBundle.hasPrefix(root + ".")
    }

    /// `extraBrowserPrefixes` = BROWSER_BUNDLE_IDS (plain prefixes, like `FamilyMatcher`).
    static func isBrowser(_ bundleID: String, extraBrowserPrefixes: [String] = []) -> Bool {
        let b = bundleID.lowercased()
        if browserRoots.contains(where: { matches(b, root: $0) }) { return true }
        return extraBrowserPrefixes.contains { let p = $0.lowercased(); return !p.isEmpty && b.hasPrefix(p) }
    }

    /// The generic rule never considers this bundle id (empty ids included).
    static func isBuiltInDenied(_ bundleID: String, extraBrowserPrefixes: [String] = []) -> Bool {
        let b = bundleID.lowercased()
        if b.isEmpty { return true }
        if denyRoots.contains(where: { matches(b, root: $0) }) { return true }
        return isBrowser(bundleID, extraBrowserPrefixes: extraBrowserPrefixes)
    }

    /// The app an audio process belongs to: Electron / Chromium helpers are named "<app>.helper", "<app>.helper.Renderer", "<app>.helper.GPU", ...
    /// Anything without a `helper` component is its own app.
    static func mainBundleID(of bundleID: String) -> String {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let at = parts.indices.dropFirst(2).first(where: { parts[$0].lowercased() == "helper" }) else { return bundleID }
        return parts[..<at].joined(separator: ".")
    }

    static let maxNameLength = 40

    /// One line, at most 40 characters, no control characters: an app's name can come from anywhere and ends up in a banner, a menu and session.json.
    static func displayName(_ raw: String?, fallbackID: String) -> String {
        let clipped = NotificationText.clip(raw ?? "", maxNameLength)
        if !clipped.isEmpty { return clipped }
        let last = fallbackID.split(separator: ".").last.map(String.init) ?? fallbackID
        let fallback = NotificationText.clip(last, maxNameLength)
        return fallback.isEmpty ? "App" : fallback
    }
}

// MARK: - EXTRA_MEETING_APPS

struct ExtraCallApp: Equatable {
    var id: String
    var name: String
}

enum ExtraMeetingApps {
    static let maxEntries = 64
    static let maxIDLength = 128
    static let maxInputLength = 16_384
    static let maxProblems = 5

    struct Result: Equatable {
        var apps: [ExtraCallApp] = []
        var problems: [String] = []       // at most `maxProblems` lines, the last one counts the rest
    }

    /// Reverse-DNS style: letters, digits, '.', '-', '_', starting with a letter or digit, at least one '.'.
    static func isValidBundleID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= maxIDLength, id.contains(".") else { return false }
        return id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    /// `bundle.id` or `bundle.id=Display Name`, separated by commas. Garbage entries, duplicates (the first counts), our own app, Zoom, Teams, browsers and
    /// apps that are in the built-in table are dropped with one line each (the first `maxProblems` lines are kept); more than `maxEntries` entries or
    /// `maxInputLength` characters are cut. Never throws and never crashes on any input.
    static func parse(_ raw: String, browserPrefixes: [String] = []) -> Result {
        var out = Result()
        var dropped = 0
        func problem(_ text: String) {
            if out.problems.count < maxProblems { out.problems.append(text) } else { dropped += 1 }
        }
        var text = raw
        if text.count > maxInputLength {
            text = String(text.prefix(maxInputLength))
            problem("the value is longer than \(maxInputLength) characters: the rest is ignored")
        }
        var seen = Set<String>()
        for token in text.split(separator: ",", omittingEmptySubsequences: true) {
            let item = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            if out.apps.count >= maxEntries {
                problem("more than \(maxEntries) apps: the rest is ignored")
                break
            }
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard isValidBundleID(id) else {
                problem("'\(NotificationText.clip(id, 40))' is not a bundle id (letters, digits, '.', '-', '_'; at least one '.'): ignored")
                continue
            }
            let key = id.lowercased()
            if seen.contains(key) {
                problem("\(id) is listed more than once: the first entry counts")
                continue
            }
            if FamilyMatcher.isOwn(key) {
                problem("\(id) is this app: it never records itself")
                continue
            }
            if key == "us.zoom" || key.hasPrefix("us.zoom.") || key.hasPrefix(FamilyMatcher.teamsPrefix) {
                problem("\(id) is Zoom / Teams: they have their own detection (ENABLED_PLATFORMS)")
                continue
            }
            if CallApps.isBrowser(id, extraBrowserPrefixes: browserPrefixes) {
                problem("\(id) is a browser: a call in a browser is Google Meet (ENABLED_PLATFORMS) or a meeting page (CALL_BROWSER_URLS)")
                continue
            }
            if CallApps.known(forBundle: id) != nil {
                problem("\(id) is already in the built-in table: nothing to add")
                continue
            }
            seen.insert(key)
            let name = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            out.apps.append(ExtraCallApp(id: id, name: CallApps.displayName(name, fallbackID: id)))
        }
        if dropped > 0 { out.problems.append("... and \(dropped) more problem(s)") }
        return out
    }
}

// MARK: - Meeting pages in a browser tab

struct WebMeetingMatch: Equatable {
    var siteID: String
    var name: String
}

/// The table of meeting pages of CALL_BROWSER_URLS: DATA, one row per site (`WebMeetingURL.table`), read by one small matcher. A match only says "this tab is a
/// meeting page of that site": the call itself still needs the browser to hold the microphone AND play sound. Exact host (or a dotted suffix of a domain):
/// `whereby.com.evil.com` never matches, and only `https`. Google Meet is NOT in this table (it stays behind `meet` in ENABLED_PLATFORMS). All rows are
/// implemented from public link formats and are not verified against a real call.
enum WebMeetingURL {
    /// How the path (lower case, as the URL gives it) of a page of the site says "this is a meeting".
    enum PathRule {
        case prefix(String)                                          // the path starts with it
        case prefixWithMore(String)                                  // starts with it and has at least one more character ("/meet/" + a room)
        case lastSegment(String)                                     // the last path segment is exactly this ("j.php")
        case prefixContaining(String, segment: String)               // starts with it and has this segment somewhere after it
        case prefixWithQuery(String, name: String, value: String)    // starts with it and the query has name=value
        case room(reserved: Set<String>)                             // the first segment is a room name: anything but a reserved word of the site
    }

    struct Site {
        var id: String
        var name: String
        var exactHosts: [String] = []                                // the host is one of these ...
        var domains: [String] = []                                   // ... or is one of these domains or a subdomain of it
        var excludedHosts: [String] = []                             // hosts of the domain that are never a meeting (marketing, docs)
        var rules: [PathRule]
    }

    static let table: [Site] = [
        Site(id: "webex", name: "Webex (web)", domains: ["webex.com"], rules: [
            .prefixWithMore("/meet/"),                               // personal room: <site>.webex.com/meet/<name>
            .lastSegment("j.php"),                                   // classic join link: <site>.webex.com/<site>/j.php?MTID=...
            .prefix("/wbxmjs/joinservice/"),
            .prefixContaining("/webappng/sites/", segment: "meeting"),
        ]),
        Site(id: "whereby", name: "Whereby", domains: ["whereby.com"],
             excludedHosts: ["www.whereby.com", "docs.whereby.com", "help.whereby.com", "api.whereby.com", "support.whereby.com"],
             rules: [.room(reserved: [
                "information", "pricing", "blog", "product", "about", "features", "login", "signup", "sign-up", "business", "embedded", "user", "dashboard", "legal",
                "terms", "privacy", "contact", "careers", "press", "customers", "education", "healthcare", "download", "downloads", "solutions", "use-cases",
                "partners", "developers", "help", "support", "security", "accessibility", "enterprise", "pro", "free", "plans"])]),
        Site(id: "jitsi", name: "Jitsi Meet", exactHosts: ["meet.jit.si"],
             rules: [.room(reserved: ["static", "images", "libs", "css", "sounds", "fonts", "plugins", "index.html"])]),
        Site(id: "teams-web", name: "Teams (web)", exactHosts: ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"], rules: [
            .prefix("/l/meetup-join/"), .prefix("/dl/launcher"), .prefixWithMore("/meet/"),
            .prefixWithQuery("/v2", name: "meetingjoin", value: "true"),
        ]),
        Site(id: "zoom-web", name: "Zoom (web)", domains: ["zoom.us", "zoom.com"], rules: [.prefix("/wc/")]),
    ]

    /// Every site of the table, in the order the documentation lists them.
    static var sites: [WebMeetingMatch] { table.map { WebMeetingMatch(siteID: $0.id, name: $0.name) } }

    private static func hostMatches(_ host: String, _ site: Site) -> Bool {
        if site.excludedHosts.contains(host) { return false }
        return site.exactHosts.contains(host) || site.domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func pathMatches(_ rule: PathRule, path: String, segments: [String], query: [URLQueryItem]) -> Bool {
        switch rule {
        case .prefix(let p): return path.hasPrefix(p)
        case .prefixWithMore(let p): return path.hasPrefix(p) && path.count > p.count
        case .lastSegment(let name): return segments.last == name
        case .prefixContaining(let p, let segment): return path.hasPrefix(p) && segments.contains(segment)
        case .prefixWithQuery(let p, let name, let value):
            return path.hasPrefix(p) && query.contains { $0.name.lowercased() == name && $0.value?.lowercased() == value }
        case .room(let reserved): return segments.first.map { !reserved.contains($0) } ?? false
        }
    }

    static func classify(_ url: String) -> WebMeetingMatch? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 4096, let comps = URLComponents(string: trimmed), comps.scheme?.lowercased() == "https",
              let host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        let path = comps.path.lowercased()
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let query = comps.queryItems ?? []
        for site in table where hostMatches(host, site) {
            if site.rules.contains(where: { pathMatches($0, path: path, segments: segments, query: query) }) {
                return WebMeetingMatch(siteID: site.id, name: site.name)
            }
        }
        return nil
    }
}

// MARK: - Decisions per app (SUPPORT_DIR/call-apps.json)

enum CallDecision: String, Equatable {
    case allowed, denied
}

struct CallAppEntry: Equatable {
    var id: String            // lower case bundle id
    var name: String
    var decision: CallDecision
}

/// The decision of the person per app, kept in SUPPORT_DIR/call-apps.json (mode 0600). `denied` = never record this app (known, extra and generic apps alike, and a
/// meeting page by its site: key `web:<siteID>`); `allowed` = recorded before and not objected to. The file holds bundle ids, display names, the decision and the
/// time of the last change: no titles, no meeting content. Written atomically (temp file + rename). Thread-safe: the detector reads it on its poll queue, the menu
/// changes it on the main thread.
///
/// The list fails CLOSED. A file that cannot be used (not valid JSON of this shape, empty, a directory, no read permission) is left alone (nothing overwrites it):
/// the store reports `problem`, `allowsCalls` is false (no call of another app is detected while the person's denials are unknown) and no decision can be changed
/// until the file is fixed or removed (`reload()`). Inside a readable file only an entry that says `allowed` is allowed: any other decision text (a typo such as
/// "Denied" or "deny") is read as `denied`, and the next save writes it as `denied`; only an entry whose key is not a bundle id is skipped. A decision whose write
/// failed stays in force for this run and survives every `reload()`; the next successful read writes it again.
final class CallAppStore {
    static let fileName = "call-apps.json"
    static let maxEntries = 500

    private struct Record { var decision: CallDecision; var name: String; var updated: String }

    private let file: URL?
    private let lock = NSLock()          // the in-memory state: short holds, the detector reads it on every poll
    private let ioLock = NSLock()        // one read or write of the file at a time (held across the file access and the swap of the state)
    private var apps: [String: Record] = [:]
    private var unsaved: Set<String> = []     // decisions made in this run that are not in the file (a failed write)
    private var corrupt: String?
    private var skipped = 0
    private var readAsDenied = 0

    /// `file` nil = memory only (tests). The file is read at once; a missing file means "no decisions yet".
    init(file: URL?) {
        self.file = file
        reload()
    }

    convenience init(supportDir: URL) {
        self.init(file: supportDir.appendingPathComponent(Self.fileName))
    }

    /// A bundle id, or `web:<siteID>` for a meeting page in a browser (the browser's own id must never be denied: it would silence Google Meet and every page).
    static func isValidKey(_ key: String) -> Bool {
        if key.hasPrefix(Self.webPrefix) {
            let site = key.dropFirst(Self.webPrefix.count)
            return !site.isEmpty && site.count <= 32 && site.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        }
        return ExtraMeetingApps.isValidBundleID(key)
    }
    static let webPrefix = "web:"

    /// Why the file cannot be used (nil = fine). While it is set no call of another app is detected and `set` refuses.
    var problem: String? { lock.lock(); defer { lock.unlock() }; return corrupt }

    /// False while the file is unreadable: without the person's denials nothing that is not Zoom, Teams or Meet may be recorded.
    var allowsCalls: Bool { problem == nil }

    /// Number of entries that were skipped (a key that is not a bundle id, or beyond the limit) at the last read.
    var skippedEntries: Int { lock.lock(); defer { lock.unlock() }; return skipped }

    /// Number of entries whose decision was not `allowed` / `denied` and is read as `denied` at the last read.
    var readAsDeniedEntries: Int { lock.lock(); defer { lock.unlock() }; return readAsDenied }

    func decision(for bundleID: String) -> CallDecision? {
        lock.lock(); defer { lock.unlock() }
        return apps[bundleID.lowercased()]?.decision
    }

    func isDenied(_ bundleID: String) -> Bool { decision(for: bundleID) == .denied }

    /// Sorted by name, then id.
    func entries() -> [CallAppEntry] {
        lock.lock(); defer { lock.unlock() }
        return apps.map { CallAppEntry(id: $0.key, name: $0.value.name, decision: $0.value.decision) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    /// Reads the file again (the menu does it every time it opens, so a hand edit is picked up). A file that cannot be read keeps the decisions of the last good
    /// read in memory; decisions that could not be written yet are kept and written again once the file can be read.
    func reload() {
        guard let file = file else { return }
        ioLock.lock(); defer { ioLock.unlock() }
        reloadLocked(file)
    }

    private func reloadLocked(_ file: URL) {
        var loaded: [String: Record] = [:]
        var bad = 0
        var assumed = 0
        var problem: String?
        // fileExists is false only for a file that is not there (a dangling link included); a file that exists and cannot be read is a problem, never "no decisions".
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let data = try Data(contentsOf: file)
                if data.isEmpty {
                    problem = "\(Self.fileName) is empty"
                } else if let object = try? JSONSerialization.jsonObject(with: data), let top = object as? [String: Any], let list = top["apps"] as? [String: Any] {
                    (loaded, bad, assumed) = Self.parse(list)
                } else {
                    problem = "\(Self.fileName) is not valid JSON of the form {\"apps\": {...}}"
                }
            } catch {
                problem = "\(Self.fileName) cannot be read (\((error as NSError).localizedDescription))"
            }
        }
        lock.lock()
        let before = (corrupt, skipped, readAsDenied)
        if problem == nil {
            for id in unsaved { if let mine = apps[id] { loaded[id] = mine } }     // a decision of this run that the file does not have yet
            apps = loaded
            skipped = bad
            readAsDenied = assumed
        }
        corrupt = problem
        let pending = problem == nil && !unsaved.isEmpty ? apps : nil
        lock.unlock()
        if let p = problem, before.0 != p {
            Log.warn("call apps: \(p) (\(file.path)); it is left as it is, no call of another app is detected and no decision can be changed until it is fixed or removed")
        } else if problem == nil, before.0 != nil {
            Log.info("call apps: \(Self.fileName) is readable again (\(loaded.count) apps)")
        }
        if problem == nil, bad > 0, bad != before.1 { Log.warn("call apps: \(bad) entr\(bad == 1 ? "y" : "ies") of \(Self.fileName) skipped (not a bundle id, or beyond \(Self.maxEntries) entries)") }
        if problem == nil, assumed > 0, assumed != before.2 {
            Log.warn("call apps: \(assumed) entr\(assumed == 1 ? "y" : "ies") of \(Self.fileName) with a decision that is not 'allowed' or 'denied' read as 'denied' (never record)")
        }
        if let snapshot = pending, save(snapshot) {
            lock.lock(); unsaved.removeAll(); lock.unlock()
            Log.info("call apps: the decisions that could not be saved before are written")
        }
    }

    /// Entries of `apps`: only the word `allowed` allows; anything else is `denied`. A key that is not a bundle id is skipped; past `maxEntries` the allowed ones go
    /// first (a denial is never dropped for an allowance). Two keys that differ only in case: denied wins, then the key order.
    private static func parse(_ list: [String: Any]) -> (apps: [String: Record], skipped: Int, readAsDenied: Int) {
        var parsed: [(id: String, key: String, record: Record)] = []
        var bad = 0
        var assumed = 0
        for (key, value) in list {
            guard isValidKey(key.lowercased()) else { bad += 1; continue }
            let entry = value as? [String: Any]
            let word = ((entry?["decision"] as? String) ?? (value as? String))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if word != "allowed" && word != "denied" { assumed += 1 }
            let id = key.lowercased()
            parsed.append((id, key, Record(decision: word == "allowed" ? .allowed : .denied, name: CallApps.displayName(entry?["name"] as? String, fallbackID: id),
                                           updated: (entry?["updated"] as? String).map { NotificationText.clip($0, 40) } ?? "")))
        }
        parsed.sort { ($0.record.decision == .denied ? 0 : 1, $0.id, $0.key) < ($1.record.decision == .denied ? 0 : 1, $1.id, $1.key) }
        var out: [String: Record] = [:]
        for p in parsed {
            if out[p.id] != nil { continue }
            if out.count >= maxEntries { bad += 1; continue }
            out[p.id] = p.record
        }
        return (out, bad, assumed)
    }

    /// Sets the decision of one app and saves. False = nothing was changed (the file is unreadable, or the table is full). The file is read again first, so a file
    /// that went bad since the last read is never overwritten and a hand edit is not lost. A failed write keeps the decision for this run (and across `reload()`) and logs it.
    @discardableResult
    func set(_ bundleID: String, decision: CallDecision, name: String?, now: Date = Date()) -> Bool {
        let id = bundleID.lowercased()
        guard Self.isValidKey(id) else { return false }
        ioLock.lock(); defer { ioLock.unlock() }
        if let file = file { reloadLocked(file) }
        lock.lock()
        if corrupt != nil { lock.unlock(); return false }
        if apps[id] == nil && apps.count >= Self.maxEntries { lock.unlock(); return false }
        let keptName = apps[id]?.name
        apps[id] = Record(decision: decision, name: CallApps.displayName(name ?? keptName, fallbackID: id), updated: ShellUtil.iso8601(now))
        unsaved.insert(id)
        let snapshot = apps
        lock.unlock()
        if save(snapshot) {
            lock.lock(); unsaved.removeAll(); lock.unlock()
        }
        return true
    }

    /// A recording of this app (any kind: known, extra, generic, or a meeting page by its `web:<site>` key) has started: it is listed (as allowed) so that the menu can
    /// flip it; an existing decision is never changed.
    func noteRecorded(_ bundleID: String, name: String?, now: Date = Date()) {
        if decision(for: bundleID) == nil { set(bundleID, decision: .allowed, name: name, now: now) }
    }

    /// True = the snapshot is in the file (or there is no file).
    private func save(_ snapshot: [String: Record]) -> Bool {
        guard let file = file else { return true }
        var list: [String: Any] = [:]
        for (id, r) in snapshot { list[id] = ["decision": r.decision.rawValue, "name": r.name, "updated": r.updated] as [String: Any] }
        let top: [String: Any] = ["version": 1, "apps": list]
        guard let data = try? JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".tmp")
            try? fm.removeItem(at: temp)
            guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                Log.warn("call apps: cannot write \(temp.path); the decision holds until the app quits")
                return false
            }
            if rename(temp.path, file.path) != 0 {
                Log.warn("call apps: cannot replace \(file.path) (errno \(errno)); the decision holds until the app quits")
                try? fm.removeItem(at: temp)
                return false
            }
            return true
        } catch {
            Log.warn("call apps: cannot save \(file.path): \(error); the decision holds until the app quits")
            return false
        }
    }
}

// MARK: - What the tracker needs to know about an app

struct CallAppInfo: Equatable {
    var name: String
    var isGUI: Bool
}

/// NSRunningApplication, cached for a few seconds. A GUI app is one with a Dock icon or a menu-bar item (`regular` / `accessory`): daemons and background
/// agents are never guessed. Not thread-safe by itself: the detector calls it under its own lock.
final class LiveCallAppInfo {
    private var cache: [String: (info: CallAppInfo?, at: Date)] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 10) { self.ttl = ttl }

    func info(for bundleID: String) -> CallAppInfo? {
        let now = Date()
        if let c = cache[bundleID], now >= c.at, now.timeIntervalSince(c.at) < ttl { return c.info }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let app = running.first { $0.activationPolicy == .regular } ?? running.first
        let info = app.map { CallAppInfo(name: CallApps.displayName($0.localizedName, fallbackID: bundleID), isGUI: $0.activationPolicy != .prohibited) }
        if cache.count > 256 { cache.removeAll() }
        cache[bundleID] = (info, now)
        return info
    }
}

// MARK: - The tracker

/// What `probe` / diagnostics say about one tracked app.
struct CallAppDiagnostics: Codable, Equatable {
    var id: String
    var name: String
    var kind: CallKind
    var rawInput: Bool
    var rawOutput: Bool
    var stableInput: Bool
    var stableOutput: Bool
    var heldSeconds: Double?          // generic: how long input and output have been held together
    var active: Bool
}

final class CallTracker {
    /// The result of classifying one Core Audio bundle id (before the person's decisions and the GUI check).
    struct Target: Equatable {
        var key: String               // lower case main bundle id
        var id: String                // main bundle id as the table / the process spells it
        var kind: CallKind
        var name: String?             // known / extra: the table's name; generic: nil (asked from the app)
    }

    private struct Flags {
        var input = HysteresisFlag(rise: DetectionTuning.inputRise, fall: DetectionTuning.fall)
        var output = HysteresisFlag(rise: DetectionTuning.outputRise, fall: DetectionTuning.fall)
    }

    private struct AppState {
        var target: Target
        var name: String
        var flags = Flags()
        var bothSince: Date?
        var lastInput: Date?              // the last poll with the smoothed input on (the bounded output keep of a generic call)
        var active = false
        var lastRaw: Date
        var rawInput = false
        var rawOutput = false
    }

    /// A generic (guessed) call whose microphone closed (a mute) is kept by its output for this long; after that only the microphone keeps it.
    static let genericOutputKeepSeconds: TimeInterval = 120

    /// An app whose flags are all off and that is not in a call is forgotten after this long (a generic app that only held the microphone once).
    static let forgetAfter: TimeInterval = 60

    private let settings: CallDetectSettings
    private let browserPrefixes: [String]
    private let store: CallAppStore?
    private let extras: [String: ExtraCallApp]
    private var states: [String: AppState] = [:]
    private var classified: [String: Target?] = [:]
    private var browserFlags = Flags()
    private var webActive: [String: Bool] = [:]

    init(settings: CallDetectSettings, browserBundleIDs: [String], store: CallAppStore?) {
        self.settings = settings
        self.browserPrefixes = browserBundleIDs.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.store = store
        var map: [String: ExtraCallApp] = [:]
        for e in settings.extraApps where map[e.id.lowercased()] == nil { map[e.id.lowercased()] = e }
        self.extras = map
    }

    /// While call-apps.json cannot be read the person's denials are unknown: nothing of another app is detected (Zoom, Teams and Meet are not affected).
    private var paused: Bool { store?.allowsCalls == false }
    var isOn: Bool { settings.mode != .off && !paused }
    var genericOn: Bool { settings.mode == .generic && !paused }
    var webOn: Bool { isOn && settings.browserURLs }

    // MARK: classification

    func isBrowser(_ bundleID: String) -> Bool { CallApps.isBrowser(bundleID, extraBrowserPrefixes: browserPrefixes) }

    /// The static part of the classification: own app / extra / known / generic-eligible / nothing. Cached per bundle id.
    func classify(_ bundleID: String) -> Target? {
        if let hit = classified[bundleID] { return hit }
        let result = computeTarget(bundleID)
        if classified.count > 2048 { classified.removeAll() }
        classified[bundleID] = result
        return result
    }

    private func computeTarget(_ bundleID: String) -> Target? {
        let lower = bundleID.lowercased()
        guard !lower.isEmpty, !FamilyMatcher.isOwn(lower) else { return nil }
        for (key, e) in extras where lower == key || lower.hasPrefix(key + ".") {
            return Target(key: key, id: e.id, kind: .extra, name: e.name)
        }
        if let k = CallApps.known(forBundle: bundleID) { return Target(key: k.id.lowercased(), id: k.id, kind: .known, name: k.name) }
        guard settings.mode == .generic else { return nil }
        let main = CallApps.mainBundleID(of: bundleID)
        guard !CallApps.isBuiltInDenied(main, extraBrowserPrefixes: browserPrefixes), !CallApps.isBuiltInDenied(bundleID, extraBrowserPrefixes: browserPrefixes) else { return nil }
        return Target(key: main.lowercased(), id: main, kind: .generic, name: nil)
    }

    /// Does the detector have to read this process's flags (both of them)? The known apps, the apps being tracked, the browser while tab addresses are read.
    func isInteresting(_ bundleID: String) -> Bool {
        guard isOn else { return false }
        if webOn, isBrowser(bundleID) { return true }
        guard let t = classify(bundleID) else { return false }
        if store?.isDenied(t.key) == true { return false }
        switch t.kind {
        case .known, .extra, .web: return true
        case .generic: return genericOn && states[t.key] != nil
        }
    }

    /// Browser processes with audio IO right now (raw or smoothed): the gate of the tab query.
    func browserAudioActive(_ processes: [AudioProcessInfo]) -> Bool {
        guard webOn else { return false }
        let mine = processes.filter { isBrowser($0.bundleID) }
        return mine.contains { $0.isRunningInput || $0.isRunningOutput } || browserFlags.input.value || browserFlags.output.value
    }

    // MARK: the rule (pure)

    /// Start / keep, see the header. `heldSeconds` is how long input and output have been on together (generic only); `wasActive` is the keep latch;
    /// `secondsSinceInput` is how long ago the smoothed input was last on (nil = never).
    static func inCall(kind: CallKind, stableInput: Bool, stableOutput: Bool, heldSeconds: Double?, genericSeconds: TimeInterval, wasActive: Bool,
                       secondsSinceInput: Double? = nil) -> Bool {
        let both = stableInput && stableOutput
        let start: Bool
        switch kind {
        case .generic: start = both && (heldSeconds ?? 0) >= genericSeconds
        case .known, .extra, .web: start = both
        }
        // A GUESSED call is kept by the microphone, and by output only for a bounded time after the microphone closed: output alone (a game's or a player's sound)
        // would otherwise keep a recording of a non-call going for as long as the app plays, with the microphone track running all the time.
        let keep: Bool
        switch kind {
        case .generic: keep = stableInput || (stableOutput && (secondsSinceInput ?? .infinity) <= genericOutputKeepSeconds)
        case .known, .extra, .web: keep = stableInput || stableOutput
        }
        return start || (wasActive && keep)
    }

    private static func b(_ v: Bool) -> String { v ? "1" : "0" }

    /// The key of a meeting page in the store and in `PlatformSignal.meetingKey`.
    static func webKey(_ siteID: String) -> String { CallAppStore.webPrefix + siteID }

    // MARK: poll

    /// One poll. `processes` = what `AudioProcessMonitor.pollCalls` returned (the interesting processes with both flags, the other microphone holders with their
    /// output flag); `tabs` = the tab list of this poll (only its `webTabs` and `status` are read). Returns one signal per tracked app, and diagnostics.
    func update(processes: [AudioProcessInfo], now: Date, tabs: TabsInfo?, appInfo: (String) -> CallAppInfo?) -> (signals: [PlatformSignal], diagnostics: [CallAppDiagnostics]) {
        guard settings.mode != .off else { return ([], []) }
        if paused {
            // Fresh smoothing when the file can be read again: an app must not come back "already in a call" from before the pause.
            if !states.isEmpty || !webActive.isEmpty { states.removeAll(); webActive.removeAll(); browserFlags = Flags() }
            return ([], [])
        }
        var groups: [String: (target: Target, processes: [AudioProcessInfo])] = [:]
        var browserProcesses: [AudioProcessInfo] = []
        for p in processes {
            if webOn, isBrowser(p.bundleID) { browserProcesses.append(p); continue }
            guard let t = classify(p.bundleID), store?.isDenied(t.key) != true else { continue }
            if t.kind == .generic, !genericOn { continue }
            groups[t.key, default: (t, [])].processes.append(p)
        }

        // Apps that have no process in this poll feed `false` (their flags then fall after the usual 3 s), newly seen apps get a state.
        for key in Set(states.keys).union(groups.keys) {
            let procs = groups[key]?.processes ?? []
            if states[key] == nil {
                guard let target = groups[key]?.target else { continue }
                var name = target.name
                if target.kind == .generic {
                    // GUI apps only: a daemon or a helper without an app is never guessed. The name comes from the running app.
                    guard let info = appInfo(target.id), info.isGUI else { continue }
                    name = info.name
                }
                states[key] = AppState(target: target, name: CallApps.displayName(name, fallbackID: target.id), lastRaw: now)
            }
            guard var s = states[key] else { continue }
            let rawIn = procs.contains { $0.isRunningInput }
            let rawOut = procs.contains { $0.isRunningOutput }
            s.rawInput = rawIn
            s.rawOutput = rawOut
            let stableIn = s.flags.input.update(raw: rawIn, now: now)
            let stableOut = s.flags.output.update(raw: rawOut, now: now)
            if stableIn { s.lastInput = now }
            if let last = s.lastInput, last > now { s.lastInput = now }
            if let since = s.bothSince, since > now { s.bothSince = now }
            if stableIn && stableOut { s.bothSince = s.bothSince ?? now } else { s.bothSince = nil }
            let held = s.bothSince.map { now.timeIntervalSince($0) }
            s.active = Self.inCall(kind: s.target.kind, stableInput: stableIn, stableOutput: stableOut, heldSeconds: held,
                                   genericSeconds: settings.genericSeconds, wasActive: s.active, secondsSinceInput: s.lastInput.map { now.timeIntervalSince($0) })
            if rawIn || rawOut || stableIn || stableOut || s.active { s.lastRaw = now }
            states[key] = s
        }
        for (key, s) in states where !s.active && !s.flags.input.value && !s.flags.output.value && now.timeIntervalSince(s.lastRaw) >= Self.forgetAfter {
            states.removeValue(forKey: key)
        }

        var signals: [PlatformSignal] = []
        var diagnostics: [CallAppDiagnostics] = []
        for key in states.keys.sorted() {
            guard let s = states[key] else { continue }
            let stableIn = s.flags.input.value, stableOut = s.flags.output.value
            // One entry per app that has shown any audio IO; an idle known app is not listed (every poll would carry nine empty signals).
            guard s.active || s.rawInput || s.rawOutput || stableIn || stableOut else { continue }
            let held = s.bothSince.map { now.timeIntervalSince($0) }
            let procs = groups[key]?.processes ?? []
            let audio = FamilyAudio(platform: .call, processes: procs)
            var sig = PlatformSignal(platform: .call, inCall: s.active, confidence: s.target.kind == .generic ? .low : .high,
                                     meetingKey: s.target.key, bundleID: s.target.id)
            sig.appName = s.name
            sig.callKind = s.target.kind
            sig.evidence.append("call-audio \(s.name) in=\(Self.b(stableIn)) out=\(Self.b(stableOut)) raw=\(Self.b(s.rawInput))/\(Self.b(s.rawOutput)) io=\(audio.ioSummary)")
            sig.evidence.append("app=\(s.target.kind.rawValue) \(s.target.id)")
            if s.target.kind == .generic {
                sig.evidence.append(String(format: "generic: in+out held %.0f s of %.0f s", held ?? 0, settings.genericSeconds))
            }
            if s.active {
                sig.evidence.append(stableIn && stableOut ? "via=in+out" : "via=keep (\(stableIn ? "in" : "out") only)")
            } else if stableIn || stableOut {
                sig.evidence.append("needs in+out" + (s.target.kind == .generic ? " for \(ZoomTierSettings.format(settings.genericSeconds)) s" : ""))
            }
            signals.append(sig)
            diagnostics.append(CallAppDiagnostics(id: s.target.id, name: s.name, kind: s.target.kind, rawInput: s.rawInput, rawOutput: s.rawOutput,
                                                  stableInput: stableIn, stableOutput: stableOut, heldSeconds: held, active: s.active))
        }

        if webOn {
            let web = webSignals(browserProcesses: browserProcesses, now: now, tabs: tabs)
            signals += web.signals
            diagnostics += web.diagnostics
        }
        return (signals, diagnostics)
    }

    /// The browser meeting pages: a tab of the table AND the browser holding the microphone and playing sound. The tab list failing (Automation not granted,
    /// error) never starts anything and never ends a call that is running; a tab list that is read and has no such tab ends it.
    private func webSignals(browserProcesses: [AudioProcessInfo], now: Date, tabs: TabsInfo?) -> (signals: [PlatformSignal], diagnostics: [CallAppDiagnostics]) {
        let rawIn = browserProcesses.contains { $0.isRunningInput }
        let rawOut = browserProcesses.contains { $0.isRunningOutput }
        let stableIn = browserFlags.input.update(raw: rawIn, now: now)
        let stableOut = browserFlags.output.update(raw: rawOut, now: now)
        let tabsOK = tabs?.status.isOK == true
        var tabBySite: [String: WebMeetingTab] = [:]
        if tabsOK {
            for tab in (tabs?.webTabs ?? []).sorted(by: { ($0.isFrontActive ? 0 : 1, $0.windowOrder) < ($1.isFrontActive ? 0 : 1, $1.windowOrder) }) where tabBySite[tab.siteID] == nil {
                tabBySite[tab.siteID] = tab
            }
        }
        // The main process of the browser has the shortest bundle id ("com.google.Chrome" against "com.google.Chrome.helper").
        let browserID = browserProcesses.map { $0.bundleID }.min { $0.count < $1.count } ?? ChromeTabs.defaultBundleID
        let audio = FamilyAudio(platform: .call, processes: browserProcesses)
        var signals: [PlatformSignal] = []
        var diagnostics: [CallAppDiagnostics] = []
        for site in WebMeetingURL.sites {
            // 'Never record' for a meeting page is kept per site (the browser's own id is never denied).
            if store?.isDenied(Self.webKey(site.siteID)) == true { webActive[site.siteID] = false; continue }
            let tab = tabBySite[site.siteID]
            let was = webActive[site.siteID] ?? false
            var active = false
            if tab != nil && stableIn && stableOut {
                active = true
            } else if was && (stableIn || stableOut) && (tab != nil || !tabsOK) {
                active = true
            }
            webActive[site.siteID] = active
            guard tab != nil || active else { continue }
            var sig = PlatformSignal(platform: .call, inCall: active, confidence: .high, meetingKey: Self.webKey(site.siteID), bundleID: browserID)
            sig.appName = site.name
            sig.callKind = .web
            sig.evidence.append("browser-audio in=\(Self.b(stableIn)) out=\(Self.b(stableOut)) raw=\(Self.b(rawIn))/\(Self.b(rawOut)) io=\(audio.ioSummary)")
            sig.evidence.append("web=\(site.siteID) tab=\(tab != nil ? "yes" : (tabsOK ? "no" : "n/a"))")
            if active {
                sig.evidence.append(stableIn && stableOut ? "via=tab+in+out" : "via=keep (\(stableIn ? "in" : "out") only)")
            } else {
                sig.evidence.append("meeting tab but the browser audio is not in+out yet")
            }
            signals.append(sig)
            diagnostics.append(CallAppDiagnostics(id: Self.webKey(site.siteID), name: site.name, kind: .web, rawInput: rawIn, rawOutput: rawOut,
                                                  stableInput: stableIn, stableOutput: stableOut, heldSeconds: nil, active: active))
        }
        return (signals, diagnostics)
    }
}
