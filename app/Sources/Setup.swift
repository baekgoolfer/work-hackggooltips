import AppKit
import Foundation
import Darwin

// =====================================================================================
// `<short name> setup` (CATE setup by default): one-shot first-install checklist.
//
// It deliberately TRIGGERS the macOS permission prompts (microphone, system audio, Chrome automation (only when Meet is
// enabled: it is off by default), Google Drive folder access, notifications) so they appear once, attributed to the app, instead of in the
// middle of the first real meeting. Exit code 0 only if every check is OK: a FAIL or a WARN (a status string we do
// not recognize, or one that could not be verified) both give exit code 1, so setup never reports green by accident.
//
// Claude billing (SPEC 17): CLAUDE_AUTH=subscription checks the claude.ai login as before; CLAUDE_AUTH=api checks that the API key ITEM
// exists in the Keychain (`security find-generic-password -s <service> -a <user>`, never -w / -g: the app does not read the key).
//
// Claude is optional for a personal install: audio and transcripts work without it. So without an organisation policy of the company
// profile a missing `claude` tool, or a login that `claude auth status` does not show, is a [WARN] (SetupLanePlan.claudeOptional), not a
// [FAIL]: `make confirm-live-tested` refuses a report with a [FAIL], and a user who does not want notes must still be able to turn on
// automatic start. The same holds when a new meeting starts Local-Only (LOCAL_ONLY_DEFAULT=1 or the policy's default: no Claude call is
// made unless the user switches a meeting to non-local); then a missing API key item is a [WARN] too (SetupLanePlan.startsLocal).
// A company policy keeps the [FAIL]s: its lanes decide what is needed.
//
// SPEC 18 (organisation policy, Policy.swift): the checks are lane-aware. A lane the policy (or a locked local-only flag) denies is not
// a failure: its checks (claude CLI, login / API key, ARCHIVE_DIR and the Google Drive prompt) print `skipped: lane denied (...)` and
// LOCAL_ARCHIVE_DIR is checked instead. A locked policy is a FAIL (every external lane is closed), a valid one is reported, and the
// company runtime and the pipeline version are checked. Without a policy nothing new is printed.
//
// It only runs as the signed app started by launchd / LaunchServices (`LaunchGuard.isSignedAppLaunch`: bundle id AND
// parent). From a shell it refuses (exit 2) before it touches anything, because every prompt it raised would be
// attributed to the terminal / agent app. The `-n` matters: without it `open` only activates an already running
// instance, drops the arguments and `-W` waits forever.
//   open -n -W -a ~/Applications/<short name>.app --stdout "$(tty)" --stderr "$(tty)" --args setup
// (the report is also written to ~/Library/Logs/MeetingCapture/setup-report.txt).
// =====================================================================================

private final class SetupReport {
    private(set) var failures = 0
    private(set) var warnings = 0
    private var lines: [String] = []
    private let echo: Bool

    init(echo: Bool = true) { self.echo = echo }

