import AppKit
import SwiftUI

struct TrimEditorView: View {
    @StateObject private var model: TrimEditorViewModel
    let onClose: () -> Void
    @State private var isConfirmingReplace = false

    init(target: TrimTarget, onFileChanged: @escaping () -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TrimEditorViewModel(target: target, onFileChanged: onFileChanged))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch model.phase {
            case .loading:
                placeholder {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing audio…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                placeholder {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            case .ready, .saving, .saved:
                if let waveform = model.waveform {
                    editor(waveform: waveform)
                }
            }

            footer
        }
        .background(
            LocalEventMonitor(onKeyDown: handleKeyDown)
        )
        .onAppear { model.load() }
        .onDisappear { model.shutdown() }
        .confirmationDialog(
            "Replace the original file?",
            isPresented: $isConfirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Replace Original", role: .destructive) {
                model.save(replacingOriginal: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original is moved to the Trash, so you can still recover it. Tags and artwork are kept.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trim")
                    .font(.title3.weight(.semibold))
                Text(model.target.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(model.target.format.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Text(model.target.format.cutDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 236)
        .background(WaveformCanvas.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Editor

    private func editor(waveform: WaveformData) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 6) {
                WaveformOverview(model: model, waveform: waveform)
                    .frame(height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                WaveformDetail(model: model, waveform: waveform)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    Text(Self.format(model.visibleRange.lowerBound))
                    Spacer()
                    Text("Scroll or pinch to zoom · drag to move")
                    Spacer()
                    Text(Self.format(min(model.visibleRange.upperBound, model.duration)))
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            }

            HStack(alignment: .bottom, spacing: 18) {
                readout("Start", value: model.startTime, handle: .start)
                readout("End", value: model.endTime, handle: .end)
                readout("Length", value: model.selectionLength, handle: nil)
                Spacer(minLength: 8)
                ShortcutsInfo()
            }
            .zIndex(1)
        }
        .disabled(model.phase != .ready)
    }

    private func readout(_ title: String, value: TimeInterval, handle: TrimEditorViewModel.Handle?) -> some View {
        let isActive = handle != nil && model.activeHandle == handle
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isActive ? WaveformCanvas.handleColor : .secondary)
            Text(Self.format(value))
                .font(.system(.body, design: .monospaced).weight(.medium))
                .monospacedDigit()
        }
        .contentShape(.rect)
        .onTapGesture {
            if let handle {
                model.activeHandle = handle
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 8) {
            Button {
                model.playSelection()
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 16)
            }
            .meloBorderedButton()
            .help("Play from the start of the selection (⇧Space)")

            PlayPauseButton(player: model.player) {
                model.togglePlayback()
            }

            Button {
                model.isLoopEnabled.toggle()
            } label: {
                if model.isLoopEnabled && model.phase == .ready {
                    Image(systemName: "repeat")
                        .frame(width: 16)
                        .foregroundStyle(WaveformCanvas.handleColor)
                } else {
                    Image(systemName: "repeat")
                        .frame(width: 16)
                }
            }
            .meloBorderedButton()
            .help("Loop the selection (L)")
        }
    }

    // MARK: - Footer

    /// One row when it fits; otherwise transport and actions stack on their own left-aligned
    /// rows, and finally every action button gets its own row.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                transportGroup
                status
                Spacer(minLength: 8)
                actionButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                transportGroup
                HStack(spacing: 8) {
                    actionButtons
                }
                status
            }

            VStack(alignment: .leading, spacing: 10) {
                transportGroup
                VStack(alignment: .leading, spacing: 8) {
                    actionButtons
                }
                status
            }
        }
    }

    @ViewBuilder
    private var transportGroup: some View {
        if model.waveform != nil {
            transport
                .disabled(model.phase != .ready)
                .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .saved(.newFile(let url)):
            Label("Saved as \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
        case .saved(.replacedOriginal):
            Label("Original replaced. The old version is in the Trash.", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        default:
            if let error = model.saveErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if case .saved = model.phase {
            revealButton
            doneButton
        } else {
            Button("Cancel", action: onClose)
                .meloBorderedButton()
                .disabled(model.phase == .saving)

            Button("Replace Original…") {
                isConfirmingReplace = true
            }
            .meloBorderedButton(destructive: true)
            .disabled(!canSave)

            Button {
                model.save(replacingOriginal: false)
            } label: {
                Label("Save as New", systemImage: "scissors")
            }
            .meloBorderedButton()
            .disabled(!canSave)
        }
    }

    private var revealButton: some View {
        Button {
            model.revealSavedFile()
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .meloBorderedButton()
    }

    private var doneButton: some View {
        Button("Done", action: onClose)
            .meloBorderedButton()
    }

    private var canSave: Bool {
        model.phase == .ready && model.hasChanges
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }

        if event.keyCode == 53 {
            if model.phase != .saving {
                onClose()
            }
            return true
        }

        guard model.phase == .ready else { return false }
        let shift = modifiers.contains(.shift)

        switch event.keyCode {
        case 49:
            shift ? model.playSelection() : model.togglePlayback()
        case 123:
            model.nudgeActiveHandle(by: -1, large: shift)
        case 124:
            model.nudgeActiveHandle(by: 1, large: shift)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "i": model.setHandleAtPlayhead(.start)
            case "o": model.setHandleAtPlayhead(.end)
            case "l": model.isLoopEnabled.toggle()
            case "r": model.resetSelection()
            default: return false
            }
        }
        return true
    }

    static func format(_ time: TimeInterval) -> String {
        let clamped = max(0, time)
        let minutes = Int(clamped) / 60
        let seconds = clamped - Double(minutes * 60)
        return String(format: "%d:%06.3f", minutes, seconds)
    }
}

/// Info circle that shows the editor's keyboard shortcuts while hovered. Drawn as an overlay
/// rather than a popover so it never takes key focus away from the editor's shortcuts.
private struct ShortcutsInfo: View {
    @State private var isHovering = false

    private let shortcuts: [(key: String, action: String)] = [
        ("Space", "Play / pause"),
        ("⇧Space", "Play from start"),
        ("I / O", "Set start / end at playhead"),
        ("← →", "Nudge handle (⇧ for 1 s)"),
        ("L", "Loop"),
        ("R", "Reset selection"),
        ("Esc", "Close")
    ]

    var body: some View {
        Image(systemName: "info.circle")
            .font(.callout)
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .overlay(alignment: .bottomTrailing) {
                if isHovering {
                    card
                        .fixedSize()
                        .offset(y: -24)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var card: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(shortcuts, id: \.key) { shortcut in
                GridRow {
                    Text(shortcut.key)
                        .font(.caption.weight(.semibold))
                        .monospaced()
                    Text(shortcut.action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

private struct PlayPauseButton: View {
    @ObservedObject var player: AudioPreviewPlayer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .frame(width: 16)
        }
        .meloBorderedButton()
        .help("Play or pause from the playhead (Space)")
    }
}

private struct WaveformOverview: View {
    @ObservedObject var model: TrimEditorViewModel
    let waveform: WaveformData

    var body: some View {
        GeometryReader { geometry in
            let fullRange = 0...max(model.duration, 0.001)
            ZStack(alignment: .topLeading) {
                WaveformCanvas(
                    waveform: waveform,
                    visibleRange: fullRange,
                    selection: model.startTime...model.endTime,
                    viewport: model.visibleSpan < model.duration ? model.visibleRange : nil
                )
                WaveformPlayhead(player: model.player, visibleRange: fullRange)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.centerViewport(on: time(at: value.location.x, width: geometry.size.width))
                    }
                    .onEnded { value in
                        guard abs(value.translation.width) < 3 else { return }
                        model.seek(to: time(at: value.location.x, width: geometry.size.width))
                    }
            )
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(max(0, min(x, width)) / width) * model.duration
    }
}

private struct WaveformDetail: View {
    private enum DragMode: Equatable {
        case handle(TrimEditorViewModel.Handle)
        case pending
        case pan(origin: TimeInterval)
    }

    @ObservedObject var model: TrimEditorViewModel
    let waveform: WaveformData
    @State private var dragMode: DragMode?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                WaveformCanvas(
                    waveform: waveform,
                    visibleRange: model.visibleRange,
                    selection: model.startTime...model.endTime,
                    activeHandle: model.activeHandle
                )
                WaveformPlayhead(player: model.player, visibleRange: model.visibleRange) { time in
                    model.followPlayhead(time)
                }
            }
            .contentShape(.rect)
            .gesture(dragGesture(width: width))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if dragMode == nil {
                        (model.handle(nearX: location.x, width: width) != nil ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .background(
                LocalEventMonitor(
                    onScroll: { event, point in
                        handleScroll(event, at: point, width: width)
                    },
                    onMagnify: { event, point in
                        model.zoom(by: 1 + event.magnification, anchor: model.time(atX: point.x, width: width))
                        return true
                    }
                )
            )
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragMode == nil {
                    if let handle = model.handle(nearX: value.startLocation.x, width: width) {
                        model.activeHandle = handle
                        dragMode = .handle(handle)
                    } else {
                        dragMode = .pending
                    }
                }

                switch dragMode {
                case .handle(let handle):
                    model.setHandle(handle, to: model.time(atX: value.location.x, width: width))
                case .pending:
                    if abs(value.translation.width) > 3 {
                        dragMode = .pan(origin: model.visibleRange.lowerBound)
                    }
                case .pan(let origin):
                    let offset = -Double(value.translation.width / max(width, 1)) * model.visibleSpan
                    model.setVisibleRange(lowerBound: origin + offset, span: model.visibleSpan)
                case nil:
                    break
                }
            }
            .onEnded { value in
                if dragMode == .pending {
                    model.seek(to: model.time(atX: value.location.x, width: width))
                }
                dragMode = nil
            }
    }

    /// Horizontal scroll pans; vertical scroll (wheel or trackpad) zooms around the cursor.
    private func handleScroll(_ event: NSEvent, at point: CGPoint, width: CGFloat) -> Bool {
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas

        if abs(deltaX) > abs(deltaY) {
            let points = precise ? deltaX : deltaX * 10
            model.pan(by: -Double(points / max(width, 1)) * model.visibleSpan)
        } else if deltaY != 0 {
            let factor = exp(Double(deltaY) * (precise ? 0.01 : 0.08))
            model.zoom(by: factor, anchor: model.time(atX: point.x, width: width))
        }
        return true
    }
}
