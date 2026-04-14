import AppKit
import SwiftUI
import Sparkle

@main
struct meloDLApp: App {
    @StateObject private var appSettings = AppSettings()
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView(
                appSettings: appSettings,
                onCheckAppUpdates: checkForAppUpdates
            )
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // Intentionally empty to disable Command-N new window.
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...", action: checkForAllUpdates)
            }
        }

        Settings {
            SettingsView(
                updater: updaterController.updater,
                appSettings: appSettings
            )
        }
    }

    private func checkForAppUpdates() {
        guard updaterController.updater.canCheckForUpdates else { return }
        updaterController.updater.checkForUpdates()
    }

    private func checkForAllUpdates() {
        checkForAppUpdates()
        Task.detached(priority: .utility) {
            await GitHubUpdateService.shared.checkForUpdates()
        }
    }
}

struct SettingsView: View {
    let updater: SPUUpdater
    @ObservedObject var appSettings: AppSettings

    var body: some View {
        TabView {
            DownloadsSettingsView(appSettings: appSettings)
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            UpdateSettingsView(updater: updater)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }

            CreditsSettingsView()
                .tabItem {
                    Label("Credits", systemImage: "person.3")
                }

            SupportSettingsView()
                .tabItem {
                    Label("Support", systemImage: "lifepreserver")
                }
        }
        .frame(width: 520, height: 380)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())

            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

            content
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

private struct SettingsSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
    }
}

struct UpdateSettingsView: View {
    @State private var automaticallyChecks: Bool
    private let updater: SPUUpdater
    private let subordinateIndent: CGFloat = 14

    init(updater: SPUUpdater) {
        self.updater = updater
        self._automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        SettingsPage(title: "Updates", subtitle: "Control app update behavior.") {
            SettingsSectionTitle(text: "Preferences")

            Toggle("Automatically check for app updates", isOn: $automaticallyChecks)
                .onChange(of: automaticallyChecks) { _, newValue in
                    updater.automaticallyChecksForUpdates = newValue
                }
                .padding(.leading, subordinateIndent)
        }
    }
}

struct DownloadsSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    @StateObject private var fileService = FileService()
    private let subordinateIndent: CGFloat = 14

    var body: some View {
        SettingsPage(title: "Downloads", subtitle: "Default behavior for new download batches.") {
            SettingsSectionTitle(text: "Download Folder")

            Group {
                FolderSelectionView(fileService: fileService, isDisabled: false) { folder in
                    if let folder {
                        appSettings.downloadFolderPath = folder.path
                    }
                }
            }
            .padding(.leading, subordinateIndent)

            SettingsSectionTitle(text: "Audio Defaults")

            Group {
                HStack(spacing: 12) {
                    Text("Quality")
                        .frame(width: 60, alignment: .leading)
                    Picker("Quality", selection: $appSettings.quality) {
                        ForEach(AudioQuality.allCases, id: \.self) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Toggle("Embed metadata", isOn: $appSettings.embedMetadata)

                if appSettings.format.supportsThumbnailEmbed {
                    Toggle("Embed thumbnail", isOn: $appSettings.embedThumbnail)
                } else {
                    Text("Thumbnail embed is unavailable for the selected format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, subordinateIndent)

            SettingsSectionTitle(text: "Batch Behavior")

            Group {
                Toggle("Fast downloads", isOn: $appSettings.fastDownloads)
                Toggle("Open download folder after successful batch", isOn: $appSettings.openFolderOnSuccess)
            }
            .padding(.leading, subordinateIndent)
        }
        .onAppear {
            fileService.selectedFolder = appSettings.downloadFolderURL
        }
    }
}

struct AboutSettingsView: View {
    private let subordinateIndent: CGFloat = 14

    var body: some View {
        SettingsPage(title: "About", subtitle: "A focused desktop app for quick audio downloads.") {
            SettingsSectionTitle(text: "meloDL")

            Text("meloDL is a lightweight macOS app for downloading and converting audio with a simple, settings-first workflow.")
                .padding(.leading, subordinateIndent)

            SettingsSectionTitle(text: "Details")

            Text("Built and maintained by Alexandru Apavaloaiei. Official website: coming soon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, subordinateIndent)
        }
    }
}

struct CreditsSettingsView: View {
    private let subordinateIndent: CGFloat = 14

    var body: some View {
        SettingsPage(title: "Credits", subtitle: "People and tools that made meloDL possible.") {
            SettingsSectionTitle(text: "Open Source")

            VStack(alignment: .leading, spacing: 4) {
                Text("yt-dlp")
                    .font(.headline)
                Link("github.com/yt-dlp/yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
            }
                .padding(.leading, subordinateIndent)

            SettingsSectionTitle(text: "Acknowledgements")

            Text("Created and maintained by Alexandru Apavaloaiei.")
                .padding(.leading, subordinateIndent)

            SettingsSectionTitle(text: "License")

            Text("meloDL is released under the MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, subordinateIndent)
        }
    }
}

struct SupportSettingsView: View {
    private let subordinateIndent: CGFloat = 14

    var body: some View {
        SettingsPage(title: "Support", subtitle: "Get help, report issues, and contact the team.") {
            SettingsSectionTitle(text: "Need Help?")

            Text("Need help or want to report an issue?")
                .padding(.leading, subordinateIndent)

            SettingsSectionTitle(text: "Contact")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Email:")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("alex@apvl.dev", forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: "alex@apvl.dev")
                            Image(systemName: "doc.on.doc")
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.rect)
                    .help("Copy email address")
                    .onHover { isHovering in
                        if isHovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }

                Text("GitHub Issues: coming soon (repository not public yet).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
                .padding(.leading, subordinateIndent)
        }
    }
}