    func emit(_ text: String) {
        if echo { print(text) }
        lines.append(text)
    }
    func ok(_ title: String, _ detail: String) { emit("[ OK ] \(title): \(detail)") }
    func fail(_ title: String, _ detail: String, next: String? = nil, then: String? = nil) {
        failures += 1
        emit("[FAIL] \(title): \(detail)")
        if let n = next { emit("       next: \(n)") }
        if let t = then { emit("       then: \(t)") }
    }
    func warn(_ title: String, _ detail: String, next: String? = nil) {
        warnings += 1
        emit("[WARN] \(title): \(detail)")
        if let n = next { emit("       next: \(n)") }
    }
    func note(_ title: String, _ detail: String) { emit("[ -- ] \(title): \(detail)") }
    func notifications(_ status: NotificationAuthorization) {
        let c = interpretNotificationAuthorization(status)
        if c.verdict == .ok { ok("notifications", c.detail) } else { warn("notifications", c.detail, next: c.next) }
    }
    func check(_ good: Bool, _ title: String, ok okText: String, fail failText: String) {
        if good { ok(title, okText) } else { fail(title, failText) }
    }
    func billing(_ c: PermissionCheck) {
        switch c.verdict {
        case .ok: ok("claude billing", c.detail)
        case .warn: warn("claude billing", c.detail, next: c.next)
        case .fail: fail("claude billing", c.detail, next: c.next, then: c.then)
        }
    }
    func permission(_ key: String, _ status: String) {
        let c = interpretPermission(key: key, status: status)
        switch c.verdict {
        case .ok: ok("permission \(key)", c.detail)
        case .warn: warn("permission \(key)", c.detail, next: c.next)
        case .fail: fail("permission \(key)", c.detail, next: c.next)
        }
    }
    func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Everything `runSetup` takes from the outside, so the self-test can run the whole checklist against fakes and a temp
/// config without a device, a prompt or the real log directory. Production uses the defaults.
struct SetupHooks {
    var signedAppLaunch: Bool = LaunchGuard.isSignedAppLaunch
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var capturePermissions: () -> [String: String] = { requestCapturePermissions() }
    var chromePermission: () -> String = { requestChromeAutomationPermission() }
    /// Asks macOS for notification permission (shows the prompt) and returns the answer. Never throws. The default only works in
    /// the signed app (Notifier checks LaunchGuard); anywhere else it answers .unavailable.
    var notificationAuthorization: () -> NotificationAuthorization = { Notifier().requestAuthorization() }
    var logDir: URL? = nil              // where setup-report.txt goes; default: the app's log directory
    var echo: Bool = true               // print the report to stdout
    /// SPEC 17 (CLAUDE_AUTH=api): the Keychain tool and the only way setup talks to it. The default is /usr/bin/security (or the shim named
    /// by MCAP_SECURITY_BIN, which the self-test sets so that no test can reach the real Keychain) run with the minimal environment.
    var securityBin: URL = ApiKeyItem.securityBinary()
    var runSecurity: ToolRunner = { exe, args in runCapturing(exe, args, env: minimalToolEnvironment(), timeout: 15) }
    /// SPEC 18: the organisation policy of this Mac (nil = read it). A test passes one.
    var policy: OrgPolicy? = nil
    /// The version of the pipeline (`python -m mcap --version`); only asked when a policy requires one.
    var pipelineVersion: (AppConfig) -> String? = { PipelineVersionProbe.shared.version(pythonBin: $0.pythonBin, projectDir: $0.projectDir) }
    /// lstat for the runtime-trust check and the device of a path for the LOCAL_ARCHIVE_DIR check (tests inject both).
    var fileInfo: (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile
    var deviceOf: (String) -> UInt64? = LocalArchiveCheck.deviceOf
}

/// Which checks a policy turns into `skipped: lane denied`. A reason is the code a lane is denied for: policy-locked,
/// local_only (the policy locks the flag on), policy-lane, policy-unapproved, policy-claude-unpinned, archive-not-configured,
/// policy-archive-root. nil = the lane is open, its checks run as before.
struct SetupLanePlan: Equatable {
    var llmDenied: String?
    var calendarDenied: String?
    var driveDenied: String?
    /// LOCAL_ARCHIVE_DIR is checked when meetings can go there: the Drive lane is denied or a new meeting starts local-only.
    var checkLocalArchive: Bool
    /// `claude` is not needed to record and transcribe: a missing or logged-out `claude` is a [WARN], not a [FAIL] that keeps the login
    /// agent from being written. True for a personal install (no policy, or a personal-profile policy) and whenever a new meeting starts
    /// Local-Only; false under a company policy that does not start Local-Only.
    var claudeOptional = false
    /// A new meeting starts Local-Only (LOCAL_ONLY_DEFAULT=1 or the policy's default): no Claude call is made unless the user switches a
    /// meeting to non-local, so a missing API key item is a [WARN] as well.
    var startsLocal = false

