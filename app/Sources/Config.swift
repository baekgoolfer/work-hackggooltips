import Foundation

// =====================================================================================
// config.env parsing for the Swift app (SPEC section 3).
//
// - File: $MCAP_CONFIG if set, otherwise SUPPORT_DIR/config.env.
// - Format: KEY=VALUE per line. '#' starts a comment at line start or after whitespace.
//   Values may be unquoted paths with spaces. '~' is expanded. Unknown keys are ignored
//   (the Python side owns ASR_*/NOTE_*/AUDIO_* keys).
// - Invalid values: Log.warn and keep the default. A missing file means all defaults.
// - MAX_RECORDING_HOURS is clamped to 0.01...12 (warning). An empty ENABLED_PLATFORMS is allowed but warned about
//   and shown in the menu ("Auto-detection off"). The default is zoom,teams: Meet is opt-in (SPEC 15).
// - NO_SPEECH_STOP_MINUTES (default 15) and RETRY_SWEEP_HOURS (default 6): 0 = off, negative = keep default (warning),
//   positive values are clamped into 1...600 minutes / 0.25...168 hours (warning).
// - CLAUDE_AUTH (SPEC 17): api (default) | subscription, case-insensitive; anything else logs a warning and means subscription.
//   CLAUDE_KEY_SERVICE: Keychain service name of the API key item (default "MeetingCapture Anthropic API key"). The app never
//   reads the key; setup only checks that the item exists (Setup.swift).
// - UI_LANGUAGE (default en): en | ko, case-insensitive; anything else logs a warning and means en. It decides the language of the
//   notifications, menu hints and dialogs of the app (`tr(en, ko:)`, set into `L10n.current` by `AppConfig.load()`).
// - NOTIFY_RECORDING (default 1): post a macOS notification when a recording starts and when it ends (the menu-bar icon can be
//   hidden by the notch or a menu-bar manager, so the notification is the only sign that the app noticed the meeting).
//   1/0, true/false, yes/no, on/off (any case); anything else logs a warning and keeps the default (on). Warnings and results
//   (remote audio silent, recording could not start, processing failed, note ready) are never switched off by it.
// - ZOOM_STRONG_SOCKETS (default 6) and ZOOM_WEAK_DEBOUNCE_SECONDS (default 15, 0 = off): the Zoom evidence tiers, see `ZoomTierSettings`
//   at the end of this file (they are not AppConfig fields).
// - CALL_DETECT (known | generic | off, default known; off on a policy-managed Mac), CALL_GENERIC_SECONDS (default 45), EXTRA_MEETING_APPS (bundle ids, optionally id=Name) and
//   CALL_BROWSER_URLS (default off): the detection of calls beyond Zoom / Teams / Meet, see `CallDetectSettings` at the end of this file (not AppConfig
//   fields either). docs/DETECTION.md section 3b.
// - OFFLINE_AUTOSTART (default off) and the OFFLINE_* numbers of the calendar auto-start are not AppConfig fields either: `OfflineAutostartSettings` at the end of
//   this file reads them (CalendarWatcher.swift). A typo in OFFLINE_AUTOSTART means off; an invalid number keeps its default (warning).
// - PROJECT_DIR (where the pipeline, the config examples and the scripts live): the config.env key wins; without it the default is the app's own
//   Contents/Resources/mcap when that folder exists (the app installer, scripts/build_dmg.sh puts the pipeline there; `AppConfig.bundledProjectDir`),
//   else ~/Developer/meeting-capture (a checkout; scripts/install.sh writes PROJECT_DIR for it). A policy-managed Mac still fixes it itself.
//   The Python side needs no variable for this: it finds config/ next to the package it runs from (pipeline/mcap/note.py `prompt_candidates`).
// - Mirrors pipeline/mcap/config.py (same comment rules, same "SUPPORT_DIR" test override).
// - SPEC 18 (organisation policy, Policy.swift): on a policy-managed Mac (/Library/Application Support/MeetingCapture/policy.json or
//   policy.required exists) the test hooks ($MCAP_CONFIG, $MCAP_LOG_DIR, $MCAP_SECURITY_BIN) and the config.env keys SUPPORT_DIR,
//   PYTHON_BIN, PROJECT_DIR and CLAUDE_BIN are ignored, and the policy's `defaults` / `enforced` layers are applied around the values
//   (PolicyLayers.apply). Without a policy none of this changes anything: the same values, the same log lines.
// - The privacy keys (LOCAL_ONLY_DEFAULT, ASR_ENGINE, MIC_MUTE_GATE, LOCAL_ARCHIVE_DIR, LOG_CONTENT, ...) are not AppConfig fields
//   (Types.swift is not changed); `PrivacySettings` reads them from the same layered values.
// =====================================================================================

