import ApplicationServices
import Foundation
import os

/// Adds files to the Rekordbox collection: one track through Import Track, more through Import Playlist
/// with the leftover playlist removed again. Falls back to meloDL's XML inbox when Rekordbox can't be driven.
@MainActor
final class RekordboxImporter {
    static let shared = RekordboxImporter()

    enum Outcome {
        /// `leftoverPlaylist` names an import playlist that stayed in Rekordbox.
        case imported(count: Int, leftoverPlaylist: String?)
        case addedToXML(count: Int, note: String?)
    }

    enum Step {
        case importing(count: Int)
        case removingPlaylist
        case refreshing
    }

    private let automation = RekordboxAutomationService.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "RekordboxImporter")

    var canDriveRekordbox: Bool {
        AXIsProcessTrusted()
    }

    /// Writes chosen genres into the files, imports them, then refreshes the collection so meloDL sees what landed.
    /// `playlistName` names the playlist when `keepsPlaylist` is on.
    func importTracks(
        _ tracks: [RekordboxXMLTrack],
        playlistName: String,
        keepsPlaylist: Bool,
        onStep: (Step) -> Void
    ) async throws -> Outcome {
        guard !tracks.isEmpty else { return .imported(count: 0, leftoverPlaylist: nil) }
        await writeGenres(of: tracks)

        guard canDriveRekordbox else {
            RekordboxXMLQueue.shared.add(tracks)
            return .addedToXML(count: tracks.count, note: nil)
        }

        onStep(.importing(count: tracks.count))
        var leftoverPlaylist: String?
        do {
            if tracks.count == 1, let track = tracks.first {
                try await automation.importTrack(at: URL(fileURLWithPath: track.path))
            } else {
                // The name has to be unique and easy to read back from the screen.
                let name = keepsPlaylist ? playlistName : "meloDL \(Self.timestamp())"
                let playlistURL = try writePlaylistFile(named: name, tracks: tracks)
                defer { try? FileManager.default.removeItem(at: playlistURL) }
                try await automation.importPlaylist(at: playlistURL)

                if !keepsPlaylist {
                    onStep(.removingPlaylist)
                    if !(await automation.deleteImportedPlaylist(named: name, trackCount: tracks.count)) {
                        leftoverPlaylist = name
                    }
                }
            }
        } catch let error as RekordboxAutomationError where error.cannotControlRekordbox {
            // Tracks that did make it in drop out of the XML at the next refresh.
            RekordboxXMLQueue.shared.add(tracks)
            return .addedToXML(count: tracks.count, note: error.localizedDescription)
        }

        onStep(.refreshing)
        try await RekordboxLibraryStore.shared.refreshFromRekordbox()
        return .imported(count: tracks.count, leftoverPlaylist: leftoverPlaylist)
    }

    private func writeGenres(of tracks: [RekordboxXMLTrack]) async {
        let engine = DownloadEngine()
        for track in tracks {
            guard let genre = track.genre else { continue }
            do {
                try await engine.writeGenre(genre, to: URL(fileURLWithPath: track.path))
            } catch {
                logger.failure("Writing genre failed for \(track.path): \(error.localizedDescription)")
            }
        }
    }

    /// Rekordbox names the playlist after this file.
    private func writePlaylistFile(named name: String, tracks: [RekordboxXMLTrack]) throws -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("meloDL/imports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = folder.appendingPathComponent("\(safeName).m3u8")
        let lines = ["#EXTM3U"] + tracks.map(\.path)
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
