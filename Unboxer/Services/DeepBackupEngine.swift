import Foundation
import SQLite3

/// Per-app backup for apps that house_arrest cannot vend (production App Store
/// apps). It drives a whole-device mobilebackup2 backup into a working folder,
/// then extracts ONLY the requested app's domain (AppDomain-<bundleID>, plus its
/// app-extension plugin domains) out of Manifest.db into a browsable tree, and
/// deletes the raw device backup. The first run is slow because iOS streams a
/// full snapshot; only the chosen app's data is kept.
class DeepBackupEngine {
    static let shared = DeepBackupEngine()

    private let fm = FileManager.default

    private var backupsDirectoryURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var workDirectoryURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("DeepBackupWork", isDirectory: true)
    }

    func deepBackupApp(bundleID: String, appName: String, version: String) async throws -> BackupEntry {
        // Start from a clean working directory for the raw device backup.
        let workDir = workDirectoryURL
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1) Whole-device backup (heavy) off the main thread.
        let workPath = workDir.path
        let result = try await Task.detached(priority: .userInitiated) {
            try RustIdevice.deepBackup(workDir: workPath)
        }.value
        let deviceBackupDir = URL(fileURLWithPath: result.root)
            .appendingPathComponent(result.source, isDirectory: true)

        // 2) Destination backup folder with a pre-made extracted/ tree so the
        //    existing browser opens it directly (no zip step).
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let relPath = "\(bundleID)_\(timestamp)"
        let backupDir = backupsDirectoryURL.appendingPathComponent(relPath)
        let extractedDir = backupDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractedDir, withIntermediateDirectories: true)

        // 3) Pull just this app's domain out of Manifest.db.
        let stats: ExtractStats
        do {
            stats = try extractDomain(bundleID: bundleID, deviceBackupDir: deviceBackupDir, into: extractedDir)
        } catch {
            try? fm.removeItem(at: workDir)
            try? fm.removeItem(at: backupDir)
            throw error
        }

        // 4) Drop the raw device backup to reclaim space.
        try? fm.removeItem(at: workDir)

        if stats.files == 0 && stats.dirs == 0 {
            try? fm.removeItem(at: backupDir)
            throw NSError(domain: "DeepBackupEngine", code: -30, userInfo: [NSLocalizedDescriptionKey:
                "The device backup contained no data for \(appName). The app may store nothing yet, or its data was excluded from the backup."])
        }

        // 5) Size + metadata.
        let totalSize = directorySize(extractedDir)
        let entry = BackupEntry(
            appName: appName,
            bundleID: bundleID,
            version: version,
            date: Date(),
            totalSize: totalSize,
            relativePath: relPath,
            isDocumentsOnly: false,
            fileCount: stats.files,
            dirCount: stats.dirs,
            symlinkCount: stats.symlinks,
            skippedCount: stats.skipped,
            isPartial: stats.skipped > 0,
            isIncomplete: false
        )
        let metaData = try JSONEncoder().encode(entry)
        try metaData.write(to: backupDir.appendingPathComponent("metadata.json"))
        return entry
    }

    private struct ExtractStats {
        var files = 0
        var dirs = 0
        var symlinks = 0
        var skipped = 0
    }

    /// Reads Manifest.db (plaintext SQLite in an unencrypted backup) and copies
    /// every hashed blob belonging to the app's domains into `extractedDir`
    /// under its real relative path. iOS backup layout: a file with id <fileID>
    /// lives at <deviceBackupDir>/<first 2 hex of fileID>/<fileID>.
    private func extractDomain(bundleID: String, deviceBackupDir: URL, into extractedDir: URL) throws -> ExtractStats {
        let manifestPath = deviceBackupDir.appendingPathComponent("Manifest.db").path
        guard fm.fileExists(atPath: manifestPath) else {
            throw NSError(domain: "DeepBackupEngine", code: -20, userInfo: [NSLocalizedDescriptionKey:
                "Manifest.db not found \u{2014} the device backup did not complete. Make sure the device stays unlocked and backups are not encrypted, then try again."])
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(manifestPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw NSError(domain: "DeepBackupEngine", code: -21, userInfo: [NSLocalizedDescriptionKey:
                "Could not open Manifest.db (the backup may be encrypted)."])
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT fileID, relativePath, flags FROM Files WHERE domain = ?1 OR domain LIKE ?2;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DeepBackupEngine", code: -22, userInfo: [NSLocalizedDescriptionKey:
                "Manifest.db query failed (unexpected backup format)."])
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "AppDomain-\(bundleID)", -1, transient)
        // App-extension (plugin) domains for this app, e.g. AppDomainPlugin-<id>.<ext>
        sqlite3_bind_text(stmt, 2, "AppDomainPlugin-\(bundleID)%", -1, transient)

        var stats = ExtractStats()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let fidC = sqlite3_column_text(stmt, 0) else { continue }
            let fileID = String(cString: fidC)
            let rel = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let flags = sqlite3_column_int(stmt, 2)
            if rel.isEmpty { continue }

            let target = extractedDir.appendingPathComponent(rel)
            switch flags {
            case 2: // directory
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                stats.dirs += 1
            case 1: // regular file
                let blob = deviceBackupDir
                    .appendingPathComponent(String(fileID.prefix(2)))
                    .appendingPathComponent(fileID)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
                    try fm.copyItem(at: blob, to: target)
                    stats.files += 1
                } catch {
                    stats.skipped += 1
                }
            case 4: // symlink
                stats.symlinks += 1
            default:
                stats.skipped += 1
            }
        }
        return stats
    }

    private func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                if let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}
