import AppKit
import Darwin

// =====================================================================================
// The menu-bar application: lifecycle, single-instance guard, signals, sleep notifications.
//
// Exit codes (launchd KeepAlive SuccessfulExit=false):
//   0        Quit from the menu, SIGTERM/SIGINT, or "another instance is already running"
//   non-zero a real failure (a crash exits by signal, which launchd also treats as unsuccessful)
// =====================================================================================

enum AppInfo {
    /// The identifier a bare binary (no Info.plist: the self tests of a swiftc test binary) falls back to. It is the default of scripts/build_app.sh.
    static let defaultBundleID = "org.meetingcapture.app"
    /// The bundle identifier of the running app. It is a build input (MCAP_BUNDLE_ID, written into Info.plist by scripts/build_app.sh) and is read
    /// from there at run time; everything that is named after the app (queues, the aggregate-device prefix, our own audio processes) derives from it.
    static let bundleID = resolveBundleID(Bundle.main.bundleIdentifier)
    static func resolveBundleID(_ declared: String?) -> String {
        guard let id = declared, !id.isEmpty else { return defaultBundleID }
        return id
    }
    /// The names a bare binary (no Info.plist) falls back to. They are the defaults of scripts/bundle_id.sh (MCAP_DEFAULT_APP_NAME / MCAP_DEFAULT_APP_SHORT_NAME) and of
    /// pipeline/mcap/appinfo.py; scripts/test_scripts.sh checks that the three agree.
    static let defaultDisplayName = "Catch Everything"
    static let defaultShortName = "CATE"
    /// The human name of the app: build input MCAP_APP_NAME, written into Info.plist as CFBundleDisplayName by scripts/build_app.sh and read from there at run
    /// time, like the bundle id. Every message that names the app is built from it (alerts, menu items, notification titles, permission hints), never retyped.
    static let displayName = resolveDisplayName(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    /// The file-safe short name: build input MCAP_APP_SHORT_NAME, CFBundleName. The app folder is `shortName.app` and the program is `shortName`; the command hints
    /// (`CapturePermissionGuard.openAppPrefix`) use it.
    static let shortName = resolveShortName(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    /// A declared value is used only when it follows the rules scripts/build_app.sh enforces at build time (so a damaged or foreign Info.plist cannot put a newline, a
    /// `%` or a slash into a message or a file name); anything else is the default.
    static func resolveDisplayName(_ declared: String?) -> String {
        guard let name = declared, isValidDisplayName(name) else { return defaultDisplayName }
        return name
    }
    static func resolveShortName(_ declared: String?) -> String {
        guard let name = declared, isValidShortName(name) else { return defaultShortName }
        return name
    }
    private static func isASCIIAlnum(_ c: Unicode.Scalar) -> Bool { (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") }
    /// ASCII letters, digits, spaces, hyphens and periods; starts with a letter or digit; no trailing space; 1 to 40 characters (MCAP_APP_NAME).
    static func isValidDisplayName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...40).contains(scalars.count), let first = scalars.first, let last = scalars.last, last != " ", isASCIIAlnum(first) else { return false }
        return scalars.allSatisfy { isASCIIAlnum($0) || $0 == " " || $0 == "." || $0 == "-" }
    }
    /// ASCII letters and digits, starts with a letter, 1 to 32 characters (MCAP_APP_SHORT_NAME).
    static func isValidShortName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first, (first >= "A" && first <= "Z") || (first >= "a" && first <= "z") else { return false }
        return scalars.allSatisfy { isASCIIAlnum($0) }
    }
    static let fallbackVersion = "0.2.0"
    /// CFBundleShortVersionString when running from the .app bundle, a constant for a bare binary.
    static var version: String {
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackVersion
    }
}

// MARK: - Notifications at startup

enum NotificationStartup {
    /// The app's notifier with its click router, click handler already installed (exactly once; `Notifier.start()` is idempotent).
    /// applicationDidFinishLaunching calls this first, before anything can post a notification. The self-test calls it with a fake
    /// backend and checks the handler was installed once (and never in an inactive, i.e. non-signed, process).
    /// `extraFolderRoots` (LOCAL_ARCHIVE_DIR: a click on a local-only meeting opens its folder) and `hideArchivePaths` (LOG_CONTENT=0) are
    /// SPEC 18; the defaults are what this always was.
    static func make(config: AppConfig, logDir: URL, active: Bool = LaunchGuard.isSignedAppLaunch,
                     backend: NotificationCenterBackend? = nil, extraFolderRoots: [URL] = [], hideArchivePaths: Bool = false) -> Notifier {
        let router = NotificationClickRouter(policy: NotificationPathPolicy(config: config, logDir: logDir, extraFolderRoots: extraFolderRoots,
                                                                            hideArchivePaths: hideArchivePaths))
        let notifier = Notifier(active: active, backend: backend, router: router)
        notifier.start()
        return notifier
    }
}

// MARK: - Launch arguments

enum LaunchArguments {
    static let commands: Set<String> = ["probe", "selftest-detector", "selftest-capture", "selftest-session", "selftest-policy", "selftest-firstrun", "policy-status",
                                        "selftest-notify", "setup", "version", "help"]

