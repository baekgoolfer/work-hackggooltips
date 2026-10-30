import Foundation

// =====================================================================================
// The model behind the Settings window (SettingsWindow.swift is a thin AppKit layer over it): pure functions over text and values, no window,
// no file, no process, no Keychain. selftest-session checks all of it (SettingsSelfTests.swift).
//
//   SettingsCatalog     the config.env keys the window edits (twenty), their tab, kind, default and who reads them
//   SettingsValue       what a typed text means for a key: the canonical form, or why it is refused (the rules of Config.swift /
//                       Policy.swift / CallApps.swift / pipeline config.py, reused where the code exists)
//   SettingsSnapshot    config.env text + the organisation policy -> what every control shows (for a stored text that is not understood: what the
//                       code really reads, which is not always the default), which keys the policy locks, and, for the keys the person touched, the
//                       exact list of changes to write (ConfigEnvEditor, SettingsConfigWriter.swift)
//   AsrDestination      host and port of a cloud engine's address, the way pipeline/mcap/asr_providers.py `split_base` reads them (the Keychain
//                       item of its API key is bound to them)
//   PrivacySummary      what leaves the Mac under the saved settings, in plain words (docs/PRIVACY_LANES.md, English and Korean); the decisions come from
//                       EffectiveLanes (Policy.swift), the same code that drives the menu, with the wording added here
//
// What is NOT here, by design: secrets (they go to the Keychain only: SettingsKeychain.swift), the consent of a cloud engine (written only by
// `python -m mcap asr-engines consent <engine>` in a Terminal: this window shows its state and opens that command, it never writes the file).
// =====================================================================================

// MARK: - Catalog

enum SettingsTab: String, CaseIterable {
    case general, claude, transcription, detection, privacy

    var title: String {
        switch self {
        case .general: return tr("General", ko: "일반")
        case .claude: return "Claude"
        case .transcription: return tr("Transcription", ko: "전사")
        case .detection: return tr("Detection", ko: "감지")
        case .privacy: return tr("Privacy", ko: "개인정보")
        }
    }
}

/// Who reads a key: the app (a change needs a restart), the Python pipeline (it reads config.env on every run), or both.
enum SettingsReader: Equatable { case app, pipeline, both }

struct SettingsField: Equatable {
    enum Kind: Equatable {
        case choice([String])                                  // one of these words (lower case)
        case toggle(on: String, off: String, switchWords: Bool) // the words written when nothing in the file says otherwise; switchWords: 1/0, true/false, yes/no, on/off all read the same
        case text(max: Int)                                    // one line of free text
        case word                                              // one word, no spaces: a Claude model alias
        case token(max: Int)                                   // one printable ASCII token of at most `max` characters (no blank): the model field of an OpenAI-style server
        case folder                                            // an absolute path (or ~/...)
        case url(engine: String)                               // the https address of a cloud engine (host rules of asr_providers.split_base)
        case money                                             // USD, a plain decimal number, 0 = off
        case platforms                                         // a subset of zoom,teams,meet; an empty one is allowed (auto-detection off)
        case appList                                           // EXTRA_MEETING_APPS: bundle ids, each optionally id=Name
    }

    let key: String
    let tab: SettingsTab
    let kind: Kind
    /// What the code assumes while the key is absent ("" = unset).
    let defaultValue: String
    let reader: SettingsReader
    let titleEN: String, titleKO: String
    let hintEN: String, hintKO: String

    var title: String { tr(titleEN, ko: titleKO) }
    var hint: String { tr(hintEN, ko: hintKO) }
    var needsRestart: Bool { reader != .pipeline }
    /// A cleared text field removes the key (the default applies again). ENABLED_PLATFORMS is the exception: an empty list is a value of its own.
    var removable: Bool { if case .platforms = kind { return false } else { return true } }
}

