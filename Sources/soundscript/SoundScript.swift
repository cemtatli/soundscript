import ArgumentParser
import SoundScriptCore
import Foundation

@main
struct SoundScript: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "soundscript",
        abstract: "Video → transkript → çeviri. Tamamen bu Mac'te çalışır.",
        subcommands: [Run.self, Models.self],
        defaultSubcommand: Run.self
    )
}

extension ExportFormat: ExpressibleByArgument {}
extension Translator.Quality: ExpressibleByArgument {}
extension TranslationEngine: ExpressibleByArgument {}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dosyayı ya da bağlantıyı işle.")

    @Argument(help: "Video/ses dosyası ya da bağlantı (yt-dlp ile indirilir).")
    var input: String

    @Option(name: .shortAndLong, help: "Çeviri dili (örn. tr, en). Boşsa: kaynak Türkçeyse en, değilse tr.")
    var to: String?

    @Flag(name: .long, help: "Çeviri yapma, sadece transkript.")
    var noTranslate = false

    @Option(name: .shortAndLong, help: "Kaynak dili zorla (en, tr…). Boşsa algılanır.")
    var language: String?

    @Option(name: .shortAndLong, help: "Çıktı biçimi: \(ExportFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var format: ExportFormat = .srt

    @Option(name: .shortAndLong, help: "Çıktı klasörü. Boşsa dosyanın yanına yazar.")
    var output: String?

    @Option(help: "Çeviri motoru: apple, opus (EN↔TR, önce: soundscript models --opus).")
    var engine: TranslationEngine = .apple

    @Option(help: "Apple çeviri kalitesi: fast, high.")
    var quality: Translator.Quality = .high

    @Flag(help: "Küçük Whisper modelini kullan (daha hızlı, daha az doğru).")
    var small = false

    @Flag(name: .long, help: "En doğru Whisper modelini kullan (large-v3, ~1.6 GB; 16 GB+).")
    var best = false

    func validate() throws {
        if small && best { throw ValidationError("--small ve --best birlikte kullanılamaz.") }
    }

    func run() async throws {
        // Önceki adlarla ("Altyazı", "Dalga", "clipX") kurulmuş model verisi (~1,6 GB) yeni konuma taşınır.
        Storage.migrateLegacyStorage()
        let source: URL
        if Downloader.isURL(input) {
            log("İndiriliyor: \(input)")
            source = try await Downloader.download(input)
            log("İndirildi: \(source.lastPathComponent)")
        } else {
            source = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        }

        let started = Date()
        log("Ses çözülüyor…")

        let model = small ? TranscriberModel.small : best ? .bestQuality : .recommended
        let transcriber = Transcriber(model: model)
        if !transcriber.isDownloaded {
            log("\(transcriber.model.label) indiriliyor (bir kez)…")
        }
        let downloading = !transcriber.isDownloaded

        // Ses çözme ve model hazırlığı paralel; soğuk açılışta bekleme süresini kısaltır.
        async let samplesTask = AudioDecoder.loadMono16k(source)
        async let prepareTask: Void = transcriber.prepare { progress in
            log(String(format: "  %%%.0f", progress * 100), sameLine: true)
        }
        var samples = try await samplesTask
        try await prepareTask
        if downloading { log("") }
        let duration = Double(samples.count) / Double(AudioDecoder.sampleRate)

        log("Metne dökülüyor (\(Exporter.clock(duration)))…")
        let transcript = try await transcriber.transcribe(samples: samples, language: language) { progress in
            log(String(format: "  %%%.0f", progress * 100), sameLine: true)
        }
        // Ham ses (1 saatlik video için 225 MB) çeviri sırasında boşuna durmasın.
        samples = []
        log("")
        log("\(transcript.segments.count) satır · dil: \(transcript.language)")

        // Çeviri başarısız olsa bile transkript dosyası yazılır.
        var translation: TranslatedTranscript?
        var translationError: Error?
        if !noTranslate {
            let target = to ?? (transcript.language.hasPrefix("tr") ? "en" : "tr")
            if target != transcript.language {
                log("Çevriliyor: \(transcript.language) → \(target)…")
                do {
                    translation = engine == .apple
                        ? try await Translator(quality: quality).translate(transcript, to: target) { fraction in
                            logProgress(fraction)
                        }
                        : try await engine.translate(transcript, to: target) { fraction in
                            logProgress(fraction)
                        }
                } catch {
                    translationError = error
                }
            }
        }

        let written = try write(transcript: transcript, translation: translation, source: source)
        log(String(format: "Bitti (%.1f sn):", Date().timeIntervalSince(started)))
        written.forEach { print($0.path) }

        if let translationError {
            log("\nÇeviri yapılamadı: \(translationError.localizedDescription)")
            if case SoundScriptError.translationNotInstalled = translationError {
                openTranslationSettings()
            }
            throw ExitCode.failure
        }
    }

    private func write(transcript: Transcript, translation: TranslatedTranscript?, source: URL) throws -> [URL] {
        let directory = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? source.deletingLastPathComponent()
        try Storage.ensure(directory)
        let base = directory.appending(path: source.deletingPathExtension().lastPathComponent)

        var files: [(URL, String)] = []
        switch format {
        case .srt:
            files.append((base.appendingPathExtension("srt"), Exporter.srt(transcript.segments)))
            if let translation {
                files.append((base.appendingPathExtension("\(translation.language).srt"), Exporter.srt(translation.segments)))
            }
        case .txt:
            files.append((base.appendingPathExtension("txt"), Exporter.txt(transcript.segments)))
            if let translation {
                files.append((base.appendingPathExtension("\(translation.language).txt"), Exporter.txt(translation.segments)))
            }
        case .md:
            files.append((base.appendingPathExtension("md"), Exporter.markdown(transcript, translation: translation)))
        case .json:
            files.append((base.appendingPathExtension("json"), try Exporter.json(transcript, translation: translation)))
        }

        for (url, contents) in files {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return files.map(\.0)
    }
}

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Modelleri önceden indir ve durumu göster.")

    @Flag(help: "Küçük Whisper modelini indir.")
    var small = false

    @Flag(name: .long, help: "En doğru Whisper modelini indir (large-v3, ~1.6 GB).")
    var best = false

    @Flag(help: "opus-mt EN↔TR çeviri modellerini kur (~950 MB + Python ortamı).")
    var opus = false

    func validate() throws {
        if small && best { throw ValidationError("--small ve --best birlikte kullanılamaz.") }
    }

    func run() async throws {
        Storage.migrateLegacyStorage()
        if opus {
            if OpusEngine.isInstalled {
                log("opus-mt hazır: \(OpusEngine.root.path)")
                return
            }
            try await OpusEngine.install { progress, message in
                log(String(format: "  %%%3.0f  %@", progress * 100, message), sameLine: true)
            }
            log("\nopus-mt hazır.")
            return
        }
        log("Konum: \(Storage.models.path)")
        for model in TranscriberModel.all {
            let state = Transcriber(model: model).isDownloaded ? "indirildi" : "yok"
            log("  \(model.label): \(state)")
        }
        let model = small ? TranscriberModel.small : best ? .bestQuality : .recommended
        let transcriber = Transcriber(model: model)
        if transcriber.isDownloaded {
            log("\(transcriber.model.label) hazır.")
            return
        }
        log("\(transcriber.model.label) indiriliyor…")
        try await transcriber.prepare { progress in
            log(String(format: "  %%%.0f", progress * 100), sameLine: true)
        }
        log("\nHazır.")
    }
}

/// Çeviri dilleri yalnızca Sistem Ayarları'ndan (ya da bir arayüzden) indirilebilir; CLI'dan kurulamaz.
func openTranslationSettings() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["x-apple.systempreferences:com.apple.Localization-Settings.extension"]
    try? process.run()
}

/// Bilgi satırları stderr'e gider; stdout yalnızca yazılan dosya yollarıdır (betiklerde kullanılabilir).
func log(_ message: String, sameLine: Bool = false) {
    let line = sameLine ? "\r\(message)" : "\(message)\n"
    logLock.lock()
    FileHandle.standardError.write(Data(line.utf8))
    logLock.unlock()
}

/// Çeviri ilerlemesi: tek satırda yüzde. Aynı satıra defalarca yazılır.
func logProgress(_ fraction: Double) {
    let percent = Int((fraction * 100).rounded())
    guard percent % 2 == 0 else { return }
    log("  %\(percent)", sameLine: true)
}

private let logLock = NSLock()
