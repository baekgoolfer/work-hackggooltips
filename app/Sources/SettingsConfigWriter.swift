import Foundation
import Darwin

// =====================================================================================
// Writing config.env from the Settings window.
//
//   ConfigEnvEditor   a pure function over the text of the file: update, insert or remove given keys and keep every other line, comment, blank
//                     line, unknown key, line ending and the quoting style of the lines it edits byte for byte. The result is parsed again by
//                     BOTH parsers (Config.swift `parseEnvText`, and a mirror of pipeline/mcap/config.py `parse_env_text`): it must hold exactly the
//                     intended values and change nothing else, or nothing is written.
//   ConfigEnvWriter   the file side: a temp file next to config.env (0600) renamed over it (atomic), a timestamped backup first (the last five
//                     `config.env.bak-settings-*` are kept), a failure at any step leaves the old file untouched.
//
// A secret is never part of this: API keys go to the macOS Keychain only (SettingsKeychain.swift) and nothing in config.env refers to them.
// =====================================================================================

enum ConfigEnvEditor {
    struct Failure: Error, Equatable {
        var message: String
    }

    static let addedHeader = "# Added by the Settings window"

    // MARK: Checks on one value (structure only; what a value MEANS for its key is SettingsValue's business)

    /// Why `value` cannot be written as the value of a line of config.env, or nil. Both parsers must read it back unchanged.
    static func structuralProblem(key: String, value: String) -> String? {
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return tr("a value cannot contain a line break or another control character", ko: "값에는 줄바꿈이나 다른 제어 문자를 넣을 수 없어요")
        }
        if value != value.trimmingCharacters(in: .whitespacesAndNewlines) {
            return tr("a value cannot start or end with a blank", ko: "값은 공백으로 시작하거나 끝날 수 없어요")
        }
        if SettingsValue.hasCommentTrigger(value) {
            return tr("a value cannot contain ' #' or start with #: the rest would be read as a comment", ko: "값에 ' #'을 넣거나 #로 시작할 수 없어요: 뒤가 주석으로 읽혀요")
        }
        if SettingsValue.hasQuoteAtEdge(value) {
            return tr("a value cannot start or end with a quote character", ko: "값은 따옴표로 시작하거나 끝날 수 없어요")
        }
        if value.range(of: "^[A-Z][A-Z0-9_]*=", options: .regularExpression) != nil {
            return tr("a value cannot look like another KEY=VALUE line", ko: "값이 다른 KEY=VALUE 줄처럼 보이면 안 돼요")
        }
        return nil
    }

    static func isValidKey(_ key: String) -> Bool {
        return key.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil
    }

    // MARK: Apply

    /// `changes`: a value = set the key, nil = remove it (every active line of it). The last active line of a key that is set is rewritten (the parsers
    /// let the last one win); a key without a line is appended at the end under one header comment.
    static func apply(_ changes: [ConfigChange], to text: String) -> Result<String, Failure> {
        func fail(_ en: String, _ ko: String) -> Result<String, Failure> { .failure(Failure(message: tr(en, ko: ko))) }
        var seen = Set<String>()
        for change in changes {
            guard isValidKey(change.key) else { return fail("'\(NotificationText.clip(change.key, 40))' is not a valid key name", "'\(NotificationText.clip(change.key, 40))'은(는) 올바른 키 이름이 아니에요") }
            guard seen.insert(change.key).inserted else { return fail("\(change.key) is changed twice", "\(change.key)이(가) 두 번 바뀌어요") }
            if let value = change.value, let why = structuralProblem(key: change.key, value: value) {
                return .failure(Failure(message: "\(change.key): \(why)"))
            }
        }
        if let odd = unusualLineSeparator(in: text) {
            return fail("config.env contains \(odd): edit it by hand", "config.env에 \(odd)이(가) 있어요: 직접 고쳐 주세요")
        }

        // Lines without their "\n"; a "\r" before it stays at the end of its line.
        var lines = text.components(separatedBy: "\n")
        let endedWithNewline = text.isEmpty || text.unicodeScalars.last == "\n"          // scalars: a Character "\r\n" is not "\n"
        if endedWithNewline { lines.removeLast() }                       // the empty piece after the last "\n"
        let crlf = lines.first?.hasSuffix("\r") ?? false
        var appended: [String] = []

        for change in changes {
            let indices = lines.indices.filter { definition(in: lines[$0])?.key == change.key }
            if let value = change.value {
                if let last = indices.last {
                    lines[last] = rewrite(lines[last], value: value)
                } else {
                    appended.append("\(change.key)=\(value)")
                }
            } else {
                for index in indices.reversed() { lines.remove(at: index) }
            }
        }
        if !appended.isEmpty {
            if !lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == addedHeader }) {
                if !lines.isEmpty, !(lines.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(crlf ? "\r" : "") }
                lines.append(addedHeader + (crlf ? "\r" : ""))
            }
            for line in appended { lines.append(line + (crlf ? "\r" : "")) }
        }
        let terminated = endedWithNewline || !appended.isEmpty
        let result = lines.joined(separator: "\n") + (terminated && !lines.isEmpty ? "\n" : "")

        // The result must hold exactly what was meant, in both parsers, and nothing else may have moved.
        let before = AppConfig.parseEnvText(text), beforePy = parseLikePython(text)
        let after = AppConfig.parseEnvText(result), afterPy = parseLikePython(result)
        for change in changes {
            let expected = change.value
            if after[change.key] != expected || afterPy[change.key] != expected {
                return fail("internal check failed for \(change.key): the file would not read back as intended; nothing was written", "내부 검사 실패 (\(change.key)): 파일이 의도한 대로 읽히지 않아서 아무것도 쓰지 않았어요")
            }
        }
        let touched = Set(changes.map { $0.key })
        if before.filter({ !touched.contains($0.key) }) != after.filter({ !touched.contains($0.key) })
            || beforePy.filter({ !touched.contains($0.key) }) != afterPy.filter({ !touched.contains($0.key) }) {
            return fail("internal check failed: another setting would change; nothing was written", "내부 검사 실패: 다른 설정이 바뀌게 돼서 아무것도 쓰지 않았어요")
        }
        return .success(result)
    }

    // MARK: Line level

    private static func isBlank(_ s: Unicode.Scalar) -> Bool { CharacterSet.whitespaces.contains(s) }

    /// The key of an active "KEY=VALUE" line and the scalar offset right after its first "=" (the same line rules as `AppConfig.parseEnvText`:
    /// blank lines and lines starting with # are no definition; a key is trimmed); nil otherwise. `line` may end in "\r".
    static func definition(in line: String) -> (key: String, valueStart: Int)? {
        var scalars = Array(line.unicodeScalars)
        if scalars.last == "\r" { scalars.removeLast() }
        var i = scalars.first == "\u{FEFF}" ? 1 : 0                       // the BOM of the first line
        while i < scalars.count, isBlank(scalars[i]) { i += 1 }
        if i >= scalars.count || scalars[i] == "#" { return nil }
        guard let eq = scalars[i...].firstIndex(of: "=") else { return nil }
        var keyEnd = eq
        while keyEnd > i, isBlank(scalars[keyEnd - 1]) { keyEnd -= 1 }
        if keyEnd == i { return nil }
        return (String(String.UnicodeScalarView(scalars[i..<keyEnd])), eq + 1)
    }

    /// `line` with the value of its key replaced: everything before the value, the blanks around it, a trailing comment and the quoting style stay.
    static func rewrite(_ line: String, value: String) -> String {
        guard let def = definition(in: line) else { return line }
        var scalars = Array(line.unicodeScalars)
        var cr: [Unicode.Scalar] = []
        if scalars.last == "\r" { cr = [scalars.removeLast()] }
        let prefix = Array(scalars[0..<def.valueStart])
        let rest = Array(scalars[def.valueStart...])
        // an inline comment starts at a '#' that follows a blank (the rule of both parsers; the blank may be the one right after '=')
        var commentAt = rest.count
        var previous: Unicode.Scalar?
        for (k, ch) in rest.enumerated() {
            if ch == "#", let p = previous, p.properties.isWhitespace { commentAt = k; break }
            previous = ch
        }
        let region = Array(rest[0..<commentAt])
        let comment = Array(rest[commentAt...])
        var lead = 0
        while lead < region.count, isBlank(region[lead]) { lead += 1 }
        var trail = region.count
        while trail > lead, isBlank(region[trail - 1]) { trail -= 1 }
        let core = Array(region[lead..<trail])
        var quote: Unicode.Scalar?
        if core.count >= 2, let first = core.first, first == core.last, first == "\"" || first == "'" { quote = first }
        var newValue = Array(value.unicodeScalars)
        if let q = quote, !newValue.contains(q) { newValue = [q] + newValue + [q] }          // a value that contains the quote is written bare: still read back whole
        var out = prefix + Array(region[0..<lead]) + newValue + Array(region[trail...])
        if !comment.isEmpty, let last = out.last, !last.properties.isWhitespace { out.append(" ") }   // never glue the comment to the value
        out += comment + cr
        return String(String.UnicodeScalarView(out))
    }

    /// A line separator that the line rules above do not handle the way the two parsers do (a lone CR, VT, FF, FS/GS/RS, NEL, LS, PS), or nil.
    static func unusualLineSeparator(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            switch s.value {
            case 0x0D where !(i + 1 < scalars.count && scalars[i + 1] == "\n"): return tr("a lone carriage return", ko: "단독 캐리지 리턴")
            case 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029: return tr("an unusual line separator", ko: "특이한 줄 구분 문자")
            default: continue
            }
        }
        return nil
    }

    /// pipeline/mcap/config.py `parse_env_text`: lines split like `splitlines`, `strip()`, '#' comment after a blank (never at index 0), then
    /// `strip().strip('"').strip("'")` (every quote character at either end goes, not one matching pair).
    static func parseLikePython(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func strip(_ s: String, quote: Character) -> String {
            var chars = Substring(s)
            while chars.first == quote { chars = chars.dropFirst() }
            while chars.last == quote { chars = chars.dropLast() }
            return String(chars)
        }
        for raw in text.components(separatedBy: "\n") {
            let line = strip(raw)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            var value = String(line[line.index(after: eq)...])
            let chars = Array(value)
            for i in chars.indices where chars[i] == "#" && i > 0 && chars[i - 1].isWhitespace {
                value = String(chars[0..<i])
                break
            }
            out[strip(key)] = strip(strip(strip(value), quote: "\""), quote: "'")
        }
        return out
    }
}

