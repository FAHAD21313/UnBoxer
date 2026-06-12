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
