import SwiftUI

struct StatusDisplayView: View {
    let status: String
    let statusColor: Color
    let downloads: [DownloadItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !status.isEmpty && status != "Idle" {
                Text(status)
                    .foregroundStyle(statusColor)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
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
                .background(Color(.controlBackgroundColor).opacity(0.35))
                .cornerRadius(8)
            } else {
                Text("Queue is empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
