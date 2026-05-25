import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct OnboardingView: View {
    @ObservedObject var appSettings: AppSettings
    let updater: SPUUpdater
    let onFinish: () -> Void

    @State private var step: Step = .downloads
    @State private var highestUnlockedStep: Step = .downloads
    @State private var indexedRoots: [String] = []
    @State private var selectedRoot: String?
    @State private var dropTargeted = false
    @State private var showingIndexedFolderPicker = false
    @State private var feedbackMessage: String?
    @State private var notificationStatusText: String?
    @State private var pendingParentFolderConflict: ParentFolderConflict?
    @State private var automaticallyChecksForUpdates: Bool
    @State private var isAdvancing = false
    @State private var showRestartPrompt = false
    @State private var initialMenubarOnlyMode = false
    @State private var didInitialize = false
    @State private var navigationDirection = 1
    @State private var outgoingStep: Step?
    @State private var slideProgress: CGFloat = 1
    @State private var isSliding = false

    init(appSettings: AppSettings, updater: SPUUpdater, onFinish: @escaping () -> Void) {
        self.appSettings = appSettings
        self.updater = updater
        self.onFinish = onFinish
        _automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        ZStack {
            onboardingBackground

            VStack(spacing: 0) {
                topBar

                Divider()

                HStack(spacing: 0) {
                    stepRail

                    Divider()

                    stage
                }
            }
        }
        .frame(minWidth: 820, idealWidth: 860, minHeight: 600, idealHeight: 640)
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            initialMenubarOnlyMode = appSettings.menubarOnlyMode
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            setupInitialIndexedRoots()
            Task {
                await refreshNotificationStatusText()
            }
        }
        .fileImporter(
            isPresented: $showingIndexedFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls where url.hasDirectoryPath {
                proposeRootAddition(path: url.path)
            }
        }
        .alert("Restart Required", isPresented: $showRestartPrompt) {
            Button("Later", role: .cancel) {
                completeOnboarding()
            }
            Button("Relaunch Now") {
                completeOnboarding()
                AppRelauncher.relaunch(menubarOnly: true)
            }
        } message: {
            Text("Please restart meloDL to apply menubar mode changes.")
        }
        .confirmationDialog(
            "Replace indexed child folders?",
            isPresented: Binding(
                get: { pendingParentFolderConflict != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingParentFolderConflict = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove child folders and keep parent") {
                replaceChildFoldersWithPendingParent()
            }
            Button("Cancel", role: .cancel) {
                pendingParentFolderConflict = nil
            }
        } message: {
            if let pendingParentFolderConflict {
                Text("\"\(pendingParentFolderConflict.parentRoot)\" contains \(pendingParentFolderConflict.childRoots.count) folder\(pendingParentFolderConflict.childRoots.count == 1 ? "" : "s") already in your index.")
            }
        }
    }

    private var onboardingBackground: some View {
        ZStack {
            Color(.windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.12),
                    Color(.windowBackgroundColor).opacity(0.2),
                    Color(.controlBackgroundColor).opacity(0.38)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up meloDL")
                    .font(.title2.bold())
            }

            Spacer(minLength: 0)

            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule(style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Step.allCases, id: \.self) { currentStep in
                Button {
                    guard canSelectStep(currentStep) else { return }
                    move(to: currentStep)
                } label: {
                    OnboardingStepRailRow(
                        step: currentStep,
                        isCurrent: currentStep == step,
                        isComplete: currentStep.rawValue < highestUnlockedStep.rawValue,
                        isLocked: currentStep.rawValue > highestUnlockedStep.rawValue
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(!canSelectStep(currentStep))
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Label("Info", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                Text("All changes will be editable in Settings after onboarding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color(.controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.controlBackgroundColor).opacity(0.22))
    }

    private var stage: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let width = proxy.size.width

                ZStack(alignment: .topLeading) {
                    if let outgoingStep {
                        stagePage(for: outgoingStep)
                            .offset(x: outgoingOffset(width: width))
                    }

                    stagePage(for: step)
                        .offset(x: incomingOffset(width: width))
                }
                .clipped()
            }

            Divider()

            navigationBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stagePage(for displayedStep: Step) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                stageHeader(for: displayedStep)

                switch displayedStep {
                case .downloads:
                    downloadsStep
                case .behavior:
                    behaviorStep
                case .indexing:
                    indexingStep
                case .updates:
                    updatesStep
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stageHeader(for displayedStep: Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: displayedStep.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)

                Text(displayedStep.kicker)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            Text(displayedStep.title)
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Text(displayedStep.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func incomingOffset(width: CGFloat) -> CGFloat {
        guard outgoingStep != nil else { return 0 }
        return CGFloat(navigationDirection) * width * (1 - slideProgress)
    }

    private func outgoingOffset(width: CGFloat) -> CGFloat {
        -CGFloat(navigationDirection) * width * slideProgress
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button {
                moveBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(step.previous == nil || isAdvancing || isSliding)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            Button {
                moveForward()
            } label: {
                HStack(spacing: 6) {
                    Text(step.primaryActionTitle)
                    Image(systemName: step == .updates ? "checkmark" : "chevron.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAdvancing || isSliding || validationMessage != nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.thinMaterial)
    }

    private var downloadsStep: some View {
        DownloadsPreferencesContent(
            appSettings: appSettings,
            style: .onboarding,
            onDownloadFolderSelected: proposeRootAddition(path:)
        )
    }

    private var behaviorStep: some View {
        BehaviorPreferencesContent(
            appSettings: appSettings,
            style: .onboarding,
            notificationDescription: notificationStatusText ?? "Show macOS notifications for session completion, failures, and review prompts.",
            onNotificationChanged: { newValue in
                Task {
                    if newValue {
                        _ = await DownloadNotificationService.shared.requestAuthorizationIfNeeded()
                    }
                    await refreshNotificationStatusText()
                }
            }
        )
    }

    private var indexingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            DuplicateDetectionPreferencesSection(appSettings: appSettings, style: .onboarding)

            IndexedFoldersPreferencesSection(
                style: .onboarding,
                roots: indexedRoots,
                selectedRoot: $selectedRoot,
                dropTargeted: $dropTargeted,
                feedbackMessage: feedbackMessage,
                onAdd: { showingIndexedFolderPicker = true },
                onRemove: removeRoot,
                onDropProviders: handleDrop(providers:)
            )
        }
    }

    private var updatesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpdatesPreferencesContent(
                style: .onboarding,
                updater: updater,
                automaticallyChecks: $automaticallyChecksForUpdates
            )

            PreferencesSummarySection {
                VStack(alignment: .leading, spacing: 10) {
                    SummaryRow(label: "Downloads", value: appSettings.downloadFolderURL.displayName)
                    SummaryRow(label: "Indexing", value: "\(indexedRoots.count) folder\(indexedRoots.count == 1 ? "" : "s")")
                    SummaryRow(label: "Mode", value: appSettings.menubarOnlyMode ? "Menu bar only" : "Windowed app")
                    SummaryRow(label: "Updates", value: automaticallyChecksForUpdates ? "Automatic checks on" : "Manual checks")
                }
            }
        }
    }

    private var validationMessage: String? {
        switch step {
        case .downloads:
            return appSettings.downloadFolderPath.isEmptyOrWhitespace ? "Choose a download folder." : nil
        case .indexing:
            return appSettings.duplicateDetectionEnabled && indexedRoots.isEmpty ? "Add at least one indexed folder." : nil
        case .behavior, .updates:
            return nil
        }
    }

    private func move(to newStep: Step) {
        guard newStep != step else { return }
        guard !isSliding else { return }
        let previousStep = step
        navigationDirection = newStep.rawValue > step.rawValue ? 1 : -1
        outgoingStep = previousStep
        slideProgress = 0
        isSliding = true
        step = newStep

        withAnimation(.easeInOut(duration: 0.24)) {
            slideProgress = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            outgoingStep = nil
            slideProgress = 1
            isSliding = false
        }
    }

    private func canSelectStep(_ candidate: Step) -> Bool {
        guard candidate.rawValue <= highestUnlockedStep.rawValue else { return false }
        guard candidate.rawValue > step.rawValue else { return true }
        return validationMessage == nil
    }

    private func moveBack() {
        guard let previous = step.previous else { return }
        move(to: previous)
    }

    private func moveForward() {
        switch step {
        case .downloads:
            unlockAndMove(to: .behavior)
        case .behavior:
            Task {
                await moveFromBehaviorToIndexing()
            }
        case .indexing:
            unlockAndMove(to: .updates)
        case .updates:
            if appSettings.menubarOnlyMode, appSettings.menubarOnlyMode != initialMenubarOnlyMode {
                showRestartPrompt = true
            } else {
                completeOnboarding()
            }
        }
    }

    private func unlockAndMove(to newStep: Step) {
        highestUnlockedStep = max(highestUnlockedStep, newStep)
        move(to: newStep)
    }

    private func moveFromBehaviorToIndexing() async {
        isAdvancing = true
        defer { isAdvancing = false }

        if appSettings.notifyOnSessionEvents {
            _ = await DownloadNotificationService.shared.requestAuthorizationIfNeeded()
        }
        await refreshNotificationStatusText()

        unlockAndMove(to: .indexing)
    }

    private func completeOnboarding() {
        updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        appSettings.onboardingCompleted = true
        onFinish()
    }

    private func setupInitialIndexedRoots() {
        let existingRoots = appSettings.duplicateIndexRoots
        let downloadPath = appSettings.downloadFolderPath
        let musicPath = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?.path
        indexedRoots = []

        for root in existingRoots {
            appendRootRespectingOverlap(root)
        }

        appendRootRespectingOverlap(downloadPath)
        if let musicPath {
            appendRootRespectingOverlap(musicPath)
        }

        applyRoots(indexedRoots)
    }

    private func appendRootRespectingOverlap(_ path: String) {
        let overlap = TrackIndexStore.rootOverlap(for: path, existingRootPaths: indexedRoots)
        guard !overlap.proposedRoot.isEmpty else { return }
        guard !overlap.exactMatch else { return }
        guard overlap.parentRoot == nil else { return }
        guard overlap.childRoots.isEmpty else { return }
        indexedRoots.append(overlap.proposedRoot)
    }

    private func refreshNotificationStatusText() async {
        guard appSettings.notifyOnSessionEvents else {
            notificationStatusText = "Notifications are disabled for session events."
            return
        }

        let status = await DownloadNotificationService.shared.currentAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            notificationStatusText = "Notification permission is enabled."
        case .denied:
            notificationStatusText = "Notification permission is denied in macOS settings."
        case .notDetermined:
            notificationStatusText = "macOS will ask for notification permission before continuing."
        @unknown default:
            notificationStatusText = "Notification permission status is unknown."
        }
    }

    private func removeRoot(_ root: String) {
        applyRoots(indexedRoots.filter { $0 != root })
        self.selectedRoot = nil
    }

    private func proposeRootAddition(path: String) {
        let overlap = TrackIndexStore.rootOverlap(for: path, existingRootPaths: indexedRoots)
        guard !overlap.proposedRoot.isEmpty else { return }

        if overlap.exactMatch {
            feedbackMessage = "Folder is already indexed."
            return
        }

        if let parentRoot = overlap.parentRoot {
            feedbackMessage = "\"\(overlap.proposedRoot)\" is already covered by \"\(parentRoot)\"."
            return
        }

        if !overlap.childRoots.isEmpty {
            pendingParentFolderConflict = ParentFolderConflict(
                parentRoot: overlap.proposedRoot,
                childRoots: overlap.childRoots
            )
            feedbackMessage = nil
            return
        }

        var updated = indexedRoots
        updated.append(overlap.proposedRoot)
        applyRoots(updated)
        feedbackMessage = nil
    }

    private func replaceChildFoldersWithPendingParent() {
        guard let pendingParentFolderConflict else { return }
        let childRoots = Set(pendingParentFolderConflict.childRoots)
        var updatedRoots = indexedRoots.filter { !childRoots.contains(TrackIndexStore.canonicalize(path: $0)) }
        updatedRoots.append(pendingParentFolderConflict.parentRoot)
        applyRoots(updatedRoots)
        feedbackMessage = nil
        self.pendingParentFolderConflict = nil
    }

    private func applyRoots(_ roots: [String]) {
        let normalized = Array(
            Set(
                roots
                    .map(TrackIndexStore.canonicalize(path:))
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        indexedRoots = normalized
        appSettings.duplicateIndexRoots = normalized

        if let selectedRoot, !normalized.contains(selectedRoot) {
            self.selectedRoot = nil
        }
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
                    proposeRootAddition(path: folderURL.path)
                }
            }
        }
        return true
    }

    fileprivate enum Step: Int, CaseIterable, Comparable {
        case downloads
        case behavior
        case indexing
        case updates

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .downloads: return "Downloads"
            case .behavior: return "Behavior"
            case .indexing: return "Indexing"
            case .updates: return "Updates"
            }
        }

        var kicker: String {
            switch self {
            case .downloads: return "Step 01"
            case .behavior: return "Step 02"
            case .indexing: return "Step 03"
            case .updates: return "Step 04"
            }
        }

        var subtitle: String {
            switch self {
            case .downloads:
                return "Decide where files go and what quality new downloads should use by default."
            case .behavior:
                return "Shape the app around how you want it to behave after work completes."
            case .indexing:
                return "Point meloDL at your library so duplicate checks start from useful data."
            case .updates:
                return "Choose the update behavior, then start using the app."
            }
        }

        var primaryActionTitle: String {
            switch self {
            case .downloads, .behavior, .indexing: return "Continue"
            case .updates: return "Start using meloDL"
            }
        }

        var symbolName: String {
            switch self {
            case .downloads: return "arrow.down.circle"
            case .behavior: return "switch.2"
            case .indexing: return "magnifyingglass"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }

        var previous: Step? {
            Step(rawValue: rawValue - 1)
        }
    }

    private struct ParentFolderConflict {
        let parentRoot: String
        let childRoots: [String]
    }
}

private struct OnboardingStepRailRow: View {
    let step: OnboardingView.Step
    let isCurrent: Bool
    let isComplete: Bool
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(indicatorFill)
                    .frame(width: 28, height: 28)

                Image(systemName: indicatorSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(indicatorForeground)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout.weight(isCurrent ? .semibold : .medium))
                    .foregroundStyle(isLocked ? .secondary : .primary)
                Text(step.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color(.controlBackgroundColor).opacity(0.88) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isCurrent ? Color.blue.opacity(0.28) : Color.clear, lineWidth: 1)
        )
    }

    private var indicatorSymbol: String {
        if isComplete { return "checkmark" }
        if isLocked { return "lock" }
        return step.symbolName
    }

    private var indicatorFill: Color {
        if isCurrent { return Color.blue.opacity(0.18) }
        if isComplete { return Color.green.opacity(0.18) }
        return Color.secondary.opacity(0.12)
    }

    private var indicatorForeground: Color {
        if isCurrent { return .blue }
        if isComplete { return .green }
        return .secondary
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }
}
