import Foundation
import os

struct PlaylistEntry: Sendable {
    let url: String
    let title: String
}

enum DownloadEvent: Sendable {
    case playlistDiscovered([PlaylistEntry])
    case started(url: String, title: String, worker: Int?)
    case titleResolved(url: String, title: String, worker: Int?)
    case completed(url: String, filepath: String, worker: Int?)
    case error(url: String, message: String, worker: Int?)
    case playlistProgress(completed: Int, total: Int)
}

struct ProcessOutput {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

final class DownloadEngine {
    private let binaryManager: BinaryManager
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "DownloadEngine")
    private let processRegistry = ProcessRegistry()

    init(binaryManager: BinaryManager = .shared) {
        self.binaryManager = binaryManager
    }

    func cancelAllDownloads() {
        processRegistry.terminateAll()
    }

    // MARK: - Single Download

    func download(
        url: String,
        config: DownloadConfiguration,
        audioSettings: AudioSettings,
        preloadedTitle: String? = nil,
        deferTitleResolution: Bool = false
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamGuard = StreamEmissionGuard()
            Task {
                var titleTask: Task<Void, Never>?
                do {
                    let title: String
                    if let preloadedTitle {
                        title = preloadedTitle
                    } else if deferTitleResolution {
                        title = url
                        titleTask = Task { [weak self] in
                            guard let self else { return }
                            let resolvedTitle = await self.resolveSingleTitle(for: url)
                            guard resolvedTitle != url else { return }
                            guard await streamGuard.canEmit else { return }
                            continuation.yield(.titleResolved(url: url, title: resolvedTitle, worker: nil))
                        }
                    } else {
                        title = await resolveSingleTitle(for: url)
                    }
                    let entry = PlaylistEntry(url: url, title: title)
                    let event = try await runSingleDownload(
                        entry: entry,
                        config: config,
                        audioSettings: audioSettings,
                        workerID: nil,
                        continuation: continuation
                    )
                    continuation.yield(event)
                    await streamGuard.close()
                    titleTask?.cancel()
                    continuation.finish()
                } catch {
                    continuation.yield(.error(url: url, message: error.localizedDescription, worker: nil))
                    await streamGuard.close()
                    titleTask?.cancel()
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func resolveSingleTitle(for url: String) async -> String {
        do {
            let ytdlpPath = await binaryManager.ytdlpPath
            let output = try await runProcess(
                ytdlpPath,
                arguments: [url, "--no-playlist", "--print", "%(title)s", "--skip-download", "--no-warnings"]
            )

            guard output.exitCode == 0 else { return url }

            let title = output.stdout
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? url

            return title
        } catch {
            logger.error("Single title probe failed: \(error.localizedDescription)")
            return url
        }
    }

    // MARK: - Playlist Download

    func downloadPlaylist(
        url: String,
        config: DownloadConfiguration,
        audioSettings: AudioSettings,
        prefetchedEntries: [PlaylistEntry]? = nil
    ) -> AsyncThrowingStream<DownloadEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let entries: [PlaylistEntry]
                    if let prefetchedEntries {
                        entries = prefetchedEntries
                    } else {
                        entries = try await extractPlaylistEntries(from: url)
                    }
                    guard !entries.isEmpty else {
                        continuation.yield(.error(url: url, message: "No items found in playlist", worker: nil))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.playlistDiscovered(entries))
                    continuation.yield(.playlistProgress(completed: 0, total: entries.count))

                    let completed = ActorCounter()
                    let total = entries.count
                    let workerPlan = chooseWorkerPlan(totalItems: total, fastDownloads: config.fastDownloads)
                    let workerCount = workerPlan.effectiveWorkers
                    let queue = PlaylistQueue(items: entries)
                    let playlistStartedAt = Date()
                    logger.info("Playlist starting with \(workerCount) workers (download target: \(workerPlan.downloadWorkers), transcode target: \(workerPlan.transcodeWorkers))")

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for workerID in 1 ... workerCount {
                            group.addTask {
                                while let entry = await queue.next() {
                                    do {
                                        let event = try await self.runSingleDownload(
                                            entry: entry,
                                            config: config,
                                            audioSettings: audioSettings,
                                            workerID: workerID,
                                            continuation: continuation
                                        )
                                        continuation.yield(event)
                                    } catch {
                                        continuation.yield(.error(url: entry.url, message: error.localizedDescription, worker: workerID))
                                    }

                                    let count = await completed.increment()
                                    continuation.yield(.playlistProgress(completed: count, total: total))
                                }
                            }
                        }

                        try await group.waitForAll()
                    }
                    let playlistDurationMs = Int(Date().timeIntervalSince(playlistStartedAt) * 1_000)
                    logger.info("Playlist finished in \(playlistDurationMs)ms (\(total) items)")

                    continuation.finish()
                } catch {
                    continuation.yield(.error(url: url, message: error.localizedDescription, worker: nil))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func prefetchEntries(from url: String) async -> [PlaylistEntry] {
        do {
            let entries = try await extractPlaylistEntries(from: url)
            if !entries.isEmpty {
                return entries
            }
        } catch {
            logger.error("Prefetch playlist entries failed: \(error.localizedDescription)")
        }

        let title = await resolveSingleTitle(for: url)
        return [PlaylistEntry(url: url, title: title)]
    }

    // MARK: - Internal Download Runner

    private func runSingleDownload(
        entry: PlaylistEntry,
        config: DownloadConfiguration,
        audioSettings: AudioSettings,
        workerID: Int?,
        continuation: AsyncThrowingStream<DownloadEvent, Error>.Continuation
    ) async throws -> DownloadEvent {
        let ytdlpPath = await binaryManager.ytdlpPath
        let ffmpegPath = await binaryManager.ffmpegPath
        let outputFolder = config.outputFolder ?? DownloadConfiguration.defaultDownloadFolder
        let startedAt = Date()

        continuation.yield(.started(url: entry.url, title: entry.title, worker: workerID))

        var arguments = [
            entry.url,
            "--ffmpeg-location", ffmpegPath.path,
            "--output", "\(outputFolder.path)/%(title)s.%(ext)s",
            "--no-playlist",
            "--extract-audio",
            "--audio-format", audioSettings.format.rawValue,
            "--audio-quality", audioSettings.quality.ytdlpValue
        ]

        if audioSettings.embedMetadata {
            arguments.append("--embed-metadata")
        }

        if audioSettings.embedThumbnail {
            arguments.append("--embed-thumbnail")
        }

        let output = try await runProcess(ytdlpPath, arguments: arguments)

        if output.exitCode == 0 {
            let filepath = entry.title
            let totalMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            logger.info("Item finished \(entry.url, privacy: .public) in \(totalMs)ms")
            return .completed(url: entry.url, filepath: filepath, worker: workerID)
        }

        let errorMsg = extractErrorMessage(from: output.stderr)
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        logger.error("Item failed \(entry.url, privacy: .public) after \(totalMs)ms: \(errorMsg, privacy: .public)")
        return .error(url: entry.url, message: errorMsg, worker: workerID)
    }

    // MARK: - Playlist URL Extraction

    private func extractPlaylistEntries(from url: String) async throws -> [PlaylistEntry] {
        let ytdlpPath = await binaryManager.ytdlpPath

        let output = try await runProcess(
            ytdlpPath,
            arguments: [url, "--flat-playlist", "--print", "%(title)s\t%(url)s", "--no-warnings"]
        )

        guard output.exitCode == 0 else {
            throw DownloadEngineError.playlistExtractionFailed
        }

        return output.stdout
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.components(separatedBy: "\t")
                if parts.count >= 2, parts[1].hasPrefix("http") {
                    return PlaylistEntry(url: parts[1], title: parts[0].isEmpty ? parts[1] : parts[0])
                }
                if trimmed.hasPrefix("http") {
                    return PlaylistEntry(url: trimmed, title: trimmed)
                }
                return nil
            }
    }

    // MARK: - Process Execution

    private func runProcess(_ executable: URL, arguments: [String]) async throws -> ProcessOutput {
        let processRegistry = self.processRegistry
        let processID = UUID()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                process.terminationHandler = { proc in
                    processRegistry.unregister(processID)

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let result = ProcessOutput(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? ""
                    )
                    continuation.resume(returning: result)
                }

                do {
                    processRegistry.register(process, id: processID)
                    try process.run()
                } catch {
                    processRegistry.unregister(processID)
                    continuation.resume(throwing: error)
                    return
                }
            }
        }, onCancel: {
            processRegistry.terminate(processID)
        })
    }

    private func extractErrorMessage(from stderr: String) -> String {
        let lines = stderr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.last ?? "Unknown error"
    }

    private func chooseWorkerPlan(totalItems: Int, fastDownloads: Bool) -> (downloadWorkers: Int, transcodeWorkers: Int, effectiveWorkers: Int) {
        guard totalItems > 0 else { return (1, 1, 1) }
        guard fastDownloads else { return (1, 1, 1) }

        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let downloadByPlaylistSize: Int
        switch totalItems {
        case 1 ... 3:
            downloadByPlaylistSize = 1
        case 4 ... 10:
            downloadByPlaylistSize = 2
        case 11 ... 20:
            downloadByPlaylistSize = 4
        case 21 ... 40:
            downloadByPlaylistSize = 5
        default:
            downloadByPlaylistSize = 6
        }

        let downloadWorkers = max(1, min(downloadByPlaylistSize, max(2, cores / 2), totalItems))
        let transcodeWorkers = max(1, min(4, max(2, cores / 2), totalItems))
        let effectiveWorkers = max(1, min(downloadWorkers, transcodeWorkers, totalItems))
        return (downloadWorkers, transcodeWorkers, effectiveWorkers)
    }
}

// MARK: - Errors

enum DownloadEngineError: LocalizedError {
    case executableNotFound
    case playlistExtractionFailed
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Required executables not found"
        case .playlistExtractionFailed:
            return "Failed to extract playlist URLs"
        case .downloadFailed(let msg):
            return msg
        }
    }
}

// MARK: - Thread-safe counter for TaskGroup progress

private actor ActorCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

private actor PlaylistQueue {
    private var items: [PlaylistEntry]
    private var index = 0

    init(items: [PlaylistEntry]) {
        self.items = items
    }

    func next() -> PlaylistEntry? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

private actor StreamEmissionGuard {
    private var isOpen = true

    var canEmit: Bool { isOpen }

    func close() {
        isOpen = false
    }
}

private final class ProcessRegistry {
    private var processes: [UUID: Process] = [:]
    private let lock = NSLock()

    func register(_ process: Process, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        processes[id] = process
    }

    func unregister(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        processes[id] = nil
    }

    func terminate(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let process = processes[id] else { return }
        if process.isRunning {
            process.terminate()
        }
        processes[id] = nil
    }

    func terminateAll() {
        lock.lock()
        defer { lock.unlock() }
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
    }
}
