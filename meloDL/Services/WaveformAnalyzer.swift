import Accelerate
import AVFoundation
import Foundation

/// Per-bucket peak and RMS level plus low/mid/high band energy, normalized to 0...1.
/// Bands share one scale so their real balance (bass usually loudest) drives the colour, and
/// are smoothed over ~100 ms so it drifts instead of flickering.
final class WaveformData: Sendable {
    static let targetBucketsPerSecond: Double = 400

    let duration: TimeInterval
    /// Exact rate: buckets hold a whole number of samples, so this differs slightly from the target.
    let bucketsPerSecond: Double
    let peaks: [Float]
    let levels: [Float]
    let lows: [Float]
    let mids: [Float]
    let highs: [Float]

    init(duration: TimeInterval, bucketsPerSecond: Double, peaks: [Float], levels: [Float], lows: [Float], mids: [Float], highs: [Float]) {
        self.duration = duration
        self.bucketsPerSecond = bucketsPerSecond
        self.peaks = peaks
        self.levels = levels
        self.lows = lows
        self.mids = mids
        self.highs = highs
    }

    var bucketCount: Int { levels.count }
}

actor WaveformAnalyzer {
    static let shared = WaveformAnalyzer()

    private static let lowCrossover: Double = 200
    private static let highCrossover: Double = 2_500
    private static let cacheLimit = 4

    private var cache: [(path: String, modifiedAt: Date?, data: WaveformData)] = []

    func waveform(for url: URL) throws -> WaveformData {
        let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let hit = cache.first(where: { $0.path == url.path && $0.modifiedAt == modifiedAt }) {
            return hit.data
        }

        let data = try Self.analyze(url: url)
        cache.removeAll { $0.path == url.path }
        cache.append((url.path, modifiedAt, data))
        if cache.count > Self.cacheLimit {
            cache.removeFirst(cache.count - Self.cacheLimit)
        }
        return data
    }

    private static func analyze(url: URL) throws -> WaveformData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let samplesPerBucket = max(1, Int((sampleRate / WaveformData.targetBucketsPerSecond).rounded()))
        let chunkFrames = AVAudioFrameCount(samplesPerBucket * 1024)

        guard channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              var lowFilter = makeBiquad(lowpass(lowCrossover, sampleRate: sampleRate), sections: 1),
              var midFilter = makeBiquad(highpass(lowCrossover, sampleRate: sampleRate) + lowpass(highCrossover, sampleRate: sampleRate), sections: 2),
              var highFilter = makeBiquad(highpass(highCrossover, sampleRate: sampleRate), sections: 1) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let expectedBuckets = Int(file.length) / samplesPerBucket + 1
        var peaks: [Float] = []
        var levels: [Float] = []
        var lows: [Float] = []
        var mids: [Float] = []
        var highs: [Float] = []
        peaks.reserveCapacity(expectedBuckets)
        levels.reserveCapacity(expectedBuckets)
        lows.reserveCapacity(expectedBuckets)
        mids.reserveCapacity(expectedBuckets)
        highs.reserveCapacity(expectedBuckets)

        var mono = [Float](repeating: 0, count: Int(chunkFrames))
        var bucketFill = 0
        var peak: Float = 0
        var levelSquares: Float = 0
        var lowSquares: Float = 0
        var midSquares: Float = 0
        var highSquares: Float = 0

        func emitBucket() {
            let count = Float(max(bucketFill, 1))
            peaks.append(peak)
            levels.append((levelSquares / count).squareRoot())
            lows.append((lowSquares / count).squareRoot())
            mids.append((midSquares / count).squareRoot())
            highs.append((highSquares / count).squareRoot())
            bucketFill = 0
            peak = 0
            levelSquares = 0
            lowSquares = 0
            midSquares = 0
            highSquares = 0
        }

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }

            mono.withUnsafeMutableBufferPointer { destination in
                guard let base = destination.baseAddress else { return }
                base.update(from: channels[0], count: frames)
                for channel in 1..<channelCount {
                    vDSP_vadd(base, 1, channels[channel], 1, base, 1, vDSP_Length(frames))
                }
                if channelCount > 1 {
                    var scale = 1 / Float(channelCount)
                    vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frames))
                }
            }

            let input = mono[0..<frames]
            let low = lowFilter.apply(input: input)
            let mid = midFilter.apply(input: input)
            let high = highFilter.apply(input: input)

            var offset = 0
            while offset < frames {
                let count = min(samplesPerBucket - bucketFill, frames - offset)
                let range = offset..<(offset + count)
                peak = max(peak, vDSP.maximumMagnitude(mono[range]))
                levelSquares += vDSP.sumOfSquares(mono[range])
                lowSquares += vDSP.sumOfSquares(low[range])
                midSquares += vDSP.sumOfSquares(mid[range])
                highSquares += vDSP.sumOfSquares(high[range])
                bucketFill += count
                offset += count
                if bucketFill == samplesPerBucket {
                    emitBucket()
                }
            }
        }

        if bucketFill > 0 {
            emitBucket()
        }

        let loudestBand = zip(lows, zip(mids, highs)).map { max($0, $1.0, $1.1) }
        let bandReference = percentile(loudestBand, 0.98)

        return WaveformData(
            duration: Double(file.length) / sampleRate,
            bucketsPerSecond: sampleRate / Double(samplesPerBucket),
            peaks: normalized(peaks, percentile: 0.995),
            levels: normalized(levels, percentile: 0.995),
            lows: smoothed(vDSP.clip(vDSP.divide(lows, bandReference), to: 0...1)),
            mids: smoothed(vDSP.clip(vDSP.divide(mids, bandReference), to: 0...1)),
            highs: smoothed(vDSP.clip(vDSP.divide(highs, bandReference), to: 0...1))
        )
    }

    /// Centered moving average; `radius` buckets on each side (20 at 400/s is about 100 ms total).
    private static func smoothed(_ values: [Float], radius: Int = 20) -> [Float] {
        guard values.count > 1 else { return values }
        var prefix = [Float](repeating: 0, count: values.count + 1)
        for index in values.indices {
            prefix[index + 1] = prefix[index] + values[index]
        }
        return values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count, index + radius + 1)
            return (prefix[upper] - prefix[lower]) / Float(upper - lower)
        }
    }

    /// Scales so the given percentile maps to 1, so a few spikes don't flatten loud masters.
    private static func normalized(_ values: [Float], percentile fraction: Double) -> [Float] {
        let reference = percentile(values, fraction)
        guard reference > 0 else { return values }
        return vDSP.clip(vDSP.divide(values, reference), to: 0...1)
    }

    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return max(sorted[Int(Double(sorted.count - 1) * fraction)], .leastNonzeroMagnitude)
    }

    private static func makeBiquad(_ coefficients: [Double], sections: Int) -> vDSP.Biquad<Float>? {
        vDSP.Biquad(
            coefficients: coefficients,
            channelCount: 1,
            sectionCount: vDSP_Length(sections),
            ofType: Float.self
        )
    }

    // RBJ cookbook biquads, normalized to [b0, b1, b2, a1, a2].
    private static func lowpass(_ frequency: Double, sampleRate: Double, q: Double = 0.7071) -> [Double] {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        return [(1 - cosine) / 2 / a0, (1 - cosine) / a0, (1 - cosine) / 2 / a0, -2 * cosine / a0, (1 - alpha) / a0]
    }

    private static func highpass(_ frequency: Double, sampleRate: Double, q: Double = 0.7071) -> [Double] {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        return [(1 + cosine) / 2 / a0, -(1 + cosine) / a0, (1 + cosine) / 2 / a0, -2 * cosine / a0, (1 - alpha) / a0]
    }
}
