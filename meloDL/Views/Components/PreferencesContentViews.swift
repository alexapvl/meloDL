import Sparkle
import SwiftUI
import UniformTypeIdentifiers

enum PreferencesFormStyle {
    case settings
    case onboarding
}

struct DownloadsPreferencesContent: View {
    @ObservedObject var appSettings: AppSettings
    let style: PreferencesFormStyle
    var onDownloadFolderSelected: (String) -> Void = { _ in }
    @StateObject private var fileService = FileService()

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            PreferencesSection(
                style: style,
                systemImage: "folder",
                title: "Download folder",
                subtitle: "This is where completed audio files land."
            ) {
                PreferencesRow(
                    style: style,
                    title: "Folder",
                    description: style == .settings ? appSettings.downloadFolderPath : nil
                ) {
                    if style == .onboarding {
                        PreferencesPathToken(path: appSettings.downloadFolderPath, systemImage: "folder.fill")
                    }

                    Button {
                        fileService.selectFolder()
                    } label: {
                        Label(style == .settings ? "Choose Folder" : "Choose", systemImage: "folder.badge.plus")
                    }
                    .meloBorderedButton()
                    .fixedSize()
                }
            }

            PreferencesSection(
                style: style,
                systemImage: "waveform",
                title: "Audio defaults",
                subtitle: "Set the default quality and file metadata for new downloads."
            ) {
                PreferencesRow(style: style, title: "Quality", description: style == .settings ? "Default audio quality for converted downloads." : nil) {
                    qualityPicker
                }

                PreferencesDivider(style: style)

                PreferencesToggleRow(
                    style: style,
                    title: "Embed metadata",
                    description: "Write artist, title, album, and related tags into the audio file.",
                    isOn: $appSettings.embedMetadata
                )

                PreferencesDivider(style: style)

                PreferencesToggleRow(
                    style: style,
                    title: "Embed thumbnail",
                    description: appSettings.format.supportsThumbnailEmbed
                        ? "Attach cover art when the selected format supports it."
                        : "Only available for MP3, M4A, and FLAC formats.",
                    isOn: $appSettings.embedThumbnail
                )
                .disabled(!appSettings.format.supportsThumbnailEmbed)
            }

            PreferencesSection(
                style: style,
                systemImage: "speedometer",
                title: "Batch behavior",
                subtitle: "Choose how aggressively download batches should run."
            ) {
                PreferencesToggleRow(
                    style: style,
                    title: "Fast downloads",
                    description: "Run eligible download work with faster defaults.",
                    isOn: $appSettings.fastDownloads
                )

                PreferencesDivider(style: style)

                PreferencesStepperRow(
                    style: style,
                    title: "Max parallel sessions",
                    description: style == .settings
                        ? "Higher values can increase CPU use, ffmpeg load, network failures, and platform rate limiting."
                        : "Limit how many separate sessions can run at once.",
                    value: $appSettings.maxParallelSessions,
                    range: 1 ... 10
                )
            }
        }
        .onAppear {
            fileService.selectedFolder = appSettings.downloadFolderURL
        }
        .fileImporter(
            isPresented: $fileService.showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            _ = fileService.handleFolderSelection(result: result)
            if let folder = fileService.selectedFolder {
                appSettings.downloadFolderPath = folder.path
                onDownloadFolderSelected(folder.path)
            }
        }
    }

    private var sectionSpacing: CGFloat {
        style == .settings ? 34 : 14
    }
}

struct BehaviorPreferencesContent: View {
    @ObservedObject var appSettings: AppSettings
    let style: PreferencesFormStyle
    let notificationDescription: String
    var onNotificationChanged: ((Bool) -> Void)?
    var showsRestartPrompt = false
    @State private var showRestartPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            PreferencesSection(
                style: style,
                systemImage: "checkmark.circle",
                title: "After download",
                subtitle: "Decide what happens when a batch finishes."
            ) {
                PreferencesToggleRow(
                    style: style,
                    title: "Open download folder",
                    description: "Reveal the download folder after a successful batch.",
                    isOn: $appSettings.openFolderOnSuccess
                )

                PreferencesDivider(style: style)

                PreferencesToggleRow(
                    style: style,
                    title: "Session notifications",
                    description: notificationDescription,
                    isOn: $appSettings.notifyOnSessionEvents
                )
                .onChange(of: appSettings.notifyOnSessionEvents) { _, newValue in
                    onNotificationChanged?(newValue)
                }
            }