    static func make(policy: OrgPolicy, settings: PrivacySettings, archiveDir: URL, home: String = NSHomeDirectory()) -> SetupLanePlan {
        func denial(_ lane: String) -> String? {
            if policy.isValid && policy.localOnlyLocked { return "local_only" }
            return policy.laneDenialReason(lane)
        }
        var drive = denial("drive")
        if drive == nil && policy.isCompany && !settings.archiveDirExplicit { drive = "archive-not-configured" }
        if drive == nil && !ArchiveRootMatcher.allows(path: archiveDir.path, roots: policy.archiveAllowedRoots, home: home) { drive = "policy-archive-root" }
        let startsLocal = LocalOnlyResolver.initial(policy: policy, settings: settings).value
        return SetupLanePlan(llmDenied: denial("llm"), calendarDenied: denial("calendar"), driveDenied: drive, checkLocalArchive: drive != nil || startsLocal,
                             claudeOptional: startsLocal || !policy.isCompany, startsLocal: startsLocal)
    }
}

/// nil = setup may run. Otherwise the text to print (stderr) before exiting with 2: a start from a shell would make every
/// prompt, including the Google Drive one, belong to the parent app.
func setupRefusal(signedAppLaunch: Bool, env: [String: String], launch: String = CapturePermissionGuard.launchDescription()) -> String? {
    guard CapturePermissionGuard.promptRefusal(signedAppLaunch: signedAppLaunch, env: env, launch: launch) != nil else { return nil }
    return "setup: refusing to run. This process was not started by launchd / LaunchServices as the signed \(AppInfo.shortName).app (\(launch)), "
         + "so macOS would show the permission prompts (Microphone, System Audio Recording, Automation, Google Drive) for your terminal "
         + "instead of for \(AppInfo.displayName). Run it as the app:\n  \(CapturePermissionGuard.openAppCommand("setup"))\n"
}

func runSetup(config: AppConfig, hooks: SetupHooks = SetupHooks()) -> Int32 {
    if let refusal = setupRefusal(signedAppLaunch: hooks.signedAppLaunch, env: hooks.environment) {
        FileHandle.standardError.write(Data(refusal.utf8))
        Log.warn("setup refused: not started by launchd / LaunchServices as the signed app")
        return 2
    }
    let report = SetupReport(echo: hooks.echo)
    let fm = FileManager.default
    let policy = hooks.policy ?? OrgPolicy.load()
    let settings = PrivacySettings.load(config: config, policy: policy)
    let plan = SetupLanePlan.make(policy: policy, settings: settings, archiveDir: config.archiveDir)

    report.emit("\(AppInfo.displayName) \(AppInfo.version) setup")
    report.emit("config: \(AppConfig.configFilePath.path)")
    report.emit("")

    // ---- 1. files that need no permission ---------------------------------------------------------
    let configFile = AppConfig.configFilePath
    report.check(fm.fileExists(atPath: configFile.path), "config.env", ok: configFile.path,
                 fail: "missing \(configFile.path) (run scripts/install.sh or copy config/config.env.example)")
    let vocabularyFile = config.supportDir.appendingPathComponent("vocabulary.txt")
    report.check(fm.fileExists(atPath: vocabularyFile.path), "vocabulary.txt", ok: vocabularyFile.path,
                 fail: "missing \(vocabularyFile.path) (run scripts/install.sh or copy PROJECT_DIR/config/vocabulary.txt)")
    // SPEC 14.4: the pipeline reads PROJECT_DIR/config/note_prompt.md unless the user created SUPPORT_DIR/note_prompt.md to
    // override it, so the installed copy is optional (install.sh does not create it).
    let notePromptOverride = config.supportDir.appendingPathComponent("note_prompt.md")
    let notePromptRepo = config.projectDir.appendingPathComponent("config/note_prompt.md")
    if fm.fileExists(atPath: notePromptOverride.path) {
        report.ok("note_prompt.md", "user override: \(notePromptOverride.path)")
    } else {
        report.check(fm.fileExists(atPath: notePromptRepo.path), "note_prompt.md", ok: "repo copy: \(notePromptRepo.path)",
                     fail: "neither \(notePromptOverride.path) nor \(notePromptRepo.path) exists (check PROJECT_DIR in config.env)")
    }
    report.check(fm.isExecutableFile(atPath: config.pythonBin.path), "PYTHON_BIN", ok: config.pythonBin.path,
                 fail: "not found or not executable: \(config.pythonBin.path) (run scripts/setup_python.sh)")
    let pipelinePkg = config.projectDir.appendingPathComponent("pipeline/mcap")
    report.check(fm.fileExists(atPath: pipelinePkg.path), "pipeline package", ok: pipelinePkg.path,
                 fail: "missing \(pipelinePkg.path) (check PROJECT_DIR)")
    checkPolicy(policy: policy, config: config, report: report, hooks: hooks)

    // ---- 2. Claude billing: the claude.ai subscription (CLAUDE_AUTH=subscription) or an API key in the Keychain (api, SPEC 17) -----
    checkClaude(config: config, report: report, hooks: hooks, plan: plan)

    // ---- 3. permission prompts ---------------------------------------------------------------------
    report.emit("")
    report.emit("Permission prompts may appear now. Please click Allow.")

    // Google Drive / ARCHIVE_DIR (the first write triggers the File Provider access prompt). A denied Drive lane never writes there, so
    // the prompt is not raised either; LOCAL_ARCHIVE_DIR is what matters then.
    if let reason = plan.driveDenied {
        report.note("ARCHIVE_DIR writable", "skipped: lane denied (drive: \(reason)); meetings stay in LOCAL_ARCHIVE_DIR")
    } else {
        switch checkArchiveDir(config.archiveDir) {
        case .success(let detail): report.ok("ARCHIVE_DIR writable", detail)
        case .failure(let err): report.fail("ARCHIVE_DIR writable", err.message)
        }
    }
    if plan.checkLocalArchive { checkLocalArchive(settings: settings, config: config, policy: policy, report: report, hooks: hooks) }

    // Microphone + system audio tap (capture owner)
    let capture = hooks.capturePermissions()
    if capture.isEmpty {
        report.fail("capture permissions", "requestCapturePermissions() returned nothing",
                    next: "this is a bug in the app build; rebuild with scripts/build_app.sh and run setup again")
    }
    for expected in ["microphone", "system_audio"] where capture[expected] == nil && !capture.isEmpty {
        report.warn("permission \(expected)", "no status was reported for it",
                    next: "check it by hand in System Settings > Privacy & Security, then run setup again")
    }
    for key in capture.keys.sorted() {
        report.permission(key, capture[key] ?? "")
    }

    // Chrome automation (needed for Meet tab URLs): only when Meet is enabled, or when CALL_BROWSER_URLS asks for the meeting pages of other sites
    // (Whereby, Jitsi, ...: docs/DETECTION.md section 3b). Both are off by default (SPEC 15), so the Automation prompt never appears for someone who
    // does not use them.
    if config.enabledPlatforms.contains(.meet) || CallDetectSettings.current.needsBrowserAutomation(for: config) {
        report.permission("chrome-automation", hooks.chromePermission())
    } else {
        report.note("permission chrome-automation", "skipped: meet not enabled (add 'meet' to ENABLED_PLATFORMS in config.env to use Google Meet)")
    }

    // Notifications (remote audio silent, recording failed, pipeline failed, note ready): OK or WARN, never FAIL. Without them
    // the same messages still reach the menu and app.log.
    // An accessory (menu-bar) app is never frontmost by itself and macOS only shows the notification prompt for an active app,
    // so in the real signed app bring this process forward first; otherwise the dialog can stay behind other windows and the
    // request times out unanswered. Tests (no real app) skip this.
    if LaunchGuard.isSignedAppLaunch {
        DispatchQueue.main.async { NSApplication.shared.activate() }
        report.emit("A macOS dialog '\(AppInfo.displayName) would like to send you notifications' should appear now (top right). Please click Allow.")
    }
    report.notifications(hooks.notificationAuthorization())

    report.emit("")
    if report.failures == 0 && report.warnings == 0 {
        report.emit("Setup complete: all checks passed.")
        report.emit("next: check the recording path end to end (plays a short phrase through the speakers, records 12 s):")
        report.emit("      \(CapturePermissionGuard.openAppCommand("selftest-capture --live --seconds 12 --out ~/mcap-selftest"))")
    } else {
        if report.failures == 0 {
            report.emit("Setup finished with \(report.warnings) warning(s): the items marked [WARN] could not be verified. Follow the 'next:' lines and run setup again.")
        } else {
            report.emit("Setup incomplete: \(report.failures) check(s) failed, \(report.warnings) warning(s). Follow the 'next:' lines and run setup again.")
        }
        report.emit("To run setup again: \(CapturePermissionGuard.openAppCommand("setup"))")
    }
    report.save(to: (hooks.logDir ?? ShellUtil.logDir(for: config)).appendingPathComponent("setup-report.txt"))
    return report.failures == 0 && report.warnings == 0 ? 0 : 1
}

// MARK: - ARCHIVE_DIR

private struct SetupError: Error { let message: String }

private func checkArchiveDir(_ dir: URL) -> Result<String, SetupError> {
    let fm = FileManager.default
    // Safety: never fabricate a Google Drive mount point. If Drive for desktop is not running, creating
    // ~/Library/CloudStorage/GoogleDrive-.../My Drive/Meetings would make a bogus local folder in its place.
    let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage").path
    if dir.path.hasPrefix(cloud + "/") {
        let parts = dir.path.dropFirst(cloud.count + 1).split(separator: "/").map(String.init)
        var probe = URL(fileURLWithPath: cloud)
        for part in parts.prefix(2) {
            probe.appendPathComponent(part)
            if !fm.fileExists(atPath: probe.path) {
                return .failure(SetupError(message: "\(probe.path) does not exist. Is Google Drive for desktop running and signed in?"))
            }
        }
    }
    do {
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let probe = dir.appendingPathComponent(".mcap-write-probe-\(getpid())")
        try Data("probe".utf8).write(to: probe)
        try fm.removeItem(at: probe)
    } catch {
        return .failure(SetupError(message: "cannot write to \(dir.path): \(error.localizedDescription)"))
    }
    return .success(dir.path)
}

// MARK: - Organisation policy (SPEC 18)

/// Nothing is printed without a policy. A locked policy is a FAIL (every external lane is closed until IT redeploys a valid one), a valid
/// one is reported with its lanes, the company runtime must be root-owned, and a pipeline older than the contract is a FAIL.
private func checkPolicy(policy: OrgPolicy, config: AppConfig, report: SetupReport, hooks: SetupHooks) {
    // The company runtime (a valid company policy with runtime.root, and a locked one that does not say personal: the lock keeps it).
    func checkRuntime() {
        guard policy.pinnedRuntimeRoot != nil else { return }
        switch RuntimeTrust.verify(pythonBin: config.pythonBin, projectDir: config.projectDir, policy: policy, fileInfo: hooks.fileInfo) {
        case .ok: report.ok("runtime", "python and the pipeline are in the root-owned release folder")
        case .untrusted(let why):
            report.fail("runtime", "\(why): the app refuses to start the pipeline from here",
                        next: "install the company package; python and the pipeline must live under the policy's runtime.root, owned by root")
        }
    }
    switch policy.state {
    case .absent:
        return
    case .invalid(let reason):
        report.fail("organisation policy", "LOCKED (\(reason)): every external lane is closed; meetings are recorded and transcribed on this Mac only"
                    + (policy.supportContact.map { " (contact: \($0))" } ?? ""),
                    next: "ask IT to deploy a valid policy.json (docs/POLICY.md), then run setup again")
        checkRuntime()
    case .valid:
        let lanes = OrgPolicy.lanesInOrder.map { "\($0)=\(policy.lanes[$0] ?? "deny")" }.joined(separator: " ")
        report.note("organisation policy", "\(policy.profile) revision \(policy.revision ?? 0) (sha256 \(policy.sha256Prefix ?? "-")); lanes: \(lanes)")
        checkRuntime()
    }
    if let need = PipelineContract.required(policy: policy, sessionLocalOnly: nil) {
        switch hooks.pipelineVersion(config) {
        case nil:
            report.warn("pipeline version", "could not read the version (python -m mcap --version); this Mac needs \(need) or newer",
                        next: "check PYTHON_BIN and PROJECT_DIR, then run setup again")
        case let have? where PipelineContract.satisfied(version: have, required: need):
            report.ok("pipeline version", "\(have) (needs \(need) or newer)")
        case let have?:
            report.fail("pipeline version", "\(have) is older than \(need): the app would not start it",
                        next: "update the pipeline (git pull in PROJECT_DIR / the company package), then run setup again")
        }
    }
}

/// LOCAL_ARCHIVE_DIR: the allow-list of SPEC 18 (the same verdicts as the pipeline), then the same writable probe as ARCHIVE_DIR.
private func checkLocalArchive(settings: PrivacySettings, config: AppConfig, policy: OrgPolicy, report: SetupReport, hooks: SetupHooks) {
    let verdict = LocalArchiveCheck.verdict(path: settings.localArchiveDir.path, supportDir: config.supportDir.path, extraRoots: policy.localRoots,
                                            device: hooks.deviceOf)
    guard verdict.ok else {
        report.fail("LOCAL_ARCHIVE_DIR", "\(settings.localArchiveDir.path) is not allowed (\(verdict.reason)): local-only meetings would stop with local_archive_unsafe",
                    next: "use a folder under \(config.supportDir.path) (no symlink in the path, same disk as your home folder) or one the policy lists in archive.local_roots")
        return
    }
    switch checkArchiveDir(settings.localArchiveDir) {
    case .success(let detail): report.ok("LOCAL_ARCHIVE_DIR writable", detail)
    case .failure(let err): report.fail("LOCAL_ARCHIVE_DIR writable", err.message)
    }
}

// MARK: - Claude billing (SPEC 17)

/// The CLAUDE_AUTH text of config.env when it is neither `subscription` nor `api` (any case); nil when the key is absent, empty or valid.
/// AppConfig.load maps such a value to subscription (it can never switch the app to api) and only writes a line to app.log, while the
/// Python pipeline refuses every Claude call until it is fixed. Setup must say so out loud, otherwise a typo (`apikey`) reads as a
/// healthy subscription setup here and as a failing pipeline later.
func invalidClaudeAuthSetting(configFile: URL = AppConfig.configFilePath) -> String? {
    guard let data = FileManager.default.contents(atPath: configFile.path), let text = String(data: data, encoding: .utf8) else { return nil }
    guard let raw = AppConfig.parseEnvText(text)["CLAUDE_AUTH"] else { return nil }
    let value = raw.trimmingCharacters(in: .whitespaces)
    if value.isEmpty || ClaudeAuthMode(rawValue: value.lowercased()) != nil { return nil }
    return value
}

private func checkClaude(config: AppConfig, report: SetupReport, hooks: SetupHooks, plan: SetupLanePlan = SetupLanePlan(llmDenied: nil, calendarDenied: nil, driveDenied: nil, checkLocalArchive: false)) {
    // SPEC 18: no LLM and no calendar lane = nothing runs `claude` on this Mac: the CLI, the login and the key are not needed.
    if let llm = plan.llmDenied, let calendar = plan.calendarDenied {
        report.note("claude CLI", "skipped: lane denied (llm: \(llm), calendar: \(calendar)); no cleanup, note, verification or calendar lookup runs on this Mac")
        report.note("claude billing", "skipped: lane denied (llm: \(llm))")
        return
    }
    // Only the calendar lane is open: `claude` is started for the calendar lookup alone (the claude.ai login, never an API key).
    if let llm = plan.llmDenied {
        report.note("claude billing", "skipped: lane denied (llm: \(llm))")
        guard claudeBinaryIsExecutable(config, report) else { return }
        switch readClaudeLogin(config.claudeBin) {
        case .read(let method, let subscription) where method == "claude.ai":
            report.note("claude.ai login", "logged in" + (subscription.map { " (\($0))" } ?? "") + ", used for the Calendar title lookup only")
        default:
            report.note("claude.ai login", "not logged in or not readable from `claude auth status`: the Calendar title lookup is skipped; `claude auth login` with the claude.ai account enables it")
        }
        return
    }
    if let bad = invalidClaudeAuthSetting() {
        report.fail("claude billing", "CLAUDE_AUTH=\(bad.prefix(40)) in config.env is neither 'subscription' nor 'api': the pipeline makes no Claude call until it is fixed (this app reads it as subscription, never as api)",
                    next: "fix CLAUDE_AUTH in \(AppConfig.configFilePath.path), then run setup again")
        return
    }
    switch config.claudeAuth {
    case .subscription: checkClaudeSubscription(config: config, report: report, optional: plan.claudeOptional)
    case .api: checkClaudeAPI(config: config, report: report, hooks: hooks, calendarDenied: plan.calendarDenied, optional: plan.claudeOptional, keyOptional: plan.startsLocal)
    }
}

/// CLAUDE_AUTH=subscription: the claude.ai login must be the one `claude -p` uses; any other auth method would bill API credits.
private func checkClaudeSubscription(config: AppConfig, report: SetupReport, optional: Bool = false) {
    guard claudeBinaryIsExecutable(config, report, optional: optional) else { return }
    let problem: (String, String) -> Void = { optional ? report.warn($0, $1 + claudeOptionalSuffix) : report.fail($0, $1) }
    switch readClaudeLogin(config.claudeBin) {
    case .notRun:
        problem("claude auth", "could not run \(config.claudeBin.path) auth status")
    case .unreadable(let status):
        problem("claude auth", "could not read authMethod from `claude auth status` (exit \(status)). Run `claude auth login`.")
    case .read(let method, let subscription):
        if method == "claude.ai" {
            report.ok("claude billing", "subscription via claude.ai login" + (subscription.map { " (\($0))" } ?? ""))
        } else {
            report.fail("claude billing",
                        "WARNING: authMethod is '\(method)', which bills API credits, not your subscription. Meeting notes would be skipped. Run `claude auth login` and choose the claude.ai account.")
        }
    }
}

/// CLAUDE_AUTH=api: the pipeline bills an API key kept in the Keychain. The app does not read the key (the Python side does, right
/// before each call); it only asks whether the item exists. The claude.ai login still matters for one thing, the Google Calendar title
/// lookup, so its state is reported as information ([ -- ]), never as a failure.
private func checkClaudeAPI(config: AppConfig, report: SetupReport, hooks: SetupHooks, calendarDenied: String? = nil, optional: Bool = false, keyOptional: Bool = false) {
    let cliPresent = claudeBinaryIsExecutable(config, report, optional: optional)

    let service = config.claudeKeychainService
    let outcome = ApiKeyItem.lookup(service: service, account: NSUserName(), securityBin: hooks.securityBin, run: hooks.runSecurity)
    var billing = interpretApiKeyItem(outcome, service: service)
    if keyOptional && billing.verdict == .fail {        // Local-Only start: no Claude call is made unless the user switches a meeting to non-local
        billing.verdict = .warn
        billing.detail += "." + claudeOptionalSuffix
    }
    report.billing(billing)

    if let reason = calendarDenied {
        report.note("calendar lookup", "skipped: lane denied (calendar: \(reason)); meeting titles come from the window title or the platform name")
        return
    }
    report.note("calendar lookup", "the Google Calendar title lookup keeps using the claude.ai login, not the API key (everything else is billed to the API key)")
    guard cliPresent else {
        report.note("claude.ai login", "not checked: the claude CLI is missing (see above)")
        return
    }
    let skipped = "the Calendar title lookup is skipped and meeting titles come from the window title or the platform name; `claude auth login` with the claude.ai account enables it"
    switch readClaudeLogin(config.claudeBin) {
    case .read(let method, let subscription) where method == "claude.ai":
        report.note("claude.ai login", "logged in" + (subscription.map { " (\($0))" } ?? "") + ", used for the Calendar title lookup only")
    case .read(let method, _):
        report.note("claude.ai login", "authMethod is '\(method)', not claude.ai: \(skipped)")
    case .unreadable, .notRun:
        report.note("claude.ai login", "not logged in or not readable from `claude auth status`: \(skipped)")
    }
}

private let claudeOptionalSuffix = " Meeting notes need it; audio and transcripts do not, so this does not block automatic start. Set LOCAL_ONLY_DEFAULT=1 if you want transcripts only."

private func claudeBinaryIsExecutable(_ config: AppConfig, _ report: SetupReport, optional: Bool = false) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: config.claudeBin.path) else {
        let detail = "not found or not executable: \(config.claudeBin.path) (CLAUDE_BIN)"
        if optional { report.warn("claude CLI", detail + "." + claudeOptionalSuffix) } else { report.fail("claude CLI", detail) }
        return false
    }
    return true
}

