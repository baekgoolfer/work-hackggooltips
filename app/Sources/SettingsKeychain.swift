import Foundation

// =====================================================================================
// API keys of the Settings window: written ONLY to the macOS Keychain, in the way the Python side reads them, never into config.env.
//
// Where each secret lives (the same service and account strings as the pipeline, so that Python reads what this wrote):
//   Anthropic API key          service  CLAUDE_KEY_SERVICE (default "MeetingCapture Anthropic API key")    account  <login name>       pipeline/mcap/apikey.py
//   CLOVA / OpenAI-compatible  service  "MeetingCapture ASR <engine>"                                       account  <login name>@<host>:<port>   pipeline/mcap/asr_creds.py
// (host and port come from the SAVED address of the engine: `AsrDestination`, the same reading as asr_providers.split_base).
//
// How a key is written (the method of gcal.write_token): `/usr/bin/security -i` with the command on STDIN and the value hex-encoded (`-X`), so the
// value is in no argument, no environment variable and no file, and no quoting can break it. The tool is the absolute /usr/bin/security (a test
// shim through MCAP_SECURITY_BIN only on a Mac without an organisation policy: ApiKeyItem.securityBinary), with stdout and stderr discarded
// and a minimal environment. The interactive mode does not tell a failed command from a good one, so the item is read back once (`-w`) and
// compared; the value is dropped at once and is never logged, shown or returned. Status and removal never read the value.
//
// Swift cannot wipe a String: the typed key stays in memory until it is overwritten by the allocator. The window clears the field right after the
// call. See docs/SETTINGS.md.
// =====================================================================================

struct KeychainItem: Equatable {
    var service: String
    var account: String
}

enum SecretKind: Equatable { case anthropicKey, engineKey }

/// Which Keychain item a secret field of the window means.
enum SecretSlot: Equatable {
    case claude, clova, openAICompat

    var kind: SecretKind { self == .claude ? .anthropicKey : .engineKey }
    var engine: String? {
        switch self {
        case .claude: return nil
        case .clova: return "clova"
        case .openAICompat: return "openai-compat"
        }
    }
    /// The config.env key whose SAVED value names the destination (an unsaved edit of it must not be used: the item is bound to what the pipeline reads).
    var addressKey: String? {
        switch self {
        case .claude: return nil
        case .clova: return "ASR_CLOVA_INVOKE_URL"
        case .openAICompat: return "ASR_OPENAI_COMPAT_URL"
        }
    }

    /// `effective`: the layered config.env values (SettingsSnapshot.effective). `user`: the login name the pipeline sees in USER.
    func item(effective: [String: String], user: String) -> Result<KeychainItem, SettingsError> {
        switch self {
        case .claude:
            let configured = (effective["CLAUDE_KEY_SERVICE"] ?? "").trimmingCharacters(in: .whitespaces)
            return .success(KeychainItem(service: configured.isEmpty ? AppConfig.defaults().claudeKeychainService : configured, account: user))
        case .clova, .openAICompat:
            guard let engine = engine, let key = addressKey, let dest = AsrDestination.parse(effective[key] ?? "", engine: engine) else {
                return .failure(SettingsError(message: tr("Enter a valid address above and save it first: the key is stored for that server.", ko: "위에 올바른 주소를 입력하고 먼저 저장하세요: 키는 그 서버용으로 저장돼요.")))
            }
            return .success(KeychainItem(service: AsrDestination.service(engine: engine), account: dest.keychainAccount(user: user)))
        }
    }
}

enum KeyStatus: Equatable {
    case stored, notStored, unknown

    var text: String {
        switch self {
        case .stored: return tr("Stored in Keychain", ko: "키체인에 저장됨")
        case .notStored: return tr("Not stored", ko: "저장 안 됨")
        case .unknown: return tr("Could not check the Keychain", ko: "키체인을 확인하지 못했어요")
        }
    }
}

