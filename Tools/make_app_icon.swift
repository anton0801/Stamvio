// Generates the 1024×1024 app icon variants (light, dark, tinted) with Core Graphics.
// Usage: swift Tools/make_app_icon.swift TimestampCameraWorkPhotos/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Variant { case light, dark, tinted }

func draw(_ variant: Variant) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    // Background
    switch variant {
    case .light:
        let gradient = CGGradient(colorsSpace: space, colors: [color(0x2F74F0), color(0x1546B8)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    case .dark:
        let gradient = CGGradient(colorsSpace: space, colors: [color(0x23272E), color(0x121417)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    case .tinted:
        ctx.setFillColor(color(0x000000))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    }

    let bodyColor: CGColor = variant == .tinted ? color(0xFFFFFF) : (variant == .dark ? color(0xE9EDF3) : color(0xFFFFFF))
    let accent: CGColor = variant == .light ? color(0x1A4FC4) : (variant == .dark ? color(0x4D8DFF) : color(0x9A9A9A))

    // Camera body
    let body = CGRect(x: 172, y: 262, width: 680, height: 470)
    ctx.setFillColor(bodyColor)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 110, cornerHeight: 110, transform: nil))
    ctx.fillPath()
    // Viewfinder hump
    ctx.addPath(CGPath(roundedRect: CGRect(x: 330, y: 690, width: 250, height: 110), cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.fillPath()
    // Lens ring and glass
    let center = CGPoint(x: 512, y: 492)
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: center.x - 165, y: center.y - 165, width: 330, height: 330))
    ctx.setFillColor(bodyColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 118, y: center.y - 118, width: 236, height: 236))
    // Clock hands inside the lens (timestamp)
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + 78))
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x + 62, y: center.y - 30))
    ctx.strokePath()
    ctx.setFillColor(accent)
    ctx.fillEllipse(in: CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44))
    // Stamp bar
    ctx.setFillColor(accent)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 620, y: 300, width: 180, height: 46), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: output.appendingPathComponent(name))
    print("wrote \(name)")
}

write(draw(.light), "AppIcon.png")
write(draw(.dark), "AppIcon-Dark.png")
write(draw(.tinted), "AppIcon-Tinted.png")
