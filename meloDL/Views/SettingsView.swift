import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

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

            IndexingSettingsView(appSettings: appSettings)
                .tabItem {
                    Label("Indexing", systemImage: "magnifyingglass")
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
                            Text("Thumbnail embed is only available for MP3, M4A, and FLAC formats.")
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

struct IndexingSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    @StateObject private var viewModel: IndexingSettingsViewModel
    @State private var dropTargeted = false

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        _viewModel = StateObject(wrappedValue: IndexingSettingsViewModel(appSettings: appSettings))
    }

    var body: some View {
        SettingsPage(title: "Indexing", subtitle: "Configure duplicate detection indexing roots and maintenance.") {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                    SettingsSection(title: "Duplicate Detection") {
                        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                            SettingsToggleRow(
                                title: "Enable duplicate detection before download",
                                isOn: $appSettings.duplicateDetectionEnabled
                            )

                            Button("Find Duplicate Files in Index") {
                                viewModel.openExactDuplicateFinder()
                            }
                            .disabled(viewModel.roots.isEmpty || viewModel.isIndexing)

                            Text("Shows exact duplicate files grouped by content hash and full path.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsSection(title: "Index Status") {
                        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                            HStack(spacing: 8) {
                                if viewModel.isIndexing {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Indexing...")
                                } else {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                    Text("Idle")
                                }
                            }

                            Text(lastIndexedText)
                                .foregroundStyle(.secondary)
                            Text("Indexed tracks: \(viewModel.indexedTrackCount)")
                                .foregroundStyle(.secondary)
                            Text("DB (data): \(formatBytes(viewModel.databaseSizeMainBytes))")
                                .foregroundStyle(.secondary)
                            Text("DB (WAL buffer): \(formatBytes(viewModel.databaseSizeWalBytes))")
                                .foregroundStyle(.secondary)
                            Text("DB (shared memory): \(formatBytes(viewModel.databaseSizeShmBytes))")
                                .foregroundStyle(.secondary)
                            Text("DB (total): \(formatBytes(viewModel.databaseSizeTotalBytes))")
                                .foregroundStyle(.secondary)

                            if !viewModel.inaccessibleRoots.isEmpty {
                                Text("Some indexed folders are currently inaccessible.")
                                    .foregroundStyle(.orange)
                            }

                            HStack(spacing: 10) {
                                Button("Update index now") {
                                    viewModel.updateIndexNow()
                                }
                                .disabled(!viewModel.canUpdateIndexNow)

                                Button("Clear indexing data...") {
                                    viewModel.showClearDataConfirmation = true
                                }
                                .disabled(viewModel.isIndexing)
                            }
                        }
                        .font(.caption)
                    }

                    SettingsSection(title: "Indexed Folders") {
                        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
                            List(selection: $viewModel.selectedRoot) {
                                if viewModel.roots.isEmpty {
                                    Text("No indexed folders yet")
                                        .foregroundStyle(.secondary)
                                        .listRowBackground(Color(.controlBackgroundColor).opacity(0.45))
                                } else {
                                    ForEach(Array(viewModel.roots.enumerated()), id: \.element) { index, root in
                                        Text(root)
                                            .tag(root)
                                            .listRowBackground(
                                                (index % 2 == 0
                                                    ? Color(.controlBackgroundColor).opacity(0.55)
                                                    : Color(.controlBackgroundColor).opacity(0.35))
                                            )
                                    }
                                }
                            }
                            .frame(minHeight: 130, maxHeight: 170)
                            .scrollContentBackground(.hidden)
                            .listStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(.windowBackgroundColor).opacity(0.28))
                            )
                            .onDrop(
                                of: [UTType.fileURL.identifier],
                                isTargeted: $dropTargeted,
                                perform: handleDrop(providers:)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        dropTargeted ? Color.accentColor : Color.secondary.opacity(0.2),
                                        lineWidth: 1
                                    )
                            }

                            HStack(alignment: .center) {
                                HStack(spacing: 0) {
                                    Button {
                                        viewModel.removeSelectedRoot()
                                    } label: {
                                        Image(systemName: "minus")
                                            .frame(width: 18, height: 18)
                                    }
                                    .disabled(viewModel.selectedRoot == nil || viewModel.isIndexing)
                                    .buttonStyle(.plain)
                                    .frame(width: 28, height: 24)

                                    Divider()
                                        .frame(height: 16)

                                    Button {
                                        viewModel.addRootUsingPanel()
                                    } label: {
                                        Image(systemName: "plus")
                                            .frame(width: 18, height: 18)
                                    }
                                    .disabled(viewModel.isIndexing)
                                    .buttonStyle(.plain)
                                    .frame(width: 28, height: 24)
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color(.controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                                )

                                Spacer(minLength: 0)

                                Text("Tip: Drag and drop folders into this list to add them.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let feedbackMessage = viewModel.feedbackMessage {
                        Text(feedbackMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .alert("Clear indexing data?", isPresented: $viewModel.showClearDataConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Data", role: .destructive) {
                viewModel.clearIndexData()
            }
        } message: {
            Text("This removes all indexed tracks but keeps your folder list.")
        }
        .confirmationDialog(
            "Folder overlap detected",
            isPresented: Binding(
                get: { viewModel.pendingConflict != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.pendingConflict = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            switch viewModel.pendingConflict {
            case .childInsideParent:
                Button("Keep existing parent only") {
                    viewModel.chooseKeepParentForChildConflict()
                }
                Button("Keep both folders") {
                    viewModel.chooseKeepBothForChildConflict()
                }
            case .parentWithChildren:
                Button("Keep existing child folders only") {
                    viewModel.chooseKeepChildrenForParentConflict()
                }
                Button("Replace child folders with parent") {
                    viewModel.chooseReplaceChildrenWithParent()
                }
            case .none:
                EmptyView()
            }
            Button("Cancel", role: .cancel) {
                viewModel.pendingConflict = nil
            }
        } message: {
            switch viewModel.pendingConflict {
            case .childInsideParent(let proposedRoot, let parentRoot):
                Text("\"\(proposedRoot)\" is inside already indexed parent \"\(parentRoot)\".")
            case .parentWithChildren(let proposedRoot, let childRoots):
                Text("\"\(proposedRoot)\" contains currently indexed child folders: \(childRoots.joined(separator: ", ")).")
            case .none:
                Text("")
            }
        }
        .sheet(isPresented: $viewModel.showExactDuplicateFinder) {
            ExactDuplicateFinderSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.showExactDuplicateFinder) { wasPresented, isPresented in
            if wasPresented && !isPresented {
                viewModel.reindexAfterDuplicateFinderClosed()
            }
        }
    }

    private var lastIndexedText: String {
        if let lastIndexedAt = viewModel.lastIndexedAt {
            return "Last indexed: \(lastIndexedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Last indexed: never"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let item else { return }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsData = item as? NSData {
                    url = URL(dataRepresentation: nsData as Data, relativeTo: nil)
                } else if let string = item as? String {
                    url = URL(string: string)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                }
                guard let folderURL = url else { return }
                Task { @MainActor in
                    viewModel.handleDroppedFolderURLs([folderURL])
                }
            }
        }
        return true
    }
}

private struct ExactDuplicateFinderSheet: View {
    @ObservedObject var viewModel: IndexingSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exact Duplicate Files")
                        .font(.title3.bold())
                    Text("\(viewModel.exactDuplicateGroups.count) groups, \(viewModel.totalExactDuplicateFiles) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if viewModel.isScanningExactDuplicates || viewModel.isRunningSmartCleanup {
                ProgressView(viewModel.isRunningSmartCleanup ? "Running smart cleanup..." : "Scanning indexed files...")
                    .controlSize(.small)
            } else if let exactDuplicateScanError = viewModel.exactDuplicateScanError {
                Text(exactDuplicateScanError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let smartCleanupSummary = viewModel.smartCleanupSummary {
                Text(cleanupSummaryText(for: smartCleanupSummary))
                    .font(.caption)
                    .foregroundStyle(smartCleanupSummary.failedCount > 0 ? .orange : .secondary)
            }

            if !viewModel.isScanningExactDuplicates && !viewModel.isRunningSmartCleanup {
                if viewModel.isManualReviewMode {
                    manualReviewContent
                } else if viewModel.exactDuplicateGroups.isEmpty {
                    ContentUnavailableView(
                        "No Exact Duplicates",
                        systemImage: "checkmark.circle",
                        description: Text("No files in your index share identical content.")
                    )
                } else {
                    List {
                        ForEach(viewModel.exactDuplicateGroups) { group in
                            Section {
                                ForEach(group.files) { file in
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.filename)
                                                .font(.body)
                                            Text(file.path)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                        metadataLabel(for: file)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Button("Preview") {
                                            TrackPreviewService.shared.previewTrack(
                                                atPath: file.path,
                                                title: file.filename
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    .contextMenu {
                                        Button("Copy Path") {
                                            copyPath(file.path)
                                        }
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                        }
                                    }
                                }
                            } header: {
                                Text("Hash \(group.contentHash.prefix(12))... (\(group.files.count) files)")
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }

            Spacer(minLength: 0)
            Divider()
            bottomActionBar
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 460, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: viewModel.showExactDuplicateFinder) {
            if viewModel.showExactDuplicateFinder && viewModel.exactDuplicateGroups.isEmpty {
                viewModel.refreshExactDuplicateGroups()
            }
        }
        .alert("Run Smart Cleanup?", isPresented: $viewModel.showSmartCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Move Duplicates to Trash", role: .destructive) {
                viewModel.runSmartCleanup()
            }
        } message: {
            Text(
                """
                \(viewModel.smartCleanupKeepRule.descriptionText)
                All other files in each duplicate group will be moved to Trash.
                Files to remove: \(viewModel.smartCleanupCandidateCount)
                Estimated space reclaimed: \(ByteCountFormatter.string(fromByteCount: viewModel.smartCleanupEstimatedReclaimBytes, countStyle: .file))
                """
            )
        }
    }

    private func metadataLabel(for file: ExactDuplicateFileEntry) -> Text {
        let sizeText = file.filesize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size"
        let dateText = file.mtime == .distantPast
            ? "Unknown"
            : file.mtime.formatted(date: .abbreviated, time: .shortened)
        return Text("Size: ").bold()
            + Text(sizeText)
            + Text(" | ")
            + Text("Date added: ").bold()
            + Text(dateText)
    }

    @ViewBuilder
    private var manualReviewContent: some View {
        if let state = viewModel.manualCurrentGroupState {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.manualGroupProgressText)
                            .font(.headline)
                        Text(manualStatsText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text("Select one keeper. Other files will be moved to Trash when you confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    Section {
                        ForEach(state.group.files) { file in
                            let isSelectedKeeper = state.keeperPath == file.path
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    viewModel.selectManualKeeper(path: file.path)
                                } label: {
                                    Image(systemName: isSelectedKeeper ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(isSelectedKeeper ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Set as keeper")

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.filename)
                                        .font(.body)
                                    Text(file.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    metadataLabel(for: file)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button("Preview") {
                                    TrackPreviewService.shared.previewTrack(
                                        atPath: file.path,
                                        title: file.filename
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelectedKeeper ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(isSelectedKeeper ? Color.accentColor.opacity(0.28) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(.rect)
                            .onTapGesture {
                                viewModel.selectManualKeeper(path: file.path)
                            }
                        }
                    } header: {
                        Text("Hash \(state.group.contentHash.prefix(12))... (\(state.group.files.count) files)")
                    }
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView(
                "Manual Review Complete",
                systemImage: "checkmark.circle",
                description: Text("No more duplicate groups to process in this session.")
            )
        }
    }

    private var manualStatsText: String {
        let reclaimed = ByteCountFormatter.string(fromByteCount: viewModel.manualReclaimedBytes, countStyle: .file)
        return "Applied groups: \(viewModel.manualAppliedGroupsCount) | Removed files: \(viewModel.manualAppliedFilesCount) | Failed: \(viewModel.manualFailedDeleteCount) | Reclaimed: \(reclaimed) | Remaining groups: \(viewModel.manualRemainingGroupsCount)"
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            if viewModel.isManualReviewMode {
                Button("Previous") {
                    viewModel.moveToPreviousManualGroup()
                }
                .disabled(viewModel.manualCurrentIndex == 0 || viewModel.isRunningSmartCleanup)

                Button("Skip") {
                    viewModel.skipManualGroup()
                }
                .disabled(viewModel.manualCurrentIndex >= viewModel.manualRemainingGroupsCount - 1 || viewModel.isRunningSmartCleanup)

                Button("Keep Selected, Trash Others") {
                    viewModel.applyCurrentManualGroup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.manualCurrentGroupState == nil || viewModel.isRunningSmartCleanup)
            } else {
                Button("Refresh Scan") {
                    viewModel.refreshExactDuplicateGroups()
                }
                .disabled(viewModel.isScanningExactDuplicates || viewModel.isRunningSmartCleanup)

                Picker("Keep rule", selection: $viewModel.smartCleanupKeepRule) {
                    ForEach(SmartCleanupKeepRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(viewModel.isRunningSmartCleanup)

                Button("Manual Review") {
                    viewModel.startManualReviewSession()
                }
                .disabled(
                    viewModel.exactDuplicateGroups.isEmpty
                    || viewModel.isScanningExactDuplicates
                    || viewModel.isRunningSmartCleanup
                )

                Button("Smart Cleanup...") {
                    viewModel.showSmartCleanupConfirmation = true
                }
                .disabled(
                    viewModel.exactDuplicateGroups.isEmpty
                    || viewModel.isScanningExactDuplicates
                    || viewModel.isRunningSmartCleanup
                    || viewModel.isIndexing
                )
            }

            Spacer(minLength: 0)

            if viewModel.isManualReviewMode {
                Button("Back") {
                    viewModel.exitManualReviewMode()
                }
                .disabled(viewModel.isRunningSmartCleanup)
            } else {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isRunningSmartCleanup)
            }
        }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func cleanupSummaryText(for summary: SmartCleanupSummary) -> String {
        let reclaimed = ByteCountFormatter.string(fromByteCount: summary.reclaimedBytes, countStyle: .file)
        if summary.failedCount > 0 {
            return "Cleanup removed \(summary.removedCount) files, failed \(summary.failedCount), kept \(summary.keptCount), reclaimed \(reclaimed)."
        }
        return "Cleanup removed \(summary.removedCount) files, kept \(summary.keptCount), reclaimed \(reclaimed)."
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