            PreferencesSection(
                style: style,
                systemImage: "hand.draw",
                title: "Duplicate review",
                subtitle: "Keep the duplicate review interaction discoverable."
            ) {
                PreferencesToggleRow(
                    style: style,
                    title: "Show gesture tip",
                    description: "Show the swipe gesture hint in duplicate review.",
                    isOn: $appSettings.showDuplicateReviewGestureTip
                )
            }

            PreferencesSection(
                style: style,
                systemImage: "menubar.rectangle",
                title: "App mode",
                subtitle: "Choose whether meloDL lives as a normal windowed app or only in the menu bar."
            ) {
                PreferencesToggleRow(
                    style: style,
                    title: style == .settings ? "Menu bar only" : "Use menubar-only mode",
                    description: style == .settings
                        ? "Run meloDL from the menu bar instead of the Dock."
                        : "Start as a compact menu bar utility.",
                    isOn: $appSettings.menubarOnlyMode
                )
                .onChange(of: appSettings.menubarOnlyMode) { _, newValue in
                    if showsRestartPrompt {
                        showRestartPrompt = true
                    }
                }

                PreferencesDivider(style: style)

                PreferencesToggleRow(
                    style: style,
                    title: "Open at login",
                    description: "Launch meloDL automatically when you sign in.",
                    isOn: $appSettings.openAtLogin
                )
                .onChange(of: appSettings.openAtLogin) { _, newValue in
                    LoginItemService.setEnabled(newValue)
                }
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

    private var sectionSpacing: CGFloat {
        style == .settings ? 34 : 14
    }
}

struct DuplicateDetectionPreferencesSection: View {
    @ObservedObject var appSettings: AppSettings
    let style: PreferencesFormStyle
    var scanAction: (() -> Void)?
    var isScanDisabled = false

    var body: some View {
        PreferencesSection(
            style: style,
            systemImage: "magnifyingglass",
            title: "Duplicate detection",
            subtitle: "Index your music folders so meloDL can warn before downloading the same track again."
        ) {
            PreferencesToggleRow(
                style: style,
                title: style == .settings ? "Duplicate detection" : "Check for duplicates before download",
                description: style == .settings
                    ? "Check indexed folders before downloading a matching track."
                    : "Compare new downloads against indexed folders.",
                isOn: $appSettings.duplicateDetectionEnabled
            )

            if let scanAction {
                PreferencesDivider(style: style)

                PreferencesRow(
                    style: style,
                    title: "Library duplicate scan",
                    description: "Shows exact duplicate files grouped by content hash and full path."
                ) {
                    Button("Scan Library for Duplicates", action: scanAction)
                        .meloBorderedButton()
                        .disabled(isScanDisabled)
                }
            }
        }
    }
}

struct IndexedFoldersPreferencesSection: View {
    let style: PreferencesFormStyle
    let roots: [String]
    var rootTrackCounts: [String: Int] = [:]
    @Binding var selectedRoot: String?
    @Binding var dropTargeted: Bool
    var isDisabled = false
    let onAdd: () -> Void
    let onRemove: (String) -> Void
    let onDropProviders: ([NSItemProvider]) -> Bool

    var body: some View {
        if style == .settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Indexed Folders")
                    .font(.title3.weight(.semibold))
                indexedFoldersPicker
            }
        } else {
            PreferencesSection(
                style: style,
                systemImage: "externaldrive",
                title: "Indexed folders",
                subtitle: "Add every folder where your existing music library lives."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    indexedFoldersPicker
                }
            }
        }
    }

    private var indexedFoldersPicker: some View {
        IndexedFoldersPickerView(
            roots: roots,
            rootTrackCounts: rootTrackCounts,
            selectedRoot: $selectedRoot,
            dropTargeted: $dropTargeted,
            isDisabled: isDisabled,
            emptyTitle: "No folders selected",
            emptyDescription: "Add at least one indexed folder before continuing.",
            onAdd: onAdd,
            onRemove: onRemove,
            onDropProviders: onDropProviders
        )
    }
}

