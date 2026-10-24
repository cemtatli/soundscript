import AVFoundation
import Foundation

/// Bağlantıdan video indirmek için sistemdeki yt-dlp'yi çağırır.
/// yt-dlp'yi uygulamaya gömmüyoruz: kullanıcı `brew install yt-dlp` ile kurar
/// ve güncel tutar (sitelerin değişen formatlarına hızlı uyum için).
public enum Downloader {
    static let searchPaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]

    public static var executable: URL? {
        searchPaths.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func isURL(_ input: String) -> Bool {
        guard let url = URL(string: input), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// İndirilen dosyanın yolunu döner.
    @concurrent
    public static func download(_ link: String, into directory: URL = Storage.downloads) async throws -> URL {
        guard let executable else { throw SoundScriptError.downloaderMissing }
        try Storage.ensure(directory)

        // Finder'dan açılan uygulama terminalin PATH'ini almaz: yt-dlp ffmpeg'i (birleştirme)
        // ve YouTube için JS çalışma ortamını (deno/node) bulamaz, parçaları birleştirmeden bırakır.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"] + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        let ffmpeg = ffmpegPaths.first(where: FileManager.default.isExecutableFile(atPath:))
        let arguments = (ffmpeg.map { ["--ffmpeg-location", $0] } ?? []) + [
            "--no-playlist",
            // AVFoundation VP9/AV1 çözemiyor; indirme sonrası dönüştürme 34 sn'lik videoda
            // ~4 sn sürüyordu. Sıra: AVC DASH → HEVC DASH → hazır (progressive) dosya → VP9/AV1.
            // Instagram'da DASH yalnızca VP9 sunduğu için üçüncü adım devreye girer: 720p H.264,
            // birleştirme ve dönüştürme yok (ölçüm: 6,8 sn → 2,4 sn).
            "--format", "bv*[vcodec^=avc1]+ba[ext=m4a]/bv*[vcodec^=hvc1]+ba[ext=m4a]/b/bv*[ext=mp4]+ba[ext=m4a]",
            "--merge-output-format", "mp4",
            "--output", directory.appending(path: "%(title).80B [%(id)s].%(ext)s").path,
            "--print", "after_move:filepath",
            "--quiet", "--no-warnings",
            link,
        ]
        let result = try ProcessRunner.run(executable.path, arguments, environment: environment)
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SoundScriptError.downloadFailed(message.isEmpty ? "yt-dlp çıkış kodu \(result.status)" : message)
        }
        let path = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { throw SoundScriptError.downloadFailed("yt-dlp dosya yolu döndürmedi") }
        let file = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            removeParts(of: file)
            throw SoundScriptError.downloadFailed(
                ffmpeg == nil
                    ? "Görüntü ve ses birleştirilemedi: ffmpeg bulunamadı. Kur: brew install ffmpeg"
                    : "İndirilen dosya bulunamadı: \(file.lastPathComponent)"
            )
        }
        return try await ensurePlayable(file)
    }

    /// Birleştirilemeyen ".f137.mp4" / ".f140.m4a" parçalarını siler.
    static func removeParts(of file: URL) {
        let stem = file.deletingPathExtension().lastPathComponent
        let directory = file.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(stem + ".") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    static let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    /// Site yalnızca VP9/AV1 sunduysa görüntüyü H.264'e çevirir (donanım kodlayıcıyla, birkaç saniye).
    /// ffmpeg yoksa dosya olduğu gibi kalır: ses ve transkript yine çalışır.
    @concurrent
    public static func ensurePlayable(_ url: URL) async throws -> URL {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else { return url }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        guard ![kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(codec),
              let ffmpeg = ffmpegPaths.first(where: FileManager.default.isExecutableFile(atPath:)) else { return url }

        let output = url.deletingPathExtension().appendingPathExtension("h264.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-y", "-loglevel", "error", "-i", url.path,
            "-c:v", "h264_videotoolbox", "-b:v", "6M", "-c:a", "copy",
            "-movflags", "+faststart", output.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return url }

        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: output, to: url)
        return url
    }
}
