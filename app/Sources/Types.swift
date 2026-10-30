import Foundation

// =====================================================================================
// Shared contracts for all Swift components.
// Do NOT change existing signatures without updating SPEC.md section 12.
// Additive changes (new fields with defaults) are fine.
// =====================================================================================

// MARK: - Platforms & detection

enum Platform: String, Codable, CaseIterable {
    case meet, zoom, teams, manual
    /// Every other call (additive, docs/DETECTION.md section 3b): a known native app (Slack huddle, Webex, ...), a browser meeting page (Whereby, Jitsi,
    /// ...) or an app the generic rule took for a call. The label is the app's: `PlatformSignal.displayLabel` / session.json `platform_label`.
    case call

    var label: String {
        switch self {
        case .meet: return "Google Meet"
        case .zoom: return "Zoom"
        case .teams: return "Microsoft Teams"
        case .manual: return "Manual"
        case .call: return "Call"
        }
    }
}

enum Confidence: String, Codable { case high, low }

/// What named the app of a `.call` signal (docs/DETECTION.md section 3b). Written into session.json as `call_kind`.
enum CallKind: String, Codable, Equatable {
    case known      // the built-in table of call apps
    case extra      // EXTRA_MEETING_APPS
    case generic    // CALL_DETECT=generic: any GUI app that held the microphone and played sound for CALL_GENERIC_SECONDS
    case web        // a browser tab with a meeting URL of the table (Whereby, Jitsi, Webex web, Teams web, Zoom web client)
}

/// One platform's verdict for one poll.
struct PlatformSignal: Codable {
    var platform: Platform
    var inCall: Bool
    var confidence: Confidence = .high
    var titleHint: String? = nil      // window / tab title if known
    var meetingURL: String? = nil     // e.g. https://meet.google.com/abc-defg-hij
    var meetingKey: String? = nil     // e.g. Meet code "abc-defg-hij"; used to split back-to-back meetings
    var bundleID: String? = nil       // app that owns the call (e.g. com.google.Chrome)
    var evidence: [String] = []       // human-readable reasons, printed by `probe` and logged on transitions
    // Additive (platform .call only; nil for every other platform):
    var appName: String? = nil        // display name of the call app ("Slack huddle"), one line, at most 40 characters
    var callKind: CallKind? = nil
}

extension PlatformSignal {
    /// The words for this signal in notifications, the menu and session.json `platform_label`: the app's name for a call, else the platform's label.
    var displayLabel: String {
        guard platform == .call, let name = appName, !name.isEmpty else { return platform.label }
        return name
    }
}

struct DetectionSnapshot: Codable {
    var time: Date
    var signals: [PlatformSignal]     // one entry per enabled platform (inCall may be false)

    /// Preferred active signal: high confidence first, then enabled order.
    var best: PlatformSignal? {
        let active = signals.filter { $0.inCall }
        return active.first(where: { $0.confidence == .high }) ?? active.first
    }
}

protocol MeetingDetecting: AnyObject {
    /// Blocking. Call from a background queue. Must never throw or hang (internal timeouts for AppleScript etc.).
    func poll() -> DetectionSnapshot
}

enum EndReason: String, Codable {
    case meetingEnded = "meeting-ended"
    case manual
    case paused
    case appQuit = "app-quit"
    case sleep
    case diskLow = "disk-low"
    case maxDuration = "max-duration"
    case crashRecovered = "crash-recovered"
}

/// Output of `DetectionStateMachine.step` (the struct itself lives in DetectionStateMachine.swift):
///
///     struct DetectionStateMachine {
///         init(startDebounce: TimeInterval, grace: TimeInterval)
///         var isRecording: Bool { get }     // state == recording (incl. grace period)
///         var isCandidate: Bool { get }     // inCall seen but still debouncing  -> menu "Meeting detected"
///         mutating func step(now: Date, snapshot: DetectionSnapshot) -> StateAction
///         mutating func reset()             // call after manual stop / pause / app-initiated stop
///         mutating func adoptManualRecording()  // user pressed Start Recording Now: machine tracks it as recording w/o auto-stop
///     }
enum StateAction {
    case none
    case start(PlatformSignal)      // begin a new session
    case split(PlatformSignal)      // Meet code changed and stayed changed: stop current session, start a new one
    case stop(EndReason)            // end the current session (grace elapsed)
}

