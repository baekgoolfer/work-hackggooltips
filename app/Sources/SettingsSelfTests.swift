import AppKit
import Foundation

// =====================================================================================
// Self tests of the Settings window's model (SettingsModel.swift, SettingsConfigWriter.swift, SettingsKeychain.swift, SettingsBackend.swift) and of the
// menu-bar icon mapping (StatusMenu.swift `menuIcon`). `runSettingsSelfTests()` is hooked into selftest-session (SelfTests.swift, before S-LO-01).
//
// Device-free: no window, no real Keychain (a closure that stands for /usr/bin/security, and a shell shim for the process-level checks), no network,
// no Terminal, no real python (a fake one), no real config.env: everything happens in a temp directory. The key canary below must never show up in
// an argument, an environment, a log, a file or a status text; the consent file is never written by anything in here.
//
// The shared corpus pipeline/tests/fixtures/settings_parity.json (cloud-engine addresses, config.env parsing, the exact bytes of the writer) is read by
// pipeline/tests/test_settings_parity.py as well, so that the Python and the Swift side cannot drift apart without one of the two failing.
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

/// A key that no argument, environment, log, file or text may ever contain (built from pieces so that a secret scanner does not take the source for a key).
private let settingsCanary = "sk-" + "ant-api03-" + "SETTINGS-CANARY-" + String(repeating: "7", count: 24)
private let engineCanary = "ENGINEKEY-" + String(repeating: "Q", count: 30)

private func hasHangulText(_ s: String) -> Bool { s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }

private func appLogText() -> String {
    Log.flush()
    return (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
}

private func repoRoot() -> URL? {
    let env = ProcessInfo.processInfo.environment
    var candidates: [URL] = []
    if let explicit = env["MC_POLICY_FIXTURES"], !explicit.isEmpty {
        candidates.append(URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true).deletingLastPathComponent().deletingLastPathComponent())
    }
    candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    var exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    for _ in 0..<5 { exe.deleteLastPathComponent() }
    candidates.append(exe)
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pipeline/mcap/cli.py").path) }
}

private func source(_ repo: URL, _ path: String) -> String {
    return (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// A policy through the real strict parser (the one the app reads policy.json with).
private func settingsPolicy(profile: String = "company", extra: [String: Any] = [:]) -> OrgPolicy {
    var object: [String: Any] = ["schema": 1, "profile": profile, "revision": 3, "support": ["contact": "IT helpdesk"]]
    for (key, value) in extra { object[key] = value }
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return OrgPolicy.parse(data)
}

private func canon(_ key: String, _ raw: String) -> String? {
    guard let field = SettingsCatalog.field(key) else { return nil }
    if case .success(let v) = SettingsValue.canonical(raw, for: field) { return v }
    return nil
}

// MARK: - Fakes

/// Stands for /usr/bin/security: remembers the items it was given by `-i` (parsed from the command on stdin), answers the read-back, the status and the delete.
private final class FakeKeychain {
    struct Call { var args: [String]; var stdin: String?; var capture: Bool }
    private(set) var calls: [Call] = []
    var items: [String: String] = [:]               // "service|account" -> the value (decoded from the hex)
    var dropStores = false                          // `security -i` that exits 0 and stores nothing (it does not report failures)
    var launches = true
    var status: Int32? = nil

    var runner: SecurityRunner {
        return { [self] args, stdin, capture in
            let text = stdin.flatMap { String(data: $0, encoding: .utf8) }
            calls.append(Call(args: args, stdin: text, capture: capture))
            guard launches else { return SecurityRunResult(launched: false, status: -1) }
            if let forced = status { return SecurityRunResult(launched: true, status: forced) }
            if args == ["-i"], let line = text, let item = FakeKeychain.parse(line) {
                if !dropStores { items["\(item.service)|\(item.account)"] = item.value }
                return SecurityRunResult(launched: true, status: 0)
            }
            guard let verb = args.first, let s = args.firstIndex(of: "-s"), let a = args.firstIndex(of: "-a"), s + 1 < args.count, a + 1 < args.count else {
                return SecurityRunResult(launched: true, status: 2)
            }
            let id = "\(args[s + 1])|\(args[a + 1])"
            switch verb {
            case "find-generic-password":
                guard let value = items[id] else { return SecurityRunResult(launched: true, status: 44) }
                return SecurityRunResult(launched: true, status: 0, stdout: capture ? Data((value + "\n").utf8) : Data())
            case "delete-generic-password":
                return SecurityRunResult(launched: true, status: items.removeValue(forKey: id) == nil ? 44 : 0)
            default:
                return SecurityRunResult(launched: true, status: 2)
            }
        }
    }

    static func parse(_ line: String) -> (account: String, service: String, value: String)? {
        guard let re = try? NSRegularExpression(pattern: #"^add-generic-password -U -a "([^"]*)" -s "([^"]*)" -X ([0-9a-f]+)\n$"#),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), m.numberOfRanges == 4 else { return nil }
        func part(_ i: Int) -> String { String(line[Range(m.range(at: i), in: line)!]) }
        var bytes: [UInt8] = []
        let hex = Array(part(3))
        var i = 0
        while i + 1 < hex.count { bytes.append(UInt8(String(hex[i...i + 1]), radix: 16) ?? 0); i += 2 }
        return (part(1), part(2), String(decoding: bytes, as: UTF8.self))
    }
}

/// The coordinator against a temp folder: every effect is a recorder.
private final class SettingsHarness {
    let dir: URL
    let file: URL
    let keychain = FakeKeychain()
    var policy: OrgPolicy = OrgPolicy.absent()
    var mcap: [McapCommand: McapRun] = [:]
    private(set) var mcapCalls: [McapCommand] = []
    private(set) var terminalFiles: [URL] = []
    var terminalOpens = true
    var recording = false
    var hold: RestartHold? = nil
    var bundle: String? = "/Applications/\(AppInfo.shortName).app"
    var spawnWorks = true
    private(set) var spawned: [String] = []
    private(set) var terminated = 0
    var ops = ConfigFileOps()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let user = "tester"

    init(_ base: URL, name: String, config: String? = nil) {
        dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("tmp", isDirectory: true), withIntermediateDirectories: true)
        file = dir.appendingPathComponent("config.env")
        if let text = config { try? text.write(to: file, atomically: true, encoding: .utf8) }
    }

    var coordinator: SettingsCoordinator {
        var env = SettingsEnvironment(
            configFile: { [self] in file },
            policy: { [self] in policy },
            runMcap: { [self] command in mcapCalls.append(command); return mcap[command] ?? McapRun(launched: true, status: 1, timedOut: false, output: "") },
            openTerminal: { [self] url in terminalFiles.append(url); return terminalOpens },
            python: { [self] in dir.appendingPathComponent("venv/bin/python") },
            pipelineDir: { [self] in dir.appendingPathComponent("project/pipeline", isDirectory: true) },
            isRecording: { [self] in recording })
        env.restartHold = { [self] in hold }
        env.user = { [self] in user }
        env.keychain = { [self] in SettingsKeychain(run: keychain.runner) }
        env.tempDir = { [self] in dir.appendingPathComponent("tmp", isDirectory: true) }
        env.now = { [self] in clock }
        env.fileOps = ops
        env.bundlePath = { [self] in bundle }
        env.spawnRestart = { [self] path in spawned.append(path); return spawnWorks }
        env.terminate = { [self] in terminated += 1 }
        return SettingsCoordinator(env: env)
    }

    var text: String? { try? String(contentsOf: file, encoding: .utf8) }
    var backups: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("config.env.bak-settings-") }.sorted() }
}

// MARK: - Entry point

/// Runs every check of this file and returns the counts. Leaves no environment variable or global changed (the language is put back).
func runSettingsSelfTests() -> (pass: Int, fail: Int) {
    passed = 0
    failed = 0
    let savedLanguage = L10n.current
    defer { L10n.current = savedLanguage }
    let tmpRoot = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
    let base = URL(fileURLWithPath: tmpRoot, isDirectory: true).standardizedFileURL.appendingPathComponent("mcap-selftest-settings-\(getpid())", isDirectory: true)
    let fm = FileManager.default
    try? fm.removeItem(at: base)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    L10n.current = .en
    testSettingsCatalog()
    testSettingsValueRules()
    testSettingsParsersAgree()
    testSettingsSnapshot()
    testSettingsUnreadable()
    testSettingsChanges()
    testSettingsEditor()
    testSettingsCorpus()
    testSettingsWriter(base)
    testSettingsKeychain()
    testSettingsKeychainProcess(base)
    testSettingsDestinations()
    testSettingsCommands(base)
    testSettingsInterpreters()
    testSettingsTerminal(base)
    testSettingsRestart(base)
    testSettingsCoordinator(base)
    testSettingsFolderChecker()
    testSettingsPrivacy()
    testSettingsPrivacyFollowsLanes()
    testSettingsMenuIcon()
    testSettingsDriftGuards()
    L10n.current = .ko
    testSettingsKorean()
    return (passed, failed)
}

// MARK: - Catalog

private func testSettingsCatalog() {
    section("settings: the catalog")
    let fields = SettingsCatalog.fields
    let keys = SettingsCatalog.keys
    check(keys.count == 20 && Set(keys).count == 20, "twenty distinct keys", "\(keys.count)")
    check(keys.allSatisfy { ConfigEnvEditor.isValidKey($0) }, "every key is a valid config.env key name")
    check(Set(fields.map { $0.tab }) == Set(SettingsTab.allCases), "every one of the five tabs has fields", "\(Set(fields.map { $0.tab }))")
    check(SettingsTab.allCases.map { $0.rawValue } == ["general", "claude", "transcription", "detection", "privacy"], "the tabs are General, Claude, Transcription, Detection, Privacy")
    check(!keys.contains { $0.contains("API_KEY") || $0.contains("TOKEN") || $0.contains("SECRET") || $0.contains("PASSWORD") || $0.hasSuffix("_KEY") },
          "no key of the catalog is a secret: secrets are Keychain items, never config.env keys")
    for tab in SettingsTab.allCases {
        let expected: [String: [String]] = [
            "general": ["UI_LANGUAGE", "ARCHIVE_DIR", "SELF_NAME"],
            "claude": ["CLAUDE_AUTH", "NOTE_MODEL", "CLAUDE_DAILY_BUDGET_USD", "CLAUDE_MEETING_BUDGET_USD"],
            "transcription": ["ASR_ENGINE", "ASR_STRATEGY", "ASR_CLOVA_INVOKE_URL", "ASR_OPENAI_COMPAT_URL", "ASR_OPENAI_COMPAT_MODEL"],
            "detection": ["ENABLED_PLATFORMS", "CALL_DETECT", "CALL_BROWSER_URLS", "EXTRA_MEETING_APPS", "OFFLINE_AUTOSTART"],
            "privacy": ["LOCAL_ONLY_DEFAULT", "NOTIFY_RECORDING", "LOG_CONTENT"],
        ]
        check(SettingsCatalog.fields(in: tab).map { $0.key } == expected[tab.rawValue], "tab \(tab.rawValue) edits exactly its keys", "\(SettingsCatalog.fields(in: tab).map { $0.key })")
    }
    check(SettingsCatalog.field("ASR_ENGINE")?.kind == .choice(PrivacySettings.engineWords), "ASR_ENGINE offers the engines the app already knows (PrivacySettings.engineWords, clova and openai-compat included)")
    check(PrivacySettings.engineWords.contains("clova") && PrivacySettings.engineWords.contains("openai-compat"), "the engine words include clova and openai-compat")
    check(fields.allSatisfy { if case .success = SettingsValue.canonical($0.defaultValue, for: $0) { return true } else { return false } }, "every default is a value its own rule accepts")
    for language in [UILanguage.en, .ko] {
        L10n.current = language
        check(fields.allSatisfy { !$0.title.isEmpty && !$0.hint.isEmpty } && SettingsTab.allCases.allSatisfy { !$0.title.isEmpty }, "every title and hint exists in \(language.rawValue)")
    }
    L10n.current = .ko
    check(fields.allSatisfy { hasHangulText($0.title) && hasHangulText($0.hint) }, "every title and hint is translated to Korean")
    L10n.current = .en
    check(!fields.contains { hasHangulText($0.title) || hasHangulText($0.hint) }, "the English texts have no Korean in them")
    check(fields.filter { $0.needsRestart }.count > 0 && SettingsCatalog.field("NOTE_MODEL")?.needsRestart == false && SettingsCatalog.field("UI_LANGUAGE")?.needsRestart == true,
          "the app's keys need a restart, the pipeline's keys apply from the next run")
}

// MARK: - Value rules

private func testSettingsValueRules() {
    section("settings: what a typed text means (the rules of the parsers)")
    let cases: [(String, String, String?)] = [
        ("UI_LANGUAGE", "ko", "ko"), ("UI_LANGUAGE", " KO ", "ko"), ("UI_LANGUAGE", "fr", nil), ("UI_LANGUAGE", "", nil),
        ("CLAUDE_AUTH", "API", "api"), ("CLAUDE_AUTH", "subscription", "subscription"), ("CLAUDE_AUTH", "maybe", nil),
        ("ASR_STRATEGY", "single", "single"), ("ASR_STRATEGY", "triple", nil),
        ("ASR_ENGINE", "clova", "clova"), ("ASR_ENGINE", "openai-compat", "openai-compat"), ("ASR_ENGINE", "google", nil),
        ("CALL_DETECT", "generic", "generic"), ("CALL_DETECT", "on", nil),
        ("ARCHIVE_DIR", "~/Meetings", "~/Meetings"), ("ARCHIVE_DIR", "/Volumes/Share/Meetings 2026", "/Volumes/Share/Meetings 2026"), ("ARCHIVE_DIR", "Meetings", nil),
        ("ARCHIVE_DIR", "~/Meetings #1", nil), ("ARCHIVE_DIR", "\"~/Meetings\"", nil), ("ARCHIVE_DIR", "~/a\nb", nil), ("ARCHIVE_DIR", "", ""),
        ("ARCHIVE_DIR", "/tmp/x\u{0}y", nil), ("ARCHIVE_DIR", "/tmp/a'", nil),
        ("SELF_NAME", "Sam", "Sam"), ("SELF_NAME", "  Sam  ", "Sam"), ("SELF_NAME", "", ""), ("SELF_NAME", String(repeating: "x", count: 61), nil),
        ("SELF_NAME", "Sam # me", nil), ("SELF_NAME", "A\tB", nil), ("SELF_NAME", "UI_LANGUAGE=ko", nil), ("SELF_NAME", "Sam=1", "Sam=1"),
        ("NOTE_MODEL", "opus", "opus"), ("NOTE_MODEL", "claude-opus-4-1", "claude-opus-4-1"), ("NOTE_MODEL", "sonnet[1m]", "sonnet[1m]"), ("NOTE_MODEL", "-x", nil),
        ("NOTE_MODEL", "two words", nil), ("NOTE_MODEL", "a=b", nil), ("NOTE_MODEL", "", ""),
        ("CLAUDE_DAILY_BUDGET_USD", "5", "5"), ("CLAUDE_DAILY_BUDGET_USD", "5.0", "5"), ("CLAUDE_DAILY_BUDGET_USD", "2.50", "2.5"), ("CLAUDE_DAILY_BUDGET_USD", "0", "0"),
        ("CLAUDE_DAILY_BUDGET_USD", "-1", nil), ("CLAUDE_DAILY_BUDGET_USD", "1e3", nil), ("CLAUDE_DAILY_BUDGET_USD", "abc", nil), ("CLAUDE_DAILY_BUDGET_USD", "$5", nil),
        ("CLAUDE_DAILY_BUDGET_USD", "nan", nil), ("CLAUDE_DAILY_BUDGET_USD", "inf", nil), ("CLAUDE_DAILY_BUDGET_USD", "5,5", nil), ("CLAUDE_MEETING_BUDGET_USD", "0.05", "0.05"),
        ("ENABLED_PLATFORMS", "zoom,teams", "zoom,teams"), ("ENABLED_PLATFORMS", "Meet, ZOOM", "zoom,meet"), ("ENABLED_PLATFORMS", "", ""), ("ENABLED_PLATFORMS", "call", nil),
        ("ENABLED_PLATFORMS", "zoom,webex", nil), ("ENABLED_PLATFORMS", "teams,teams", "teams"),
        ("CALL_BROWSER_URLS", "on", "1"), ("CALL_BROWSER_URLS", "OFF", "0"), ("CALL_BROWSER_URLS", "true", "1"), ("CALL_BROWSER_URLS", "maybe", nil),
        ("LOCAL_ONLY_DEFAULT", "1", "1"), ("LOCAL_ONLY_DEFAULT", "no", "0"), ("LOCAL_ONLY_DEFAULT", "2", nil),
        ("OFFLINE_AUTOSTART", "auto", "1"), ("OFFLINE_AUTOSTART", "off", "0"), ("OFFLINE_AUTOSTART", "on", nil), ("OFFLINE_AUTOSTART", "1", nil),
        ("EXTRA_MEETING_APPS", "com.example.talk=Example Talk", "com.example.talk=Example Talk"), ("EXTRA_MEETING_APPS", "com.example.a, com.example.b", "com.example.a, com.example.b"),
        ("EXTRA_MEETING_APPS", "notabundle", nil), ("EXTRA_MEETING_APPS", "com.google.Chrome", nil), ("EXTRA_MEETING_APPS", "us.zoom.xos", nil), ("EXTRA_MEETING_APPS", "com.example.a # x", nil),
        ("EXTRA_MEETING_APPS", "", ""),
        ("ASR_CLOVA_INVOKE_URL", "https://clovaspeech-gw.ncloud.com/external/v1/abc/def", "https://clovaspeech-gw.ncloud.com/external/v1/abc/def"),
        ("ASR_CLOVA_INVOKE_URL", "https://example.com/x", nil), ("ASR_CLOVA_INVOKE_URL", "http://gw.ncloud.com/x", nil), ("ASR_CLOVA_INVOKE_URL", "", ""),
        ("ASR_OPENAI_COMPAT_URL", "https://api.openai.com/v1", "https://api.openai.com/v1"), ("ASR_OPENAI_COMPAT_URL", "https://10.0.0.5/v1", nil),
        ("ASR_OPENAI_COMPAT_URL", "https://api.example.com/v1?key=abc", nil), ("ASR_OPENAI_COMPAT_MODEL", "whisper-1", "whisper-1"), ("ASR_OPENAI_COMPAT_MODEL", "my model", nil),
        ("ASR_OPENAI_COMPAT_MODEL", "Systran/faster-whisper-large-v3", "Systran/faster-whisper-large-v3"), ("ASR_OPENAI_COMPAT_MODEL", "openai/whisper-large-v3", "openai/whisper-large-v3"),
        ("ASR_OPENAI_COMPAT_MODEL", "whisper-large-v3:latest", "whisper-large-v3:latest"), ("ASR_OPENAI_COMPAT_MODEL", String(repeating: "m", count: 100), String(repeating: "m", count: 100)),
        ("ASR_OPENAI_COMPAT_MODEL", String(repeating: "m", count: 101), nil), ("ASR_OPENAI_COMPAT_MODEL", "\u{e9}t\u{e9}", nil), ("ASR_OPENAI_COMPAT_MODEL", "a\tb", nil),
        ("ASR_OPENAI_COMPAT_MODEL", "\"quoted\"", nil), ("ASR_OPENAI_COMPAT_MODEL", "#x", nil), ("ASR_OPENAI_COMPAT_MODEL", "WHISPER=1", nil), ("ASR_OPENAI_COMPAT_MODEL", "", ""),
        ("NOTE_MODEL", "Systran/x", nil),
    ]
    var wrong: [String] = []
    for (key, raw, expected) in cases {
        let got = canon(key, raw)
        if got != expected { wrong.append("\(key)=\(raw.debugDescription): \(got.map { $0.debugDescription } ?? "refused") (wanted \(expected.map { $0.debugDescription } ?? "refused"))") }
    }
    check(wrong.isEmpty, "\(cases.count) typed texts are accepted or refused exactly as the rules say", wrong.joined(separator: " | "))
    check(AppConfig.isAbsolutePathValue("/a") && AppConfig.isAbsolutePathValue("~/a") && !AppConfig.isAbsolutePathValue("a/b") && !AppConfig.isAbsolutePathValue(""),
          "AppConfig.isAbsolutePathValue is the rule of Config.swift for a path")
    if case .failure(let e) = SettingsValue.canonical("-1", for: SettingsCatalog.field("CLAUDE_DAILY_BUDGET_USD")!) { check(e.message.contains("plain number"), "a refused number says what a good one looks like", e.message) }
    else { check(false, "a negative budget is refused") }
    check(SettingsValue.toggleWords(on: true, field: SettingsCatalog.field("LOCAL_ONLY_DEFAULT")!, existing: "false") == "true"
          && SettingsValue.toggleWords(on: false, field: SettingsCatalog.field("LOCAL_ONLY_DEFAULT")!, existing: "true") == "false"
          && SettingsValue.toggleWords(on: true, field: SettingsCatalog.field("LOCAL_ONLY_DEFAULT")!, existing: nil) == "1"
          && SettingsValue.toggleWords(on: true, field: SettingsCatalog.field("CALL_BROWSER_URLS")!, existing: nil) == "on"
          && SettingsValue.toggleWords(on: false, field: SettingsCatalog.field("CALL_BROWSER_URLS")!, existing: "yes") == "no"
          && SettingsValue.toggleWords(on: true, field: SettingsCatalog.field("OFFLINE_AUTOSTART")!, existing: "off") == "auto"
          && SettingsValue.toggleWords(on: false, field: SettingsCatalog.field("OFFLINE_AUTOSTART")!, existing: "auto") == "off",
          "a switch is written in the words the file already uses (true/false stays true/false); OFFLINE_AUTOSTART is auto/off")
}

