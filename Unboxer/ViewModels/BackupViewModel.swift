import Foundation

class BackupViewModel: ObservableObject {
    @Published var backups: [BackupEntry] = []
    @Published var selectedBackup: BackupEntry?
    @Published var currentDirectory: URL?
    @Published var directoryContents: [FileItem] = []
    @Published var showDeleteConfirmation = false
    @Published var entryToDelete: BackupEntry?

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
        let dir = backupsDirectoryURL.appendingPathComponent(entry.relativePath)
        currentDirectory = dir
        loadContents(dir)
    }

    func enterDirectory(_ url: URL) {
        currentDirectory = url
        loadContents(url)
    }

    func goBack() {
        guard let current = currentDirectory else { return }
        let parent = current.deletingLastPathComponent()
        if parent == backupsDirectoryURL {
            selectedBackup = nil
            currentDirectory = nil
            directoryContents = []
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
            selectedBackup = nil
            currentDirectory = nil
            directoryContents = []
        }
        loadBackups()
    }
}
