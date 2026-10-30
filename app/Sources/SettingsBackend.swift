import Foundation

// =====================================================================================
// Everything the Settings window does besides editing text, as plain functions and one coordinator the window calls (no AppKit here):
//
//   McapCommand / PipelineLauncher.runMcap   the three read-only pipeline commands the window asks for (`api-key check`, `gcal status`,
//                                            `asr-engines list --json`): fixed argv, the clean environment of every pipeline job, the runtime-trust
//                                            check of the launcher, 30 s. The answers are interpreted by pure functions that keep only content-free text.
//   TerminalScript                           the two things only a Terminal may do: `python -m mcap asr-engines consent <engine>` (the consent of a
//                                            cloud engine: typed phrase on a TTY) and `python -m mcap gcal auth` (Google sign-in). The window writes a
//                                            small .command file that runs exactly that command and opens it in Terminal.app. It NEVER writes the
//                                            consent file itself and never reads the Google token.
//   RestartPlan / RestartTracker / AppRestarter  "Saved. Restart the app to apply": relaunch only while nothing would be undone by it: no recording
//                                            runs and no pause, hand-stopped call or call about to be recorded is in the controller's memory (a relaunch
//                                            forgets those and records the call again); otherwise only "Restart after the recording / the call".
//   FolderStatusChecker                      the meeting folder's state, asked after the typing paused and never on the main thread.
//   SettingsCoordinator                      load / save / key status / key store / checks, with every effect injected (SettingsEnvironment).
// =====================================================================================

// MARK: - The pipeline commands

enum McapCommand: Equatable {
    case apiKeyCheck, gcalStatus, asrEnginesList

    /// Fixed: nothing of the window's text ever reaches an argument.
    var arguments: [String] {
        switch self {
        case .apiKeyCheck: return ["-m", "mcap", "api-key", "check"]
        case .gcalStatus: return ["-m", "mcap", "gcal", "status"]
        case .asrEnginesList: return ["-m", "mcap", "asr-engines", "list", "--json"]
        }
    }
    static let timeout: TimeInterval = 30
}

struct McapRun: Equatable {
    var launched: Bool
    var status: Int32
    var timedOut: Bool
    var output: String                // stdout and stderr together: only the interpreters below look at it, and they keep content-free text
    var refusal: String? = nil        // nothing was started, and why
}

extension PipelineLauncher {
    /// Runs one of the commands above with the python of the pipeline venv, from PROJECT_DIR/pipeline, after the launcher's runtime-trust check. BLOCKS
    /// until the child ended or `timeout` passed: call it from a background queue. `runner` is the seam of the self test (default: the child runner of
    /// the company-server enrollment: stdin closed after nothing, output capped at 64 KB, SIGTERM at the timeout).
    static func runMcap(_ command: McapCommand, config: AppConfig, policy: OrgPolicy, timeout: TimeInterval = McapCommand.timeout,
                        runner: CompanyServerConnect.Runner = CompanyServerConnect.runChild,
                        environment base: [String: String] = ProcessInfo.processInfo.environment,
                        fileInfo: (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile) -> McapRun {
        func refused(_ why: String) -> McapRun { McapRun(launched: false, status: -1, timedOut: false, output: "", refusal: why) }
        let fm = FileManager.default
        let pipelineDir = config.projectDir.appendingPathComponent("pipeline", isDirectory: true)
        guard fm.isExecutableFile(atPath: config.pythonBin.path) else { return refused("python is missing") }
        guard fm.fileExists(atPath: pipelineDir.appendingPathComponent("mcap").path) else { return refused("the pipeline package is missing") }
        if case .untrusted(let why) = RuntimeTrust.verify(pythonBin: config.pythonBin, projectDir: config.projectDir, policy: policy, fileInfo: fileInfo) {
            return refused("the runtime is not trusted (\(why))")
        }
        let result = runner(config.pythonBin, command.arguments, sanitizedEnvironment(from: base, policy: policy), pipelineDir, Data(), timeout)
        if !result.launched { return refused("python could not be started") }
        return McapRun(launched: true, status: result.status, timedOut: result.timedOut, output: result.output)
    }
}

// MARK: - Interpreting the answers (content-free)

enum SettingsText {
    /// One line of tool output, safe to show: control characters gone, `sk-ant-...` shapes and long token-like words masked, clipped.
    static func scrubbed(_ text: String, limit: Int = 200) -> String {
        var s = String(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) })
        s = s.replacingOccurrences(of: "sk-ant-[A-Za-z0-9_\\-]+", with: "sk-ant-***", options: .regularExpression)
        s = s.replacingOccurrences(of: "[A-Za-z0-9_\\-]{32,}", with: "***", options: .regularExpression)
        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return NotificationText.clip(s, limit)
    }
}

