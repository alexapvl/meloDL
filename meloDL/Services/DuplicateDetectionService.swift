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
        let incoming = TrackTitleFingerprint(title)
        guard !incoming.isEmpty else { return [] }

        let corpus = try await currentCorpus()
        var candidateIndices = Set<Int>()
        for token in incoming.searchTokens {
            candidateIndices.formUnion(corpus.indicesByToken[token] ?? [])
        }

        var matches: [DuplicateMatch] = []
        for index in candidateIndices {
            let entry = corpus.entries[index]
            // The file's own tags can name the track better than its file name.
            let byName = incoming.match(entry.fingerprint)
            let byTags = entry.tagFingerprint.flatMap(incoming.match)
            guard let match = [byName, byTags].compactMap({ $0 }).max(by: { $0.score < $1.score }) else { continue }

            var score = match.score
            var strength = match.strength
            if let expectedDurationSec, let candidateDuration = entry.title.durationSec {
                let delta = abs(expectedDurationSec - candidateDuration)
                if delta <= 2 {
                    // Same length backs up a title match, e.g. a one-word title like "Echo".
                    strength = strength == .low ? .medium : .high
                } else if delta > 3 {
                    score -= 0.25
                    strength = .low
                }
            }
            guard score >= 0.72 else { continue }

            matches.append(DuplicateMatch(
                candidatePath: entry.title.path,
                candidateTitle: entry.title.filename,
                confidence: Self.confidence(for: strength),
                score: max(0, min(1, score)),
                reason: match.reason
            ))
        }

        matches.sort { $0.score > $1.score }
        let topMatches = Array(matches.prefix(10))
        logger.info("Duplicate check for '\(title, privacy: .public)' produced \(topMatches.count) match(es)")
        return topMatches
    }

    private struct CorpusEntry {
        let title: IndexedTitle
        let fingerprint: TrackTitleFingerprint
        let tagFingerprint: TrackTitleFingerprint?
    }

    private struct Corpus {
        let marker: String
        let entries: [CorpusEntry]
        let indicesByToken: [String: Set<Int>]
    }

    private var corpus: Corpus?

    /// Fingerprints of every indexed file, rebuilt only when the index changes.
    private func currentCorpus() async throws -> Corpus {
        let marker = try await indexStore.titleCorpusMarker()
        if let corpus, corpus.marker == marker {
            return corpus
        }

        let entries = try await indexStore.fetchTitleCorpus().map { title in
            let tagFingerprint = title.titleTag.map { tagTitle in
                TrackTitleFingerprint(title.artistTag.map { "\($0) - \(tagTitle)" } ?? tagTitle)
            }
            return CorpusEntry(
                title: title,
                fingerprint: TrackTitleFingerprint((title.filename as NSString).deletingPathExtension),
                tagFingerprint: tagFingerprint
            )
        }
        var indicesByToken: [String: Set<Int>] = [:]
        for (index, entry) in entries.enumerated() {
            let tokens = entry.fingerprint.searchTokens.union(entry.tagFingerprint?.searchTokens ?? [])
            for token in tokens {
                indicesByToken[token, default: []].insert(index)
            }
        }
        let rebuilt = Corpus(marker: marker, entries: entries, indicesByToken: indicesByToken)
        corpus = rebuilt
        return rebuilt
    }

    private static func confidence(for strength: TrackTitleFingerprint.Strength) -> DuplicateMatch.Confidence {
        switch strength {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }

    func findExactDuplicateFileGroups(limit: Int = 300) async throws -> [ExactDuplicateGroup] {
        let groups = try await indexStore.fetchExactDuplicateGroups(limit: limit)
        logger.info("Exact duplicate scan produced \(groups.count) grouped duplicate hash(es)")
        return groups
    }

    /// Lowercased letters and digits of any script, accents removed.
    static func normalize(_ input: String) -> String {
        TrackTitleFingerprint.tokens(TrackTitleFingerprint.fold(input)).joined(separator: " ")
    }

    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        TrackTitleFingerprint.stringSimilarity(normalize(a), normalize(b))
    }
}