/// What the window writes is what the real parsers read: the same functions as the app and the pipeline use.
private func testSettingsParsersAgree() {
    section("settings: the real parsers read what the window writes")
    var cfg = AppConfig.build(from: ["UI_LANGUAGE": "ko", "CLAUDE_AUTH": "subscription", "SELF_NAME": "Sam", "ARCHIVE_DIR": "~/Notes Archive", "NOTIFY_RECORDING": "false"], source: "settings-test")
    check(cfg.uiLanguage == .ko && cfg.claudeAuth == .subscription && cfg.selfName == "Sam" && cfg.notifyRecording == false, "AppConfig reads UI_LANGUAGE, CLAUDE_AUTH, SELF_NAME and NOTIFY_RECORDING as written")
    check(cfg.archiveDir.path == NSHomeDirectory() + "/Notes Archive", "AppConfig reads ARCHIVE_DIR with ~ expanded", cfg.archiveDir.path)
    cfg = AppConfig.build(from: ["ENABLED_PLATFORMS": "zoom,meet"], source: "settings-test")
    check(cfg.enabledPlatforms == [.zoom, .meet], "AppConfig reads ENABLED_PLATFORMS=zoom,meet")
    cfg = AppConfig.build(from: ["ENABLED_PLATFORMS": ""], source: "settings-test")
    check(cfg.enabledPlatforms.isEmpty, "an empty ENABLED_PLATFORMS is read as no automatic detection (the value the window writes for no box checked)")
    let call = CallDetectSettings.build(from: ["CALL_DETECT": "generic", "CALL_BROWSER_URLS": "on", "EXTRA_MEETING_APPS": "com.example.talk=Example Talk"], source: "settings-test")
    check(call.mode == .generic && call.browserURLs && call.extraApps.map { $0.id } == ["com.example.talk"] && call.extraApps.first?.name == "Example Talk", "CallDetectSettings reads CALL_DETECT, CALL_BROWSER_URLS and EXTRA_MEETING_APPS as written")
    check(OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": "auto"], source: "settings-test").isOn && !OfflineAutostartSettings.build(from: ["OFFLINE_AUTOSTART": "off"], source: "settings-test").isOn, "OfflineAutostartSettings reads auto and off")
    let privacy = PrivacySettings.build(from: ["LOCAL_ONLY_DEFAULT": "1", "LOG_CONTENT": "0", "ASR_ENGINE": "clova"], supportDir: AppConfig.defaultSupportDir, source: "settings-test")
    check(privacy.localOnlyDefault && !privacy.logContent && privacy.asrEngine == "clova", "PrivacySettings reads LOCAL_ONLY_DEFAULT, LOG_CONTENT and ASR_ENGINE as written")
    // every word the window offers for a choice is a word of the enum the app parses it with (the Python side: test_settings_parity.py)
    func words(_ key: String) -> [String] {
        if case .choice(let w)? = SettingsCatalog.field(key)?.kind { return w }
        return []
    }
    check(words("UI_LANGUAGE").count == 2 && words("UI_LANGUAGE").allSatisfy { UILanguage(rawValue: $0) != nil }, "UI_LANGUAGE: both words are UILanguage cases")
    check(words("CLAUDE_AUTH").count == 2 && words("CLAUDE_AUTH").allSatisfy { ClaudeAuthMode(rawValue: $0) != nil }, "CLAUDE_AUTH: both words are ClaudeAuthMode cases")
    check(words("CALL_DETECT").count == 3 && words("CALL_DETECT").allSatisfy { CallDetectSettings.Mode(rawValue: $0) != nil }, "CALL_DETECT: all three words are CallDetectSettings.Mode cases")
    check(words("ASR_ENGINE").allSatisfy { PrivacySettings.engineWords.contains($0) }, "ASR_ENGINE: every word is one of PrivacySettings.engineWords")
    check(SettingsCatalog.platformWords.allSatisfy { Platform(rawValue: $0) != nil && $0 != Platform.call.rawValue && $0 != Platform.manual.rawValue }, "the platform words are Platform cases that ENABLED_PLATFORMS accepts")
    for (key, value) in [("UI_LANGUAGE", "en"), ("CLAUDE_AUTH", "api"), ("CALL_DETECT", "known"), ("CALL_DETECT", "off")] {
        check(canon(key, value) == value, "\(key)=\(value) is a value of the catalog")
    }
}

// MARK: - Snapshot and changes

private func testSettingsSnapshot() {
    section("settings: the snapshot (what every control shows, what the policy locks)")
    let empty = SettingsSnapshot.load(text: nil, policy: OrgPolicy.absent())
    check(empty.states.count == 20 && !empty.managed, "an absent file shows twenty controls on an unmanaged Mac")
    check(empty.states.allSatisfy { $0.fileValue == nil && $0.lock == nil && $0.problem == nil }, "an absent file: no value, no lock, no problem")
    let defaults = Dictionary(uniqueKeysWithValues: empty.states.map { ($0.field.key, $0.shown) })
    check(defaults["UI_LANGUAGE"] == "en" && defaults["ARCHIVE_DIR"] == "~/Meetings" && defaults["SELF_NAME"] == "Me" && defaults["CLAUDE_AUTH"] == "api" && defaults["NOTE_MODEL"] == "opus"
          && defaults["CLAUDE_DAILY_BUDGET_USD"] == "5" && defaults["CLAUDE_MEETING_BUDGET_USD"] == "2" && defaults["ASR_ENGINE"] == "whisper" && defaults["ASR_STRATEGY"] == "dual"
          && defaults["ENABLED_PLATFORMS"] == "zoom,teams" && defaults["CALL_DETECT"] == "known" && defaults["CALL_BROWSER_URLS"] == "0" && defaults["OFFLINE_AUTOSTART"] == "0"
          && defaults["LOCAL_ONLY_DEFAULT"] == "0" && defaults["NOTIFY_RECORDING"] == "1" && defaults["LOG_CONTENT"] == "1" && defaults["ASR_OPENAI_COMPAT_MODEL"] == "whisper-1",
          "the defaults shown are the defaults of the code", "\(defaults)")

    let text = "# my settings\nUI_LANGUAGE=KO   # korean\nCLAUDE_DAILY_BUDGET_USD = 7.50\nENABLED_PLATFORMS=zoom,teams,meet\nLOCAL_ONLY_DEFAULT=true\nCALL_DETECT=maybe\nNOTE_MODEL=\nUNKNOWN_KEY=1\n"
    let snap = SettingsSnapshot.load(text: text, policy: OrgPolicy.absent())
    check(snap.state("UI_LANGUAGE")?.shown == "ko" && snap.state("UI_LANGUAGE")?.fileValue == "KO", "a stored value is shown in its canonical form")
    check(snap.state("CLAUDE_DAILY_BUDGET_USD")?.shown == "7.5", "a number is shown without trailing zeros")
    check(snap.state("ENABLED_PLATFORMS")?.shown == "zoom,teams,meet" && snap.state("LOCAL_ONLY_DEFAULT")?.shown == "1", "a list and a switch are read like the app reads them")
    check(snap.state("CALL_DETECT")?.problem != nil && snap.state("CALL_DETECT")?.shown == "known", "a typo is flagged and the control shows what the app reads (the default)")
    check(snap.state("NOTE_MODEL")?.shown == "opus" && snap.state("NOTE_MODEL")?.problem == nil, "an empty value counts as unset")
    check(snap.effective["UNKNOWN_KEY"] == "1", "unknown keys stay in the layered values (and in the file)")

    let managed = SettingsSnapshot.load(text: "", policy: settingsPolicy())
    check(managed.managed && managed.state("CALL_DETECT")?.shown == "off", "on a managed Mac an unset CALL_DETECT shows off (the code reads it as off)")
    let enforced = settingsPolicy(extra: ["enforced": ["NOTE_MODEL": "sonnet", "CLAUDE_AUTH": "subscription"], "defaults": ["ASR_ENGINE": "whisper", "CALL_DETECT": "off", "CALL_BROWSER_URLS": "on"]])
    let locked = SettingsSnapshot.load(text: "NOTE_MODEL=opus\nCALL_DETECT=generic\n", policy: enforced)
    check(locked.state("NOTE_MODEL")?.lock == .policy && locked.state("NOTE_MODEL")?.shown == "sonnet", "an enforced key is locked and shows the policy's value, whatever the file says")
    check(locked.state("CLAUDE_AUTH")?.lock == .policy && locked.state("LOG_CONTENT")?.lock == .policy && locked.state("LOG_CONTENT")?.shown == "0" && locked.state("NOTIFY_RECORDING")?.lock == .policy,
          "every enforced key is locked, the company baseline (LOG_CONTENT, NOTIFY_RECORDING) included")
    check(locked.state("CALL_BROWSER_URLS")?.lock == nil && locked.state("CALL_BROWSER_URLS")?.fromPolicyDefault == true && locked.state("CALL_BROWSER_URLS")?.shown == "1", "a policy DEFAULT is no lock: it shows until the file says otherwise")
    check(locked.state("CALL_DETECT")?.lock == nil && locked.state("CALL_DETECT")?.shown == "generic" && locked.state("CALL_DETECT")?.fromPolicyDefault == false, "the file wins over a policy default")
    check(locked.state("UI_LANGUAGE")?.lock == nil && locked.state("SELF_NAME")?.lock == nil && locked.state("ARCHIVE_DIR")?.lock == nil, "keys that no policy can set stay editable")
    check(SettingsLock.policy.reason == "Fixed by organisation policy", "the lock reason is plain words")
    let lockedLO = SettingsSnapshot.load(text: "LOCAL_ONLY_DEFAULT=0\n", policy: settingsPolicy(extra: ["local_only": ["default": true, "locked": true]]))
    check(lockedLO.state("LOCAL_ONLY_DEFAULT")?.lock == .localOnly && lockedLO.state("LOCAL_ONLY_DEFAULT")?.shown == "1", "Local-Only fixed by the policy: the switch is locked on, whatever the file says")
    let defaultLO = SettingsSnapshot.load(text: "LOCAL_ONLY_DEFAULT=0\n", policy: settingsPolicy(extra: ["local_only": ["default": true, "locked": false]]))
    check(defaultLO.state("LOCAL_ONLY_DEFAULT")?.lock == .localOnlyDefault && defaultLO.state("LOCAL_ONLY_DEFAULT")?.shown == "1" && SettingsLock.localOnlyDefault.reason.contains("single meeting"),
          "a policy whose default is Local-Only: the start value is policy OR file, so the switch shows on and cannot be turned off here (a meeting still can in the menu)")
    let openLO = SettingsSnapshot.load(text: "", policy: settingsPolicy(extra: ["local_only": ["default": false, "locked": false]]))
    check(openLO.state("LOCAL_ONLY_DEFAULT")?.lock == nil && openLO.state("LOCAL_ONLY_DEFAULT")?.shown == "0", "a policy that does not default to Local-Only leaves the switch free")
    let broken = SettingsSnapshot.load(text: "", policy: OrgPolicy.locked("bad-json"))
    check(broken.state("LOG_CONTENT")?.lock == .policy && broken.state("LOCAL_ONLY_DEFAULT")?.lock == .localOnly, "a policy that cannot be read keeps the company baseline locked, and Local-Only")
}

/// A typo does not always read as the default: a switch that fails closed, a misspelt CLAUDE_AUTH, a word list that falls back to the harmless word, a budget that is
/// no number. The window must show what the code reads, and say so; every rule is checked against the real parser (and, for the pipeline, against the shared corpus
/// that test_settings_parity.py runs through config.py).
private func testSettingsUnreadable() {
    section("settings: a stored text that is not understood is shown as what the code reads, not as the default")
    func state(_ key: String, _ text: String, policy: OrgPolicy = OrgPolicy.absent()) -> SettingsFieldState? {
        SettingsSnapshot.load(text: "\(key)=\(text)\n", policy: policy).state(key)
    }
    let support = AppConfig.defaultSupportDir
    for text in ["ture", "2", "maybe"] {
        let reads = PrivacySettings.build(from: ["LOCAL_ONLY_DEFAULT": text], supportDir: support, source: "settings-test").localOnlyDefault
        let st = state("LOCAL_ONLY_DEFAULT", text)
        check(reads && st?.shown == "1" && st?.problem?.contains("read as 1") == true, "LOCAL_ONLY_DEFAULT=\(text): PrivacySettings reads it as on (fail closed), so the switch shows on and says so", "\(st?.shown ?? "nil") \(st?.problem ?? "nil")")
    }
    for text in ["ofn", "maybe"] {
        let reads = PrivacySettings.build(from: ["LOG_CONTENT": text], supportDir: support, source: "settings-test").logContent
        let st = state("LOG_CONTENT", text)
        check(!reads && st?.shown == "0" && st?.problem?.contains("read as 0") == true, "LOG_CONTENT=\(text): PrivacySettings reads it as off (fail closed), so the switch shows off and says so", "\(st?.shown ?? "nil") \(st?.problem ?? "nil")")
    }
    let auth = AppConfig.build(from: ["CLAUDE_AUTH": "apii"], source: "settings-test").claudeAuth
    let authState = state("CLAUDE_AUTH", "apii")
    check(auth == .subscription && authState?.shown == auth.rawValue && authState?.problem?.contains("no Claude call") == true,
          "CLAUDE_AUTH=apii: AppConfig reads subscription and the pipeline makes no Claude call: the control shows subscription and the message says no call is made", "\(authState?.shown ?? "nil") \(authState?.problem ?? "nil")")
    let strategy = state("ASR_STRATEGY", "triple")
    check(strategy?.shown == "single" && strategy?.problem?.contains("single") == true, "ASR_STRATEGY=triple: config.py's _Enum falls back to single (corpus below), not to the default dual", "\(strategy?.shown ?? "nil")")
    for key in ["CLAUDE_DAILY_BUDGET_USD", "CLAUDE_MEETING_BUDGET_USD"] {
        let st = state(key, "$5")
        check(st?.problem?.contains("does not run") == true && st?.problem?.contains("default") != true, "\(key)=$5 is no number: the pipeline refuses to run, and the window says that, not 'reads the default'", st?.problem ?? "nil")
    }
    let typo = "maybe"
    for (managed, policy) in [(false, OrgPolicy.absent()), (true, settingsPolicy())] {
        let reads = CallDetectSettings.build(from: ["CALL_DETECT": typo], source: "settings-test", unsetMode: managed ? .off : .known).mode.rawValue
        let st = state("CALL_DETECT", typo, policy: policy)
        check(reads == "known" && st?.shown == reads && st?.problem?.contains("known") == true, "CALL_DETECT=\(typo)\(managed ? " on a managed Mac" : ""): CallDetectSettings reads known, so the control shows known", "\(st?.shown ?? "nil") \(st?.problem ?? "nil")")
    }
    check(state("CALL_DETECT", "")?.shown == "known" && SettingsSnapshot.load(text: "", policy: settingsPolicy()).state("CALL_DETECT")?.shown == "off", "an UNSET CALL_DETECT still reads off on a managed Mac (only a typo reads known)")

    // the shared corpus: the same rows run through config.py by test_settings_parity.py
    guard let corpus = loadParityCorpus(), let rows = corpus["reads_as"] as? [[String: Any]] else { check(false, "the corpus has reads_as rows"); return }
    var wrong: [String] = []
    for row in rows {
        guard let key = row["key"] as? String, let text = row["text"] as? String, let problem = row["problem"] as? Bool, let st = state(key, text) else { continue }
        let name = "\(key)=\(text.debugDescription)"
        if (st.problem != nil) != problem { wrong.append("\(name): problem \(st.problem ?? "nil")") }
        if let shown = row["shown"] as? String, st.shown != shown { wrong.append("\(name): shows \(st.shown), wanted \(shown)") }
        if row["shown"] is NSNull, st.problem?.contains("does not run") != true { wrong.append("\(name): no 'does not run'") }
    }
    check(rows.count >= 10 && wrong.isEmpty, "\(rows.count) stored texts show what config.py reads for them", wrong.joined(separator: " | "))

    // saving: an untouched typo stays as it is; a touched control replaces it, even by the value it already shows
    let typoSnap = SettingsSnapshot.load(text: "CLAUDE_AUTH=apii\nLOCAL_ONLY_DEFAULT=ture\n", policy: OrgPolicy.absent())
    check(typoSnap.changes(touched: [:]).changes.isEmpty && typoSnap.changes(touched: ["CLAUDE_AUTH": "subscription"]).changes == [ConfigChange(key: "CLAUDE_AUTH", value: "subscription")]
          && typoSnap.changes(touched: ["CLAUDE_AUTH": "api"]).changes == [ConfigChange(key: "CLAUDE_AUTH", value: "api")]
          && typoSnap.changes(touched: ["LOCAL_ONLY_DEFAULT": "0"]).changes == [ConfigChange(key: "LOCAL_ONLY_DEFAULT", value: "0")],
          "an untouched typo is left alone; picking a value (even the one shown) writes it")
}

private func testSettingsChanges() {
    section("settings: the changes to write (only touched controls, nothing for an unchanged one)")
    let text = "UI_LANGUAGE=en\nLOCAL_ONLY_DEFAULT=false\nNOTE_MODEL=sonnet\nCALL_DETECT=maybe\nENABLED_PLATFORMS=zoom,teams\n"
    let snap = SettingsSnapshot.load(text: text, policy: OrgPolicy.absent())
    func changes(_ touched: [String: String]) -> (changes: [ConfigChange], problems: [SettingsProblem]) { snap.changes(touched: touched) }

    check(changes(["UI_LANGUAGE": "en"]).changes.isEmpty, "a touched control that says what the file says is no change")
    check(changes(["UI_LANGUAGE": "EN"]).changes.isEmpty, "... also in another spelling")
    check(changes(["UI_LANGUAGE": "ko"]).changes == [ConfigChange(key: "UI_LANGUAGE", value: "ko")], "a changed choice is one change")
    check(changes(["LOCAL_ONLY_DEFAULT": "1"]).changes == [ConfigChange(key: "LOCAL_ONLY_DEFAULT", value: "true")], "a switch keeps the words of the file (false -> true)")
    check(changes(["LOCAL_ONLY_DEFAULT": "0"]).changes.isEmpty, "a switch that stays off is no change")
    check(changes(["NOTE_MODEL": ""]).changes == [ConfigChange(key: "NOTE_MODEL", value: nil)], "a cleared text field removes the key (the default applies again)")
    check(changes(["CLAUDE_AUTH": ""]).problems.count == 1, "a cleared choice is refused (it has no default to fall back to by itself)")
    check(changes(["SELF_NAME": ""]).changes.isEmpty, "clearing a key that is not in the file is no change")
    check(changes(["SELF_NAME": "Me"]).changes.isEmpty, "typing the default of an absent key is no change")
    check(changes(["SELF_NAME": "Sam"]).changes == [ConfigChange(key: "SELF_NAME", value: "Sam")], "a new text is written as typed (trimmed)")
    check(changes(["SELF_NAME": "  Sam  "]).changes == [ConfigChange(key: "SELF_NAME", value: "Sam")], "blanks around a text are dropped")
    check(changes(["CALL_DETECT": "known"]).changes == [ConfigChange(key: "CALL_DETECT", value: "known")], "a typo in the file is replaced when the person picks a value, even the default")
    check(changes(["ENABLED_PLATFORMS": ""]).changes == [ConfigChange(key: "ENABLED_PLATFORMS", value: "")], "no platform checked is written as an empty value, not removed")
    check(changes(["ENABLED_PLATFORMS": "zoom,teams"]).changes.isEmpty && changes(["ENABLED_PLATFORMS": "teams,zoom"]).changes.isEmpty, "the same set of platforms is no change, in any order")
    check(changes(["ENABLED_PLATFORMS": "zoom,meet"]).changes == [ConfigChange(key: "ENABLED_PLATFORMS", value: "zoom,meet")], "a platform list is written in the fixed order and spelling")
    check(changes(["CLAUDE_DAILY_BUDGET_USD": "abc"]).problems.map { $0.key } == ["CLAUDE_DAILY_BUDGET_USD"] && changes(["CLAUDE_DAILY_BUDGET_USD": "abc"]).changes.isEmpty, "an invalid value is refused with its key")
    check(changes(["ARCHIVE_DIR": "relative"]).problems.count == 1, "a relative folder is refused")
    let both = changes(["UI_LANGUAGE": "ko", "CLAUDE_DAILY_BUDGET_USD": "-3"])
    check(both.changes.count == 1 && both.problems.count == 1, "one refused control does not hide the others (the save as a whole is refused later)")
    check(changes(["ANTHROPIC_API_KEY": settingsCanary]).problems.map { $0.key } == ["ANTHROPIC_API_KEY"] && changes(["ANTHROPIC_API_KEY": settingsCanary]).changes.isEmpty && !changes(["ANTHROPIC_API_KEY": settingsCanary]).problems.map { $0.message }.joined().contains(settingsCanary),
          "a key that is not a setting of this window (a secret's name) is refused, and its value is not repeated")
    check(changes(["CLAUDE_KEY_SERVICE": "x"]).problems.count == 1, "CLAUDE_KEY_SERVICE is not edited by this window")

    let policy = settingsPolicy(extra: ["enforced": ["NOTE_MODEL": "haiku"]])
    let lockedSnap = SettingsSnapshot.load(text: "NOTE_MODEL=opus\n", policy: policy)
    check(lockedSnap.changes(touched: ["NOTE_MODEL": "sonnet"]).problems.first?.message == "Fixed by organisation policy" && lockedSnap.changes(touched: ["NOTE_MODEL": "sonnet"]).changes.isEmpty, "a locked key cannot be changed: refused with the reason")
    check(lockedSnap.changes(touched: ["NOTE_MODEL": "haiku"]).changes.isEmpty && lockedSnap.changes(touched: ["NOTE_MODEL": "haiku"]).problems.isEmpty, "a locked control that still shows the policy's value is no change")
    let lo = SettingsSnapshot.load(text: "", policy: settingsPolicy(extra: ["local_only": ["default": true, "locked": true]]))
    check(lo.changes(touched: ["LOCAL_ONLY_DEFAULT": "0"]).problems.count == 1 && lo.changes(touched: ["LOCAL_ONLY_DEFAULT": "1"]).problems.isEmpty, "Local-Only fixed by the policy cannot be switched off here")
    let backOff = SettingsSnapshot.load(text: "", policy: settingsPolicy(extra: ["defaults": ["CALL_BROWSER_URLS": "on"]]))
    check(backOff.changes(touched: ["CALL_BROWSER_URLS": "off"]).changes == [ConfigChange(key: "CALL_BROWSER_URLS", value: "off")], "choosing the built-in default over a policy default is written (the file must say it)")
}

// MARK: - The editor

private func edit(_ text: String, _ changes: [String: String?], order: [String]? = nil) -> Result<String, ConfigEnvEditor.Failure> {
    let keys = order ?? changes.keys.sorted()
    return ConfigEnvEditor.apply(keys.map { ConfigChange(key: $0, value: changes[$0] ?? nil) }, to: text)
}

private func editOK(_ text: String, _ changes: [String: String?], order: [String]? = nil) -> String? {
    if case .success(let s) = edit(text, changes, order: order) { return s }
    return nil
}

private func testSettingsEditor() {
    section("settings: ConfigEnvEditor keeps every other byte, refuses what the parsers would misread")
    let header = ConfigEnvEditor.addedHeader
    check(editOK("# a\nUI_LANGUAGE=en\n\nOTHER=1   # note\n", ["UI_LANGUAGE": "ko"]) == "# a\nUI_LANGUAGE=ko\n\nOTHER=1   # note\n", "update one line, every other line is the same bytes")
    check(editOK("UI_LANGUAGE=en", ["UI_LANGUAGE": "ko"]) == "UI_LANGUAGE=ko", "no trailing newline stays none")
    check(editOK("SELF_NAME =  Me   # label\n", ["SELF_NAME": "Sam"]) == "SELF_NAME =  Sam   # label\n", "spaces around '=' and the trailing comment stay")
    check(editOK("A=\"x y\"\n", ["A": "z"]) == "A=\"z\"\n" && editOK("A='x y'\n", ["A": "z"]) == "A='z'\n", "double and single quotes stay")
    check(editOK("A='x'\n", ["A": "it's"]) == "A=it's\n", "a value that contains the quote of the line is written bare, and reads back whole")
    check(editOK("A=1\nA=2\n", ["A": "9"]) == "A=1\nA=9\n", "of a duplicated key the LAST line (the one that counts) is rewritten")
    check(editOK("A=1\nB=2\nA=3\n", ["A": nil]) == "B=2\n", "removing a key removes every line of it (an earlier one would count again otherwise)")
    check(editOK("# A=1\n", ["A": "2"]) == "# A=1\n\n\(header)\nA=2\n", "a commented key is no definition: the key is appended, the comment stays")
    check(editOK("", ["A": "1"]) == "\(header)\nA=1\n", "an empty file gets the header and the key")
    check(editOK("X=1", ["A": "1"]) == "X=1\n\n\(header)\nA=1\n", "a file without a final newline gets one before the appended lines")
    check(editOK("X=1\n\n\(header)\nA=1\n", ["B": "2"]) == "X=1\n\n\(header)\nA=1\nB=2\n", "the header is not repeated")
    check(editOK("X=1\n", ["B": "2", "A": "1"], order: ["B", "A"]) == "X=1\n\n\(header)\nB=2\nA=1\n", "several new keys are appended in the order given")
    check(editOK("X=1\r\nUI_LANGUAGE=en\r\n", ["UI_LANGUAGE": "ko"]) == "X=1\r\nUI_LANGUAGE=ko\r\n", "CRLF line ends stay")
    check(editOK("X=1\r\n", ["A": "1"]) == "X=1\r\n\r\n\(header)\r\nA=1\r\n", "appended lines of a CRLF file are CRLF too")
    check(editOK("A=  # none\n", ["A": "v"]) == "A=  v # none\n", "a comment is never glued to the new value")
    check(editOK("\n  A = 1\n\n", ["A": "2"]) == "\n  A = 2\n\n", "indentation and blank lines stay")
    check(editOK("A=1\n", ["A": ""]) == "A=\n", "an empty value is written as an empty value")
    check(editOK("# only a comment\n", [:]) == "# only a comment\n", "no change: the same text")
    check(editOK("\u{FEFF}A=1\nB=2\n", ["B": "3"]) == "\u{FEFF}A=1\nB=3\n", "a BOM at the start stays")
    check(editOK("A=a=b\n", ["A": "c=d"]) == "A=c=d\n", "'=' inside a value is fine where the key allows it (EXTRA_MEETING_APPS)")

    func refused(_ text: String, _ changes: [String: String?]) -> Bool { editOK(text, changes) == nil }
    check(refused("A=1\n", ["A": "x\ny"]) && refused("A=1\n", ["A": "x\ry"]) && refused("A=1\n", ["A": "x\u{0}y"]), "a value with a line break or another control character is refused")
    check(refused("A=1\n", ["A": " x"]) && refused("A=1\n", ["A": "x "]), "a value with a blank at either end is refused")
    check(refused("A=1\n", ["A": "x # y"]) && refused("A=1\n", ["A": "x\t#y"]) && refused("A=1\n", ["A": "#x"]), "a value that a parser would cut at a comment is refused")
    check(editOK("A=1\n", ["A": "x#y"]) == "A=x#y\n", "a '#' that follows no blank is part of the value")
    check(refused("A=1\n", ["A": "\"x\""]) && refused("A=1\n", ["A": "x'"]) && refused("A=1\n", ["A": "'x"]), "a value that starts or ends with a quote is refused (the two parsers strip quotes differently)")
    check(refused("A=1\n", ["B=2": "x"]) && refused("A=1\n", ["b": "x"]) && refused("A=1\n", ["": "x"]) && refused("A=1\n", ["A B": "x"]), "a key that is not a plain config.env key name is refused ('=' in a key)")
    check(refused("A=1\n", ["A": "UI_LANGUAGE=ko"]) && refused("A=1\n", ["A": "X_Y=1"]), "a value that looks like another KEY=VALUE line is refused")
    check(ConfigEnvEditor.apply([ConfigChange(key: "A", value: "1"), ConfigChange(key: "A", value: "2")], to: "").isFailure, "one key changed twice is refused")
    check(refused("A=1\rB=2\n", ["A": "2"]) && refused("A=1\u{2028}B=2\n", ["A": "2"]) && refused("A=1\u{0B}B=2\n", ["A": "2"]), "a file with a line separator the two parsers read differently is refused whole")
    check(refused("A=1\n", ["B": "x\u{7F}"]), "DEL is a control character too")

    // the result is read back by both parsers; nothing else may change
    let source = "# comment\nUI_LANGUAGE=en\nUNKNOWN=zz # u\nEXTRA_MEETING_APPS=\nA=\"q\"\n"
    if case .success(let out) = edit(source, ["UI_LANGUAGE": "ko", "EXTRA_MEETING_APPS": "com.example.a=Name A", "NEW_ONE": "v"]) {
        let swift = AppConfig.parseEnvText(out), python = ConfigEnvEditor.parseLikePython(out)
        check(swift == python, "both parsers read the edited file the same way", "\(swift) vs \(python)")
        check(swift["UI_LANGUAGE"] == "ko" && swift["EXTRA_MEETING_APPS"] == "com.example.a=Name A" && swift["NEW_ONE"] == "v" && swift["UNKNOWN"] == "zz" && swift["A"] == "q", "the intended values, and the unknown key and the quoted key as before")
    } else { check(false, "a three-change edit succeeds") }
    check(ConfigEnvEditor.parseLikePython("A=\"x\"\nB='y'\nC=a#b\nD=e # f\nG = \"h\" # i\n") == ["A": "x", "B": "y", "C": "a#b", "D": "e", "G": "h"], "the mirror of config.py parse_env_text reads quotes, comments and blanks like Python")
    check(ConfigEnvEditor.parseLikePython("A=\"x\n") == ["A": "x"] && AppConfig.parseEnvText("A=\"x\n") == ["A": "\"x"], "the two parsers really differ on a lone quote (why the editor refuses quotes at the edge of a value)")
    check(ConfigEnvEditor.definition(in: "  KEY = v # c")?.key == "KEY" && ConfigEnvEditor.definition(in: "# KEY=v") == nil && ConfigEnvEditor.definition(in: "KEY") == nil && ConfigEnvEditor.definition(in: "=v") == nil,
          "definition(in:) follows the line rules of parseEnvText")
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}

// MARK: - The shared corpus

private func loadParityCorpus() -> [String: Any]? {
    guard let repo = repoRoot(), let data = try? Data(contentsOf: repo.appendingPathComponent("pipeline/tests/fixtures/settings_parity.json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func testSettingsCorpus() {
    section("settings: the shared corpus pipeline/tests/fixtures/settings_parity.json (the Python test reads the same file)")
    guard let corpus = loadParityCorpus() else { check(false, "the corpus is found next to the working directory or the app"); return }
    let env = corpus["env_parse"] as? [[String: Any]] ?? []
    let writer = corpus["writer"] as? [[String: Any]] ?? []
    check(env.count >= 10 && writer.count >= 10, "the corpus has parsing and writer cases", "\(env.count) / \(writer.count)")
    var badEnv: [String] = []
    for row in env {
        guard let text = row["text"] as? String, let expect = row["expect"] as? [String: String] else { continue }
        if AppConfig.parseEnvText(text) != expect { badEnv.append(text.debugDescription) }
    }
    check(badEnv.isEmpty, "Config.swift parseEnvText reads every parsing case as the corpus says (Python's parse_env_text is checked against the same expectations)", badEnv.joined(separator: " | "))
    var badWriter: [String] = []
    for row in writer {
        guard let name = row["name"] as? String, let text = row["text"] as? String, let changes = row["changes"] as? [String: Any], let result = row["result"] as? String else { continue }
        let list = changes.keys.sorted().map { ConfigChange(key: $0, value: changes[$0] as? String) }
        // the order of a multi-key insert in the corpus is the key order of the JSON object: sorted
        if case .success(let got) = ConfigEnvEditor.apply(list, to: text) {
            if got != result { badWriter.append("\(name): \(got.debugDescription)") }
        } else { badWriter.append("\(name): refused") }
    }
    check(badWriter.isEmpty, "the editor writes exactly the bytes of every writer case", badWriter.joined(separator: " | "))

    // an OpenAI-style model name: what the pipeline accepts ([\x21-\x7e]{1,100}), minus what the config.env writer cannot store
    let names = corpus["model_names"] as? [[String: Any]] ?? []
    var badNames: [String] = []
    for row in names {
        guard let text = row["text"] as? String, let window = row["window"] as? Bool, let python = row["python"] as? Bool else { continue }
        let accepted = canon("ASR_OPENAI_COMPAT_MODEL", text) != nil
        if accepted != window { badNames.append("\(text.prefix(20).debugDescription): \(accepted)") }
        if accepted && !python { badNames.append("\(text.prefix(20).debugDescription) is accepted but the pipeline refuses it") }
    }
    check(names.count >= 10 && badNames.isEmpty, "\(names.count) model names: the window takes an id such as Systran/faster-whisper-large-v3, and never one that the pipeline refuses", badNames.joined(separator: " | "))
}

// MARK: - The file

private func testSettingsWriter(_ base: URL) {
    section("settings: ConfigEnvWriter (atomic, 0600, backups, failures leave the old file)")
    let fm = FileManager.default
    func mode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    let h = SettingsHarness(base, name: "writer", config: "UI_LANGUAGE=en\n# keep me\n")
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: h.file.path)
    let outcome = ConfigEnvWriter.save("UI_LANGUAGE=ko\n# keep me\n", to: h.file, now: h.clock)
    guard case .saved(let backup) = outcome else { check(false, "a save succeeds", "\(outcome)"); return }
    check(h.text == "UI_LANGUAGE=ko\n# keep me\n", "the new text is in config.env")
    check(mode(h.file) == 0o600, "config.env is 0600 after the save (it was 0644)", String(mode(h.file), radix: 8))
    check(backup != nil && (try? String(contentsOf: backup!, encoding: .utf8)) == "UI_LANGUAGE=en\n# keep me\n" && mode(backup!) == 0o600, "the backup holds the OLD text and is 0600")
    check(h.backups.count == 1 && h.backups[0].range(of: "^config\\.env\\.bak-settings-[0-9]{8}-[0-9]{6}-[0-9]{3}$", options: .regularExpression) != nil, "the backup is named config.env.bak-settings-<timestamp>", "\(h.backups)")
    check(!((try? fm.contentsOfDirectory(atPath: h.dir.path)) ?? []).contains { $0.contains(".tmp-") }, "no temp file is left behind")

    // rotation: the last five backups, nothing else touched
    let other = h.dir.appendingPathComponent("config.env.bak-by-hand")
    try? "mine".write(to: other, atomically: true, encoding: .utf8)
    for i in 1...8 {
        h.clock = h.clock.addingTimeInterval(Double(i) * 3.0)
        _ = ConfigEnvWriter.save("UI_LANGUAGE=ko\nSELF_NAME=S\(i)\n", to: h.file, now: h.clock)
    }
    check(h.backups.count == 5, "only the last five backups are kept", "\(h.backups.count): \(h.backups)")
    check(fm.fileExists(atPath: other.path), "a file that is not one of ours (config.env.bak-by-hand) is never deleted")
    let newest = h.backups.last.flatMap { try? String(contentsOf: h.dir.appendingPathComponent($0), encoding: .utf8) }
    check(newest == "UI_LANGUAGE=ko\nSELF_NAME=S7\n", "the newest backup is the text before the last save", newest ?? "nil")
    check(h.text == "UI_LANGUAGE=ko\nSELF_NAME=S8\n", "and the file is the last text")

    // failures
    let before = h.text
    let countBefore = h.backups.count
    var failing = ConfigFileOps()
    failing.writeTemp = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
    if case .failed(let why) = ConfigEnvWriter.save("X=1\n", to: h.file, now: h.clock.addingTimeInterval(100), ops: failing) {
        check(h.text == before && h.backups.count == countBefore, "a failure writing the temp file leaves config.env and the backups as they were")
        check(why.contains("unchanged"), "... and says the old file is unchanged", why)
    } else { check(false, "a failing temp write is a failure") }
    var failingRename = ConfigFileOps()
    failingRename.rename = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)) }
    if case .failed = ConfigEnvWriter.save("X=1\n", to: h.file, now: h.clock.addingTimeInterval(200), ops: failingRename) {
        check(h.text == before && h.backups.count == countBefore, "a failing rename leaves config.env unchanged and removes the backup it had made")
        check(!((try? fm.contentsOfDirectory(atPath: h.dir.path)) ?? []).contains { $0.contains(".tmp-") }, "... and the temp file")
    } else { check(false, "a failing rename is a failure") }
    var calls = 0
    var failSecond = ConfigFileOps()
    failSecond.writeTemp = { data, url in calls += 1; if calls == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }; try ConfigFileOps.realWriteTemp(data, url) }
    if case .failed = ConfigEnvWriter.save("X=1\n", to: h.file, now: h.clock.addingTimeInterval(300), ops: failSecond) {
        check(h.text == before && h.backups.count == countBefore, "no backup, no change: when the backup cannot be written nothing is replaced")
    } else { check(false, "a failing backup is a failure") }
    // a real failure: the folder cannot be written
    let ro = SettingsHarness(base, name: "writer-readonly", config: "A=1\n")
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.dir.path)
    if case .failed = ConfigEnvWriter.save("A=2\n", to: ro.file, now: ro.clock) {
        check(ro.text == "A=1\n", "a read-only folder: the save fails and the file is unchanged")
    } else { check(getuid() == 0, "a read-only folder makes the save fail") }
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.dir.path)

    // a new file, a link
    let fresh = SettingsHarness(base, name: "writer-new")
    if case .saved(let b) = ConfigEnvWriter.save("A=1\n", to: fresh.file, now: fresh.clock) { check(b == nil && fresh.text == "A=1\n" && mode(fresh.file) == 0o600 && fresh.backups.isEmpty, "a missing config.env is created (0600), no backup of nothing") }
    else { check(false, "a new file is written") }
    let linked = SettingsHarness(base, name: "writer-link")
    let target = linked.dir.appendingPathComponent("real.env")
    try? "A=1\n".write(to: target, atomically: true, encoding: .utf8)
    try? fm.createSymbolicLink(at: linked.file, withDestinationURL: target)
    if case .saved = ConfigEnvWriter.save("A=2\n", to: linked.file, now: linked.clock) {
        check((try? fm.destinationOfSymbolicLink(atPath: linked.file.path)) != nil && (try? String(contentsOf: target, encoding: .utf8)) == "A=2\n", "a config.env that is a link is written through: the link stays, its target changes")
    } else { check(false, "a save through a link works") }
    let bad = SettingsHarness(base, name: "writer-binary")
    try? Data([0xFF, 0xFE, 0x41, 0x80]).write(to: bad.file)
    check(ConfigEnvWriter.read(bad.file).problem != nil && ConfigEnvWriter.read(bad.file).text == nil, "a config.env that is not UTF-8 is reported, never read as text")
    if case .failed = bad.coordinator.save(touched: ["UI_LANGUAGE": "ko"]) { check((try? Data(contentsOf: bad.file)) == Data([0xFF, 0xFE, 0x41, 0x80]), "and it is never overwritten") }
    else { check(false, "a save over a file that is not UTF-8 is refused") }
}

