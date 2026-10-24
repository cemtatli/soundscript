import Foundation

/// Whisper bazen cümleyi ikiye böler ("Is this how you" + "normally pet sit?").
/// Cümle bazlı çevirmenler yarım cümlede bozulduğu için bitmemiş parçaları
/// bir sonrakiyle birleştiriyoruz. Tam cümlelere dokunmuyoruz.
///
/// Eski sürüm yalnızca 26 karakterden kısa parçaları birleştiriyordu; Whisper
/// 30–80 karakterlik yarım cümleler de ürettiği için çeviriye hâlâ kırık
/// cümleler gidiyordu. Artık sınır karakter değil, cümle sonu noktalaması.
public enum SegmentMerger {
    static let maxGap = 1.2
    static let maxLength = 240
    static let terminal = #"[.!?…。！？؟۔।॥።]["'”’»›)\]}】》」』]*$"#

    public static func merge(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var pending: Segment?

        for segment in segments {
            let text = collapse(segment.text)
            guard !text.isEmpty else { continue }
            let current = Segment(start: segment.start, end: segment.end, text: text)

            guard let previous = pending else {
                if isComplete(current.text) { out.append(current) } else { pending = current }
                continue
            }

            let joined = collapse("\(previous.text) \(current.text)")
            let gap = current.start - previous.end
            if gap <= maxGap, joined.count <= maxLength {
                let merged = Segment(
                    start: previous.start,
                    end: max(previous.end, current.end),
                    text: joined
                )
                if isComplete(merged.text) {
                    out.append(merged)
                    pending = nil
                } else {
                    pending = merged
                }
            } else {
                out.append(previous)
                pending = nil
                if isComplete(current.text) { out.append(current) } else { pending = current }
            }
        }

        if let pending { out.append(pending) }
        return out
    }

    /// Cümle sonu noktalaması yoksa parça sayılır. Uzunluk sınırı yok.
    static func isFragment(_ text: String) -> Bool {
        !isComplete(text)
    }

    static func isComplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.range(of: terminal, options: .regularExpression) != nil
    }

    private static func collapse(_ text: String) -> String {
        text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    }
}
