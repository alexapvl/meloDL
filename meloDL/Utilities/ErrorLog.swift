import Foundation
import os

/// Shareable error log at ~/Library/Logs/meloDL/errors.log, revealed from Settings > Support.
enum ErrorLog {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/meloDL/errors.log")

    private static let queue = DispatchQueue(label: "com.alexapvl.meloDL.error-log")
    private static let maxBytes = 1_000_000
    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }()

    static func append(_ message: String, source: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(appVersion) [\(source)] \(message)\n"
        queue.async {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // ponytail: keeps the newest half once the file passes 1 MB; rotate files if older history matters.
            if let size = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
               size > maxBytes,
               let data = try? Data(contentsOf: fileURL) {
                try? data.suffix(maxBytes / 2).write(to: fileURL, options: .atomic)
            }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    /// Creates the file if needed so Finder has something to select.
    static func ensureFileExists() {
        queue.sync {
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: fileURL)
        }
    }
}

extension Logger {
    /// Logs an error and appends it to the shareable error log.
    func failure(_ message: String, fileID: String = #fileID) {
        error("\(message, privacy: .public)")
        let source = ((fileID as NSString).lastPathComponent as NSString).deletingPathExtension
        ErrorLog.append(message, source: source)
    }
}
