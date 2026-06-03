import SwiftUI

struct BackupsView: View {
    @StateObject private var viewModel = BackupViewModel()

    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .center, spacing: 4) {
                Text("Backups")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)

                Text("Your backed-up app containers")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal)
            .padding(.top, 110)

            Spacer()

            if viewModel.isBackingUp || viewModel.backupSuccess != nil || viewModel.backupError != nil {
                backupStatusView
            } else if viewModel.selectedBackup != nil {
                if viewModel.isExtracting {
                    extractingView
                } else if let err = viewModel.extractError {
                    extractionErrorView(err)
                } else {
                    fileBrowserView
                }
            } else if viewModel.backups.isEmpty {
                emptyStateView
            } else {
                backupListView
            }

            Spacer()
        }
        .onAppear { viewModel.loadBackups() }
        .confirmationDialog("Delete Backup?", isPresented: $viewModel.showDeleteConfirmation, titleVisibility: .visible) {
            if let entry = viewModel.entryToDelete {
                Button("Delete \"\(entry.appName)\"", role: .destructive) {
                    viewModel.deleteBackup(entry)
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let entry = viewModel.entryToDelete {
                Text("This will permanently delete the backup of \(entry.appName) including all files.")
            }
        }
    }

    private var backupStatusView: some View {
        VStack(spacing: 16) {
            if viewModel.isBackingUp {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Backing up...")
                    .font(.system(size: 16, weight: .bold))
                Text("Please keep the device nearby.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else if let msg = viewModel.backupSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)
                Text(msg)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.center)
                Button("Done") {
                    viewModel.backupSuccess = nil
                }
                .buttonStyle(.borderedProminent)
            } else if let msg = viewModel.backupError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.red)
                Text(msg)
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                Button("Dismiss") {
                    viewModel.backupError = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }

    private var extractingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Extracting backup...")
                .font(.system(size: 16, weight: .bold))
            Text("Preparing files for browsing.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }

    private func extractionErrorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.yellow)

            Text("Extraction Failed")
                .font(.system(size: 18, weight: .bold))

            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Go Back") {
                viewModel.clearExtraction()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 40))
                .foregroundColor(.blue)

            Text("No Backups Yet")
                .font(.system(size: 18, weight: .bold))

            Text("Backed-up app containers will appear here once you create your first backup.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal)
    }

    private var backupListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.backups) { entry in
                    BackupRowView(entry: entry)
                        .onTapGesture { viewModel.selectBackup(entry) }
                        .contextMenu {
                            Button(role: .destructive) {
                                viewModel.entryToDelete = entry
                                viewModel.showDeleteConfirmation = true
                            } label: {
                                Label("Delete Backup", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal)
        }
    }

    private var fileBrowserView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: { viewModel.goBack() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Text("Back")
                            .font(.system(size: 15))
                    }
                    .foregroundColor(.blue)
                }

                Spacer()

                Text(viewModel.currentDirectory?.lastPathComponent ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.directoryContents) { item in
                        FileRowView(item: item)
                            .onTapGesture {
                                if item.isDirectory {
                                    viewModel.enterDirectory(item.url)
                                }
                            }
                            .contextMenu {
                                ShareLink(item: item.url, preview: SharePreview(item.name))
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct BackupRowView: View {
    let entry: BackupEntry

    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.1))
                .frame(width: 50, height: 50)
                .overlay(
                    Image(systemName: "archivebox.fill")
                        .foregroundColor(.white.opacity(0.5))
                        .font(.system(size: 24))
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.appName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                    if entry.isDocumentsOnly {
                        Text("Documents Only")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                Text(entry.bundleID)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("\(entry.displaySize) \u{2022} \(entry.displayDate)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.system(size: 14))
        }
        .padding()
        .background(Color.black.opacity(0.2))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }
}

struct FileRowView: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundColor(item.isDirectory ? .blue : .white.opacity(0.5))
                .font(.system(size: 20))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !item.isDirectory {
                    Text(item.displaySize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.15))
        .cornerRadius(12)
    }
}
