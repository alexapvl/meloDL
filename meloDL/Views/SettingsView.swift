import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let updater: SPUUpdater
    @ObservedObject var appSettings: AppSettings
    let onDismiss: () -> Void
    #if DEBUG
    let onReplayOnboarding: () -> Void
    #endif
    @State private var selection: SettingsDestination = .downloads
    @State private var isBackButtonHovered = false
    @Environment(\.controlActiveState) private var controlActiveState

    init(
        updater: SPUUpdater,
        appSettings: AppSettings,
        onDismiss: @escaping () -> Void = {},
        onReplayOnboarding: (() -> Void)? = nil
    ) {
        self.updater = updater
        self.appSettings = appSettings
        self.onDismiss = onDismiss
        #if DEBUG
        self.onReplayOnboarding = onReplayOnboarding ?? {}
        #endif
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()
                .ignoresSafeArea(.container, edges: .top)

            selectedPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SettingsTheme.contentBackground)
        .overlay {
            KeyEventMonitor(onEscape: onDismiss)
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 640)
        .onExitCommand(perform: onDismiss)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsDestination.allCases, id: \.self) { destination in
                SettingsSidebarRow(
                    destination: destination,
                    isSelected: selection == destination
                ) {
                    selection = destination
                }
            }

            Spacer(minLength: 0)

            sidebarFooter
        }
        .padding(.top, SettingsLayout.sidebarContentTopInset)
        .padding(.horizontal, 6)
        .padding(.bottom, SettingsLayout.sidebarContentBottomPadding)
        .frame(width: SettingsLayout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(sidebarBackground)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarBackground: Color {
        controlActiveState == .inactive
            ? SettingsTheme.sidebarInactiveBackground
            : SettingsTheme.sidebarActiveBackground
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .overlay(SettingsTheme.rowDivider)

            Button(action: onDismiss) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 18)
                    Text("Back to app")
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(backButtonFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isBackButtonHovered = $0 }
        }
    }

    private var backButtonFill: Color {
        isBackButtonHovered ? Color.primary.opacity(0.08) : .clear
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .downloads:
            DownloadsSettingsView(appSettings: appSettings)
        case .behavior:
            BehaviorSettingsView(appSettings: appSettings)
        case .indexing:
            IndexingSettingsView(appSettings: appSettings)
        case .updates:
            UpdateSettingsView(updater: updater)
        case .about:
            AboutSettingsView()
        case .credits:
            CreditsSettingsView()
        case .support:
            SupportSettingsView()
        #if DEBUG
        case .debug:
            DebugSettingsView(
                appSettings: appSettings,
                onReplayOnboarding: onReplayOnboarding
            )
        #endif
        }
    }
}

private struct SettingsSidebarRow: View {
    let destination: SettingsDestination
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: destination.symbolName)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 18)
                Text(destination.title)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(rowFill)
    }

    private var rowFill: Color {
        if isSelected {
            return Color.primary.opacity(0.14)
        }
        if isHovered {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}

private enum SettingsDestination: CaseIterable {
    case downloads
    case behavior
    case indexing
    case updates
    case about
    case credits
    case support
    #if DEBUG
    case debug
    #endif

    var title: String {
        switch self {
        case .downloads: return "Downloads"
        case .behavior: return "Behavior"
        case .indexing: return "Indexing"
        case .updates: return "Updates"
        case .about: return "About"
        case .credits: return "Credits"
        case .support: return "Support"
        #if DEBUG
        case .debug: return "Debug"
        #endif
        }
    }

    var symbolName: String {
        switch self {
        case .downloads: return "arrow.down.circle"
        case .behavior: return "switch.2"
        case .indexing: return "magnifyingglass"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        case .credits: return "person.3"
        case .support: return "lifepreserver"
        #if DEBUG
        case .debug: return "hammer"
        #endif
        }
    }
}

private enum SettingsLayout {
    static let pageHorizontalPadding: CGFloat = 44
    static let pageTopPadding: CGFloat = 46
    static let pageBottomPadding: CGFloat = 28
    static let sidebarWidth: CGFloat = 230
    static let sidebarContentTopInset: CGFloat = 64
    static let sidebarContentBottomPadding: CGFloat = 12
    static let pageSpacing: CGFloat = 34
    static let sectionSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 0
    static let contentMaxWidth: CGFloat = 615
}

private enum SettingsTheme {
    static let sidebarActiveBackground = Color.black.opacity(0.28)
    static let sidebarInactiveBackground = Color.black.opacity(0.2)
    static let contentBackground = Color(nsColor: .windowBackgroundColor).opacity(0.96)
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.58)
    static let cardStroke = Color.secondary.opacity(0.18)
    static let rowDivider = Color.secondary.opacity(0.13)
}

