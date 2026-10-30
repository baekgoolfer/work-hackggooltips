import Foundation
import ApplicationServices

// =====================================================================================
// CalendarWatcher: starts a recording for an in-person conversation that has a Google Calendar event, and stops it when the event is over.
//
//   OFFLINE_AUTOSTART=auto (config.env; OFF by default) ->  every 60 s
//     PYTHON_BIN -m mcap gcal upcoming --from-minutes <OFFLINE_START_AFTER_MINUTES> --to-minutes <OFFLINE_START_BEFORE_MINUTES + 1>
//         (PipelineLauncher.runCalendarCommand: same python, same clean environment, 20 s hard limit, off the main thread, one run at a time)
//     -> CalendarCommandParser (one JSON object; anything else is an error state, never a crash)
//     -> CalendarRules.decide (PURE: injected clock and presence provider; start, or skip with a reason)
//     -> SessionController.startRecordingFromCalendar (the path of the menu item 'Start Recording Now': platform manual)
//
// ONE USER, ONE MAC. This is a personal convenience for a person who carries the laptop into their own conversations, and it records people
// who may not have agreed to it. Recording a conversation without the consent of the people in it is illegal in many places. The feature is off
// until the owner writes OFFLINE_AUTOSTART=auto, says so in app.log at every start, and every start posts a notification that says the recording
// came from the calendar and how to stop it. docs/CONFIGURATION.md carries the same warning.
//
// The command has already dropped every event the owner does not take part in (organizer or creator, or an accepted / tentative answer): an invitation
// that nobody answered never reaches this file (gcal.map_event; the app sees no attendee answer other than `declined`).
// What qualifies (all of it, `CalendarRules`): not an all-day event, not declined, event_type default (no focus time, out of office, working
// location, birthday, mail event), no video-conference link (a call is the detector's business, and a call that is recorded twice is worse than
// one that is not), at least one other attendee (OFFLINE_REQUIRE_GUESTS), a length between OFFLINE_MIN_MINUTES and OFFLINE_MAX_MINUTES, now between
// start - OFFLINE_START_BEFORE_MINUTES and start + OFFLINE_START_AFTER_MINUTES and before the end, and somebody at the Mac: the screen is not
// locked, this user is the one at the console, and the last keyboard / mouse input is not older than OFFLINE_IDLE_MAX_MINUTES.
// Never when a recording of any platform runs, never for an event whose recording the user stopped by hand, never for an event id that was
// already started (SUPPORT_DIR/calendar-autostart.json, 0600: ids and end times only, no titles, pruned after a day: a crash or a restart of the
// app in the middle of the event does not record it again, and neither does a stop that was a decision: the calendar's own end, no speech, a full
// disk, the time limit, the policy).
// Three things are NOT decisions, and the event is picked up again for as long as it runs (at most 3 times per event, the presence rules still apply,
// the start window does not): a SLEEP of the Mac and a QUIT of the app end the recording from outside ('pick up the laptop and walk to the room'); the
// id is then taken out of the store, so even a new run of the app starts it again while the start window is open (the window, not the memory of the
// run, bounds that case). And a recording of another platform or of the user's own that was running when the event came due, and ended since, has
// already covered the event: the id is marked as started (a manual stop, or a Zoom call that ended, must not turn into a silent calendar recording a
// minute later). Not covered: a crash (nothing says the recording ended; the id stays in the store).
//
// Stop: when now is later than the event's end + OFFLINE_STOP_AFTER_END_MINUTES the recording this feature started is ended (end reason
// meeting-ended, labelled calendar-end in app.log); the no-speech rule (NO_SPEECH_STOP_MINUTES) covers it too. A recording the user started
// by hand is never touched, and the menu switch below does not release a running recording from this stop.
//
// Closed while: the organisation policy switched recording off, cannot be read, or denies the calendar lane, or local-only is the start value of
// every meeting (`SessionController.calendarGate`): then nothing is asked from Google and nothing is started.
//
// Errors: a failed or unreadable answer is a visible menu state ('Calendar auto-start: error: ...'), a backoff of 1 and then at most 2 minutes (a
// transient failure must not outlast the 17 minute start window; a failed offline poll costs a fraction of a second of CPU), 15 minutes at once when
// nothing but the owner can fix it (not configured, sign-in needed, policy), an immediate retry after a wake from sleep, one log line per change (never
// one per poll), and for 'not configured' and 'sign-in needed' one notification per 12 hours.
//
// Privacy: an event title is never logged, never stored in calendar-autostart.json and never shown in the menu. It reaches session.json as the title
// hint, exactly like a window title, only when LOG_CONTENT allows titles (SessionController.startRecordingFromCalendar).
//
// Threading: everything mutable lives on `queue` (serial, utility). The blocking command runs on it, never on the main queue and never on the controller
// queue, and a second poll cannot start while one runs. The controller is called with `queue.sync` (never the other way round: its callback hops to
// `queue.async`).
// =====================================================================================

