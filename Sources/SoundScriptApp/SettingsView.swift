import SoundScriptCore
import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library
    @AppStorage(Preferences.engineKey) private var engine: TranslationEngine = .apple
    @AppStorage(Preferences.modelKey) private var modelChoice: TranscriptionModelChoice = .automatic
    @State private var install: InstallState = OpusEngine.isInstalled ? .installed : .idle

    enum InstallState: Equatable {
        case idle
        case running(Double, String)
        case installed
        case failed(String)
    }

    var body: some View {
        Form {
            Section("Çeviri") {
                Picker("Motor", selection: $engine) {
                    ForEach(TranslationEngine.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if engine == .opus { opusRow }
            }

            Section("Transkript") {
                Picker("Model", selection: $modelChoice) {
                    ForEach(TranscriptionModelChoice.allCases) { Text($0.label).tag($0) }
                }
                .disabled(library.isBusy)
                .onChange(of: modelChoice) { _, choice in library.setModel(choice) }

                Text("Otomatik: M2+ turbo, M1 large-v3 626 MB. En doğru mod 16 GB+ RAM ister.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LabeledContent("Seçili", value: library.modelLabel)
                LabeledContent("Durum", value: modelState)
            }

            if engine == .apple {
                Section("Apple çeviri dilleri") {
                    ForEach(pairs, id: \.label) { pair in
                        LabeledContent(pair.label) {
                            switch library.languageState(from: pair.source, to: pair.target) {
                            case .installed:
                                Label("Kurulu", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .missing:
                                Label("Kurulu değil", systemImage: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                            case .unknown:
                                Text("Bilinmiyor")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text("Dil paketleri macOS indirir: Sistem Ayarları → Genel → Dil ve Bölge → Çeviri Dilleri.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button("Durumu Yenile") { Task { await library.refreshLanguages() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await library.refreshLanguages() }
    }

    /// Sistemdeki çeviri dilleriyle eşleşen yönler.
    private var pairs: [(source: String, target: String, label: String)] {
        [("en", "tr", "İngilizce → Türkçe"), ("tr", "en", "Türkçe → İngilizce")]
    }

    private var description: String {
        switch engine {
        case .apple:
            "Kurulum gerektirmez. Dil paketini macOS indirir. Satır satır çevirir; deyim ve argoda zayıf kalabilir."
        case .opus:
            "İngilizce ↔ Türkçe için eğitilmiş Helsinki-NLP modeli. Diyalogda daha doğal sonuç verir. Diğer diller için Apple kullanılır."
        }
    }

    @ViewBuilder
    private var opusRow: some View {
        switch install {
        case .idle:
            LabeledContent("Modeller") {
                Button("Kur (~1 GB)", action: startInstall)
            }
        case .running(let progress, let message):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .installed:
            LabeledContent("Modeller") {
                HStack(spacing: 10) {
                    Label("Kurulu", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Kaldır", role: .destructive) {
                        try? OpusEngine.uninstall()
                        install = .idle
                        engine = .apple
                    }
                }
            }
        case .failed(let message):
            LabeledContent("Modeller") {
                Button("Tekrar Dene", action: startInstall)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var modelState: String {
        switch library.model {
        case .missing: "İndirilmedi"
        case .downloading(let progress): "İndiriliyor · %\(Int(progress * 100))"
        case .downloaded: "İndirildi"
        case .loading: "Derleniyor"
        case .ready: "Hazır"
        case .failed(let message): message
        }
    }

    private func startInstall() {
        install = .running(0, "Hazırlanıyor…")
        Task {
            do {
                try await OpusEngine.install { progress, message in
                    Task { @MainActor in
                        // Bitişten sonra gelen geç bir olay durumu geri çekmesin
                        if case .running = install { install = .running(progress, "\(message) %\(Int(progress * 100))") }
                    }
                }
                install = .installed
            } catch {
                install = .failed(error.localizedDescription)
            }
        }
    }
}
