import Foundation
import os

actor GitHubUpdateService {
    static let shared = GitHubUpdateService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "GitHubUpdateService")
    private let binaryManager = BinaryManager.shared

    private let lastCheckKey = "lastBinaryUpdateCheck"
    private let checkInterval: TimeInterval = 24 * 60 * 60

    // MARK: - Public

    func checkForUpdatesIfNeeded() async {
        guard shouldCheck() else {
            logger.info("Skipping binary update check (checked recently)")
            return
        }
        await checkForUpdates()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
    }

    func checkForUpdates() async {
        async let ytdlpUpdate: Void = checkYtdlp()
        async let ffmpegUpdate: Void = checkFfmpeg()
        _ = await (ytdlpUpdate, ffmpegUpdate)
    }

    // MARK: - Throttle

    private nonisolated func shouldCheck() -> Bool {
        let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
        guard lastCheck > 0 else { return true }
        return Date().timeIntervalSince1970 - lastCheck >= checkInterval
    }

    // MARK: - yt-dlp

    private func checkYtdlp() async {
        do {
            let release = try await fetchLatestRelease(owner: "yt-dlp", repo: "yt-dlp")
            let remoteVersion = release.tagName
            let localVersion = await binaryManager.currentVersion(for: "yt-dlp")

            if localVersion == nil || remoteVersion != localVersion {
                logger.info("yt-dlp update available: \(localVersion ?? "none") → \(remoteVersion)")
                try await downloadAndInstallYtdlp(release: release)
            } else {
                logger.info("yt-dlp is up to date (\(remoteVersion))")
            }
        } catch {
            logger.error("Failed to check yt-dlp updates: \(error.localizedDescription)")
        }
    }

    private func downloadAndInstallYtdlp(release: GitHubRelease) async throws {
        let assetName = "yt-dlp_macos"
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            logger.warning("No macOS asset found in yt-dlp release")
            return
        }

        let tempURL = try await downloadAsset(asset)
        try await binaryManager.replaceBinary(name: "yt-dlp", with: tempURL)
        try await binaryManager.updateVersion(for: "yt-dlp", version: release.tagName)
        logger.info("yt-dlp updated to \(release.tagName)")
    }

    // MARK: - ffmpeg

    private func checkFfmpeg() async {
        do {
            let release = try await fetchLatestRelease(owner: "eugeneware", repo: "ffmpeg-static")
            let remoteVersion = release.tagName
            let localVersion = await binaryManager.currentVersion(for: "ffmpeg")

            if localVersion == nil || remoteVersion != localVersion {
                logger.info("ffmpeg update available: \(localVersion ?? "none") → \(remoteVersion)")
                try await downloadAndInstallFfmpeg(release: release)
            } else {
                logger.info("ffmpeg is up to date (\(remoteVersion))")
            }
        } catch {
            logger.error("Failed to check ffmpeg updates: \(error.localizedDescription)")
        }
    }

    private func downloadAndInstallFfmpeg(release: GitHubRelease) async throws {
        #if arch(arm64)
        let ffmpegAsset = "ffmpeg-darwin-arm64"
        let ffprobeAsset = "ffprobe-darwin-arm64"
        #else
        let ffmpegAsset = "ffmpeg-darwin-x64"
        let ffprobeAsset = "ffprobe-darwin-x64"
        #endif

        if let asset = release.assets.first(where: { $0.name == ffmpegAsset }) {
            let tempURL = try await downloadAsset(asset)
            try await binaryManager.replaceBinary(name: "ffmpeg", with: tempURL)
            logger.info("ffmpeg updated to \(release.tagName)")
        }

        if let asset = release.assets.first(where: { $0.name == ffprobeAsset }) {
            let tempURL = try await downloadAsset(asset)
            try await binaryManager.replaceBinary(name: "ffprobe", with: tempURL)
            logger.info("ffprobe updated to \(release.tagName)")
        }

        try await binaryManager.updateVersion(for: "ffmpeg", version: release.tagName)
    }

    // MARK: - GitHub API

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("meloDL/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadAsset(_ asset: GitHubAsset) async throws -> URL {
        guard let url = URL(string: asset.browserDownloadURL) else {
            throw URLError(.badURL)
        }

        logger.info("Downloading \(asset.name)...")
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}