enum KeychainOutcome: Equatable {
    case ok
    case refused(String)       // nothing was run: the value or the names are not acceptable
    case failed(String)

    var message: String? {
        switch self {
        case .ok: return nil
        case .refused(let m), .failed(let m): return m
        }
    }
}

/// What the `security` tool did. `stdout` is only filled when the caller asked to capture it (the read-back).
struct SecurityRunResult: Equatable {
    var launched: Bool
    var status: Int32
    var stdout: Data = Data()
    var timedOut: Bool = false
}

typealias SecurityRunner = (_ arguments: [String], _ stdin: Data?, _ captureOutput: Bool) -> SecurityRunResult

struct SettingsKeychain {
    static let readTimeout: TimeInterval = 10                 // apikey.READ_TIMEOUT_S
    static let maxCommandBytes = 3000                         // gcal.MAX_COMMAND_BYTES
    static let maxSecretChars = 512                           // asr_creds.MAX_SECRET_CHARS
    static let anthropicPrefix = "sk-ant-"

    var run: SecurityRunner

    init(run: @escaping SecurityRunner) { self.run = run }

    /// The real tool: /usr/bin/security (or the test shim of ApiKeyItem.securityBinary on a Mac without a policy).
    init(securityBin: URL = ApiKeyItem.securityBinary()) {
        self.run = { arguments, stdin, capture in SettingsKeychain.runTool(securityBin, arguments, stdin: stdin, capture: capture) }
    }

    // MARK: Pure pieces

