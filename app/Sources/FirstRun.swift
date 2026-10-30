import AppKit
import Foundation
import Darwin

// =====================================================================================
// First run of the app installer (the dmg): is everything the app needs installed, and if not, offer the guided helper.
//
// The dmg ships the pipeline, the config examples, the scripts and a Python runtime INSIDE the app (<short name>.app: Contents/Resources/mcap and
// runtime, made by scripts/build_dmg.sh). What does not fit into an app is installed at the first launch by scripts/first_run_install.sh, in
// Terminal. This file decides WHEN to offer it and starts it. Everything that can be decided without a window is a pure function (`FirstRun`,
// tested by selftest-session); `FirstRunController` and the AppKit alert are a thin layer over it that nobody has seen in a real session.
//
// What is checked (cheap: a few small file reads and stat calls, no network, never on the main thread, never blocks the start):
//   - Contents/Resources/mcap/components.json exists. Without it (a build from source, the company package) the whole feature is off: nothing is
//     checked, nothing is offered, no menu item.
//   - SUPPORT_DIR/components-installed.json exists and carries the same hashes as components.json (the Python runtime archive, the requirements
//     lock): written by the helper at its last step; a new app with another runtime or lock makes it "outdated".
//   - the venv python (PYTHON_BIN) is executable, the pinned speech model file and the Silero model have their pinned sizes (the same numbers as
//     scripts/setup_python.sh; scripts/test_scripts.sh compares them). The speech model is only required when ASR_ENGINE is whisper or auto.
//
// What is offered: ONE alert per launch ("<name> needs to install its components ... Start now?" [Start] [Later]), never under self tests (no
// AppDelegate exists there), never when UI is not allowed (the app was not started by launchd / LaunchServices: a shell exec), never on a policy-managed
// Mac (the company package brings its own runtime). Start copies the bundled helper to SUPPORT_DIR/first-run-install.command (so a moved or
// deleted app does not matter), writes SUPPORT_DIR/first-run.env (one line, the app's mcap folder, which the helper reads and never executes) and opens the copy
// with `open -a Terminal`. The menu item "Components: not installed - run installer" does the same without asking. An app that runs from the disk image or
// from a translocated copy asks the person to drag it to Applications first: components installed for such a copy would point at a place macOS may remove.
//
// Recording is HELD until the helper has finished (`FirstRun.holdsRecording`): the recording legal notice exists only in step 1 of the helper, and macOS
// permissions and notifications are asked in its step 7, so an app that has no components-installed.json yet neither detects calls nor starts a recording
// (not automatic, not "Start Recording Now", not the calendar), and the menu says so. The verdict is read synchronously before the controller starts
// (`FirstRunController.evaluateNow`, a few file reads); while the hold lasts the check repeats every `holdRecheckSeconds` and the hold ends by itself when
// the helper has written its record. Only `.notInstalled` holds: an older record (`.outdated`, a missing model) means the notice was accepted before.
//
// Language: the app's UI language (`tr`); at the very first launch there is no config.env yet, so the alert and the menu item follow the macOS language
// (`FirstRun.systemLanguage`) until the helper has written UI_LANGUAGE.
//
// Main thread: the alert is NOT run inside a DispatchQueue.main.async block. libdispatch's main queue is serial and not re-entrant, so a modal run loop
// started from such a block would keep every other main-queue block (the menu icon, the busy guard, notification clicks) waiting until the person answers.
// The controller hands the prompt to `runOnRunLoop` (RunLoop.main.perform in the app), which runs after the dispatch block has returned.
// Cloud ASR consent stays a Terminal-only step of the pipeline: nothing in here writes the consent file or any config.env key.
// =====================================================================================

enum FirstRun {
    static let componentsFile = "components.json"
    static let installedFile = "components-installed.json"
    static let installerCopyName = "first-run-install.command"
    static let envFileName = "first-run.env"
    static let bundledScript = "scripts/first_run_install.sh"
    /// The helper's lock (scripts/first_run_install.sh): a symbolic link of this name in SUPPORT_DIR whose target is the pid of the running helper.
    static let lockName = ".first-run.lock"
    static let holdRecheckSeconds: TimeInterval = 10

    // MARK: - What the helper installs (the numbers of scripts/setup_python.sh)

