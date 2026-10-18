import Foundation
import os

struct YouTubeMusicCandidate: Sendable, Equatable {
    let videoID: String
    let title: String
    let artists: [String]
    let durationSec: Int?

    var url: String { "https://music.youtube.com/watch?v=\(videoID)" }
}

struct YouTubeMusicMatch: Sendable {
    let candidate: YouTubeMusicCandidate
    let score: Double
}

/// Finds a Spotify track on YouTube Music through the web client's search endpoint (the one `ytmusicapi` uses).
actor YouTubeMusicMatcher {
    static let shared = YouTubeMusicMatcher()
    /// Title and artist must match and the length must be within 10 seconds.
    static let autoAcceptScore = 0.85

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "YouTubeMusicMatcher")
    private let session = URLSession(configuration: .ephemeral)
    private static let searchURL = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!

    enum Filter: String {
        case songs = "EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ=="
        case videos = "EgWKAQIQAWoQEAMQBBAJEAoQBRAREBAQFQ=="
    }

    /// Searches songs first; falls back to videos when a song isn't in the region's catalog.
    func bestMatch(for track: SpotifyTrack) async throws -> YouTubeMusicMatch? {
        let query = "\(track.artists.joined(separator: " ")) \(track.title)"
        var best = try await bestMatch(for: track, in: search(query, filter: .songs))
        if (best?.score ?? 0) < Self.autoAcceptScore {
            do {
                if let video = try await bestMatch(for: track, in: search(query, filter: .videos)),
                   video.score > best?.score ?? 0 {
                    best = video
                }
            } catch let error where best != nil {
                logger.warning("Video fallback failed for '\(track.displayTitle, privacy: .public)', keeping song match: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let best {
            logger.info("Matched '\(track.displayTitle, privacy: .public)' to '\(best.candidate.title, privacy: .public)' (\(best.score))")
        }
        return best
    }

    /// The web client sends its build date; a stale one can get different or empty responses.
    private static var clientVersion: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return "1.\(formatter.string(from: Date())).01.00"
    }

    private func bestMatch(for track: SpotifyTrack, in candidates: [YouTubeMusicCandidate]) -> YouTubeMusicMatch? {
        candidates
            .map { YouTubeMusicMatch(candidate: $0, score: Self.score(track: track, candidate: $0)) }
            .max { $0.score < $1.score }
    }

    /// Any real search returns results, so an empty response means YouTube throttled or changed the request; retry with backoff.
    func search(_ query: String, filter: Filter) async throws -> [YouTubeMusicCandidate] {
        let attempts = 3
        var lastStatus = 0
        var lastSnippet = ""
        for attempt in 1 ... attempts {
            if attempt > 1 {
                try await Task.sleep(nanoseconds: UInt64(attempt - 1) * 2_000_000_000)
            }
            let (data, status) = try await performSearch(query, filter: filter)
            lastStatus = status
            lastSnippet = String(decoding: data.prefix(300), as: UTF8.self)
            if status == 200 {
                let candidates = (try? JSONSerialization.jsonObject(with: data)).map(Self.parseCandidates) ?? []
                if !candidates.isEmpty { return candidates }
            } else if status != 429 && status < 500 {
                logger.failure("YouTube Music search HTTP \(status) for '\(query)': \(lastSnippet)")
                throw YouTubeMusicMatcherError.requestFailed(status)
            }
        }
        logger.failure("YouTube Music search for '\(query)' returned no results after \(attempts) attempts (HTTP \(lastStatus)): \(lastSnippet)")
        throw YouTubeMusicMatcherError.unexpectedResponse
    }

    private func performSearch(_ query: String, filter: Filter) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.clientVersion, "hl": "en"]],
            "query": query,
            "params": filter.rawValue
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parseCandidates(_ object: Any) -> [YouTubeMusicCandidate] {
        var renderers: [[String: Any]] = []
        collect(key: "musicResponsiveListItemRenderer", in: object, into: &renderers)

        return renderers.compactMap { renderer in
            guard let columns = renderer["flexColumns"] as? [[String: Any]],
                  let titleRuns = runs(in: columns.first),
                  let title = titleRuns.first?["text"] as? String else { return nil }

            let videoID = (renderer["playlistItemData"] as? [String: Any])?["videoId"] as? String
                ?? ((titleRuns.first?["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
            guard let videoID else { return nil }

            let detailRuns = columns.count > 1 ? runs(in: columns[1]) ?? [] : []
            let artists = detailRuns.compactMap { run -> String? in
                guard pageType(of: run) == "MUSIC_PAGE_TYPE_ARTIST" else { return nil }
                return run["text"] as? String
            }
            let duration = detailRuns.compactMap { ($0["text"] as? String).flatMap(parseDuration) }.last

            return YouTubeMusicCandidate(videoID: videoID, title: title, artists: artists, durationSec: duration)
        }
    }

    static func score(track: SpotifyTrack, candidate: YouTubeMusicCandidate) -> Double {
        let primary = track.artists.first.map(DuplicateDetectionService.normalize) ?? ""
        let (unprefixedTitle, prefixHasArtist) = splitArtistPrefix(candidate.title, primaryArtist: primary)
        let trackTitle = withoutFeaturing(track.title)
        let candidateTitle = withoutFeaturing(unprefixedTitle)
        let trackVersion = versionTags(trackTitle)
        let candidateVersion = versionTags(candidateTitle)
        var titleScore = DuplicateDetectionService.titleSimilarity(trackTitle, candidateTitle)
        if trackVersion.isEmpty && candidateVersion.isEmpty {
            titleScore = max(titleScore, DuplicateDetectionService.titleSimilarity(coreTitle(trackTitle), coreTitle(candidateTitle)))
        }

        let candidateArtists = DuplicateDetectionService.normalize(candidate.artists.joined(separator: " "))
        let artistScore: Double
        if prefixHasArtist {
            artistScore = 1
        } else if !primary.isEmpty, !candidateArtists.isEmpty {
            artistScore = candidateArtists.contains(primary)
                ? 1
                : DuplicateDetectionService.titleSimilarity(track.artistLine, candidate.artists.joined(separator: ", "))
        } else {
            artistScore = 0.5
        }

        let durationScore: Double
        if let candidateDuration = candidate.durationSec, track.durationMs > 0 {
            let delta = abs(Double(candidateDuration) - track.durationSec)
            durationScore = delta <= 3 ? 1 : delta <= 10 ? 0.6 : delta <= 30 ? 0.2 : 0
        } else {
            durationScore = 0.5
        }

        let versionPenalty = trackVersion == candidateVersion ? 0 : 0.25
        return max(0, 0.5 * titleScore + 0.3 * artistScore + 0.2 * durationScore - versionPenalty)
    }

    private static let versionWords: Set<String> = [
        "remix", "mix", "edit", "live", "acoustic", "extended", "instrumental",
        "vip", "dub", "rework", "bootleg", "flip", "cover", "karaoke", "slowed", "sped", "acapella"
    ]

    /// Words that mark a different recording of the same song, e.g. "Remix" or "Radio Edit".
    static func versionTags(_ title: String) -> Set<String> {
        Set(DuplicateDetectionService.normalize(title).split(separator: " ").map(String.init)).intersection(versionWords)
    }

    /// Video titles often read "Artist feat. Other - Title (Official Audio)".
    static func splitArtistPrefix(_ title: String, primaryArtist: String) -> (title: String, hasArtist: Bool) {
        guard !primaryArtist.isEmpty, let separator = title.range(of: " - ") else { return (title, false) }
        let head = " \(DuplicateDetectionService.normalize(String(title[..<separator.lowerBound]))) "
        guard head.contains(" \(primaryArtist) ") else { return (title, false) }
        return (String(title[separator.upperBound...]), true)
    }

    /// Featured artists are credited inconsistently ("(feat. X)", "ft. X", or not at all).
    static func withoutFeaturing(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\s*[\(\[](feat|ft|featuring|with)\b[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(feat|ft|featuring)\.?\s[^\(\[]*?(?=\s+-\s|\s*[\(\[]|$)"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Drops "(feat. X)", "[Remastered]" and " - Radio Edit" style suffixes.
    static func coreTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+.*$"#, with: "", options: .regularExpression)
    }

    static func parseDuration(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard (2 ... 3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    private static func runs(in column: [String: Any]?) -> [[String: Any]]? {
        ((column?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]]
    }

    private static func pageType(of run: [String: Any]) -> String? {
        let browse = (run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
        let configs = browse?["browseEndpointContextSupportedConfigs"] as? [String: Any]
        return (configs?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String
    }

    private static func collect(key: String, in object: Any, into results: inout [[String: Any]]) {
        if let dictionary = object as? [String: Any] {
            for (childKey, value) in dictionary {
                if childKey == key, let match = value as? [String: Any] {
                    results.append(match)
                } else {
                    collect(key: key, in: value, into: &results)
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                collect(key: key, in: value, into: &results)
            }
        }
    }
}

enum YouTubeMusicMatcherError: LocalizedError {
    case requestFailed(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed(let status):
            return "YouTube Music search failed (HTTP \(status)). Retry, or send the error log from Settings > Support."
        case .unexpectedResponse:
            return "YouTube Music sent an empty response. Retry, or send the error log from Settings > Support."
        }
    }
}
