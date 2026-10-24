import Foundation

/// SRT için okunabilir altyazı üretir: uzun cümleleri sığdırır, satırları
/// dengeli böler ve zamanı karakter sayısına göre paylaştırır. Transkript
/// metnini değiştirmez; yalnızca dışa aktarımda kullanılır.
public enum SubtitleFormatter {
    public struct Cue: Sendable, Hashable {
        public let start: Double
        public let end: Double
        public let text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    static let maxLineLength = 42
    static let maxLines = 2
    static let maxCueLength = maxLineLength * maxLines
    static let terminal: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let cjkTerminal: Set<Character> = ["。", "！", "？"]
    static let closing: Set<Character> = ["\"", "'", "”", "’", ")", "]"]

    public static func cues(_ segments: [Segment]) -> [Cue] {
        segments.flatMap(cues(for:))
    }

    static func cues(for segment: Segment) -> [Cue] {
        let text = normalize(segment.text)
        guard !text.isEmpty else { return [] }

        let start = max(0, segment.start)
        let end = segment.end > start ? segment.end : start + 2
        let duration = end - start

        let groups = group(splitLongPieces(sentences(text)))
        guard !groups.isEmpty else { return [] }

        let total = max(1, groups.reduce(0) { $0 + $1.count })
        var consumed = 0
        var cues: [Cue] = []
        for (index, group) in groups.enumerated() {
            let lower = Double(consumed) / Double(total)
            consumed += group.count
            let upper = Double(consumed) / Double(total)
            let cueStart = index == 0 ? start : start + duration * lower
            let cueEnd = index == groups.count - 1 ? end : start + duration * upper
            cues.append(Cue(start: cueStart, end: max(cueStart, cueEnd), text: wrap(group)))
        }
        return cues
    }

    /// Noktalama + boşluktan cümle sınırı çıkarır. "3.14" gibi durumlarda
    /// noktadan sonra boşluk olmadığı için bölmez.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var sentenceStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            guard terminal.contains(text[index]) else {
                index = text.index(after: index)
                continue
            }

            var after = text.index(after: index)
            while after < text.endIndex, closing.contains(text[after]) {
                after = text.index(after: after)
            }
            // Latin noktalamasında boşluk şart; CJK'da cümleler boşluksuz biter.
            let isCJK = cjkTerminal.contains(text[index])
            if !isCJK {
                guard after < text.endIndex, text[after].isWhitespace else {
                    index = text.index(after: index)
                    continue
                }
            }

            let sentence = text[sentenceStart..<after].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }

            while after < text.endIndex, text[after].isWhitespace {
                after = text.index(after: after)
            }
            sentenceStart = after
            index = after
        }

        let rest = text[sentenceStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// Tek bir cümle iki satıra sığmıyorsa kelime sınırından parçalar.
    static func splitLongPieces(_ pieces: [String]) -> [String] {
        pieces.flatMap { piece in
            guard piece.count > maxCueLength else { return [piece] }
            var result: [String] = []
            var line = ""
            for word in piece.split(whereSeparator: \.isWhitespace) {
                if !line.isEmpty {
                    let candidate = "\(line) \(word)"
                    if candidate.count <= maxCueLength {
                        line = candidate
                        continue
                    }
                    result.append(line)
                    line = ""
                }

                if word.count > maxCueLength {
                    var start = word.startIndex
                    while start < word.endIndex {
                        let end = word.index(start, offsetBy: maxCueLength, limitedBy: word.endIndex) ?? word.endIndex
                        result.append(String(word[start..<end]))
                        start = end
                    }
                } else {
                    line = String(word)
                }
            }
            if !line.isEmpty { result.append(line) }
            return result
        }
    }

    /// Kısa parçaları tekrar iki satırlık bir cue'da toplar.
    static func group(_ pieces: [String]) -> [String] {
        var result: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : "\(current) \(piece)"
            if candidate.count <= maxCueLength {
                current = candidate
            } else {
                if !current.isEmpty { result.append(current) }
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// İki satırı mümkünse eşit uzunlukta böler; tek kelime taşarsa yine de
    /// metni kaybetmez.
    static func wrap(_ text: String) -> String {
        guard text.count > maxLineLength else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return text }

        var best: (index: Int, score: Int)?
        for index in 1..<words.count {
            let first = words[..<index].joined(separator: " ")
            let second = words[index...].joined(separator: " ")
            guard first.count <= maxLineLength, second.count <= maxLineLength else { continue }
            let score = abs(first.count - second.count)
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }

        if let best {
            return words[..<best.index].joined(separator: " ") + "\n" + words[best.index...].joined(separator: " ")
        }

        // İki satıra sığmayan tek uzun kelime: taşan kısmı ikinci satıra koy.
        let split = text.index(text.startIndex, offsetBy: maxLineLength)
        let first = text[..<split].trimmingCharacters(in: .whitespaces)
        let second = text[split...].trimmingCharacters(in: .whitespaces)
        return second.isEmpty ? first : "\(first)\n\(second)"
    }

    static func normalize(_ text: String) -> String {
        text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
