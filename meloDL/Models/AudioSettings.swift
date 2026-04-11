import Foundation

struct AudioSettings: Equatable {
    var format: AudioFormat
    var quality: AudioQuality
    var embedMetadata: Bool
    var embedThumbnail: Bool

    init(
        format: AudioFormat = .mp3,
        quality: AudioQuality = .high,
        embedMetadata: Bool = true,
        embedThumbnail: Bool = false
    ) {
        self.format = format
        self.quality = quality
        self.embedMetadata = embedMetadata
        self.embedThumbnail = embedThumbnail
    }
}

enum AudioFormat: String, CaseIterable {
    case mp3 = "mp3"
    case wav = "wav"
    case m4a = "m4a"
    case flac = "flac"
    case ogg = "vorbis"

    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .m4a: return "M4A"
        case .flac: return "FLAC"
        case .ogg: return "OGG"
        }
    }

    var supportsThumbnailEmbed: Bool {
        self == .mp3 || self == .m4a || self == .flac
    }
}

enum AudioQuality: String, CaseIterable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var ytdlpValue: String {
        switch self {
        case .high: return "0"
        case .medium: return "5"
        case .low: return "10"
        }
    }

    var displayName: String { rawValue }
}
