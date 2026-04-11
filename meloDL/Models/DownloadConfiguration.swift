import Foundation

struct DownloadConfiguration {
    var fastDownloads: Bool
    var outputFolder: URL?
    
    init(
        fastDownloads: Bool = true,
        outputFolder: URL? = nil
    ) {
        self.fastDownloads = fastDownloads
        self.outputFolder = outputFolder ?? Self.defaultDownloadFolder
    }
    
    static var defaultDownloadFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
    }
    
}


