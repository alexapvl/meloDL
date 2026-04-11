import SwiftUI

struct DownloadButtonView: View {
    let isDownloading: Bool
    let canDownload: Bool
    let downloadAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        Button(action: isDownloading ? cancelAction : downloadAction) {
            HStack {
                if isDownloading {
                    Image(systemName: "xmark.circle")
                }
                Text(isDownloading ? "Cancel download" : "Download")
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!isDownloading && !canDownload)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

#Preview {
    VStack(spacing: 20) {
        DownloadButtonView(isDownloading: false, canDownload: true, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: true, canDownload: false, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: false, canDownload: false, downloadAction: {}, cancelAction: {})
    }
    .padding()
}
