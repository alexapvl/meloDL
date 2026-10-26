import AppKit
import Foundation
import SwiftUI
import os

enum SessionReview: Identifiable {
    case duplicate(DuplicateReviewItem)
    case match(DownloadSessionItem, SpotifyItemInfo)

    var id: UUID {
        switch self {
        case .duplicate(let item): return item.id
        case .match(let item, _): return item.id
        }
    }
}

enum RekordboxImportActivity: Equatable {
    case importing(count: Int)
    case removingPlaylist
    case refreshing
    /// `leftoverPlaylist` names an import playlist meloDL couldn't safely remove.
    case finished(imported: Int, leftoverPlaylist: String?)
    /// Written to meloDL's Rekordbox XML; `note` explains why Rekordbox couldn't be driven.
    case addedToXML(count: Int, note: String?)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .importing, .removingPlaylist, .refreshing: return true
        case .finished, .addedToXML, .failed: return false
        }
    }

    init(_ step: RekordboxImporter.Step) {
        switch step {
        case .importing(let count): self = .importing(count: count)
        case .removingPlaylist: self = .removingPlaylist
        case .refreshing: self = .refreshing
        }
    }

    init(_ outcome: RekordboxImporter.Outcome) {
        switch outcome {
        case .imported(let count, let leftoverPlaylist): self = .finished(imported: count, leftoverPlaylist: leftoverPlaylist)
        case .addedToXML(let count, let note): self = .addedToXML(count: count, note: note)
        }
    }
}

@MainActor
final class DownloadSessionCoordinator: ObservableObject {
    @Published var draftURL = ""
    /// Rekordbox genre for the next session. nil leaves it to the default genre.
    @Published var draftGenre: String?
    @Published private(set) var rekordboxImportActivity: [UUID: RekordboxImportActivity] = [:]
    @Published private(set) var sessions: [DownloadSession] = []
    @Published var selectedSessionID: UUID? {
        didSet {
            acknowledgeAttentionIfNeeded(forDeselected: oldValue, newSelection: selectedSessionID)
            if let trimTarget, trimTarget.sessionID != selectedSessionID {
                self.trimTarget = nil
            }
        }
    }
    @Published private(set) var trimTarget: TrimTarget?
    @Published private(set) var isIndexingTracks = false
    @Published private(set) var isSpotifyConnected = false
    @Published var temporaryDownloadFolderPath: String?

