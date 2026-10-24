import Foundation

public enum ExportFormat: String, CaseIterable, Sendable {
    case srt, txt, md, json
}

public enum Exporter {
    public static func srt(_ segments: [Segment]) -> String {
        SubtitleFormatter.cues(segments).enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func txt(_ segments: [Segment]) -> String {
        segments.map(\.text).joined(separator: "\n") + "\n"
    }

    /// Orijinal ve çeviriyi yan yana tablo olarak yazar.
    public static func markdown(_ transcript: Transcript, translation: TranslatedTranscript?) -> String {
        var lines = ["| Zaman | \(transcript.language.uppercased()) |" + (translation.map { " \($0.language.uppercased()) |" } ?? "")]
        lines.append("| --- | --- |" + (translation == nil ? "" : " --- |"))
        for (index, segment) in transcript.segments.enumerated() {
            var row = "| \(clock(segment.start)) | \(escape(segment.text)) |"
            if let translation { row += " \(escape(translation.segments[safe: index]?.text ?? "")) |" }
            lines.append(row)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(_ transcript: Transcript, translation: TranslatedTranscript?) throws -> String {
        struct Payload: Encodable {
            let transcript: Transcript
            let translation: TranslatedTranscript?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Payload(transcript: transcript, translation: translation))
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func timestamp(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
    }

    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func escape(_ text: String) -> String {
        text.replacing("|", with: "\\|")
    }
}

extension Array {
    public subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
