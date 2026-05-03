import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct OnboardingView: View {
    @ObservedObject var appSettings: AppSettings
    let onFinish: () -> Void

    @State private var step: Step = .downloads
    @State private var indexedRoots: [String] = []
    @State private var selectedRoot: String?
    @State private var dropTargeted = false
    @State private var showingIndexedFolderPicker = false
    @State private var feedbackMessage: String?
    @State private var notificationStatusText: String?
    @State private var isAdvancing = false
    @State private var showRestartPrompt = false
    @State private var initialMenubarOnlyMode = false
    @State private var didInitialize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            onboardingHeader
            pagedContent
            VStack(spacing: 10) {
                progressDots
                navigationBar
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 640)
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            initialMenubarOnlyMode = appSettings.menubarOnlyMode
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
    }

    private var onboardingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to meloDL")
                .font(.largeTitle.bold())
            Text("Set things up once. You can change any option later in Settings.")
                .foregroundStyle(.secondary)
            // Text("Step \(step.rawValue + 1) of \(Step.allCases.count): \(step.title)")
            //     .font(.caption)
            //     .foregroundStyle(.secondary)
            //     .padding(.top, 2)
        }
    }

    private var pagedContent: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                stepPage(width: width) { downloadsStep }
                stepPage(width: width) { behaviorStep }
                stepPage(width: width) { indexingStep }
            }
            .frame(width: width * CGFloat(Step.allCases.count), alignment: .leading)
            .offset(x: -CGFloat(step.rawValue) * width)
            .animation(.easeInOut(duration: 0.24), value: step)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func stepPage<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(width: width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.windowBackgroundColor).opacity(0.65))
        .clipped()
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { currentStep in
                Capsule(style: .continuous)
                    .fill(currentStep == step ? Color.accentColor : Color.secondary.opacity(0.24))
                    .frame(width: currentStep == step ? 18 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.18), value: step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var navigationBar: some View {
        HStack {
            Button("Back") {
                moveBack()
            }
            .disabled(step.previous == nil || isAdvancing)

            Spacer(minLength: 0)

            Button(step == .indexing ? "Finish" : "Next") {
                moveForward()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAdvancing)
        }
    }

    private var downloadsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Downloads")
                .font(.title2.bold())
            Text("Choose where music is saved and set your default audio options.")
                .foregroundStyle(.secondary)

            onboardingCard(title: "Download Folder") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(appSettings.downloadFolderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.controlBackgroundColor))
                            .clipShape(.rect(cornerRadius: 6))
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Button("Choose Folder") {
                            chooseDownloadFolder()
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                    }
                }
            }

            onboardingCard(title: "Audio Defaults") {
                VStack(alignment: .leading, spacing: 12) {
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
                    Text("Includes artist/title/album tags in downloaded files so music apps can organize tracks correctly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var behaviorStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Behavior")
                .font(.title2.bold())
            Text("Configure how meloDL behaves after downloads and at app launch.")
                .foregroundStyle(.secondary)

            onboardingCard(title: "After Download") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show notification when download finishes", isOn: $appSettings.notifyOnDownloadCompletion)
                        .onChange(of: appSettings.notifyOnDownloadCompletion) { _, newValue in
                            Task {
                                if newValue {
                                    _ = await DownloadNotificationService.shared.requestAuthorizationIfNeeded()
                                }
                                await refreshNotificationStatusText()
                            }
                        }

                    if let notificationStatusText {
                        Text(notificationStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            onboardingCard(title: "App Mode") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Use menubar-only mode", isOn: $appSettings.menubarOnlyMode)
                        .onChange(of: appSettings.menubarOnlyMode) { _, newValue in
                            if !newValue, appSettings.openAtLogin {
                                appSettings.openAtLogin = false
                                LoginItemService.setEnabled(false)
                            }
                        }

                    Toggle("Open meloDL at login", isOn: $appSettings.openAtLogin)
                        .disabled(!appSettings.menubarOnlyMode)
                        .onChange(of: appSettings.openAtLogin) { _, newValue in
                            LoginItemService.setEnabled(newValue)
                        }

                    if !appSettings.menubarOnlyMode {
                        Text("Available only when menubar-only mode is enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var indexingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Indexing")
                .font(.title2.bold())

            Text("Indexing helps prevent duplicate downloads and lets meloDL scan your existing library for duplicate files to clean up.")
                .foregroundStyle(.secondary)

            onboardingCard(title: "Duplicate Detection") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable duplicate detection before download", isOn: $appSettings.duplicateDetectionEnabled)
                }
            }

            onboardingCard(title: "Indexed Folders") {
                VStack(alignment: .leading, spacing: 10) {
                    List(selection: $selectedRoot) {
                        if indexedRoots.isEmpty {
                            Text("No indexed folders yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(indexedRoots, id: \.self) { root in
                                Text(root)
                                    .tag(root)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedRoot = root
                                    }
                            }
                        }
                    }
                    .frame(minHeight: 160, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .listStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.windowBackgroundColor).opacity(0.2))
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
                                removeSelectedRoot()
                            } label: {
                                Image(systemName: "minus")
                                    .frame(width: 18, height: 18)
                            }
                            .disabled(selectedRoot == nil)
                            .buttonStyle(.plain)
                            .frame(width: 28, height: 24)

                            Divider()
                                .frame(height: 16)

                            Button {
                                showingIndexedFolderPicker = true
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 18, height: 18)
                            }
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

                        Text("Tip: Drag and drop folders you keep music in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let feedbackMessage {
                Text(feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func onboardingCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }

    private func moveBack() {
        guard let previous = step.previous else { return }
        step = previous
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.directoryURL = URL(fileURLWithPath: appSettings.downloadFolderPath, isDirectory: true)

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        appSettings.downloadFolderPath = folderURL.path
        proposeRootAddition(path: folderURL.path)
    }

    private func moveForward() {
        switch step {
        case .downloads:
            step = .behavior
        case .behavior:
            Task {
                await moveFromBehaviorToIndexing()
            }
        case .indexing:
            if appSettings.menubarOnlyMode, appSettings.menubarOnlyMode != initialMenubarOnlyMode {
                showRestartPrompt = true
            } else {
                completeOnboarding()
            }
        }
    }

    private func moveFromBehaviorToIndexing() async {
        isAdvancing = true
        defer { isAdvancing = false }

        if appSettings.notifyOnDownloadCompletion {
            _ = await DownloadNotificationService.shared.requestAuthorizationIfNeeded()
        }
        await refreshNotificationStatusText()

        step = .indexing
    }

    private func completeOnboarding() {
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
        guard appSettings.notifyOnDownloadCompletion else {
            notificationStatusText = "Notifications are disabled for download completion."
            return
        }

        let status = await DownloadNotificationService.shared.currentAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            notificationStatusText = "Notification permission: enabled."
        case .denied:
            notificationStatusText = "Notification permission: denied in macOS settings."
        case .notDetermined:
            notificationStatusText = "Notification permission has not been decided yet."
        @unknown default:
            notificationStatusText = "Notification permission status is unknown."
        }
    }

    private func removeSelectedRoot() {
        guard let selectedRoot else { return }
        applyRoots(indexedRoots.filter { $0 != selectedRoot })
        self.selectedRoot = nil
    }

    private func proposeRootAddition(path: String) {
        let overlap = TrackIndexStore.rootOverlap(for: path, existingRootPaths: indexedRoots)
        guard !overlap.proposedRoot.isEmpty else { return }

        if overlap.exactMatch {
            feedbackMessage = "Folder is already in the indexed folders list."
            return
        }

        if let parentRoot = overlap.parentRoot {
            feedbackMessage = "\"\(overlap.proposedRoot)\" is inside already indexed parent \"\(parentRoot)\"."
            return
        }

        if !overlap.childRoots.isEmpty {
            feedbackMessage = "\"\(overlap.proposedRoot)\" contains currently indexed child folders."
            return
        }

        var updated = indexedRoots
        updated.append(overlap.proposedRoot)
        applyRoots(updated)
        feedbackMessage = nil
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

    private enum Step: Int, CaseIterable {
        case downloads
        case behavior
        case indexing

        var title: String {
            switch self {
            case .downloads: return "Downloads"
            case .behavior: return "Behavior"
            case .indexing: return "Indexing"
            }
        }

        var previous: Step? {
            Step(rawValue: rawValue - 1)
        }
    }
}
