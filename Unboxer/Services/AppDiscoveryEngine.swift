import Foundation

// MARK: - Models
public struct AppInfo: Identifiable, Codable {
    public var id = UUID()
    public let name: String
    public let bundleID: String
    public let version: String
    public let path: String
}

// MARK: - AppDiscoveryEngine
public class AppDiscoveryEngine {
    public static let shared = AppDiscoveryEngine()

    private init() {}

    public func fetchAllApps(udid: String) throws -> [AppInfo] {
        guard let jsonString = RustIdevice.fetchAllApps() else {
            throw NSError(domain: "AppDiscoveryEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Rust Core returned nil for app discovery. Ensure device is connected over Wi-Fi."])
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "AppDiscoveryEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode Rust JSON string to Data."])
        }

        guard let array = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            throw NSError(domain: "AppDiscoveryEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON format from Rust Core."])
        }

        if array.isEmpty {
            let preview = String(data: jsonData, encoding: .utf8)?.prefix(500) ?? "no data"
            print("[DISCOVERY DEBUG] instproxy returned empty array. Raw JSON preview: \(preview)")
        }

        let apps: [AppInfo] = array.compactMap { dict in
            guard let bundleID = dict["CFBundleIdentifier"] as? String else {
                if !array.isEmpty { print("[DISCOVERY DEBUG] Missing CFBundleIdentifier in entry, keys: \(dict.keys.joined(separator: ", "))") }
                return nil
            }
            let name = (dict["CFBundleDisplayName"] as? String)
                ?? (dict["CFBundleName"] as? String)
                ?? bundleID
            let version = (dict["CFBundleShortVersionString"] as? String) ?? "1.0"
            let path = (dict["BundlePath"] as? String) ?? ""
            return AppInfo(name: name, bundleID: bundleID, version: version, path: path)
        }
        .filter { ($0.bundleID as NSString).length > 0 }

        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
