import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var pairingManager: PairingManager
    
    var body: some View {
        VStack(spacing: 20) {
            // Centered Header
            VStack(alignment: .center, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)
                
                Text("Customize your UnBoxer experience")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal)
            .padding(.top, 110)
            
            Spacer()
            
            if pairingManager.isPaired {
                // Glass Settings List for Pairing Info
                VStack(spacing: 16) {
                    Text("Pairing Profile")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                    
                    VStack(spacing: 0) {
                        InfoRow(title: "Status", value: "Active", systemImage: "link", iconColor: .green)

                        Divider().background(Color.white.opacity(0.1))

                        InfoRow(title: "Type",
                                value: pairingManager.isRemotePairing ? "RemotePairing" : "Lockdown",
                                systemImage: "lock.shield",
                                iconColor: .teal)

                        Divider().background(Color.white.opacity(0.1))

                        if pairingManager.hasMissingKeys {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                    .font(.system(size: 14))
                                
                                Text("Warning: Missing crucial keys (HostID/SystemBUID)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.yellow)
                                
                                Spacer()
                            }
                            .padding()
                            .background(Color.yellow.opacity(0.1))
                        }
                        
                        if let hostID = pairingManager.hostID {
                            Divider().background(Color.white.opacity(0.1))
                            InfoRow(title: "HostID", value: hostID, systemImage: "server.rack", iconColor: .blue)
                        }
                        
                        if let systemBUID = pairingManager.systemBUID {
                            Divider().background(Color.white.opacity(0.1))
                            InfoRow(title: "SystemBUID", value: systemBUID, systemImage: "cpu", iconColor: .purple)
                        }
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        Button(action: {
                            withAnimation(.spring()) {
                                pairingManager.deleteFile()
                            }
                        }) {
                            HStack {
                                Spacer()
                                Text("Delete / Replace Pairing File")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.red)
                                Spacer()
                            }
                            .padding()
                        }
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
                .padding(.horizontal)
                
            } else {
                // Clean Placeholder
                VStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    
                    Text("No Settings Yet")
                        .font(.system(size: 16, weight: .bold))
                        .multilineTextAlignment(.center)
                    
                    Text("Please upload a pairing file in the Dashboard.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .cornerRadius(24)
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.2), lineWidth: 1))
                .padding(.horizontal)
            }
            
            Spacer()
        }
    }
}

// Reusable Custom Info Row (LTR standard layout)
struct InfoRow: View {
    let title: String
    let value: String
    let systemImage: String
    let iconColor: Color
    
    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundColor(.white)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .background(iconColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .padding(.leading, 8)
            
            Spacer()
            
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .trailing)
        }
        .padding()
    }
}