    /// Removes the arguments the system adds on its own: "-psn_..." (legacy Finder launch) and leading "-NS*" /
    /// "-Apple*" name/value pairs, e.g. "-NSQuitAlwaysKeepsWindows NO" or "-ApplePersistenceIgnoreState YES", which
    /// AppKit passes when it relaunches an app after a crash. What is left is our own command line (empty = menu-bar app).
    static func strip(_ args: [String]) -> [String] {
        var rest = ArraySlice(args.filter { !$0.hasPrefix("-psn_") })
        while let first = rest.first, first.hasPrefix("-NS") || first.hasPrefix("-Apple") {
            rest = rest.dropFirst()
            // The value of the pair ("YES", "NO", "(en)"); never swallow another option or one of our commands.
            if let value = rest.first, !value.hasPrefix("-"), !commands.contains(value) { rest = rest.dropFirst() }
        }
        return Array(rest)
    }
}

// MARK: - Single instance

/// flock() on SUPPORT_DIR/app.lock, held for the life of the process. The kernel drops it on exit or crash,
/// so a stale lock file can never block the next launch.
enum SingleInstanceLock {
    private static var fd: Int32 = -1

    static func acquire(in supportDir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let path = supportDir.appendingPathComponent("app.lock").path
        let handle = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)      // CLOEXEC: the pipeline child must not inherit the lock
        if handle < 0 {
            // Cannot create a lock file (read-only support dir?). Better to run than to refuse to start.
            Log.warn("single-instance lock: cannot open \(path) (errno \(errno)); continuing without it")
            return true
        }
        if flock(handle, LOCK_EX | LOCK_NB) != 0 {
            close(handle)
            return false
        }
        fd = handle
        let pid = "\(getpid())\n"
        _ = ftruncate(handle, 0)
        _ = pid.withCString { write(handle, $0, strlen($0)) }
        return true
    }
}

// MARK: - Policy watcher

/// What the controller's 60 s policy poll calls. `OrgPolicy.load` writes a log line for every read and, when the policy is locked, waits half
/// a second for its confirming second read: reading the file every minute would fill app.log with 1440 lines a day. So the file is only
/// parsed again when its fingerprint (inode, size, mtime, ctime, mode and owner of policy.json, of policy.required and of their folder)
/// changed, and while the policy is locked (a repair of a parent folder is not in the fingerprint; the locked state is an incident anyway).
/// The self test injects `load` and `fingerprint`.
final class PolicyWatcher {
    private let load: () -> OrgPolicy
    private let fingerprint: () -> String
    private let lock = NSLock()
    private var cached: OrgPolicy
    private var lastFingerprint: String

    /// `initialFingerprint` is the fingerprint taken BEFORE `initial` was read: a file that changes between the read and this init is then
    /// seen as changed at the first poll (taking it here would pair the old policy with the new fingerprint and never notice).
    init(initial: OrgPolicy, initialFingerprint: String? = nil, load: @escaping () -> OrgPolicy = { OrgPolicy.load() },
         fingerprint: @escaping () -> String = { PolicyWatcher.systemFingerprint() }) {
        self.cached = initial
        self.load = load
        self.fingerprint = fingerprint
        self.lastFingerprint = initialFingerprint ?? fingerprint()
    }