/// The result of `api-key check`: one tiny paid call that proves the stored key works. Only the verdict, the model and the cost are shown.
struct KeyCheckOutcome: Equatable {
    var ok: Bool
    var text: String

    static func interpret(_ run: McapRun) -> KeyCheckOutcome {
        if let why = run.refusal { return KeyCheckOutcome(ok: false, text: tr("The check could not be started: \(why).", ko: "확인을 시작하지 못했어요: \(why).")) }
        if run.timedOut { return KeyCheckOutcome(ok: false, text: tr("The check did not finish within 30 seconds.", ko: "확인이 30초 안에 끝나지 않았어요.")) }
        let lines = run.output.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        if run.status == 0, lines.contains(where: { $0.hasPrefix("API key OK") }) {
            let extras = lines.filter { $0.hasPrefix("model:") || $0.hasPrefix("cost_usd:") }.map { SettingsText.scrubbed($0, limit: 80) }
            return KeyCheckOutcome(ok: true, text: ([tr("API key OK", ko: "API 키 확인됨")] + extras).joined(separator: " · "))
        }
        if let failed = lines.first(where: { $0.hasPrefix("FAILED:") }) {
            return KeyCheckOutcome(ok: false, text: SettingsText.scrubbed(failed))
        }
        return KeyCheckOutcome(ok: false, text: tr("The check failed (exit \(run.status)).", ko: "확인에 실패했어요 (종료 코드 \(run.status))."))
    }
}

/// One row of `asr-engines list --json`, reduced to what the window shows.
struct AsrEngineState: Equatable {
    var engine: String
    var consentOK: Bool
    var consent: String            // a short phrase
    var credential: String         // stored | missing | none (optional) | ...
}

enum AsrEngineStates {
    static func parse(_ output: String) -> [String: AsrEngineState]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["engines"] as? [[String: Any]] else { return nil }
        var out: [String: AsrEngineState] = [:]
        for row in rows {
            guard let engine = row["engine"] as? String else { continue }
            let consent = (row["consent"] as? String) ?? ""
            let credential = (row["credential"] as? String) ?? ""
            out[engine] = AsrEngineState(engine: engine, consentOK: consent.hasPrefix("ok"), consent: consentPhrase(consent), credential: SettingsText.scrubbed(credential, limit: 40))
        }
        return out.isEmpty ? nil : out
    }

    static func consentPhrase(_ raw: String) -> String {
        if raw.hasPrefix("ok") {
            if let r = raw.range(of: "until "), let end = raw.range(of: ")", range: r.upperBound..<raw.endIndex) {
                let date = SettingsText.scrubbed(String(raw[r.upperBound..<end.lowerBound]), limit: 30)
                return tr("valid until \(date)", ko: "\(date)까지 유효")
            }
            return tr("valid", ko: "유효")
        }
        switch raw {
        case "no-consent": return tr("no consent recorded", ko: "동의 기록 없음")
        case "consent-mismatch": return tr("the consent no longer matches (address, model or role changed)", ko: "동의가 더 이상 맞지 않아요 (주소, 모델, 역할이 바뀜)")
        case "consent-expired": return tr("the consent expired", ko: "동의가 만료됐어요")
        case "consent-tampered": return tr("the consent file failed its integrity check", ko: "동의 파일의 무결성 검사가 실패했어요")
        case "not-configured": return tr("the address is not set", ko: "주소가 설정되지 않았어요")
        case "bad-host": return tr("the address is not accepted", ko: "주소를 받아들일 수 없어요")
        case "n/a", "not needed": return tr("not needed", ko: "필요 없음")
        default: return SettingsText.scrubbed(raw, limit: 40)
        }
    }
}

