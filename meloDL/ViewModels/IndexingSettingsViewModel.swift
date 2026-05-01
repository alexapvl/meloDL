import AppKit
import Foundation
import SwiftUI

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
    @Published var showClearDataConfirmation = false
    @Published var pendingConflict: RootConflictPrompt?

    private let appSettings: AppSettings
    private let store: TrackIndexStore
    private let indexer: TrackIndexer
    private var pollingTask: Task<Void, Never>?

    init(
        appSettings: AppSettings,
        store: TrackIndexStore = .shared,
        indexer: TrackIndexer = .shared
    ) {
        self.appSettings = appSettings
        self.store = store
        self.indexer = indexer
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
