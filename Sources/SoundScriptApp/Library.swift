import SoundScriptCore
import Foundation
import Observation
import os
@preconcurrency import Translation

struct Job: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case queued, downloading, decoding, loadingModel, transcribing, translating, done, failed

        var label: String {
            switch self {
            case .queued: "Sırada"
            case .downloading: "İndiriliyor"
            case .decoding: "Ses çözülüyor"
            case .loadingModel: "Model hazırlanıyor"
            case .transcribing: "Metne dökülüyor"
            case .translating: "Çevriliyor"
            case .done: "Hazır"
            case .failed: "İşlenemedi"
            }
        }

        var isBusy: Bool { ![.queued, .done, .failed].contains(self) }
    }

    var id = UUID()
    var name: String
    /// Library klasöründeki kopya; bağlantılarda indirme bitene kadar nil
    var file: URL?
    var link: String?
    var status: Status = .queued
    var progress: Double?
    var error: String?
    var transcript: Transcript?
    var translation: TranslatedTranscript?
    var translationError: String?
    /// Çeviri dili kurulu değil: arayüz indirme isteği gösterir
    var needsLanguage: String?
    var createdAt = Date()
    var duration: Double?

    var isAudio: Bool {
        ["mp3", "m4a", "wav", "aac", "flac", "ogg", "opus"].contains(file?.pathExtension.lowercased() ?? "")
    }
}

extension Transcript: Hashable {
    public static func == (lhs: Transcript, rhs: Transcript) -> Bool {
        lhs.language == rhs.language && lhs.model == rhs.model && lhs.segments == rhs.segments
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(segments) }
}

extension TranslatedTranscript: Hashable {
    public static func == (lhs: TranslatedTranscript, rhs: TranslatedTranscript) -> Bool {
        lhs.language == rhs.language && lhs.engine == rhs.engine && lhs.segments == rhs.segments
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(segments) }
}

enum TranscriptionModelChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case best
    case fast

    var id: Self { self }

    var label: String {
        switch self {
        case .automatic: "Otomatik (cihaza göre)"
        case .best: "En doğru (large-v3; 16 GB+)"
        case .fast: "En hızlı (small, 216 MB)"
        }
    }

    var model: TranscriberModel {
        switch self {
        case .automatic: .recommended
        case .best: .bestQuality
        case .fast: .small
        }
    }
}

/// Kullanıcı tercihleri (UserDefaults). Görünümler aynı anahtarı @AppStorage ile okur.
enum Preferences {
    static let engineKey = "translationEngine"
    static let modelKey = "transcriptionModel"

    static var engine: TranslationEngine {
        let stored = UserDefaults.standard.string(forKey: engineKey).flatMap(TranslationEngine.init(rawValue:)) ?? .apple
        // Seçili ama kurulmamışsa sessizce Apple'a düş; Ayarlar bunu gösterir
        return stored == .opus && !OpusEngine.isInstalled ? .apple : stored
    }

    static var modelChoice: TranscriptionModelChoice {
        UserDefaults.standard.string(forKey: modelKey).flatMap(TranscriptionModelChoice.init(rawValue:)) ?? .automatic
    }
}

/// Whisper modelinin yaşam döngüsü: diskte mi, bellekte mi, şu an ne yapıyor.
enum ModelState: Equatable {
    case missing
    case downloading(Double)
    /// Diskte var; ilk yüklemede Core ML bu Mac için derler (bir kez, birkaç dakika)
    case downloaded
    case loading
    case ready
    case failed(String)
}

/// Apple'ın çeviri dil paketinin durumu.
enum TranslationPack: Equatable {
    /// Henüz sorgulanmadı
    case unknown
    case installed
    case missing
}

/// Kuyruk + kalıcılık. İşler sırayla çalışır: Whisper modeli bellekte tek kopya.
@Observable
final class Library {
    /// Finder'dan açılan dosyalar AppDelegate'e gelir; SwiftUI ile aynı örneği paylaşırlar.
    static let shared = Library()

    private(set) var jobs: [Job] = []
    var selection: Job.ID?
    var isImporting = false
    var notice: String?
    private(set) var model: ModelState = .missing
    private(set) var transcriptionModel: TranscriptionModelChoice
    /// "en-tr" → dil paketi durumu (Settings'te gösterilir)
    private(set) var languageStatus: [String: TranslationPack] = [:]

    private var transcriber: Transcriber
    private var worker: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.soundscript.app", category: "library")

