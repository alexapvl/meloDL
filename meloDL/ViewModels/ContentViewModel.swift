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

    let appSettings: AppSettings

    private let downloadEngine = DownloadEngine()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "ContentViewModel")
    private var activeDownloadTask: Task<Void, Never>?
    private var playlistTotalCount = 0
    private var downloadRequestedAt: Date?
    private var startupLogged = false

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }

    var canDownload: Bool {
        !url.isEmptyOrWhitespace && !isDownloading
    }

    var statusColor: Color {
        if statusMessage.hasPrefix("Cancelled") { return .secondary }
        if statusMessage.hasPrefix("Error") { return .red }
        if let progress = parsePlaylistProgress(statusMessage) {
            return progress.completed == progress.total ? .green : .secondary
        }
        if statusMessage.hasPrefix("Downloaded") { return .green }
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

        isDownloading = true
        downloadRequestedAt = Date()
        startupLogged = false
        playlistTotalCount = 0

        if isLikelyPlaylistURL(url) {
            statusMessage = "Analyzing playlist..."
            activeDownloadTask = Task {
                let entries = await downloadEngine.prefetchEntries(from: url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.isDownloading else { return }
                    if entries.count > 1 {
                        self.startPlaylistDownload(prefetchedEntries: entries)
                    } else {
                        self.startSingleDownload(preloadedTitle: entries.first?.title, deferTitleResolution: false)
                    }
                }
            }
        } else {
            startSingleDownload(preloadedTitle: nil, deferTitleResolution: true)
        }
    }

    func cancelDownloads() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil

        downloadEngine.cancelAllDownloads()

        for index in downloads.indices where downloads[index].status.isActive {
            downloads[index].status = .failed(message: "Cancelled")
        }

        isDownloading = false
        statusMessage = "Cancelled"
        downloadRequestedAt = nil
        startupLogged = false
        playlistTotalCount = 0
    }

    private func startSingleDownload(preloadedTitle: String? = nil, deferTitleResolution: Bool = false) {
        let downloadURL = url
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
            maybeOpenDownloadFolderIfNeeded()
            isDownloading = false
            activeDownloadTask = nil
        }
    }

    private func startPlaylistDownload(prefetchedEntries: [PlaylistEntry]? = nil) {
        let downloadURL = url
        statusMessage = "Reading playlist..."
        downloads = []

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
                let completedCount = downloads.filter {
                    if case .completed = $0.status { return true }
                    return false
                }.count
                statusMessage = "\(completedCount)/\(downloads.count) tracks downloaded"
                maybeOpenDownloadFolderIfNeeded()
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
            downloads = entries.map { entry in
                var item = DownloadItem(url: entry.url)
                item.title = entry.title
                return item
            }
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
                statusMessage = "Downloading"
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
                statusMessage = "Downloaded \(URL(fileURLWithPath: filepath).lastPathComponent)"
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
        guard appSettings.openFolderOnSuccess else { return }
        let hasCompletedItems = downloads.contains { item in
            if case .completed = item.status { return true }
            return false
        }
        guard hasCompletedItems else { return }
        NSWorkspace.shared.open(appSettings.downloadFolderURL)
    }
}
