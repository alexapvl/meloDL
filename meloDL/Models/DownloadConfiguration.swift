import Foundation

struct DownloadConfiguration {
    var fastDownloads: Bool
    var outputFolder: URL?
    /// Genre written to downloaded files. nil keeps yt-dlp's genre; empty removes it.
    var genre: String?
    
    init(
        fastDownloads: Bool = true,
        outputFolder: URL? = nil,
        genre: String? = nil
    ) {
        self.fastDownloads = fastDownloads
        self.outputFolder = outputFolder ?? Self.defaultDownloadFolder
        self.genre = genre
    }
    
    static var defaultDownloadFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
    }
    
}


