import AppKit
import Foundation
import UserNotifications

// =====================================================================================
// Notifier: macOS notifications for what an unattended app must not keep to itself (SPEC 15, shell.md "notifications").
//
//   * a recording started / ended           (NOTIFY_RECORDING, default on: the menu-bar icon can be hidden by the notch or a
//                                            menu-bar manager, then this is the only sign that the app noticed the meeting),
//   * the other side's audio looks silent   (remote track),
//   * a recording could not start           (permission / device / disk),
//   * the pipeline failed                   (with the reason),
//   * the meeting note is ready             (with its title),
//   * SPEC 18: the per-meeting local-only toggle and its refusals, a policy that cannot be read, a pipeline that is too
//     old or not trusted, a transcript without a note (local-only / lane denied), a transcription server that cannot be reached.
//
// A meeting title (and a folder name that carries its slug) is left out of the banner text and of the app.log lines when the meeting is
// local-only or LOG_CONTENT=0 (`hideTitle`); the click target inside the notification payload keeps the path.
//
// Content: in the UI language (UI_LANGUAGE, English by default, the Korean texts kept), never empty. Every notification has a title, a subtitle (meeting title / platform / what is safe) and a body
// (<= 100 characters, the consequence and what a click does). Failures and warnings make a sound; start / stop / "note ready"
// do not. They are all `active` (a banner): `passive` would only add them to the list without a banner, which is exactly what a
// hidden menu-bar icon cannot afford. The two that cost recordings (silent remote track, could not start) are `timeSensitive`
// (macOS treats that as `active` when an app lacks the Time Sensitive Notifications entitlement, which a locally signed app does).
//
// Clicks: the click handler (UNUserNotificationCenter delegate) is installed once in `Notifier.start()`, called at app startup
// before anything can be posted. Every notification carries a userInfo of plain strings: `action` plus `path` (a folder or log)
// or `url` (a System Settings pane). `NotificationClickRouter` validates it again at click time (paths must lie under
// ARCHIVE_DIR, SUPPORT_DIR/sessions or LOG_DIR, resolved through symlinks, no "..", folders only, never a package/app bundle;
// settings URLs must be one of a fixed allow-list) and always calls the completion handler. All of that is pure Swift behind
// `NotificationOpening`, so selftest-session exercises it with a fake opener and never touches UserNotifications.
//
// Rules
//  * Active only when LaunchGuard.isSignedAppLaunch (the signed app started by launchd / LaunchServices). In every other
//    process (a shell running a self-test, an agent) `UNUserNotificationCenter` is never touched: it needs a real app
//    bundle (the bare binary would trap) and a notification would belong to the wrong app.
//  * Fail-soft: not authorized, not available or an error while delivering only means a log line. Nothing here can throw,
//    block the caller (delivery is asynchronous) or change what the app records.
//  * The center sits behind `NotificationCenterBackend` and the app talks to `NotificationPosting`, so selftest-session
//    and the unit tests run against fakes and never reach macOS.
//  * Authorization is requested by `setup` only (a prompt in the middle of a meeting would be worse than none).
//  * Log lines stay English (grep): "notification (kind): <english summary> [click: action]", "notification clicked: <action> ...".
// =====================================================================================

enum NotificationAuthorization: Equatable {
    case authorized
    case denied
    case notDetermined
    case unavailable(String)

    var label: String {
        switch self {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        case .unavailable(let why): return "unavailable (\(why))"
        }
    }
}

// MARK: - What a click does

/// The System Settings panes a click may open. Fixed list: a notification can never carry an arbitrary URL.
enum NotificationSettingsPane {
    static let scheme = "x-apple.systempreferences"
    /// Privacy & Security (the fallback for every other pane).
    static let privacy = "x-apple.systempreferences:com.apple.preference.security"
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    /// "Screen & System Audio Recording": where "System Audio Recording Only" lives up to macOS 15.
    static let screenAndSystemAudio = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    /// The "System Audio Recording" pane of macOS 26 (anchor `Privacy_AudioCapture` = kTCCServiceAudioCapture in its
    /// Security & Privacy settings extension).
    static let systemAudioRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    static let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    static let allowList: Set<String> = [privacy, microphone, screenAndSystemAudio, systemAudioRecording, notifications]

    static func isAllowed(_ url: String) -> Bool { allowList.contains(url) }

    /// The pane that holds the System Audio Recording permission on this macOS.
    static func systemAudio(osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        return osMajorVersion >= 26 ? systemAudioRecording : screenAndSystemAudio
    }
}

/// What happens when the user clicks a notification. The userInfo of a notification is exactly `userInfo` below.
enum NotificationClickAction: Equatable {
    case none
    case openFolder(String)          // absolute path of a folder (checked against the allowed roots when posted and when clicked)
    case openLog(String)             // absolute path of app.log / pipeline-*.log (must be inside LOG_DIR)
    case openSettings(String)        // one of NotificationSettingsPane.allowList (exact match)

    static let actionKey = "action"
    static let pathKey = "path"
    static let urlKey = "url"
    static let knownActions: Set<String> = ["none", "openFolder", "openLog", "openSettings"]

    var name: String {
        switch self {
        case .none: return "none"
        case .openFolder: return "openFolder"
        case .openLog: return "openLog"
        case .openSettings: return "openSettings"
        }
    }

    /// Plain strings only: the action name plus its one argument. Nothing else is ever put into a notification's userInfo.
    var userInfo: [String: String] {
        switch self {
        case .none: return [Self.actionKey: "none"]
        case .openFolder(let p): return [Self.actionKey: "openFolder", Self.pathKey: p]
        case .openLog(let p): return [Self.actionKey: "openLog", Self.pathKey: p]
        case .openSettings(let u): return [Self.actionKey: "openSettings", Self.urlKey: u]
        }
    }
}

// MARK: - Text helpers (UI language)

enum NotificationText {
    static let titleLimit = 40
    static let subtitleLimit = 60
    static let bodyLimit = 100

    /// "Zoom", "Teams", "Google Meet", "수동" (a recording started by hand).
    static func platformName(_ p: Platform) -> String {
        switch p {
        case .zoom: return "Zoom"
        case .teams: return "Teams"
        case .meet: return "Google Meet"
        case .manual: return tr("manual", ko: "수동")
        case .call: return tr("Call", ko: "통화")
        }
    }

    /// The words for a signal: the app's name for a call of another app ("Slack huddle"), else `platformName`. One line, at most 40 characters.
    static func platformName(_ signal: PlatformSignal) -> String {
        guard signal.platform == .call, let name = nonEmpty(signal.appName) else { return platformName(signal.platform) }
        return clip(name, CallApps.maxNameLength)
    }

