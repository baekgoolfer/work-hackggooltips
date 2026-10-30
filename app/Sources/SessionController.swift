import Foundation

// =====================================================================================
// SessionController: the brain of the menu-bar app.
//
//   detector.poll() --> DetectionStateMachine --> StateAction --> Recorder start/stop/split
//                                                                      |
//                                                    stop --> pipeline.enqueue(session dir)
//
// Everything is injected (detector, recorder factory, pipeline, clock, free-disk probe) so the whole
// behaviour can be exercised device-free by `selftest-session` with fakes and a virtual clock.
//
// Threading: all mutable state lives on `queue` (serial). The detector is polled OUTSIDE that queue
// (poll() may block for seconds on AppleScript), then the snapshot is processed on `queue`.
// UI callbacks are delivered through `deliver` (main queue by default).
//
// Calendar auto-start (CalendarWatcher.swift, OFFLINE_AUTOSTART=auto, off by default): the watcher calls `startRecordingFromCalendar`, which takes
// the same path as the menu item 'Start Recording Now' (platform manual, the machine adopts it, so the detector never stops it) and remembers the
// event id; `stopRecordingFromCalendar` ends it when the event is over; `onCalendarRecordingEnded` tells the watcher when such a recording ended
// for any reason (a click on 'Stop Recording Now' means: this event is not recorded again). The no-speech rule keeps applying to it.
//
// SPEC 18 (organisation policy, per-meeting local-only flag): the controller writes the start value of
// the flag into every real recording (`SessionRecordingPrivacy`, before start()), owns the menu toggle during and after the recording
// (`toggleLocalOnly`), refuses to record when the policy switches recording off and ends a running recording within one policy poll (60 s),
// and tells the user what is true: notifications without a meeting title for a local-only meeting, a transcript-ready text when no note is
// made, a quiet waiting text when the transcription server cannot be reached. Without a policy and with the flag off (the personal install)
// nothing visible changes. Nothing here opens a socket, starts `claude` or reads the Keychain.
//
// SPEC 18 (microphone mute gate): `MIC_MUTE_GATE=on` (config.env, or forced by the company baseline through
// PolicyLayers) is handed to every real recording before start() (`SessionRecordingMicGate.configureMuteGate`); the recorder does the work
// (MuteGate.swift). The controller owns the manual path, the menu item 'Pause Microphone' (`toggleMicrophonePause`): the one way to stop
// the microphone that does not depend on a signal of the meeting app. With the gate off (the personal install) there is no item and nothing
// changes.
// =====================================================================================

// MARK: - Status published to the menu

enum SessionStatus: Equatable {
    case idle
    case candidate(Platform)
    case recording(Platform, since: Date)
    case processing(String)          // stage text, e.g. "Transcribing remote 12/48"
    case done(String)                // meeting title
    case error(String)               // actionable one-liner
}

/// Why a relaunch of the app would undo something although nothing is recording right now: these facts live in the controller's memory only, so the new
/// process would start recording the still-running call again (the Settings window's restart waits for them to end, SettingsBackend.swift `RestartPlan`).
enum RestartHold: Equatable {
    case paused          // "Pause Auto Recording" is on
    case stoppedCall     // the person stopped this call by hand, or the no-speech rule ended it, and it is still running
    case callLive        // a call was just detected and the recording starts after the debounce
}

/// Everything the menu needs in one value (delivered on the main queue whenever it changes).
struct ControllerState: Equatable {
    var status: SessionStatus = .idle
    var paused = false               // "Pause Auto Recording" is on
    var installHold = false          // the app installer has not finished (FirstRun.holdsRecording): nothing is detected and no recording can start, by hand or by calendar
    var manualRecording = false      // the active recording was started with "Start Recording Now"
    var calendarRecording = false    // the active recording was started by the calendar auto-start (it is a manual-path recording too)
    var warning: String? = nil       // latest non-fatal recorder warning for the active recording
    var autoDetectionOff = false     // ENABLED_PLATFORMS is empty: nothing is detected, only "Start Recording Now" works
    var remoteSilentSuspected = false // the active recording's remote (system audio) track looks silent: the other side may be missing
    var notice: String? = nil        // a standing message after the fact (auto-stopped for no speech, remote audio was silent), shown for a while
    // SPEC 18 (additive, SPEC 18):
    var localOnly: LocalOnlyView? = nil          // the "Local-Only Meeting" menu item; nil = the controller has not computed it yet
    var infoLines: [String] = []                 // EffectiveLanes.idleLinesText: what is true for the next meeting (shown while idle)
    var recordingBlockedByPolicy = false         // policy.recording.enabled == false: no recording starts, an active one was ended
    // SPEC 18, microphone gate:
    var micGate: MicGateView? = nil              // the 'Pause Microphone' item; nil = MIC_MUTE_GATE is off (no item at all)
    // Calls of other apps (docs/DETECTION.md section 3b, additive):
    var callApp: CallAppView? = nil              // the app of the active recording / of the meeting detected, when its platform is `call`
    // The Settings window's restart (additive):
    var restartHold: RestartHold? = nil          // what a relaunch would undo while nothing records; nil = a relaunch loses nothing
}

/// The app behind a `call` status: what the menu says ("Recording Slack huddle") and what 'Never record <App>' acts on.
struct CallAppView: Equatable {
    var name: String
    var bundleID: String
    var generic: Bool            // the generic rule guessed it (CALL_DETECT=generic): the menu's 'Never record <App>' says so (it is offered for every call app)
    var key: String = ""         // what call-apps.json is keyed by: the main bundle id (lower case), or `web:<site>` for a meeting page; empty = use bundleID
}

extension CallAppView {
    /// The key of the decision this app is stored under.
    var decisionKey: String { (key.isEmpty ? bundleID : key).lowercased() }

    init(signal: PlatformSignal, name: String) {
        self.init(name: name, bundleID: signal.bundleID ?? "", generic: signal.callKind == .generic, key: signal.meetingKey ?? signal.bundleID ?? "")
    }
}

/// What the 'Pause Microphone' menu item needs: the gate is on for this install, a recording that can be paused is running, and whether the
/// microphone is paused now.
struct MicGateView: Equatable {
    var recording: Bool
    var paused: Bool
}

/// What `toggleMicrophonePause` did. `.notAvailable` = the gate is off, the recorder has no gate or did not accept it.
enum MicPauseResult: Equatable {
    case applied(paused: Bool)
    case notAvailable
    case noRecording
}

/// What the "Local-Only Meeting" menu item needs: the value of the target meeting, whether the policy locks it, which
/// session a click would change (nil = none: nothing is recording and no recent session can still take it), whether OFF is still possible
/// and whether the pipeline is too old to honour the value a click would set.
struct LocalOnlyView: Equatable {
    var value: Bool
    var locked: Bool
    var targetSession: String?
    var canRelax: Bool
    var pipelineTooOld: Bool
}

/// What `toggleLocalOnly` did. `.writeFailed` is an addition: the session file could not be written.
enum LocalOnlyToggleResult: Equatable {
    case applied(LocalOnlyValue)
    case appliedMaybeLate              // written, but the processing was already at or past publishing: it may not have taken effect
    case refusedLocked                 // the policy keeps the flag on
    case noTarget                      // nothing is recording and no recent session is in staging
    case tooLate                       // the session is past the point where the flag can still change (state.json, stage)
    case pipelineTooOld                // the pipeline could not honour the value (SPEC 18 contract)
    case writeFailed(String)
}

/// The launcher did not start the pipeline: the session stays in staging as it was and no attempt is counted.
enum PipelineBlock: Equatable {
    case pipelineTooOld(have: String?, required: String)
    case runtimeUntrusted(String)

    /// English, for app.log and the menu error line (no meeting content).
    var logText: String {
        switch self {
        case .pipelineTooOld(let have, let required): return "pipeline \(have ?? "of unknown version") is older than the required \(required)"
        case .runtimeUntrusted(let why): return "runtime is not trusted (\(why))"
        }
    }

    /// A stable key for the notification throttle.
    var key: String {
        switch self {
        case .pipelineTooOld: return "pipeline-too-old"
        case .runtimeUntrusted: return "runtime-untrusted"
        }
    }
}

/// The policy of this Mac as the running app knows it: the controller's watcher replaces it when the file changes, the launcher and the
/// menu read it. Thread-safe.
final class PolicyBox {
    private let lock = NSLock()
    private var current: OrgPolicy

    init(_ policy: OrgPolicy) { current = policy }

