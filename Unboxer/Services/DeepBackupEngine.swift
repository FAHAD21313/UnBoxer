import Foundation
import SQLite3

/// Live progress of a deep backup, delivered to the UI while it runs.
struct DeepBackupProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case waitingForDevice   // snapshot requested, device has not reported progress yet
        case snapshotting       // device streaming the whole-device snapshot
        case extracting         // pulling the app's domain out of Manifest.db
        case finishing          // cleanup + metadata
    }

    var phase: Phase
    /// Overall fraction 0...1 across all phases; nil while indeterminate.
    var fraction: Double?
    /// Bytes received from the device so far (snapshot phase).
    var bytesDone: Int64
    /// Files received from the device so far (snapshot phase).
    var files: Int
    /// Estimated seconds remaining; nil while there is not enough signal.
    var etaSeconds: TimeInterval?
}

/// Estimates time remaining from the device-reported percentage: rate over a
/// sliding window of recent samples, so stalls honestly degrade to "unknown"
/// instead of freezing on a stale number.
private struct DeepBackupETAEstimator {
    private var samples: [(time: Date, percent: Double)] = []

    mutating func update(percent: Double) -> TimeInterval? {
        let now = Date()
        samples.append((now, percent))
        samples.removeAll { now.timeIntervalSince($0.time) > 90 }
        guard let oldest = samples.first, samples.count >= 2 else { return nil }
        let deltaPercent = percent - oldest.percent
        let deltaTime = now.timeIntervalSince(oldest.time)
        guard deltaPercent > 0.05, deltaTime > 2 else { return nil }
        return (100 - percent) / (deltaPercent / deltaTime)
    }
}

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

    /// Diagnostic trace written by the Rust side next to the work dir (so it
    /// survives the work-dir wipe). Used in phase 1 to capture the device's
    /// mobilebackup2 operation sequence. Present only after a deep backup ran.
    var traceLogURL: URL? {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("DeepBackupTrace.log")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// The device snapshot dominates the runtime, so it owns the bar up to
    /// this fraction; local extraction fills the rest.
    private static let snapshotShare = 0.95

    func deepBackupApp(
        bundleID: String,
        appName: String,
        version: String,
        onProgress: @escaping @Sendable (DeepBackupProgress) -> Void = { _ in }
    ) async throws -> BackupEntry {
        // Start from a clean working directory for the raw device backup.
        let workDir = workDirectoryURL
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        onProgress(DeepBackupProgress(phase: .waitingForDevice, fraction: nil, bytesDone: 0, files: 0, etaSeconds: nil))

        // 1) Whole-device backup (heavy) off the main thread, with a sibling
        //    task polling the Rust-side progress atomics until it finishes.
        let workPath = workDir.path
        let backupTask = Task.detached(priority: .userInitiated) {
            try RustIdevice.deepBackup(workDir: workPath)
        }
        let poller = Task.detached {
            var eta = DeepBackupETAEstimator()
            while !Task.isCancelled {
                if let snap = RustIdevice.deepBackupProgress() {
                    if let percent = snap.percent {
                        onProgress(DeepBackupProgress(
                            phase: .snapshotting,
                            fraction: percent / 100.0 * DeepBackupEngine.snapshotShare,
                            bytesDone: snap.bytesDone,
                            files: snap.files,
                            etaSeconds: eta.update(percent: percent)
                        ))
                    } else {
                        onProgress(DeepBackupProgress(
                            phase: .waitingForDevice, fraction: nil,
                            bytesDone: snap.bytesDone, files: snap.files, etaSeconds: nil
                        ))
                    }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        defer { poller.cancel() }

        let result: (root: String, source: String)
        do {
            result = try await backupTask.value
        } catch {
            try? fm.removeItem(at: workDir)
            throw error
        }
        poller.cancel()
        let snapshotStats = RustIdevice.deepBackupProgress()
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
        let deviceBytes = snapshotStats?.bytesDone ?? 0
        let deviceFiles = snapshotStats?.files ?? 0
        onProgress(DeepBackupProgress(
            phase: .extracting, fraction: Self.snapshotShare,
            bytesDone: deviceBytes, files: deviceFiles, etaSeconds: nil
        ))
        let stats: ExtractStats
        do {
            stats = try extractDomain(bundleID: bundleID, deviceBackupDir: deviceBackupDir, into: extractedDir) { done, total in
                guard total > 0 else { return }
                let extractFraction = Double(done) / Double(total)
                onProgress(DeepBackupProgress(
                    phase: .extracting,
                    fraction: Self.snapshotShare + extractFraction * (1.0 - Self.snapshotShare),
                    bytesDone: deviceBytes, files: deviceFiles, etaSeconds: nil
                ))
            }
        } catch {
            try? fm.removeItem(at: workDir)
            try? fm.removeItem(at: backupDir)
            throw error
        }

        // 4) Drop the raw device backup to reclaim space.
        onProgress(DeepBackupProgress(
            phase: .finishing, fraction: 1.0,
            bytesDone: deviceBytes, files: deviceFiles, etaSeconds: nil
        ))
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
    private func extractDomain(
        bundleID: String,
        deviceBackupDir: URL,
        into extractedDir: URL,
        onRow: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> ExtractStats {
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

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let domainFilter = "domain = ?1 OR domain LIKE ?2"
        let exactDomain = "AppDomain-\(bundleID)"
        // App-extension (plugin) domains for this app, e.g. AppDomainPlugin-<id>.<ext>
        let pluginDomains = "AppDomainPlugin-\(bundleID)%"

        // Row count up front so extraction can report a real fraction.
        var totalRows = 0
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM Files WHERE \(domainFilter);", -1, &countStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(countStmt, 1, exactDomain, -1, transient)
            sqlite3_bind_text(countStmt, 2, pluginDomains, -1, transient)
            if sqlite3_step(countStmt) == SQLITE_ROW {
                totalRows = Int(sqlite3_column_int(countStmt, 0))
            }
        }
        sqlite3_finalize(countStmt)

        let sql = "SELECT fileID, relativePath, flags FROM Files WHERE \(domainFilter);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "DeepBackupEngine", code: -22, userInfo: [NSLocalizedDescriptionKey:
                "Manifest.db query failed (unexpected backup format)."])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, exactDomain, -1, transient)
        sqlite3_bind_text(stmt, 2, pluginDomains, -1, transient)

        var stats = ExtractStats()
        var rowsDone = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowsDone += 1
            if rowsDone % 25 == 0 || rowsDone == totalRows {
                onRow(rowsDone, totalRows)
            }
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