extension AppConfig {

    /// The config.env that `load()` reads: $MCAP_CONFIG (tests / alternate setups; ignored on a policy-managed Mac) or SUPPORT_DIR/config.env.
    static var configFilePath: URL {
        if let p = OrgPolicy.testHookValue("MCAP_CONFIG") {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return defaultSupportDir.appendingPathComponent("config.env")
    }

    /// Loads the configuration. Never fails: problems are logged and defaults are used.
    static func load() -> AppConfig {
        let cfg = load(from: configFilePath)
        L10n.current = cfg.uiLanguage           // the one place where the language of the running app is decided
        return cfg
    }

    /// `policy` nil = read the policy of this Mac (a test passes one). With a policy the layers of PolicyLayers are applied to the values;
    /// without one (the personal install) the result and the log lines are what they always were.
    static func load(from file: URL, policy: OrgPolicy? = nil) -> AppConfig {
        let policy = policy ?? OrgPolicy.load()
        let defaults = AppConfig.defaultsWithBundledProject()
        let fm = FileManager.default
        var values: [String: String] = [:]
        if !fm.fileExists(atPath: file.path) {
            Log.info("config: \(file.path) not found; using built-in defaults")
            guard policy.isEnforced else { return defaults }
        } else if let data = fm.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) {
            values = parseEnvText(text)
        } else {
            Log.warn("config: cannot read \(file.path) as UTF-8; using built-in defaults")
            guard policy.isEnforced else { return defaults }
        }
        if policy.isEnforced {
            let dropped = OrgPolicy.ignoredConfigKeys.filter { values[$0] != nil }
            if !dropped.isEmpty { Log.info("config: \(dropped.joined(separator: ", ")) in \(file.path) ignored: this Mac is policy-managed") }
            PolicyLayers.apply(&values, policy: policy)
        }
        return build(from: values, source: file.path)
    }

    // MARK: - Parsing

