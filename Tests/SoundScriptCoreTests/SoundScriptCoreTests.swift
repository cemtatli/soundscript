import Foundation
import Testing
@testable import SoundScriptCore

@Test func mergesFragmentsIntoNextSegment() {
    let merged = SegmentMerger.merge([
        Segment(start: 0, end: 1, text: "Is this how you"),
        Segment(start: 1.2, end: 2.5, text: "normally pet sit?"),
        Segment(start: 3, end: 4, text: "Cancel it."),
    ])
    #expect(merged.map(\.text) == ["Is this how you normally pet sit?", "Cancel it."])
    #expect(merged[0].start == 0 && merged[0].end == 2.5)
}

@Test func keepsFullSentencesSeparate() {
    let merged = SegmentMerger.merge([
        Segment(start: 0, end: 1, text: "Welcome home."),
        Segment(start: 1.1, end: 2, text: "Why are we outside?"),
    ])
    #expect(merged.count == 2)
}

@Test func mergesLongIncompleteClause() {
    let merged = SegmentMerger.merge([
        Segment(start: 0, end: 1, text: "This is a long clause without any ending punctuation at all"),
        Segment(start: 1.1, end: 2, text: "and it continues here."),
    ])
    #expect(merged == [
        Segment(start: 0, end: 2, text: "This is a long clause without any ending punctuation at all and it continues here."),
    ])
}

@Test func mergesCommaClause() {
    let merged = SegmentMerger.merge([
        Segment(start: 0, end: 1, text: "When the door opened,"),
        Segment(start: 1.1, end: 2, text: "everyone turned around."),
    ])
    #expect(merged.count == 1)
}

@Test func doesNotMergeAcrossLongGap() {
    let merged = SegmentMerger.merge([
        Segment(start: 0, end: 1, text: "An unfinished thought"),
        Segment(start: 3, end: 4, text: "A new sentence."),
    ])
    #expect(merged.count == 2)
}

@Test func splitsLongSubtitleIntoCues() {
    let text = "This is a very long sentence that should be split into readable subtitle lines because it exceeds the maximum cue width by a lot."
    let cues = SubtitleFormatter.cues([Segment(start: 0, end: 10, text: text)])
    #expect(cues.count >= 2)
    #expect(cues.first?.start == 0)
    #expect(cues.last?.end == 10)
    #expect(cues.allSatisfy { $0.text.split(separator: "\n").count <= 2 })
    #expect(cues.allSatisfy { $0.text.split(separator: "\n").allSatisfy { $0.count <= 42 } })
    #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
}

@Test func wrapsSubtitleLinesBalanced() {
    let wrapped = SubtitleFormatter.wrap("This line should be split into two balanced subtitle rows cleanly")
    let lines = wrapped.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines.allSatisfy { $0.count <= 42 })
}

@Test func splitsCJKSentencesWithoutSpaces() {
    #expect(SubtitleFormatter.sentences("你好。世界！") == ["你好。", "世界！"])
}

@Test func readsStdoutAndStderrWithoutDeadlock() throws {
    let result = try ProcessRunner.run("/bin/sh", ["-c", "printf out; printf err >&2"])
    #expect(result.status == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "out")
    #expect(String(decoding: result.stderr, as: UTF8.self) == "err")
}

@Test func writesProcessStdin() throws {
    let result = try ProcessRunner.run("/bin/cat", [], input: Data("hello".utf8))
    #expect(result.status == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "hello")
}

@Test func recommendedWhisperModelIsKnown() {
    #expect(TranscriberModel.all.contains(TranscriberModel.recommended))
    #expect(TranscriberModel.all.contains(TranscriberModel.bestQuality))
}

@Test func formatsSrt() {
    let srt = Exporter.srt([Segment(start: 4.2, end: 6.05, text: "Cancel it.")])
    #expect(srt == "1\n00:00:04,200 --> 00:00:06,050\nCancel it.\n")
}

@Test func stripsWhisperTokens() {
    #expect(Transcriber.clean("<|0.00|> Cancel it.<|2.00|>") == "Cancel it.")
    #expect(Transcriber.clean("- Can I get some water?") == "Can I get some water?")
}

@Test func capitalizesTurkishSentenceStart() {
    #expect(Translator.matchCase(source: "Cancel it.", output: "iptal et.", language: "tr") == "İptal et.")
}