    /// `seconds` as a whole, non-negative number of seconds. `Int(Double)` traps on NaN, infinity and anything beyond Int.max, and a
    /// crash in the notification path would take the whole app (and a running recording) down: such a value counts as 0, a huge one
    /// as 10^9 s (more than 30 years).
    static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), 1e9).rounded())
    }

    /// "45 s", "32 min", "1 h", "1 h 05 min" ("45초", "32분", "1시간", "1시간 05분" in Korean; rounded to the minute from one minute on).
    static func duration(_ seconds: Double) -> String {
        let s = wholeSeconds(seconds)
        if s < 60 { return tr("\(max(s, 1)) s", ko: "\(max(s, 1))초") }
        let minutes = Int((Double(s) / 60).rounded())
        if minutes < 60 { return tr("\(minutes) min", ko: "\(minutes)분") }
        let h = minutes / 60, m = minutes % 60
        let mm = String(format: "%02d", m)
        return m == 0 ? tr("\(h) h", ko: "\(h)시간") : tr("\(h) h \(mm) min", ko: "\(h)시간 \(mm)분")
    }

    /// "15:00" in the local time zone.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// API keys never leave the Keychain; this is the last line of defence against one reaching a banner through an error text.
    static func redact(_ text: String) -> String {
        return text.replacingOccurrences(of: #"sk-[A-Za-z0-9][A-Za-z0-9_\-]{7,}"#, with: "sk-\u{2026}", options: .regularExpression)
    }

    /// A session name that may go into app.log, a notification's log line and its identifier for a meeting whose title must stay out of
    /// them (a local-only meeting, LOG_CONTENT=0). A staging id is date, time and platform ("2026-10-07_1400_meet") and a job
    /// name ("retry-sweep") says nothing about a meeting: both stay. The published folder of a meeting is "<date>_<time>_<slug>", and the
    /// slug is made from its title: only date and time are kept. Anything else becomes "a session".
    static func contentFreeSession(_ name: String) -> String {
        if name == SessionController.sweepJobName || name == "reprocess-last" { return name }
        let parts = name.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        func digits(_ text: String, _ count: Int) -> Bool { text.utf8.count == count && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
        guard parts.count >= 2, parts[0].utf8.count == 10, parts[0].utf8.enumerated().allSatisfy({ ($0.offset == 4 || $0.offset == 7) ? $0.element == 0x2D : ($0.element >= 0x30 && $0.element <= 0x39) }),
              digits(parts[1], 4) else { return "a session" }
        if parts.count == 3, Platform(rawValue: parts[2]) != nil { return name }
        return "\(parts[0])_\(parts[1])"
    }

    /// A failure text (it comes from Python and from the launcher's reading of its log) without the places it names, for a local-only meeting
    /// and under LOG_CONTENT=0: the folder a session was being moved to has the slug of its title in its name ("cannot move session to
    /// <folder>: ..."). Every absolute path (and ~/...) up to the next colon, quote, bracket or the end of the line becomes "<path>"; a
    /// folder name in the published form "<date>_<time>_<slug>" that stands alone loses its slug. The rest of the text is kept.
    static func withoutPaths(_ text: String) -> String {
        var out = text
        if let paths = try? NSRegularExpression(pattern: #"(?<![\w.])~?/[^:"'()\n]*"#) {
            for match in paths.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                let found = String(out[range])
                let trailing = String(found.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
                out.replaceSubrange(range, with: "<path>" + trailing)
            }
        }
        if let folders = try? NSRegularExpression(pattern: #"(?<![\w-])(\d{4}-\d{2}-\d{2}_\d{4})_([^\s:/'"()]+)"#) {
            for match in folders.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let whole = Range(match.range, in: out), let stamp = Range(match.range(at: 1), in: out), let rest = Range(match.range(at: 2), in: out) else { continue }
                if Platform(rawValue: String(out[rest])) != nil { continue }              // a staging id: nothing of a title in it
                out.replaceSubrange(whole, with: "\(out[stamp])_<folder>")
            }
        }
        return out
    }

    /// Control characters (C0 / C1 except tab and the line breaks, which `clip` turns into a space) and the bidirectional override /
    /// embedding / isolate characters: a meeting title can come from a calendar invite written by someone else, and neither belongs in
    /// a banner or a log line (an ESC sequence, a right-to-left override that reorders the text around it).
    static func isStrippedScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00...0x08, 0x0E...0x1F, 0x7F, 0x80...0x84, 0x86...0x9F: return true
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// One line, secrets masked, at most `limit` characters (with an ellipsis when cut).
    static func clip(_ text: String, _ limit: Int) -> String {
        // Strip BEFORE masking: a control character inside an API key must not split it into two pieces the mask does not recognise.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isStrippedScalar($0) })
        let flat = redact(String(scalars)).split(whereSeparator: { $0.isNewline }).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    static func nonEmpty(_ text: String?) -> String? {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// `lead` + `sep` + one more part that has to fit into `limit` characters in all. The lead (the cause) is never cut for the tail (a
    /// support contact): the tail is the part that is shortened, and it is left out when nothing is left for it.
    static func fit(_ lead: String, sep: String = " · ", tail: String?, limit: Int = bodyLimit) -> String {
        guard let tail = nonEmpty(tail) else { return clip(lead, limit) }
        let room = limit - lead.count - sep.count
        guard room >= 4 else { return clip(lead, limit) }
        return lead + sep + clip(tail, room)
    }

    /// "Contact: IT helpdesk" / "문의: IT helpdesk": the support contact of the organisation policy at the end of a body.
    static func contactTail(_ contact: String) -> String { tr("Contact: \(contact)", ko: "문의: \(contact)") }

    /// The tail of a recording-start notification: only when the flag is on or a policy exists; the personal default
    /// (no policy, flag off) keeps today's text.
    static func localOnlyTail(on: Bool, policyExists: Bool) -> String? {
        if on { return tr(" · Local-only: on", ko: " · 로컬 전용: 켜짐") }
        return policyExists ? tr(" · Local-only: off (turn it on in the menu for a sensitive meeting)", ko: " · 로컬 전용: 꺼짐 (민감한 회의면 메뉴에서 켜세요)") : nil
    }
}

/// Why a recording could not start, as far as the user can act on it.
enum StartFailureKind: Equatable {
    case microphonePermission
    case systemAudioPermission
    case permission                  // both, or not clear which
    case device
    case disk
    case folder
    case policy                      // recording.enabled=false in the organisation policy
    case other
}

/// Why a recording ended, when the reason is worth a sentence in the notification.
enum StopNote: Equatable {
    case normal
    case diskLow
    case maxDuration
    case sleep
    case noSpeech(minutes: Int)
    case policyKillSwitch            // the organisation policy switched recording off
}

// MARK: - The notification

struct AppNotification: Equatable {
    enum Kind: String {
        case remoteSilent, recordingFailed, pipelineFailed, noteReady, recordingStarted, recordingStopped
        case localOnlyChanged, policyProblem, transcriptReady, waitingForServer          // SPEC 18
        case calendarProblem                                                              // calendar auto-start needs the owner (CalendarWatcher.swift)
    }
    enum Level: String { case active, timeSensitive }

    var kind: Kind
    var title: String
    var subtitle: String
    var body: String
    var identifier: String          // a new notification with the same identifier replaces the earlier one
    var sound: Bool                 // failures and warnings make a sound; start / stop / "note ready" do not
    var level: Level = .active
    var action: NotificationClickAction = .none
    var summary: String = ""        // English one-liner for app.log

    var userInfo: [String: String] { action.userInfo }

    /// Clips, masks secrets and makes sure no part is empty.
    private static func make(_ kind: Kind, title: String, subtitle: String, body: String, identifier: String, sound: Bool,
                             level: Level = .active, action: NotificationClickAction, summary: String) -> AppNotification {
        func fill(_ text: String, limit: Int, fallback: String) -> String {
            let t = NotificationText.clip(text, limit)
            return t.isEmpty ? fallback : t
        }
        return AppNotification(
            kind: kind,
            title: fill(title, limit: NotificationText.titleLimit, fallback: AppInfo.displayName),
            subtitle: fill(subtitle, limit: NotificationText.subtitleLimit, fallback: AppInfo.displayName),
            body: fill(body, limit: NotificationText.bodyLimit, fallback: tr("See the log for details", ko: "자세한 내용은 로그를 확인하세요")),
            identifier: identifier, sound: sound, level: level, action: action,
            summary: NotificationText.clip(summary, 160))
    }

    private static func folderAction(_ url: URL?) -> NotificationClickAction {
        guard let url = url else { return NotificationClickAction.none }
        return NotificationClickAction.openFolder(url.path)
    }

    // MARK: Recording started / ended

    /// `localOnlyTail` (NotificationText.localOnlyTail) says whether the meeting is local-only; `hideTitle` leaves the meeting title out.
    /// `fromCalendar` (calendar auto-start, a manual-path recording that nobody pressed a button for) says so in the title and the body: nobody
    /// in the room has been asked, so this banner is the one sign that a recording runs.
    static func recordingStarted(platformLabel: String, manual: Bool, titleHint: String?, session: String, folder: URL?,
                                 localOnlyTail: String? = nil, hideTitle: Bool = false, fromCalendar: Bool = false) -> AppNotification {
        let hint = hideTitle ? nil : NotificationText.nonEmpty(titleHint)
        let tail = tr("Shown in case the menu-bar icon is hidden", ko: "메뉴바 아이콘이 가려져 있어도 이 알림으로 확인할 수 있어요")
        let extra = localOnlyTail ?? ""
        if fromCalendar {
            return make(.recordingStarted,
                        title: tr("Recording started · calendar", ko: "녹음 시작 · 캘린더"),
                        subtitle: hint ?? tr("Started from the calendar event", ko: "캘린더 일정으로 시작했어요"),
                        body: tr("Started from the calendar event. Stop it in the menu if anyone here has not agreed", ko: "캘린더 일정에 맞춰 시작했어요. 동의하지 않은 사람이 있으면 메뉴에서 멈추세요") + extra,
                        identifier: "mcap.recording-started.\(session)", sound: false,
                        action: folderAction(folder),
                        summary: "recording started from the calendar (\(session))")
        }
        return make(.recordingStarted,
                    title: manual ? tr("Recording started · manual", ko: "녹음 시작 · 수동") : tr("Recording started · \(platformLabel)", ko: "녹음 시작 · \(platformLabel)"),
                    subtitle: hint ?? (manual ? tr("Started by hand", ko: "수동으로 시작했어요") : tr("Meeting detected, started automatically", ko: "회의를 감지해 자동으로 시작했어요")),
                    body: (manual ? tr("Recording started by hand. \(tail)", ko: "수동으로 녹음을 시작했어요. \(tail)")
                                  : tr("Started recording the \(platformLabel) meeting. \(tail)", ko: "\(platformLabel) 회의 녹음을 시작했어요. \(tail)")) + extra,
                    identifier: "mcap.recording-started.\(session)", sound: false,
                    action: folderAction(folder),
                    summary: "recording started: \(manual ? "manual" : platformLabel) (\(session))")
    }

    /// A recording that started because the GENERIC rule took `appName` for a call (CALL_DETECT=generic, docs/DETECTION.md section 3b). Nobody named this app
    /// as a call app, so the banner says why the recording runs and how to stop it for good ("Menu > Never record <App>"). The same identifier as the normal
    /// start notification: it replaces it. The name is cut to what the banner can hold.
    static func genericCallStarted(appName: String, session: String, folder: URL?, localOnlyTail: String? = nil) -> AppNotification {
        let shortName = NotificationText.clip(appName, 18)
        let extra = localOnlyTail ?? ""
        return make(.recordingStarted,
                    title: tr("Recording started · \(shortName)", ko: "녹음 시작 · \(shortName)"),
                    subtitle: tr("\(shortName) looks like a call: recording started", ko: "\(shortName)이(가) 통화로 보여 녹음을 시작했어요"),
                    body: tr("Not a call? Menu > Never record \(shortName)", ko: "통화가 아니라면 메뉴 > Never record \(shortName)") + extra,
                    identifier: "mcap.recording-started.\(session)", sound: false,
                    action: folderAction(folder),
                    summary: "\(NotificationText.clip(appName, CallApps.maxNameLength)) looks like a call: recording started. Not a call? Menu > Never record \(NotificationText.clip(appName, CallApps.maxNameLength)) (\(session))")
    }

    static func recordingStopped(platformLabel: String, manual: Bool, durationSeconds: Double, titleHint: String?, session: String,
                                 folder: URL?, note: StopNote = .normal, hideTitle: Bool = false) -> AppNotification {
        let length = NotificationText.duration(durationSeconds)
        let who = manual ? tr("manual", ko: "수동") : platformLabel
        let hint = hideTitle ? nil : NotificationText.nonEmpty(titleHint)
        var body = tr("\(length) recording saved. You will be told when the note is ready", ko: "\(length) 녹음을 저장했어요. 회의록이 준비되면 다시 알려 드릴게요")
        var problem = false
        switch note {
        case .normal: break
        case .diskLow:
            body = tr("Disk space is low, so recording stopped. The recording (\(length)) is saved and transcription starts", ko: "저장 공간이 부족해 녹음을 멈췄어요. 녹음(\(length))은 저장됐고 전사를 시작합니다")
            problem = true
        case .maxDuration:
            body = tr("Reached the maximum recording time and stopped at \(length). Transcription starts", ko: "최대 녹음 시간에 도달해 \(length)에서 멈췄어요. 전사를 시작합니다")
        case .sleep:
            body = tr("The Mac went to sleep, so recording stopped at \(length). Transcription starts", ko: "Mac이 잠자기에 들어가 \(length)에서 멈췄어요. 전사를 시작합니다")
        case .noSpeech(let minutes):
            body = tr("No sound for \(minutes) min, so recording stopped. Transcribing the saved recording (\(length))", ko: "\(minutes)분 동안 소리가 없어 녹음을 멈췄어요. 저장된 녹음(\(length))을 전사합니다")
        case .policyKillSwitch:
            body = tr("Recording stopped by organisation policy. The recording (\(length)) is saved and transcription starts", ko: "조직 정책에 따라 녹음을 멈췄어요. 녹음(\(length))은 저장됐고 전사를 시작합니다")
            problem = true
        }
        return make(.recordingStopped,
                    title: tr("Recording ended · transcription starts", ko: "녹음 종료 · 전사 시작"),
                    subtitle: hint.map { "\($0) · \(length)" } ?? "\(who) · \(length)",
                    body: body,
                    identifier: "mcap.recording-stopped.\(session)", sound: problem,
                    level: problem ? .timeSensitive : .active,
                    action: folderAction(folder),
                    summary: "recording stopped: \(manual ? "manual" : platformLabel), \(NotificationText.wholeSeconds(durationSeconds)) s (\(session))\(note == .normal ? "" : ", \(note)")")
    }

    // MARK: The four warnings / results

    static func remoteSilent(platformLabel: String, session: String) -> AppNotification {
        return make(.remoteSilent,
                    title: tr("The other side may not be recorded", ko: "상대방 소리가 녹음되지 않는 것 같아요"),
                    subtitle: tr("Recording \(platformLabel)", ko: "\(platformLabel) 녹음 중"),
                    body: tr("Normal if you are presenting alone. Otherwise check the System Audio Recording permission and the AirPods connection · Click to open Settings",
                             ko: "혼자 발표 중이면 정상이에요. 아니라면 시스템 오디오 녹음 권한과 AirPods 연결을 확인하세요 · 클릭하면 설정이 열립니다"),
                    identifier: "mcap.remote-silent.\(session)", sound: true, level: .timeSensitive,
                    action: .openSettings(NotificationSettingsPane.systemAudio()),
                    summary: "remote audio looks silent in the \(platformLabel) recording (\(session))")
    }

    /// `reason` is the English message of describeStartError (it goes to the log, never to the banner unless the cause is unknown).
    static func recordingFailed(reason: String, kind: StartFailureKind = .other, platformLabel: String? = nil, logFile: URL? = nil,
                                contact: String? = nil) -> AppNotification {
        let log: NotificationClickAction = logFile.map { NotificationClickAction.openLog($0.path) } ?? NotificationClickAction.none
        let platform = NotificationText.nonEmpty(platformLabel)
        var subtitle: String
        var body: String
        var action: NotificationClickAction
        switch kind {
        case .microphonePermission:
            subtitle = tr("Microphone permission needed", ko: "마이크 권한이 필요해요")
            body = tr("Turn \(AppInfo.displayName) on in Settings > Privacy & Security > Microphone · Click to open Settings", ko: "설정 > 개인정보 보호 및 보안 > 마이크에서 \(AppInfo.displayName) 앱을 켜 주세요 · 클릭하면 설정이 열립니다")
            action = .openSettings(NotificationSettingsPane.microphone)
        case .systemAudioPermission:
            subtitle = tr("System Audio Recording permission needed", ko: "시스템 오디오 녹음 권한이 필요해요")
            body = tr("Turn \(AppInfo.displayName) on in Settings > Privacy & Security > System Audio Recording · Click to open Settings", ko: "설정 > 개인정보 보호 및 보안 > 시스템 오디오 녹음에서 \(AppInfo.displayName) 앱을 켜 주세요 · 클릭하면 설정이 열립니다")
            action = .openSettings(NotificationSettingsPane.systemAudio())
        case .permission:
            subtitle = tr("Recording permission needed", ko: "녹음 권한이 필요해요")
            body = tr("Check the Microphone and System Audio Recording permissions · Click to open the privacy settings", ko: "마이크와 시스템 오디오 녹음 권한을 확인해 주세요 · 클릭하면 개인정보 보호 설정이 열립니다")
            action = .openSettings(NotificationSettingsPane.privacy)
        case .device:
            subtitle = tr("The audio device is not available", ko: "오디오 장치를 쓸 수 없어요")
            body = tr("A device such as AirPods may be switching. It retries automatically in a moment · Click to open the log", ko: "AirPods 등 장치가 바뀌는 중일 수 있어요. 잠시 뒤 자동으로 다시 시도합니다 · 클릭하면 로그가 열립니다")
            action = log
        case .disk:
            subtitle = tr("Disk space is low", ko: "저장 공간이 부족해요")
            body = tr("Free some disk space. It retries automatically once there is enough · Click to open the log", ko: "디스크 공간을 확보해 주세요. 확보되면 자동으로 다시 시도합니다 · 클릭하면 로그가 열립니다")
            action = log
        case .folder:
            subtitle = tr("Cannot create the session folder", ko: "세션 폴더를 만들 수 없어요")
            body = tr("Check the write permission of the Application Support folder · Click to open the log", ko: "Application Support 폴더의 쓰기 권한을 확인해 주세요 · 클릭하면 로그가 열립니다")
            action = log
        case .policy:
            subtitle = tr("Recording is off by organisation policy", ko: "조직 정책으로 녹음이 꺼져 있어요")
            body = NotificationText.fit(tr("Organisation policy blocks recording on this Mac", ko: "조직 정책이 이 Mac의 녹음을 막고 있어요"), tail: contact.map(NotificationText.contactTail))
            action = NotificationClickAction.none
        case .other:
            subtitle = platform.map { tr("\($0) meeting", ko: "\($0) 회의") } ?? tr("Cause unknown", ko: "원인을 알 수 없어요")
            let tail = tr(" · Click to open the log", ko: " · 클릭하면 로그가 열립니다")
            let head = tr("Cause: ", ko: "원인: ")
            body = head + NotificationText.clip(reason, NotificationText.bodyLimit - head.count - tail.count) + tail
            action = log
        }
        return make(.recordingFailed,
                    title: tr("Could not start recording", ko: "녹음을 시작하지 못했어요"),
                    subtitle: subtitle, body: body,
                    identifier: "mcap.recording-failed", sound: true, level: .timeSensitive, action: action,
                    summary: "recording could not start (\(kind)): \(reason)")
    }

    /// `kind`, `retryable`, `resetsAt` come from state.json (read-only); `reason` is the one-line message of the failure event.
    static func pipelineFailed(session: String, reason: String, kind: String? = nil, retryable: Bool? = nil, resetsAt: Date? = nil,
                               folder: URL? = nil, logFile: URL? = nil, contact: String? = nil) -> AppNotification {
        let hint = retryable == true ? tr("Automatic retry · now: mcap reprocess --pending", ko: "자동 재시도 · 즉시: mcap reprocess --pending")
                                     : tr("Reprocess: mcap reprocess --last", ko: "재처리: mcap reprocess --last")
        let sep = " · "
        let reasonText = failureReason(kind: kind, message: reason, resetsAt: resetsAt)
        let room = NotificationText.bodyLimit - hint.count - sep.count
        // asr_policy_blocked: the cause and the support contact; a manual reprocess hint would not help (policy decides).
        let body = kind == "asr_policy_blocked"
            ? NotificationText.fit(reasonText, tail: contact.map(NotificationText.contactTail))
            : NotificationText.clip(reasonText, room) + sep + hint
        let transcriptMayBeMissing: Set<String> = ["audio_failed", "asr_failed", "stalled", "no_audio"]
        let action: NotificationClickAction
        if let folder = folder {
            action = .openFolder(folder.path)
        } else if let logFile = logFile {
            action = .openLog(logFile.path)
        } else {
            action = NotificationClickAction.none
        }
        return make(.pipelineFailed,
                    title: tr("Meeting note failed", ko: "회의록 생성 실패"),
                    subtitle: transcriptMayBeMissing.contains(kind ?? "") ? tr("Recording is kept safe", ko: "녹음은 안전하게 보관됨") : tr("Transcript and recording are kept safe", ko: "전사본·녹음은 안전하게 보관됨"),
                    body: body,
                    identifier: "mcap.pipeline-failed.\(session)", sound: true, action: action,
                    summary: "processing failed for \(session)\(kind.map { " (\($0))" } ?? ""): \(reason)")
    }

    /// The cause (in the UI language) for the failure kinds the pipeline reports (state.json error_kind); an unknown kind shows the raw message.
    static func failureReason(kind: String?, message: String, resetsAt: Date?) -> String {
        switch kind ?? "" {
        case "usage_limit":
            return tr("Claude usage limit reached", ko: "Claude 사용 한도에 도달했어요")
                + (resetsAt.map { tr(" (available after \(NotificationText.clock($0)))", ko: " (\(NotificationText.clock($0)) 이후 가능)") } ?? "")
        case "credit_exhausted": return tr("Claude API credit is used up (top up, then reprocess)", ko: "Claude API 크레딧이 부족해요 (충전 후 재처리)")
        case "budget_daily", "budget_meeting", "budget": return tr("Claude spending budget reached", ko: "Claude 사용 예산 한도에 도달했어요")
        case "auth", "billing_mode_violation": return tr("Claude login or billing setting error (mcap api-key check)", ko: "Claude 인증 또는 과금 설정 오류 (mcap api-key check)")
        case "overloaded", "rate_limited", "timeout", "model_unavailable": return tr("Claude is slow or overloaded", ko: "Claude 응답이 지연되거나 과부하예요")
        case "overage_guard": return tr("The extra-usage guard held the note back", ko: "초과 사용 가드로 노트 생성을 보류했어요")
        case "config": return tr("Settings error (check with mcap doctor)", ko: "설정 오류 (mcap doctor로 점검)")
        case "archive_unavailable": return tr("Could not save to the archive folder", ko: "Google Drive 폴더에 저장하지 못했어요")
        case "asr_failed": return tr("Speech recognition (transcription) failed", ko: "음성 인식(전사)에 실패했어요")
        case "asr_policy_blocked": return tr("This Mac cannot transcribe locally and sending audio out is not allowed, so nothing was transcribed (the recording is kept)", ko: "이 Mac에서는 로컬 전사를 할 수 없고 외부 전송도 금지돼 전사하지 못했어요 (녹음은 보관됨)")
        case "local_archive_unsafe": return tr("The local archive folder is not safe, so nothing was saved (LOCAL_ARCHIVE_DIR)", ko: "로컬 보관 폴더가 안전하지 않아 저장하지 않았어요 (LOCAL_ARCHIVE_DIR)")
        case "audio_failed": return tr("Audio conversion failed", ko: "오디오 변환에 실패했어요")
        case "publish_failed": return tr("Saving the meeting folder failed", ko: "회의 폴더 저장에 실패했어요")
        case "stalled": return tr("Processing stalled and was stopped", ko: "처리가 멈춰서 중단됐어요")
        default: return tr("Cause: \(message)", ko: "원인: \(message)")
        }
    }

    /// `hideTitle` (local-only meeting or LOG_CONTENT=0): the banner and the log line carry no meeting title.
    static func noteReady(title: String?, session: String, platformLabel: String? = nil, durationSeconds: Double? = nil,
                          folder: URL? = nil, hideTitle: Bool = false) -> AppNotification {
        let name = hideTitle ? nil : NotificationText.nonEmpty(title)
        var facts: [String] = []
        if let p = NotificationText.nonEmpty(platformLabel) { facts.append(p) }
        let clickFolder = tr("Click to open the folder", ko: "클릭하면 폴더가 열립니다")
        let savedInFolder = tr("Saved in the meeting folder", ko: "회의 폴더에 저장했어요")
        if let d = durationSeconds, d >= 1 { facts.append(tr("\(NotificationText.duration(d)) recorded", ko: "\(NotificationText.duration(d)) 녹음")) }
        if folder != nil { facts.append(clickFolder) }
        if hideTitle {
            let what = facts.filter { $0 != clickFolder }
            return make(.noteReady,
                        title: tr("Meeting note is ready", ko: "회의록이 준비됐어요"),
                        subtitle: what.isEmpty ? savedInFolder : what.joined(separator: " · "),
                        body: folder != nil ? clickFolder : savedInFolder,
                        identifier: "mcap.note-ready.\(session)", sound: false, action: folderAction(folder),
                        summary: "meeting note ready (\(session))")
        }
        return make(.noteReady,
                    title: tr("Meeting note is ready", ko: "회의록이 준비됐어요"),
                    subtitle: name ?? tr("Untitled meeting", ko: "제목 없는 회의"),
                    body: facts.isEmpty ? savedInFolder : facts.joined(separator: " · "),
                    identifier: "mcap.note-ready.\(session)", sound: false, action: folderAction(folder),
                    summary: "meeting note ready: \(name ?? "(untitled)") (\(session))")
    }

    // MARK: SPEC 18: local-only, policy, transcript without a note, server unreachable

    /// What went wrong when the local-only menu item was used.
    enum LocalOnlyProblem: Equatable { case tooLate, maybeLate, pipelineTooOld, writeFailed }

    /// The flag was switched ON for this meeting. No meeting title.
    static func localOnlyOn(platformLabel: String?, session: String) -> AppNotification {
        let where_ = NotificationText.nonEmpty(platformLabel)
        return make(.localOnlyChanged,
                    title: tr("Local-only meeting", ko: "로컬 전용 회의"),
                    subtitle: (where_.map { "\($0) · " } ?? "") + tr("This meeting only", ko: "이 회의만 적용"),
                    body: tr("Transcription stays on this Mac. No note (Claude), no calendar lookup, no upload. Transcript and recording are kept in a local folder on this Mac",
                             ko: "전사는 이 Mac에서만 처리해요. 회의록(Claude), 캘린더 조회, Drive 업로드는 하지 않아요. 전사본과 녹음은 이 Mac의 로컬 폴더에 저장돼요"),
                    identifier: "mcap.local-only.\(session)", sound: false, action: NotificationClickAction.none,
                    summary: "local-only ON for \(session)")
    }

    /// The flag was switched OFF: `summary` is `EffectiveLanes.summaryText` (what is true for this meeting now).
    static func localOnlyOff(summary: String, session: String) -> AppNotification {
        return make(.localOnlyChanged,
                    title: tr("Local-only turned off", ko: "로컬 전용 해제"),
                    subtitle: summary,
                    body: tr("If anything sensitive was said, turn it on again before processing", ko: "민감한 내용이 있었다면 처리 전에 다시 켜세요"),
                    identifier: "mcap.local-only.\(session)", sound: false, action: NotificationClickAction.none,
                    summary: "local-only OFF for \(session)")
    }

    /// The organisation policy keeps the flag on.
    static func localOnlyLocked(contact: String?, session: String) -> AppNotification {
        return make(.localOnlyChanged,
                    title: tr("Local-only is fixed by policy", ko: "로컬 전용은 조직 정책으로 고정돼 있어요"),
                    subtitle: tr("Organisation policy", ko: "조직 정책"),
                    body: NotificationText.fit(tr("It cannot be turned off", ko: "해제할 수 없어요"), tail: contact.map(NotificationText.contactTail)),
                    identifier: "mcap.local-only.\(session)", sound: false, action: NotificationClickAction.none,
                    summary: "local-only is locked by policy; the toggle was refused for \(session)")
    }

    static func localOnlyProblem(_ problem: LocalOnlyProblem, session: String, logFile: URL? = nil) -> AppNotification {
        let title: String
        let body: String
        var action = NotificationClickAction.none
        var sound = false
        switch problem {
        case .tooLate:
            title = tr("Cannot change local-only", ko: "로컬 전용을 바꿀 수 없어요")
            body = tr("Processing has already started. It can only be changed while recording or before processing starts", ko: "이미 처리 단계에 들어가 바꿀 수 없어요. 녹음 중이거나 처리가 시작되기 전에만 바꿀 수 있어요")
        case .maybeLate:
            title = tr("Check that local-only applied", ko: "로컬 전용 적용을 확인하세요")
            body = tr("Processing was already finishing, so it may not have applied", ko: "처리가 이미 끝나는 중이라 적용되지 않았을 수 있어요")
            sound = true
        case .pipelineTooOld:
            title = tr("Cannot change local-only", ko: "로컬 전용을 바꿀 수 없어요")
            body = tr("The pipeline is too old to support local-only", ko: "파이프라인이 오래돼 로컬 전용을 지원하지 않아요")
        case .writeFailed:
            title = tr("Could not save local-only", ko: "로컬 전용을 저장하지 못했어요")
            body = tr("The session file could not be written, so the change did not apply · Click to open the log", ko: "세션 파일을 쓰지 못해 변경은 적용되지 않았어요 · 클릭하면 로그가 열립니다")
            action = logFile.map { NotificationClickAction.openLog($0.path) } ?? NotificationClickAction.none
            sound = true
        }
        return make(.localOnlyChanged, title: title, subtitle: tr("This meeting", ko: "이 회의"), body: body,
                    identifier: "mcap.local-only.\(session)", sound: sound, level: sound ? .timeSensitive : .active, action: action,
                    summary: "local-only toggle: \(problem) for \(session)")
    }

    /// The organisation policy cannot be read (locked): `reasonText` is `OrgPolicy.lockedReasonText` (at most 20 characters, no
    /// policy text), so that the support contact is not cut off.
    static func policyProblem(reasonText: String, contact: String?, logFile: URL? = nil) -> AppNotification {
        let reason = NotificationText.clip(reasonText, 20)
        let lead = tr("For safety nothing is sent out; local transcription only · \(reason)", ko: "안전을 위해 외부 전송을 막고 로컬 전사만 해요 · \(reason)")
        return make(.policyProblem,
                    title: tr("Cannot read the organisation policy", ko: "조직 정책을 읽을 수 없어요"),
                    subtitle: tr("Sending out is blocked", ko: "외부 전송 차단 중"),
                    body: NotificationText.fit(lead, tail: contact.map(NotificationText.contactTail)),
                    identifier: "mcap.policy-problem", sound: true, level: .timeSensitive,
                    action: logFile.map { NotificationClickAction.openLog($0.path) } ?? NotificationClickAction.none,
                    summary: "organisation policy is locked: \(reasonText)")
    }

    /// The launcher refused to start the pipeline: the session stays in staging, no attempt is counted.
    static func pipelineBlocked(_ block: PipelineBlock, session: String, contact: String?, logFile: URL? = nil) -> AppNotification {
        let title: String
        let lead: String
        switch block {
        case .pipelineTooOld:
            title = tr("Pipeline update needed", ko: "파이프라인 업데이트가 필요해요")
            lead = tr("This setting needs a newer pipeline, so processing was not started", ko: "이 설정에는 새 파이프라인이 필요해서 처리를 시작하지 않았어요")
        case .runtimeUntrusted:
            title = tr("Untrusted runtime", ko: "신뢰할 수 없는 실행 환경이에요")
            lead = tr("It is not the install location the organisation set, so processing was not started", ko: "조직이 지정한 설치 위치가 아니라서 처리를 시작하지 않았어요")
        }
        return make(.policyProblem,
                    title: title,
                    subtitle: tr("Recording is kept safe", ko: "녹음은 안전하게 보관됨"),
                    body: NotificationText.fit(lead, tail: contact.map(NotificationText.contactTail)),
                    identifier: "mcap.pipeline-blocked", sound: true, level: .timeSensitive,
                    action: logFile.map { NotificationClickAction.openLog($0.path) } ?? NotificationClickAction.none,
                    summary: "pipeline not started for \(session): \(block.logText)")
    }

    /// The session ended without a meeting note: local-only (`localOnly`) or a lane the organisation denied. No meeting title.
    static func transcriptReady(localOnly: Bool, session: String, platformLabel: String? = nil, durationSeconds: Double? = nil,
                                folder: URL? = nil) -> AppNotification {
        var facts: [String] = []
        if let p = NotificationText.nonEmpty(platformLabel) { facts.append(p) }
        if let d = durationSeconds, d >= 1 { facts.append(tr("\(NotificationText.duration(d)) recorded", ko: "\(NotificationText.duration(d)) 녹음")) }
        let skipped = localOnly ? tr("Note, calendar and upload were skipped", ko: "회의록·캘린더·Drive 업로드는 건너뛰었어요")
                                : tr("The note was skipped by organisation policy", ko: "회의록은 조직 정책에 따라 건너뛰었어요")
        return make(.transcriptReady,
                    title: localOnly ? tr("Transcript is ready (local-only)", ko: "전사본이 준비됐어요 (로컬 전용)") : tr("Transcript is ready", ko: "전사본이 준비됐어요"),
                    subtitle: facts.isEmpty ? tr("Saved in the meeting folder", ko: "회의 폴더에 저장했어요") : facts.joined(separator: " · "),
                    body: folder != nil ? tr("\(skipped) · Click to open the folder", ko: "\(skipped) · 클릭하면 폴더가 열립니다") : skipped,
                    identifier: "mcap.transcript-ready.\(session)", sound: false, action: folderAction(folder),
                    summary: "transcript ready (\(localOnly ? "local-only" : "note skipped by policy")) (\(session))")
    }

    /// What the calendar auto-start needs from its owner (said once in a long while, see CalendarWatcher): the Google side is not set up, or
    /// the sign-in has to be done again. No event, no account, no address in the text.
    enum CalendarAttention: Equatable { case notConfigured, authRequired }

    static func calendarProblem(_ attention: CalendarAttention, logFile: URL? = nil) -> AppNotification {
        let subtitle: String
        let summary: String
        switch attention {
        case .notConfigured:
            subtitle = tr("Google Calendar is not set up", ko: "구글 캘린더가 설정되지 않았어요")
            summary = "calendar auto-start: Google Calendar is not set up (mcap gcal auth)"
        case .authRequired:
            subtitle = tr("Sign in to Google again", ko: "구글에 다시 로그인하세요")
            summary = "calendar auto-start: sign-in needed (mcap gcal auth)"
        }
        return make(.calendarProblem,
                    title: tr("Calendar auto-start needs you", ko: "캘린더 자동 시작을 확인하세요"),
                    subtitle: subtitle,
                    body: tr("No meeting is started from the calendar until you run: mcap gcal auth", ko: "mcap gcal auth 를 실행하기 전까지 캘린더로 녹음을 시작하지 않아요"),
                    identifier: "mcap.calendar-problem", sound: true,
                    action: logFile.map { NotificationClickAction.openLog($0.path) } ?? NotificationClickAction.none,
                    summary: summary)
    }

    /// error_kind asr_unreachable: the transcription server did not answer; the recording is kept and processed when it does.
    static func waitingForServer(session: String, folder: URL? = nil) -> AppNotification {
        return make(.waitingForServer,
                    title: tr("Cannot reach the server", ko: "서버에 연결할 수 없어요"),
                    subtitle: tr("Recording is kept safe", ko: "녹음은 안전하게 보관됨"),
                    body: tr("It is processed automatically once the connection works", ko: "연결되면 자동으로 처리해요"),
                    identifier: "mcap.waiting-for-server.\(session)", sound: false, action: folderAction(folder),
                    summary: "transcription server unreachable for \(session); waiting")
    }
}

// MARK: - Who posts, who delivers

/// What the app (SessionController) needs: fire and forget.
protocol NotificationPosting: AnyObject {
    func post(_ notification: AppNotification)
}

/// Does nothing: the default for a controller that was not given a notifier.
final class NullNotifier: NotificationPosting {
    func post(_ notification: AppNotification) {}
}

/// The calls the real notification center is reduced to (so a fake can stand in for it).
protocol NotificationCenterBackend: AnyObject {
    func authorizationStatus(_ completion: @escaping (NotificationAuthorization) -> Void)
    func requestAuthorization(_ completion: @escaping (NotificationAuthorization) -> Void)
    /// `completion(nil)` on success, otherwise a short error text.
    func add(_ notification: AppNotification, completion: @escaping (String?) -> Void)
    /// Registers the router that gets every click (the real center: `UNUserNotificationCenter.delegate`). Called exactly once per
    /// process by `Notifier.start()` at app startup, before the first notification can be posted.
    func installClickHandler(_ router: NotificationClickRouter)
}

/// Allows a notification at most once per `interval` for a key (a failing start is retried every few seconds; the user
/// should hear about it once, not every retry). Pure, driven by the caller's clock, so the tests use virtual time.
struct NotificationThrottle {
    private var lastPosted: [String: Date] = [:]

    mutating func allow(key: String, now: Date, interval: TimeInterval) -> Bool {
        if let last = lastPosted[key], now >= last, now.timeIntervalSince(last) < interval { return false }
        lastPosted[key] = now
        if lastPosted.count > 200 {                                   // never grows without bound in a long-running app
            lastPosted = lastPosted.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
        }
        return true
    }
}

// MARK: - Click routing (pure; the fake opener stands in for NSWorkspace)

/// Where a click may lead. Paths are only trusted when they are absolute, free of "..", resolved through symlinks and inside
/// ARCHIVE_DIR, SUPPORT_DIR/sessions or LOG_DIR; a log file must be inside LOG_DIR.
struct NotificationPathPolicy {
    let folderRoots: [URL]
    let logRoot: URL
    /// Folders whose paths are not written to app.log: the local archive of local-only meetings (always) and, when
    /// LOG_CONTENT=0, the archive too (a meeting folder name carries the slug of its title).
    let privateRoots: [URL]

    /// `extraFolderRoots`: more folders a click may open, in practice LOCAL_ARCHIVE_DIR. They are local, so they are looked at
    /// before ARCHIVE_DIR. `hideArchivePaths` (LOG_CONTENT=0) keeps archive paths out of the log as well.
    init(config: AppConfig, logDir: URL, extraFolderRoots: [URL] = [], hideArchivePaths: Bool = false) {
        // Local roots first: `check` looks at the roots in this order and canonicalizes each one it looks at, which is file I/O. A
        // start / stop notice (a session folder) is posted on the controller's queue and must never wait for ARCHIVE_DIR, a Google
        // Drive mount that can be slow or gone, just to find out that the folder is not in it.
        folderRoots = [config.sessionsDir, logDir] + extraFolderRoots + [config.archiveDir]
        logRoot = logDir
        privateRoots = extraFolderRoots + (hideArchivePaths ? [config.archiveDir] : [])
    }

    init(folderRoots: [URL], logRoot: URL, privateRoots: [URL] = []) {
        self.folderRoots = folderRoots
        self.logRoot = logRoot
        self.privateRoots = privateRoots
    }

    /// The path as the log may show it: a path inside a private root is replaced by a label (no title, no slug).
    func loggable(_ path: String) -> String {
        for root in privateRoots {
            if Self.isInside(path, root: root.path) || Self.isInside(path, root: Self.canonical(root.path)) { return "<folder omitted from the log>" }
        }
        return path
    }

    enum Check: Equatable {
        case ok(URL)
        case rejected(String)
    }

    /// `realpath` of the longest existing prefix plus the rest (so a symlink in the middle of a path that does not exist yet is still
    /// resolved). Independent of Foundation's `resolvingSymlinksInPath` special cases (/private).
    static func canonical(_ path: String) -> String {
        var head = path
        var tail: [String] = []
        while true {
            if let r = realpath(head, nil) {
                let base = String(cString: r)
                free(r)
                return tail.reversed().reduce(base) { $0 == "/" ? "/\($1)" : "\($0)/\($1)" }
            }
            if head == "/" || head.isEmpty { return path }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
            if head.isEmpty { head = "/" }
        }
    }

    static func isInside(_ path: String, root: String) -> Bool {
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// PATH_MAX on macOS: no path the kernel accepts is longer, so a longer string is never a real folder. Without this bound a
    /// forged payload with thousands of components made `canonical` retry `realpath` once per component for minutes.
    static let maxPathBytes = 1024

    /// `enforceLength: false` is only for the parents of a path that already passed (`folderTarget` climbs a canonical path, which a
    /// symlink such as /tmp -> /private/tmp can have made a few bytes longer than the string that came in).
    func check(_ path: String, roots: [URL], enforceLength: Bool = true) -> Check {
        guard !path.isEmpty, path.hasPrefix("/") else { return .rejected("not an absolute path") }
        guard !enforceLength || path.utf8.count <= Self.maxPathBytes else { return .rejected("the path is longer than PATH_MAX") }
        guard !path.contains("\0") else { return .rejected("NUL character in the path") }
        guard !path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else { return .rejected("the path contains '..'") }
        let target = Self.canonical(path)
        for root in roots where Self.isInside(target, root: Self.canonical(root.path)) {
            return .ok(URL(fileURLWithPath: target))
        }
        return .rejected("outside ARCHIVE_DIR, the sessions folder and LOG_DIR")
    }

    func checkFolder(_ path: String, enforceLength: Bool = true) -> Check { check(path, roots: folderRoots, enforceLength: enforceLength) }
    func checkLog(_ path: String) -> Check { check(path, roots: [logRoot]) }
}

/// Opens a URL with the default handler (NSWorkspace in the app, a recorder in the tests). Returns false when macOS refused.
protocol NotificationOpening: AnyObject {
    func open(_ url: URL) -> Bool
}

final class WorkspaceOpener: NotificationOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

enum NotificationRoute: Equatable {
    case nothing                                   // action "none"
    case open(URL)                                 // a folder (Finder) or a log file (its default handler)
    case openSettings(URL, fallback: URL)          // an allow-listed pane, then Privacy & Security if that cannot be opened
    case rejected(String)                          // never opened: the reason is logged
}

final class NotificationClickRouter {
    let policy: NotificationPathPolicy
    private let opener: NotificationOpening
    private let dispatch: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var _observer: ((String) -> Void)?

    /// - dispatch: where the opening happens (main queue in the app: NSWorkspace wants it; the tests run it inline).
    init(policy: NotificationPathPolicy, opener: NotificationOpening = WorkspaceOpener(),
         dispatch: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }) {
        self.policy = policy
        self.opener = opener
        self.dispatch = dispatch
    }

    /// Called with the action name of every click (selftest-notify prints it). Set before the first click.
    var observer: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _observer }
        set { lock.lock(); _observer = newValue; lock.unlock() }
    }

    // MARK: before posting

    /// The notification as it will be delivered: a click target that is not allowed is dropped (the click then only logs).
    func sanitized(_ n: AppNotification) -> AppNotification {
        var out = n
        switch n.action {
        case .none:
            break
        case .openFolder(let path):
            switch policy.checkFolder(path) {
            case .ok(let url): out.action = .openFolder(url.path)
            case .rejected(let why):
                Log.warn("notification (\(n.kind.rawValue)): click target \(policy.loggable(path)) refused (\(why)); the click will do nothing")
                out.action = .none
            }
        case .openLog(let path):
            switch policy.checkLog(path) {
            case .ok(let url): out.action = .openLog(url.path)
            case .rejected(let why):
                Log.warn("notification (\(n.kind.rawValue)): log target \(path) refused (\(why)); the click will do nothing")
                out.action = .none
            }
        case .openSettings(let url):
            if !NotificationSettingsPane.isAllowed(url) {
                Log.warn("notification (\(n.kind.rawValue)): settings pane \(url) is not in the allow-list; the click will do nothing")
                out.action = .none
            }
        }
        return out
    }

    // MARK: at click time

    private static func printable(_ text: String) -> String {
        let flat = text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined()
        return flat.count > 40 ? String(flat.prefix(39)) + "\u{2026}" : flat
    }

    private static func isOpenableFolder(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return v.isDirectory == true && v.isPackage != true          // never a bundle: opening one would launch it
    }

    /// The folder itself, or - when it is gone (the pipeline moves staging folders into the archive) - the nearest parent that still
    /// exists inside an allowed root.
    private func folderTarget(_ url: URL) -> URL? {
        var candidate = url
        while true {
            if Self.isOpenableFolder(candidate) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path, case .ok(let inside) = policy.checkFolder(parent.path, enforceLength: false) else { return nil }
            candidate = inside
        }
    }

    /// What a userInfo asks for, validated. Never touches the file system except to look (exists / directory / package).
    func decide(_ userInfo: [AnyHashable: Any]) -> (name: String, route: NotificationRoute) {
        guard let action = userInfo[NotificationClickAction.actionKey] as? String else { return ("(none)", .rejected("no action in the notification")) }
        guard NotificationClickAction.knownActions.contains(action) else {
            return ("unknown(\(Self.printable(action)))", .rejected("unknown action"))
        }
        switch action {
        case "openFolder":
            guard let path = userInfo[NotificationClickAction.pathKey] as? String else { return (action, .rejected("no path")) }
            switch policy.checkFolder(path) {
            case .rejected(let why): return (action, .rejected(why))
            case .ok(let url):
                guard let folder = folderTarget(url) else { return (action, .rejected("the folder does not exist")) }
                return (action, .open(folder))
            }
        case "openLog":
            guard let path = userInfo[NotificationClickAction.pathKey] as? String else { return (action, .rejected("no path")) }
            switch policy.checkLog(path) {
            case .rejected(let why): return (action, .rejected(why))
            case .ok(let url):
                let ext = url.pathExtension.lowercased()
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, ["log", "txt"].contains(ext) {
                    return (action, .open(url))
                }
                // no such log (yet): show the log folder instead of nothing
                if let folder = folderTarget(URL(fileURLWithPath: NotificationPathPolicy.canonical(policy.logRoot.path), isDirectory: true)) { return (action, .open(folder)) }
                return (action, .rejected("no such log file"))
            }
        case "openSettings":
            guard let text = userInfo[NotificationClickAction.urlKey] as? String, NotificationSettingsPane.isAllowed(text),
                  let url = URL(string: text), url.scheme == NotificationSettingsPane.scheme,
                  let fallback = URL(string: NotificationSettingsPane.privacy) else { return (action, .rejected("the settings pane is not in the allow-list")) }
            return (action, .openSettings(url, fallback: fallback))
        default:
            return (action, .nothing)
        }
    }

    /// The whole click. `completion` is called exactly once, whatever happens (the system waits for it).
    func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else {
            Log.info("notification action ignored: \(Self.printable(actionIdentifier)) (only a click on the notification itself acts)")
            completion()
            return
        }
        let decision = decide(userInfo)
        observer?(decision.name)
        switch decision.route {
        case .nothing:
            Log.info("notification clicked: \(decision.name)")
            completion()
        case .rejected(let why):
            Log.warn("notification clicked: \(decision.name) rejected (\(why))")
            completion()
        case .open(let url):
            Log.info("notification clicked: \(decision.name) \(policy.loggable(url.path))")
            dispatch { [opener, policy] in
                if !opener.open(url) { Log.warn("notification click: macOS could not open \(policy.loggable(url.path))") }
                completion()
            }
        case .openSettings(let url, let fallback):
            Log.info("notification clicked: \(decision.name) \(url.absoluteString)")
            dispatch { [opener] in
                if !opener.open(url) {
                    Log.warn("notification click: could not open \(url.absoluteString); opening Privacy & Security instead")
                    if !opener.open(fallback) { Log.warn("notification click: could not open Privacy & Security either") }
                }
                completion()
            }
        }
    }
}

