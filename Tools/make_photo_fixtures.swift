// Generates photo fixtures for manual QA (import into the Simulator or a device).
// Usage: swift Tools/make_photo_fixtures.swift TestFixtures/Photos
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func image(width: Int, height: Int, label: String, color: CGColor) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // "TOP" marker band at the top of the pixel data to check orientation handling.
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: height - height / 8, width: width, height: height / 8))
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let font = NSFont.boldSystemFont(ofSize: CGFloat(min(width, height)) / 12)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    (label as NSString).draw(at: NSPoint(x: CGFloat(width) * 0.06, y: CGFloat(height) * 0.45), withAttributes: attrs)
    ("TOP" as NSString).draw(at: NSPoint(x: CGFloat(width) * 0.06, y: CGFloat(height) - CGFloat(height) / 9), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func write(_ name: String, _ img: CGImage, type: UTType = .jpeg, props: [CFString: Any] = [:]) {
    let url = out.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var p = props
    if type == .jpeg { p[kCGImageDestinationLossyCompressionQuality] = 0.85 }
    CGImageDestinationAddImage(dest, img, p as CFDictionary)
    CGImageDestinationFinalize(dest)
    print("wrote \(name)")
}

func exif(_ date: String, _ offset: String? = nil) -> [CFString: Any] {
    var e: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: date]
    if let offset { e[kCGImagePropertyExifOffsetTimeOriginal] = offset }
    return [kCGImagePropertyExifDictionary: e]
}

let blue = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.7, alpha: 1)
let green = CGColor(srgbRed: 0.2, green: 0.55, blue: 0.35, alpha: 1)
let gray = CGColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 1)

var withGPS = exif("2026:09:30 09:15:00", "+02:00")
withGPS[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 48.8566, kCGImagePropertyGPSLatitudeRef: "N",
                                         kCGImagePropertyGPSLongitude: 2.3522, kCGImagePropertyGPSLongitudeRef: "E",
                                         kCGImagePropertyGPSHPositioningError: 8.0] as [CFString: Any]
write("01_exif_with_offset_and_gps.jpg", image(width: 2400, height: 1800, label: "EXIF +02:00 · GPS Paris", color: blue), props: withGPS)
write("02_exif_without_offset.jpg", image(width: 2400, height: 1800, label: "EXIF, no time zone", color: green), props: exif("2026:09:29 18:40:00"))
write("03_no_exif.png", image(width: 1600, height: 1200, label: "No EXIF (PNG)", color: gray), type: .png)
var rotated = exif("2026:09:28 12:00:00", "-05:00")
rotated[kCGImagePropertyOrientation] = 6
write("04_orientation_6_portrait.jpg", image(width: 2400, height: 1800, label: "Orientation 6", color: blue), props: rotated)
write("05_before_portrait.jpg", image(width: 1800, height: 2400, label: "BEFORE kitchen", color: gray), props: exif("2026:10:01 09:00:00", "+01:00"))
write("06_after_landscape.jpg", image(width: 2400, height: 1800, label: "AFTER kitchen", color: green), props: exif("2026:10:01 15:30:00", "+01:00"))
write("07_too_many_pixels_63MP.jpg", image(width: 9000, height: 7000, label: "63 MP", color: gray), props: [kCGImageDestinationLossyCompressionQuality: 0.3])

// Animated GIF (2 frames) — must be refused with a clear message.
let gifURL = out.appendingPathComponent("08_animated.gif")
let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 2, nil)!
for (index, color) in [blue, green].enumerated() {
    CGImageDestinationAddImage(gif, image(width: 300, height: 200, label: "GIF \(index + 1)", color: color),
                               [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
}
CGImageDestinationFinalize(gif)
print("wrote 08_animated.gif")

// Truncated JPEG — must be refused as damaged.
let full = try! Data(contentsOf: out.appendingPathComponent("06_after_landscape.jpg"))
try! full.prefix(full.count / 3).write(to: out.appendingPathComponent("09_corrupted_truncated.jpg"))
print("wrote 09_corrupted_truncated.jpg")

let captions = """
Long captions for manual tests (A12). Paste into photo captions (limit 500 characters).

DE: Gründliche Endreinigung der Küche einschließlich Arbeitsplatten, Spülmaschinenverkleidung, Dunstabzugshaube und aller Schranktüren innen und außen; Entkalkung der Armaturen und Reinigung der Fliesenfugen mit einem umweltfreundlichen Spezialreiniger.

FR: Nettoyage complet de la salle de bain : détartrage de la robinetterie et de la paroi de douche, désinfection des sanitaires, nettoyage des joints de carrelage et des miroirs, dépoussiérage des luminaires et lavage du sol avec un produit écologique adapté.

RU: Генеральная уборка кухни: мытьё фасадов и столешниц, очистка вытяжки и духового шкафа, удаление известкового налёта со смесителей, мытьё плитки и швов, протирка светильников и подоконников, влажная уборка пола экологичным средством.
"""
try! captions.write(to: out.appendingPathComponent("10_long_captions.txt"), atomically: true, encoding: .utf8)
print("wrote 10_long_captions.txt")
