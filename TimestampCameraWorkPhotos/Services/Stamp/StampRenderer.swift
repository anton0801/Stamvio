import CoreGraphics
import CoreText
import Foundation
import UIKit

struct StampLine: Equatable {
    enum Style: Equatable {
        case primary
        case secondary
    }

    var text: String
    var style: Style
}

/// Everything the stamp needs about one photo, as plain values.
struct StampInput: Equatable {
    var dateInfo: PhotoDateInfo
    var isImported: Bool
    var projectTitle: String?
    var location: PhotoLocation?
    var shortCaption: String
}

/// Geometry of a stamp. Text is laid out once in a reference space (short side = 1000) and drawn
/// with a uniform scale, so the preview and the final file are identical in proportion on any size
/// (system fonts change tracking with point size; scaling avoids that) — STAMP-02.
struct StampLayout {
    struct Line {
        let attributed: NSAttributedString
        /// In reference space.
        let rect: CGRect
    }

    let imageSize: CGSize
    /// Image pixels per reference unit.
    let scale: CGFloat
    /// Box in reference space.
    let referenceBox: CGRect
    let referenceCornerRadius: CGFloat
    let lines: [Line]
    /// Safe margin in image pixels.
    let margin: CGFloat
    /// The stamp needs more than the allowed area: the user must shorten or hide a field.
    let overflow: Bool

    /// Box in image pixels (top-left origin).
    var boxRect: CGRect {
        CGRect(x: referenceBox.minX * scale, y: referenceBox.minY * scale,
               width: referenceBox.width * scale, height: referenceBox.height * scale)
    }

    /// Box position as fractions of the image size.
    var normalizedBox: CGRect {
        let box = boxRect
        return CGRect(x: box.minX / imageSize.width, y: box.minY / imageSize.height,
                      width: box.width / imageSize.width, height: box.height / imageSize.height)
    }
}

enum StampRenderer {
    /// Safe distance from every edge: at least 3 % of the short side.
    static let safeMarginRatio: CGFloat = 0.03
    /// A stamp taller than half the image, or covering more than 40 % of it, is an overflow
    /// (it would hide the work): the user is asked to shorten or hide fields.
    static let maxHeightRatio: CGFloat = 0.5
    static let maxAreaRatio: CGFloat = 0.4
    static let referenceShortSide: CGFloat = 1000
    static let boxColor = UIColor(white: 0, alpha: 0.58).cgColor
    static let textColor = UIColor.white.cgColor

    static func layout(lines: [StampLine], settings: StampSettings, imageSize: CGSize) -> StampLayout? {
        guard !lines.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(imageSize.width, imageSize.height) / referenceShortSide
        let size = CGSize(width: imageSize.width / scale, height: imageSize.height / scale)
        let margin = ceil(referenceShortSide * safeMarginRatio)
        let fontSize = referenceShortSide * settings.size.relativeFontSize
        let padding = round(fontSize * 0.45)
        let gap = round(fontSize * 0.18)
        let maxTextWidth = max(1, size.width - 2 * margin - 2 * padding)
        let alignment: CTTextAlignment = settings.position.isLeft ? .left : .right

        var measured: [(NSAttributedString, CGSize)] = []
        for line in lines {
            let font: UIFont = line.style == .primary
                ? .systemFont(ofSize: fontSize, weight: .semibold)
                : .systemFont(ofSize: fontSize * 0.84, weight: .regular)
            let attributed = TextBox.attributed(line.text, style: .init(font: font, color: textColor, alignment: alignment))
            measured.append((attributed, TextBox.measure(attributed, width: maxTextWidth)))
        }
        let textWidth = min(maxTextWidth, measured.map(\.1.width).max() ?? 0)
        let textHeight = measured.map(\.1.height).reduce(0, +) + gap * CGFloat(max(0, measured.count - 1))
        let boxSize = CGSize(width: ceil(textWidth + 2 * padding), height: ceil(textHeight + 2 * padding))
        let overflow = boxSize.height > size.height * maxHeightRatio
            || boxSize.width * boxSize.height > size.width * size.height * maxAreaRatio

        let x = settings.position.isLeft ? margin : size.width - margin - boxSize.width
        let y = settings.position.isTop ? margin : size.height - margin - boxSize.height
        let box = CGRect(origin: CGPoint(x: x, y: y), size: boxSize)

        var cursor = box.minY + padding
        var laidOut: [StampLayout.Line] = []
        for (attributed, measuredSize) in measured {
            laidOut.append(.init(attributed: attributed, rect: CGRect(x: box.minX + padding, y: cursor, width: textWidth, height: measuredSize.height)))
            cursor += measuredSize.height + gap
        }
        return StampLayout(imageSize: imageSize, scale: scale, referenceBox: box, referenceCornerRadius: round(fontSize * 0.35),
                           lines: laidOut, margin: margin * scale, overflow: overflow)
    }