// MARK: - Recording

struct RecorderSummary {
    var sessionID: String
    var sessionDir: URL
    var durationSec: Double
    var micSeconds: Double          // seconds of audio written to mic.wav
    var remoteSeconds: Double       // seconds of audio written to remote.wav
    var warnings: [String]
}

enum RecorderError: Error, CustomStringConvertible {
    case permissionDenied(String)
    case deviceUnavailable(String)
    case failed(String)
    var description: String {
        switch self {
        case .permissionDenied(let s): return "permission denied: \(s)"
        case .deviceUnavailable(let s): return "device unavailable: \(s)"
        case .failed(let s): return "recorder failed: \(s)"
        }
    }
}

/// Implemented by `final class Recorder: SessionRecording` in Recorder.swift:
///     init(sessionDir: URL, signal: PlatformSignal, config: AppConfig)
/// Writes session.json (end_time=null) at start() and rewrites it at stop() (SPEC section 4.1).
protocol SessionRecording: AnyObject {
    var isRecording: Bool { get }
    var startedAt: Date { get }
    /// Called (any queue) for non-fatal problems: silent remote track, device change, disk low, etc.
    var onWarning: ((String) -> Void)? { get set }
    /// Starts both tracks. Throws RecorderError. If only one track can start (e.g. no mic permission) it MAY continue with the
    /// other and report through onWarning, but must throw if neither track can start.
    func start() throws
    /// Idempotent. Finalizes WAV headers, rewrites session.json with end_time/end_reason, returns summary.
    func stop(reason: EndReason) -> RecorderSummary
    /// Update metadata learned after start (e.g. tab title). Persisted into session.json at stop().
    func updateMeta(titleHint: String?, meetingURL: String?)
    /// Recent RMS level in dBFS (about last 5 s) per track, for diagnostics / "no audio" warnings. -120 = silence/no data.
    var recentLevelsDB: (mic: Float, remote: Float) { get }
}

// MARK: - Config (parsed from config.env; parsing lives in Config.swift as `extension AppConfig { static func load() -> AppConfig }`)

enum SystemAudioMode: String { case global, app }

/// Language of the app's own texts (notifications, menu hints, dialogs): UI_LANGUAGE=en|ko in config.env, English by default.
/// The Korean texts are kept word for word: an install that sets UI_LANGUAGE=ko sees what it always saw.
enum UILanguage: String { case en, ko }

enum L10n {
    /// Set once at start from the configuration (`AppConfig.load()`); the self tests set it explicitly. Read at the moment a text is built.
    static var current: UILanguage = .en
}

/// The text in the UI language: `en` by default, `ko` when UI_LANGUAGE=ko.
func tr(_ en: String, ko: String) -> String { L10n.current == .ko ? ko : en }

/// How the pipeline's `claude -p` calls are billed (SPEC 17). `subscription` = your own claude.ai login; `api` = an API key kept in the
/// macOS Keychain (billed per token to your Console account). The key itself never passes through the Swift app: the Python pipeline reads it from the Keychain.
enum ClaudeAuthMode: String { case subscription, api }