// MARK: - Events and the pure rules

/// One event of `gcal upcoming` (the contract of the calendar package). Only what the rules need.
struct CalendarEvent: Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var declined: Bool
    var eventType: String
    var guests: Int
    var hasConference: Bool
}

/// Why an event does not start a recording (a stable code for app.log and the tests; never a title).
enum CalendarSkip: Equatable {
    case allDay, declined, eventType(String), hasConference, noGuests, badTimes, tooShort, tooLong
    case notYet, ended, windowPassed
    case userStopped, alreadyStarted, alreadyRecording
    case notOnConsole, screenLocked, idleUnknown, idle

    var code: String {
        switch self {
        case .allDay: return "all-day"
        case .declined: return "declined"
        case .eventType(let t): return "event-type:\(NotificationText.clip(t, 24))"
        case .hasConference: return "has-conference-link"
        case .noGuests: return "no-other-guests"
        case .badTimes: return "bad-times"
        case .tooShort: return "too-short"
        case .tooLong: return "too-long"
        case .notYet: return "not-yet"
        case .ended: return "ended"
        case .windowPassed: return "start-window-passed"
        case .userStopped: return "stopped-by-user"
        case .alreadyStarted: return "already-started"
        case .alreadyRecording: return "already-recording"
        case .notOnConsole: return "not-on-console"
        case .screenLocked: return "screen-locked"
        case .idleUnknown: return "input-age-unknown"
        case .idle: return "idle"
        }
    }
}

enum CalendarDecision: Equatable {
    case start
    case skip(CalendarSkip)
}

/// Is somebody at the Mac? The app runs, so the system is awake; what is left is the screen lock, whose session is on the console, and the age of the last input.
struct CalendarPresence: Equatable {
    var screenLocked: Bool
    var onConsole: Bool = true
    /// Seconds since the last keyboard / mouse / scroll event of this session; nil = cannot be told (counts as away).
    var secondsSinceInput: TimeInterval?

    /// The real one: CGSessionCopyCurrentDictionary (kCGSSessionScreenIsLocked, kCGSSessionOnConsoleKey) and CGEventSource.secondsSinceLastEventType. Neither needs a permission.
    static func system() -> CalendarPresence {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        let onConsole = (session?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? false
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown, .flagsChanged]
        let ages = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.filter { $0.isFinite && $0 >= 0 }
        return CalendarPresence(screenLocked: locked, onConsole: onConsole, secondsSinceInput: ages.min())
    }
}

enum CalendarRules {
    /// The verdict for one event. Pure: `now` and `presence` come from the caller (the presence provider is only asked when everything cheaper said yes).
    /// `started`: ids that were started before (this run or an earlier one); `userStopped`: ids whose recording the user stopped by hand;
    /// `resumable`: ids whose recording was interrupted from outside (sleep, quit): while the event runs they ignore `started` and the start window.
    static func decide(_ e: CalendarEvent, now: Date, settings: OfflineAutostartSettings, presence: () -> CalendarPresence,
                       recordingActive: Bool, userStopped: Set<String>, started: Set<String>, resumable: Set<String> = []) -> CalendarDecision {
        let resuming = resumable.contains(e.id)
        if e.allDay { return .skip(.allDay) }
        if e.declined { return .skip(.declined) }
        if e.eventType != "default" { return .skip(.eventType(e.eventType)) }
        if e.hasConference { return .skip(.hasConference) }
        if settings.requireGuests && e.guests < 1 { return .skip(.noGuests) }
        let length = e.end.timeIntervalSince(e.start)
        if length <= 0 { return .skip(.badTimes) }
        if length < Double(settings.minMinutes) * 60 { return .skip(.tooShort) }
        if length > Double(settings.maxMinutes) * 60 { return .skip(.tooLong) }
        if now < e.start.addingTimeInterval(-Double(settings.startBeforeMinutes) * 60) { return .skip(.notYet) }
        if now >= e.end { return .skip(.ended) }
        if !resuming && now > e.start.addingTimeInterval(Double(settings.startAfterMinutes) * 60) { return .skip(.windowPassed) }
        if userStopped.contains(e.id) { return .skip(.userStopped) }
        if !resuming && started.contains(e.id) { return .skip(.alreadyStarted) }
        if recordingActive { return .skip(.alreadyRecording) }
        let p = presence()
        if !p.onConsole { return .skip(.notOnConsole) }
        if p.screenLocked { return .skip(.screenLocked) }
        guard let idle = p.secondsSinceInput else { return .skip(.idleUnknown) }
        if idle > Double(settings.idleMaxMinutes) * 60 { return .skip(.idle) }
        return .start
    }

    struct Selection: Equatable {
        var start: CalendarEvent?
        var skips: [String: CalendarSkip]            // by event id
    }

