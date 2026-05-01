import Foundation
import os

actor TrackIndexer {
    static let shared = TrackIndexer()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL",
        category: "TrackIndexer"
    )
    private let fileManager = FileManager.default
    private let store: TrackIndexStore
    private let defaults = UserDefaults.standard
    private let lastIndexKey = "duplicateIndex.lastSuccessfulReindexAt"
    private let reindexInterval: TimeInterval = 24 * 60 * 60
    private var isIndexing = false

    init(store: TrackIndexStore = .shared) {
        self.store = store
    }

    func reindexIfNeeded(roots: [String]) async {
        guard !isIndexing else { return }
        let canonicalRoots = canonicalizeRoots(roots)
        guard !canonicalRoots.isEmpty else { return }

        let lastIndex = defaults.double(forKey: lastIndexKey)
        let shouldRun = lastIndex <= 0 || Date().timeIntervalSince1970 - lastIndex >= reindexInterval
        if !shouldRun {
            do {
                let count = try await store.countTracks()
                if count > 0 { return }
            } catch {
                logger.error("Failed to count tracks before reindex decision: \(error.localizedDescription)")
            }
        }
        await reindexNow(roots: canonicalRoots)
    }

    struct IndexStatus: Sendable {
        let isIndexing: Bool
        let lastSuccessfulReindexAt: Date?
    }

    func status() -> IndexStatus {
        let lastIndex = defaults.double(forKey: lastIndexKey)
        let lastSuccessfulReindexAt: Date? = lastIndex > 0 ? Date(timeIntervalSince1970: lastIndex) : nil
        return IndexStatus(isIndexing: isIndexing, lastSuccessfulReindexAt: lastSuccessfulReindexAt)
    }

    func reindexNow(roots: [String]) async {
        guard !isIndexing else { return }
        let canonicalRoots = canonicalizeRoots(roots)
        guard !canonicalRoots.isEmpty else { return }

        isIndexing = true
        defer { isIndexing = false }
        let passStartedAt = Date()

        do {
            try await store.ensureReady()
            try await store.replaceRoots(with: canonicalRoots)
            try await store.removeTracksOutsideRoots(canonicalRoots)

            var indexedCount = 0
            for root in canonicalRoots {
                indexedCount += try await reindexRoot(rootPath: root, passStartedAt: passStartedAt)
            }

            defaults.set(Date().timeIntervalSince1970, forKey: lastIndexKey)
            logger.info("Reindex finished. Indexed \(indexedCount) files across \(canonicalRoots.count) roots.")
        } catch {
            logger.error("Reindex failed: \(error.localizedDescription)")
        }
    }

    private func reindexRoot(rootPath: String, passStartedAt: Date) async throws -> Int {
        var indexedCount = 0
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            logger.warning("Skipping missing root: \(rootPath, privacy: .public)")
            return 0
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            logger.warning("Could not enumerate root: \(rootPath, privacy: .public)")
            return 0
        }

        for case let fileURL as URL in enumerator {
            guard isAudioFile(fileURL.pathExtension) else { continue }
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { continue }

            let filename = values.name ?? fileURL.lastPathComponent
            let stem = fileURL.deletingPathExtension().lastPathComponent
            let normalizedTitle = DuplicateDetectionService.normalize(stem)
            let filesize = values.fileSize.map(Int64.init)
            let mtime = values.contentModificationDate ?? Date.distantPast

            let track = IndexedTrack(
                path: fileURL.path,
                rootPath: rootPath,
                filename: filename,
                normalizedTitle: normalizedTitle,
                artistHint: nil,
                durationSec: nil,
                filesize: filesize,
                mtime: mtime,
                hashPrefix: nil,
                lastSeenAt: passStartedAt
            )
            try await store.upsertTrack(track)
            indexedCount += 1
        }

        try await store.removeStaleTracks(rootPath: rootPath, olderThan: passStartedAt)
        return indexedCount
    }

    private func canonicalizeRoots(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for path in roots {
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            if canonical.isEmpty || seen.contains(canonical) { continue }
            seen.insert(canonical)
            normalized.append(canonical)
        }
        return normalized.sorted()
    }

    private func isAudioFile(_ ext: String) -> Bool {
        switch ext.lowercased() {
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac", "m4b":
            return true
        default:
            return false
        }
    }
}
