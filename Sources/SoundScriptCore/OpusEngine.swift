import Foundation
import os

/// Uygulamanın kullanabileceği çeviri motorları.
public enum TranslationEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Apple'ın cihaz üstü çevirisi: kurulum yok, dil paketini sistem indirir
    case apple
    /// Helsinki-NLP opus-mt-tc-big (CTranslate2): EN↔TR'ye özel, ~470 MB/yön
    case opus

    public var id: Self { self }

    public var label: String {
        switch self {
        case .apple: "Apple Translation"
        case .opus: "opus-mt (EN↔TR)"
        }
    }
}

extension TranslationEngine {
    /// Seçili motorla çevirir. opus bu dil çiftini desteklemiyorsa Apple'a düşer.
    /// - Parameter progress: 0…1 arası ilerleme; çeviri sırasında çağrılır.
    public func translate(
        _ transcript: Transcript,
        to target: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranslatedTranscript {
        if self == .opus, OpusEngine.pair(from: transcript.language, to: target) != nil {
            return try await OpusEngine.translate(transcript, to: target, progress: progress)
        }
        return try await Translator().translate(transcript, to: target, progress: progress)
    }
}

/// opus-mt-tc-big modellerini Python + CTranslate2 ile çalıştırır.
/// CTranslate2'nin Swift bağlayıcısı yok; küçük bir Python köprüsü en sağlam yol.
/// Her şey Storage.root/opus altında durur: venv (~56 MB) + yön başına model (~470 MB).
public enum OpusEngine {
    public struct Pair: Sendable, Hashable {
        public let source: String
        public let target: String
        let repo: String
        /// Üçüncü taraf dönüşüm: sonradan değişmesin diye commit'e sabitli
        let revision: String

        public var id: String { "\(source)-\(target)" }

        public static let enTr = Pair(
            source: "en", target: "tr",
            repo: "ooeoeo/opus-mt-tc-big-en-tr-ct2-float16",
            revision: "4729dd2c625df6a5782d0a2225a36b14d52925b0"
        )
        public static let trEn = Pair(
            source: "tr", target: "en",
            repo: "ooeoeo/opus-mt-tc-big-tr-en-ct2-float16",
            revision: "22e01c5dbf6da0e9ac7f49ec4a25266ff28effe6"
        )
        public static let all: [Pair] = [.enTr, .trEn]
    }

    static let files = ["model.bin", "config.json", "shared_vocabulary.json", "source.spm", "target.spm"]
    static let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]

    public static var root: URL { Storage.root.appending(path: "opus", directoryHint: .isDirectory) }
    static var venvPython: URL { root.appending(path: "venv/bin/python") }
    static var script: URL { root.appending(path: "opus_translate.py") }

    static func folder(_ pair: Pair) -> URL { root.appending(path: pair.id, directoryHint: .isDirectory) }

    public static func pair(from source: String, to target: String) -> Pair? {
        Pair.all.first { source.hasPrefix($0.source) && target.hasPrefix($0.target) }
    }