    /// The event to start (the earliest qualifying one; a second one that qualifies at the same time waits for the first one's recording to end)
    /// and the reason for every other event. The presence provider is asked at most once.
    static func choose(_ events: [CalendarEvent], now: Date, settings: OfflineAutostartSettings, presence: () -> CalendarPresence,
                       recordingActive: Bool, userStopped: Set<String>, started: Set<String>, resumable: Set<String> = []) -> Selection {
        var cached: CalendarPresence?
        let lazyPresence: () -> CalendarPresence = {
            if let p = cached { return p }
            let p = presence()
            cached = p
            return p
        }
        var chosen: CalendarEvent?
        var skips: [String: CalendarSkip] = [:]
        for e in events.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let verdict = decide(e, now: now, settings: settings, presence: lazyPresence, recordingActive: recordingActive || chosen != nil,
                                 userStopped: userStopped, started: started, resumable: resumable)
            switch verdict {
            case .start:
                chosen = e
            case .skip(let why):
                skips[e.id] = why
            }
        }
        return Selection(start: chosen, skips: skips)
    }
}

// MARK: - The answer of the command

enum CalendarProblemKind: String, Equatable, CaseIterable {
    case notConfigured = "not_configured", authRequired = "auth_required", network, laneDenied = "lane_denied", policy, apiError = "api_error"
    case helperMissing = "helper_missing", timeout, crashed, malformed

    /// Nothing but the owner (or the policy) can fix it: one poll every 15 minutes at most, from the first failure on.
    var needsOwner: Bool {
        switch self {
        case .notConfigured, .authRequired, .laneDenied, .policy, .helperMissing: return true
        case .network, .apiError, .timeout, .crashed, .malformed: return false
        }
    }

    /// The short phrase after 'Calendar auto-start: error: ' in the menu.
    var menuText: String {
        switch self {
        case .notConfigured: return tr("not set up (run mcap gcal auth)", ko: "설정 안 됨 (mcap gcal auth 실행)")
        case .authRequired: return tr("sign in again (run mcap gcal auth)", ko: "다시 로그인 필요 (mcap gcal auth 실행)")
        case .network: return tr("no network, retrying", ko: "네트워크 없음, 재시도 중")
        case .laneDenied: return tr("calendar not allowed by policy", ko: "조직 정책이 캘린더를 허용하지 않음")
        case .policy: return tr("blocked by policy", ko: "조직 정책으로 막힘")
        case .apiError: return tr("Google Calendar error, retrying", ko: "구글 캘린더 오류, 재시도 중")
        case .helperMissing: return tr("Python or the pipeline is missing", ko: "Python 또는 파이프라인이 없음")
        case .timeout: return tr("calendar helper timed out, retrying", ko: "캘린더 도우미 응답 없음, 재시도 중")
        case .crashed: return tr("calendar helper failed (pipeline too old?)", ko: "캘린더 도우미 실패 (파이프라인이 오래됨?)")
        case .malformed: return tr("unreadable answer from the calendar helper", ko: "캘린더 도우미의 답을 읽을 수 없음")
        }
    }
}

struct CalendarProblem: Equatable {
    var kind: CalendarProblemKind
    /// Short, free of event content and secrets (the command promises that; it is clipped and masked here as well). For app.log and the tooltip.
    var message: String
}

enum CalendarPoll: Equatable {
    case events([CalendarEvent], dropped: Int)
    case problem(CalendarProblem)
}

