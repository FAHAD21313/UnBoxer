import Foundation

class BackupViewModel: ObservableObject {
    @Published var backups: [BackupEntry] = []
    @Published var selectedBackup: BackupEntry?
    @Published var currentDirectory: URL?
    @Published var directoryContents: [FileItem] = []
    @Published var showDeleteConfirmation = false
    @Published var entryToDelete: BackupEntry?
    @Published var isExtracting = false
    @Published var extractError: String?
    @Published var isBackingUp = false
    @Published var backupError: String?
    @Published var backupSuccess: String?

    private let fm = FileManager.default

    /// The directory the file browser is rooted at (the backup's `extracted/`
    /// folder). Navigation is clamped to this subtree so Back can never walk
    /// above it into the app sandbox or iOS system paths.
    private var browseRoot: URL?

    var backupsDirectoryURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func loadBackups() {
        guard let contents = try? fm.contentsOfDirectory(at: backupsDirectoryURL,
                    includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        backups = contents.compactMap { url in
            let meta = url.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: meta),
                  let entry = try? JSONDecoder().decode(BackupEntry.self, from: data)
            else { return nil }
            return entry
        }.sorted { $0.date > $1.date }
    }

    func selectBackup(_ entry: BackupEntry) {
        selectedBackup = entry
        isExtracting = true
        extractError = nil

        Task {
            do {
                let dir = try BackupEngine.shared.ensureExtracted(for: entry)
                await MainActor.run {
                    browseRoot = dir
                    currentDirectory = dir
                    loadContents(dir)
                    isExtracting = false
                }
            } catch {
                await MainActor.run {
                    extractError = error.localizedDescription
                    isExtracting = false
                }
            }
        }
    }

    func performBackup(bundleID: String, appName: String, version: String) {
        guard !isBackingUp else { return }
        isBackingUp = true
        backupError = nil
        backupSuccess = nil

        Task {
            do {
                let entry = try await BackupEngine.shared.backupApp(bundleID: bundleID, appName: appName, version: version)
                await MainActor.run {
                    loadBackups()
                    isBackingUp = false
                    backupSuccess = entry.successMessage(appName: appName)
                }
            } catch {
                await MainActor.run {
                    backupError = error.localizedDescription
                    isBackingUp = false
                }
            }
        }
    }

    func clearExtraction() {
        selectedBackup = nil
        currentDirectory = nil
        browseRoot = nil
        directoryContents = []
        extractError = nil
        isExtracting = false
    }

    func enterDirectory(_ url: URL) {
        // Only descend into directories that stay within the browse root.
        guard let root = browseRoot, isInside(url, root: root) else { return }
        currentDirectory = url
        loadContents(url)
    }

    /// True when the browser is at its root, so the Back button should leave
    /// the browser entirely instead of navigating to a parent directory.
    var isAtBrowseRoot: Bool {
        guard let current = currentDirectory, let root = browseRoot else { return true }
        return canonicalPath(current) == canonicalPath(root)
    }

    func goBack() {
        guard let current = currentDirectory, let root = browseRoot else {
            clearExtraction()
            return
        }

        // At the root (or, defensively, anywhere outside it) → return to the list.
        if canonicalPath(current) == canonicalPath(root) || !isInside(current, root: root) {
            clearExtraction()
            return
        }

        let parent = current.deletingLastPathComponent()
        // Never navigate above the root; clamp to it instead.
        if isInside(parent, root: root) {
            currentDirectory = parent
            loadContents(parent)
        } else {
            currentDirectory = root
            loadContents(root)
        }
    }

    /// Canonical filesystem path: resolves symlinks (e.g. iOS `/private`) and
    /// standardizes the URL so boundary comparisons are reliable.
    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// True if `url` is the root itself or nested anywhere beneath it.
    private func isInside(_ url: URL, root: URL) -> Bool {
        let target = canonicalPath(url)
        let base = canonicalPath(root)
        return target == base || target.hasPrefix(base + "/")
    }

    func loadContents(_ url: URL) {
        guard let items = try? fm.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        else { directoryContents = []; return }

        directoryContents = items.compactMap { u in
            guard let r = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            else { return nil }
            return FileItem(url: u, name: u.lastPathComponent,
                           isDirectory: r.isDirectory ?? false,
                           size: Int64(r.fileSize ?? 0),
                           modificationDate: r.contentModificationDate ?? Date())
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func deleteBackup(_ entry: BackupEntry) {
        let dir = backupsDirectoryURL.appendingPathComponent(entry.relativePath)
        try? fm.removeItem(at: dir)
        if selectedBackup?.id == entry.id {
            clearExtraction()
        }
        loadBackups()
    }
}
