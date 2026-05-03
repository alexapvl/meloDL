import Foundation
import CryptoKit
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
    private var pendingRoots: Set<String> = []
    private var pendingForcedPass = false

    init(store: TrackIndexStore = .shared) {
        self.store = store
    }

    func reindexIfNeeded(roots: [String]) async {
        let canonicalRoots = canonicalizeRoots(roots)
        guard !canonicalRoots.isEmpty else { return }
        guard !isIndexing else {
            pendingRoots.formUnion(canonicalRoots)
            return
        }
        await runReindexLoop(initialRoots: canonicalRoots, forceFirstPass: false)
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
        let canonicalRoots = canonicalizeRoots(roots)
        guard !canonicalRoots.isEmpty else { return }
        guard !isIndexing else {
            pendingRoots.formUnion(canonicalRoots)
            pendingForcedPass = true
            return
        }

        await runReindexLoop(initialRoots: canonicalRoots, forceFirstPass: true)
    }

    private func runReindexLoop(initialRoots: [String], forceFirstPass: Bool) async {
        isIndexing = true
        defer { isIndexing = false }
        var roots = initialRoots
        var forcePass = forceFirstPass

        while true {
            let shouldRunPass: Bool
            if forcePass {
                shouldRunPass = true
            } else {
                shouldRunPass = await shouldRunIfNeeded()
            }
            if shouldRunPass {
                let passStartedAt = Date()
                do {
                    try await store.ensureReady()
                    try await store.replaceRoots(with: roots)
                    try await store.removeTracksOutsideRoots(roots)

                    var indexedCount = 0
                    for root in roots {
                        indexedCount += try await reindexRoot(rootPath: root, passStartedAt: passStartedAt)
                    }

                    defaults.set(Date().timeIntervalSince1970, forKey: lastIndexKey)
                    logger.info("Reindex finished. Indexed \(indexedCount) files across \(roots.count) roots.")
                } catch {
                    logger.error("Reindex failed: \(error.localizedDescription)")
                }
            }

            guard !pendingRoots.isEmpty else { break }
            roots = Array(pendingRoots).sorted()
            pendingRoots.removeAll()
            forcePass = pendingForcedPass
            pendingForcedPass = false
        }
    }

    private func shouldRunIfNeeded() async -> Bool {
        let lastIndex = defaults.double(forKey: lastIndexKey)
        let intervalElapsed = lastIndex <= 0 || Date().timeIntervalSince1970 - lastIndex >= reindexInterval
        if intervalElapsed { return true }
        do {
            return try await store.countTracks() == 0
        } catch {
            logger.error("Failed to count tracks before reindex decision: \(error.localizedDescription)")
            return true
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
            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true else { continue }

                let filename = values.name ?? fileURL.lastPathComponent
                let stem = fileURL.deletingPathExtension().lastPathComponent
                let normalizedTitle = DuplicateDetectionService.normalize(stem)
                let filesize = values.fileSize.map(Int64.init)
                let mtime = values.contentModificationDate ?? Date.distantPast
                let existingTrack = try await store.fetchTrack(atPath: fileURL.path)
                let contentHash = try resolveContentHash(
                    for: fileURL,
                    filesize: filesize,
                    mtime: mtime,
                    existingTrack: existingTrack
                )
                let hashPrefix = contentHash.map { String($0.prefix(16)) }

                let track = IndexedTrack(
                    path: fileURL.path,
                    rootPath: rootPath,
                    filename: filename,
                    normalizedTitle: normalizedTitle,
                    artistHint: nil,
                    durationSec: nil,
                    filesize: filesize,
                    mtime: mtime,
                    hashPrefix: hashPrefix,
                    contentHash: contentHash,
                    lastSeenAt: passStartedAt
                )
                try await store.upsertTrack(track)
                indexedCount += 1
            } catch {
                logger.warning("Skipping file during index due to error: \(fileURL.path, privacy: .public) - \(error.localizedDescription)")
            }
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

    private func resolveContentHash(
        for fileURL: URL,
        filesize: Int64?,
        mtime: Date,
        existingTrack: IndexedTrack?
    ) throws -> String? {
        if let existingTrack,
           existingTrack.filesize == filesize,
           abs(existingTrack.mtime.timeIntervalSince1970 - mtime.timeIntervalSince1970) < 0.5,
           let existingHash = existingTrack.contentHash,
           !existingHash.isEmpty {
            return existingHash
        }
        return try sha256Hex(for: fileURL)
    }

    private func sha256Hex(for fileURL: URL) throws -> String? {
        let chunkSize = 64 * 1024
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
