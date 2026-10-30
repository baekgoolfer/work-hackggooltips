import Foundation
import Darwin
import CryptoKit

// =====================================================================================
// Organisation policy, per-meeting local-only flag, privacy settings and the helpers the shell needs around them
// (SPEC 18). Types.swift is NOT changed: everything here is new.
//
//   OrgPolicy            policy.json reader: strict closed schema, fail closed, injectable file info (no root needed in tests).
//                        Same verdicts as pipeline/mcap/policy.py for every case of config/policy-fixtures (`selftest-policy`).
//   PolicyLayers         the policy's `defaults` / `enforced` layers around config.env (AppConfig.load applies them).
//   PrivacySettings      the new config.env keys the app itself acts on, each parsed to the RESTRICTIVE value of that key.
//   ArchiveRootMatcher   realpath + NFC + casefold, component-wise, only `*` is a wildcard (same algorithm as Python).
//   EffectiveLanes       what is TRUE for the next meeting (no 'audio never leaves this Mac': Drive archives the m4a).
//   PipelineContract / RuntimeTrust   what the launcher checks before it starts python (the launcher itself is W6a).
//   LocalOnlyResolver / SessionJSONPatch / SessionPrivateLog   the per-meeting flag: start value, toggle, atomic patch, history.
//   PolicyStatus         `<short name> policy-status [--json] [--console-user]`: content-free state for MDM and support.
//
// Nothing in this file opens a socket, starts `claude` or reads the Keychain. The only process it may start is
// `python -m mcap --version` (PipelineVersionProbe, only when the caller asks for the pipeline version).
// =====================================================================================

// MARK: - Strict JSON (policy.json)

/// A small strict JSON reader. Foundation's JSONSerialization keeps the LAST of two equal keys, reads `1.0` and `1` and `true` through
/// one NSNumber bridge and cannot tell a duplicate key from a typo: all of that would make the Swift verdict differ from Python's, so the
/// policy is read by this parser instead. Differences from the Python reader are only in the CLOSED direction (nesting deeper than
/// `maxDepth`, a lone UTF-16 surrogate, an integer outside Int64 where a number range matters).
enum PolicyJSON {
    typealias Member = (key: String, value: Value)

    indirect enum Value {
        case null
        case bool(Bool)
        case int(Int)
        case bigInt(negative: Bool)         // an integer literal outside Int64: only its sign matters to the policy rules
        case double(Double)                 // a literal with '.', 'e' or 'E' (always finite: NaN / Infinity / 1e999 never get here)
        case string(String)
        case array([Value])
        case object([Member])               // members in document order; duplicates are rejected when the object closes
    }

    /// `code` is a reason code of the shared corpus: bad-json or duplicate-key.
    struct Failure: Error {
        let code: String
        let detail: String
    }

    static let maxDepth = 128

    static func parse(_ text: String) throws -> Value {
        var reader = Reader(bytes: Array(text.utf8))
        reader.skipSpace()
        let value = try reader.value(depth: 0)
        reader.skipSpace()
        guard reader.index == reader.bytes.count else { throw reader.fail("data after the value") }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        func fail(_ detail: String) -> Failure { Failure(code: "bad-json", detail: detail) }

        mutating func skipSpace() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
        }

