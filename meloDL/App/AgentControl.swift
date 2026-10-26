#if DEBUG
import CoreGraphics
import Foundation

/// Debug-only control surface for driving meloDL from scripts and agents.
///
/// Commands arrive as `melodl://agent/<command>?id=<request id>&...` (open them with `open -g`),
/// and each writes its result as JSON to `~/Library/Application Support/meloDL/agent/<id>.json`.
///
/// - `status`: every session with its items, current review and Rekordbox state
/// - `download?url=&folder=&genre=`: start a session; `genre=` (empty) means no genre, leaving it out uses the default
/// - `review?session=&item=&action=skip|download`: resolve the session's current review, which must be `item`
/// - `genres?session=&file=`: set item genres from a JSON file `{ "<item id>": "Genre" | "" | null }`,
///   where "" means no genre and null falls back to the session or default genre
/// - `import?session=`: import the session's pending tracks into Rekordbox
/// - `refresh`: export the Rekordbox collection and reload it
/// - `cancel?session=`, `retry?session=`: cancel a session, or retry its failed and cancelled tracks
/// - `relocate?session=&folder=`: move a stopped session's finished files to `folder` and download the rest there
@MainActor
enum AgentControl {
    static let responseFolder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("meloDL/agent", isDirectory: true)

    static func handle(_ url: URL, coordinator: DownloadSessionCoordinator) {
        guard url.host == "agent",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let command = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var query: [String: String] = [:]
        // Form-style encoding sends spaces as "+", which URLComponents keeps literally.
        for item in components.percentEncodedQueryItems ?? [] {
            let value = (item.value ?? "").replacingOccurrences(of: "+", with: " ")
            query[item.name] = value.removingPercentEncoding ?? value
        }
        let requestID = query["id"] ?? UUID().uuidString

        Task {
            let result: [String: Any]
            do {
                result = try await run(command, query: query, coordinator: coordinator)
            } catch {
                result = ["ok": false, "error": error.localizedDescription]
            }
            write(result.merging(["command": command, "id": requestID]) { current, _ in current }, id: requestID)
        }
    }

    private struct AgentError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func run(_ command: String, query: [String: String], coordinator: DownloadSessionCoordinator) async throws -> [String: Any] {
        func session() throws -> DownloadSession {
            guard let id = query["session"].flatMap(UUID.init(uuidString:)),
                  let session = coordinator.sessions.first(where: { $0.id == id }) else {
                throw AgentError("Unknown session")
            }
            return session
        }

        switch command {
        case "status":
            return [
                "ok": true,
                "canDriveRekordbox": RekordboxImporter.shared.canDriveRekordbox,
                "screenRecording": CGPreflightScreenCaptureAccess(),
                "rekordboxTracks": RekordboxLibraryStore.shared.trackCount,
                "sessions": coordinator.sessions.map { describe($0, coordinator: coordinator) }
            ]

        case "download":
            guard let url = query["url"], !url.isEmpty else { throw AgentError("Missing url") }
            coordinator.draftURL = url
            // An empty genre means no genre, unlike a missing one, which falls back to the default genre.
            coordinator.draftGenre = query["genre"]
            coordinator.submitDraftURL(outputFolderPath: query["folder"].flatMap { $0.isEmpty ? nil : $0 })
            return ["ok": true, "session": coordinator.selectedSessionID?.uuidString ?? ""]

        case "review":
            let session = try session()
            guard let review = coordinator.currentReview(for: session.id) else { throw AgentError("No review pending") }
            guard review.id.uuidString == query["item"] else {
                throw AgentError("Current review is item \(review.id.uuidString), not \(query["item"] ?? "")")
            }
            let download = query["action"] == "download"
            switch review {
            case .duplicate:
                download ? coordinator.downloadCurrentDuplicateAnyway(for: session.id) : coordinator.skipCurrentDuplicate(for: session.id)
            case .match:
                download ? coordinator.acceptCurrentMatch(for: session.id) : coordinator.skipCurrentMatch(for: session.id)
            }
            return ["ok": true]

        case "genres":
            let session = try session()
            guard let path = query["file"],
                  let data = FileManager.default.contents(atPath: path),
                  let genres = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentError("Missing or unreadable genre file")
            }
            var updated = 0
            for (itemID, value) in genres {
                guard let id = UUID(uuidString: itemID), session.items.contains(where: { $0.id == id }) else { continue }
                coordinator.setGenre(value as? String, forItem: id, in: session.id)
                updated += 1
            }
            return ["ok": true, "updated": updated]