enum CalendarCommandParser {
    /// The command exits 0 with ONE JSON object on stdout in every case; a non-zero exit is a crash. Anything that does not fit the contract is a
    /// `.problem`, never a crash and never a half-read event list. An event that lacks a field of the contract is dropped (and counted): fail closed.
    static func parse(_ result: CalendarCommandResult) -> CalendarPoll {
        func problem(_ kind: CalendarProblemKind, _ message: String) -> CalendarPoll { .problem(CalendarProblem(kind: kind, message: message)) }
        if let why = result.refusal { return problem(.helperMissing, NotificationText.clip(why, 120)) }
        guard result.launched else { return problem(.helperMissing, "python could not be started") }
        if result.timedOut { return problem(.timeout, "the calendar command did not answer in \(Int(PipelineLauncher.calendarCommandTimeout)) s and was stopped") }
        if result.status != 0 {
            return problem(.crashed, "the calendar command crashed (exit status \(result.status))" + (result.status == 2 ? "; the pipeline may be too old for 'gcal'" : ""))
        }
        guard let data = result.output.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return problem(.malformed, "the answer is not one JSON object")
        }
        guard let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.intValue == 1 else {
            return problem(.malformed, "unknown schema of the answer")
        }
        guard let ok = PipelineLauncher.booleanValue(object["ok"]) else { return problem(.malformed, "the answer has no ok flag") }
        if !ok {
            let message = NotificationText.clip((object["message"] as? String) ?? "", 120)
            let known: [CalendarProblemKind] = [.notConfigured, .authRequired, .network, .laneDenied, .policy, .apiError]
            if let kind = (object["error"] as? String).flatMap({ CalendarProblemKind(rawValue: $0) }), known.contains(kind) { return problem(kind, message) }
            return problem(.apiError, "unknown error code: \(message)")
        }
        guard let list = object["events"] as? [Any] else { return problem(.malformed, "the answer has no event list") }
        var events: [CalendarEvent] = []
        var dropped = 0
        for item in list {
            guard let e = item as? [String: Any] else { dropped += 1; continue }
            let allDay = PipelineLauncher.booleanValue(e["all_day"])
            guard let id = e["id"] as? String, !id.isEmpty, id.utf8.count <= 1024, !id.unicodeScalars.contains(where: NotificationText.isStrippedScalar),
                  let allDayFlag = allDay, let declined = PipelineLauncher.booleanValue(e["declined"]),
                  let conference = PipelineLauncher.booleanValue(e["has_conference"]), let type = e["event_type"] as? String,
                  let guestsNumber = e["guests"] as? NSNumber, CFGetTypeID(guestsNumber) != CFBooleanGetTypeID(), guestsNumber.intValue >= 0,
                  guestsNumber.doubleValue == Double(guestsNumber.intValue) else {
                dropped += 1
                continue
            }
            guard let startText = e["start"] as? String, let endText = e["end"] as? String,
                  let start = ShellUtil.parseISO8601(startText), let end = ShellUtil.parseISO8601(endText) else {
                if !allDayFlag { dropped += 1 }              // an all-day event may carry plain dates: it never starts anything, no need to count it
                continue
            }
            events.append(CalendarEvent(id: id, title: (e["title"] as? String) ?? "", start: start, end: end, allDay: allDayFlag, declined: declined,
                                        eventType: type, guests: guestsNumber.intValue, hasConference: conference))
        }
        return .events(events, dropped: dropped)
    }
}

// MARK: - Gate, status, menu text

/// Why the feature is closed right now (policy facts; no content). Closed = nothing is asked from Google and nothing is started.
enum CalendarBlock: String, Equatable {
    case recordingOff = "recording-off", policyLocked = "policy-locked", laneDenied = "lane-denied", localOnlyDefault = "local-only-default"

    /// English, for app.log.
    var logText: String {
        switch self {
        case .recordingOff: return "recording is switched off by the organisation policy"
        case .policyLocked: return "the organisation policy cannot be read (locked)"
        case .laneDenied: return "the organisation policy does not allow the calendar"
        case .localOnlyDefault: return "local-only is the start value of every meeting, so nothing is asked from Google"
        }
    }

    /// The short phrase in the menu line.
    var menuText: String {
        switch self {
        case .recordingOff: return tr("recording is off by policy", ko: "조직 정책으로 녹음이 꺼져 있음")
        case .policyLocked: return tr("policy cannot be read", ko: "정책을 읽을 수 없음")
        case .laneDenied: return tr("calendar blocked by policy", ko: "조직 정책이 캘린더를 막음")
        case .localOnlyDefault: return tr("local-only is on", ko: "로컬 전용이 켜져 있음")
        }
    }
}

/// What the menu shows (the line 'Calendar auto-start: on / off / error: ...').
enum CalendarStatus: Equatable {
    case on
    case off                                  // switched off from the menu for this session
    case blocked(CalendarBlock)
    case error(CalendarProblem)
}

/// What the watcher needs from the controller (`SessionController` implements it; the self test uses the real controller with fakes).
protocol CalendarRecordingControl: AnyObject {
    var isRecordingActive: Bool { get }
    func calendarGate() -> CalendarBlock?
    func startRecordingFromCalendar(eventID: String, title: String?) -> CalendarStartResult
    @discardableResult func stopRecordingFromCalendar(eventID: String) -> Bool
    var onCalendarRecordingEnded: ((CalendarRecordingEnd) -> Void)? { get set }
}

extension SessionController: CalendarRecordingControl {}

// MARK: - The started ids (SUPPORT_DIR/calendar-autostart.json)

/// Event ids that were started, with the end time of their event: {"schema": 1, "started": {"<id>": "<end, ISO 8601>"}}. Mode 0600, written
/// atomically, entries older than a day (by their end) are pruned. Never a title or anything else about the event. A file that cannot be read means an
/// empty list (one possible repeat, once); a file that cannot be written is logged and the list lives on in memory for this run.
final class CalendarStartedStore {
    static let fileName = "calendar-autostart.json"
    static let keepSeconds: TimeInterval = 24 * 3600
    static let maxEntries = 500

    let file: URL
    private let clock: () -> Date
    private let lock = NSLock()
    private var entries: [String: Date] = [:]

