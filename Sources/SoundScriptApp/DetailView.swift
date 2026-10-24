import AppKit
import AVKit
import SoundScriptCore
import SwiftUI
@preconcurrency import Translation

/// Oynatıcının zaman gözlemcisini tutan kutu. Kutu yok edilirken gözlemci
/// kaldırılır; aksi halde her iş değişiminde gözlemci sızıntı yapıyordu.
/// Gözlemci belirteci `Any` tipinde; deinit'ten erişilebilmesi için
/// Sendable bir kılıf kullanıyoruz.
nonisolated struct ObserverToken: @unchecked Sendable {
    let value: Any
}

nonisolated private final class TimeObserver: @unchecked Sendable {
    private let player: AVPlayer
    private let token: ObserverToken

    init(player: AVPlayer, interval: CMTime, onTick: @escaping @Sendable (Double) -> Void) {
        self.player = player
        token = ObserverToken(
            value: player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                onTick(time.seconds)
            }
        )
    }

    deinit { player.removeTimeObserver(token.value) }
}

@Observable
final class PlayerModel {
    let player: AVPlayer
    var time: Double = 0
    /// Videonun gerçek en-boy oranı; oynatıcı siyah boşluk bırakmadan sarar
    var aspectRatio: CGFloat?

    private var timeObserver: TimeObserver?
    private var loadedURL: URL?

    init(url: URL?) {
        let player = AVPlayer()
        self.player = player
        // weak: oynatıcı bloğu tutar, blok modeli tutarsa döngü olur ve model hiç bırakılmaz
        timeObserver = TimeObserver(
            player: player,
            interval: CMTime(seconds: 0.2, preferredTimescale: 600)
        ) { [weak self] seconds in
            MainActor.assumeIsolated {
                // Duraklatılmışken zamanı güncellemek her 0,2 sn'de tüm listeyi
                // yeniden çizdiriyordu; oynatılmıyorsa dokunma.
                guard let self, self.player.rate != 0 else { return }
                self.time = seconds
            }
        }
        load(url)
    }