    /// The policy as of now: the cached one when nothing changed, else a fresh read.
    func current() -> OrgPolicy {
        let now = fingerprint()
        lock.lock()
        let unchanged = now == lastFingerprint && !cached.isLocked
        let held = cached
        lock.unlock()
        if unchanged { return held }
        let fresh = load()
        lock.lock(); cached = fresh; lastFingerprint = now; lock.unlock()
        return fresh
    }

    /// lstat facts of the two policy files and their folder ("absent" for a path that is not there).
    static func systemFingerprint(paths: [URL] = [OrgPolicy.systemPath, OrgPolicy.requiredMarker, OrgPolicy.systemPath.deletingLastPathComponent()]) -> String {
        return paths.map { url -> String in
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return "absent" }
            return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec):\(st.st_mode):\(st.st_uid)"
        }.joined(separator: "|")
    }
}

// MARK: - Sleep prevention

/// Two assertions:
///  - "monitoring": always held, keeps App Nap from throttling the 2 s detector timer of a windowless app,
///    but still allows the Mac to sleep when idle.
///  - "busy": held while a meeting is being detected/recorded/processed, blocks idle system sleep.
final class ActivityGuard {
    private var monitoring: NSObjectProtocol?
    private var busy: NSObjectProtocol?

    init() {
        monitoring = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "\(AppInfo.displayName) is watching for meetings")
    }

    func setBusy(_ isBusy: Bool) {
        if isBusy, busy == nil {
            busy = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "\(AppInfo.displayName) is recording or processing a meeting")
            Log.info("sleep prevention on")
        } else if !isBusy, let token = busy {
            ProcessInfo.processInfo.endActivity(token)
            busy = nil
            Log.info("sleep prevention off")
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private let logDir: URL
    private var controller: SessionController?
    private var calendar: CalendarWatcher?
    private var menu: StatusMenuController?
    private var firstRun: FirstRunController?
    private let activity = ActivityGuard()
    private var signalSources: [DispatchSourceSignal] = []
    private var terminating = false
    private var logRotationTimer: Timer?

    init(config: AppConfig, logDir: URL) {
        self.config = config
        self.logDir = logDir
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("\(AppInfo.displayName) \(AppInfo.version) starting (pid \(getpid()), support dir \(config.supportDir.path))")

        // SPEC 18: the organisation policy is read ONCE here (a locked policy is confirmed by a second read) and the
        // controller's watcher reads it again every 60 s; the launcher, the controller and the menu share one box. No policy file and no
        // policy.required (the personal install): absent, nothing below changes what the app does.
        let policyFingerprint = PolicyWatcher.systemFingerprint()
        let policy = OrgPolicy.load()
        let policyBox = PolicyBox(policy)
        let privacy = PrivacySettings.load(config: config, policy: policy)
        let policyWatcher = PolicyWatcher(initial: policy, initialFingerprint: policyFingerprint)
        Log.info("privacy: local-only default \(privacy.localOnlyDefault ? "on" : "off"), LOG_CONTENT \(privacy.logContent ? 1 : 0), local archive \(privacy.localArchiveDir.path)")
        rotateAppLog(privacy)
        let pipeline = PipelineLauncher(config: config, logDir: logDir, policy: policyBox, privacy: privacy)
        // Calls of other apps (CALL_DETECT, docs/DETECTION.md section 3b): the decisions per app live in SUPPORT_DIR/call-apps.json (0600); the detector,
        // the controller and the menu share one store.
        let callSettings = CallDetectSettings.current
        let callStore = CallAppStore(supportDir: config.supportDir)
        let detector = Detector(config: config, callStore: callStore)
        let cfg = config
        // macOS notifications (recording started / ended, remote audio silent, recording failed, pipeline failed, note ready): active only
        // in the signed app started by launchd / LaunchServices (LaunchGuard); anywhere else the notifier only logs. Permission is asked
        // by `setup`. The click handler (UNUserNotificationCenter delegate: clicks open the folder / log / settings pane) is installed
        // HERE, at startup, before the controller below can post anything (and before macOS can hand us the click that launched us).
        let notifier = NotificationStartup.make(config: config, logDir: logDir, extraFolderRoots: [privacy.localArchiveDir],
                                                hideArchivePaths: !privacy.logContent)
        Log.info("notifications: \(notifier.isActive ? "enabled (delivery needs macOS permission; `setup` asks for it), click handler installed" : "inactive (not started as the signed app by launchd / LaunchServices)"); recording start/stop notices \(config.notifyRecording ? "on" : "off (NOTIFY_RECORDING=0)")")
        let controller = SessionController(
            config: config,
            detector: detector,
            recorderFactory: { dir, signal in Recorder(sessionDir: dir, signal: signal, config: cfg) },
            pipeline: pipeline,
            clock: { Date() },
            notifier: notifier,
            policy: policyBox,
            privacy: privacy,
            policyReader: { policyWatcher.current() },
            callApps: callStore,
            callSettings: callSettings)
        self.controller = controller
        pipeline.recordingActive = { [weak controller] in controller?.isRecordingActive ?? false }
        pipeline.prepareContractCheck(localOnlyDefault: privacy.localOnlyDefault)

        // Calendar auto-start (CalendarWatcher.swift): OFF unless config.env says OFFLINE_AUTOSTART=auto. Off, nothing below exists: no watcher, no
        // timer, no menu item, no process, no log line. The watcher reads config.env with the policy already loaded above (no second policy read).
        let offline = OfflineAutostartSettings.load(from: AppConfig.configFilePath, policy: policy)
        var calendar: CalendarWatcher?
        if offline.isOn {
            calendar = CalendarWatcher(settings: offline, control: controller,
                                       runner: { from, to in PipelineLauncher.runCalendarCommand(config: cfg, policy: policyBox.policy, fromMinutes: from, toMinutes: to) },
                                       store: CalendarStartedStore(supportDir: config.supportDir), notifier: notifier, logFile: Log.fileURL)
        }
        self.calendar = calendar

        // The Settings window (SettingsWindow.swift, menu "Settings..."): a thin layer over SettingsCoordinator. It reads and writes config.env (through the
        // pure editor), stores API keys in the Keychain only, shows the consent / Google state read-only and opens Terminal for the two commands that only a
        // Terminal may run. The call-app choices go through the same controller call as the Call Apps submenu.
        let settingsEnv = SettingsEnvironment.live(config: config, policy: { policyWatcher.current() }, isRecording: { [weak controller] in controller?.isRecordingActive ?? false },
                                                   restartHold: { [weak controller] in controller?.restartHold },
                                                   terminate: { NSApp.terminate(nil) })
        let settingsApps = SettingsCallApps(entries: { callStore.entries() }, problem: { callStore.problem }, settings: { callSettings },
                                            set: { [weak controller] id, decision in controller?.setCallDecision(bundleID: id, decision: decision) }, reload: { callStore.reload() })
        let settings = SettingsWindowController(coordinator: SettingsCoordinator(env: settingsEnv), callApps: settingsApps)

        // First run of the app installer (FirstRun.swift): only an app that carries Contents/Resources/mcap/components.json (the dmg) ever checks or offers anything.
        // The verdict is read here, before the controller starts (a few file reads): without components-installed.json the helper has not shown the recording legal
        // notice yet, so recording is held (SessionController.setInstallHold) until the helper has finished. The later checks are background file reads; at most one
        // alert per launch; the menu item follows the result.
        let firstRun = FirstRunController(env: .live(config: config))
        self.firstRun = firstRun
        let launchStatus = firstRun.evaluateNow()

        let menu = StatusMenuController(controller: controller, config: config, logDir: logDir, calendar: calendar,
                                        callApps: callSettings.mode == .off ? nil : callStore, callSettings: callSettings, settings: settings, firstRun: firstRun)
        self.menu = menu
        controller.onState = { [weak self] state in
            self?.menu?.update(state)
            self?.updateBusy(state)
        }
        calendar?.onState = { [weak self] status in self?.menu?.updateCalendar(status) }

        installSignalHandlers()
        installWorkspaceObservers(controller, calendar: calendar)

        firstRun.onHoldChange = { [weak controller] hold in controller?.setInstallHold(hold) }
        controller.setInstallHold(FirstRun.holdsRecording(launchStatus))      // before the first poll: the queue of the controller keeps the order
        calendar?.start()
        controller.start()
        firstRun.checkAtLaunch()
    }

    /// app.log rotation (APP_LOG_MAX_MB): at start and every ten minutes. 0 = off, which is the personal default and what
    /// the app always did: nothing here touches the log then.
    private func rotateAppLog(_ privacy: PrivacySettings) {
        guard privacy.appLogMaxMB > 0 else { return }
        let rotate = { LogRotation.rotateIfNeeded(file: Log.fileURL, maxBytes: privacy.appLogMaxMB * 1_048_576, keep: 5, maxAgeDays: privacy.logRetentionDays) }
        if rotate() { Log.info("app.log rotated (APP_LOG_MAX_MB=\(privacy.appLogMaxMB))") }
        let timer = Timer(timeInterval: 600, repeats: true) { _ in _ = rotate() }
        RunLoop.main.add(timer, forMode: .common)
        logRotationTimer = timer
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        gracefulShutdown(reason: "quit")
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Shutdown

    /// Finalizes any active recording (WAV headers + session.json) and stops the pipeline child. Idempotent.
    private func gracefulShutdown(reason: String) {
        guard !terminating else { return }
        terminating = true
        Log.info("shutting down (\(reason))")
        calendar?.shutdown()                    // never waits; nothing is started from the calendar from here on
        controller?.shutdown(reason: .appQuit)
        Log.info("shutdown complete")
        Log.flush()
    }

    private func installSignalHandlers() {
        // SIGTERM (launchctl stop / logout) and SIGINT (Ctrl-C when run from a terminal) take the same path as
        // the menu's Quit: NSApp.terminate -> applicationShouldTerminate (finalizes the recording) -> exit code 0.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                Log.info("received signal \(sig)")
                self?.requestQuit()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Quit through AppKit; if AppKit does not get us out within 30 s, finalize and exit anyway.
    private func requestQuit() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            Log.error("quit did not complete in 30 s; forcing exit")
            Log.flush()
            exit(0)
        }
        NSApp.terminate(nil)
    }

    private func installWorkspaceObservers(_ controller: SessionController, calendar: CalendarWatcher?) {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Log.info("system will sleep")
            controller.systemWillSleep()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Log.info("system did wake")
            controller.systemDidWake()          // re-arms the pipeline stall watchdog, holds the retry sweep back for a moment
            calendar?.systemDidWake()           // the calendar poll is retried at once, whatever its backoff was
        }
        // "Will power off" only says that a logout / shutdown was REQUESTED; another app can still cancel it and the
        // notification is never retracted. So do NOT shut the controller down here (that would leave a dead app after a
        // cancelled logout, with nothing to restart it). Just close the active recording so no audio is at risk; the real
        // termination arrives as SIGTERM or applicationShouldTerminate, which run gracefulShutdown().
        nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            Log.info("system will power off")
            controller.systemWillPowerOff()
        }
    }

    private func updateBusy(_ state: ControllerState) {
        switch state.status {
        case .recording, .candidate, .processing: activity.setBusy(true)
        default: activity.setBusy(false)
        }
    }
}

// MARK: - Entry point for "no arguments"

/// Runs the menu-bar app. Never returns.
func runMenuBarApp(config: AppConfig, logDir: URL) -> Never {
    guard SingleInstanceLock.acquire(in: config.supportDir) else {
        Log.info("another \(AppInfo.displayName) instance is already running; exiting")
        Log.flush()
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)               // no Dock icon, no app menu (LSUIElement does the same in the bundle)
    let delegate = AppDelegate(config: config, logDir: logDir)
    app.delegate = delegate                           // NSApplication.delegate is weak: keep it alive explicitly
    withExtendedLifetime(delegate) { app.run() }
    Log.flush()
    exit(0)
}

/// For CLI commands that trigger permission prompts: the main thread runs an NSApplication loop (so callbacks on
/// the main queue still work and the process is a proper GUI-session client) while `work` runs on a background
/// thread. Exits the process with work's exit code. Never returns.
func runWithMainRunLoop(_ work: @escaping () -> Int32) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.global(qos: .userInitiated).async {
        let code = work()
        Log.flush()
        fflush(stdout)
        fflush(stderr)
        exit(code)
    }
    app.run()
    exit(0)
}
