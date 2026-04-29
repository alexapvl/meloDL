import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var format: AudioFormat {
        didSet { defaults.set(format.rawValue, forKey: Keys.audioFormat) }
    }
    @Published var quality: AudioQuality {
        didSet { defaults.set(quality.rawValue, forKey: Keys.audioQuality) }
    }
    @Published var embedMetadata: Bool {
        didSet { defaults.set(embedMetadata, forKey: Keys.embedMetadata) }
    }
    @Published var embedThumbnail: Bool {
        didSet { defaults.set(embedThumbnail, forKey: Keys.embedThumbnail) }
    }
    @Published var fastDownloads: Bool {
        didSet { defaults.set(fastDownloads, forKey: Keys.fastDownloads) }
    }
    @Published var openFolderOnSuccess: Bool {
        didSet { defaults.set(openFolderOnSuccess, forKey: Keys.openFolderOnSuccess) }
    }
    @Published var notifyOnDownloadCompletion: Bool {
        didSet { defaults.set(notifyOnDownloadCompletion, forKey: Keys.notifyOnDownloadCompletion) }
    }
    @Published var downloadFolderPath: String {
        didSet { defaults.set(downloadFolderPath, forKey: Keys.downloadFolderPath) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.audioFormat), let saved = AudioFormat(rawValue: raw) {
            format = saved
        } else {
            format = .mp3
        }

        if let raw = defaults.string(forKey: Keys.audioQuality), let saved = AudioQuality(rawValue: raw) {
            quality = saved
        } else {
            quality = .high
        }

        if defaults.object(forKey: Keys.embedMetadata) != nil {
            embedMetadata = defaults.bool(forKey: Keys.embedMetadata)
        } else {
            embedMetadata = true
        }

        if defaults.object(forKey: Keys.embedThumbnail) != nil {
            embedThumbnail = defaults.bool(forKey: Keys.embedThumbnail)
        } else {
            embedThumbnail = false
        }

        if defaults.object(forKey: Keys.fastDownloads) != nil {
            fastDownloads = defaults.bool(forKey: Keys.fastDownloads)
        } else {
            fastDownloads = true
        }

        if defaults.object(forKey: Keys.openFolderOnSuccess) != nil {
            openFolderOnSuccess = defaults.bool(forKey: Keys.openFolderOnSuccess)
        } else {
            openFolderOnSuccess = false
        }

        if defaults.object(forKey: Keys.notifyOnDownloadCompletion) != nil {
            notifyOnDownloadCompletion = defaults.bool(forKey: Keys.notifyOnDownloadCompletion)
        } else {
            notifyOnDownloadCompletion = true
        }

        let persistedPath = defaults.string(forKey: Keys.downloadFolderPath) ?? ""
        if persistedPath.isEmpty {
            downloadFolderPath = DownloadConfiguration.defaultDownloadFolder.path
        } else {
            downloadFolderPath = persistedPath
        }
    }

    var audioSettings: AudioSettings {
        AudioSettings(
            format: format,
            quality: quality,
            embedMetadata: embedMetadata,
            embedThumbnail: format.supportsThumbnailEmbed ? embedThumbnail : false
        )
    }

    var downloadFolderURL: URL {
        URL(fileURLWithPath: downloadFolderPath, isDirectory: true)
    }

    var downloadConfiguration: DownloadConfiguration {
        DownloadConfiguration(
            fastDownloads: fastDownloads,
            outputFolder: downloadFolderURL
        )
    }

    private enum Keys {
        static let audioFormat = "settings.audioFormat"
        static let audioQuality = "settings.audioQuality"
        static let embedMetadata = "settings.embedMetadata"
        static let embedThumbnail = "settings.embedThumbnail"
        static let fastDownloads = "settings.fastDownloads"
        static let downloadFolderPath = "settings.downloadFolderPath"
        static let openFolderOnSuccess = "settings.openFolderOnSuccess"
        static let notifyOnDownloadCompletion = "settings.notifyOnDownloadCompletion"
    }
}
