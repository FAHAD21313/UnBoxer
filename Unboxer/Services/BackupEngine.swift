import Foundation

class BackupEngine {
    static let shared = BackupEngine()

    private let fm = FileManager.default

    private var backupsDirectoryURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    @discardableResult
    func backupApp(bundleID: String, appName: String, version: String) async throws -> BackupEntry {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let relPath = "\(bundleID)_\(timestamp)"
        let backupDir = backupsDirectoryURL.appendingPathComponent(relPath)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let outputDir = backupDir.path

        let json = try await Task.detached(priority: .userInitiated) {
            try RustIdevice.backupApp(bundleId: bundleID, outputDir: outputDir)
        }.value

        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zipPath = dict["zip_path"] as? String
        else {
            throw NSError(domain: "BackupEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing zip_path in response"])
        }

        let totalSize = (try? fm.attributesOfItem(atPath: zipPath)[.size] as? Int64) ?? 0
        let isDocs = (dict["backup_type"] as? String) == "documents"

        // New stats are absent for documents-only backups and for any build
        // running the previous Rust framework, so read them defensively.
        let entry = BackupEntry(
            appName: appName,
            bundleID: bundleID,
            version: version,
            date: Date(),
            totalSize: totalSize,
            relativePath: relPath,
            isDocumentsOnly: isDocs,
            fileCount: dict["file_count"] as? Int,
            dirCount: dict["dir_count"] as? Int,
            symlinkCount: dict["symlink_count"] as? Int,
            skippedCount: dict["skipped_count"] as? Int,
            isPartial: dict["partial"] as? Bool,
            isIncomplete: dict["incomplete"] as? Bool
        )
        let metaData = try JSONEncoder().encode(entry)
        try metaData.write(to: backupDir.appendingPathComponent("metadata.json"))

        return entry
    }

    func ensureExtracted(for entry: BackupEntry) throws -> URL {
        let backupDir = backupsDirectoryURL.appendingPathComponent(entry.relativePath)
        let zipPath = backupDir.appendingPathComponent("\(entry.bundleID).zip")
        let extractedDir = backupDir.appendingPathComponent("extracted")

        if fm.fileExists(atPath: extractedDir.path) {
            return extractedDir
        }

        try RustIdevice.extractZip(zipPath: zipPath.path, outputDir: extractedDir.path)
        return extractedDir
    }
}
