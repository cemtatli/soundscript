import SoundScriptCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var library = library

        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let job = library.job(library.selection) {
                DetailView(job: job).id(job.id)
            } else {
                ContentUnavailableView {
                    Label("Video ekle", systemImage: "film.stack")
                } description: {
                    Text("Dosyayı pencereye sürükle ya da ⌘O ile seç. Transkript ve çeviri bu Mac'te yapılır.")
                } actions: {
                    Button("Dosya Seç…") { library.isImporting = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .fileImporter(isPresented: $library.isImporting, allowedContentTypes: [.movie, .audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.add(files: urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let media = urls.filter(\.isMedia)
            library.add(files: media)
            return !media.isEmpty
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { isDropTarget = targeted }
        }
        .overlay {
            if isDropTarget { DropHighlight().transition(.opacity) }
        }
        .alert(library.notice ?? "", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
            Button("Tamam", role: .cancel) {}
        }
    }
}

private extension URL {
    var isMedia: Bool {
        UTType(filenameExtension: pathExtension)?.conforms(to: .audiovisualContent) ?? false
    }
}

/// Sürüklerken pencerenin kabul ettiğini gösteren çerçeve
private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                Label("Bırak, kuyruğa ekleyelim", systemImage: "arrow.down.doc")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glassEffect()
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}

// MARK: - Kenar çubuğu

private struct Sidebar: View {
    @Environment(Library.self) private var library
    @State private var showsLink = false

    var body: some View {
        @Bindable var library = library

        List(selection: $library.selection) {
            ForEach(library.jobs) { job in
                JobRow(job: job)
                    .tag(job.id)
                    .contextMenu { menu(for: job) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { ModelStatus() }
        .onDeleteCommand {
            if let id = library.selection { library.remove(id) }
        }
        .overlay {
            if library.jobs.isEmpty { EmptyQueue(onAddLink: { showsLink = true }) }
        }
        .toolbar {
            ToolbarItemGroup {
                if library.hasDownloader {
                    Button("Bağlantıdan ekle", systemImage: "link") { showsLink = true }
                }
                Button("Dosya ekle", systemImage: "plus") { library.isImporting = true }
            }
        }
        .sheet(isPresented: $showsLink) { LinkSheet() }
    }

    @ViewBuilder
    private func menu(for job: Job) -> some View {
        Button(job.status == .failed ? "Tekrar Dene" : "Yeniden İşle", systemImage: "arrow.clockwise") {
            library.retry(job.id)
        }
        .disabled(job.status.isBusy)
        if let file = job.file {
            Button("Finder'da Göster", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
        Divider()
        Button("Kaldır", systemImage: "trash", role: .destructive) { library.remove(job.id) }
            .disabled(job.status.isBusy)
    }
}

/// Model durumu yalnızca bir şey gerektiğinde görünür: indirilmemiş, indiriliyor,
/// hazırlanıyor ya da hata verdi. Model hazırsa satır tamamen kaybolur — kuyruk
/// zaten doğru adımı gösteriyor, aynı bilgiyi tekrarlamaya gerek yok.
private struct ModelStatus: View {
    @Environment(Library.self) private var library

    var body: some View {
        if needsAttention {
            HStack(spacing: 8) {
                indicator
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                action
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .help("\(library.modelLabel)\nÇeviri: \(library.translationLabel)")
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Model diskte ve bellekte hazırsa kullanıcının yapacak bir işi yok.
    private var needsAttention: Bool {
        switch library.model {
        case .missing, .downloading, .loading, .failed: true
        case .downloaded, .ready: false
        }
    }

    @ViewBuilder
    private var action: some View {
        switch library.model {
        case .missing:
            Button("İndir") { Task { try? await library.prepareModel() } }
                .controlSize(.small)
        case .failed:
            Button("Tekrar Dene") { Task { try? await library.prepareModel() } }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var text: String {
        switch library.model {
        case .missing: "Model indirilmeli"
        case .downloading(let progress): "Model indiriliyor · %\(Int(progress * 100))"
        case .downloaded: "Model indirildi"
        case .loading: "Model hazırlanıyor…"
        case .ready: "Model hazır"
        case .failed: "Model yüklenemedi"
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch library.model {
        case .downloading, .loading: ProgressView().controlSize(.mini)
        case .ready, .downloaded: Circle().fill(.green).frame(width: 6, height: 6)
        case .missing: Circle().fill(.orange).frame(width: 6, height: 6)
        case .failed: Circle().fill(.red).frame(width: 6, height: 6)
        }
    }
}

/// Kuyruk boşken kenar çubuğu: logo + kısa yol tarifi + iki eylem.
private struct EmptyQueue: View {
    @Environment(Library.self) private var library
    let onAddLink: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .padding(.bottom, 2)

            Text("Kuyruk boş")
                .font(.headline)

            Text("Dosyayı sürükle ya da bağlantı ekle.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Dosya Ekle…") { library.isImporting = true }
                    .controlSize(.small)
                if library.hasDownloader {
                    Button("Bağlantı Ekle…", action: onAddLink)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 240)
    }
}

private struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusIcon(job: job)
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(job.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(job.status == .failed ? 2 : 1)
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        if job.status == .failed, let error = job.error { return error }
        if job.status.isBusy {
            if let progress = job.progress { return "\(job.status.label) · %\(Int(progress * 100))" }
            return job.status.label
        }
        if job.needsLanguage != nil || job.translationError != nil { return "Çeviri yok" }
        return job.duration.map(Exporter.clock) ?? job.status.label
    }
}

/// Durumu tek bir sabit genişlikli simgeyle gösterir; metin hizası bozulmaz.
private struct StatusIcon: View {
    let job: Job

    var body: some View {
        switch job.status {
        case .done:
            Image(systemName: job.isAudio ? "waveform" : "film")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        default:
            if let progress = job.progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct LinkSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        Form {
            Section {
                TextField("Bağlantı", text: $link, prompt: Text("https://…"))
                    .onSubmit(submit)
            } header: {
                Text("Bağlantıdan ekle")
            } footer: {
                Text("Video yt-dlp ile bu Mac'e indirilir, sonra kuyruğa eklenir.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("İndir", action: submit)
                    .disabled(!Downloader.isURL(link.trimmingCharacters(in: .whitespaces)))
            }
        }
    }

    private func submit() {
        guard Downloader.isURL(link.trimmingCharacters(in: .whitespaces)) else { return }
        library.add(link: link)
        dismiss()
    }
}
