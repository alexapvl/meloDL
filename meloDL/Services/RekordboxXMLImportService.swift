import Foundation

struct RekordboxLibrarySnapshot: Sendable {
    let canonicalPaths: Set<String>
    let trackCount: Int
    let sourceURL: URL
    let genreCounts: [String: Int]
    /// Source links found in track comments, keyed by `SourceLinkKey`, mapped to the track's canonical path.
    let sourceLinkPaths: [String: String]
}

enum RekordboxXMLImportError: LocalizedError {
    case invalidXML
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidXML:
            return "The selected file is not a valid Rekordbox XML export."
        case .unreadableFile(let message):
            return "Could not read Rekordbox XML file: \(message)"
        }
    }
}

actor RekordboxXMLImportService {
    static let shared = RekordboxXMLImportService()

    func importSnapshot(from fileURL: URL) throws -> RekordboxLibrarySnapshot {
        do {
            let parser = XMLParser(contentsOf: fileURL)
            let delegate = RekordboxTrackPathParserDelegate()
            parser?.delegate = delegate

            guard let parser, parser.parse() else {
                throw RekordboxXMLImportError.invalidXML
            }

            return RekordboxLibrarySnapshot(
                canonicalPaths: delegate.collectedPaths,
                trackCount: delegate.trackCount,
                sourceURL: fileURL,
                genreCounts: delegate.genreCounts,
                sourceLinkPaths: delegate.sourceLinkPaths
            )
        } catch let error as RekordboxXMLImportError {
            throw error
        } catch {
            throw RekordboxXMLImportError.unreadableFile(error.localizedDescription)
        }
    }
}

private final class RekordboxTrackPathParserDelegate: NSObject, XMLParserDelegate {
    private(set) var collectedPaths: Set<String> = []
    private(set) var trackCount = 0
    private(set) var genreCounts: [String: Int] = [:]
    private(set) var sourceLinkPaths: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "TRACK" else { return }

        guard let location = attributeDict["Location"],
              let decodedPath = Self.decodeFilePath(fromLocation: location),
              !decodedPath.isEmpty else {
            return
        }

        trackCount += 1
        let canonicalPath = TrackIndexStore.canonicalize(path: decodedPath)
        collectedPaths.insert(canonicalPath)

        if let genre = attributeDict["Genre"]?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            genreCounts[genre, default: 0] += 1
        }
        if let comments = attributeDict["Comments"], let key = SourceLinkKey.key(for: comments) {
            sourceLinkPaths[key] = canonicalPath
        }
    }

    private static func decodeFilePath(fromLocation location: String) -> String? {
        guard let url = URL(string: location), url.isFileURL else {
            return nil
        }
        var path = url.path
        if path.isEmpty {
            path = (location as NSString).removingPercentEncoding ?? location
        }
        return path
    }
}