enum SettingsCatalog {
    /// Written out one by one, with the key as a literal, so that the parity tests (selftest-session, pipeline/tests/test_settings_parity.py,
    /// scripts/test_scripts.sh) can read this list from the source.
    static let fields: [SettingsField] = [
        // ---- General
        SettingsField(key: "UI_LANGUAGE", tab: .general, kind: .choice(["en", "ko"]), defaultValue: "en", reader: .app,
                      titleEN: "Language", titleKO: "언어",
                      hintEN: "Language of the app's own texts: notifications, menu hints and dialogs.", hintKO: "알림, 메뉴 안내, 대화상자 등 앱 자체 문구의 언어예요."),
        SettingsField(key: "ARCHIVE_DIR", tab: .general, kind: .folder, defaultValue: "~/Meetings", reader: .both,
                      titleEN: "Meeting folder", titleKO: "회의 보관 폴더",
                      hintEN: "Where finished meetings are filed. A synced folder (Google Drive) works too.", hintKO: "끝난 회의를 보관하는 폴더예요. Google Drive 같은 동기화 폴더도 쓸 수 있어요."),
        SettingsField(key: "SELF_NAME", tab: .general, kind: .text(max: 60), defaultValue: "Me", reader: .both,
                      titleEN: "Your name", titleKO: "내 이름",
                      hintEN: "Label of your microphone track in transcripts and notes.", hintKO: "전사본과 회의록에서 내 마이크 트랙에 붙는 이름이에요."),
        // ---- Claude
        SettingsField(key: "CLAUDE_AUTH", tab: .claude, kind: .choice(["api", "subscription"]), defaultValue: "api", reader: .pipeline,
                      titleEN: "Who pays for Claude", titleKO: "Claude 비용 지불 방식",
                      hintEN: "api = an Anthropic Console API key from the Keychain (billed per token). subscription = your own claude.ai login.",
                      hintKO: "api = 키체인의 Anthropic Console API 키(토큰당 과금). subscription = 내 claude.ai 로그인."),
        SettingsField(key: "NOTE_MODEL", tab: .claude, kind: .word, defaultValue: "opus", reader: .pipeline,
                      titleEN: "Note model", titleKO: "회의록 모델",
                      hintEN: "Model alias of the meeting note (opus, sonnet, ...).", hintKO: "회의록을 쓰는 모델 별칭이에요 (opus, sonnet 등)."),
        SettingsField(key: "CLAUDE_DAILY_BUDGET_USD", tab: .claude, kind: .money, defaultValue: "5", reader: .pipeline,
                      titleEN: "Daily budget (USD)", titleKO: "하루 예산 (USD)",
                      hintEN: "api mode: the later Claude stages of the day stop when today's cost reaches this. 0 = off.", hintKO: "api 방식: 오늘 비용이 이 값에 닿으면 그날의 남은 Claude 단계를 멈춰요. 0 = 끔."),
        SettingsField(key: "CLAUDE_MEETING_BUDGET_USD", tab: .claude, kind: .money, defaultValue: "2", reader: .pipeline,
                      titleEN: "Budget per meeting (USD)", titleKO: "회의당 예산 (USD)",
                      hintEN: "api mode: per processing run; the note itself is always kept. 0 = off.", hintKO: "api 방식: 처리 1회당 한도예요. 회의록 작성은 항상 확보돼요. 0 = 끔."),
        // ---- Transcription
        SettingsField(key: "ASR_ENGINE", tab: .transcription, kind: .choice(PrivacySettings.engineWords), defaultValue: "whisper", reader: .both,
                      titleEN: "Engine", titleKO: "엔진",
                      hintEN: "whisper = on this Mac. clova, openai-compat, azure, remote send speech to a server and need your consent (Terminal only).",
                      hintKO: "whisper = 이 Mac에서 처리. clova, openai-compat, azure, remote는 음성을 서버로 보내며 동의가 필요해요 (동의는 터미널에서만)."),
        SettingsField(key: "ASR_STRATEGY", tab: .transcription, kind: .choice(["dual", "single"]), defaultValue: "dual", reader: .pipeline,
                      titleEN: "Strategy", titleKO: "전사 방식",
                      hintEN: "dual = every chunk is decoded twice by the local model and merged (slower, more accurate). single = once.",
                      hintKO: "dual = 로컬 모델이 청크마다 두 번 해독해 합쳐요(느리지만 더 정확). single = 한 번."),
        SettingsField(key: "ASR_CLOVA_INVOKE_URL", tab: .transcription, kind: .url(engine: "clova"), defaultValue: "", reader: .pipeline,
                      titleEN: "CLOVA invoke URL", titleKO: "CLOVA 인보크 URL",
                      hintEN: "https address of your CLOVA Speech domain (a NAVER Cloud host). Its host and port bind your consent and the API key.",
                      hintKO: "내 CLOVA Speech 도메인의 https 주소예요 (NAVER Cloud 호스트). 호스트와 포트가 동의와 API 키에 묶여요."),
        SettingsField(key: "ASR_OPENAI_COMPAT_URL", tab: .transcription, kind: .url(engine: "openai-compat"), defaultValue: "", reader: .pipeline,
                      titleEN: "OpenAI-compatible URL", titleKO: "OpenAI 호환 서버 URL",
                      hintEN: "Base https address of a server with POST <base>/audio/transcriptions. You decide who runs it.",
                      hintKO: "POST <base>/audio/transcriptions를 제공하는 서버의 https 기본 주소예요. 누가 운영하는지는 직접 정해요."),
        SettingsField(key: "ASR_OPENAI_COMPAT_MODEL", tab: .transcription, kind: .token(max: 100), defaultValue: "whisper-1", reader: .pipeline,
                      titleEN: "OpenAI-compatible model", titleKO: "OpenAI 호환 모델",
                      hintEN: "The model field of that request: one token without blanks, up to 100 characters (Systran/faster-whisper-large-v3 is fine).",
                      hintKO: "그 요청의 model 값이에요: 공백 없는 한 덩어리, 100자 이하 (Systran/faster-whisper-large-v3 같은 값도 돼요)."),
        // ---- Detection
        SettingsField(key: "ENABLED_PLATFORMS", tab: .detection, kind: .platforms, defaultValue: "zoom,teams", reader: .app,
                      titleEN: "Detect automatically", titleKO: "자동 감지할 앱",
                      hintEN: "Zoom, Teams and Google Meet (Meet needs the Chrome Automation permission). None checked = no automatic detection.",
                      hintKO: "Zoom, Teams, Google Meet (Meet는 Chrome 자동화 권한이 필요해요). 모두 해제하면 자동 감지를 하지 않아요."),
        SettingsField(key: "CALL_DETECT", tab: .detection, kind: .choice(["known", "generic", "off"]), defaultValue: "known", reader: .app,
                      titleEN: "Calls of other apps", titleKO: "다른 앱의 통화",
                      hintEN: "known = a built-in table of call apps plus your list. generic = also GUESS any app that holds the microphone and plays sound. off = none.",
                      hintKO: "known = 내장 통화 앱 목록과 내 목록. generic = 마이크를 잡고 소리를 내는 다른 앱도 추측해서 녹음. off = 끔."),
        SettingsField(key: "CALL_BROWSER_URLS", tab: .detection, kind: .toggle(on: "on", off: "off", switchWords: true), defaultValue: "off", reader: .app,
                      titleEN: "Read Chrome tab addresses for meeting pages", titleKO: "Chrome 탭 주소로 회의 페이지 감지",
                      hintEN: "Whereby, Jitsi, Webex web, Teams web, Zoom web. Needs the Chrome Automation permission.", hintKO: "Whereby, Jitsi, Webex 웹, Teams 웹, Zoom 웹. Chrome 자동화 권한이 필요해요."),
        SettingsField(key: "EXTRA_MEETING_APPS", tab: .detection, kind: .appList, defaultValue: "", reader: .app,
                      titleEN: "More call apps", titleKO: "통화 앱 추가",
                      hintEN: "Bundle ids separated by commas, each id or id=Name (com.example.talk=Example Talk).", hintKO: "번들 ID를 쉼표로 구분해요. id 또는 id=이름 (com.example.talk=Example Talk)."),
        SettingsField(key: "OFFLINE_AUTOSTART", tab: .detection, kind: .toggle(on: "auto", off: "off", switchWords: false), defaultValue: "off", reader: .app,
                      titleEN: "Start recordings from my Google Calendar", titleKO: "Google 캘린더로 녹음 자동 시작",
                      hintEN: "Starts a recording for an in-person event of your calendar, with nobody pressing a button. Recording people without their consent can be illegal.",
                      hintKO: "버튼을 누르지 않아도 캘린더의 대면 일정에 맞춰 녹음을 시작해요. 동의 없이 사람을 녹음하는 것은 불법일 수 있어요."),
        // ---- Privacy
        SettingsField(key: "LOCAL_ONLY_DEFAULT", tab: .privacy, kind: .toggle(on: "1", off: "0", switchWords: true), defaultValue: "0", reader: .both,
                      titleEN: "Every new recording starts Local-Only", titleKO: "새 녹음은 항상 로컬 전용으로 시작",
                      hintEN: "Transcribed on this Mac only: no note (Claude), calendar lookup or archive upload. Each meeting can still be changed in the menu.",
                      hintKO: "이 Mac에서만 전사해요: 회의록(Claude), 캘린더 조회, 보관 폴더 업로드가 없어요. 회의마다 메뉴에서 바꿀 수 있어요."),
        SettingsField(key: "NOTIFY_RECORDING", tab: .privacy, kind: .toggle(on: "1", off: "0", switchWords: true), defaultValue: "1", reader: .app,
                      titleEN: "Notify when a recording starts and ends", titleKO: "녹음 시작과 종료를 알림으로 알려주기",
                      hintEN: "The menu-bar icon can be hidden by the notch. Warnings and results are always shown.", hintKO: "메뉴 막대 아이콘은 노치에 가려질 수 있어요. 경고와 결과 알림은 항상 보여요."),
        SettingsField(key: "LOG_CONTENT", tab: .privacy, kind: .toggle(on: "1", off: "0", switchWords: true), defaultValue: "1", reader: .both,
                      titleEN: "Logs may contain meeting titles and short transcript snippets", titleKO: "로그에 회의 제목과 전사 조각 남기기",
                      hintEN: "Off = only lengths and short hashes, and no titles in notifications and the app log.", hintKO: "끄면 길이와 짧은 해시만 남고, 알림과 앱 로그에 제목이 나오지 않아요."),
    ]

