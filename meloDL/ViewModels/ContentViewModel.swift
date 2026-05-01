import AppKit
import Foundation
import SwiftUI
import os

@MainActor
class ContentViewModel: ObservableObject {
    @Published var url: String = ""
    @Published var downloads: [DownloadItem] = []
    @Published var statusMessage: String = "Idle"
    @Published var isDownloading: Bool = false
    @Published var ytdlpVersion: String?
    @Published var ffmpegVersion: String?
    @Published var binaryUpdateStatus: String?
    @Published var isShowingDuplicateReview: Bool = false
    @Published private(set) var duplicateReviewItems: [DuplicateReviewItem] = []
    @Published private(set) var duplicateReviewIndex: Int = 0

    let appSettings: AppSettings

    private let downloadEngine = DownloadEngine()
    private let duplicateDetectionService = DuplicateDetectionService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "ContentViewModel")
    private var activeDownloadTask: Task<Void, Never>?
    private var playlistTotalCount = 0
    private var downloadRequestedAt: Date?
    private var startupLogged = false
    @Published private(set) var isCheckingDuplicates = false
    @Published private(set) var isAnalyzingPlaylist = false
    private var cancellationRequested = false
    private var duplicateReviewDecisions: [UUID: DuplicateReviewDecision] = [:]
    private var pendingSingleDuplicateContext: (url: String, title: String)?
    private var pendingPlaylistEntries: [PlaylistEntry] = []
    private var pendingPlaylistSkippedItems: [DownloadItem] = []

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }

    var canDownload: Bool {
        !url.isEmptyOrWhitespace && !isDownloading && !isCheckingDuplicates
    }

    var statusColor: Color {
        if statusMessage.hasPrefix("Cancelled") { return .secondary }
        if statusMessage.hasPrefix("Error") { return .red }
        if let progress = parsePlaylistProgress(statusMessage) {
            return progress.completed == progress.total ? .green : .secondary
        }
        if statusMessage.hasPrefix("Download finished") { return .green }
        return .secondary
    }

    // MARK: - Lifecycle

    func onAppear() {
        Task {
            await bootstrapBinaries()
        }
    }

    private func bootstrapBinaries() async {
        do {
            try await BinaryManager.shared.ensureBinaries()
            do {
                try await TrackIndexStore.shared.ensureReady(defaultRootPath: appSettings.downloadFolderPath)
                try await TrackIndexStore.shared.replaceRoots(with: appSettings.duplicateIndexRoots)
                await TrackIndexer.shared.reindexIfNeeded(roots: appSettings.duplicateIndexRoots)
            } catch {
                logger.warning("Duplicate index bootstrap failed: \(error.localizedDescription)")
            }
            let versions = await BinaryManager.shared.versions
            ytdlpVersion = versions.ytdlp?.version
            ffmpegVersion = versions.ffmpeg?.version

            Task.detached(priority: .utility) {
                await GitHubUpdateService.shared.checkForUpdatesIfNeeded()
                let updatedVersions = await BinaryManager.shared.versions
                await MainActor.run {
                    self.ytdlpVersion = updatedVersions.ytdlp?.version
                    self.ffmpegVersion = updatedVersions.ffmpeg?.version
                }
            }
        } catch {
            statusMessage = "Error: Failed to initialize binaries"
            logger.error("Bootstrap failed: \(error.localizedDescription)")
        }
    }

    func checkForAllUpdates(checkForAppUpdates: () -> Void) {
        binaryUpdateStatus = "Checking..."
        checkForAppUpdates()
        Task.detached(priority: .utility) {
            await GitHubUpdateService.shared.checkForUpdates()
            let versions = await BinaryManager.shared.versions
            await MainActor.run {
                self.ytdlpVersion = versions.ytdlp?.version
                self.ffmpegVersion = versions.ffmpeg?.version
                self.binaryUpdateStatus = "Up to date"
            }
        }
    }

    // MARK: - Download

    func downloadVideo() {
        guard canDownload else {
            if url.isEmptyOrWhitespace {
                statusMessage = "Please enter a URL."
            }
            return
        }

        downloadRequestedAt = Date()
        cancellationRequested = false
        startupLogged = false
        playlistTotalCount = 0

        if isLikelyPlaylistURL(url) {
            isAnalyzingPlaylist = true
            isDownloading = true
            statusMessage = "Idle"
            activeDownloadTask = Task {
                let entries = await downloadEngine.prefetchEntries(from: url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.isDownloading else { return }
                    self.isAnalyzingPlaylist = false
                    if entries.count > 1 {
                        self.preparePlaylistDownloadWithDuplicateCheck(prefetchedEntries: entries)
                    } else {
                        self.startSingleDownload(preloadedTitle: entries.first?.title, deferTitleResolution: false)
                    }
                }
            }
        } else {
            prepareSingleDownloadWithDuplicateCheck()
        }
    }

    func cancelDownloads() {
        cancellationRequested = true
        activeDownloadTask?.cancel()
        activeDownloadTask = nil

        downloadEngine.cancelAllDownloads()

        for index in downloads.indices where downloads[index].status.isActive {
            downloads[index].status = .failed(message: "Cancelled")
        }

        isDownloading = false
        isCheckingDuplicates = false
        isAnalyzingPlaylist = false
        isShowingDuplicateReview = false
        duplicateReviewItems = []
        duplicateReviewIndex = 0
        duplicateReviewDecisions = [:]
        pendingSingleDuplicateContext = nil
        pendingPlaylistEntries = []
        pendingPlaylistSkippedItems = []
        statusMessage = "Cancelled"
        downloadRequestedAt = nil
        startupLogged = false
        playlistTotalCount = 0
    }

    func duplicateReviewDownloadCurrent() {
        applyDecisionForCurrentItem(.downloadAnyway)
    }

    func duplicateReviewSkipCurrent() {
        applyDecisionForCurrentItem(.skip)
    }

    func previewCurrentDuplicateMatch() {
        guard let current = currentDuplicateReviewItem else { return }
        TrackPreviewService.shared.previewTrack(
            atPath: current.match.candidatePath,
            title: current.match.candidateTitle
        )
    }

    func cancelDuplicateReview() {
        isShowingDuplicateReview = false
        duplicateReviewItems = []
        duplicateReviewIndex = 0
        duplicateReviewDecisions = [:]
        pendingSingleDuplicateContext = nil
        pendingPlaylistEntries = []
        pendingPlaylistSkippedItems = []
        isCheckingDuplicates = false
        isAnalyzingPlaylist = false
        isDownloading = false
        activeDownloadTask = nil
        statusMessage = "Cancelled"
    }

    var currentDuplicateReviewItem: DuplicateReviewItem? {
        guard duplicateReviewIndex >= 0, duplicateReviewIndex < duplicateReviewItems.count else { return nil }
        return duplicateReviewItems[duplicateReviewIndex]
    }

    private func prepareSingleDownloadWithDuplicateCheck() {
        let downloadURL = url
        isCheckingDuplicates = true

        activeDownloadTask = Task {
            let resolvedTitle = await downloadEngine.resolveTitleForPreflight(for: downloadURL)
            guard !Task.isCancelled else { return }

            if appSettings.duplicateDetectionEnabled {
                do {
                    await TrackIndexer.shared.reindexIfNeeded(roots: appSettings.duplicateIndexRoots)
                    let matches = try await duplicateDetectionService.findPotentialDuplicates(title: resolvedTitle)
                    if !matches.isEmpty {
                        let items = matches.map { match in
                            DuplicateReviewItem(
                                source: .single(url: downloadURL),
                                incomingTitle: resolvedTitle,
                                incomingURL: downloadURL,
                                match: match
                            )
                        }
                        pendingSingleDuplicateContext = (downloadURL, resolvedTitle)
                        startDuplicateReview(with: items)
                        isCheckingDuplicates = false
                        return
                    }
                } catch {
                    logger.error("Duplicate check failed: \(error.localizedDescription)")
                }
            }

            isCheckingDuplicates = false
            startSingleDownload(sourceURL: downloadURL, preloadedTitle: resolvedTitle, deferTitleResolution: false)
        }
    }

    private func preparePlaylistDownloadWithDuplicateCheck(prefetchedEntries: [PlaylistEntry]) {
        guard appSettings.duplicateDetectionEnabled else {
            startPlaylistDownload(prefetchedEntries: prefetchedEntries)
            return
        }

        isCheckingDuplicates = true

        activeDownloadTask = Task {
            do {
                await TrackIndexer.shared.reindexIfNeeded(roots: appSettings.duplicateIndexRoots)
                var reviewItems: [DuplicateReviewItem] = []

                for entry in prefetchedEntries {
                    let matches = try await duplicateDetectionService.findPotentialDuplicates(title: entry.title)
                    if let first = matches.first {
                        reviewItems.append(
                            DuplicateReviewItem(
                                source: .playlist(url: entry.url),
                                incomingTitle: entry.title,
                                incomingURL: entry.url,
                                match: first
                            )
                        )
                    }
                }

                if !reviewItems.isEmpty {
                    pendingPlaylistEntries = prefetchedEntries
                    startDuplicateReview(with: reviewItems)
                    isCheckingDuplicates = false
                    isDownloading = false
                    return
                }
            } catch {
                logger.error("Playlist duplicate check failed: \(error.localizedDescription)")
            }

            isCheckingDuplicates = false
            startPlaylistDownload(prefetchedEntries: prefetchedEntries)
        }
    }

    private func startSingleDownload(preloadedTitle: String? = nil, deferTitleResolution: Bool = false) {
        startSingleDownload(sourceURL: url, preloadedTitle: preloadedTitle, deferTitleResolution: deferTitleResolution)
    }

    private func startSingleDownload(sourceURL: String, preloadedTitle: String? = nil, deferTitleResolution: Bool = false) {
        cancellationRequested = false
        isAnalyzingPlaylist = false
        isCheckingDuplicates = false
        isDownloading = true
        let downloadURL = sourceURL
        statusMessage = "Starting download..."

        var item = DownloadItem(url: downloadURL)
        item.title = preloadedTitle ?? downloadURL
        downloads = [item]

        activeDownloadTask = Task {
            do {
                let stream = downloadEngine.download(
                    url: downloadURL,
                    config: appSettings.downloadConfiguration,
                    audioSettings: appSettings.audioSettings,
                    preloadedTitle: preloadedTitle,
                    deferTitleResolution: deferTitleResolution
                )
                for try await event in stream {
                    handleEvent(event)
                }
            } catch {
                if Task.isCancelled {
                    statusMessage = "Cancelled"
                } else {
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
            if !cancellationRequested && !Task.isCancelled {
                maybeOpenDownloadFolderIfNeeded()
            }
            isDownloading = false
            activeDownloadTask = nil
        }
    }

    private func startPlaylistDownload(prefetchedEntries: [PlaylistEntry]? = nil) {
        let downloadURL = url
        cancellationRequested = false
        isAnalyzingPlaylist = false
        isCheckingDuplicates = false
        isDownloading = true
        statusMessage = "Reading playlist..."
        downloads = pendingPlaylistSkippedItems
        pendingPlaylistSkippedItems = []

        activeDownloadTask = Task {
            do {
                let stream = downloadEngine.downloadPlaylist(
                    url: downloadURL,
                    config: appSettings.downloadConfiguration,
                    audioSettings: appSettings.audioSettings,
                    prefetchedEntries: prefetchedEntries
                )
                for try await event in stream {
                    handleEvent(event)
                }
                if cancellationRequested || Task.isCancelled {
                    statusMessage = "Cancelled"
                } else {
                    let completedCount = downloads.filter {
                        if case .completed = $0.status { return true }
                        return false
                    }.count
                    statusMessage = "\(completedCount)/\(downloads.count) tracks downloaded"
                    maybeSendCompletionNotification()
                    maybeOpenDownloadFolderIfNeeded()
                }
            } catch {
                if Task.isCancelled {
                    statusMessage = "Cancelled"
                } else {
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
            isDownloading = false
            activeDownloadTask = nil
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: DownloadEvent) {
        switch event {
        case .playlistDiscovered(let entries):
            let activeItems = entries.map { entry in
                var item = DownloadItem(url: entry.url)
                item.title = entry.title
                return item
            }
            downloads.append(contentsOf: activeItems)
            playlistTotalCount = entries.count
            statusMessage = "0/\(entries.count) tracks downloaded"

        case .started(let sourceURL, let title, _):
            if !startupLogged, let requestedAt = downloadRequestedAt {
                let startupMs = Int(Date().timeIntervalSince(requestedAt) * 1_000)
                logger.info("Analyze-to-start latency: \(startupMs)ms")
                startupLogged = true
                downloadRequestedAt = nil
            }
            let idx = indexForURL(sourceURL) ?? appendAndGetIndex(for: sourceURL, fallbackTitle: title)
            downloads[idx].title = title
            downloads[idx].status = .downloading
            if playlistTotalCount <= 1 {
                statusMessage = "Downloading to \(appSettings.downloadFolderPath)"
            }

        case .titleResolved(let sourceURL, let title, _):
            if let idx = indexForURL(sourceURL) {
                downloads[idx].title = title
            }

        case .completed(let sourceURL, let filepath, _):
            if let idx = indexForURL(sourceURL) {
                downloads[idx].status = .completed(filepath: filepath)
            }
            if playlistTotalCount <= 1 {
                statusMessage = "Download finished"
                maybeSendCompletionNotification()
            }

        case .error(let sourceURL, let msg, _):
            if let idx = indexForURL(sourceURL) {
                downloads[idx].status = .failed(message: msg)
            } else {
                var item = DownloadItem(url: sourceURL)
                item.title = sourceURL
                item.status = .failed(message: msg)
                downloads.append(item)
            }
            statusMessage = "Error: \(msg)"

        case .playlistProgress(let completed, let total):
            statusMessage = "\(completed)/\(total) tracks downloaded"
        }
    }

    private func isLikelyPlaylistURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL) else { return false }
        let queryNames = Set((components.queryItems ?? []).map { $0.name.lowercased() })
        if queryNames.contains("list") || queryNames.contains("playlist") {
            return true
        }
        let path = components.path.lowercased()
        return path.contains("/playlist") || path.contains("/sets/")
    }

    private func indexForURL(_ url: String) -> Int? {
        if let active = downloads.firstIndex(where: { $0.url == url && $0.status.isActive }) {
            return active
        }
        return downloads.firstIndex(where: { $0.url == url })
    }

    private func appendAndGetIndex(for url: String, fallbackTitle: String) -> Int {
        var item = DownloadItem(url: url)
        item.title = fallbackTitle
        downloads.append(item)
        return downloads.count - 1
    }

    private func parsePlaylistProgress(_ status: String) -> (completed: Int, total: Int)? {
        guard status.hasSuffix("tracks downloaded") else { return nil }
        let firstToken = status.split(separator: " ").first ?? ""
        let parts = firstToken.split(separator: "/")
        guard parts.count == 2,
              let completed = Int(parts[0]),
              let total = Int(parts[1]),
              total > 0 else {
            return nil
        }
        return (completed, total)
    }

    private func maybeOpenDownloadFolderIfNeeded() {
        guard !cancellationRequested else { return }
        guard appSettings.openFolderOnSuccess else { return }
        let hasCompletedItems = downloads.contains { item in
            if case .completed = item.status { return true }
            return false
        }
        guard hasCompletedItems else { return }
        NSWorkspace.shared.open(appSettings.downloadFolderURL)
    }

    private func maybeSendCompletionNotification() {
        guard !cancellationRequested else { return }
        guard appSettings.notifyOnDownloadCompletion else { return }
        DownloadNotificationService.shared.postDownloadFinishedNotification(folderURL: appSettings.downloadFolderURL)
    }

    private func startDuplicateReview(with items: [DuplicateReviewItem]) {
        guard !items.isEmpty else { return }
        duplicateReviewItems = items
        duplicateReviewIndex = 0
        duplicateReviewDecisions = [:]
        isShowingDuplicateReview = true
    }

    private func applyDecisionForCurrentItem(_ decision: DuplicateReviewDecision) {
        guard let current = currentDuplicateReviewItem else { return }
        duplicateReviewDecisions[current.id] = decision

        if duplicateReviewIndex + 1 < duplicateReviewItems.count {
            duplicateReviewIndex += 1
            return
        }
        finishDuplicateReview()
    }

    private func finishDuplicateReview() {
        isShowingDuplicateReview = false

        let reviewedItems = duplicateReviewItems
        let decisions = duplicateReviewDecisions

        duplicateReviewItems = []
        duplicateReviewIndex = 0
        duplicateReviewDecisions = [:]
        isCheckingDuplicates = false

        if let singleContext = pendingSingleDuplicateContext {
            pendingSingleDuplicateContext = nil
            let shouldDownload = reviewedItems.contains { item in
                decisions[item.id] == .downloadAnyway
            }
            if shouldDownload {
                startSingleDownload(
                    sourceURL: singleContext.url,
                    preloadedTitle: singleContext.title,
                    deferTitleResolution: false
                )
            } else {
                isDownloading = false
                activeDownloadTask = nil
                var skippedItem = DownloadItem(url: singleContext.url)
                skippedItem.title = singleContext.title
                skippedItem.status = .skipped(reason: "Skipped duplicate")
                downloads = [skippedItem]
                statusMessage = "Idle"
            }
            return
        }

        if !pendingPlaylistEntries.isEmpty {
            let entries = pendingPlaylistEntries
            pendingPlaylistEntries = []

            let skippedURLs = Set(reviewedItems.compactMap { item in
                decisions[item.id] == .skip ? item.incomingURL : nil
            })

            let skippedItems: [DownloadItem] = reviewedItems
                .filter { skippedURLs.contains($0.incomingURL) }
                .map { item in
                    var skipped = DownloadItem(url: item.incomingURL)
                    skipped.title = item.incomingTitle
                    skipped.status = .skipped(reason: "Skipped duplicate")
                    return skipped
                }

            let filteredEntries = entries.filter { !skippedURLs.contains($0.url) }
            pendingPlaylistSkippedItems = skippedItems

            if filteredEntries.isEmpty {
                isDownloading = false
                activeDownloadTask = nil
                downloads = skippedItems
                statusMessage = "All duplicate tracks skipped"
                pendingPlaylistSkippedItems = []
            } else {
                startPlaylistDownload(prefetchedEntries: filteredEntries)
            }
        }
    }

}
