import AppKit
import SwiftUI

extension View {
    func disableFocusRings() -> some View {
        background(FocusRingDisabler())
    }
}

private struct FocusRingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusRingDisablingView {
        FocusRingDisablingView()
    }

    func updateNSView(_ nsView: FocusRingDisablingView, context: Context) {
        nsView.disableFocusRingsSoon()
    }
}

private final class FocusRingDisablingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disableFocusRingsSoon()
    }

    override func layout() {
        super.layout()
        disableFocusRingsSoon()
    }

    func disableFocusRingsSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            Self.disableFocusRings(in: window)
        }
    }

    private static func disableFocusRings(in window: NSWindow) {
        if let contentView = window.contentView {
            disableFocusRings(in: contentView)
        }
    }

    private static func disableFocusRings(in view: NSView) {
        view.focusRingType = .none
        view.subviews.forEach { disableFocusRings(in: $0) }
    }
}
