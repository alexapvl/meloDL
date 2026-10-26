import Foundation

@MainActor
final class RekordboxLibraryStore: ObservableObject {
    static let shared = RekordboxLibraryStore()

    /// Where meloDL asks Rekordbox to export the collection.
    static let automaticExportURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("meloDL", isDirectory: true)
        .appendingPathComponent("rekordbox-collection.xml")

    @Published private(set) var canonicalPaths: Set<String> = []
    @Published private(set) var trackCount = 0
    @Published private(set) var sourceFilename: String?
    @Published private(set) var importedAt: Date?
    /// Genres used in the collection, most used first. YouTube categories are left out.
    @Published private(set) var genres: [String] = []
    private(set) var sourceLinkPaths: [String: String] = [:]
    private var sourcePath: String?
    private var sourceModifiedAt: Date?

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

    func path(forSourceLinkKey key: String) -> String? {
        sourceLinkPaths[key]
    }

    func load(from url: URL) async throws {
        let snapshot = try await RekordboxXMLImportService.shared.importSnapshot(from: url)
        try apply(snapshot: snapshot)
    }

    /// Has Rekordbox export its collection, then loads it.
    func refreshFromRekordbox() async throws {
        try await RekordboxAutomationService.shared.exportCollection(to: Self.automaticExportURL)
        try await load(from: Self.automaticExportURL)
    }

    /// Picks up a newer export written to the same file, e.g. a manual re-export from Rekordbox.
    func reloadIfSourceChanged() async {
        guard let sourcePath,
              let modifiedAt = Self.modificationDate(atPath: sourcePath),
              modifiedAt != sourceModifiedAt else { return }
        try? await load(from: URL(fileURLWithPath: sourcePath))
    }

    func apply(snapshot: RekordboxLibrarySnapshot) throws {
        canonicalPaths = snapshot.canonicalPaths
        trackCount = snapshot.trackCount
        sourceFilename = snapshot.sourceURL.lastPathComponent
        importedAt = Date()
        genres = Self.rankedGenres(from: snapshot.genreCounts)
        sourceLinkPaths = snapshot.sourceLinkPaths
        sourcePath = snapshot.sourceURL.path
        sourceModifiedAt = Self.modificationDate(atPath: snapshot.sourceURL.path)
        try saveToDisk()
        RekordboxXMLQueue.shared.removeImported(collectionPaths: canonicalPaths)
    }

    func clear() throws {
        canonicalPaths = []
        trackCount = 0
        sourceFilename = nil
        importedAt = nil
        genres = []
        sourceLinkPaths = [:]
        sourcePath = nil
        sourceModifiedAt = nil
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    /// yt-dlp writes the YouTube category as the genre, so these aren't real genres.
    private static let youTubeCategories: Set<String> = [
        "Autos & Vehicles", "Comedy", "Education", "Entertainment", "Film & Animation",
        "Gaming", "Howto & Style", "Music", "News & Politics", "Nonprofits & Activism",
        "People & Blogs", "Pets & Animals", "Science & Technology", "Sports", "Travel & Events"
    ]

    private static func rankedGenres(from counts: [String: Int]) -> [String] {
        counts
            .filter { genre, _ in !youTubeCategories.contains(genre) && Int(genre) == nil }
            .sorted { lhs, rhs in
                lhs.value != rhs.value
                    ? lhs.value > rhs.value
                    : lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .map(\.key)
    }

    private static func modificationDate(atPath path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private struct PersistedState: Codable {
        var canonicalPaths: [String]
        var trackCount: Int
        var sourceFilename: String?
        var importedAt: Date?
        var genres: [String]?
        var sourceLinkPaths: [String: String]?
        var sourcePath: String?
        var sourceModifiedAt: Date?
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
            genres = persisted.genres ?? []
            sourceLinkPaths = persisted.sourceLinkPaths ?? [:]
            sourcePath = persisted.sourcePath
            sourceModifiedAt = persisted.sourceModifiedAt
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
            importedAt: importedAt,
            genres: genres,
            sourceLinkPaths: sourceLinkPaths,
            sourcePath: sourcePath,
            sourceModifiedAt: sourceModifiedAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(persisted)
        try data.write(to: fileURL, options: .atomic)
    }
}
