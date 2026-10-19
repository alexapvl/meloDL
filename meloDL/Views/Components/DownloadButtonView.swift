import SwiftUI

struct DownloadButtonView: View {
    let isDownloading: Bool
    let isCheckingDuplicates: Bool
    let isAnalyzingPlaylist: Bool
    let isIndexingTracks: Bool
    let canDownload: Bool
    let downloadAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        Button(action: isDownloading ? cancelAction : downloadAction) {
            HStack(spacing: 8) {
                if isCheckingDuplicates || isAnalyzingPlaylist {
                    ProgressView()
                        .controlSize(.small)
                } else if isIndexingTracks && !isDownloading {
                    ProgressView()
                        .controlSize(.small)
                } else if isDownloading {
                    Image(systemName: "xmark.circle")
                }
                Text(buttonTitle)
            }
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .disabled(isCheckingDuplicates || isAnalyzingPlaylist || (!isDownloading && (!canDownload || isIndexingTracks)))
        .buttonStyle(.borderedProminent)
        .pointerStyle(.link)
        .controlSize(.regular)
        .tint(isDownloading ? .red : .accentColor)
    }

    private var buttonTitle: String {
        if isCheckingDuplicates { return "Checking duplicates..." }
        if isAnalyzingPlaylist { return "Analyzing playlist..." }
        if isIndexingTracks && !isDownloading { return "Indexing tracks in progress..." }
        if isDownloading { return "Cancel download" }
        return "Download"
    }
}

struct MeloBorderedButtonStyle: ButtonStyle {
    var destructive = false
    var armed = false

    func makeBody(configuration: Configuration) -> some View {
        MeloBorderedButtonBody(
            configuration: configuration,
            destructive: destructive,
            armed: armed
        )
    }

    private struct MeloBorderedButtonBody: View {
        let configuration: Configuration
        let destructive: Bool
        let armed: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundStyle(foregroundStyle)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(backgroundFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
                .opacity(isEnabled ? 1 : 0.55)
                .contentShape(.rect)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { isHovered = $0 }
        }

        private var isRed: Bool {
            armed || (destructive && isHovered)
        }

        private var foregroundStyle: Color {
            guard isEnabled else { return .secondary }
            return isRed ? .red : .primary
        }

        private var backgroundFill: Color {
            guard isEnabled else { return Color.primary.opacity(0.035) }
            if armed { return .red.opacity(configuration.isPressed ? 0.20 : 0.16) }
            if destructive && isHovered { return .red.opacity(configuration.isPressed ? 0.14 : 0.10) }
            if isHovered { return Color.primary.opacity(configuration.isPressed ? 0.10 : 0.08) }
            return Color.primary.opacity(configuration.isPressed ? 0.08 : 0.06)
        }

        private var borderColor: Color {
            guard isEnabled else { return Color.secondary.opacity(0.12) }
            if armed { return .red.opacity(0.28) }
            if destructive && isHovered { return .red.opacity(0.20) }
            return Color.secondary.opacity(0.18)
        }
    }
}

extension ButtonStyle where Self == MeloBorderedButtonStyle {
    static var meloBordered: MeloBorderedButtonStyle {
        MeloBorderedButtonStyle()
    }
}

extension View {
    func meloBorderedButton(destructive: Bool = false, armed: Bool = false) -> some View {
        buttonStyle(MeloBorderedButtonStyle(destructive: destructive, armed: armed))
            .focusable(false)
            .pointerStyle(.link)
    }
}

#Preview {
    VStack(spacing: 20) {
        DownloadButtonView(isDownloading: false, isCheckingDuplicates: false, isAnalyzingPlaylist: false, isIndexingTracks: false, canDownload: true, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: false, isCheckingDuplicates: false, isAnalyzingPlaylist: false, isIndexingTracks: true, canDownload: false, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: true, isCheckingDuplicates: false, isAnalyzingPlaylist: false, isIndexingTracks: false, canDownload: false, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: false, isCheckingDuplicates: true, isAnalyzingPlaylist: false, isIndexingTracks: false, canDownload: false, downloadAction: {}, cancelAction: {})
        DownloadButtonView(isDownloading: true, isCheckingDuplicates: false, isAnalyzingPlaylist: true, isIndexingTracks: false, canDownload: false, downloadAction: {}, cancelAction: {})
    }
    .padding()
}