    init(supportDir: URL, clock: @escaping () -> Date = { Date() }) {
        self.file = supportDir.appendingPathComponent(Self.fileName)
        self.clock = clock
        load()
    }

    var ids: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.keys)
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[id] != nil
    }

    /// Remembers `id` (its event ends at `end`), prunes, and writes the file.
    func record(id: String, end: Date) {
        lock.lock()
        entries[id] = end
        prune()
        let snapshot = entries
        lock.unlock()
        write(snapshot)
    }

    /// Forgets `id` (an interrupted recording that may be picked up again) and writes the file.
    func remove(id: String) {
        lock.lock()
        let had = entries.removeValue(forKey: id) != nil
        let snapshot = entries
        lock.unlock()
        if had { write(snapshot) }
    }

    private func prune() {
        let limit = clock().addingTimeInterval(-Self.keepSeconds)
        entries = entries.filter { $0.value >= limit }
        if entries.count > Self.maxEntries {
            for (id, _) in entries.sorted(by: { $0.value < $1.value }).prefix(entries.count - Self.maxEntries) { entries.removeValue(forKey: id) }
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let json = ShellUtil.readJSON(file), let started = json["started"] as? [String: Any] else {
            Log.warn("calendar: \(Self.fileName) cannot be read; starting with an empty list")
            return
        }
        for (id, value) in started {
            guard !id.isEmpty, id.utf8.count <= 1024, let text = value as? String, let end = ShellUtil.parseISO8601(text) else { continue }
            entries[id] = end
        }
        prune()
    }

    private func write(_ snapshot: [String: Date]) {
        let fm = FileManager.default
        let object: [String: Any] = ["schema": 1, "started": snapshot.mapValues { ShellUtil.iso8601($0) }]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(Self.fileName).\(getpid()).tmp")
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: tmp)
            guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            _ = chmod(tmp.path, 0o600)
            if rename(tmp.path, file.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? fm.removeItem(at: tmp)
            Log.warn("calendar: cannot write \(Self.fileName): \(error.localizedDescription). The started events are remembered until the app quits only")
        }
    }
}

// MARK: - The watcher

final class CalendarWatcher {
    /// One poll of Google a minute; the stop check and the gate run at the same beat and need no network.
    static let pollSeconds: TimeInterval = 60
    /// For a failure that only the owner can fix (not configured, sign-in needed, policy); also the bound for a clock that went back.
    static let maxBackoffSeconds: TimeInterval = 900
    /// For a failure that may pass by itself (network, Google, timeout): shorter than the start window (17 minutes) by a wide margin.
    static let transientBackoffSeconds: TimeInterval = 120
    /// A recording that sleep or a quit interrupted is picked up again at most this many times per event.
    static let maxResumes = 3
    /// A tick that comes a little early (timer jitter) still counts as due.
    static let dueSlackSeconds: TimeInterval = 5
    /// After a wake the network is not back at the very instant; the poll follows this soon.
    static let wakeDelaySeconds: TimeInterval = 2
    /// 'Not configured' and 'sign-in needed' are said by a notification at most this often.
    static let problemNoticeSeconds: TimeInterval = 12 * 3600

    /// Blocks until the child ended or its time limit passed (PipelineLauncher.runCalendarCommand); `from` / `to` are the contract's minutes.
    typealias Runner = (_ fromMinutes: Int, _ toMinutes: Int) -> CalendarCommandResult

    /// Called (through `deliver`: the main queue in the app) whenever the status changes. Set before start().
    var onState: ((CalendarStatus) -> Void)?

