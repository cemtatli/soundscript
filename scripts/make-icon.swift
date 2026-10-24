// SoundScript uygulama simgesini üretir.
//
// Kaynak: design/logo/app-icon-artwork.png — beyaz zeminde 3B "kesik altyazı" logosu.
// Adımlar: beyaz zemini şeffaflaştır (kenar bağlantılı dolgu ile, iç beyaz kalsın)
//           → içeriği kırp → macOS ikon ızgarasına (824'lik gövde, 100 boşluk) oturt
//           → Resources/AppIcon.png + Resources/AppIcon.icns yaz.
//
// Kullanım: swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let artworkURL = root.appendingPathComponent("design/logo/app-icon-artwork.png")
let pngURL = root.appendingPathComponent("Resources/AppIcon.png")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")

let canvasSize = 1024
let inset: CGFloat = 100          // macOS ikon ızgarası: 1024 - 2*100 = 824'lik gövde
let bodySize = CGFloat(canvasSize) - inset * 2

// MARK: - Kaynağı oku

guard let artwork = NSImage(contentsOf: artworkURL),
      let source = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Kaynak okunamadı: \(artworkURL.path)")
}

let width = source.width
let height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)

guard let bitmap = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Bitmap bağlamı oluşturulamadı")
}
bitmap.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

// MARK: - Beyaz zemini şeffaflaştır
// Dışarıdan bağlantılı beyaz pikseller arka plan; logonun içindeki beyaz
// parçalar korunur. Kenardaki yumuşak pikseller koyuluğa göre kademeli saydamlaşır.

func isWhite(_ index: Int) -> Bool {
    let base = index * 4
    return pixels[base] >= 245 && pixels[base + 1] >= 245 && pixels[base + 2] >= 245
}

var background = [Bool](repeating: false, count: width * height)
var queue: [Int] = []
var head = 0

func enqueue(_ index: Int) {
    guard !background[index], isWhite(index) else { return }
    background[index] = true
    queue.append(index)
}

for x in 0..<width {
    enqueue(x)
    enqueue((height - 1) * width + x)
}
for y in 0..<height {
    enqueue(y * width)
    enqueue(y * width + width - 1)
}
while head < queue.count {
    let index = queue[head]
    head += 1
    let x = index % width
    let y = index / width
    if x > 0 { enqueue(index - 1) }
    if x < width - 1 { enqueue(index + 1) }
    if y > 0 { enqueue(index - width) }
    if y < height - 1 { enqueue(index + width) }
}

// Kenar bandındaki pikseller için yumuşak alpha: koyuluk 5 -> 0, 45 -> 1
var alpha = [Float](repeating: 1, count: width * height)
for index in 0..<(width * height) where background[index] {
    alpha[index] = 0
}
for index in 0..<(width * height) where !background[index] {
    let x = index % width
    let y = index / width
    let nearEdge = (x >= 2 && background[index - 2]) || (x + 2 < width && background[index + 2])
        || (y >= 2 && background[index - 2 * width]) || (y + 2 < height && background[index + 2 * width])
    guard nearEdge else { continue }
    let base = index * 4
    let darkness = 255 - Int(min(pixels[base], pixels[base + 1], pixels[base + 2]))
    alpha[index] = Float(min(max(darkness - 5, 0), 40)) / 40
}

// Alpha'yı piksel verisine yaz (premultiplied)
var minX = width, maxX = -1, minY = height, maxY = -1
for index in 0..<(width * height) {
    let a = alpha[index]
    let base = index * 4
    if a <= 0.001 {
        pixels[base] = 0
        pixels[base + 1] = 0
        pixels[base + 2] = 0
        pixels[base + 3] = 0
        continue
    }
    pixels[base] = UInt8((Double(pixels[base]) * Double(a)).rounded())
    pixels[base + 1] = UInt8((Double(pixels[base + 1]) * Double(a)).rounded())
    pixels[base + 2] = UInt8((Double(pixels[base + 2]) * Double(a)).rounded())
    pixels[base + 3] = UInt8((Double(a) * 255).rounded())

    let x = index % width
    let y = index / width
    minX = min(minX, x); maxX = max(maxX, x)
    minY = min(minY, y); maxY = max(maxY, y)
}

guard maxX > minX, maxY > minY else { fatalError("Logo içeriği bulunamadı") }

// MARK: - Kırp ve 1024 tuvale yerleştir

let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1
guard let full = bitmap.makeImage(),
      let cropContext = CGContext(
          data: nil,
          width: cropWidth,
          height: cropHeight,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    fatalError("Kırpma bağlamı oluşturulamadı")
}
cropContext.draw(full, in: CGRect(x: -minX, y: -minY, width: width, height: height))
guard let cropped = cropContext.makeImage() else {
    fatalError("Kırpma başarısız")
}

let canvasContext = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
canvasContext.interpolationQuality = .high
canvasContext.draw(cropped, in: CGRect(x: inset, y: inset, width: bodySize, height: bodySize))
guard let canvasImage = canvasContext.makeImage() else {
    fatalError("Tuval oluşturulamadı")
}

let rep = NSBitmapImageRep(cgImage: canvasImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG kodlaması başarısız")
}
try png.write(to: pngURL)
print(pngURL.path)

// MARK: - .icns üret

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("soundscript-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("İkon boyutu oluşturulamadı: \(size)")
    }
    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(canvasImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    let r = NSBitmapImageRep(cgImage: context.makeImage()!)
    try r.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(icnsURL.path)