    static func field(_ key: String) -> SettingsField? { fields.first { $0.key == key } }
    static func fields(in tab: SettingsTab) -> [SettingsField] { fields.filter { $0.tab == tab } }
    static var keys: [String] { fields.map { $0.key } }

    /// Fixed order and spelling of ENABLED_PLATFORMS.
    static let platformWords = ["zoom", "teams", "meet"]
    static let switchFamilies: [(on: String, off: String)] = [("1", "0"), ("true", "false"), ("yes", "no"), ("on", "off")]
}

// MARK: - Problems, locks

struct SettingsProblem: Equatable {
    var key: String
    var message: String
}

struct SettingsError: Error, Equatable {
    var message: String
}

/// Why a control is disabled.
enum SettingsLock: Equatable {
    case policy                 // the organisation policy enforces a value for this key
    case localOnly              // the policy forces Local-Only (locked, or a policy that cannot be read)
    case localOnlyDefault       // the policy's own default is Local-Only: the start value is `policy default OR LOCAL_ONLY_DEFAULT`, so the file cannot turn it off

    var reason: String {
        switch self {
        case .policy: return tr("Fixed by organisation policy", ko: "조직 정책으로 고정")
        case .localOnly: return tr("Fixed by organisation policy: Local-Only is always on", ko: "조직 정책으로 고정: 로컬 전용이 항상 켜져 있어요")
        case .localOnlyDefault: return tr("Set by organisation policy: every new recording starts Local-Only (a single meeting can still be changed in the menu)",
                                          ko: "조직 정책으로 설정: 새 녹음은 항상 로컬 전용으로 시작해요 (회의마다 메뉴에서 바꿀 수는 있어요)")
        }
    }
}

// MARK: - What a typed text means

enum SettingsValue {
    private static let wordPattern = "^[A-Za-z0-9][A-Za-z0-9._:\\[\\]-]{0,63}$"
    private static let moneyPattern = "^[0-9]{1,6}(\\.[0-9]{1,4})?$"

