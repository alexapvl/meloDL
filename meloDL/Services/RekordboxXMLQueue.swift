import Foundation
import os

struct RekordboxXMLTrack: Codable, Equatable, Sendable {
    let path: String
    var name: String
    var artist: String?
    var genre: String?
    var comment: String?

    /// File names like "Artist - Title" fill both fields when the file's tags aren't known.
    init(path: String, name: String? = nil, artist: String? = nil, genre: String? = nil, comment: String? = nil) {
        self.path = path
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if let name, !name.isEmpty {
            self.name = name
            self.artist = artist
        } else if artist == nil, let separator = stem.range(of: " - ") {
            self.artist = String(stem[..<separator.lowerBound])
            self.name = String(stem[separator.upperBound...])
        } else {
            self.name = stem
            self.artist = artist
        }
        self.genre = genre?.isEmpty == true ? nil : genre
        self.comment = comment
    }
}

/// Tracks waiting in meloDL's Rekordbox XML file. Rekordbox lists them under its "rekordbox xml"
/// sidebar node, where one Import To Collection adds them all. Imported tracks drop out once
/// the collection is refreshed.
@MainActor
final class RekordboxXMLQueue: ObservableObject {
    static let shared = RekordboxXMLQueue()

    /// The file to set in Rekordbox under Preferences > Advanced > Database > rekordbox xml.
    static let xmlURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("meloDL", isDirectory: true)
        .appendingPathComponent("meloDL-rekordbox.xml")

    @Published private(set) var tracks: [RekordboxXMLTrack] = []

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "RekordboxXMLQueue")
    private let queueURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("meloDL", isDirectory: true)
        .appendingPathComponent("rekordbox-xml-queue.json")

    private init() {
        if let data = try? Data(contentsOf: queueURL),
           let saved = try? JSONDecoder().decode([RekordboxXMLTrack].self, from: data) {
            tracks = saved
        }
        // Rekordbox complains about a missing file, so keep one there even when empty.
        if !FileManager.default.fileExists(atPath: Self.xmlURL.path) {
            save()
        }
    }

    func contains(path: String) -> Bool {
        let canonical = TrackIndexStore.canonicalize(path: path)
        return tracks.contains { $0.path == canonical }
    }

    func add(_ newTracks: [RekordboxXMLTrack]) {
        for var track in newTracks {
            track = RekordboxXMLTrack(
                path: TrackIndexStore.canonicalize(path: track.path),
                name: track.name,
                artist: track.artist,
                genre: track.genre,
                comment: track.comment
            )
            if let index = tracks.firstIndex(where: { $0.path == track.path }) {
                tracks[index] = track
            } else {
                tracks.append(track)
            }
        }
        save()
    }

    func removeAll() {
        tracks = []
        save()
    }

    func remove(paths: Set<String>) {
        let before = tracks.count
        tracks.removeAll { paths.contains($0.path) }
        guard tracks.count != before else { return }
        save()
    }

    /// Drops tracks that are in the collection now, or whose file is gone.
    func removeImported(collectionPaths: Set<String>) {
        let fileManager = FileManager.default
        let before = tracks.count
        tracks.removeAll { collectionPaths.contains($0.path) || !fileManager.fileExists(atPath: $0.path) }
        guard tracks.count != before else { return }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(tracks).write(to: queueURL, options: .atomic)
            try Data(Self.xml(for: tracks).utf8).write(to: Self.xmlURL, options: .atomic)
        } catch {
            logger.failure("Saving the Rekordbox XML failed: \(error.localizedDescription)")
        }
    }

    static func xml(for tracks: [RekordboxXMLTrack]) -> String {
        let entries = tracks.enumerated().map { index, track in
            var attributes = [
                ("TrackID", "\(index + 1)"),
                ("Name", track.name),
                ("Kind", kind(forPath: track.path)),
                ("Location", location(forPath: track.path))
            ]
            if let artist = track.artist { attributes.append(("Artist", artist)) }
            if let genre = track.genre { attributes.append(("Genre", genre)) }
            if let comment = track.comment { attributes.append(("Comments", comment)) }
            let rendered = attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
            return "    <TRACK \(rendered)/>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <PRODUCT Name="meloDL" Version="\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")" Company="meloDL"/>
          <COLLECTION Entries="\(tracks.count)">
        \(entries.joined(separator: "\n"))
          </COLLECTION>
          <PLAYLISTS>
            <NODE Type="0" Name="ROOT" Count="0"/>
          </PLAYLISTS>
        </DJ_PLAYLISTS>

        """
    }

    /// Same encoding as Rekordbox's own export: precomposed UTF-8, only `/-._~(),` left as is.
    private static let locationAllowed = CharacterSet.alphanumerics
        .intersection(CharacterSet(charactersIn: Unicode.Scalar(0) ..< Unicode.Scalar(128)))
        .union(CharacterSet(charactersIn: "/-._~(),"))

    private static func location(forPath path: String) -> String {
        let encoded = path.precomposedStringWithCanonicalMapping
            .addingPercentEncoding(withAllowedCharacters: locationAllowed) ?? path
        return "file://localhost" + encoded
    }

    private static func kind(forPath path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp3": return "MP3 File"
        case "wav": return "WAV File"
        case "m4a", "aac": return "M4A File"
        case "flac": return "FLAC File"
        case "aif", "aiff": return "AIFF File"
        default: return "Audio File"
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
