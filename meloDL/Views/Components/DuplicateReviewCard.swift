import AppKit
import SwiftUI

struct DuplicateReviewCard: View {
    let item: DuplicateReviewItem
    let onSkip: () -> Void
    let onDownloadAnyway: () -> Void
    let onPreview: () -> Void

    @GestureState private var dragTranslation: CGSize = .zero
    @State private var persistentOffset: CGFloat = 0
    @State private var isCommitAnimating = false
    private let swipeCommitThreshold: CGFloat = 115
    private let maxInteractiveOffset: CGFloat = 190
    private let swipeAnimationDuration: Double = 0.24

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Incoming Track")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.incomingTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Matched Track")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.match.candidateTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(item.match.candidatePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Text("Match confidence: \(item.match.confidence.rawValue.capitalized)")
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 10) {
                Button("Skip", role: .destructive) {
                    swipeLeft()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Preview") {
                    onPreview()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("p", modifiers: [])

                Button("Download anyway") {
                    swipeRight()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            swipeFeedbackOverlay
        }
        .shadow(radius: 14, y: 8)
        .offset(x: currentOffsetX)
        .rotationEffect(.degrees(Double(currentOffsetX / 24)))
        .overlay {
            TrackpadHorizontalSwipeCapture(
                onHorizontalDelta: handleTrackpadHorizontalScroll(delta:),
                onScrollEnded: settleTrackpadSwipe
            )
            .allowsHitTesting(false)
        }
        .gesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    if value.translation.width > swipeCommitThreshold {
                        swipeRight()
                    } else if value.translation.width < -swipeCommitThreshold {
                        swipeLeft()
                    } else {
                        withAnimation(.easeOut(duration: 0.22)) {
                            persistentOffset = 0
                        }
                    }
                }
        )
        .onAppear {
            // Ensure a fresh neutral state for every new card instance.
            persistentOffset = 0
            isCommitAnimating = false
        }
    }

    @ViewBuilder
    private var swipeFeedbackOverlay: some View {
        let clamped = min(abs(currentOffsetX) / maxInteractiveOffset, 1)
        if currentOffsetX != 0 {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(actionColor.opacity(0.18 + (clamped * 0.28)))
                .overlay {
                    centeredActionIndicator
                }
                .allowsHitTesting(false)
        }
    }

    private var centeredActionIndicator: some View {
        return ZStack {
            Circle()
                .stroke(actionColor.opacity(0.32), lineWidth: 5)
                .frame(width: 70, height: 70)

            Circle()
                .trim(from: 0, to: commitProgress)
                .stroke(
                    ringProgressColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 70, height: 70)
                .transaction { transaction in
                    transaction.animation = isCommitAnimating
                        ? .easeOut(duration: swipeAnimationDuration)
                        : nil
                }

            Text(actionLabel)
                .font(.caption2.weight(.bold))
            .foregroundStyle(actionColor)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var actionLabel: String {
        currentOffsetX < 0 ? "SKIP" : "DOWNLOAD"
    }

    private var actionColor: Color {
        currentOffsetX < 0 ? .red : .blue
    }

    private var ringProgressColor: Color {
        commitProgress >= 1 ? actionColor : .white.opacity(0.72)
    }

    private var commitProgress: CGFloat {
        min(abs(currentOffsetX) / swipeCommitThreshold, 1)
    }

    private var currentOffsetX: CGFloat {
        persistentOffset + dragTranslation.width
    }

    private func swipeLeft() {
        isCommitAnimating = true
        withAnimation(.easeOut(duration: swipeAnimationDuration)) {
            persistentOffset = -260
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            onSkip()
            persistentOffset = 0
            isCommitAnimating = false
        }
    }

    private func swipeRight() {
        isCommitAnimating = true
        withAnimation(.easeOut(duration: swipeAnimationDuration)) {
            persistentOffset = 260
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            onDownloadAnyway()
            persistentOffset = 0
            isCommitAnimating = false
        }
    }

    private func handleTrackpadHorizontalScroll(delta: CGFloat) {
        isCommitAnimating = false
        let nextOffset = persistentOffset + (delta * 1.05)
        persistentOffset = min(max(nextOffset, -maxInteractiveOffset), maxInteractiveOffset)
    }

    private func settleTrackpadSwipe() {
        if persistentOffset > swipeCommitThreshold {
            swipeRight()
            return
        }
        if persistentOffset < -swipeCommitThreshold {
            swipeLeft()
            return
        }
        isCommitAnimating = false
        withAnimation(.easeOut(duration: swipeAnimationDuration)) {
            persistentOffset = 0
        }
    }
}

private struct TrackpadHorizontalSwipeCapture: NSViewRepresentable {
    let onHorizontalDelta: (CGFloat) -> Void
    let onScrollEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHorizontalDelta: onHorizontalDelta, onScrollEnded: onScrollEnded)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onHorizontalDelta = onHorizontalDelta
        context.coordinator.onScrollEnded = onScrollEnded
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var onHorizontalDelta: (CGFloat) -> Void
        var onScrollEnded: () -> Void

        private weak var hostView: NSView?
        private var monitor: Any?

        init(onHorizontalDelta: @escaping (CGFloat) -> Void, onScrollEnded: @escaping () -> Void) {
            self.onHorizontalDelta = onHorizontalDelta
            self.onScrollEnded = onScrollEnded
        }

        func attach(to view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event: event) ?? event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(event: NSEvent) -> NSEvent? {
            guard let hostView,
                  let hostWindow = hostView.window,
                  event.window === hostWindow else {
                return event
            }

            if event.phase == .began || event.phase == .mayBegin {
                return event
            }

            // Ignore inertial momentum to avoid auto-swiping the next card.
            if event.momentumPhase != [] {
                return nil
            }

            // Use natural scroll direction: finger-left moves card left.
            let horizontalDelta = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let mostlyHorizontal = abs(horizontalDelta) > abs(deltaY)

            if mostlyHorizontal {
                onHorizontalDelta(horizontalDelta)
                if event.phase == .ended || event.phase == .cancelled {
                    onScrollEnded()
                }
                return nil
            }

            if event.phase == .ended || event.phase == .cancelled {
                onScrollEnded()
            }

            return event
        }
    }
}
