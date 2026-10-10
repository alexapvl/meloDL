import AVFoundation
import Foundation
import os

/// Sample-accurate preview playback for the trim editor.
@MainActor
final class AudioPreviewPlayer: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false

    private(set) var duration: TimeInterval = 0
    private(set) var fileFormat: AVAudioFormat?
    /// Playback stops (or loops, with `isLooping`) at the region's end. Both are live: changing
    /// them during playback takes effect on the next tick.
    var region: ClosedRange<TimeInterval>?
    var isLooping = false

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.alexapvl.meloDL", category: "AudioPreviewPlayer")
    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var segmentStart: TimeInterval = 0
    private var ticker: Timer?

    func load(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        self.file = file
        fileFormat = file.fileFormat
        sampleRate = file.processingFormat.sampleRate
        duration = Double(file.length) / sampleRate
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()
    }

    /// Plays from `start`. Audio is scheduled to the track end so the region can grow during
    /// playback; `tick()` enforces the region's end.
    func play(from start: TimeInterval) {
        guard let file else { return }
        let start = max(0, min(start, duration))
        guard duration - start > 0.01 else { return }

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                logger.error("Failed to start audio engine: \(error.localizedDescription)")
                return
            }
        }

        playerNode.stop()
        let startFrame = AVAudioFramePosition(start * sampleRate)
        let frameCount = AVAudioFrameCount(max(1, Double(file.length - startFrame)))
        playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil)
        playerNode.play()

        segmentStart = start
        currentTime = start
        isPlaying = true
        startTicker()
    }

    func pause() {
        playerNode.stop()
        isPlaying = false
        stopTicker()
    }

    func seek(to time: TimeInterval) {
        let time = max(0, min(time, duration))
        guard isPlaying else {
            currentTime = time
            return
        }
        play(from: time)
    }

    func shutdown() {
        stopTicker()
        playerNode.stop()
        engine.stop()
        isPlaying = false
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPlaying,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }

        let elapsed = max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
        let time = segmentStart + elapsed
        let end = min(region?.upperBound ?? duration, duration)
        guard time < end else {
            if isLooping, let region {
                play(from: region.lowerBound)
            } else {
                pause()
                currentTime = end
            }
            return
        }
        currentTime = time
    }
}
