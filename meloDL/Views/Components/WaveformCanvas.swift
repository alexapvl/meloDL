import AppKit
import SwiftUI

/// Rekordbox-style RGB waveform (same approach as Mixxx's RGB renderer): bass drives red, mids
/// green, highs blue, mixed additively. A dim outer layer follows the peaks; a brighter core
/// follows the RMS level.
struct WaveformCanvas: View {
    let waveform: WaveformData
    let visibleRange: ClosedRange<TimeInterval>
    let selection: ClosedRange<TimeInterval>
    var activeHandle: TrimEditorViewModel.Handle?
    var viewport: ClosedRange<TimeInterval>?

    static let background = Color(white: 0.07)
    static let handleColor = Color.orange
    private static let lowRGB: (Double, Double, Double) = (1, 0.1, 0.1)
    private static let midRGB: (Double, Double, Double) = (0.1, 1, 0.2)
    private static let highRGB: (Double, Double, Double) = (0.15, 0.35, 1)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.background))
            drawColumns(in: &context, size: size)
            drawSelection(in: &context, size: size)
            if let viewport {
                drawViewport(viewport, in: &context, size: size)
            }
        }
    }

    private var span: TimeInterval {
        max(visibleRange.upperBound - visibleRange.lowerBound, 0.001)
    }

    private func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat((time - visibleRange.lowerBound) / span) * width
    }

    private func drawColumns(in context: inout GraphicsContext, size: CGSize) {
        let count = waveform.bucketCount
        guard count > 0, size.width > 0 else { return }

        let midY = size.height / 2
        let maxHalfHeight = size.height / 2 - 1
        let columnWidth: CGFloat = 1
        let bucketsPerSecond = waveform.bucketsPerSecond

        context.fill(
            Path(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1)),
            with: .color(.white.opacity(0.08))
        )

        var x: CGFloat = 0
        while x < size.width {
            let startTime = visibleRange.lowerBound + Double(x / size.width) * span
            let endTime = visibleRange.lowerBound + Double((x + columnWidth) / size.width) * span
            let first = max(0, Int(startTime * bucketsPerSecond))
            let last = min(count, max(first + 1, Int(endTime * bucketsPerSecond)))
            guard first < count else { break }

            var peak: Float = 0
            var level: Float = 0
            var low: Float = 0
            var mid: Float = 0
            var high: Float = 0
            for index in first..<last {
                peak += waveform.peaks[index]
                level += waveform.levels[index]
                low += waveform.lows[index]
                mid += waveform.mids[index]
                high += waveform.highs[index]
            }
            let bucketCount = Float(last - first)
            peak /= bucketCount
            level /= bucketCount

            let (red, green, blue) = Self.mix(low: low, mid: mid, high: high)
            let brightness = 0.5 + 0.5 * Double(min(1, level * 1.3))
            let outerHeight = max(0.5, CGFloat(min(1, peak * 0.95)) * maxHalfHeight)
            let innerHeight = min(outerHeight, max(0.5, CGFloat(min(1, 1.1 * pow(level, 0.75))) * maxHalfHeight))

            context.fill(
                Path(CGRect(x: x, y: midY - outerHeight, width: columnWidth, height: outerHeight * 2)),
                with: .color(Color(red: red * brightness * 0.5, green: green * brightness * 0.5, blue: blue * brightness * 0.5))
            )
            context.fill(
                Path(CGRect(x: x, y: midY - innerHeight, width: columnWidth, height: innerHeight * 2)),
                with: .color(Color(red: red * brightness, green: green * brightness, blue: blue * brightness))
            )
            x += columnWidth
        }
    }

    /// Additive band mix scaled so the brightest channel is 1. Highs carry far less energy than
    /// bass, so they get a fixed boost to stay visible; squaring lets the dominant band lead so
    /// full-spectrum passages stay saturated instead of washing out to white.
    private static func mix(low: Float, mid: Float, high: Float) -> (Double, Double, Double) {
        let sharpness = 2.5
        let low = pow(Double(low), sharpness)
        let mid = pow(Double(mid) * 1.1, sharpness)
        let high = pow(Double(high) * 1.8, sharpness)
        let red = low * lowRGB.0 + mid * midRGB.0 + high * highRGB.0
        let green = low * lowRGB.1 + mid * midRGB.1 + high * highRGB.1
        let blue = low * lowRGB.2 + mid * midRGB.2 + high * highRGB.2
        let brightest = max(red, green, blue)
        guard brightest > 0 else { return lowRGB }
        return (red / brightest, green / brightest, blue / brightest)
    }

    private func drawSelection(in context: inout GraphicsContext, size: CGSize) {
        let startX = x(for: selection.lowerBound, width: size.width)
        let endX = x(for: selection.upperBound, width: size.width)
        let dim = GraphicsContext.Shading.color(.black.opacity(0.62))

        if startX > 0 {
            context.fill(Path(CGRect(x: 0, y: 0, width: min(startX, size.width), height: size.height)), with: dim)
        }
        if endX < size.width {
            context.fill(Path(CGRect(x: max(endX, 0), y: 0, width: size.width - max(endX, 0), height: size.height)), with: dim)
        }

        drawHandle(at: startX, isActive: activeHandle == .start, pointsRight: true, in: &context, size: size)
        drawHandle(at: endX, isActive: activeHandle == .end, pointsRight: false, in: &context, size: size)
    }

    private func drawHandle(at x: CGFloat, isActive: Bool, pointsRight: Bool, in context: inout GraphicsContext, size: CGSize) {
        guard x >= -8, x <= size.width + 8 else { return }
        let color = isActive ? Self.handleColor : Self.handleColor.opacity(0.7)
        let lineWidth: CGFloat = isActive ? 2 : 1.5
        context.fill(Path(CGRect(x: x - lineWidth / 2, y: 0, width: lineWidth, height: size.height)), with: .color(color))

        guard activeHandle != nil else { return }
        let flag: CGFloat = min(9, size.height / 4)
        let direction: CGFloat = pointsRight ? 1 : -1
        for y in [CGFloat(0), size.height] {
            let tip = y == 0 ? flag : size.height - flag
            var triangle = Path()
            triangle.move(to: CGPoint(x: x, y: y))
            triangle.addLine(to: CGPoint(x: x + flag * direction, y: y))
            triangle.addLine(to: CGPoint(x: x, y: tip))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(color))
        }
    }

    private func drawViewport(_ viewport: ClosedRange<TimeInterval>, in context: inout GraphicsContext, size: CGSize) {
        let startX = x(for: viewport.lowerBound, width: size.width)
        let endX = x(for: viewport.upperBound, width: size.width)
        let rect = CGRect(x: startX, y: 0.5, width: max(2, endX - startX), height: size.height - 1)
        context.fill(Path(rect), with: .color(.white.opacity(0.06)))
        context.stroke(Path(rect), with: .color(.white.opacity(0.55)), lineWidth: 1)
    }
}

