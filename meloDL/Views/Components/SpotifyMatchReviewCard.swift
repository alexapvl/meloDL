import AppKit
import SwiftUI

struct SpotifyMatchReviewCard: View {
    let info: SpotifyItemInfo
    let matchURL: String
    let onSkip: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            trackColumn(
                label: "On Spotify",
                title: info.track.title,
                artists: info.track.artistLine,
                durationSec: Int(info.track.durationSec.rounded())
            )

            Divider()

            trackColumn(
                label: "Best match on YouTube Music",
                title: info.matchTitle ?? "Unknown",
                artists: info.matchArtists ?? "",
                durationSec: info.matchDurationSec
            )

            if let score = info.matchScore {
                Text("Match confidence: \(Int((score * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Skip", role: .destructive, action: onSkip)
                    .meloBorderedButton(destructive: true)
                    .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Open on YouTube Music") {
                    if let url = URL(string: matchURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .meloBorderedButton()
                .keyboardShortcut("p", modifiers: [])

                Button("Download", action: onDownload)
                    .meloBorderedButton()
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 14, y: 8)
    }

    private func trackColumn(label: String, title: String, artists: String, durationSec: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
            Text([artists, durationSec.map(Self.formatDuration)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private static func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