    var hasDownloader: Bool { Downloader.executable != nil }
    var modelLabel: String { transcriber.model.label }
    var translationLabel: String { Preferences.engine.label }

    private init() {
        // Önceki adlarla ("Altyazı", "Dalga", "clipX") kurulmuş model verisi (~1,6 GB) yeni konuma taşınır.
        Storage.migrateLegacyStorage()
        let choice = Preferences.modelChoice
        transcriptionModel = choice
        transcriber = Transcriber(model: choice.model)
        jobs = Self.load()
        for index in jobs.indices where jobs[index].status.isBusy {
            // Uygulama kapanırken yarıda kalan işler
            jobs[index].progress = nil
            if jobs[index].transcript != nil {
                jobs[index].status = .done
            } else {
                jobs[index].status = .failed
                jobs[index].error = "İşlem yarıda kaldı."
            }
        }
        selection = jobs.first?.id
        model = transcriber.isDownloaded ? .downloaded : .missing
        pump()
    }

    // MARK: Modeller

    var isBusy: Bool {
        if jobs.contains(where: { $0.status.isBusy }) { return true }
        switch model {
        case .downloading, .loading: return true
        default: return false
        }
    }

    func setModel(_ choice: TranscriptionModelChoice) {
        guard choice != transcriptionModel, !isBusy else { return }
        transcriptionModel = choice
        transcriber = Transcriber(model: choice.model)
        model = transcriber.isDownloaded ? .downloaded : .missing
    }

    /// İş beklemeden modeli indirip belleğe yükler; iş sırasında da aynı yol kullanılır.
    func prepareModel() async throws {
        if model == .ready { return }
        model = transcriber.isDownloaded ? .loading : .downloading(0)
        do {
            try await transcriber.prepare { progress in
                Task { @MainActor in
                    if case .downloading = self.model { self.model = progress >= 1 ? .loading : .downloading(progress) }
                }
            }
            model = .ready
        } catch {
            model = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Apple'ın çeviri dil paketlerinin kurulu olup olmadığını sorar.
    /// Yalnızca Settings açıldığında çağrılır; her işten sonra değil.
    func refreshLanguages() async {
        let availability = LanguageAvailability()
        for (source, target) in [("en", "tr"), ("tr", "en")] {
            let status = await availability.status(
                from: Locale.Language(identifier: source),
                to: Locale.Language(identifier: target)
            )
            languageStatus["\(source)-\(target)"] = status == .installed ? .installed : .missing
        }
    }

    /// Verilen dil çifti için paket durumu.
    func languageState(from source: String, to target: String) -> TranslationPack {
        languageStatus["\(source)-\(target)"] ?? .unknown
    }

    // MARK: Eklemek / kaldırmak

    func add(files: [URL]) {
        guard !files.isEmpty else { return }
        let additions = files.map { (id: UUID(), url: $0) }

        // Kopyalama büyük videolarda ana aktörü kilitlemesin: iş hemen görünür,
        // dosya arka planda kütüphaneye taşınır, sonra kuyruğa girer.
        for (id, url) in additions {
            jobs.insert(Job(id: id, name: url.lastPathComponent), at: 0)
        }
        selection = additions.first?.id
        save()

        for (id, url) in additions {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let copy = try await Self.copyIntoLibrary(url, id: id)
                    guard self.job(id) != nil else {
                        try? FileManager.default.removeItem(at: copy)
                        return
                    }
                    self.update(id) { $0.file = copy }
                    self.save()
                    self.pump()
                } catch {
                    guard self.job(id) != nil else { return }
                    self.update(id) {
                        $0.status = .failed
                        $0.error = "Dosya kopyalanamadı: \(error.localizedDescription)"
                    }
                    self.notice = "\(url.lastPathComponent) eklenemedi: \(error.localizedDescription)"
                    self.save()
                    self.pump()
                }
            }
        }
    }

    func add(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Downloader.isURL(trimmed) else {
            notice = "Bu geçerli bir bağlantı değil."
            return
        }
        let job = Job(name: trimmed, link: trimmed)
        jobs.insert(job, at: 0)
        selection = job.id
        save()
        pump()
    }

