import Foundation

struct DuplicateMatch: Identifiable, Sendable {
    enum Confidence: String, Sendable {
        case high
        case medium
        case low
    }

    let id: UUID
    let candidatePath: String
    let candidateTitle: String
    let confidence: Confidence
    let score: Double
    let reason: String

    init(
        id: UUID = UUID(),
        candidatePath: String,
        candidateTitle: String,
        confidence: Confidence,
        score: Double,
        reason: String
    ) {
        self.id = id
        self.candidatePath = candidatePath
        self.candidateTitle = candidateTitle
        self.confidence = confidence
        self.score = score
        self.reason = reason
    }
}

struct DuplicateReviewItem: Identifiable, Sendable {
    enum Source: Sendable {
        case single(url: String)
        case playlist(url: String)
    }

    let id: UUID
    let source: Source
    let incomingTitle: String
    let incomingURL: String
    let match: DuplicateMatch

    init(
        id: UUID = UUID(),
        source: Source,
        incomingTitle: String,
        incomingURL: String,
        match: DuplicateMatch
    ) {
        self.id = id
        self.source = source
        self.incomingTitle = incomingTitle
        self.incomingURL = incomingURL
        self.match = match
    }
}

enum DuplicateReviewDecision: Sendable {
    case downloadAnyway
    case skip
}