private enum ClaudeLogin {
    case notRun                                         // the claude binary could not be started
    case unreadable(status: Int32)                      // it ran, but its answer has no authMethod
    case read(method: String, subscription: String?)
}

/// Runs `claude auth status` with the minimal environment and reads authMethod / subscriptionType from it.
private func readClaudeLogin(_ claudeBin: URL) -> ClaudeLogin {
    guard let result = runCapturing(claudeBin, ["auth", "status"], env: minimalToolEnvironment(), timeout: 30) else { return .notRun }
    let parsed = parseClaudeAuthStatus(result.stdout.isEmpty ? result.stderr : result.stdout)
    guard let method = parsed.method else { return .unreadable(status: result.status) }
    return .read(method: method, subscription: parsed.subscription)
}

/// authMethod and subscriptionType from the output of `claude auth status` (JSON; a loose `authMethod: x` text is accepted too).
func parseClaudeAuthStatus(_ text: String) -> (method: String?, subscription: String?) {
    var method: String?
    var subscription: String?
    if let data = text.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        method = obj["authMethod"] as? String
        subscription = obj["subscriptionType"] as? String
    } else if let r = text.range(of: #"authMethod"?\s*[:=]\s*"?([A-Za-z0-9._-]+)"#, options: .regularExpression) {
        // Fallback for a non-JSON status format.
        let hit = String(text[r])
        method = hit.split(whereSeparator: { ":= \"".contains($0) }).last.map(String.init)
    }
    return (method, subscription)
}