    struct Pinned: Equatable {
        var modelRepoDir = "models--mlx-community--whisper-large-v3-mlx"
        var modelRevision = "49e6aa286ad60c14352c404340ded53710378a11"
        var modelFile = "weights.npz"
        var modelBytes: Int64 = 3_083_520_416
        var sileroFile = "silero_vad.onnx"
        var sileroBytes: Int64 = 2_327_524
        static let current = Pinned()

        /// The speech model file in the default Hugging Face cache of `home` (the pipeline child gets HOME only, so this is the cache it uses).
        func modelPath(home: URL) -> URL {
            return home.appendingPathComponent(".cache/huggingface/hub/\(modelRepoDir)/snapshots/\(modelRevision)/\(modelFile)")
        }
        func sileroPath(supportDir: URL) -> URL {
            return supportDir.appendingPathComponent("models/\(sileroFile)")
        }
    }

    // MARK: - The two records

    struct Components: Equatable {
        var runtimeSHA256: String
        var requirementsLockSHA256: String
    }

    private static func hex64(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 64, text.allSatisfy({ $0.isHexDigit }) else { return nil }
        return text
    }

    /// components.json of the app: {"python_runtime":{"file":...,"sha256":...},"requirements_lock_sha256":...}. nil when it is not that.
    static func parseBundleComponents(_ data: Data) -> Components? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let runtime = object["python_runtime"] as? [String: Any],
              let runtimeSHA = hex64(runtime["sha256"]), let lockSHA = hex64(object["requirements_lock_sha256"]) else { return nil }
        return Components(runtimeSHA256: runtimeSHA, requirementsLockSHA256: lockSHA)
    }

    /// components-installed.json (written by the helper): the same two hashes, plus fields the app does not need. nil when it is not that.
    static func parseInstalled(_ data: Data) -> Components? {
        return parseBundleComponents(data)
    }

    // MARK: - The verdict

    enum Reason: Equatable {
        case notInstalled           // no components-installed.json (or one that cannot be read)
        case outdated               // its hashes differ from the app's components.json
        case venvMissing            // PYTHON_BIN is not an executable file
        case modelMissing           // the speech model file is missing or has another size than the pinned one
        case vadModelMissing        // the Silero model file is missing or has another size
    }

    enum Status: Equatable {
        case notApplicable          // this app has no components.json: not a dmg build
        case ready
        case needsInstall(Reason)

        var needsInstall: Bool {
            if case .needsInstall = self { return true }
            return false
        }
    }

    /// What the disk says, gathered without a network and without a window.
    struct Facts: Equatable {
        var bundle: Components?              // nil: the app has no (valid) components.json
        var installed: Components?           // nil: no (valid) components-installed.json
        var venvPythonExecutable = false
        var modelBytes: Int64? = nil         // nil: the file is missing
        var sileroBytes: Int64? = nil
        var needsLocalModel = true           // ASR_ENGINE whisper or auto
    }

    static func evaluate(_ facts: Facts, pinned: Pinned = .current) -> Status {
        guard let bundle = facts.bundle else { return .notApplicable }
        guard let installed = facts.installed else { return .needsInstall(.notInstalled) }
        if installed != bundle { return .needsInstall(.outdated) }
        if !facts.venvPythonExecutable { return .needsInstall(.venvMissing) }
        if facts.needsLocalModel && facts.modelBytes != pinned.modelBytes { return .needsInstall(.modelMissing) }
        if facts.sileroBytes != pinned.sileroBytes { return .needsInstall(.vadModelMissing) }
        return .ready
    }

    /// The facts of the disk. `read` and `size` are injected so the self test needs no real files for the model (3 GB).
    struct Disk {
        var read: (URL) -> Data? = { FileManager.default.contents(atPath: $0.path) }
        /// stat() follows links: huggingface_hub keeps snapshots/<rev>/weights.npz as a link into blobs/ (attributesOfItem does not follow it and would see a
        /// 76-byte link). The target must be a regular file; a dangling link is missing.
        var size: (URL) -> Int64? = { url in
            var info = stat()
            guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return Int64(info.st_size)
        }
        var isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func gatherFacts(resources: URL?, supportDir: URL, pythonBin: URL, home: URL, needsLocalModel: Bool,
                            pinned: Pinned = .current, disk: Disk = Disk()) -> Facts {
        var facts = Facts()
        facts.needsLocalModel = needsLocalModel
        if let resources = resources, let data = disk.read(resources.appendingPathComponent("mcap/\(componentsFile)")) {
            facts.bundle = parseBundleComponents(data)
        }
        guard facts.bundle != nil else { return facts }
        if let data = disk.read(supportDir.appendingPathComponent(installedFile)) { facts.installed = parseInstalled(data) }
        facts.venvPythonExecutable = disk.isExecutable(pythonBin)
        facts.modelBytes = disk.size(pinned.modelPath(home: home))
        facts.sileroBytes = disk.size(pinned.sileroPath(supportDir: supportDir))
        return facts
    }

    /// The facts of THIS Mac: config.env (when there is one) says whether the local speech model is needed, the rest is `gatherFacts`.
    static func liveFacts(configFile: URL, resources: URL?, supportDir: URL, pythonBin: URL, home: URL, disk: Disk = Disk()) -> Facts {
        let values = disk.read(configFile).flatMap { String(data: $0, encoding: .utf8) }.map { AppConfig.parseEnvText($0) } ?? [:]
        return gatherFacts(resources: resources, supportDir: supportDir, pythonBin: pythonBin, home: home,
                           needsLocalModel: needsLocalModel(asrEngine: values["ASR_ENGINE"]), disk: disk)
    }

    /// ASR_ENGINE decides whether the local speech model is needed: whisper (the default) and auto use it; a cloud or company engine does not.
    static func needsLocalModel(asrEngine: String?) -> Bool {
        switch (asrEngine ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "whisper", "auto": return true
        default: return false
        }
    }

    // MARK: - When to ask

    /// True when the app runs from the disk image, from another volume or from a translocated copy (Gatekeeper's randomized read-only path).
    static func isMisplaced(bundlePath: String) -> Bool {
        return bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/Volumes/")
    }

    /// At most one alert per launch, only when something is missing, a window may be shown and the Mac is not policy-managed.
    static func shouldPrompt(status: Status, uiAllowed: Bool, policyManaged: Bool, alreadyPrompted: Bool) -> Bool {
        return status.needsInstall && uiAllowed && !policyManaged && !alreadyPrompted
    }

    /// True while the app must not record: no components-installed.json yet, so the helper has not shown the recording legal notice (its step 1) or asked for
    /// the macOS permissions (its step 7). Not for an outdated or incomplete install (the notice was accepted then), not for a build without components.json.
    static func holdsRecording(_ status: Status) -> Bool {
        return status == .needsInstall(.notInstalled)
    }

    /// True while a helper window runs: the lock link exists and the pid it names is a live process. A dead pid is a lock a crashed helper left behind (the helper
    /// itself also removes it). `destination` and `isAlive` are injected for the self test.
    static func installerRunning(supportDir: URL,
                                 destination: (String) -> String? = { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) },
                                 isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> Bool {
        guard let target = destination(supportDir.appendingPathComponent(lockName).path), let pid = pid_t(target), pid > 0 else { return false }
        return isAlive(pid)
    }

    // MARK: - Texts (the app's UI language)

    /// The language of these texts. At the very first launch there is no config.env yet (the helper writes UI_LANGUAGE later), so the app still speaks its default,
    /// English: this window follows the macOS language instead (`systemLanguage`) until a config.env exists.
    static func systemLanguage(_ preferred: [String]) -> UILanguage {
        return (preferred.first ?? "").lowercased().hasPrefix("ko") ? .ko : .en
    }

    private static func pick(_ lang: UILanguage, _ en: String, _ ko: String) -> String { return lang == .ko ? ko : en }

    struct AlertText: Equatable {
        var message: String
        var info: String
        var start: String
        var later: String
    }

    static func alertText(lang: UILanguage = L10n.current) -> AlertText {
        return AlertText(
            message: pick(lang, "\(AppInfo.displayName) needs to install its components (about 4 GB download, needs internet). Start now?",
                          "\(AppInfo.displayName) 앱이 구성 요소를 설치해야 해요 (약 4 GB 다운로드, 인터넷 필요). 지금 시작할까요?"),
            info: pick(lang, "A Terminal window shows the progress and asks a few questions. Later, the menu bar icon has the item \"Components: not installed - run installer\".",
                       "터미널 창에 진행 상황이 보이고 몇 가지를 물어봐요. 나중에 하려면 메뉴 막대 아이콘의 \"구성 요소: 설치 안 됨 - 설치 프로그램 실행\" 항목을 쓰세요."),
            start: pick(lang, "Start", "시작"),
            later: pick(lang, "Later", "나중에"))
    }

    struct MisplacedText: Equatable {
        var message: String
        var info: String
        var ok: String
    }

    static func misplacedText(lang: UILanguage = L10n.current) -> MisplacedText {
        return MisplacedText(
            message: pick(lang, "Move \(AppInfo.displayName) to the Applications folder first", "먼저 \(AppInfo.displayName) 앱을 Applications 폴더로 옮겨 주세요"),
            info: pick(lang, "The app is running from the disk image or from a temporary place, and the components would be installed for a copy that macOS can remove. Drag it to Applications in the disk image window, open it from there, and the installer is offered again.",
                       "앱이 디스크 이미지나 임시 위치에서 실행 중이에요. 이대로 설치하면 macOS가 지울 수 있는 복사본을 기준으로 설치돼요. 디스크 이미지 창에서 Applications로 끌어다 놓고 거기서 다시 열면 설치 창이 다시 떠요."),
            ok: pick(lang, "OK", "확인"))
    }

    struct RunningText: Equatable {
        var message: String
        var info: String
        var ok: String
    }

    /// `command` is the line that runs the copy of the helper by hand (the helper itself says what holds the lock and ignores a lock of a dead process).
    static func runningText(command: String, lang: UILanguage = L10n.current) -> RunningText {
        return RunningText(
            message: pick(lang, "The installer is already running", "설치 프로그램이 이미 실행 중이에요"),
            info: pick(lang, "An installer window is open in Terminal (it may be behind other windows): finish it there. If you cannot find any installer window, open Terminal and run:  \(command)",
                       "터미널에 설치 창이 이미 열려 있어요 (다른 창 뒤에 있을 수 있어요). 거기서 끝내세요. 설치 창이 보이지 않으면 터미널을 열고 다음을 실행하세요:  \(command)"),
            ok: pick(lang, "OK", "확인"))
    }

    struct MenuItemState: Equatable {
        var title: String
        var visible: Bool
        var tooltip: String?
    }

    static func menuItem(for status: Status, lang: UILanguage = L10n.current) -> MenuItemState {
        guard case .needsInstall(let reason) = status else { return MenuItemState(title: "", visible: false, tooltip: nil) }
        switch reason {
        case .notInstalled:
            return MenuItemState(title: pick(lang, "Components: not installed - run installer", "구성 요소: 설치 안 됨 - 설치 프로그램 실행"), visible: true,
                                 tooltip: pick(lang, "The Python environment and the speech models are not installed yet. Click to open the installer in Terminal.",
                                               "Python 환경과 음성 인식 모델이 아직 설치되지 않았어요. 누르면 터미널에서 설치 프로그램을 열어요."))
        case .outdated:
            return MenuItemState(title: pick(lang, "Components: update needed - run installer", "구성 요소: 업데이트 필요 - 설치 프로그램 실행"), visible: true,
                                 tooltip: pick(lang, "This version of the app needs other components than the ones installed. Click to open the installer in Terminal.",
                                               "이 버전의 앱에는 설치된 것과 다른 구성 요소가 필요해요. 누르면 터미널에서 설치 프로그램을 열어요."))
        case .venvMissing, .modelMissing, .vadModelMissing:
            return MenuItemState(title: pick(lang, "Components: incomplete - run installer", "구성 요소: 불완전 - 설치 프로그램 실행"), visible: true,
                                 tooltip: pick(lang, "Something the app needs is missing (the Python environment or a speech model). Click to open the installer in Terminal: it repairs what is missing.",
                                               "앱에 필요한 것이 없어요 (Python 환경 또는 음성 인식 모델). 누르면 터미널에서 설치 프로그램을 열어요. 없는 것만 다시 설치해요."))
        }
    }

    static func failureText(_ error: InstallerError, lang: UILanguage = L10n.current) -> String {
        switch error {
        case .noBundle:
            return pick(lang, "This copy of the app has no installer files.", "이 앱에는 설치 프로그램 파일이 없어요.")
        case .scriptMissing(let path):
            return pick(lang, "The installer script is missing from the app (\(path)). Copy the app from the disk image again.", "앱에서 설치 스크립트를 찾지 못했어요 (\(path)). 디스크 이미지에서 앱을 다시 복사하세요.")
        case .writeFailed(let path):
            return pick(lang, "The installer could not be prepared in \(path).", "\(path) 에 설치 프로그램을 준비하지 못했어요.")
        case .terminalFailed(let path):
            return pick(lang, "Terminal could not be opened. Open Terminal yourself and run:  bash \"\(path)\"", "터미널을 열지 못했어요. 터미널을 직접 열고 다음을 실행하세요:  bash \"\(path)\"")
        }
    }

    // MARK: - The installer copy

    enum InstallerError: Error, Equatable {
        case noBundle
        case scriptMissing(String)
        case writeFailed(String)
        case terminalFailed(String)
    }

    /// Copies the bundled helper to SUPPORT_DIR/first-run-install.command (0755; an identical copy is left alone) and writes SUPPORT_DIR/first-run.env
    /// (0600, one line: MCAP_BUNDLE_DIR=<the app's mcap folder>). Returns the copy. Nothing else is written.
    static func prepareInstaller(mcapDir: URL, supportDir: URL, fm: FileManager = .default) -> Result<URL, InstallerError> {
        let source = mcapDir.appendingPathComponent(bundledScript)
        guard let script = fm.contents(atPath: source.path), !script.isEmpty else { return .failure(.scriptMissing(source.path)) }
        guard !mcapDir.path.contains("\n"), !mcapDir.path.contains("\r") else { return .failure(.writeFailed(mcapDir.path)) }
        let copy = supportDir.appendingPathComponent(installerCopyName)
        do {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            if fm.contents(atPath: copy.path) != script || !fm.isExecutableFile(atPath: copy.path) {
                try writeAtomically(script, to: copy, mode: 0o755, fm: fm)
            }
            try writeAtomically(Data("MCAP_BUNDLE_DIR=\(mcapDir.path)\n".utf8), to: supportDir.appendingPathComponent(envFileName), mode: 0o600, fm: fm)
        } catch {
            return .failure(.writeFailed(supportDir.path))
        }
        return .success(copy)
    }

    private static func writeAtomically(_ data: Data, to url: URL, mode: Int, fm: FileManager) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid())")
        try? fm.removeItem(at: temp)
        try data.write(to: temp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        if rename(temp.path, url.path) != 0 {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The command after `open`: the same way Settings opens Terminal for its two commands.
    static func terminalArguments(for installer: URL) -> [String] {
        return ["-a", "Terminal", installer.path]
    }
}

// MARK: - The effects (injected: the self test replaces every one of them)

struct FirstRunEnvironment {
    var supportDir: URL
    var mcapDir: () -> URL?
    var bundlePath: () -> String
    var facts: () -> FirstRun.Facts
    var uiAllowed: () -> Bool
    var policyManaged: () -> Bool
    var language: () -> UILanguage = { L10n.current }    // UI_LANGUAGE, or the macOS language while there is no config.env yet
    var ask: (FirstRun.AlertText) -> Bool                // the alert [Start] [Later]: true = Start (main thread)
    var tellMisplaced: (FirstRun.MisplacedText) -> Void  // the "move me to Applications" alert (main thread)
    var tellRunning: (FirstRun.RunningText) -> Void      // the "the installer is already running" alert (main thread)
    var openTerminal: (URL) -> Bool
    var installerRunning: () -> Bool                     // a helper window holds the lock (FirstRun.installerRunning)
    var showFailure: (String) -> Void                    // main thread
    var runInBackground: (@escaping () -> Void) -> Void
    var runOnMain: (@escaping () -> Void) -> Void        // DispatchQueue.main.async
    var runOnRunLoop: (@escaping () -> Void) -> Void     // RunLoop.main.perform: AFTER the dispatch block has returned. Anything modal goes through this.
    var runAfter: (TimeInterval, @escaping () -> Void) -> Void   // main thread, once
    var log: (String) -> Void = { Log.info($0) }

    static func live(config: AppConfig) -> FirstRunEnvironment {
        let background = DispatchQueue(label: "\(AppInfo.bundleID).first-run", qos: .utility)
        func lang() -> UILanguage {
            return FileManager.default.fileExists(atPath: AppConfig.configFilePath.path) ? L10n.current : FirstRun.systemLanguage(Locale.preferredLanguages)
        }
        func notice(_ message: String, _ info: String, _ ok: String) {
            NSApp.activate(ignoringOtherApps: true)              // a menu-bar app is not active: the alert would open behind the other windows
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = info
            alert.addButton(withTitle: ok)
            _ = alert.runModal()
        }
        return FirstRunEnvironment(
            supportDir: config.supportDir,
            mcapDir: {
                let dir = Bundle.main.resourceURL?.appendingPathComponent("mcap", isDirectory: true)
                return dir.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            },
            bundlePath: { Bundle.main.bundleURL.path },
            facts: {
                FirstRun.liveFacts(configFile: AppConfig.configFilePath, resources: Bundle.main.resourceURL, supportDir: config.supportDir, pythonBin: config.pythonBin,
                                   home: FileManager.default.homeDirectoryForCurrentUser)
            },
            uiAllowed: { LaunchGuard.isSignedAppLaunch },
            policyManaged: { OrgPolicy.systemPolicyPresent() },
            language: { lang() },
            ask: { text in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = text.message
                alert.informativeText = text.info
                alert.addButton(withTitle: text.start)
                alert.addButton(withTitle: text.later)
                return alert.runModal() == .alertFirstButtonReturn
            },
            tellMisplaced: { text in notice(text.message, text.info, text.ok) },
            tellRunning: { text in notice(text.message, text.info, text.ok) },
            openTerminal: { file in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = FirstRun.terminalArguments(for: file)
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
            },
            installerRunning: { FirstRun.installerRunning(supportDir: config.supportDir) },
            showFailure: { text in
                notice(lang() == .ko ? "설치 프로그램을 시작하지 못했어요" : "The installer could not be started", text, lang() == .ko ? "확인" : "OK")
            },
            runInBackground: { work in background.async(execute: work) },
            runOnMain: { work in DispatchQueue.main.async(execute: work) },
            runOnRunLoop: { work in RunLoop.main.perform(inModes: [.common], block: work) },
            runAfter: { seconds, work in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) })
    }
}