/// `gcal status` without its details: signed in or not, never the account, the client file's path or a token.
enum GoogleCalendarState: Equatable {
    case ready, notConfigured, notSignedIn, laneDenied, unknown(String)

    var text: String {
        switch self {
        case .ready: return tr("Signed in to Google Calendar (read-only)", ko: "Google 캘린더에 로그인됨 (읽기 전용)")
        case .notConfigured: return tr("Not set up: the Google OAuth client file is missing or unusable (docs/CALENDAR_AUTOSTART.md)", ko: "설정 안 됨: Google OAuth 클라이언트 파일이 없거나 쓸 수 없어요 (docs/CALENDAR_AUTOSTART.md)")
        case .notSignedIn: return tr("Not signed in to Google", ko: "Google에 로그인하지 않았어요")
        case .laneDenied: return tr("Blocked by the organisation policy", ko: "조직 정책으로 막혀 있어요")
        case .unknown(let why): return tr("Could not check: \(why)", ko: "확인하지 못했어요: \(why)")
        }
    }

    static func interpret(_ run: McapRun) -> GoogleCalendarState {
        if let why = run.refusal { return .unknown(SettingsText.scrubbed(why, limit: 60)) }
        if run.timedOut { return .unknown(tr("timed out", ko: "시간 초과")) }
        let lines = run.output.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        if run.status == 0, lines.last == "ready" { return .ready }
        if lines.contains(where: { $0.hasPrefix("OAuth client file:") && $0.contains("NOT usable") }) { return .notConfigured }
        if lines.contains(where: { $0.hasPrefix("token:") && $0.contains("NOT available") }) { return .notSignedIn }
        if lines.contains(where: { $0.hasPrefix("organisation lane:") && $0.contains("DENIED") }) { return .laneDenied }
        return .unknown(tr("exit \(run.status)", ko: "종료 코드 \(run.status)"))
    }
}

// MARK: - Terminal

enum TerminalAction: Equatable {
    case consent(engine: String)
    case googleSignIn

    /// Engines whose consent is given with `consent <engine>` (the company server `remote` is enrolled, not consented to, from the menu).
    static let consentEngines = ["clova", "openai-compat", "azure"]

    /// The command after the python path: exactly the commands of docs/PRIVACY_AND_CONSENT.md and docs/CALENDAR_AUTOSTART.md.
    var arguments: [String]? {
        switch self {
        case .consent(let engine):
            return Self.consentEngines.contains(engine) ? ["-m", "mcap", "asr-engines", "consent", engine] : nil
        case .googleSignIn:
            return ["-m", "mcap", "gcal", "auth"]
        }
    }
}

