import Foundation

struct DownloadSession: Identifiable, Sendable {
    let id: UUID
    var sourceURL: String
    var kind: DownloadSessionKind
    var displayTitle: String
    var resolvedTitle: String?
    var status: DownloadSessionStatus
    var attentionReason: SessionAttentionReason?
    var createdAt: Date
    var completedAt: Date?
    var outputFolderPath: String
    var format: AudioFormat
    var items: [DownloadSessionItem]
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        sourceURL: String,
        kind: DownloadSessionKind = .unknown,
        displayTitle: String,
        resolvedTitle: String? = nil,
        status: DownloadSessionStatus = .waitingForSlot,
        attentionReason: SessionAttentionReason? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        outputFolderPath: String,
        format: AudioFormat,
        items: [DownloadSessionItem] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
        self.displayTitle = displayTitle
        self.resolvedTitle = resolvedTitle
        self.status = status
        self.attentionReason = attentionReason
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.outputFolderPath = outputFolderPath
        self.format = format
        self.items = items
        self.errorMessage = errorMessage
    }

    var needsAttention: Bool {
        attentionReason != nil || status == .waitingForUser || status == .failed
    }

    var completedFilePaths: [String] {
        items.compactMap(\.outputFilePath)
    }

    var firstExistingCompletedFilePath: String? {
        completedFilePaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    var downloadableItems: [DownloadSessionItem] {
        items.filter { !$0.isSkippedDuplicate }
    }

    var downloadableProgress: (current: Int, total: Int)? {
        let downloadableItems = downloadableItems.sorted { $0.itemIndex < $1.itemIndex }
        guard !downloadableItems.isEmpty else { return nil }

        let currentIndex = downloadableItems.firstIndex {
            $0.status == .queued ||
            $0.status == .checkingDuplicates ||
            $0.status == .waitingForUser ||
            $0.status == .downloading
        }
        let completedCount = downloadableItems.filter { $0.status == .completed }.count
        let current = currentIndex.map { $0 + 1 } ?? completedCount

        return (min(max(current, 0), downloadableItems.count), downloadableItems.count)
    }

    var duplicateReviewTotal: Int {
        items.filter(\.hadDuplicateMatch).count
    }

    var duplicateReviewRemaining: Int {
        items.filter { $0.status == .waitingForUser && $0.duplicateMatch != nil }.count
    }

    var duplicateReviewPosition: Int {
        let total = duplicateReviewTotal
        guard total > 0 else { return 1 }
        let remaining = duplicateReviewRemaining
        return min(max(total - remaining + 1, 1), total)
    }

    static func fallbackTitle(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              let host = components.host,
              !host.isEmpty else {
            return "Preparing download"
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

enum DownloadSessionKind: String, Sendable {
    case unknown
    case single
    case playlist
}

enum DownloadSessionStatus: String, Sendable {
    case waitingForSlot
    case preparing
    case checkingDuplicates
    case waitingForUser
    case downloading
    case completed
    case failed
    case cancelled
    case skipped

    var isActive: Bool {
        switch self {
        case .preparing, .checkingDuplicates, .downloading:
            return true
        case .waitingForSlot, .waitingForUser, .completed, .failed, .cancelled, .skipped:
            return false
        }
    }

    var displayText: String {
        switch self {
        case .waitingForSlot: return "Waiting"
        case .preparing: return "Preparing"
        case .checkingDuplicates: return "Checking duplicates"
        case .waitingForUser: return "Needs review"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        }
    }
}

enum SessionAttentionReason: String, Sendable {
    case duplicateReview
    case failed
}

struct DownloadSessionItem: Identifiable, Sendable {
    let id: UUID
    var sourceURL: String
    var title: String
    var status: DownloadSessionItemStatus
    var outputFilePath: String?
    var duplicateMatch: DuplicateMatchSnapshot?
    var errorMessage: String?
    var itemIndex: Int
    var hadDuplicateMatch: Bool

    init(
        id: UUID = UUID(),
        sourceURL: String,
        title: String,
        status: DownloadSessionItemStatus = .queued,
        outputFilePath: String? = nil,
        duplicateMatch: DuplicateMatchSnapshot? = nil,
        errorMessage: String? = nil,
        itemIndex: Int,
        hadDuplicateMatch: Bool = false
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.status = status
        self.outputFilePath = outputFilePath
        self.duplicateMatch = duplicateMatch
        self.errorMessage = errorMessage
        self.itemIndex = itemIndex
        self.hadDuplicateMatch = hadDuplicateMatch
    }

    var isSkippedDuplicate: Bool {
        status == .skipped && duplicateMatch != nil
    }
}

enum DownloadSessionItemStatus: String, Sendable {
    case queued
    case checkingDuplicates
    case waitingForUser
    case downloading
    case completed
    case failed
    case cancelled
    case skipped

    var displayText: String {
        switch self {
        case .queued: return "Queued"
        case .checkingDuplicates: return "Checking duplicates"
        case .waitingForUser: return "Needs review"
        case .downloading: return "Downloading"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        }
    }
}

struct DuplicateMatchSnapshot: Sendable {
    var candidatePath: String
    var candidateTitle: String
    var confidence: DuplicateMatch.Confidence
    var score: Double
    var reason: String

    init(match: DuplicateMatch) {
        self.candidatePath = match.candidatePath
        self.candidateTitle = match.candidateTitle
        self.confidence = match.confidence
        self.score = match.score
        self.reason = match.reason
    }

    init(
        candidatePath: String,
        candidateTitle: String,
        confidence: DuplicateMatch.Confidence,
        score: Double,
        reason: String
    ) {
        self.candidatePath = candidatePath
        self.candidateTitle = candidateTitle
        self.confidence = confidence
        self.score = score
        self.reason = reason
    }

    var duplicateMatch: DuplicateMatch {
        DuplicateMatch(
            candidatePath: candidatePath,
            candidateTitle: candidateTitle,
            confidence: confidence,
            score: score,
            reason: reason
        )
    }
}