        private func isDigit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 }

        mutating func value(depth: Int) throws -> Value {
            guard depth <= PolicyJSON.maxDepth else { throw fail("nesting too deep") }
            guard index < bytes.count else { throw fail("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), 0x30...0x39: return try number()
            default: throw fail("unexpected character")      // includes NaN and Infinity: a lock in both parsers
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else { throw fail("bad literal") }
            index += w.count
        }

        mutating func number() throws -> Value {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw fail("bad number") }
            if bytes[index] == 0x30 {
                index += 1
            } else if bytes[index] >= 0x31 && bytes[index] <= 0x39 {
                while isDigit(index) { index += 1 }
            } else {
                throw fail("bad number")
            }
            var isFloat = false
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard isDigit(index) else { throw fail("bad number") }
                while isDigit(index) { index += 1 }
                isFloat = true
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard isDigit(index) else { throw fail("bad number") }
                while isDigit(index) { index += 1 }
                isFloat = true
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if isFloat {
                guard let d = Double(text), d.isFinite else { throw fail("number is not finite") }
                return .double(d)
            }
            if let n = Int(text) { return .int(n) }
            return .bigInt(negative: text.hasPrefix("-"))
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail("bad \\u escape") }
            var code: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[index]
                let digit: UInt32
                switch c {
                case 0x30...0x39: digit = UInt32(c - 0x30)
                case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
                default: throw fail("bad \\u escape")
                }
                code = code * 16 + digit
                index += 1
            }
            return code
        }

        mutating func string() throws -> String {
            index += 1                                                          // the opening quote
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw fail("unterminated string") }
                let c = bytes[index]
                if c == UInt8(ascii: "\"") { index += 1; break }
                if c < 0x20 { throw fail("control character in a string") }
                if c != UInt8(ascii: "\\") { out.append(c); index += 1; continue }
                index += 1
                guard index < bytes.count else { throw fail("unterminated string") }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if code >= 0xD800 && code <= 0xDBFF {                       // a high surrogate needs its low half right behind it
                        guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw fail("lone surrogate")
                        }
                        index += 2
                        let low = try hex4()
                        guard low >= 0xDC00 && low <= 0xDFFF else { throw fail("lone surrogate") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if code >= 0xDC00 && code <= 0xDFFF {
                        throw fail("lone surrogate")
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw fail("bad \\u escape") }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func array(depth: Int) throws -> Value {
            index += 1
            var items: [Value] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                items.append(try value(depth: depth + 1))
                skipSpace()
                guard index < bytes.count else { throw fail("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; break }
                throw fail("expected , or ]")
            }
            return .array(items)
        }

        mutating func object(depth: Int) throws -> Value {
            index += 1
            var members: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let key = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected :") }
                index += 1
                skipSpace()
                members.append((key: key, value: try value(depth: depth + 1)))
                skipSpace()
                guard index < bytes.count else { throw fail("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; break }
                throw fail("expected , or }")
            }
            // Duplicates are judged when the object is complete, like Python's object_pairs_hook (a syntax error further on wins).
            var seen = Set<[UInt32]>()
            for member in members {
                if !seen.insert(member.key.unicodeScalars.map { $0.value }).inserted {
                    throw Failure(code: "duplicate-key", detail: String(member.key.prefix(30)))
                }
            }
            return .object(members)
        }
    }
}

// MARK: - OrgPolicy

/// The organisation policy as this app reads it. `state` is absent (no policy.json and no policy.required: the
/// personal install), valid, or invalid (locked: every external lane closed, the per-meeting flag forced on, recording still allowed).
/// `lanes` are EFFECTIVE verdicts (approvals and the signature pin already applied), `laneReasons` the policy-level reason of each deny.
/// A nil `archiveAllowedRoots` / `allowedEngines` / `allowedHosts` means "no restriction"; an empty list means "nothing allowed".
struct OrgPolicy: Equatable {
    enum State: Equatable { case absent, valid, invalid(String) }       // absent = no policy.json and no policy.required

    var state: State
    var profile: String                                 // company | personal | none (absent) | unknown (locked and unreadable)
    var revision: Int?
    var sha256Prefix: String?                           // first 8 hex characters of the SHA-256 of the file
    var localOnlyDefault: Bool
    var localOnlyLocked: Bool
    var recordingEnabled: Bool
    var lanes: [String: String]
    var supportContact: String?
    var minPipelineVersion: String?
    var archiveAllowedRoots: [String]?
    var localRoots: [String]
    var runtimeRoot: String?
    var defaults: [String: String]
    var enforced: [String: String]
    // Additive (SPEC 18 lists the fields above): everything the shared corpus checks and the next packages need.
    var laneReasons: [String: String] = [:]
    var allowedEngines: [String]? = nil
    var allowedHosts: [String]? = nil
    var orgConsentHosts: [String] = []                  // hosts of the policy's org consents (a menu item for the company server needs one)
    var claudeBinPinned: Bool = false
    /// `asr.send_vocab.server` / `.cloud`: may the terms of vocabulary.txt go to a company server / to a cloud engine (pipeline/mcap/policy.py `send_vocab`;
    /// a company policy's cloud default is false, a locked policy closes both, no policy opens both).
    var sendVocabServer: Bool = true
    var sendVocabCloud: Bool = true

    /// What lstat says about one path. Injectable, so a test needs neither root nor a real policy folder.
    struct FileInfo: Equatable {
        var isRegular: Bool
        var isSymlink: Bool
        var uid: UInt32
        var mode: UInt16                                // permission bits
        var size: Int
        /// Informational (set by `statFile`): the parent directory is root-owned and not group/other writable. The verdict of
        /// `load` asks about EVERY ancestor directory through its own `fileInfo` call, so this field is not used for it.
        var parentOK: Bool = true
        /// lstat failed for a reason other than "not there" (permissions): unknown is the closed reading.
        var statError: Bool = false
    }

    static let systemPath = URL(fileURLWithPath: "/Library/Application Support/MeetingCapture/policy.json")
    static let requiredMarker = URL(fileURLWithPath: "/Library/Application Support/MeetingCapture/policy.required")
    static let maxBytes = 256 * 1024
    static let lanesInOrder = ["asr_remote", "asr_cloud", "llm", "calendar", "drive"]
    static let approvalLanes = ["llm", "asr_cloud", "calendar", "drive"]     // asr_remote has no approval reference
    /// Applied to a company policy and kept by a locked one (a damaged file must not make the privacy settings looser).
    static let companyBaselineEnforced = ["LOG_CONTENT": "0", "ASR_ALLOW_DOWNLOAD": "0", "MIC_MUTE_GATE": "on", "NOTIFY_RECORDING": "1"]
    static let childEnvNames: Set<String> = ["DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
    /// Test hooks (environment variables) a policy-managed Mac ignores (Python: config.TEST_HOOK_ENV).
    static let testHookNames = ["MCAP_CONFIG", "MCAP_LOG_DIR", "MCAP_SILERO_MODEL", "MCAP_SECURITY_BIN", "MCAP_POLICY_PATH"]
    /// config.env keys a policy-managed Mac ignores: the policy decides where the runtime lives (Python: config.POLICY_IGNORED_KEYS).
    static let ignoredConfigKeys = ["SUPPORT_DIR", "PYTHON_BIN", "PROJECT_DIR", "CLAUDE_BIN"]
    /// Where the company package installs the root-owned releases: the runtime a LOCKED policy still requires when its file
    /// did not name a usable `runtime.root`.
    static let defaultRuntimeRoot = "/Library/Application Support/MeetingCapture/releases"

    var isLocked: Bool { if case .invalid = state { return true } else { return false } }
    var isEnforced: Bool { state != .absent }           // the policy file or the marker exists: this Mac is policy-managed
    var isValid: Bool { state == .valid }
    var isCompany: Bool { isValid && profile == "company" }
    /// The root-owned folder python and the pipeline must live under (PolicyLayers pins PYTHON_BIN and PROJECT_DIR to <root>/current,
    /// RuntimeTrust checks it); nil = no requirement. A valid company policy: its `runtime.root`, if it has one. A LOCKED policy that
    /// does not positively say `personal` keeps the requirement (the strictest state must not hand the launcher back to a user-writable
    /// runtime, nor stop the local transcription of a package-installed Mac): the root its file named when that was readable and sane,
    /// else `defaultRuntimeRoot`. The personal install (no policy), personal profiles and a company policy without a root: nil.
    var pinnedRuntimeRoot: String? {
        if isCompany { return runtimeRoot }
        if isLocked && profile != "personal" { return runtimeRoot ?? OrgPolicy.defaultRuntimeRoot }
        return nil
    }
    /// The lock reason (`code` or `code: where`), nil unless invalid.
    var lockedReason: String? { if case .invalid(let r) = state { return r } else { return nil } }
    /// The flag is forced on whatever session.json says: a locked policy or `local_only.locked`.
    var forcesLocalOnly: Bool { isLocked || (isValid && localOnlyLocked) }

    func laneAllowed(_ lane: String) -> Bool { lanes[lane] == "allow" }

    /// The policy lets the vocabulary go to this engine word's kind of destination (`remote` and `auto` are the server kind, the others the cloud kind).
    func sendVocabAllowed(engine: String) -> Bool { engine == "remote" || engine == "auto" ? sendVocabServer : sendVocabCloud }

    /// The reason code a lane is denied for at the policy level (nil = allowed): policy-locked, policy-lane, policy-unapproved,
    /// policy-claude-unpinned.
    func laneDenialReason(_ lane: String) -> String? {
        if isLocked { return "policy-locked" }
        if laneAllowed(lane) { return nil }
        return laneReasons[lane] ?? "policy-lane"
    }

    /// The part of the lock reason before ': ' (one of the codes in config/policy-fixtures/index.json).
    var lockedCode: String? {
        guard let r = lockedReason else { return nil }
        return r.components(separatedBy: ": ").first ?? r
    }

    /// The lock reason as a short phrase in the UI language (at most 20 characters, no policy text): notifications have 100 characters in all and
    /// the support contact must not be cut off.
    var lockedReasonText: String? {
        guard let code = lockedCode else { return nil }
        return OrgPolicy.reasonText(forCode: code)
    }

    static func reasonText(forCode code: String) -> String {
        switch code {
        case "bom", "not-utf8", "bad-json", "duplicate-key", "not-object": return tr("Policy format error", ko: "정책 파일 형식 오류")
        case "bad-schema", "no-profile", "bad-profile", "bad-revision", "unknown-key", "forbidden-key", "bad-type", "bad-value":
            return tr("Policy content error", ko: "정책 내용 오류")
        case "not-regular-file", "bad-owner", "group-or-other-writable", "parent-bad-owner", "parent-writable", "parent-unreadable":
            return tr("Policy permissions", ko: "정책 파일 권한 오류")
        case "too-large": return tr("Policy file too big", ko: "정책 파일이 너무 큼")
        case "unreadable": return tr("Policy unreadable", ko: "정책 파일을 읽지 못함")
        case "required-missing": return tr("Policy file missing", ko: "정책 파일 없음")
        case "pipeline-too-old": return tr("Pipeline too old", ko: "파이프라인이 오래됨")
        default: return tr("Policy error", ko: "정책 내부 오류")
        }
    }

    // MARK: Constructors

    /// No policy.json and no policy.required: nothing restricts.
    static func absent() -> OrgPolicy {
        var lanes: [String: String] = [:]
        for lane in lanesInOrder { lanes[lane] = "allow" }
        return OrgPolicy(state: .absent, profile: "none", revision: nil, sha256Prefix: nil, localOnlyDefault: false, localOnlyLocked: false,
                         recordingEnabled: true, lanes: lanes, supportContact: nil, minPipelineVersion: nil, archiveAllowedRoots: nil,
                         localRoots: [], runtimeRoot: nil, defaults: [:], enforced: [:])
    }

    /// A policy that cannot be trusted: every lane deny, flag default and lock on, recording stays allowed (a lock must not lose a
    /// meeting), the company baseline stays in `enforced` unless the file positively says personal.
    static func locked(_ reason: String, profile: String = "unknown", revision: Int? = nil, sha256Prefix: String? = nil,
                       contact: String? = nil, minVersion: String? = nil, runtimeRoot: String? = nil) -> OrgPolicy {
        var lanes: [String: String] = [:]
        var reasons: [String: String] = [:]
        for lane in lanesInOrder { lanes[lane] = "deny"; reasons[lane] = "policy-locked" }
        return OrgPolicy(state: .invalid(reason), profile: profile, revision: revision, sha256Prefix: sha256Prefix, localOnlyDefault: true,
                         localOnlyLocked: true, recordingEnabled: true, lanes: lanes, supportContact: contact, minPipelineVersion: minVersion,
                         archiveAllowedRoots: [], localRoots: [], runtimeRoot: profile == "personal" ? nil : runtimeRoot, defaults: [:],
                         enforced: profile == "personal" ? [:] : companyBaselineEnforced, laneReasons: reasons,
                         allowedEngines: [], allowedHosts: [], sendVocabServer: false, sendVocabCloud: false)
    }

    // MARK: Reading

    /// Pure: the verdict of one policy text. `pipelineVersion` (the version of the pipeline that reads it) is only given by the shared
    /// corpus test: a pipeline older than `min_pipeline_version` reads the policy as locked (pipeline-too-old). The app passes nil: it
    /// refuses to LAUNCH an old pipeline instead (PipelineContract).
    static func parse(_ data: Data, pipelineVersion: String? = nil) -> OrgPolicy {
        let sha = sha8(data)
        if data.count > maxBytes { return locked("too-large", sha256Prefix: sha) }
        var parsed: PolicyJSON.Value?
        do {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw PolicyInvalid(code: "bom") }
            guard let text = String(data: data, encoding: .utf8) else { throw PolicyInvalid(code: "not-utf8") }
            do {
                parsed = try PolicyJSON.parse(text)
            } catch let failure as PolicyJSON.Failure {
                throw PolicyInvalid(code: failure.code, detail: failure.detail)
            }
            return try PolicyBuilder.build(parsed!, sha8: sha, pipelineVersion: pipelineVersion)
        } catch let invalid as PolicyInvalid {
            let facts = PolicyBuilder.lenient(parsed)
            return locked(invalid.reason, profile: facts.profile ?? "unknown", revision: facts.revision, sha256Prefix: sha,
                          contact: facts.contact, minVersion: facts.minVersion, runtimeRoot: facts.runtimeRoot)
        } catch {
            return locked("internal-error", sha256Prefix: sha)
        }
    }

    private static func sha8(_ data: Data) -> String {
        return SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// lstat of one path: nil = it is not there (ENOENT / ENOTDIR); any other failure is `statError`.
    static func statFile(_ url: URL) -> FileInfo? {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            return FileInfo(isRegular: false, isSymlink: false, uid: 0, mode: 0, size: 0, parentOK: false, statError: true)
        }
        let kind = st.st_mode & S_IFMT
        var parentOK = false
        var pst = stat()
        if lstat(url.deletingLastPathComponent().path, &pst) == 0 { parentOK = pst.st_uid == 0 && (pst.st_mode & 0o022) == 0 }
        return FileInfo(isRegular: kind == S_IFREG, isSymlink: kind == S_IFLNK, uid: UInt32(st.st_uid), mode: UInt16(st.st_mode & 0o7777),
                        size: Int(st.st_size), parentOK: parentOK)
    }

    /// Reads at most maxBytes + 1 bytes of the file without following a symlink (nil = cannot read).
    static func readPolicyFile(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxBytes {
            let n = read(fd, &buffer, min(buffer.count, maxBytes + 1 - data.count))
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    /// Reads the policy of this Mac. Never throws. No file and no marker: absent. A valid file: valid. Anything else: invalid (locked),
    /// confirmed by ONE more read `retryAfterMs` later (MDM writes the file: a half-written one must not lock the Mac for a run).
    static func load(path: URL = systemPath, marker: URL = requiredMarker, fileInfo: (URL) -> FileInfo? = OrgPolicy.statFile,
                     retryAfterMs: Int = 500, pipelineVersion: String? = nil,
                     readFile: (URL) -> Data? = OrgPolicy.readPolicyFile) -> OrgPolicy {
        let first = evaluate(path: path, marker: marker, fileInfo: fileInfo, readFile: readFile, pipelineVersion: pipelineVersion)
        var result = first
        if first.isLocked {
            if retryAfterMs > 0 { usleep(UInt32(retryAfterMs) * 1000) }
            result = evaluate(path: path, marker: marker, fileInfo: fileInfo, readFile: readFile, pipelineVersion: pipelineVersion)
        }
        switch result.state {
        case .absent: break
        case .valid: Log.info("policy: valid, profile \(result.profile), revision \(result.revision.map(String.init) ?? "?"), sha256 \(result.sha256Prefix ?? "?")")
        case .invalid(let reason): Log.warn("policy: LOCKED (\(reason)); every external lane is closed, the per-meeting flag is forced on")
        }
        return result
    }

    private static func evaluate(path: URL, marker: URL, fileInfo: (URL) -> FileInfo?, readFile: (URL) -> Data?, pipelineVersion: String?) -> OrgPolicy {
        let markerInfo = fileInfo(marker)
        let markerPresent = markerInfo != nil           // a marker that cannot be read counts as there: unknown is managed
        guard let st = fileInfo(path) else { return markerPresent ? locked("required-missing") : absent() }
        if st.statError { return locked("unreadable: stat") }
        if st.isSymlink || !st.isRegular { return locked("not-regular-file") }
        if st.uid != 0 { return locked("bad-owner") }
        if st.mode & 0o022 != 0 { return locked("group-or-other-writable") }
        if st.size > maxBytes { return locked("too-large") }
        var ancestor = path.deletingLastPathComponent()
        while true {
            guard let info = fileInfo(ancestor), !info.statError, !info.isRegular else { return locked("parent-unreadable") }
            if info.uid != 0 { return locked("parent-bad-owner") }
            if info.mode & 0o022 != 0 { return locked("parent-writable") }
            if ancestor.path == "/" || ancestor.path.isEmpty { break }
            let next = ancestor.deletingLastPathComponent()
            if next.path == ancestor.path { break }
            ancestor = next
        }
        guard let data = readFile(path) else { return locked("unreadable: read") }
        if data.count > maxBytes { return locked("too-large", sha256Prefix: sha8(data)) }
        return parse(data, pipelineVersion: pipelineVersion)
    }

    // MARK: Test hooks and managed Macs

    /// True when this Mac is policy-managed: policy.json or policy.required is there (lstat; a dangling symlink counts, and so does a
    /// lookup that fails for any reason other than "not there").
    static func systemPolicyPresent(path: URL = systemPath, marker: URL = requiredMarker, fileInfo: (URL) -> FileInfo? = OrgPolicy.statFile) -> Bool {
        return fileInfo(path) != nil || fileInfo(marker) != nil
    }

    /// The value of a test-hook environment variable (`testHookNames`), nil when it is unset or empty or this Mac is policy-managed.
    /// Everything that reads MCAP_CONFIG, MCAP_LOG_DIR or MCAP_SECURITY_BIN goes through here (or through `systemPolicyPresent`).
    static func testHookValue(_ name: String, env: [String: String] = ProcessInfo.processInfo.environment, policyPresent: Bool? = nil) -> String? {
        guard let value = env[name], !value.isEmpty else { return nil }
        if policyPresent ?? systemPolicyPresent() { return nil }
        return value
    }
}

// MARK: - Policy builder (mirrors pipeline/mcap/policy.py _build_policy rule by rule, in the same order)

private struct PolicyInvalid: Error {
    let code: String
    var detail: String = ""
    var reason: String { String((detail.isEmpty ? code : "\(code): \(detail)").prefix(80)) }
}

private indirect enum PolicySchema {
    case leaf                               // any value; typed later
    case free                               // `ext`
    case names(Set<String>)                 // an object whose keys must be in the set (defaults, enforced, llm.child_env)
    case object([String: PolicySchema])
    case list(PolicySchema)                 // a list of closed objects (asr.org_consents)

    static let consentKeys: [String: PolicySchema] = Dictionary(uniqueKeysWithValues:
        ["engine", "host", "port", "protocol", "backend_kind", "ca_sha256", "attest_build_sha256", "use", "expires"].map { ($0, PolicySchema.leaf) })

    static let top: PolicySchema = .object([
        "schema": .leaf, "profile": .leaf, "revision": .leaf, "issued": .leaf, "min_pipeline_version": .leaf,
        "support": .object(["contact": .leaf]),
        "lanes": .object(Dictionary(uniqueKeysWithValues: OrgPolicy.lanesInOrder.map { ($0, PolicySchema.leaf) })),
        "approvals": .object(Dictionary(uniqueKeysWithValues: OrgPolicy.approvalLanes.map { ($0, PolicySchema.leaf) })),
        "local_only": .object(["default": .leaf, "locked": .leaf]),
        "recording": .object(["enabled": .leaf]),
        "asr": .object(["allowed_engines": .leaf, "allowed_hosts": .leaf, "allow_foreign": .leaf, "daily_audio_minutes_cap": .leaf,
                        "send_vocab": .object(["server": .leaf, "cloud": .leaf]), "org_consents": .list(.object(consentKeys))]),
        "archive": .object(["allowed_roots": .leaf, "local_roots": .leaf]),
        "llm": .object(["claude_bin_pin": .object(["team_id": .leaf, "sha256": .leaf]), "child_env": .names(OrgPolicy.childEnvNames)]),
        "runtime": .object(["root": .leaf]),
        "defaults": .names(PolicyLayers.whitelist),
        "enforced": .names(PolicyLayers.whitelist),
        "ext": .free,
    ])
}

private enum PolicyBuilder {
    typealias Members = [PolicyJSON.Member]

    // MARK: closed schema

    static func scan(_ value: PolicyJSON.Value, schema: PolicySchema, path: String) throws {
        switch schema {
        case .leaf, .free:
            return
        case .list(let item):
            guard case .array(let items) = value else { throw PolicyInvalid(code: "bad-type", detail: path) }
            for (i, element) in items.enumerated() { try scan(element, schema: item, path: "\(path)[\(i)]") }
        case .names(let allowed):
            guard case .object(let members) = value else { throw PolicyInvalid(code: "bad-type", detail: path) }
            for member in members {
                let here = path.isEmpty ? member.key : "\(path).\(member.key)"
                if PolicyLayers.forbiddenKeys.contains(member.key) { throw PolicyInvalid(code: "forbidden-key", detail: here) }
                if !allowed.contains(member.key) { throw PolicyInvalid(code: "unknown-key", detail: here) }
            }
        case .object(let keys):
            guard case .object(let members) = value else { throw PolicyInvalid(code: "bad-type", detail: path) }
            for member in members {
                let here = path.isEmpty ? member.key : "\(path).\(member.key)"
                guard let sub = keys[member.key] else { throw PolicyInvalid(code: "unknown-key", detail: here) }
                try scan(member.value, schema: sub, path: here)
            }
        }
    }

    // MARK: typed readers (a bool is not a number, null is not "absent")

    static func find(_ members: Members, _ key: String) -> PolicyJSON.Value? {
        return members.first { $0.key.utf8.elementsEqual(key.utf8) }?.value
    }

    /// The members of an object-valued key (the scan already guaranteed the container type), [] when the key is absent.
    static func section(_ members: Members, _ key: String) -> Members {
        if case .object(let inner)? = find(members, key) { return inner }
        return []
    }

    static func getBool(_ members: Members, _ key: String, default fallback: Bool, path: String) throws -> Bool {
        guard let value = find(members, key) else { return fallback }
        guard case .bool(let b) = value else { throw PolicyInvalid(code: "bad-type", detail: path + key) }
        return b
    }

    static func getInt(_ members: Members, _ key: String, path: String, minimum: Int, maximum: Int? = nil) throws -> Int? {
        guard let value = find(members, key) else { return nil }
        switch value {
        case .int(let n):
            if n < minimum || (maximum != nil && n > maximum!) { throw PolicyInvalid(code: "bad-value", detail: path + key) }
            return n
        case .bigInt(let negative):
            if negative || maximum != nil { throw PolicyInvalid(code: "bad-value", detail: path + key) }
            return Int.max
        default:
            throw PolicyInvalid(code: "bad-type", detail: path + key)
        }
    }

    static func cleanString(_ value: PolicyJSON.Value, path: String, maxLength: Int, singleLine: Bool = true) throws -> String {
        guard case .string(let s) = value else { throw PolicyInvalid(code: "bad-type", detail: path) }
        let scalars = s.unicodeScalars
        if scalars.count > maxLength || scalars.contains(where: { $0.value == 0 })
            || (singleLine && scalars.contains(where: { $0.value < 32 || $0.value == 127 })) {
            throw PolicyInvalid(code: "bad-value", detail: path)
        }
        return s
    }

    static func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func stringList(_ members: Members, _ key: String, path: String, lower: Bool = false, maxItems: Int = 256, maxLength: Int = 1024) throws -> [String]? {
        guard let value = find(members, key) else { return nil }
        guard case .array(let items) = value, items.count <= maxItems else { throw PolicyInvalid(code: "bad-type", detail: path + key) }
        var out: [String] = []
        for (i, item) in items.enumerated() {
            let text = strip(try cleanString(item, path: "\(path)\(key)[\(i)]", maxLength: maxLength))
            if text.isEmpty { throw PolicyInvalid(code: "bad-value", detail: "\(path)\(key)[\(i)]") }
            out.append(lower ? text.lowercased() : text)
        }
        return out
    }

    static func isHex64(_ s: String) -> Bool {
        return s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    static func isTeamID(_ s: String) -> Bool {
        return s.utf8.count == 10 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }
    }

    /// YYYY-MM-DD with ASCII digits and a real calendar date.
    static func isDate(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D else { return false }
        func num(_ range: Range<Int>) -> Int? {
            var n = 0
            for i in range { guard b[i] >= 0x30 && b[i] <= 0x39 else { return nil }; n = n * 10 + Int(b[i] - 0x30) }
            return n
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10), y >= 1, (1...12).contains(m), d >= 1 else { return false }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return d <= days[m - 1]
    }

    // MARK: lenient facts of a policy that failed a rule

    /// `runtime.root` as the builder accepts it: an absolute path without a `..` component.
    static func isPlainRuntimeRoot(_ text: String) -> Bool {
        return text.hasPrefix("/") && !(text + "/").contains("/../") && !text.hasSuffix("/..")
    }

    static func lenient(_ value: PolicyJSON.Value?) -> (profile: String?, revision: Int?, contact: String?, minVersion: String?, runtimeRoot: String?) {
        guard case .object(let top)? = value else { return (nil, nil, nil, nil, nil) }
        var profile: String?
        var revision: Int?
        var contact: String?
        var minVersion: String?
        var runtimeRoot: String?
        if case .string(let p)? = find(top, "profile"), p == "company" || p == "personal" { profile = p }
        switch find(top, "revision") {
        case .int(let n)? where n > 0: revision = n
        case .bigInt(let negative)? where !negative: revision = Int.max
        default: break
        }
        if case .object(let support)? = find(top, "support"), case .string(let c)? = find(support, "contact"),
           !c.isEmpty, c.unicodeScalars.count <= 60, !c.unicodeScalars.contains(where: { $0.value < 32 }) {
            contact = c
        }
        if case .string(let v)? = find(top, "min_pipeline_version"), !v.isEmpty { minVersion = String(v.prefix(20)) }
        // The runtime the file named (a lock must not move the launcher to another place): only a value the builder would have accepted.
        if case .object(let runtime)? = find(top, "runtime"), let root = find(runtime, "root"),
           let text = try? cleanString(root, path: "runtime.root", maxLength: 1024), isPlainRuntimeRoot(text) {
            runtimeRoot = text
        }
        return (profile, revision, contact, minVersion, runtimeRoot)
    }

    // MARK: build

    static func build(_ root: PolicyJSON.Value, sha8: String, pipelineVersion: String?) throws -> OrgPolicy {
        guard case .object(let top) = root else { throw PolicyInvalid(code: "not-object") }
        try scan(root, schema: PolicySchema.top, path: "")
        guard case .int(let schema)? = find(top, "schema"), schema == 1 else { throw PolicyInvalid(code: "bad-schema") }
        guard let profileValue = find(top, "profile") else { throw PolicyInvalid(code: "no-profile") }
        guard case .string(let profile) = profileValue, profile == "company" || profile == "personal" else { throw PolicyInvalid(code: "bad-profile") }
        let company = profile == "company"
        let revision: Int
        switch find(top, "revision") {
        case .int(let n)? where n > 0: revision = n
        case .bigInt(let negative)? where !negative: revision = Int.max
        default: throw PolicyInvalid(code: "bad-revision")
        }
        if let issued = find(top, "issued") { _ = try cleanString(issued, path: "issued", maxLength: 64) }
        var minVersion: String?
        if let v = find(top, "min_pipeline_version") {
            let text = try cleanString(v, path: "min_pipeline_version", maxLength: 20).trimmingCharacters(in: CharacterSet(charactersIn: " "))
            guard PipelineContract.parseVersion(text) != nil else { throw PolicyInvalid(code: "bad-value", detail: "min_pipeline_version") }
            minVersion = text
        }
        var contact: String?
        let support = section(top, "support")
        if let c = find(support, "contact") {
            let text = try cleanString(c, path: "support.contact", maxLength: 60)
            if strip(text).isEmpty { throw PolicyInvalid(code: "bad-value", detail: "support.contact") }
            contact = text
        }

        // lanes: a value that is not exactly "allow" is deny for THAT lane (never a lock); a missing lane follows the profile
        let lanesRaw = section(top, "lanes")
        var approvals: [String: String] = [:]
        for member in section(top, "approvals") {
            guard case .string(let ref) = member.value else { throw PolicyInvalid(code: "bad-type", detail: "approvals.\(member.key)") }
            if ref.unicodeScalars.count > 80 || ref.unicodeScalars.contains(where: { $0.value < 32 }) {
                throw PolicyInvalid(code: "bad-value", detail: "approvals.\(member.key)")
            }
            if !strip(ref).isEmpty { approvals[member.key] = strip(ref) }
        }

        // llm
        let llm = section(top, "llm")
        var pinned = false
        if let rawPin = find(llm, "claude_bin_pin") {
            guard case .object(let pin) = rawPin else { throw PolicyInvalid(code: "bad-type", detail: "llm.claude_bin_pin") }
            if pin.count == 1, pin[0].key == "team_id", case .string(let id) = pin[0].value, isTeamID(id) {
                pinned = true
            } else if pin.count == 1, pin[0].key == "sha256", case .string(let digest) = pin[0].value, isHex64(digest) {
                pinned = true
            } else {
                throw PolicyInvalid(code: "bad-value", detail: "llm.claude_bin_pin")
            }
        }
        for member in section(llm, "child_env") { _ = try cleanString(member.value, path: "llm.child_env.\(member.key)", maxLength: 64) }

        var effective: [String: String] = [:]
        var reasons: [String: String] = [:]
        for lane in OrgPolicy.lanesInOrder {
            var verdict: String
            if let raw = find(lanesRaw, lane) {
                if case .string(let s) = raw, s == "allow" { verdict = "allow" } else { verdict = "deny" }
            } else {
                verdict = company ? "deny" : "allow"
            }
            var reason: String?
            if verdict == "deny" {
                reason = "policy-lane"
            } else if company && OrgPolicy.approvalLanes.contains(lane) && approvals[lane] == nil {
                verdict = "deny"; reason = "policy-unapproved"
            } else if company && lane == "llm" && !pinned {
                verdict = "deny"; reason = "policy-claude-unpinned"
            }
            effective[lane] = verdict
            if let r = reason { reasons[lane] = r }
        }

        let localOnly = section(top, "local_only")
        let loDefault = try getBool(localOnly, "default", default: false, path: "local_only.")
        let loLocked = try getBool(localOnly, "locked", default: false, path: "local_only.")
        let recording = try getBool(section(top, "recording"), "enabled", default: true, path: "recording.")

        // asr
        let asr = section(top, "asr")
        var engines = try stringList(asr, "allowed_engines", path: "asr.", lower: true, maxLength: 40)
        var hosts = try stringList(asr, "allowed_hosts", path: "asr.", lower: true, maxLength: 253)
        if let h = hosts, h.contains(where: { $0.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) }) {
            throw PolicyInvalid(code: "bad-value", detail: "asr.allowed_hosts")
        }
        _ = try getBool(asr, "allow_foreign", default: false, path: "asr.")
        _ = try getInt(asr, "daily_audio_minutes_cap", path: "asr.", minimum: 0, maximum: 100_000)
        let vocab = section(asr, "send_vocab")
        let vocabServer = try getBool(vocab, "server", default: true, path: "asr.send_vocab.")
        let vocabCloud = try getBool(vocab, "cloud", default: !company, path: "asr.send_vocab.")
        var consentHosts: [String] = []
        if case .array(let items)? = find(asr, "org_consents") {
            if items.count > 50 { throw PolicyInvalid(code: "bad-value", detail: "asr.org_consents") }
            for (i, item) in items.enumerated() {
                guard case .object(let entry) = item else { throw PolicyInvalid(code: "bad-type", detail: "asr.org_consents[\(i)]") }
                let here = "asr.org_consents[\(i)]."
                for key in ["engine", "host", "protocol", "backend_kind", "ca_sha256", "attest_build_sha256", "use", "expires"] where find(entry, key) == nil {
                    throw PolicyInvalid(code: "bad-value", detail: here + key)
                }
                let engine = strip(try cleanString(find(entry, "engine")!, path: here + "engine", maxLength: 40)).lowercased()
                let host = strip(try cleanString(find(entry, "host")!, path: here + "host", maxLength: 253)).lowercased()
                _ = try cleanString(find(entry, "protocol")!, path: here + "protocol", maxLength: 40)
                let backend = try cleanString(find(entry, "backend_kind")!, path: here + "backend_kind", maxLength: 20)
                _ = try getInt(entry, "port", path: here, minimum: 1, maximum: 65535)
                let ca = try cleanString(find(entry, "ca_sha256")!, path: here + "ca_sha256", maxLength: 64)
                let use = try cleanString(find(entry, "use")!, path: here + "use", maxLength: 20)
                let expires = try cleanString(find(entry, "expires")!, path: here + "expires", maxLength: 10)
                guard case .array(let buildsRaw) = find(entry, "attest_build_sha256")!, buildsRaw.count <= 64 else {
                    throw PolicyInvalid(code: "bad-type", detail: here + "attest_build_sha256")
                }
                var builds: [String] = []
                for b in buildsRaw { builds.append(try cleanString(b, path: here + "attest_build_sha256", maxLength: 64).lowercased()) }
                if engine.isEmpty || host.isEmpty || host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
                    || !isHex64(ca) || builds.contains(where: { !isHex64($0) }) || !["primary", "fallback", "both"].contains(use)
                    || backend != "server" || !isDate(expires) {
                    throw PolicyInvalid(code: "bad-value", detail: "asr.org_consents[\(i)]")
                }
                consentHosts.append(host)
            }
        }

        // archive and runtime
        let archive = section(top, "archive")
        var roots = try stringList(archive, "allowed_roots", path: "archive.")
        let localRoots = try stringList(archive, "local_roots", path: "archive.") ?? []
        for (key, items) in [("allowed_roots", roots ?? []), ("local_roots", localRoots)] {
            for (i, item) in items.enumerated() where !ArchiveRootMatcher.anchored(item) {
                throw PolicyInvalid(code: "bad-value", detail: "archive.\(key)[\(i)]")
            }
        }
        if roots == nil && company { roots = [] }
        if engines == nil && company { engines = [] }
        if hosts == nil && company { hosts = [] }
        var runtimeRoot: String?
        if let r = find(section(top, "runtime"), "root") {
            let text = try cleanString(r, path: "runtime.root", maxLength: 1024)
            if !isPlainRuntimeRoot(text) { throw PolicyInvalid(code: "bad-value", detail: "runtime.root") }
            runtimeRoot = company ? text : nil
        }

        // defaults / enforced: whitelisted behavioural keys, string values the config parser itself accepts
        var layers: [String: [String: String]] = [:]
        for name in ["defaults", "enforced"] {
            var layer: [String: String] = [:]
            for member in section(top, name) {
                let text = try cleanString(member.value, path: "\(name).\(member.key)", maxLength: 500)
                if strip(text).isEmpty { throw PolicyInvalid(code: "bad-value", detail: "\(name).\(member.key)") }
                if !LayerValue.acceptable(key: member.key, text: text) { throw PolicyInvalid(code: "bad-value", detail: "\(name).\(member.key)") }
                layer[member.key] = text
            }
            layers[name] = layer
        }
        var enforced = company ? OrgPolicy.companyBaselineEnforced : [:]
        for (key, value) in layers["enforced"] ?? [:] { enforced[key] = value }

        // a pipeline older than the policy asks for reads it as locked: the policy may use keys it cannot know
        if let minimum = minVersion, let current = pipelineVersion {
            let tooOld: Bool
            if let have = PipelineContract.parseVersion(current), let want = PipelineContract.parseVersion(minimum) {
                tooOld = PipelineContract.versionLess(have, want)
            } else {
                tooOld = true
            }
            if tooOld { throw PolicyInvalid(code: "pipeline-too-old", detail: minimum) }
        }

        return OrgPolicy(state: .valid, profile: profile, revision: revision, sha256Prefix: sha8, localOnlyDefault: loDefault, localOnlyLocked: loLocked,
                         recordingEnabled: recording, lanes: effective, supportContact: contact, minPipelineVersion: minVersion,
                         archiveAllowedRoots: roots, localRoots: localRoots, runtimeRoot: runtimeRoot, defaults: layers["defaults"] ?? [:],
                         enforced: enforced, laneReasons: reasons, allowedEngines: engines, allowedHosts: hosts, orgConsentHosts: consentHosts,
                         claudeBinPinned: pinned, sendVocabServer: vocabServer, sendVocabCloud: vocabCloud)
    }
}

/// The value rules of pipeline/mcap/config.py `_KEYS` for the keys a policy layer may carry: a number key needs a number (and the range
/// of its caster); switches, words and the keys only the app reads accept any text. Python locks the whole policy on a bad value, so
/// the Swift reader does too. Python's int() / float() grammar is followed for ASCII text (surrounding blanks, a sign, `1_000` with
/// underscores between digits, an integer of any size, inf / nan); only non-ASCII digits are refused here, which is the closed direction.
enum LayerValue {
    struct Rule { var isInt: Bool; var minimum: Double? = nil; var exclusiveMinimum = false; var maximum: Double? = nil; var finite = true }

    static let rules: [String: Rule] = [
        "ASR_LOCAL_MIN_RAM_GB": Rule(isInt: true, minimum: 0),
        "ASR_LOCAL_MAX_RTF": Rule(isInt: false, minimum: 0, exclusiveMinimum: true),
        "ASR_REMOTE_MAX_WAIT_S": Rule(isInt: true, minimum: 1),
        "ASR_AZURE_BIAS": Rule(isInt: false, minimum: 0, maximum: 2),
        "ASR_AZURE_USD_PER_HOUR": Rule(isInt: false, minimum: 0),
        "ASR_CLOUD_DAILY_MINUTES": Rule(isInt: true, minimum: 0),
        "ASR_REQUEST_TIMEOUT_S": Rule(isInt: true, minimum: 1),
        "ASR_RETRY_MAX": Rule(isInt: true, minimum: 1),
        "ASR_CIRCUIT_FAILS": Rule(isInt: true, minimum: 1),
        "ASR_CIRCUIT_COOLDOWN_S": Rule(isInt: true, minimum: 1),
        "LOCAL_ARCHIVE_RETENTION_DAYS": Rule(isInt: true, minimum: 0),
        "STAGING_FAILED_RETENTION_DAYS": Rule(isInt: true, minimum: 0),
        "LOG_RETENTION_DAYS": Rule(isInt: true, minimum: 0),
        "APP_LOG_MAX_MB": Rule(isInt: true, minimum: 0),
        "AUDIO_RETENTION_DAYS": Rule(isInt: true),
        "NOTE_TIMEOUT_SECONDS": Rule(isInt: true),
        "MAX_CLAUDE_CALLS_PER_MEETING": Rule(isInt: true),
        "CLAUDE_DAILY_BUDGET_USD": Rule(isInt: false, finite: false),
        "CLAUDE_MEETING_BUDGET_USD": Rule(isInt: false, finite: false),
    ]

    static func acceptable(key: String, text: String) -> Bool {
        guard let rule = rules[key] else { return true }
        guard let cleaned = withoutUnderscores(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        var number: Double
        if rule.isInt {
            var digits = Substring(cleaned)
            if digits.hasPrefix("+") || digits.hasPrefix("-") { digits = digits.dropFirst() }
            guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
            if let n = Int(cleaned) {
                number = Double(n)
            } else {
                number = cleaned.hasPrefix("-") ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude    // beyond Int64: Python has big integers
            }
        } else {
            let lower = cleaned.lowercased()
            guard !cleaned.isEmpty, !lower.contains("x"), !lower.contains("("), let d = Double(cleaned) else { return false }
            if rule.finite && !d.isFinite { return false }
            number = d
        }
        if let lo = rule.minimum, rule.exclusiveMinimum ? number <= lo : number < lo { return false }
        if let hi = rule.maximum, number > hi { return false }
        return true
    }

    /// Python lets an underscore stand between two digits ("1_000"); anywhere else it is an error. nil = a misplaced underscore.
    static func withoutUnderscores(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        func digit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        var out: [UInt8] = []
        for (i, c) in bytes.enumerated() {
            if c == 0x5F {
                guard i > 0, i + 1 < bytes.count, digit(bytes[i - 1]), digit(bytes[i + 1]) else { return nil }
                continue
            }
            out.append(c)
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - Policy layers over config.env

/// The policy's `defaults` (beneath config.env, only where the key is unset) and `enforced` (above it) layers, restricted to the
/// whitelisted behavioural keys, and the rules of a policy-managed Mac. AppConfig.load calls `apply` on the parsed
/// config.env values; PrivacySettings and ZoomTierSettings read the same layered values.
enum PolicyLayers {
    /// Keys a layer may carry (the closed list of pipeline/mcap/policy.py DEFAULTS_WHITELIST; the self test compares the two).
    static let whitelist: Set<String> = [
        "ASR_MODEL", "ASR_LANGUAGE", "ASR_LANGUAGES", "ASR_VAD", "ASR_ENGINE", "ASR_FALLBACK", "ASR_LOCAL_MIN_RAM_GB", "ASR_LOCAL_MAX_RTF",
        "ASR_REMOTE_URL", "ASR_REMOTE_CA_FILE", "ASR_REMOTE_MAX_WAIT_S", "ASR_AZURE_REGION", "ASR_AZURE_HOST", "ASR_AZURE_LOCALES",
        "ASR_AZURE_BIAS", "ASR_AZURE_USD_PER_HOUR", "ASR_CLOUD_DAILY_MINUTES", "ASR_REQUEST_TIMEOUT_S", "ASR_RETRY_MAX", "ASR_CIRCUIT_FAILS",
        "ASR_CIRCUIT_COOLDOWN_S", "ASR_ALLOW_DOWNLOAD", "ASR_SEND_VOCAB", "LOCAL_ONLY_DEFAULT", "AUDIO_RETENTION_DAYS",
        "LOCAL_ARCHIVE_RETENTION_DAYS", "STAGING_FAILED_RETENTION_DAYS", "LOG_CONTENT", "LOG_RETENTION_DAYS", "APP_LOG_MAX_MB",
        "STATUS_INCLUDE_USAGE", "MIC_MUTE_GATE", "NOTIFY_RECORDING", "CLAUDE_AUTH", "CLAUDE_DAILY_BUDGET_USD", "CLAUDE_MEETING_BUDGET_USD",
        "MAX_CLAUDE_CALLS_PER_MEETING", "NOTE_MODEL", "NOTE_FALLBACK_MODEL", "NOTE_EFFORT", "NOTE_LANGUAGE", "NOTE_TIMEOUT_SECONDS",
        "NOTE_STOP_ON_OVERAGE", "TRANSCRIPT_CLEANUP", "NOTE_VERIFY", "CALENDAR_LOOKUP", "MIC_AEC", "ENABLED_PLATFORMS", "BROWSER_BUNDLE_IDS",
        "POLL_INTERVAL_SECONDS", "START_DEBOUNCE_SECONDS", "GRACE_SECONDS", "MIN_RECORDING_SECONDS", "MAX_RECORDING_HOURS", "MIN_FREE_DISK_GB",
        "NO_SPEECH_STOP_MINUTES", "RETRY_SWEEP_HOURS", "SYSTEM_AUDIO_MODE", "ZOOM_STRONG_SOCKETS", "ZOOM_WEAK_DEBOUNCE_SECONDS",
        "CALL_DETECT", "CALL_GENERIC_SECONDS", "EXTRA_MEETING_APPS", "CALL_BROWSER_URLS",
    ]
    /// Never settable through any layer (shared contract files and the personal install).
    static let forbiddenKeys: Set<String> = ["ARCHIVE_DIR", "PROJECT_DIR", "PYTHON_BIN", "CLAUDE_BIN", "SUPPORT_DIR", "SELF_NAME", "LOCAL_ARCHIVE_DIR"]

    /// built-in default < `policy.defaults` (only where the key is unset or empty) < config.env < `policy.enforced`.
    /// No policy (absent): the values are untouched. On a policy-managed Mac (a policy or the marker exists, valid or not):
    ///   - SUPPORT_DIR, PYTHON_BIN, PROJECT_DIR and CLAUDE_BIN of config.env are dropped (the policy decides where the runtime lives);
    ///   - a valid policy's `defaults` apply; `enforced` applies for a valid AND a locked policy (a lock keeps the company baseline);
    ///   - company with `runtime.root`, or a locked policy that does not say personal (`OrgPolicy.pinnedRuntimeRoot`): PROJECT_DIR and
    ///     PYTHON_BIN are fixed to <root>/current.
    static func apply(_ values: inout [String: String], policy: OrgPolicy) {
        guard policy.isEnforced else { return }
        for key in OrgPolicy.ignoredConfigKeys { values.removeValue(forKey: key) }
        if policy.isValid {
            for (key, value) in policy.defaults where whitelist.contains(key) && (values[key] ?? "").isEmpty { values[key] = value }
        }
        for (key, value) in policy.enforced where whitelist.contains(key) { values[key] = value }
        if let root = policy.pinnedRuntimeRoot {
            let release = (root.hasSuffix("/") ? String(root.dropLast()) : root) + "/current"
            values["PROJECT_DIR"] = release
            values["PYTHON_BIN"] = release + "/venv/bin/python"
        }
    }
}

// MARK: - Privacy settings (config.env)

/// The new config.env keys the app acts on. Every switch is read to the RESTRICTIVE value of that key when its text is not understood
/// (a typo must never switch a protection off nor a leak on): LOCAL_ONLY_DEFAULT unknown = on, LOG_CONTENT unknown = off,
/// MIC_MUTE_GATE unknown = on. Defaults reproduce today's behaviour. Mirrors pipeline/mcap/config.py (`_switch`, `_Enum`, `_mic_gate`).
struct PrivacySettings: Equatable {
    var localOnlyDefault: Bool                  // LOCAL_ONLY_DEFAULT (default 0)
    var asrEngine: String                       // ASR_ENGINE whisper | remote | azure | clova | openai-compat | auto (default whisper)
    var micMuteGate: String                     // MIC_MUTE_GATE off | on (default off; unknown text = on)
    var localArchiveDir: URL                    // LOCAL_ARCHIVE_DIR (default SUPPORT_DIR/local-meetings)
    var archiveDirExplicit: Bool                // ARCHIVE_DIR is written in config.env (a company Mac without it has no Drive lane)
    // Additive:
    var asrFallback: String = "none"            // ASR_FALLBACK none | whisper | remote | azure | clova | openai-compat
    var logContent: Bool = true                 // LOG_CONTENT (default 1; unknown text = 0)
    var logRetentionDays: Int = 0               // LOG_RETENTION_DAYS (0 = keep)
    var appLogMaxMB: Int = 0                    // APP_LOG_MAX_MB (0 = no rotation: today's behaviour)
    var calendarLookup: Bool = true             // CALENDAR_LOOKUP is not 0/off/false/no/none
    var warnings: [String] = []                 // unrecognised switch / word / number texts (doctor shows the same)

    // The same words as ASR_ENGINE_CHOICES / ASR_FALLBACK_CHOICES of pipeline/mcap/policy.py (a self-test compares them): a word the app
    // does not know would be read as whisper and the menu would say that nothing leaves this Mac.
    static let engineWords = ["whisper", "remote", "azure", "clova", "openai-compat", "auto"]
    static let fallbackWords = ["none", "whisper", "remote", "azure", "clova", "openai-compat"]

    static func build(from values: [String: String], supportDir: URL, source: String) -> PrivacySettings {
        var settings = PrivacySettings(localOnlyDefault: false, asrEngine: "whisper", micMuteGate: "off",
                                       localArchiveDir: supportDir.appendingPathComponent("local-meetings", isDirectory: true),
                                       archiveDirExplicit: false)
        func text(_ key: String) -> String? {
            guard let v = values[key], !v.isEmpty else { return nil }
            return v
        }
        func warn(_ key: String, _ raw: String, _ meaning: String) {
            let shown = String(raw.prefix(30))
            settings.warnings.append("\(key)=\(shown) is not understood; read as \(meaning)")
            Log.warn("config: \(key)=\(shown) is not understood (in \(source)); read as \(meaning)")
        }
        func switchValue(_ key: String, restrictive: Bool, fallback: Bool) -> Bool {
            guard let raw = text(key) else { return fallback }
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default:
                warn(key, raw, restrictive ? "1 (fail closed)" : "0 (fail closed)")
                return restrictive
            }
        }
        func word(_ key: String, _ allowed: [String], fallback: String) -> String {
            guard let raw = text(key) else { return fallback }
            let w = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if allowed.contains(w) { return w }
            warn(key, raw, fallback)
            return fallback
        }
        func wholeNumber(_ key: String) -> Int {
            guard let raw = text(key) else { return 0 }
            let t = raw.trimmingCharacters(in: .whitespaces)
            if let n = Int(t), n >= 0 { return n }
            let shown = String(raw.prefix(30))
            settings.warnings.append("\(key)=\(shown) is not a whole number >= 0; keeping 0")
            Log.warn("config: \(key)=\(shown) is not a whole number >= 0 (in \(source)); keeping 0")
            return 0
        }

        settings.localOnlyDefault = switchValue("LOCAL_ONLY_DEFAULT", restrictive: true, fallback: false)
        settings.asrEngine = word("ASR_ENGINE", engineWords, fallback: "whisper")
        settings.asrFallback = word("ASR_FALLBACK", fallbackWords, fallback: "none")
        if let raw = text("MIC_MUTE_GATE") {
            let w = raw.trimmingCharacters(in: .whitespaces).lowercased()
            settings.micMuteGate = ["0", "false", "no", "off"].contains(w) ? "off" : "on"
            if !["1", "true", "yes", "on", "0", "false", "no", "off"].contains(w) { warn("MIC_MUTE_GATE", raw, "on (fail closed)") }
        }
        settings.logContent = switchValue("LOG_CONTENT", restrictive: false, fallback: true)
        settings.logRetentionDays = wholeNumber("LOG_RETENTION_DAYS")
        settings.appLogMaxMB = wholeNumber("APP_LOG_MAX_MB")
        if let raw = text("CALENDAR_LOOKUP") {
            settings.calendarLookup = !["0", "off", "false", "no", "none"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
        }
        if let raw = text("LOCAL_ARCHIVE_DIR") {
            let expanded = (raw as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                settings.localArchiveDir = URL(fileURLWithPath: expanded, isDirectory: true)
            } else {
                settings.warnings.append("LOCAL_ARCHIVE_DIR is not an absolute path; keeping the default")
                Log.warn("config: LOCAL_ARCHIVE_DIR=\(raw) is not an absolute path (in \(source)); keeping default")
            }
        }
        settings.archiveDirExplicit = text("ARCHIVE_DIR") != nil
        return settings
    }

    /// The settings of this run: config.env (`file`) with the policy layers applied, like AppConfig.load does.
    static func load(config: AppConfig, policy: OrgPolicy, file: URL = AppConfig.configFilePath) -> PrivacySettings {
        var values: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) {
            values = AppConfig.parseEnvText(text)
        }
        PolicyLayers.apply(&values, policy: policy)
        return build(from: values, supportDir: config.supportDir, source: file.path)
    }
}

// MARK: - realpath and archive roots

/// realpath for paths that may not exist: the existing prefix is resolved (symlinks followed), the rest is kept and `.` / `..` are
/// folded lexically, like Python's os.path.realpath (non-strict).
enum RealPath {
    static func resolve(_ absolute: String, maxLinks: Int = 40) -> String {
        var resolved: [String] = []
        var pending = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init).reversed() as [String]
        var links = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            var st = stat()
            if lstat(candidate, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                links += 1
                if links > maxLinks { return lexical(absolute) }                 // a link loop: leave the path as it is
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(candidate, &buffer, buffer.count - 1)
                if n < 0 { resolved.append(component); continue }
                buffer[n] = 0
                let target = String(cString: buffer)
                if target.hasPrefix("/") { resolved = [] }
                pending.append(contentsOf: target.split(separator: "/", omittingEmptySubsequences: true).map(String.init).reversed() as [String])
            } else {
                resolved.append(component)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// '..', '.' and '//' folded without touching the disk (os.path.abspath).
    static func lexical(_ absolute: String) -> String {
        var out: [String] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(String(component))
        }
        return "/" + out.joined(separator: "/")
    }
}

/// Is a path inside one of the policy's archive roots? Same algorithm as pipeline/mcap/policy.py `archive_root_matches`, same cases
/// (config/policy-fixtures/archive_roots_cases.json): both sides are `~`-expanded and realpath'ed, split into NFC + casefolded
/// components, and a root matches by PREFIX of whole components; inside a component only `*` is a wildcard (not ? and not [..]).
/// A path or root that is not anchored ('/...', '~', '~/...') matches nothing, whatever the working directory.
enum ArchiveRootMatcher {
    static func anchored(_ text: String) -> Bool { text == "~" || text.hasPrefix("/") || text.hasPrefix("~/") }

    /// realpath of an anchored path (the `~` expanded with `home`), nil for text that is not anchored or cannot be a path.
    static func resolved(_ text: String, home: String) -> String? {
        guard anchored(text), !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return nil }
        var h = home
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        var expanded = text
        if text == "~" { expanded = h } else if text.hasPrefix("~/") { expanded = (h == "/" ? "" : h) + "/" + text.dropFirst(2) }
        guard expanded.hasPrefix("/") else { return nil }
        return RealPath.resolve(expanded)
    }

    static func fold(_ text: String) -> String {
        return text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    static func components(_ path: String) -> [String] {
        return path.split(separator: "/", omittingEmptySubsequences: true).map { fold(String($0)) }
    }

    /// One path component against one pattern component: `*` matches any run of characters inside the component, the rest is literal.
    static func componentMatches(_ component: String, pattern: String) -> Bool {
        if !pattern.contains("*") { return component.unicodeScalars.elementsEqual(pattern.unicodeScalars) }
        let text = Array(component.unicodeScalars)
        let pieces = pattern.unicodeScalars.split(separator: "*", omittingEmptySubsequences: false).map { Array($0) }
        guard let first = pieces.first, let last = pieces.last else { return false }
        guard text.count >= first.count + last.count, Array(text[0..<first.count]) == first,
              Array(text[(text.count - last.count)...]) == last else { return false }
        var position = first.count
        let limit = text.count - last.count
        for piece in pieces.dropFirst().dropLast() where !piece.isEmpty {
            var found: Int?
            var start = position
            while start + piece.count <= limit {
                if Array(text[start..<start + piece.count]) == piece { found = start; break }
                start += 1
            }
            guard let at = found else { return false }
            position = at + piece.count
        }
        return position <= limit
    }

    static func matches(path: String, roots: [String], home: String = NSHomeDirectory()) -> Bool {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        guard let real = resolved(path, home: home) else { return false }
        let actual = components(real)
        for root in roots {
            if root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let realRoot = resolved(root, home: home) else { continue }
            let pattern = components(realRoot)
            if pattern.isEmpty || pattern.count > actual.count { continue }
            if zip(actual, pattern).allSatisfy({ componentMatches($0, pattern: $1) }) { return true }
        }
        return false
    }

    /// nil roots = no restriction (true); an empty list matches nothing.
    static func allows(path: String, roots: [String]?, home: String = NSHomeDirectory()) -> Bool {
        guard let roots = roots else { return true }
        return matches(path: path, roots: roots, home: home)
    }
}

/// The allow-list of LOCAL_ARCHIVE_DIR (pipeline/mcap/policy.py `local_archive_ok`): realpath under SUPPORT_DIR or inside a
/// policy `archive.local_roots` entry, no symlink in the path (except the macOS /var /tmp /etc firmlinks), same device as the home
/// directory. `reason`: ok | empty-path | bad-path | symlink-in-path | outside-allowed-roots | different-device.
enum LocalArchiveCheck {
    static let systemSymlinks: Set<String> = ["var", "tmp", "etc"]

    static func verdict(path: String, supportDir: String, extraRoots: [String], home: String = NSHomeDirectory(),
                        device: (String) -> UInt64? = LocalArchiveCheck.deviceOf) -> (ok: Bool, reason: String) {
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (false, "empty-path") }
        guard let real = ArchiveRootMatcher.resolved(path, home: home) else { return (false, "bad-path") }
        var expanded = path
        if path == "~" { expanded = home } else if path.hasPrefix("~/") { expanded = home + "/" + path.dropFirst(2) }
        let absolute = RealPath.lexical(expanded)
        let head = absolute.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let aliased = systemSymlinks.contains(head) ? "/private" + absolute : absolute
        if real != absolute && real != aliased { return (false, "symlink-in-path") }
        var inside = false
        if !supportDir.isEmpty {
            guard let base = ArchiveRootMatcher.resolved(supportDir, home: home) else { return (false, "bad-path") }
            let b = ArchiveRootMatcher.components(base)
            let mine = ArchiveRootMatcher.components(real)
            inside = !b.isEmpty && mine.count >= b.count && Array(mine[0..<b.count]) == b
        }
        if !inside && !extraRoots.isEmpty { inside = ArchiveRootMatcher.matches(path: real, roots: extraRoots, home: home) }
        if !inside { return (false, "outside-allowed-roots") }
        guard let homeDevice = device(home), let archiveDevice = device(nearestExisting(real)), homeDevice == archiveDevice else {
            return (false, "different-device")
        }
        return (true, "ok")
    }

    static func nearestExisting(_ path: String) -> String {
        var probe = path
        while !probe.isEmpty && probe != "/" && !FileManager.default.fileExists(atPath: probe) {
            probe = (probe as NSString).deletingLastPathComponent
        }
        return probe.isEmpty ? "/" : probe
    }

    static func deviceOf(_ path: String) -> UInt64? {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(bitPattern: Int64(st.st_dev)) : nil
    }
}

// MARK: - What is true for the next meeting

/// The five-lane facts the menu and the notifications state, computed from the policy, the flag and the settings. Only statements that
/// are true: with the Drive lane open the m4a files ARE uploaded, so there is no 'audio never leaves this Mac' line. The
/// ASR line says what is POSSIBLE (an engine that is configured and allowed); consent is checked by the pipeline, not here.
struct EffectiveLanes: Equatable {
    var asr: String                 // "this-mac" | "company-server" | "azure-kr" | "clova-kr" | "chosen-server" (an OpenAI-style server the user named) | "local-only"
    var note: Bool                  // meeting note (the LLM lane)
    var calendar: Bool
    var archive: String             // "org-folder" | "this-mac"
    var orgManaged: Bool = false    // a policy exists: the folder is the team drive (otherwise the personal Google Drive folder)

    /// The `asr` word of an engine word when the policy lets that engine be used at all (its lane is open and it is on the allowed list); nil = it cannot
    /// be used, whatever consent exists. The one place that says so: `compute` and the Settings window's 'What leaves this Mac' box both ask it.
    static func destination(of word: String, policy: OrgPolicy) -> String? {
        func engineAllowed(_ engine: String) -> Bool { policy.allowedEngines?.contains(engine) ?? true }
        if (word == "remote" || word == "auto") && policy.laneAllowed("asr_remote") && engineAllowed("remote") { return "company-server" }
        if word == "azure" && policy.laneAllowed("asr_cloud") && engineAllowed("azure") { return "azure-kr" }
        if word == "clova" && policy.laneAllowed("asr_cloud") && engineAllowed("clova") { return "clova-kr" }
        if word == "openai-compat" && policy.laneAllowed("asr_cloud") && engineAllowed("openai-compat") { return "chosen-server" }
        return nil
    }

    static func compute(policy: OrgPolicy, localOnly: Bool, settings: PrivacySettings, archiveDir: URL, home: String = NSHomeDirectory()) -> EffectiveLanes {
        let open = !localOnly && !policy.forcesLocalOnly
        var asr = "this-mac"
        if !open {
            asr = "local-only"
        } else {
            let named = [settings.asrEngine, settings.asrFallback]
            // a server the user named is the destination nobody can check: it is the one the line names when it is primary or fallback
            for word in named.contains("openai-compat") ? ["openai-compat"] + named : named {
                if let destination = destination(of: word, policy: policy) { asr = destination; break }
            }
        }
        var driveOpen = open && policy.laneAllowed("drive")
        if driveOpen && policy.isCompany && !settings.archiveDirExplicit { driveOpen = false }
        if driveOpen && !ArchiveRootMatcher.allows(path: archiveDir.path, roots: policy.archiveAllowedRoots, home: home) { driveOpen = false }
        return EffectiveLanes(asr: asr, note: open && policy.laneAllowed("llm"), calendar: open && policy.laneAllowed("calendar") && settings.calendarLookup,
                              archive: driveOpen ? "org-folder" : "this-mac", orgManaged: policy.isEnforced)
    }

    private var asrWord: String {
        switch asr {
        case "company-server": return tr("company server", ko: "회사 서버")
        case "azure-kr": return tr("Azure Korea", ko: "Azure 한국")
        case "clova-kr": return tr("CLOVA", ko: "CLOVA")                      // short: the summary line must stay under 45 characters
        case "chosen-server": return tr("a server you chose", ko: "직접 정한 서버")
        default: return tr("this Mac", ko: "이 Mac")
        }
    }

    private var archiveWord: String {
        if archive == "org-folder" { return orgManaged ? tr("team drive", ko: "팀 드라이브") : tr("archive folder", ko: "Google Drive") }
        return tr("this Mac", ko: "이 Mac")
    }

    /// e.g. "This meeting: transcription=this Mac · note=on · archive=team drive" ("이 회의: 전사=이 Mac · 회의록=켜짐 · 보관=팀 드라이브"; short: the notification around it has 100 characters)
    var summaryText: String {
        return tr("This meeting: transcription=\(asrWord) · note=\(note ? "on" : "off") · archive=\(archiveWord)",
                  ko: "이 회의: 전사=\(asrWord) · 회의록=\(note ? "켜짐" : "꺼짐") · 보관=\(archiveWord)")
    }

    /// The idle info lines of the menu: the transcription line and the archive line.
    var idleLinesText: [String] {
        let transcription: String
        switch asr {
        case "company-server": transcription = tr("Transcription: external engine possible (company server)", ko: "전사: 외부 엔진 가능 (회사 서버)")
        case "azure-kr": transcription = tr("Transcription: external engine possible (Azure Korea)", ko: "전사: 외부 엔진 가능 (Azure 한국)")
        case "clova-kr": transcription = tr("Transcription: external engine possible (NAVER CLOVA)", ko: "전사: 외부 엔진 가능 (NAVER CLOVA)")
        case "chosen-server": transcription = tr("Transcription: external engine possible (a server you chose)", ko: "전사: 외부 엔진 가능 (직접 정한 서버)")
        case "local-only": transcription = tr("Transcription: local only", ko: "전사: 로컬 전용")
        default: transcription = tr("Transcription: on this Mac (no external transcription)", ko: "전사: 이 Mac에서 처리 (외부 전사 없음)")
        }
        let storage = archive == "org-folder" ? tr("Archive: \(archiveWord) (synced)", ko: "보관: \(archiveWord)(동기화)") : tr("Archive: this Mac only", ko: "보관: 이 Mac 전용")
        return [transcription, storage]
    }
}

// MARK: - Pipeline contract and runtime trust (checked by the launcher before it starts python)

enum PipelineContract {
    static let minVersion = "0.2.0"

    /// '0.10.0' -> [0, 10, 0]: ASCII digits and dots only (1 to 4 numbers of at most 6 digits), surrounding ASCII spaces trimmed.
    static func parseVersion(_ text: String) -> [Int]? {
        let t = text.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var out: [Int] = []
        for part in parts {
            guard (1...6).contains(part.utf8.count), part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(part) else { return nil }
            out.append(n)
        }
        return out
    }

    /// a < b, the shorter tuple padded with zeros ([0, 2] == [0, 2, 0]).
    static func versionLess(_ a: [Int], _ b: [Int]) -> Bool {
        let width = max(a.count, b.count)
        let x = a + Array(repeating: 0, count: width - a.count)
        let y = b + Array(repeating: 0, count: width - b.count)
        return x.lexicographicallyPrecedes(y)
    }

    /// The pipeline version the launcher must see before it starts python. nil = no requirement: the personal install without a policy
    /// (and a session that is not local-only) keeps working with an older pipeline. A policy (valid or locked), the marker, or a session
    /// with local_only true require max(0.2.0, policy.min_pipeline_version).
    static func required(policy: OrgPolicy, sessionLocalOnly: Bool?) -> String? {
        guard policy.isEnforced || sessionLocalOnly == true else { return nil }
        guard let minimum = policy.minPipelineVersion, let want = parseVersion(minimum), let base = parseVersion(minVersion) else { return minVersion }
        return versionLess(base, want) ? minimum : minVersion
    }

    /// Is `version` at least `required`? An unreadable version is not.
    static func satisfied(version: String, required: String) -> Bool {
        guard let have = parseVersion(version), let want = parseVersion(required) else { return false }
        return !versionLess(have, want)
    }
}

/// The pipeline's own version (`python -m mcap --version`), cached per (python, pipeline/mcap/__init__.py mtime) so that a launch does
/// not start an extra python every time. The runner is injectable: tests never start a real python.
final class PipelineVersionProbe {
    typealias Runner = (_ python: URL, _ pipelineDir: URL) -> String?     // the stdout text, nil = could not run

    static let shared = PipelineVersionProbe()

    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    /// "mcap 0.2.0" (argparse's --version output) -> "0.2.0"
    static func parse(_ output: String) -> String? {
        let words = output.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard let last = words.last, PipelineContract.parseVersion(last) != nil else { return nil }
        return last
    }

    func version(pythonBin: URL, projectDir: URL, runner: Runner? = nil) -> String? {
        let pipelineDir = projectDir.appendingPathComponent("pipeline", isDirectory: true)
        let marker = pipelineDir.appendingPathComponent("mcap/__init__.py")
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(pythonBin.path)|\(pipelineDir.path)|\(stamp)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let output = (runner ?? PipelineVersionProbe.runPython)(pythonBin, pipelineDir)
        let version = output.flatMap { PipelineVersionProbe.parse($0) }
        lock.lock(); cache[key] = version; lock.unlock()
        return version
    }

    /// `python -m mcap --version` in the pipeline folder with a minimal environment, 15 s at most.
    static func runPython(_ python: URL, _ pipelineDir: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: python.path) else { return nil }
        let result = runCapturing(python, ["-m", "mcap", "--version"], env: minimalToolEnvironment().merging(["PYTHONDONTWRITEBYTECODE": "1"]) { a, _ in a },
                                  timeout: 15, cwd: pipelineDir)
        guard let r = result, r.status == 0 else { return nil }
        return r.stdout
    }
}

/// Company profile with `runtime.root` (and a locked policy that does not say personal: `OrgPolicy.pinnedRuntimeRoot`): python and the
/// pipeline must live under that root-owned folder. Their realpath has to be inside the root and every component of
/// the real path must be owned by root and not writable by group or others (so a standard user cannot swap the code the pipeline runs).
/// Other profiles, the personal install and a company policy without a runtime root: always ok.
enum RuntimeTrust {
    enum Verdict: Equatable { case ok, untrusted(String) }

    static func verify(pythonBin: URL, projectDir: URL, policy: OrgPolicy, fileInfo: (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile,
                       realpath: (String) -> String = { RealPath.resolve($0) }) -> Verdict {
        guard let root = policy.pinnedRuntimeRoot else { return .ok }
        let rootReal = ArchiveRootMatcher.components(realpath(root))
        let targets = [("python", pythonBin.path), ("pipeline", projectDir.appendingPathComponent("pipeline").path)]
        for (name, path) in targets {
            let real = realpath(path)
            let parts = real.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let folded = parts.map { ArchiveRootMatcher.fold($0) }
            guard !rootReal.isEmpty, folded.count >= rootReal.count, Array(folded[0..<rootReal.count]) == rootReal else {
                return .untrusted("\(name): outside the runtime root")
            }
            var current = "/"
            var chain = [current]
            for part in parts { current = (current == "/" ? "" : current) + "/" + part; chain.append(current) }
            for step in chain {
                guard let info = fileInfo(URL(fileURLWithPath: step)), !info.statError else { return .untrusted("\(name): cannot be inspected") }
                if info.uid != 0 { return .untrusted("\(name): not owned by root") }
                if info.mode & 0o022 != 0 { return .untrusted("\(name): writable by group or others") }
            }
        }
        return .ok
    }
}

// MARK: - The per-meeting local-only flag

struct LocalOnlyValue: Equatable {
    var value: Bool
    var source: String          // default | config-default | policy-default | policy-invalid | menu | menu-after-stop | policy-lock
    var locked: Bool
}

enum LocalOnlyResolver {
    /// The start value of a new recording, first match wins: a locked or invalid policy forces true (policy-invalid / policy-lock),
    /// `local_only.default` true (policy-default), LOCAL_ONLY_DEFAULT true (config-default), else false.
    static func initial(policy: OrgPolicy, settings: PrivacySettings) -> LocalOnlyValue {
        if policy.isLocked { return LocalOnlyValue(value: true, source: "policy-invalid", locked: true) }
        if policy.isValid && policy.localOnlyLocked { return LocalOnlyValue(value: true, source: "policy-lock", locked: true) }
        if policy.isValid && policy.localOnlyDefault { return LocalOnlyValue(value: true, source: "policy-default", locked: false) }
        if settings.localOnlyDefault { return LocalOnlyValue(value: true, source: "config-default", locked: false) }
        return LocalOnlyValue(value: false, source: "default", locked: false)
    }

    /// The value after the user asked for `want` (source: menu | menu-after-stop). nil = refused: relaxing is not possible while the
    /// policy locks the flag. Turning it ON is always possible; asking for the value it already has changes nothing.
    static func toggled(from: LocalOnlyValue, to want: Bool, policy: OrgPolicy, source: String) -> LocalOnlyValue? {
        if from.value == want { return from }
        if want { return LocalOnlyValue(value: true, source: source.isEmpty ? "menu" : source, locked: false) }
        if from.locked || policy.forcesLocalOnly { return nil }
        return LocalOnlyValue(value: false, source: source.isEmpty ? "menu" : source, locked: false)
    }
}

/// Separate from SessionRecordingExtras so that the existing fakes still compile. A recorder that implements it writes `local_only` and
/// `local_only_source` into session.json ONLY after `setLocalOnly` was called (the exact-key assertion of the capture self test).
protocol SessionRecordingPrivacy: AnyObject {
    func setLocalOnly(_ value: Bool, source: String) -> Bool      // false = not persisted
    var localOnly: Bool? { get }
}

// MARK: - session.json patch and the private sidecar

/// Only the Swift app writes session.json. After the recording has stopped the controller patches `local_only` and `local_only_source`
/// (serialized on its queue): read, change exactly those two keys, write atomically, read back and compare. Every other key is kept.
enum SessionJSONPatch {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]    // like Recorder

    /// How the new bytes reach session.json: an atomic replace (a temp file in the same folder, then a rename), so a reader never sees a
    /// half-written file and a failed write leaves the old one as it was. The self test swaps in writers that fail, write short or write
    /// something else, to see that the read-back below is what stops a bad patch.
    static let atomicWrite: (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }

    /// `now` is only for the log line: session.json carries just the two keys, the history goes to SessionPrivateLog.
    /// `write` is the seam of the self test; production always uses `atomicWrite`.
    static func apply(localOnly: Bool, source: String, to sessionDir: URL, now: Date = Date(),
                      write: (Data, URL) throws -> Void = SessionJSONPatch.atomicWrite) throws {
        guard !source.isEmpty, source.utf8.count <= 40, source.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F || $0 == 0x3A }) else {
            throw Failure(message: "local_only_source must be 1-40 characters of [a-z0-9_:-]")
        }
        let file = sessionDir.appendingPathComponent("session.json")
        var st = stat()
        guard lstat(file.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw Failure(message: "session.json is missing or not a regular file") }
        guard let original = FileManager.default.contents(atPath: file.path), let before = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
            throw Failure(message: "session.json is not a JSON object")
        }
        var patched = before
        patched["local_only"] = localOnly
        patched["local_only_source"] = source
        let data = try JSONSerialization.data(withJSONObject: patched, options: options)
        try write(data, file)
        // Read back: the file must say what was written and keep everything else (another writer may have been faster).
        guard let written = FileManager.default.contents(atPath: file.path), let after = (try? JSONSerialization.jsonObject(with: written)) as? [String: Any],
              let flag = after["local_only"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue == localOnly,
              after["local_only_source"] as? String == source else {
            throw Failure(message: "session.json does not hold the new local_only after the write")
        }
        var rest = after
        rest.removeValue(forKey: "local_only"); rest.removeValue(forKey: "local_only_source")
        var expected = before
        expected.removeValue(forKey: "local_only"); expected.removeValue(forKey: "local_only_source")
        guard NSDictionary(dictionary: rest).isEqual(to: expected) else { throw Failure(message: "session.json changed in other keys during the patch") }
        Log.info("session.json patched: local_only=\(localOnly) source=\(source) at \(ShellUtil.iso8601(now))")
    }
}

/// SUPPORT_DIR/session-private/<session id>.json: what must not reach Drive (the local_only history, mute spans). Swift writes it, nobody
/// else; the folder is 0700 and the file 0600. Each list keeps the newest `maxEntries` entries.
enum SessionPrivateLog {
    static let historyKey = "local_only_history"
    static let historyLimit = 20
    /// One read-modify-write of the file at a time, whatever the session and the key: the history (controller queue) and the mute spans
    /// (recorder queue) are written from different threads into the SAME file, and without this an append silently loses entries (the
    /// local_only audit history among them).
    private static let writeLock = NSLock()

    static func isPlainName(_ session: String) -> Bool {
        return !session.isEmpty && session.utf8.count <= 200 && session != "." && session != ".."
            && session.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F }
    }

    static func file(session: String, supportDir: URL) -> URL? {
        guard isPlainName(session) else { return nil }
        return supportDir.appendingPathComponent("session-private", isDirectory: true).appendingPathComponent("\(session).json")
    }

    static func read(session: String, supportDir: URL) -> [String: Any]? {
        guard let url = file(session: session, supportDir: supportDir), let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Appends `entry` to the list under `key` and keeps the last `maxEntries`. Other keys of the file stay. False = not written.
    @discardableResult
    static func append(session: String, supportDir: URL, entry: [String: Any], key: String = historyKey, maxEntries: Int = historyLimit) -> Bool {
        guard let url = file(session: session, supportDir: supportDir), JSONSerialization.isValidJSONObject(entry), maxEntries > 0 else {
            Log.warn("session-private: refused an entry (bad session id or entry)")
            return false
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)       // also when the folder was there before
            var object = read(session: session, supportDir: supportDir) ?? [:]
            var list = object[key] as? [Any] ?? []
            list.append(entry)
            if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
            object[key] = list
            let data = try JSONSerialization.data(withJSONObject: object, options: SessionJSONPatch.options)
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            Log.warn("session-private: cannot write \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - policy-status

/// `<short name> policy-status [--json] [--console-user]`: the policy state, the start value of the flag, the lanes and the contract
/// and trust verdicts. Content-free: no meeting title, no session id, no path of a meeting. MDM runs it as root, so --console-user reads
/// the HOME and the config.env of the user who is logged in at the console instead of root's.
struct PolicyStatusHooks {
    var loadPolicy: () -> OrgPolicy = { OrgPolicy.load() }
    var consoleUser: () -> (name: String, home: String)? = { PolicyStatus.consoleUser() }
    var pipelineVersion: (AppConfig) -> String? = { PipelineVersionProbe.shared.version(pythonBin: $0.pythonBin, projectDir: $0.projectDir) }
    var fileInfo: (URL) -> OrgPolicy.FileInfo? = OrgPolicy.statFile
    var currentHome: String = NSHomeDirectory()
    var configFile: URL = AppConfig.configFilePath
    var effectiveUID: uid_t = geteuid()
}

enum PolicyStatus {
    /// The user logged in at the console (the owner of /dev/console), nil at the login window or when it cannot be told.
    static func consoleUser() -> (name: String, home: String)? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, st.st_uid != 0, let pw = getpwuid(st.st_uid), let name = pw.pointee.pw_name, let dir = pw.pointee.pw_dir else { return nil }
        return (String(cString: name), String(cString: dir))
    }

    /// `~` in config values means the console user's home in --console-user mode (this process may run as root).
    static func expandTilde(_ values: [String: String], home: String) -> [String: String] {
        var out = values
        for (key, value) in values {
            if value == "~" { out[key] = home } else if value.hasPrefix("~/") { out[key] = home + "/" + value.dropFirst(2) }
        }
        return out
    }

    /// May `python -m mcap --version` be started? Never as root from a place a user can write: MDM runs `policy-status` as root, and a
    /// user's PYTHON_BIN, venv or pipeline folder would then run with root's rights. Root only starts a python that RuntimeTrust has
    /// verified (company runtime under a root-owned runtime.root, also the one a locked policy keeps); any other user may start his own.
    static func mayProbePipeline(effectiveUID: uid_t, policy: OrgPolicy, trust: RuntimeTrust.Verdict) -> Bool {
        if effectiveUID != 0 { return true }
        return policy.pinnedRuntimeRoot != nil && trust == .ok
    }

    static func report(policy: OrgPolicy, settings: PrivacySettings, config: AppConfig, pipelineVersion: String?, trust: RuntimeTrust.Verdict,
                       home: String) -> [String: Any] {
        let start = LocalOnlyResolver.initial(policy: policy, settings: settings)
        let effective = EffectiveLanes.compute(policy: policy, localOnly: start.value, settings: settings, archiveDir: config.archiveDir, home: home)
        var policyBlock: [String: Any] = [
            "state": { () -> String in switch policy.state { case .absent: return "absent"; case .valid: return "valid"; case .invalid: return "invalid" } }(),
            "profile": policy.profile,
            "revision": policy.revision.map { $0 as Any } ?? NSNull(),
            "sha256_8": policy.sha256Prefix.map { $0 as Any } ?? NSNull(),
            "locked_reason": policy.lockedReason.map { $0 as Any } ?? NSNull(),
            "min_pipeline_version": policy.minPipelineVersion.map { $0 as Any } ?? NSNull(),
            "recording_enabled": policy.recordingEnabled,
            "local_only_locked": policy.forcesLocalOnly,
        ]
        policyBlock["runtime_root_set"] = policy.pinnedRuntimeRoot != nil
        let required = PipelineContract.required(policy: policy, sessionLocalOnly: nil)
        var contract: [String: Any] = ["required": required.map { $0 as Any } ?? NSNull(), "pipeline_version": pipelineVersion.map { $0 as Any } ?? NSNull()]
        if let need = required {
            if let have = pipelineVersion {
                let ok = PipelineContract.satisfied(version: have, required: need)
                contract["satisfied"] = ok
                contract["pipeline_too_old"] = !ok
            } else {
                contract["satisfied"] = NSNull()
                contract["pipeline_too_old"] = NSNull()
            }
        } else {
            contract["satisfied"] = true
            contract["pipeline_too_old"] = false
        }
        var runtime: [String: Any] = ["verdict": "ok", "reason": NSNull()]
        if case .untrusted(let why) = trust { runtime = ["verdict": "untrusted", "reason": why] }
        return [
            "schema": 1,
            "app_version": AppInfo.version,
            "policy": policyBlock,
            "local_only_start": ["value": start.value, "source": start.source, "locked": start.locked],
            "lanes": policy.lanes,
            "lane_reasons": policy.laneReasons,
            "effective": ["asr": effective.asr, "note": effective.note, "calendar": effective.calendar, "archive": effective.archive],
            "contract": contract,
            "runtime": runtime,
            "settings_warnings": settings.warnings.count,
        ]
    }

    static func jsonText(_ report: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func humanText(_ report: [String: Any]) -> String {
        let policy = report["policy"] as? [String: Any] ?? [:]
        let start = report["local_only_start"] as? [String: Any] ?? [:]
        let lanes = report["lanes"] as? [String: String] ?? [:]
        let contract = report["contract"] as? [String: Any] ?? [:]
        let runtime = report["runtime"] as? [String: Any] ?? [:]
        var lines: [String] = []
        var head = "policy: \(policy["state"] as? String ?? "?")"
        if (policy["state"] as? String) != "absent" {
            head += " (profile \(policy["profile"] as? String ?? "?"), revision \(policy["revision"] as? Int ?? 0), sha256 \(policy["sha256_8"] as? String ?? "-"))"
        }
        lines.append(head)
        if let reason = policy["locked_reason"] as? String { lines.append("locked: \(reason)") }
        lines.append("recording: \((policy["recording_enabled"] as? Bool ?? true) ? "enabled" : "DISABLED by policy")")
        lines.append("local-only start value: \(start["value"] as? Bool ?? false) (\(start["source"] as? String ?? "?")\((start["locked"] as? Bool ?? false) ? ", locked" : ""))")
        lines.append("lanes: " + OrgPolicy.lanesInOrder.map { "\($0)=\(lanes[$0] ?? "?")" }.joined(separator: " "))
        let required = contract["required"] as? String
        let have = contract["pipeline_version"] as? String
        lines.append("pipeline: version \(have ?? "unknown"), required \(required ?? "none")" + ((contract["pipeline_too_old"] as? Bool) == true ? "  -> TOO OLD" : ""))
        lines.append("runtime: \(runtime["verdict"] as? String ?? "?")" + ((runtime["reason"] as? String).map { " (\($0))" } ?? ""))
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Runs the command; `arguments` are what follows `policy-status`. Exit code 0 = reported, 1 = nothing to report on (no console user),
/// 2 = unknown option. Writes no app.log line (see main.swift) and nothing outside stdout/stderr.
func runPolicyStatus(arguments: [String], hooks: PolicyStatusHooks = PolicyStatusHooks(), out: (String) -> Void = { print($0, terminator: "") },
                     err: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }) -> Int32 {
    var json = false
    var console = false
    for argument in arguments {
        switch argument {
        case "--json": json = true
        case "--console-user": console = true
        default:
            err("policy-status: unknown option '\(argument)' (usage: policy-status [--json] [--console-user])\n")
            return 2
        }
    }
    var home = hooks.currentHome
    var configFile = hooks.configFile
    if console {
        guard let user = hooks.consoleUser() else {
            err("policy-status: no user is logged in at the console\n")
            return 1
        }
        home = user.home
        configFile = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MeetingCapture/config.env")
    }
    let policy = hooks.loadPolicy()
    var values: [String: String] = [:]
    if let data = FileManager.default.contents(atPath: configFile.path), let text = String(data: data, encoding: .utf8) {
        values = AppConfig.parseEnvText(text)
    }
    PolicyLayers.apply(&values, policy: policy)
    if console {
        values = PolicyStatus.expandTilde(values, home: home)
        let support = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MeetingCapture", isDirectory: true)
        if values["SUPPORT_DIR"] == nil { values["SUPPORT_DIR"] = support.path }
        if values["PROJECT_DIR"] == nil { values["PROJECT_DIR"] = URL(fileURLWithPath: home).appendingPathComponent("Developer/meeting-capture").path }
        if values["PYTHON_BIN"] == nil { values["PYTHON_BIN"] = support.appendingPathComponent("venv/bin/python").path }
    }
    let config = AppConfig.build(from: values, source: configFile.path)
    let settings = PrivacySettings.build(from: values, supportDir: config.supportDir, source: configFile.path)
    let trust = RuntimeTrust.verify(pythonBin: config.pythonBin, projectDir: config.projectDir, policy: policy, fileInfo: hooks.fileInfo)
    // The pipeline version costs a process: only when something requires one, and never as root from a user-writable place.
    let wantsVersion = PipelineContract.required(policy: policy, sessionLocalOnly: nil) != nil
    let version = wantsVersion && PolicyStatus.mayProbePipeline(effectiveUID: hooks.effectiveUID, policy: policy, trust: trust) ? hooks.pipelineVersion(config) : nil
    let report = PolicyStatus.report(policy: policy, settings: settings, config: config, pipelineVersion: version, trust: trust, home: home)
    out(json ? PolicyStatus.jsonText(report) + "\n" : PolicyStatus.humanText(report))
    return 0
}
