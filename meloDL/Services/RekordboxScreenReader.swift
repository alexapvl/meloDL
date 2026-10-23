import AppKit
import Foundation
import Vision

/// Reads Rekordbox's window with text recognition, for the parts of its interface that scripts can't reach.
/// Needs Screen Recording access.
@MainActor
struct RekordboxScreenReader {
    struct Target {
        let point: CGPoint
    }

    private struct Window {
        let id: CGWindowID
        let bounds: CGRect
    }

    private struct RecognizedText {
        let text: String
        /// Normalized to the window, origin top-left.
        let rect: CGRect
    }

    /// Finds a playlist in the sidebar, scrolling down because new playlists are added at the bottom.
    /// Retries for a while, since a large import takes time before the playlist shows up.
    func findSidebarEntry(named name: String, timeout: TimeInterval = 30) async throws -> Target? {
        let wanted = Self.normalize(name)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let window = mainWindow() {
                let texts = try await recognizeText(in: window)
                if let entry = texts.first(where: { $0.rect.midX < 0.3 && Self.normalize($0.text).hasSuffix(wanted) }) {
                    return target(for: entry, in: window)
                }
                scroll(at: CGPoint(x: window.bounds.minX + window.bounds.width * 0.08, y: window.bounds.minY + window.bounds.height * 0.7))
            }
            try await Task.sleep(nanoseconds: 1_200_000_000)
        } while Date() < deadline
        return nil
    }

    /// The browser header reads "Name (N Tracks)" for the selected playlist.
    func headerShows(name: String, trackCount: Int) async throws -> Bool {
        guard let window = mainWindow() else { return false }
        let expected = Self.normalize(name) + "\(trackCount)track"
        return try await recognizeText(in: window).contains { Self.normalize($0.text).contains(expected) }
    }

    /// The OK button of Rekordbox's "Delete" dialog, only when the dialog names this playlist.
    func confirmationOKButton(naming name: String) async throws -> Target? {
        guard let dialog = window(named: "Delete") else { return nil }
        let texts = try await recognizeText(in: dialog)
        let wanted = Self.normalize(name)
        guard texts.contains(where: { Self.normalize($0.text) == wanted }),
              let ok = texts.first(where: { $0.text.trimmingCharacters(in: .whitespaces) == "OK" }) else { return nil }
        return target(for: ok, in: dialog)
    }

    func click(_ target: Target) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target.point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(type == .mouseMoved ? 120_000 : 60_000)
        }
    }

    // MARK: - Windows

    private func mainWindow() -> Window? {
        rekordboxWindows()
            .filter { $0.layer == 0 }
            .max { $0.window.bounds.width * $0.window.bounds.height < $1.window.bounds.width * $1.window.bounds.height }?
            .window
    }

    private func window(named name: String) -> Window? {
        rekordboxWindows().first { $0.name == name }?.window
    }

    private func rekordboxWindows() -> [(window: Window, name: String, layer: Int)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowOwnerName as String] as? String == "rekordbox",
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return (Window(id: id, bounds: bounds), info[kCGWindowName as String] as? String ?? "", info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    // MARK: - Reading

    private func recognizeText(in window: Window) async throws -> [RecognizedText] {
        let image = try await capture(window)
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return RecognizedText(
                    text: candidate.string,
                    rect: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                )
            }
        }.value
    }

    /// screencapture grabs one window even when it sits on another display.
    private func capture(_ window: Window) async throws -> CGImage {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("meloDL-rekordbox-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(window.id)", fileURL.path]
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        guard let image = NSImage(contentsOf: fileURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return cgImage
    }

    private func target(for text: RecognizedText, in window: Window) -> Target {
        Target(point: CGPoint(
            x: window.bounds.minX + text.rect.midX * window.bounds.width,
            y: window.bounds.minY + text.rect.midY * window.bounds.height
        ))
    }

    private func scroll(at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(100_000)
        for _ in 0 ..< 10 {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -300, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    /// Letters and digits only, lowercased, so icon glyphs and punctuation the recognizer adds don't matter.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