    /// Parses KEY=VALUE text. Same rules as the Python side: blank lines and '#' lines are skipped, an inline
    /// comment starts at a '#' that follows whitespace, surrounding quotes are removed. Later keys win.
    static func parseEnvText(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }          // UTF-8 BOM from some editors
        for rawLine in body.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            var value = String(line[line.index(after: eq)...])
            // Inline comment: '#' preceded by whitespace (so '#' inside a path or URL fragment survives).
            var previous: Character? = nil
            for idx in value.indices {
                let ch = value[idx]
                if ch == "#", let p = previous, p.isWhitespace {
                    value = String(value[value.startIndex..<idx])
                    break
                }
                previous = ch
            }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// Applies parsed values on top of the built-in defaults.
    static func build(from values: [String: String], source: String, bundledProject: URL? = AppConfig.bundledProjectDir()) -> AppConfig {
        var cfg = AppConfig.defaults()
        if let bundled = bundledProject { cfg.projectDir = bundled }          // the config.env key PROJECT_DIR below still wins

        // Test/override hook, same as the Python side. Must be processed first because the default
        // PYTHON_BIN lives inside SUPPORT_DIR.
        if let raw = values["SUPPORT_DIR"], !raw.isEmpty, let dir = absolutePath(raw, key: "SUPPORT_DIR", source: source) {
            cfg.supportDir = dir
            cfg.pythonBin = dir.appendingPathComponent("venv/bin/python")
        }

        func str(_ key: String) -> String? {
            guard let v = values[key], !v.isEmpty else { return nil }
            return v
        }
        func path(_ key: String, isDir: Bool) -> URL? {
            guard let v = str(key), let url = absolutePath(v, key: key, source: source) else { return nil }
            return isDir ? URL(fileURLWithPath: url.path, isDirectory: true) : url
        }
        func number(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let v = str(key) else { return nil }
            guard let d = Double(v), d.isFinite else {
                Log.warn("config: \(key)=\(v) is not a number (in \(source)); keeping default")
                return nil
            }
            guard range.contains(d) else {
                Log.warn("config: \(key)=\(v) is outside \(range.lowerBound)...\(range.upperBound) (in \(source)); keeping default")
                return nil
            }
            return d
        }

        // Like number(), but an out-of-range value is clamped (with a warning) instead of ignored.
        func clampedNumber(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let v = str(key) else { return nil }
            guard let d = Double(v), d.isFinite else {
                Log.warn("config: \(key)=\(v) is not a number (in \(source)); keeping default")
                return nil
            }
            let clamped = min(max(d, range.lowerBound), range.upperBound)
            if clamped != d {
                Log.warn("config: \(key)=\(v) is outside \(range.lowerBound)...\(range.upperBound) (in \(source)); using \(clamped)")
            }
            return clamped
        }

        // 0 = feature off; a negative value is a typo (keep the default, with a warning); a positive value is clamped into `range`.
        func offOrClamped(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            guard let v = str(key) else { return nil }
            guard let d = Double(v), d.isFinite else {
                Log.warn("config: \(key)=\(v) is not a number (in \(source)); keeping default")
                return nil
            }
            if d < 0 {
                Log.warn("config: \(key)=\(v) is negative (in \(source)); use 0 to switch it off; keeping default")
                return nil
            }
            if d == 0 { return 0 }
            let clamped = min(max(d, range.lowerBound), range.upperBound)
            if clamped != d {
                Log.warn("config: \(key)=\(v) is outside \(range.lowerBound)...\(range.upperBound) (in \(source)); using \(clamped) (0 switches it off)")
            }
            return clamped
        }

        if let u = path("ARCHIVE_DIR", isDir: true) { cfg.archiveDir = u }
        if let u = path("PROJECT_DIR", isDir: true) { cfg.projectDir = u }
        if let u = path("PYTHON_BIN", isDir: false) { cfg.pythonBin = u }
        if let u = path("CLAUDE_BIN", isDir: false) { cfg.claudeBin = u }
        if let s = str("SELF_NAME") { cfg.selfName = s }

        if let raw = values["ENABLED_PLATFORMS"] {
            // An explicitly empty list means "detect nothing" (manual recording only); this is also how tests
            // keep the detector quiet. Python ignores the key, so there is no conflict.
            cfg.enabledPlatforms = parsePlatforms(raw, fallback: cfg.enabledPlatforms, source: source)
        }
        if let raw = str("BROWSER_BUNDLE_IDS") {
            let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if ids.isEmpty {
                Log.warn("config: BROWSER_BUNDLE_IDS=\(raw) has no bundle ids (in \(source)); keeping default")
            } else {
                cfg.browserBundleIDs = ids
            }
        }
        if let d = number("POLL_INTERVAL_SECONDS", 0.5...60) { cfg.pollInterval = d }
        if let d = number("START_DEBOUNCE_SECONDS", 0...600) { cfg.startDebounce = d }
        if let d = number("GRACE_SECONDS", 0...3600) { cfg.grace = d }
        if let d = number("MIN_RECORDING_SECONDS", 0...3600) { cfg.minRecordingSeconds = d }
        if let d = clampedNumber("MAX_RECORDING_HOURS", maxRecordingHoursRange) { cfg.maxRecordingHours = d }
        if let d = number("MIN_FREE_DISK_GB", 0...10_000) { cfg.minFreeDiskGB = d }
        if let d = offOrClamped("NO_SPEECH_STOP_MINUTES", noSpeechStopMinutesRange) { cfg.noSpeechStopMinutes = d }
        if let d = offOrClamped("RETRY_SWEEP_HOURS", retrySweepHoursRange) { cfg.retrySweepHours = d }
        if let raw = str("SYSTEM_AUDIO_MODE") {
            if let mode = SystemAudioMode(rawValue: raw.lowercased()) {
                cfg.systemAudioMode = mode
            } else {
                Log.warn("config: SYSTEM_AUDIO_MODE=\(raw) must be 'global' or 'app' (in \(source)); keeping default")
            }
        }

        // SPEC 17: how the pipeline's `claude -p` calls are billed; the default is api. Anything but 'subscription' / 'api' falls back to
        // subscription (the mode that cannot spend Console credits; the pipeline makes no call for such a value). The service name is only
        // ever used to ask the Keychain whether the item exists.
        if let raw = str("CLAUDE_AUTH") {
            if let mode = ClaudeAuthMode(rawValue: raw.lowercased()) {
                cfg.claudeAuth = mode
            } else {
                Log.warn("config: CLAUDE_AUTH=\(raw) must be 'subscription' or 'api' (in \(source)); using subscription")
                cfg.claudeAuth = .subscription
            }
        }
        if let s = str("CLAUDE_KEY_SERVICE") { cfg.claudeKeychainService = s }

        // UI_LANGUAGE: the language of the app's own texts. Unknown text keeps English (with a warning).
        if let raw = str("UI_LANGUAGE") {
            if let lang = UILanguage(rawValue: raw.lowercased()) {
                cfg.uiLanguage = lang
            } else {
                Log.warn("config: UI_LANGUAGE=\(raw) must be 'en' or 'ko' (in \(source)); using en")
            }
        }

        if let raw = str("NOTIFY_RECORDING") {
            if let on = parseSwitch(raw) {
                cfg.notifyRecording = on
            } else {
                Log.warn("config: NOTIFY_RECORDING=\(raw) must be 1 or 0 (or true/false, yes/no, on/off) (in \(source)); keeping default (\(cfg.notifyRecording ? "on" : "off"))")
            }
        }
        return cfg
    }