        case "import":
            let session = try session()
            coordinator.importToRekordbox(sessionID: session.id)
            return ["ok": true]

        case "refresh":
            try await RekordboxLibraryStore.shared.refreshFromRekordbox()
            return ["ok": true, "tracks": RekordboxLibraryStore.shared.trackCount]

        case "cancel":
            coordinator.cancelSession(try session().id)
            return ["ok": true]

        case "retry":
            coordinator.retrySession(try session().id)
            return ["ok": true]

        case "relocate":
            guard let folder = query["folder"], !folder.isEmpty else { throw AgentError("Missing folder") }
            try coordinator.relocateSession(try session().id, to: folder)
            return ["ok": true]

        default:
            throw AgentError("Unknown command \(command)")
        }
    }

    // MARK: - Status

    private static func describe(_ session: DownloadSession, coordinator: DownloadSessionCoordinator) -> [String: Any] {
        var result: [String: Any] = [
            "id": session.id.uuidString,
            "title": session.displayTitle,
            "sourceURL": session.sourceURL,
            "status": session.status.rawValue,
            "outputFolder": session.outputFolderPath,
            "format": session.format.rawValue,
            "itemCount": session.items.count,
            "pendingImportCount": coordinator.rekordboxPendingItems(in: session).count
        ]
        result["attention"] = session.attentionReason?.rawValue
        result["error"] = session.errorMessage
        result["notice"] = session.notice
        result["genre"] = session.genre
        if let activity = coordinator.rekordboxImportActivity[session.id] {
            result["importActivity"] = String(describing: activity)
        }
        if let review = coordinator.currentReview(for: session.id) {
            result["currentReview"] = describe(review)
        }
        result["items"] = session.items.sorted { $0.itemIndex < $1.itemIndex }.map { item -> [String: Any] in
            var entry: [String: Any] = [
                "id": item.id.uuidString,
                "index": item.itemIndex,
                "title": item.title,
                "status": item.status.rawValue,
                "sourceURL": item.sourceURL,
                "inRekordbox": coordinator.isInRekordbox(item),
                "waitingInXML": coordinator.isWaitingInRekordboxXML(item)
            ]
            entry["path"] = item.outputFilePath
            entry["error"] = item.errorMessage
            entry["genre"] = item.genre
            entry["duplicateReason"] = item.duplicateMatch?.reason
            if let track = item.spotify?.track {
                entry["spotifyTitle"] = track.title
                entry["spotifyArtists"] = track.artistLine
            }
            return entry
        }
        return result
    }

    private static func describe(_ review: SessionReview) -> [String: Any] {
        switch review {
        case .duplicate(let item):
            return [
                "kind": "duplicate",
                "item": item.id.uuidString,
                "incomingTitle": item.incomingTitle,
                "incomingURL": item.incomingURL,
                "candidatePath": item.match.candidatePath,
                "candidateTitle": item.match.candidateTitle,
                "confidence": item.match.confidence.rawValue,
                "score": item.match.score,
                "reason": item.match.reason,
                "candidateInRekordbox": item.isMatchInRekordbox
            ]
        case .match(let item, let info):
            var result: [String: Any] = [
                "kind": "match",
                "item": item.id.uuidString,
                "spotifyTitle": info.track.title,
                "spotifyArtists": info.track.artistLine,
                "spotifyDurationSec": info.track.durationSec,
                "matchURL": item.sourceURL
            ]
            result["matchTitle"] = info.matchTitle
            result["matchArtists"] = info.matchArtists
            result["matchDurationSec"] = info.matchDurationSec
            result["matchScore"] = info.matchScore
            return result
        }
    }

    private static func write(_ result: [String: Any], id: String) {
        do {
            try FileManager.default.createDirectory(at: responseFolder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: responseFolder.appendingPathComponent("\(id).json"), options: .atomic)
        } catch {
            NSLog("AgentControl failed to write response: \(error.localizedDescription)")
        }
    }
}
#endif