    let settings: OfflineAutostartSettings
    private let control: CalendarRecordingControl
    private let runner: Runner
    private let presence: () -> CalendarPresence
    private let clock: () -> Date
    private let store: CalendarStartedStore
    private let notifier: NotificationPosting
    private let logFile: URL?
    private let deliver: (@escaping () -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let beatDelay: TimeInterval
    private let beatInterval: TimeInterval
    private let queue = DispatchQueue(label: "\(AppInfo.bundleID).calendar", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let flagLock = NSLock()
    private var down = false
    private var publishedStatus: CalendarStatus?
    private var lastStatus: CalendarStatus { flagLock.lock(); defer { flagLock.unlock() }; return publishedStatus ?? .on }

    // --- state (queue-confined) ---
    private var sessionEnabled = true
    private var nextFetchAt: Date
    private var failures = 0
    private var problem: CalendarProblem?
    private var block: CalendarBlock?
    private var userStopped = Set<String>()
    private var active: (id: String, end: Date)?
    private var skipLog: [String: String] = [:]
    private var startHold: [String: (attempts: Int, notBefore: Date)] = [:]
    private var throttle = NotificationThrottle()

    // --- interrupted recordings (resumeLock: the controller's queue writes them from `recordingEnded`, the watcher's queue reads them) ---
    private let resumeLock = NSLock()
    private var interruptions: [String: Int] = [:]          // shortcut: one small entry per interrupted event for the life of the run; fine for a person's calendar
    private var resumable = Set<String>()

    /// - control: the controller. - runner / presence / clock / store / notifier / deliver / schedule: injected by the self test (a fake command, a virtual
    ///   presence and clock, a store in a temp folder, a recording notifier, synchronous delivery, recorded delays); the app passes the real ones.
    /// - beatDelay / beatInterval: the timer of `start()` (5 s after the start, then every 60 s); only the self test makes them short.
    init(settings: OfflineAutostartSettings, control: CalendarRecordingControl, runner: @escaping Runner,
         presence: @escaping () -> CalendarPresence = { CalendarPresence.system() }, clock: @escaping () -> Date = { Date() },
         store: CalendarStartedStore, notifier: NotificationPosting? = nil, logFile: URL? = nil,
         deliver: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) },
         schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
         beatDelay: TimeInterval = 5, beatInterval: TimeInterval = CalendarWatcher.pollSeconds) {
        self.settings = settings
        self.control = control
        self.runner = runner
        self.presence = presence
        self.clock = clock
        self.store = store
        self.notifier = notifier ?? NullNotifier()
        self.logFile = logFile
        self.deliver = deliver
        self.beatDelay = beatDelay
        self.beatInterval = beatInterval
        self.nextFetchAt = clock()
        let watcherQueue = queue
        self.schedule = schedule ?? { delay, work in watcherQueue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    // MARK: Lifecycle

    /// Starts the beat. With OFFLINE_AUTOSTART=off this does nothing at all: no timer, no hook into the controller, no process, no log line.
    func start() {
        guard settings.isOn else { return }
        attach()
        Log.info(settings.summary)
        Log.warn("calendar auto-start is ON: a recording starts without anybody pressing a button. Recording people without their consent can be illegal; tell them, or switch it off in the menu or with OFFLINE_AUTOSTART=off")
        queue.async { [self] in
            guard !isDown else { return }
            publish(currentStatus())
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + beatDelay, repeating: beatInterval, leeway: beatInterval >= 1 ? .seconds(2) : .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tickLocked() }
            timer = t
            t.resume()
        }
    }

    /// The one hook into the controller: it says when a recording that this watcher started has ended (`start()` calls it; the self test drives the
    /// beat itself and calls it instead of `start()`). Nothing with OFFLINE_AUTOSTART=off.
    func attach() {
        guard settings.isOn else { return }
        control.onCalendarRecordingEnded = { [weak self] end in self?.recordingEnded(end) }
    }

    /// Quit: never waits (the queue may be inside the 20 s command); nothing is started from now on.
    func shutdown() {
        flagLock.lock(); down = true; flagLock.unlock()
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private var isDown: Bool { flagLock.lock(); defer { flagLock.unlock() }; return down }

    /// One beat, waited for (the timer calls `tickLocked` on the queue itself; the self test calls this with a virtual clock). The beat runs on the
    /// watcher's own queue, never on the caller's thread.
    func tick() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            tickLocked()
            done.signal()
        }
        done.wait()
    }

    /// Waits until everything queued so far has run (tests).
    func flush() { queue.sync {} }

    /// NSWorkspace.didWakeNotification: the next poll is not held back by a backoff, and comes at once (the network gets `wakeDelaySeconds`).
    func systemDidWake() {
        guard settings.isOn else { return }
        queue.async { [self] in
            guard !isDown else { return }
            failures = 0
            nextFetchAt = clock()
            schedule(Self.wakeDelaySeconds) { [weak self] in self?.tickLocked() }
        }
    }

    /// The menu item: a session-level switch (config.env is never written). While the status is an error the click is 'try again now' instead.
    func menuClicked() {
        guard settings.isOn else { return }
        queue.async { [self] in
            guard !isDown else { return }
            if sessionEnabled, problem != nil, block == nil {
                Log.info("calendar: retry asked from the menu")
                failures = 0
                nextFetchAt = clock()
                schedule(0.2) { [weak self] in self?.tickLocked() }
                return
            }
            setEnabledLocked(!sessionEnabled)
        }
    }

    /// Session-level on / off (default: on, because OFFLINE_AUTOSTART=auto is what created the watcher).
    func setEnabled(_ on: Bool) {
        guard settings.isOn else { return }
        queue.async { [self] in setEnabledLocked(on) }
    }

    private func setEnabledLocked(_ on: Bool) {
        guard !isDown, on != sessionEnabled else { return }
        sessionEnabled = on
        Log.info("calendar auto-start switched \(on ? "on" : "off") from the menu (this session only; config.env is not changed)")
        if on {
            failures = 0
            problem = nil
            nextFetchAt = clock()
            schedule(0.2) { [weak self] in self?.tickLocked() }
        }
        publish(currentStatus())
    }

