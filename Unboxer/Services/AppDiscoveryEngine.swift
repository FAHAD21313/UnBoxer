import Foundation

// MARK: - Native C Bindings (libimobiledevice)
@_silgen_name("idevice_new")
internal func _idevice_new(_ device: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, _ udid: UnsafePointer<Int8>?) -> Int32

@_silgen_name("idevice_free")
internal func _idevice_free(_ device: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("lockdownd_client_new_with_handshake")
internal func _lockdownd_client_new_with_handshake(_ device: UnsafeMutableRawPointer?, _ client: UnsafeMutablePointer<UnsafeMutableRawPointer?>?, _ label: UnsafePointer<Int8>?) -> Int32

@_silgen_name("lockdownd_start_service")
internal func _lockdownd_start_service(_ client: UnsafeMutableRawPointer?, _ identifier: UnsafePointer<Int8>?, _ service: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32

@_silgen_name("lockdownd_client_free")
internal func _lockdownd_client_free(_ client: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("lockdownd_service_descriptor_free")
internal func _lockdownd_service_descriptor_free(_ service: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("instproxy_client_new")
internal func _instproxy_client_new(_ device: UnsafeMutableRawPointer?, _ service: UnsafeMutableRawPointer?, _ client: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32

@_silgen_name("instproxy_browse")
internal func _instproxy_browse(_ client: UnsafeMutableRawPointer?, _ client_options: UnsafeMutableRawPointer?, _ result: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32

@_silgen_name("instproxy_client_free")
internal func _instproxy_client_free(_ client: UnsafeMutableRawPointer?) -> Int32

// MARK: - Native C Bindings (libplist)
@_silgen_name("plist_new_dict")
internal func _plist_new_dict() -> UnsafeMutableRawPointer?

@_silgen_name("plist_new_string")
internal func _plist_new_string(_ val: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer?

@_silgen_name("plist_new_array")
internal func _plist_new_array() -> UnsafeMutableRawPointer?

@_silgen_name("plist_array_append_item")
internal func _plist_array_append_item(_ node: UnsafeMutableRawPointer?, _ item: UnsafeMutableRawPointer?)

@_silgen_name("plist_dict_set_item")
internal func _plist_dict_set_item(_ node: UnsafeMutableRawPointer?, _ key: UnsafePointer<Int8>?, _ item: UnsafeMutableRawPointer?)

@_silgen_name("plist_to_xml")
internal func _plist_to_xml(_ node: UnsafeMutableRawPointer?, _ xml: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?, _ length: UnsafeMutablePointer<UInt32>?)

@_silgen_name("plist_free")
internal func _plist_free(_ node: UnsafeMutableRawPointer?)

@_silgen_name("free")
internal func _c_free(_ ptr: UnsafeMutableRawPointer?)

// MARK: - Models
public struct AppInfo: Identifiable {
    public let id = UUID()
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
        var device: UnsafeMutableRawPointer? = nil
        let deviceErr = _idevice_new(&device, udid)
        guard deviceErr == 0, let devicePtr = device else {
            throw NSError(domain: "AppDiscoveryEngine", code: Int(deviceErr), userInfo: [NSLocalizedDescriptionKey: "Failed to connect to device. Ensure pairing file is valid and network is reachable."])
        }
        defer { _idevice_free(devicePtr) }
        
        var lockdown: UnsafeMutableRawPointer? = nil
        let lockErr = _lockdownd_client_new_with_handshake(devicePtr, &lockdown, "Unboxer-Discovery")
        guard lockErr == 0, let lockdownPtr = lockdown else {
            throw NSError(domain: "AppDiscoveryEngine", code: Int(lockErr), userInfo: [NSLocalizedDescriptionKey: "Failed to establish lockdownd handshake."])
        }
        defer { _lockdownd_client_free(lockdownPtr) }
        
        var service: UnsafeMutableRawPointer? = nil
        let srvErr = _lockdownd_start_service(lockdownPtr, "com.apple.mobile.installation_proxy", &service)
        guard srvErr == 0, let servicePtr = service else {
            throw NSError(domain: "AppDiscoveryEngine", code: Int(srvErr), userInfo: [NSLocalizedDescriptionKey: "Failed to start installation_proxy service."])
        }
        defer { _lockdownd_service_descriptor_free(servicePtr) }
        
        var instproxy: UnsafeMutableRawPointer? = nil
        let instErr = _instproxy_client_new(devicePtr, servicePtr, &instproxy)
        guard instErr == 0, let instproxyPtr = instproxy else {
            throw NSError(domain: "AppDiscoveryEngine", code: Int(instErr), userInfo: [NSLocalizedDescriptionKey: "Failed to create installation_proxy client."])
        }
        defer { _instproxy_client_free(instproxyPtr) }
        
        // Setup client_options dict
        let clientOptions = _plist_new_dict()
        defer { _plist_free(clientOptions) }
        
        let clientOptsDict = _plist_new_dict()
        let typeStr = _plist_new_string("User")
        _plist_dict_set_item(clientOptions, "ApplicationType", typeStr)
        
        let returnAttrs = _plist_new_array()
        let attr1 = _plist_new_string("CFBundleDisplayName")
        let attr2 = _plist_new_string("CFBundleIdentifier")
        let attr3 = _plist_new_string("CFBundleShortVersionString")
        let attr4 = _plist_new_string("Path")
        let attr5 = _plist_new_string("Container")
        
        _plist_array_append_item(returnAttrs, attr1)
        _plist_array_append_item(returnAttrs, attr2)
        _plist_array_append_item(returnAttrs, attr3)
        _plist_array_append_item(returnAttrs, attr4)
        _plist_array_append_item(returnAttrs, attr5)
        
        _plist_dict_set_item(clientOptions, "ReturnAttributes", returnAttrs)
        
        var resultPlist: UnsafeMutableRawPointer? = nil
        let browseErr = _instproxy_browse(instproxyPtr, clientOptions, &resultPlist)
        guard browseErr == 0, let resPlist = resultPlist else {
            throw NSError(domain: "AppDiscoveryEngine", code: Int(browseErr), userInfo: [NSLocalizedDescriptionKey: "Failed to browse apps via instproxy."])
        }
        defer { _plist_free(resPlist) }
        
        // Convert the result plist to XML string
        var xmlPtr: UnsafeMutablePointer<Int8>? = nil
        var xmlLen: UInt32 = 0
        _plist_to_xml(resPlist, &xmlPtr, &xmlLen)
        
        guard let validXmlPtr = xmlPtr else {
            throw NSError(domain: "AppDiscoveryEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert apps plist to XML."])
        }
        defer { _c_free(UnsafeMutableRawPointer(validXmlPtr)) }
        
        let xmlString = String(cString: validXmlPtr)
        guard let data = xmlString.data(using: .utf8),
              let appsArray = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] else {
            throw NSError(domain: "AppDiscoveryEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Swift plist from XML."])
        }
        
        // Map to AppInfo
        var apps: [AppInfo] = []
        for appDict in appsArray {
            let bundleID = appDict["CFBundleIdentifier"] as? String ?? "Unknown"
            let name = appDict["CFBundleDisplayName"] as? String ?? bundleID
            let version = appDict["CFBundleShortVersionString"] as? String ?? "1.0"
            let path = appDict["Path"] as? String ?? ""
            
            apps.append(AppInfo(name: name, bundleID: bundleID, version: version, path: path))
        }
        
        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