enum TerminalScript {
    /// POSIX single quoting: the text is taken literally by the shell.
    static func shellQuote(_ text: String) -> String {
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// nil for an action that is not one of the two commands (an engine that has no consent command).
    static func script(for action: TerminalAction, python: URL, pipelineDir: URL) -> String? {
        guard let arguments = action.arguments else { return nil }
        let command = ([shellQuote(python.path)] + arguments.map { shellQuote($0) }).joined(separator: " ")
        let shown = (["python"] + arguments).joined(separator: " ")
        return """
        #!/bin/bash
        # Written by the Settings window of \(AppInfo.displayName). It runs the one command below in this Terminal window and removes itself.
        rm -f -- "$0"
        cd \(shellQuote(pipelineDir.path)) || exit 1
        echo \(shellQuote("$ " + shown))
        \(command)
        status=$?
        echo
        echo "Finished with exit code $status. You can close this window."
        exit $status

        """
    }

    /// Writes the script as an executable (0700) `.command` file in a private new folder of `parent` and returns its URL.
    static func write(_ script: String, name: String, in parent: URL) throws -> URL {
        let fm = FileManager.default
        let dir = parent.appendingPathComponent("mcap-terminal-\(getpid())-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent(name)
        try Data(script.utf8).write(to: file, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    static func fileName(for action: TerminalAction) -> String {
        switch action {
        case .consent(let engine): return "mcap-consent-\(engine).command"
        case .googleSignIn: return "mcap-google-sign-in.command"
        }
    }
}

// MARK: - Restart

extension RestartHold {
    /// Why the restart waits (or is refused), in plain words.
    var reason: String {
        switch self {
        case .paused:
            return tr("Auto recording is paused, and a restart would forget the pause. Resume it in the menu first, then restart.",
                      ko: "자동 녹음이 일시정지 상태인데, 다시 시작하면 일시정지가 풀려요. 메뉴에서 먼저 재개한 뒤에 다시 시작하세요.")
        case .stoppedCall:
            return tr("You stopped a call that is still running (or it was ended for no speech). A restart would record it again, so the restart waits until the call is over.",
                      ko: "아직 진행 중인 통화를 직접 멈췄어요 (또는 소리가 없어서 종료됐어요). 지금 다시 시작하면 그 통화를 다시 녹음하므로 통화가 끝난 뒤에 다시 시작해요.")
        case .callLive:
            return tr("A call was just detected and is about to be recorded, so the restart waits until it is over.",
                      ko: "통화가 막 감지돼서 곧 녹음이 시작돼요. 그래서 통화가 끝난 뒤에 다시 시작해요.")
        }
    }
}

enum RestartPlan: Equatable {
    case now
    case afterRecording
    case afterCall(RestartHold)          // nothing records, but a relaunch would record a call again: wait until it is over
    case unavailable(String)

    /// Never while a recording runs (the app would finalise it and the rest of the meeting would be lost), and never while a relaunch would undo a pause or a
    /// manual stop (both live in memory only: the new process would record the call again). A pause has no end of its own, so nothing is armed for it.
    static func decide(recording: Bool, hold: RestartHold? = nil, bundlePath: String?) -> RestartPlan {
        guard let path = bundlePath, path.hasSuffix(".app") else {
            return .unavailable(tr("This copy does not run from an app bundle: quit it and start it again yourself.", ko: "이 사본은 앱 번들로 실행 중이 아니에요: 직접 종료한 뒤 다시 시작하세요."))
        }
        if recording { return .afterRecording }
        switch hold {
        case .paused?: return .unavailable(RestartHold.paused.reason)
        case let h?: return .afterCall(h)
        case nil: return .now
        }
    }

    /// The restart button: its title and whether it can be pressed. A restart that is armed can always be cancelled.
    func button(armed: Bool) -> (title: String, enabled: Bool) {
        if armed { return (tr("Cancel the restart", ko: "다시 시작 취소"), true) }
        switch self {
        case .now: return (tr("Restart now", ko: "지금 다시 시작"), true)
        case .afterRecording: return (tr("Restart after the recording", ko: "녹음이 끝난 뒤 다시 시작"), true)
        case .afterCall: return (tr("Restart after the call", ko: "통화가 끝난 뒤 다시 시작"), true)
        case .unavailable: return (tr("Restart now", ko: "지금 다시 시작"), false)
        }
    }

    /// Why the button is off or only offers to wait (its tooltip); nil for a restart that can happen now.
    var explanation: String? {
        switch self {
        case .afterCall(let hold): return hold.reason
        case .unavailable(let why): return why
        default: return nil
        }
    }

    /// What the status line says once the person armed the restart.
    var armedText: String {
        switch self {
        case .afterCall(let hold): return hold.reason
        default: return tr("The app restarts as soon as the recording ends.", ko: "녹음이 끝나면 곧바로 앱이 다시 시작돼요.")
        }
    }
}

/// "Restart after the recording": armed from the window, fired when the controller reports that no recording runs any more AND that a relaunch loses nothing
/// (no pause, no hand-stopped call that is still running, no call about to be recorded).
struct RestartTracker: Equatable {
    private(set) var armed = false

    mutating func toggleArmed() { armed.toggle() }

    /// True = restart now. Disarms when it fires.
    mutating func stateChanged(recording: Bool, hold: RestartHold? = nil) -> Bool {
        guard armed, !recording, hold == nil else { return false }
        armed = false
        return true
    }
}

enum AppRestarter {
    /// `sh -c` waits (at most 30 s) until the old process is gone, so that the single-instance lock is free, and then opens a NEW instance of the
    /// bundle (`open -n -a`). The pid and the path are positional parameters, never part of the script text.
    static let script = "i=0; while kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt 150 ]; do sleep 0.2; i=$((i+1)); done; exec /usr/bin/open -n -a \"$2\""

    static func arguments(pid: Int32, bundlePath: String) -> [String] {
        return ["-c", script, "mc-restart", String(pid), bundlePath]
    }

    static func spawn(pid: Int32 = getpid(), bundlePath: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = arguments(pid: pid, bundlePath: bundlePath)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); return true } catch { return false }
    }
}

// MARK: - The meeting folder

struct FolderStatus: Equatable {
    enum State: Equatable { case writable, notWritable, willBeCreated, parentMissing, notAFolder }
    var state: State

    var text: String {
        switch state {
        case .writable: return tr("The folder exists and is writable.", ko: "폴더가 있고 쓸 수 있어요.")
        case .notWritable: return tr("The folder exists but is NOT writable: meetings stay in staging until that is fixed.", ko: "폴더는 있지만 쓸 수 없어요: 고칠 때까지 회의는 staging에 남아요.")
        case .willBeCreated: return tr("The folder does not exist yet: it is created when the first meeting is filed.", ko: "폴더가 아직 없어요: 첫 회의를 보관할 때 만들어져요.")
        case .parentMissing: return tr("The folder's parent does not exist (a synced folder whose app is not running?): meetings stay in staging until it does.", ko: "상위 폴더가 없어요 (동기화 앱이 꺼져 있나요?): 생길 때까지 회의는 staging에 남아요.")
        case .notAFolder: return tr("This path is a file, not a folder.", ko: "이 경로는 폴더가 아니라 파일이에요.")
        }
    }
    var ok: Bool { state == .writable || state == .willBeCreated }

    /// The folder to ask about for the text in the field (an empty field means the default folder); nil = not an absolute path: nothing to say yet.
    static func target(typed: String, defaultPath: String) -> String? {
        let path = typed.trimmingCharacters(in: .whitespaces).isEmpty ? defaultPath : typed
        return AppConfig.isAbsolutePathValue(path) ? path : nil
    }

    static func check(_ path: String, fm: FileManager = .default) -> FolderStatus {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
            if !isDir.boolValue { return FolderStatus(state: .notAFolder) }
            return FolderStatus(state: fm.isWritableFile(atPath: expanded) ? .writable : .notWritable)
        }
        let parent = (expanded as NSString).deletingLastPathComponent
        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: parent, isDirectory: &parentIsDir), parentIsDir.boolValue else { return FolderStatus(state: .parentMissing) }
        return FolderStatus(state: fm.isWritableFile(atPath: parent) ? .willBeCreated : .parentMissing)
    }
}