    /// Dosya sonradan gelebilir (bağlantıdan indirme): aynı oynatıcıya yeni öğe takılır.
    /// Böylece indirme bitince video, uygulama yeniden açılmadan görünür.
    func load(_ url: URL?) {
        guard url != loadedURL else { return }
        loadedURL = url
        time = 0
        aspectRatio = nil
        guard let url else {
            player.replaceCurrentItem(with: nil)
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        Task { [weak self] in
            let ratio = await Self.aspect(of: url)
            // Bu arada başka bir iş seçilmiş olabilir: eski oranı yazma.
            guard let self, self.loadedURL == url else { return }
            self.aspectRatio = ratio
        }
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private static func aspect(of url: URL) async -> CGFloat? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let oriented = size.applying(transform)
        let width = abs(oriented.width), height = abs(oriented.height)
        return height > 0 ? width / height : nil
    }
}

struct DetailView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case both = "Yan Yana", source = "Orijinal", target = "Çeviri"
        var id: Self { self }
    }

    let job: Job
    @Environment(Library.self) private var library
    @State private var player: PlayerModel
    @State private var mode: Mode = .both
    @State private var languageRequest: TranslationSession.Configuration?
    @State private var copied = false

    init(job: Job) {
        self.job = job
        _player = State(initialValue: PlayerModel(url: job.file))
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                MediaPane(job: job, player: player, available: geometry.size)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(job.name)
        .navigationSubtitle(subtitle)
        .onChange(of: job.file) { _, url in player.load(url) }
        .toolbar { toolbar }
        .translationTask(languageRequest) { session in
            // Sistem, kullanıcı onayıyla dil paketini indirir; ardından çeviriyi yeniden dene.
            do {
                try await session.prepareTranslation()
                await library.retranslate(job.id)
            } catch {
                library.notice = "Dil paketi indirilemedi: \(error.localizedDescription)"
            }
            languageRequest = nil
        }
    }

    private var subtitle: String {
        guard let transcript = job.transcript else { return job.status.label }
        let languages = transcript.language.uppercased() + (job.translation.map { " → \($0.language.uppercased())" } ?? "")
        return [job.duration.map(Exporter.clock), languages].compactMap(\.self).joined(separator: "  ·  ")
    }

    @ViewBuilder
    private var content: some View {
        if let transcript = job.transcript {
            VStack(spacing: 0) {
                banner
                TranscriptList(
                segments: transcript.segments,
                translated: job.translation?.segments ?? [],
                sourceLabel: languageName(transcript.language),
                targetLabel: languageName(job.translation?.language ?? (transcript.language.hasPrefix("tr") ? "en" : "tr")),
                mode: mode,
                translating: job.status == .translating,
                time: player.time,
                    onSeek: player.seek
                )
            }
        } else if job.status == .failed {
            ContentUnavailableView {
                Label("İşlenemedi", systemImage: "exclamationmark.triangle")
            } description: {
                Text(job.error ?? "Bilinmeyen hata.")
            } actions: {
                Button("Tekrar Dene") { library.retry(job.id) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ProcessingSteps(job: job)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let language = job.needsLanguage, let source = job.transcript?.language {
            Banner(
                symbol: "arrow.down.circle",
                title: "\(languageName(language)) çeviri dili bu Mac'te yok",
                detail: "Bir kez indirilir, sonra çevrimdışı çalışır.",
                action: "İndir"
            ) {
                languageRequest = .init(source: Locale.Language(identifier: source), target: Locale.Language(identifier: language))
            }
        } else if let error = job.translationError {
            Banner(symbol: "exclamationmark.triangle", title: "Çeviri yapılamadı", detail: error, action: "Tekrar Dene", tint: .orange) {
                Task { await library.retranslate(job.id) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Görünüm", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(job.transcript == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                .contentTransition(.symbolEffect(.replace))
                .disabled(job.transcript == nil)

            Menu("Dışa Aktar", systemImage: "square.and.arrow.up") {
                Section("SoundScript") {
                    Button("SRT · Orijinal") { export(.srt, translated: false) }
                    Button("SRT · Çeviri") { export(.srt, translated: true) }.disabled(job.translation == nil)
                }
                Section("Metin") {
                    Button("TXT · Orijinal") { export(.txt, translated: false) }
                    Button("TXT · Çeviri") { export(.txt, translated: true) }.disabled(job.translation == nil)
                    Button("Markdown · Yan Yana") { export(.md, translated: false) }
                    Button("JSON") { export(.json, translated: false) }
                }
            }
            .disabled(job.transcript == nil)

            Menu("Diğer", systemImage: "ellipsis") {
                Button("Yeniden Çevir", systemImage: "translate") { Task { await library.retranslate(job.id) } }
                    .disabled(job.transcript == nil || job.status.isBusy)
                Button("Yeniden İşle", systemImage: "arrow.clockwise") { library.retry(job.id) }
                    .disabled(job.status.isBusy)
                if let file = job.file {
                    Button("Finder'da Göster", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
            .menuIndicator(.hidden)
        }
    }

    private func copy() {
        guard let transcript = job.transcript else { return }
        var text = Exporter.txt(transcript.segments)
        if let translation = job.translation { text += "\n" + Exporter.txt(translation.segments) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func export(_ format: ExportFormat, translated: Bool) {
        guard let transcript = job.transcript else { return }
        let segments = translated ? job.translation?.segments ?? [] : transcript.segments
        let contents = switch format {
        case .srt: Exporter.srt(segments)
        case .txt: Exporter.txt(segments)
        case .md: Exporter.markdown(transcript, translation: job.translation)
        case .json: (try? Exporter.json(transcript, translation: job.translation)) ?? ""
        }

        let panel = NSSavePanel()
        let base = (job.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (translated ? ".\(job.translation?.language ?? "tr")" : "") + ".\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            library.notice = "Kaydedilemedi: \(error.localizedDescription)"
        }
    }
}

func languageName(_ code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code.uppercased()
}

// MARK: - Medya

private struct MediaPane: View {
    let job: Job
    let player: PlayerModel
    let available: CGSize

    private let inset: CGFloat = 20

    var body: some View {
        if job.file == nil {
            // Bağlantı henüz inmedi: boş siyah oynatıcı yerine hiçbir şey
            EmptyView()
        } else if job.isAudio {
            PlayerView(player: player.player)
                .frame(width: 320, height: 64)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .padding(inset)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            // Yüksekliği doldur, genişliği orandan hesapla; transkripte en az 520 pt kalsın
            let aspect = player.aspectRatio ?? 9 / 16
            let width = max(200, min((available.height - inset * 2) * aspect, available.width - 520 - inset * 2))
            PlayerView(player: player.player)
                .frame(width: width, height: width / aspect)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .padding(inset)
                .frame(maxHeight: .infinity)
        }
    }
}

/// SwiftUI'nin VideoPlayer'ı SwiftPM ile derlenen uygulamada metadata hatasıyla
/// çöküyor (_AVKit_SwiftUI); AppKit oynatıcısını doğrudan sarıyoruz.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - İşlem durumu

/// Bekleme ekranı: hangi adımda olduğumuzu ve sırada ne olduğunu gösterir.
private struct ProcessingSteps: View {
    let job: Job

    private var steps: [Job.Status] {
        (job.link != nil ? [.downloading] : []) + [.decoding, .loadingModel, .transcribing, .translating]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(steps, id: \.self) { step in
                HStack(spacing: 12) {
                    icon(for: step).frame(width: 18)
                    Text(step.label)
                        .foregroundStyle(state(of: step) == .pending ? .tertiary : .primary)
                    if state(of: step) == .active, let progress = job.progress {
                        Text("%\(Int(progress * 100))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if job.status == .loadingModel {
                Text("İlk seferde model indirilir ve bu Mac için derlenir. Bu birkaç dakika sürer, bir kez olur.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .animation(.smooth, value: job.status)
    }

    private enum StepState { case done, active, pending }

    private func state(of step: Job.Status) -> StepState {
        guard let current = steps.firstIndex(of: job.status), let index = steps.firstIndex(of: step) else {
            return job.status == .queued ? .pending : .done
        }
        return index < current ? .done : index == current ? .active : .pending
    }

    @ViewBuilder
    private func icon(for step: Job.Status) -> some View {
        switch state(of: step) {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
        case .active: ProgressView().controlSize(.small)
        case .pending: Image(systemName: "circle").foregroundStyle(.quaternary)
        }
    }
}

private struct Banner: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String
    var tint: Color = .accentColor
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
                .tint(tint)
        }
        .padding(12)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

// MARK: - Transkript

private struct TranscriptList: View {
    let segments: [Segment]
    let translated: [Segment]
    let sourceLabel: String
    let targetLabel: String
    let mode: DetailView.Mode
    let translating: Bool
    let time: Double
    let onSeek: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Oynatılan satır. Segmentler zamana göre sıralı olduğu için ikili arama
    /// kullanıyoruz: her karede tüm listeyi taramak uzun transkriptlerde pahalıydı.
    private var active: Int? {
        var low = 0
        var high = segments.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if segments[mid].start <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let candidate else { return nil }
        if matches(candidate) { return candidate }
        let previous = candidate - 1
        if previous >= 0, matches(previous) { return previous }
        return nil
    }

    private func matches(_ index: Int) -> Bool {
        let segment = segments[index]
        return time <= max(segment.end, segment.start + 2.5)
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnLayout(mode: mode) {
                Color.clear.frame(height: 1)
            } source: {
                Text(sourceLabel)
            } target: {
                Text(targetLabel)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(segments.indices, id: \.self) { index in
                            TranscriptRow(
                                segment: segments[index],
                                translation: translated[safe: index]?.text,
                                mode: mode,
                                translating: translating,
                                isActive: active == index,
                                onSeek: onSeek
                            )
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
                .onChange(of: active) { _, index in
                    guard let index else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let segment: Segment
    let translation: String?
    let mode: DetailView.Mode
    let translating: Bool
    let isActive: Bool
    let onSeek: (Double) -> Void

    @State private var hovering = false

    var body: some View {
        ColumnLayout(mode: mode) {
            Text(Exporter.clock(segment.start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        } source: {
            Text(segment.text)
        } target: {
            if let translation {
                Text(translation)
            } else {
                Text(translating ? "Çevriliyor…" : "—").foregroundStyle(.tertiary)
            }
        }
        .lineSpacing(3)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.6 : 0)))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { onSeek(segment.start) }
        .animation(.smooth(duration: 0.2), value: isActive)
        .accessibilityAction(named: "Bu satıra git") { onSeek(segment.start) }
    }
}

/// Başlık ve satırların aynı sütun ızgarasını paylaşması için tek yerleşim.
private struct ColumnLayout<Time: View, Source: View, Target: View>: View {
    let mode: DetailView.Mode
    @ViewBuilder let time: Time
    @ViewBuilder let source: Source
    @ViewBuilder let target: Target

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            time.frame(width: 44, alignment: .leading)
            if mode != .target { source.frame(maxWidth: .infinity, alignment: .leading) }
            if mode != .source { target.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(.horizontal, 12)
        .textSelection(.enabled)
    }
}