/// The API key lives only in the macOS Keychain and is read by the Python pipeline. This app NEVER reads it: it asks the Keychain whether
/// the item EXISTS with `security find-generic-password -s <service> -a <user>`, and without `-w` / `-g` (the two options that print the
/// secret). The arguments come from `existenceArguments` only; a test records them and fails if either option ever shows up.
enum ApiKeyItem {
    static let defaultSecurityPath = "/usr/bin/security"
    /// Test hook, like MCAP_CONFIG: an absolute path to a shim script that stands in for /usr/bin/security.
    static let securityBinEnv = "MCAP_SECURITY_BIN"
    /// `security` exits with 44 (errSecItemNotFound) when no item matches.
    static let itemNotFoundStatus: Int32 = 44

    /// A policy-managed Mac ignores the test hook (SPEC 18: only /usr/bin/security). `policyPresent` nil = look at this Mac.
    static func securityBinary(env: [String: String] = ProcessInfo.processInfo.environment, policyPresent: Bool? = nil) -> URL {
        if let p = env[securityBinEnv], p.hasPrefix("/"), !(policyPresent ?? OrgPolicy.systemPolicyPresent()) { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: defaultSecurityPath)
    }

    /// nil when a value is empty or starts with "-": it could be read as an option, and nothing here may be able to ask for the secret.
    static func existenceArguments(service: String, account: String) -> [String]? {
        guard !service.isEmpty, !account.isEmpty, !service.hasPrefix("-"), !account.hasPrefix("-") else { return nil }
        return ["find-generic-password", "-s", service, "-a", account]
    }

