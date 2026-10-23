import Foundation

@MainActor
final class RekordboxLibraryStore {
    static let shared = RekordboxLibraryStore()

    private(set) var canonicalPaths: Set<String> = []
    private(set) var trackCount = 0
    private(set) var sourceFilename: String?
    private(set) var importedAt: Date?

    private let fileManager = FileManager.default
    private let fileURL: URL

    private init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = base
            .appendingPathComponent("meloDL", isDirectory: true)
            .appendingPathComponent("rekordbox-library.json")
        loadFromDisk()
    }

    var isActive: Bool {
        !canonicalPaths.isEmpty
    }

    func contains(path: String) -> Bool {
        guard !canonicalPaths.isEmpty else { return false }
        return canonicalPaths.contains(TrackIndexStore.canonicalize(path: path))
    }

    func apply(snapshot: RekordboxLibrarySnapshot) throws {
        canonicalPaths = snapshot.canonicalPaths
        trackCount = snapshot.trackCount
        sourceFilename = snapshot.sourceURL.lastPathComponent
        importedAt = Date()
        try saveToDisk()
    }

    func clear() throws {
        canonicalPaths = []
        trackCount = 0
        sourceFilename = nil
        importedAt = nil
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private struct PersistedState: Codable {
        var canonicalPaths: [String]
        var trackCount: Int
        var sourceFilename: String?
        var importedAt: Date?
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(PersistedState.self, from: data)
            canonicalPaths = Set(persisted.canonicalPaths)
            trackCount = persisted.trackCount
            sourceFilename = persisted.sourceFilename
            importedAt = persisted.importedAt
        } catch {
            canonicalPaths = []
            trackCount = 0
            sourceFilename = nil
            importedAt = nil
        }
    }

    private func saveToDisk() throws {
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let persisted = PersistedState(
            canonicalPaths: Array(canonicalPaths),
            trackCount: trackCount,
            sourceFilename: sourceFilename,
            importedAt: importedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(persisted)
        try data.write(to: fileURL, options: .atomic)
    }
}
