import AppKit
import SwiftUI

struct DiscoverySettingsView: View {
    @ObservedObject var viewModel: AppInventoryViewModel
    @AppStorage(DiscoveryConfiguration.dockerKey) private var includeDocker = false
    @State private var folders: [URL] = []

    var body: some View {
        Form {
            Section("Application Folders") {
                Text("Add folders containing installed apps or game libraries, including external disks. Scans stay within six folder levels and skip nested app contents and symbolic links.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(folders, id: \.path) { folder in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(folder.lastPathComponent).font(.body.weight(.medium))
                            Text(folder.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(folder.path)
                        }
                        Spacer()
                        Button {
                            folders.removeAll { $0 == folder }
                            saveFolders()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove Folder")
                            .accessibilityLabel(Text("Remove Folder") + Text(" " + folder.lastPathComponent))
                    }
                }
                Button("Add Folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                    .disabled(folders.count >= 16 || viewModel.isScanning)
                Text("Disconnected or unreadable folders appear in scan diagnostics. Removing a folder does not delete its contents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local Managers") {
                Text("GOG Galaxy, Epic Games, Heroic, Setapp, JetBrains Toolbox, Adobe, CrossOver and Whisky are discovered from local installation records and reviewed folders. Removed games and download-only libraries are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Discover Docker containers and images", isOn: $includeDocker)
                Text("Off by default. Reads only the current Docker connection: image IDs and platforms, container names and state, Compose project/service names and volume names. It does not start Docker, pull images, enter containers or read environment variables, mount paths or registry credentials.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Image tags are not versions. Docker updates remain managed externally; Update Atlas does not compare private registries or install container updates.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 8) {
                    Text("Docker")
                    BetaFeatureBadge()
                }
            }
            Section {
                HStack {
                    Text("Changes apply to the next scan and are shared with the CLI.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Now") { Task { await viewModel.scan() } }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.isScanning)
        .onAppear { folders = DiscoveryConfiguration.current().folders }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder", bundle: AppL10n.bundle, locale: AppL10n.locale)
        panel.begin { response in
            guard response == .OK else { return }
            folders = Array(DiscoveryConfiguration(folders: folders + panel.urls).folders.prefix(16))
            saveFolders()
        }
    }
    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: DiscoveryConfiguration.foldersKey)
    }
}