    static func hasControlCharacter(_ text: String) -> Bool {
        return text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Whitespace followed by '#' ends a value in both parsers (an inline comment); a '#' at the start would be a comment character too.
    static func hasCommentTrigger(_ text: String) -> Bool {
        if text.hasPrefix("#") { return true }
        var previous: Character?
        for ch in text {
            if ch == "#", let p = previous, p.isWhitespace { return true }
            previous = ch
        }
        return false
    }

    static func hasQuoteAtEdge(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        return first == "\"" || first == "'" || last == "\"" || last == "'"
    }

    /// The canonical form of `raw` for `field`, or why it is refused. "" is canonical for "unset" (every kind but ENABLED_PLATFORMS, where it
    /// is the empty list). The same words as the parsers: a text the parser would reject, clamp or read as something else is refused here.
    static func canonical(_ raw: String, for field: SettingsField) -> Result<String, SettingsError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func fail(_ en: String, _ ko: String) -> Result<String, SettingsError> { .failure(SettingsError(message: tr(en, ko: ko))) }
        switch field.kind {
        case .choice(let words):
            let word = text.lowercased()
            return words.contains(word) ? .success(word) : fail("must be one of: \(words.joined(separator: ", "))", "다음 중 하나여야 해요: \(words.joined(separator: ", "))")

        case .toggle(_, _, let switchWords):
            let word = text.lowercased()
            if switchWords {
                if let on = AppConfig.parseSwitch(word) { return .success(on ? "1" : "0") }
                return fail("must be on or off (1/0, true/false, yes/no, on/off)", "켬 또는 끔이어야 해요 (1/0, true/false, yes/no, on/off)")
            }
            if let mode = OfflineAutostartSettings.Mode(rawValue: word) { return .success(mode == .auto ? "1" : "0") }
            return fail("must be auto or off", "auto 또는 off여야 해요")

        case .text(let max):
            if text.isEmpty { return .success("") }
            if text.count > max { return fail("is longer than \(max) characters", "\(max)자보다 길어요") }
            return plainLine(text)

        case .word:
            if text.isEmpty { return .success("") }
            if text.range(of: wordPattern, options: .regularExpression) == nil {
                return fail("must be one word of letters, digits and . _ : - [ ] (at most 64, not starting with a symbol)", "영문, 숫자, . _ : - [ ] 로 된 한 단어여야 해요 (64자 이하, 기호로 시작하면 안 돼요)")
            }
            return .success(text)

        case .token(let max):
            if text.isEmpty { return .success("") }
            // pipeline/mcap/asr_openai_compat.py `_MODEL`: [\x21-\x7e]{1,100}
            guard text.unicodeScalars.count <= max, text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
                return fail("must be one token of printable ASCII characters without blanks (at most \(max))", "공백 없이 출력 가능한 ASCII 문자로 된 한 덩어리여야 해요 (\(max)자 이하)")
            }
            return plainLine(text)

        case .folder:
            if text.isEmpty { return .success("") }
            if text.count > 1024 { return fail("is too long", "너무 길어요") }
            guard AppConfig.isAbsolutePathValue(text) else { return fail("must be an absolute path (or start with ~/)", "절대 경로여야 해요 (또는 ~/로 시작)") }
            return plainLine(text)

        case .url(let engine):
            if text.isEmpty { return .success("") }
            if text.count > 512 { return fail("is too long", "너무 길어요") }
            guard AsrDestination.parse(text, engine: engine) != nil else {
                return engine == "clova"
                    ? fail("must be an https address on a NAVER Cloud host (…ncloud.com), a DNS name, no user name, query or fragment", "NAVER Cloud 호스트(…ncloud.com)의 https 주소여야 해요 (DNS 이름, 사용자 정보, 쿼리, 프래그먼트 없이)")
                    : fail("must be an https address with a DNS name (never an IP address), no user name, query or fragment", "DNS 이름의 https 주소여야 해요 (IP 주소 불가, 사용자 정보, 쿼리, 프래그먼트 없이)")
            }
            return .success(text)

        case .money:
            if text.isEmpty { return .success("") }
            guard text.range(of: moneyPattern, options: .regularExpression) != nil, let d = Double(text), d.isFinite else {
                return fail("must be a plain number such as 5 or 2.5 (0 = off)", "5 또는 2.5 같은 숫자여야 해요 (0 = 끔)")
            }
            return .success(formatMoney(d))

        case .platforms:
            var chosen = Set<String>()
            for piece in text.split(separator: ",", omittingEmptySubsequences: true) {
                let name = piece.trimmingCharacters(in: .whitespaces).lowercased()
                if name.isEmpty { continue }
                guard SettingsCatalog.platformWords.contains(name) else {
                    return fail("'\(NotificationText.clip(name, 20))' is not zoom, teams or meet", "'\(NotificationText.clip(name, 20))'은(는) zoom, teams, meet이 아니에요")
                }
                chosen.insert(name)
            }
            return .success(SettingsCatalog.platformWords.filter { chosen.contains($0) }.joined(separator: ","))

        case .appList:
            if text.isEmpty { return .success("") }
            if text.count > 4000 { return fail("is too long", "너무 길어요") }
            if hasControlCharacter(text) || hasCommentTrigger(text) || hasQuoteAtEdge(text) { return plainLine(text) }
            let parsed = ExtraMeetingApps.parse(text)
            if let problem = parsed.problems.first {
                return fail("is not accepted: \(problem)", "받아들일 수 없어요: \(problem)")
            }
            return .success(text)
        }
    }

    /// A single line that both parsers read back unchanged: no control character, no ' #', no quote at either end, not a second assignment.
    private static func plainLine(_ text: String) -> Result<String, SettingsError> {
        if hasControlCharacter(text) { return .failure(SettingsError(message: tr("must be one line without control characters", ko: "제어 문자 없는 한 줄이어야 해요"))) }
        if hasCommentTrigger(text) { return .failure(SettingsError(message: tr("cannot contain ' #' or start with #: config.env would read the rest as a comment", ko: "' #'을 넣거나 #로 시작할 수 없어요: config.env가 뒤를 주석으로 읽어요"))) }
        if hasQuoteAtEdge(text) { return .failure(SettingsError(message: tr("cannot start or end with a quote character", ko: "따옴표로 시작하거나 끝날 수 없어요"))) }
        if text.range(of: "^[A-Z][A-Z0-9_]*=", options: .regularExpression) != nil {
            return .failure(SettingsError(message: tr("looks like another KEY=VALUE line", ko: "다른 KEY=VALUE 줄처럼 보여요")))
        }
        return .success(text)
    }

    static func formatMoney(_ d: Double) -> String {
        if d == d.rounded() { return String(Int(d)) }
        var s = String(format: "%.4f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The canonical form of what config.env holds (the file's text for the key), or nil when the parser would not read it as a value of this kind.
    static func canonicalFromFile(_ raw: String, for field: SettingsField) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        switch field.kind {
        case .choice(let words):
            let w = text.lowercased()
            return words.contains(w) ? w : nil
        case .toggle(_, _, let switchWords):
            if switchWords { return AppConfig.parseSwitch(text).map { $0 ? "1" : "0" } }
            return OfflineAutostartSettings.Mode(rawValue: text.lowercased()).map { $0 == .auto ? "1" : "0" }
        case .platforms:
            // exactly what Config.swift reads: unknown names and `call` are dropped
            let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            if names.isEmpty { return "" }
            let valid = SettingsCatalog.platformWords.filter { names.contains($0) }
            return valid.isEmpty ? nil : valid.joined(separator: ",")
        case .money:
            // What the pipeline reads: Python's float() (LayerValue follows its grammar, `1_000` and inf / nan included) or a refusal to run (nil here); a
            // limit that is not above zero is no limit (usage.py `_limit`: negative and NaN read as 0, and an infinite one is never reached).
            guard LayerValue.acceptable(key: field.key, text: text), let cleaned = LayerValue.withoutUnderscores(text), let d = Double(cleaned) else { return nil }
            return d.isFinite && d > 0 ? formatMoney(d) : "0"
        case .url, .folder, .text, .word, .token, .appList:
            if case .success(let v) = canonical(text, for: field) { return v }
            return nil
        }
    }

    /// What the code reads when the stored text is NOT understood, and what to tell the person. It is not always the default: a switch that fails closed reads
    /// as its restrictive value, a misspelt CLAUDE_AUTH stops every Claude call, a word list falls back to the harmless word, a budget that is no number stops
    /// the pipeline altogether. Each rule is the fallback of the real parser (PrivacySettings.build, AppConfig.build, CallDetectSettings.build, config.py);
    /// the self test checks every one of them against those parsers, not against literals.
    static func unreadable(_ raw: String, for field: SettingsField, canonicalDefault: String) -> (shown: String, message: String) {
        let stored = NotificationText.clip(raw, 40)
        switch field.key {
        case "LOCAL_ONLY_DEFAULT":
            return ("1", tr("The stored value '\(stored)' is not understood: it is read as 1 (every new recording starts Local-Only; an unclear switch fails closed).",
                            ko: "저장된 값 '\(stored)'을(를) 이해하지 못해서 1로 읽어요 (새 녹음은 모두 로컬 전용으로 시작해요: 불분명한 스위치는 안전한 쪽으로 읽어요)."))
        case "LOG_CONTENT":
            return ("0", tr("The stored value '\(stored)' is not understood: it is read as 0 (no meeting titles or transcript snippets in logs; an unclear switch fails closed).",
                            ko: "저장된 값 '\(stored)'을(를) 이해하지 못해서 0으로 읽어요 (로그에 회의 제목과 전사 조각을 남기지 않아요: 불분명한 스위치는 안전한 쪽으로 읽어요)."))
        case "CLAUDE_AUTH":
            return ("subscription", tr("The stored value '\(stored)' is not understood: the app reads subscription, and the pipeline makes no Claude call until it is fixed.",
                                       ko: "저장된 값 '\(stored)'을(를) 이해하지 못해요: 앱은 subscription으로 읽고, 고칠 때까지 파이프라인은 Claude를 부르지 않아요."))
        case "ASR_STRATEGY":
            return ("single", tr("The stored value '\(stored)' is not understood: it is read as single (every chunk is decoded once).",
                                 ko: "저장된 값 '\(stored)'을(를) 이해하지 못해서 single로 읽어요 (청크마다 한 번만 해독해요)."))
        case "CALL_DETECT":
            return ("known", tr("The stored value '\(stored)' is not understood: it is read as known (the built-in table of call apps plus your list, no guessing), on a managed Mac too.",
                                ko: "저장된 값 '\(stored)'을(를) 이해하지 못해서 known으로 읽어요 (내장 통화 앱 목록과 내 목록, 추측 없음). 조직이 관리하는 Mac에서도 마찬가지예요."))
        case "CLAUDE_DAILY_BUDGET_USD", "CLAUDE_MEETING_BUDGET_USD":
            return (canonicalDefault, tr("The stored value '\(stored)' is not a number: the pipeline stops with an error (bad value) and does not run until it is fixed.",
                                         ko: "저장된 값 '\(stored)'은(는) 숫자가 아니에요: 파이프라인이 오류(bad value)로 멈추고 고칠 때까지 실행되지 않아요."))
        default:
            return (canonicalDefault, tr("The stored value '\(stored)' is not understood; the app reads the default (\(canonicalDefault.isEmpty ? "empty" : canonicalDefault)).",
                                         ko: "저장된 값 '\(stored)'을(를) 이해하지 못해서 앱은 기본값(\(canonicalDefault.isEmpty ? "비어 있음" : canonicalDefault))으로 읽어요."))
        }
    }

    /// The words written for a toggle: the family the file already uses (true/false stays true/false), else the field's own words.
    static func toggleWords(on: Bool, field: SettingsField, existing: String?) -> String {
        guard case .toggle(let onWord, let offWord, let switchWords) = field.kind else { return on ? "1" : "0" }
        if switchWords, let e = existing?.trimmingCharacters(in: .whitespaces).lowercased(),
           let family = SettingsCatalog.switchFamilies.first(where: { $0.on == e || $0.off == e }) {
            return on ? family.on : family.off
        }
        return on ? onWord : offWord
    }
}

