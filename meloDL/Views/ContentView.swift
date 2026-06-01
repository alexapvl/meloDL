import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject private var appSettings: AppSettings
    @ObservedObject private var coordinator: DownloadSessionCoordinator
    private let onOpenSettings: (() -> Void)?

    init(
        appSettings: AppSettings,
        coordinator: DownloadSessionCoordinator,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.appSettings = appSettings
        self.coordinator = coordinator
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        HStack(spacing: 0) {
            SessionSidebar(
                appSettings: appSettings,
                coordinator: coordinator,
                onOpenSettings: onOpenSettings
            )

            Divider()
                .ignoresSafeArea(.container, edges: .top)

            SessionDetailPane(
                appSettings: appSettings,
                coordinator: coordinator,
                session: coordinator.selectedSession
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SessionTheme.contentBackground)
        .frame(minWidth: 580, minHeight: 620)
        .onAppear { coordinator.onAppear() }
        .onChange(of: appSettings.maxParallelSessions) {
            coordinator.maxParallelSessionsDidChange()
        }
    }
}

private struct SessionSidebar: View {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var coordinator: DownloadSessionCoordinator
    let onOpenSettings: (() -> Void)?
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isSettingsHovered = false
    @State private var isFormatHovered = false
    @State private var isDestinationHovered = false
    @State private var sessionPendingDeletion: DownloadSession?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            submitArea

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(historyGroups) { group in
                        if !group.sessions.isEmpty {
                            SessionHistoryGroupView(
                                group: group,
                                selectedSessionID: coordinator.selectedSession?.id,
                                onSelect: coordinator.selectSession,
                                onRequestDelete: requestDeleteConfirmation
                            )
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.hidden)

            sidebarFooter
        }
        .padding(.top, SessionLayout.sidebarTopInset)
        .padding(.bottom, SessionLayout.sidebarBottomPadding)
        .frame(width: SessionLayout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(sidebarBackground)
        .ignoresSafeArea(.container, edges: .top)
        .confirmationDialog(
            "Delete session?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let session = sessionPendingDeletion {
                Button("Confirm delete", role: .destructive) {
                    coordinator.removeSession(session.id)
                    sessionPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            if let session = sessionPendingDeletion {
                Text("This removes \"\(session.displayTitle)\" from the session list.")
            }
        }
    }

    private func requestDeleteConfirmation(for session: DownloadSession) {
        sessionPendingDeletion = session
        isShowingDeleteConfirmation = true
    }

    private func submitDraftURL() {
        coordinator.submitDraftURL()
    }

    private var destinationMenu: some View {
        Menu {
            Button {
                clearDownloadFolderOverride()
            } label: {
                destinationMenuLabel(
                    title: "Default Folder",
                    isSelected: !hasDownloadFolderOverride
                )
            }

            if hasDownloadFolderOverride {
                Label("Current: \(destinationMenuTitle(for: effectiveDownloadFolderPath))", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !indexedDestinationPaths.isEmpty {
                Divider()
                Section("Indexed folders") {
                    ForEach(indexedDestinationPaths, id: \.self) { path in
                        Button {
                            setDownloadFolderOverride(path)
                        } label: {
                            destinationMenuLabel(
                                title: destinationMenuTitle(for: path),
                                isSelected: pathsMatch(effectiveDownloadFolderPath, path)
                            )
                        }
                    }
                }
            }

            Divider()

            Button {
                chooseDownloadFolderOverride()
            } label: {
                Label("Choose folder...", systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: hasDownloadFolderOverride ? "folder.fill" : "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(destinationControlForeground)
                .frame(width: 24, height: 24)
                .background(destinationControlBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isDestinationHovered = $0 }
        .help(destinationHelpText)
    }

    private var formatMenu: some View {
        Menu {
            ForEach(AudioFormat.allCases, id: \.self) { format in
                Button {
                    appSettings.format = format
                } label: {
                    if appSettings.format == format {
                        Label(format.displayName, systemImage: "checkmark")
                    } else {
                        Text(format.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption.weight(.semibold))
                Text(appSettings.format.displayName)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(formatControlForeground)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(formatControlBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isFormatHovered = $0 }
        .help("Format for the next session")
    }

    @ViewBuilder
    private func destinationMenuLabel(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var effectiveDownloadFolderPath: String {
        coordinator.temporaryDownloadFolderPath ?? appSettings.downloadFolderPath
    }

    private var hasDownloadFolderOverride: Bool {
        guard let downloadFolderOverridePath = coordinator.temporaryDownloadFolderPath else { return false }
        return !pathsMatch(downloadFolderOverridePath, appSettings.downloadFolderPath)
    }

    private var indexedDestinationPaths: [String] {
        let defaultPath = canonicalPath(appSettings.downloadFolderPath)
        var seen = Set<String>()
        return appSettings.duplicateIndexRoots
            .map(canonicalPath)
            .filter { !$0.isEmpty && $0 != defaultPath }
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                destinationMenuTitle(for: lhs).localizedStandardCompare(destinationMenuTitle(for: rhs)) == .orderedAscending
            }
    }

    private var destinationHelpText: String {
        if hasDownloadFolderOverride {
            return "Downloads go to \(effectiveDownloadFolderPath) until the app closes.\nThis does not change Settings."
        }
        return "Downloads go to the Settings folder.\nChoose a temporary folder for this app session."
    }

    private func destinationMenuTitle(for path: String) -> String {
        let abbreviatedPath = (path as NSString).abbreviatingWithTildeInPath
        return abbreviatePath(abbreviatedPath, maxLength: 48)
    }

    private func abbreviatePath(_ path: String, maxLength: Int) -> String {
        let components = path.split(separator: "/").map(String.init)
        if path.hasPrefix("~/") {
            let homeRelativePath = components.dropFirst().joined(separator: "/")
            guard homeRelativePath.count > maxLength else { return homeRelativePath }
            guard components.count > 2 else { return homeRelativePath.truncated(to: maxLength) }
            return "\(components[1])/.../\(components.last ?? "")"
        }

        guard path.count > maxLength else { return path }
        guard components.count > 2 else { return path.truncated(to: maxLength) }

        let suffix = components.suffix(2).joined(separator: "/")
        if path.hasPrefix("/") {
            let firstComponent = components.first ?? ""
            return "/\(firstComponent)/.../\(suffix)"
        }
        return "\(components[0])/.../\(suffix)"
    }

    private func setDownloadFolderOverride(_ path: String) {
        let normalizedPath = canonicalPath(path)
        guard !normalizedPath.isEmpty else { return }
        if pathsMatch(normalizedPath, appSettings.downloadFolderPath) {
            clearDownloadFolderOverride()
        } else {
            coordinator.temporaryDownloadFolderPath = normalizedPath
        }
    }

    private func clearDownloadFolderOverride() {
        coordinator.temporaryDownloadFolderPath = nil
    }

    private func chooseDownloadFolderOverride() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: effectiveDownloadFolderPath, isDirectory: true)
        panel.prompt = "Use Folder"
        panel.message = "Choose a temporary download folder for this app session."

        if panel.runModal() == .OK, let url = panel.url {
            setDownloadFolderOverride(url.path)
        }
    }

    private func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private func canonicalPath(_ path: String) -> String {
        TrackIndexStore.canonicalize(path: path)
    }

    private var submitArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("New Session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                destinationMenu
                formatMenu
            }
            .padding(.horizontal, 12)

            NoFocusRingURLField(
                placeholder: "Paste URL",
                text: $coordinator.draftURL,
                onSubmit: submitDraftURL
            )
            .frame(height: 30)
            .padding(.leading, 9)
            .padding(.trailing, 30)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .trailing) {
                Image(systemName: "return")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary.opacity(coordinator.draftURL.isEmptyOrWhitespace ? 0.34 : 0.62))
                    .padding(.trailing, 9)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            }
            .padding(.horizontal, 6)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .overlay(SessionTheme.rowDivider)

            if let onOpenSettings {
                Button(action: onOpenSettings) {
                    settingsButtonLabel
                }
                .buttonStyle(.plain)
                .onHover { isSettingsHovered = $0 }
            } else {
                SettingsLink {
                    settingsButtonLabel
                }
                .buttonStyle(.plain)
                .onHover { isSettingsHovered = $0 }
            }
        }
        .padding(.horizontal, 6)
    }

    private var settingsButtonLabel: some View {
        Label("Settings", systemImage: "gearshape")
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(settingsButtonFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }

    private var settingsButtonFill: Color {
        isSettingsHovered ? Color.primary.opacity(0.08) : .clear
    }

    private var formatControlForeground: Color {
        isFormatHovered ? .primary : Color.secondary
    }

    private var formatControlBackground: Color {
        isFormatHovered ? Color.primary.opacity(0.08) : .clear
    }

    private var destinationControlForeground: Color {
        if hasDownloadFolderOverride {
            return .accentColor
        }
        return isDestinationHovered ? .primary : Color.secondary
    }

    private var destinationControlBackground: Color {
        if hasDownloadFolderOverride && isDestinationHovered {
            return Color.accentColor.opacity(0.14)
        }
        return isDestinationHovered ? Color.primary.opacity(0.08) : .clear
    }

    private var sidebarBackground: Color {
        controlActiveState == .inactive
            ? SessionTheme.sidebarInactiveBackground
            : SessionTheme.sidebarActiveBackground
    }

    private var historyGroups: [SessionHistoryGroup] {
        SessionHistoryGroup.groups(for: coordinator.sessions)
    }
}

private struct SessionHistoryGroupView: View {
    let group: SessionHistoryGroup
    let selectedSessionID: UUID?
    let onSelect: (DownloadSession) -> Void
    let onRequestDelete: (DownloadSession) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(group.sessions) { session in
                    SessionSidebarRow(
                        session: session,
                        isSelected: selectedSessionID == session.id
                    ) {
                        onSelect(session)
                    } onRequestDelete: {
                        onRequestDelete(session)
                    }
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct SessionSidebarRow: View {
    let session: DownloadSession
    let isSelected: Bool
    let action: () -> Void
    let onRequestDelete: () -> Void
    @State private var isHovered = false

    init(
        session: DownloadSession,
        isSelected: Bool,
        action: @escaping () -> Void,
        onRequestDelete: @escaping () -> Void
    ) {
        self.session = session
        self.isSelected = isSelected
        self.action = action
        self.onRequestDelete = onRequestDelete
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    ShimmeringStatusText(
                        text: subtitle,
                        isAnimated: shouldAnimateStatus
                    )
                }

                Spacer(minLength: 0)

                if session.needsAttention {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            if let path = session.firstExistingCompletedFilePath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }

            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Label("Delete session", systemImage: "trash")
            }
        }
        .onHover { isHovered = $0 }
    }

    private var subtitle: String {
        if session.kind == .playlist, let progress = session.downloadableProgress {
            return "\(session.status.displayText) - \(progress.current)/\(progress.total)"
        }
        return session.status.displayText
    }

    private var shouldAnimateStatus: Bool {
        switch session.status {
        case .waitingForSlot, .preparing, .checkingDuplicates, .waitingForUser, .downloading:
            return true
        case .completed, .failed, .cancelled, .skipped:
            return false
        }
    }

    private var iconName: String {
        switch session.status {
        case .waitingForSlot: return "clock"
        case .preparing, .checkingDuplicates: return "magnifyingglass"
        case .waitingForUser: return "exclamationmark.circle"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "xmark.circle"
        case .cancelled: return "slash.circle"
        case .skipped: return "forward.circle"
        }
    }

    private var iconColor: Color {
        switch session.status {
        case .completed: return .green
        case .failed, .waitingForUser: return .orange
        default: return .secondary
        }
    }

    private var rowFill: Color {
        if isSelected { return Color.primary.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}

private struct SessionDetailPane: View {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var coordinator: DownloadSessionCoordinator
    let session: DownloadSession?
    @State private var isRemoveConfirming = false
    @State private var isConfirmingSkipRemaining = false

    var body: some View {
        if let session {
            let reviewItem = coordinator.currentDuplicateReviewItem(for: session.id)
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header(for: session)
                        itemList(for: session)
                    }
                    .frame(maxWidth: SessionLayout.detailContentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 46)
                    .padding(.top, 52)
                    .padding(.bottom, 32)
                }
                .blur(radius: reviewItem == nil ? 0 : 7)
                .disabled(reviewItem != nil)

                if let reviewItem {
                    duplicateReviewOverlay(item: reviewItem, session: session)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .background(SessionTheme.contentBackground)
            .animation(.easeInOut(duration: 0.18), value: reviewItem?.id)
            .onChange(of: session.id) {
                isRemoveConfirming = false
                isConfirmingSkipRemaining = false
            }
        } else {
            ContentUnavailableView(
                "No Sessions",
                systemImage: "arrow.down.circle",
                description: Text("Paste a URL in the sidebar to start a download session.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SessionTheme.contentBackground)
        }
    }

    private func header(for session: DownloadSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(2)

                    Text(session.sourceURL)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                if session.status.isActive {
                    Button("Cancel", role: .destructive) {
                        coordinator.cancelSession(session.id)
                    }
                    .meloBorderedButton(destructive: true)
                }

                if session.status == .failed || session.status == .cancelled {
                    Button("Retry") {
                        coordinator.retrySession(session.id)
                    }
                    .meloBorderedButton()
                }

                if let firstFile = session.firstExistingCompletedFilePath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: firstFile)])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .meloBorderedButton()
                }

                ConfirmingDeleteButton(isConfirming: $isRemoveConfirming) {
                    coordinator.removeSession(session.id)
                }
            }
        }
    }

    @ViewBuilder
    private func duplicateReviewOverlay(item: DuplicateReviewItem, session: DownloadSession) -> some View {
        let total = session.duplicateReviewTotal
        let position = session.duplicateReviewPosition
        let remaining = session.duplicateReviewRemaining

        ZStack {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duplicate Review")
                            .font(.title3.weight(.semibold))
                        Text("Resolve this match to continue the session. Other sessions can keep running.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    VStack(alignment: .trailing, spacing: 8) {
                        Text("\(position)/\(total)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Button(position == 1 ? "Skip all" : "Skip remaining") {
                            isConfirmingSkipRemaining = true
                        }
                        .meloBorderedButton()
                    }
                }

                if appSettings.showDuplicateReviewGestureTip {
                    swipeTipBanner
                        .allowsHitTesting(false)
                }

                DuplicateReviewCard(
                    item: item,
                    onSkip: { coordinator.skipCurrentDuplicate(for: session.id) },
                    onDownloadAnyway: { coordinator.downloadCurrentDuplicateAnyway(for: session.id) },
                    onPreview: { coordinator.previewCurrentDuplicateMatch(for: session.id) }
                )
            }
            .padding(24)
            .frame(maxWidth: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SessionTheme.cardStroke, lineWidth: 1)
            }
            .shadow(radius: 22, y: 12)
            .padding(34)
        }
        .confirmationDialog(
            "Skip remaining duplicates?",
            isPresented: $isConfirmingSkipRemaining,
            titleVisibility: .visible
        ) {
            Button("Skip All", role: .destructive) {
                coordinator.skipRemainingDuplicates(for: session.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remaining \(remaining) duplicate tracks will be skipped and won't be downloaded.")
        }
    }

    private func itemList(for session: DownloadSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.kind == .playlist ? "Tracks" : "Download")
                .font(.title3.weight(.semibold))

            VStack(spacing: 0) {
                let sortedItems = session.items.sorted { $0.itemIndex < $1.itemIndex }
                if sortedItems.isEmpty {
                    ShimmeringStatusText(
                        text: emptyItemListStatusText(for: session),
                        font: .callout,
                        isAnimated: shouldAnimateEmptyItemListStatus(for: session)
                    )
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(sortedItems) { item in
                        SessionItemRow(item: item)
                        if item.id != sortedItems.last?.id {
                            Divider()
                                .overlay(SessionTheme.rowDivider)
                        }
                    }
                }
            }
            .background(SessionTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SessionTheme.cardStroke, lineWidth: 1)
            }
        }
    }

    private func emptyItemListStatusText(for session: DownloadSession) -> String {
        switch session.status {
        case .waitingForSlot:
            return "Waiting for an available session slot."
        case .preparing, .checkingDuplicates, .downloading, .waitingForUser:
            return "Preparing download metadata."
        case .cancelled:
            return DownloadSessionStatus.cancelled.displayText
        case .failed:
            return session.errorMessage ?? DownloadSessionStatus.failed.displayText
        case .completed:
            return DownloadSessionStatus.completed.displayText
        case .skipped:
            return DownloadSessionStatus.skipped.displayText
        }
    }

    private func shouldAnimateEmptyItemListStatus(for session: DownloadSession) -> Bool {
        switch session.status {
        case .waitingForSlot, .preparing, .checkingDuplicates, .waitingForUser, .downloading:
            return true
        case .completed, .failed, .cancelled, .skipped:
            return false
        }
    }

    private var swipeTipBanner: some View {
        HStack(spacing: 12) {
            SwipeGestureTipAnimationView()

            VStack(alignment: .leading, spacing: 4) {
                Text("Tip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.82))
                Text("Swipe with two fingers or drag the card sideways while holding click. You can disable this tip in Settings > Behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .frame(maxWidth: 680)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct SessionItemRow: View {
    let item: DownloadSessionItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                ShimmeringStatusText(
                    text: detailText,
                    font: .caption,
                    isAnimated: item.status == .downloading
                )
            }

            Spacer()

            if let path = item.outputFilePath, FileManager.default.fileExists(atPath: path) {
                Button("Preview") {
                    TrackPreviewService.shared.previewTrack(atPath: path, title: item.title)
                }
                .meloBorderedButton()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var detailText: String {
        if let error = item.errorMessage {
            return error
        }
        if item.duplicateMatch != nil && item.status == .waitingForUser {
            return "Duplicate review needed"
        }
        return item.status.displayText
    }

    private var iconName: String {
        switch item.status {
        case .queued: return "clock"
        case .checkingDuplicates: return "magnifyingglass"
        case .waitingForUser: return "exclamationmark.circle"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .skipped: return "forward.fill"
        }
    }

    private var iconColor: Color {
        switch item.status {
        case .completed: return .green
        case .failed, .waitingForUser: return .orange
        default: return .secondary
        }
    }
}

private struct ConfirmingDeleteButton: View {
    @Binding var isConfirming: Bool
    let onConfirm: () -> Void

    var body: some View {
        Button {
            if isConfirming {
                onConfirm()
                isConfirming = false
            } else {
                isConfirming = true
            }
        } label: {
            Group {
                if isConfirming {
                    Label("Confirm delete", systemImage: "trash")
                } else {
                    Label("Delete session", systemImage: "trash")
                }
            }
        }
        .meloBorderedButton(destructive: true, armed: isConfirming)
    }
}

private struct ShimmeringStatusText: View {
    let text: String
    var font: Font = .caption2
    let isAnimated: Bool
    private let duration: TimeInterval = 1.65

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .overlay {
                if isAnimated {
                    TimelineView(.animation) { timeline in
                        shimmerMask(at: timeline.date)
                    }
                }
            }
    }

    private func shimmerMask(at date: Date) -> some View {
        GeometryReader { proxy in
            let progress = date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            let width = max(proxy.size.width * 0.58, 44)
            let travel = proxy.size.width + width
            LinearGradient(
                colors: [
                    .clear,
                    Color.white.opacity(0.10),
                    Color.white.opacity(0.86),
                    Color.white.opacity(0.10),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width, height: proxy.size.height)
            .offset(x: CGFloat(progress) * travel - width)
        }
        .mask {
            Text(text)
                .font(font)
                .lineLimit(1)
        }
        .allowsHitTesting(false)
    }
}

private struct NoFocusRingURLField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.font = .systemFont(ofSize: 13, weight: .regular)
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingMiddle
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderString = placeholder
        textField.focusRingType = .none
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingMiddle
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        @objc
        func submit() {
            onSubmit()
        }
    }
}

private struct SessionHistoryGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [DownloadSession]

    static func groups(for sessions: [DownloadSession]) -> [SessionHistoryGroup] {
        let calendar = Calendar.current
        let now = Date()
        var today: [DownloadSession] = []
        var yesterday: [DownloadSession] = []
        var previous7: [DownloadSession] = []
        var previous30: [DownloadSession] = []
        var older: [String: [DownloadSession]] = [:]

        for session in sessions.sorted(by: { $0.createdAt > $1.createdAt }) {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: session.createdAt), to: calendar.startOfDay(for: now)).day ?? 0
            switch days {
            case 0:
                today.append(session)
            case 1:
                yesterday.append(session)
            case 2 ... 7:
                previous7.append(session)
            case 8 ... 30:
                previous30.append(session)
            default:
                let title = monthYearTitle(for: session.createdAt)
                older[title, default: []].append(session)
            }
        }

        var groups = [
            SessionHistoryGroup(id: "today", title: "Today", sessions: today),
            SessionHistoryGroup(id: "yesterday", title: "Yesterday", sessions: yesterday),
            SessionHistoryGroup(id: "previous7", title: "Previous 7 Days", sessions: previous7),
            SessionHistoryGroup(id: "previous30", title: "Previous 30 Days", sessions: previous30)
        ]

        let olderGroups = older.keys.sorted { lhs, rhs in
            guard let leftDate = monthYearDate(from: lhs), let rightDate = monthYearDate(from: rhs) else { return lhs > rhs }
            return leftDate > rightDate
        }.map { key in
            SessionHistoryGroup(id: key, title: key, sessions: older[key] ?? [])
        }
        groups.append(contentsOf: olderGroups)
        return groups
    }

    private static func monthYearTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }

    private static func monthYearDate(from title: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.date(from: title)
    }
}

private enum SessionLayout {
    static let sidebarWidth: CGFloat = 230
    static let sidebarTopInset: CGFloat = 64
    static let sidebarBottomPadding: CGFloat = 12
    static let detailContentMaxWidth: CGFloat = 760
}

private enum SessionTheme {
    static let sidebarActiveBackground = Color.black.opacity(0.28)
    static let sidebarInactiveBackground = Color.black.opacity(0.2)
    static let contentBackground = Color(nsColor: .windowBackgroundColor).opacity(0.96)
    static let cardBackground = Color(nsColor: .controlBackgroundColor).opacity(0.52)
    static let cardStroke = Color.secondary.opacity(0.16)
    static let rowDivider = Color.secondary.opacity(0.13)
}
