import Foundation
import os

actor DuplicateDetectionService {
    static let shared = DuplicateDetectionService()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL",
        category: "DuplicateDetectionService"
    )
    private let indexStore: TrackIndexStore

    init(indexStore: TrackIndexStore = .shared) {
        self.indexStore = indexStore
    }

    func findPotentialDuplicates(title: String, expectedDurationSec: Double? = nil) async throws -> [DuplicateMatch] {
        let normalizedTitle = Self.normalize(title)
        guard !normalizedTitle.isEmpty else { return [] }

        let candidates = try await indexStore.fetchCandidateTracks(forNormalizedTitle: normalizedTitle, limit: 250)
        guard !candidates.isEmpty else { return [] }

        let sourceTokens = Set(Self.tokens(from: normalizedTitle))
        var matches: [DuplicateMatch] = []

        for candidate in candidates {
            let candidateTitle = candidate.normalizedTitle
            guard !candidateTitle.isEmpty else { continue }

            if candidateTitle == normalizedTitle {
                matches.append(DuplicateMatch(
                    candidatePath: candidate.path,
                    candidateTitle: candidate.filename,
                    confidence: .high,
                    score: 1.0,
                    reason: "Exact normalized title match"
                ))
                continue
            }

            let candidateTokens = Set(Self.tokens(from: candidateTitle))
            let jaccard = Self.jaccardSimilarity(sourceTokens, candidateTokens)
            let levenshtein = Self.normalizedLevenshteinSimilarity(normalizedTitle, candidateTitle)

            var score = (0.65 * levenshtein) + (0.35 * jaccard)

            if let expectedDurationSec,
               let candidateDuration = candidate.durationSec {
                let delta = abs(expectedDurationSec - candidateDuration)
                if delta > 3 {
                    score -= 0.25
                }
            }

            guard score >= 0.72 else { continue }
            let confidence: DuplicateMatch.Confidence
            if score >= 0.90 {
                confidence = .high
            } else if score >= 0.82 {
                confidence = .medium
            } else {
                confidence = .low
            }

            matches.append(DuplicateMatch(
                candidatePath: candidate.path,
                candidateTitle: candidate.filename,
                confidence: confidence,
                score: max(0, min(1, score)),
                reason: "Fuzzy title similarity"
            ))
        }

        matches.sort { $0.score > $1.score }
        let topMatches = Array(matches.prefix(10))
        logger.info("Duplicate check for '\(title, privacy: .public)' produced \(topMatches.count) match(es)")
        return topMatches
    }

    func findExactDuplicateFileGroups(limit: Int = 300) async throws -> [ExactDuplicateGroup] {
        let groups = try await indexStore.fetchExactDuplicateGroups(limit: limit)
        logger.info("Exact duplicate scan produced \(groups.count) grouped duplicate hash(es)")
        return groups
    }

    static func normalize(_ input: String) -> String {
        let lowered = input
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let sanitized = lowered.replacingOccurrences(
            of: #"[^a-z0-9\s]"#,
            with: " ",
            options: .regularExpression
        )
        return sanitized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
    }

    private static func tokens(from normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    private static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1.0 }
        let intersection = Double(a.intersection(b).count)
        let union = Double(a.union(b).count)
        guard union > 0 else { return 0 }
        return intersection / union
    }

    private static func normalizedLevenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let distance = levenshteinDistance(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - (Double(distance) / Double(maxLen))
    }

    private static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0 ... b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1, // deletion
                    current[j - 1] + 1, // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }
}
