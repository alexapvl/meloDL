import AVFoundation
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
    /// Set while a pass runs, so a pass cut short by quitting resumes on the next launch.
    private let passInProgressKey = "duplicateIndex.passInProgress"
    /// Bump when the metadata read per file changes, so existing rows are read again.
    static let metadataVersion = 1
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
                defaults.set(true, forKey: passInProgressKey)
                do {
                    try await store.ensureReady()
                    try await store.replaceRoots(with: roots)
                    try await store.removeTracksOutsideRoots(roots)

                    var indexedCount = 0
                    for root in roots {
                        indexedCount += try await reindexRoot(rootPath: root, passStartedAt: passStartedAt)
                    }

                    defaults.set(Date().timeIntervalSince1970, forKey: lastIndexKey)
                    defaults.set(false, forKey: passInProgressKey)
                    logger.info("Reindex finished. Indexed \(indexedCount) files across \(roots.count) roots.")
                } catch {
                    logger.failure("Reindex failed: \(error.localizedDescription)")
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
        if intervalElapsed || defaults.bool(forKey: passInProgressKey) { return true }
        do {
            if try await store.countTracksNeedingMetadata(currentVersion: Self.metadataVersion) > 0 {
                return true
            }
            return try await store.countTracks() == 0
        } catch {
            logger.failure("Failed to count tracks before reindex decision: \(error.localizedDescription)")
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
                let metadata = await resolveMetadata(
                    for: fileURL,
                    filesize: filesize,
                    mtime: mtime,
                    existingTrack: existingTrack
                )

                let track = IndexedTrack(
                    path: fileURL.path,
                    rootPath: rootPath,
                    filename: filename,
                    normalizedTitle: normalizedTitle,
                    artistHint: metadata.artist,
                    durationSec: metadata.durationSec,
                    filesize: filesize,
                    mtime: mtime,
                    hashPrefix: hashPrefix,
                    contentHash: contentHash,
                    lastSeenAt: passStartedAt,
                    titleTag: metadata.title,
                    metadataVersion: Self.metadataVersion
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

    private struct FileMetadata {
        var durationSec: Double?
        var artist: String?
        var title: String?
    }

    /// Unchanged files keep what was read before, so only new or edited files are opened.
    private func resolveMetadata(
        for fileURL: URL,
        filesize: Int64?,
        mtime: Date,
        existingTrack: IndexedTrack?
    ) async -> FileMetadata {
        if let existingTrack,
           existingTrack.metadataVersion >= Self.metadataVersion,
           existingTrack.filesize == filesize,
           abs(existingTrack.mtime.timeIntervalSince1970 - mtime.timeIntervalSince1970) < 0.5 {
            return FileMetadata(durationSec: existingTrack.durationSec, artist: existingTrack.artistHint, title: existingTrack.titleTag)
        }
        return await readMetadata(for: fileURL)
    }

    /// Reads only the header: length plus artist and title tags. Formats AVFoundation can't open just get nothing.
    private func readMetadata(for fileURL: URL) async -> FileMetadata {
        let asset = AVURLAsset(url: fileURL)
        guard let (duration, metadata) = try? await asset.load(.duration, .commonMetadata) else {
            return FileMetadata()
        }

        func string(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
                  let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        let seconds = duration.seconds
        return FileMetadata(
            durationSec: seconds.isFinite && seconds > 0 ? seconds : nil,
            artist: await string(.commonIdentifierArtist),
            title: await string(.commonIdentifierTitle)
        )
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
