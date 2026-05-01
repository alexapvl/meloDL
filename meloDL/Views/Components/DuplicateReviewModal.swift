import SwiftUI

struct DuplicateReviewModal: View {
    let items: [DuplicateReviewItem]
    let currentIndex: Int
    let onSkipCurrent: () -> Void
    let onDownloadCurrent: () -> Void
    let onPreviewCurrent: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                header

                if let currentItem = activeItem {
                    DuplicateReviewCard(
                        item: currentItem,
                        onSkip: onSkipCurrent,
                        onDownloadAnyway: onDownloadCurrent,
                        onPreview: onPreviewCurrent
                    )
                    .id(currentItem.id)
                    .frame(maxWidth: 680)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98)),
                            removal: .opacity
                        )
                    )
                } else {
                    Text("No duplicates to review")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
        }
        .animation(.easeInOut(duration: 0.2), value: currentIndex)
    }

    private var activeItem: DuplicateReviewItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate Review")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("\(min(currentIndex + 1, items.count))/\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.8))
        }
    }
}