/// Kept separate from the waveform so 60 fps playhead updates don't redraw the columns.
struct WaveformPlayhead: View {
    @ObservedObject var player: AudioPreviewPlayer
    let visibleRange: ClosedRange<TimeInterval>
    var onTimeChange: ((TimeInterval) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let span = max(visibleRange.upperBound - visibleRange.lowerBound, 0.001)
            let x = CGFloat((player.currentTime - visibleRange.lowerBound) / span) * geometry.size.width
            if x >= 0, x <= geometry.size.width {
                Rectangle()
                    .fill(.white)
                    .frame(width: 1.5)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .offset(x: x - 0.75)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: player.currentTime) { _, time in
            onTimeChange?(time)
        }
    }
}

/// Window-local event taps for wheel/pinch over this view's frame and for editor shortcuts.
/// SwiftUI on macOS has no scroll-wheel or key handling that works without focus juggling.
struct LocalEventMonitor: NSViewRepresentable {
    var onScroll: ((NSEvent, CGPoint) -> Bool)?
    var onMagnify: ((NSEvent, CGPoint) -> Bool)?
    var onKeyDown: ((NSEvent) -> Bool)?

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
        nsView.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class MonitorView: NSView {
        var onScroll: ((NSEvent, CGPoint) -> Bool)?
        var onMagnify: ((NSEvent, CGPoint) -> Bool)?
        var onKeyDown: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            if onKeyDown != nil, window?.firstResponder is NSText {
                window?.makeFirstResponder(nil)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown]) { [weak self] event in
                let isHandled = MainActor.assumeIsolated {
                    self?.handle(event) ?? false
                }
                return isHandled ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            switch event.type {
            case .keyDown:
                guard let onKeyDown, !(window.firstResponder is NSText) else { return false }
                return onKeyDown(event)
            case .scrollWheel, .magnify:
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point) else { return false }
                if event.type == .scrollWheel {
                    return onScroll?(event, point) ?? false
                }
                return onMagnify?(event, point) ?? false
            default:
                return false
            }
        }
    }
}