    /// Draws the box and text into a top-left-origin context. `offset` is in image pixels.
    static func draw(_ layout: StampLayout, in context: CGContext, offset: CGPoint = .zero) {
        context.saveGState()
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: layout.scale, y: layout.scale)
        context.setFillColor(boxColor)
        let radius = layout.referenceCornerRadius
        context.addPath(CGPath(roundedRect: layout.referenceBox, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        for line in layout.lines {
            TextBox.draw(line.attributed, in: line.rect, context: context)
        }
        context.restoreGState()
    }

    /// Returns a new sRGB image with the stamp. Throws `stampOverflow` instead of producing a cut stamp.
    static func render(image: CGImage, lines: [StampLine], settings: StampSettings, allowOverflow: Bool = false) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        guard let context = ImageLoader.makeContext(width: image.width, height: image.height) else {
            throw AppError(.exportFailed)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        if let layout = layout(lines: lines, settings: settings, imageSize: size) {
            if layout.overflow && !allowOverflow { throw AppError(.stampOverflow) }
            // Switch to a top-left origin for the stamp.
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            draw(layout, in: context)
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw AppError(.exportFailed) }
        return result
    }

    /// Transparent image of just the stamp box, for the live camera overlay.
    static func overlayImage(_ layout: StampLayout, scale: CGFloat) -> UIImage? {
        let box = layout.boxRect
        guard box.width > 0, box.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: box.size, format: format)
        return renderer.image { ctx in
            draw(layout, in: ctx.cgContext, offset: CGPoint(x: -box.minX, y: -box.minY))
        }
    }
}

/// Builds stamp lines with honest provenance labels (STAMP-01).
enum StampContentBuilder {
    static func lines(input: StampInput, settings: StampSettings, language: AppLanguage, includeLocation: Bool) -> [StampLine] {
        let strings = LocalizedStrings(language: language)
        let formatting = DateTimeFormatting(locale: strings.locale, dateStyle: settings.dateStyle, timeFormat: settings.timeFormat)
        let fields = settings.fields
        var lines: [StampLine] = []

        if fields.dateTime {
            let info = input.dateInfo
            if let local = info.local, info.kind != .unavailable {
                var text = formatting.dateTimeString(local, offsetSeconds: info.offsetSeconds)
                // A manual value is always marked; the mark cannot be turned off on its own.
                if info.kind == .manual { text += " · " + strings.t("stamp.label.manualDate") }
                if info.kind == .importedNoOffset { text += " · " + strings.t("stamp.label.timeZoneUnknown") }
                lines.append(StampLine(text: text, style: .primary))
            } else {
                lines.append(StampLine(text: strings.t("stamp.label.captureTimeUnavailable"), style: .primary))
            }
        }

        if fields.projectName, let title = input.projectTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            lines.append(StampLine(text: title, style: .secondary))
        }

        if includeLocation, let location = input.location {
            if fields.address, let address = location.displayAddress {
                lines.append(StampLine(text: addressLine(address, location: location, strings: strings), style: .secondary))
            }
            if fields.coordinates, location.hasCoordinates {
                lines.append(StampLine(text: coordinateLine(location, strings: strings), style: .secondary))
            }
        }

        if fields.caption {
            let caption = input.shortCaption.trimmingCharacters(in: .whitespacesAndNewlines)
            if !caption.isEmpty { lines.append(StampLine(text: caption, style: .secondary)) }
        }

        if input.isImported {
            lines.append(StampLine(text: strings.t("stamp.label.imported"), style: .secondary))
        }
        return lines
    }

    static func addressLine(_ address: String, location: PhotoLocation, strings: LocalizedStrings) -> String {
        switch location.displayAddressKind {
        case .manual: return address + " · " + strings.t("stamp.label.manualLocation")
        case .project: return address + " · " + strings.t("stamp.label.projectAddress")
        case .geocoded, .none:
            if location.isApproximate { return "≈ " + address + " · " + strings.t("stamp.label.approximate") }
            if location.source == .exif { return address + " · " + strings.t("stamp.label.fromFile") }
            return address
        }
    }

    static func coordinateLine(_ location: PhotoLocation, strings: LocalizedStrings) -> String {
        guard var text = CoordinateFormatting.string(location) else { return "" }
        if let accuracy = location.horizontalAccuracy {
            text += " ±" + DistanceFormatting.string(meters: accuracy, locale: strings.locale)
        }
        if location.isApproximate { text += " · " + strings.t("stamp.label.approximate") }
        if location.source == .exif { text += " · " + strings.t("stamp.label.fromFile") }
        return text
    }
}

enum CoordinateFormatting {
    /// "40.71280° N, 74.00600° W" — fixed decimal point so values are unambiguous.
    static func string(latitude: Double, longitude: Double, decimals: Int = 5) -> String {
        let lat = String(format: "%.\(decimals)f° %@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.\(decimals)f° %@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }

    /// Coordinates of a photo rounded to their real precision; nil without coordinates.
    static func string(_ location: PhotoLocation) -> String? {
        guard let lat = location.latitude, let lon = location.longitude else { return nil }
        return string(latitude: lat, longitude: lon, decimals: location.coordinateDecimals)
    }

    static func rounded(_ value: Double, decimals: Int) -> Double {
        let scale = pow(10, Double(decimals))
        return (value * scale).rounded() / scale
    }
}

enum DistanceFormatting {
    static func string(meters: Double, locale: Locale) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitStyle = .medium
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = meters >= 1000 ? 1 : 0
        return formatter.string(from: Measurement(value: meters.rounded(), unit: UnitLength.meters))
    }
}