// MARK: - The controller (main thread)

final class FirstRunController {
    private let env: FirstRunEnvironment
    private var prompted = false
    private var recheckPending = false
    private(set) var status: FirstRun.Status = .notApplicable
    /// Called on the main thread whenever a check finishes (the menu item follows it).
    var onStatusChange: ((FirstRun.Status) -> Void)?
    /// Called on the main thread whenever a check finishes: does the app have to hold recording (`FirstRun.holdsRecording`)? Also after `evaluateNow`.
    var onHoldChange: ((Bool) -> Void)?

    init(env: FirstRunEnvironment) { self.env = env }

    /// Before the session controller starts: the verdict, read right here (a few file reads, no network), so that the first poll already knows whether the
    /// app may record. Sets `status` and calls the two callbacks like a finished check does.
    @discardableResult
    func evaluateNow() -> FirstRun.Status {
        let verdict = FirstRun.evaluate(env.facts())
        apply(verdict)
        return verdict
    }

    /// At launch: the cheap checks run in the background, the answer comes back on the main thread, and at most one alert is shown.
    func checkAtLaunch() {
        check(thenPrompt: true)
    }

    /// When the menu opens: the item follows the disk (the helper may have finished since). Never an alert.
    func refreshStatus() {
        check(thenPrompt: false)
    }

