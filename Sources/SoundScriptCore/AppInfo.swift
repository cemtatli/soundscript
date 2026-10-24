import Foundation

/// Uygulamanın kimliği tek yerde: ad, terminal komutu, bundle id ve veri dizini.
///
/// İsim değişikliği sadece burada yapılır; kodun geri kalanı bu değerleri kullanır.
public enum AppInfo {
    /// Kullanıcıya görünen ad: pencere başlığı, menüler, README.
    public static let displayName = "SoundScript"

    /// Terminal komutu: `soundscript video.mp4`
    public static let commandName = "soundscript"

    /// Bundle kimliği (macOS, dağıtım).
    public static let bundleIdentifier = "dev.soundscript.app"

    /// Veri dizini: `~/Library/Application Support/<storageFolderName>`
    public static let storageFolderName = "SoundScript"

    /// Önceki adlarla kurulmuş veri dizinleri; ilk açılışta sırayla denenip taşınır.
    /// (Modeller ~1,6 GB: yeniden indirilmesin.)
    public static let legacyStorageFolderNames = ["Altyazı", "Dalga", "clipX"]
}