    public static var isRuntimeInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: venvPython.path)
    }

    public static func isInstalled(_ pair: Pair) -> Bool {
        isRuntimeInstalled && files.allSatisfy {
            FileManager.default.fileExists(atPath: folder(pair).appending(path: $0).path)
        }
    }

    public static var isInstalled: Bool { Pair.all.allSatisfy(isInstalled) }

    // MARK: Kurulum

    /// Python ortamını ve iki yönün modelini kurar. İlerleme 0…1.
    @concurrent
    public static func install(onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        try Storage.ensure(root)
        try source.write(to: script, atomically: true, encoding: .utf8)

        if !isRuntimeInstalled {
            onProgress(0, "Python ortamı kuruluyor…")
            guard let python = pythonCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                throw SoundScriptError.downloadFailed("python3 bulunamadı. Kur: xcode-select --install")
            }
            try run(python, ["-m", "venv", root.appending(path: "venv").path])
            try run(venvPython.path, ["-m", "pip", "install", "-q", "--disable-pip-version-check", "ctranslate2", "sentencepiece"])
        }

        let pending = Pair.all.filter { !isInstalled($0) }
        for (index, pair) in pending.enumerated() {
            let destination = try Storage.ensure(folder(pair))
            for file in files where !FileManager.default.fileExists(atPath: destination.appending(path: file).path) {
                let url = URL(string: "https://huggingface.co/\(pair.repo)/resolve/\(pair.revision)/\(file)")!
                let label = "\(pair.source.uppercased())→\(pair.target.uppercased()) modeli indiriliyor…"
                try await FileDownload.fetch(url, to: destination.appending(path: file)) { fraction in
                    // model.bin dosyaların neredeyse tamamı; ilerlemeyi ona göre say
                    let share = file == "model.bin" ? fraction : 0
                    onProgress(0.05 + 0.95 * (Double(index) + share) / Double(pending.count), label)
                }
            }
        }
        onProgress(1, "Hazır")
    }

    public static func uninstall() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    // MARK: Çeviri

    @concurrent
    public static func translate(
        _ transcript: Transcript,
        to target: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranslatedTranscript {
        guard let pair = pair(from: transcript.language, to: target) else {
            throw SoundScriptError.translationUnsupported(from: transcript.language, to: target)
        }
        guard isInstalled(pair) else { throw SoundScriptError.opusNotInstalled }
        // Betik her çağrıda tazelenir: eski kurulumlar yeni ayarları (beam, partiler) almasın.
        try source.write(to: script, atomically: true, encoding: .utf8)

        struct Payload: Codable { let lines: [String] }
        let input = try JSONEncoder().encode(Payload(lines: transcript.segments.map(\.text)))
        let total = transcript.segments.count
        let done = OSAllocatedUnfairLock(initialState: 0)

        let output = try run(venvPython.path, [script.path, folder(pair).path], input: input) { line in
            // Betik stderr'e "PROGRESS\t<biten satır sayısı>" yazar.
            guard let value = line.split(separator: "\t").last, let count = Int(value), total > 0 else { return }
            let current = done.withLock { value -> Int in
                value = max(value, count)
                return value
            }
            progress?(Double(current) / Double(total))
        }
        let lines = try JSONDecoder().decode(Payload.self, from: output).lines

        let segments = transcript.segments.enumerated().map { index, segment in
            Segment(start: segment.start, end: segment.end, text: lines[safe: index] ?? segment.text)
        }
        return TranslatedTranscript(source: transcript, language: target, segments: segments, engine: TranslationEngine.opus.label)
    }

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) throws -> Data {
        var onStderr: (@Sendable (Data) -> Void)?
        if let onStderrLine {
            let splitter = LineSplitter(handler: onStderrLine)
            onStderr = { data in splitter.feed(data) }
        }
        let result = try ProcessRunner.run(
            executable,
            arguments,
            input: input,
            onStderr: onStderr
        )
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            throw SoundScriptError.downloadFailed(message.isEmpty ? "\(executable) çıkış kodu \(result.status)" : message)
        }
        return result.stdout
    }

    /// Kurulumda diske yazılan köprü betiği.
    static let source = #"""
    """SoundScript opus-mt köprüsü: stdin'den JSON satır listesi alır, çevirileri JSON olarak yazar.

    Kullanım: python opus_translate.py <model_klasörü>
    Girdi:  {"lines": ["Hello.", "..."]}
    Çıktı:  {"lines": ["Merhaba.", "..."]}

    İlerleme stderr'e satır satır yazılır: "PROGRESS\t<biten satır sayısı>"
    """
    import json
    import os
    import sys

    import ctranslate2
    import sentencepiece as spm

    # beam 2, beam 4'ün yarı sürede benzer kalitede sonuç veriyor
    # (ölçüm: 1000 satırda 100 sn -> 49 sn)
    BEAM_SIZE = 2
    # Küçük partiler: ilerleme görünür olsun, bellek tepe değeri düşük kalsın
    BATCH_SIZE = 25


    def main() -> None:
        model_dir = sys.argv[1]
        source = spm.SentencePieceProcessor(model_file=os.path.join(model_dir, "source.spm"))
        target = spm.SentencePieceProcessor(model_file=os.path.join(model_dir, "target.spm"))
        # float16 ağırlıklar CPU'da int8'e çevrilerek yüklenir: daha az bellek, daha hızlı
        translator = ctranslate2.Translator(model_dir, device="cpu", compute_type="int8", inter_threads=1)

        lines = json.load(sys.stdin)["lines"]
        batch = [source.encode(line, out_type=str) + ["</s>"] for line in lines]

        out = []
        done = 0
        for start in range(0, len(batch), BATCH_SIZE):
            chunk = batch[start:start + BATCH_SIZE]
            results = translator.translate_batch(
                chunk,
                beam_size=BEAM_SIZE,
                max_decoding_length=256,
                repetition_penalty=1.1,
            )
            out.extend(target.decode(result.hypotheses[0]).strip() for result in results)
            done += len(chunk)
            print(f"PROGRESS\t{done}", file=sys.stderr, flush=True)

        json.dump({"lines": out}, sys.stdout, ensure_ascii=False)


    if __name__ == "__main__":
        main()
    """#
}

/// stderr'den gelen baytları satırlara böler: bir bayt paketi satırın ortasında
/// bitmiş olabilir, satır sınırı paket sınırıyla çakışmaz.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func feed(_ data: Data) {
        lock.lock()
        pending += String(decoding: data, as: UTF8.self)
        let parts = pending.split(separator: "\n", omittingEmptySubsequences: false)
        pending = parts.last.map(String.init) ?? ""
        let complete = parts.dropLast()
        lock.unlock()
        for line in complete { handler(String(line)) }
    }
}

/// İlerleme bildiren tek dosya indirme (URLSession download task + delegate).
enum FileDownload {
    static func fetch(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Delegate(onProgress: onProgress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SoundScriptError.downloadFailed("\(url.lastPathComponent): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        onProgress(1)
    }

    final class Delegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let onProgress: @Sendable (Double) -> Void
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        // async download(from:delegate:) dosyayı kendisi döndürür; bu çağrı yalnızca protokol için
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
