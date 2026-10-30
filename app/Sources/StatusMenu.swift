import AppKit

// =====================================================================================
// StatusMenuController: the NSStatusItem + menu (SPEC 6). Main thread only.
//
//   [status line]                      Idle / Meeting detected / Recording mm:ss / Processing: ... / Done / Error
//   (optional detail lines)            wrapped error text or recorder warning, a standing warning (remote audio silent, recording
//                                      auto-stopped for no speech), "Auto-detection off (...)" notice, the policy line, and while idle
//                                      what is true for the next meeting (EffectiveLanes: where it is transcribed, where it is kept)
//   Components: not installed - run installer   (only in the app installer's build, FirstRun.swift, and only while something the app needs is not
//                                        installed: one click opens the first-run helper in Terminal; the item is hidden when everything is in place)
//   "Auto recording is off until the installer has finished"   (the first line while the installer's record does not exist: the recording legal notice is
//                                        part of its first step, so the controller detects nothing and starts no recording; "Start Recording Now" is off)
//   -----
//   Pause Auto Recording / Resume Auto Recording
//   Start Recording Now / Stop Recording Now        (disabled while the organisation policy switches recording off)
//   Never record <App>                  (only while the GENERIC call rule is recording an app nobody named as a call app: one click remembers
//                                        "never record this app" in call-apps.json and stops the recording like Stop Recording Now)
//   Calendar auto-start: on / off / error: ...      (only when OFFLINE_AUTOSTART=auto: CalendarWatcher.swift. One check item: the title is the state, a
//                                        click switches it off or on for this session (config.env is never written); in an error state a click means
//                                        'try again now'; closed by the policy it is disabled and says why)
//   Local-Only Meeting                  (a check item, SPEC 18 : this meeting only; active while recording and, until the
//                                        pipeline publishes it, for the meeting that was just recorded)
//   Pause Microphone / Resume Microphone (SPEC 18 : only when MIC_MUTE_GATE is on; active while a recording runs; the
//                                        guaranteed way to keep your own voice out of the recording, whatever the meeting app says)
//   Call Apps >                         (a submenu, only while CALL_DETECT is not off: every app of the built-in table, your EXTRA_MEETING_APPS, the meeting-page
//                                        sites (CALL_BROWSER_URLS) and every other app that was recorded or that you decided about; one click flips an app
//                                        between "recorded" and "never record", also before its first call; docs/DETECTION.md section 3b)
//   Never record <App>                  (while a call of another app is recorded, whatever found it: one click stops it and the app is not recorded again)
//   Open Meeting Folder
//   Reprocess Last Meeting              (disabled while a recording is active; the title and tooltip say why)
//   Connect to Company Server...        (SPEC 18 , optional: only when this Mac is set up for a company server, i.e. the policy
//                                        has an org consent or ASR_REMOTE_URL is set; disabled, with the reason, while the policy keeps the
//                                        relay closed. It asks for the enrollment code and runs `mcap asr-engines enroll remote
//                                        --code-stdin`: PipelineLauncher.swift, CompanyServerConnect. The app never sees the token.)
//   Settings...                         (Cmd-,: the Settings window, SettingsWindow.swift: config.env keys, API keys (Keychain only), the call apps, what leaves the Mac)
//   Open Logs
//   About <name>                        (AppInfo.displayName; the standard About panel: version and, only when this copy was built with MCAP_BUILT_BY, the
//                                        builder; AboutText below, docs/BRANDING.md)
//   -----
//   Quit
// =====================================================================================

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller: SessionController
    private let config: AppConfig
    private let logDir: URL
    private let connector: CompanyServerConnect
    private let calendar: CalendarWatcher?
    private let callApps: CallAppStore?
    private let callSettings: CallDetectSettings
    private let settings: SettingsWindowController?
    private let firstRun: FirstRunController?
    private let connectQueue = DispatchQueue(label: "\(AppInfo.bundleID).connect-menu", qos: .utility)

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private var detailLines: [NSMenuItem] = []
    private let componentsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Auto Recording", action: nil, keyEquivalent: "")
    private let manualItem = NSMenuItem(title: "Start Recording Now", action: nil, keyEquivalent: "")
    private let neverRecordItem = NSMenuItem(title: "Never record", action: nil, keyEquivalent: "")
    private let callAppsItem = NSMenuItem(title: "Call Apps", action: nil, keyEquivalent: "")
    private let callAppsMenu = NSMenu(title: "Call Apps")
    private let calendarItem = NSMenuItem(title: "Calendar auto-start: on", action: nil, keyEquivalent: "")
    private let localOnlyItem = NSMenuItem(title: "Local-Only Meeting", action: nil, keyEquivalent: "")
    private let micPauseItem = NSMenuItem(title: "Pause Microphone", action: nil, keyEquivalent: "")
    private let folderItem = NSMenuItem(title: "Open Meeting Folder", action: nil, keyEquivalent: "")
    private let reprocessItem = NSMenuItem(title: "Reprocess Last Meeting", action: nil, keyEquivalent: "")
    private let connectItem = NSMenuItem(title: CompanyServerConnect.menuTitle, action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: tr("Settings\u{2026}", ko: "설정\u{2026}"), action: nil, keyEquivalent: ",")
    private let logsItem = NSMenuItem(title: "Open Logs", action: nil, keyEquivalent: "")
    private let aboutItem = NSMenuItem(title: "About \(AppInfo.displayName)", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")

    private var state = ControllerState()
    private var ticker: Timer?
    private var connectAvailability = CompanyServerConnect.Availability.hidden       // the last verdict (main thread)
    private var connectBusy = false                                                  // an enrollment (or its code prompt) is under way (main thread)

    /// - connect: the connector of "Connect to Company Server..." (App.swift can hand over `pipeline.companyServerConnect(notifier:)`, which shares the
    ///   launcher's policy box and the app's notifier). Without one the menu makes its own: it reads the policy files lazily and posts through a
    ///   notifier of its own. Until the person clicks the item nothing is started: the verdict only reads the policy files and config.env.
    /// - calendar: the calendar auto-start (nil unless OFFLINE_AUTOSTART=auto: then the item is not in the menu at all).
    /// - callApps: the decisions per call app (nil unless CALL_DETECT is on: then neither 'Never record <App>' nor the Call Apps submenu is in the menu).
    /// - callSettings: the apps the Call Apps submenu lists besides the decisions (the built-in table, EXTRA_MEETING_APPS, the meeting-page sites).
    /// - settings: the Settings window (nil = the item "Settings..." is not in the menu: the self tests).
    /// - firstRun: the first-run check of the app installer (nil = no item "Components: ..." in the menu: the self tests; the item is also hidden while nothing is missing).
    init(controller: SessionController, config: AppConfig, logDir: URL, connect: CompanyServerConnect? = nil, calendar: CalendarWatcher? = nil,
         callApps: CallAppStore? = nil, callSettings: CallDetectSettings = .defaults, settings: SettingsWindowController? = nil, firstRun: FirstRunController? = nil) {
        self.controller = controller
        self.config = config
        self.logDir = logDir
        self.callApps = callApps
        self.callSettings = callSettings
        self.settings = settings
        self.firstRun = firstRun
        self.connector = connect ?? CompanyServerConnect(config: config, logDir: logDir)
        self.calendar = calendar
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        statusItem.menu = menu
        menu.delegate = self
        apply(ControllerState())
        refreshConnectItem()
        calendarItem.isHidden = calendar == nil
        settingsItem.isHidden = settings == nil
        callAppsItem.isHidden = callApps == nil
        neverRecordItem.isHidden = true
        if let calendar = calendar { updateCalendar(calendar.status) }
        showComponents(firstRun?.status ?? .notApplicable)
        firstRun?.onStatusChange = { [weak self] status in self?.showComponents(status) }
    }

    // MARK: Menu construction

    private func buildMenu() {
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        for _ in 0..<Self.maxDetailLines {                 // detail lines (hidden unless used)
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            detailLines.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        callAppsItem.submenu = callAppsMenu
        callAppsMenu.autoenablesItems = false
        for (item, selector) in [(componentsItem, #selector(openInstaller)),
                                 (pauseItem, #selector(togglePause)),
                                 (manualItem, #selector(toggleManual)),
                                 (neverRecordItem, #selector(neverRecordCurrentApp)),
                                 (calendarItem, #selector(toggleCalendar)),
                                 (localOnlyItem, #selector(toggleLocalOnly)),
                                 (micPauseItem, #selector(toggleMicPause)),
                                 (callAppsItem, #selector(noAction)),
                                 (folderItem, #selector(openMeetingFolder)),
                                 (reprocessItem, #selector(reprocessLast)),
                                 (connectItem, #selector(connectCompanyServer)),
                                 (settingsItem, #selector(openSettings)),
                                 (logsItem, #selector(openLogs)),
                                 (aboutItem, #selector(showAbout))] {
            item.action = selector
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }
        connectItem.isHidden = true                        // until the verdict says this Mac is set up for a company server
        menu.addItem(.separator())
        quitItem.action = #selector(quit)
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: State -> UI

    /// Called on the main queue by the controller callback.
    func update(_ newState: ControllerState) {
        apply(newState)
        var recording = false
        if case .recording = newState.status { recording = true }
        settings?.recordingStateChanged(recording: recording, hold: newState.restartHold)
    }

    private func apply(_ newState: ControllerState) {
        state = newState

        // elapsed-time ticker only while recording
        if case .recording = newState.status {
            if ticker == nil {
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshTimeDependentUI() }
                RunLoop.main.add(t, forMode: .common)      // keeps ticking while the menu is open
                ticker = t
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }

        pauseItem.title = newState.paused ? "Resume Auto Recording" : "Pause Auto Recording"
        let manual = Self.manualItemState(for: newState)
        manualItem.title = manual.title
        manualItem.isEnabled = manual.enabled
        manualItem.toolTip = manual.tooltip
        let never = Self.neverRecordItemState(for: newState)
        neverRecordItem.title = never.title
        neverRecordItem.isHidden = !never.visible || callApps == nil
        neverRecordItem.toolTip = never.tooltip
        let localOnly = Self.localOnlyItemState(for: newState)
        localOnlyItem.title = localOnly.title
        localOnlyItem.state = localOnly.checked ? .on : .off
        localOnlyItem.isEnabled = localOnly.enabled
        localOnlyItem.toolTip = localOnly.tooltip
        let micPause = Self.micPauseItemState(for: newState)
        micPauseItem.title = micPause.title
        micPauseItem.state = micPause.checked ? .on : .off
        micPauseItem.isEnabled = micPause.enabled
        micPauseItem.isHidden = !micPause.visible
        micPauseItem.toolTip = micPause.tooltip
        let reprocess = Self.reprocessItemState(for: newState)
        reprocessItem.isEnabled = reprocess.enabled
        reprocessItem.title = reprocess.title
        reprocessItem.toolTip = reprocess.tooltip
        refreshTimeDependentUI()
    }

    /// "Start Recording Now" / "Stop Recording Now". While the organisation policy switches recording off (recording.enabled=false) the
    /// start item is disabled and says why (the controller would refuse the start anyway). Pure, so selftest-session checks it.
    struct ManualItemState: Equatable {
        var title: String
        var enabled: Bool
        var tooltip: String?
    }

    static func manualItemState(for state: ControllerState) -> ManualItemState {
        if case .recording = state.status { return ManualItemState(title: "Stop Recording Now", enabled: true, tooltip: nil) }
        if state.recordingBlockedByPolicy {
            return ManualItemState(title: tr("Start Recording Now (off by organisation policy)", ko: "Start Recording Now (조직 정책으로 꺼짐)"), enabled: false,
                                   tooltip: tr("The organisation policy (recording.enabled) blocks recording on this Mac", ko: "조직 정책(recording.enabled)이 이 Mac의 녹음을 막고 있어요"))
        }
        if state.installHold {
            return ManualItemState(title: tr("Start Recording Now (after the installer)", ko: "Start Recording Now (설치가 끝난 뒤)"), enabled: false,
                                   tooltip: installHoldTooltip)
        }
        return ManualItemState(title: "Start Recording Now", enabled: true, tooltip: nil)
    }

    /// "Never record <App>": while a call of another app is being recorded (state.callApp): an app of the built-in table, an EXTRA_MEETING_APPS app, a meeting page
    /// in a browser (by its site) or an app the generic rule guessed. One click remembers the decision (call-apps.json) and stops this recording like "Stop Recording
    /// Now" (it is kept and queued). Pure, so selftest-session checks it.
    struct NeverRecordItemState: Equatable {
        var title: String
        var visible: Bool
        var tooltip: String?
    }

    static func neverRecordItemState(for state: ControllerState) -> NeverRecordItemState {
        guard case .recording = state.status, let call = state.callApp else {
            return NeverRecordItemState(title: "Never record", visible: false, tooltip: nil)
        }
        let tooltip = call.generic
            ? tr("\(call.name) looks like a call to the app, but nobody named it as one. Click if it is not: this recording stops and the app is never recorded again (the Call Apps menu undoes it)",
                 ko: "\(call.name)을(를) 앱이 통화로 판단했어요. 통화가 아니라면 누르세요: 이 녹음을 멈추고 이 앱은 다시 녹음하지 않아요 (Call Apps 메뉴에서 되돌릴 수 있어요)")
            : tr("Click to stop this recording and never record \(call.name) again (the Call Apps menu undoes it)",
                 ko: "누르면 이 녹음을 멈추고 \(call.name)은(는) 다시 녹음하지 않아요 (Call Apps 메뉴에서 되돌릴 수 있어요)")
        return NeverRecordItemState(title: "Never record \(truncate(call.name, 30))", visible: true, tooltip: tooltip)
    }

    /// The rows of the Call Apps submenu: every decision in the file, plus every app of the built-in table, every EXTRA_MEETING_APPS app and (with CALL_BROWSER_URLS) every
    /// meeting-page site that has no decision yet (shown as recorded: nothing is denied until you say so), so an app can be switched off BEFORE its first call. Sorted by
    /// name, then id. Pure.
    static func callAppRows(entries: [CallAppEntry], settings: CallDetectSettings) -> [CallAppEntry] {
        var rows = entries
        var seen = Set(entries.map { $0.id })
        func add(_ id: String, _ name: String) {
            let key = id.lowercased()
            if seen.insert(key).inserted { rows.append(CallAppEntry(id: key, name: name, decision: .allowed)) }
        }
        for app in CallApps.known { add(app.id, app.name) }
        for app in settings.extraApps { add(app.id, app.name) }
        if settings.browserURLs { for site in WebMeetingURL.sites { add(CallTracker.webKey(site.siteID), site.name) } }
        return rows.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    /// One row of the Call Apps submenu. The check mark = the app is recorded when it looks like a call; no mark = "never record". Pure.
    struct CallAppItemState: Equatable {
        var title: String
        var checked: Bool
        var tooltip: String
    }

    static func callAppItemState(_ entry: CallAppEntry) -> CallAppItemState {
        switch entry.decision {
        case .allowed:
            return CallAppItemState(title: truncate(entry.name, 40), checked: true,
                                    tooltip: tr("Recorded when it looks like a call (\(entry.id)). Click to never record it", ko: "통화처럼 보이면 녹음해요 (\(entry.id)). 누르면 다시는 녹음하지 않아요"))
        case .denied:
            return CallAppItemState(title: truncate(entry.name, 40) + tr(" (never record)", ko: " (녹음 안 함)"), checked: false,
                                    tooltip: tr("Never recorded (\(entry.id)). Click to allow it again", ko: "녹음하지 않아요 (\(entry.id)). 누르면 다시 허용해요"))
        }
    }

    /// The disabled lines at the top of the submenu: what it is for, or why nothing can be changed. Pure.
    static func callAppsMenuHeader(entries: [CallAppEntry], problem: String?) -> [String] {
        if let p = problem {
            return [tr("\(p): calls of other apps are not recorded", ko: "\(p): 다른 앱의 통화는 녹음하지 않아요"),
                    tr("Fix or remove call-apps.json, then open this menu again", ko: "call-apps.json을 고치거나 지운 뒤 이 메뉴를 다시 열어 주세요")]
        }
        if entries.isEmpty {
            return [tr("No app yet: an app that is recorded as a call appears here", ko: "아직 앱이 없어요: 통화로 녹음된 앱이 여기에 나타나요")]
        }
        return [tr("Click an app to switch between recorded and never record", ko: "앱을 누르면 녹음함과 녹음 안 함이 바뀌어요")]
    }

    /// "Calendar auto-start: on / off / error: ...": one check item for the calendar auto-start (CalendarWatcher). Pure, so selftest-session checks every
    /// status without a status item.
    ///   - on: checked, a click switches it off for this session;
    ///   - off (switched off from the menu): unchecked, a click switches it on again;
    ///   - error: unchecked, the title says what is wrong, a click tries again now (the tooltip has the helper's own short message);
    ///   - blocked (the organisation policy, or local-only as the start value): disabled, and says why.
    struct CalendarItemState: Equatable {
        var title: String
        var checked: Bool
        var enabled: Bool
        var tooltip: String?
    }

    static var calendarTitle: String { tr("Calendar auto-start", ko: "캘린더 자동 시작") }

    static func calendarItemState(for status: CalendarStatus) -> CalendarItemState {
        let base = calendarTitle + ": "
        switch status {
        case .on:
            return CalendarItemState(title: base + tr("on", ko: "켜짐"), checked: true, enabled: true,
                                     tooltip: tr("Starts a recording for an in-person event of your Google Calendar. Click to switch it off until you quit the app (config.env is not changed)",
                                                 ko: "구글 캘린더의 대면 일정에 맞춰 녹음을 시작해요. 누르면 앱을 끌 때까지 꺼요 (config.env는 바뀌지 않아요)"))
        case .off:
            return CalendarItemState(title: base + tr("off", ko: "꺼짐"), checked: false, enabled: true,
                                     tooltip: tr("Click to switch it on again (this session only; config.env is not changed)", ko: "누르면 다시 켜요 (이번 실행에만 적용, config.env는 바뀌지 않아요)"))
        case .blocked(let why):
            return CalendarItemState(title: base + tr("off", ko: "꺼짐") + " (\(why.menuText))", checked: false, enabled: false, tooltip: why.menuText)
        case .error(let problem):
            let detail = problem.message.isEmpty ? "" : problem.message + " · "
            return CalendarItemState(title: base + tr("error: ", ko: "오류: ") + problem.kind.menuText, checked: false, enabled: true,
                                     tooltip: detail + tr("Click to try again now", ko: "누르면 지금 다시 시도해요"))
        }
    }

    /// Called on the main queue (the watcher delivers there).
    func updateCalendar(_ status: CalendarStatus) {
        let item = Self.calendarItemState(for: status)
        calendarItem.title = item.title
        calendarItem.state = item.checked ? .on : .off
        calendarItem.isEnabled = item.enabled
        calendarItem.toolTip = item.tooltip
    }

    /// "Local-Only Meeting": a check item for THIS meeting only (the English label, the tooltips and notes in the UI language).
    ///   - the policy keeps it on: checked, disabled, "fixed by organisation policy";
    ///   - the pipeline is too old to honour the value a click would set: disabled, "the pipeline is too old to support local-only";
    ///   - nothing to change (no recording, no recent session that can still take it): disabled;
    ///   - OFF: a click turns it on (recording, or the recorded session before publishing); ON: a click turns it off only while it can
    ///     still be relaxed (while recording, or before the pipeline has started).
    /// Pure, so selftest-session checks every combination without a status item.
    struct LocalOnlyItemState: Equatable {
        var title: String
        var checked: Bool
        var enabled: Bool
        var tooltip: String?
    }

    static let localOnlyTitle = "Local-Only Meeting"

    static func localOnlyItemState(for state: ControllerState) -> LocalOnlyItemState {
        let base = localOnlyTitle
        guard let v = state.localOnly else {
            return LocalOnlyItemState(title: base, checked: false, enabled: false, tooltip: tr("Only for a meeting that is recording or has not started processing", ko: "녹음 중이거나 처리가 시작되기 전인 회의에만 쓸 수 있어요"))
        }
        if v.locked {
            return LocalOnlyItemState(title: "\(base) " + tr("(fixed by organisation policy)", ko: "(조직 정책으로 고정)"), checked: true, enabled: false, tooltip: tr("Fixed by organisation policy", ko: "조직 정책으로 고정"))
        }
        if v.pipelineTooOld {
            return LocalOnlyItemState(title: "\(base) " + tr("(pipeline too old)", ko: "(파이프라인이 오래됨)"), checked: v.value, enabled: false, tooltip: tr("The pipeline is too old to support local-only", ko: "파이프라인이 오래돼 로컬 전용을 지원하지 않아요"))
        }
        guard v.targetSession != nil else {
            return LocalOnlyItemState(title: base, checked: v.value, enabled: false, tooltip: tr("Only for a meeting that is recording or has not started processing", ko: "녹음 중이거나 처리가 시작되기 전인 회의에만 쓸 수 있어요"))
        }
        if v.value {
            return v.canRelax
                ? LocalOnlyItemState(title: base, checked: true, enabled: true,
                                     tooltip: tr("This meeting is local-only. Turning it off brings back the note, calendar lookup and archiving your settings allow (this meeting only)", ko: "이 회의는 로컬 전용이에요. 끄면 설정에 따라 회의록·캘린더 조회·보관이 다시 켜져요 (이 회의만 적용)"))
                : LocalOnlyItemState(title: base, checked: true, enabled: false, tooltip: tr("Processing has already started, so it can no longer be turned off", ko: "처리가 이미 시작돼 더 이상 끌 수 없어요"))
        }
        return LocalOnlyItemState(title: base, checked: false, enabled: true,
                                  tooltip: tr("Turn on to transcribe this meeting on this Mac only, with no note (Claude), calendar lookup or upload (this meeting only)", ko: "켜면 이 회의는 전사를 이 Mac에서만 하고 회의록(Claude)·캘린더 조회·Drive 업로드를 하지 않아요 (이 회의만 적용)"))
    }

    /// "Pause Microphone": not in the menu at all while MIC_MUTE_GATE is off (the personal install keeps today's menu);
    /// with the gate on it is there all the time, active while a recording runs. While paused the title says Resume and the item is checked.
    /// Pure, so selftest-session checks every combination without a status item.
    struct MicPauseItemState: Equatable {
        var title: String
        var visible: Bool
        var enabled: Bool
        var checked: Bool
        var tooltip: String?
    }

    static let micPauseTitle = "Pause Microphone"
    static let micResumeTitle = "Resume Microphone"
    /// The end of the status line while the microphone is paused (the first line of the menu and the tooltip of the icon).
    static var micPausedSuffix: String { tr(" · microphone paused", ko: " · 마이크 일시중지") }

    static func micPauseItemState(for state: ControllerState) -> MicPauseItemState {
        guard let gate = state.micGate else {
            return MicPauseItemState(title: micPauseTitle, visible: false, enabled: false, checked: false, tooltip: nil)
        }
        guard gate.recording else {
            return MicPauseItemState(title: micPauseTitle, visible: true, enabled: false, checked: false,
                                     tooltip: tr("Only available during a recording", ko: "녹음 중인 회의에서만 쓸 수 있어요"))
        }
        if gate.paused {
            return MicPauseItemState(title: micResumeTitle, visible: true, enabled: true, checked: true,
                                     tooltip: tr("The microphone is paused: your voice is not recorded for this stretch. Click to record again", ko: "마이크 일시중지 중이에요. 이 시간의 내 목소리는 기록되지 않아요. 누르면 다시 기록해요"))
        }
        return MicPauseItemState(title: micPauseTitle, visible: true, enabled: true, checked: false,
                                 tooltip: tr("Click to stop recording your voice until you click again (this meeting only). It works whatever the meeting app's mute signal says", ko: "누르면 다시 누를 때까지 내 목소리가 기록되지 않아요 (이 회의만 적용). 회의 앱의 음소거 신호와 상관없이 항상 동작해요"))
    }

    /// "Reprocess Last Meeting" is a long ASR run: while a recording is active it is disabled (and says why in its title and
    /// tooltip), because it would compete with the recorder for CPU, memory and disk. Pure, so selftest-session checks it.
    struct ReprocessItemState: Equatable {
        var enabled: Bool
        var title: String
        var tooltip: String?
    }

    static func reprocessItemState(for state: ControllerState) -> ReprocessItemState {
        if case .recording = state.status {
            return ReprocessItemState(enabled: false,
                                      title: "Reprocess Last Meeting (not while recording)",
                                      tooltip: "Disabled while a recording is active: reprocessing is a long transcription run that would compete with the recorder for CPU, memory and disk. Available again after the recording stops.")
        }
        return ReprocessItemState(enabled: true, title: "Reprocess Last Meeting", tooltip: nil)
    }

    /// "Connect to Company Server...": not in the menu at all unless this Mac is set up for a company server (the policy has
    /// an org consent, or ASR_REMOTE_URL is set: `CompanyServerConnect.availability`), so the personal menu stays as it was. With the policy
    /// keeping the relay closed the item is there, disabled, and says why; while an enrollment is under way it is disabled too.
    /// Pure, so selftest-session checks every case without a status item.
    struct ConnectItemState: Equatable {
        var title: String
        var visible: Bool
        var enabled: Bool
        var tooltip: String?
    }

    static func connectItemState(for availability: CompanyServerConnect.Availability, busy: Bool = false) -> ConnectItemState {
        let base = CompanyServerConnect.menuTitle
        switch availability {
        case .hidden:
            return ConnectItemState(title: base, visible: false, enabled: false, tooltip: nil)
        case .denied(let why):
            return ConnectItemState(title: "\(base) " + tr("(blocked by organisation policy)", ko: "(조직 정책으로 막힘)"), visible: true, enabled: false, tooltip: why.reasonText)
        case .ready:
            if busy {
                return ConnectItemState(title: "\(base) " + tr("(connecting)", ko: "(연결 중)"), visible: true, enabled: false, tooltip: tr("Connecting to the company server", ko: "회사 서버에 연결하는 중이에요"))
            }
            return ConnectItemState(title: base, visible: true, enabled: true,
                                    tooltip: tr("Enter the enrollment code from your administrator to register this Mac with the company server. The credentials are stored only in the keychain and the app never sees them", ko: "관리자에게 받은 등록 코드를 입력해 이 Mac을 회사 서버에 등록해요. 인증 정보는 키체인에만 저장되고 앱은 보지 못해요"))
        }
    }

    /// What "About <name>" shows in the standard About panel (pure, so selftest-session checks it without a window).
    /// The version is CFBundleShortVersionString and the only thing said about the build: no build date, because scripts/build_app.sh writes no
    /// timestamp (builds are deterministic). The builder is the optional Info.plist key MCBuiltBy, which build_app.sh sets from MCAP_BUILT_BY
    /// (docs/BRANDING.md); a copy built without it names nobody. The same rules as build_app.sh (normalize_built_by): whitespace and control
    /// characters, newlines included, become one space, the ends are trimmed, a value longer than builtByMaxLength is cut and ends in an ellipsis.
    struct AboutText: Equatable {
        var version: String
        var copyright: String
        var builtBy: String?           // nil when there is no builder
        var credits: String            // "Built by <builtBy>"; empty when there is no builder
    }

    static let aboutCopyright = "Copyright 2026 Meeting Capture contributors"     // the same words as NOTICE and app/Info.plist.template
    static let builtByMaxLength = 80

    /// Works on Unicode scalars, ASCII separators only (space and the control characters), exactly like the shell function.
    static func normalizedBuiltBy(_ raw: String?) -> String? {
        let words = (raw ?? "").unicodeScalars.split(whereSeparator: { $0.value <= 0x20 || $0.value == 0x7f })
        var text = words.map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        if text.unicodeScalars.count > builtByMaxLength {
            var head = String(String.UnicodeScalarView(text.unicodeScalars.prefix(builtByMaxLength - 1)))
            if head.hasSuffix(" ") { head.removeLast() }
            text = head + "\u{2026}"
        }
        return text.isEmpty ? nil : text
    }

    static func aboutText(version: String?, builtBy: String?) -> AboutText {
        let v = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let by = normalizedBuiltBy(builtBy)
        return AboutText(version: v.isEmpty ? "unknown" : v, copyright: aboutCopyright, builtBy: by, credits: by.map { "Built by \($0)" } ?? "")
    }

    /// Text shown for a state (pure, so selftest-session can check it without creating a status item).
    struct MenuText: Equatable {
        var headline: String         // the disabled first menu line (also the tooltip)
        var lines: [String]          // extra disabled lines under it
        var buttonTitle: String      // text next to the icon ("mm:ss" while recording)
    }

    static let detectionOffText = "Auto-detection off (ENABLED_PLATFORMS empty)"
    /// The app installer has not finished (FirstRun.holdsRecording): the recording legal notice is part of its first step, so nothing records before it.
    static var installHoldText: String { tr("Auto recording is off until the installer has finished", ko: "설치가 끝날 때까지 자동 녹음이 꺼져 있어요") }
    static var installHoldTooltip: String {
        tr("The installer shows the recording legal notice and asks for the macOS permissions. Until it has finished, nothing is detected and nothing is recorded. Use the item \"Components: ...\" to run it",
           ko: "설치 프로그램이 녹음 고지를 보여 주고 macOS 권한을 요청해요. 끝나기 전에는 아무것도 감지하거나 녹음하지 않아요. \"구성 요소: ...\" 항목으로 실행하세요")
    }
    static var policyBlockedText: String { tr("Recording is off by organisation policy", ko: "조직 정책으로 녹음이 꺼져 있어요") }

    /// Worst case: an error or recorder warning (4 wrapped lines) + remote-silent (2) + notice (3) + the detection-off line (1), or while
    /// idle: a notice (3) + detection off (1) + the policy line (1) + the two info lines.
    static let maxDetailLines = 10

    static func menuText(for state: ControllerState, now: Date) -> MenuText {
        var lines: [String] = []
        var headline: String
        var title = ""

        switch state.status {
        case .idle:
            if state.installHold {
                headline = installHoldText
            } else if state.paused {
                headline = "Paused: auto recording is off"
            } else if state.autoDetectionOff {
                headline = detectionOffText
            } else {
                headline = "Idle: waiting for a meeting"
            }
        case .candidate(let p):
            headline = "Meeting detected: \(state.callApp?.name ?? p.label)"
        case .recording(let p, let since):
            let elapsed = formatElapsed(now.timeIntervalSince(since))
            headline = state.calendarRecording ? "Recording (calendar)  \(elapsed)"
                : state.manualRecording ? "Recording (manual)  \(elapsed)" : "Recording \(state.callApp?.name ?? p.label)  \(elapsed)"
            if state.micGate?.paused == true { headline += micPausedSuffix }
            title = elapsed
        case .processing(let text):
            headline = "Processing: \(text)"
        case .done(let t):
            headline = "Done: \(t)"
        case .error(let text):
            headline = "Error"
            lines = wrap(text, width: 58, maxLines: 4)
        }
        if let w = state.warning, lines.isEmpty {
            lines = wrap("Warning: \(w)", width: 58, maxLines: 4)
        }
        // Standing warnings (SPEC 15): while recording the remote track looks silent; after a stop, what happened to the recording.
        if state.remoteSilentSuspected {
            lines += wrap("Warning: remote audio is silent, the other side may be missing. Check the System Audio Recording permission.",
                          width: 58, maxLines: 2)
        }
        if let n = state.notice { lines += wrap(n, width: 58, maxLines: 3) }
        // Detection off is a standing condition: keep it visible in every state, not only when idle.
        if state.autoDetectionOff, headline != detectionOffText { lines.append(detectionOffText) }
        // SPEC 18: the policy switched recording off (standing), and while idle what is true for the next meeting.
        if state.recordingBlockedByPolicy { lines.append(policyBlockedText) }
        if case .idle = state.status { lines += state.infoLines }
        return MenuText(headline: truncate(headline, 64), lines: lines, buttonTitle: title)
    }

    /// The menu-bar icon of a state as an ordered list of SF Symbol names (the first one the system has wins) and whether it is drawn in red.
    /// One pure function so that selftest-session checks the whole mapping. Every first name exists on macOS 14.0 (SF Symbols 5; checked with
    /// CoreGlyphs' name_availability.plist and by rendering them, docs/BRANDING.md); the older symbols of the former icon set stay at the end of every list,
    /// so a macOS that lacks a name still shows something.
    ///   idle        pencil.and.list.clipboard             recording   red pencil.and.scribble, alternating with pencil.line once a second
    ///   candidate   the idle symbol (SF Symbols has no circle variant of it)        paused      pause.circle
    ///   detection off   pencil.slash (the clipboard has no slashed variant)           processing  ellipsis.bubble
    ///   done        checkmark.circle                      error       exclamationmark.triangle
    /// `elapsed` = whole seconds of the running recording (the ticker of `apply` fires once a second only while recording): the two frames of the
    /// recording icon follow its parity. `reduceMotion` (System Settings > Accessibility > Display) keeps the first frame still.
    struct MenuIcon: Equatable {
        var names: [String]
        var red: Bool
    }

    static let idleSymbols = ["pencil.and.list.clipboard", "list.clipboard", "waveform"]
    static let recordingSymbols = (writing: ["pencil.and.scribble", "pencil", "record.circle.fill"], line: ["pencil.line", "pencil", "record.circle.fill"])

    static func menuIcon(for state: ControllerState, elapsed: Int = 0, reduceMotion: Bool = false) -> MenuIcon {
        switch state.status {
        case .idle:
            if state.paused || state.installHold { return MenuIcon(names: ["pause.circle", "waveform"], red: false) }
            if state.autoDetectionOff { return MenuIcon(names: ["pencil.slash", "waveform.slash", "waveform"], red: false) }
            return MenuIcon(names: idleSymbols, red: false)
        case .candidate:
            return MenuIcon(names: idleSymbols, red: false)
        case .recording:
            let second = reduceMotion ? 0 : max(0, elapsed)
            return MenuIcon(names: second % 2 == 0 ? recordingSymbols.writing : recordingSymbols.line, red: true)
        case .processing:
            return MenuIcon(names: ["ellipsis.bubble", "ellipsis.circle", "gearshape"], red: false)
        case .done:
            return MenuIcon(names: ["checkmark.circle", "checkmark"], red: false)
        case .error:
            return MenuIcon(names: ["exclamationmark.triangle"], red: false)
        }
    }

    private func refreshTimeDependentUI() {
        let now = Date()
        var elapsed = 0
        if case .recording(_, let since) = state.status { elapsed = Int(now.timeIntervalSince(since)) }
        let icon = Self.menuIcon(for: state, elapsed: elapsed, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let imageNames = icon.names
        let tint: NSColor? = icon.red ? .systemRed : nil
        let text = Self.menuText(for: state, now: now)

        statusLine.title = text.headline
        for (i, item) in detailLines.enumerated() {
            if i < text.lines.count {
                item.title = text.lines[i]
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }

        if let button = statusItem.button {
            let image = Self.symbol(imageNames, description: text.headline, tint: tint)
            button.image = image
            button.imagePosition = image == nil ? .noImage : .imageLeading
            if text.buttonTitle.isEmpty {
                button.title = image == nil ? "MC" : ""
            } else {
                button.title = image == nil ? "\u{25CF} \(text.buttonTitle)" : " \(text.buttonTitle)"   // "●" only if the symbol is missing
            }
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = text.headline
        }
    }

    // MARK: Actions

    @objc private func togglePause() {
        controller.setPaused(!state.paused)
    }

    @objc private func toggleManual() {
        if case .recording = state.status {
            controller.stopRecordingNow()
        } else if Self.manualItemState(for: state).enabled {
            controller.startRecordingNow()
        }
    }

    @objc private func neverRecordCurrentApp() {
        guard Self.neverRecordItemState(for: state).visible else { return }
        controller.neverRecordCurrentCallApp()                  // asynchronous: the controller works on its own queue
    }

    @objc private func noAction() {}

    /// The submenu is built when the menu opens (the file is read again, so a hand edit and a decision from the other menu item show up).
    private func refreshCallAppsMenu() {
        guard let store = callApps else { return }
        store.reload()
        callAppsMenu.removeAllItems()
        let entries = Self.callAppRows(entries: store.entries(), settings: callSettings)
        let problem = store.problem
        for line in Self.callAppsMenuHeader(entries: entries, problem: problem) {
            let header = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            header.isEnabled = false
            callAppsMenu.addItem(header)
        }
        if !entries.isEmpty { callAppsMenu.addItem(.separator()) }
        for entry in entries {
            let st = Self.callAppItemState(entry)
            let item = NSMenuItem(title: st.title, action: #selector(flipCallApp(_:)), keyEquivalent: "")
            item.target = self
            item.state = st.checked ? .on : .off
            item.toolTip = st.tooltip
            item.representedObject = entry.id
            item.isEnabled = problem == nil
            callAppsMenu.addItem(item)
        }
    }

    @objc private func flipCallApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let store = callApps else { return }
        let next: CallDecision = store.decision(for: id) == .denied ? .allowed : .denied
        controller.setCallDecision(bundleID: id, decision: next)
    }

    @objc private func toggleCalendar() {
        guard let calendar = calendar, Self.calendarItemState(for: calendar.status).enabled else { return }
        calendar.menuClicked()                              // asynchronous: the watcher may be inside its 20 s command
    }

    @objc private func toggleLocalOnly() {
        guard Self.localOnlyItemState(for: state).enabled else { return }
        // The controller works on its own queue and may be busy starting a recorder: never wait for it on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [controller] in controller.toggleLocalOnly() }
    }

    @objc private func toggleMicPause() {
        guard Self.micPauseItemState(for: state).enabled else { return }
        // Same as the local-only item: the controller's queue may be busy, never wait for it on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [controller] in controller.toggleMicrophonePause() }
    }

    @objc private func openMeetingFolder() {
        // lastMeetingFolder() lists directories on Google Drive: never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [controller] in
            let url = controller.lastMeetingFolder()
            DispatchQueue.main.async {
                guard let url = url else {
                    Log.warn("Open Meeting Folder: no folder found")
                    NSSound.beep()
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func reprocessLast() {
        guard Self.reprocessItemState(for: state).enabled else { return }       // never while recording (the item is disabled anyway)
        controller.reprocessLast()
    }

    // MARK: Connect to Company Server

    func menuWillOpen(_ menu: NSMenu) {
        firstRun?.refreshStatus()                           // the helper may have finished since the last look (cheap file checks, off the main thread)
        refreshCallAppsMenu()
        refreshConnectItem()                                // the policy may have changed since the last look (the read is a few lstat calls)
    }

    /// Asks the connector for its verdict in the background (it reads the policy and config.env) and shows it.
    private func refreshConnectItem() {
        let connector = self.connector
        connectQueue.async { [weak self] in
            let verdict = connector.availability()
            DispatchQueue.main.async { self?.showConnectItem(verdict) }
        }
    }

    private func showConnectItem(_ verdict: CompanyServerConnect.Availability) {
        connectAvailability = verdict
        let item = Self.connectItemState(for: verdict, busy: connectBusy)
        connectItem.title = item.title
        connectItem.isEnabled = item.enabled
        connectItem.isHidden = !item.visible
        connectItem.toolTip = item.tooltip
    }

    private func setConnectBusy(_ busy: Bool) {
        connectBusy = busy
        showConnectItem(connectAvailability)
    }

    /// The click: first the policy as of now and the runtime checks, off the main thread (nothing is asked from the person when nothing could be
    /// done with the answer), then the code prompt, then the enrollment. Every end, good or bad, is one notification (the connector posts it).
    @objc private func connectCompanyServer() {
        guard Self.connectItemState(for: connectAvailability, busy: connectBusy).enabled else { return }
        setConnectBusy(true)
        let connector = self.connector
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let refusal = connector.precheck() {
                connector.report(.refused(refusal))
                DispatchQueue.main.async { self?.setConnectBusy(false); self?.refreshConnectItem() }
                return
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let code = Self.askEnrollmentCode() else { self.setConnectBusy(false); return }       // cancelled
                connector.connect(code: code) { _ in
                    DispatchQueue.main.async { self.setConnectBusy(false); self.refreshConnectItem() }
                }
            }
        }
    }

    /// The code prompt. The code is not a secret (SPEC 18: one use, 10 minutes), so the field shows what is typed, which lets the person see a
    /// typo; it can be pasted into with the keyboard (`EnrollmentCodeField`: the notification for a malformed code tells the person to paste).
    /// nil = cancelled or empty. The text goes to `CompanyServerConnect.connect` and from there to the child's stdin, nowhere else.
    private static func askEnrollmentCode() -> String? {
        NSApp.activate(ignoringOtherApps: true)             // a menu-bar app is not active: the dialog would open behind the other windows
        let alert = NSAlert()
        alert.messageText = tr("Connect to the company server", ko: "회사 서버에 연결")
        alert.informativeText = tr("Enter the enrollment code from your administrator. The code can be used once. The app does not see the credentials: they go straight into the keychain.",
                                   ko: "관리자에게 받은 등록 코드를 입력하세요. 코드는 한 번만 쓸 수 있어요. 인증 정보는 앱이 보지 않고 키체인에 직접 저장돼요.")
        alert.addButton(withTitle: tr("Connect", ko: "연결"))
        alert.addButton(withTitle: tr("Cancel", ko: "취소"))
        let field = EnrollmentCodeField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = tr("Enrollment code", ko: "등록 코드")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @objc private func openSettings() {
        settings?.show()
    }

    /// "Components: not installed - run installer": the item exists only while the first-run check says something is missing (FirstRun.menuItem).
    private func showComponents(_ status: FirstRun.Status) {
        let item = firstRun?.menuItem(for: status) ?? FirstRun.menuItem(for: status)
        componentsItem.title = item.title
        componentsItem.toolTip = item.tooltip
        componentsItem.isHidden = !item.visible
    }

    @objc private func openInstaller() {
        firstRun?.startInstaller()
    }

    @objc private func openLogs() {
        let log = logDir.appendingPathComponent("app.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(logDir)
        }
    }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let about = Self.aboutText(version: info?["CFBundleShortVersionString"] as? String, builtBy: info?["MCBuiltBy"] as? String)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.displayName,
            .applicationVersion: about.version,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): about.copyright,     // the panel would show the Info.plist line, which repeats the builder
        ]
        if !about.credits.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            options[.credits] = NSAttributedString(string: about.credits, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        }
        NSApp.activate(ignoringOtherApps: true)             // a menu-bar app is not active: the panel would open behind the other windows
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    private static func symbol(_ names: [String], description: String, tint: NSColor?) -> NSImage? {
        for name in names {
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: description) else { continue }
            if let tint = tint,
               let colored = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) {
                colored.isTemplate = false          // keep the colour (template images are tinted by the menu bar)
                return colored
            }
            base.isTemplate = true
            return base
        }
        return nil
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        return s.count <= n ? s : String(s.prefix(n - 1)) + "\u{2026}"
    }

    /// Greedy word wrap for disabled menu lines (NSMenuItem titles do not wrap by themselves).
    static func wrap(_ text: String, width: Int, maxLines: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines[maxLines - 1] = truncate(lines[maxLines - 1] + " \u{2026}", width)
        }
        return lines
    }
}

// =====================================================================================
// EnrollmentCodeField: the text field of the code prompt of "Connect to Company Server...".
//
// The app is an accessory app (App.swift: setActivationPolicy(.accessory)) and has no main menu, so there is no Edit menu either. AppKit routes the
// standard editing key equivalents (Cmd-V, Cmd-C, Cmd-X, Cmd-A, Cmd-Z) through the main menu: without one they do nothing, not even in a dialog, and a
// code that was copied from a mail or a chat could only be put in with the right-click menu. The field answers those keys itself, through its field
// editor. Nothing else about the field is different.
// =====================================================================================
final class EnrollmentCodeField: NSTextField {
    /// What a key does in an editing field: the standard Edit-menu commands and nothing else (pure and free of AppKit types, so selftest-session
    /// checks every key without a window).
    enum EditCommand: Equatable { case paste, copy, cut, selectAll, undo, redo }

    /// The command of the key that makes `key` without Shift, with Command held and exactly the other modifiers given (caps lock, the function
    /// flag and the numeric pad are not modifiers of a chord); nil for any other key.
    static func editCommand(key: String?, command: Bool, shift: Bool, option: Bool, control: Bool) -> EditCommand? {
        guard command, !option, !control, let key = key?.lowercased() else { return nil }
        switch (key, shift) {
        case ("v", false): return .paste
        case ("c", false): return .copy
        case ("x", false): return .cut
        case ("a", false): return .selectAll
        case ("z", false): return .undo
        case ("z", true): return .redo
        default: return nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let editor = currentEditor() as? NSTextView,            // only while this field is being edited (it is the first responder)
              let command = Self.editCommand(key: event.charactersIgnoringModifiers, command: flags.contains(.command), shift: flags.contains(.shift),
                                             option: flags.contains(.option), control: flags.contains(.control)) else {
            return super.performKeyEquivalent(with: event)
        }
        switch command {
        case .paste: editor.paste(nil)
        case .copy: editor.copy(nil)
        case .cut: editor.cut(nil)
        case .selectAll: editor.selectAll(nil)
        case .undo: editor.undoManager?.undo()
        case .redo: editor.undoManager?.redo()
        }
        return true
    }
}