    // MARK: - The pipeline inside the app

    /// Contents/Resources/mcap of a .app bundle, when that folder exists (the app installer's layout, scripts/build_dmg.sh). nil for a bare binary, a
    /// bundle without the folder (a build from source, the company package) and any other place: then the default project folder stays as it was.
    static func bundledProjectDir(bundleURL: URL = Bundle.main.bundleURL, resourceURL: URL? = Bundle.main.resourceURL,
                                  isDirectory: (URL) -> Bool = { url in
                                      var isDir: ObjCBool = false
                                      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                                  }) -> URL? {
        guard bundleURL.pathExtension == "app", let resources = resourceURL else { return nil }
        let dir = resources.appendingPathComponent("mcap", isDirectory: true)
        return isDirectory(dir) ? dir : nil
    }

    /// `defaults()` with the project folder of the app installer when this app has one.
    static func defaultsWithBundledProject(bundledProject: URL? = AppConfig.bundledProjectDir()) -> AppConfig {
        var cfg = AppConfig.defaults()
        if let bundled = bundledProject { cfg.projectDir = bundled }
        return cfg
    }

    // MARK: - Limits

    /// WavWriter stops at 4 GiB per file (12.4 h of 48 kHz mono 16-bit), so a longer limit would silently lose audio.
    static let maxRecordingHoursRange: ClosedRange<Double> = 0.01...12

    /// NO_SPEECH_STOP_MINUTES: 0 = off. Anything between 0 and 1 minute would end a recording during an ordinary pause in a
    /// call, so it is raised to 1; more than 10 hours is beyond MAX_RECORDING_HOURS anyway.
    static let noSpeechStopMinutesRange: ClosedRange<Double> = 1...600

    /// RETRY_SWEEP_HOURS: 0 = off. The minimum keeps a typo from starting a Python process every few seconds.
    static let retrySweepHoursRange: ClosedRange<Double> = 0.25...168

    // MARK: - Helpers

    /// The path rule of `absolutePath` without the log line: a value that is absolute after `~` is expanded (the Settings window uses it to refuse a
    /// folder the parser would not take).
    static func isAbsolutePathValue(_ raw: String) -> Bool {
        return (raw as NSString).expandingTildeInPath.hasPrefix("/")
    }

    private static func absolutePath(_ raw: String, key: String, source: String) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        guard isAbsolutePathValue(raw) else {
            Log.warn("config: \(key)=\(raw) is not an absolute path (in \(source)); keeping default")
            return nil
        }
        return URL(fileURLWithPath: expanded)
    }

    /// 1/0, true/false, yes/no, on/off (any case); nil for anything else.
    static func parseSwitch(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    private static func parsePlatforms(_ raw: String, fallback: [Platform], source: String) -> [Platform] {
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if names.isEmpty {
            // Supported (tests, "manual recording only"), but never silent: a typo such as
            // "ENABLED_PLATFORMS=   # meet,zoom" must not turn automatic recording off unnoticed. The menu shows it too.
            Log.warn("config: ENABLED_PLATFORMS is empty (in \(source)): automatic meeting detection is OFF, only 'Start Recording Now' works")
            return []
        }
        var result: [Platform] = []
        for name in names {
            if name == Platform.call.rawValue {
                // `call` is the platform of every other call; it is not a detector of its own: CALL_DETECT switches it.
                Log.warn("config: ENABLED_PLATFORMS contains 'call' (in \(source)); calls of other apps are switched with CALL_DETECT, not here; ignoring it")
                continue
            }
            guard let p = Platform(rawValue: name), p != .manual else {
                Log.warn("config: ENABLED_PLATFORMS contains unknown platform '\(name)' (in \(source)); ignoring it")
                continue
            }
            if !result.contains(p) { result.append(p) }
        }
        if result.isEmpty {
            Log.warn("config: ENABLED_PLATFORMS=\(raw) has no valid platform (in \(source)); keeping default")
            return fallback
        }
        return result
    }
}

// MARK: - Zoom evidence tiers (ZOOM_STRONG_SOCKETS, ZOOM_WEAK_DEBOUNCE_SECONDS)