    private func apply(_ verdict: FirstRun.Status) {
        status = verdict
        onStatusChange?(verdict)
        onHoldChange?(FirstRun.holdsRecording(verdict))
        // While recording is held the check repeats by itself: the hold ends when the helper has written its record, without a click on the menu.
        if FirstRun.holdsRecording(verdict) && !recheckPending {
            recheckPending = true
            env.runAfter(FirstRun.holdRecheckSeconds) { [weak self] in
                guard let self = self else { return }
                self.recheckPending = false
                self.check(thenPrompt: false)
            }
        }
    }

    private func check(thenPrompt: Bool) {
        env.runInBackground { [weak self] in
            guard let self = self else { return }
            let verdict = FirstRun.evaluate(self.env.facts())
            self.env.runOnMain { [weak self] in
                guard let self = self else { return }
                self.apply(verdict)
                // never modal inside the dispatch block (see the header): the prompt waits for the run loop
                if thenPrompt { self.env.runOnRunLoop { [weak self] in self?.promptIfNeeded(verdict) } }
            }
        }
    }

    private func promptIfNeeded(_ verdict: FirstRun.Status) {
        guard FirstRun.shouldPrompt(status: verdict, uiAllowed: env.uiAllowed(), policyManaged: env.policyManaged(), alreadyPrompted: prompted) else { return }
        prompted = true
        env.log("first run: components need to be installed (\(verdict)); asking")
        if FirstRun.isMisplaced(bundlePath: env.bundlePath()) {
            env.tellMisplaced(FirstRun.misplacedText(lang: env.language()))
            return
        }
        if env.ask(FirstRun.alertText(lang: env.language())) { startInstaller() } else { env.log("first run: the person chose Later") }
    }

