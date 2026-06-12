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

    func backupApp(bundleID: String, appName: String, version: String) async throws -> String {
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

        let entry = BackupEntry(
            appName: appName,
            bundleID: bundleID,
            version: version,
            date: Date(),
            totalSize: totalSize,
            relativePath: relPath,
            isDocumentsOnly: isDocs
        )
        let metaData = try JSONEncoder().encode(entry)
        try metaData.write(to: backupDir.appendingPathComponent("metadata.json"))

        return zipPath
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