// MARK: - Snapshot

struct ConfigChange: Equatable {
    var key: String
    var value: String?            // nil = remove the key (the default applies again)
}

struct SettingsFieldState: Equatable {
    var field: SettingsField
    /// The text of the last active line of config.env for the key (nil = no such line).
    var fileValue: String?
    /// What the control starts with: the canonical effective value (file, else policy default, else the built-in default; the policy's enforced value when locked).
    var shown: String
    var lock: SettingsLock?
    /// Set when the stored text is not understood: the app reads something else than the person wrote.
    var problem: String?
    var fromPolicyDefault: Bool
}

struct SettingsSnapshot: Equatable {
    var states: [SettingsFieldState]
    /// A policy file (or its marker) exists on this Mac.
    var managed: Bool
    /// Every config.env value with the organisation policy's layers applied (PolicyLayers): the values the app and the pipeline really use.
    var effective: [String: String]
    /// The raw values of config.env alone.
    var file: [String: String]

    func state(_ key: String) -> SettingsFieldState? { states.first { $0.field.key == key } }

    static func load(text: String?, policy: OrgPolicy) -> SettingsSnapshot {
        let file = AppConfig.parseEnvText(text ?? "")
        var layered = file
        PolicyLayers.apply(&layered, policy: policy)
        var states: [SettingsFieldState] = []
        for field in SettingsCatalog.fields {
            var defaultValue = field.defaultValue
            if field.key == "CALL_DETECT", policy.isEnforced { defaultValue = "off" }       // an unset CALL_DETECT is off on a managed Mac
            let canonicalDefault = (try? SettingsValue.canonical(defaultValue, for: field).get()) ?? defaultValue
            let fileRaw = file[field.key]
            var state = SettingsFieldState(field: field, fileValue: fileRaw, shown: canonicalDefault, lock: nil, problem: nil, fromPolicyDefault: false)

            var lock: SettingsLock?
            if field.key == "LOCAL_ONLY_DEFAULT", policy.forcesLocalOnly { lock = .localOnly }
            else if field.key == "LOCAL_ONLY_DEFAULT", policy.isValid, policy.localOnlyDefault { lock = .localOnlyDefault }
            else if PolicyLayers.whitelist.contains(field.key), policy.isEnforced, policy.enforced[field.key] != nil { lock = .policy }
            state.lock = lock

            if lock == .localOnly || lock == .localOnlyDefault {
                state.shown = "1"
            } else if let raw = layered[field.key], (lock != nil || !raw.isEmpty || !field.removable) {
                if lock == nil, (fileRaw ?? "").isEmpty, field.removable { state.fromPolicyDefault = true }
                if let value = SettingsValue.canonicalFromFile(raw, for: field) {
                    state.shown = value
                } else {
                    let reading = SettingsValue.unreadable(raw, for: field, canonicalDefault: canonicalDefault)
                    state.shown = reading.shown
                    state.problem = reading.message
                }
            }
            states.append(state)
        }
        return SettingsSnapshot(states: states, managed: policy.isEnforced, effective: layered, file: file)
    }

