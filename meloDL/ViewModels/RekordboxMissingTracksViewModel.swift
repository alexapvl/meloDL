import AppKit
import Combine
import Foundation
import SwiftUI

/// Indexed tracks that aren't in the Rekordbox collection, grouped by folder,
/// for adding to meloDL's Rekordbox XML in bulk.
@MainActor
final class RekordboxMissingTracksViewModel: ObservableObject {
    struct Track: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let name: String
        let artist: String?
        let durationSec: Double?
        let folder: String
    }

    struct Folder: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let tracks: [Track]
    }

    @Published var searchText = "" {
        didSet { rebuild() }
    }
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var ignoredFolders: [Folder] = []
    @Published var selection: Set<String> = []
    /// Genre for the selected tracks. nil uses the default genre.
    @Published var genre: String?
    @Published private(set) var isLoading = false
    @Published private(set) var importActivity: RekordboxImportActivity?
    private var allTracks: [Track] = []
    private var cancellables: Set<AnyCancellable> = []

    private let appSettings: AppSettings
    private let indexStore: TrackIndexStore
    private let rekordboxLibrary: RekordboxLibraryStore
    private let xmlQueue: RekordboxXMLQueue

    init(
        appSettings: AppSettings,
        indexStore: TrackIndexStore = .shared,
        rekordboxLibrary: RekordboxLibraryStore = .shared,
        xmlQueue: RekordboxXMLQueue = .shared
    ) {
        self.appSettings = appSettings
        self.indexStore = indexStore
        self.rekordboxLibrary = rekordboxLibrary
        self.xmlQueue = xmlQueue

        // Rebuild after the change lands; @Published fires before the new value is stored.
        Publishers.Merge4(
            rekordboxLibrary.$canonicalPaths.map { _ in () },
            xmlQueue.$tracks.map { _ in () },
            appSettings.$rekordboxIgnoredPaths.map { _ in () },
            appSettings.$rekordboxIncludesAppleMusicLibrary.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuild() }
        .store(in: &cancellables)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let titles = (try? await indexStore.fetchTitleCorpus()) ?? []
        allTracks = titles.map { title in
            let path = TrackIndexStore.canonicalize(path: title.path)
            let stem = (title.filename as NSString).deletingPathExtension
            return Track(
                path: path,
                name: title.titleTag ?? stem,
                artist: title.titleTag == nil ? nil : title.artistTag,
                durationSec: title.durationSec,
                folder: (path as NSString).deletingLastPathComponent
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        rebuild()
    }

    /// Missing tracks, minus ignored ones, the Apple Music library unless included, and tracks already in the XML.
    private func rebuild() {
        let collection = rekordboxLibrary.canonicalPaths
        let queued = Set(xmlQueue.tracks.map(\.path))
        let missing = allTracks.filter { !collection.contains($0.path) && !queued.contains($0.path) }
        folders = group(missing.filter { !isIgnored($0) && matchesSearch($0) })
        ignoredFolders = group(missing.filter { isIgnored($0) && !isHiddenAppleMusic($0) })
        selection.formIntersection(folders.flatMap(\.tracks).map(\.path))
    }

    var missingCount: Int {
        folders.reduce(0) { $0 + $1.tracks.count }
    }

    var selectedTracks: [Track] {
        folders.flatMap(\.tracks).filter { selection.contains($0.path) }
    }

    // MARK: - Selection

    func toggle(_ track: Track) {
        if selection.contains(track.path) {
            selection.remove(track.path)
        } else {
            selection.insert(track.path)
        }
    }

    func isFullySelected(_ folder: Folder) -> Bool {
        folder.tracks.allSatisfy { selection.contains($0.path) }
    }

    func toggle(_ folder: Folder) {
        let paths = Set(folder.tracks.map(\.path))
        if isFullySelected(folder) {
            selection.subtract(paths)
        } else {
            selection.formUnion(paths)
        }
    }

    func selectAll() {
        selection = Set(folders.flatMap(\.tracks).map(\.path))
    }

    func clearSelection() {
        selection = []
    }

    // MARK: - Ignoring

    func ignore(folder: Folder) {
        ignore(path: folder.path)
        selection.subtract(folder.tracks.map(\.path))
    }

    func ignore(track: Track) {
        ignore(path: track.path)
        selection.remove(track.path)
    }

    func unignore(folder: Folder) {
        let paths = Set(folder.tracks.map(\.path) + [folder.path])
        appSettings.rekordboxIgnoredPaths.removeAll { ignored in
            paths.contains(ignored) || folder.path.hasPrefix(ignored + "/")
        }
    }

    private func ignore(path: String) {
        guard !appSettings.rekordboxIgnoredPaths.contains(path) else { return }
        appSettings.rekordboxIgnoredPaths.append(path)
    }

    // MARK: - Adding

    var isImporting: Bool {
        importActivity?.isRunning == true
    }

    func importSelection() {
        guard !isImporting else { return }
        let defaultGenre = appSettings.rekordboxDefaultGenre
        let tracks = selectedTracks.map { track in
            RekordboxXMLTrack(
                path: track.path,
                name: track.artist == nil ? nil : track.name,
                artist: track.artist,
                genre: genre ?? defaultGenre
            )
        }
        guard !tracks.isEmpty else { return }

        importActivity = .importing(count: tracks.count)
        Task {
            do {
                let outcome = try await RekordboxImporter.shared.importTracks(
                    tracks,
                    playlistName: "meloDL import",
                    keepsPlaylist: appSettings.rekordboxKeepsImportPlaylist
                ) { [weak self] step in
                    self?.importActivity = RekordboxImportActivity(step)
                }
                importActivity = RekordboxImportActivity(outcome)
                selection = []
            } catch {
                importActivity = .failed(error.localizedDescription)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func dismissImportActivity() {
        guard !isImporting else { return }
        importActivity = nil
    }

    // MARK: - Filtering

    private func isIgnored(_ track: Track) -> Bool {
        if isHiddenAppleMusic(track) { return true }
        return appSettings.rekordboxIgnoredPaths.contains { ignored in
            track.path == ignored || track.path.hasPrefix(ignored + "/")
        }
    }

    private func isHiddenAppleMusic(_ track: Track) -> Bool {
        !appSettings.rekordboxIncludesAppleMusicLibrary && Self.isInAppleMusicLibrary(track.path)
    }

    /// Apple Music keeps its files in ~/Music/Music/Media(.localized).
    private static let appleMusicLibraryPrefix = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Music/").path

    static func isInAppleMusicLibrary(_ path: String) -> Bool {
        path.hasPrefix(appleMusicLibraryPrefix)
    }

    private func matchesSearch(_ track: Track) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return track.path.localizedCaseInsensitiveContains(query)
            || track.name.localizedCaseInsensitiveContains(query)
            || (track.artist?.localizedCaseInsensitiveContains(query) ?? false)
    }

    private func group(_ tracks: [Track]) -> [Folder] {
        Dictionary(grouping: tracks, by: \.folder)
            .map { Folder(path: $0.key, tracks: $0.value) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
