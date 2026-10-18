// Live self-check for Spotify link parsing, embed scraping, YouTube Music matching and tag arguments.
// Run: scripts/spotify-check.sh

import Foundation

@main
struct SpotifyCheck {
    static func main() async throws {
        assert(SpotifyLink("https://open.spotify.com/intl-de/track/3zOYmiNOuyDL0ClxJcEJ0T?si=abc") == .track("3zOYmiNOuyDL0ClxJcEJ0T"))
        assert(SpotifyLink("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M") == .playlist("37i9dQZF1DXcBWIGoYBM5M"))
        assert(SpotifyLink("https://open.spotify.com/collection/tracks") == .likedSongs)
        assert(SpotifyLink("https://www.youtube.com/watch?v=x") == nil)
        assert(SpotifySplitCheck.split("Pitbull,\u{00a0}Sensato") == ["Pitbull", "Sensato"])

        let args = DownloadEngine.metadataOverrideArguments(for: SpotifyTrack(
            id: "x", title: "A: B 50%", artists: ["C"], album: nil, albumArtist: nil, releaseDate: nil, trackNumber: 3, durationMs: 1
        ))
        assert(args.contains("A\\: B 50%%%(meloDL|)s:%(meta_title)s"))
        assert(args.contains("3%(meloDL|)s:%(meta_track)s"))
        assert(!args.contains { $0.contains("meta_album") })

        let latch = SpotifyTrack(id: "x", title: "Latch - Kaytranada Remix", artists: ["Disclosure"], album: nil, albumArtist: nil, releaseDate: nil, trackNumber: nil, durationMs: 250_000)
        let original = YouTubeMusicCandidate(videoID: "a", title: "Latch", artists: ["Disclosure", "Sam Smith"], durationSec: 255)
        let sameRemix = YouTubeMusicCandidate(videoID: "b", title: "Latch (Kaytranada Remix)", artists: ["Disclosure"], durationSec: 251)
        assert(YouTubeMusicMatcher.score(track: latch, candidate: original) < YouTubeMusicMatcher.autoAcceptScore)
        assert(YouTubeMusicMatcher.score(track: latch, candidate: sameRemix) >= YouTubeMusicMatcher.autoAcceptScore)

        let rain = SpotifyTrack(id: "x", title: "Rain Over Me (feat. Marc Anthony) - Benny Benassi Remix", artists: ["Pitbull", "Marc Anthony"], album: nil, albumArtist: nil, releaseDate: nil, trackNumber: nil, durationMs: 316_000)
        let rainVideo = YouTubeMusicCandidate(videoID: "c", title: "Pitbull Feat. Marc Anthony - Rain Over Me (Benny Benassi Remix)", artists: [], durationSec: 317)
        assert(YouTubeMusicMatcher.score(track: rain, candidate: rainVideo) >= YouTubeMusicMatcher.autoAcceptScore)

        let playlist = try await SpotifyService.shared.resolve(.playlist("37i9dQZF1DX5Ejj0EkURtP"))
        print("playlist:", playlist.name, playlist.tracks.count, "truncated:", playlist.isTruncated)
        assert(playlist.tracks.count == SpotifyService.embedTrackLimit && playlist.isTruncated)

        let album = try await SpotifyService.shared.resolve(.album("4aawyAB9vmqN3uQ7FjRGTy"))
        print("album:", album.name, album.tracks.count, album.tracks[0].album ?? "-", album.tracks[0].trackNumber ?? 0)
        assert(album.tracks.first?.album == album.name && !album.isTruncated)

        var accepted = 0
        for track in playlist.tracks.prefix(8) {
            let match = try await YouTubeMusicMatcher.shared.bestMatch(for: track)
            let score = match?.score ?? 0
            if score >= YouTubeMusicMatcher.autoAcceptScore { accepted += 1 }
            print(String(format: "%.2f", score), track.displayTitle, "->", match?.candidate.title ?? "nil", match?.candidate.artists ?? [])
        }
        assert(accepted >= 6, "Most popular tracks should auto-match")
        print("OK")
    }
}

enum SpotifySplitCheck {
    static func split(_ value: String) -> [String] { SpotifyService.splitEmbedArtists(value) }
}