    var policy: OrgPolicy {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}


// MARK: - Calendar auto-start (the controller's side)

/// What `SessionController.startRecordingFromCalendar` did. Only `.started` changes anything.
enum CalendarStartResult: Equatable {
    case started
    case alreadyRecording          // a recording of any platform is running
    case paused                    // 'Pause Auto Recording' is on: an automatic start is not wanted
    case held                      // the app installer has not finished (setInstallHold): no start until it has; the event is not marked as handled
    case blocked(String)           // the organisation policy switched recording off (English, no content)
    case failed(String)            // the recorder could not start (an actionable one-liner, no content)
    case shutDown
}

/// A recording that the calendar auto-start began has ended. `label` is the controller's own name of the cause when `reason` is too coarse
/// ("calendar-end", "no-speech", "policy-kill-switch").
struct CalendarRecordingEnd: Equatable {
    var eventID: String
    var reason: EndReason
    var label: String?
}

// MARK: - Pipeline abstraction (implemented by PipelineLauncher; faked in selftest-session)

enum PipelineEvent {
    case progress(session: String, text: String)
    case finished(session: String, title: String?, finalDir: URL?, discarded: Bool)
    case failed(session: String, message: String)
    /// A job ended well but has nothing to show (a retry sweep that found nothing, or only failed sessions that now work):
    /// clears its progress text and an earlier error of the same name; no "done" line, no notification.
    case nothingToReport(session: String)
    /// The launcher refused to start the pipeline: too old for the policy / the local-only flag, or a runtime that is
    /// not the root-owned one. Nothing ran and nothing was written: the session is in staging as it was.
    case blocked(session: String, reason: PipelineBlock)
}

/// What the pipeline left behind for one session, read-only from state.json / session.json by the launcher (the texts of the
/// "note ready" / "processing failed" notifications and where a click on them goes). Nothing here is ever written by the app.
struct PipelineOutcome: Equatable {
    var platform: Platform? = nil          // session.json "platform"
    var durationSeconds: Double? = nil     // session.json end_time - start_time
    var folder: URL? = nil                 // final_dir (when it exists), else the staging session folder (when it exists)
    var errorKind: String? = nil           // state.json error_kind
    var retryable: Bool? = nil             // state.json retryable
    var resetsAt: Date? = nil              // state.json resets_at (usage limit)
    var logFile: URL? = nil                // the job's pipeline log
    var localOnly: Bool? = nil             // state.json "local_only" (SPEC 18; written by Python, only read here)
    var lanesSkipped: [String] = []        // state.json "lanes": the lanes whose value starts with "skipped" (e.g. ["llm", "calendar", "drive"])
}

protocol PipelineRunning: AnyObject {
    /// Set once by the controller. Called on an arbitrary queue.
    var onEvent: ((PipelineEvent) -> Void)? { get set }
    /// Queue a session folder for `mcap process`. Never blocks; duplicates are ignored.
    func enqueue(_ sessionDir: URL)
    /// Queue `mcap reprocess --last`.
    func reprocessLast()
    /// Queue `mcap reprocess --pending` (the retry sweep: every failed session with retryable=true). Duplicates are ignored.
    func reprocessPending()
    /// True while this session folder is queued or running in the launcher (the sweep must not queue it again).
    func isProcessing(_ sessionDir: URL) -> Bool
    /// The Mac woke from sleep: re-arm the stall watchdog (a job that was suspended with the machine is not stalled).
    func systemDidWake()
    /// Folder for the "Open Meeting Folder" menu item. May do file I/O: call off the main thread.
    func lastMeetingFolder() -> URL?
    /// App is quitting: stop the child process (state is re-entrant, the next launch resumes it).
    func shutdown()
    /// What the launcher read for this session just before it reported its end (finished / failed); nil when it has nothing.
    /// No file I/O (the launcher did that on its own queue).
    func outcome(forSession session: String) -> PipelineOutcome?
    /// The pipeline version (`python -m mcap --version`) as far as the launcher knows it, nil = not known (yet). Never starts a process:
    /// the menu asks it on every published state.
    var pipelineVersion: String? { get }
    /// Asks the launcher to find out the pipeline version in the background (one `python -m mcap --version`, about 0.1 s; never an
    /// untrusted python; once per launch of the app unless a launch refreshed it). Returns at once. The controller calls it when the
    /// toggle needs a version that is not known yet: an unknown version is NOT taken as 'new enough' (SPEC 18: an old pipeline never
    /// re-reads session.json, so 'local-only ON' would be a false assurance), so the menu waits for the answer.
    func probePipelineVersion()
    /// Called (on any queue) when a version answer arrived, so that the menu can be computed again. Set once by the controller.
    var onVersionKnown: (() -> Void)? { get set }
}

extension PipelineRunning {
    func outcome(forSession session: String) -> PipelineOutcome? { nil }
    var pipelineVersion: String? { nil }
    func probePipelineVersion() {}
    var onVersionKnown: (() -> Void)? { get { nil } set {} }
}

// MARK: - Small shared helpers (kept in a namespace to avoid clashing with other files)

enum ShellUtil {
    private static let sessionIDFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return f
    }()
    private static let isoOutFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"      // "+09:00" also for UTC ("+00:00"), never "Z"
        return f
    }()

    /// "2026-10-07_1400_meet" (local time). Collision suffixes are added by the caller.
    static func sessionIDBase(at date: Date, platform: Platform) -> String {
        return "\(sessionIDFormatter.string(from: date))_\(platform.rawValue)"
    }

    static func iso8601(_ date: Date) -> String { isoOutFormatter.string(from: date) }

    static func parseISO8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: text)
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Atomic replace (write temp + rename) so a crash mid-write never leaves a truncated session.json.
    static func writeJSONAtomically(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Free space (GiB, conservative) on the volume that holds `url` (or its nearest existing parent).
    static func freeDiskGB(near url: URL) -> Double? {
        var target = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        guard let values = try? target.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                .volumeAvailableCapacityKey]) else { return nil }
        let bytes: Int64?
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            bytes = important
        } else if let raw = values.volumeAvailableCapacity {
            bytes = Int64(raw)
        } else {
            bytes = nil
        }
        guard let b = bytes else { return nil }
        return Double(b) / 1_073_741_824.0
    }

    /// LOG_DIR, or $MCAP_LOG_DIR when set (test hook: keeps self-test and probe runs out of the real logs).
    static func logDir(for config: AppConfig) -> URL {
        if let d = ProcessInfo.processInfo.environment["MCAP_LOG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        return config.logDir
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        return a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

// MARK: - SessionController

final class SessionController {
    typealias RecorderFactory = (URL, PlatformSignal) -> SessionRecording

    /// An AUTO-detected session shorter than this that ended by meeting-ended / sleep / app-quit is an accidental
    /// blip and is deleted (effective limit = min(10, MIN_RECORDING_SECONDS); 0 disables deletion). Manual recordings
    /// and every other stop reason are always kept: the pipeline discards no-speech sessions itself.
    static let blipSeconds: TimeInterval = 10
    /// Delays before the same meeting is retried after a failed Recorder.start(): escalating, the last value repeats.
    /// A transient failure (Bluetooth profile switch, device busy at call start) costs seconds, not minutes.
    static let startRetrySchedule: [TimeInterval] = [10, 30, 60, 300]
    /// Long lockout for failures that will not fix themselves in seconds: permission denied, disk full.
    static let startLockoutSeconds: TimeInterval = 300
    /// A start-failure record is forgotten when the meeting has not been retried for this long after its lockout.
    static let startFailureMemorySeconds: TimeInterval = 900
    static let diskCheckSeconds: TimeInterval = 30
    static let doneDisplaySeconds: TimeInterval = 10
    /// SPEC 14.4: a session whose end_time is null and whose WAV was written within this long is a LIVE recording (or a
    /// crash a moment ago): the startup scan never touches it, and looks again once the window has passed.
    static let liveRecordingWindow: TimeInterval = 120
    /// The scan re-checks a session it skipped as "maybe live" at most this many times.
    static let maxLiveRescans = 3
    /// state.json error_kind values of a failed STAGING session that the startup scan retries once per app launch (with
    /// retryable == true): the archive was not reachable, the ASR run failed, or the transcription server
    /// could not be reached (asr_unreachable, SPEC 18: a waiting kind, Python does not count it as an attempt). Everything else
    /// that failed (audio problems, bugs, non-retryable states) is never retried automatically; in particular asr_policy_blocked and
    /// local_archive_unsafe (SPEC 18) stay as they are until the policy or the setting changes and the user reprocesses by hand.
    static let retryableFailureKinds: Set<String> = ["archive_unavailable", "asr_failed", "asr_unreachable"]

    /// SPEC 15, no-speech auto-stop: both tracks below this level (5 s RMS, dBFS) for NO_SPEECH_STOP_MINUTES. A muted microphone is
    /// normal in a call, so it takes BOTH tracks; a mic with a noise floor above this keeps the recording going (MAX_RECORDING_HOURS
    /// stays the backstop).
    static let noSpeechThresholdDB: Float = -70
    /// How long the "auto-stopped / remote silent" notice stays in the menu after the recording ended.
    static let noticeSeconds: TimeInterval = 2 * 3600

    /// Retry sweep (SPEC 15): the first sweep runs this long after launch (Google Drive may still be mounting after a login) and
    /// this long after a wake from sleep (the network is not back yet).
    static let sweepSettleSeconds: TimeInterval = 120
    /// A session the sweep re-enqueued (interrupted, never finished) at most this many times per app launch.
    static let maxSweepEnqueues = 3
    /// state.json `attempts` (failed runs, written by Python) at which the app stops launching a sweep for a session on its own.
    static let sweepAttemptCap = 6
    /// Notification throttles (seconds per key). A failing start is retried every few seconds: tell the user once in a while.
    static let startFailureNotifySeconds: TimeInterval = 30 * 60
    static let pipelineFailureNotifySeconds: TimeInterval = 12 * 3600
    /// Recording start / stop notifications are never throttled except for an identical repeat (same kind, same session) within seconds.
    static let recordingNoticeRepeatSeconds: TimeInterval = 5
    /// A recording that started on WEAK Zoom evidence (docs/DETECTION.md section 3) does not announce itself until it is confirmed: a STRONG
    /// observation, or this many seconds of uninterrupted inCall since the recording started. Until then it has no 'recording started'
    /// notification, and if it ends unconfirmed it has no 'recording ended' one either (no banner pair for a non-meeting).
    static let weakConfirmSeconds: TimeInterval = 20
    /// An AUTO recording that ended normally (meeting-ended) with less than this many seconds of inCall holds its 'recording ended' notification
    /// until the pipeline has said what became of it: dropped when the pipeline discards the session (no speech), posted otherwise.
    static let deferStopNoticeBelowSeconds: TimeInterval = 60
    /// A held 'recording ended' notification the pipeline never answered for is dropped after this long (a lost event must not leak).
    static let deferredStopExpirySeconds: TimeInterval = 30 * 60
    /// Name the launcher gives the sweep job in its events.
    static let sweepJobName = "retry-sweep"
    /// SPEC 18: the policy file is read again this often (the recording kill switch ends an active recording within it).
    static let policyPollSeconds: TimeInterval = 60
    /// The stages of state.json in which the local-only flag can still take effect: before the pipeline publishes.
    static let stagesBeforePublishing: Set<String> = ["queued", "audio", "transcribing", "noting"]
    /// `end_reason` label of a recording ended because the policy switched recording off (end_reason itself is `manual`).
    static let policyKillSwitchLabel = "policy-kill-switch"

    /// Delivered via `deliver` (main queue in the app) whenever the state changes. Set before start().
    var onState: ((ControllerState) -> Void)?
    /// Called on the controller queue when a recording that the calendar auto-start began has ended (any reason). Set before start(); the receiver
    /// must not block on the controller (the watcher hops to its own queue).
    var onCalendarRecordingEnded: ((CalendarRecordingEnd) -> Void)?
    /// `label` of the stop that the calendar auto-start asks for when the event is over (the end reason itself is meeting-ended: Types.swift has no
    /// case of its own and is not ours to extend).
    static let calendarEndLabel = "calendar-end"
    /// The longest event title that goes into session.json as the title hint (a title is somebody else's text: control characters are stripped too).
    static let calendarTitleLimit = 120

    private let config: AppConfig
    private let detector: MeetingDetecting
    private let recorderFactory: RecorderFactory
    private let pipeline: PipelineRunning
    private let clock: () -> Date
    private let freeDiskGB: () -> Double?
    private let deliver: (@escaping () -> Void) -> Void
    private let notifier: NotificationPosting

    // SPEC 18
    private let policyBox: PolicyBox
    private let privacy: PrivacySettings
    private let policyReader: (() -> OrgPolicy)?
    private let policyPollSeconds: TimeInterval
    private let sessionPatch: (Bool, String, URL) throws -> Void       // rewrites local_only of a STOPPED session (SessionJSONPatch.apply)

    private let scheduleRescan: (TimeInterval, @escaping () -> Void) -> Void

    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).session")
    private let pollQueue = DispatchQueue(label: "\(AppInfo.bundleID).poll", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var started = false

    // True while a recording is active; readable from any thread (the pipeline launcher asks before a reprocess).
    private let activeLock = NSLock()
    private var recordingFlag = false
    var isRecordingActive: Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return recordingFlag
    }
    // The last published `restartHold` (any thread: the Settings window asks when its restart button is pressed).
    private var restartHoldFlag: RestartHold?
    var restartHold: RestartHold? {
        activeLock.lock(); defer { activeLock.unlock() }
        return restartHoldFlag
    }

    // --- state (queue-confined) ---
    private var machine: DetectionStateMachine
    private var recorder: SessionRecording? {
        didSet {
            activeLock.lock(); recordingFlag = recorder != nil; activeLock.unlock()
        }
    }
    private var currentDir: URL?
    private var retriedFailed = Set<String>()        // failed-but-retryable sessions already re-enqueued by this launch
    private var liveRescans = 0
    private var currentPlatform: Platform = .manual
    private var currentLabel: String = ""             // the words for the active recording in texts (the platform's, or the call app's name)
    private var currentCall: CallAppView?             // the app of the active recording when it is a call of another app
    private var currentKey: String?
    private var currentIsManual = false
    private var currentCalendarEvent: String?        // the calendar event whose auto-start began the active recording (nil: anything else)
    private var lastTitle: String?
    private var lastURL: String?
    private var lastDiskCheck: Date?
    private var warning: String?

    private var paused = false
    private var installHold = false                   // see setInstallHold
    private var isShutDown = false
    private var lastSnapshot: DetectionSnapshot?
    private var wasCandidate = false
    private var ignoredLogged = Set<String>()             // meetings that were in a call while another recording ran (logged once each)

    private struct StartFailure { var key: String; var until: Date; var attempts: Int; var logged: Bool }
    private struct UserStop { var key: String; var lastSeen: Date; var logged: Bool }
    /// The last recording of this meeting was ended by the no-speech rule: no restart for the same meeting until detection has
    /// said "not in a call" once.
    private struct NoSpeechStop { var key: String; var logged: Bool }
    private var startFailure: StartFailure?
    private var userStop: UserStop?
    private var noSpeechStop: NoSpeechStop?

    private var silentSince: Date?                   // both tracks below noSpeechThresholdDB since (AUTO recordings only)
    private var remoteSilent = false                 // the active recording's remote track is suspected silent
    private var notice: (text: String, until: Date)?
    private var throttle = NotificationThrottle()

    /// What decides the start / stop notifications of the active AUTO recording (nil for a manual recording and while idle).
    private struct AutoNotice {
        var signal: PlatformSignal        // the signal the recording started on (the text of the start notification)
        var dir: URL
        var startNoticeSent: Bool         // false: started on WEAK evidence, not confirmed yet
        var inCallSince: Date?            // start of the current uninterrupted run of inCall polls (the sustained-inCall confirmation)
        var lastInCall: Date              // the last poll that still said inCall (the length of the call without the grace period)
    }
    private var autoNotice: AutoNotice?
    /// A 'recording ended' notification held back until the pipeline outcome of its session is known (see `deferStopNoticeBelowSeconds`).
    private struct DeferredStop { var notification: AppNotification; var key: String; var created: Date }
    private var deferredStops: [String: DeferredStop] = [:]
    /// A candidate with WEAK evidence only is not shown as "meeting detected"; this remembers when it began (for the log line when it ends).
    private var weakCandidate: (since: Date, lastSeen: Date, evidence: String)?
    /// ZOOM_WEAK_DEBOUNCE_SECONDS in force (for the log).
    private let zoomTier: ZoomTierSettings
    /// The decisions per call app (SUPPORT_DIR/call-apps.json) and the call rule of this run (the log line; the detector has its own copy).
    private let callApps: CallAppStore?
    private let callSettings: CallDetectSettings
    /// Platform and length of the recordings of this launch, by session id: the fallback for the "note ready" text when session.json
    /// cannot be read (queue-confined, at most `maxRecordedFacts` entries).
    private struct RecordedFacts { var platform: Platform; var label: String; var manual: Bool; var seconds: Double }
    private var recordedFacts: [String: RecordedFacts] = [:]
    private static let maxRecordedFacts = 64

    // Retry sweep
    private var nextSweepAt: Date?
    private var sweepEnqueues: [String: Int] = [:]
    private var sweepsRun = 0

    // SPEC 18 (queue-confined)
    private var lastPolicyRead: Date
    private var activeLocalOnly: LocalOnlyValue?       // the flag of the active recording
    private var micPaused = false                      // 'Pause Microphone' is on for the active recording
    /// The last recording this launch ended and kept: the menu item can still change its flag until the pipeline publishes it.
    private struct EndedSession { var dir: URL; var value: LocalOnlyValue; var platform: Platform; var label: String }
    private var ended: EndedSession?
    private var infoCache: (policy: OrgPolicy, localOnly: Bool, lines: [String])?
    private var infoPending: (policy: OrgPolicy, localOnly: Bool)?     // an info-line computation is running on infoQueue for this input
    private let infoQueue = DispatchQueue(label: "\(AppInfo.bundleID).session.info", qos: .utility)

    private var recordError: String?
    private var pipelineText: String?
    private var pipelineError: (session: String, text: String)?
    private var done: (title: String, until: Date)?
    private var lastPublished: ControllerState?

    init(config: AppConfig,
         detector: MeetingDetecting,
         recorderFactory: @escaping RecorderFactory,
         pipeline: PipelineRunning,
         clock: @escaping () -> Date = { Date() },
         freeDiskGB: (() -> Double?)? = nil,
         deliver: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) },
         scheduleRescan: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
         notifier: NotificationPosting? = nil,
         zoomTier: ZoomTierSettings? = nil,
         policy: PolicyBox? = nil,
         privacy: PrivacySettings? = nil,
         policyReader: (() -> OrgPolicy)? = nil,
         policyPollSeconds: TimeInterval = SessionController.policyPollSeconds,
         sessionPatch: ((Bool, String, URL) throws -> Void)? = nil,
         callApps: CallAppStore? = nil,
         callSettings: CallDetectSettings? = nil) {
        self.config = config
        self.detector = detector
        self.callApps = callApps
        self.callSettings = callSettings ?? CallDetectSettings.current
        // nil = what config.env says (ZOOM_WEAK_DEBOUNCE_SECONDS); the self tests pass an explicit value.
        let tier = zoomTier ?? ZoomTierSettings.current
        self.zoomTier = tier
        self.recorderFactory = recorderFactory
        self.pipeline = pipeline
        self.clock = clock
        self.notifier = notifier ?? NullNotifier()
        let sessionsDir = config.sessionsDir
        self.freeDiskGB = freeDiskGB ?? { ShellUtil.freeDiskGB(near: sessionsDir) }
        self.deliver = deliver
        let controllerQueue = queue
        self.scheduleRescan = scheduleRescan ?? { delay, work in controllerQueue.asyncAfter(deadline: .now() + delay, execute: work) }
        self.machine = DetectionStateMachine(startDebounce: config.startDebounce, grace: config.grace, weakDebounce: tier.weakDebounce)
        // No policy given = the personal install (absent) and the built-in defaults: the flag starts off, nothing is restricted.
        self.policyBox = policy ?? PolicyBox(OrgPolicy.absent())
        self.privacy = privacy ?? PrivacySettings.build(from: [:], supportDir: config.supportDir, source: "the built-in defaults")
        self.policyReader = policyReader
        self.policyPollSeconds = max(policyPollSeconds, 1)
        self.sessionPatch = sessionPatch ?? { value, source, dir in try SessionJSONPatch.apply(localOnly: value, source: source, to: dir) }
        self.lastPolicyRead = clock()
        pipeline.onEvent = { [weak self] event in
            guard let self = self else { return }
            self.queue.async { self.handlePipelineEvent(event) }
        }
        // The version question the menu asked has an answer: compute the menu item again (it was waiting, i.e. disabled).
        pipeline.onVersionKnown = { [weak self] in
            guard let self = self else { return }
            self.queue.async { if !self.isShutDown { self.publish(self.clock()) } }
        }
    }

    // MARK: Lifecycle

    /// Startup crash-recovery scan, then begin polling every `config.pollInterval`.
    func start() {
        let shouldStart: Bool = queue.sync {
            guard !isShutDown, !started else { return false }
            started = true
            let policy = policyBox.policy
            if policy.isLocked {
                Log.warn("policy is LOCKED (\(policy.lockedReason ?? "?")): every external lane is closed, the per-meeting flag is forced on")
                notifyPolicyProblem(policy, now: clock())
            }
            _ = recoverSessionsLocked()
            armRetrySweepLocked()
            publish(clock())
            return true
        }
        guard shouldStart else { return }
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + 0.5, repeating: max(config.pollInterval, 0.5), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        queue.sync { timer = t }
        t.resume()
        let platforms = config.enabledPlatforms.isEmpty
            ? "none (auto-detection OFF: ENABLED_PLATFORMS is empty)"
            : config.enabledPlatforms.map { $0.rawValue }.joined(separator: ",")
        Log.info("session controller started (poll every \(config.pollInterval)s, platforms: \(platforms))")
        if config.enabledPlatforms.contains(.zoom) { Log.info("detection: \(zoomTier.summary)") }
        if !config.enabledPlatforms.isEmpty { Log.info("detection: \(callSettings.summary)") }
    }

    /// The retry sweep (SPEC 15): the first one a couple of minutes after launch (Google Drive may still be mounting after a
    /// login), then every RETRY_SWEEP_HOURS; 0 = never. start() arms it; the self-test drives the controller with tick() and a
    /// virtual clock instead of start(), so it arms it by hand.
    func armRetrySweep() { queue.sync { armRetrySweepLocked() } }

    private func armRetrySweepLocked() {
        nextSweepAt = config.retrySweepHours > 0 ? clock().addingTimeInterval(Self.sweepSettleSeconds) : nil
    }

    /// One poll cycle: detector.poll() (blocking, off the controller queue) then process the snapshot.
    /// Called by the timer; `selftest-session` calls it directly with a virtual clock.
    func tick() {
        let shouldPoll: Bool = queue.sync { !paused && !installHold && !isShutDown && !config.enabledPlatforms.isEmpty }
        let snapshot: DetectionSnapshot? = shouldPoll ? detector.poll() : nil
        let policy = readPolicyIfDue()
        queue.sync { process(snapshot, policy: policy) }
    }

    /// Every `policyPollSeconds` the policy file is read again. The read happens here, outside the controller queue: a locked
    /// policy is confirmed by a second read half a second later, and nothing else may wait for that.
    private func readPolicyIfDue() -> OrgPolicy? {
        guard let reader = policyReader else { return nil }
        let due: Bool = queue.sync {
            guard !isShutDown else { return false }
            let now = clock()
            if now.timeIntervalSince(lastPolicyRead) < policyPollSeconds && now >= lastPolicyRead { return false }
            lastPolicyRead = now
            return true
        }
        return due ? reader() : nil
    }

    /// Waits until everything queued so far on the controller queue has run (tests).
    func flush() { queue.sync {} }

    /// Graceful stop for SIGTERM / SIGINT / Quit (not for "will power off": see systemWillPowerOff): ALWAYS finalizes
    /// the recording (WAV headers + session.json).
    /// Does not enqueue the pipeline (we are exiting; the next launch picks the session up).
    func shutdown(reason: EndReason = .appQuit, timeout: TimeInterval = 20) {
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            if !self.isShutDown {
                self.timer?.cancel()
                self.timer = nil
                if self.recorder != nil {
                    Log.info("shutdown: finalizing active recording (\(reason.rawValue))")
                    self.endRecording(reason, enqueue: false)
                }
                self.machine.reset()
                self.isShutDown = true
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            Log.error("shutdown: controller queue did not finish within \(Int(timeout))s")
        }
        pipeline.shutdown()
    }

    /// NSWorkspace.willSleepNotification: finalize now (blocks until done) and continue after wake.
    func systemWillSleep() {
        queue.sync {
            guard !isShutDown else { return }
            if recorder != nil {
                Log.info("system will sleep: stopping recording")
                endRecording(.sleep, enqueue: true)
                machine.reset()
            }
            publish(clock())
        }
    }

    /// NSWorkspace.didWakeNotification: re-arm the pipeline's stall watchdog and hold the next retry sweep back for a moment
    /// (Wi-Fi and Google Drive are not back at the instant of the wake; a sweep now would just fail again).
    func systemDidWake() {
        queue.async {
            guard !self.isShutDown else { return }
            if let due = self.nextSweepAt {
                self.nextSweepAt = max(due, self.clock().addingTimeInterval(Self.sweepSettleSeconds))
            }
            self.pipeline.systemDidWake()
        }
    }

    /// NSWorkspace.willPowerOffNotification: a logout / shutdown was REQUESTED, but another app can still cancel it and
    /// the notification is never retracted. So only close the active recording (kept and queued, like any stop) and keep
    /// running. Real termination arrives later as SIGTERM or applicationShouldTerminate -> shutdown().
    func systemWillPowerOff() {
        queue.sync {
            guard !isShutDown else { return }
            if recorder != nil {
                Log.info("system will power off: finalizing the active recording (the logout may still be cancelled)")
                endRecording(.appQuit, enqueue: true)
                machine.reset()           // a call that is still running is picked up again after the debounce
            }
            publish(clock())
        }
    }

    // MARK: Menu actions (asynchronous; safe to call from the main thread)

    func setPaused(_ pause: Bool) {
        queue.async { self.setPausedLocked(pause) }
    }

    /// The app installer's gate (FirstRun.holdsRecording, App.swift): while it is on nothing is detected and no recording starts: not automatic, not
    /// "Start Recording Now", not the calendar. The recording legal notice is shown only by the installer's helper, so an app that has not been through it
    /// must not record. Unlike "Pause Auto Recording" the person cannot switch it off; the app switches it off when the helper has finished. It never ends a
    /// recording that already runs. Set before start() at launch (the order of the queue keeps it ahead of the first poll).
    func setInstallHold(_ hold: Bool) {
        queue.async { self.setInstallHoldLocked(hold) }
    }

    /// "Start Recording Now" (manual fallback, platform .manual). Works while paused.
    func startRecordingNow() {
        queue.async { self.startManualLocked() }
    }

    /// "Stop Recording Now": stops whatever is being recorded (manual or auto-detected) and keeps it.
    func stopRecordingNow() {
        queue.async { self.stopNowLocked() }
    }

    /// Menu "Reprocess Last Meeting". Refused while a recording is active: a reprocess is a long ASR run that would compete
    /// with the recorder for CPU, memory and disk (the menu item is disabled then; this is the second line of defence).
    func reprocessLast() {
        queue.async {
            if self.recorder != nil {
                Log.warn("Reprocess Last Meeting refused: a recording is active")
                return
            }
            self.pipelineError = nil
            self.pipelineText = "Queued: reprocess last meeting"
            self.publish(self.clock())
            self.pipeline.reprocessLast()
        }
    }

    func lastMeetingFolder() -> URL? { pipeline.lastMeetingFolder() }

    // MARK: Call apps (menu: 'Never record <App>' and the Call Apps submenu)

    /// Remembers the decision of the person for one app (SUPPORT_DIR/call-apps.json). Denying the app that is being recorded ends that recording the way
    /// 'Stop Recording Now' does (it is kept and queued, like any stop by hand); denying an app that only looked like a call forgets the candidate.
    func setCallDecision(bundleID: String, decision: CallDecision) {
        queue.async { self.setCallDecisionLocked(bundleID, decision) }
    }

    /// 'Never record <App>' while a call of another app is being recorded.
    func neverRecordCurrentCallApp() {
        queue.async {
            guard let call = self.currentCall, !call.decisionKey.isEmpty else { return }
            self.setCallDecisionLocked(call.decisionKey, .denied)
        }
    }

    private func setCallDecisionLocked(_ bundleID: String, _ decision: CallDecision) {
        guard !isShutDown, let store = callApps else { return }
        let now = clock()
        let id = bundleID.lowercased()
        // The name the menu row shows: the stored one, the running recording's, else the table's (an app that was never recorded can be denied in advance).
        let name = store.entries().first { $0.id == id }?.name ?? (currentCall?.decisionKey == id ? currentCall?.name : nil)
            ?? CallApps.known(forBundle: id)?.name ?? callSettings.extraApps.first { $0.id.lowercased() == id }?.name
            ?? WebMeetingURL.sites.first { CallTracker.webKey($0.siteID) == id }?.name
        guard store.set(bundleID, decision: decision, name: name, now: now) else {
            Log.warn("call apps: the decision for \(id) was not saved (\(store.problem ?? "the list is full"))")
            publish(now)
            return
        }
        Log.info("call apps: \(id) -> \(decision.rawValue) (from the menu)")
        if decision == .denied {
            if recorder != nil, currentPlatform == .call, currentCall?.decisionKey == id {
                Log.info("call apps: stopping the recording of \(id): 'never record' was chosen")
                stopNowLocked()
            } else if recorder == nil {
                machine.reset()
            }
        }
        publish(now)
    }

    // MARK: Calendar auto-start (any thread; the work is done on the controller queue)

    /// Why the calendar auto-start must not contact Google or start anything right now (nil = it may). Reads the shared policy box only, so any
    /// thread may ask: the kill switch (recording.enabled=false), a policy that cannot be read, a policy that denies the calendar lane, and
    /// 'local-only' being the start value of every meeting (nothing is to leave this Mac, and a calendar lookup is a call to Google).
    func calendarGate() -> CalendarBlock? {
        let policy = policyBox.policy
        if !policy.recordingEnabled { return .recordingOff }
        if policy.isLocked { return .policyLocked }
        if !policy.laneAllowed("calendar") { return .laneDenied }
        if LocalOnlyResolver.initial(policy: policy, settings: privacy).value { return .localOnlyDefault }
        return nil
    }

    /// Starts a recording for a calendar event the way 'Start Recording Now' does (platform manual, adopted by the detection machine so that no
    /// detector verdict stops it) and remembers `eventID` for it. Refused while another recording runs, while 'Pause Auto Recording' is on, and
    /// while `calendarGate` is closed. `title` becomes the session's title hint only when LOG_CONTENT allows a title in logs (a title the
    /// calendar gave: control characters are stripped and it is cut to `calendarTitleLimit`); it is never logged here.
    func startRecordingFromCalendar(eventID: String, title: String?) -> CalendarStartResult {
        return queue.sync { startFromCalendarLocked(eventID: eventID, title: title) }
    }

    private func startFromCalendarLocked(eventID: String, title: String?) -> CalendarStartResult {
        guard !isShutDown else { return .shutDown }
        if recorder != nil { return .alreadyRecording }
        if paused { return .paused }
        if installHold { return .held }
        if let block = calendarGate() { return .blocked(block.logText) }
        let now = clock()
        let hint = privacy.logContent ? NotificationText.nonEmpty(title).map { NotificationText.clip($0, Self.calendarTitleLimit) } : nil
        let signal = PlatformSignal(platform: .manual, inCall: true, confidence: .high, titleHint: hint.flatMap { $0.isEmpty ? nil : $0 }, meetingURL: nil,
                                    meetingKey: nil, bundleID: nil, evidence: ["calendar auto-start"])
        let result: CalendarStartResult
        switch startRecording(signal, manual: true, now: now, calendarEvent: eventID) {
        case .started:
            machine.adoptManualRecording()
            result = .started
        case .failed(let message, _, let kind):
            recordError = message
            notifyStartFailure(message, kind: kind, platform: .manual, now: now)
            result = kind == .policy ? .blocked(message) : .failed(message)
        }
        publish(now)
        return result
    }

    /// The event is over: ends the recording that `eventID`'s auto-start began (end reason meeting-ended, labelled calendar-end), keeps it and
    /// queues it for the pipeline. False when no such recording runs (nothing else is ever stopped by the calendar).
    @discardableResult
    func stopRecordingFromCalendar(eventID: String) -> Bool {
        return queue.sync {
            guard !isShutDown, recorder != nil, currentCalendarEvent == eventID else { return false }
            Log.info("calendar: the event is over; stopping the recording it started")
            endRecording(.meetingEnded, enqueue: true, label: Self.calendarEndLabel, allowBlipDelete: false)
            machine.reset()
            publish(clock())
            return true
        }
    }

    // MARK: Poll processing (queue)

    private func process(_ snapshot: DetectionSnapshot?, policy fresh: OrgPolicy? = nil) {
        guard !isShutDown else { return }
        let now = clock()
        if let fresh = fresh { applyPolicy(fresh, now: now) }
        housekeeping(now)
        if let snap = snapshot, !paused, !installHold { handleDetection(snap, now: now) }
        publish(now)
    }

    private func handleDetection(_ snap: DetectionSnapshot, now: Date) {
        lastSnapshot = snap
        updateUserStopSuppression(snap, now: now)
        updateNoSpeechSuppression(snap)

        let action = machine.step(now: now, snapshot: snap)

        // A candidate that has shown WEAK evidence only (the idle Zoom flicker) is not "a meeting detected" yet: no menu status, no log
        // line unless it turns into one; the log says once when such a run ended without ever becoming a recording.
        let candidateShown = machine.isCandidate && !machine.candidateIsWeakOnly
        if candidateShown != wasCandidate {
            wasCandidate = candidateShown
            // While this meeting is suppressed (start failed / stopped by hand) the machine cycles through
            // "candidate" every few seconds; the "suppressed" line (once per window) already says why.
            if wasCandidate, !isSuppressed(snap.best, now: now) { Log.info("meeting candidate: \(Self.describe(snap))") }
        }
        trackWeakCandidate(snap, now: now)

        switch action {
        case .none:
            break
        case .start(let signal):
            if recorder != nil {
                Log.warn("detector asked to start while already recording; ignoring")
            } else {
                beginAutoRecording(signal, now: now, snapshot: snap)
            }
        case .split(let signal):
            if recorder != nil && !currentIsManual {
                Log.info("split: meeting changed (\(currentKey ?? "?") -> \(Self.meetingKey(signal))); \(Self.describe(snap))")
                endRecording(.meetingEnded, enqueue: true)
                beginAutoRecording(signal, now: now, snapshot: snap)
            } else if recorder == nil {
                beginAutoRecording(signal, now: now, snapshot: snap)
            }
        case .stop(let reason):
            if recorder != nil && !currentIsManual {
                Log.info("stop (\(reason.rawValue)): \(Self.describe(snap))")
                endRecording(reason, enqueue: true)
            } else if recorder == nil {
                machine.reset()
            }
            // A manual recording is never stopped by the detector.
        }

        if recorder != nil && !currentIsManual {
            forwardMeta(snap)
            updateAutoNotice(snap, now: now)
        }
        logSignalsWithoutRecording(snap)
    }

    /// One recording at a time: a meeting that is in a call while another recording runs gets one log line (per call, again after it ended) instead of a silence
    /// that looks like a missed meeting. A Zoom / Teams / Meet meeting that is STRONG takes a call app's recording over after the start debounce (state machine).
    private func logSignalsWithoutRecording(_ snap: DetectionSnapshot) {
        guard recorder != nil, !currentIsManual else { ignoredLogged.removeAll(); return }
        let others = snap.signals.filter { sig in sig.inCall && activeSignal(in: snap).map { Self.meetingKey($0) != Self.meetingKey(sig) } ?? true }
        let keys = Set(others.map { Self.meetingKey($0) })
        ignoredLogged.formIntersection(keys)
        for sig in others where ignoredLogged.insert(Self.meetingKey(sig)).inserted {
            let takeover = currentPlatform == .call && sig.platform != .call ? "; a STRONG Zoom / Teams / Meet signal takes over from a call app after the start debounce" : ""
            Log.info("detect: \(Self.meetingKey(sig)) is in a call while the recording \(currentKey ?? "?") runs: one recording at a time\(takeover)")
        }
    }

    /// The signal of the active recording's own meeting in this snapshot (nil = not in a call). Platform alone is enough for Zoom, Teams and Meet; calls of
    /// other apps have one signal per app, so the app counts too.
    private func activeSignal(in snap: DetectionSnapshot) -> PlatformSignal? {
        return snap.signals.first { sig in
            guard sig.inCall, sig.platform == currentPlatform else { return false }
            if currentPlatform == .call, let key = currentKey { return Self.meetingKey(sig) == key }
            return true
        }
    }

    /// Log-only bookkeeping for a candidate that has shown WEAK evidence only: remembers when it began and says, once, when it ended
    /// without a recording (the idle Zoom flicker is exactly this, every ~2 minutes; docs/DETECTION.md section 3).
    private func trackWeakCandidate(_ snap: DetectionSnapshot, now: Date) {
        if machine.candidateIsWeakOnly {
            weakCandidate = (weakCandidate?.since ?? now, now, Self.describe(snap))
            return
        }
        guard let w = weakCandidate else { return }
        weakCandidate = nil
        // Ended as a STRONG candidate / a recording: those have their own lines. Ended as nothing: that is the flicker we are absorbing.
        // (A reset by pause / sleep / quit leaves an old entry behind: it is not logged as a flicker.)
        guard !machine.isCandidate, !machine.isRecording, now.timeIntervalSince(w.lastSeen) <= max(config.pollInterval * 3, 10) else { return }
        Log.info(String(format: "weak evidence ended after %.0f s without a recording (it must last %@ s to count as a meeting): %@",
                        max(0, w.lastSeen.timeIntervalSince(w.since)), ZoomTierSettings.format(machine.weakWait), w.evidence))
    }

    /// Start / stop notification bookkeeping of the active AUTO recording: tracks the last inCall poll (the call's length without the grace
    /// period) and the confirmation of a recording that started on WEAK evidence (a STRONG poll, or `weakConfirmSeconds` of inCall).
    private func updateAutoNotice(_ snap: DetectionSnapshot, now: Date) {
        guard var a = autoNotice else { return }
        if let sig = activeSignal(in: snap) {
            a.lastInCall = now
            if a.inCallSince == nil { a.inCallSince = now }
            if !a.startNoticeSent {
                let strong = sig.evidenceTier == .strong
                let sustained = a.inCallSince.map { now.timeIntervalSince($0) >= Self.weakConfirmSeconds } ?? false
                if strong || sustained {
                    a.startNoticeSent = true
                    autoNotice = a
                    Log.info("recording \(a.dir.lastPathComponent) confirmed (\(strong ? "strong evidence" : String(format: "inCall for %.0f s", Self.weakConfirmSeconds))): posting the start notification")
                    notifyRecordingStarted(signal: a.signal, dir: a.dir, manual: false, now: now)
                    return
                }
            }
        } else {
            a.inCallSince = nil
        }
        autoNotice = a
    }

    /// Pass the newest tab title / meeting URL to the recorder (persisted into session.json at stop()).
    private func forwardMeta(_ snap: DetectionSnapshot) {
        guard let rec = recorder else { return }
        guard let sig = activeSignal(in: snap) else { return }
        let sigKey = Self.meetingKey(sig)
        if let current = currentKey {
            // During a pending Meet split the signal already shows the NEXT meeting; do not mix it into this
            // session. Only two KNOWN, different codes block: an unknown code ("meet:-", e.g. a tab query that
            // timed out when the session started) is compatible with anything on the same platform.
            if !Self.sameMeeting(sigKey, current) { return }
            if Self.keyIsUnknown(current), !Self.keyIsUnknown(sigKey) {
                Log.info("meeting code learned for the active session: \(sigKey)")
                currentKey = sigKey
            }
        }
        let title = sig.titleHint ?? lastTitle
        let url = sig.meetingURL ?? lastURL
        if title != lastTitle || url != lastURL {
            lastTitle = title
            lastURL = url
            rec.updateMeta(titleHint: title, meetingURL: url)
        }
    }

    // MARK: Housekeeping (queue)

    private func housekeeping(_ now: Date) {
        if let rec = recorder {
            if !rec.isRecording {
                Log.warn("recorder stopped by itself; finalizing the session")
                endRecording(.meetingEnded, enqueue: true)
                machine.reset()
            } else if now.timeIntervalSince(rec.startedAt) >= config.maxRecordingHours * 3600 {
                Log.warn("max recording duration (\(config.maxRecordingHours) h) reached; stopping")
                endRecording(.maxDuration, enqueue: true)
                machine.reset()      // a meeting that is still running starts a fresh session after the debounce
            } else if lastDiskCheck == nil || now.timeIntervalSince(lastDiskCheck ?? now) >= Self.diskCheckSeconds {
                lastDiskCheck = now
                if let free = freeDiskGB(), free < config.minFreeDiskGB {
                    recordError = String(format: "Disk space low (%.1f GB free, need %.0f GB): recording stopped. Free up space.",
                                         free, config.minFreeDiskGB)
                    Log.error("disk low (\(String(format: "%.1f", free)) GB free < \(config.minFreeDiskGB)): stopping recording")
                    let key = currentKey
                    endRecording(.diskLow, enqueue: true)
                    machine.reset()
                    // Do not restart into a full disk right away: retry (and re-check the disk) in 5 minutes.
                    if let k = key { _ = registerStartFailure(key: k, now: now, longLockout: true) }
                }
            }
        }
        if let rec = recorder, rec.isRecording { checkNoSpeech(rec, now: now) }
        if let n = notice, now >= n.until { notice = nil }
        if let d = done, now >= d.until { done = nil }
        for (session, held) in deferredStops where now.timeIntervalSince(held.created) >= Self.deferredStopExpirySeconds {
            deferredStops.removeValue(forKey: session)
            Log.info("'recording ended' notification for \(session) dropped: no pipeline outcome after \(Int(Self.deferredStopExpirySeconds / 60)) min")
        }
        runSweepIfDue(now)
        // Forget an old failure once the meeting has not been retried for a while (call over): the next meeting with
        // the same (possibly unknown) key starts again at the shortest backoff.
        if let f = startFailure, now >= f.until.addingTimeInterval(Self.startFailureMemorySeconds) { startFailure = nil }
    }

    // MARK: Starting / stopping recordings (queue)

    private func beginAutoRecording(_ signal: PlatformSignal, now: Date, snapshot: DetectionSnapshot) {
        let key = Self.meetingKey(signal)
        // The person said "never record this app" (menu, call-apps.json): no start, whatever the detector says. The detector skips such an app itself;
        // this is the second line of defence for a decision made between a poll and its start.
        if signal.platform == .call, let id = signal.meetingKey ?? signal.bundleID, callApps?.isDenied(id) == true {
            Log.info("start for \(key) suppressed: the app is on the 'never record' list")
            machine.reset()
            return
        }
        if var f = startFailure, Self.throttleApplies(failedKey: f.key, to: key), now < f.until {
            if !f.logged {
                Log.info("start for \(key) suppressed until \(ShellUtil.iso8601(f.until)) (start attempt \(f.attempts) failed)")
                f.logged = true
                startFailure = f
            }
            machine.reset()
            return
        }
        // The recording kill switch (recording.enabled=false) and a call of another app: nobody opened a meeting, so there is nothing to announce. Log it and leave
        // the app alone for the long lockout instead of a 'Recording failed' banner for every app that looks like a call.
        if signal.platform == .call, !policyBox.policy.recordingEnabled {
            let delay = registerStartFailure(key: key, now: now, longLockout: true)
            Log.info("start for \(key) skipped: recording is switched off by the organisation policy (recording.enabled=false); no notification for a call of another app, asked again in \(Self.describeDelay(delay))")
            machine.reset()
            return
        }
        if var u = userStop, Self.sameMeeting(u.key, key) {
            if !u.logged {
                Log.info("start for \(key) suppressed: stopped by hand, waiting for the meeting to end")
                u.logged = true
                userStop = u
            }
            machine.reset()          // the user stopped this meeting by hand: do not restart it
            return
        }
        if var n = noSpeechStop, Self.sameMeeting(n.key, key) {
            if !n.logged {
                Log.info("start for \(key) suppressed: the last recording of this meeting was stopped for no speech; waiting until detection goes false once")
                n.logged = true
                noSpeechStop = n
            }
            machine.reset()
            return
        }
        // Strong from the machine's point of view: the recording's run of inCall polls showed STRONG evidence at some point (the current
        // poll alone may be weak). Everything but Zoom is always strong.
        let startedStrong = machine.sessionStartedStrong ?? (signal.evidenceTier == .strong)
        Log.info("start: \(signal.platform.rawValue) key=\(key)\(startedStrong ? "" : " on WEAK evidence (it lasted \(ZoomTierSettings.format(machine.weakWait)) s; its start notification waits for a confirmation)"); \(Self.describe(snapshot))")
        switch startRecording(signal, manual: false, now: now, startedStrong: startedStrong) {
        case .started:
            startFailure = nil
        case .failed(let message, let longLockout, let kind):
            let delay = registerStartFailure(key: key, now: now, longLockout: longLockout)
            recordError = message + " Will retry in \(Self.describeDelay(delay))."
            notifyStartFailure(message, kind: kind, platform: signal.platform, label: NotificationText.platformName(signal), now: now)
            machine.reset()
        }
    }

    /// Remembers that starting `key` failed and returns how long the same meeting is left alone. Escalating backoff
    /// (10, 30, 60, then 300 s) for the same meeting; `longLockout` (permission denied, disk full) is 300 s at once.
    private func registerStartFailure(key: String, now: Date, longLockout: Bool) -> TimeInterval {
        var attempts = 1
        if let f = startFailure, Self.throttleApplies(failedKey: f.key, to: key) { attempts = f.attempts + 1 }
        let schedule = Self.startRetrySchedule
        let delay = longLockout ? Self.startLockoutSeconds : schedule[min(attempts, schedule.count) - 1]
        startFailure = StartFailure(key: key, until: now.addingTimeInterval(delay), attempts: attempts, logged: false)
        return delay
    }

    private enum StartOutcome {
        case started
        case failed(message: String, longLockout: Bool, kind: StartFailureKind)
    }

    /// Creates the session dir, builds the recorder and starts it. On failure: logs, removes the empty dir and returns
    /// the actionable message (the caller shows it and decides about retries). Never throws.
    private func startRecording(_ signal: PlatformSignal, manual: Bool, now: Date, startedStrong: Bool = true, calendarEvent: String? = nil) -> StartOutcome {
        // The recording kill switch: no recording starts, manual or automatic, while the policy says recording.enabled=false.
        let policy = policyBox.policy
        if !policy.recordingEnabled {
            let msg = "Recording is switched off by the organisation policy (recording.enabled=false)."
            Log.warn("\(msg) Not recording.")
            return .failed(message: msg, longLockout: true, kind: .policy)
        }
        if let free = freeDiskGB(), free < config.minFreeDiskGB {
            let msg = String(format: "Disk space low (%.1f GB free, need %.0f GB): not recording. Free up space.", free, config.minFreeDiskGB)
            Log.error(msg)
            return .failed(message: msg, longLockout: true, kind: .disk)
        }
        guard let dir = makeSessionDir(platform: signal.platform, now: now) else {
            return .failed(message: "Cannot create the session folder in \(config.sessionsDir.path).", longLockout: false, kind: .folder)
        }
        let rec = recorderFactory(dir, signal)
        // The start value of the per-meeting flag goes into the first session.json: between the factory and start().
        let initial = LocalOnlyResolver.initial(policy: policy, settings: privacy)
        if let privacyRecorder = rec as? SessionRecordingPrivacy {
            if !privacyRecorder.setLocalOnly(initial.value, source: initial.source) {
                Log.warn("recorder did not accept local_only=\(initial.value) (\(initial.source)); the pipeline falls back to its default chain")
            }
        }
        // The microphone gate: on or off for THIS recording, before start() (the delay line is built with the recording).
        let micGateOn = privacy.micMuteGate == "on"
        (rec as? SessionRecordingMicGate)?.configureMuteGate(enabled: micGateOn)
        rec.onWarning = { [weak self] message in
            guard let self = self else { return }
            self.queue.async {
                guard self.recorder != nil else { return }
                Log.warn("recorder warning: \(message)")
                if message.hasPrefix(Recorder.remoteSilentWarningPrefix) { return }      // the menu has its own standing line for this
                self.warning = message
                self.publish(self.clock())
            }
        }
        if let extras = rec as? SessionRecordingExtras {
            extras.onRemoteSilentSuspected = { [weak self] _ in
                guard let self = self else { return }
                self.queue.async { self.remoteSilentSuspected(session: dir.lastPathComponent, label: NotificationText.platformName(signal)) }
            }
        }
        do {
            try rec.start()
        } catch {
            let msg = Self.describeStartError(error)
            Log.error("Recorder.start() failed: \(error)")
            removeSessionDir(dir, why: "recorder failed to start")
            var longLockout = false
            if let e = error as? RecorderError, case .permissionDenied = e { longLockout = true }
            return .failed(message: msg, longLockout: longLockout, kind: Self.startFailureKind(error))
        }
        recorder = rec
        currentDir = dir
        activeLocalOnly = initial
        micPaused = false
        ended = nil                                     // the menu item now belongs to this recording
        currentPlatform = signal.platform
        currentLabel = NotificationText.platformName(signal)
        currentCall = signal.platform == .call && !manual ? CallAppView(signal: signal, name: currentLabel) : nil
        // Every call app that is recorded is listed (as allowed), known and EXTRA_MEETING_APPS apps and meeting pages (by site) included: that is what lets the
        // Call Apps submenu and 'Never record <App>' reach them.
        if let call = currentCall, !call.decisionKey.isEmpty { callApps?.noteRecorded(call.decisionKey, name: signal.appName, now: now) }
        currentKey = manual ? nil : Self.meetingKey(signal)
        currentIsManual = manual
        currentCalendarEvent = calendarEvent
        lastTitle = signal.titleHint
        lastURL = signal.meetingURL
        lastDiskCheck = now
        warning = nil
        recordError = nil
        silentSince = nil
        remoteSilent = false
        notice = nil
        Log.info("recording started: \(dir.lastPathComponent) (\(calendarEvent != nil ? "calendar" : manual ? "manual" : signal.displayLabel)); local_only=\(initial.value) (\(initial.source))"
                 + (micGateOn ? "; mic_gate=on" : ""))
        // A recording that started on WEAK evidence (a few Zoom sockets, no audio IO) does not announce itself until it is confirmed.
        autoNotice = manual ? nil : AutoNotice(signal: signal, dir: dir, startNoticeSent: startedStrong, inCallSince: now, lastInCall: now)
        if manual || startedStrong {
            notifyRecordingStarted(signal: signal, dir: dir, manual: manual, now: now, fromCalendar: calendarEvent != nil)
        } else {
            Log.info("start notification for \(dir.lastPathComponent) held back: weak evidence, not confirmed yet (a STRONG observation or \(Int(Self.weakConfirmSeconds)) s of inCall confirms it)")
        }
        return .started
    }

    /// Stops the active recorder (idempotent). Everything goes to the pipeline except an accidental blip: an
    /// auto-detected session shorter than the blip limit that ended by meeting-ended / sleep / app-quit.
    /// Manual recordings and manual / paused / other stops are explicit user actions (or real data): always kept.
    /// `label` only changes the log line (the no-speech stop is recorded as end_reason meeting-ended; Types.swift has no such
    /// case and is not ours to extend). `allowBlipDelete: false` keeps even a very short recording (a stop the app chose itself).
    @discardableResult
    private func endRecording(_ reason: EndReason, enqueue: Bool, label: String? = nil, allowBlipDelete: Bool = true) -> RecorderSummary? {
        guard let rec = recorder, let dir = currentDir else { return nil }
        let wasManual = currentIsManual
        let label0 = currentLabel
        let calendarEvent = currentCalendarEvent
        let facts = autoNotice
        autoNotice = nil
        let localOnlyAtStop = activeLocalOnly
        let hideAtStop = hidesMeetingContent                    // before the recording state is cleared: the stop notification is built below
        let summary = rec.stop(reason: reason)
        recorder = nil
        currentDir = nil
        activeLocalOnly = nil
        micPaused = false
        currentKey = nil
        currentCall = nil
        currentIsManual = false
        currentCalendarEvent = nil
        warning = nil
        silentSince = nil
        if remoteSilent {
            // The flag is in session.json for the pipeline; the menu keeps saying it for a while after the call is over.
            remoteSilent = false
            notice = (Self.remoteSilentNotice, clock().addingTimeInterval(Self.noticeSeconds))
        }

        let seconds = max(summary.durationSec, summary.micSeconds, summary.remoteSeconds)
        rememberFacts(session: dir.lastPathComponent, platform: currentPlatform, label: label0, manual: wasManual, seconds: seconds)
        Log.info(String(format: "recording stopped: %@ reason=%@ duration=%.1fs mic=%.1fs remote=%.1fs",
                        dir.lastPathComponent, label ?? reason.rawValue, summary.durationSec, summary.micSeconds, summary.remoteSeconds))
        for w in summary.warnings { Log.warn("recording \(dir.lastPathComponent): \(w)") }
        if let event = calendarEvent { onCalendarRecordingEnded?(CalendarRecordingEnd(eventID: event, reason: reason, label: label)) }

        let blipLimit = min(Self.blipSeconds, config.minRecordingSeconds)
        if seconds < blipLimit {
            let files = Self.describeFiles(in: dir)
            if allowBlipDelete, Self.mayDeleteBlip(manual: wasManual, reason: reason) {
                removeSessionDir(dir, why: String(format: "accidental blip (%.1fs < %.0fs, auto session, %@); files: %@",
                                                  seconds, blipLimit, reason.rawValue, files))
                return summary
            }
            Log.info(String(format: "short recording %@ kept (%.1fs, %@%@); files: %@", dir.lastPathComponent, seconds,
                            wasManual ? "manual recording, " : "", reason.rawValue, files))
        }
        // The session stays in staging: until the pipeline publishes it the menu item can still change its flag.
        if let value = localOnlyAtStop { ended = EndedSession(dir: dir, value: value, platform: currentPlatform, label: label0) }
        if enqueue {
            if pipelineText == nil { pipelineText = "Queued" }
            pipeline.enqueue(dir)
            // Not when the app is quitting (enqueue is false then: nothing starts processing, and the process is going away).
            let inCallSeconds = facts.map { max(0, $0.lastInCall.timeIntervalSince(rec.startedAt)) } ?? seconds
            let decision = Self.stopNoticeDecision(manual: wasManual, startNoticeSent: facts?.startNoticeSent ?? true, reason: reason,
                                                   label: label, inCallSeconds: inCallSeconds)
            switch decision {
            case .post:
                postRecordingStopped(dir: dir, platformLabel: label0, manual: wasManual, seconds: seconds, reason: reason, label: label, hideTitle: hideAtStop)
            case .skipUnconfirmed:
                Log.info("no 'recording ended' notification for \(dir.lastPathComponent): its start was never announced (weak evidence, not confirmed)")
            case .deferUntilOutcome:
                if let n = recordingStoppedNotification(dir: dir, platformLabel: label0, manual: wasManual, seconds: seconds, reason: reason, label: label, hideTitle: hideAtStop) {
                    let now = clock()
                    deferredStops[dir.lastPathComponent] = DeferredStop(notification: n, key: "recording-stopped:\(dir.lastPathComponent)", created: now)
                    Log.info(String(format: "'recording ended' notification for %@ held back: %.0f s of inCall (< %.0f s); posted only if the pipeline keeps the session",
                                    dir.lastPathComponent, inCallSeconds, Self.deferStopNoticeBelowSeconds))
                }
            }
        }
        return summary
    }

    private func rememberFacts(session: String, platform: Platform, label: String, manual: Bool, seconds: Double) {
        recordedFacts[session] = RecordedFacts(platform: platform, label: label, manual: manual, seconds: seconds)
        if recordedFacts.count > Self.maxRecordedFacts {
            for key in recordedFacts.keys.sorted().prefix(recordedFacts.count - Self.maxRecordedFacts) { recordedFacts.removeValue(forKey: key) }
        }
    }

    /// Only an auto-detected session that ended by itself (meeting-ended) or by the system (sleep, app-quit) may be
    /// dropped as a blip. A user action (manual start, Stop Recording Now, Pause), disk-low, max-duration and crash
    /// recovery always keep the audio.
    static func mayDeleteBlip(manual: Bool, reason: EndReason) -> Bool {
        if manual { return false }
        switch reason {
        case .meetingEnded, .sleep, .appQuit: return true
        case .manual, .paused, .diskLow, .maxDuration, .crashRecovered: return false
        }
    }

    /// "mic.wav=96044 B, remote.wav=96044 B, session.json=612 B" (for the blip log lines).
    static func describeFiles(in dir: URL) -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path), !names.isEmpty else { return "(empty folder)" }
        return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
            let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? NSNumber
            return "\(name)=\(size?.int64Value ?? -1) B"
        }.joined(separator: ", ")
    }

    private func setPausedLocked(_ pause: Bool) {
        guard !isShutDown, pause != paused else { return }
        paused = pause
        if pause {
            Log.info("auto recording paused")
            if recorder != nil { endRecording(.paused, enqueue: true) }
            machine.reset()
            lastSnapshot = nil
            wasCandidate = false
        } else {
            Log.info("auto recording resumed")
            machine.reset()
            startFailure = nil
            userStop = nil
            noSpeechStop = nil
        }
        publish(clock())
    }

    private func setInstallHoldLocked(_ hold: Bool) {
        guard !isShutDown, hold != installHold else { return }
        installHold = hold
        machine.reset()
        lastSnapshot = nil
        wasCandidate = false
        if hold {
            Log.info("recording held: the app installer has not finished (no detection and no recording until it has)")
        } else {
            Log.info("recording hold released: the app installer has finished")
            startFailure = nil
            userStop = nil
            noSpeechStop = nil
        }
        publish(clock())
    }

    private func startManualLocked() {
        guard !isShutDown else { return }
        if installHold {
            Log.info("manual start refused: the app installer has not finished")
            return
        }
        let now = clock()
        if recorder != nil {
            Log.info("manual start ignored: already recording")
            return
        }
        startFailure = nil
        userStop = nil
        noSpeechStop = nil
        let signal = PlatformSignal(platform: .manual, inCall: true, confidence: .high, titleHint: nil, meetingURL: nil,
                                    meetingKey: nil, bundleID: nil, evidence: ["manual start from menu"])
        switch startRecording(signal, manual: true, now: now) {
        case .started:
            machine.adoptManualRecording()
        case .failed(let message, _, let kind):
            recordError = message         // an explicit user action: shown, never throttled
            notifyStartFailure(message, kind: kind, platform: .manual, now: now)
        }
        publish(now)
    }

    private func stopNowLocked() {
        guard !isShutDown, recorder != nil else { return }
        let now = clock()
        let wasManual = currentIsManual
        let key = currentKey
        endRecording(.manual, enqueue: true)
        machine.reset()
        // Do not re-record the meeting the user just stopped until it has ended.
        let suppress: String? = wasManual ? lastSnapshot?.best.map { Self.meetingKey($0) } : key
        if let k = suppress { userStop = UserStop(key: k, lastSeen: now, logged: false) }
        publish(now)
    }

    /// Clears the "user stopped this meeting" suppression once the meeting has been gone for a while.
    private func updateUserStopSuppression(_ snap: DetectionSnapshot, now: Date) {
        guard var u = userStop else { return }
        if snap.signals.contains(where: { $0.inCall && Self.sameMeeting(Self.meetingKey($0), u.key) }) {
            u.lastSeen = now
            userStop = u
        } else if now.timeIntervalSince(u.lastSeen) > max(config.grace, 10) {
            userStop = nil
        }
    }

    // MARK: Session directory management

    /// SPEC 2: YYYY-MM-DD_HHMM_<platform>, collision suffix -2, -3, ... The directory is created here (and is the
    /// atomic claim on the name), then handed to the recorder.
    private func makeSessionDir(platform: Platform, now: Date) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: config.sessionsDir, withIntermediateDirectories: true)
        } catch {
            Log.error("cannot create sessions dir \(config.sessionsDir.path): \(error)")
            return nil
        }
        let base = ShellUtil.sessionIDBase(at: now, platform: platform)
        for n in 1...99 {
            let id = n == 1 ? base : "\(base)-\(n)"
            let dir = config.sessionsDir.appendingPathComponent(id, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                return dir
            } catch {
                if fm.fileExists(atPath: dir.path) { continue }      // name taken: try next suffix
                Log.error("cannot create session dir \(dir.path): \(error)")
                return nil
            }
        }
        Log.error("no free session id for \(base)")
        return nil
    }

    /// Only ever deletes a direct child of the sessions dir (defense against a bad path).
    private func removeSessionDir(_ dir: URL, why: String) {
        guard ShellUtil.sameFile(dir.deletingLastPathComponent(), config.sessionsDir), !dir.lastPathComponent.isEmpty else {
            Log.error("refusing to delete \(dir.path): not inside \(config.sessionsDir.path)")
            return
        }
        do {
            try FileManager.default.removeItem(at: dir)
            Log.info("deleted session folder \(dir.lastPathComponent): \(why)")
        } catch {
            Log.warn("could not delete session folder \(dir.path): \(error)")
        }
        // The private history (SPEC 18, SUPPORT_DIR/session-private) of a session that no longer exists goes with it.
        if let sidecar = SessionPrivateLog.file(session: dir.lastPathComponent, supportDir: config.supportDir) { try? FileManager.default.removeItem(at: sidecar) }
    }

    // MARK: No-speech auto-stop (queue)

    /// The menu notice while a recorded session waits for the transcription server (error_kind asr_unreachable).
    static let waitingForServerNotice = "Waiting for the transcription server: the recording is kept and is processed when it can be reached."

    /// The menu notice after a recording whose remote track was suspected silent (short: it is a menu line; the notification has its own text).
    static let remoteSilentNotice = "Remote audio was silent for 3+ min in the last recording; the other side may be missing. "
        + "Check the System Audio Recording permission."

    /// SPEC 15: an AUTO recording whose two tracks (both: a muted microphone is normal) stay below -70 dBFS for
    /// NO_SPEECH_STOP_MINUTES while detection still says "in a call" is ended like any other stop: finalized, kept, queued for
    /// the pipeline. The same meeting is not restarted until detection has said "not in a call" once. Manual recordings are the
    /// user's call and are never stopped here. 0 minutes = off.
    private func checkNoSpeech(_ rec: SessionRecording, now: Date) {
        // A recording the calendar auto-start began is a manual-path recording, but nobody pressed a button for it: the rule covers it too.
        let calendarOwned = currentCalendarEvent != nil
        guard !currentIsManual || calendarOwned, config.noSpeechStopMinutes > 0 else { silentSince = nil; return }
        let levels = rec.recentLevelsDB
        guard levels.mic < Self.noSpeechThresholdDB, levels.remote < Self.noSpeechThresholdDB else {
            silentSince = nil
            return
        }
        let since = silentSince ?? now
        silentSince = since
        let silentFor = now.timeIntervalSince(since)
        guard silentFor >= config.noSpeechStopMinutes * 60 else { return }
        if calendarOwned {
            // No call to detect and no meeting key to suppress: the event id is already remembered by the watcher, so this event is not started again.
            let minutes = Self.describeMinutes(silentFor)
            Log.info(String(format: "stop (no-speech): both tracks below %.0f dBFS for %@ (mic %.1f, remote %.1f dBFS); the recording was started from the calendar",
                            Self.noSpeechThresholdDB, minutes, levels.mic, levels.remote))
            (rec as? SessionRecordingExtras)?.annotate("auto-stopped: no speech on either track (both below \(Int(Self.noSpeechThresholdDB)) dBFS) for \(minutes)")
            endRecording(.meetingEnded, enqueue: true, label: "no-speech", allowBlipDelete: false)
            machine.reset()
            notice = ("Recording stopped after \(minutes) without speech on either track. The next calendar event starts a new one.",
                      now.addingTimeInterval(Self.noticeSeconds))
            return
        }
        // Detection must still say "in a call": if it does not, the normal grace stop is about to end this recording anyway.
        guard let snap = lastSnapshot, let active = activeSignal(in: snap) else { return }

        let key = currentKey ?? Self.meetingKey(active)
        let minutes = Self.describeMinutes(silentFor)
        Log.info(String(format: "stop (no-speech): both tracks below %.0f dBFS for %@ (mic %.1f, remote %.1f dBFS) while detection still says in a call; %@",
                        Self.noSpeechThresholdDB, minutes, levels.mic, levels.remote, Self.describe(snap)))
        (rec as? SessionRecordingExtras)?.annotate("auto-stopped: no speech on either track (both below \(Int(Self.noSpeechThresholdDB)) dBFS) for \(minutes) while the call was still detected")
        endRecording(.meetingEnded, enqueue: true, label: "no-speech", allowBlipDelete: false)
        machine.reset()
        noSpeechStop = NoSpeechStop(key: key, logged: false)
        notice = ("Recording stopped after \(minutes) without speech on either track. It starts again with the next call.",
                  now.addingTimeInterval(Self.noticeSeconds))
    }

    /// "Until detection goes false once": the first snapshot without an in-call signal for that meeting ends the suppression.
    private func updateNoSpeechSuppression(_ snap: DetectionSnapshot) {
        guard let n = noSpeechStop else { return }
        if !snap.signals.contains(where: { $0.inCall && Self.sameMeeting(Self.meetingKey($0), n.key) }) {
            Log.info("no-speech suppression for \(n.key) lifted: detection says the call is over")
            noSpeechStop = nil
        }
    }

    /// "5 min", "15 min", "1 h 05 min"
    static func describeMinutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60)) min" : "\(m) min"
    }

    // MARK: Notifications (queue)

    /// The recorder says the remote track has been digital silence for 3+ minutes (a message is already in session.json).
    private func remoteSilentSuspected(session: String, label: String) {
        guard recorder != nil, currentDir?.lastPathComponent == session else { return }
        guard !remoteSilent else { return }
        remoteSilent = true
        Log.warn("remote audio suspected silent in \(session)")
        notify(.remoteSilent(platformLabel: label, session: session), key: "remote-silent:\(session)", interval: 0, now: clock())
        publish(clock())
    }

    /// One notification per cause (kind of failure) per 30 minutes, whatever the retry rhythm; the text says what to do about THIS cause.
    private func notifyStartFailure(_ message: String, kind: StartFailureKind, platform: Platform, label: String? = nil, now: Date) {
        notify(.recordingFailed(reason: message, kind: kind,
                                platformLabel: platform == .manual ? nil : (label ?? NotificationText.platformName(platform)),
                                logFile: Log.fileURL, contact: policyBox.policy.supportContact),
               key: "start-failed:\(kind)", interval: Self.startFailureNotifySeconds, now: now)
    }

    /// NOTIFY_RECORDING: the menu-bar icon can be hidden (notch, menu-bar managers); this is then the only sign that the meeting was noticed.
    private func notifyRecordingStarted(signal: PlatformSignal, dir: URL, manual: Bool, now: Date, fromCalendar: Bool = false) {
        let session = dir.lastPathComponent
        // A recording the GENERIC rule started (nobody named this app as a call app): the banner says which app looks like a call and how to stop it for
        // good. It is the one sign that this recording is a guess, so NOTIFY_RECORDING=0 does not switch it off (like the warnings).
        if signal.callKind == .generic, !manual {
            let tail = NotificationText.localOnlyTail(on: effectiveLocalOnly, policyExists: policyBox.policy.isEnforced)
            notify(.genericCallStarted(appName: NotificationText.platformName(signal), session: session, folder: dir, localOnlyTail: tail),
                   key: "recording-started:\(session)", interval: Self.recordingNoticeRepeatSeconds, now: now)
            return
        }
        guard config.notifyRecording else { return }
        // SPEC 18: the state of the flag at the end of the text, only when it is on or a policy exists (the personal default keeps
        // today's text); a local-only meeting (or LOG_CONTENT=0) leaves the meeting title out.
        let tail = NotificationText.localOnlyTail(on: effectiveLocalOnly, policyExists: policyBox.policy.isEnforced)
        notify(.recordingStarted(platformLabel: NotificationText.platformName(signal), manual: manual, titleHint: signal.titleHint,
                                 session: session, folder: dir, localOnlyTail: tail, hideTitle: hidesMeetingContent, fromCalendar: fromCalendar),
               key: "recording-started:\(session)", interval: Self.recordingNoticeRepeatSeconds, now: now)
    }

    private func postRecordingStopped(dir: URL, platformLabel: String, manual: Bool, seconds: Double, reason: EndReason, label: String?, hideTitle: Bool) {
        guard let n = recordingStoppedNotification(dir: dir, platformLabel: platformLabel, manual: manual, seconds: seconds, reason: reason, label: label, hideTitle: hideTitle) else { return }
        notify(n, key: "recording-stopped:\(dir.lastPathComponent)", interval: Self.recordingNoticeRepeatSeconds, now: clock())
    }

    /// The 'recording ended' notification of a session (nil when NOTIFY_RECORDING is off; the policy kill switch is always announced).
    private func recordingStoppedNotification(dir: URL, platformLabel: String, manual: Bool, seconds: Double, reason: EndReason, label: String?, hideTitle: Bool) -> AppNotification? {
        guard config.notifyRecording || label == Self.policyKillSwitchLabel else { return nil }
        let session = dir.lastPathComponent
        let note: StopNote
        if label == Self.policyKillSwitchLabel {
            note = .policyKillSwitch
        } else if label == "no-speech" {
            note = .noSpeech(minutes: max(1, Int(config.noSpeechStopMinutes.rounded())))
        } else {
            switch reason {
            case .diskLow: note = .diskLow
            case .maxDuration: note = .maxDuration
            case .sleep: note = .sleep
            default: note = .normal
            }
        }
        return .recordingStopped(platformLabel: platformLabel, manual: manual, durationSeconds: seconds,
                                 titleHint: hideTitle ? nil : lastTitle, session: session, folder: dir, note: note, hideTitle: hideTitle)
    }

    enum StopNoticeDecision: Equatable {
        case post                // say it now
        case skipUnconfirmed     // the start was never announced (weak evidence, never confirmed): no banner pair for a non-meeting
        case deferUntilOutcome   // a short call: wait for what the pipeline makes of it (a no-speech discard posts nothing)
    }

    /// When does an ended recording announce itself? (pure, see the self test)
    ///   - a manual recording: always (the user started it and knows about it);
    ///   - an AUTO recording whose start was never announced: never;
    ///   - a normal end (meeting-ended, not the no-speech stop) of an AUTO recording with less than `deferStopNoticeBelowSeconds` of inCall:
    ///     after the pipeline outcome is known, and not at all when the pipeline discards it for no speech;
    ///   - everything else (a long call, sleep, disk low, max duration, Pause / Stop Recording Now, the no-speech stop): now.
    static func stopNoticeDecision(manual: Bool, startNoticeSent: Bool, reason: EndReason, label: String?, inCallSeconds: Double) -> StopNoticeDecision {
        if manual { return .post }
        if !startNoticeSent { return .skipUnconfirmed }
        if reason == .meetingEnded, label == nil, inCallSeconds < deferStopNoticeBelowSeconds { return .deferUntilOutcome }
        return .post
    }

    /// The pipeline outcome of `session` is known: the held 'recording ended' notification is posted (the session is kept) or dropped (discarded).
    private func resolveDeferredStop(session: String, discarded: Bool) {
        guard let held = deferredStops.removeValue(forKey: session) else { return }
        if discarded {
            Log.info("'recording ended' notification for \(session) dropped: the pipeline discarded the session (no speech)")
        } else {
            notify(held.notification, key: held.key, interval: Self.recordingNoticeRepeatSeconds, now: clock())
        }
    }

    /// Did the pipeline leave a transcript without a meeting note: a local-only meeting, or the organisation denied the LLM lane
    /// (state.json `local_only` / `lanes`, read by the launcher)? Then "Meeting note ready" would not be true.
    private static func noteWasSkipped(_ outcome: PipelineOutcome?) -> Bool {
        guard let o = outcome else { return false }
        return o.localOnly == true || o.lanesSkipped.contains("llm")
    }

    /// "Meeting note ready" (or, without a note, "Transcript ready"): platform / length / folder from what the launcher read (session.json,
    /// state.json), else what this launch knows. A local-only meeting, or LOG_CONTENT=0, has no meeting title in the text.
    /// `session` finds the facts; `label` is the name that goes into the notification (its log line and its identifier): the session itself,
    /// or its content-free form for a meeting whose title must stay out of them.
    private func noteReadyNotification(session: String, label: String, title: String?, finalDir: URL?) -> AppNotification {
        let outcome = pipeline.outcome(forSession: session)
        let remembered = recordedFacts[session]
        let platform = outcome?.platform ?? remembered?.platform
        // A call of another app: session.json has the app's name, but the launcher only reads the platform, so this launch's own record names it.
        let platformText: String? = platform.map { $0 == .call ? (remembered?.label ?? NotificationText.platformName($0)) : NotificationText.platformName($0) }
        let seconds = outcome?.durationSeconds ?? remembered?.seconds
        let folder = finalDir ?? outcome?.folder ?? config.archiveDir
        if Self.noteWasSkipped(outcome) {
            return .transcriptReady(localOnly: outcome?.localOnly == true, session: label, platformLabel: platformText,
                                    durationSeconds: seconds, folder: folder)
        }
        return .noteReady(title: title, session: label, platformLabel: platformText,
                          durationSeconds: seconds, folder: folder, hideTitle: !privacy.logContent)
    }

    /// "Processing failed": reason kind / retry / reset time from state.json, the folder (published or staging) or the pipeline log to open.
    /// `label` and `message` are what may be shown (see `.failed` in `handlePipelineEvent`).
    private func pipelineFailedNotification(session: String, label: String, message: String) -> AppNotification {
        let outcome = pipeline.outcome(forSession: session)
        let log = outcome?.logFile.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? Log.fileURL
        return .pipelineFailed(session: label, reason: message, kind: outcome?.errorKind, retryable: outcome?.retryable,
                               resetsAt: outcome?.resetsAt, folder: outcome?.folder, logFile: log, contact: policyBox.policy.supportContact)
    }

    /// Must the texts about a session the pipeline reported on stay free of the meeting's title and of folder names? A
    /// local-only meeting (state.json `local_only`, read by the launcher), or LOG_CONTENT=0.
    private func hidesContent(of outcome: PipelineOutcome?) -> Bool { !privacy.logContent || outcome?.localOnly == true }

    /// The flag of the active recording, or the policy's lock.
    private var effectiveLocalOnly: Bool { (activeLocalOnly?.value ?? false) || policyBox.policy.forcesLocalOnly }

    /// A local-only meeting, or LOG_CONTENT=0: no meeting title (and no slug path) in notification texts and app.log lines.
    private var hidesMeetingContent: Bool { effectiveLocalOnly || !privacy.logContent }

    /// Posts unless the same key was posted less than `interval` seconds ago (0 = always).
    private func notify(_ n: AppNotification, key: String, interval: TimeInterval, now: Date) {
        guard interval <= 0 || throttle.allow(key: key, now: now, interval: interval) else {
            Log.info("notification '\(n.summary)' not repeated (same cause within \(Self.describeDelay(interval)))")
            return
        }
        notifier.post(n)
    }

    // MARK: Retry sweep (queue)

    /// What the sweep makes of one staging folder (pure, see the self-test).
    enum SweepClass: Equatable {
        case ignore                              // done, nothing to do, or failed in a way a retry cannot fix
        case failedDue                           // failed, retryable, any usage-limit reset time has passed -> `mcap reprocess --pending`
        case failedWaiting(until: Date)          // failed, retryable, but Claude's usage limit resets later: not before that time
        case failedExhausted                     // failed, retryable, but already failed `sweepAttemptCap` times
        case interrupted                         // has a finished session.json but state.json is missing / not done / not failed
    }

    static func sweepClass(state: [String: Any]?, hasFinishedSession: Bool, now: Date, attemptCap: Int = sweepAttemptCap) -> SweepClass {
        let stage = state?["stage"] as? String
        if stage == "done" { return .ignore }
        if stage == "failed" {
            guard (state?["retryable"] as? Bool) == true else { return .ignore }
            if let text = state?["resets_at"] as? String, let due = ShellUtil.parseISO8601(text), due > now { return .failedWaiting(until: due) }
            let attempts = (state?["attempts"] as? NSNumber)?.intValue ?? 0
            return attempts >= attemptCap ? .failedExhausted : .failedDue
        }
        return hasFinishedSession ? .interrupted : .ignore
    }

    /// Housekeeping hook: runs the sweep when it is due. Never while a recording is active (a heavy job would compete with the
    /// recorder; it simply stays due and runs after the recording).
    private func runSweepIfDue(_ now: Date) {
        guard let due = nextSweepAt, config.retrySweepHours > 0, now >= due, recorder == nil, !isShutDown else { return }
        let result = sweepLocked(now: now)
        var next = now.addingTimeInterval(config.retrySweepHours * 3600)
        if let reset = result.earliestReset { next = min(next, max(reset.addingTimeInterval(60), now.addingTimeInterval(60))) }
        nextSweepAt = next
    }

    struct SweepResult {
        var failedDue = 0
        var waiting = 0
        var exhausted = 0
        var interrupted: [URL] = []
        var earliestReset: Date?
    }

    /// Looks at staging: failed + retryable sessions are retried together by `mcap reprocess --pending` (Python decides again,
    /// per session); interrupted sessions (killed by the watchdog, a crash, an app quit) are enqueued like the startup scan does.
    /// Everything goes through the launcher's single serial queue, so two pipeline jobs never overlap.
    @discardableResult
    func sweepLocked(now: Date) -> SweepResult {
        let fm = FileManager.default
        var result = SweepResult()
        let entries = (try? fm.contentsOfDirectory(at: config.sessionsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = dir.lastPathComponent
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, !name.hasPrefix("_") else { continue }
            if let active = currentDir, ShellUtil.sameFile(active, dir) { continue }
            let session = ShellUtil.readJSON(dir.appendingPathComponent("session.json"))
            // A finished session: session.json exists and its end_time is set (a null end_time is a live or crashed recording:
            // the startup scan owns crash recovery and the live-recording protection).
            let finished = session != nil && !(session?["end_time"] == nil || session?["end_time"] is NSNull)
            switch Self.sweepClass(state: ShellUtil.readJSON(dir.appendingPathComponent("state.json")), hasFinishedSession: finished, now: now) {
            case .ignore: break
            case .failedDue:
                // Already queued or running in the launcher (so the next result is not known yet), or the startup scan gave it
                // its one more try a moment ago (first sweep only): do not start a second run for it right behind the first.
                if pipeline.isProcessing(dir) || (sweepsRun == 0 && retriedFailed.contains(name)) { continue }
                result.failedDue += 1
            case .failedWaiting(let until):
                result.waiting += 1
                if result.earliestReset == nil || until < result.earliestReset! { result.earliestReset = until }
            case .failedExhausted:
                result.exhausted += 1
                Log.info("retry sweep: \(name) already failed \(Self.sweepAttemptCap) times; not retrying it automatically (run `mcap reprocess <folder>` or use the menu)")
            case .interrupted:
                guard !pipeline.isProcessing(dir) else { continue }
                guard (sweepEnqueues[name] ?? 0) < Self.maxSweepEnqueues else {
                    Log.info("retry sweep: \(name) was enqueued \(Self.maxSweepEnqueues) times in this launch without finishing; leaving it for the next launch")
                    continue
                }
                sweepEnqueues[name, default: 0] += 1
                result.interrupted.append(dir)
            }
        }
        sweepsRun += 1
        for dir in result.interrupted { pipeline.enqueue(dir) }
        if result.failedDue > 0 { pipeline.reprocessPending() }
        if result.failedDue + result.interrupted.count + result.waiting + result.exhausted == 0 {
            Log.info("retry sweep: nothing pending")
        } else {
            var parts: [String] = []
            if result.failedDue > 0 { parts.append("\(result.failedDue) failed retryable session(s) -> mcap reprocess --pending") }
            if !result.interrupted.isEmpty { parts.append("\(result.interrupted.count) interrupted session(s) enqueued") }
            if result.waiting > 0 { parts.append("\(result.waiting) waiting for a Claude usage-limit reset (earliest \(result.earliestReset.map { ShellUtil.iso8601($0) } ?? "?"))") }
            if result.exhausted > 0 { parts.append("\(result.exhausted) failed too often for automatic retries") }
            Log.info("retry sweep: " + parts.joined(separator: "; "))
            if pipelineText == nil, result.failedDue > 0 || !result.interrupted.isEmpty { pipelineText = "Queued" }
        }
        publish(now)
        return result
    }

    // MARK: Pipeline events (queue)

    private func handlePipelineEvent(_ event: PipelineEvent) {
        guard !isShutDown else { return }
        let now = clock()
        switch event {
        case .progress(_, let text):
            pipelineText = text
        case .finished(let session, let title, let finalDir, let discarded):
            pipelineText = nil
            if pipelineError?.session == session { pipelineError = nil }
            if notice?.text == Self.waitingForServerNotice { notice = nil }
            resolveDeferredStop(session: session, discarded: discarded)
            if discarded {
                Log.info("session \(session) discarded by pipeline (no speech)")
            } else {
                let outcome = pipeline.outcome(forSession: session)
                // The menu line "Done: <title>" carries no meeting title for a local-only meeting (nor under LOG_CONTENT=0, nor when no note was made).
                let doneText: String
                if Self.noteWasSkipped(outcome) {
                    doneText = outcome?.localOnly == true ? "Transcript ready (local-only)" : "Transcript ready (note skipped by policy)"
                } else {
                    doneText = privacy.logContent ? (title ?? "Meeting note ready") : "Meeting note ready"
                }
                done = (title: doneText, until: now.addingTimeInterval(Self.doneDisplaySeconds))
                // A session the retry sweep finished is named by its PUBLISHED folder (date, time and the slug of its title): for a local-only
                // meeting, and under LOG_CONTENT=0, that name does not go into the notification (its log line, its identifier).
                let label = hidesContent(of: outcome) ? NotificationText.contentFreeSession(session) : session
                notify(noteReadyNotification(session: session, label: label, title: title, finalDir: finalDir), key: "done:\(session)", interval: 0, now: now)
            }
        case .failed(let session, let message):
            resolveDeferredStop(session: session, discarded: false)
            pipelineText = nil
            let outcome = pipeline.outcome(forSession: session)
            // A failure text comes from Python and can name the folder the session was being moved to ("cannot move session to <folder>":
            // its slug carries the meeting title). For a local-only meeting, and under LOG_CONTENT=0, no path and no folder name goes into
            // app.log, the menu line or the notification.
            let hide = hidesContent(of: outcome)
            let shown = hide ? NotificationText.withoutPaths(message) : message
            let label = hide ? NotificationText.contentFreeSession(session) : session
            if outcome?.errorKind == "asr_unreachable" {
                // The transcription server did not answer: not a failed meeting. The recording is kept and the retry
                // (startup scan, sweep) processes it when the server is back: a quiet notice, no error status, no sound.
                Log.warn("pipeline: \(label) waits for the transcription server (asr_unreachable): \(shown)")
                notice = (Self.waitingForServerNotice, now.addingTimeInterval(Self.noticeSeconds))
                if pipelineError?.session == session { pipelineError = nil }
                notify(.waitingForServer(session: label, folder: outcome?.folder), key: "waiting-for-server:\(session)",
                       interval: Self.pipelineFailureNotifySeconds, now: now)
            } else {
                pipelineError = (session: session, text: "Processing failed (\(label)): \(shown)")
                Log.error("pipeline failed for \(label): \(shown)")
                if message != PipelineLauncher.reprocessBlockedMessage {       // the user's own click on a disabled action is not news
                    notify(pipelineFailedNotification(session: session, label: label, message: shown), key: "pipeline-failed:\(session)",
                           interval: Self.pipelineFailureNotifySeconds, now: now)
                }
            }
        case .blocked(let session, let block):
            // The launcher did not start the pipeline. The session is untouched in staging: say why, once in a while.
            resolveDeferredStop(session: session, discarded: false)
            pipelineText = nil
            pipelineError = (session: session, text: "Pipeline not started (\(session)): \(block.logText). The recording stays in staging.")
            Log.error("pipeline not started for \(session): \(block.logText)")
            let outcome = pipeline.outcome(forSession: session)
            notify(.pipelineBlocked(block, session: session, contact: policyBox.policy.supportContact, logFile: outcome?.logFile ?? Log.fileURL),
                   key: "pipeline-blocked:\(block.key)", interval: Self.pipelineFailureNotifySeconds, now: now)
        case .nothingToReport(let session):
            pipelineText = nil
            if pipelineError?.session == session { pipelineError = nil }
        }
        publish(now)
    }

    // MARK: Crash recovery & startup scan (queue)

    /// What the scan does with a session that has a session.json, judged by its state.json (pure, see the tests).
    enum ScanDecision: Equatable {
        case skip                              // done, or failed in a way that is never retried automatically
        case enqueue                           // never processed, or interrupted mid-run
        case retryFailed(kind: String)         // failed, retryable, and of a kind worth one more try per launch
    }

    static func scanDecision(state: [String: Any]?) -> ScanDecision {
        guard let state = state, let stage = state["stage"] as? String else { return .enqueue }
        switch stage {
        case "done":
            return .skip
        case "failed":
            if (state["retryable"] as? Bool) == true, let kind = state["error_kind"] as? String, retryableFailureKinds.contains(kind) {
                return .retryFailed(kind: kind)
            }
            return .skip
        default:
            return .enqueue
        }
    }

    /// What the pipeline leaves in staging after publish / discard: a folder with only a state.json (stage done or failed,
    /// title, final_dir) and no session.json or audio. The menu reads it; the scan ignores it, silently.
    static func isStateTombstone(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let state = ShellUtil.readJSON(dir.appendingPathComponent("state.json")),
              let stage = state["stage"] as? String, stage == "done" || stage == "failed" else { return false }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return !names.contains("session.json") && !names.contains { $0.lowercased().hasSuffix(".wav") }
    }

    /// Seconds since the newest WAV of the folder was written (nil without a WAV). Clock skew counts as "just now".
    static func newestWavAge(in dir: URL, now: Date) -> TimeInterval? {
        let fm = FileManager.default
        var newest: Date?
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.lowercased().hasSuffix(".wav") {
            guard let m = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.modificationDate] as? Date else { continue }
            if newest == nil || m > newest! { newest = m }
        }
        return newest.map { max(0, now.timeIntervalSince($0)) }
    }

    /// Scans sessions/*: closes sessions whose end_time is null (crash) and enqueues everything that still needs
    /// the pipeline. Rules:
    ///  * the active recording, folders starting with "_" (sessions/_discarded/), and state-only tombstones are ignored
    ///    silently (no log line per launch);
    ///  * a session with end_time == null whose WAV was written within `liveRecordingWindow` is not touched at all (it may
    ///    be a live recording; typically it is the crash of a moment ago, which launchd restarted us after): the scan
    ///    looks at it again once the window has passed;
    ///  * state done: never again; state failed: only when retryable and of a retryable kind, once per app launch.
    /// Returns the enqueued dirs.
    @discardableResult
    func recoverSessions() -> [URL] {
        return queue.sync { recoverSessionsLocked() }
    }

    private func recoverSessionsLocked(only: Set<String>? = nil) -> [URL] {
        let fm = FileManager.default
        let now = clock()
        guard let entries = try? fm.contentsOfDirectory(at: config.sessionsDir,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var enqueued: [URL] = []
        var recheck: [String: TimeInterval] = [:]          // skipped as "maybe live": name -> seconds until the window is over
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = dir.lastPathComponent
            if let only = only, !only.contains(name) { continue }
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, !name.hasPrefix("_") else { continue }
            if let active = currentDir, ShellUtil.sameFile(active, dir) { continue }

            let sessionFile = dir.appendingPathComponent("session.json")
            guard fm.fileExists(atPath: sessionFile.path) else {
                if !Self.isStateTombstone(dir) { Log.info("startup scan: \(name) has no session.json; leaving it alone") }
                continue
            }
            guard var meta = ShellUtil.readJSON(sessionFile) else {
                Log.warn("startup scan: \(name)/session.json is unreadable; leaving it (audio is kept)")
                continue
            }

            if meta["end_time"] == nil || meta["end_time"] is NSNull {
                if let age = Self.newestWavAge(in: dir, now: now), age < Self.liveRecordingWindow {
                    let wait = (Self.liveRecordingWindow - age).rounded(.up) + 3
                    Log.info("startup scan: \(name) has no end_time and its audio was written \(Int(age.rounded())) s ago: it may be a live recording, "
                             + "not touching it (looking again in \(Int(wait)) s)")
                    recheck[name] = wait
                    continue
                }
                recoverCrashedSession(dir: dir, meta: &meta, sessionFile: sessionFile)
            }

            switch Self.scanDecision(state: ShellUtil.readJSON(dir.appendingPathComponent("state.json"))) {
            case .skip:
                continue
            case .enqueue:
                Log.info("startup scan: enqueue \(name) for processing")
            case .retryFailed(let kind):
                guard retriedFailed.insert(name).inserted else { continue }      // once per app launch
                Log.info("startup scan: \(name) failed earlier (\(kind), retryable); trying it once more")
            }
            pipeline.enqueue(dir)
            enqueued.append(dir)
        }
        if !enqueued.isEmpty { pipelineText = pipelineText ?? "Queued" }
        if let wait = recheck.values.min(), liveRescans < Self.maxLiveRescans, !isShutDown {
            liveRescans += 1
            let names = Set(recheck.keys)
            scheduleRescan(wait) { [weak self] in
                guard let self = self, !self.isShutDown else { return }
                _ = self.recoverSessionsLocked(only: names)
                self.publish(self.clock())
            }
        }
        return enqueued
    }

    /// 16-bit mono WAV: seconds = (bytes - 44) / (2 * sample_rate). end_time = start_time + longest track.
    /// Every track's WAV header is repaired too (a crashed file's RIFF/data sizes lag by up to ~5 s), so afconvert and
    /// QuickTime see the whole recording and not only the part covered by the last header refresh.
    private func recoverCrashedSession(dir: URL, meta: inout [String: Any], sessionFile: URL) {
        let fm = FileManager.default
        var longest = 0.0
        if let tracks = meta["tracks"] as? [String: Any] {
            for (name, value) in tracks {
                // The file name comes from session.json: accept a plain name inside the session folder only.
                guard let track = value as? [String: Any], let file = track["file"] as? String,
                      !file.isEmpty, !file.contains("/") else { continue }
                let url = dir.appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value, size > 44 else { continue }
                var rate = (track["sample_rate"] as? NSNumber)?.doubleValue ?? 0
                if rate <= 0 { rate = Self.wavSampleRate(url) ?? 0 }
                guard rate > 0 else {
                    Log.warn("crash recovery: no sample rate for \(dir.lastPathComponent)/\(name)")
                    continue
                }
                let offset = (track["start_offset_sec"] as? NSNumber)?.doubleValue ?? 0
                longest = max(longest, offset + Double(size - 44) / (2 * rate))
                repairWavHeader(url, label: "\(dir.lastPathComponent)/\(file)")
            }
        }
        let startDate = (meta["start_time"] as? String).flatMap(ShellUtil.parseISO8601)
        guard let start = startDate else {
            Log.warn("crash recovery: \(dir.lastPathComponent) has no valid start_time; leaving session.json untouched")
            return
        }
        meta["end_time"] = ShellUtil.iso8601(start.addingTimeInterval(longest.rounded()))   // whole seconds, like the recorder
        meta["end_reason"] = EndReason.crashRecovered.rawValue
        do {
            try ShellUtil.writeJSONAtomically(meta, to: sessionFile)
            Log.warn(String(format: "crash recovery: %@ closed at %.1fs of audio", dir.lastPathComponent, longest))
        } catch {
            Log.error("crash recovery: cannot rewrite \(sessionFile.path): \(error)")
        }
    }

    /// Fixes the RIFF/data size fields of a crashed WAV with the capture owner's `WavWriter.repairHeader(at:)`. Skips
    /// files whose header is already right and files whose own sample-rate field is implausible (repairHeader builds the
    /// new header from that field). A failure is logged and harmless: the Python reader recovers from the file length.
    private func repairWavHeader(_ url: URL, label: String) {
        if Self.wavHeaderMatchesFileSize(url) { return }
        guard let rate = Self.wavSampleRate(url), (1_000...768_000).contains(Int(rate)) else {
            Log.warn("crash recovery: \(label) has no plausible WAV sample rate; header left as is")
            return
        }
        _ = WavWriter.repairHeader(at: url)
        if Self.wavHeaderMatchesFileSize(url) {
            Log.info("crash recovery: repaired the WAV header of \(label)")
        } else {
            Log.warn("crash recovery: could not repair the WAV header of \(label) (the pipeline reads it by file length)")
        }
    }

    /// True when a canonical 44-byte header's RIFF size (bytes 4..7) and data size (bytes 40..43) match the file length.
    static func wavHeaderMatchesFileSize(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 44), data.count >= 44 else { return false }
        let size = ((try? h.seekToEnd()) ?? 0)
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt64 { UInt64(b[o]) | UInt64(b[o + 1]) << 8 | UInt64(b[o + 2]) << 16 | UInt64(b[o + 3]) << 24 }
        return u32(4) == size - 8 && u32(40) == size - 44
    }

    /// Sample rate from a canonical WAV header (bytes 24..27, little endian).
    private static func wavSampleRate(_ url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 28), data.count >= 28 else { return nil }
        let b = [UInt8](data)
        let rate = UInt32(b[24]) | UInt32(b[25]) << 8 | UInt32(b[26]) << 16 | UInt32(b[27]) << 24
        return rate > 0 ? Double(rate) : nil
    }

    // MARK: Policy and the per-meeting local-only flag (SPEC 18; queue)

    /// "absent" | "valid (company, revision 12, sha256 ab12cd34)" | "LOCKED (reason code)": content-free, for app.log.
    static func describePolicy(_ p: OrgPolicy) -> String {
        switch p.state {
        case .absent: return "absent"
        case .valid: return "valid (profile \(p.profile), revision \(p.revision.map(String.init) ?? "?"), sha256 \(p.sha256Prefix ?? "?"))"
        case .invalid(let reason): return "LOCKED (\(reason))"
        }
    }

    /// A policy that cannot be read: said once in a while per reason code (the file is read again every poll).
    private func notifyPolicyProblem(_ p: OrgPolicy, now: Date) {
        guard p.isLocked else { return }
        notify(.policyProblem(reasonText: p.lockedReasonText ?? OrgPolicy.reasonText(forCode: "internal-error"), contact: p.supportContact, logFile: Log.fileURL),
               key: "policy-problem:\(p.lockedCode ?? "?")", interval: Self.pipelineFailureNotifySeconds, now: now)
    }

    /// The policy was read again (every `policyPollSeconds`). A change replaces the shared box, which the launcher and the menu read; the
    /// recording kill switch (recording.enabled=false) ends an active recording right here: end_reason manual, label policy-kill-switch,
    /// the audio is kept and goes to the pipeline like any other stop.
    private func applyPolicy(_ fresh: OrgPolicy, now: Date) {
        let before = policyBox.policy
        guard fresh != before else { return }
        policyBox.policy = fresh
        Log.info("policy changed: \(Self.describePolicy(before)) -> \(Self.describePolicy(fresh))")
        if fresh.isLocked, fresh.lockedCode != before.lockedCode { notifyPolicyProblem(fresh, now: now) }
        if !fresh.recordingEnabled {
            if recorder != nil {
                Log.warn("policy: recording.enabled=false (revision \(fresh.revision.map(String.init) ?? "?")): ending the active recording (\(Self.policyKillSwitchLabel))")
                endRecording(.manual, enqueue: true, label: Self.policyKillSwitchLabel, allowBlipDelete: false)
                machine.reset()
            }
        } else if !before.recordingEnabled {
            // Recording is allowed again: a start refused because of the switch must not keep holding the meeting back.
            Log.info("policy: recording is enabled again")
            startFailure = nil
            recordError = nil
        }
    }

    /// Is `stage` one in which the flag can still take effect (before publishing)? An unknown stage is not.
    static func stageIsBeforePublishing(_ stage: String?) -> Bool {
        guard let stage = stage else { return false }
        return stagesBeforePublishing.contains(stage)
    }

    private struct EndedFacts {
        var gone: Bool                  // the staging folder or its session.json is not there any more (published, deleted)
        var stateFileExists: Bool       // the pipeline has started: state.json is there
        var beforePublishing: Bool      // no state.json yet, or its stage is before publishing
    }

    private func endedFacts(_ e: EndedSession) -> EndedFacts {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let gone = !(fm.fileExists(atPath: e.dir.path, isDirectory: &isDir) && isDir.boolValue) || !fm.fileExists(atPath: e.dir.appendingPathComponent("session.json").path)
        let stateURL = e.dir.appendingPathComponent("state.json")
        let exists = fm.fileExists(atPath: stateURL.path)
        let stage = ShellUtil.readJSON(stateURL)?["stage"] as? String
        // A state.json that cannot be read counts as "started, stage unknown": never claim the flag can still be changed.
        return EndedFacts(gone: gone, stateFileExists: exists, beforePublishing: !exists || Self.stageIsBeforePublishing(stage))
    }

    /// Would the pipeline honour the flag at `value`? No requirement (nothing a policy or a local-only meeting asks for) = yes.
    /// An UNKNOWN pipeline version is no: the old pipeline of the personal install never asks for its version at start and never re-reads
    /// session.json, so accepting a toggle ON for it would show 'local-only: no Claude, no calendar, no Drive' for a meeting that still
    /// goes to Claude and Drive. The version is asked for in the background (`probePipelineVersion`) and the menu is computed again when
    /// the answer is there (`onVersionKnown`); until then the item is disabled ('pipeline too old' is the closest of the texts).
    private func pipelineAccepts(localOnly value: Bool) -> Bool {
        guard let need = PipelineContract.required(policy: policyBox.policy, sessionLocalOnly: value) else { return true }
        if pipeline.pipelineVersion == nil { pipeline.probePipelineVersion() }       // returns at once; a fake that knows the answer sets it here
        guard let have = pipeline.pipelineVersion else { return false }
        return PipelineContract.satisfied(version: have, required: need)
    }

    /// The menu item's facts.
    private func localOnlyView() -> LocalOnlyView {
        let policy = policyBox.policy
        let forced = policy.forcesLocalOnly
        if recorder != nil, let current = activeLocalOnly, let dir = currentDir {
            let value = current.value || forced
            return LocalOnlyView(value: value, locked: forced, targetSession: dir.lastPathComponent, canRelax: !forced,
                                 pipelineTooOld: !pipelineAccepts(localOnly: !value))
        }
        if let e = ended {
            let facts = endedFacts(e)
            let value = e.value.value || forced
            let usable = !facts.gone && facts.beforePublishing
            return LocalOnlyView(value: value, locked: forced, targetSession: usable ? e.dir.lastPathComponent : nil,
                                 canRelax: usable && !forced && !facts.stateFileExists, pipelineTooOld: !pipelineAccepts(localOnly: !value))
        }
        let initial = LocalOnlyResolver.initial(policy: policy, settings: privacy)
        return LocalOnlyView(value: initial.value, locked: forced, targetSession: nil, canRelax: false, pipelineTooOld: false)
    }

    /// The ended session is forgotten once it can no longer take a change (published, gone, or past publishing): no more file reads.
    private func forgetEndedIfSettled() {
        guard let e = ended else { return }
        let facts = endedFacts(e)
        if facts.gone || !facts.beforePublishing { ended = nil }
    }

    /// What is true for the NEXT meeting, as the menu's idle lines (EffectiveLanes). Cached. Comparing ARCHIVE_DIR with the policy's archive
    /// roots resolves the path (lstat on every component: a Google Drive mount can be slow or gone), and the controller queue starts and
    /// stops recordings: when the answer needs that, it is computed on a background queue (no lines until it is there) and published when
    /// ready. Everything else is computed at once.
    private func idleInfoLines() -> [String] {
        let policy = policyBox.policy
        let start = LocalOnlyResolver.initial(policy: policy, settings: privacy)
        if let cached = infoCache, cached.policy == policy, cached.localOnly == start.value { return cached.lines }
        let settings = privacy, archive = config.archiveDir
        guard policy.archiveAllowedRoots != nil, policy.laneAllowed("drive"), !start.value else {
            let lines = EffectiveLanes.compute(policy: policy, localOnly: start.value, settings: settings, archiveDir: archive).idleLinesText
            infoCache = (policy, start.value, lines)
            return lines
        }
        if let pending = infoPending, pending.policy == policy, pending.localOnly == start.value { return [] }
        infoPending = (policy, start.value)
        infoQueue.async { [weak self] in
            let lines = EffectiveLanes.compute(policy: policy, localOnly: start.value, settings: settings, archiveDir: archive).idleLinesText
            self?.queue.async {
                guard let self = self, !self.isShutDown else { return }
                self.infoCache = (policy, start.value, lines)
                self.infoPending = nil
                self.publish(self.clock())
            }
        }
        return []
    }

    /// The menu item "Local-Only Meeting" (any thread; the work is done on the controller queue). Flips the flag of the target meeting:
    /// the active recording, else the one that was just recorded while the pipeline has not published it. `to` asks for a value.
    /// A refusal or warning is also posted as a notification; a success says what is true now.
    @discardableResult
    func toggleLocalOnly(to want: Bool? = nil) -> LocalOnlyToggleResult {
        return queue.sync { toggleLocalOnlyLocked(to: want) }
    }

    private func toggleLocalOnlyLocked(to want: Bool?) -> LocalOnlyToggleResult {
        guard !isShutDown else { return .noTarget }
        let now = clock()
        let policy = policyBox.policy
        var result: LocalOnlyToggleResult = .noTarget
        var changed = true                                  // false: the meeting already had the asked value, nothing was written
        if let rec = recorder, let current = activeLocalOnly, let dir = currentDir {
            (result, changed) = toggleActive(rec: rec, dir: dir, current: current, to: want, policy: policy)
        } else if let e = ended {
            (result, changed) = toggleEnded(e, to: want, policy: policy)
        }
        let session = (recorder != nil ? currentDir : ended?.dir)?.lastPathComponent ?? "-"
        let platformLabel: String? = recorder != nil ? currentLabel : ended.map { $0.label }
        switch result {
        case .applied(let value):
            if changed {
                Log.info("local_only toggled: \(value.value) (\(value.source)) for \(session)")
                postToggled(value, session: session, platformLabel: platformLabel, now: now)
            } else {
                Log.info("local_only toggle: \(session) already has \(value.value); nothing changed")
            }
        case .appliedMaybeLate:
            notify(.localOnlyProblem(.maybeLate, session: session), key: "local-only:\(session)", interval: 0, now: now)
        case .refusedLocked:
            notify(.localOnlyLocked(contact: policy.supportContact, session: session), key: "local-only:\(session)", interval: 0, now: now)
        case .tooLate:
            notify(.localOnlyProblem(.tooLate, session: session), key: "local-only:\(session)", interval: 0, now: now)
        case .pipelineTooOld:
            notify(.localOnlyProblem(.pipelineTooOld, session: session), key: "local-only:\(session)", interval: 0, now: now)
        case .writeFailed:
            notify(.localOnlyProblem(.writeFailed, session: session, logFile: Log.fileURL), key: "local-only:\(session)", interval: 0, now: now)
        case .noTarget:
            Log.info("local_only toggle ignored: no recording and no recent session that can still take it")
        }
        publish(now)
        return result
    }

    private func postToggled(_ value: LocalOnlyValue, session: String, platformLabel: String?, now: Date) {
        if value.value {
            notify(.localOnlyOn(platformLabel: platformLabel, session: session), key: "local-only:\(session)", interval: 0, now: now)
        } else {
            let lanes = EffectiveLanes.compute(policy: policyBox.policy, localOnly: false, settings: privacy, archiveDir: config.archiveDir)
            notify(.localOnlyOff(summary: lanes.summaryText, session: session), key: "local-only:\(session)", interval: 0, now: now)
        }
    }

    /// During the recording: the recorder rewrites session.json (and keeps the private history); the file is read back before success.
    private func toggleActive(rec: SessionRecording, dir: URL, current: LocalOnlyValue, to want: Bool?,
                              policy: OrgPolicy) -> (LocalOnlyToggleResult, changed: Bool) {
        guard let privacyRecorder = rec as? SessionRecordingPrivacy else { return (.noTarget, false) }
        let nowValue = current.value || policy.forcesLocalOnly
        let target = want ?? !nowValue
        if target == nowValue { return (.applied(current), false) }
        guard let next = LocalOnlyResolver.toggled(from: LocalOnlyValue(value: nowValue, source: current.source, locked: current.locked || policy.forcesLocalOnly),
                                                   to: target, policy: policy, source: "menu") else { return (.refusedLocked, false) }
        guard pipelineAccepts(localOnly: next.value) else { return (.pipelineTooOld, false) }
        guard privacyRecorder.setLocalOnly(next.value, source: next.source) else {
            return (.writeFailed("the recorder could not write session.json"), false)
        }
        guard Self.sessionLocalOnly(in: dir) == next.value else {
            return (.writeFailed("session.json does not say \(next.value) after the write"), false)
        }
        activeLocalOnly = next
        return (.applied(next), true)
    }

    /// After the stop: state -> patch session.json atomically -> read back -> state again. ON until the pipeline publishes,
    /// OFF only while it has not started (no state.json).
    private func toggleEnded(_ e: EndedSession, to want: Bool?, policy: OrgPolicy) -> (LocalOnlyToggleResult, changed: Bool) {
        let before = endedFacts(e)
        if before.gone { return (.tooLate, false) }
        let nowValue = e.value.value || policy.forcesLocalOnly
        let target = want ?? !nowValue
        if target == nowValue { return (.applied(e.value), false) }
        guard let next = LocalOnlyResolver.toggled(from: LocalOnlyValue(value: nowValue, source: e.value.source, locked: e.value.locked || policy.forcesLocalOnly),
                                                   to: target, policy: policy, source: "menu-after-stop") else { return (.refusedLocked, false) }
        if !before.beforePublishing { return (.tooLate, false) }
        if !next.value && before.stateFileExists { return (.tooLate, false) }   // the pipeline has started: it may have seen the ON already
        guard pipelineAccepts(localOnly: next.value) else { return (.pipelineTooOld, false) }
        do {
            try sessionPatch(next.value, next.source, e.dir)
        } catch {
            Log.warn("local_only: cannot patch session.json of \(e.dir.lastPathComponent): \(error)")
            return (.writeFailed("\(error)"), false)
        }
        let after = endedFacts(e)
        // Read back (the patch did it once already; a patcher is replaceable). A folder that is gone by now is not a failed write: the
        // pipeline published it meanwhile, which is the 'may be late' case below.
        if !after.gone, Self.sessionLocalOnly(in: e.dir) != next.value {
            Log.warn("local_only: session.json of \(e.dir.lastPathComponent) does not say \(next.value) after the patch")
            return (.writeFailed("session.json does not say \(next.value) after the patch"), false)
        }
        ended?.value = next
        SessionPrivateLog.append(session: e.dir.lastPathComponent, supportDir: config.supportDir,
                                 entry: ["at": ShellUtil.iso8601(clock()), "value": next.value, "source": next.source, "phase": "after-stop"])
        // The pipeline can have moved on while the file was written: from publishing on (or when the folder is gone) the claim is only
        // 'may not have taken effect'; an OFF that meets a state.json that was not there before may come too late for a ratchet.
        if after.gone || !after.beforePublishing || (!next.value && after.stateFileExists) {
            Log.warn("local_only=\(next.value) was written for \(e.dir.lastPathComponent), but processing had already moved on: it may not have taken effect")
            return (.appliedMaybeLate, true)
        }
        return (.applied(next), true)
    }

    /// session.json's `local_only` when it is a real boolean (nil: unreadable, missing or not a boolean).
    static func sessionLocalOnly(in dir: URL) -> Bool? {
        guard let json = ShellUtil.readJSON(dir.appendingPathComponent("session.json")), let raw = json["local_only"] as? NSNumber,
              CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return raw.boolValue
    }

    // MARK: Pause Microphone

    /// The menu item 'Pause Microphone' (any thread; the work is done on the controller queue): while paused the recorder writes zeros for the
    /// microphone, whatever the meeting app's own mute says. The guaranteed path of the mute gate: it needs no signal. Only while a gated
    /// recording runs; the pause ends with the recording. `to` asks for a value.
    @discardableResult
    func toggleMicrophonePause(to want: Bool? = nil) -> MicPauseResult {
        return queue.sync { toggleMicrophonePauseLocked(to: want) }
    }

    private func toggleMicrophonePauseLocked(to want: Bool?) -> MicPauseResult {
        guard !isShutDown, let rec = recorder else { return .noRecording }
        guard privacy.micMuteGate == "on", let gated = rec as? SessionRecordingMicGate, gated.muteGateEnabled else { return .notAvailable }
        let target = want ?? !micPaused
        if target == micPaused { return .applied(paused: micPaused) }
        guard gated.setMicrophonePaused(target) else {
            Log.warn("microphone \(target ? "pause" : "resume") was not accepted by the recorder")
            return .notAvailable
        }
        micPaused = target
        Log.info("microphone \(target ? "paused" : "resumed") from the menu")
        publish(clock())
        return .applied(paused: target)
    }

    /// The menu view of the gate: nil when MIC_MUTE_GATE is off (the personal install shows nothing new).
    private func micGateView() -> MicGateView? {
        guard privacy.micMuteGate == "on" else { return nil }
        let usable = (recorder as? SessionRecordingMicGate)?.muteGateEnabled == true
        return MicGateView(recording: usable, paused: usable && micPaused)
    }

    // MARK: Publishing (queue)

    private func computeState(now: Date) -> ControllerState {
        var st = ControllerState()
        st.paused = paused
        st.installHold = installHold
        st.manualRecording = recorder != nil && currentIsManual
        st.calendarRecording = recorder != nil && currentCalendarEvent != nil
        st.warning = recorder != nil ? warning : nil
        st.autoDetectionOff = config.enabledPlatforms.isEmpty
        st.remoteSilentSuspected = recorder != nil && remoteSilent
        if let n = notice, now < n.until { st.notice = n.text }
        st.recordingBlockedByPolicy = !policyBox.policy.recordingEnabled
        st.localOnly = localOnlyView()
        st.infoLines = idleInfoLines()
        st.micGate = micGateView()
        st.restartHold = currentRestartHold()

        if let rec = recorder {
            st.status = .recording(currentPlatform, since: rec.startedAt)
            st.callApp = currentCall
        } else if !paused, !installHold, machine.isCandidate, !machine.candidateIsWeakOnly, let best = lastSnapshot?.best, !isSuppressed(Self.meetingKey(best), now: now) {
            st.status = .candidate(best.platform)
            if best.platform == .call { st.callApp = CallAppView(signal: best, name: NotificationText.platformName(best)) }
        } else if let e = recordError {
            st.status = .error(e)
        } else if let t = pipelineText {
            st.status = .processing(t)
        } else if let e = pipelineError {
            st.status = .error(e.text)
        } else if let d = done, now < d.until {
            st.status = .done(d.title)
        } else {
            st.status = .idle
        }
        return st
    }

    /// Paused, a call stopped by hand (or for no speech) that is still running, or a call detected that is about to be recorded: a relaunch forgets all three
    /// (they are in memory only) and the new process would record the call again.
    private func currentRestartHold() -> RestartHold? {
        if paused { return .paused }
        if userStop != nil || noSpeechStop != nil { return .stoppedCall }
        if machine.isCandidate && !machine.candidateIsWeakOnly { return .callLive }
        return nil
    }

    private func isSuppressed(_ key: String, now: Date) -> Bool {
        if let f = startFailure, Self.throttleApplies(failedKey: f.key, to: key), now < f.until { return true }
        if let u = userStop, Self.sameMeeting(u.key, key) { return true }
        if let n = noSpeechStop, Self.sameMeeting(n.key, key) { return true }
        return false
    }

    private func isSuppressed(_ signal: PlatformSignal?, now: Date) -> Bool {
        guard let s = signal else { return false }
        return isSuppressed(Self.meetingKey(s), now: now)
    }

    private func publish(_ now: Date) {
        forgetEndedIfSettled()
        let st = computeState(now: now)
        activeLock.lock(); restartHoldFlag = st.restartHold; activeLock.unlock()
        guard st != lastPublished else { return }
        lastPublished = st
        let cb = onState
        deliver { cb?(st) }
    }

    // MARK: Pure helpers

    /// Identity of "one meeting" for retry throttling and manual-stop suppression.
    static func meetingKey(_ s: PlatformSignal) -> String {
        return "\(s.platform.rawValue):\(s.meetingKey ?? "-")"
    }

    /// "meet:-": the platform is known but the meeting code is not (low-confidence Meet signal, tab query timed out).
    static func keyIsUnknown(_ key: String) -> Bool { key.hasSuffix(":-") }

    /// Same meeting for retry throttling, manual-stop suppression and metadata forwarding. Equal keys match; an unknown
    /// code ("meet:-") matches any code on the same platform; two known, different codes never match.
    static func sameMeeting(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.prefix(while: { $0 != ":" }) == b.prefix(while: { $0 != ":" }) else { return false }
        return keyIsUnknown(a) || keyIsUnknown(b)
    }

    /// Does a start-failure record for `failedKey` hold back a start for `key`? Equal keys do. A record WITH a code also
    /// covers a signal without one (the same call whose tab became unreadable). A record WITHOUT a code ("meet:-": the tab
    /// could not be read when the start failed) does NOT cover a signal that carries a real code: that call is never delayed
    /// by it (at worst it costs one more failed attempt, which then starts its own backoff). Different platforms, or two
    /// different known codes, never match.
    static func throttleApplies(failedKey: String, to key: String) -> Bool {
        if failedKey == key { return true }
        guard failedKey.prefix(while: { $0 != ":" }) == key.prefix(while: { $0 != ":" }) else { return false }
        return keyIsUnknown(key) && !keyIsUnknown(failedKey)
    }

    /// "10 s", "30 s", "1 min", "5 min".
    static func describeDelay(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 && s % 60 == 0 ? "\(s / 60) min" : "\(s) s"
    }

    static func describe(_ snap: DetectionSnapshot) -> String {
        return snap.signals.map { s in
            "\(s.platform.rawValue)\(s.platform == .call ? ":" + (s.bundleID ?? "?") : "")=\(s.inCall ? "IN" : "out")(\(s.confidence.rawValue))[\(s.evidence.joined(separator: "; "))]"
        }.joined(separator: " | ")
    }

    /// What the user can do about a failed start (the notification text and where its click goes).
    static func startFailureKind(_ error: Error) -> StartFailureKind {
        guard let e = error as? RecorderError else { return .other }
        switch e {
        case .permissionDenied(let what): return permissionKind(what)
        case .deviceUnavailable: return .device
        case .failed(let what):
            let lower = what.lowercased()
            return lower.contains("session folder") || lower.contains("session.json") ? .folder : .other
        }
    }

    /// Which permission a denied start is about. The recorder joins its two tracks as "microphone: permission denied: ...; system audio:
    /// recorder failed: ..."; only a track whose text says denied / not granted / restricted counts. Both (or not clear) = Privacy & Security.
    static func permissionKind(_ what: String) -> StartFailureKind {
        var mic = false, system = false
        for part in what.components(separatedBy: "; ") {
            let lower = part.lowercased().trimmingCharacters(in: .whitespaces)
            guard lower.contains("denied") || lower.contains("not been granted") || lower.contains("not granted") || lower.contains("restricted") else { continue }
            if lower.hasPrefix("microphone") { mic = true } else if lower.hasPrefix("system audio") { system = true }
        }
        if mic != system { return mic ? .microphonePermission : .systemAudioPermission }
        if mic && system { return .permission }
        let lower = what.lowercased()
        let hasMic = lower.contains("microphone"), hasSystem = lower.contains("system audio") || lower.contains("tap")
        if hasMic != hasSystem { return hasMic ? .microphonePermission : .systemAudioPermission }
        return .permission
    }

    /// Actionable one-liner for the menu (which permission, where to grant it).
    static func describeStartError(_ error: Error) -> String {
        if let e = error as? RecorderError {
            switch e {
            case .permissionDenied(let what):
                return "Cannot record: permission denied (\(what)). Allow \(AppInfo.displayName) in System Settings > Privacy & Security > Microphone and > Screen & System Audio Recording (System Audio Recording Only)."
            case .deviceUnavailable(let what):
                return "Cannot record: audio device unavailable (\(what))."
            case .failed(let what):
                return "Cannot record: \(what)."
            }
        }
        return "Cannot record: \(error)."
    }
}