/// Settings of the Zoom STRONG / WEAK evidence rule (docs/DETECTION.md section 3, `Detector.classifyZoom`, `DetectionStateMachine`).
///
///   STRONG  = Zoom main-pid UDP sockets >= `strongSockets`, OR Zoom input running (us.zoom.xos / us.zoom.caphost), OR Zoom output running
///             with >= `outputSockets` sockets. A STRONG signal starts a recording after the normal START_DEBOUNCE_SECONDS.
///   WEAK    = UDP sockets present but fewer than `strongSockets`, no input, no output (the idle "flicker" of a signed-in Zoom:
///             4 sockets for a few seconds about every 2 minutes). It only counts as a meeting once it has lasted `weakDebounce`
///             seconds (`0` = no extra wait: weak behaves like strong, the behaviour before this rule existed).
///
/// Why this is not an `AppConfig` field: `AppConfig` lives in Types.swift (additive changes only, not touched
/// here). The two values are read with the same parser from the same file as `AppConfig.load()` (`$MCAP_CONFIG`, else
/// SUPPORT_DIR/config.env). `Detector.init(config:)` and `SessionController.init` use `ZoomTierSettings.current`; the self tests pass
/// `.defaults` or an explicit value, so no test depends on the real config file. Moving both fields into `AppConfig` later is a
/// mechanical change: every reader goes through this struct.
struct ZoomTierSettings: Equatable {
    static let defaultStrongSockets = 6
    static let defaultWeakDebounce: TimeInterval = 15
    /// Output running together with at least this many main-pid sockets is STRONG as well (not configurable).
    static let outputSockets = 3
    /// ZOOM_STRONG_SOCKETS must be a whole number in this range (1 = any socket is strong: the tiering is practically off).
    static let strongSocketsRange = 1...64
    /// ZOOM_WEAK_DEBOUNCE_SECONDS: 0 = off, otherwise clamped into this range.
    static let weakDebounceRange: ClosedRange<Double> = 1...300

    var strongSockets: Int = ZoomTierSettings.defaultStrongSockets
    /// Seconds weak evidence has to last before it counts as a meeting (0 = off). The state machine never waits less than START_DEBOUNCE_SECONDS.
    var weakDebounce: TimeInterval = ZoomTierSettings.defaultWeakDebounce

    static let defaults = ZoomTierSettings()

    /// The settings of this process: config.env read once, on first use (warnings about bad values are logged once, not per component).
    static let current: ZoomTierSettings = load()

    static func load() -> ZoomTierSettings { load(from: AppConfig.configFilePath) }

    /// A missing or unreadable file means the defaults (AppConfig.load already says so in the log). On a policy-managed Mac the policy's
    /// `defaults` / `enforced` layers apply here too (both keys are on the whitelist); `policy` nil = the policy of this Mac.
    static func load(from file: URL, policy: OrgPolicy? = nil) -> ZoomTierSettings {
        let policy = policy ?? OrgPolicy.load()
        var values: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) {
            values = AppConfig.parseEnvText(text)
        } else if !policy.isEnforced {
            return defaults
        }
        PolicyLayers.apply(&values, policy: policy)
        return build(from: values, source: file.path)
    }

    /// Applies parsed values on top of the defaults. An invalid value keeps the default and logs a warning; it never throws.
    static func build(from values: [String: String], source: String) -> ZoomTierSettings {
        var s = ZoomTierSettings()
        if let v = values["ZOOM_STRONG_SOCKETS"], !v.isEmpty {
            let whole: Int? = Int(v) ?? Double(v).flatMap { $0.isFinite && $0 == $0.rounded() && abs($0) < 1e6 ? Int($0) : nil }
            if let n = whole, strongSocketsRange.contains(n) {
                s.strongSockets = n
            } else {
                Log.warn("config: ZOOM_STRONG_SOCKETS=\(v) must be a whole number in \(strongSocketsRange.lowerBound)...\(strongSocketsRange.upperBound) (in \(source)); keeping default \(defaultStrongSockets)")
            }
        }
        if let v = values["ZOOM_WEAK_DEBOUNCE_SECONDS"], !v.isEmpty {
            if let d = Double(v), d.isFinite {
                if d < 0 {
                    Log.warn("config: ZOOM_WEAK_DEBOUNCE_SECONDS=\(v) is negative (in \(source)); use 0 to switch the extra wait off; keeping default \(Int(defaultWeakDebounce))")
                } else if d == 0 {
                    s.weakDebounce = 0
                } else {
                    let clamped = min(max(d, weakDebounceRange.lowerBound), weakDebounceRange.upperBound)
                    if clamped != d {
                        Log.warn("config: ZOOM_WEAK_DEBOUNCE_SECONDS=\(v) is outside \(weakDebounceRange.lowerBound)...\(weakDebounceRange.upperBound) (in \(source)); using \(clamped) (0 switches the extra wait off)")
                    }
                    s.weakDebounce = clamped
                }
            } else {
                Log.warn("config: ZOOM_WEAK_DEBOUNCE_SECONDS=\(v) is not a number (in \(source)); keeping default \(Int(defaultWeakDebounce))")
            }
        }
        return s
    }

    /// One line for app.log / probe.
    var summary: String {
        let wait = weakDebounce > 0 ? "WEAK evidence counts as a meeting after \(ZoomTierSettings.format(weakDebounce)) s" : "no extra wait for WEAK evidence (ZOOM_WEAK_DEBOUNCE_SECONDS=0)"
        return "zoom evidence tiers: STRONG = main-pid UDP sockets >= \(strongSockets) | input running | output running + >= \(Self.outputSockets) sockets; \(wait)"
    }

    static func format(_ v: TimeInterval) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

