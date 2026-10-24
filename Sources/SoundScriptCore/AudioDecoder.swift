import AVFoundation

/// Video ya da ses dosyasından Whisper'ın beklediği 16 kHz mono Float32 örnekleri çıkarır.
/// AVAudioFile mp4/mov içindeki ses kanalını okuyamadığı için AVAssetReader kullanıyoruz.
public enum AudioDecoder {
    public static let sampleRate = 16_000

    /// Uzun videolarda saniyeler sürer; çağıran ana aktörde olsa bile arka planda çalışsın.
    @concurrent
    public static func loadMono16k(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SoundScriptError.noAudioTrack(url)
        }

        // Yerini önceden ayır: dizi büyürken kapasite ikiye katlanıyordu.
        // 1 saatlik bir video için tepe bellek 614 MB yerine 230 MB'ye düşüyor.
        let duration = try? await asset.load(.duration)
        let estimated = duration.map { max(0, $0.seconds) * Double(sampleRate) } ?? 0
        var samples = [Float]()
        if estimated.isFinite, estimated > 0 {
            samples.reserveCapacity(Int(estimated))
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw SoundScriptError.decodeFailed(reader.error?.localizedDescription ?? "okuma başlamadı")
        }

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if status == kCMBlockBufferNoErr { samples.append(contentsOf: chunk) }
        }

        if reader.status == .failed {
            throw SoundScriptError.decodeFailed(reader.error?.localizedDescription ?? "bilinmeyen hata")
        }
        return samples
    }
}
