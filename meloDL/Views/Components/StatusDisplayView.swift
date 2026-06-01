import SwiftUI

struct StatusDisplayView: View {
    let status: String
    let statusColor: Color
    let downloads: [DownloadItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Queue", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !downloads.isEmpty {
                    Text("\(downloads.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            if !status.isEmpty && status != "Idle" {
                Text(status)
                    .foregroundStyle(statusColor)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
            }

            if !downloads.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(downloads) { item in
                            DownloadItemRow(item: item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.controlBackgroundColor).opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                emptyState
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.13), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.7))

            VStack(spacing: 3) {
                Text("No downloads yet")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.85))

                Text("Paste a supported URL above to start a new download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DownloadItemRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 8) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.truncated(to: 120))
                    .font(.caption)
                    .lineLimit(1)
                if let detail = item.status.displayText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let filepath = previewFilepath {
                Button("Preview") {
                    TrackPreviewService.shared.previewTrack(
                        atPath: filepath,
                        title: item.title
                    )
                }
                .meloBorderedButton()
                .help("Preview in Finder")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var previewFilepath: String? {
        guard let filepath = item.status.completedFilepath else { return nil }
        return FileManager.default.fileExists(atPath: filepath) ? filepath : nil
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .downloading:
            ProgressView()
                .controlSize(.small)
        case .skipped:
            Image(systemName: "forward.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}