    /// What may sit inside the double quotes of a `security -i` command (gcal._QUOTE_SAFE).
    static func isQuoteSafe(_ text: String) -> Bool {
        return !text.isEmpty && !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\"" || $0 == "\\" }
    }

    /// Why a secret is not acceptable (a fixed sentence, never the value), or nil. The rules of the Python readers: one printable token without a blank
    /// (asr_creds._checked: 33...126, at most 512), and for the Anthropic key the prefix apikey.usable_key requires.
    static func problem(with secret: String, kind: SecretKind) -> String? {
        if secret.isEmpty { return tr("Enter the key first.", ko: "먼저 키를 입력하세요.") }
        if secret.count > maxSecretChars || !secret.unicodeScalars.allSatisfy({ (33..<127).contains($0.value) }) {
            return tr("A key is one printable token without spaces or line breaks (at most 512 characters). Paste it again.", ko: "키는 공백이나 줄바꿈 없는 한 덩어리의 출력 가능한 문자열이에요 (512자 이하). 다시 붙여 넣으세요.")
        }
        if kind == .anthropicKey, !secret.hasPrefix(anthropicPrefix) {
            return tr("An Anthropic API key starts with sk-ant- (Console > Settings > API keys).", ko: "Anthropic API 키는 sk-ant-로 시작해요 (Console > Settings > API keys).")
        }
        return nil
    }

    /// The one line sent to `security -i`; nil when a name cannot sit inside the quotes or the line would be long.
    static func addCommand(item: KeychainItem, secret: String) -> String? {
        guard isQuoteSafe(item.account), isQuoteSafe(item.service) else { return nil }
        let hex = secret.utf8.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(item.account)\" -s \"\(item.service)\" -X \(hex)\n"
        return command.utf8.count <= maxCommandBytes ? command : nil
    }

    static func existenceArguments(_ item: KeychainItem) -> [String]? {
        return ApiKeyItem.existenceArguments(service: item.service, account: item.account)
    }

    static func deleteArguments(_ item: KeychainItem) -> [String]? {
        guard let find = existenceArguments(item) else { return nil }
        return ["delete-generic-password"] + find.dropFirst()
    }

    static func readArguments(_ item: KeychainItem) -> [String]? {
        guard let find = existenceArguments(item) else { return nil }
        return find + ["-w"]
    }

    // MARK: Actions

    func status(_ item: KeychainItem) -> KeyStatus {
        guard let args = Self.existenceArguments(item) else { return .unknown }
        let r = run(args, nil, false)
        guard r.launched, !r.timedOut else { return .unknown }
        if r.status == 0 { return .stored }
        return r.status == ApiKeyItem.itemNotFoundStatus ? .notStored : .unknown
    }

    func store(secret: String, kind: SecretKind, item: KeychainItem) -> KeychainOutcome {
        if let why = Self.problem(with: secret, kind: kind) { return .refused(why) }
        guard let command = Self.addCommand(item: item, secret: secret), let readBack = Self.readArguments(item) else {
            return .refused(tr("The Keychain item name cannot be used.", ko: "키체인 항목 이름을 쓸 수 없어요."))
        }
        let write = run(["-i"], Data(command.utf8), false)
        guard write.launched, !write.timedOut else { return .failed(tr("The Keychain tool could not be run.", ko: "키체인 도구를 실행하지 못했어요.")) }
        guard write.status == 0 else { return .failed(tr("The Keychain tool refused to store the key.", ko: "키체인 도구가 키 저장을 거부했어요.")) }
        // `security -i` does not report a failed command: read the item back once and compare (the value is dropped at once).
        let read = run(readBack, nil, true)
        guard read.launched, read.status == 0, Self.sameSecret(read.stdout, secret) else {
            return .failed(tr("The key could not be confirmed in the Keychain.", ko: "키체인에서 키를 확인하지 못했어요."))
        }
        return .ok
    }

    /// `security ... -w` prints the value and a newline; data it takes for binary comes as hex.
    static func sameSecret(_ output: Data, _ secret: String) -> Bool {
        let text = (String(data: output, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text == secret { return true }
        let hex = secret.utf8.map { String(format: "%02x", $0) }.joined()
        return text.lowercased() == hex
    }

    func remove(_ item: KeychainItem) -> KeychainOutcome {
        guard let args = Self.deleteArguments(item) else { return .refused(tr("The Keychain item name cannot be used.", ko: "키체인 항목 이름을 쓸 수 없어요.")) }
        let r = run(args, nil, false)
        guard r.launched, !r.timedOut else { return .failed(tr("The Keychain tool could not be run.", ko: "키체인 도구를 실행하지 못했어요.")) }
        if r.status == 0 || r.status == ApiKeyItem.itemNotFoundStatus { return .ok }
        return .failed(tr("The Keychain tool did not remove the key.", ko: "키체인 도구가 키를 지우지 못했어요."))
    }

    // MARK: The process

    /// A minimal environment (apikey._security_env), stdin from a pipe only when there is something to send, stdout only when it is wanted.
    static func runTool(_ bin: URL, _ arguments: [String], stdin: Data?, capture: Bool, timeout: TimeInterval = readTimeout) -> SecurityRunResult {
        let process = Process()
        process.executableURL = bin
        process.arguments = arguments
        process.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let input = Pipe(), output = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        process.standardOutput = capture ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return SecurityRunResult(launched: false, status: -1) }
        if let data = stdin {
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)      // a tool that exits without reading must not kill the app
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
        }
        final class Box {
            private let lock = NSLock()
            private var data = Data()
            private var stopped = false
            func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
            func stop() { lock.lock(); stopped = true; lock.unlock() }
            var value: Data { lock.lock(); defer { lock.unlock() }; return data }
            var wasStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        }
        let box = Box()
        let reading = DispatchGroup()
        if capture {
            reading.enter()
            DispatchQueue.global().async {
                box.set(output.fileHandleForReading.readDataToEndOfFile())
                reading.leave()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            box.stop()
            process.terminate()
        }
        process.waitUntilExit()
        if capture { _ = reading.wait(timeout: .now() + 5) }
        return SecurityRunResult(launched: true, status: process.terminationStatus, stdout: capture ? box.value : Data(), timedOut: box.wasStopped)
    }
}
