import AppKit

// =====================================================================================
// The Settings window (menu: "Settings…", Cmd-,): one window, five tabs (General, Claude, Transcription, Detection, Privacy). A THIN AppKit layer: what a
// value means, what is written, what is refused, what the Keychain and the pipeline are asked, and the privacy text are all in SettingsModel.swift /
// SettingsConfigWriter.swift / SettingsKeychain.swift / SettingsBackend.swift, where selftest-session checks them. This file builds controls from
// the catalog and hands their text to the coordinator. It could not be looked at in a real session while it was written (docs/SETTINGS.md).
//
//   - Controls are made from `SettingsCatalog`: a popup for a choice, a check box for a switch, a text field for the rest. Only the controls the person
//     TOUCHED are saved (the coordinator compares them with the file), so nothing else in config.env changes.
//   - API keys: secure fields that are never filled from the Keychain; the status line says only stored / not stored. Keys go through the coordinator to
//     the Keychain, never to config.env.
//   - Consent of a cloud engine: shown read-only; the button opens Terminal with the existing command. The consent file is never written here.
//   - After a save: "Saved. Restart the app to apply." and a [Restart now] button; while a recording runs, or while a relaunch would undo a pause or a hand-stopped
//     call (RestartPlan), the button only offers to restart after it (or is off, for a pause).
//   - The state of the meeting folder is asked after the typing paused and off the main thread (FolderStatusChecker).
//   - Check key (one real call to Anthropic) is off while the organisation policy keeps the Claude lane closed.
// =====================================================================================

/// What the Detection tab needs of the Call Apps store (the logic of the Call Apps submenu of the status menu is reused: `StatusMenuController.callAppRows`).
struct SettingsCallApps {
    var entries: () -> [CallAppEntry]
    var problem: () -> String?
    var settings: () -> CallDetectSettings
    var set: (_ id: String, _ decision: CallDecision) -> Void
    var reload: () -> Void
}

// MARK: - Text fields that answer the editing keys

/// The app is an accessory app without an Edit menu, so Cmd-V and friends reach no field by themselves (see EnrollmentCodeField): these fields answer them.
private func performEditKey(_ field: NSTextField, _ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard let editor = field.currentEditor() as? NSTextView,
          let command = EnrollmentCodeField.editCommand(key: event.charactersIgnoringModifiers, command: flags.contains(.command), shift: flags.contains(.shift),
                                                        option: flags.contains(.option), control: flags.contains(.control)) else { return false }
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

final class SettingsTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool { performEditKey(self, event) || super.performKeyEquivalent(with: event) }
}

final class SettingsSecureField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool { performEditKey(self, event) || super.performKeyEquivalent(with: event) }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - One API key row

/// A secure field with [Save key] [Check key] [Remove key] and a status line. Holds no key: the text goes to `save` and the field is emptied.
private final class KeyRow: NSObject {
    let slot: SecretSlot
    let field: SettingsSecureField
    let status: NSTextField
    let result: NSTextField
    let saveButton: NSButton, removeButton: NSButton
    let checkButton: NSButton?
    let view: NSStackView
    var onSave: ((SecretSlot, String, @escaping (String?) -> Void) -> Void)?
    var onRemove: ((SecretSlot, @escaping (String?) -> Void) -> Void)?
    var onCheck: ((@escaping (String) -> Void) -> Void)?
    /// Off while the address of the engine has unsaved edits (the Keychain item is bound to the SAVED address): the row says why.
    var enabled = true { didSet { updateEnabled(); showStandingNote() } }
    /// Check key is off (the reason, shown under the row) while the organisation policy keeps the Claude lane closed: it would be a real call to Anthropic.
    var checkBlocked: String? { didSet { if checkBlocked != oldValue { updateEnabled(); showStandingNote() } } }
    private var noteShown = false
    private var busy = false { didSet { updateEnabled() } }

