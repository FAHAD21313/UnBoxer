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
                _ = try await BackupEngine.shared.backupApp(bundleID: bundleID, appName: appName, version: version)
                await MainActor.run {
                    loadBackups()
                    isBackingUp = false
                    backupSuccess = "Backup of \(appName) completed successfully."
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
        directoryContents = []
        extractError = nil
        isExtracting = false
    }

    func enterDirectory(_ url: URL) {
        currentDirectory = url
        loadContents(url)
    }

    func goBack() {
        guard let current = currentDirectory else { return }
        let parent = current.deletingLastPathComponent()
        let expectedExtracted = backupsDirectoryURL
            .appendingPathComponent(selectedBackup?.relativePath ?? "")
            .appendingPathComponent("extracted")
        if parent == expectedExtracted || parent == backupsDirectoryURL {
            clearExtraction()
        } else {
            currentDirectory = parent
            loadContents(parent)
        }
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
