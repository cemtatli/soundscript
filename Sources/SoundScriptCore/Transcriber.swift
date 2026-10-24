import Foundation
import os
import WhisperKit

public struct TranscriberModel: Sendable, Hashable {
    public let id: String
    public let label: String

    public static let turbo = TranscriberModel(
        id: "openai_whisper-large-v3-v20240930_turbo_632MB",
        label: "Whisper large-v3-turbo (632 MB)"
    )
    /// M1'de turbo resmi destek listesinde yok; bu model aynı kalite bandında çalışır.
    public static let largeV3Quantized = TranscriberModel(
        id: "openai_whisper-large-v3-v20240930_626MB",
        label: "Whisper large-v3 (626 MB, M1)"
    )
    /// Yalnızca 16 GB+ RAM'de açılır; en yüksek doğruluk, en yavaş seçenek.
    public static let largeV3 = TranscriberModel(
        id: "openai_whisper-large-v3-v20240930",
        label: "Whisper large-v3 (1.6 GB, en doğru)"
    )
    public static let small = TranscriberModel(id: "openai_whisper-small_216MB", label: "Whisper small (216 MB)")

    public static let all: [TranscriberModel] = [.turbo, .largeV3Quantized, .largeV3, .small]

    /// Cihazın WhisperKit destek listesine göre dengeli varsayılan.
    /// M2+ → turbo; M1 → large-v3 626 MB.
    public static var recommended: TranscriberModel {
        let supported = WhisperKit.recommendedModels().supported
        if supported.contains(turbo.id) { return .turbo }
        if supported.contains(largeV3Quantized.id) { return .largeV3Quantized }
        return .small
    }

    /// "En doğru" modu. 1.6 GB modeli 8 GB makinelere yüklemeyelim.
    public static var bestQuality: TranscriberModel {
        let support = WhisperKit.recommendedModels()
        let hasEnoughRAM = ProcessInfo.processInfo.physicalMemory >= 16 * 1_073_741_824
        if hasEnoughRAM, support.supported.contains(largeV3.id) { return .largeV3 }
        return recommended
    }
}

/// WhisperKit sarmalayıcısı. Model bir kez iner, Storage.models altında kalır;
/// sonraki çalıştırmalarda ağa çıkmadan yüklenir.
public actor Transcriber {
    static let repo = "argmaxinc/whisperkit-coreml"

    public nonisolated let model: TranscriberModel
    private var pipe: WhisperKit?

    public init(model: TranscriberModel = .recommended) {
        self.model = model
    }

    public nonisolated var localFolder: URL {
        Storage.models.appending(path: "models/\(Self.repo)/\(model.id)", directoryHint: .isDirectory)
    }

    public nonisolated var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localFolder.appending(path: "AudioEncoder.mlmodelc").path)
    }

    /// Modeli indirir (gerekirse) ve belleğe yükler.
    public func prepare(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if pipe != nil { return }
        try Storage.ensure(Storage.models)

        let folder: URL
        if isDownloaded {
            folder = localFolder
        } else {
            folder = try await WhisperKit.download(
                variant: model.id,
                downloadBase: Storage.models,
                from: Self.repo,
                progressCallback: { progress in onProgress?(progress.fractionCompleted) }
            )
        }

        let config = WhisperKitConfig(
            model: model.id,
            downloadBase: Storage.models,
            modelFolder: folder.path,
            tokenizerFolder: Storage.models,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
    }

    /// - Parameters:
    ///   - language: nil ise Whisper dili kendisi algılar.
    ///   - onProgress: 0…1 arası ilerleme; segment keşfedildikçe artar.
    public func transcribe(
        samples: [Float],
        language: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        try await prepare()
        guard let pipe else { throw SoundScriptError.noSpeech }

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            // WhisperKit macOS'ta varsayılan olarak 16 eşzamanlı işçi kullanıyor;
            // her işçi kendi mel tamponunu tutuyor. 4 işçi neredeyse aynı hızı
            // verirken tepe belleği yarıya indiriyor (ölçüm: 737 MB → 411 MB).
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )

        // Segment callback'i WhisperKit'in VAD yolunda da çalışsın diye hem
        // instance property'sine hem çağrıya veriyoruz.
        let duration = Double(samples.count) / Double(AudioDecoder.sampleRate)
        let reported = OSAllocatedUnfairLock(initialState: 0.0)
        let segmentCallback: SegmentDiscoveryCallback?
        if let onProgress {
            segmentCallback = { segments in
                guard duration > 0, let end = segments.map(\.end).max() else { return }
                let fraction = min(1, max(0, Double(end) / duration))
                let shouldReport = reported.withLock { value in
                    guard fraction > value + 0.005 else { return false }
                    value = fraction
                    return true
                }
                if shouldReport { onProgress(fraction) }
            }
        } else {
            segmentCallback = nil
        }
        pipe.segmentDiscoveryCallback = segmentCallback
        defer { pipe.segmentDiscoveryCallback = nil }

        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options,
            segmentCallback: segmentCallback
        )

        let raw = results.flatMap(\.segments).map {
            Segment(start: Double($0.start), end: Double($0.end), text: Self.clean($0.text))
        }
        let segments = SegmentMerger.merge(raw)
        guard !segments.isEmpty else { throw SoundScriptError.noSpeech }

        onProgress?(1)
        let detected = results.first?.language ?? language ?? "en"
        return Transcript(language: detected, segments: segments, model: model.id)
    }

    /// skipSpecialTokens'a rağmen kalan "<|0.00|>" token artıklarını ve Whisper'ın
    /// diyalog için koyduğu baştaki "- " işaretini temizler.
    static func clean(_ text: String) -> String {
        text.replacing(/<\|[^|]*\|>/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/^[-–—]\s*/, with: "")
    }
}
