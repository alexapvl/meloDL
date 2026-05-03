import SwiftUI
import UniformTypeIdentifiers

struct FolderSelectionView: View {
    @ObservedObject var fileService: FileService
    let isDisabled: Bool
    let onFolderSelected: (URL?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(fileService.selectedFolder?.path ?? "No folder selected")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(fileService.selectedFolder == nil ? .secondary : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.controlBackgroundColor))
                .clipShape(.rect(cornerRadius: 6))
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button("Choose Folder") {
                fileService.selectFolder()
            }
            .disabled(isDisabled)
            .buttonStyle(.bordered)
            .fixedSize()
            .layoutPriority(1)
        }
        .fileImporter(
            isPresented: $fileService.showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            _ = fileService.handleFolderSelection(result: result)
            onFolderSelected(fileService.selectedFolder)
        }
    }
}

#Preview {
    FolderSelectionView(fileService: FileService(), isDisabled: false) { _ in }
        .padding()
}