    enum Outcome: Equatable {
        case exists
        case missing(status: Int32)     // security ran and did not confirm the item (44 = not found)
        case notRun(String)             // security could not be started, or the arguments were refused
    }

    static func lookup(service: String, account: String, securityBin: URL, run: ToolRunner) -> Outcome {
        guard let args = existenceArguments(service: service, account: account) else {
            return .notRun("the Keychain service name or the user name is empty or starts with '-'")
        }
        guard let result = run(securityBin, args) else { return .notRun("could not run \(securityBin.path)") }
        return result.status == 0 ? .exists : .missing(status: result.status)
    }
}

/// What the Keychain lookup means for setup. Never prints anything the tool wrote: only its exit status is used.
func interpretApiKeyItem(_ outcome: ApiKeyItem.Outcome, service: String) -> PermissionCheck {
    switch outcome {
    case .exists:
        return PermissionCheck(verdict: .ok, detail: "API key in the Keychain (Console credits): item \(service)", next: nil)
    case .missing(let status):
        let unconfirmed = status == ApiKeyItem.itemNotFoundStatus ? "" : " (security exited with status \(status), so the item could not be confirmed)"
        return PermissionCheck(verdict: .fail, detail: "no API key in the Keychain item \(service)\(unconfirmed)",
                               next: "make set-api-key", then: "python -m mcap api-key check")
    case .notRun(let why):
        return PermissionCheck(verdict: .fail, detail: "cannot check the Keychain item \(service): \(why)",
                               next: "make sure \(ApiKeyItem.defaultSecurityPath) exists and runs, then run setup again")
    }
}