    func remove(_ id: Job.ID) {
        guard let job = job(id), !job.status.isBusy else { return }
        if let file = job.file { try? FileManager.default.removeItem(at: file) }
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.first?.id }
        save()
    }

    func retry(_ id: Job.ID) {
        update(id) {
            $0 = Job(id: $0.id, name: $0.name, file: $0.file, link: $0.link, createdAt: $0.createdAt, duration: $0.duration)
        }
        save()
        pump()
    }

    /// Dil paketi indikten sonra ya da "Yeniden çevir" ile.
    func retranslate(_ id: Job.ID) async {
        guard let transcript = job(id)?.transcript else { return }
        await translate(id, transcript: transcript)
        save()
    }

    func job(_ id: Job.ID?) -> Job? {
        jobs.first { $0.id == id }
    }

    // MARK: Kuyruk

    private func pump() {
        guard worker == nil, let next = jobs.last(where: { $0.status == .queued }) else { return }
        worker = Task {
            await run(next.id)
            worker = nil
            pump()
        }
    }

    private func run(_ id: Job.ID) async {
        do {
            if let link = job(id)?.link, job(id)?.file == nil {
                update(id) { $0.status = .downloading }
                let downloaded = try await Downloader.download(link)
                let copy = try await Self.copyIntoLibrary(downloaded, id: id, move: true)
                update(id) {
                    $0.file = copy
                    $0.name = downloaded.lastPathComponent
                }
            }
            guard let file = job(id)?.file else { throw SoundScriptError.decodeFailed("dosya bulunamadı") }

            update(id) { $0.status = .decoding }
            // Ses çözme ile model indirme/derleme paralel: soğuk açılışta ciddi süre kazancı.
            async let samplesTask = AudioDecoder.loadMono16k(file)
            async let modelTask: Void = prepareModel()
            var samples = try await samplesTask
            update(id) {
                $0.duration = Double(samples.count) / Double(AudioDecoder.sampleRate)
                $0.status = .loadingModel
            }
            try await modelTask

            update(id) {
                $0.status = .transcribing
                $0.progress = nil
            }
            let transcript = try await transcriber.transcribe(samples: samples) { progress in
                Task { @MainActor in
                    guard self.job(id)?.status == .transcribing else { return }
                    self.update(id) { $0.progress = progress }
                }
            }
            // Ham sesi bırak: çeviri sırasında 225 MB (1 saatlik video) boşuna durmasın.
            samples = []
            update(id) { $0.transcript = transcript }
            save()

            await translate(id, transcript: transcript)
        } catch {
            logger.error("job failed: \(error.localizedDescription, privacy: .public)")
            update(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
                $0.progress = nil
            }
        }
        save()
    }

    private func translate(_ id: Job.ID, transcript: Transcript) async {
        let target = transcript.language.hasPrefix("tr") ? "en" : "tr"
        update(id) {
            $0.status = .translating
            $0.translationError = nil
            $0.needsLanguage = nil
            $0.progress = 0
        }
        do {
            let translation = try await Preferences.engine.translate(transcript, to: target) { fraction in
                Task { @MainActor in
                    guard self.job(id)?.status == .translating else { return }
                    self.update(id) { $0.progress = fraction }
                }
            }
            update(id) { $0.translation = translation }
        } catch SoundScriptError.translationNotInstalled {
            update(id) { $0.needsLanguage = target }
        } catch {
            update(id) { $0.translationError = error.localizedDescription }
        }
        update(id) {
            $0.status = .done
            $0.progress = nil
        }
    }

    // MARK: Kalıcılık

    private func update(_ id: Job.ID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    @concurrent
    private static func copyIntoLibrary(_ url: URL, id: UUID, move: Bool = false) async throws -> URL {
        try Storage.ensure(Storage.library)
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let destination = Storage.library.appending(path: "\(id.uuidString).\(ext)")
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if move {
            try FileManager.default.moveItem(at: url, to: destination)
        } else {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        return destination
    }

    private nonisolated static var indexFile: URL { Storage.library.appending(path: "library.json") }

    private static func load() -> [Job] {
        guard let data = try? Data(contentsOf: indexFile),
              let stored = try? JSONDecoder().decode([Job].self, from: data) else { return [] }
        return stored.filter { job in
            job.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? (job.link != nil)
        }
    }

    /// Durum değişiklikleri art arda gelir; diske en fazla yarım saniyede bir yazılır.
    private func save() {
        pendingSave?.cancel()
        let snapshot = jobs
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await Self.write(snapshot)
            } catch {
                logger.error("save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @concurrent
    private static func write(_ jobs: [Job]) async throws {
        try Storage.ensure(Storage.library)
        try JSONEncoder().encode(jobs).write(to: indexFile, options: .atomic)
    }
}