struct AppConfig {
    var supportDir: URL
    var archiveDir: URL
    var projectDir: URL
    var pythonBin: URL
    var claudeBin: URL
    var selfName: String = "Me"
    var enabledPlatforms: [Platform] = [.zoom, .teams]   // Meet is opt-in (needs the Chrome automation permission, least verified platform); add 'meet' to ENABLED_PLATFORMS to enable
    var browserBundleIDs: [String] = ["com.google.Chrome"]
    var pollInterval: TimeInterval = 2
    var startDebounce: TimeInterval = 4
    var grace: TimeInterval = 20
    var minRecordingSeconds: TimeInterval = 30
    var maxRecordingHours: Double = 6
    var minFreeDiskGB: Double = 5
    var systemAudioMode: SystemAudioMode = .global
    var claudeAuth: ClaudeAuthMode = .api            // CLAUDE_AUTH in config.env (default api: a Console key is the supported path)
    var uiLanguage: UILanguage = .en       // UI_LANGUAGE: language of notifications, menu hints and dialogs
    var claudeKeychainService: String = "MeetingCapture Anthropic API key"   // CLAUDE_KEY_SERVICE (generic-password item, account = $USER)
    var notifyRecording: Bool = true       // NOTIFY_RECORDING: post a notification when a recording starts / ends (the menu-bar icon can be hidden by the notch or menu-bar managers)
    var noSpeechStopMinutes: Double = 15   // auto-stop an AUTO recording when both tracks stay silent this long (0 = off)
    var retrySweepHours: Double = 6        // how often the app runs 'mcap reprocess --pending' while failed retryable sessions exist (0 = off)

    var sessionsDir: URL { supportDir.appendingPathComponent("sessions", isDirectory: true) }
    var logDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MeetingCapture", isDirectory: true) }
    var configFile: URL { supportDir.appendingPathComponent("config.env") }

    static var defaultSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeetingCapture", isDirectory: true)
    }

    /// Built-in defaults matching SPEC section 3 (used when config.env is missing keys).
    static func defaults() -> AppConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = defaultSupportDir
        return AppConfig(
            supportDir: support,
            archiveDir: home.appendingPathComponent("Meetings", isDirectory: true),     // a plain local folder; a Google Drive folder is set with ARCHIVE_DIR
            projectDir: home.appendingPathComponent("Developer/meeting-capture", isDirectory: true),
            pythonBin: support.appendingPathComponent("venv/bin/python"),
            claudeBin: home.appendingPathComponent(".local/bin/claude")
        )
    }
}

// MARK: - Logging (thread-safe; appends to LOG_DIR/app.log; echoes to stderr when MC_LOG_STDERR=1 or running a CLI subcommand)

enum Log {
    private static let queue = DispatchQueue(label: "\(AppInfo.bundleID).log")
    static var echoToStderr: Bool = ProcessInfo.processInfo.environment["MC_LOG_STDERR"] == "1"
    static var fileURL: URL = AppConfig.defaults().logDir.appendingPathComponent("app.log")

    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func info(_ message: @autoclosure () -> String) { write("INFO", message()) }
    static func warn(_ message: @autoclosure () -> String) { write("WARN", message()) }
    static func error(_ message: @autoclosure () -> String) { write("ERROR", message()) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(fmt.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            }
        }
    }

    /// Block until queued lines are flushed (call before exit in CLI modes).
    static func flush() { queue.sync {} }
}


// MARK: - Launch guard (permission prompts / AppleScript must only ever be raised by the signed app itself)

enum LaunchGuard {
    /// The identifier of the app bundle (AppInfo.bundleID: Info.plist, else the default). A bare binary has no bundle identifier at all, so it is never a
    /// signed app launch whatever id this build carries.
    static var bundleID: String { AppInfo.bundleID }

    /// True only when running from the signed app bundle AND launched by launchd / LaunchServices
    /// (LaunchAgent, `open -a`, `open -n -a`), not when the in-bundle binary is exec'd from a shell:
    /// a shell exec would make macOS attribute any permission prompt to the parent app (Terminal, Claude.app).
    /// `open`-launched apps have ppid == 1 and __CFBundleIdentifier == their own bundle id; a shell exec does not.
    static var isSignedAppLaunch: Bool {
        guard Bundle.main.bundleIdentifier == bundleID else { return false }
        if getppid() == 1 { return true }
        return ProcessInfo.processInfo.environment["__CFBundleIdentifier"] == bundleID
    }
}
