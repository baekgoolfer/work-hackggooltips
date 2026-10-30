import Foundation

// =====================================================================================
// app.log rotation (config key APP_LOG_MAX_MB; LOG_RETENTION_DAYS for the age).
//
// Today nothing ever shrinks app.log, so the default stays "no rotation": APP_LOG_MAX_MB=0 (the personal install). The company template
// sets 5 MB x 5 and 30 days. `Log` (Types.swift) opens, appends and closes the file for every line, so renaming it between two lines is safe;
// the next line creates a fresh app.log.
//
//   app.log      the active file
//   app.log.1    the previous one (the newest archive) ... app.log.<keep> (the oldest; it falls off at the next rotation)
//
// Nothing here throws or logs: a log that cannot be rotated must never stop the app.
// =====================================================================================

enum LogRotation {
    /// Rotates `file` when it has reached `maxBytes` (0 = never by size) and removes archives beyond `keep` files (keep <= 0: no archive
    /// at all, the full file is removed) or older than `maxAgeDays` (0 = never by age). The active file is never removed by age.
    /// Returns true when the active file was rotated away. `now` is injectable for tests.
    @discardableResult
    static func rotateIfNeeded(file: URL, maxBytes: Int, keep: Int, maxAgeDays: Int, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        pruneArchives(of: file, keep: keep, maxAgeDays: maxAgeDays, now: now)
        guard maxBytes > 0, let attributes = try? fm.attributesOfItem(atPath: file.path), let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= maxBytes else { return false }
        if keep <= 0 {
            try? fm.removeItem(at: file)
            return true
        }
        try? fm.removeItem(at: archive(file, keep))
        if keep > 1 {
            for i in stride(from: keep - 1, through: 1, by: -1) {
                let from = archive(file, i)
                if fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: archive(file, i + 1))
                    try? fm.moveItem(at: from, to: archive(file, i + 1))
                }
            }
        }
        try? fm.removeItem(at: archive(file, 1))
        do { try fm.moveItem(at: file, to: archive(file, 1)) } catch { return false }
        return true
    }

    static func archive(_ file: URL, _ number: Int) -> URL {
        return file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).\(number)")
    }

    /// The archives of `file` that exist: (number, url), oldest number last.
    static func archives(of file: URL) -> [(number: Int, url: URL)] {
        let dir = file.deletingLastPathComponent()
        let prefix = file.lastPathComponent + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [(number: Int, url: URL)] = []
        for name in names where name.hasPrefix(prefix) {
            let tail = name.dropFirst(prefix.count)
            if !tail.isEmpty, tail.utf8.count <= 6, tail.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int(tail), n >= 1 {
                out.append((n, dir.appendingPathComponent(name)))
            }
        }
        return out.sorted { $0.number < $1.number }
    }

    private static func pruneArchives(of file: URL, keep: Int, maxAgeDays: Int, now: Date) {
        let fm = FileManager.default
        for item in archives(of: file) {
            if keep <= 0 || item.number > keep {
                try? fm.removeItem(at: item.url)
                continue
            }
            if maxAgeDays > 0, let modified = (try? fm.attributesOfItem(atPath: item.url.path))?[.modificationDate] as? Date,
               now.timeIntervalSince(modified) > Double(maxAgeDays) * 86_400 {
                try? fm.removeItem(at: item.url)
            }
        }
    }
}
