import AppKit
import Sparkle
import SwiftUI

struct SettingsView: View {
    let updater: SPUUpdater
    @ObservedObject var appSettings: AppSettings

    var body: some View {
        TabView {
            DownloadsSettingsView(appSettings: appSettings)
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            BehaviorSettingsView(appSettings: appSettings)
                .tabItem {
                    Label("Behavior", systemImage: "switch.2")
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

private enum SettingsLayout {
    static let pagePadding: CGFloat = 20
    static let pageSpacing: CGFloat = 18
    static let sectionSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 8
    static let subordinateIndent: CGFloat = 18
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
        VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())

                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }

            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SettingsLayout.pagePadding)
    }
}

private struct SettingsSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            SettingsSectionTitle(text: title)
            content
                .padding(.leading, SettingsLayout.subordinateIndent)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var onChange: ((Bool, Bool) -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .toggleStyle(.switch)
        .onChange(of: isOn) { oldValue, newValue in
            onChange?(oldValue, newValue)
        }
    }
}

struct UpdateSettingsView: View {
    @State private var automaticallyChecks: Bool
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self._automaticallyChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        SettingsPage(title: "Updates", subtitle: "Control app update behavior.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "Preferences") {
                    SettingsToggleRow(
                        title: "Automatically check for app updates",
                        isOn: $automaticallyChecks
                    ) { _, newValue in
                        updater.automaticallyChecksForUpdates = newValue
                    }
                }

                SettingsSection(title: "Manual Check") {
                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }
}

struct DownloadsSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    @StateObject private var fileService = FileService()

    var body: some View {
        SettingsPage(title: "Downloads", subtitle: "Default behavior for new download batches.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "Download Folder") {
                    FolderSelectionView(fileService: fileService, isDisabled: false) { folder in
                        if let folder {
                            appSettings.downloadFolderPath = folder.path
                        }
                    }
                }

                SettingsSection(title: "Audio Defaults") {
                    VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
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

                        SettingsToggleRow(
                            title: "Embed metadata",
                            isOn: $appSettings.embedMetadata
                        )

                        if appSettings.format.supportsThumbnailEmbed {
                            SettingsToggleRow(
                                title: "Embed thumbnail",
                                isOn: $appSettings.embedThumbnail
                            )
                        } else {
                            Text("Thumbnail embed is unavailable for the selected format.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsSection(title: "Batch Behavior") {
                    VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                        SettingsToggleRow(
                            title: "Fast downloads",
                            isOn: $appSettings.fastDownloads
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            fileService.selectedFolder = appSettings.downloadFolderURL
        }
    }
}

struct BehaviorSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    @State private var showRestartPrompt = false

    var body: some View {
        SettingsPage(title: "Behavior", subtitle: "App and post-download actions.") {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                    SettingsSection(title: "After Download") {
                        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                            SettingsToggleRow(
                                title: "Open download folder after successful batch",
                                isOn: $appSettings.openFolderOnSuccess
                            )
                            SettingsToggleRow(
                                title: "Show notification when download finishes",
                                isOn: $appSettings.notifyOnDownloadCompletion
                            )
                        }
                    }

                    SettingsSection(title: "App Mode") {
                        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                            SettingsToggleRow(
                                title: "Use menubar-only mode",
                                isOn: $appSettings.menubarOnlyMode
                            ) { _, _ in
                                showRestartPrompt = true
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert("Restart Required", isPresented: $showRestartPrompt) {
            Button("Later", role: .cancel) {}
            Button("Relaunch Now") {
                AppRelauncher.relaunch(menubarOnly: appSettings.menubarOnlyMode)
            }
        } message: {
            Text("Please restart meloDL to apply menubar mode changes.")
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(title: "About", subtitle: "A focused desktop app for quick audio downloads.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "meloDL") {
                    Text("meloDL is a lightweight macOS app for downloading and converting audio with a simple, settings-first workflow.")
                        .font(.body)
                }

                SettingsSection(title: "Details") {
                    VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                        HStack(spacing: 0) {
                            Text("Built and maintained by ")
                                .foregroundStyle(.secondary)
                            Link("Alexandru Apavaloaiei", destination: URL(string: "https://apvl.dev")!)
                                .foregroundStyle(.blue)
                        }
                        .font(.body)

                        HStack(spacing: 0) {
                            Text("Official website: ")
                                .foregroundStyle(.secondary)
                            Link("apvl.dev/stuff/meloDL", destination: URL(string: "https://apvl.dev/stuff/meloDL")!)
                                .foregroundStyle(.blue)
                        }
                        .font(.body)

                        HStack(spacing: 0) {
                            Text("Supported links: ")
                                .foregroundStyle(.secondary)
                            Link("yt-dlp supported sites", destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!)
                                .foregroundStyle(.blue)
                        }
                        .font(.body)
                    }
                }
            }
        }
    }
}

struct CreditsSettingsView: View {
    var body: some View {
        SettingsPage(title: "Credits", subtitle: "People and tools that made meloDL possible.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "Open Source") {
                    VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                        Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                        Link("ffmpeg", destination: URL(string: "https://github.com/FFmpeg/FFmpeg")!)
                        Link("ffprobe", destination: URL(string: "https://ffmpeg.org/ffprobe.html")!)
                    }
                    .font(.body)
                }

                SettingsSection(title: "License") {
                    Text("meloDL is released under the MIT License.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SupportSettingsView: View {
    var body: some View {
        SettingsPage(title: "Support", subtitle: "Get help, report issues, and contact the team.") {
            SettingsSection(title: "Contact") {
                VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
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

                    HStack(spacing: 6) {
                        Text("GitHub Issues:")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Link("github.com/alexapvl/meloDL/issues", destination: URL(string: "https://github.com/alexapvl/meloDL/issues")!)
                            .font(.body)
                    }
                }
            }
        }
    }
}
