import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var pairingManager: PairingManager
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showFileImporter = false
    @State private var backupToast: Toast? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            // Centered Header
            VStack(alignment: .center, spacing: 4) {
                Text("Dashboard")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("Welcome to UnBoxer")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal)
            .padding(.top, 110)
            
            Spacer()
            
            if !pairingManager.isPaired {
                // Upload Pairing File Glass Card
                VStack(spacing: 16) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    
                    Text("Pairing File Required")
                        .font(.system(size: 18, weight: .bold))
                    
                    Text("Please upload your device pairing file (.plist) to proceed.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button(action: { showFileImporter = true }) {
                        Text("Upload File")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 30)
                            .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(Capsule())
                            .shadow(color: .blue.opacity(0.3), radius: 5, y: 3)
                    }
                    .padding(.top, 8)
                    
                    if let errorMessage = pairingManager.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .cornerRadius(24)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2), lineWidth: 1))
                .padding(.horizontal)
                .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.propertyList], allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first {
                            pairingManager.importFile(from: url)
                        }
                    case .failure(let error):
                        print("Error importing: \(error.localizedDescription)")
                    }
                }
            } else {
                // Device is Paired State
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                    
                    Text("Device is Paired")
                        .font(.system(size: 16, weight: .bold))
                        .multilineTextAlignment(.center)
                    
                    Text("Your pairing file is securely stored.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        
                    Divider().background(Color.white.opacity(0.1)).padding(.vertical, 8)
                    
                    // Native Engine Test Section
                    Button(action: {
                        viewModel.establishLockdownConnection(pairingFile: pairingManager.fileURL.path)
                    }) {
                        HStack(spacing: 10) {
                            if viewModel.isTesting {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "network")
                            }
                            Text(viewModel.showAppList ? "Refresh Apps" : "Start Engine Test")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(viewModel.isTesting ? Color.gray : Color.blue)
                        .clipShape(Capsule())
                    }
                    .disabled(viewModel.isTesting)
                    
                    // Log Terminal
                    if !viewModel.logs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Engine Terminal Logs")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                
                                Button(action: {
                                    withAnimation(.spring()) {
                                        viewModel.isLogsFolded.toggle()
                                    }
                                }) {
                                    Image(systemName: viewModel.isLogsFolded ? "chevron.down" : "chevron.up")
                                        .foregroundColor(.white)
                                        .font(.system(size: 12, weight: .bold))
                                        .padding(8)
                                        .background(Color.white.opacity(0.1))
                                        .clipShape(Circle())
                                }
                                
                                Button(action: {
                                    #if os(iOS)
                                    UIPasteboard.general.string = viewModel.logs
                                    #endif
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.white)
                                        .font(.system(size: 12))
                                        .padding(8)
                                        .background(Color.white.opacity(0.1))
                                        .clipShape(Circle())
                                }
                            }
                            
                            if !viewModel.isLogsFolded {
                                ScrollView {
                                    Text(viewModel.logs)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.green)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 120)
                                .padding(10)
                                .background(Color.black.opacity(0.4))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(.top, 10)
                        .transition(.opacity)
                    }
                    
                    // App List Section
                    if viewModel.showAppList {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Installed Apps (\(viewModel.apps.count))")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.top, 10)

                            // Deep backup progress card (percent + ETA)
                            if let deep = viewModel.deepProgress {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "externaldrive.badge.timemachine")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.purple)
                                        Text("Deep Backup \u{2014} \(deep.appName)")
                                            .font(.system(size: 13, weight: .bold))
                                            .lineLimit(1)
                                        Spacer()
                                        Text(deep.percentText)
                                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                                            .foregroundColor(.purple)
                                    }
                                    ProgressView(value: deep.fraction ?? 0)
                                        .progressViewStyle(LinearProgressViewStyle(tint: .purple))
                                        .animation(.easeInOut(duration: 0.4), value: deep.fraction)
                                    Text(deep.detailText)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(12)
                                .background(Color.purple.opacity(0.08))
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.25), lineWidth: 1))
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            // Diagnostic trace of the last deep backup (phase 1
                            // of the space-saving redesign) — share it so the
                            // device's operation sequence can be analyzed.
                            if let traceURL = viewModel.deepTraceLogURL, viewModel.deepProgress == nil {
                                ShareLink(item: traceURL) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 11, weight: .bold))
                                        Text("Share Deep Backup Trace Log")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundColor(.purple)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 12)
                                    .background(Color.purple.opacity(0.1))
                                    .clipShape(Capsule())
                                }
                            }

                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(viewModel.apps) { app in
                                        HStack(spacing: 16) {
                                            // App Icon Placeholder
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.white.opacity(0.1))
                                                .frame(width: 50, height: 50)
                                                .overlay(
                                                    Image(systemName: "app.fill")
                                                        .foregroundColor(.white.opacity(0.5))
                                                        .font(.system(size: 24))
                                                )
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(app.name)
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundColor(.primary)
                                                Text(app.bundleID)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            
                                            Spacer()
                                            
                                            Text("v\(app.version)")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.white.opacity(0.1))
                                                .clipShape(Capsule())
                                            
                                            Button(action: {
                                                viewModel.performBackup(
                                                    bundleID: app.bundleID,
                                                    appName: app.name,
                                                    version: app.version
                                                )
                                            }) {
                                                if viewModel.backingUpBundleID == app.bundleID {
                                                    ProgressView()
                                                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                                                        .scaleEffect(0.8)
                                                        .frame(width: 32, height: 32)
                                                } else {
                                                    Image(systemName: "archivebox")
                                                        .font(.system(size: 14, weight: .bold))
                                                        .foregroundColor(.blue)
                                                        .frame(width: 32, height: 32)
                                                        .background(Color.blue.opacity(0.1))
                                                        .clipShape(Circle())
                                                }
                                            }
                                            .disabled(viewModel.backingUpBundleID == app.bundleID || viewModel.isBackingUp)
                                        }
                                        .padding()
                                        .background(Color.black.opacity(0.2))
                                        .cornerRadius(16)
                                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.05), lineWidth: 1))
                                        .contextMenu {
                                            Button {
                                                viewModel.performBackup(
                                                    bundleID: app.bundleID,
                                                    appName: app.name,
                                                    version: app.version
                                                )
                                            } label: {
                                                Label("Quick Backup (container/documents)", systemImage: "archivebox")
                                            }
                                            Button {
                                                viewModel.performDeepBackup(
                                                    bundleID: app.bundleID,
                                                    appName: app.name,
                                                    version: app.version
                                                )
                                            } label: {
                                                Label("Deep Backup (App Store apps \u{2014} slow)", systemImage: "externaldrive.badge.timemachine")
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                            .frame(maxHeight: 300)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .cornerRadius(24)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2), lineWidth: 1))
                .padding(.horizontal)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: viewModel.showAppList)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: viewModel.isLogsFolded)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: viewModel.deepProgress == nil)
            }
            
            Spacer()
            
            // Toast overlay
            if let toast = backupToast {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Image(systemName: toast.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(toast.isError ? .red : .green)
                        Text(toast.message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: backupToast?.id)
            }
        }
        .onAppear {
            viewModel.deepTraceLogURL = DeepBackupEngine.shared.traceLogURL
        }
        .onChange(of: viewModel.showBackupToast) { show in
            if show {
                let msg = viewModel.backupSuccessMessage ?? viewModel.backupError ?? ""
                let isErr = viewModel.backupError != nil
                withAnimation { backupToast = Toast(id: UUID(), message: msg, isError: isErr) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { backupToast = nil }
                    viewModel.showBackupToast = false
                }
            }
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id: UUID
    let message: String
    let isError: Bool
}