// MARK: - Calls of other apps (CALL_DETECT, CALL_GENERIC_SECONDS, EXTRA_MEETING_APPS, CALL_BROWSER_URLS)

/// Settings of the detection of calls beyond Zoom, Teams and Google Meet (docs/DETECTION.md section 3b, `CallApps.swift`, `CallTracker`).
///
///   CALL_DETECT           known | generic | off (default known; off on a policy-managed Mac that does not set it). known = the built-in table of call apps plus
///                         EXTRA_MEETING_APPS; generic = those and any other GUI app that is not on the built-in deny list and not denied by you, once it has
///                         held the microphone AND played sound for CALL_GENERIC_SECONDS (GUESSING: opt in, never the default); off = none of this (Zoom /
///                         Teams / Meet and the manual start are not affected). Any other text reads as `known` (a typo never switches the guessing on, nor the
///                         whole feature off) and is logged. ENABLED_PLATFORMS does not bound it (only an empty ENABLED_PLATFORMS switches it off too).
///   CALL_GENERIC_SECONDS  45 (clamped into 10...600): how long a generic app has to hold the microphone and output continuously.
///   EXTRA_MEETING_APPS    comma separated bundle ids, each optionally `id=Name` (`com.example.talk=Example Talk`): apps that count like the known ones.
///   CALL_BROWSER_URLS     off (default) | on: also look at the address of Chrome tabs for meeting pages of Whereby, Jitsi, Webex web, Teams web and the Zoom web
///                         client. This needs the same Chrome Automation permission as Google Meet, so it is off: nobody who uses native apps only is
///                         ever asked for it. Google Meet itself stays behind `meet` in ENABLED_PLATFORMS.
///
/// Why this is not an `AppConfig` field: the same reason as `ZoomTierSettings` (the values are read with the same parser from the same file). An invalid
/// value keeps the default and logs a warning; it never throws. An empty ENABLED_PLATFORMS (no automatic detection) switches all of this off too.
/// All four keys are on the policy whitelist (`PolicyLayers.whitelist`): an organisation can set or enforce them. On a policy-managed Mac a CALL_DETECT that
/// neither config.env nor the policy sets means `off`, so a company baseline of `ENABLED_PLATFORMS=zoom,teams` never records another app by default.
struct CallDetectSettings: Equatable {
    enum Mode: String { case known, generic, off }

    static let defaultGenericSeconds: TimeInterval = 45
    static let genericSecondsRange: ClosedRange<Double> = 10...600

    var mode: Mode = .known
    var genericSeconds: TimeInterval = CallDetectSettings.defaultGenericSeconds
    var extraApps: [ExtraCallApp] = []
    var browserURLs = false

    static let defaults = CallDetectSettings()
    /// Nothing beyond the three platforms: what the detector seam (`Detector.init(config:inputs:)`) uses unless a test asks for more.
    static let off = CallDetectSettings(mode: .off)

    /// The settings of this process: config.env read once, on first use (warnings about bad values are logged once).
    static let current: CallDetectSettings = load()

    static func load() -> CallDetectSettings { load(from: AppConfig.configFilePath) }

