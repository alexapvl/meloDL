import Foundation
import SwiftUI
import UniformTypeIdentifiers

class FileService: ObservableObject {
    @Published var selectedFolder: URL?
    @Published var showingFolderPicker: Bool = false
    
    init() {
        // Set default download folder to ~/Downloads
        selectedFolder = DownloadConfiguration.defaultDownloadFolder
    }
    
    func selectFolder() {
        showingFolderPicker = true
    }
    
    func handleFolderSelection(result: Result<[URL], Error>) -> String {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                selectedFolder = url
                return "Folder selected: \(url.lastPathComponent)"
            } else {
                return "No folder selected"
            }
        case .failure(let error):
            return "Error selecting folder: \(error.localizedDescription)"
        }
    }
    
    func validateSelectedFolder() -> Bool {
        guard let folder = selectedFolder else { return false }
        return FileManager.default.fileExists(atPath: folder.path)
    }
    
    func createDirectoryIfNeeded() throws {
        guard let folder = selectedFolder else {
            throw FileError.noFolderSelected
        }
        
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }
}

enum FileError: LocalizedError {
    case noFolderSelected
    case directoryCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .noFolderSelected:
            return "No download folder selected"
        case .directoryCreationFailed:
            return "Failed to create download directory"
        }
    }
}