// MARK: - The file

/// The two steps of the write that a test makes fail on purpose.
struct ConfigFileOps {
    /// Creates `url` exclusively with mode 0600, writes `data`, fsyncs and closes it.
    var writeTemp: (_ data: Data, _ url: URL) throws -> Void = ConfigFileOps.realWriteTemp
    /// rename(2): atomic on one volume.
    var rename: (_ from: URL, _ to: URL) throws -> Void = ConfigFileOps.realRename

    static func realWriteTemp(_ data: Data, _ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += n
            }
        }
        if fsync(fd) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    static func realRename(_ from: URL, _ to: URL) throws {
        if Darwin.rename(from.path, to.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

enum ConfigEnvWriter {
    static let keepBackups = 5

    enum Outcome: Equatable {
        case saved(backup: URL?)
        case failed(String)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    static func backupPrefix(for file: URL) -> String { file.lastPathComponent + ".bak-settings-" }

    static func backupName(for file: URL, now: Date) -> String { backupPrefix(for: file) + stamp.string(from: now) }

    /// The current text of the file: nil when there is none, a failure text when it cannot be read as UTF-8 (it is never overwritten then).
    static func read(_ file: URL) -> (text: String?, problem: String?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return (nil, nil) }
        guard let data = fm.contents(atPath: file.path) else { return (nil, tr("config.env cannot be read", ko: "config.env를 읽을 수 없어요")) }
        guard let text = String(data: data, encoding: .utf8) else { return (nil, tr("config.env is not valid UTF-8: edit it by hand", ko: "config.env가 올바른 UTF-8이 아니에요: 직접 고쳐 주세요")) }
        return (text, nil)
    }

    /// Replaces `file` with `text`: temp file (0600) in the same folder, a backup of the old file, rename, then the backups beyond the last five are
    /// deleted. A symbolic link config.env is written through (its target is replaced, the link stays). Any failure leaves the old file as it was.
    static func save(_ text: String, to file: URL, now: Date = Date(), keep: Int = keepBackups, ops: ConfigFileOps = ConfigFileOps()) -> Outcome {
        let fm = FileManager.default
        var target = file
        if let dest = try? fm.destinationOfSymbolicLink(atPath: file.path) {
            target = URL(fileURLWithPath: dest, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
        }
        let dir = target.deletingLastPathComponent()
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return .failed(tr("the folder of config.env cannot be created", ko: "config.env의 폴더를 만들 수 없어요")) }

        let old = fm.contents(atPath: target.path)
        let temp = dir.appendingPathComponent(".\(target.lastPathComponent).tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        do { try ops.writeTemp(Data(text.utf8), temp) }
        catch {
            try? fm.removeItem(at: temp)
            return .failed(tr("the new config.env could not be written; the old one is unchanged", ko: "새 config.env를 쓰지 못했어요. 기존 파일은 그대로예요"))
        }
        var backup: URL?
        if let old = old {
            var stamp = now
            while fm.fileExists(atPath: dir.appendingPathComponent(backupName(for: target, now: stamp)).path), stamp.timeIntervalSince(now) < 1 { stamp = stamp.addingTimeInterval(0.001) }   // two saves in one millisecond must not share a name
            let url = dir.appendingPathComponent(backupName(for: target, now: stamp))
            do { try ops.writeTemp(old, url) }
            catch {
                try? fm.removeItem(at: temp)
                try? fm.removeItem(at: url)
                return .failed(tr("the backup of config.env could not be written, so nothing was changed", ko: "config.env 백업을 쓰지 못해서 아무것도 바꾸지 않았어요"))
            }
            backup = url
        }
        do { try ops.rename(temp, target) }
        catch {
            try? fm.removeItem(at: temp)
            if let b = backup { try? fm.removeItem(at: b) }
            return .failed(tr("config.env could not be replaced; the old one is unchanged", ko: "config.env를 교체하지 못했어요. 기존 파일은 그대로예요"))
        }
        rotateBackups(in: dir, prefix: backupPrefix(for: target), keep: keep)
        return .saved(backup: backup)
    }

    /// Keeps the newest `keep` files named `<prefix>yyyyMMdd-HHmmss-SSS`; nothing else in the folder is touched.
    static func rotateBackups(in dir: URL, prefix: String, keep: Int) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
            $0.hasPrefix(prefix) && $0.dropFirst(prefix.count).range(of: "^[0-9]{8}-[0-9]{6}-[0-9]{3}$", options: .regularExpression) != nil
        }.sorted(by: >)
        for name in names.dropFirst(max(0, keep)) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }
}
