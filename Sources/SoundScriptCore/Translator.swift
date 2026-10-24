import Foundation
@preconcurrency import Translation

/// Apple'ın cihaz üstü Translation framework'ü. macOS 26.4+ üzerinde
/// `.highFidelity` stratejisi daha kaliteli (daha yavaş) modeli seçer.
public struct Translator: Sendable {
    public let quality: Quality

    public enum Quality: String, Sendable, CaseIterable {
        case fast
        case high
    }

    public init(quality: Quality = .high) {
        self.quality = quality
    }

    public func translate(
        _ transcript: Transcript,
        to target: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranslatedTranscript {
        let source = Locale.Language(identifier: transcript.language)
        let destination = Locale.Language(identifier: target)

        let status = await LanguageAvailability().status(from: source, to: destination)
        switch status {
        case .unsupported:
            throw SoundScriptError.translationUnsupported(from: transcript.language, to: target)
        case .supported:
            throw SoundScriptError.translationNotInstalled(from: transcript.language, to: target)
        case .installed:
            break
        @unknown default:
            break
        }

        let session = makeSession(source: source, target: destination)
        let segments = transcript.segments
        var byIndex: [Int: String] = [:]

        // Satırları parçala: tek seferde binlerce istek hem bellek hem gecikme
        // demek; parçalar sayesinde ilerleme de görünür oluyor.
        let batchSize = 40
        for start in stride(from: 0, to: segments.count, by: batchSize) {
            let end = min(start + batchSize, segments.count)
            let requests = (start..<end).map { index in
                TranslationSession.Request(sourceText: segments[index].text, clientIdentifier: String(index))
            }
            let responses = try await session.translations(from: requests)
            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id) {
                    byIndex[index] = response.targetText
                }
            }
            if segments.count > 0 {
                progress?(Double(end) / Double(segments.count))
            }
        }

        let translated = segments.enumerated().map { index, segment in
            let text = byIndex[index].map { Self.matchCase(source: segment.text, output: $0, language: target) }
            return Segment(start: segment.start, end: segment.end, text: text ?? segment.text)
        }

        return TranslatedTranscript(
            source: transcript,
            language: target,
            segments: translated,
            engine: "Apple Translation (\\(quality.rawValue))"
        )
    }

    private func makeSession(source: Locale.Language, target: Locale.Language) -> TranslationSession {
        if #available(macOS 26.4, *) {
            return TranslationSession(
                installedSource: source,
                target: target,
                preferredStrategy: quality == .high ? .highFidelity : .lowLatency
            )
        }
        return TranslationSession(installedSource: source, target: target)
    }

    /// Çevirmen bazen cümle başını küçük bırakıyor ("iptal et.").
    static func matchCase(source: String, output: String, language: String) -> String {
        guard let first = source.first, first.isUppercase, let head = output.first, head.isLowercase else {
            return output
        }
        let locale = Locale(identifier: language)
        return head.description.uppercased(with: locale) + output.dropFirst()
    }
}