private struct KeyEventMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onEscape: () -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        deinit {
            stop()
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    let self,
                    self.view?.window?.isKeyWindow == true,
                    event.keyCode == 53
                else {
                    return event
                }

                self.onEscape()
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))

                    if let subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                content
            }
            .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
            .padding(.top, SettingsLayout.pageTopPadding)
            .padding(.bottom, SettingsLayout.pageBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsTheme.contentBackground)
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
            SettingsCard {
                content
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsTheme.cardStroke, lineWidth: 1)
        )
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
            .overlay(SettingsTheme.rowDivider)
    }
}

private struct SettingsRow<Action: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let action: Action

    init(title: String, description: String? = nil, @ViewBuilder action: () -> Action) {
        self.title = title
        self.description = description
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout)

                if let description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 16)

            action
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool
    var onChange: ((Bool, Bool) -> Void)? = nil

    init(
        title: String,
        description: String? = nil,
        isOn: Binding<Bool>,
        onChange: ((Bool, Bool) -> Void)? = nil
    ) {
        self.title = title
        self.description = description
        self._isOn = isOn
        self.onChange = onChange
    }

    var body: some View {
        SettingsRow(title: title, description: description) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .toggleStyle(.switch)
        .onChange(of: isOn) { oldValue, newValue in
            onChange?(oldValue, newValue)
        }
    }
}

private struct SettingsTextBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SecondaryHoverLink: View {
    let title: String
    let url: URL
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .underline(isHovered, color: .secondary)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }
}

private struct SecondaryHoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @State private var isHovered = false

    init(action: @escaping () -> Void, @ViewBuilder label: @escaping (Bool) -> Label) {
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label(isHovered)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
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
            UpdatesPreferencesContent(
                style: .settings,
                updater: updater,
                automaticallyChecks: $automaticallyChecks
            )
        }
    }
}

#if DEBUG
struct DebugSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    let onReplayOnboarding: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsPage(title: "Debug", subtitle: "Development-only tools for app state.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "Onboarding") {
                    SettingsRow(
                        title: "Replay Onboarding",
                        description: "Marks onboarding as incomplete and opens the first-run flow again."
                    ) {
                        Button {
                            onReplayOnboarding()
                            openWindow(id: AppWindowID.main)
                            focusMainWindow()
                        } label: {
                            Label("Replay Onboarding", systemImage: "arrow.clockwise")
                        }
                        .meloBorderedButton()
                    }
                    SettingsDivider()
                    SettingsRow(
                        title: "Current state",
                        description: "Shows whether onboarding is currently complete."
                    ) {
                        Text(appSettings.onboardingCompleted ? "Completed" : "Visible")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func focusMainWindow() {
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first {
                $0.level == .normal && $0.canBecomeKey && !$0.isMiniaturized
            }?.makeKeyAndOrderFront(nil)
        }
    }
}
#endif

struct DownloadsSettingsView: View {
    @ObservedObject var appSettings: AppSettings