// MARK: - Notifier

final class Notifier: NotificationPosting {
    enum Delivery: Equatable {
        case delivered
        case inactive                       // not the signed app: only logged
        case notAllowed(String)             // authorization status label
        case failed(String)
    }

    private let active: Bool
    private let backend: NotificationCenterBackend?
    private let router: NotificationClickRouter?
    private let lock = NSLock()
    private var started = false

    /// Production: `Notifier(router: ...)`. `active` is only overridden by the tests; an inactive notifier never creates or calls a
    /// backend. Without a router (the `setup` command) clicks are not handled and notifications carry no click target.
    init(active: Bool = LaunchGuard.isSignedAppLaunch, backend: NotificationCenterBackend? = nil, router: NotificationClickRouter? = nil) {
        self.active = active
        self.backend = active ? (backend ?? LiveNotificationCenter()) : nil
        self.router = router
    }

    var isActive: Bool { active }

    /// Installs the click handler. Called once at app startup (App.swift), before anything is posted; idempotent, so a second call
    /// (and the safety net in `post`) does nothing. Inactive notifier / no router: nothing to install.
    func start() {
        guard active, let backend = backend else { return }
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }
        guard let router = router else {
            Log.info("notification click handler not installed (no router): clicks on notifications do nothing")
            return
        }
        backend.installClickHandler(router)
        Log.info("notification click handler installed")
    }

    func post(_ n: AppNotification) { post(n, completion: nil) }

    /// `completion` (tests, selftest-notify) hears what became of it; the app never waits for it.
    func post(_ original: AppNotification, completion: ((Delivery) -> Void)?) {
        let n = router?.sanitized(original) ?? { var plain = original; plain.action = .none; return plain }()
        Log.info("notification (\(n.kind.rawValue)): \(n.summary.isEmpty ? n.kind.rawValue : n.summary) [click: \(n.action.name)]")
        guard active, let backend = backend else {
            Log.info("notification not delivered: not running as the signed \(AppInfo.shortName).app started by launchd / LaunchServices")
            completion?(.inactive)
            return
        }
        start()                                                        // safety net: the handler must exist before the first delivery
        backend.authorizationStatus { status in
            guard status == .authorized else {
                // Not allowed (denied, never asked: `setup` asks) or no center: the menu and app.log still carry the message.
                Log.warn("notification not delivered: macOS notifications are \(status.label); the message is in this log and the menu only. Run setup or allow them in System Settings > Notifications.")
                completion?(.notAllowed(status.label))
                return
            }
            backend.add(n) { error in
                if let e = error {
                    Log.warn("notification could not be delivered: \(e)")
                    completion?(.failed(e))
                } else {
                    completion?(.delivered)
                }
            }
        }
    }

    /// For `setup`: asks macOS for permission (this is what shows the prompt) and waits for the answer. Never throws.
    func requestAuthorization(timeout: TimeInterval = 120) -> NotificationAuthorization {
        guard active, let backend = backend else {
            return .unavailable("only the signed \(AppInfo.shortName).app started by launchd / LaunchServices can ask")
        }
        let box = AnswerBox()
        let sem = DispatchSemaphore(value: 0)
        backend.requestAuthorization { answer in
            box.set(answer)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return box.get() ?? .notDetermined }
        return box.get() ?? .unavailable("no answer")
    }

    private final class AnswerBox {
        private let lock = NSLock()
        private var answer: NotificationAuthorization?
        func set(_ a: NotificationAuthorization) { lock.lock(); answer = a; lock.unlock() }
        func get() -> NotificationAuthorization? { lock.lock(); defer { lock.unlock() }; return answer }
    }
}

