import CoreGraphics
import CoreText
import Foundation
import UIKit

/// CoreText measuring and drawing shared by the stamp renderer and the PDF builder.
/// Thread-safe (no UIKit view APIs). All rects are in a top-left origin coordinate space.
enum TextBox {
    struct Style {
        var font: UIFont
        var color: CGColor
        var alignment: CTTextAlignment = .left
        var lineSpacing: CGFloat = 0
    }

    static func attributed(_ text: String, style: Style) -> NSAttributedString {
        var alignment = style.alignment
        var lineBreak = CTLineBreakMode.byWordWrapping
        var spacing = style.lineSpacing
        // The paragraph style is created inside the closures so the value pointers stay valid.
        let paragraph: CTParagraphStyle = withUnsafeBytes(of: &alignment) { alignmentPtr in
            withUnsafeBytes(of: &lineBreak) { breakPtr in
                withUnsafeBytes(of: &spacing) { spacingPtr in
                    let settings = [
                        CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                value: alignmentPtr.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size,
                                                value: breakPtr.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
                                                value: spacingPtr.baseAddress!)
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): style.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Size needed to draw the whole string within `width` (rounded up).
    static func measure(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        guard string.length > 0 else { return .zero }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width) + 1, height: ceil(size.height) + 1)
    }

    /// Number of UTF-16 characters that fit into the box (whole lines only).
    static func fittingLength(_ string: NSAttributedString, width: CGFloat, height: CGFloat) -> Int {
        guard string.length > 0, height > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        return visible.length
    }

    /// Draws into a context whose coordinate system has a top-left origin (y grows downwards).
    static func draw(_ string: NSAttributedString, in rect: CGRect, context: CGContext) {
        guard string.length > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Splits text into the part that fits and the remainder, breaking at a whitespace when possible.
    static func split(_ text: String, style: Style, width: CGFloat, height: CGFloat) -> (head: String, tail: String) {
        let attributed = attributed(text, style: style)
        let fit = fittingLength(attributed, width: width, height: height)
        guard fit > 0 else { return ("", text) }
        guard fit < attributed.length else { return (text, "") }
        let ns = text as NSString
        var cut = fit
        let whitespace = CharacterSet.whitespacesAndNewlines
        while cut > fit / 2 {
            let scalar = ns.character(at: cut - 1)
            if let unicode = Unicode.Scalar(scalar), whitespace.contains(unicode) { break }
            cut -= 1
        }
        if cut <= fit / 2 { cut = fit }
        let range = ns.rangeOfComposedCharacterSequence(at: max(0, cut - 1))
        let safeCut = min(ns.length, NSMaxRange(range))
        let head = ns.substring(to: safeCut).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = ns.substring(from: safeCut).trimmingCharacters(in: .whitespacesAndNewlines)
        return (head, tail)
    }
}
