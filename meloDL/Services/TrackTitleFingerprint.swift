import Foundation

/// A track title split into the parts that decide whether two titles are the same recording:
/// "Artist feat. X - Title (Extended Mix) [Official Video]" becomes
/// artists {artist, x}, title [title], version "extended mix".
struct TrackTitleFingerprint: Sendable {
    let artistTokens: Set<String>
    let titleTokens: [String]
    /// Sorted words of the version groups, e.g. "extended jerome remix". Empty for the plain or original version.
    let versionSignature: String
    let numbers: Set<String>

    var allTokens: Set<String> {
        artistTokens.union(titleTokens)
    }

    var isEmpty: Bool {
        titleTokens.isEmpty && artistTokens.isEmpty
    }

    init(_ raw: String) {
        var text = Self.fold(raw)
        for pattern in Self.noisePatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        var artists = Set<String>()
        var titleWords: [String] = []
        var versionWords: [String] = []

        // Bracket groups, including an unclosed one cut off by a truncated filename.
        let groupPattern = #"[\(\[\{]([^\(\)\[\]\{\}]*)(?:[\)\]\}]|$)"#
        let groups = Self.matches(of: groupPattern, in: text)
        text = text.replacingOccurrences(of: groupPattern, with: " - ", options: .regularExpression)
        for group in groups {
            Self.classify(segment: group, artists: &artists, title: &titleWords, versions: &versionWords)
        }

        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: "|｜"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !Self.tokens($0).isEmpty }

        if parts.count >= 2 {
            artists.formUnion(Self.tokens(parts[0]))
            for part in parts.dropFirst() {
                Self.classify(segment: part, artists: &artists, title: &titleWords, versions: &versionWords)
            }
        } else if let only = parts.first {
            Self.classify(segment: only, artists: &artists, title: &titleWords, versions: &versionWords)
        }

