import Foundation
import Security
import os

struct SpotifyCollection: Sendable {
    let name: String
    let tracks: [SpotifyTrack]
    let isTruncated: Bool
}

enum SpotifyError: LocalizedError {
    case unavailable
    case likedSongsNeedsConnection
    case unreadable
    case empty
    case authFailed(String)
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This Spotify link is private or unavailable. To download your own private playlists, connect Spotify in Settings > Spotify."
        case .likedSongsNeedsConnection:
            return "Connect Spotify in Settings > Spotify to download your Liked Songs."
        case .unreadable:
            return "Couldn't read this Spotify link. Spotify may have changed its page format."
        case .empty:
            return "No songs found in this Spotify link."
        case .authFailed(let message):
            return "Spotify login failed: \(message)"
        case .requestFailed(let status):
            return "Spotify request failed (HTTP \(status))."
        }
    }
}

private struct SpotifyCredentials: Codable {
    var clientID: String
    var refreshToken: String
    var displayName: String?
}

actor SpotifyService {
    static let shared = SpotifyService()
    static let embedTrackLimit = 100
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "SpotifyService")
    private let session = URLSession(configuration: .ephemeral)
    private var credentials: SpotifyCredentials?
    private var didLoadCredentials = false
    private var accessToken: (value: String, expiresAt: Date)?

    // MARK: - Connection

    var connectedAccountName: String? {
        loadCredentialsIfNeeded()
        guard let credentials else { return nil }
        return credentials.displayName ?? "Spotify account"
    }

    var connectedClientID: String? {
        loadCredentialsIfNeeded()
        return credentials?.clientID
    }

    /// Stores tokens from a completed login and returns the account's display name.
    func storeConnection(clientID: String, refreshToken: String, accessToken: String, expiresIn: Double) async throws -> String {
        self.accessToken = (accessToken, Date().addingTimeInterval(expiresIn - 60))
        credentials = SpotifyCredentials(clientID: clientID, refreshToken: refreshToken, displayName: nil)
        didLoadCredentials = true

        let me = try await apiObject("https://api.spotify.com/v1/me")
        let name = (me["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (me["id"] as? String) ?? "Spotify account"
        credentials?.displayName = name
        try saveCredentials()
        return name
    }

    func disconnect() {
        credentials = nil
        accessToken = nil
        didLoadCredentials = true
        SecItemDelete(keychainQuery as CFDictionary)
    }

    // MARK: - Resolve

    func resolve(_ link: SpotifyLink) async throws -> SpotifyCollection {
        loadCredentialsIfNeeded()

        if link == .likedSongs {
            guard credentials != nil else { throw SpotifyError.likedSongsNeedsConnection }
            return try await apiLikedSongs()
        }

        if credentials != nil {
            do {
                if let collection = try await apiResolve(link) {
                    return collection
                }
            } catch {
                logger.warning("Spotify API lookup failed, falling back to embed: \(error.localizedDescription, privacy: .public)")
            }
        }

        return try await embedResolve(link)
    }

    // MARK: - Web API

    /// Returns nil when the API doesn't expose the content (playlists the user doesn't own or collaborate on).
    private func apiResolve(_ link: SpotifyLink) async throws -> SpotifyCollection? {
        switch link {
        case .track(let id):
            let object = try await apiObject("https://api.spotify.com/v1/tracks/\(id)")
            guard let track = Self.parseAPITrack(object) else { throw SpotifyError.unreadable }
            return SpotifyCollection(name: track.displayTitle, tracks: [track], isTruncated: false)

        case .album(let id):
            let album = try await apiObject("https://api.spotify.com/v1/albums/\(id)")
            let name = album["name"] as? String ?? "Album"
            var page = album["tracks"] as? [String: Any]
            var tracks: [SpotifyTrack] = []
            while let current = page {
                for item in current["items"] as? [[String: Any]] ?? [] {
                    if let track = Self.parseAPITrack(item, album: album) {
                        tracks.append(track)
                    }
                }
                page = try await nextPage(of: current)
            }
            return SpotifyCollection(name: name, tracks: tracks, isTruncated: false)

        case .playlist(let id):
            let playlist = try await apiObject("https://api.spotify.com/v1/playlists/\(id)")
            guard var page = (playlist["items"] ?? playlist["tracks"]) as? [String: Any],
                  page["items"] != nil else {
                return nil
            }
            let name = playlist["name"] as? String ?? "Playlist"
            var tracks: [SpotifyTrack] = []
            while true {
                tracks += Self.parseAPIPlaylistItems(page)
                guard let next = try await nextPage(of: page) else { break }
                page = next
            }
            return SpotifyCollection(name: name, tracks: tracks, isTruncated: false)

        case .likedSongs:
            return try await apiLikedSongs()
        }
    }

    private func apiLikedSongs() async throws -> SpotifyCollection {
        var page: [String: Any]? = try await apiObject("https://api.spotify.com/v1/me/tracks?limit=50")
        var tracks: [SpotifyTrack] = []
        while let current = page {
            tracks += Self.parseAPIPlaylistItems(current)
            page = try await nextPage(of: current)
        }
        return SpotifyCollection(name: "Liked Songs", tracks: tracks, isTruncated: false)
    }

    private func nextPage(of page: [String: Any]) async throws -> [String: Any]? {
        guard let next = page["next"] as? String, !next.isEmpty else { return nil }
        return try await apiObject(next)
    }

    private func apiObject(_ urlString: String, retryOnUnauthorized: Bool = true) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw SpotifyError.unreadable }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch status {
        case 200:
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SpotifyError.unreadable
            }
            return object
        case 401 where retryOnUnauthorized:
            accessToken = nil
            return try await apiObject(urlString, retryOnUnauthorized: false)
        case 429:
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
            try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 30) * 1_000_000_000))
            return try await apiObject(urlString, retryOnUnauthorized: retryOnUnauthorized)
        case 403, 404:
            throw SpotifyError.unavailable
        default:
            throw SpotifyError.requestFailed(status)
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expiresAt > Date() {
            return accessToken.value
        }
        guard let credentials else { throw SpotifyError.authFailed("Not connected") }

        let response = try await Self.tokenRequest(
            session: session,
            form: [
                "grant_type": "refresh_token",
                "refresh_token": credentials.refreshToken,
                "client_id": credentials.clientID
            ]
        )
        accessToken = (response.accessToken, Date().addingTimeInterval(response.expiresIn - 60))
        if let rotated = response.refreshToken, rotated != credentials.refreshToken {
            self.credentials?.refreshToken = rotated
            try? saveCredentials()
        }
        return response.accessToken
    }

    struct TokenResponse: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
    }

    static func tokenRequest(session: URLSession = .shared, form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let accessToken = object["access_token"] as? String else {
            let message = object["error_description"] as? String ?? object["error"] as? String ?? "Unexpected response"
            throw SpotifyError.authFailed(message)
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expiresIn: (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        )
    }

    private static func parseAPIPlaylistItems(_ page: [String: Any]) -> [SpotifyTrack] {
        (page["items"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let track = (entry["item"] ?? entry["track"]) as? [String: Any],
                  (track["type"] as? String ?? "track") == "track" else { return nil }
            return parseAPITrack(track)
        }
    }

    private static func parseAPITrack(_ object: [String: Any], album: [String: Any]? = nil) -> SpotifyTrack? {
        guard let id = object["id"] as? String,
              let name = object["name"] as? String else { return nil }
        let albumObject = album ?? object["album"] as? [String: Any]
        let artistNames: ([[String: Any]]?) -> [String] = { ($0 ?? []).compactMap { $0["name"] as? String } }
        return SpotifyTrack(
            id: id,
            title: name,
            artists: artistNames(object["artists"] as? [[String: Any]]),
            album: albumObject?["name"] as? String,
            albumArtist: artistNames(albumObject?["artists"] as? [[String: Any]]).first,
            releaseDate: albumObject?["release_date"] as? String,
            trackNumber: object["track_number"] as? Int,
            durationMs: object["duration_ms"] as? Int ?? 0
        )
    }

    // MARK: - Embed

    private func embedResolve(_ link: SpotifyLink) async throws -> SpotifyCollection {
        let path: String
        switch link {
        case .track(let id): path = "track/\(id)"
        case .album(let id): path = "album/\(id)"
        case .playlist(let id): path = "playlist/\(id)"
        case .likedSongs: throw SpotifyError.likedSongsNeedsConnection
        }

        var request = URLRequest(url: URL(string: "https://open.spotify.com/embed/\(path)")!)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw status == 404 ? SpotifyError.unavailable : SpotifyError.requestFailed(status)
        }

        let html = String(decoding: data, as: UTF8.self)
        guard let entity = Self.embedEntity(from: html) else { throw SpotifyError.unavailable }
        return try Self.parseEmbedEntity(entity, link: link)
    }

    static func embedEntity(from html: String) -> [String: Any]? {
        guard let start = html.range(of: #"<script id="__NEXT_DATA__"[^>]*>"#, options: .regularExpression),
              let end = html.range(of: "</script>", range: start.upperBound ..< html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound ..< end.lowerBound].utf8)) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let data = state["data"] as? [String: Any] else { return nil }
        return data["entity"] as? [String: Any]
    }

    static func parseEmbedEntity(_ entity: [String: Any], link: SpotifyLink) throws -> SpotifyCollection {
        let releaseDate = ((entity["releaseDate"] as? [String: Any])?["isoString"] as? String).map { String($0.prefix(10)) }
        let name = entity["name"] as? String ?? entity["title"] as? String ?? "Spotify"

        if case .track(let id) = link {
            guard let title = entity["title"] as? String ?? entity["name"] as? String else { throw SpotifyError.unreadable }
            let artists = (entity["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let track = SpotifyTrack(
                id: id,
                title: title,
                artists: artists,
                album: nil,
                albumArtist: nil,
                releaseDate: releaseDate,
                trackNumber: nil,
                durationMs: entity["duration"] as? Int ?? 0
            )
            return SpotifyCollection(name: track.displayTitle, tracks: [track], isTruncated: false)
        }

        guard let trackList = entity["trackList"] as? [[String: Any]] else { throw SpotifyError.unreadable }
        let isAlbum = { if case .album = link { return true } else { return false } }()

        let tracks = trackList.enumerated().compactMap { index, item -> SpotifyTrack? in
            guard (item["entityType"] as? String ?? "track") == "track",
                  let uri = item["uri"] as? String,
                  let id = uri.split(separator: ":").last.map(String.init),
                  let title = item["title"] as? String else { return nil }
            return SpotifyTrack(
                id: id,
                title: title,
                artists: splitEmbedArtists(item["subtitle"] as? String ?? ""),
                album: isAlbum ? name : nil,
                albumArtist: isAlbum ? (entity["subtitle"] as? String).flatMap { splitEmbedArtists($0).first } : nil,
                releaseDate: isAlbum ? releaseDate : nil,
                trackNumber: isAlbum ? index + 1 : nil,
                durationMs: item["duration"] as? Int ?? 0
            )
        }

        let isTruncated = !isAlbum && trackList.count >= embedTrackLimit
        return SpotifyCollection(name: name, tracks: tracks, isTruncated: isTruncated)
    }

    // ponytail: artists arrive as one comma-joined string, so names containing commas ("Tyler, The Creator") split wrong. The Web API path has exact names.
    static func splitEmbedArtists(_ subtitle: String) -> [String] {
        subtitle
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00a0}"))) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Keychain

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.alexapvl.meloDL.spotify",
            kSecAttrAccount as String: "credentials"
        ]
    }

    private func loadCredentialsIfNeeded() {
        guard !didLoadCredentials else { return }
        didLoadCredentials = true
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return }
        credentials = try? JSONDecoder().decode(SpotifyCredentials.self, from: data)
    }

    private func saveCredentials() throws {
        guard let credentials else { return }
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(keychainQuery as CFDictionary)
        var item = keychainQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SpotifyError.authFailed("Couldn't save the login to Keychain (\(status)).")
        }
    }
}
