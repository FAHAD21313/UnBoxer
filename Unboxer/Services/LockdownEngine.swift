import Foundation

public enum LockdownEngineError: Error, LocalizedError {
    case pairingFileNotFound
    case engineFailure(String)
    
    public var errorDescription: String? {
        switch self {
        case .pairingFileNotFound:
            return "Pairing file not found. Please import a valid pairing file first."
        case .engineFailure(let reason):
            return "Engine Execution Failed: \(reason)"
        }
    }
}

/// A robust, thread-safe coordinator that bridges the Swift UI to the underlying
/// pre-compiled Rust Core and libimobiledevice C-binaries.
public class LockdownEngine {
    public static let shared = LockdownEngine()
    
    private init() {}
    
    /// Executes the native connection sequence.
    /// - Parameter pairingFile: The absolute path to the pairing file.
    /// - Returns: A log string of the native execution.
    public func executeNativeEngine(pairingFile: String?) throws -> String {
        guard let pairingFile = pairingFile, FileManager.default.fileExists(atPath: pairingFile) else {
            throw LockdownEngineError.pairingFileNotFound
        }
        
        var executionLogs = ""
        
        // 1. Analyze the pairing file type natively in Swift
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pairingFile)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw LockdownEngineError.engineFailure("Invalid Pairing File Format")
        }
        
        if plist["private_key"] != nil {
            executionLogs += "$ [ENGINE] Detected RPPairing configuration.\n"
            // Configure the C-binary with the file
            do {
                try RustIdevice.setRpPairingFile(pairingFile)
                executionLogs += "$ [ENGINE] C-Library successfully configured with RPPairing.\n"
            } catch {
                throw LockdownEngineError.engineFailure("Failed to set RPPairing in C-Library: \(error.localizedDescription)")
            }
        } else if plist["UDID"] != nil {
            executionLogs += "$ [ENGINE] Detected Standard Lockdown configuration.\n"
        } else {
            throw LockdownEngineError.engineFailure("Missing UDID or Keys in Pairing File")
        }
        
        // 2. Test the connection through libimobiledevice!
        // NOTE: On iOS, this will attempt to connect to /var/run/usbmuxd.
        // Since we are sandboxed, if minimuxer loopback is not running, this will fail gracefully.
        executionLogs += "$ [ENGINE] Attempting native C-level device connection...\n"
        let isConnected = RustIdevice.testDeviceConnection()
        
        if isConnected {
            executionLogs += "$ [ENGINE] SUCCESS: Device connection verified via libimobiledevice!\n"
            
            // 3. Fetch UDID via C-Binding
            if let udid = RustIdevice.fetchUDID() {
                executionLogs += "$ [ENGINE] Natively extracted UDID: \(udid)\n"
            } else {
                executionLogs += "$ [ENGINE] WARNING: Connected, but failed to extract UDID.\n"
            }
        } else {
            executionLogs += "$ [ENGINE] ERROR: Connection failed.\n"
            executionLogs += "          (This is expected on sandboxed iOS if the Minimuxer loopback TCP Proxy is not running. libimobiledevice cannot reach the UNIX socket).\n"
        }
        
        return executionLogs
    }
}