        let versionSet = Set(versionWords).subtracting(Self.separatorWords)
        artistTokens = artists.subtracting(Self.separatorWords)
        titleTokens = titleWords.filter { !Self.separatorWords.contains($0) }
        versionSignature = versionSet.isSubset(of: Self.neutralVersionWords) ? "" : versionSet.sorted().joined(separator: " ")
        numbers = Set((titleWords + versionWords).filter { $0.allSatisfy(\.isNumber) })
    }

    // MARK: - Matching

    enum Strength: Comparable, Sendable {
        case low
        case medium
        case high
    }

    struct Match: Sendable {
        let score: Double
        let strength: Strength
        let reason: String
    }

    /// nil when the titles describe different recordings.
    func match(_ other: TrackTitleFingerprint) -> Match? {
        guard !isEmpty, !other.isEmpty else { return nil }

        // A different remix, edit, or episode number is a different track.
        if !versionSignature.isEmpty, !other.versionSignature.isEmpty, versionSignature != other.versionSignature {
            return nil
        }
        if !numbers.isEmpty, !other.numbers.isEmpty, numbers != other.numbers {
            return nil
        }

        let bothHaveArtists = !artistTokens.isEmpty && !other.artistTokens.isEmpty
        let artistOverlap = bothHaveArtists
            ? Double(artistTokens.intersection(other.artistTokens).count) / Double(min(artistTokens.count, other.artistTokens.count))
            : 0
        // Same title by clearly different artists is a different song.
        if bothHaveArtists, artistOverlap < 0.5 { return nil }
        let artistsAgree = artistOverlap >= 0.99

        // Bilingual uploads add a translated title, so one title fully inside the other still counts,
        // as long as it's more than one word or the artists match.
        let smaller = Set(titleTokens.count <= other.titleTokens.count ? titleTokens : other.titleTokens)
        let larger = Set(titleTokens.count <= other.titleTokens.count ? other.titleTokens : titleTokens)
        let titleContained = !smaller.isEmpty && smaller.isSubset(of: larger) && (smaller.count >= 2 || artistsAgree)
        let titleScore = max(Self.similarity(titleTokens, other.titleTokens), titleContained ? 0.8 : 0)
        var score: Double

        if bothHaveArtists {
            score = 0.65 * titleScore + 0.35 * artistOverlap
        } else {
            // One side has no "Artist - " prefix, so its artist may sit inside the title words.
            let whole = Self.similarity(allTokens.sorted(), other.allTokens.sorted())
            let contained = !titleTokens.isEmpty && !other.titleTokens.isEmpty
                && Set(titleTokens).isSubset(of: other.allTokens)
                && Set(other.titleTokens).isSubset(of: allTokens)
            score = max(titleScore, whole, contained ? 0.92 : 0)
        }

        guard score >= 0.72 else { return nil }

        var strength: Strength = score >= 0.9 ? .high : score >= 0.82 ? .medium : .low
        // One-word titles like "Echo" need the artist to agree before they count as sure.
        let isWeak = Set(titleTokens).count <= 1 && !artistsAgree
        // "Be In The Moment (ASOT 86)" against a plain "Be In The Moment" may be another recording.
        if isWeak || versionSignature != other.versionSignature || numbers != other.numbers {
            strength = .low
        }

        let reason: String
        if versionSignature != other.versionSignature {
            reason = "Same song, possibly a different version"
        } else if score >= 0.99 {
            reason = bothHaveArtists ? "Same artist and title" : "Same title"
        } else {
            reason = "Similar title"
        }
        return Match(score: min(score, 1), strength: strength, reason: reason)
    }

    /// Words worth looking up candidates by.
    var searchTokens: Set<String> {
        allTokens.filter { $0.count >= 2 && !Self.stopWords.contains($0) }
    }

    // MARK: - Parsing

    static let versionWordSet: Set<String> = [
        "remix", "rmx", "mix", "edit", "extended", "radio", "club", "dub", "vip", "acapella", "acappella",
        "instrumental", "live", "bootleg", "mashup", "rework", "flip", "remake", "cover", "karaoke",
        "slowed", "sped", "nightcore", "reverb", "acoustic", "remaster", "remastered", "version", "edition"
    ]
    private static let neutralVersionWords: Set<String> = ["original", "mix", "version"]
    private static let separatorWords: Set<String> = ["feat", "ft", "featuring", "vs", "x", "and", "with", "presents", "pres"]
    private static let stopWords: Set<String> = separatorWords.union(["the", "a", "an", "of", "de", "la", "el", "le", "in", "on", "to", "my", "me", "you"])

    /// Upload filler that says nothing about the recording.
    private static let noisePatterns = [
        #"\bofficial\s+(?:music\s+|lyrics?\s+|hd\s+|4k\s+)?(?:video|audio|visuali[sz]er|clip|videoclip)\b"#,
        #"\b(?:music|lyrics?)\s+video\b"#,
        #"\bvideo\s*clip\b"#,
        #"\bclip\s+officiel\b"#,
        #"\b(?:lyrics?|visuali[sz]er|official|audio|hd|hq|4k|1080p|720p|out\s+now|free\s+download)\b"#
    ]

    private static func classify(segment: String, artists: inout Set<String>, title: inout [String], versions: inout [String]) {
        if let featuring = segment.range(of: #"\b(?:feat|ft|featuring)\b\.?"#, options: .regularExpression) {
            artists.formUnion(tokens(String(segment[featuring.upperBound...])))
            classify(segment: String(segment[..<featuring.lowerBound]), artists: &artists, title: &title, versions: &versions)
            return
        }
        let words = tokens(segment)
        if words.contains(where: versionWordSet.contains) {
            versions += words
        } else {
            title += words
        }
    }

    static func fold(_ input: String) -> String {
        input
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    /// Letters and digits of any script; everything else separates words.
    static func tokens(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Similarity

    /// Character and word overlap of two word lists, 0...1.
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return stringSimilarity(a.joined(separator: " "), b.joined(separator: " "))
    }

    static func stringSimilarity(_ a: String, _ b: String) -> Double {
        let jaccard = jaccardSimilarity(Set(a.split(separator: " ")), Set(b.split(separator: " ")))
        return 0.65 * levenshteinSimilarity(a, b) + 0.35 * jaccard
    }

    private static func jaccardSimilarity(_ a: Set<Substring>, _ b: Set<Substring>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    private static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        let maxLength = max(a.count, b.count)
        guard maxLength > 0 else { return 0 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var previous = Array(0 ... b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(maxLength)
    }
}