    private let appSettings: AppSettings
    private let sessionStore: DownloadSessionStore
    private let duplicateDetectionService: DuplicateDetectionService
    private let rekordboxLibraryStore: RekordboxLibraryStore
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "DownloadSessionCoordinator")
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeEngines: [UUID: DownloadEngine] = [:]
    private var indexerStatusTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var didBootstrap = false

    init(
        appSettings: AppSettings,
        sessionStore: DownloadSessionStore = .shared,
        duplicateDetectionService: DuplicateDetectionService = .shared,
        rekordboxLibraryStore: RekordboxLibraryStore = .shared
    ) {
        self.appSettings = appSettings
        self.sessionStore = sessionStore
        self.duplicateDetectionService = duplicateDetectionService
        self.rekordboxLibraryStore = rekordboxLibraryStore
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
        Task {
            isSpotifyConnected = await SpotifyService.shared.connectedAccountName != nil
        }
        Task {
            await rekordboxLibraryStore.reloadIfSourceChanged()
        }
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
            format: appSettings.format,
            genre: isRekordboxGenreAvailable(for: appSettings.format) ? draftGenre : nil
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

    #if DEBUG
    /// Moves a stopped session's finished files to `folderPath` and downloads the rest there.
    func relocateSession(_ sessionID: UUID, to folderPath: String) throws {
        guard let session = sessions.first(where: { $0.id == sessionID }), !session.status.isActive else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)

        var movedPaths: [UUID: String] = [:]
        for item in session.items {
            guard let path = item.outputFilePath, fileManager.fileExists(atPath: path) else { continue }
            let destination = (folderPath as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            if !fileManager.fileExists(atPath: destination) {
                try fileManager.moveItem(atPath: path, toPath: destination)
            }
            movedPaths[item.id] = destination
        }
        mutateSession(sessionID) { session in
            session.outputFolderPath = folderPath
            for index in session.items.indices {
                if let moved = movedPaths[session.items[index].id] {
                    session.items[index].outputFilePath = moved
                }
            }
        }
    }
    #endif

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

    func makeTrimTarget(forFileAt path: String?, title: String, in sessionID: UUID) -> TrimTarget? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        let fileURL = URL(fileURLWithPath: path)
        guard let format = AudioTrimFormat(fileURL: fileURL) else { return nil }
        return TrimTarget(sessionID: sessionID, fileURL: fileURL, title: title, format: format)
    }

    /// Single-track sessions only; playlists pick a track from the detail list.
    func makeTrimTarget(for session: DownloadSession) -> TrimTarget? {
        guard session.kind != .playlist,
              let item = session.items.first(where: { $0.outputFilePath == session.firstExistingCompletedFilePath }) else { return nil }
        return makeTrimTarget(forFileAt: item.outputFilePath, title: item.title, in: session.id)
    }

    func openTrimEditor(_ target: TrimTarget) {
        selectedSessionID = target.sessionID
        trimTarget = target
    }

    func closeTrimEditor() {
        trimTarget = nil
    }

    func trimmedFileDidChange() {
        schedulePostDownloadReindex()
    }

    func removeSession(_ sessionID: UUID) {
        if trimTarget?.sessionID == sessionID {
            trimTarget = nil
        }
        cancelSession(sessionID)
        sessions.removeAll { $0.id == sessionID }
        if selectedSessionID == sessionID {
            selectedSessionID = sessions.first?.id
        }
        Task {
            do {
                try await sessionStore.deleteSession(id: sessionID)
            } catch {
                logger.failure("Failed to delete session: \(error.localizedDescription)")
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

    /// Duplicate and YouTube Music match reviews share one queue, in track order.
    func currentReview(for sessionID: UUID) -> SessionReview? {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let item = session.items
                .sorted(by: { $0.itemIndex < $1.itemIndex })
                .first(where: { $0.status == .waitingForUser }) else { return nil }
        if item.duplicateMatch != nil, let duplicate = currentDuplicateReviewItem(for: sessionID) {
            return .duplicate(duplicate)
        }
        if let info = item.spotify, item.needsMatchReview {
            return .match(item, info)
        }
        return nil
    }

    func skipAllPendingReviews(for sessionID: UUID) {
        mutateSession(sessionID) { session in
            for index in session.items.indices where session.items[index].status == .waitingForUser {
                session.items[index].status = .skipped
            }
            finalizeReviewState(in: &session)
        }
        scheduleWaitingSessionsIfReady(sessionID)
    }

    func currentDuplicateReviewItem(for sessionID: UUID) -> DuplicateReviewItem? {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let item = session.items.first(where: { $0.status == .waitingForUser && $0.duplicateMatch != nil }),
              let match = item.duplicateMatch else {
            return nil
        }
        return DuplicateReviewItem(
            id: item.id,
            source: session.kind == .playlist ? .playlist(url: item.sourceURL) : .single(url: item.sourceURL),
            incomingTitle: item.title,
            incomingURL: item.sourceURL,
            match: match.duplicateMatch,
            isMatchInRekordbox: rekordboxLibraryStore.contains(path: match.candidatePath)
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
            logger.failure("Failed to persist quit cancellation state: \(error.localizedDescription)")
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
            logger.failure("Failed to load sessions: \(error.localizedDescription)")
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
            logger.failure("Bootstrap failed: \(error.localizedDescription)")
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
            guard let session = sessions.first(where: { $0.id == id }) else { continue }
            guard !session.hasPendingReview else { continue }
            let shouldSkipDuplicateCheck = !session.items.isEmpty
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
            await rematchUnmatchedSpotifyItems(in: sessionID)
            guard let refreshed = sessions.first(where: { $0.id == sessionID }) else { return }
            entries = refreshed.items
                .filter { $0.status == .queued }
                .map(Self.entry(for:))
        } else if let link = SpotifyLink(sourceURL) {
            guard let resolved = await resolveSpotifySession(sessionID, link: link) else { return }
            entries = resolved
        } else {
            entries = await engine.prefetchEntries(from: sourceURL)
            applyResolvedEntries(entries, to: sessionID)
        }

        guard !Task.isCancelled else {
            finishCancelledSession(sessionID)
            return
        }

        if !skipDuplicateCheck && appSettings.duplicateDetectionEnabled {
            await checkDuplicates(for: sessionID, entries: entries)
        }

        guard !Task.isCancelled else {
            finishCancelledSession(sessionID)
            return
        }

        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        guard !session.hasPendingReview else {
            mutateSession(sessionID) { session in
                finalizeReviewState(in: &session)
            }
            activeTasks[sessionID] = nil
            activeEngines[sessionID] = nil
            notifyIfNeeded(
                title: "Download needs review",
                body: session.displayTitle
            )
            scheduleWaitingSessions()
            return
        }

        let queuedEntries = entries.filter { entry in
            guard let item = session.items.first(where: { $0.sourceURL == entry.url }) else { return true }
            return item.status == .queued
        }
        await startDownloadPhase(sessionID, engine: engine, entries: queuedEntries)
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

    // MARK: - Spotify

    private static func entry(for item: DownloadSessionItem) -> PlaylistEntry {
        PlaylistEntry(url: item.sourceURL, title: item.title, metadata: item.spotify?.track)
    }

    /// Resolves the Spotify link, matches every track on YouTube Music, and fills the session items.
    /// Returns nil when the session failed or was cancelled.
    private func resolveSpotifySession(_ sessionID: UUID, link: SpotifyLink) async -> [PlaylistEntry]? {
        let collection: SpotifyCollection
        do {
            collection = try await SpotifyService.shared.resolve(link)
            guard !collection.tracks.isEmpty else { throw SpotifyError.empty }
        } catch {
            endSessionTask(sessionID) {
                failSession(sessionID, message: error.localizedDescription)
            }
            return nil
        }

        let isConnected = await SpotifyService.shared.connectedAccountName != nil
        mutateSession(sessionID) { session in
            session.kind = collection.tracks.count > 1 ? .playlist : .single
            session.resolvedTitle = collection.name
            session.displayTitle = collection.name
            session.notice = collection.isTruncated
                ? (isConnected
                    ? "Spotify only shares the first \(SpotifyService.embedTrackLimit) songs of playlists you don't own or collaborate on."
                    : "Spotify only shares the first \(SpotifyService.embedTrackLimit) songs of playlists without logging in.\nConnect Spotify in Settings > Spotify to download your own and collaborative playlists in full.")
                : nil
        }

        let results = await matchOnYouTubeMusic(collection.tracks)
        guard !Task.isCancelled else {
            finishCancelledSession(sessionID)
            return nil
        }

        var claimedURLs = Set<String>()
        let items = collection.tracks.enumerated().map { index, track in
            var item = DownloadSessionItem(
                sourceURL: track.webURL,
                title: track.displayTitle,
                itemIndex: index,
                spotify: SpotifyItemInfo(track: track, needsReview: false)
            )
            apply(results[index], to: &item, claimedURLs: &claimedURLs)
            return item
        }

        mutateSession(sessionID) { session in
            session.items = items
        }
        let entries = items.filter { $0.status == .queued || $0.status == .waitingForUser }.map(Self.entry(for:))
        guard !entries.isEmpty else {
            endSessionTask(sessionID) {
                failSession(sessionID, message: items.first?.errorMessage ?? "No songs from this link were found on YouTube Music.")
            }
            return nil
        }
        return entries
    }

    /// Retry path: tracks that never got a YouTube Music match are searched again.
    private func rematchUnmatchedSpotifyItems(in sessionID: UUID) async {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let unmatched = session.items.filter { $0.status == .queued && $0.spotify != nil && SpotifyLink($0.sourceURL) != nil }
        guard !unmatched.isEmpty else { return }

        let results = await matchOnYouTubeMusic(unmatched.compactMap { $0.spotify?.track })
        mutateSession(sessionID) { session in
            var claimedURLs = Set(session.items.map(\.sourceURL))
            for (offset, original) in unmatched.enumerated() {
                guard let index = session.items.firstIndex(where: { $0.id == original.id }) else { continue }
                apply(results[offset], to: &session.items[index], claimedURLs: &claimedURLs)
            }
        }
    }

    private func apply(
        _ result: Result<YouTubeMusicMatch?, Error>,
        to item: inout DownloadSessionItem,
        claimedURLs: inout Set<String>
    ) {
        switch result {
        case .success(let match?) where !claimedURLs.contains(match.candidate.url):
            claimedURLs.insert(match.candidate.url)
            let needsReview = match.score < YouTubeMusicMatcher.autoAcceptScore
            item.sourceURL = match.candidate.url
            item.status = needsReview ? .waitingForUser : .queued
            item.errorMessage = nil
            item.spotify?.matchTitle = match.candidate.title
            item.spotify?.matchArtists = match.candidate.artists.joined(separator: ", ")
            item.spotify?.matchDurationSec = match.candidate.durationSec
            item.spotify?.matchScore = match.score
            item.spotify?.needsReview = needsReview
        case .success(let match?):
            item.status = .skipped
            item.errorMessage = "Same YouTube Music song as another track: \(match.candidate.title)"
        case .success(nil):
            item.status = .failed
            item.errorMessage = "No match found on YouTube Music"
        case .failure(let error):
            item.status = .failed
            item.errorMessage = error.localizedDescription
        }
    }

    private func matchOnYouTubeMusic(_ tracks: [SpotifyTrack]) async -> [Result<YouTubeMusicMatch?, Error>] {
        let concurrency = 2
        return await withTaskGroup(of: (Int, Result<YouTubeMusicMatch?, Error>).self) { group in
            var results = [Result<YouTubeMusicMatch?, Error>](repeating: .success(nil), count: tracks.count)
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < tracks.count, !Task.isCancelled else { return }
                let index = nextIndex
                let track = tracks[index]
                nextIndex += 1
                group.addTask {
                    do {
                        return (index, .success(try await YouTubeMusicMatcher.shared.bestMatch(for: track)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            for _ in 0 ..< concurrency {
                enqueueNext()
            }
            while let (index, result) = await group.next() {
                results[index] = result
                enqueueNext()
            }
            return results
        }
    }

    private func endSessionTask(_ sessionID: UUID, _ update: () -> Void) {
        update()
        activeTasks[sessionID] = nil
        activeEngines[sessionID] = nil
        scheduleWaitingSessions()
    }

    func currentMatchReviewItem(for sessionID: UUID) -> DownloadSessionItem? {
        sessions.first { $0.id == sessionID }?.items
            .sorted { $0.itemIndex < $1.itemIndex }
            .first(where: \.needsMatchReview)
    }

    func acceptCurrentMatch(for sessionID: UUID) {
        resolveCurrentMatch(for: sessionID, accept: true)
    }

    func skipCurrentMatch(for sessionID: UUID) {
        resolveCurrentMatch(for: sessionID, accept: false)
    }

    private func resolveCurrentMatch(for sessionID: UUID, accept: Bool) {
        guard let itemID = currentMatchReviewItem(for: sessionID)?.id else { return }
        mutateSession(sessionID) { session in
            guard let index = session.items.firstIndex(where: { $0.id == itemID }) else { return }
            if accept {
                session.items[index].spotify?.needsReview = false
                session.items[index].status = .queued
            } else {
                session.items[index].status = .skipped
            }
            finalizeReviewState(in: &session)
        }
        scheduleWaitingSessionsIfReady(sessionID)
    }

    private func scheduleWaitingSessionsIfReady(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if session.status == .waitingForSlot {
            scheduleWaitingSessions()
        }
    }

    // MARK: - Rekordbox

    /// Genre tagging only shows once a Rekordbox export is loaded, i.e. the user uses Rekordbox.
    func isRekordboxGenreAvailable(for format: AudioFormat) -> Bool {
        rekordboxLibraryStore.isActive && format.supportsRekordbox
    }

    func isInRekordbox(_ item: DownloadSessionItem) -> Bool {
        item.outputFilePath.map(rekordboxLibraryStore.contains(path:)) ?? false
    }

    func isWaitingInRekordboxXML(_ item: DownloadSessionItem) -> Bool {
        item.outputFilePath.map(RekordboxXMLQueue.shared.contains(path:)) ?? false
    }

    /// Downloaded files that still exist, aren't in the loaded Rekordbox export, and aren't already in meloDL's XML.
    func rekordboxPendingItems(in session: DownloadSession) -> [DownloadSessionItem] {
        guard isRekordboxGenreAvailable(for: session.format) else { return [] }
        return session.items
            .filter { $0.status == .completed }
            .filter { item in
                guard let path = item.outputFilePath, FileManager.default.fileExists(atPath: path) else { return false }
                return !rekordboxLibraryStore.contains(path: path) && !RekordboxXMLQueue.shared.contains(path: path)
            }
            .sorted { $0.itemIndex < $1.itemIndex }
    }

    var isRekordboxBusy: Bool {
        rekordboxImportActivity.values.contains(where: \.isRunning)
    }

    func setGenre(_ genre: String?, forItem itemID: UUID, in sessionID: UUID) {
        mutateSession(sessionID) { session in
            guard let index = session.items.firstIndex(where: { $0.id == itemID }) else { return }
            session.items[index].genre = genre
        }
    }

    func setGenreForPendingItems(_ genre: String?, in sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let pendingIDs = Set(rekordboxPendingItems(in: session).map(\.id))
        mutateSession(sessionID) { session in
            for index in session.items.indices where pendingIDs.contains(session.items[index].id) {
                session.items[index].genre = genre
            }
        }
    }

    func dismissRekordboxImportActivity(for sessionID: UUID) {
        guard rekordboxImportActivity[sessionID]?.isRunning == false else { return }
        rekordboxImportActivity[sessionID] = nil
    }

    /// Writes each track's genre into the file and adds the tracks to the Rekordbox collection.
    func importToRekordbox(sessionID: UUID) {
        guard !isRekordboxBusy else { return }
        Task {
            await rekordboxLibraryStore.reloadIfSourceChanged()
            guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
            let tracks = rekordboxPendingItems(in: session).compactMap { item -> RekordboxXMLTrack? in
                guard let path = item.outputFilePath else { return nil }
                return RekordboxXMLTrack(
                    path: path,
                    name: item.spotify?.track.title,
                    artist: item.spotify?.track.artistLine,
                    genre: session.effectiveGenre(for: item, defaultGenre: appSettings.rekordboxDefaultGenre),
                    comment: item.sourceURL
                )
            }
            guard !tracks.isEmpty else { return }

            rekordboxImportActivity[sessionID] = .importing(count: tracks.count)
            do {
                let outcome = try await RekordboxImporter.shared.importTracks(
                    tracks,
                    playlistName: session.displayTitle,
                    keepsPlaylist: appSettings.rekordboxKeepsImportPlaylist
                ) { step in
                    rekordboxImportActivity[sessionID] = RekordboxImportActivity(step)
                }
                rekordboxImportActivity[sessionID] = RekordboxImportActivity(outcome)
            } catch {
                rekordboxImportActivity[sessionID] = .failed(error.localizedDescription)
            }
            schedulePostDownloadReindex()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Duplicates

    private func checkDuplicates(for sessionID: UUID, entries: [PlaylistEntry]) async {
        mutateSession(sessionID) { session in
            session.status = .checkingDuplicates
            for index in session.items.indices where session.items[index].status == .queued {
                session.items[index].status = .checkingDuplicates
            }
        }

        do {
            await TrackIndexer.shared.reindexIfNeeded(roots: appSettings.duplicateIndexRoots)
            await rekordboxLibraryStore.reloadIfSourceChanged()
            var duplicateSnapshotsByURL: [String: DuplicateMatchSnapshot] = [:]

            for entry in entries {
                if let snapshot = await sameLinkDuplicate(for: entry.url) {
                    duplicateSnapshotsByURL[entry.url] = snapshot
                    continue
                }
                let matches = try await duplicateDetectionService.findPotentialDuplicates(
                    title: entry.title,
                    expectedDurationSec: entry.metadata?.durationSec ?? entry.durationSec
                )
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
            logger.failure("Duplicate check failed: \(error.localizedDescription)")
            mutateSession(sessionID) { session in
                for index in session.items.indices where session.items[index].status == .checkingDuplicates {
                    session.items[index].status = .queued
                }
            }
        }
    }

    /// A link downloaded before, by meloDL or found in a Rekordbox track's comments, is a sure duplicate.
    private func sameLinkDuplicate(for url: String) async -> DuplicateMatchSnapshot? {
        guard let key = SourceLinkKey.key(for: url) else { return nil }
        let fileManager = FileManager.default

        if let path = try? await sessionStore.downloadedFilePath(forLinkKey: key), fileManager.fileExists(atPath: path) {
            return Self.sameLinkSnapshot(path: path, reason: "Same link downloaded before")
        }
        if let path = rekordboxLibraryStore.path(forSourceLinkKey: key), fileManager.fileExists(atPath: path) {
            return Self.sameLinkSnapshot(path: path, reason: "Same link already in Rekordbox")
        }
        return nil
    }

    private static func sameLinkSnapshot(path: String, reason: String) -> DuplicateMatchSnapshot {
        DuplicateMatchSnapshot(
            candidatePath: path,
            candidateTitle: URL(fileURLWithPath: path).lastPathComponent,
            confidence: .high,
            score: 1.0,
            reason: reason
        )
    }

    private func startDownloadPhase(_ sessionID: UUID, engine: DownloadEngine, entries: [PlaylistEntry]) async {
        guard !entries.isEmpty else {
            finishSkippedSessionIfNeeded(sessionID)
            return
        }

        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }

        let config = downloadConfiguration(for: session)

        mutateSession(sessionID) { session in
            session.status = .downloading
            session.attentionReason = nil
            for index in session.items.indices where session.items[index].status == .queued {
                session.items[index].duplicateMatch = nil
            }
        }

        do {
            if entries.count == 1 {
                let entry = entries[0]
                let stream = engine.download(
                    url: entry.url,
                    config: config,
                    audioSettings: appSettings.audioSettings,
                    preloadedTitle: entry.title,
                    deferTitleResolution: false,
                    metadata: entry.metadata
                )
                for try await event in stream {
                    handle(event, for: sessionID)
                }
            } else {
                let stream = engine.downloadPlaylist(
                    url: session.sourceURL,
                    config: config,
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
            recordDownloadedLink(sourceURL: sourceURL, filePath: filepath, in: sessionID)

        case .error(let sourceURL, let message, _):
            mutateItem(sourceURL: sourceURL, in: sessionID) { item in
                item.status = .failed
                item.errorMessage = message
            }
        }
    }

    private func recordDownloadedLink(sourceURL: String, filePath: String, in sessionID: UUID) {
        guard let key = SourceLinkKey.key(for: sourceURL) else { return }
        let title = sessions.first { $0.id == sessionID }?.items.first { $0.sourceURL == sourceURL }?.title ?? sourceURL
        Task {
            do {
                try await sessionStore.recordDownloadedLink(key: key, url: sourceURL, filePath: filePath, title: title)
            } catch {
                logger.failure("Failed to record downloaded link: \(error.localizedDescription)")
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
        logger.failure("Session failed: \(message)")
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
                session.items[itemIndex].status = session.items[itemIndex].spotify?.needsReview == true ? .waitingForUser : .queued
                session.items[itemIndex].duplicateMatch = nil
            } else {
                session.items[itemIndex].status = .skipped
            }

            finalizeReviewState(in: &session)
        }

        scheduleWaitingSessionsIfReady(sessionID)
    }

    private func finalizeReviewState(in session: inout DownloadSession) {
        if session.hasPendingDuplicateReview {
            session.status = .waitingForUser
            session.attentionReason = .duplicateReview
        } else if session.hasPendingMatchReview {
            session.status = .waitingForUser
            session.attentionReason = .matchReview
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
                logger.failure("Failed to persist session: \(error.localizedDescription)")
            }
        }
    }

    private func downloadConfiguration(for session: DownloadSession) -> DownloadConfiguration {
        DownloadConfiguration(
            fastDownloads: appSettings.fastDownloads,
            outputFolder: URL(fileURLWithPath: session.outputFolderPath, isDirectory: true),
            genre: isRekordboxGenreAvailable(for: session.format)
                ? session.genre ?? appSettings.rekordboxDefaultGenre
                : nil
        )
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
                if self.isIndexingTracks != status.isIndexing {
                    self.isIndexingTracks = status.isIndexing
                }
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
