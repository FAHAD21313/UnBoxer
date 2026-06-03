import Foundation
import SwiftUI
import Combine

/// Integrates the newly generated Lockdownd Networking Engine perfectly into the UI.
/// This orchestrated ViewModel binds terminal logs and execution states safely to the main thread.
class DashboardViewModel: ObservableObject {
    @Published var logs: String = ""
    @Published var isTesting: Bool = false
    @Published var apps: [AppInfo] = []
    @Published var showAppList: Bool = false
    @Published var isLogsFolded: Bool = false
    @Published var isBackingUp: Bool = false
    @Published var backingUpBundleID: String?
    @Published var backupError: String?
    @Published var backupSuccessMessage: String?
    @Published var showBackupToast: Bool = false
    
    /// Triggered from the UI when "Start Test" is tapped.
    /// Initiates the extraction, connection, and session startup sequentially.
    func establishLockdownConnection(pairingFile: String, udid: String?) {
        // Dispatch to Main Thread to update UI securely
        DispatchQueue.main.async {
            self.isTesting = true
            self.showAppList = false
            self.isLogsFolded = false
            self.logs = "$ Starting Native Lockdown Engine...\n"
            
            // Push the heavy lifting to a background thread to prevent UI freezing
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let engineLogs = try LockdownEngine.shared.executeNativeEngine(pairingFile: pairingFile)
                    self.appendLog(engineLogs)
                    
                    if let udid = udid {
                        self.appendLog("$ [DISCOVERY] Initiating App Discovery Engine...")
                        let fetchedApps = try AppDiscoveryEngine.shared.fetchAllApps(udid: udid)
                        self.appendLog("$ [DISCOVERY] Found \(fetchedApps.count) User Apps!")
                        
                        DispatchQueue.main.async {
                            self.apps = fetchedApps
                            self.showAppList = true
                            self.isLogsFolded = true // Fold logs on success to show apps
                        }
                    }
                    
                    self.appendLog("$ [ENGINE] Execution Completed Successfully.")
                } catch {
                    self.appendLog("$ [ENGINE] FATAL ERROR: \(error.localizedDescription)")
                }
                
                // Teardown the UI state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.teardown()
                }
            }
        }
    }
    
    /// Thread-safe logger binding directly to the terminal UI view
    private func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.logs += "\(message)\n"
        }
    }
    
    /// Cleans up resources natively and resets UI state
    private func teardown() {
        DispatchQueue.main.async { [weak self] in
            self?.isTesting = false
            self?.logs += "\n$ Engine gracefully stopped. Ready for next action.\n"
        }
    }

    func performBackup(bundleID: String, appName: String, version: String) {
        guard !isBackingUp else { return }
        isBackingUp = true
        backingUpBundleID = bundleID
        backupError = nil
        backupSuccessMessage = nil

        Task {
            do {
                _ = try await BackupEngine.shared.backupApp(
                    bundleID: bundleID,
                    appName: appName,
                    version: version
                )
                await MainActor.run {
                    self.isBackingUp = false
                    self.backingUpBundleID = nil
                    self.backupSuccessMessage = "Backup of \(appName) completed."
                    self.showBackupToast = true
                }
            } catch {
                await MainActor.run {
                    self.isBackingUp = false
                    self.backingUpBundleID = nil
                    self.backupError = error.localizedDescription
                    self.showBackupToast = true
                }
            }
        }
    }
}
