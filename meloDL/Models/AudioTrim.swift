import AVFoundation
import Foundation

struct TrimTarget: Identifiable, Equatable, Sendable {
    let id = UUID()
    let sessionID: UUID
    let fileURL: URL
    let title: String
    let format: AudioTrimFormat
}

/// Lossy formats are stream-copied so quality is untouched (cuts land on a codec frame boundary).
/// Lossless formats are re-encoded, which keeps them lossless and sample-accurate.
enum AudioTrimFormat: Sendable {
    case mp3
    case m4a
    case ogg
    case flac
    case wav

    init?(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "mp3": self = .mp3
        case "m4a": self = .m4a
        case "ogg", "oga": self = .ogg
        case "flac": self = .flac
        case "wav", "wave": self = .wav
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .m4a: return "M4A"
        case .ogg: return "OGG"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        }
    }

    var isStreamCopy: Bool {
        switch self {
        case .mp3, .m4a, .ogg: return true
        case .flac, .wav: return false
        }
    }

    /// Samples per codec frame for formats whose stream-copy cuts land on a fixed grid.
    var frameSampleCount: Int? {
        switch self {
        case .mp3: return 1152
        case .m4a: return 1024
        case .ogg, .flac, .wav: return nil
        }
    }

    var cutDescription: String {
        switch self {
        case .mp3: return "Lossless cut. Edges snap to MP3 frames (about 26 ms)."
        case .m4a: return "Lossless cut. Edges snap to AAC frames (about 23 ms)."
        case .ogg: return "Lossless cut. Edges land on the nearest Vorbis packet."
        case .flac, .wav: return "Sample-accurate lossless cut."
        }
    }

    func codecArguments(fileFormat: AVAudioFormat) -> [String] {
        switch self {
        case .mp3, .m4a, .ogg:
            return ["-c", "copy"]
        case .flac:
            return ["-c:a", "flac", "-c:v", "copy"]
        case .wav:
            return ["-c:a", Self.pcmCodec(for: fileFormat)]
        }
    }

    private static func pcmCodec(for format: AVAudioFormat) -> String {
        let bitDepth = format.settings[AVLinearPCMBitDepthKey] as? Int ?? 16
        let isFloat = format.settings[AVLinearPCMIsFloatKey] as? Bool ?? false
        if isFloat {
            return bitDepth == 64 ? "pcm_f64le" : "pcm_f32le"
        }
        switch bitDepth {
        case 8: return "pcm_u8"
        case 24: return "pcm_s24le"
        case 32: return "pcm_s32le"
        default: return "pcm_s16le"
        }
    }
}

enum AudioTrimError: LocalizedError {
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let message):
            return "ffmpeg failed: \(message)"
        }
    }
}