    /// The list of changes for the controls the person touched (`touched`: key -> the text of the control now), or why a change is refused. A touched
    /// control that says what the file already says is no change; a locked key is refused. Nothing is written for an untouched key, so a typo or a
    /// comment elsewhere in the file stays as it is.
    func changes(touched: [String: String]) -> (changes: [ConfigChange], problems: [SettingsProblem]) {
        var out: [ConfigChange] = []
        var problems: [SettingsProblem] = []
        for key in touched.keys.sorted() where SettingsCatalog.field(key) == nil {            // never a key this window does not edit (a secret's name, a typo)
            problems.append(SettingsProblem(key: key, message: tr("is not a setting of this window", ko: "이 창에서 바꾸는 설정이 아니에요")))
        }
        for field in SettingsCatalog.fields {
            guard let edit = touched[field.key], let st = state(field.key) else { continue }
            func refuse(_ message: String) { problems.append(SettingsProblem(key: field.key, message: message)) }
            let verdict = SettingsValue.canonical(edit, for: field)
            if let lock = st.lock {                                  // a locked control cannot be changed: saying what it shows already is no change
                if case .success(let canon) = verdict, canon == st.shown { continue }
                refuse(lock.reason)
                continue
            }
            guard case .success(let canon) = verdict else {
                if case .failure(let e) = verdict { refuse(e.message) }
                continue
            }
            let present: Bool = field.removable ? !(st.fileValue ?? "").isEmpty : st.fileValue != nil
            let current = present ? SettingsValue.canonicalFromFile(st.fileValue ?? "", for: field) : nil
            if canon.isEmpty, field.removable {
                if present { out.append(ConfigChange(key: field.key, value: nil)) }
                continue
            }
            if present, let current = current, current == canon { continue }
            let builtIn = (try? SettingsValue.canonical(field.defaultValue, for: field).get()) ?? field.defaultValue
            if !present, st.problem == nil, !st.fromPolicyDefault, canon == builtIn { continue }
            switch field.kind {
            case .toggle:
                out.append(ConfigChange(key: field.key, value: SettingsValue.toggleWords(on: canon == "1", field: field, existing: st.fileValue)))
            case .choice, .platforms, .money:
                out.append(ConfigChange(key: field.key, value: canon))
            default:
                out.append(ConfigChange(key: field.key, value: edit.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return (out, problems)
    }
}

// MARK: - The address of a cloud engine

/// The destination of a cloud engine's https address, read exactly as pipeline/mcap/asr_providers.py `split_base` reads it: https, a plain lower-case
/// DNS name (never an IP address, user info, query, fragment), a port (443 when absent), a path of printable characters; CLOVA's host must end in a NAVER
/// Cloud suffix. The consent and the Keychain item of the API key are bound to host and port, so Swift and Python must agree on them: the shared corpus
/// pipeline/tests/fixtures/settings_parity.json is checked by both (pipeline/tests/test_settings_parity.py, selftest-session).
struct AsrDestination: Equatable {
    var host: String
    var port: Int
    var path: String

    static let clovaSuffixes = [".ncloud.com", ".fin-ncloud.com", ".gov-ncloud.com"]
    static let servicePrefix = "MeetingCapture ASR "
    static let maxPathChars = 200

    static func suffixes(for engine: String) -> [String] { engine == "clova" ? clovaSuffixes : [] }

    static func service(engine: String) -> String { servicePrefix + engine }

    /// `<user>@<host>:<port>` (asr_creds.account_name). `user` is the login name the pipeline child sees in USER (PipelineLauncher.sanitizedEnvironment).
    func keychainAccount(user: String) -> String { "\(user)@\(host):\(port)" }

    static func parse(_ raw: String, engine: String) -> AsrDestination? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for scalar in text.unicodeScalars where scalar.properties.isWhitespace || scalar.value < 32 { return nil }
        if text.contains("?") || text.contains("#") || text.contains("\\") { return nil }
        let schemeEnd = "https://"
        guard text.lowercased().hasPrefix(schemeEnd) else { return nil }
        let rest = String(text.dropFirst(schemeEnd.count))
        let slash = rest.firstIndex(of: "/")
        let authority = slash.map { String(rest[rest.startIndex..<$0]) } ?? rest
        let rawPath = slash.map { String(rest[$0...]) } ?? ""
        if authority.isEmpty || authority.contains("@") || authority.contains("[") || authority.contains("]") { return nil }

        var hostText = authority
        var port = 443
        if let colon = authority.lastIndex(of: ":") {
            hostText = String(authority[authority.startIndex..<colon])
            let portText = String(authority[authority.index(after: colon)...])
            if !portText.isEmpty {
                guard portText.count <= 5, portText.allSatisfy({ $0.isASCII && $0.isNumber }), let p = Int(portText) else { return nil }
                port = p
            }
        }
        guard (1...65535).contains(port) else { return nil }
        let host = hostText.lowercased()
        let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
        guard host.unicodeScalars.allSatisfy({ $0.isASCII }), host.range(of: "^\(label)(\\.\(label))+$", options: .regularExpression) != nil else { return nil }
        let labels = host.split(separator: ".")
        if labels.allSatisfy({ $0.allSatisfy { $0.isNumber } }) { return nil }          // an IP address (stricter than Python for odd numeric forms, never looser)
        let suffixes = Self.suffixes(for: engine)
        if !suffixes.isEmpty, !suffixes.contains(where: { host.hasSuffix($0) && host.count > $0.count }) { return nil }

        var path = rawPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.count > maxPathChars { return nil }
        if !path.isEmpty {
            if path.range(of: "^(/[A-Za-z0-9._~%+=@:,-]+)+$", options: .regularExpression) == nil { return nil }
            if path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) { return nil }
        }
        return AsrDestination(host: host, port: port, path: path)
    }
}

// MARK: - What leaves the Mac

/// The read-only box of the Privacy tab: what leaves this Mac under the SAVED settings, in plain words (the wording of docs/PRIVACY_LANES.md, English and
/// Korean). Pure: the consent states come from `python -m mcap asr-engines list --json` (nil = not known now), the rest from the layered config.env values
/// and the organisation policy.
enum PrivacySummary {
    struct Line: Equatable {
        enum Topic: String { case audio, transcript, calendar, archive, localOnly }
        var topic: Topic
        /// True when something of the meeting or the calendar goes to another party under these settings.
        var leaves: Bool
        var text: String
    }

    /// Engines whose audio goes to another party, with what this Mac may say about each.
    static func destinationLabel(_ engine: String) -> String {
        switch engine {
        case "clova": return tr("NAVER Cloud CLOVA Speech", ko: "NAVER Cloud CLOVA Speech")
        case "openai-compat": return tr("the server you named in ASR_OPENAI_COMPAT_URL (this Mac cannot tell who runs it)", ko: "ASR_OPENAI_COMPAT_URL에 적은 서버 (누가 운영하는지 이 Mac은 알 수 없어요)")
        case "azure": return tr("Azure Speech", ko: "Azure Speech")
        case "remote": return tr("your organisation's speech server", ko: "조직의 음성 인식 서버")
        default: return engine
        }
    }

    static func isExternal(_ engine: String) -> Bool { ["remote", "azure", "clova", "openai-compat"].contains(engine) }

    /// Path of a folder that a sync service watches (Google Drive for desktop, iCloud Drive, Dropbox, OneDrive).
    static func looksSynced(_ path: String) -> Bool {
        let p = path.lowercased()
        return ["/library/cloudstorage/", "google drive", "googledrive", "mobile documents", "icloud", "dropbox", "onedrive"].contains { p.contains($0) }
    }

    /// `values`: config.env with the policy's layers applied (SettingsSnapshot.effective). `consent`: engine -> a valid consent exists (nil = unknown).
    /// `credentialMissing`: engines whose API key `asr-engines list` says is not stored (nothing can be sent without it). `home`: for the archive roots of a policy.
    ///
    /// What is allowed is decided by `EffectiveLanes.compute` / `EffectiveLanes.destination` (Policy.swift), the code that drives the menu and the notifications:
    /// Local-Only, the lanes, the engines a policy lists, the archive roots. This function adds the consent, the stored key, the vocabulary switch and the words.
    static func lines(values: [String: String], policy: OrgPolicy, consent: [String: Bool?], credentialMissing: Set<String> = [],
                      home: String = NSHomeDirectory()) -> [Line] {
        let privacy = PrivacySettings.build(from: values, supportDir: AppConfig.defaultSupportDir, source: "settings")
        let offline = OfflineAutostartSettings.build(from: values, source: "settings")
        var lines: [Line] = []

        let archiveRaw = (values["ARCHIVE_DIR"] ?? "").isEmpty ? "~/Meetings" : values["ARCHIVE_DIR"] ?? "~/Meetings"
        let archive = (archiveRaw as NSString).expandingTildeInPath
        let startsLocalOnly = privacy.localOnlyDefault || policy.forcesLocalOnly || (policy.isValid && policy.localOnlyDefault)
        let effective = EffectiveLanes.compute(policy: policy, localOnly: startsLocalOnly, settings: privacy, archiveDir: URL(fileURLWithPath: archive, isDirectory: true), home: home)
        let localOnly = effective.asr == "local-only"

        if localOnly {
            lines.append(Line(topic: .localOnly, leaves: false, text: policy.forcesLocalOnly
                ? tr("Local-Only is fixed by organisation policy: speech, transcript text, calendar and the archive upload stay off for every meeting.",
                     ko: "로컬 전용이 조직 정책으로 고정돼 있어요: 모든 회의에서 음성, 전사 텍스트, 캘린더, 보관 폴더 업로드가 꺼져 있어요.")
                : tr("Every new recording starts Local-Only: speech, transcript text, calendar and the archive upload stay off for it. You can turn Local-Only off for a single meeting in the menu, before it is processed.",
                     ko: "새 녹음은 모두 로컬 전용으로 시작해요: 그 회의의 음성, 전사 텍스트, 캘린더, 보관 폴더 업로드가 꺼져 있어요. 처리되기 전이라면 메뉴에서 회의마다 끌 수 있어요.")))
        }

        // The vocabulary (vocabulary.txt) goes to a company server, Azure or CLOVA along with the speech, when ASR_SEND_VOCAB is on (the default; an unclear value
        // reads as off) AND the policy allows it for every kind of destination in use (pipeline/mcap/policy.py `AsrDecision.send_vocab`). openai-compat sends no terms.
        let vocabRaw = (values["ASR_SEND_VOCAB"] ?? "").trimmingCharacters(in: .whitespaces)
        let vocabOn = vocabRaw.isEmpty ? true : (AppConfig.parseSwitch(vocabRaw) ?? false)
        func canSend(_ engine: String) -> Bool {
            return isExternal(engine) && EffectiveLanes.destination(of: engine, policy: policy) != nil && (consent[engine] ?? nil) == true && !credentialMissing.contains(engine)
        }
        let inUse = [privacy.asrEngine, privacy.asrFallback].filter { canSend($0) }
        let vocabGoes = vocabOn && !inUse.isEmpty && inUse.allSatisfy { policy.sendVocabAllowed(engine: $0) }
        func sendsTerms(_ engine: String) -> Bool { return vocabGoes && ["clova", "azure", "remote"].contains(engine) }

        // Speech recognition. A cloud engine is used only when the policy lets that engine be used at all, a valid consent exists and its API key is stored; without
        // that the pipeline falls back to local Whisper (decision table A3, A6).
        func engineLines(_ engine: String, role: String) {
            let primary = role == "primary"
            guard isExternal(engine) else { return }
            let known = consent[engine] ?? nil
            if localOnly {
                return
            }
            if EffectiveLanes.destination(of: engine, policy: policy) == nil {
                lines.append(Line(topic: .audio, leaves: false, text: tr("Speech recognition: \(engine) is selected but the organisation policy keeps that lane closed or does not allow this engine, so nothing is sent.",
                                                                           ko: "음성 인식: \(engine)이(가) 선택돼 있지만 조직 정책이 그 경로를 막고 있거나 이 엔진을 허용하지 않아서 아무것도 보내지 않아요.")))
                return
            }
            switch known {
            case .some(true) where credentialMissing.contains(engine):
                lines.append(Line(topic: .audio, leaves: false, text: tr("Speech recognition: \(engine) is selected and a consent is recorded, but no API key is stored for it, so nothing can be sent yet; this Mac transcribes locally with Whisper instead.",
                                                                           ko: "음성 인식: \(engine)이(가) 선택돼 있고 동의도 기록돼 있지만 API 키가 저장돼 있지 않아서 아직 아무것도 보낼 수 없어요. 대신 이 Mac이 Whisper로 직접 전사해요.")))
            case .some(true):
                let terms = sendsTerms(engine)
                lines.append(Line(topic: .audio, leaves: true, text: primary
                    ? tr("Speech recognition: the speech parts of the meeting (echo removed; never the title, attendees, session id or file name)\(terms ? " and the terms of your vocabulary list (vocabulary.txt)" : "") are sent to \(destinationLabel(engine)), because a consent for it is recorded. Local-Only meetings never send it.",
                         ko: "음성 인식: 에코를 제거한 발화 구간(제목, 참석자, 세션 ID, 파일명은 보내지 않아요)\(terms ? "과 용어집(vocabulary.txt)의 용어를" : "을") \(destinationLabel(engine))(으)로 보내요. 동의가 기록돼 있기 때문이에요. 로컬 전용 회의는 보내지 않아요.")
                    : tr("Fallback engine (ASR_FALLBACK, set in config.env): when the main engine fails, a chunk of speech\(terms ? " and the terms of your vocabulary list (vocabulary.txt)" : "") goes to \(destinationLabel(engine)) because a consent for it is recorded.",
                         ko: "대체 엔진 (ASR_FALLBACK, config.env에서 설정): 주 엔진이 실패하면 \(destinationLabel(engine))(으)로 음성 조각\(terms ? "과 용어집(vocabulary.txt)의 용어를" : "을") 보내요. 동의가 기록돼 있기 때문이에요.")))
            case .some(false):
                lines.append(Line(topic: .audio, leaves: false, text: tr("Speech recognition: \(engine) is selected but no valid consent is recorded, so nothing is sent; this Mac transcribes locally with Whisper instead. A consent is given in Terminal only.",
                                                                           ko: "음성 인식: \(engine)이(가) 선택돼 있지만 유효한 동의가 없어서 아무것도 보내지 않고, 이 Mac이 Whisper로 직접 전사해요. 동의는 터미널에서만 할 수 있어요.")))
            case .none:
                lines.append(Line(topic: .audio, leaves: false, text: tr("Speech recognition: \(engine) is selected. Speech goes there only if a valid consent exists; its state could not be read just now.",
                                                                           ko: "음성 인식: \(engine)이(가) 선택돼 있어요. 유효한 동의가 있을 때만 음성이 그곳으로 가요. 지금은 동의 상태를 읽지 못했어요.")))
            }
        }
        if !localOnly {
            if privacy.asrEngine == "auto" {
                if EffectiveLanes.destination(of: "auto", policy: policy) == nil {
                    lines.append(Line(topic: .audio, leaves: false, text: tr("Speech recognition: ASR_ENGINE=auto uses local Whisper; the organisation policy keeps the company-server lane closed or does not allow it, so nothing is sent.",
                                                                               ko: "음성 인식: ASR_ENGINE=auto는 로컬 Whisper를 써요. 조직 정책이 회사 서버 경로를 막고 있거나 허용하지 않아서 아무것도 보내지 않아요.")))
                } else {
                    let terms = vocabOn && policy.sendVocabServer
                    lines.append(Line(topic: .audio, leaves: false, text: tr("Speech recognition: ASR_ENGINE=auto uses local Whisper when this Mac can run it, and your organisation's speech server (consent needed\(terms ? "; the terms of your vocabulary list go along" : "")) only when it cannot.",
                                                                               ko: "음성 인식: ASR_ENGINE=auto는 이 Mac이 돌릴 수 있으면 로컬 Whisper를 쓰고, 못 돌릴 때만 조직의 음성 인식 서버(동의 필요\(terms ? ", 용어집의 용어도 함께 가요" : ""))를 써요.")))
                }
            } else if isExternal(privacy.asrEngine) {
                engineLines(privacy.asrEngine, role: "primary")
            } else {
                lines.append(Line(topic: .audio, leaves: false, text: tr("Speech recognition: runs on this Mac with local Whisper; no speech is sent to a speech service.",
                                                                           ko: "음성 인식: 이 Mac에서 로컬 Whisper로 처리해요. 음성을 음성 인식 서비스로 보내지 않아요.")))
            }
            if isExternal(privacy.asrFallback) { engineLines(privacy.asrFallback, role: "fallback") }
        }

        // Transcript text to Claude (the llm lane).
        if !localOnly {
            let auth = (values["CLAUDE_AUTH"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let mode = auth.isEmpty ? "api" : auth
            if !effective.note {
                lines.append(Line(topic: .transcript, leaves: false, text: tr("Transcript text: stays on this Mac, because the organisation policy keeps the Claude lane closed.",
                                                                                ko: "전사 텍스트: 조직 정책이 Claude 경로를 막고 있어서 이 Mac 안에만 있어요.")))
            } else if mode != "api" && mode != "subscription" {
                lines.append(Line(topic: .transcript, leaves: false, text: tr("Transcript text: CLAUDE_AUTH is neither api nor subscription, so no Claude call is made and the text stays on this Mac until it is fixed.",
                                                                                ko: "전사 텍스트: CLAUDE_AUTH가 api도 subscription도 아니라서 고칠 때까지 Claude를 부르지 않고 이 Mac 안에만 있어요.")))
            } else {
                let billing = mode == "api" ? tr("with your API key", ko: "내 API 키로") : tr("with your claude.ai login", ko: "내 claude.ai 로그인으로")
                lines.append(Line(topic: .transcript, leaves: true, text: tr(
                    "Transcript text: sent to Claude (Anthropic) through your own claude tool \(billing) to clean the transcript, write the note and check it: transcript segments, vocabulary, title hints and calendar attendee names. Local-Only meetings send nothing.",
                    ko: "전사 텍스트: 내 claude 도구를 통해 \(billing) Claude(Anthropic)로 보내요. 전사 정리, 회의록 작성, 검증에 쓰이고 전사 세그먼트, 용어집, 제목 힌트, 캘린더 참석자 이름이 포함돼요. 로컬 전용 회의는 아무것도 보내지 않아요.")))
            }
        }

        // Calendar: Google (auto-start) and the claude.ai connector (lookup of the title).
        if offline.isOn {
            if localOnly {
                lines.append(Line(topic: .calendar, leaves: false, text: tr("Calendar: auto-start is on, but Local-Only closes it: no Google Calendar access.",
                                                                              ko: "캘린더: 자동 시작이 켜져 있지만 로컬 전용이 막아서 Google 캘린더에 접근하지 않아요.")))
            } else if policy.laneDenialReason("calendar") != nil {
                lines.append(Line(topic: .calendar, leaves: false, text: tr("Calendar: auto-start is on, but the organisation policy keeps the calendar lane closed: no Google Calendar access.",
                                                                              ko: "캘린더: 자동 시작이 켜져 있지만 조직 정책이 캘린더 경로를 막고 있어서 Google 캘린더에 접근하지 않아요.")))
            } else {
                lines.append(Line(topic: .calendar, leaves: true, text: tr(
                    "Calendar: auto-start is on, so the app reads your primary Google Calendar (read-only: titles, times, locations, attendee counts, meeting links) directly from Google. Nothing from it goes anywhere else and the app never writes to your calendar.",
                    ko: "캘린더: 자동 시작이 켜져 있어서 앱이 본인 기본 Google 캘린더(읽기 전용: 제목, 시간, 장소, 참석자 수, 화상회의 링크)를 Google에서 직접 읽어요. 그 내용은 다른 곳으로 가지 않고, 앱이 캘린더에 쓰지도 않아요.")))
            }
        } else {
            lines.append(Line(topic: .calendar, leaves: false, text: tr("Calendar: auto-start is off, so there is no Google Calendar access.", ko: "캘린더: 자동 시작이 꺼져 있어서 Google 캘린더에 접근하지 않아요.")))
        }
        if effective.calendar && effective.note {
            lines.append(Line(topic: .calendar, leaves: true, text: tr(
                "Calendar lookup (CALENDAR_LOOKUP): a time window around the start of a recording is sent to Claude's calendar connector (your claude.ai login) to find the title and attendees. Set CALENDAR_LOOKUP=0 in config.env to stop it.",
                ko: "캘린더 조회 (CALENDAR_LOOKUP): 녹음 시작 전후의 시간대를 Claude의 캘린더 커넥터(내 claude.ai 로그인)로 보내 제목과 참석자를 찾아요. 끄려면 config.env에 CALENDAR_LOOKUP=0을 적어요.")))
        }

        // The archive: the meeting folder (audio .m4a files, transcript, note) is moved to ARCHIVE_DIR when the policy opens that upload for the folder.
        if !localOnly {
            if effective.archive == "org-folder" {
                let synced = looksSynced(archive)
                lines.append(Line(topic: .archive, leaves: synced, text: synced
                    ? tr("Archive: each finished meeting folder (audio .m4a files, transcript, note) is moved to \(archiveRaw). That folder looks synced (for example Google Drive for desktop), so the sync service gets a copy of the audio too.",
                         ko: "보관 폴더: 끝난 회의 폴더(오디오 .m4a, 전사본, 회의록)를 \(archiveRaw)(으)로 옮겨요. 이 폴더는 동기화되는 것으로 보여서(예: Google Drive for desktop) 동기화 서비스가 오디오 사본도 받아요.")
                    : tr("Archive: each finished meeting folder (audio .m4a files, transcript, note) is moved to \(archiveRaw). Nothing leaves the Mac unless something syncs that folder.",
                         ko: "보관 폴더: 끝난 회의 폴더(오디오 .m4a, 전사본, 회의록)를 \(archiveRaw)(으)로 옮겨요. 그 폴더를 동기화하는 것이 없다면 Mac 밖으로 나가지 않아요.")))
            } else {
                lines.append(Line(topic: .archive, leaves: false, text: tr(
                    "Archive: the organisation policy does not open the archive upload for this folder (the lane is closed, no ARCHIVE_DIR of your own is set, or the folder is outside the allowed team folders), so finished meetings stay on this Mac.",
                    ko: "보관 폴더: 조직 정책이 이 폴더로의 보관 업로드를 열어 두지 않았어요 (경로가 막혀 있거나, 직접 정한 ARCHIVE_DIR이 없거나, 허용된 팀 폴더 밖이에요). 그래서 끝난 회의는 이 Mac에 남아요.")))
            }
        }
        return lines
    }

    static func text(_ lines: [Line]) -> String {
        return lines.map { "\u{2022} \($0.text)" }.joined(separator: "\n\n")
    }
}