    init(slot: SecretSlot, placeholder: String) {
        self.slot = slot
        let field = SettingsSecureField(frame: .zero)
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        let width = field.widthAnchor.constraint(equalToConstant: 260)
        width.priority = .defaultHigh
        width.isActive = true
        let status = NSTextField(wrappingLabelWithString: "")
        let result = NSTextField(wrappingLabelWithString: "")
        for label in [status, result] {
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 420
        }
        let save = NSButton(title: tr("Save key", ko: "키 저장"), target: nil, action: nil)
        let remove = NSButton(title: tr("Remove key", ko: "키 삭제"), target: nil, action: nil)
        let check: NSButton? = slot == .claude ? NSButton(title: tr("Check key", ko: "키 확인"), target: nil, action: nil) : nil
        let buttons = NSStackView(views: [field, save] + (check.map { [$0] } ?? []) + [remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [buttons, status, result])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        self.field = field
        self.status = status
        self.result = result
        self.saveButton = save
        self.removeButton = remove
        self.checkButton = check
        self.view = stack
        result.isHidden = true
        super.init()
        for b in [save, remove] + (check.map { [$0] } ?? []) { b.target = self }
        save.action = #selector(savePressed)
        remove.action = #selector(removePressed)
        check?.action = #selector(checkPressed)
    }

    private func setResult(_ text: String) {
        result.stringValue = text
        result.isHidden = text.isEmpty
    }

    private func showStandingNote() {
        let note: String? = !enabled ? tr("Save the address first: the key is stored for the saved address.", ko: "먼저 주소를 저장하세요: 키는 저장된 주소용으로 저장돼요.") : checkBlocked
        if let note = note { setResult(note); noteShown = true }
        else if noteShown { setResult(""); noteShown = false }
    }

    private func updateEnabled() {
        for b in [saveButton, removeButton] { b.isEnabled = enabled && !busy }
        checkButton?.isEnabled = enabled && !busy && checkBlocked == nil
        checkButton?.toolTip = checkBlocked
        field.isEnabled = enabled && !busy
    }

    @objc private func savePressed() {
        let secret = field.stringValue
        busy = true
        setResult("")
        onSave?(slot, secret) { [weak self] problem in
            guard let self = self else { return }
            self.busy = false
            if let problem = problem { self.setResult(problem) } else { self.field.stringValue = ""; self.setResult(tr("Key stored.", ko: "키를 저장했어요.")) }
        }
    }

    @objc private func removePressed() {
        let alert = NSAlert()
        alert.messageText = tr("Remove the key from the Keychain?", ko: "키체인에서 키를 삭제할까요?")
        alert.informativeText = tr("The key is deleted from your Keychain. You can store it again with Save key.", ko: "키체인에서 키가 삭제돼요. 키 저장으로 다시 저장할 수 있어요.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("Remove key", ko: "키 삭제"))
        alert.addButton(withTitle: tr("Cancel", ko: "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        setResult("")
        onRemove?(slot) { [weak self] problem in
            guard let self = self else { return }
            self.busy = false
            self.setResult(problem ?? tr("Key removed.", ko: "키를 삭제했어요."))
        }
    }

    @objc private func checkPressed() {
        busy = true
        setResult(tr("Checking (one tiny paid call)…", ko: "확인하는 중 (아주 작은 유료 호출 1회)…"))
        onCheck? { [weak self] text in
            self?.busy = false
            self?.setResult(text)
        }
    }
}

// MARK: - The window

final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let coordinator: SettingsCoordinator
    private let callApps: SettingsCallApps?
    private var window: NSWindow?
    private var snapshot: SettingsSnapshot?
    private var tracker = RestartTracker()
    private var restartPending = false                             // a save in this run of the app still waits for a restart

    private var controls: [String: NSControl] = [:]                 // catalog key -> popup / check box / text field
    private var platformBoxes: [String: NSButton] = [:]             // zoom / teams / meet
    private var errorLabels: [String: NSTextField] = [:]
    private var lockLabels: [String: NSTextField] = [:]
    private var touched = Set<String>()
    private var keyRows: [SecretSlot: KeyRow] = [:]
    private var folderStatus = NSTextField(wrappingLabelWithString: "")
    private let folderChecker = FolderStatusChecker()
    private let consentLabel = NSTextField(wrappingLabelWithString: "")
    private let consentButton = NSButton(title: tr("Open Terminal and grant consent", ko: "터미널을 열어 동의하기"), target: nil, action: nil)
    private let googleLabel = NSTextField(wrappingLabelWithString: "")
    private let googleButton = NSButton(title: tr("Open Terminal and sign in to Google", ko: "터미널을 열어 Google에 로그인"), target: nil, action: nil)
    private let privacyView = NSTextView.scrollableTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: tr("Save", ko: "저장"), target: nil, action: nil)
    private let revertButton = NSButton(title: tr("Revert", ko: "되돌리기"), target: nil, action: nil)
    private let restartButton = NSButton(title: tr("Restart now", ko: "지금 다시 시작"), target: nil, action: nil)
    private let callAppsStack = NSStackView()
    private let callAppsHeader = NSTextField(wrappingLabelWithString: "")
    private var engineStates: [String: AsrEngineState]?
    private var statusRefreshGeneration = 0

    init(coordinator: SettingsCoordinator, callApps: SettingsCallApps?) {
        self.coordinator = coordinator
        self.callApps = callApps
        super.init()
    }

    // MARK: Showing

    func show() {
        if window == nil { buildWindow() }
        reload(keepStatus: false)
        NSApp.activate(ignoringOtherApps: true)                   // a menu-bar app is not active: the window would open behind the others
        window?.makeKeyAndOrderFront(nil)
    }

    /// Builds the window and fills it from config.env WITHOUT showing it (a snapshot tool uses it to draw the tabs offscreen).
    func prepareWindow() -> NSWindow {
        if window == nil { buildWindow() }
        reload(keepStatus: false)
        return window!
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshStatuses() }       // the consent or the Google sign-in may have just been done in Terminal

    func windowWillClose(_ notification: Notification) {
        for row in keyRows.values { row.field.stringValue = "" }                  // a typed key does not stay in a hidden window
    }

    /// Called by the status menu on every controller state: the restart that was asked for "after the recording" happens now, unless a relaunch would still undo
    /// something (`hold`: a pause, a call the person stopped that is still running, a call about to be recorded).
    func recordingStateChanged(recording: Bool, hold: RestartHold?) {
        if tracker.stateChanged(recording: recording, hold: hold) { _ = coordinator.restartNow() }
        updateRestartButton()
    }

    private var savedMessage: String { tr("Saved. Restart the app to apply.", ko: "저장했어요. 적용하려면 앱을 다시 시작하세요.") }

    // MARK: Building

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = tr("\(AppInfo.displayName) Settings", ko: "\(AppInfo.displayName) 설정")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for tab in SettingsTab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = scrollable(grid: grid(for: tab))
            tabs.addTabViewItem(item)
        }

        statusLabel.maximumNumberOfLines = 4
        statusLabel.preferredMaxLayoutWidth = 470
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        saveButton.target = self; saveButton.action = #selector(savePressed); saveButton.keyEquivalent = "\r"
        revertButton.target = self; revertButton.action = #selector(revertPressed)
        restartButton.target = self; restartButton.action = #selector(restartPressed); restartButton.isHidden = true
        let buttons = NSStackView(views: [restartButton, revertButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabs)
        content.addSubview(statusLabel)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
        w.contentView = content
        window = w
    }

    private func scrollable(grid: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        scroll.documentView = doc
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
        ])
        return scroll
    }

    private func smallLabel(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = color
        l.preferredMaxLayoutWidth = 440
        return l
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.alignment = .right
        l.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        l.preferredMaxLayoutWidth = 200
        l.isSelectable = false
        return l
    }

    private func vstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    /// The right-hand cell of a field: its control, an error line (empty until needed), the hint, the reason it is locked.
    private func cell(for field: SettingsField, control: NSView) -> NSStackView {
        let error = smallLabel("", color: .systemRed)
        error.isHidden = true
        let lock = smallLabel("", color: .systemOrange)
        lock.isHidden = true
        errorLabels[field.key] = error
        lockLabels[field.key] = lock
        return vstack([control, error, smallLabel(field.hint), lock])
    }

    private func makeControl(for field: SettingsField) -> NSView {
        let id = NSUserInterfaceItemIdentifier(field.key)
        switch field.kind {
        case .choice(let words):
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: words)
            popup.identifier = id
            popup.target = self; popup.action = #selector(controlChanged(_:))
            controls[field.key] = popup
            return popup
        case .toggle:
            let box = NSButton(checkboxWithTitle: field.title, target: self, action: #selector(controlChanged(_:)))
            box.identifier = id
            controls[field.key] = box
            return box
        case .platforms:
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 14
            for (name, title) in [("zoom", "Zoom"), ("teams", "Microsoft Teams"), ("meet", "Google Meet")] {
                let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(platformChanged(_:)))
                box.identifier = NSUserInterfaceItemIdentifier(name)
                platformBoxes[name] = box
                row.addArrangedSubview(box)
            }
            return row
        case .folder:
            let text = SettingsTextField(frame: .zero)
            configureText(text, id: id, width: 320)
            let choose = NSButton(title: tr("Choose…", ko: "선택…"), target: self, action: #selector(chooseFolder))
            let row = NSStackView(views: [text, choose])
            row.orientation = .horizontal
            row.spacing = 8
            folderStatus.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            folderStatus.textColor = .secondaryLabelColor
            folderStatus.preferredMaxLayoutWidth = 440
            return vstack([row, folderStatus])
        default:
            let text = SettingsTextField(frame: .zero)
            configureText(text, id: id, width: field.kind == .money ? 100 : 400)
            return text
        }
    }

    private func configureText(_ text: SettingsTextField, id: NSUserInterfaceItemIdentifier, width: CGFloat) {
        text.identifier = id
        text.delegate = self
        text.translatesAutoresizingMaskIntoConstraints = false
        let fixed = text.widthAnchor.constraint(equalToConstant: width)
        fixed.priority = .defaultHigh                          // a narrow window compresses the field instead of growing the window
        fixed.isActive = true
        controls[id.rawValue] = text
    }

    private func row(_ field: SettingsField) -> [NSView] {
        let control = makeControl(for: field)
        let right = cell(for: field, control: control)
        if case .toggle = field.kind { return [NSView(), right] }               // the check box carries the title itself
        return [titleLabel(field.title), right]
    }

    private func finish(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 14
        g.columnSpacing = 12
        g.column(at: 0).xPlacement = .trailing
        g.column(at: 1).xPlacement = .leading
        for r in 0..<g.numberOfRows { g.row(at: r).yPlacement = .top }
        return g
    }

    private func keyRow(_ slot: SecretSlot, placeholder: String) -> KeyRow {
        let r = KeyRow(slot: slot, placeholder: placeholder)
        keyRows[slot] = r
        r.onSave = { [weak self] slot, secret, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = self?.coordinator.storeKey(slot, secret: secret) ?? .failed("")
                DispatchQueue.main.async { done(outcome.message); self?.refreshStatuses() }
            }
        }
        r.onRemove = { [weak self] slot, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = self?.coordinator.removeKey(slot) ?? .failed("")
                DispatchQueue.main.async { done(outcome.message); self?.refreshStatuses() }
            }
        }
        r.onCheck = { [weak self] done in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = self?.coordinator.checkKey() ?? KeyCheckOutcome(ok: false, text: "")
                DispatchQueue.main.async { done(outcome.text) }
            }
        }
        return r
    }

    private func grid(for tab: SettingsTab) -> NSView {
        switch tab {
        case .general:
            return finish(SettingsCatalog.fields(in: .general).map { row($0) })

        case .claude:
            var rows = SettingsCatalog.fields(in: .claude).map { row($0) }
            let key = keyRow(.claude, placeholder: "sk-ant-…")
            let note = smallLabel(tr("The key goes straight into your macOS Keychain, never into config.env, a log or a file. Only \"Stored in Keychain\" or \"Not stored\" is ever shown. Check key makes one tiny paid call (about a tenth of a cent) to prove it works.",
                                     ko: "키는 macOS 키체인에만 저장되고 config.env, 로그, 파일에는 남지 않아요. \"키체인에 저장됨\" 또는 \"저장 안 됨\"만 표시돼요. 키 확인은 작동 여부를 확인하려고 아주 작은 유료 호출을 1회(약 0.1센트) 해요."))
            rows.insert([titleLabel(tr("Anthropic API key", ko: "Anthropic API 키")), vstack([key.view, note])], at: 1)
            return finish(rows)

        case .transcription:
            var rows: [[NSView]] = []
            rows.append(row(SettingsCatalog.field("ASR_ENGINE")!))
            consentLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            consentLabel.preferredMaxLayoutWidth = 440
            consentButton.target = self; consentButton.action = #selector(consentPressed)
            let refresh = NSButton(title: tr("Refresh", ko: "새로고침"), target: self, action: #selector(refreshPressed))
            let consentRow = NSStackView(views: [consentButton, refresh])
            consentRow.orientation = .horizontal
            consentRow.spacing = 8
            rows.append([titleLabel(tr("Consent", ko: "동의")), vstack([consentLabel, consentRow,
                smallLabel(tr("The consent is recorded only by the command in Terminal (you type a sentence there). This window never writes it.", ko: "동의는 터미널의 명령으로만 기록돼요 (거기서 문장을 직접 입력해요). 이 창은 동의를 쓰지 않아요."))])])
            rows.append(row(SettingsCatalog.field("ASR_STRATEGY")!))
            rows.append(row(SettingsCatalog.field("ASR_CLOVA_INVOKE_URL")!))
            rows.append([titleLabel(tr("CLOVA API key", ko: "CLOVA API 키")), keyRow(.clova, placeholder: tr("API key", ko: "API 키")).view])
            rows.append(row(SettingsCatalog.field("ASR_OPENAI_COMPAT_URL")!))
            rows.append(row(SettingsCatalog.field("ASR_OPENAI_COMPAT_MODEL")!))
            rows.append([titleLabel(tr("OpenAI-compatible key (optional)", ko: "OpenAI 호환 키 (선택)")), keyRow(.openAICompat, placeholder: tr("API key (optional)", ko: "API 키 (선택)")).view])
            return finish(rows)

        case .detection:
            var rows: [[NSView]] = []
            for key in ["ENABLED_PLATFORMS", "CALL_DETECT", "CALL_BROWSER_URLS", "EXTRA_MEETING_APPS"] { rows.append(row(SettingsCatalog.field(key)!)) }
            callAppsStack.orientation = .vertical
            callAppsStack.alignment = .leading
            callAppsStack.spacing = 4
            callAppsHeader.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            callAppsHeader.textColor = .secondaryLabelColor
            callAppsHeader.preferredMaxLayoutWidth = 420
            let listScroll = NSScrollView()
            listScroll.hasVerticalScroller = true
            listScroll.borderType = .bezelBorder
            listScroll.translatesAutoresizingMaskIntoConstraints = false
            let listDoc = FlippedView()
            listDoc.translatesAutoresizingMaskIntoConstraints = false
            callAppsStack.translatesAutoresizingMaskIntoConstraints = false
            listDoc.addSubview(callAppsStack)
            listScroll.documentView = listDoc
            NSLayoutConstraint.activate([
                callAppsStack.topAnchor.constraint(equalTo: listDoc.topAnchor, constant: 6),
                callAppsStack.leadingAnchor.constraint(equalTo: listDoc.leadingAnchor, constant: 8),
                callAppsStack.bottomAnchor.constraint(equalTo: listDoc.bottomAnchor, constant: -6),
                callAppsStack.trailingAnchor.constraint(lessThanOrEqualTo: listDoc.trailingAnchor, constant: -8),
                listDoc.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor),
                listDoc.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor),
                listScroll.widthAnchor.constraint(equalToConstant: 400),
                listScroll.heightAnchor.constraint(equalToConstant: 150),
            ])
            rows.append([titleLabel(tr("Call apps", ko: "통화 앱")), vstack([callAppsHeader, listScroll,
                smallLabel(tr("A check mark = recorded when it looks like a call; no mark = never record. Changes here apply at once (call-apps.json), without Save.",
                              ko: "체크 = 통화처럼 보이면 녹음, 체크 해제 = 녹음 안 함. 여기서의 변경은 저장 없이 바로 적용돼요 (call-apps.json)."))])])
            rows.append(row(SettingsCatalog.field("OFFLINE_AUTOSTART")!))
            googleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            googleLabel.preferredMaxLayoutWidth = 440
            googleButton.target = self; googleButton.action = #selector(googlePressed)
            rows.append([titleLabel(tr("Google Calendar", ko: "Google 캘린더")), vstack([googleLabel, googleButton,
                smallLabel(tr("Sign-in is done by the command in Terminal; the token is stored in your Keychain by it. Read-only access.", ko: "로그인은 터미널의 명령으로 하고, 토큰은 그 명령이 키체인에 저장해요. 읽기 전용이에요."))])])
            return finish(rows)

        case .privacy:
            var rows = SettingsCatalog.fields(in: .privacy).map { row($0) }
            let text = privacyView.documentView as? NSTextView
            text?.isEditable = false
            text?.isSelectable = true
            text?.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            text?.textContainerInset = NSSize(width: 6, height: 6)
            privacyView.translatesAutoresizingMaskIntoConstraints = false
            privacyView.hasVerticalScroller = true
            privacyView.borderType = .bezelBorder
            let boxWidth = privacyView.widthAnchor.constraint(equalToConstant: 520)
            boxWidth.priority = .defaultHigh
            boxWidth.isActive = true
            privacyView.heightAnchor.constraint(equalToConstant: 330).isActive = true
            rows.append([titleLabel(tr("What leaves this Mac", ko: "이 Mac 밖으로 나가는 것")), vstack([smallLabel(tr("Under the SAVED settings (not the unsaved edits above):", ko: "저장된 설정 기준이에요 (위의 저장 전 변경은 반영되지 않아요):")), privacyView])])
            return finish(rows)
        }
    }

    // MARK: Loading the controls

    private func reload(keepStatus: Bool) {
        let loaded = coordinator.load()
        snapshot = loaded.snapshot
        touched.removeAll()
        for state in loaded.snapshot.states { apply(state, fileProblem: loaded.problem) }
        if let problem = loaded.problem { statusLabel.stringValue = problem }
        else if !keepStatus { statusLabel.stringValue = restartPending ? savedMessage : "" }
        restartButton.isHidden = !restartPending
        updateRestartButton()
        updateButtons()
        updateKeyRowAvailability()
        keyRows[.claude]?.checkBlocked = coordinator.checkKeyBlockedReason()
        updateFolderStatus()
        updateConsentLine()
        rebuildCallApps()
        refreshStatuses()
    }

    private func apply(_ state: SettingsFieldState, fileProblem: String?) {
        let key = state.field.key
        let editable = state.lock == nil && fileProblem == nil
        switch state.field.kind {
        case .choice:
            if let popup = controls[key] as? NSPopUpButton { popup.selectItem(withTitle: state.shown); popup.isEnabled = editable }
        case .toggle:
            if let box = controls[key] as? NSButton { box.state = state.shown == "1" ? .on : .off; box.isEnabled = editable }
        case .platforms:
            let chosen = Set(state.shown.split(separator: ",").map(String.init))
            for (name, box) in platformBoxes { box.state = chosen.contains(name) ? .on : .off; box.isEnabled = editable }
        default:
            if let text = controls[key] as? NSTextField {
                // empty = the default applies (the placeholder shows it); a stored text that is not understood is shown as written
                let usesDefault = state.lock == nil && state.problem == nil && !state.fromPolicyDefault && (state.fileValue ?? "").isEmpty
                if state.lock != nil { text.stringValue = state.shown }
                else if state.problem != nil { text.stringValue = state.fileValue ?? "" }
                else { text.stringValue = usesDefault ? "" : state.shown }
                text.placeholderString = state.field.defaultValue.isEmpty ? nil : state.field.defaultValue
                text.isEnabled = editable
            }
        }
        if let lock = lockLabels[key] {
            lock.stringValue = state.lock?.reason ?? ""
            lock.isHidden = state.lock == nil
        }
        if let error = errorLabels[key] {
            error.stringValue = state.problem ?? ""
            error.isHidden = state.problem == nil
        }
    }

    private func updateButtons() {
        saveButton.isEnabled = !touched.isEmpty
        revertButton.isEnabled = !touched.isEmpty
    }

    // MARK: Edits

    @objc private func controlChanged(_ sender: NSControl) {
        guard let key = sender.identifier?.rawValue else { return }
        touched.insert(key)
        validate(key)
        if key == "ASR_ENGINE" { updateConsentLine() }
        updateButtons()
    }

    @objc private func platformChanged(_ sender: NSButton) {
        touched.insert("ENABLED_PLATFORMS")
        validate("ENABLED_PLATFORMS")
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let key = field.identifier?.rawValue else { return }
        touched.insert(key)
        validate(key)
        if key == "ARCHIVE_DIR" { updateFolderStatus(delay: FolderStatusChecker.debounce) }
        updateKeyRowAvailability()
        updateButtons()
    }

    private func currentText(_ key: String) -> String? {
        guard let field = SettingsCatalog.field(key) else { return nil }
        if case .platforms = field.kind { return SettingsCatalog.platformWords.filter { platformBoxes[$0]?.state == .on }.joined(separator: ",") }
        switch controls[key] {
        case let popup as NSPopUpButton: return popup.titleOfSelectedItem ?? ""
        case let box as NSButton:
            if case .toggle(let on, let off, _) = field.kind { return box.state == .on ? on : off }
            return nil
        case let text as NSTextField: return text.stringValue
        default: return nil
        }
    }

    private func collectTouched() -> [String: String] {
        var out: [String: String] = [:]
        for key in touched { if let text = currentText(key) { out[key] = text } }
        return out
    }

    /// A refusal under the control as soon as it is typed (the same function that decides at Save).
    private func validate(_ key: String) {
        guard let field = SettingsCatalog.field(key), let text = currentText(key), let error = errorLabels[key] else { return }
        if case .failure(let e) = SettingsValue.canonical(text, for: field) {
            error.stringValue = e.message
            error.isHidden = false
        } else if snapshot?.state(key)?.problem == nil {
            error.stringValue = ""
            error.isHidden = true
        }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = tr("Choose", ko: "선택")
        if let current = (controls["ARCHIVE_DIR"] as? NSTextField)?.stringValue, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        }
        guard let window = window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self, let text = self.controls["ARCHIVE_DIR"] as? NSTextField else { return }
            text.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            self.touched.insert("ARCHIVE_DIR")
            self.validate("ARCHIVE_DIR")
            self.updateFolderStatus()
            self.updateButtons()
        }
    }

    /// `delay`: the typing pause to wait for before the file system is asked (0 for a window that was just opened or a folder that was just chosen).
    private func updateFolderStatus(delay: TimeInterval = 0) {
        let typed = (controls["ARCHIVE_DIR"] as? NSTextField)?.stringValue ?? ""
        folderStatus.stringValue = ""                                                         // the old answer is about another path
        folderChecker.request(typed: typed, defaultPath: SettingsCatalog.field("ARCHIVE_DIR")?.defaultValue ?? "~/Meetings", delay: delay) { [weak self] status in
            guard let self = self, let status = status else { return }
            self.folderStatus.stringValue = status.text
            self.folderStatus.textColor = status.ok ? .secondaryLabelColor : .systemOrange
        }
    }

    // MARK: Keys, consent, Google

    /// The key buttons of a cloud engine act on the SAVED address: while its field has unsaved edits they are off (the Keychain item is bound to the host).
    private func updateKeyRowAvailability() {
        for (slot, row) in keyRows {
            if let addressKey = slot.addressKey { row.enabled = !touched.contains(addressKey) } else { row.enabled = true }
        }
    }

    private func updateConsentLine() {
        let engine = (controls["ASR_ENGINE"] as? NSPopUpButton)?.titleOfSelectedItem ?? "whisper"
        let line = ConsentLine.make(engine: engine, states: engineStates)
        consentLabel.stringValue = line.text
        consentButton.isEnabled = line.canGrant
        consentButton.isHidden = !TerminalAction.consentEngines.contains(engine)
    }

    @objc private func refreshPressed() { refreshStatuses() }

    @objc private func consentPressed() {
        let engine = (controls["ASR_ENGINE"] as? NSPopUpButton)?.titleOfSelectedItem ?? ""
        if let problem = coordinator.openTerminal(.consent(engine: engine)) { statusLabel.stringValue = problem }
        else { statusLabel.stringValue = tr("Terminal is open: follow the steps there. When you are done, come back to this window.", ko: "터미널이 열렸어요: 거기 안내를 따르세요. 끝나면 이 창으로 돌아오세요.") }
    }

    @objc private func googlePressed() {
        if let problem = coordinator.openTerminal(.googleSignIn) { statusLabel.stringValue = problem }
        else { statusLabel.stringValue = tr("Terminal is open: sign in with your browser. When you are done, come back to this window.", ko: "터미널이 열렸어요: 브라우저로 로그인하세요. 끝나면 이 창으로 돌아오세요.") }
    }

    /// Everything that needs a process (Keychain tool, python) runs off the main thread; the answers are applied if no newer refresh started.
    private func refreshStatuses() {
        statusRefreshGeneration += 1
        let generation = statusRefreshGeneration
        googleLabel.stringValue = tr("Checking…", ko: "확인하는 중…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var keys: [SecretSlot: (KeyStatus, String?)] = [:]
            for slot in [SecretSlot.claude, .clova, .openAICompat] {
                if case .failure(let e) = self.coordinator.item(for: slot) { keys[slot] = (.unknown, e.message) } else { keys[slot] = (self.coordinator.keyStatus(slot), nil) }
            }
            let states = self.coordinator.engineStates()
            let google = self.coordinator.googleState()
            let lines = self.coordinator.privacyLines(states: states)
            let checkBlocked = self.coordinator.checkKeyBlockedReason()
            DispatchQueue.main.async {
                guard generation == self.statusRefreshGeneration else { return }
                self.keyRows[.claude]?.checkBlocked = checkBlocked
                for (slot, answer) in keys { self.keyRows[slot]?.status.stringValue = answer.1 ?? answer.0.text }
                self.engineStates = states
                self.updateConsentLine()
                self.googleLabel.stringValue = google.text
                (self.privacyView.documentView as? NSTextView)?.string = PrivacySummary.text(lines)
            }
        }
    }

    // MARK: Call apps (the logic of the status menu's Call Apps submenu)

    private func rebuildCallApps() {
        for view in callAppsStack.arrangedSubviews { callAppsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let apps = callApps else {
            callAppsHeader.stringValue = tr("Call apps are not available in this run.", ko: "이번 실행에서는 통화 앱 목록을 쓸 수 없어요.")
            return
        }
        apps.reload()
        let entries = StatusMenuController.callAppRows(entries: apps.entries(), settings: apps.settings())
        let problem = apps.problem()
        var header = StatusMenuController.callAppsMenuHeader(entries: entries, problem: problem)
        if apps.settings().mode == .off { header.append(tr("CALL_DETECT is off: these choices are kept but not used.", ko: "CALL_DETECT가 꺼져 있어요: 이 선택은 저장되지만 쓰이지 않아요.")) }
        callAppsHeader.stringValue = header.joined(separator: "\n")
        for entry in entries {
            let st = StatusMenuController.callAppItemState(entry)
            let box = NSButton(checkboxWithTitle: st.title, target: self, action: #selector(callAppToggled(_:)))
            box.state = st.checked ? .on : .off
            box.toolTip = st.tooltip
            box.identifier = NSUserInterfaceItemIdentifier(entry.id)
            box.isEnabled = problem == nil
            callAppsStack.addArrangedSubview(box)
        }
    }

    @objc private func callAppToggled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let apps = callApps else { return }
        apps.set(id, sender.state == .on ? .allowed : .denied)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.rebuildCallApps() }        // the controller saves on its own queue
    }

    // MARK: Save, revert, restart

    @objc private func savePressed() {
        let edits = collectTouched()
        saveButton.isEnabled = false
        statusLabel.stringValue = tr("Saving…", ko: "저장하는 중…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.coordinator.save(touched: edits)
            DispatchQueue.main.async { self.saved(result) }
        }
    }

    private func saved(_ result: SettingsSaveResult) {
        switch result {
        case .nothingToSave:
            statusLabel.stringValue = tr("Nothing to save: the file already says this.", ko: "저장할 것이 없어요: 파일에 이미 같은 값이 있어요.")
            reload(keepStatus: true)
        case .refused(let problems):
            statusLabel.stringValue = tr("Not saved: ", ko: "저장 안 됨: ") + problems.map { "\(SettingsCatalog.field($0.key)?.title ?? $0.key): \($0.message)" }.joined(separator: " · ")
            for p in problems { errorLabels[p.key]?.stringValue = p.message; errorLabels[p.key]?.isHidden = false }
            updateButtons()
        case .failed(let why):
            statusLabel.stringValue = tr("Not saved: ", ko: "저장 안 됨: ") + why
            updateButtons()
        case .saved(_, let restartNeeded, _):
            restartPending = true
            statusLabel.stringValue = savedMessage
                + (restartNeeded ? "" : tr(" (Only pipeline keys changed: they also apply from the next processing run.)", ko: " (파이프라인 키만 바뀌었어요: 다음 처리부터 다시 시작 없이도 적용돼요.)"))
            reload(keepStatus: true)
        }
    }

    @objc private func revertPressed() {
        reload(keepStatus: false)
    }

    @objc private func restartPressed() {
        let plan = coordinator.restartPlan()
        if tracker.armed {                                                    // an armed restart is always cancelled by the button, whatever the plan says now
            tracker.toggleArmed()
            statusLabel.stringValue = tr("The restart was cancelled.", ko: "다시 시작을 취소했어요.")
        } else {
            switch plan {
            case .now:
                if case .unavailable(let why) = coordinator.restartNow() { statusLabel.stringValue = why }
            case .afterRecording, .afterCall:
                tracker.toggleArmed()
                statusLabel.stringValue = plan.armedText
            case .unavailable(let why):
                statusLabel.stringValue = why
            }
        }
        updateRestartButton()
    }

    private func updateRestartButton() {
        let plan = coordinator.restartPlan()
        let button = plan.button(armed: tracker.armed)
        restartButton.title = button.title
        restartButton.isEnabled = button.enabled
        restartButton.toolTip = plan.explanation
    }
}