/// Asks `FolderStatus.check` for the folder typed in the field WITHOUT touching the file system on the main thread or while the person is still typing: a stale
/// network mount or a File Provider folder can block a stat for a long time, and a half-typed path under Documents, Desktop or a removable volume can raise a
/// macOS file-access prompt. `request` returns at once; the check runs after `delay` on a background queue, and an answer that a newer request has overtaken is
/// dropped (generation counter, like the window's `refreshStatuses`). Main thread only. The queues are injected: the self test runs them by hand.
final class FolderStatusChecker {
    static let debounce: TimeInterval = 0.4

    typealias Queue = (@escaping () -> Void) -> Void
    private let check: (String) -> FolderStatus
    private let mainAfter: (TimeInterval, @escaping () -> Void) -> Void
    private let background: Queue
    private let main: Queue
    private var generation = 0

    init(check: @escaping (String) -> FolderStatus = { FolderStatus.check($0) },
         mainAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
         background: @escaping Queue = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         main: @escaping Queue = { DispatchQueue.main.async(execute: $0) }) {
        self.check = check
        self.mainAfter = mainAfter
        self.background = background
        self.main = main
    }

    /// `deliver(nil)` at once when there is nothing to check (not an absolute path); `deliver(status)` later, if no newer request came in the meantime.
    func request(typed: String, defaultPath: String, delay: TimeInterval, deliver: @escaping (FolderStatus?) -> Void) {
        generation += 1
        let mine = generation
        guard let path = FolderStatus.target(typed: typed, defaultPath: defaultPath) else { deliver(nil); return }
        mainAfter(delay) { [weak self] in
            guard let self = self, mine == self.generation else { return }              // typed on: nothing was touched
            self.background {
                let status = self.check(path)
                self.main { if mine == self.generation { deliver(status) } }
            }
        }
    }
}

