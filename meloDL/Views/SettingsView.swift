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
    @State private var selection: SettingsDestination
    @State private var isBackButtonHovered = false
    @State private var pendingDestination: SettingsDestination?
    @State private var showLeaveDuplicatesDialog = false
    @StateObject private var indexingViewModel: IndexingSettingsViewModel
    @Environment(\.controlActiveState) private var controlActiveState

    init(
        updater: SPUUpdater,
        appSettings: AppSettings,
        initialDestination: SettingsDestination = .downloads,
        onDismiss: @escaping () -> Void = {},
        onReplayOnboarding: (() -> Void)? = nil
    ) {
        self.updater = updater
        self.appSettings = appSettings
        self.onDismiss = onDismiss
        _selection = State(initialValue: initialDestination)
        _indexingViewModel = StateObject(wrappedValue: IndexingSettingsViewModel(appSettings: appSettings))
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
                .entrance(x: 28)
                .clipped()
        }
        .background(SettingsTheme.contentBackground)
        .overlay {
            KeyEventMonitor(onEscape: onDismiss)
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 600, idealHeight: 640)
        .environment(\.openURL, OpenURLAction { url in
            guard let destination = SettingsPathLink.destination(for: url) else { return .systemAction }
            selectDestination(destination)
            return .handled
        })
        .onAppear { indexingViewModel.onAppear() }
        .onDisappear { indexingViewModel.onDisappear() }
        .onExitCommand(perform: onDismiss)
        .confirmationDialog(
            "Leave manual review?",
            isPresented: $showLeaveDuplicatesDialog,
            titleVisibility: .visible
        ) {
            Button("Apply Session", role: .destructive) {
                Task {
                    await indexingViewModel.confirmManualReviewSessionAsync()
                    completePendingNavigation()
                }
            }
            Button("Discard Changes", role: .destructive) {
                indexingViewModel.cancelManualReviewSession()
                completePendingNavigation()
            }
            Button("Continue Reviewing", role: .cancel) {
                pendingDestination = nil
            }
        } message: {
            Text("You have staged cleanup actions. Apply them before leaving, discard them, or continue reviewing.")
        }
    }

    private func completePendingNavigation() {
        guard let destination = pendingDestination else { return }
        pendingDestination = nil
        if selection == .duplicates && destination != .duplicates {
            indexingViewModel.onDuplicatesPageDisappeared()
        }
        commitSelection(destination)
    }

    private func selectDestination(_ destination: SettingsDestination) {
        guard destination != selection else { return }

        if selection == .duplicates && destination != .duplicates {
            if indexingViewModel.requiresLeaveDuplicatesConfirmation {
                pendingDestination = destination
                showLeaveDuplicatesDialog = true
                return
            }
            indexingViewModel.onDuplicatesPageDisappeared()
        }

        commitSelection(destination)
    }

    private func commitSelection(_ destination: SettingsDestination) {
        selection = destination
        if destination == .duplicates {
            indexingViewModel.onDuplicatesPageAppeared()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(SettingsDestination.allCases.enumerated()), id: \.element) { index, destination in
                    SettingsSidebarRow(
                        destination: destination,
                        isSelected: selection == destination
                    ) {
                        selectDestination(destination)
                    }
                    .sidebarEntrance(index: index)
                }
            }
            .padding(.horizontal, 6)

            Spacer(minLength: 0)

            sidebarFooter
        }
        .padding(.top, SettingsLayout.sidebarContentTopInset)
        .padding(.bottom, SettingsLayout.sidebarBottomPadding)
        .frame(width: SettingsLayout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(sidebarBackground)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarFooter: some View {
        SidebarFooterSection {
            Button(action: onDismiss) {
                SidebarFooterButtonLabel(
                    title: "Back to app",
                    systemImage: "arrow.left",
                    isHovered: isBackButtonHovered
                )
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { isBackButtonHovered = $0 }
        }
    }

    private var sidebarBackground: Color {
        controlActiveState == .inactive
            ? SettingsTheme.sidebarInactiveBackground
            : SettingsTheme.sidebarActiveBackground
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .downloads:
            DownloadsSettingsView(appSettings: appSettings)
        case .behavior:
            BehaviorSettingsView(appSettings: appSettings)
        case .spotify:
            SpotifySettingsView()
        case .rekordbox:
            RekordboxSettingsView(appSettings: appSettings, viewModel: indexingViewModel)
        case .indexing:
            IndexingSettingsView(appSettings: appSettings, viewModel: indexingViewModel)
        case .duplicates:
            DuplicatesSettingsView(viewModel: indexingViewModel)
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
        .pointerStyle(.link)
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

enum SettingsDestination: String, CaseIterable {
    case downloads
    case behavior
    case spotify
    case rekordbox
    case indexing
    case duplicates
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
        case .spotify: return "Spotify"
        case .rekordbox: return "Rekordbox"
        case .indexing: return "Indexing"
        case .duplicates: return "Duplicates"
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
        case .spotify: return "music.note.list"
        case .rekordbox: return "opticaldisc"
        case .indexing: return "magnifyingglass"
        case .duplicates: return "doc.on.doc"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        case .credits: return "heart.text.square"
        case .support: return "lifepreserver"
        #if DEBUG
        case .debug: return "hammer"
        #endif
        }
    }
}

private enum SettingsLayout {
    static let pageHorizontalPadding: CGFloat = 44
    static let pageTopPadding: CGFloat = 15
    static let pageBottomPadding: CGFloat = 28
    static let sidebarWidth: CGFloat = 230
    static let sidebarContentTopInset: CGFloat = 44
    static let sidebarBottomPadding: CGFloat = 12

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
        .pointerStyle(.link)
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
        .pointerStyle(.link)
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

struct SpotifySettingsView: View {
    @State private var connectedName: String?
    @State private var clientID = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var connectTask: Task<Void, Never>?

    private var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsPage(title: "Spotify", subtitle: "Download songs from Spotify links. meloDL finds each song on YouTube Music.") {
            SettingsSection(title: "Without Connecting") {
                SettingsTextBlock(text: "Paste a Spotify link to download tracks, albums and public playlists. Spotify only shares the first \(SpotifyService.embedTrackLimit) songs of a playlist this way. Connect to also download your Liked Songs and, in full, your own playlists and ones you collaborate on, including private ones.")
            }

            if let connectedName {
                SettingsSection(title: "Account") {
                    SettingsRow(title: "Connected as \(connectedName)", description: "Your own playlists, playlists you collaborate on, and your Liked Songs download in full, with album, year and track number tags.") {
                        Button("Disconnect", role: .destructive) {
                            Task {
                                await SpotifyService.shared.disconnect()
                                self.connectedName = nil
                            }
                        }
                        .meloBorderedButton(destructive: true)
                    }
                }
            } else {
                setupGuide
            }
        }
        .task {
            connectedName = await SpotifyService.shared.connectedAccountName
            if clientID.isEmpty {
                clientID = await SpotifyService.shared.connectedClientID ?? ""
            }
        }
        .onDisappear {
            connectTask?.cancel()
        }
    }

    @ViewBuilder
    private var setupGuide: some View {
        SettingsSection(title: "1. Create a Spotify App") {
            SettingsRow(
                title: "Open the Spotify Developer Dashboard",
                description: "Log in and click Create app. Your Spotify account needs Premium. This is a Spotify rule for personal developer apps."
            ) {
                Button("Open Dashboard") {
                    NSWorkspace.shared.open(SpotifyAuthService.dashboardURL)
                }
                .meloBorderedButton()
            }
        }

        SettingsSection(title: "2. Fill In the Form") {
            copyRow(title: "App name", value: "meloDL")
            SettingsDivider()
            copyRow(title: "App description", value: "Personal meloDL downloads")
            SettingsDivider()
            copyRow(title: "Redirect URI", value: SpotifyAuthService.redirectURI, description: "Paste it, then click Add.")
            SettingsDivider()
            SettingsRow(title: "Which API/SDKs are you planning to use?", description: "Tick Web API, accept the terms, then click Save.") {
                EmptyView()
            }
        }

        SettingsSection(title: "3. Paste Your Client ID") {
            SettingsRow(
                title: "Client ID",
                description: clientIDHint
            ) {
                TextField("32-character code", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(width: 290)
            }
        }

        SettingsSection(title: "4. Connect") {
            SettingsRow(
                title: isConnecting ? "Waiting for Spotify login in your browser…" : "Log in with Spotify",
                description: errorMessage ?? "Your browser opens Spotify's login page. Approve access, then come back here."
            ) {
                if isConnecting {
                    Button("Cancel") {
                        connectTask?.cancel()
                    }
                    .meloBorderedButton()
                } else {
                    Button("Connect Spotify") {
                        connect()
                    }
                    .meloBorderedButton()
                    .disabled(!SpotifyAuthService.isValidClientID(trimmedClientID))
                }
            }
        }
    }

    private var clientIDHint: String {
        if trimmedClientID.isEmpty {
            return "In your app on the dashboard, open Settings and copy the Client ID."
        }
        return SpotifyAuthService.isValidClientID(trimmedClientID)
            ? "Looks good."
            : "A Client ID is 32 letters and numbers. Check that you copied the Client ID, not the Client secret."
    }

    private func copyRow(title: String, value: String, description: String? = nil) -> some View {
        SettingsRow(title: title, description: description) {
            HStack(spacing: 8) {
                Text(value)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .meloBorderedButton()
            }
        }
    }

    private func connect() {
        let clientID = trimmedClientID
        errorMessage = nil
        isConnecting = true
        connectTask = Task {
            do {
                connectedName = try await SpotifyAuthService.connect(clientID: clientID)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

struct RekordboxSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var viewModel: IndexingSettingsViewModel
    @ObservedObject private var rekordboxLibrary = RekordboxLibraryStore.shared
    @ObservedObject private var xmlQueue = RekordboxXMLQueue.shared
    @StateObject private var missingTracks: RekordboxMissingTracksViewModel

    init(appSettings: AppSettings, viewModel: IndexingSettingsViewModel) {
        self.appSettings = appSettings
        self.viewModel = viewModel
        _missingTracks = StateObject(wrappedValue: RekordboxMissingTracksViewModel(appSettings: appSettings))
    }
    @State private var hasAccessibilityAccess = AXIsProcessTrusted()
    @State private var automationPermission: AutomationPermission = .unknown
    @State private var hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()

    var body: some View {
        SettingsPage(title: "Rekordbox", subtitle: "Check downloads against your collection and import them with a genre.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                SettingsSection(title: "Collection") {
                    SettingsRow(title: "Collection import", description: collectionDescription) {
                        HStack(spacing: 8) {
                            if viewModel.isRefreshingRekordbox {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.horizontal, 6)
                            } else {
                                Button("Refresh Now") {
                                    viewModel.refreshRekordboxFromApp()
                                }
                                .meloBorderedButton()
                                .disabled(viewModel.isIndexing)
                                .help("Has the open Rekordbox app export its collection for meloDL. Rekordbox comes to the front for a few seconds.")
                            }

                            Button("Import XML...") {
                                viewModel.importRekordboxXMLUsingPanel()
                            }
                            .meloBorderedButton()
                            .disabled(viewModel.isIndexing || viewModel.isRefreshingRekordbox)
                            .help("Pick a file you exported with File > Export Collection in xml format in Rekordbox.")

                            if viewModel.isRekordboxAssistActive {
                                Button("Clear") {
                                    viewModel.clearRekordboxImport()
                                }
                                .meloBorderedButton()
                                .disabled(viewModel.isRefreshingRekordbox)
                            }
                        }
                    }
                }

                if viewModel.isRekordboxAssistActive {
                    SettingsSection(title: "Import into Rekordbox") {
                        SettingsTextBlock(text: "Pick a genre before downloading in the sidebar, or per track in a session, then use Import to Rekordbox in the session. Rekordbox needs to be open and set to English, and comes to the front while meloDL imports.")

                        SettingsDivider()

                        SettingsRow(
                            title: "Default genre",
                            description: "Used for downloads that don't get a genre."
                        ) {
                            defaultGenreMenu
                        }

                        SettingsDivider()

                        SettingsToggleRow(
                            title: "Keep a playlist of each import",
                            description: "Rekordbox makes a playlist when importing several tracks at once. meloDL removes it unless this is on, and then names it after the session.",
                            isOn: $appSettings.rekordboxKeepsImportPlaylist
                        )
                    }
                }

                if viewModel.isRekordboxAssistActive {
                    SettingsSection(title: "Rekordbox XML") {
                        SettingsRow(
                            title: "meloDL's XML file",
                            description: "Set this file once in Rekordbox under Preferences > Advanced > Database > rekordbox xml. Its tracks then show under rekordbox xml in Rekordbox's sidebar."
                        ) {
                            HStack(spacing: 8) {
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(RekordboxXMLQueue.xmlURL.path, forType: .string)
                                }
                                .meloBorderedButton()

                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([RekordboxXMLQueue.xmlURL])
                                }
                                .meloBorderedButton()
                            }
                        }

                        SettingsDivider()

                        SettingsRow(title: waitingTitle, description: waitingDescription) {
                            if !xmlQueue.tracks.isEmpty {
                                Button("Clear") {
                                    xmlQueue.removeAll()
                                }
                                .meloBorderedButton()
                                .help("Removes all tracks from meloDL's XML. Nothing changes in Rekordbox.")
                            }
                        }
                    }

                    RekordboxMissingTracksSection(
                        appSettings: appSettings,
                        viewModel: missingTracks,
                        genres: rekordboxLibrary.genres
                    )
                }

                SettingsSection(title: "Permissions") {
                    SettingsRow(
                        title: "Accessibility",
                        description: hasAccessibilityAccess
                            ? "Allowed. meloDL can use Rekordbox's File menu."
                            : "Needed to use Rekordbox's File menu for exporting and importing."
                    ) {
                        if hasAccessibilityAccess {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Open System Settings") {
                                openPrivacySettings("Privacy_Accessibility")
                            }
                            .meloBorderedButton()
                        }
                    }

                    SettingsDivider()

                    SettingsRow(
                        title: "Screen Recording",
                        description: hasScreenRecordingAccess
                            ? "Allowed. meloDL reads Rekordbox's window to find and remove the import playlist."
                            : "Lets meloDL read Rekordbox's window to find and remove the playlist an import leaves behind. Without it, imports still work and the playlist stays. macOS may ask you to reopen meloDL after allowing it."
                    ) {
                        if hasScreenRecordingAccess {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Allow...") {
                                if !CGRequestScreenCaptureAccess() {
                                    openPrivacySettings("Privacy_ScreenCapture")
                                }
                                hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
                            }
                            .meloBorderedButton()
                        }
                    }

                    SettingsDivider()

                    SettingsRow(title: "Automation", description: automationDescription) {
                        switch automationPermission {
                        case .granted:
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        case .notDetermined:
                            Button("Allow...") {
                                Task {
                                    automationPermission = await RekordboxAutomationService.shared.systemEventsPermission(ask: true)
                                }
                            }
                            .meloBorderedButton()
                        case .denied, .unknown:
                            Button("Open System Settings") {
                                openPrivacySettings("Privacy_Automation")
                            }
                            .meloBorderedButton()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await refreshAutomationPermission()
        }
        .task {
            await missingTracks.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibilityAccess = AXIsProcessTrusted()
            hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
            Task { await refreshAutomationPermission() }
        }
    }

    private var automationDescription: String {
        switch automationPermission {
        case .granted:
            return "Allowed. meloDL can control System Events."
        case .denied:
            return "Denied. Turn on System Events under meloDL in System Settings."
        case .notDetermined, .unknown:
            return "Needed to control System Events, which presses Rekordbox's menus."
        }
    }

    private func refreshAutomationPermission() async {
        automationPermission = await RekordboxAutomationService.shared.systemEventsPermission(ask: false)
    }

    private var waitingTitle: String {
        switch xmlQueue.tracks.count {
        case 0: return "No tracks waiting"
        case 1: return "1 track waiting"
        case let count: return "\(count) tracks waiting"
        }
    }

    private var waitingDescription: String {
        if xmlQueue.tracks.isEmpty {
            return "Tracks you add to the XML wait here until they're in your collection."
        }
        return "In Rekordbox, refresh the rekordbox xml node in the sidebar, select its tracks and choose Import To Collection. Then press Refresh Now above, and imported tracks leave this list."
    }

    private var collectionDescription: String {
        if let status = viewModel.rekordboxIndexingStatusText {
            return status
        }
        return "Refresh Now exports the collection from the open Rekordbox app. Import XML loads a file you exported yourself with File > Export Collection in xml format."
    }

    private var defaultGenreMenu: some View {
        GenreMenu(
            genres: rekordboxLibrary.genres,
            selection: appSettings.rekordboxDefaultGenre,
            inheritedGenre: nil,
            onSelect: { appSettings.rekordboxDefaultGenre = $0 ?? "" }
        ) {
            HStack(spacing: 6) {
                Text(appSettings.rekordboxDefaultGenre.isEmpty ? "No genre" : appSettings.rekordboxDefaultGenre)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .fixedSize()
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Indexed tracks missing from the Rekordbox collection, grouped by folder.
private struct RekordboxMissingTracksSection: View {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var viewModel: RekordboxMissingTracksViewModel
    let genres: [String]
    @State private var expandedFolders: Set<String> = []
    @State private var isShowingIgnored = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                SettingsSectionTitle(text: "Not in Rekordbox")
                Spacer()
                Text(viewModel.missingCount == 1 ? "1 track" : "\(viewModel.missingCount) tracks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("Tracks in your indexed folders that aren't in your Rekordbox collection. Select some to import them, or ignore folders that don't belong in Rekordbox.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Toggle("Include Apple Music library", isOn: $appSettings.rekordboxIncludesAppleMusicLibrary)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            SettingsCard {
                if viewModel.isLoading && viewModel.folders.isEmpty {
                    SettingsTextBlock(text: "Loading indexed tracks…")
                } else if viewModel.folders.isEmpty {
                    SettingsTextBlock(text: viewModel.searchText.isEmpty
                        ? "Every indexed track is in Rekordbox or waiting in the XML."
                        : "No tracks match your search.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.folders) { folder in
                            if folder.id != viewModel.folders.first?.id {
                                SettingsDivider()
                            }
                            folderRow(folder)
                            if expandedFolders.contains(folder.path) {
                                ForEach(folder.tracks) { track in
                                    trackRow(track)
                                }
                            }
                        }
                    }
                }
            }

            actionBar
            importStatus

            if !viewModel.ignoredFolders.isEmpty {
                ignoredList
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text(viewModel.selection.isEmpty ? "None selected" : "\(viewModel.selection.count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(viewModel.selection.isEmpty ? "Select All" : "Clear") {
                if viewModel.selection.isEmpty {
                    viewModel.selectAll()
                } else {
                    viewModel.clearSelection()
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .disabled(viewModel.folders.isEmpty)

            Spacer()

            GenreMenu(
                genres: genres,
                selection: viewModel.genre,
                inheritedGenre: appSettings.rekordboxDefaultGenre,
                onSelect: { viewModel.genre = $0 }
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .foregroundStyle(.secondary)
                    Text(genreTitle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }
                .contentShape(.rect)
            }
            .fixedSize()
            .help("Genre for the selected tracks")

            Button(viewModel.selection.isEmpty ? "Import to Rekordbox" : "Import \(viewModel.selection.count) to Rekordbox") {
                viewModel.importSelection()
            }
            .meloBorderedButton()
            .disabled(viewModel.selection.isEmpty || viewModel.isImporting)
            .help("Rekordbox needs to be open and comes to the front for a few seconds. Without Accessibility access, the tracks go to meloDL's Rekordbox XML instead.")
        }
    }

    @ViewBuilder
    private var importStatus: some View {
        if let activity = viewModel.importActivity {
            HStack(spacing: 8) {
                switch activity {
                case .importing(let count):
                    ProgressView().controlSize(.small)
                    Text("Importing \(count == 1 ? "1 track" : "\(count) tracks") into Rekordbox. Don't use the mouse or keyboard until it's done.")
                case .removingPlaylist:
                    ProgressView().controlSize(.small)
                    Text("Removing the playlist Rekordbox made for the import.")
                case .refreshing:
                    ProgressView().controlSize(.small)
                    Text("Checking your Rekordbox collection.")
                case .finished(let imported, let leftoverPlaylist):
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text((imported == 1 ? "Imported 1 track." : "Imported \(imported) tracks.")
                        + (leftoverPlaylist.map { " The playlist \"\($0)\" stayed in Rekordbox; delete it there if you don't need it." } ?? ""))
                case .addedToXML(let count, let note):
                    Image(systemName: "tray.and.arrow.down").foregroundStyle(Color.accentColor)
                    Text([note, "Added \(count == 1 ? "1 track" : "\(count) tracks") to meloDL's Rekordbox XML instead."].compactMap { $0 }.joined(separator: " "))
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message)
                }
                Spacer(minLength: 0)
                if !activity.isRunning {
                    Button {
                        viewModel.dismissImportActivity()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var genreTitle: String {
        switch viewModel.genre {
        case nil:
            return appSettings.rekordboxDefaultGenre.isEmpty ? "Genre" : appSettings.rekordboxDefaultGenre
        case "":
            return "No genre"
        case let genre?:
            return genre
        }
    }

    private func folderRow(_ folder: RekordboxMissingTracksViewModel.Folder) -> some View {
        let isExpanded = expandedFolders.contains(folder.path)
        let selectedCount = folder.tracks.filter { viewModel.selection.contains($0.path) }.count
        return HStack(spacing: 10) {
            Button {
                viewModel.toggle(folder)
            } label: {
                Image(systemName: selectedCount == 0 ? "square" : selectedCount == folder.tracks.count ? "checkmark.square.fill" : "minus.square.fill")
                    .foregroundStyle(selectedCount == 0 ? Color.secondary : .accentColor)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel("Select folder")

            Button {
                if isExpanded {
                    expandedFolders.remove(folder.path)
                } else {
                    expandedFolders.insert(folder.path)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text((folder.path as NSString).lastPathComponent)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text("\(folder.tracks.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                Button("Ignore Folder") {
                    viewModel.ignore(folder: folder)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: folder.path, isDirectory: true))
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Folder actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func trackRow(_ track: RekordboxMissingTracksViewModel.Track) -> some View {
        let isSelected = viewModel.selection.contains(track.path)
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.callout)
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let duration = track.durationSec {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 48)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { viewModel.toggle(track) }
        .contextMenu {
            Button("Ignore Track") {
                viewModel.ignore(track: track)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: track.path)])
            }
        }
    }

    private var ignoredList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isShowingIgnored.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isShowingIgnored ? 90 : 0))
                    Text("Ignored (\(viewModel.ignoredFolders.reduce(0) { $0 + $1.tracks.count }) tracks)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isShowingIgnored {
                SettingsCard {
                    ForEach(viewModel.ignoredFolders) { folder in
                        if folder.id != viewModel.ignoredFolders.first?.id {
                            SettingsDivider()
                        }
                        SettingsRow(
                            title: (folder.path as NSString).lastPathComponent,
                            description: "\((folder.path as NSString).abbreviatingWithTildeInPath) · \(folder.tracks.count) tracks"
                        ) {
                            Button("Show Again") {
                                viewModel.unignore(folder: folder)
                            }
                            .meloBorderedButton()
                        }
                    }
                }
            }
        }
    }
}

struct IndexingSettingsView: View {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var viewModel: IndexingSettingsViewModel
    @State private var dropTargeted = false

    var body: some View {
        SettingsPage(title: "Indexing", subtitle: "Configure duplicate detection indexing roots and maintenance.") {
            VStack(alignment: .leading, spacing: SettingsLayout.pageSpacing) {
                DuplicateDetectionPreferencesSection(
                    appSettings: appSettings,
                    style: .settings
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

private struct DuplicatesSettingsView: View {
    @ObservedObject var viewModel: IndexingSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Duplicates")
                        .font(.system(size: 28, weight: .bold))
                    Text("\(viewModel.exactDuplicateGroups.count) groups, \(viewModel.totalExactDuplicateFiles) files in your indexed library.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
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
                    Text(SettingsPathLink.linkify("Load your Rekordbox collection in Settings > Rekordbox to see which duplicates are already in your DJ library."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                duplicateFinderContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: SettingsLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
            .padding(.top, SettingsLayout.pageTopPadding)

            Divider()
                .overlay(SettingsTheme.rowDivider)

            DuplicatesActionBar(viewModel: viewModel)
                .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
                .padding(.vertical, SettingsLayout.sidebarBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsTheme.contentBackground)
        .disableFocusRings()
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

    @ViewBuilder
    private var duplicateFinderContent: some View {
        if viewModel.isScanningExactDuplicates || viewModel.isRunningSmartCleanup {
            Spacer(minLength: 0)
        } else if viewModel.exactDuplicateGroups.isEmpty {
            ContentUnavailableView(
                "No Exact Duplicates",
                systemImage: "checkmark.circle",
                description: Text("No files in your index share identical content.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.isManualReviewMode {
            manualReviewContent
        } else {
            List {
                ForEach(Array(viewModel.exactDuplicateGroups.enumerated()), id: \.element.id) { index, group in
                    Section {
                        ForEach(group.files) { file in
                            let isRekordboxMatch = viewModel.isRekordboxMatched(filePath: file.path)
                            let isFirstRowInSection = file.id == group.files.first?.id
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
                            .listRowSeparator(isFirstRowInSection ? .hidden : .visible, edges: .top)
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
                    .listSectionSeparator(index == 0 ? .hidden : .visible, edges: .top)
                }
            }
            .listStyle(.inset)
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
                            manualReviewRow(
                                file: file,
                                state: state,
                                hidesTopRowSeparator: file.id == state.group.files.first?.id
                            )
                        }
                    } header: {
                        Text("Hash \(state.group.contentHash.prefix(12))... (\(state.group.files.count) files)")
                    }
                    .listSectionSeparator(.hidden, edges: .top)
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
    private func manualReviewRow(
        file: ExactDuplicateFileEntry,
        state: ManualDuplicateGroupState,
        hidesTopRowSeparator: Bool = false
    ) -> some View {
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
            .pointerStyle(.link)
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
        .listRowSeparator(hidesTopRowSeparator ? .hidden : .visible, edges: .top)
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

private struct DuplicatesActionBar: View {
    @ObservedObject var viewModel: IndexingSettingsViewModel

    var body: some View {
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

                Spacer(minLength: 0)

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
                Button("Manual Review") {
                    viewModel.returnToManualReviewMode()
                }
                .meloBorderedButton()
                .disabled(
                    viewModel.exactDuplicateGroups.isEmpty
                    || viewModel.isScanningExactDuplicates
                    || viewModel.isRunningSmartCleanup
                )

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

                Spacer(minLength: 0)

                Picker("Keep rule", selection: $viewModel.smartCleanupKeepRule) {
                    ForEach(SmartCleanupKeepRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .focusable(false)
                .disabled(viewModel.isRunningSmartCleanup)
            }
        }
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
                    SettingsTextBlock(text: "meloDL is released under the GNU General Public License v3.0.")
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

                SettingsDivider()

                SettingsRow(
                    title: "Error Log",
                    description: "meloDL records errors in a file on your Mac. When reporting a problem, attach it to your email or GitHub issue. It can include song names, links and file paths."
                ) {
                    Button("Show in Finder") {
                        ErrorLog.ensureFileExists()
                        NSWorkspace.shared.activateFileViewerSelecting([ErrorLog.fileURL])
                    }
                    .meloBorderedButton()
                }
            }
        }
    }
}
