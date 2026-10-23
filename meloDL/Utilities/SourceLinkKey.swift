import Foundation

/// Stable identity for a track's source link, so the same video matches across
/// youtu.be, music.youtube.com, and playlist-suffixed URLs.
enum SourceLinkKey {
    private static let youTubeHosts: Set<String> = ["youtube.com", "music.youtube.com", "youtu.be"]

    static func key(for text: String) -> String? {
        guard let url = firstURL(in: text),
              let host = url.host?.lowercased() else { return nil }
        var bareHost = Substring(host)
        for prefix in ["www.", "m."] where bareHost.hasPrefix(prefix) {
            bareHost = bareHost.dropFirst(prefix.count)
        }

        if youTubeHosts.contains(String(bareHost)) {
            // Playlist and channel links don't identify one track.
            return youTubeVideoID(url: url, host: String(bareHost)).map { "youtube:\($0)" }
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }
        return "\(bareHost)/\(path)".lowercased()
    }

    private static func youTubeVideoID(url: URL, host: String) -> String? {
        if host == "youtu.be" {
            return url.pathComponents.dropFirst().first
        }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty {
            return id
        }
        let components = url.pathComponents
        if let index = components.firstIndex(where: { $0 == "shorts" || $0 == "live" }), index + 1 < components.count {
            return components[index + 1]
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.range(of: "http") else { return nil }
        let candidate = trimmed[start.lowerBound...].prefix { !$0.isWhitespace }
        return URL(string: String(candidate))
    }
}