struct UpdatesPreferencesContent: View {
    let style: PreferencesFormStyle
    let updater: SPUUpdater
    @Binding var automaticallyChecks: Bool

    var body: some View {
        PreferencesSection(
            style: style,
            systemImage: "arrow.triangle.2.circlepath",
            title: style == .settings ? "Preferences" : "App updates",
            subtitle: "Keep meloDL current without needing to check manually."
        ) {
            PreferencesToggleRow(
                style: style,
                title: "Automatically check for app updates",
                description: "Sparkle will look for new meloDL releases in the background.",
                isOn: $automaticallyChecks
            )
            .onChange(of: automaticallyChecks) { _, newValue in
                updater.automaticallyChecksForUpdates = newValue
            }

            PreferencesDivider(style: style)

            PreferencesRow(
                style: style,
                title: style == .settings ? "Check now" : "Manual check",
                description: updater.canCheckForUpdates
                    ? "Manual checks remain available from the app menu."
                    : "Update checks are not available right now."
            ) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label(style == .settings ? "Check for Updates..." : "Check now", systemImage: "arrow.clockwise")
                }
                .meloBorderedButton()
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

struct PreferencesSummarySection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        PreferencesSection(
            style: .onboarding,
            systemImage: "checkmark.seal",
            title: "Ready",
            subtitle: "Onboarding is complete. All changes will be editable in Settings."
        ) {
            content
        }
    }
}

private extension DownloadsPreferencesContent {
    @ViewBuilder
    var qualityPicker: some View {
        if style == .settings {
            Picker("Quality", selection: $appSettings.quality) {
                ForEach(AudioQuality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        } else {
            Picker("Quality", selection: $appSettings.quality) {
                ForEach(AudioQuality.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}

private struct PreferencesSection<Content: View>: View {
    let style: PreferencesFormStyle
    let systemImage: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: style == .settings ? 12 : 14) {
            if style == .settings {
                Text(title.capitalized)
                    .font(.title3.weight(.semibold))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: style == .settings ? 0 : 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sectionBackground)
            .overlay(sectionStroke)
        }
        .padding(style == .onboarding ? 16 : 0)
        .background(onboardingBackground)
        .overlay(onboardingStroke)
    }

    @ViewBuilder
    private var sectionBackground: some View {
        if style == .settings {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
        }
    }

    @ViewBuilder
    private var sectionStroke: some View {
        if style == .settings {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var onboardingBackground: some View {
        if style == .onboarding {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    @ViewBuilder
    private var onboardingStroke: some View {
        if style == .onboarding {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct PreferencesRow<Action: View>: View {
    let style: PreferencesFormStyle
    let title: String
    let description: String?
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .center, spacing: style == .settings ? 16 : 14) {
            VStack(alignment: .leading, spacing: style == .settings ? 6 : 3) {
                Text(title)
                    .font(style == .settings ? .callout : .callout.weight(.medium))

                if let description {
                    Text(description)
                        .font(style == .settings ? .callout : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            if style == .settings {
                action
                    .fixedSize()
            } else {
                action
            }
        }
        .padding(.horizontal, style == .settings ? 16 : 0)
        .padding(.vertical, style == .settings ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreferencesToggleRow: View {
    let style: PreferencesFormStyle
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        PreferencesRow(style: style, title: title, description: description) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct PreferencesStepperRow: View {
    let style: PreferencesFormStyle
    let title: String
    let description: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        PreferencesRow(style: style, title: title, description: description) {
            Stepper("\(value)", value: $value, in: range)
                .frame(width: 90)
        }
    }
}

private struct PreferencesDivider: View {
    let style: PreferencesFormStyle

    var body: some View {
        if style == .settings {
            Divider()
                .padding(.leading, 16)
                .overlay(Color.secondary.opacity(0.13))
        }
    }
}

private struct PreferencesPathToken: View {
    let path: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(path)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
