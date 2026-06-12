import Foundation

struct BackupEntry: Identifiable, Codable {
    var id = UUID()
    let appName: String
    let bundleID: String
    let version: String
    let date: Date
    let totalSize: Int64
    let relativePath: String
    var isDocumentsOnly: Bool = false

    // Optional so old metadata.json files (written before these existed) still
    // decode. Populated from the Rust backup result / _UnboxerManifest.json.
    var fileCount: Int? = nil
    var dirCount: Int? = nil
    var symlinkCount: Int? = nil
    var skippedCount: Int? = nil
    var isPartial: Bool? = nil
    var isIncomplete: Bool? = nil

    var partial: Bool { isPartial ?? false }
    var incomplete: Bool { isIncomplete ?? false }

    var displayDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    var displaySize: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: totalSize)
    }

    /// One-line capture summary, or nil for legacy backups without stats.
    var statsLine: String? {
        guard let files = fileCount else { return nil }
        var parts = ["\(files) files"]
        if let d = dirCount { parts.append("\(d) folders") }
        if let s = symlinkCount, s > 0 { parts.append("\(s) links") }
        if let sk = skippedCount, sk > 0 { parts.append("\(sk) skipped") }
        return parts.joined(separator: " \u{2022} ")
    }

    /// User-facing message after a backup, with a hint when it was incomplete.
    func successMessage(appName: String) -> String {
        guard partial else { return "Backup of \(appName) completed." }
        let n = skippedCount ?? 0
        var msg = "Backup of \(appName) completed \u{2014} \(n) item(s) skipped."
        if incomplete {
            msg += " The connection dropped partway; reconnect and back up again for a complete copy."
        } else if n >= max(fileCount ?? 0, 1) {
            msg += " Many files were skipped \u{2014} the device may be locked. Unlock it and retry for a complete backup."
        }
        return msg
    }
}

struct FileItem: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date

    var displaySize: String {
        if isDirectory { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }
}
