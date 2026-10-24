import Foundation

/// Tüm kalıcı veriler ~/Library/Application Support/SoundScript altında durur.
public enum Storage {
    private static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static var root: URL {
        base.appending(path: AppInfo.storageFolderName, directoryHint: .isDirectory)
    }

    public static var models: URL { root.appending(path: "models", directoryHint: .isDirectory) }
    public static var downloads: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }
    /// Uygulamaya eklenen dosyaların kopyaları ve library.json
    public static var library: URL { root.appending(path: "library", directoryHint: .isDirectory) }

    /// Önceki adlarla ("Altyazı", "Dalga", "clipX") kurulmuş veriyi yeni konuma taşır.
    /// Taşınamazsa hiçbir şey değişmez; kullanıcı modeli yeniden indirir.
    @discardableResult
    public static func migrateLegacyStorage() -> Bool {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: root.path) else { return false }
        for name in AppInfo.legacyStorageFolderNames {
            let legacy = base.appending(path: name, directoryHint: .isDirectory)
            guard manager.fileExists(atPath: legacy.path) else { continue }
            do {
                try manager.moveItem(at: legacy, to: root)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    @discardableResult
    public static func ensure(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
