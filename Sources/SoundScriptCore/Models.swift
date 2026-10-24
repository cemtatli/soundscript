import Foundation

public struct Segment: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct Transcript: Codable, Sendable {
    /// ISO 639-1 kodu ("en", "tr")
    public var language: String
    public var segments: [Segment]
    public var model: String

    public init(language: String, segments: [Segment], model: String) {
        self.language = language
        self.segments = segments
        self.model = model
    }
}

public struct TranslatedTranscript: Codable, Sendable {
    public var source: Transcript
    public var language: String
    /// `source.segments` ile aynı sıra ve zamanlar
    public var segments: [Segment]
    public var engine: String
}

public enum SoundScriptError: LocalizedError {
    case noAudioTrack(URL)
    case decodeFailed(String)
    case noSpeech
    case translationUnsupported(from: String, to: String)
    case translationNotInstalled(from: String, to: String)
    case downloaderMissing
    case opusNotInstalled
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack(let url):
            "Dosyada ses kanalı yok: \(url.lastPathComponent)"
        case .decodeFailed(let reason):
            "Ses çözülemedi: \(reason)"
        case .noSpeech:
            "Konuşma bulunamadı (müzik ya da sessizlik olabilir)."
        case .translationUnsupported(let from, let to):
            "Bu cihazda \(from) → \(to) çevirisi desteklenmiyor."
        case .translationNotInstalled(let from, let to):
            """
            \(from) → \(to) çeviri dili indirilmemiş.
            Sistem Ayarları → Genel → Dil ve Bölge → Çeviri Dilleri'nden \(to) dilini indir, sonra tekrar dene.
            """
        case .opusNotInstalled:
            "opus-mt modelleri kurulu değil. Ayarlar'dan kur ya da: soundscript models --opus"
        case .downloaderMissing:
            "yt-dlp bulunamadı. Kur: brew install yt-dlp"
        case .downloadFailed(let reason):
            "İndirilemedi: \(reason)"
        }
    }
}
