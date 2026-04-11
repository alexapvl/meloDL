import SwiftUI
import UniformTypeIdentifiers

struct FolderSelectionView: View {
    @ObservedObject var fileService: FileService
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Download folder:")
                .font(.headline)

            HStack {
                Text(fileService.selectedFolder?.path ?? "No folder selected")
                    .foregroundStyle(fileService.selectedFolder == nil ? .secondary : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose Folder") {
                    fileService.selectFolder()
                }
                .disabled(isDisabled)
                .buttonStyle(.bordered)
            }
        }
        .fileImporter(
            isPresented: $fileService.showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            _ = fileService.handleFolderSelection(result: result)
        }
    }
}

#Preview {
    FolderSelectionView(fileService: FileService(), isDisabled: false)
        .padding()
}
