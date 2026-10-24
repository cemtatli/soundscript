import AppKit
import SwiftUI

@main
struct SoundScriptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = Library.shared

    var body: some Scene {
        Window("SoundScript", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(library)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Dosya Ekle…") { library.isImporting = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM'den başlatılınca (bundle'sız) uygulama arka planda kalmasın
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.servicesProvider = services
    }

    /// Finder'da "Şununla Aç → SoundScript" ya da dosyayı Dock simgesine bırakmak.
    func application(_ application: NSApplication, open urls: [URL]) {
        Library.shared.add(files: urls)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Finder sağ tık → "SoundScript ile transkript çıkar" (Info.plist'teki NSServices).
final class ServiceProvider: NSObject {
    @objc func transcribe(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "Dosya bulunamadı." as NSString
            return
        }
        Library.shared.add(files: urls)
        NSApp.activate()
    }
}
