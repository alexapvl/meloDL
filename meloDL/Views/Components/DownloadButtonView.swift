import SwiftUI

struct DownloadButtonView: View {
    let isDownloading: Bool
    let isCheckingDuplicates: Bool
    let isAnalyzingPlaylist: Bool
    let canDownload: Bool
    let downloadAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        Button(action: isDownloading ? cancelAction : downloadAction) {
            HStack {
                if isCheckingDuplicates || isAnalyzingPlaylist {
                    ProgressView()
                        .controlSize(.small)
                } else if isDownloading {
                    Image(systemName: "xmark.circle")
                }
                Text(buttonTitle)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(isCheckingDuplicates || isAnalyzingPlaylist || (!isDownloading && !canDownload))
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var buttonTitle: String {
        if isCheckingDuplicates { return "Checking duplicates..." }
        if isAnalyzingPlaylist { return "Analyzing playlist..." }
        if isDownloading { return "Cancel download" }
        return "Download"
    }
}

#Preview {
    VStack(spacing: 20) {
        DownloadButtonView(isDownloading: false, isCheckingDuplicates: false, isAnalyzingPlaylist: false, canDownload: true, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: true, isCheckingDuplicates: false, isAnalyzingPlaylist: false, canDownload: false, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: false, isCheckingDuplicates: true, isAnalyzingPlaylist: false, canDownload: false, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: true, isCheckingDuplicates: false, isAnalyzingPlaylist: true, canDownload: false, downloadAction: {}, cancelAction: {})
    }
    .padding()
}
