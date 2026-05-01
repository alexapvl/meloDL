import SwiftUI

struct ContentView: View {
    @ObservedObject private var appSettings: AppSettings
    @StateObject private var viewModel: ContentViewModel
    private let onCheckAppUpdates: () -> Void
    private let onOpenSettings: (() -> Void)?

    init(appSettings: AppSettings,
         onCheckAppUpdates: @escaping () -> Void,
         onOpenSettings: (() -> Void)? = nil) {
        self.appSettings = appSettings
        self.onCheckAppUpdates = onCheckAppUpdates
        self.onOpenSettings = onOpenSettings
        _viewModel = StateObject(wrappedValue: ContentViewModel(appSettings: appSettings))
    }

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                Text("meloDL")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.top)

                VStack(alignment: .leading, spacing: 15) {
                    URLInputView(
                        url: $viewModel.url,
                        isDisabled: viewModel.isDownloading,
                        onSubmitDownload: viewModel.downloadVideo
                    )

                    HStack(alignment: .bottom, spacing: 10) {
                        FormatPickerView(
                            format: $appSettings.format,
                            isDisabled: viewModel.isDownloading
                        )

                        Spacer(minLength: 0)

                        if let onOpenSettings {
                            Button(action: onOpenSettings) {
                                Label("Advanced Settings", systemImage: "gear")
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isDownloading)
                        } else {
                            SettingsLink {
                                Label("Advanced Settings", systemImage: "gear")
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isDownloading)
                        }
                    }

                    DownloadButtonView(
                        isDownloading: viewModel.isDownloading,
                        isCheckingDuplicates: viewModel.isCheckingDuplicates,
                    isAnalyzingPlaylist: viewModel.isAnalyzingPlaylist,
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
                    onCheckUpdates: {
                        viewModel.checkForAllUpdates(checkForAppUpdates: onCheckAppUpdates)
                    }
                )
            }
            .frame(minWidth: 580, minHeight: 600)
            .onAppear { viewModel.onAppear() }
            .disabled(viewModel.isShowingDuplicateReview)
            .blur(radius: viewModel.isShowingDuplicateReview ? 9 : 0)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isShowingDuplicateReview)

            if viewModel.isShowingDuplicateReview {
                DuplicateReviewModal(
                    items: viewModel.duplicateReviewItems,
                    currentIndex: viewModel.duplicateReviewIndex,
                    onSkipCurrent: viewModel.duplicateReviewSkipCurrent,
                    onDownloadCurrent: viewModel.duplicateReviewDownloadCurrent,
                    onPreviewCurrent: viewModel.previewCurrentDuplicateMatch,
                    onCancel: viewModel.cancelDuplicateReview
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }
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
            .help("Check for app and binary updates")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