    /// The controller says a recording that this watcher started has ended.
    private func recordingEnded(_ end: CalendarRecordingEnd) {
        // The bookkeeping of an interruption is synchronous on purpose: on a real quit the watcher's queue may never run again, and the store file
        // (the id is taken out of it) must be right by then. This is the controller's queue; the lock and the store's own lock never call back.
        let interrupted = Self.interruptedFromOutside(reason: end.reason)
        let resume = interrupted && markInterrupted(end.eventID)
        queue.async { [self] in
            if Self.endedByUser(reason: end.reason, label: end.label) {
                userStopped.insert(end.eventID)
                clearResumable(end.eventID)
                Log.info("calendar: the recording of event \(Self.shortID(end.eventID)) was stopped by hand; it is not started again")
            }
            if interrupted {
                Log.info("calendar: the recording of event \(Self.shortID(end.eventID)) was interrupted (\(end.reason.rawValue)); "
                         + (resume ? "it is picked up again while the event runs" : "it was interrupted more than \(Self.maxResumes) times: it is not picked up again"))
            }
            if active?.id == end.eventID { active = nil }
        }
    }

    /// A sleep of the Mac and a quit of the app end a recording from outside; every other end (the calendar's, no speech, a full disk, the time limit, the
    /// policy, the user) was a decision and stays final for the event.
    static func interruptedFromOutside(reason: EndReason) -> Bool {
        return reason == .sleep || reason == .appQuit
    }

    /// True when the event may be picked up again: takes its id out of the store and into the resumable set (at most `maxResumes` times per event).
    private func markInterrupted(_ id: String) -> Bool {
        resumeLock.lock(); defer { resumeLock.unlock() }
        let count = (interruptions[id] ?? 0) + 1
        interruptions[id] = count
        guard count <= Self.maxResumes else { resumable.remove(id); return false }
        resumable.insert(id)
        store.remove(id: id)
        return true
    }

    private func resumableIDs() -> Set<String> {
        resumeLock.lock(); defer { resumeLock.unlock() }
        return resumable
    }

    private func clearResumable(_ id: String) {
        resumeLock.lock(); defer { resumeLock.unlock() }
        resumable.remove(id)
    }

    /// 'Stop Recording Now' and 'Pause Auto Recording' are the user's own stops; a sleep, a full disk, the time limit, the policy and the calendar are not.
    static func endedByUser(reason: EndReason, label: String?) -> Bool {
        return (reason == .manual && label == nil) || reason == .paused
    }

    static func shortID(_ id: String) -> String { String(id.prefix(8)) }

    // MARK: State for the menu

    /// The status as the menu shows it now (any thread).
    var status: CalendarStatus { lastStatus }

    private func currentStatus() -> CalendarStatus {
        if !sessionEnabled { return .off }
        if let b = block { return .blocked(b) }
        if let p = problem { return .error(p) }
        return .on
    }

    private func publish(_ status: CalendarStatus) {
        flagLock.lock()
        let changed = publishedStatus != status
        publishedStatus = status
        flagLock.unlock()
        guard changed else { return }
        let cb = onState
        deliver { cb?(status) }
    }

    // MARK: One beat (queue)

    private func tickLocked() {
        guard settings.isOn, !isDown else { return }
        let now = clock()
        checkStop(now)
        // The gate first: a closed feature asks nothing from Google.
        let gate = control.calendarGate()
        if gate != block {
            if let g = gate { Log.info("calendar auto-start is off: \(g.logText)") } else { Log.info("calendar auto-start may run again: the policy reason is gone") }
            block = gate
        }
        guard gate == nil, sessionEnabled else { publish(currentStatus()); return }
        if nextFetchAt > now.addingTimeInterval(Self.maxBackoffSeconds + Self.dueSlackSeconds) { nextFetchAt = now }      // the clock went back
        guard now.addingTimeInterval(Self.dueSlackSeconds) >= nextFetchAt else { publish(currentStatus()); return }

        let result = runner(settings.startAfterMinutes, settings.startBeforeMinutes + 1)
        guard !isDown else { return }                   // the app quit while the command ran: nothing is started from its answer
        let after = clock()
        switch CalendarCommandParser.parse(result) {
        case .problem(let p):
            handle(problem: p, at: now)
        case .events(let events, let dropped):
            if let was = problem { Log.info("calendar: working again (it was: \(was.kind.rawValue))") }
            problem = nil
            failures = 0
            nextFetchAt = now.addingTimeInterval(Self.pollSeconds)
            if dropped > 0 { Log.warn("calendar: \(dropped) event(s) of the answer lacked a field of the contract and were ignored") }
            handle(events: events, at: after)
        }
        publish(currentStatus())
    }

    private func checkStop(_ now: Date) {
        guard let a = active else { return }
        if !control.isRecordingActive { active = nil; return }
        guard now > a.end.addingTimeInterval(Double(settings.stopAfterEndMinutes) * 60) else { return }
        active = nil
        if control.stopRecordingFromCalendar(eventID: a.id) {
            Log.info("calendar: event \(Self.shortID(a.id)) ended \(settings.stopAfterEndMinutes) min ago; the recording was stopped")
        }
    }

