import Foundation
import os

actor BinaryManager {
    static let shared = BinaryManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "BinaryManager")

    private let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("meloDL/bin", isDirectory: true)
    }()

    private let versionsFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("meloDL/versions.json")
    }()

    var ytdlpPath: URL { appSupportDir.appendingPathComponent("yt-dlp") }
    var ffmpegPath: URL { appSupportDir.appendingPathComponent("ffmpeg") }
    var ffprobePath: URL { appSupportDir.appendingPathComponent("ffprobe") }

    struct BinaryVersions: Codable {
        var ytdlp: VersionEntry?
        var ffmpeg: VersionEntry?

        enum CodingKeys: String, CodingKey {
            case ytdlp = "yt-dlp"
            case ffmpeg
        }
    }

    struct VersionEntry: Codable {
        var version: String
        var updatedAt: Date
    }

    private(set) var versions: BinaryVersions = BinaryVersions()

    // MARK: - Bootstrap

    func ensureBinaries() async throws {
        try createDirectoryIfNeeded()
        try seedFromBundleIfMissing("yt-dlp")
        try seedFromBundleIfMissing("ffmpeg")
        try seedFromBundleIfMissing("ffprobe")
        loadVersions()
        logger.info("Binaries ready at \(self.appSupportDir.path)")
    }

    private func createDirectoryIfNeeded() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupportDir.path) {
            try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        }
    }

    private func seedFromBundleIfMissing(_ name: String) throws {
        let dest = appSupportDir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }

        guard let bundled = Bundle.main.url(forResource: name, withExtension: nil) else {
            logger.warning("Bundled binary \(name) not found in app bundle")
            return
        }

        try FileManager.default.copyItem(at: bundled, to: dest)
        try makeExecutable(dest)
        logger.info("Seeded \(name) from app bundle")
    }

    private func makeExecutable(_ url: URL) throws {
        let fm = FileManager.default
        var attrs = try fm.attributesOfItem(atPath: url.path)
        let currentPerms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        attrs[.posixPermissions] = NSNumber(value: currentPerms | 0o111)
        try fm.setAttributes(attrs, ofItemAtPath: url.path)
    }

    // MARK: - Version Tracking

    private func loadVersions() {
        guard FileManager.default.fileExists(atPath: versionsFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: versionsFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            versions = try decoder.decode(BinaryVersions.self, from: data)
        } catch {
            logger.error("Failed to load versions.json: \(error.localizedDescription)")
        }
    }

    func saveVersions() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(versions)
        try data.write(to: versionsFileURL, options: .atomic)
    }

    func updateVersion(for binary: String, version: String) throws {
        let entry = VersionEntry(version: version, updatedAt: Date())
        switch binary {
        case "yt-dlp":
            versions.ytdlp = entry
        case "ffmpeg":
            versions.ffmpeg = entry
        default:
            break
        }
        try saveVersions()
    }

    // MARK: - Binary Replacement

    func replaceBinary(name: String, with tempFileURL: URL) throws {
        let dest = appSupportDir.appendingPathComponent(name)
        let fm = FileManager.default

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempFileURL, to: dest)
        try makeExecutable(dest)
        logger.info("Replaced \(name) binary")
    }

    func currentVersion(for binary: String) -> String? {
        switch binary {
        case "yt-dlp": return versions.ytdlp?.version
        case "ffmpeg": return versions.ffmpeg?.version
        default: return nil
        }
    }
}
