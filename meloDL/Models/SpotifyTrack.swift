import Foundation

struct SpotifyTrack: Codable, Sendable, Hashable {
    var id: String
    var title: String
    var artists: [String]
    var album: String?
    var albumArtist: String?
    var releaseDate: String?
    var trackNumber: Int?
    var durationMs: Int

    var artistLine: String {
        artists.joined(separator: ", ")
    }

    var displayTitle: String {
        artists.isEmpty ? title : "\(artistLine) - \(title)"
    }

    var durationSec: Double {
        Double(durationMs) / 1_000
    }

    var webURL: String {
        "https://open.spotify.com/track/\(id)"
    }
}

/// Spotify source track plus the YouTube Music result chosen for it.
struct SpotifyItemInfo: Codable, Sendable {
    var track: SpotifyTrack
    var matchTitle: String?
    var matchArtists: String?
    var matchDurationSec: Int?
    var matchScore: Double?
    var needsReview: Bool
}

enum SpotifyLink: Sendable, Equatable {
    case track(String)
    case album(String)
    case playlist(String)
    case likedSongs

    /// Accepts `open.spotify.com` URLs (with optional `intl-xx` prefix) and `spotify:` URIs.
    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String]
        if trimmed.lowercased().hasPrefix("spotify:") {
            parts = trimmed.split(separator: ":").dropFirst().map(String.init)
        } else if let components = URLComponents(string: trimmed),
                  let host = components.host?.lowercased(),
                  host == "open.spotify.com" || host == "play.spotify.com" {
            parts = components.path.split(separator: "/").map(String.init)
        } else {
            return nil
        }

        if parts.first?.hasPrefix("intl-") == true {
            parts.removeFirst()
        }
        if parts.first == "embed" {
            parts.removeFirst()
        }
        if parts.count >= 2, parts[0] == "user" {
            parts.removeFirst(2)
        }

        guard parts.count >= 2 else { return nil }
        let id = parts[1]
        switch parts[0] {
        case "track" where Self.isValidID(id): self = .track(id)
        case "album" where Self.isValidID(id): self = .album(id)
        case "playlist" where Self.isValidID(id): self = .playlist(id)
        case "collection" where id == "tracks": self = .likedSongs
        default: return nil
        }
    }

    private static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
