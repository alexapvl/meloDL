import Foundation

struct DownloadItem: Identifiable {
    let id: UUID
    let url: String
    var title: String
    var status: Status

    init(url: String) {
        self.id = UUID()
        self.url = url
        self.title = url
        self.status = .queued
    }

    enum Status {
        case queued
        case downloading
        case completed(filepath: String)
        case failed(message: String)

        var isActive: Bool {
            switch self {
            case .queued, .downloading: return true
            case .completed, .failed: return false
            }
        }

        var displayText: String? {
            switch self {
            case .queued: return "Queued"
            case .downloading: return "Downloading"
            case .completed: return "Completed"
            case .failed(let msg): return "Error: \(msg)"
            }
        }
    }
}