    /// The menu item for `status` in the language of the first-run texts.
    func menuItem(for status: FirstRun.Status) -> FirstRun.MenuItemState {
        return FirstRun.menuItem(for: status, lang: env.language())
    }

    /// Start of the helper: from the alert and from the menu item. A helper that already runs (its lock) is not started a second time: two helpers would write
    /// the same runtime folder, venv and download; the helper refuses a second run by itself too.
    func startInstaller() {
        let lang = env.language()
        if FirstRun.isMisplaced(bundlePath: env.bundlePath()) {
            env.tellMisplaced(FirstRun.misplacedText(lang: lang))
            return
        }
        guard let mcap = env.mcapDir() else {
            env.showFailure(FirstRun.failureText(.noBundle, lang: lang))
            return
        }
        switch FirstRun.prepareInstaller(mcapDir: mcap, supportDir: env.supportDir) {
        case .failure(let error):
            env.log("first run: the installer could not be prepared (\(error))")
            env.showFailure(FirstRun.failureText(error, lang: lang))
        case .success(let installer):
            if env.installerRunning() {
                env.log("first run: the installer is already running (lock \(FirstRun.lockName)); no second window")
                env.tellRunning(FirstRun.runningText(command: "bash \"\(installer.path)\"", lang: lang))
            } else if env.openTerminal(installer) {
                env.log("first run: the installer was opened in Terminal (\(installer.path))")
            } else {
                env.log("first run: Terminal could not be opened for \(installer.path)")
                env.showFailure(FirstRun.failureText(.terminalFailed(installer.path), lang: lang))
            }
        }
    }
}

