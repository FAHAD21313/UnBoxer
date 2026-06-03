import Foundation

// MARK: - Models
public struct AppInfo: Identifiable, Codable {
    public var id = UUID()
    public let name: String
    public let bundleID: String
    public let version: String
    public let path: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case bundleID = "BundleID"
        case version = "Version"
        case path = "Path"
    }
}

// MARK: - AppDiscoveryEngine
public class AppDiscoveryEngine {
    public static let shared = AppDiscoveryEngine()
    
    private init() {}
    
    public func fetchAllApps(udid: String) throws -> [AppInfo] {
        // [Weaponized Rust Core Discovery]
        // We bypass the native C libimobiledevice bindings entirely because they
        // cannot route over the iOS 17 RSD CoreDevice Wi-Fi tunnel.
        // Instead, we use our Custom RustBridge.xcframework FFI export.
        
        guard let jsonString = RustIdevice.fetchAllApps() else {
            throw NSError(domain: "AppDiscoveryEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Rust Core returned nil for app discovery. Ensure device is connected over Wi-Fi."])
        }
        
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw NSError(domain: "AppDiscoveryEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode Rust JSON string to Data."])
        }
        
        do {
            let apps = try JSONDecoder().decode([AppInfo].self, from: jsonData)
            return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch {
            print("[DISCOVERY ERROR] JSON Decode Error: \(error)")
            // Fallback for scaffolding JSON if properties are missing
            var fallbackApps: [AppInfo] = []
            if let array = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                for dict in array {
                    let bId = dict["BundleID"] as? String ?? "Unknown"
                    let name = dict["Name"] as? String ?? bId
                    let version = dict["Version"] as? String ?? "1.0"
                    let path = dict["Path"] as? String ?? ""
                    fallbackApps.append(AppInfo(name: name, bundleID: bId, version: version, path: path))
                }
            }
            return fallbackApps.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }
}