// MARK: - Helpers

/// What one permission status string means, and what the user should do about it.
struct PermissionCheck: Equatable {
    enum Verdict: Equatable { case ok, warn, fail }
    var verdict: Verdict
    var detail: String        // printed after the title; for ok/warn/fail alike
    var next: String?         // the next step for warn / fail
    var then: String? = nil   // what to do after `next` (only some checks have a follow-up)
}

private let microphoneSettings = "System Settings > Privacy & Security > Microphone: switch \(AppInfo.displayName) on"
private let systemAudioSettings = "System Settings > Privacy & Security > Screen & System Audio Recording, section 'System Audio Recording Only' (add \(AppInfo.displayName) with + if it is missing): switch it on"
private let runAsAppHint = "run setup through LaunchServices so macOS attributes the prompts to \(AppInfo.displayName), not to your terminal: \(CapturePermissionGuard.openAppCommand("setup"))"
private let automationSettings = "System Settings > Privacy & Security > Automation > \(AppInfo.displayName): switch 'Google Chrome' on"

/// Interprets the status strings of the permission helpers. Known formats:
///   microphone          (capture owner)    authorized | denied | restricted | notDetermined
///   system_audio        (capture owner)    exactly "ok"; failures start with "error" or contain "denied" / "silence"
///   chrome-automation   (detection owner)  authorized | "denied: ..." | "not-running: ..." | "refused: ..."
/// Anything else is a WARN with the raw text, never a silent OK. Failure markers are checked before success words,
/// so "ok, but silence" cannot pass.
func interpretPermission(key: String, status: String) -> PermissionCheck {
    let text = status.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    let head = String(lower.prefix(while: { $0.isLetter || $0 == "-" || $0 == "_" }))     // "denied (-1743)" -> "denied"
    let shown = text.isEmpty ? "(empty status)" : text
    let unknown = PermissionCheck(verdict: .warn, detail: "unrecognized status '\(shown)'",
                                  next: "check this permission by hand in System Settings > Privacy & Security, then run setup again (and report the status text if it keeps appearing)")

    // The helpers refuse to show prompts unless this process is the signed app ("error: refused ..." from the capture
    // helper, "refused: not running as <short name>.app ..." from the Chrome helper): for every key.
    if lower.hasPrefix("refused") || (lower.hasPrefix("error") && lower.contains("refused")) {
        return PermissionCheck(verdict: .fail, detail: shown, next: runAsAppHint)
    }

    switch key {
    case "microphone":
        if lower.hasPrefix("error") {
            return PermissionCheck(verdict: .fail, detail: shown, next: "\(microphoneSettings), then run setup again")
        }
        switch head {
        case "authorized": return PermissionCheck(verdict: .ok, detail: text, next: nil)
        case "denied": return PermissionCheck(verdict: .fail, detail: "microphone access is denied",
                                              next: "\(microphoneSettings), then run setup again")
        case "restricted": return PermissionCheck(verdict: .fail, detail: "microphone access is restricted by a system policy (Screen Time or a profile)",
                                                  next: "lift the restriction in System Settings, then run setup again; without a microphone your own voice is not recorded")
        case "notdetermined": return PermissionCheck(verdict: .fail, detail: "the microphone prompt was not answered",
                                                     next: "run setup again and click Allow when macOS asks (the dialog may be behind other windows)")
        default: return unknown
        }

    case "system_audio":
        if lower.hasPrefix("error") || lower.contains("denied") || lower.contains("silence") {
            return PermissionCheck(verdict: .fail, detail: shown,
                                   next: "\(systemAudioSettings), then run setup again. If a dialog is still on screen, answer it first")
        }
        if lower == "ok" { return PermissionCheck(verdict: .ok, detail: "system audio tap delivers audio", next: nil) }
        return unknown

    case "chrome-automation":
        if lower.contains("not answered") {
            return PermissionCheck(verdict: .fail, detail: shown, next: "run setup again and click OK when macOS asks to let \(AppInfo.displayName) control Google Chrome")
        }
        if lower.hasPrefix("error") || lower.contains("denied") {
            return PermissionCheck(verdict: .fail, detail: shown,
                                   next: "\(automationSettings), then run setup again. Without it Meet is detected with low confidence only")
        }
        if head == "authorized" { return PermissionCheck(verdict: .ok, detail: text, next: nil) }
        if head == "not-running" {
            return PermissionCheck(verdict: .warn, detail: shown,
                                   next: "start Google Chrome (setup never launches it), then run setup again: the Automation prompt can only be shown while Chrome is running")
        }
        return unknown

    default:
        // A status from a helper this build does not know yet: only unmistakable words count.
        if lower.hasPrefix("error") || lower.contains("denied") || lower.contains("restricted") || lower.contains("fail") {
            return PermissionCheck(verdict: .fail, detail: shown, next: "check '\(key)' in System Settings > Privacy & Security, then run setup again")
        }
        if lower == "ok" || lower == "authorized" || lower == "granted" { return PermissionCheck(verdict: .ok, detail: text, next: nil) }
        return unknown
    }
}