// MARK: - The real notification center (never created outside the signed app)

final class LiveNotificationCenter: NSObject, NotificationCenterBackend, UNUserNotificationCenterDelegate {
    /// Only ever constructed by `Notifier` when it is active (the signed app), because `UNUserNotificationCenter.current()` needs a
    /// real app bundle. Created in init (not lazily) so two threads cannot race on it.
    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private var router: NotificationClickRouter?

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
    }

    func installClickHandler(_ router: NotificationClickRouter) {
        lock.lock(); self.router = router; lock.unlock()
        center.delegate = self
    }

    func authorizationStatus(_ completion: @escaping (NotificationAuthorization) -> Void) {
        center.getNotificationSettings { settings in
            completion(Self.map(settings.authorizationStatus))
        }
    }

    func requestAuthorization(_ completion: @escaping (NotificationAuthorization) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let e = error {
                completion(.unavailable("\(e.localizedDescription)"))
            } else {
                completion(granted ? .authorized : .denied)
            }
        }
    }

    func add(_ n: AppNotification, completion: @escaping (String?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.subtitle = n.subtitle
        content.body = n.body
        content.threadIdentifier = n.kind.rawValue                     // same kind: grouped together in Notification Center
        content.interruptionLevel = n.level == .timeSensitive ? .timeSensitive : .active
        content.userInfo = n.userInfo                                  // action + path | url, nothing else
        if n.sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: n.identifier, content: content, trigger: nil)
        center.add(request) { error in completion(error.map { $0.localizedDescription }) }
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable("unknown authorization status \(status.rawValue)")
        }
    }

    /// A menu-bar app can count as "frontmost" while its menu is open: show the banner (and list entry, and sound) anyway.
    static let presentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.presentationOptions)
    }

    /// A click on the notification (or its dismissal): routed by userInfo["action"]. The completion handler is always called.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        lock.lock(); let router = self.router; lock.unlock()
        guard let router = router else {
            Log.warn("notification clicked: no click handler installed; ignoring")
            completionHandler()
            return
        }
        router.handle(actionIdentifier: response.actionIdentifier,
                      userInfo: response.notification.request.content.userInfo,
                      completion: completionHandler)
    }
}