// MARK: - Keychain

private func testSettingsKeychain() {
    section("settings: API keys go to the Keychain with the method of the Python side (security -i, hex on stdin)")
    let item = KeychainItem(service: "MeetingCapture Anthropic API key", account: "tester")
    let fake = FakeKeychain()
    let keychain = SettingsKeychain(run: fake.runner)
    check(keychain.status(item) == .notStored && fake.calls.last?.args == ["find-generic-password", "-s", item.service, "-a", item.account], "status asks without -w: not stored (exit 44)")
    check(fake.calls.last?.capture == false, "status never captures the output")
    let outcome = keychain.store(secret: settingsCanary, kind: .anthropicKey, item: item)
    check(outcome == .ok, "a key is stored", "\(outcome)")
    check(fake.calls.count >= 3 && fake.calls[1].args == ["-i"], "the store is `security -i`: the only argument is -i", "\(fake.calls.map { $0.args })")
    let stdin = fake.calls[1].stdin ?? ""
    let hex = settingsCanary.utf8.map { String(format: "%02x", $0) }.joined()
    check(stdin == "add-generic-password -U -a \"tester\" -s \"MeetingCapture Anthropic API key\" -X \(hex)\n", "the command is on stdin: add-generic-password -U -a <account> -s <service> -X <hex>", stdin)
    check(!stdin.contains(settingsCanary), "the key itself is not in the command: only its hex")
    check(!fake.calls.contains { $0.args.joined(separator: " ").contains(settingsCanary) || $0.args.joined(separator: " ").contains(hex) }, "the key (or its hex) is in no argument")
    check(fake.items["\(item.service)|\(item.account)"] == settingsCanary, "the item the fake keychain holds is the key (what Python's `find-generic-password -w` reads back)")
    check(fake.calls.last?.args == ["find-generic-password", "-s", item.service, "-a", item.account, "-w"] && fake.calls.last?.capture == true, "the read-back is one `find-generic-password ... -w`")
    check(keychain.status(item) == .stored, "status: stored")
    check(!"\(outcome)".contains(settingsCanary) && !KeyStatus.stored.text.contains("0") && !KeyStatus.stored.text.contains("character"), "no result or status text carries the key or its length")
    check(keychain.remove(item) == .ok && keychain.status(item) == .notStored && keychain.remove(item) == .ok, "remove deletes the item; removing again is fine (nothing to delete)")
    check(fake.calls.contains { $0.args == ["delete-generic-password", "-s", item.service, "-a", item.account] }, "removal is delete-generic-password -s <service> -a <account>")

    // the interactive mode cannot report a failure: the read-back must catch it
    let silent = FakeKeychain()
    silent.dropStores = true
    if case .failed(let why) = SettingsKeychain(run: silent.runner).store(secret: settingsCanary, kind: .anthropicKey, item: item) { check(!why.contains(settingsCanary), "a store that did not take is reported (read-back differs), without the key") }
    else { check(false, "a store that did not take is a failure") }
    let offline = FakeKeychain(); offline.launches = false
    check(SettingsKeychain(run: offline.runner).status(item) == .unknown, "a tool that cannot be run: status unknown")
    if case .failed = SettingsKeychain(run: offline.runner).store(secret: settingsCanary, kind: .anthropicKey, item: item) { check(true, "a tool that cannot be run: the store fails") } else { check(false, "a tool that cannot be run: the store fails") }
    let odd = FakeKeychain(); odd.status = 36
    check(SettingsKeychain(run: odd.runner).status(item) == .unknown, "an exit status that is neither 0 nor 44: status unknown")

    // what is refused before anything runs
    let quiet = FakeKeychain()
    let k2 = SettingsKeychain(run: quiet.runner)
    func refused(_ outcome: KeychainOutcome) -> Bool { if case .refused = outcome { return true } else { return false } }
    check(refused(k2.store(secret: "", kind: .anthropicKey, item: item)), "an empty key is refused")
    check(refused(k2.store(secret: "not-a-key-0123456789", kind: .anthropicKey, item: item)), "an Anthropic key must start with sk-ant-")
    check(refused(k2.store(secret: "sk-ant-abc def", kind: .anthropicKey, item: item)) && refused(k2.store(secret: "sk-ant-abc\ndef", kind: .anthropicKey, item: item)) && refused(k2.store(secret: "sk-ant-ab\u{e9}", kind: .anthropicKey, item: item)),
          "a key with a blank, a line break or a non-ASCII character is refused (asr_creds._checked)")
    check(refused(k2.store(secret: "sk-ant-" + String(repeating: "a", count: 510), kind: .anthropicKey, item: item)), "a key longer than 512 characters is refused")
    check(refused(k2.store(secret: engineCanary, kind: .engineKey, item: KeychainItem(service: "S\"x", account: "a"))) && refused(k2.store(secret: engineCanary, kind: .engineKey, item: KeychainItem(service: "S", account: "a\\b"))), "a name that cannot sit inside the quotes of `security -i` is refused")
    check(refused(k2.store(secret: engineCanary, kind: .engineKey, item: KeychainItem(service: "-S", account: "a"))), "a service name that starts with - is refused (it could be read as an option)")
    check(quiet.calls.isEmpty, "nothing was run for any refused key")
    check(k2.store(secret: engineCanary, kind: .engineKey, item: KeychainItem(service: "MeetingCapture ASR clova", account: "tester@gw.ncloud.com:443")) == .ok, "an engine key needs no prefix: any printable token")
    check(SettingsKeychain.addCommand(item: item, secret: String(repeating: "a", count: 1500)) == nil, "a command longer than 3000 bytes is not sent")
    check(SettingsKeychain.sameSecret(Data((settingsCanary + "\n").utf8), settingsCanary) && SettingsKeychain.sameSecret(Data((hex + "\n").utf8), settingsCanary) && !SettingsKeychain.sameSecret(Data("other\n".utf8), settingsCanary),
          "the read-back accepts the text or the hex form of the value, nothing else")

    // slots: the same service and account strings as the pipeline
    let userItem = SecretSlot.claude.item(effective: [:], user: "tester")
    check((try? userItem.get()) == item, "Anthropic key: service 'MeetingCapture Anthropic API key', account <login name> (apikey.py)")
    check((try? SecretSlot.claude.item(effective: ["CLAUDE_KEY_SERVICE": " Custom Service "], user: "tester").get()) == KeychainItem(service: "Custom Service", account: "tester"), "CLAUDE_KEY_SERVICE (trimmed) names the service, as apikey.keychain_service does")
    check((try? SecretSlot.clova.item(effective: ["ASR_CLOVA_INVOKE_URL": "https://ClovaSpeech-GW.ncloud.com/external/v1/a/b"], user: "tester").get())
          == KeychainItem(service: "MeetingCapture ASR clova", account: "tester@clovaspeech-gw.ncloud.com:443"), "CLOVA key: service 'MeetingCapture ASR clova', account <user>@<host>:<port> from the saved address (asr_creds.py)")
    check((try? SecretSlot.openAICompat.item(effective: ["ASR_OPENAI_COMPAT_URL": "https://llm.example.org:8443/v1"], user: "tester").get())
          == KeychainItem(service: "MeetingCapture ASR openai-compat", account: "tester@llm.example.org:8443"), "OpenAI-compatible key: service 'MeetingCapture ASR openai-compat', account with host and port")
    check(SecretSlot.clova.item(effective: [:], user: "tester").isFailure && SecretSlot.clova.item(effective: ["ASR_CLOVA_INVOKE_URL": "https://example.com/x"], user: "tester").isFailure,
          "no key can be stored for an engine without a valid saved address (the item is bound to its host)")
    check(AsrDestination.service(engine: "azure") == "MeetingCapture ASR azure" && AsrDestination.servicePrefix == "MeetingCapture ASR ", "the service of an engine is the prefix and its id")
    check(KeyStatus.notStored.text == "Not stored" && KeyStatus.unknown.text.contains("Keychain"), "the status texts say only stored / not stored / could not check")
}