/// Notification permission: OK when allowed, otherwise a WARN that says what is lost (never a FAIL: the app records and
/// processes meetings without notifications, the messages then appear in the menu and in app.log only).
func interpretNotificationAuthorization(_ status: NotificationAuthorization) -> PermissionCheck {
    let consequence = "without notifications, warnings (remote audio silent, recording could not start, processing failed) only show in the menu bar and in app.log"
    switch status {
    case .authorized:
        return PermissionCheck(verdict: .ok, detail: "macOS notifications are allowed", next: nil)
    case .denied:
        return PermissionCheck(verdict: .warn, detail: "notifications are denied: \(consequence)",
                               next: "System Settings > Notifications > \(AppInfo.displayName): allow notifications, then run setup again (or ignore this if you do not want them)")
    case .notDetermined:
        return PermissionCheck(verdict: .warn, detail: "the notification prompt was not answered: \(consequence)",
                               next: "run setup again and click Allow when macOS asks (the dialog may be behind other windows)")
    case .unavailable(let why):
        return PermissionCheck(verdict: .warn, detail: "notifications are unavailable (\(why)): \(consequence)",
                               next: "run setup through LaunchServices as the signed app: \(CapturePermissionGuard.openAppCommand("setup"))")
    }
}

/// Exit status and output of an external tool.
typealias ToolResult = (status: Int32, stdout: String, stderr: String)
/// Runs `exe args` and reports what happened; nil = the tool could not be started. SetupHooks takes one so tests never run a real tool.
typealias ToolRunner = (_ exe: URL, _ args: [String]) -> ToolResult?

/// Same minimal environment the pipeline gives `claude -p`: no ANTHROPIC_* / CLAUDE_* variable can switch billing, and none carries a key.
func minimalToolEnvironment() -> [String: String] {
    let home = NSHomeDirectory()
    return ["HOME": home,
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8"]
}

func runCapturing(_ exe: URL, _ args: [String], env: [String: String], timeout: TimeInterval, cwd: URL? = nil) -> ToolResult? {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.environment = env
    p.currentDirectoryURL = cwd ?? FileManager.default.temporaryDirectory
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }

    final class Box { var data = Data() }
    let outBox = Box(), errBox = Box()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outBox.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    p.waitUntilExit()
    group.wait()
    return (p.terminationStatus,
            String(data: outBox.data, encoding: .utf8) ?? "",
            String(data: errBox.data, encoding: .utf8) ?? "")
}