    /// A missing or unreadable file means the defaults. A policy's layers are applied like for the other keys (all four keys are on the whitelist); on a
    /// policy-managed Mac an unset CALL_DETECT is `off`.
    static func load(from file: URL, policy: OrgPolicy? = nil) -> CallDetectSettings {
        let policy = policy ?? OrgPolicy.load()
        var values: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) {
            values = AppConfig.parseEnvText(text)
        } else if !policy.isEnforced {
            return defaults
        }
        PolicyLayers.apply(&values, policy: policy)
        return build(from: values, source: file.path, unsetMode: policy.isEnforced ? .off : .known)
    }

    /// `unsetMode` = what a missing or empty CALL_DETECT means.
    static func build(from values: [String: String], source: String, unsetMode: Mode = .known) -> CallDetectSettings {
        var s = CallDetectSettings()
        s.mode = unsetMode
        if let raw = values["CALL_DETECT"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let mode = Mode(rawValue: raw.lowercased()) {
                s.mode = mode
            } else {
                Log.warn("config: CALL_DETECT=\(NotificationText.clip(raw, 40)) must be 'known', 'generic' or 'off' (in \(source)); using known (the apps of the table and EXTRA_MEETING_APPS, no guessing)")
                s.mode = .known
            }
        }
        if let raw = values["CALL_GENERIC_SECONDS"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let d = Double(raw), d.isFinite {
                let range = genericSecondsRange
                let clamped = min(max(d, range.lowerBound), range.upperBound)
                if clamped != d {
                    Log.warn("config: CALL_GENERIC_SECONDS=\(raw) is outside \(Int(range.lowerBound))...\(Int(range.upperBound)) (in \(source)); using \(Int(clamped))")
                }
                s.genericSeconds = clamped
            } else {
                Log.warn("config: CALL_GENERIC_SECONDS=\(NotificationText.clip(raw, 40)) is not a number (in \(source)); keeping default \(Int(defaultGenericSeconds))")
            }
        }
        if let raw = values["CALL_BROWSER_URLS"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let on = AppConfig.parseSwitch(raw) {
                s.browserURLs = on
            } else {
                Log.warn("config: CALL_BROWSER_URLS=\(NotificationText.clip(raw, 40)) must be 1 or 0 (or true/false, yes/no, on/off) (in \(source)); keeping default (off)")
            }
        }
        if let raw = values["EXTRA_MEETING_APPS"], !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let browsers = (values["BROWSER_BUNDLE_IDS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let parsed = ExtraMeetingApps.parse(raw, browserPrefixes: browsers.isEmpty ? AppConfig.defaults().browserBundleIDs : browsers)
            s.extraApps = parsed.apps
            for problem in parsed.problems { Log.warn("config: EXTRA_MEETING_APPS (in \(source)): \(problem)") }
        }
        return s
    }

    /// Does this configuration read the address of Chrome tabs for meeting pages (and so need the Chrome Automation permission)?
    func needsBrowserAutomation(for config: AppConfig) -> Bool {
        return mode != .off && browserURLs && !config.enabledPlatforms.isEmpty
    }

    /// One line for app.log.
    var summary: String {
        switch mode {
        case .off: return "call detection: off (CALL_DETECT=off); Zoom, Teams and Meet are not affected"
        case .known, .generic:
            let generic = mode == .generic ? "any other GUI app that holds the microphone and plays sound for \(ZoomTierSettings.format(genericSeconds)) s (not on the deny list, not denied by you)" : "no guessing"
            let urls = browserURLs ? "Chrome tab addresses of Whereby, Jitsi, Webex web, Teams web and Zoom web are read" : "no Chrome tab is read for them"
            return "call detection: \(mode.rawValue): \(CallApps.known.count) known apps + \(extraApps.count) from EXTRA_MEETING_APPS, \(generic); \(urls)"
        }
    }
}

// MARK: - Calendar auto-start (OFFLINE_AUTOSTART and friends)

/// Settings of the calendar auto-start (CalendarWatcher.swift): a single-user feature that starts a recording for an in-person conversation
/// that has a Google Calendar event, with nobody pressing "Start Recording Now". OFF by default; it needs the Google sign-in of the Python
/// side (`mcap gcal auth`). Recording people without their consent can be illegal where you are: docs/CONFIGURATION.md has the warning.
///
///   OFFLINE_AUTOSTART            off (default) | auto. Anything else is a typo and means off (warning): a switch that records people never
///                                turns on by accident.
///   OFFLINE_START_BEFORE_MINUTES (2)    a recording may start this long before the event starts (0...30).
///   OFFLINE_START_AFTER_MINUTES  (15)   ... and this long after it started (0...120): an event that began earlier than that is not joined late.
///   OFFLINE_STOP_AFTER_END_MINUTES (10) a recording this feature started stops this long after the event's end (0...120).
///   OFFLINE_IDLE_MAX_MINUTES     (5)    no keyboard or mouse input for longer than this means nobody is at the Mac: no start (1...120).
///   OFFLINE_REQUIRE_GUESTS       (1)    1 = the event needs at least one attendee besides you (a solo block is not a conversation).
///   OFFLINE_MIN_MINUTES (10) / OFFLINE_MAX_MINUTES (240)   events shorter or longer than this are never recorded (1...600 / 1...1440,
///                                MIN must not exceed MAX).
///
/// Why this is not an `AppConfig` field: the same reason as `ZoomTierSettings` (Types.swift is not changed): the values are read with the same
/// parser from the same file. An invalid number keeps the default and logs a warning; it never throws. The keys are not on the policy
/// whitelist (`PolicyLayers.whitelist`): a company policy cannot set them, and the recording kill switch, a locked policy and the local-only
/// default all close the feature (`SessionController.calendarGate`).
struct OfflineAutostartSettings: Equatable {
    enum Mode: String { case off, auto }

    static let defaultStartBefore = 2
    static let defaultStartAfter = 15
    static let defaultStopAfterEnd = 10
    static let defaultIdleMax = 5
    static let defaultMin = 10
    static let defaultMax = 240