private func testSettingsKeychainProcess(_ base: URL) {
    section("settings: the real tool runner against a shim script (stdin, argv, environment)")
    let fm = FileManager.default
    let dir = base.appendingPathComponent("shim-security", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let shim = dir.appendingPathComponent("security")
    let script = """
    #!/bin/sh
    D="$(cd "$(dirname "$0")" && pwd)"
    echo "ARGV: $*" >> "$D/calls.log"
    env | sort > "$D/env.log"
    case "$1" in
      -i) cat > "$D/stdin.log"; exit 0 ;;
      find-generic-password) case " $* " in *" -w "*) echo "stored-value"; exit 0 ;; esac; exit 44 ;;
      sleep) sleep 30; exit 0 ;;
      *) exit 2 ;;
    esac
    """
    try? script.write(to: shim, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    let command = "add-generic-password -U -a \"tester\" -s \"S\" -X 6162\n"
    let r = SettingsKeychain.runTool(shim, ["-i"], stdin: Data(command.utf8), capture: false)
    check(r.launched && r.status == 0 && !r.timedOut, "the tool runs and exits 0")
    check((try? String(contentsOf: dir.appendingPathComponent("stdin.log"), encoding: .utf8)) == command, "the command reaches the tool on stdin, byte for byte")
    check((try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) == "ARGV: -i\n", "the arguments are exactly -i")
    let env = (try? String(contentsOf: dir.appendingPathComponent("env.log"), encoding: .utf8)) ?? ""
    let names = Set(env.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
    check(names.isSubset(of: ["HOME", "USER", "PATH", "LANG", "PWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING", "OLDPWD"]) && names.contains("HOME") && !names.contains { $0.hasPrefix("ANTHROPIC") || $0.hasPrefix("MCAP") }, "the tool gets a minimal environment (no ANTHROPIC_*, no MCAP_*)", "\(names.sorted())")
    let read = SettingsKeychain.runTool(shim, ["find-generic-password", "-s", "S", "-a", "tester", "-w"], stdin: nil, capture: true)
    check(read.status == 0 && String(data: read.stdout, encoding: .utf8) == "stored-value\n", "with capture the output comes back")
    let quiet = SettingsKeychain.runTool(shim, ["find-generic-password", "-s", "S", "-a", "tester"], stdin: nil, capture: false)
    check(quiet.status == 44 && quiet.stdout.isEmpty, "without capture the output is never read")
    let slow = SettingsKeychain.runTool(shim, ["sleep"], stdin: nil, capture: false, timeout: 0.5)
    check(slow.launched && slow.timedOut, "a tool that hangs is stopped at the timeout")
    check(!SettingsKeychain.runTool(dir.appendingPathComponent("missing"), ["-i"], stdin: nil, capture: false).launched, "a tool that does not exist: not launched")
    let all = ["calls.log", "env.log", "stdin.log"].compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined()
    check(!all.contains(settingsCanary) && !appLogText().contains(settingsCanary) && !appLogText().contains(engineCanary), "the key canary is in no shim log and not in app.log")
}

// MARK: - Addresses

private func testSettingsDestinations() {
    section("settings: AsrDestination reads an address like asr_providers.split_base (shared corpus)")
    guard let corpus = loadParityCorpus(), let rows = corpus["destinations"] as? [[String: Any]] else { check(false, "the corpus has destination cases"); return }
    var wrong: [String] = []
    for row in rows {
        guard let engine = row["engine"] as? String, let url = row["url"] as? String else { continue }
        let got = AsrDestination.parse(url, engine: engine)
        if row["error"] != nil {
            if got != nil { wrong.append("\(url.prefix(60)) should be refused") }
        } else if let host = row["host"] as? String, let port = row["port"] as? Int, let path = row["path"] as? String {
            if got != AsrDestination(host: host, port: port, path: path) { wrong.append("\(url.prefix(60)): \(got.map { "\($0.host):\($0.port)\($0.path)" } ?? "refused")") }
        }
    }
    check(rows.count >= 30 && wrong.isEmpty, "\(rows.count) addresses: the same host, port and path (or the same refusal) as Python", wrong.joined(separator: " | "))
    check(AsrDestination(host: "gw.ncloud.com", port: 8443, path: "/x").keychainAccount(user: "tester") == "tester@gw.ncloud.com:8443", "the Keychain account is <user>@<host>:<port>")
    check(AsrDestination.clovaSuffixes == [".ncloud.com", ".fin-ncloud.com", ".gov-ncloud.com"], "the CLOVA gateways are the three NAVER Cloud suffixes")
}

// MARK: - The pipeline commands

private func testSettingsCommands(_ base: URL) {
    section("settings: the pipeline commands (fixed argv, clean environment, 30 s)")
    check(McapCommand.apiKeyCheck.arguments == ["-m", "mcap", "api-key", "check"] && McapCommand.gcalStatus.arguments == ["-m", "mcap", "gcal", "status"]
          && McapCommand.asrEnginesList.arguments == ["-m", "mcap", "asr-engines", "list", "--json"] && McapCommand.timeout == 30, "the three commands and the 30 s limit are fixed")
    let fm = FileManager.default
    let root = base.appendingPathComponent("mcap-run", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try? fm.createDirectory(at: project.appendingPathComponent("pipeline/mcap"), withIntermediateDirectories: true)
    let python = root.appendingPathComponent("venv/bin/python")
    try? fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    var cfg = AppConfig.defaults()
    cfg.projectDir = project
    cfg.pythonBin = python
    let policy = OrgPolicy.absent()
    var seen: [(python: URL, args: [String], env: [String: String], cwd: URL, stdin: Data, timeout: TimeInterval)] = []
    let runner: CompanyServerConnect.Runner = { py, args, env, cwd, stdin, timeout in
        seen.append((py, args, env, cwd, stdin, timeout))
        return CompanyServerConnect.RunResult(launched: true, status: 0, timedOut: false, output: "API key OK\n")
    }
    let missing = PipelineLauncher.runMcap(.apiKeyCheck, config: cfg, policy: policy, runner: runner, environment: [:])
    check(missing.refusal == "python is missing" && !missing.launched && seen.isEmpty, "no python: refused, nothing started")
    try? "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let noPackage = { () -> McapRun in
        var c = cfg; c.projectDir = root.appendingPathComponent("elsewhere")
        return PipelineLauncher.runMcap(.apiKeyCheck, config: c, policy: policy, runner: runner, environment: [:])
    }()
    check(noPackage.refusal == "the pipeline package is missing" && seen.isEmpty, "no pipeline package: refused")
    let run = PipelineLauncher.runMcap(.apiKeyCheck, config: cfg, policy: policy, runner: runner,
                                       environment: ["ANTHROPIC_API_KEY": settingsCanary, "CLAUDE_CODE_OAUTH_TOKEN": "x", "MCAP_CONFIG": "/tmp/x/config.env", "HOME": "/nobody"])
    check(run.launched && run.status == 0 && run.refusal == nil && seen.count == 1, "the command runs through the injected runner")
    if let call = seen.first {
        check(call.python == python && call.args == ["-m", "mcap", "api-key", "check"] && call.cwd.path == project.appendingPathComponent("pipeline").path && call.stdin.isEmpty && call.timeout == 30,
              "python of the venv, fixed argv, PROJECT_DIR/pipeline, no stdin, 30 s")
        check(!call.env.keys.contains { $0.hasPrefix("ANTHROPIC") || $0.hasPrefix("CLAUDE") } && !call.env.values.contains(settingsCanary), "the child environment holds no ANTHROPIC_* or CLAUDE_* variable and no key")
        check(call.env["USER"] == NSUserName() && call.env["MCAP_CONFIG"] == "/tmp/x/config.env", "USER is the login name (the Keychain account) and the test hook MCAP_CONFIG is forwarded like for every job")
    }
    // the real child runner against a fake python
    let fake = root.appendingPathComponent("fake-python.sh")
    try? "#!/bin/sh\necho \"args: $*\"\necho 'API key OK'\necho '  model:        claude-test (requested: haiku)'\necho '  cost_usd:     0.000100'\necho '  reply:        pong'\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    var cfg2 = cfg
    cfg2.pythonBin = fake
    let real = PipelineLauncher.runMcap(.apiKeyCheck, config: cfg2, policy: policy, environment: [:])
    check(real.launched && real.status == 0 && real.output.contains("args: -m mcap api-key check"), "a real child process runs with the fixed argv", real.output)
    let outcome = KeyCheckOutcome.interpret(real)
    check(outcome.ok && outcome.text.contains("API key OK") && outcome.text.contains("model:") && outcome.text.contains("cost_usd:") && !outcome.text.contains("pong"), "the result shows the verdict, the model and the cost, not the reply", outcome.text)
}

// MARK: - Interpreting answers

private func testSettingsInterpreters() {
    section("settings: the answers of the pipeline are shown content-free")
    func run(_ output: String, status: Int32 = 0, timedOut: Bool = false, refusal: String? = nil) -> McapRun {
        McapRun(launched: refusal == nil, status: status, timedOut: timedOut, output: output, refusal: refusal)
    }
    let failure = KeyCheckOutcome.interpret(run("FAILED: The API key was rejected: \(settingsCanary) (401)\n  apiKeySource: ANTHROPIC_API_KEY\n", status: 1))
    check(!failure.ok && failure.text.hasPrefix("FAILED:") && !failure.text.contains(settingsCanary) && failure.text.contains("sk-ant-***"), "a failure shows its message with every key shape masked", failure.text)
    check(!KeyCheckOutcome.interpret(run("", status: 1, timedOut: true)).ok && KeyCheckOutcome.interpret(run("", status: 1, timedOut: true)).text.contains("30 seconds"), "a timeout is reported")
    check(KeyCheckOutcome.interpret(run("", status: -1, refusal: "python is missing")).text.contains("python is missing"), "a refusal says why nothing started")
    check(KeyCheckOutcome.interpret(run("Traceback...\n", status: 1)).text == "The check failed (exit 1).", "an unknown failure shows only the exit status, never raw output")
    check(!KeyCheckOutcome.interpret(run("API key OK\n", status: 1)).ok, "an OK line with a failing exit status is no success")
    check(SettingsText.scrubbed("a\tb\u{1}c  \(settingsCanary)  \(String(repeating: "Z", count: 40))") == "a b c sk-ant-*** ***", "scrubbed: control characters, key shapes and long tokens are gone")
    check(SettingsText.scrubbed(String(repeating: "word ", count: 100)).count <= 200, "scrubbed: clipped")

    let json = """
    {"schema": 1, "engines": [
      {"engine": "whisper", "kind": "local", "consent": "not needed", "credential": "not needed", "usable": true},
      {"engine": "clova", "kind": "cloud", "consent": "ok (until 2027-04-01)", "credential": "stored", "usable": true},
      {"engine": "openai-compat", "kind": "cloud", "consent": "no-consent", "credential": "none (optional)", "usable": false},
      {"engine": "azure", "kind": "cloud", "consent": "consent-expired", "credential": "missing", "usable": false}]}
    """
    let states = AsrEngineStates.parse("warning on stderr\n" + json + "\n")
    check(states?.count == 4 && states?["clova"]?.consentOK == true && states?["clova"]?.consent == "valid until 2027-04-01" && states?["openai-compat"]?.consentOK == false, "asr-engines list --json is parsed (stderr noise around it is ignored)")
    check(states?["openai-compat"]?.consent == "no consent recorded" && states?["azure"]?.consent == "the consent expired" && states?["whisper"]?.consent == "not needed", "the consent states are said in plain words")
    check(AsrEngineStates.parse("not json") == nil && AsrEngineStates.parse("{}") == nil && AsrEngineStates.parse("{\"engines\": []}") == nil, "anything else is no answer")
    check(ConsentLine.make(engine: "whisper", states: states).canGrant == false && ConsentLine.make(engine: "clova", states: states).canGrant == true && ConsentLine.make(engine: "clova", states: states).text == "Consent: valid until 2027-04-01"
          && ConsentLine.make(engine: "openai-compat", states: states).text.hasPrefix("Consent: none that applies") && ConsentLine.make(engine: "clova", states: nil).text.contains("not known"), "the consent line of the selected engine")
    check(ConsentLine.make(engine: "remote", states: states).canGrant == false && ConsentLine.make(engine: "auto", states: states).canGrant == false && ConsentLine.make(engine: "bogus", states: states).text.isEmpty, "whisper, auto and remote have no Terminal consent button")

    let ready = "Google Calendar (read-only, for calendar autostart; docs/CALENDAR_AUTOSTART.md)\n  OAuth client file: /x/google-oauth-client.json (private, Desktop app client)\n  token:             in the Keychain (service 'S'), signed in as someone@example.org\n  access token:      cached, valid for about 30 more minutes\n  organisation lane: allowed\nready\n"
    check(GoogleCalendarState.interpret(run(ready)) == .ready, "gcal status: ready")
    check(!GoogleCalendarState.ready.text.contains("someone") && !GoogleCalendarState.ready.text.contains("@"), "the signed-in text never names the account")
    let noToken = "Google Calendar (read-only)\n  OAuth client file: /x (private, Desktop app client)\n  token:             NOT available: Google Calendar is not signed in: run gcal auth\n  organisation lane: allowed\nnot ready: see docs/CALENDAR_AUTOSTART.md\n"
    check(GoogleCalendarState.interpret(run(noToken, status: 1)) == .notSignedIn, "gcal status: not signed in")
    check(GoogleCalendarState.interpret(run("  OAuth client file: NOT usable: missing\n  token:             NOT available: x\nnot ready\n", status: 1)) == .notConfigured, "gcal status: the client file first")
    check(GoogleCalendarState.interpret(run("  OAuth client file: /x (ok)\n  token:             in the Keychain\n  organisation lane: DENIED (policy-lane)\nnot ready\n", status: 1)) == .laneDenied, "gcal status: denied by the organisation")
    if case .unknown = GoogleCalendarState.interpret(run("garbage", status: 3)) { check(true, "gcal status: anything else is 'could not check'") } else { check(false, "gcal status: anything else is unknown") }
    if case .unknown = GoogleCalendarState.interpret(run("", status: -1, refusal: "python is missing")) { check(true, "gcal status: a refusal is 'could not check'") } else { check(false, "gcal status: a refusal is unknown") }
    check(!GoogleCalendarState.notConfigured.text.contains("/x"), "no path of the client file is shown")
}

// MARK: - Terminal

private func testSettingsTerminal(_ base: URL) {
    section("settings: the Terminal commands (consent and Google sign-in): exactly the existing commands, the consent is never written here")
    let fm = FileManager.default
    check(TerminalAction.consent(engine: "clova").arguments == ["-m", "mcap", "asr-engines", "consent", "clova"]
          && TerminalAction.consent(engine: "openai-compat").arguments == ["-m", "mcap", "asr-engines", "consent", "openai-compat"]
          && TerminalAction.googleSignIn.arguments == ["-m", "mcap", "gcal", "auth"], "the commands are `python -m mcap asr-engines consent <engine>` and `python -m mcap gcal auth`")
    check(TerminalAction.consent(engine: "remote").arguments == nil && TerminalAction.consent(engine: "whisper").arguments == nil && TerminalAction.consent(engine: "clova; rm -rf ~").arguments == nil && TerminalAction.consent(engine: "").arguments == nil,
          "no consent command for any other word (the engine is never put into a command line unchecked)")
    check(TerminalScript.shellQuote("a b") == "'a b'" && TerminalScript.shellQuote("it's") == "'it'\\''s'" && TerminalScript.shellQuote("$(x)`y`") == "'$(x)`y`'", "shell quoting is literal")
    let python = URL(fileURLWithPath: "/Users/me/Library/Application Support/MeetingCapture/venv/bin/python")
    let pipeline = URL(fileURLWithPath: "/Users/me/Dev/meeting capture/pipeline")
    let script = TerminalScript.script(for: .consent(engine: "clova"), python: python, pipelineDir: pipeline) ?? ""
    let expected = """
    #!/bin/bash
    # Written by the Settings window of \(AppInfo.displayName). It runs the one command below in this Terminal window and removes itself.
    rm -f -- "$0"
    cd '/Users/me/Dev/meeting capture/pipeline' || exit 1
    echo '$ python -m mcap asr-engines consent clova'
    '/Users/me/Library/Application Support/MeetingCapture/venv/bin/python' '-m' 'mcap' 'asr-engines' 'consent' 'clova'
    status=$?
    echo
    echo "Finished with exit code $status. You can close this window."
    exit $status

    """
    check(script == expected, "the script is exactly: cd the pipeline folder, run the command, say the exit code", script)
    check(TerminalScript.script(for: .googleSignIn, python: python, pipelineDir: pipeline)?.contains("'-m' 'mcap' 'gcal' 'auth'") == true, "the Google script runs gcal auth")
    check(TerminalScript.script(for: .consent(engine: "remote"), python: python, pipelineDir: pipeline) == nil, "no script for an engine without a consent command")
    let evil = TerminalScript.script(for: .googleSignIn, python: URL(fileURLWithPath: "/tmp/it's $(touch x)/python"), pipelineDir: URL(fileURLWithPath: "/tmp/a'b"))!
    check(evil.contains("'/tmp/it'\\''s $(touch x)/python'") && evil.contains("cd '/tmp/a'\\''b'"), "paths with quotes and shell syntax stay literal in the script")

    let dir = base.appendingPathComponent("terminal-write", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    if let file = try? TerminalScript.write(script, name: TerminalScript.fileName(for: .consent(engine: "clova")), in: dir) {
        let fileMode = ((try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let dirMode = ((try? fm.attributesOfItem(atPath: file.deletingLastPathComponent().path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        check(file.lastPathComponent == "mcap-consent-clova.command" && fileMode == 0o700 && dirMode == 0o700 && (try? String(contentsOf: file, encoding: .utf8)) == script, "the .command file is private (0700, in a private folder) and holds the script")
    } else { check(false, "the script file is written") }

    // through the coordinator
    let h = SettingsHarness(base, name: "terminal")
    h.mcap[.asrEnginesList] = McapRun(launched: true, status: 0, timedOut: false, output: "{\"engines\": [{\"engine\": \"clova\", \"consent\": \"no-consent\", \"credential\": \"stored\"}]}")
    let c = h.coordinator
    check(c.openTerminal(.consent(engine: "clova")) == nil && h.terminalFiles.count == 1 && h.terminalFiles.first?.lastPathComponent == "mcap-consent-clova.command", "the coordinator opens exactly one Terminal script")
    let written = h.terminalFiles.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    check(written.contains(h.dir.appendingPathComponent("venv/bin/python").path) && written.contains("'consent' 'clova'"), "... of the python and the command of this install")
    check(c.openTerminal(.consent(engine: "remote")) != nil && h.terminalFiles.count == 1, "an engine without a consent command: a reason, nothing opened")
    h.terminalOpens = false
    check(c.openTerminal(.googleSignIn) == "Terminal could not be opened." && h.terminalFiles.count == 2 && h.terminalFiles.last.map { !fm.fileExists(atPath: $0.path) } == true, "when Terminal cannot be opened the script is removed again")
    _ = c.engineStates()
    check(h.mcapCalls == [.asrEnginesList], "reading the consent state is one read-only pipeline command")
    // the consent file is never written by anything of this window
    let consentFiles = ["asr-consent.json"].filter { name in
        if let e = fm.enumerator(at: base, includingPropertiesForKeys: nil) { for case let url as URL in e where url.lastPathComponent == name { return true } }
        return false
    }
    check(consentFiles.isEmpty, "no asr-consent.json exists anywhere after all of the above: the window never writes a consent")
}

// MARK: - Restart

private func testSettingsRestart(_ base: URL) {
    section("settings: restart (never while a recording runs, never where a relaunch would undo a pause or a manual stop)")
    check(RestartPlan.decide(recording: false, bundlePath: "/Applications/\(AppInfo.shortName).app") == .now, "idle: restart now")
    check(RestartPlan.decide(recording: true, bundlePath: "/Applications/\(AppInfo.shortName).app") == .afterRecording, "recording: only 'restart after the recording'")
    if case .unavailable = RestartPlan.decide(recording: false, bundlePath: "/Users/me/build/obj/\(AppInfo.shortName)") { check(true, "a bare binary (not an .app) cannot relaunch itself") } else { check(false, "a bare binary cannot relaunch itself") }
    if case .unavailable = RestartPlan.decide(recording: false, bundlePath: nil) { check(true, "no bundle path: unavailable") } else { check(false, "no bundle path: unavailable") }
    // a relaunch forgets the pause, the hand stop and the no-speech stop (all in memory only) and records the still-running call again
    let app = "/Applications/\(AppInfo.shortName).app"
    check(RestartPlan.decide(recording: false, hold: .stoppedCall, bundlePath: app) == .afterCall(.stoppedCall) && RestartPlan.decide(recording: false, hold: .callLive, bundlePath: app) == .afterCall(.callLive),
          "a call that was stopped by hand (or for no speech), or is about to be recorded: no restart now, only 'after the call'")
    if case .unavailable(let why) = RestartPlan.decide(recording: false, hold: .paused, bundlePath: app) { check(why.contains("paused") && why.contains("Resume"), "paused: no restart (a pause has no end of its own), and the reason says to resume first", why) }
    else { check(false, "paused: the restart is refused") }
    check(RestartPlan.decide(recording: true, hold: .stoppedCall, bundlePath: app) == .afterRecording, "a recording that runs wins: 'after the recording'")
    if case .unavailable = RestartPlan.decide(recording: false, hold: .stoppedCall, bundlePath: "/Users/me/build/obj/\(AppInfo.shortName)") { check(true, "a bare binary cannot relaunch itself, hold or not") } else { check(false, "a bare binary cannot relaunch itself") }
    check(RestartPlan.now.button(armed: false) == (title: "Restart now", enabled: true) && RestartPlan.afterRecording.button(armed: false).title == "Restart after the recording"
          && RestartPlan.afterCall(.stoppedCall).button(armed: false).title == "Restart after the call" && RestartPlan.unavailable("x").button(armed: false).enabled == false
          && RestartPlan.unavailable("x").button(armed: true) == (title: "Cancel the restart", enabled: true) && RestartPlan.afterCall(.callLive).button(armed: true).enabled,
          "the button: its title per plan, off when unavailable, and an armed restart can always be cancelled")
    check(RestartPlan.afterCall(.stoppedCall).armedText == RestartHold.stoppedCall.reason && RestartPlan.afterRecording.armedText.contains("recording ends") && RestartPlan.now.explanation == nil && RestartPlan.afterCall(.paused).explanation == RestartHold.paused.reason,
          "the status line and the tooltip say why the restart waits")
    var t = RestartTracker()
    check(!t.stateChanged(recording: false) && !t.stateChanged(recording: true), "an unarmed tracker never fires")
    t.toggleArmed()
    check(t.armed && !t.stateChanged(recording: true) && t.armed, "armed: nothing while the recording runs")
    check(t.stateChanged(recording: false) && !t.armed && !t.stateChanged(recording: false), "armed: fires once when the recording is over, then disarms")
    t.toggleArmed(); t.toggleArmed()
    check(!t.armed && !t.stateChanged(recording: false), "toggled twice = cancelled")
    // armed while recording; the recording then ends by a manual stop or a pause while the call goes on: the relaunch would record it again, so nothing fires
    var armedTracker = RestartTracker()
    armedTracker.toggleArmed()
    check(!armedTracker.stateChanged(recording: false, hold: .stoppedCall) && armedTracker.armed, "armed: the recording ended by Stop Recording Now while the call is live: no restart, still armed")
    check(!armedTracker.stateChanged(recording: false, hold: .paused) && !armedTracker.stateChanged(recording: false, hold: .callLive) && armedTracker.armed, "armed: a pause or a call about to be recorded holds it as well")
    check(armedTracker.stateChanged(recording: false, hold: nil) && !armedTracker.armed, "armed: it fires once the call is over (nothing is held any more), then disarms")
    check(AppRestarter.arguments(pid: 123, bundlePath: "/Applications/Example Recorder.app") == ["-c", AppRestarter.script, "mc-restart", "123", "/Applications/Example Recorder.app"], "the relaunch helper gets the pid and the path as positional parameters, never inside the script text")
    check(AppRestarter.script.contains("kill -0 \"$1\"") && AppRestarter.script.contains("open -n -a \"$2\"") && !AppRestarter.script.contains("/Applications"), "it waits for the old process, then opens a NEW instance of the bundle (open -n -a)")

    let h = SettingsHarness(base, name: "restart")
    let c = h.coordinator
    h.recording = true
    check(c.restartNow() == .afterRecording && h.spawned.isEmpty && h.terminated == 0, "recording: restartNow starts nothing and does not quit")
    h.recording = false
    h.hold = .paused
    if case .unavailable = c.restartNow() { check(h.spawned.isEmpty && h.terminated == 0, "paused (Settings > Save > Restart now): nothing is started and the app does not quit, so the pause is not lost") } else { check(false, "paused: restartNow is refused") }
    h.hold = .stoppedCall
    check(c.restartNow() == .afterCall(.stoppedCall) && c.restartPlan() == .afterCall(.stoppedCall) && h.spawned.isEmpty && h.terminated == 0, "a call stopped by hand: restartNow starts nothing and does not quit")
    h.hold = nil
    h.spawnWorks = false
    if case .unavailable = c.restartNow() { check(h.terminated == 0, "a relaunch that cannot be started does not quit the app") } else { check(false, "a failing spawn is reported") }
    h.spawnWorks = true
    check(c.restartNow() == .now && h.spawned.last == "/Applications/\(AppInfo.shortName).app" && h.spawned.count == 2 && h.terminated == 1, "idle: the helper is started with the bundle path, then the app quits")
    h.bundle = nil
    if case .unavailable = c.restartNow() { check(h.terminated == 1, "no bundle: nothing more happens") } else { check(false, "no bundle: unavailable") }
}

// MARK: - The coordinator end to end

private func testSettingsCoordinator(_ base: URL) {
    section("settings: the coordinator (load, save, keys) against a temp config.env")
    let fm = FileManager.default
    let original = "# my settings\nUI_LANGUAGE=en\nSELF_NAME=\"Me\"   # my label\nUNKNOWN_KEY=keep\n\nCLAUDE_AUTH=api\n"
    let h = SettingsHarness(base, name: "coordinator", config: original)
    let c = h.coordinator
    let loaded = c.load()
    check(loaded.problem == nil && loaded.snapshot.state("UI_LANGUAGE")?.shown == "en" && loaded.snapshot.state("SELF_NAME")?.shown == "Me", "load reads the file and the policy")

    check(c.save(touched: [:]) == .nothingToSave && h.text == original && h.backups.isEmpty, "nothing touched: nothing written")
    check(c.save(touched: ["UI_LANGUAGE": "en"]) == .nothingToSave, "a touched control that already says it: nothing written")
    check(c.save(touched: ["CLAUDE_DAILY_BUDGET_USD": "-1"]) == .refused([SettingsProblem(key: "CLAUDE_DAILY_BUDGET_USD", message: "must be a plain number such as 5 or 2.5 (0 = off)")]) && h.text == original, "an invalid value: refused with the message, the file untouched")
    check(c.save(touched: ["UI_LANGUAGE": "ko", "CLAUDE_DAILY_BUDGET_USD": "-1"]).isRefusal && h.text == original, "one invalid value refuses the whole save: nothing is written")

    let result = c.save(touched: ["UI_LANGUAGE": "ko", "SELF_NAME": "Sam", "NOTE_MODEL": "sonnet", "LOCAL_ONLY_DEFAULT": "1"])
    guard case .saved(let keys, let restart, let backup) = result else { check(false, "a save succeeds", "\(result)"); return }
    check(keys == ["UI_LANGUAGE", "SELF_NAME", "NOTE_MODEL", "LOCAL_ONLY_DEFAULT"] && restart && backup != nil, "saved: the keys, a restart is needed, a backup was made", "\(keys)")
    check(h.text == "# my settings\nUI_LANGUAGE=ko\nSELF_NAME=\"Sam\"   # my label\nUNKNOWN_KEY=keep\n\nCLAUDE_AUTH=api\n\n# Added by the Settings window\nNOTE_MODEL=sonnet\nLOCAL_ONLY_DEFAULT=1\n",
          "the file: comment, quoting, trailing comment, unknown key and blank line as before; the new keys appended", h.text ?? "nil")
    check(h.backups.count == 1 && (try? String(contentsOf: h.dir.appendingPathComponent(h.backups[0]), encoding: .utf8)) == original, "the backup is the file before the save")
    check(AppConfig.parseEnvText(h.text ?? "")["SELF_NAME"] == "Sam" && ConfigEnvEditor.parseLikePython(h.text ?? "")["SELF_NAME"] == "Sam", "both parsers read the new name")

    // a hand edit after the window was opened is kept (the save works on the file as it is now)
    try? ((h.text ?? "") + "HAND_EDIT=1\n").write(to: h.file, atomically: true, encoding: .utf8)
    h.clock = h.clock.addingTimeInterval(5)
    _ = c.save(touched: ["UI_LANGUAGE": "en"])
    check((h.text ?? "").contains("HAND_EDIT=1\n") && (h.text ?? "").contains("UI_LANGUAGE=en\n"), "a line added by hand since the window loaded is kept")

    // restart only needed for the app's keys
    h.clock = h.clock.addingTimeInterval(5)
    if case .saved(_, let needed, _) = c.save(touched: ["NOTE_MODEL": "opus", "CLAUDE_DAILY_BUDGET_USD": "9"]) { check(!needed, "only pipeline keys changed: no restart is needed (they apply from the next run)") }
    else { check(false, "a pipeline-key save succeeds") }

    // policy lock
    h.policy = settingsPolicy(extra: ["enforced": ["NOTE_MODEL": "haiku"]])
    let before = h.text
    check(c.save(touched: ["NOTE_MODEL": "opus"]).isRefusal && h.text == before, "a policy-locked key cannot be saved")
    h.policy = OrgPolicy.absent()

    // the Privacy box of the checks below is read for a Mac that does not start Local-Only (the test file said LOCAL_ONLY_DEFAULT=1 above): under Local-Only the box
    // says so in one line instead of naming the Claude lane
    h.clock = h.clock.addingTimeInterval(5)
    check(c.save(touched: ["LOCAL_ONLY_DEFAULT": "0"]) != .nothingToSave && !c.privacyLines(states: nil).contains { $0.topic == .localOnly }, "(Local-Only off again for the next checks)")

    // the secrets: a Keychain operation never touches config.env
    let stamp = (try? fm.attributesOfItem(atPath: h.file.path))?[.modificationDate] as? Date
    let textBefore = h.text
    check(c.storeKey(.claude, secret: settingsCanary) == .ok && c.keyStatus(.claude) == .stored, "Save key: the key is in the Keychain item of the Anthropic key; status: stored")
    check(h.keychain.items["MeetingCapture Anthropic API key|tester"] == settingsCanary, "... under the service and account the pipeline reads")
    check(c.checkKey().ok == false && h.mcapCalls.last == .apiKeyCheck && c.checkKeyBlockedReason() == nil, "Check key asks the pipeline (here: a fake that fails)")
    // Check key is a real call to Anthropic: it is off while the organisation policy keeps the Claude lane closed (the Privacy box says nothing goes to Claude then),
    // although `api-key check` itself gates nothing (an explicit command)
    let callsBefore = h.mcapCalls.count
    for (name, closed) in [("a company baseline (no lane opened)", settingsPolicy()), ("a policy that cannot be read", OrgPolicy.locked("bad-json")),
                           ("llm denied", settingsPolicy(extra: ["lanes": ["llm": "deny"]]))] {
        h.policy = closed
        let refusal = c.checkKey()
        check(!refusal.ok && refusal.text.contains("Claude lane closed") && refusal.text.contains("nothing is sent to Anthropic") && c.checkKeyBlockedReason() == refusal.text && h.mcapCalls.count == callsBefore,
              "Check key under \(name): refused with the lock text, and the pipeline is not asked", refusal.text)
        let box = c.privacyLines(states: nil)
        if closed.isLocked {          // a policy that cannot be read forces Local-Only: the box says that, and nothing leaves
            check(box.contains { $0.topic == .localOnly && !$0.leaves && $0.text.contains("fixed by organisation policy") && $0.text.contains("transcript text") } && !box.contains { $0.leaves },
                  "... the same policy: the Privacy box says Local-Only is fixed, and nothing leaves the Mac")
        } else {
            check(box.contains { $0.topic == .transcript && !$0.leaves && $0.text.contains("Claude lane closed") }, "... the same policy: the Privacy box says no transcript text goes to Claude")
        }
    }
    h.policy = settingsPolicy(extra: ["lanes": ["llm": "allow"], "approvals": ["llm": "LLM-1"], "llm": ["claude_bin_pin": ["team_id": "ABCDE12345"]]])
    check(h.policy.laneAllowed("llm") && c.checkKeyBlockedReason() == nil && c.checkKey().ok == false && h.mcapCalls.count == callsBefore + 1 && h.mcapCalls.last == .apiKeyCheck,
          "a company policy that opens the Claude lane: Check key runs")
    h.policy = OrgPolicy.absent()
    check(h.text == textBefore && (try? fm.attributesOfItem(atPath: h.file.path))?[.modificationDate] as? Date == stamp, "config.env is byte-identical and untouched after a key was stored")
    check(!(h.text ?? "").contains(settingsCanary) && !h.backups.contains { ((try? String(contentsOf: h.dir.appendingPathComponent($0), encoding: .utf8)) ?? "").contains(settingsCanary) }, "the key is in neither config.env nor a backup")
    check(c.removeKey(.claude) == .ok && c.keyStatus(.claude) == .notStored, "Remove key: gone from the Keychain")
    check(c.keyStatus(.clova) == .unknown, "no address saved for CLOVA: its key status is unknown (it cannot be bound)")
    if case .refused = c.storeKey(.clova, secret: engineCanary) { check(h.keychain.items.isEmpty, "no key is stored for an engine without a saved address") } else { check(false, "storing a CLOVA key without an address is refused") }
    _ = c.save(touched: ["ASR_CLOVA_INVOKE_URL": "https://clovaspeech-gw.ncloud.com/external/v1/abc/def"])
    check(c.storeKey(.clova, secret: engineCanary) == .ok && h.keychain.items["MeetingCapture ASR clova|tester@clovaspeech-gw.ncloud.com:443"] == engineCanary, "with the address saved the CLOVA key goes to service 'MeetingCapture ASR clova', account <user>@<host>:<port>")
    check(!(h.text ?? "").contains(engineCanary) && !appLogText().contains(engineCanary) && !appLogText().contains(settingsCanary), "no key, of either kind, is in config.env or app.log")
    check(appLogText().contains("settings: saved UI_LANGUAGE") && !appLogText().contains("MeetingCapture ASR clova"), "app.log says which keys were saved, and never the name of a Keychain item")
    // the folder status
    let folder = base.appendingPathComponent("folder-check", isDirectory: true)
    try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
    check(FolderStatus.check(folder.path).state == .writable && FolderStatus.check(folder.appendingPathComponent("new").path).state == .willBeCreated
          && FolderStatus.check(folder.appendingPathComponent("a/b/c").path).state == .parentMissing, "the meeting folder: exists and writable / will be created / parent missing")
    let file = folder.appendingPathComponent("plain.txt")
    try? "x".write(to: file, atomically: true, encoding: .utf8)
    check(FolderStatus.check(file.path).state == .notAFolder, "a file is not a folder")
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    check(getuid() == 0 || FolderStatus.check(folder.path).state == .notWritable, "a folder that cannot be written is said to be so")
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    check(FolderStatus.check("~/definitely-not-there-\(getpid())/x").state == .parentMissing && !FolderStatus(state: .notWritable).ok && FolderStatus(state: .willBeCreated).ok, "~ is expanded; only a missing or unwritable folder is a warning")
}

private extension SettingsSaveResult {
    var isRefusal: Bool { if case .refused = self { return true } else { return false } }
}

// MARK: - The folder status

private func testSettingsFolderChecker() {
    section("settings: the folder status is asked after the typing paused, off the main thread; an answer that was overtaken is dropped")
    var waitDelays: [TimeInterval] = [], waits: [() -> Void] = [], background: [() -> Void] = [], mainQueue: [() -> Void] = []
    var checked: [String] = [], checkedOffMain: [Bool] = [], inBackground = false
    var delivered: [FolderStatus?] = []
    let checker = FolderStatusChecker(check: { path in checked.append(path); checkedOffMain.append(inBackground); return FolderStatus(state: path.hasSuffix("ok") ? .writable : .notWritable) },
                                      mainAfter: { delay, block in waitDelays.append(delay); waits.append(block) },
                                      background: { block in background.append(block) },
                                      main: { block in mainQueue.append(block) })
    func request(_ typed: String, delay: TimeInterval = FolderStatusChecker.debounce) { checker.request(typed: typed, defaultPath: "~/Meetings", delay: delay) { delivered.append($0) } }
    func drain(_ queue: inout [() -> Void], offMain: Bool = false) { let batch = queue; queue = []; inBackground = offMain; batch.forEach { $0() }; inBackground = false }

    request("/tmp/a-ok")
    check(checked.isEmpty && delivered.isEmpty && waitDelays == [0.4] && FolderStatusChecker.debounce == 0.4, "typing: nothing is asked of the file system; the check waits for a pause of 0.4 s")
    request("/tmp/ab-ok")                                                                                  // typing went on
    drain(&waits)
    check(checked.isEmpty && background.count == 1, "the check of the half-typed path never runs: only the last one is scheduled", "\(checked) \(background.count)")
    drain(&background, offMain: true)
    check(checked == ["/tmp/ab-ok"] && checkedOffMain == [true] && delivered.isEmpty, "the file system is asked on a background queue, once, for the last path")
    drain(&mainQueue)
    check(delivered.count == 1 && delivered[0] == FolderStatus(state: .writable), "the answer is delivered on the main queue")

    request("/tmp/x-ok"); drain(&waits)                                                                    // the check of x is on its way ...
    request("/tmp/y-no")                                                                                   // ... and the person typed on
    drain(&background, offMain: true); drain(&mainQueue)
    check(delivered.count == 1, "an answer for a path that was typed over in the meantime is dropped", "\(delivered.count)")
    drain(&waits); drain(&background, offMain: true); drain(&mainQueue)
    check(delivered.count == 2 && delivered[1] == FolderStatus(state: .notWritable) && checked.last == "/tmp/y-no", "the newest path is answered")

    request("/tmp/q-ok"); drain(&waits)
    request("not/absolute")
    check(delivered.count == 3 && delivered[2] == nil && waits.isEmpty, "a text that is no absolute path: nothing to check, said at once and nothing is scheduled")
    drain(&background, offMain: true); drain(&mainQueue)
    check(delivered.count == 3, "... and it also drops the answer of the path before it")
    request("/tmp/now-ok", delay: 0)
    check(waitDelays.last == 0 && checked.count == 4, "a window that was just opened (or a folder that was chosen) asks without a pause, still not on the main thread")
    drain(&waits); drain(&background, offMain: true); drain(&mainQueue)
    check(delivered.last == FolderStatus(state: .writable) && checkedOffMain.allSatisfy { $0 }, "every check of this test ran on the background queue", "\(checkedOffMain)")

    check(FolderStatus.target(typed: "  ", defaultPath: "~/Meetings") == "~/Meetings" && FolderStatus.target(typed: "~/Notes", defaultPath: "~/Meetings") == "~/Notes"
          && FolderStatus.target(typed: "relative", defaultPath: "~/Meetings") == nil && FolderStatus.target(typed: "/Volumes/Share", defaultPath: "~/Meetings") == "/Volumes/Share",
          "an empty field means the default folder; a path that is not absolute has nothing to check")
}

// MARK: - What leaves the Mac

private func testSettingsPrivacy() {
    section("settings: what leaves the Mac (the read-only box of the Privacy tab)")
    let none: [String: Bool?] = [:]
    func lines(_ values: [String: String] = [:], policy: OrgPolicy = OrgPolicy.absent(), consent: [String: Bool?] = [:]) -> [PrivacySummary.Line] {
        PrivacySummary.lines(values: values, policy: policy, consent: consent)
    }
    func topics(_ l: [PrivacySummary.Line]) -> [PrivacySummary.Line.Topic] { l.map { $0.topic } }
    func has(_ l: [PrivacySummary.Line], _ topic: PrivacySummary.Line.Topic, leaves: Bool? = nil, _ phrase: String) -> Bool {
        l.contains { $0.topic == topic && (leaves == nil || $0.leaves == leaves) && $0.text.contains(phrase) }
    }

    let personal = lines()
    check(has(personal, .audio, leaves: false, "runs on this Mac with local Whisper") && has(personal, .transcript, leaves: true, "sent to Claude (Anthropic)") && has(personal, .calendar, leaves: false, "auto-start is off")
          && has(personal, .archive, leaves: false, "~/Meetings"), "the personal default: speech stays local, the transcript text goes to Claude, no calendar auto-start, a local archive")
    check(has(personal, .calendar, leaves: true, "CALENDAR_LOOKUP"), "CALENDAR_LOOKUP is on unless the file says 0: its connector lookup is said too")
    check(!lines(["CALENDAR_LOOKUP": "0"]).contains { $0.text.contains("CALENDAR_LOOKUP") }, "CALENDAR_LOOKUP=0 removes that line")
    check(!personal.contains { $0.text.lowercased().contains("never leaves") || $0.text.lowercased().contains("does not leave") }, "no sentence claims that audio never leaves the Mac (docs/PRIVACY_LANES.md: Drive can take the m4a)")

    let consented = lines(["ASR_ENGINE": "clova"], consent: ["clova": true])
    check(has(consented, .audio, leaves: true, "NAVER Cloud CLOVA Speech") && has(consented, .audio, "never the title, attendees, session id or file name"), "a cloud engine with a consent: speech goes there, and what never goes is said")
    let unconsented = lines(["ASR_ENGINE": "clova"], consent: ["clova": false])
    check(has(unconsented, .audio, leaves: false, "no valid consent is recorded, so nothing is sent") && has(unconsented, .audio, "Terminal only"), "a cloud engine without a consent: nothing is sent, local Whisper is used, consent is Terminal only")
    check(has(lines(["ASR_ENGINE": "openai-compat"], consent: none), .audio, leaves: false, "could not be read") && has(lines(["ASR_ENGINE": "openai-compat"], consent: ["openai-compat": nil]), .audio, leaves: false, "could not be read"), "consent not known: it says so and claims no upload")
    check(has(lines(["ASR_ENGINE": "openai-compat"], consent: ["openai-compat": true]), .audio, leaves: true, "cannot tell who runs it"), "openai-compat names that this Mac cannot tell who runs the server")
    check(has(lines(["ASR_ENGINE": "auto"]), .audio, leaves: false, "ASR_ENGINE=auto uses local Whisper"), "auto: local Whisper when possible")
    let fallback = lines(["ASR_ENGINE": "whisper", "ASR_FALLBACK": "clova"], consent: ["clova": true])
    check(has(fallback, .audio, leaves: true, "Fallback engine") && has(fallback, .audio, leaves: false, "local Whisper"), "an external fallback engine is listed with its consent state")

    let localOnly = lines(["LOCAL_ONLY_DEFAULT": "1", "ASR_ENGINE": "clova", "OFFLINE_AUTOSTART": "auto"], consent: ["clova": true])
    check(localOnly.first?.topic == .localOnly && !localOnly.contains { $0.leaves } && !localOnly.contains { $0.topic == .transcript || $0.topic == .archive }, "Local-Only as the default: one line, nothing leaves, even with a consented engine and auto-start on")
    check(has(localOnly, .calendar, leaves: false, "Local-Only closes it"), "... and the calendar auto-start is said to be closed by it")
    check(has(lines(policy: settingsPolicy(extra: ["local_only": ["default": true, "locked": true]])), .localOnly, leaves: false, "fixed by organisation policy"), "Local-Only fixed by the policy says so")
    check(lines(policy: settingsPolicy(extra: ["local_only": ["default": true, "locked": false]])).first?.topic == .localOnly, "a policy default of Local-Only closes the lanes in the box too")
    let denied = lines(["OFFLINE_AUTOSTART": "auto", "ASR_ENGINE": "clova"], policy: settingsPolicy(extra: ["local_only": ["default": false, "locked": false]]), consent: ["clova": true])
    check(has(denied, .transcript, leaves: false, "organisation policy keeps the Claude lane closed") && has(denied, .calendar, leaves: false, "keeps the calendar lane closed") && has(denied, .audio, leaves: false, "keeps that lane closed")
          && has(denied, .archive, leaves: false, "stay on this Mac") && !denied.contains { $0.leaves }, "organisation lanes that are closed: nothing is claimed to leave through them, and the archive says it stays here")
    let google = lines(["OFFLINE_AUTOSTART": "auto"])
    check(has(google, .calendar, leaves: true, "reads your primary Google Calendar (read-only") && has(google, .calendar, "never writes to your calendar"), "auto-start on: Google Calendar, read-only, directly from Google")
    check(has(lines(["CLAUDE_AUTH": "banana"]), .transcript, leaves: false, "neither api nor subscription") && has(lines(["CLAUDE_AUTH": "subscription"]), .transcript, leaves: true, "claude.ai login"), "CLAUDE_AUTH decides the wording; a misspelling means no Claude call")
    check(has(lines(["ARCHIVE_DIR": "~/Library/CloudStorage/GoogleDrive-me@example.org/My Drive/Meetings"]), .archive, leaves: true, "sync service gets a copy of the audio too")
          && has(lines(["ARCHIVE_DIR": "/Volumes/Share/Meetings"]), .archive, leaves: false, "Nothing leaves the Mac unless something syncs"), "a synced archive folder is named as a way out for the audio files")
    check(PrivacySummary.looksSynced("/Users/me/Dropbox/Meetings") && PrivacySummary.looksSynced("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/M") && !PrivacySummary.looksSynced("/Users/me/Meetings"), "synced folders are recognised")
    let box = PrivacySummary.text(personal)
    check(box.hasPrefix("\u{2022} Speech recognition") && box.contains("\n\n\u{2022} Transcript text"), "the box is one bullet per line, in plain words")
    check(!box.contains(settingsCanary) && !box.contains("sk-ant"), "no key in the box")
    L10n.current = .ko
    let ko = PrivacySummary.lines(values: ["ASR_ENGINE": "clova", "OFFLINE_AUTOSTART": "auto"], policy: OrgPolicy.absent(), consent: ["clova": true])
    check(ko.allSatisfy { hasHangulText($0.text) } && ko.contains { $0.text.contains("NAVER Cloud CLOVA Speech") }, "the same box in Korean")
    L10n.current = .en
}

/// The Privacy box must say what EffectiveLanes (the code behind the menu and the notifications) says: a policy that closes a lane, lists other engines or
/// allows other archive roots closes the way out in the box too; and the consent, the stored key and the vocabulary switch are added on top.
private func testSettingsPrivacyFollowsLanes() {
    section("settings: the Privacy box follows EffectiveLanes, the consent, the stored key and the vocabulary switch")
    let home = "/Users/alice"
    let team = home + "/Library/CloudStorage/GoogleDrive-user@example.com/Shared drives/Meetings"
    let myDrive = home + "/Library/CloudStorage/GoogleDrive-user@example.com/My Drive/Meetings"
    let support = AppConfig.defaultSupportDir
    func company(_ engines: [String], vocab: [String: Bool]? = nil, lanes: [String: String]? = nil) -> OrgPolicy {
        var asr: [String: Any] = ["allowed_engines": engines]
        if let v = vocab { asr["send_vocab"] = v }
        let open: [String: Any] = lanes ?? ["asr_remote": "allow", "asr_cloud": "allow", "llm": "allow", "calendar": "allow", "drive": "allow"]
        return settingsPolicy(extra: ["lanes": open, "approvals": ["asr_cloud": "A", "llm": "L", "calendar": "C", "drive": "D"], "llm": ["claude_bin_pin": ["team_id": "ABCDE12345"]],
                                      "asr": asr, "archive": ["allowed_roots": ["~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings"]]])
    }
    func lines(_ values: [String: String], _ policy: OrgPolicy = OrgPolicy.absent(), consent: [String: Bool?] = [:], keyMissing: Set<String> = []) -> [PrivacySummary.Line] {
        PrivacySummary.lines(values: values, policy: policy, consent: consent, credentialMissing: keyMissing, home: home)
    }
    func has(_ l: [PrivacySummary.Line], _ topic: PrivacySummary.Line.Topic, leaves: Bool? = nil, _ phrase: String) -> Bool {
        l.contains { $0.topic == topic && (leaves == nil || $0.leaves == leaves) && $0.text.contains(phrase) }
    }
    func effective(_ values: [String: String], _ policy: OrgPolicy) -> EffectiveLanes {
        let privacy = PrivacySettings.build(from: values, supportDir: support, source: "settings-test")
        return EffectiveLanes.compute(policy: policy, localOnly: privacy.localOnlyDefault || (policy.isValid && policy.localOnlyDefault), settings: privacy,
                                      archiveDir: URL(fileURLWithPath: ((values["ARCHIVE_DIR"] ?? "~/Meetings") as NSString).expandingTildeInPath, isDirectory: true), home: home)
    }
    let terms = "terms of your vocabulary list"

    // the case of the review: a company policy that lists only whisper and remote, clova chosen and consented, a personal Drive folder
    let narrow = company(["whisper", "remote"])
    check(narrow.isValid && narrow.laneAllowed("asr_cloud") && narrow.allowedEngines == ["whisper", "remote"], "(the company policy of these tests is valid; it lists whisper and remote only)", narrow.lockedReason ?? "")
    let stray: [String: String] = ["ASR_ENGINE": "clova", "ARCHIVE_DIR": myDrive]
    let strayLines = lines(stray, narrow, consent: ["clova": true])
    let strayLanes = effective(stray, narrow)
    check(strayLanes.asr == "this-mac" && strayLanes.archive == "this-mac", "(EffectiveLanes: this Mac, this Mac)", "\(strayLanes)")
    check(has(strayLines, .audio, leaves: false, "does not allow this engine") && !strayLines.contains { $0.topic == .audio && $0.leaves } && !strayLines.contains { $0.text.contains(terms) },
          "an engine the policy does not list: nothing is said to be sent, although a consent is recorded", "\(strayLines.map { $0.text })")
    check(has(strayLines, .archive, leaves: false, "stay on this Mac") && !strayLines.contains { $0.topic == .archive && $0.leaves }, "an archive folder outside the allowed roots: it stays here, the box does not say the sync service gets the audio")
    check(!lines(["ASR_ENGINE": "whisper"], narrow).contains { $0.topic == .archive && $0.leaves } && has(lines(["ASR_ENGINE": "whisper"], narrow), .archive, leaves: false, "no ARCHIVE_DIR of your own"),
          "a company Mac without an ARCHIVE_DIR of its own has no archive upload")
    let team1: [String: String] = ["ASR_ENGINE": "remote", "ARCHIVE_DIR": team]
    let teamLines = lines(team1, narrow, consent: ["remote": true])
    check(effective(team1, narrow).asr == "company-server" && effective(team1, narrow).archive == "org-folder" && has(teamLines, .audio, leaves: true, "your organisation's speech server") && has(teamLines, .archive, leaves: true, "sync service gets a copy"),
          "an allowed engine and an allowed team folder: both leave, as EffectiveLanes says")
    check(has(lines(["ASR_ENGINE": "auto"], company(["whisper"])), .audio, leaves: false, "does not allow it") && has(lines(["ASR_ENGINE": "auto"], narrow), .audio, leaves: false, "uses local Whisper when this Mac can run it"),
          "auto: the company server only when the policy lists it")

    // a consent is not enough: the key must be stored (credential 'missing' in `asr-engines list`)
    let noKey = lines(["ASR_ENGINE": "clova"], consent: ["clova": true], keyMissing: ["clova"])
    check(has(noKey, .audio, leaves: false, "no API key is stored for it") && !noKey.contains { $0.topic == .audio && $0.leaves } && !noKey.contains { $0.text.contains(terms) }, "a consented engine whose API key is not stored: nothing can be sent, and the box says so")
    check(has(lines(["ASR_ENGINE": "clova"], consent: ["clova": true]), .audio, leaves: true, "NAVER Cloud CLOVA Speech"), "... with the key stored (or unknown) it is described as sent")
    let h = SettingsHarness(FileManager.default.temporaryDirectory.appendingPathComponent("mcap-selftest-settings-lanes-\(getpid())", isDirectory: true), name: "lanes", config: "ASR_ENGINE=clova\n")
    defer { try? FileManager.default.removeItem(at: h.dir.deletingLastPathComponent()) }
    let rows = [AsrEngineState(engine: "clova", consentOK: true, consent: "valid", credential: "missing")]
    check(h.coordinator.privacyLines(states: Dictionary(uniqueKeysWithValues: rows.map { ($0.engine, $0) })).contains { $0.text.contains("no API key is stored") }
          && !h.coordinator.privacyLines(states: ["clova": AsrEngineState(engine: "clova", consentOK: true, consent: "valid", credential: "stored")]).contains { $0.text.contains("no API key is stored") },
          "the coordinator hands the stored-key facts of `asr-engines list` to the box")

    // the vocabulary goes along with the speech to CLOVA, Azure and the company server (docs/PRIVACY_LANES.md 2.2), never to an OpenAI-style server
    for engine in ["clova", "azure", "remote"] {
        check(has(lines(["ASR_ENGINE": engine], consent: [engine: true]), .audio, leaves: true, terms), "\(engine) with a consent, ASR_SEND_VOCAB unset (the default is on): the box names the vocabulary list too")
        for off in ["0", "off", "no", "false", "maybe"] {
            check(!lines(["ASR_ENGINE": engine, "ASR_SEND_VOCAB": off], consent: [engine: true]).contains { $0.text.contains(terms) }, "\(engine), ASR_SEND_VOCAB=\(off): no vocabulary in the box (an unclear value reads as off)")
        }
        check(has(lines(["ASR_ENGINE": engine, "ASR_SEND_VOCAB": "1"], consent: [engine: true]), .audio, leaves: true, terms), "\(engine), ASR_SEND_VOCAB=1: the vocabulary is named")
        check(!lines(["ASR_ENGINE": engine], consent: [engine: false]).contains { $0.text.contains(terms) } && !lines(["ASR_ENGINE": engine], consent: [:]).contains { $0.text.contains(terms) }, "\(engine) without a consent (or an unknown one): nothing is sent, no vocabulary named")
        check(!lines(["ASR_ENGINE": engine, "LOCAL_ONLY_DEFAULT": "1"], consent: [engine: true]).contains { $0.text.contains(terms) }, "\(engine) under Local-Only: no vocabulary named")
    }
    check(!lines(["ASR_ENGINE": "openai-compat"], consent: ["openai-compat": true]).contains { $0.text.contains(terms) }, "openai-compat sends no terms: the box does not name them")
    check(has(lines(["ASR_ENGINE": "whisper", "ASR_FALLBACK": "clova"], consent: ["clova": true]), .audio, leaves: true, terms), "a fallback engine names the vocabulary too")
    check(has(lines(["ASR_ENGINE": "auto"], narrow), .audio, leaves: false, "vocabulary list go along") && !lines(["ASR_ENGINE": "auto", "ASR_SEND_VOCAB": "0"], narrow).contains { $0.topic == .audio && $0.text.contains("vocabulary") }, "auto names the vocabulary that goes with a company server, unless ASR_SEND_VOCAB is off")
    // the policy: asr.send_vocab.cloud defaults to false for a company, .server to true
    let cloudDefault = company(["whisper", "remote", "clova", "azure", "openai-compat"])
    check(!cloudDefault.sendVocabCloud && cloudDefault.sendVocabServer && OrgPolicy.absent().sendVocabCloud && OrgPolicy.absent().sendVocabServer && !OrgPolicy.locked("bad-json").sendVocabServer, "the policy's send_vocab flags are read (company cloud: off, server: on; no policy: both on; a locked one: both off)")
    check(!lines(["ASR_ENGINE": "clova", "ARCHIVE_DIR": team], cloudDefault, consent: ["clova": true]).contains { $0.text.contains(terms) } && has(lines(["ASR_ENGINE": "clova", "ARCHIVE_DIR": team], cloudDefault, consent: ["clova": true]), .audio, leaves: true, "CLOVA"),
          "a company policy that keeps the vocabulary at home (cloud default false): the speech goes, the vocabulary is not named")
    check(has(lines(["ASR_ENGINE": "clova", "ARCHIVE_DIR": team], company(["whisper", "clova"], vocab: ["cloud": true]), consent: ["clova": true]), .audio, leaves: true, terms), "asr.send_vocab.cloud=true: named")
    check(has(lines(["ASR_ENGINE": "remote", "ARCHIVE_DIR": team], company(["whisper", "remote"], vocab: ["server": true, "cloud": false]), consent: ["remote": true]), .audio, leaves: true, terms)
          && !lines(["ASR_ENGINE": "remote", "ARCHIVE_DIR": team], company(["whisper", "remote"], vocab: ["server": false]), consent: ["remote": true]).contains { $0.text.contains(terms) }, "asr.send_vocab.server decides for the company server")
    let both: [String: String] = ["ASR_ENGINE": "clova", "ASR_FALLBACK": "remote", "ARCHIVE_DIR": team]
    let bothAllowed = company(["whisper", "clova", "remote"], vocab: ["cloud": true, "server": true]), oneDenied = company(["whisper", "clova", "remote"], vocab: ["cloud": true, "server": false])
    check(lines(both, bothAllowed, consent: ["clova": true, "remote": true]).filter { $0.text.contains(terms) }.count == 2 && !lines(both, oneDenied, consent: ["clova": true, "remote": true]).contains { $0.text.contains(terms) },
          "primary and fallback in use: the vocabulary goes only when the policy allows it for both kinds (the pipeline's all())")
    L10n.current = .ko
    check(has(lines(["ASR_ENGINE": "clova"], consent: ["clova": true]), .audio, leaves: true, "용어집(vocabulary.txt)의 용어를") && hasHangulText(lines(["ASR_ENGINE": "clova"], consent: ["clova": true], keyMissing: ["clova"]).first?.text ?? ""),
          "the vocabulary and the missing key are said in Korean too")
    L10n.current = .en

    // agreement with EffectiveLanes over a grid of policies, engines, consents and folders: the box never says more than the lanes allow
    let policies: [(String, OrgPolicy)] = [("personal", OrgPolicy.absent()), ("company open", cloudDefault), ("company: whisper and remote", narrow), ("company baseline", settingsPolicy()),
                                           ("locked", OrgPolicy.locked("bad-json")), ("Local-Only default", settingsPolicy(extra: ["local_only": ["default": true, "locked": false]])),
                                           ("company: cloud lane denied", company(["whisper", "remote", "clova", "azure"], lanes: ["asr_remote": "allow", "asr_cloud": "deny", "llm": "allow", "calendar": "allow", "drive": "allow"]))]
    var violations: [String] = []
    var scenarios = 0
    for (policyName, policy) in policies {
        for engine in PrivacySettings.engineWords {
            for fallback in ["none", "clova", "remote"] {
                for localOnly in ["0", "1"] {
                    for folder in [myDrive, team, "/Volumes/Share/Meetings"] {
                        for answer in [true, false, nil] as [Bool?] {
                            var consent: [String: Bool?] = [:]
                            for e in PrivacySettings.engineWords { consent[e] = answer }
                            let values = ["ASR_ENGINE": engine, "ASR_FALLBACK": fallback, "LOCAL_ONLY_DEFAULT": localOnly, "ARCHIVE_DIR": folder]
                            let out = lines(values, policy, consent: consent)
                            let lanes = effective(values, policy)
                            scenarios += 1
                            let tag = "\(policyName) / \(engine)+\(fallback) / local-only \(localOnly) / \(folder.suffix(18)) / consent \(String(describing: answer))"
                            if out.contains(where: { $0.topic == .audio && $0.leaves }) && (lanes.asr == "this-mac" || lanes.asr == "local-only") { violations.append("audio: \(tag)") }
                            if out.contains(where: { $0.topic == .archive && $0.leaves }) && lanes.archive != "org-folder" { violations.append("archive: \(tag)") }
                            if out.contains(where: { $0.topic == .transcript && $0.leaves }) && !lanes.note { violations.append("note: \(tag)") }
                            if out.contains(where: { $0.topic == .calendar && $0.leaves && $0.text.contains("CALENDAR_LOOKUP") }) != (lanes.calendar && lanes.note) { violations.append("lookup: \(tag)") }
                            if lanes.asr == "local-only" && (out.contains { $0.leaves } || out.first?.topic != .localOnly) { violations.append("local-only: \(tag)") }
                            if lanes.asr != "local-only" && lanes.archive == "org-folder" && !out.contains(where: { $0.topic == .archive && $0.text.contains("moved to") }) { violations.append("archive line missing: \(tag)") }
                            if lanes.asr != "local-only" && lanes.archive == "this-mac" && !out.contains(where: { $0.topic == .archive && !$0.leaves && $0.text.contains("stay on this Mac") }) { violations.append("archive closed line missing: \(tag)") }
                        }
                    }
                }
            }
        }
    }
    check(scenarios == 7 * 6 * 3 * 2 * 3 * 3 && violations.isEmpty, "\(scenarios) combinations of policy, engines, Local-Only, folder and consent: the box never claims a way out that EffectiveLanes closes", violations.prefix(5).joined(separator: " | "))
}

// MARK: - The menu-bar icon

private func testSettingsMenuIcon() {
    section("menu bar icons: one pure mapping from the state to SF Symbol names")
    func state(_ status: SessionStatus, paused: Bool = false, off: Bool = false) -> ControllerState {
        var s = ControllerState()
        s.status = status
        s.paused = paused
        s.autoDetectionOff = off
        return s
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    typealias M = StatusMenuController
    check(M.menuIcon(for: state(.idle)) == M.MenuIcon(names: ["pencil.and.list.clipboard", "list.clipboard", "waveform"], red: false), "idle: pencil.and.list.clipboard")
    check(M.menuIcon(for: state(.idle, paused: true)).names == ["pause.circle", "waveform"], "paused: pause.circle")
    check(M.menuIcon(for: state(.idle, off: true)).names.first == "pencil.slash" && M.menuIcon(for: state(.idle, off: true)).names.contains("waveform.slash"), "auto-detection off: a slashed variant that exists (pencil.slash)")
    check(M.menuIcon(for: state(.idle, paused: true, off: true)).names.first == "pause.circle", "paused wins over detection off, as before")
    check(M.menuIcon(for: state(.candidate(.zoom))) == M.menuIcon(for: state(.idle)), "candidate: the idle symbol (SF Symbols has no circle variant of pencil.and.list.clipboard)")
    check(M.menuIcon(for: state(.processing("Transcribing"))).names == ["ellipsis.bubble", "ellipsis.circle", "gearshape"], "processing: ellipsis.bubble")
    check(M.menuIcon(for: state(.done("Title"))).names == ["checkmark.circle", "checkmark"], "done: checkmark.circle")
    check(M.menuIcon(for: state(.error("x"))).names == ["exclamationmark.triangle"], "error: exclamationmark.triangle")
    let rec = state(.recording(.zoom, since: t0))
    let even = M.menuIcon(for: rec, elapsed: 4), odd = M.menuIcon(for: rec, elapsed: 5)
    check(even.red && odd.red && even.names.first == "pencil.and.scribble" && odd.names.first == "pencil.line", "recording: red pencil.and.scribble, alternating with pencil.line each second")
    check(M.menuIcon(for: rec, elapsed: 0).names.first == "pencil.and.scribble" && M.menuIcon(for: rec, elapsed: -3).names.first == "pencil.and.scribble", "the first frame is pencil.and.scribble (and a clock step back does not break it)")
    check(M.menuIcon(for: rec, elapsed: 5, reduceMotion: true).names.first == "pencil.and.scribble" && M.menuIcon(for: rec, elapsed: 6, reduceMotion: true).names.first == "pencil.and.scribble", "with Reduce Motion the icon stays on the first frame")
    check(!M.menuIcon(for: state(.idle)).red && !M.menuIcon(for: state(.error("x"))).red && !M.menuIcon(for: state(.processing("x"))).red, "only the recording icon is red")
    check(even.names.last == "record.circle.fill" && odd.names.last == "record.circle.fill" && M.menuIcon(for: state(.idle)).names.last == "waveform", "every list ends in a symbol of the former set, so an older macOS never shows nothing")

    // the first-choice names are SF Symbols 5 or older (macOS 14.0): the list of names verified with scripts (docs/BRANDING.md) and, where the OS can say, its availability file
    let verified: Set<String> = ["pencil.and.list.clipboard", "pencil.and.scribble", "pencil.line", "pause.circle", "pencil.slash", "ellipsis.bubble", "checkmark.circle", "exclamationmark.triangle",
                                 "list.clipboard", "waveform", "waveform.slash", "record.circle.fill", "ellipsis.circle", "gearshape", "checkmark", "pencil"]
    let all = Set([even, odd, M.menuIcon(for: state(.idle)), M.menuIcon(for: state(.idle, paused: true)), M.menuIcon(for: state(.idle, off: true)), M.menuIcon(for: state(.processing("x"))),
                   M.menuIcon(for: state(.done("x"))), M.menuIcon(for: state(.error("x")))].flatMap { $0.names })
    check(all.isSubset(of: verified), "every name is on the list that was checked on macOS 14.0's symbol set", "\(all.subtracting(verified))")
    let missing = all.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
    check(missing.isEmpty, "every name renders as an SF Symbol on this Mac", "\(missing)")
    let plist = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
    if let data = FileManager.default.contents(atPath: plist), let doc = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
       let symbols = doc["symbols"] as? [String: String], let years = doc["year_to_release"] as? [String: [String: String]] {
        func macOS(_ name: String) -> [Int] { (symbols[name].flatMap { years[$0]?["macOS"] } ?? "99").split(separator: ".").compactMap { Int($0) } }
        func atMost14_4(_ v: [Int]) -> Bool { v.first.map { $0 < 14 || ($0 == 14 && (v.count < 2 || v[1] <= 4)) } ?? false }
        let late = all.filter { !atMost14_4(macOS($0)) }
        check(late.isEmpty, "none of them needs a macOS newer than 14.4 (CoreGlyphs name_availability.plist)", "\(late.map { "\($0): \(macOS($0))" })")
    } else {
        print("  info  name_availability.plist is not on this Mac: the macOS 14.4 availability of the names was not checked here")
    }
}

// MARK: - Drift guards (the sources of the pipeline)

private func testSettingsDriftGuards() {
    section("settings: the names the window uses are still the pipeline's (config.py, apikey.py, asr_creds.py, gcal.py, cli.py, Config.swift)")
    guard let repo = repoRoot() else { check(false, "the repo is found next to the working directory or the app (pipeline/mcap/cli.py)"); return }
    let configPy = source(repo, "pipeline/mcap/config.py"), configSwift = source(repo, "app/Sources/Config.swift"), policySwift = source(repo, "app/Sources/Policy.swift")
    let apikey = source(repo, "pipeline/mcap/apikey.py"), creds = source(repo, "pipeline/mcap/asr_creds.py"), gcal = source(repo, "pipeline/mcap/gcal.py"), cli = source(repo, "pipeline/mcap/cli.py")
    let providers = source(repo, "pipeline/mcap/asr_providers.py"), types = source(repo, "app/Sources/Types.swift")
    check(!configPy.isEmpty && !configSwift.isEmpty && !apikey.isEmpty && !creds.isEmpty && !gcal.isEmpty && !cli.isEmpty && !providers.isEmpty, "the sources are readable", repo.path)
    let unknown = SettingsCatalog.keys.filter { key in
        let quoted = "\"\(key)\""
        return !(configPy.contains(quoted) || configSwift.contains(quoted) || policySwift.contains(quoted))
    }
    check(unknown.isEmpty, "every key the window edits is a key the parsers know (config.py _KEYS, Config.swift or Policy.swift)", "\(unknown)")
    let pythonOnly = SettingsCatalog.keys.filter { configPy.contains("\"\($0)\": (") }
    check(pythonOnly.count >= 9, "the pipeline's keys are in config.py _KEYS", "\(pythonOnly)")
    check(types.contains("\"MeetingCapture Anthropic API key\"") && apikey.contains("DEFAULT_SERVICE = \"MeetingCapture Anthropic API key\"") && AppConfig.defaults().claudeKeychainService == "MeetingCapture Anthropic API key",
          "the Anthropic key's service name is the same string in Swift and Python")
    check(creds.contains("SERVICE_PREFIX = \"MeetingCapture ASR \"") && AsrDestination.servicePrefix == "MeetingCapture ASR " && creds.contains("return f\"{apikey.keychain_account()}@{name}:{port}\""),
          "the ASR key's service prefix and account format (<user>@<host>:<port>) are the same in Swift and Python")
    check(apikey.contains("return os.environ.get(\"USER\") or getpass.getuser()") && PipelineLauncher.sanitizedEnvironment()["USER"] == NSUserName(), "Python's account is $USER, and the launcher gives the child USER = the login name")
    check(gcal.contains("command = f'add-generic-password -U -a \"{account}\" -s \"{TOKEN_SERVICE}\" -X {blob.encode(\"utf-8\").hex()}\\n'") && gcal.contains("[apikey.security_bin(), \"-i\"]") && gcal.contains("input=command.encode(\"utf-8\")"),
          "the write method is the one gcal.write_token uses: security -i, the command on stdin, the value hex-encoded (-X)")
    check(gcal.contains("MAX_COMMAND_BYTES = 3000") && SettingsKeychain.maxCommandBytes == 3000 && creds.contains("MAX_SECRET_CHARS = 512") && SettingsKeychain.maxSecretChars == 512, "the command and secret limits are the same")
    check(providers.contains("CLOVA_HOST_SUFFIXES = (\".ncloud.com\", \".fin-ncloud.com\", \".gov-ncloud.com\")"), "the CLOVA host suffixes are still the three NAVER Cloud ones")
    check(cli.contains("CONSENT_PHRASE") && cli.contains("a = asub.add_parser(\"consent\"") && cli.contains("add_parser(\"gcal\"") && cli.contains("choices=[\"auth\", \"status\", \"forget\", \"upcoming\"]") && cli.contains("choices=[\"status\", \"set\", \"check\", \"forget\"]"),
          "`asr-engines consent`, `gcal auth|status` and `api-key check` are commands of the pipeline")
    check(cli.contains("print(\"API key OK\")") && cli.contains("print(f\"FAILED: {apikey.redact(res.message)}\", file=sys.stderr)"), "`api-key check` still says 'API key OK' / 'FAILED: ...' (the window reads those words)")
    check(gcal.contains("NOT usable") && gcal.contains("NOT available") && gcal.contains("organisation lane: ") && gcal.contains("print(\"ready\" if ready else") && gcal.contains("DENIED ("), "`gcal status` still says NOT usable / NOT available / DENIED / ready (the window reads those words)")
    check(cli.contains("print(json.dumps({\"schema\": 1, \"engines\": rows}") && cli.contains("\"consent\": \"n/a\"") && cli.contains("row[\"consent\"] = state[\"state\"] + (f\" (until {state['expires']})\" if state[\"state\"] == \"ok\" else \"\")"),
          "`asr-engines list --json` still has the rows and the consent words the window reads")
    // the window never writes the consent file or a token: its sources do not even name them
    let own = ["SettingsModel", "SettingsConfigWriter", "SettingsKeychain", "SettingsBackend", "SettingsWindow"].map { source(repo, "app/Sources/\($0).swift") }
    check(own.allSatisfy { !$0.isEmpty }, "the Settings sources are readable")
    check(own.allSatisfy { !$0.contains("asr-consent") && !$0.contains("consent_path") && !$0.contains("write_consent") }, "no Settings source names the consent file: the window cannot write it")
    check(own.allSatisfy { !$0.contains("TOKEN_SERVICE") && !$0.contains("Google Calendar token") }, "no Settings source names the Google token's Keychain item")
    check(!own[0].contains("API_KEY") || !own[0].contains("SettingsField(key: \"ANTHROPIC"), "no secret is a catalog key")
}

// MARK: - Korean

private func testSettingsKorean() {
    section("settings: Korean texts (UI_LANGUAGE=ko)")
    check(SettingsLock.policy.reason == "조직 정책으로 고정" && KeyStatus.stored.text == "키체인에 저장됨" && KeyStatus.notStored.text == "저장 안 됨", "lock reason and key status in Korean")
    check(hasHangulText(KeyCheckOutcome.interpret(McapRun(launched: true, status: 0, timedOut: true, output: "")).text) && hasHangulText(GoogleCalendarState.notSignedIn.text), "check results in Korean")
    check(hasHangulText(ConsentLine.make(engine: "clova", states: nil).text) && hasHangulText(FolderStatus(state: .writable).text), "consent line and folder status in Korean")
    check(hasHangulText(SettingsCatalog.field("UI_LANGUAGE")!.title) && SettingsTab.privacy.title == "개인정보", "catalog and tabs in Korean")
    if case .failure(let e) = SettingsValue.canonical("fr", for: SettingsCatalog.field("UI_LANGUAGE")!) { check(hasHangulText(e.message) && e.message.contains("en, ko"), "a refusal in Korean names the allowed words", e.message) } else { check(false, "fr is refused") }
    check(hasHangulText(ConfigEnvEditor.structuralProblem(key: "A", value: "x\ny") ?? ""), "the writer's refusals in Korean")
    check(StatusMenuController.menuIcon(for: ControllerState()).names.first == "pencil.and.list.clipboard", "the icon mapping does not depend on the language")
    check([RestartHold.paused, .stoppedCall, .callLive].allSatisfy { hasHangulText($0.reason) } && hasHangulText(RestartPlan.afterCall(.callLive).button(armed: false).title) && hasHangulText(RestartPlan.now.button(armed: true).title),
          "the restart texts in Korean")
    let closed = SettingsCoordinator(env: SettingsEnvironment(configFile: { URL(fileURLWithPath: "/nonexistent/config.env") }, policy: { OrgPolicy.locked("bad-json") },
                                                              runMcap: { _ in McapRun(launched: false, status: -1, timedOut: false, output: "") }, openTerminal: { _ in false },
                                                              python: { URL(fileURLWithPath: "/nonexistent/python") }, pipelineDir: { URL(fileURLWithPath: "/nonexistent") }, isRecording: { false }))
    check(hasHangulText(closed.checkKeyBlockedReason() ?? ""), "the Check key lock text in Korean")
    check(["LOCAL_ONLY_DEFAULT", "LOG_CONTENT", "CLAUDE_AUTH", "ASR_STRATEGY", "CALL_DETECT", "CLAUDE_DAILY_BUDGET_USD", "NOTE_MODEL"].allSatisfy {
        hasHangulText(SettingsValue.unreadable("zzz", for: SettingsCatalog.field($0)!, canonicalDefault: "x").message) }, "what the code reads for a stored text that is not understood, in Korean")
    check(canon("ASR_OPENAI_COMPAT_MODEL", "my model") == nil, "(a model name with a blank is refused)")
    if case .failure(let e) = SettingsValue.canonical("my model", for: SettingsCatalog.field("ASR_OPENAI_COMPAT_MODEL")!) { check(hasHangulText(e.message) && e.message.contains("100"), "the refusal of a model name in Korean says the limit", e.message) } else { check(false, "a model name with a blank is refused") }
}