    var body: some View {
        SettingsPage(title: "Downloads", subtitle: "Default behavior for new download batches.") {
            DownloadsPreferencesContent(appSettings: appSettings, style: .settings)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BehaviorSettingsView: View {
    @ObservedObject var appSettings: AppSettings

    var body: some View {
        SettingsPage(title: "Behavior", subtitle: "App and post-download actions.") {
            BehaviorPreferencesContent(
                appSettings: appSettings,
                style: .settings,
                notificationDescription: "Post macOS notifications for completed, failed, and attention-needed sessions.",
                showsRestartPrompt: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
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
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                    DuplicateDetectionPreferencesSection(
                        appSettings: appSettings,
                        style: .settings,
                        scanAction: viewModel.openExactDuplicateFinder,
                        isScanDisabled: viewModel.roots.isEmpty || viewModel.isIndexing
                    )

                    IndexedFoldersPreferencesSection(
                        style: .settings,
                        roots: viewModel.roots,
                        rootTrackCounts: viewModel.indexedTrackCountsByRoot,
                        selectedRoot: $viewModel.selectedRoot,
                        dropTargeted: $dropTargeted,
                        isDisabled: viewModel.isIndexing,
                        onAdd: viewModel.addRootUsingPanel,
                        onRemove: viewModel.removeRoot,
                        onDropProviders: handleDrop(providers:)
                    )

                    SettingsSection(title: "Index Status") {
                        SettingsRow(
                            title: viewModel.isIndexing ? "Indexing..." : "Idle",
                            description: indexStatusDescription
                        ) {
                            if viewModel.isIndexing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        SettingsDivider()

                        SettingsRow(
                            title: "Maintenance",
                            description: "Update the index or clear cached indexing data."
                        ) {
                            HStack(spacing: 8) {
                                Button("Update index now") {
                                    viewModel.updateIndexNow()
                                }
                                .meloBorderedButton()
                                .disabled(!viewModel.canUpdateIndexNow)

                                Button("Clear indexing data...") {
                                    viewModel.showClearDataConfirmation = true
                                }
                                .meloBorderedButton(destructive: true)
                                .disabled(viewModel.isIndexing)
                            }
                        }
                    }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var indexStatusDescription: String {
        var parts = [
            lastIndexedText,
            "Indexed tracks: \(viewModel.indexedTrackCount)",
            "Database: \(formatBytes(viewModel.databaseSizeTotalBytes))"
        ]
        if !viewModel.inaccessibleRoots.isEmpty {
            parts.append("Some indexed folders are inaccessible.")
        }
        return parts.joined(separator: "\n")
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

            if let smartCleanupUndoToast = viewModel.smartCleanupUndoToast {
                smartCleanupUndoToastView(smartCleanupUndoToast)
            }

            if let rekordboxStatusText = viewModel.rekordboxStatusText {
                Text(rekordboxStatusText)
                    .font(.caption)
                    .foregroundStyle(viewModel.isRekordboxAssistActive ? Color.primary : Color.red)
            }

            if !viewModel.isManualReviewMode && !viewModel.isRekordboxAssistActive {
                Text("Rekordbox users: In Rekordbox, go to File -> Export collection in xml format, then import that XML here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !viewModel.isScanningExactDuplicates && !viewModel.isRunningSmartCleanup {
                if viewModel.exactDuplicateGroups.isEmpty {
                    ContentUnavailableView(
                        "No Exact Duplicates",
                        systemImage: "checkmark.circle",
                        description: Text("No files in your index share identical content.")
                    )
                } else if viewModel.isManualReviewMode {
                    manualReviewContent
                } else {
                    List {
                        ForEach(viewModel.exactDuplicateGroups) { group in
                            Section {
                                ForEach(group.files) { file in
                                    let isRekordboxMatch = viewModel.isRekordboxMatched(filePath: file.path)
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
                                        VStack(alignment: .trailing, spacing: 6) {
                                            Button("Preview") {
                                                TrackPreviewService.shared.previewTrack(
                                                    atPath: file.path,
                                                    title: file.filename
                                                )
                                            }
                                            .meloBorderedButton()

                                            if isRekordboxMatch {
                                                rekordboxMatchTag
                                            }
                                        }
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
        .disableFocusRings()
        .task(id: viewModel.showExactDuplicateFinder) {
            if viewModel.showExactDuplicateFinder && viewModel.exactDuplicateGroups.isEmpty {
                viewModel.refreshExactDuplicateGroups()
            }
        }
        .confirmationDialog("Smart Cleanup", isPresented: $viewModel.showSmartCleanupConfirmation, titleVisibility: .visible) {
            Button("Clean All Duplicates", role: .destructive) {
                viewModel.runSmartCleanup(scope: .allGroups)
            }
            if viewModel.canUseRekordboxOnlyCleanupScope() {
                Button("Clean Rekordbox Matches Only", role: .destructive) {
                    viewModel.runSmartCleanup(scope: .rekordboxOnly)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(smartCleanupDialogMessage)
        }
        .confirmationDialog(
            "Confirm Manual Session",
            isPresented: $viewModel.showManualSessionConfirmDialog,
            titleVisibility: .visible
        ) {
            Button("Apply Session", role: .destructive) {
                viewModel.confirmManualReviewSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(manualSessionDialogMessage)
        }
        .confirmationDialog(
            "Cancel Manual Session",
            isPresented: $viewModel.showManualSessionCancelDialog,
            titleVisibility: .visible
        ) {
            Button("Discard Session Changes", role: .destructive) {
                viewModel.cancelManualReviewSession()
            }
            Button("Continue Reviewing", role: .cancel) {}
        } message: {
            Text("This will discard all staged Keep/Skip decisions in this manual session and return to overview.")
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
                    let rekordboxMatches = viewModel.rekordboxMatchCount(in: state.group)
                    if rekordboxMatches > 0 {
                        Text("Rekordbox matches: \(rekordboxMatches)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                    }
                }

                Text("Select one keeper. Other files will be moved to Trash when you confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                List {
                    Section {
                        ForEach(state.group.files) { file in
                            manualReviewRow(file: file, state: state)
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

    @ViewBuilder
    private func manualReviewRow(file: ExactDuplicateFileEntry, state: ManualDuplicateGroupState) -> some View {
        let isSelectedKeeper = state.keeperPath == file.path
        let isRekordboxMatch = viewModel.isRekordboxMatched(filePath: file.path)
        let isStagedForTrash = viewModel.manualCurrentGroupStagedRemovalPaths.contains(file.path)
        let rowFillColor: Color = isSelectedKeeper
            ? Color.accentColor.opacity(0.12)
            : (isStagedForTrash ? Color.red.opacity(0.10) : .clear)
        let rowStrokeColor: Color = isSelectedKeeper
            ? Color.accentColor.opacity(0.28)
            : (isStagedForTrash ? Color.red.opacity(0.30) : .clear)

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
            VStack(alignment: .trailing, spacing: 6) {
                Button("Preview") {
                    TrackPreviewService.shared.previewTrack(
                        atPath: file.path,
                        title: file.filename
                    )
                }
                .meloBorderedButton()

                if isRekordboxMatch {
                    rekordboxMatchTag
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(rowStrokeColor, lineWidth: 1)
        )
        .contentShape(.rect)
        .onTapGesture {
            viewModel.selectManualKeeper(path: file.path)
        }
    }

    private var manualStatsText: String {
        let reclaimed = ByteCountFormatter.string(fromByteCount: viewModel.manualReclaimedBytes, countStyle: .file)
        let stagedReclaim = ByteCountFormatter.string(
            fromByteCount: viewModel.manualStagedCleanupEstimatedReclaimBytes,
            countStyle: .file
        )
        return "Staged groups: \(viewModel.manualStagedCleanupGroupCount) | Staged files: \(viewModel.manualStagedCleanupFileCount) | Staged reclaim: \(stagedReclaim) | Applied groups: \(viewModel.manualAppliedGroupsCount) | Removed files: \(viewModel.manualAppliedFilesCount) | Failed: \(viewModel.manualFailedDeleteCount) | Reclaimed: \(reclaimed)"
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            if viewModel.isManualReviewMode {
                Button("Previous") {
                    viewModel.moveToPreviousManualGroup()
                }
                .meloBorderedButton()
                .disabled(viewModel.manualCurrentIndex == 0 || viewModel.isRunningSmartCleanup)

                Button("Skip") {
                    viewModel.skipManualGroup()
                }
                .meloBorderedButton()
                .disabled(viewModel.manualCurrentIndex >= viewModel.manualRemainingGroupsCount - 1 || viewModel.isRunningSmartCleanup)

                Button(viewModel.manualCurrentGroupHasStagedApply ? "Restore" : "Keep Selected, Trash Others") {
                    if viewModel.manualCurrentGroupHasStagedApply {
                        viewModel.restoreCurrentManualGroupAction()
                    } else {
                        viewModel.applyCurrentManualGroup()
                    }
                }
                .meloBorderedButton(destructive: !viewModel.manualCurrentGroupHasStagedApply)
                .disabled(viewModel.manualCurrentGroupState == nil || viewModel.isRunningSmartCleanup)
            } else {
                Button("Manual Review") {
                    viewModel.returnToManualReviewMode()
                }
                .meloBorderedButton()
                .disabled(
                    viewModel.exactDuplicateGroups.isEmpty
                    || viewModel.isScanningExactDuplicates
                    || viewModel.isRunningSmartCleanup
                )

                Picker("Keep rule", selection: $viewModel.smartCleanupKeepRule) {
                    ForEach(SmartCleanupKeepRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .focusable(false)
                .disabled(viewModel.isRunningSmartCleanup)

                Button("Smart Cleanup...") {
                    viewModel.showSmartCleanupConfirmation = true
                }
                .meloBorderedButton(destructive: true)
                .focusable(false)
                .disabled(
                    viewModel.exactDuplicateGroups.isEmpty
                    || viewModel.isScanningExactDuplicates
                    || viewModel.isRunningSmartCleanup
                    || viewModel.isIndexing
                )

                Menu("Tools") {
                    Button("Refresh Scan") {
                        viewModel.refreshExactDuplicateGroups()
                    }
                    .disabled(viewModel.isScanningExactDuplicates || viewModel.isRunningSmartCleanup)

                    Divider()

                    Button("Import Rekordbox XML...") {
                        viewModel.importRekordboxXMLUsingPanel()
                    }
                    .disabled(viewModel.isScanningExactDuplicates || viewModel.isRunningSmartCleanup)

                    if viewModel.isRekordboxAssistActive {
                        Button("Clear Rekordbox Import") {
                            viewModel.clearRekordboxImport()
                        }
                        .disabled(viewModel.isRunningSmartCleanup)
                    }
                }
                .focusable(false)
                .disabled(viewModel.isRunningSmartCleanup)
            }

            Spacer(minLength: 0)

            if viewModel.isManualReviewMode {
                Button("Cancel Session") {
                    viewModel.showManualSessionCancelDialog = true
                }
                .meloBorderedButton()
                .disabled(viewModel.isRunningSmartCleanup)

                Button("Confirm Session") {
                    viewModel.showManualSessionConfirmDialog = true
                }
                .meloBorderedButton(destructive: true)
                .disabled(viewModel.isRunningSmartCleanup || !viewModel.hasManualStagedCleanupActions)
            } else {
                Button("Close") {
                    dismiss()
                }
                .meloBorderedButton()
                .keyboardShortcut(.cancelAction)
                .focusable(false)
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

    private var rekordboxMatchTag: some View {
        Text("Found in Rekordbox")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
    }

    private var smartCleanupDialogMessage: String {
        let allGroups = viewModel.smartCleanupGroupCount(for: .allGroups)
        let allFiles = viewModel.smartCleanupCandidateCount(for: .allGroups)
        let allReclaim = ByteCountFormatter.string(
            fromByteCount: viewModel.smartCleanupEstimatedReclaimBytes(for: .allGroups),
            countStyle: .file
        )

        let rekordboxGroups = viewModel.smartCleanupGroupCount(for: .rekordboxOnly)
        let rekordboxFiles = viewModel.smartCleanupCandidateCount(for: .rekordboxOnly)
        let rekordboxReclaim = ByteCountFormatter.string(
            fromByteCount: viewModel.smartCleanupEstimatedReclaimBytes(for: .rekordboxOnly),
            countStyle: .file
        )

        if viewModel.canUseRekordboxOnlyCleanupScope() {
            return """
            Choose how broad cleanup should be.
            Clean All removes duplicates across your whole indexed library (\(allFiles) files, about \(allReclaim)).
            Rekordbox Only limits cleanup to groups linked to your Rekordbox XML (\(rekordboxFiles) files, about \(rekordboxReclaim)).
            """
        }

        return """
        Clean All will process your full duplicate library (\(allGroups) groups, \(allFiles) files, about \(allReclaim)).
        Import a Rekordbox XML file if you want the Rekordbox-only cleanup option.
        """
    }

    @ViewBuilder
    private func smartCleanupUndoToastView(_ toast: SmartCleanupUndoToast) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(toast.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Undo") {
                    viewModel.undoLastSmartCleanup()
                }
                .meloBorderedButton()
                .disabled(viewModel.isRunningSmartCleanup || viewModel.isScanningExactDuplicates)
            }

            TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
                let remaining = max(0, toast.expiresAt.timeIntervalSince(context.date))
                let progress = min(1, max(0, remaining / 10))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.9))
                        .scaleEffect(x: progress, y: 1, anchor: .leading)
                }
                .frame(height: 6)
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var manualSessionDialogMessage: String {
        let groups = viewModel.manualStagedCleanupGroupCount
        let files = viewModel.manualStagedCleanupFileCount
        let reclaim = ByteCountFormatter.string(
            fromByteCount: viewModel.manualStagedCleanupEstimatedReclaimBytes,
            countStyle: .file
        )

        if files == 0 {
            return "No staged actions to apply. Cancel and keep reviewing, or apply to return to overview."
        }

        return """
        This will move the staged duplicate files to Trash now.
        Groups affected: \(groups)
        Files to move: \(files)
        Estimated reclaim: \(reclaim)
        """
    }
}

struct AboutSettingsView: View {
    var body: some View {
        SettingsPage(title: "About", subtitle: "A focused desktop app for quick audio downloads.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "meloDL") {
                    SettingsTextBlock(text: "meloDL is a lightweight macOS app for downloading and converting audio with a simple, settings-first workflow.")
                }

                SettingsSection(title: "Details") {
                    SettingsRow(title: "Maintainer", description: "Built and maintained by Alexandru Apavaloaiei.") {
                        SecondaryHoverLink(title: "apvl.dev", url: URL(string: "https://apvl.dev")!)
                    }

                    SettingsDivider()

                    SettingsRow(title: "Official website", description: "Product page and release information.") {
                        SecondaryHoverLink(title: "apvl.dev/stuff/meloDL", url: URL(string: "https://apvl.dev/stuff/meloDL")!)
                    }

                    SettingsDivider()

                    SettingsRow(title: "Supported links", description: "Sites supported by the download backend.") {
                        SecondaryHoverLink(title: "yt-dlp sites", url: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!)
                    }
                }
            }
        }
    }
}

struct CreditsSettingsView: View {
    var body: some View {
        SettingsPage(title: "Credits", subtitle: "Tools that made meloDL possible.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "Open Source") {
                    SettingsRow(title: "yt-dlp", description: "Download engine for supported media sites.") {
                        SecondaryHoverLink(title: "Open", url: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                    }

                    SettingsDivider()

                    SettingsRow(title: "ffmpeg", description: "Audio conversion and processing toolkit.") {
                        SecondaryHoverLink(title: "Open", url: URL(string: "https://github.com/FFmpeg/FFmpeg")!)
                    }

                    SettingsDivider()

                    SettingsRow(title: "ffprobe", description: "Media metadata inspection utility.") {
                        SecondaryHoverLink(title: "Open", url: URL(string: "https://ffmpeg.org/ffprobe.html")!)
                    }
                }

                SettingsSection(title: "License") {
                    SettingsTextBlock(text: "meloDL is released under the MIT License.")
                }
            }
        }
    }
}

struct SupportSettingsView: View {
    var body: some View {
        SettingsPage(title: "Support", subtitle: "Get help, report issues, and contact the team.") {
            SettingsSection(title: "Contact") {
                SettingsRow(title: "Email", description: "Copy the support email address.") {
                    SecondaryHoverButton {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("alex@apvl.dev", forType: .string)
                    } label: { isHovered in
                        HStack(spacing: 4) {
                            Text(verbatim: "alex@apvl.dev")
                                .underline(isHovered, color: .secondary)
                            Image(systemName: "doc.on.doc")
                        }
                    }
                    .help("Copy email address")
                }

                SettingsDivider()

                SettingsRow(title: "GitHub Issues", description: "Report bugs or request changes.") {
                    SecondaryHoverLink(title: "Open issues", url: URL(string: "https://github.com/alexapvl/meloDL/issues")!)
                }
            }
        }
    }
}
