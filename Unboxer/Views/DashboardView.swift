import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject var pairingManager: PairingManager
    @StateObject private var viewModel = DashboardViewModel()
    @State private var showFileImporter = false
    
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
                    
                    // Native C Minimuxer Test Section
                    Button(action: {
                        if pairingManager.hostID != nil {
                            viewModel.establishLockdownConnection(pairingFile: pairingManager.fileURL.path)
                        }
                    }) {
                        HStack(spacing: 10) {
                            if viewModel.isTesting {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "network")
                            }
                            Text("Start Engine Test")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(pairingManager.hostID == nil ? Color.gray : Color.blue)
                        .clipShape(Capsule())
                    }
                    .disabled(viewModel.isTesting || pairingManager.hostID == nil)
                    
                    // Log Terminal
                    if !viewModel.logs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Engine Terminal Logs")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: {
                                    // UXPasteboard implementation for macOS/iOS
                                    #if os(iOS)
                                    UIPasteboard.general.string = viewModel.logs
                                    #endif
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.white)
                                        .font(.system(size: 14))
                                        .padding(8)
                                        .background(Color.white.opacity(0.1))
                                        .clipShape(Circle())
                                }
                            }
                            
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
                        }
                        .padding(.top, 10)
                        .transition(.opacity)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .cornerRadius(24)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2), lineWidth: 1))
                .padding(.horizontal)
            }
            
            Spacer()
        }
    }
}
