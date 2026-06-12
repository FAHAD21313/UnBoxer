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
    @Published var deepProgress: DeepProgressUI?

    /// Display-ready deep backup progress for the dashboard card.
    struct DeepProgressUI: Equatable {
        var appName: String
        /// 0...1; nil while the device has not reported progress yet.
        var fraction: Double?
        var percentText: String
        var detailText: String
    }
    
    /// Triggered from the UI when "Start Engine Test" is tapped.
    /// Configures the native engine from the pairing file, verifies connectivity,
    /// then discovers installed apps.
    func establishLockdownConnection(pairingFile: String) {
        // Dispatch to Main Thread to update UI securely
        DispatchQueue.main.async {
            self.isTesting = true
            self.showAppList = false
            self.isLogsFolded = false
            self.logs = "$ Starting Native Lockdown Engine...\n"

            // Push the heavy lifting to a background thread to prevent UI freezing
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                do {
                    let engineLogs = try LockdownEngine.shared.executeNativeEngine(pairingFile: pairingFile)
                    self.appendLog(engineLogs)

                    // Discovery is driven entirely by the configured pairing file, so
                    // it always runs after the engine sequence regardless of HostID.
                    self.appendLog("$ [DISCOVERY] Initiating App Discovery Engine...")
                    let fetchedApps = try AppDiscoveryEngine.shared.fetchAllApps()
                    self.appendLog("$ [DISCOVERY] Found \(fetchedApps.count) User App(s).")

                    DispatchQueue.main.async {
                        self.apps = fetchedApps
                        self.showAppList = true
                        self.isLogsFolded = true // Fold logs on success to show apps
                    }

                    self.appendLog("$ [ENGINE] Execution Completed Successfully.")
                } catch {
                    self.appendLog("$ [ENGINE] ERROR: \(error.localizedDescription)")
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
                let entry = try await BackupEngine.shared.backupApp(
                    bundleID: bundleID,
                    appName: appName,
                    version: version
                )
                await MainActor.run {
                    self.isBackingUp = false
                    self.backingUpBundleID = nil
                    self.backupSuccessMessage = entry.successMessage(appName: appName)
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

    /// Deep backup via mobilebackup2 — for App Store apps whose full container
    /// house_arrest cannot vend. Heavy on the first run (whole-device snapshot).
    func performDeepBackup(bundleID: String, appName: String, version: String) {
        guard !isBackingUp else { return }
        isBackingUp = true
        backingUpBundleID = bundleID
        backupError = nil
        backupSuccessMessage = nil

        deepProgress = DeepProgressUI(
            appName: appName, fraction: nil,
            percentText: "\u{2026}", detailText: "Contacting device\u{2026}"
        )

        Task {
            do {
                let entry = try await DeepBackupEngine.shared.deepBackupApp(
                    bundleID: bundleID,
                    appName: appName,
                    version: version,
                    onProgress: { progress in
                        Task { @MainActor in
                            // Ignore stale poller ticks after completion/failure.
                            guard self.deepProgress != nil else { return }
                            self.deepProgress = Self.formatDeepProgress(progress, appName: appName)
                        }
                    }
                )
                await MainActor.run {
                    self.isBackingUp = false
                    self.backingUpBundleID = nil
                    self.deepProgress = nil
                    self.backupSuccessMessage = "Deep backup of \(appName) completed \u{2014} \(entry.fileCount ?? 0) files."
                    self.showBackupToast = true
                }
            } catch {
                await MainActor.run {
                    self.isBackingUp = false
                    self.backingUpBundleID = nil
                    self.deepProgress = nil
                    self.backupError = error.localizedDescription
                    self.showBackupToast = true
                }
            }
        }
    }

    private static func formatDeepProgress(_ p: DeepBackupProgress, appName: String) -> DeepProgressUI {
        let percentText = p.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2026}"

        var details: [String] = []
        switch p.phase {
        case .waitingForDevice:
            details.append("Waiting for the device to start the snapshot\u{2026}")
        case .snapshotting:
            if let eta = p.etaSeconds, let etaText = Self.remainingFormatter.string(from: max(eta, 1)) {
                details.append("about \(etaText) left")
            } else {
                details.append("estimating time left\u{2026}")
            }
            if p.bytesDone > 0 {
                details.append(ByteCountFormatter.string(fromByteCount: p.bytesDone, countStyle: .file))
            }
            if p.files > 0 {
                details.append("\(p.files) files")
            }
        case .extracting:
            details.append("Extracting \(appName)\u{2019}s data\u{2026}")
        case .finishing:
            details.append("Cleaning up\u{2026}")
        }

        return DeepProgressUI(
            appName: appName,
            fraction: p.fraction,
            percentText: percentText,
            detailText: details.joined(separator: " \u{2022} ")
        )
    }

    private static let remainingFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
}
