import AppKit
import Foundation
import os

@MainActor
final class TrimEditorViewModel: ObservableObject {
    enum Handle {
        case start
        case end
    }

    enum Phase: Equatable {
        case loading
        case ready
        case saving
        case saved(SaveOutcome)
        case failed(String)
    }

    enum SaveOutcome: Equatable {
        case newFile(URL)
        case replacedOriginal
    }

    static let minimumVisibleSpan: TimeInterval = 1
    private static let losslessNudge: TimeInterval = 0.01
    private static let largeNudge: TimeInterval = 1
    private static let edgeFade: TimeInterval = 0.005

    let target: TrimTarget
    let player = AudioPreviewPlayer()

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var waveform: WaveformData?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var startTime: TimeInterval = 0
    @Published private(set) var endTime: TimeInterval = 0
    @Published private(set) var visibleRange: ClosedRange<TimeInterval> = 0...1
    @Published var activeHandle: Handle = .start
    @Published var isLoopEnabled = false {
        didSet { player.isLooping = isLoopEnabled }
    }
    @Published private(set) var saveErrorMessage: String?

    private let onFileChanged: () -> Void
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "TrimEditor")
    private var sampleRate: Double = 44_100
    private var codecArguments: [String] = []
    private var loadTask: Task<Void, Never>?

    init(target: TrimTarget, onFileChanged: @escaping () -> Void) {
        self.target = target
        self.onFileChanged = onFileChanged
    }

    // MARK: - Lifecycle

    func load() {
        guard loadTask == nil else { return }
        loadTask = Task {
            do {
                try player.load(url: target.fileURL)
                guard let fileFormat = player.fileFormat else { throw CocoaError(.fileReadCorruptFile) }
                sampleRate = fileFormat.sampleRate
                codecArguments = target.format.codecArguments(fileFormat: fileFormat)
                duration = player.duration
                endTime = duration
                syncPlaybackRegion()
                visibleRange = 0...max(duration, Self.minimumVisibleSpan)

                let waveform = try await WaveformAnalyzer.shared.waveform(for: target.fileURL)
                guard !Task.isCancelled else { return }
                self.waveform = waveform
                phase = .ready
            } catch {
                logger.failure("Failed to load trim editor: \(error.localizedDescription)")
                phase = .failed("Couldn't read this file. \(error.localizedDescription)")
            }
        }
    }

    func shutdown() {
        loadTask?.cancel()
        player.shutdown()
    }

    // MARK: - Selection

    var selectionLength: TimeInterval { endTime - startTime }

    var hasChanges: Bool {
        startTime > 0.0005 || endTime < duration - 0.0005
    }

    private var frameDuration: TimeInterval? {
        target.format.frameSampleCount.map { Double($0) / sampleRate }
    }

    private var minimumSelection: TimeInterval {
        max(0.1, (frameDuration ?? 0) * 2)
    }

    func setHandle(_ handle: Handle, to time: TimeInterval) {
        let time = snapped(time)
        switch handle {
        case .start:
            startTime = max(0, min(time, endTime - minimumSelection))
        case .end:
            endTime = min(duration, max(time, startTime + minimumSelection))
        }
        syncPlaybackRegion()
    }

    func setHandleAtPlayhead(_ handle: Handle) {
        activeHandle = handle
        setHandle(handle, to: player.currentTime)
    }

    func nudgeActiveHandle(by direction: Double, large: Bool) {
        let step = large ? Self.largeNudge : (frameDuration ?? Self.losslessNudge)
        let current = activeHandle == .start ? startTime : endTime
        setHandle(activeHandle, to: current + direction * step)
    }

    func resetSelection() {
        startTime = 0
        endTime = duration
        syncPlaybackRegion()
    }

    /// Playback is confined to the selection, so the playhead is pulled inside whenever the
    /// handles move past it. While playing, the player itself stops or loops at the out point.
    private func syncPlaybackRegion() {
        player.region = startTime...endTime
        let time = player.currentTime
        if time < startTime || (time > endTime && !player.isPlaying) {
            player.seek(to: clampedToSelection(time))
        }
    }

    private func clampedToSelection(_ time: TimeInterval) -> TimeInterval {
        min(max(time, startTime), endTime)
    }

    /// Stream-copied formats can only cut on codec frames, so the handles snap to that grid
    /// and the preview matches the saved file.
    private func snapped(_ time: TimeInterval) -> TimeInterval {
        let clamped = max(0, min(time, duration))
        guard let frameDuration, frameDuration > 0 else { return clamped }
        return min(duration, (clamped / frameDuration).rounded() * frameDuration)
    }

    // MARK: - Viewport

    var visibleSpan: TimeInterval { visibleRange.upperBound - visibleRange.lowerBound }

    func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return visibleRange.lowerBound }
        return visibleRange.lowerBound + Double(x / width) * visibleSpan
    }

    func x(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard visibleSpan > 0 else { return 0 }
        return CGFloat((time - visibleRange.lowerBound) / visibleSpan) * width
    }

    func handle(nearX x: CGFloat, width: CGFloat, tolerance: CGFloat = 8) -> Handle? {
        let startDistance = abs(self.x(for: startTime, width: width) - x)
        let endDistance = abs(self.x(for: endTime, width: width) - x)
        guard min(startDistance, endDistance) <= tolerance else { return nil }
        return startDistance <= endDistance ? .start : .end
    }

    func zoom(by factor: Double, anchor: TimeInterval) {
        guard factor > 0, duration > 0 else { return }
        let span = visibleSpan
        let newSpan = min(max(span / factor, Self.minimumVisibleSpan), max(duration, Self.minimumVisibleSpan))
        let ratio = (anchor - visibleRange.lowerBound) / span
        setVisibleRange(lowerBound: anchor - ratio * newSpan, span: newSpan)
    }

    func pan(by seconds: TimeInterval) {
        setVisibleRange(lowerBound: visibleRange.lowerBound + seconds, span: visibleSpan)
    }

    func setVisibleRange(lowerBound: TimeInterval, span: TimeInterval) {
        let maxLower = max(0, duration - span)
        let lower = min(max(0, lowerBound), maxLower)
        visibleRange = lower...(lower + span)
    }

    func centerViewport(on time: TimeInterval) {
        setVisibleRange(lowerBound: time - visibleSpan / 2, span: visibleSpan)
    }

    /// Pages the zoomed view along while playback runs past its edges.
    func followPlayhead(_ time: TimeInterval) {
        guard player.isPlaying, visibleSpan < duration else { return }
        if time > visibleRange.upperBound || time < visibleRange.lowerBound {
            setVisibleRange(lowerBound: time - visibleSpan * 0.1, span: visibleSpan)
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            return
        }
        let atOutPoint = player.currentTime >= endTime - 0.01
        player.play(from: atOutPoint ? startTime : clampedToSelection(player.currentTime))
    }

    func playSelection() {
        player.play(from: startTime)
    }

    func seek(to time: TimeInterval) {
        player.seek(to: clampedToSelection(time))
    }

    // MARK: - Save

    func save(replacingOriginal: Bool) {
        guard phase == .ready, hasChanges else { return }
        player.pause()
        phase = .saving
        saveErrorMessage = nil

        let source = target.fileURL
        let start = startTime
        let length = selectionLength
        let codecArguments = codecArguments
        let edgeFade = target.format.isStreamCopy ? nil : Self.edgeFade
        let tempURL = Self.temporaryURL(for: source)

        Task {
            do {
                try await DownloadEngine().trimAudio(
                    source: source,
                    destination: tempURL,
                    start: start,
                    duration: length,
                    codecArguments: codecArguments,
                    edgeFade: edgeFade
                )

                if replacingOriginal {
                    try Self.replace(source, with: tempURL)
                    phase = .saved(.replacedOriginal)
                } else {
                    let destination = Self.availableEditURL(for: source)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    phase = .saved(.newFile(destination))
                }
                onFileChanged()
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                logger.failure("Trim failed: \(error.localizedDescription)")
                saveErrorMessage = error.localizedDescription
                phase = .ready
            }
        }
    }

    func revealSavedFile() {
        guard case .saved(let outcome) = phase else { return }
        let url: URL
        switch outcome {
        case .newFile(let fileURL): url = fileURL
        case .replacedOriginal: url = target.fileURL
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func temporaryURL(for source: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString.prefix(8)
        return source.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).meloDL-trim-\(token)")
            .appendingPathExtension(source.pathExtension)
    }

    private static func availableEditURL(for source: URL) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? " (edit)" : " (edit \(attempt))"
            let candidate = folder.appendingPathComponent(stem + suffix).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    /// Moves the original to the Trash (recoverable) and puts the trimmed file at its path.
    private static func replace(_ original: URL, with trimmed: URL) throws {
        let fileManager = FileManager.default
        var trashedURL: NSURL?
        try fileManager.trashItem(at: original, resultingItemURL: &trashedURL)
        do {
            try fileManager.moveItem(at: trimmed, to: original)
        } catch {
            if let trashedURL = trashedURL as URL? {
                try? fileManager.moveItem(at: trashedURL, to: original)
            }
            throw error
        }
    }
}