// MARK: - The coordinator

enum SettingsSaveResult: Equatable {
    case nothingToSave
    case refused([SettingsProblem])
    case failed(String)
    case saved(keys: [String], restartNeeded: Bool, backup: URL?)
}

/// The effects of the window, injected: the self test replaces every one of them, the app uses `live`.
struct SettingsEnvironment {
    var configFile: () -> URL
    var policy: () -> OrgPolicy
    var user: () -> String = { NSUserName() }
    var keychain: () -> SettingsKeychain = { SettingsKeychain() }
    var runMcap: (McapCommand) -> McapRun
    var openTerminal: (_ script: URL) -> Bool
    var tempDir: () -> URL = { FileManager.default.temporaryDirectory }
    var python: () -> URL
    var pipelineDir: () -> URL
    var now: () -> Date = { Date() }
    var fileOps: ConfigFileOps = ConfigFileOps()
    var isRecording: () -> Bool
    var restartHold: () -> RestartHold? = { nil }
    var bundlePath: () -> String? = { Bundle.main.bundleURL.path }
    var spawnRestart: (_ bundlePath: String) -> Bool = { AppRestarter.spawn(bundlePath: $0) }
    var terminate: () -> Void = { }

    static func live(config: AppConfig, policy: @escaping () -> OrgPolicy, isRecording: @escaping () -> Bool, restartHold: @escaping () -> RestartHold?,
                     terminate: @escaping () -> Void) -> SettingsEnvironment {
        return SettingsEnvironment(
            configFile: { AppConfig.configFilePath },
            policy: policy,
            runMcap: { command in PipelineLauncher.runMcap(command, config: config, policy: policy()) },
            openTerminal: { file in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", "Terminal", file.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
            },
            python: { config.pythonBin },
            pipelineDir: { config.projectDir.appendingPathComponent("pipeline", isDirectory: true) },
            isRecording: isRecording,
            restartHold: restartHold,
            terminate: terminate)
    }
}

final class SettingsCoordinator {
    let env: SettingsEnvironment

    init(env: SettingsEnvironment) { self.env = env }

    // MARK: Values

    /// The file and the policy as of now. `problem` is set when config.env exists and cannot be used (the window then edits nothing).
    func load() -> (snapshot: SettingsSnapshot, problem: String?) {
        let read = ConfigEnvWriter.read(env.configFile())
        return (SettingsSnapshot.load(text: read.text, policy: env.policy()), read.problem)
    }

