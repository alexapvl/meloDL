import AppKit
import Foundation
import SwiftUI
import os

@MainActor
final class DownloadSessionCoordinator: ObservableObject {
    @Published var draftURL = ""
    @Published private(set) var sessions: [DownloadSession] = []
    @Published var selectedSessionID: UUID? {
        didSet {
            acknowledgeAttentionIfNeeded(forDeselected: oldValue, newSelection: selectedSessionID)
        }
    }
    @Published private(set) var isIndexingTracks = false
    @Published var temporaryDownloadFolderPath: String?

    private let appSettings: AppSettings
    private let sessionStore: DownloadSessionStore
    private let duplicateDetectionService: DuplicateDetectionService
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "DownloadSessionCoordinator")
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeEngines: [UUID: DownloadEngine] = [:]
    private var indexerStatusTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var didBootstrap = false

    init(
        appSettings: AppSettings,
        sessionStore: DownloadSessionStore = .shared,
        duplicateDetectionService: DuplicateDetectionService = .shared
    ) {
        self.appSettings = appSettings
        self.sessionStore = sessionStore
        self.duplicateDetectionService = duplicateDetectionService
    }

    var selectedSession: DownloadSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID } ?? sessions.first
    }

    var activeSessionCount: Int {
        sessions.filter { $0.status.isActive }.count
    }

    var hasActiveSessionsForQuit: Bool {
        sessions.contains { $0.status.isActive }
    }

    func onAppear() {
        startIndexerStatusPollingIfNeeded()
        guard !didBootstrap else { return }
        didBootstrap = true
        Task {
            await bootstrapBinaries()
            await loadSessions()
        }
    }

    func submitDraftURL(outputFolderPath: String? = nil) {
        let rawURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return }

        var session = DownloadSession(
            sourceURL: rawURL,
            displayTitle: DownloadSession.fallbackTitle(for: rawURL),
            outputFolderPath: outputFolderPath ?? temporaryDownloadFolderPath ?? appSettings.downloadFolderPath,
            format: appSettings.format
        )
        session.status = .waitingForSlot

        draftURL = ""
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        persist(session)
        scheduleWaitingSessions()
    }

    func selectSession(_ session: DownloadSession) {
        selectedSessionID = session.id
    }

    func maxParallelSessionsDidChange() {
        scheduleWaitingSessions()
    }

    func cancelSession(_ sessionID: UUID) {
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = nil
        activeEngines[sessionID]?.cancelAllDownloads()
        activeEngines[sessionID] = nil
        mutateSession(sessionID) { session in
            session.status = .cancelled
            session.attentionReason = nil
            session.completedAt = Date()
            for index in session.items.indices where session.items[index].status == .queued || session.items[index].status == .downloading || session.items[index].status == .checkingDuplicates || session.items[index].status == .waitingForUser {
                session.items[index].status = .cancelled
                session.items[index].errorMessage = "Cancelled"
            }
        }
        scheduleWaitingSessions()
    }

    func retrySession(_ sessionID: UUID) {
        mutateSession(sessionID) { session in
            session.status = .waitingForSlot
            session.attentionReason = nil
            session.errorMessage = nil
            session.completedAt = nil
            session.attentionAcknowledged = false
            for index in session.items.indices where session.items[index].status == .failed || session.items[index].status == .cancelled {
                session.items[index].status = .queued
                session.items[index].errorMessage = nil
                session.items[index].outputFilePath = nil
            }
        }
        scheduleWaitingSessions()
    }

    func removeSession(_ sessionID: UUID) {
        cancelSession(sessionID)
        sessions.removeAll { $0.id == sessionID }
        if selectedSessionID == sessionID {
            selectedSessionID = sessions.first?.id
        }
        Task {
            do {
                try await sessionStore.deleteSession(id: sessionID)
            } catch {
                logger.error("Failed to delete session: \(error.localizedDescription)")
            }
        }
    }

    func clearCompletedSessions() {
        let removableIDs = sessions
            .filter { $0.status == .completed || $0.status == .completedWithErrors || $0.status == .skipped || $0.status == .cancelled }
            .map(\.id)
        for id in removableIDs {
            removeSession(id)
        }
    }

    func currentDuplicateReviewItem(for sessionID: UUID) -> DuplicateReviewItem? {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let item = session.items.first(where: { $0.status == .waitingForUser && $0.duplicateMatch != nil }),
              let match = item.duplicateMatch else {
            return nil
        }
        return DuplicateReviewItem(
            source: session.kind == .playlist ? .playlist(url: item.sourceURL) : .single(url: item.sourceURL),
            incomingTitle: item.title,
            incomingURL: item.sourceURL,
            match: match.duplicateMatch
        )
    }

    func previewCurrentDuplicateMatch(for sessionID: UUID) {
        guard let item = currentDuplicateReviewItem(for: sessionID) else { return }
        TrackPreviewService.shared.previewTrack(
            atPath: item.match.candidatePath,
            title: item.match.candidateTitle
        )
    }

    func skipCurrentDuplicate(for sessionID: UUID) {
        resolveCurrentDuplicate(for: sessionID, shouldDownload: false)
    }

    func downloadCurrentDuplicateAnyway(for sessionID: UUID) {
        resolveCurrentDuplicate(for: sessionID, shouldDownload: true)
    }

    func skipRemainingDuplicates(for sessionID: UUID) {
        mutateSession(sessionID) { session in
            for index in session.items.indices where session.items[index].status == .waitingForUser && session.items[index].duplicateMatch != nil {
                session.items[index].status = .skipped
            }
            finalizeDuplicateReviewState(in: &session)
        }

        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if session.status == .waitingForSlot {
            scheduleWaitingSessions()
        }
    }

    func cancelActiveSessionsForQuitAndPersist() async {
        var changedSessions: [DownloadSession] = []
        let activeIDs = sessions.filter { $0.status.isActive }.map(\.id)

        for sessionID in activeIDs {
            activeTasks[sessionID]?.cancel()
            activeTasks[sessionID] = nil
            activeEngines[sessionID]?.cancelAllDownloads()
            activeEngines[sessionID] = nil

            guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { continue }
            sessions[index].status = .cancelled
            sessions[index].attentionReason = nil
            sessions[index].completedAt = Date()
            sessions[index].errorMessage = "Cancelled because meloDL was closed."
            for itemIndex in sessions[index].items.indices where sessions[index].items[itemIndex].status == .queued || sessions[index].items[itemIndex].status == .downloading || sessions[index].items[itemIndex].status == .checkingDuplicates || sessions[index].items[itemIndex].status == .waitingForUser {
                sessions[index].items[itemIndex].status = .cancelled
                sessions[index].items[itemIndex].errorMessage = "Cancelled"
            }
            changedSessions.append(sessions[index])
        }

        do {
            try await sessionStore.save(changedSessions)
        } catch {
            logger.error("Failed to persist quit cancellation state: \(error.localizedDescription)")
        }
    }

    private func loadSessions() async {
        do {
            var loaded = try await sessionStore.fetchSessions()
            var changedSessions: [DownloadSession] = []
            for index in loaded.indices where loaded[index].status.isActive {
                loaded[index].status = .cancelled
                loaded[index].completedAt = Date()
                loaded[index].errorMessage = "Cancelled because meloDL was closed."
                changedSessions.append(loaded[index])
            }
            sessions = loaded
            selectedSessionID = loaded.first?.id
            if !changedSessions.isEmpty {
                try await sessionStore.save(changedSessions)
            }
            scheduleWaitingSessions()
        } catch {
            logger.error("Failed to load sessions: \(error.localizedDescription)")
        }
    }

    private func bootstrapBinaries() async {
        do {
            try await BinaryManager.shared.ensureBinaries()
            do {
                try await TrackIndexStore.shared.ensureReady(defaultRootPath: appSettings.downloadFolderPath)
                try await TrackIndexStore.shared.replaceRoots(with: appSettings.duplicateIndexRoots)
            } catch {
                logger.warning("Duplicate index bootstrap failed: \(error.localizedDescription)")
            }
            Task.detached(priority: .utility) {
                await GitHubUpdateService.shared.checkForUpdatesIfNeeded()
            }
        } catch {
            logger.error("Bootstrap failed: \(error.localizedDescription)")
        }
    }

    func checkForAllUpdates(checkForAppUpdates: () -> Void) {
        checkForAppUpdates()
        Task.detached(priority: .utility) {
            await GitHubUpdateService.shared.checkForUpdates()
        }
    }

    private func scheduleWaitingSessions() {
        let cap = AppSettings.clampParallelSessions(appSettings.maxParallelSessions)
        guard activeSessionCount < cap else { return }

        let waitingIDs = sessions
            .filter { $0.status == .waitingForSlot }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)

        for id in waitingIDs {
            guard activeSessionCount < cap else { return }
            let shouldSkipDuplicateCheck = sessions.first(where: { $0.id == id })?.items.isEmpty == false
            startSession(id, skipDuplicateCheck: shouldSkipDuplicateCheck)
        }
    }

    private func startSession(_ sessionID: UUID, skipDuplicateCheck: Bool = false) {
        guard activeTasks[sessionID] == nil else { return }

        let engine = DownloadEngine()
        activeEngines[sessionID] = engine
        mutateSession(sessionID) { session in
            session.status = .preparing
            session.attentionReason = nil
            session.errorMessage = nil
        }

        activeTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            await self.runSession(sessionID, engine: engine, skipDuplicateCheck: skipDuplicateCheck)
        }
    }

    private func runSession(_ sessionID: UUID, engine: DownloadEngine, skipDuplicateCheck: Bool) async {
        guard let initialSession = sessions.first(where: { $0.id == sessionID }) else { return }
        let sourceURL = initialSession.sourceURL

        let entries: [PlaylistEntry]
        if skipDuplicateCheck, !initialSession.items.isEmpty {
            entries = initialSession.items
                .filter { $0.status == .queued || $0.status == .waitingForUser }
                .map { PlaylistEntry(url: $0.sourceURL, title: $0.title) }
        } else {
            entries = await engine.prefetchEntries(from: sourceURL)
        }

        guard !Task.isCancelled else {
            finishCancelledSession(sessionID)
            return
        }

        applyResolvedEntries(entries, to: sessionID)

        if !skipDuplicateCheck && appSettings.duplicateDetectionEnabled {
            await checkDuplicates(for: sessionID, entries: entries)
            guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
            if session.status == .waitingForUser {
                activeTasks[sessionID] = nil
                activeEngines[sessionID] = nil
                notifyIfNeeded(
                    title: "Download needs review",
                    body: session.displayTitle
                )
                scheduleWaitingSessions()
                return
            }
        }

        guard !Task.isCancelled else {
            finishCancelledSession(sessionID)
            return
        }

        await startDownloadPhase(sessionID, engine: engine, entries: entries.filter { entry in
            guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
            guard let item = session.items.first(where: { $0.sourceURL == entry.url }) else { return true }
            return item.status != .skipped
        })
    }

    private func applyResolvedEntries(_ entries: [PlaylistEntry], to sessionID: UUID) {
        mutateSession(sessionID) { session in
            session.kind = entries.count > 1 ? .playlist : .single
            if let first = entries.first {
                session.resolvedTitle = entries.count > 1 ? "Playlist - \(entries.count) tracks" : first.title
                session.displayTitle = session.resolvedTitle ?? session.displayTitle
            }
            if session.items.isEmpty {
                session.items = entries.enumerated().map { index, entry in
                    DownloadSessionItem(
                        sourceURL: entry.url,
                        title: entry.title,
                        status: .queued,
                        itemIndex: index
                    )
                }
            }
        }
    }

    private func checkDuplicates(for sessionID: UUID, entries: [PlaylistEntry]) async {
        mutateSession(sessionID) { session in
            session.status = .checkingDuplicates
            for index in session.items.indices where session.items[index].status == .queued {
                session.items[index].status = .checkingDuplicates
            }
        }

        do {
            await TrackIndexer.shared.reindexIfNeeded(roots: appSettings.duplicateIndexRoots)
            var duplicateSnapshotsByURL: [String: DuplicateMatchSnapshot] = [:]

            for entry in entries {
                let matches = try await duplicateDetectionService.findPotentialDuplicates(title: entry.title)
                if let first = matches.first {
                    duplicateSnapshotsByURL[entry.url] = DuplicateMatchSnapshot(match: first)
                }
            }

            guard !duplicateSnapshotsByURL.isEmpty else {
                mutateSession(sessionID) { session in
                    for index in session.items.indices where session.items[index].status == .checkingDuplicates {
                        session.items[index].status = .queued
                    }
                }
                return
            }

            mutateSession(sessionID) { session in
                session.status = .waitingForUser
                session.attentionReason = .duplicateReview
                for index in session.items.indices {
                    if let snapshot = duplicateSnapshotsByURL[session.items[index].sourceURL] {
                        session.items[index].duplicateMatch = snapshot
                        session.items[index].hadDuplicateMatch = true
                        session.items[index].status = .waitingForUser
                    } else if session.items[index].status == .checkingDuplicates {
                        session.items[index].status = .queued
                    }
                }
            }
        } catch {
            logger.error("Duplicate check failed: \(error.localizedDescription)")
            mutateSession(sessionID) { session in
                for index in session.items.indices where session.items[index].status == .checkingDuplicates {
                    session.items[index].status = .queued
                }
            }
        }
    }

    private func startDownloadPhase(_ sessionID: UUID, engine: DownloadEngine, entries: [PlaylistEntry]) async {
        guard !entries.isEmpty else {
            finishSkippedSessionIfNeeded(sessionID)
            return
        }

        mutateSession(sessionID) { session in
            session.status = .downloading
            session.attentionReason = nil
            for index in session.items.indices where session.items[index].status == .queued || session.items[index].status == .waitingForUser {
                session.items[index].status = .queued
                session.items[index].duplicateMatch = nil
            }
        }

        do {
            if entries.count == 1 {
                let entry = entries[0]
                let stream = engine.download(
                    url: entry.url,
                    config: appSettings.downloadConfiguration,
                    audioSettings: appSettings.audioSettings,
                    preloadedTitle: entry.title,
                    deferTitleResolution: false
                )
                for try await event in stream {
                    handle(event, for: sessionID)
                }
            } else {
                let stream = engine.downloadPlaylist(
                    url: sessions.first(where: { $0.id == sessionID })?.sourceURL ?? entries[0].url,
                    config: appSettings.downloadConfiguration,
                    audioSettings: appSettings.audioSettings,
                    prefetchedEntries: entries
                )
                for try await event in stream {
                    handle(event, for: sessionID)
                }
            }
            finishSessionAfterDownload(sessionID)
        } catch {
            if Task.isCancelled {
                finishCancelledSession(sessionID)
            } else {
                failSession(sessionID, message: error.localizedDescription)
            }
        }

        activeTasks[sessionID] = nil
        activeEngines[sessionID] = nil
        schedulePostDownloadReindex()
        scheduleWaitingSessions()
    }

    private func handle(_ event: DownloadEvent, for sessionID: UUID) {
        switch event {
        case .playlistDiscovered:
            break

        case .playlistProgress:
            break

        case .started(let sourceURL, let title, _):
            mutateItem(sourceURL: sourceURL, in: sessionID) { item in
                item.title = title
                item.status = .downloading
            }

        case .titleResolved(let sourceURL, let title, _):
            mutateItem(sourceURL: sourceURL, in: sessionID) { item in
                item.title = title
            }

        case .completed(let sourceURL, let filepath, _):
            mutateItem(sourceURL: sourceURL, in: sessionID) { item in
                item.outputFilePath = filepath
                item.status = .completed
            }

        case .error(let sourceURL, let message, _):
            mutateItem(sourceURL: sourceURL, in: sessionID) { item in
                item.status = .failed
                item.errorMessage = message
            }
        }
    }

    private func finishSessionAfterDownload(_ sessionID: UUID) {
        mutateSession(sessionID) { session in
            guard session.status != .cancelled else { return }

            let cancelledItems = session.items.filter { $0.status == .cancelled }
            let failedItems = session.items.filter { $0.status == .failed }
            let completedItems = session.items.filter { $0.status == .completed }
            let skippedItems = session.items.filter { $0.status == .skipped }

            session.completedAt = Date()
            if !cancelledItems.isEmpty {
                session.status = .cancelled
                session.attentionReason = nil
                session.errorMessage = session.errorMessage ?? "Cancelled"
            } else if !failedItems.isEmpty && !completedItems.isEmpty {
                session.status = .completedWithErrors
                session.attentionReason = .failed
                session.attentionAcknowledged = false
                session.errorMessage = "\(failedItems.count) of \(session.downloadableItemCount) failed"
            } else if !failedItems.isEmpty {
                session.status = .failed
                session.attentionReason = .failed
                session.attentionAcknowledged = false
                session.errorMessage = failedItems.first?.errorMessage
            } else if completedItems.isEmpty && !skippedItems.isEmpty {
                session.status = .skipped
                session.attentionReason = nil
            } else {
                session.status = .completed
                session.attentionReason = nil
            }
        }

        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if session.status == .failed {
            notifyIfNeeded(title: "Download failed", body: session.displayTitle)
        } else if session.status == .completedWithErrors {
            notifyIfNeeded(
                title: "Download finished with errors",
                body: session.partialFailureNotificationBody ?? session.displayTitle
            )
            maybeOpenDownloadFolderIfNeeded(session)
        } else if session.status == .completed {
            notifyIfNeeded(title: "Download completed", body: session.displayTitle)
            maybeOpenDownloadFolderIfNeeded(session)
        }
    }

    private func finishCancelledSession(_ sessionID: UUID) {
        mutateSession(sessionID) { session in
            session.status = .cancelled
            session.completedAt = Date()
            session.attentionReason = nil
            session.errorMessage = session.errorMessage ?? "Cancelled"
            for index in session.items.indices where session.items[index].status == .queued || session.items[index].status == .downloading || session.items[index].status == .checkingDuplicates || session.items[index].status == .waitingForUser {
                session.items[index].status = .cancelled
                session.items[index].errorMessage = "Cancelled"
            }
        }
        activeTasks[sessionID] = nil
        activeEngines[sessionID] = nil
        scheduleWaitingSessions()
    }

    private func failSession(_ sessionID: UUID, message: String) {
        mutateSession(sessionID) { session in
            session.status = .failed
            session.attentionReason = .failed
            session.attentionAcknowledged = false
            session.completedAt = Date()
            session.errorMessage = message
        }
        notifyIfNeeded(title: "Download failed", body: message)
    }

    private func finishSkippedSessionIfNeeded(_ sessionID: UUID) {
        mutateSession(sessionID) { session in
            session.status = .skipped
            session.attentionReason = nil
            session.completedAt = Date()
        }
        activeTasks[sessionID] = nil
        activeEngines[sessionID] = nil
        scheduleWaitingSessions()
    }

    private func resolveCurrentDuplicate(for sessionID: UUID, shouldDownload: Bool) {
        mutateSession(sessionID) { session in
            guard let itemIndex = session.items.firstIndex(where: { $0.status == .waitingForUser && $0.duplicateMatch != nil }) else { return }
            if shouldDownload {
                session.items[itemIndex].status = .queued
                session.items[itemIndex].duplicateMatch = nil
            } else {
                session.items[itemIndex].status = .skipped
            }

            finalizeDuplicateReviewState(in: &session)
        }

        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if session.status == .waitingForSlot {
            scheduleWaitingSessions()
        }
    }

    private func finalizeDuplicateReviewState(in session: inout DownloadSession) {
        if session.items.contains(where: { $0.status == .waitingForUser && $0.duplicateMatch != nil }) {
            session.status = .waitingForUser
            session.attentionReason = .duplicateReview
        } else {
            session.attentionReason = nil
            let hasQueued = session.items.contains { $0.status == .queued }
            session.status = hasQueued ? .waitingForSlot : .skipped
            if !hasQueued {
                session.completedAt = Date()
            }
        }
    }

    private func acknowledgeAttentionIfNeeded(forDeselected previousID: UUID?, newSelection: UUID?) {
        guard let previousID, previousID != newSelection else { return }
        guard let index = sessions.firstIndex(where: { $0.id == previousID }) else { return }
        guard sessions[index].hasDismissableAttention else { return }

        sessions[index].attentionAcknowledged = true
        persist(sessions[index])
    }

    private func mutateItem(sourceURL: String, in sessionID: UUID, mutation: (inout DownloadSessionItem) -> Void) {
        mutateSession(sessionID) { session in
            if let index = session.items.firstIndex(where: { $0.sourceURL == sourceURL }) {
                mutation(&session.items[index])
            }
        }
    }

    private func mutateSession(_ sessionID: UUID, mutation: (inout DownloadSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        mutation(&sessions[index])
        let session = sessions[index]
        persist(session)
    }

    private func persist(_ session: DownloadSession) {
        let previousTask = persistenceTask
        persistenceTask = Task {
            await previousTask?.value
            do {
                try await sessionStore.save(session)
            } catch {
                logger.error("Failed to persist session: \(error.localizedDescription)")
            }
        }
    }

    private func maybeOpenDownloadFolderIfNeeded(_ session: DownloadSession) {
        guard appSettings.openFolderOnSuccess else { return }
        guard !session.completedFilePaths.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: session.outputFolderPath, isDirectory: true))
    }

    private func notifyIfNeeded(title: String, body: String) {
        guard appSettings.notifyOnSessionEvents else { return }
        guard !NSApp.isActive || appSettings.menubarOnlyMode else { return }
        DownloadNotificationService.shared.postSessionNotification(title: title, body: body)
    }

    private func schedulePostDownloadReindex() {
        let rootsSnapshot = appSettings.duplicateIndexRoots
        guard !rootsSnapshot.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await TrackIndexer.shared.reindexNow(roots: rootsSnapshot)
        }
    }

    private func startIndexerStatusPollingIfNeeded() {
        guard indexerStatusTask == nil else { return }
        indexerStatusTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let status = await TrackIndexer.shared.status()
                self.isIndexingTracks = status.isIndexing
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    deinit {
        indexerStatusTask?.cancel()
        persistenceTask?.cancel()
        for task in activeTasks.values {
            task.cancel()
        }
        for engine in activeEngines.values {
            engine.cancelAllDownloads()
        }
    }
}