// MARK: - selftest-firstrun (the contract with the scripts, run by scripts/test_scripts.sh)

/// `<short name> selftest-firstrun --components FILE [--installed FILE]`: reads the two records the way the app does (`FirstRun.parseBundleComponents`,
/// `FirstRun.parseInstalled`) and says what it understood. scripts/test_scripts.sh runs it against the components.json that scripts/build_dmg.sh really wrote and the
/// components-installed.json that scripts/first_run_install.sh really wrote, so the key names and the hash rules are checked against the Swift parser itself
/// and not against a copy of its source text. Device-free, writes nothing. Exit 0: everything given was understood (and the two match); 1: not; 2: usage.
func runSelftestFirstRun(arguments: [String]) -> Int32 {
    func value(_ flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
    guard let componentsPath = value("--components") else {
        FileHandle.standardError.write(Data("usage: \(AppInfo.shortName) selftest-firstrun --components FILE [--installed FILE]\n".utf8))
        return 2
    }
    guard let data = FileManager.default.contents(atPath: componentsPath), let bundle = FirstRun.parseBundleComponents(data) else {
        print("components: NOT UNDERSTOOD (\(componentsPath))")
        return 1
    }
    print("components: ok runtime=\(bundle.runtimeSHA256) lock=\(bundle.requirementsLockSHA256)")
    guard let installedPath = value("--installed") else { return 0 }
    guard let installedData = FileManager.default.contents(atPath: installedPath), let installed = FirstRun.parseInstalled(installedData) else {
        print("installed: NOT UNDERSTOOD (\(installedPath))")
        return 1
    }
    print("installed: ok runtime=\(installed.runtimeSHA256) lock=\(installed.requirementsLockSHA256)")
    print(installed == bundle ? "match: yes" : "match: no")
    return installed == bundle ? 0 : 1
}