    private func handle(problem p: CalendarProblem, at now: Date) {
        failures += 1
        nextFetchAt = now.addingTimeInterval(Self.backoffSeconds(failures: failures, kind: p.kind))
        if problem?.kind != p.kind {
            Log.warn("calendar: \(p.kind.rawValue): \(p.message) (next try in \(SessionController.describeDelay(nextFetchAt.timeIntervalSince(now))))")
        }
        problem = p
        switch p.kind {
        case .notConfigured: notify(.notConfigured, key: p.kind.rawValue, now: now)
        case .authRequired: notify(.authRequired, key: p.kind.rawValue, now: now)
        default: break
        }
    }

    private func notify(_ kind: AppNotification.CalendarAttention, key: String, now: Date) {
        guard throttle.allow(key: "calendar-problem:\(key)", now: now, interval: Self.problemNoticeSeconds) else { return }
        notifier.post(.calendarProblem(kind, logFile: logFile))
    }

    /// 1 minute, then 2 minutes at most; 15 minutes from the first failure when only the owner can fix the cause.
    static func backoffSeconds(failures: Int, kind: CalendarProblemKind) -> TimeInterval {
        if kind.needsOwner { return maxBackoffSeconds }
        return min(pollSeconds * pow(2, Double(max(failures, 1) - 1)), transientBackoffSeconds)
    }

    private func handle(events: [CalendarEvent], at now: Date) {
        if let a = active, let e = events.first(where: { $0.id == a.id }), e.end != a.end { active = (a.id, e.end) }      // the event was stretched or cut
        let recordingActive = control.isRecordingActive
        let busy = recordingActive && active == nil          // somebody else's recording (by hand, Zoom, ...), not this feature's own (back to back)
        let selection = CalendarRules.choose(events, now: now, settings: settings, presence: presence, recordingActive: recordingActive,
                                             userStopped: userStopped, started: store.ids, resumable: resumableIDs())
        // One log line per change of the reason of an event; the quiet ones (not yet, over) say nothing. No title, ever.
        let present = Set(events.map { $0.id })
        skipLog = skipLog.filter { present.contains($0.key) }
        startHold = startHold.filter { present.contains($0.key) }
        for (id, why) in selection.skips {
            if why != .notYet && why != .ended && skipLog[id] != why.code { Log.info("calendar: event \(Self.shortID(id)) skipped: \(why.code)") }
            skipLog[id] = why.code
            // It qualified and only the other recording kept it from starting: that recording covers the event, also after it has ended.
            if busy && why == .alreadyRecording, let e = events.first(where: { $0.id == id }) {
                store.record(id: id, end: e.end)
                clearResumable(id)
                Log.info("calendar: event \(Self.shortID(id)) is covered by another recording that is running; it is not started when that one ends")
            }
        }
        guard let event = selection.start else { return }
        if let hold = startHold[event.id], now < hold.notBefore { return }
        switch control.startRecordingFromCalendar(eventID: event.id, title: event.title) {
        case .started:
            store.record(id: event.id, end: event.end)
            clearResumable(event.id)
            active = (event.id, event.end)
            startHold.removeValue(forKey: event.id)
            Log.info("calendar: recording started for event \(Self.shortID(event.id)) (\(settings.requireGuests ? "with other attendees, " : "")ends \(ShellUtil.iso8601(event.end)))")
        case .alreadyRecording:
            Log.info("calendar: event \(Self.shortID(event.id)) not started: a recording is already running")
        case .paused:
            if skipLog[event.id] != "auto-recording-paused" { Log.info("calendar: event \(Self.shortID(event.id)) not started: 'Pause Auto Recording' is on") }
            skipLog[event.id] = "auto-recording-paused"
        case .held:
            if skipLog[event.id] != "installer-not-finished" { Log.info("calendar: event \(Self.shortID(event.id)) not started: the app installer has not finished") }
            skipLog[event.id] = "installer-not-finished"
        case .blocked(let why):
            if skipLog[event.id] != "blocked" { Log.warn("calendar: event \(Self.shortID(event.id)) not started: \(why)") }
            skipLog[event.id] = "blocked"
        case .failed:
            let attempts = (startHold[event.id]?.attempts ?? 0) + 1
            let schedule = SessionController.startRetrySchedule
            let delay = schedule[min(attempts, schedule.count) - 1]
            startHold[event.id] = (attempts, now.addingTimeInterval(delay))
            Log.warn("calendar: the recording for event \(Self.shortID(event.id)) could not be started (attempt \(attempts)); trying again in \(SessionController.describeDelay(delay)) at the earliest")
        case .shutDown:
            break
        }
    }
}