// MARK: - selftest-notify (real notifications: only from the signed app)

/// nil = may run. `selftest-notify` posts REAL notifications, so it only runs as the signed app started by launchd / LaunchServices,
/// never from a shell exec (the notifications would belong to the terminal / agent app, or the bare binary would trap).
func notifySelftestRefusal(signedAppLaunch: Bool, launch: String = CapturePermissionGuard.launchDescription()) -> String? {
    guard !signedAppLaunch else { return nil }
    return "selftest-notify: refusing to run. It posts real notifications and this process was not started by launchd / LaunchServices as the "
         + "signed \(AppInfo.shortName).app (\(launch)). Run it as the app:\n  \(CapturePermissionGuard.openAppCommand("selftest-notify"))\n"
}

/// One sample of every kind (each with a "[test]" / "[테스트]" subtitle), a click on each does what the real one does. Returns the exit code.
func runSelftestNotify(config: AppConfig, logDir: URL, waitSeconds: TimeInterval, signedAppLaunch: Bool = LaunchGuard.isSignedAppLaunch) -> Int32 {
    if let refusal = notifySelftestRefusal(signedAppLaunch: signedAppLaunch) {
        FileHandle.standardError.write(Data(refusal.utf8))
        return 2
    }
    let router = NotificationClickRouter(policy: NotificationPathPolicy(config: config, logDir: logDir))
    router.observer = { name in
        print("  click received (pid \(getpid())): \(name)")
        fflush(stdout)
    }
    let notifier = Notifier(router: router)
    notifier.start()

    DispatchQueue.main.async { NSApplication.shared.activate() }        // macOS only shows the permission prompt for an active app
    let auth = notifier.requestAuthorization()
    print("notifications: \(auth.label)")
    guard auth == .authorized else {
        print("selftest-notify: macOS does not allow notifications for \(AppInfo.displayName). Allow them in System Settings > Notifications > \(AppInfo.displayName) (or run setup), then run this again.")
        return 1
    }

    let appLog = Log.fileURL
    let archive = config.archiveDir
    let testTag = tr("[test]", ko: "[테스트]")
    var samples: [AppNotification] = [
        .noteReady(title: tr("Weekly product meeting", ko: "주간 제품 회의"), session: "selftest", platformLabel: "Zoom", durationSeconds: 32 * 60, folder: archive),
        .pipelineFailed(session: "selftest", reason: "Note failed: Claude usage limit reached", kind: "usage_limit", retryable: true,
                        resetsAt: Date().addingTimeInterval(3600), folder: archive, logFile: appLog),
        .remoteSilent(platformLabel: "Zoom", session: "selftest"),
        .recordingFailed(reason: "Cannot record: permission denied (system audio).", kind: .systemAudioPermission, platformLabel: "Zoom", logFile: appLog),
        .recordingStarted(platformLabel: "Zoom", manual: false, titleHint: nil, session: "selftest", folder: config.sessionsDir),
        .recordingStarted(platformLabel: tr("manual", ko: "수동"), manual: true, titleHint: nil, session: "selftest", folder: config.sessionsDir, fromCalendar: true),
        .calendarProblem(.authRequired, logFile: appLog),
        .recordingStopped(platformLabel: "Zoom", manual: false, durationSeconds: 32 * 60, titleHint: nil, session: "selftest", folder: config.sessionsDir),
        .localOnlyOn(platformLabel: "Zoom", session: "selftest"),
        .transcriptReady(localOnly: true, session: "selftest", platformLabel: "Zoom", durationSeconds: 32 * 60, folder: config.sessionsDir),
        .waitingForServer(session: "selftest", folder: config.sessionsDir),
        .policyProblem(reasonText: tr("Policy file permission error", ko: "정책 파일 권한 오류"), contact: tr("IT helpdesk", ko: "IT 헬프데스크 #it-help"), logFile: appLog),
    ]
    for i in samples.indices {
        samples[i].subtitle = NotificationText.clip(testTag + " " + samples[i].subtitle, NotificationText.subtitleLimit)
        samples[i].identifier = samples[i].identifier.replacingOccurrences(of: ".selftest", with: ".selftest-\(i)")
    }

    print("Posting \(samples.count) sample notifications (subtitle starts with \(testTag)); one every 2 s:")
    var failures = 0
    for n in samples {
        let sem = DispatchSemaphore(value: 0)
        let box = DeliveryBox()
        notifier.post(n) { d in box.set(d); sem.signal() }
        _ = sem.wait(timeout: .now() + 10)
        let result = box.get()
        if result != .delivered { failures += 1 }
        print("  \(n.kind.rawValue): \(n.title) | \(n.subtitle) | click: \(n.action.name) -> \(result.map { "\($0)" } ?? "no answer")")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 2)
    }
    if failures > 0 {
        print("selftest-notify: \(failures) notification(s) were not delivered (see app.log)")
        return 1
    }
    print("")
    print("Check on screen: (1) the blue \(AppInfo.displayName) icon (waveform + red dot) on every banner, (2) title, subtitle and body in your UI language (UI_LANGUAGE), (3) click each one:")
    print("  note ready / processing failed / recording started / stopped -> a Finder window opens;  silent remote / could not start -> System Settings opens")
    print("Waiting \(Int(waitSeconds)) s for clicks (a click may be handled by the already running menu-bar app instead: then see app.log, 'notification clicked: ...')")
    fflush(stdout)
    Thread.sleep(forTimeInterval: waitSeconds)
    print("selftest-notify: done")
    return 0
}

private final class DeliveryBox {
    private let lock = NSLock()
    private var value: Notifier.Delivery?
    func set(_ d: Notifier.Delivery) { lock.lock(); value = d; lock.unlock() }
    func get() -> Notifier.Delivery? { lock.lock(); defer { lock.unlock() }; return value }
}