    /// Writes the controls the person touched. The file is read again right now: a line edited by hand since the window opened stays as it is.
    func save(touched: [String: String]) -> SettingsSaveResult {
        let file = env.configFile()
        let read = ConfigEnvWriter.read(file)
        if let problem = read.problem { return .failed(problem) }
        let snapshot = SettingsSnapshot.load(text: read.text, policy: env.policy())
        let plan = snapshot.changes(touched: touched)
        if !plan.problems.isEmpty { return .refused(plan.problems) }
        if plan.changes.isEmpty { return .nothingToSave }
        switch ConfigEnvEditor.apply(plan.changes, to: read.text ?? "") {
        case .failure(let f):
            return .failed(f.message)
        case .success(let text):
            switch ConfigEnvWriter.save(text, to: file, now: env.now(), ops: env.fileOps) {
            case .failed(let why): return .failed(why)
            case .saved(let backup):
                let keys = plan.changes.map { $0.key }
                let restart = keys.contains { SettingsCatalog.field($0)?.needsRestart ?? true }
                Log.info("settings: saved \(keys.joined(separator: ", ")) to \(file.lastPathComponent)\(backup == nil ? "" : " (backup made)")")
                return .saved(keys: keys, restartNeeded: restart, backup: backup)
            }
        }
    }

    // MARK: Keys (Keychain only)

    func item(for slot: SecretSlot) -> Result<KeychainItem, SettingsError> {
        return slot.item(effective: load().snapshot.effective, user: env.user())
    }

    func keyStatus(_ slot: SecretSlot) -> KeyStatus {
        guard case .success(let item) = item(for: slot) else { return .unknown }
        return env.keychain().status(item)
    }

    func storeKey(_ slot: SecretSlot, secret: String) -> KeychainOutcome {
        switch item(for: slot) {
        case .failure(let e): return .refused(e.message)
        case .success(let item):
            let outcome = env.keychain().store(secret: secret, kind: slot.kind, item: item)
            Log.info("settings: \(slot.engine ?? "Anthropic") key \(outcome == .ok ? "stored in the Keychain" : "not stored")")        // never the value, never the item name
            return outcome
        }
    }

    func removeKey(_ slot: SecretSlot) -> KeychainOutcome {
        switch item(for: slot) {
        case .failure(let e): return .refused(e.message)
        case .success(let item):
            let outcome = env.keychain().remove(item)
            Log.info("settings: \(slot.engine ?? "Anthropic") key \(outcome == .ok ? "removed from the Keychain" : "not removed")")
            return outcome
        }
    }

    // MARK: Read-only checks

    /// `api-key check` is a real call to Anthropic, and the pipeline does not gate an explicit command by the organisation's lanes: so this window does. Non-nil
    /// (the reason) while the policy keeps the Claude lane closed, the same condition under which the Privacy box says no transcript text leaves the Mac.
    func checkKeyBlockedReason() -> String? {
        guard env.policy().laneDenialReason("llm") != nil else { return nil }
        return tr("Check key is off: the organisation policy keeps the Claude lane closed, so nothing is sent to Anthropic from this Mac.",
                  ko: "키 확인을 쓸 수 없어요: 조직 정책이 Claude 경로를 막고 있어서 이 Mac에서 Anthropic으로 아무것도 보내지 않아요.")
    }

    func checkKey() -> KeyCheckOutcome {
        if let blocked = checkKeyBlockedReason() { return KeyCheckOutcome(ok: false, text: blocked) }
        return KeyCheckOutcome.interpret(env.runMcap(.apiKeyCheck))
    }

    func engineStates() -> [String: AsrEngineState]? {
        let run = env.runMcap(.asrEnginesList)
        guard run.launched, run.refusal == nil, !run.timedOut else { return nil }
        return AsrEngineStates.parse(run.output)
    }

    func googleState() -> GoogleCalendarState { GoogleCalendarState.interpret(env.runMcap(.gcalStatus)) }

