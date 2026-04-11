import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("meloDL")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top)

            VStack(alignment: .leading, spacing: 15) {
                URLInputView(
                    url: $viewModel.url,
                    isDisabled: viewModel.isDownloading
                )

                FolderSelectionView(
                    fileService: viewModel.fileService,
                    isDisabled: viewModel.isDownloading
                )

                FormatPickerView(
                    audioSettings: $viewModel.audioSettings,
                    isDisabled: viewModel.isDownloading
                )

                FastDownloadSettingsView(
                    downloadConfiguration: $viewModel.downloadConfiguration,
                    isDisabled: viewModel.isDownloading
                )

                DownloadButtonView(
                    isDownloading: viewModel.isDownloading,
                    canDownload: viewModel.canDownload,
                    downloadAction: viewModel.downloadVideo,
                    cancelAction: viewModel.cancelDownloads
                )
            }
            .padding(.horizontal)

            StatusDisplayView(
                status: viewModel.statusMessage,
                statusColor: viewModel.statusColor,
                downloads: viewModel.downloads
            )
            .padding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BinaryVersionBar(
                ytdlpVersion: viewModel.ytdlpVersion,
                ffmpegVersion: viewModel.ffmpegVersion,
                updateStatus: viewModel.binaryUpdateStatus,
                onCheckUpdates: viewModel.checkForBinaryUpdates
            )
        }
        .frame(minWidth: 580, minHeight: 600)
        .onAppear { viewModel.onAppear() }
        .onChange(of: viewModel.audioSettings.format) { _, _ in
            viewModel.persistAudioSettings()
        }
        .onChange(of: viewModel.audioSettings.quality) { _, _ in
            viewModel.persistAudioSettings()
        }
        .onChange(of: viewModel.audioSettings.embedMetadata) { _, _ in
            viewModel.persistAudioSettings()
        }
        .onChange(of: viewModel.audioSettings.embedThumbnail) { _, _ in
            viewModel.persistAudioSettings()
        }
        .onChange(of: viewModel.downloadConfiguration.fastDownloads) { _, _ in
            viewModel.persistDownloadSettings()
        }
        .onChange(of: viewModel.fileService.selectedFolder) { _, _ in
            viewModel.persistSelectedFolder()
        }
    }
}

struct BinaryVersionBar: View {
    let ytdlpVersion: String?
    let ffmpegVersion: String?
    let updateStatus: String?
    let onCheckUpdates: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let v = ytdlpVersion {
                Label("yt-dlp \(v)", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let v = ffmpegVersion {
                Label("ffmpeg \(v)", systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let status = updateStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button(action: onCheckUpdates) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Check for binary updates")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
