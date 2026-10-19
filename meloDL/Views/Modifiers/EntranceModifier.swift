import AppKit
import SwiftUI

/// Fades and nudges a view into place the first time it appears.
private struct EntranceModifier: ViewModifier {
    let offset: CGSize
    let delay: Double
    let duration: Double
    @State private var isVisible: Bool

    init(offset: CGSize, delay: Double, duration: Double, enabled: Bool) {
        self.offset = offset
        self.delay = delay
        self.duration = duration
        _isVisible = State(initialValue: !enabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .zero : offset)
            .onAppear {
                guard !isVisible else { return }
                withAnimation(.smooth(duration: duration).delay(delay)) {
                    isVisible = true
                }
            }
    }
}

extension View {
    func entrance(x: CGFloat = 0, y: CGFloat = 0, delay: Double = 0, duration: Double = 0.32, enabled: Bool = true) -> some View {
        modifier(EntranceModifier(offset: CGSize(width: x, height: y), delay: delay, duration: duration, enabled: enabled))
    }

    /// Top-to-bottom cascade for sidebar items.
    func sidebarEntrance(index: Int) -> some View {
        entrance(y: -8, delay: 0.02 + Double(index) * 0.015, duration: 0.22, enabled: index < 14)
    }
}