    /// `states`: what `asr-engines list --json` said (nil = not known now): the consent and the stored-key facts of the engines.
    func privacyLines(states: [String: AsrEngineState]?) -> [PrivacySummary.Line] {
        let snapshot = load().snapshot
        let consent: [String: Bool?] = states.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key, Optional($0.value.consentOK)) }) } ?? [:]
        let keyMissing = Set((states ?? [:]).filter { $0.value.credential == "missing" }.map { $0.key })
        return PrivacySummary.lines(values: snapshot.effective, policy: env.policy(), consent: consent, credentialMissing: keyMissing)
    }

    // MARK: Terminal and restart

    /// Writes the script of `action` and opens it in Terminal. Returns nil when it was opened, else a short reason. Nothing else is done: the consent
    /// and the Google token are written by the commands the person runs there.
    func openTerminal(_ action: TerminalAction) -> String? {
        guard let script = TerminalScript.script(for: action, python: env.python(), pipelineDir: env.pipelineDir()) else {
            return tr("This engine has no consent command.", ko: "이 엔진에는 동의 명령이 없어요.")
        }
        do {
            let file = try TerminalScript.write(script, name: TerminalScript.fileName(for: action), in: env.tempDir())
            if env.openTerminal(file) { return nil }
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            return tr("Terminal could not be opened.", ko: "터미널을 열지 못했어요.")
        } catch {
            return tr("The Terminal script could not be written.", ko: "터미널 스크립트를 쓰지 못했어요.")
        }
    }

    func restartPlan() -> RestartPlan { RestartPlan.decide(recording: env.isRecording(), hold: env.restartHold(), bundlePath: env.bundlePath()) }

    /// Relaunches the app when the plan says now; the answer is what happened. The plan is decided again here: a recording may have started since
    /// the button was drawn.
    func restartNow() -> RestartPlan {
        let plan = restartPlan()
        guard plan == .now, let path = env.bundlePath() else { return plan }
        guard env.spawnRestart(path) else { return .unavailable(tr("The relaunch could not be started.", ko: "다시 시작을 실행하지 못했어요.")) }
        Log.info("settings: restarting the app")
        env.terminate()
        return .now
    }
}

// MARK: - The consent line of the Transcription tab

/// What the tab says about the consent of the selected engine, and whether the Terminal button applies. Read-only: the consent is recorded by
/// `python -m mcap asr-engines consent <engine>` in a Terminal, never by this window.
enum ConsentLine {
    static func make(engine: String, states: [String: AsrEngineState]?) -> (text: String, canGrant: Bool) {
        switch engine {
        case "whisper":
            return (tr("Local engine: nothing is sent to a speech service, so no consent is needed.", ko: "로컬 엔진: 음성을 음성 인식 서비스로 보내지 않으므로 동의가 필요 없어요."), false)
        case "auto":
            return (tr("auto: local Whisper when this Mac can run it; otherwise the company server, which has its own consent (menu: Connect to Company Server…).",
                       ko: "auto: 이 Mac이 돌릴 수 있으면 로컬 Whisper, 아니면 회사 서버를 써요. 회사 서버는 자체 동의가 필요해요 (메뉴: Connect to Company Server…)."), false)
        case "remote":
            return (tr("Company server: it is set up from the menu (Connect to Company Server…); its consent comes from your organisation's policy or your own.",
                       ko: "회사 서버: 메뉴(Connect to Company Server…)에서 설정해요. 동의는 조직 정책이나 본인이 해요."), false)
        default:
            guard TerminalAction.consentEngines.contains(engine) else { return ("", false) }
            guard let state = states?[engine] else {
                return (tr("Consent: not known right now (the pipeline could not be asked).", ko: "동의: 지금은 알 수 없어요 (파이프라인에 물어보지 못했어요)."), true)
            }
            let prefix = state.consentOK ? tr("Consent: ", ko: "동의: ") : tr("Consent: none that applies, ", ko: "동의: 해당하는 동의 없음, ")
            return (prefix + state.consent, true)          // a valid consent can be renewed too
        }
    }
}
