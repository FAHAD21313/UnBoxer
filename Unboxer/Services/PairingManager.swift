import Foundation
import SwiftUI

class PairingManager: ObservableObject {
    @Published var isPaired: Bool = false
    @Published var hostID: String? = nil
    @Published var systemBUID: String? = nil
    @Published var hasMissingKeys: Bool = false
    @Published var isRemotePairing: Bool = false
    @Published var errorMessage: String? = nil
    
    private let fileName = "pairing_file.plist"
    
    init() {
        checkAndLoadFile()
    }
    
    private var documentDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    var fileURL: URL {
        documentDirectory.appendingPathComponent(fileName)
    }
    
    func checkAndLoadFile() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            parseFile(at: fileURL)
            DispatchQueue.main.async {
                self.isPaired = true
                self.errorMessage = nil
            }
        } else {
            DispatchQueue.main.async {
                self.isPaired = false
                self.hostID = nil
                self.systemBUID = nil
                self.hasMissingKeys = false
                self.isRemotePairing = false
            }
        }
    }
    
    func importFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            // Check file size limit (1 MB = 1 * 1024 * 1024 bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let fileSize = attributes[.size] as? NSNumber {
                if fileSize.int64Value > 1_048_576 {
                    DispatchQueue.main.async {
                        self.errorMessage = "Error: File size exceeds the 1 MB limit."
                    }
                    return
                }
            }
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.copyItem(at: url, to: fileURL)
            checkAndLoadFile()
        } catch {
            print("Failed to import file: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.errorMessage = "Error: Failed to read the selected file."
            }
        }
    }
    
    func deleteFile() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            checkAndLoadFile()
        } catch {
            print("Failed to delete file: \(error.localizedDescription)")
        }
    }
    
    private func parseFile(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                // The Rust engine drives device communication through a RemotePairing
                // file, which is identified by a `private_key` entry rather than the
                // classic usbmuxd keys (HostID / SystemBUID).
                let remotePairing = plist["private_key"] != nil
                let host = plist["HostID"] as? String
                let buid = plist["SystemBUID"] as? String
                DispatchQueue.main.async {
                    self.isRemotePairing = remotePairing
                    self.hostID = host
                    self.systemBUID = buid
                    // A RemotePairing file is complete on its own; only classic
                    // lockdown files need both HostID and SystemBUID.
                    self.hasMissingKeys = remotePairing ? false : (host == nil || buid == nil)
                }
            }
        } catch {
            print("Failed to parse plist: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.hasMissingKeys = true
                self.isRemotePairing = false
            }
        }
    }
}