    static let startBeforeRange = 0...30
    static let startAfterRange = 0...120
    static let stopAfterEndRange = 0...120
    static let idleMaxRange = 1...120
    static let minRange = 1...600
    static let maxRange = 1...1440

    var mode: Mode = .off
    var startBeforeMinutes = OfflineAutostartSettings.defaultStartBefore
    var startAfterMinutes = OfflineAutostartSettings.defaultStartAfter
    var stopAfterEndMinutes = OfflineAutostartSettings.defaultStopAfterEnd
    var idleMaxMinutes = OfflineAutostartSettings.defaultIdleMax
    var requireGuests = true
    var minMinutes = OfflineAutostartSettings.defaultMin
    var maxMinutes = OfflineAutostartSettings.defaultMax

    static let defaults = OfflineAutostartSettings()

    var isOn: Bool { mode == .auto }

    /// The settings of this process: config.env read once, on first use (warnings are logged once).
    static let current: OfflineAutostartSettings = load()

    static func load() -> OfflineAutostartSettings { load(from: AppConfig.configFilePath) }

    /// A missing or unreadable file means the defaults (off). A policy's layers are applied like for the other keys (none of ours is on the whitelist).
    static func load(from file: URL, policy: OrgPolicy? = nil) -> OfflineAutostartSettings {
        let policy = policy ?? OrgPolicy.load()
        var values: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) {
            values = AppConfig.parseEnvText(text)
        } else if !policy.isEnforced {
            return defaults
        }
        PolicyLayers.apply(&values, policy: policy)
        return build(from: values, source: file.path)
    }

    static func build(from values: [String: String], source: String) -> OfflineAutostartSettings {
        var s = OfflineAutostartSettings()
        if let raw = values["OFFLINE_AUTOSTART"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let mode = Mode(rawValue: raw.lowercased()) {
                s.mode = mode
            } else {
                Log.warn("config: OFFLINE_AUTOSTART=\(raw) must be 'off' or 'auto' (in \(source)); calendar auto-start stays off")
            }
        }
        func whole(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
            guard let v = values[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return fallback }
            guard let n = Int(v) ?? Double(v).flatMap({ $0.isFinite && $0 == $0.rounded() && abs($0) < 1e6 ? Int($0) : nil }) else {
                Log.warn("config: \(key)=\(v) is not a whole number (in \(source)); keeping default \(fallback)")
                return fallback
            }
            guard range.contains(n) else {
                Log.warn("config: \(key)=\(v) is outside \(range.lowerBound)...\(range.upperBound) (in \(source)); keeping default \(fallback)")
                return fallback
            }
            return n
        }
        s.startBeforeMinutes = whole("OFFLINE_START_BEFORE_MINUTES", startBeforeRange, defaultStartBefore)
        s.startAfterMinutes = whole("OFFLINE_START_AFTER_MINUTES", startAfterRange, defaultStartAfter)
        s.stopAfterEndMinutes = whole("OFFLINE_STOP_AFTER_END_MINUTES", stopAfterEndRange, defaultStopAfterEnd)
        s.idleMaxMinutes = whole("OFFLINE_IDLE_MAX_MINUTES", idleMaxRange, defaultIdleMax)
        s.minMinutes = whole("OFFLINE_MIN_MINUTES", minRange, defaultMin)
        s.maxMinutes = whole("OFFLINE_MAX_MINUTES", maxRange, defaultMax)
        if s.minMinutes > s.maxMinutes {
            Log.warn("config: OFFLINE_MIN_MINUTES=\(s.minMinutes) is larger than OFFLINE_MAX_MINUTES=\(s.maxMinutes) (in \(source)); keeping the defaults \(defaultMin) and \(defaultMax)")
            s.minMinutes = defaultMin
            s.maxMinutes = defaultMax
        }
        if let raw = values["OFFLINE_REQUIRE_GUESTS"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let on = AppConfig.parseSwitch(raw) {
                s.requireGuests = on
            } else {
                Log.warn("config: OFFLINE_REQUIRE_GUESTS=\(raw) must be 1 or 0 (or true/false, yes/no, on/off) (in \(source)); keeping default (on)")
            }
        }
        return s
    }

    /// One line for app.log.
    var summary: String {
        guard isOn else { return "calendar auto-start: off (OFFLINE_AUTOSTART)" }
        return "calendar auto-start: auto; start from \(startBeforeMinutes) min before to \(startAfterMinutes) min after the event start, stop \(stopAfterEndMinutes) min after its end, "
            + "idle limit \(idleMaxMinutes) min, \(requireGuests ? "needs another attendee" : "no attendee needed"), event length \(minMinutes)...\(maxMinutes) min"
    }
}
