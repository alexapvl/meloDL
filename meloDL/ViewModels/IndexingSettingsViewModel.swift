import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class IndexingSettingsViewModel: ObservableObject {
    @Published private(set) var roots: [String] = []
    @Published var selectedRoot: String?
    @Published private(set) var isIndexing = false
    @Published private(set) var lastIndexedAt: Date?
    @Published private(set) var indexedTrackCount = 0
    @Published private(set) var databaseSizeMainBytes: Int64 = 0
    @Published private(set) var databaseSizeWalBytes: Int64 = 0
    @Published private(set) var databaseSizeShmBytes: Int64 = 0
    @Published private(set) var inaccessibleRoots: [String] = []
    @Published private(set) var feedbackMessage: String?
    @Published private(set) var exactDuplicateGroups: [ExactDuplicateGroup] = []
    @Published private(set) var isScanningExactDuplicates = false
    @Published private(set) var exactDuplicateScanError: String?
    @Published private(set) var isRunningSmartCleanup = false
    @Published var showSmartCleanupConfirmation = false
    @Published private(set) var smartCleanupSummary: SmartCleanupSummary?
    @Published var smartCleanupKeepRule: SmartCleanupKeepRule = .oldestModified
    @Published var isManualReviewMode = false
    @Published private(set) var manualQueue: [ManualDuplicateGroupState] = []
    @Published private(set) var manualCurrentIndex = 0
    @Published private(set) var manualAppliedGroupsCount = 0
    @Published private(set) var manualAppliedFilesCount = 0
    @Published private(set) var manualFailedDeleteCount = 0
    @Published private(set) var manualReclaimedBytes: Int64 = 0
    @Published private(set) var rekordboxImportedTrackCount = 0
    @Published private(set) var rekordboxImportError: String?
    @Published private(set) var rekordboxSourceFilename: String?
    @Published var showExactDuplicateFinder = false
    @Published var showClearDataConfirmation = false
    @Published var pendingConflict: RootConflictPrompt?

    private let appSettings: AppSettings
    private let store: TrackIndexStore
    private let indexer: TrackIndexer
    private let duplicateDetectionService: DuplicateDetectionService
    private let rekordboxImportService: RekordboxXMLImportService
    private var rekordboxCanonicalPaths: Set<String> = []
    private var pollingTask: Task<Void, Never>?

    init(
        appSettings: AppSettings,
        store: TrackIndexStore = .shared,
        indexer: TrackIndexer = .shared,
        duplicateDetectionService: DuplicateDetectionService = .shared,
        rekordboxImportService: RekordboxXMLImportService = .shared
    ) {
        self.appSettings = appSettings
        self.store = store
        self.indexer = indexer
        self.duplicateDetectionService = duplicateDetectionService
        self.rekordboxImportService = rekordboxImportService
    }

    func onAppear() {
        syncRootsFromSettings()
        startPolling()
        Task {
            await refreshSnapshot()
        }
    }

    func onDisappear() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func addRootUsingPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder to include in duplicate indexing."
        if panel.runModal() == .OK, let url = panel.url {
            proposeRootAddition(path: url.path)
        }
    }

    func handleDroppedFolderURLs(_ urls: [URL]) {
        for url in urls where url.hasDirectoryPath {
            proposeRootAddition(path: url.path)
        }
    }

    func removeSelectedRoot() {
        guard let currentSelection = selectedRoot else { return }
        let newRoots = roots.filter { $0 != currentSelection }
        selectedRoot = nil
        updateRoots(newRoots, triggerSmartSync: true)
    }

    func updateIndexNow() {
        let currentRoots = roots
        guard !currentRoots.isEmpty else { return }
        feedbackMessage = nil
        Task {
            await indexer.reindexNow(roots: currentRoots)
            await refreshSnapshot()
            feedbackMessage = "Index is up to date."
        }
    }

    func clearIndexData() {
        feedbackMessage = nil
        Task {
            do {
                try await store.clearTracksData()
                await refreshSnapshot()
                feedbackMessage = "Index data cleared."
            } catch {
                feedbackMessage = "Failed to clear index data: \(error.localizedDescription)"
            }
        }
    }

    func openExactDuplicateFinder() {
        showExactDuplicateFinder = true
        isManualReviewMode = false
        resetManualReviewStats()
        manualQueue = []
        manualCurrentIndex = 0
        refreshExactDuplicateGroups()
    }

    func importRekordboxXMLUsingPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.xml]
        panel.prompt = "Import XML"
        panel.message = "Choose the Rekordbox collection XML exported from File -> Export collection in xml format."

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        rekordboxImportError = nil
        Task {
            do {
                let snapshot = try await rekordboxImportService.importSnapshot(from: fileURL)
                rekordboxCanonicalPaths = snapshot.canonicalPaths
                rekordboxImportedTrackCount = snapshot.trackCount
                rekordboxSourceFilename = snapshot.sourceURL.lastPathComponent
                if isManualReviewMode {
                    refreshManualQueueFromCurrentGroups()
                }
            } catch {
                rekordboxCanonicalPaths = []
                rekordboxImportedTrackCount = 0
                rekordboxSourceFilename = nil
                rekordboxImportError = error.localizedDescription
            }
        }
    }

    func clearRekordboxImport() {
        rekordboxCanonicalPaths = []
        rekordboxImportedTrackCount = 0
        rekordboxSourceFilename = nil
        rekordboxImportError = nil
        if isManualReviewMode {
            refreshManualQueueFromCurrentGroups()
        }
    }

    func reindexAfterDuplicateFinderClosed() {
        let rootsSnapshot = roots
        guard !rootsSnapshot.isEmpty else { return }
        Task {
            await indexer.reindexNow(roots: rootsSnapshot)
            await refreshSnapshot()
        }
    }

    func refreshExactDuplicateGroups() {
        guard !roots.isEmpty else {
            exactDuplicateGroups = []
            exactDuplicateScanError = "Add at least one indexed folder before scanning."
            return
        }
        guard !isScanningExactDuplicates else { return }

        exactDuplicateScanError = nil
        isScanningExactDuplicates = true
        Task {
            defer { isScanningExactDuplicates = false }
            await indexer.reindexIfNeeded(roots: roots)
            await refreshSnapshot()
            do {
                let groups = try await duplicateDetectionService.findExactDuplicateFileGroups()
                exactDuplicateGroups = groups
                smartCleanupSummary = nil
                if isManualReviewMode {
                    refreshManualQueueFromCurrentGroups()
                }
                if groups.isEmpty {
                    feedbackMessage = "No exact duplicate files found."
                } else {
                    feedbackMessage = "Found \(groups.count) duplicate group(s)."
                }
            } catch {
                exactDuplicateScanError = "Failed to scan duplicates: \(error.localizedDescription)"
            }
        }
    }

    func runSmartCleanup(scope: SmartCleanupScope) {
        guard !isRunningSmartCleanup else { return }
        let groupsForScope = groupsForCleanupScope(scope, from: exactDuplicateGroups)
        let plan = buildSmartCleanupPlan(from: groupsForScope, keepRule: smartCleanupKeepRule)
        guard !plan.remove.isEmpty else {
            smartCleanupSummary = SmartCleanupSummary(
                keptCount: plan.keep.count,
                removedCount: 0,
                failedCount: 0,
                reclaimedBytes: 0
            )
            feedbackMessage = "Nothing to clean up."
            return
        }

        isRunningSmartCleanup = true
        exactDuplicateScanError = nil
        let rootsSnapshot = roots

        Task {
            defer { isRunningSmartCleanup = false }

            let removalResult = await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                var removedCount = 0
                var failedCount = 0
                var reclaimedBytes: Int64 = 0

                for file in plan.remove {
                    let url = URL(fileURLWithPath: file.path)
                    do {
                        if fileManager.fileExists(atPath: url.path) {
                            try fileManager.trashItem(at: url, resultingItemURL: nil)
                            removedCount += 1
                            if let filesize = file.filesize {
                                reclaimedBytes += filesize
                            }
                        }
                    } catch {
                        failedCount += 1
                    }
                }

                return (removedCount, failedCount, reclaimedBytes)
            }.value

            await indexer.reindexNow(roots: rootsSnapshot)
            await refreshSnapshot()
            do {
                exactDuplicateGroups = try await duplicateDetectionService.findExactDuplicateFileGroups()
            } catch {
                exactDuplicateScanError = "Cleanup succeeded, but duplicate list refresh failed: \(error.localizedDescription)"
            }

            smartCleanupSummary = SmartCleanupSummary(
                keptCount: plan.keep.count,
                removedCount: removalResult.0,
                failedCount: removalResult.1,
                reclaimedBytes: removalResult.2
            )

            if removalResult.1 > 0 {
                feedbackMessage = "Cleanup finished with partial failures."
                exactDuplicateScanError = "Failed to move \(removalResult.1) file(s) to Trash."
            } else {
                feedbackMessage = "Smart cleanup removed \(removalResult.0) duplicate file(s)."
            }
        }
    }

    func startManualReviewSession() {
        guard !exactDuplicateGroups.isEmpty else { return }
        isManualReviewMode = true
        resetManualReviewStats()
        manualQueue = []
        manualCurrentIndex = 0
        refreshManualQueueFromCurrentGroups()
    }

    func showOverviewMode() {
        isManualReviewMode = false
    }

    func returnToManualReviewMode() {
        if manualQueue.isEmpty {
            refreshManualQueueFromCurrentGroups()
        }
        isManualReviewMode = true
    }

    func isRekordboxMatched(filePath: String) -> Bool {
        isInRekordboxLibrary(path: filePath)
    }

    func rekordboxMatchCount(in group: ExactDuplicateGroup) -> Int {
        group.files.reduce(0) { partial, file in
            partial + (isInRekordboxLibrary(path: file.path) ? 1 : 0)
        }
    }

    func hasRekordboxMatch(in group: ExactDuplicateGroup) -> Bool {
        group.files.contains { isInRekordboxLibrary(path: $0.path) }
    }

    func canUseRekordboxOnlyCleanupScope() -> Bool {
        exactDuplicateGroups.contains { hasRekordboxMatch(in: $0) }
    }

    private func resetManualReviewStats() {
        manualAppliedGroupsCount = 0
        manualAppliedFilesCount = 0
        manualFailedDeleteCount = 0
        manualReclaimedBytes = 0
    }

    private func groupsForCleanupScope(_ scope: SmartCleanupScope, from groups: [ExactDuplicateGroup]) -> [ExactDuplicateGroup] {
        switch scope {
        case .allGroups:
            return groups
        case .rekordboxOnly:
            return groups.filter { hasRekordboxMatch(in: $0) }
        }
    }

    func smartCleanupGroupCount(for scope: SmartCleanupScope) -> Int {
        groupsForCleanupScope(scope, from: exactDuplicateGroups).count
    }

    func smartCleanupCandidateCount(for scope: SmartCleanupScope) -> Int {
        let groups = groupsForCleanupScope(scope, from: exactDuplicateGroups)
        return buildSmartCleanupPlan(from: groups, keepRule: smartCleanupKeepRule).remove.count
    }

    func smartCleanupEstimatedReclaimBytes(for scope: SmartCleanupScope) -> Int64 {
        let groups = groupsForCleanupScope(scope, from: exactDuplicateGroups)
        return buildSmartCleanupPlan(from: groups, keepRule: smartCleanupKeepRule).remove.reduce(0) { partial, file in
            partial + (file.filesize ?? 0)
        }
    }

    func exitManualReviewMode() {
        showOverviewMode()
    }

    func selectManualKeeper(path: String) {
        guard manualQueue.indices.contains(manualCurrentIndex) else { return }
        manualQueue[manualCurrentIndex].keeperPath = path
    }

    func moveToPreviousManualGroup() {
        guard !manualQueue.isEmpty else { return }
        manualCurrentIndex = max(0, manualCurrentIndex - 1)
    }

    func skipManualGroup() {
        guard !manualQueue.isEmpty else { return }
        manualCurrentIndex = min(max(0, manualQueue.count - 1), manualCurrentIndex + 1)
    }

    func applyCurrentManualGroup() {
        guard manualQueue.indices.contains(manualCurrentIndex) else { return }
        guard !isRunningSmartCleanup else { return }

        let groupState = manualQueue[manualCurrentIndex]
        guard let keeperPath = groupState.keeperPath else {
            return
        }
        let filesToDelete = groupState.group.files.filter { $0.path != keeperPath }
        guard !filesToDelete.isEmpty else {
            manualQueue.remove(at: manualCurrentIndex)
            manualAppliedGroupsCount += 1
            normalizeManualCurrentIndex()
            return
        }

        isRunningSmartCleanup = true
        exactDuplicateScanError = nil

        Task {
            defer { isRunningSmartCleanup = false }
            let result = await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                var removedCount = 0
                var failedCount = 0
                var reclaimedBytes: Int64 = 0

                for file in filesToDelete {
                    let url = URL(fileURLWithPath: file.path)
                    do {
                        if fileManager.fileExists(atPath: url.path) {
                            try fileManager.trashItem(at: url, resultingItemURL: nil)
                            removedCount += 1
                            reclaimedBytes += file.filesize ?? 0
                        }
                    } catch {
                        failedCount += 1
                    }
                }
                return (removedCount, failedCount, reclaimedBytes)
            }.value

            manualAppliedGroupsCount += 1
            manualAppliedFilesCount += result.0
            manualFailedDeleteCount += result.1
            manualReclaimedBytes += result.2

            let groupHash = groupState.group.contentHash
            manualQueue.remove(at: manualCurrentIndex)
            exactDuplicateGroups.removeAll { $0.contentHash == groupHash }
            normalizeManualCurrentIndex()

            if result.1 > 0 {
                exactDuplicateScanError = "Failed to move \(result.1) file(s) to Trash."
            }
        }
    }

    func chooseKeepParentForChildConflict() {
        pendingConflict = nil
        feedbackMessage = "Skipped nested folder because parent is already indexed."
    }

    func chooseKeepBothForChildConflict() {
        guard case .childInsideParent(let proposed, _) = pendingConflict else { return }
        pendingConflict = nil
        applyAddedRoot(proposed)
    }

    func chooseKeepChildrenForParentConflict() {
        pendingConflict = nil
        feedbackMessage = "Kept existing child folders."
    }

    func chooseReplaceChildrenWithParent() {
        guard case .parentWithChildren(let proposed, let children) = pendingConflict else { return }
        pendingConflict = nil
        var newRoots = roots.filter { !children.contains($0) }
        newRoots.append(proposed)
        updateRoots(newRoots, triggerSmartSync: true)
        feedbackMessage = "Replaced child folders with parent folder."
    }

    var canUpdateIndexNow: Bool {
        !roots.isEmpty && !isIndexing
    }

    var totalExactDuplicateFiles: Int {
        exactDuplicateGroups.reduce(0) { $0 + $1.files.count }
    }

    var smartCleanupCandidateCount: Int {
        smartCleanupCandidateCount(for: .allGroups)
    }

    var smartCleanupEstimatedReclaimBytes: Int64 {
        smartCleanupEstimatedReclaimBytes(for: .allGroups)
    }

    var isRekordboxAssistActive: Bool {
        !rekordboxCanonicalPaths.isEmpty
    }

    var rekordboxStatusText: String? {
        if let rekordboxImportError {
            return "Rekordbox import failed: \(rekordboxImportError)"
        }
        guard isRekordboxAssistActive else { return nil }
        let source = rekordboxSourceFilename ?? "XML"
        let trackCountText = NumberFormatter.localizedString(
            from: NSNumber(value: rekordboxImportedTrackCount),
            number: .decimal
        )
        let autoResolvableGroupsText = NumberFormatter.localizedString(
            from: NSNumber(value: autoResolvableGroupCount),
            number: .decimal
        )
        return "Rekordbox: \(trackCountText) tracks loaded, \(autoResolvableGroupsText) groups can be auto-resolved with Smart Cleanup (\(source))."
    }

    private var autoResolvableGroupCount: Int {
        exactDuplicateGroups.filter { hasRekordboxMatch(in: $0) }.count
    }

    var manualCurrentGroupState: ManualDuplicateGroupState? {
        guard manualQueue.indices.contains(manualCurrentIndex) else { return nil }
        return manualQueue[manualCurrentIndex]
    }

    var manualGroupProgressText: String {
        guard let _ = manualCurrentGroupState else { return "No pending groups" }
        return "Group \(manualCurrentIndex + 1) of \(max(1, manualQueue.count))"
    }

    var manualRemainingGroupsCount: Int {
        manualQueue.count
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshSnapshot()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func refreshSnapshot() async {
        do {
            try await store.ensureReady(defaultRootPath: appSettings.downloadFolderPath)
            let status = await indexer.status()
            let count = try await store.countTracks()
            let sizeBreakdown = try await store.databaseSizeBreakdown()
            syncRootsFromSettings()
            isIndexing = status.isIndexing
            lastIndexedAt = status.lastSuccessfulReindexAt
            indexedTrackCount = count
            databaseSizeMainBytes = sizeBreakdown.mainBytes
            databaseSizeWalBytes = sizeBreakdown.walBytes
            databaseSizeShmBytes = sizeBreakdown.shmBytes
            inaccessibleRoots = roots.filter { !Self.isAccessibleDirectory(path: $0) }
        } catch {
            feedbackMessage = "Failed to refresh index status: \(error.localizedDescription)"
        }
    }

    var databaseSizeTotalBytes: Int64 {
        databaseSizeMainBytes + databaseSizeWalBytes + databaseSizeShmBytes
    }

    private func syncRootsFromSettings() {
        let normalized = Array(Set(appSettings.duplicateIndexRoots.map(TrackIndexStore.canonicalize(path:)))).sorted()
        roots = normalized
        if let selectedRoot, !normalized.contains(selectedRoot) {
            self.selectedRoot = nil
        }
    }

    private func proposeRootAddition(path: String) {
        let overlap = TrackIndexStore.rootOverlap(for: path, existingRootPaths: roots)
        guard !overlap.proposedRoot.isEmpty else { return }

        if overlap.exactMatch {
            feedbackMessage = "Folder is already in the index roots list."
            return
        }

        if let parentRoot = overlap.parentRoot {
            pendingConflict = .childInsideParent(proposedRoot: overlap.proposedRoot, parentRoot: parentRoot)
            return
        }

        if !overlap.childRoots.isEmpty {
            pendingConflict = .parentWithChildren(proposedRoot: overlap.proposedRoot, childRoots: overlap.childRoots)
            return
        }

        applyAddedRoot(overlap.proposedRoot)
    }

    private func applyAddedRoot(_ root: String) {
        var newRoots = roots
        newRoots.append(root)
        updateRoots(newRoots, triggerSmartSync: true)
    }

    private func updateRoots(_ newRoots: [String], triggerSmartSync: Bool) {
        let canonical = Array(Set(newRoots.map(TrackIndexStore.canonicalize(path:)).filter { !$0.isEmpty })).sorted()
        roots = canonical
        appSettings.duplicateIndexRoots = canonical

        Task {
            do {
                try await store.ensureReady(defaultRootPath: appSettings.downloadFolderPath)
                try await store.replaceRoots(with: canonical)
                if triggerSmartSync, !canonical.isEmpty {
                    await indexer.reindexNow(roots: canonical)
                } else if canonical.isEmpty {
                    try await store.clearTracksData()
                }
                await refreshSnapshot()
            } catch {
                feedbackMessage = "Failed to update roots: \(error.localizedDescription)"
            }
        }
    }

    private static func isAccessibleDirectory(path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func buildSmartCleanupPlan(
        from groups: [ExactDuplicateGroup],
        keepRule: SmartCleanupKeepRule
    ) -> (keep: [ExactDuplicateFileEntry], remove: [ExactDuplicateFileEntry]) {
        var keep: [ExactDuplicateFileEntry] = []
        var remove: [ExactDuplicateFileEntry] = []

        for group in groups {
            let sorted = sortDuplicateFiles(group.files, keepRule: keepRule)
            guard let keeper = sorted.first else { continue }
            keep.append(keeper)
            remove.append(contentsOf: sorted.dropFirst())
        }
        return (keep, remove)
    }

    private func defaultKeeperPath(for group: ExactDuplicateGroup, keepRule: SmartCleanupKeepRule) -> String? {
        let sorted = sortDuplicateFiles(group.files, keepRule: keepRule)
        return sorted.first?.path
    }

    private func sortDuplicateFiles(_ files: [ExactDuplicateFileEntry], keepRule: SmartCleanupKeepRule) -> [ExactDuplicateFileEntry] {
        files.sorted { lhs, rhs in
            let lhsInRekordbox = isInRekordboxLibrary(path: lhs.path)
            let rhsInRekordbox = isInRekordboxLibrary(path: rhs.path)
            if lhsInRekordbox != rhsInRekordbox {
                return lhsInRekordbox
            }

            switch keepRule {
            case .newestModified:
                if lhs.mtime != rhs.mtime {
                    return lhs.mtime > rhs.mtime
                }
            case .oldestModified:
                if lhs.mtime != rhs.mtime {
                    return lhs.mtime < rhs.mtime
                }
            case .shortestPath:
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func isInRekordboxLibrary(path: String) -> Bool {
        guard !rekordboxCanonicalPaths.isEmpty else { return false }
        return rekordboxCanonicalPaths.contains(TrackIndexStore.canonicalize(path: path))
    }

    private func normalizeManualCurrentIndex() {
        if manualQueue.isEmpty {
            manualCurrentIndex = 0
            return
        }
        manualCurrentIndex = min(max(0, manualCurrentIndex), manualQueue.count - 1)
    }

    private func refreshManualQueueFromCurrentGroups() {
        let existingByHash = Dictionary(uniqueKeysWithValues: manualQueue.map { ($0.group.contentHash, $0) })
        manualQueue = exactDuplicateGroups.map { group in
            let fallbackKeeper = defaultKeeperPath(for: group, keepRule: smartCleanupKeepRule)
            if let existing = existingByHash[group.contentHash] {
                let keeperStillExists = existing.keeperPath.flatMap { keeper in
                    group.files.first(where: { $0.path == keeper })?.path
                }
                let resolvedKeeper: String?
                if let keeperStillExists,
                   hasRekordboxMatch(in: group),
                   !isInRekordboxLibrary(path: keeperStillExists) {
                    // Force Rekordbox-first keeper when available.
                    resolvedKeeper = fallbackKeeper
                } else {
                    resolvedKeeper = keeperStillExists ?? fallbackKeeper
                }
                return ManualDuplicateGroupState(
                    group: group,
                    status: existing.status,
                    keeperPath: resolvedKeeper
                )
            }
            return ManualDuplicateGroupState(
                group: group,
                status: .pending,
                keeperPath: defaultKeeperPath(for: group, keepRule: smartCleanupKeepRule)
            )
        }
        normalizeManualCurrentIndex()
    }
}

enum RootConflictPrompt: Identifiable {
    case childInsideParent(proposedRoot: String, parentRoot: String)
    case parentWithChildren(proposedRoot: String, childRoots: [String])

    var id: String {
        switch self {
        case .childInsideParent(let proposedRoot, let parentRoot):
            return "child:\(proposedRoot):\(parentRoot)"
        case .parentWithChildren(let proposedRoot, let childRoots):
            return "parent:\(proposedRoot):\(childRoots.joined(separator: "|"))"
        }
    }
}

struct SmartCleanupSummary: Sendable {
    let keptCount: Int
    let removedCount: Int
    let failedCount: Int
    let reclaimedBytes: Int64
}

enum SmartCleanupKeepRule: String, CaseIterable, Identifiable, Sendable {
    case newestModified
    case oldestModified
    case shortestPath

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestModified:
            return "Keep newest"
        case .oldestModified:
            return "Keep oldest"
        case .shortestPath:
            return "Keep shortest path"
        }
    }

    var descriptionText: String {
        switch self {
        case .newestModified:
            return "Keeps the most recently modified file in each group."
        case .oldestModified:
            return "Keeps the oldest modified file in each group."
        case .shortestPath:
            return "Keeps the file with the shortest path in each group."
        }
    }
}

enum SmartCleanupScope: String, CaseIterable, Identifiable, Sendable {
    case allGroups
    case rekordboxOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allGroups:
            return "All groups"
        case .rekordboxOnly:
            return "Rekordbox matches only"
        }
    }
}

enum ManualDuplicateGroupStatus: String, Sendable {
    case pending
    case skipped
}

struct ManualDuplicateGroupState: Identifiable, Sendable {
    let group: ExactDuplicateGroup
    var status: ManualDuplicateGroupStatus
    var keeperPath: String?

    var id: String { group.contentHash }
}
