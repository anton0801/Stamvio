import CoreGraphics
import Foundation
import UIKit

/// One drawable item of a PDF page. Rects are in PDF points with a top-left origin.
enum PDFElement {
    case text(NSAttributedString, CGRect)
    /// Photo drawn aspect-fit (never cropped) exactly into the rect.
    case photo(UUID, CGRect)
    case frame(CGRect)
    case rule(CGRect)
    case logo(CGRect)
}

struct ReportPage {
    var elements: [PDFElement] = []
}

/// Print theme: always light, independent of the app theme (section 1.1).
struct ReportStyle {
    static let margin: CGFloat = 40           // 14.1 mm ≥ 14 mm
    static let headerHeight: CGFloat = 24
    static let footerHeight: CGFloat = 24
    static let titleSize: CGFloat = 20
    static let headingSize: CGFloat = 13
    static let bodySize: CGFloat = 11
    static let technicalSize: CGFloat = 9      // technical captions never below 9 pt
    static let gap: CGFloat = 6
    static let itemGap: CGFloat = 18
    static let minImageHeight: CGFloat = 150
    static let minPairImageHeight: CGFloat = 120
    static let columnGap: CGFloat = 14

    static let textColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1).cgColor
    static let secondaryColor = UIColor(red: 0.33, green: 0.33, blue: 0.36, alpha: 1).cgColor
    static let accentColor = UIColor(red: 0.07, green: 0.36, blue: 0.80, alpha: 1).cgColor
    static let ruleColor = UIColor(red: 0.82, green: 0.82, blue: 0.84, alpha: 1).cgColor
    static let frameColor = UIColor(red: 0.88, green: 0.88, blue: 0.90, alpha: 1).cgColor

    let pageSize: CGSize

    var contentRect: CGRect {
        CGRect(x: Self.margin, y: Self.margin + Self.headerHeight,
               width: pageSize.width - 2 * Self.margin,
               height: pageSize.height - 2 * Self.margin - Self.headerHeight - Self.footerHeight)
    }

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func style(_ size: CGFloat, _ weight: UIFont.Weight = .regular, color: CGColor = textColor,
                      alignment: CTTextAlignment = .left) -> TextBox.Style {
        TextBox.Style(font: font(size, weight), color: color, alignment: alignment, lineSpacing: size * 0.18)
    }
}

/// Provenance wording shared by reports and photo details (PDF-02: a mark next to each field).
enum ProvenanceText {
    static func time(_ info: PhotoDateInfo, isImported: Bool, strings: LocalizedStrings, formatting: DateTimeFormatting) -> String {
        guard let local = info.local, info.kind != .unavailable else {
            return strings.t("provenance.time.unavailable")
        }
        let value = formatting.dateTimeString(local, offsetSeconds: info.offsetSeconds)
        var label = strings.t(info.provenanceKey)
        if info.kind == .manual, isImported { label += ", " + strings.t("provenance.photo.imported") }
        return "\(value) · \(label)"
    }

    static func locationLabel(_ location: PhotoLocation, strings: LocalizedStrings) -> String {
        switch location.displayAddressKind {
        case .manual: return strings.t("provenance.location.manual")
        case .project: return strings.t("provenance.location.project")
        case .geocoded, .none: return coordinateLabel(location, strings: strings)
        }
    }

    static func coordinateLabel(_ location: PhotoLocation, strings: LocalizedStrings) -> String {
        if location.source == .exif { return strings.t("provenance.location.file") }
        let accuracy = location.horizontalAccuracy.map { DistanceFormatting.string(meters: $0, locale: strings.locale) }
        if location.isApproximate {
            return accuracy.map { strings.t("provenance.location.approximateAccuracy", $0) } ?? strings.t("provenance.location.approximate")
        }
        return accuracy.map { strings.t("provenance.location.gps", $0) } ?? strings.t("provenance.location.gpsNoAccuracy")
    }
}

/// Paginates a report snapshot into pages of elements. Text is never shrunk: long text moves to the
/// next page or continues there; only image heights adapt (never below a readable minimum).
struct ReportLayoutEngine {
    let snapshot: ReportSnapshot
    let strings: LocalizedStrings
    let formatting: DateTimeFormatting
    let style: ReportStyle
    /// width / height of the logo, when a logo is drawn (Pro).
    let logoAspect: CGFloat?

    init(snapshot: ReportSnapshot, logoAspect: CGFloat?) {
        self.snapshot = snapshot
        self.strings = LocalizedStrings(language: snapshot.settings.language)
        self.formatting = DateTimeFormatting(locale: strings.locale, dateStyle: snapshot.settings.dateStyle,
                                             timeFormat: snapshot.settings.timeFormat)
        self.style = ReportStyle(pageSize: snapshot.settings.pageSize.pointSize)
        self.logoAspect = logoAspect
    }

    private final class Flow {
        let content: CGRect
        var pages: [ReportPage] = []
        var current = ReportPage()
        var y: CGFloat
        var itemsOnPage = 0

        init(content: CGRect) {
            self.content = content
            self.y = content.minY
        }

        var remaining: CGFloat { content.maxY - y }
        var isAtTop: Bool { y <= content.minY + 0.5 }

        func add(_ element: PDFElement) { current.elements.append(element) }

        func newPage() {
            pages.append(current)
            current = ReportPage()
            y = content.minY
            itemsOnPage = 0
        }

        func finish() -> [ReportPage] {
            if !current.elements.isEmpty || pages.isEmpty { pages.append(current) }
            return pages
        }
    }

    func makePages() -> [ReportPage] {
        let flow = Flow(content: style.contentRect)
        appendTitleBlock(flow)
        switch snapshot.settings.template {
        case .standard: layoutStandard(flow)
        case .beforeAfter: layoutPairs(flow)
        }
        return flow.finish()
    }

    // MARK: Text helpers

    /// ": " — with the typographic space French needs before a colon (" : ").
    private var separator: String { strings.t("report.labelSeparator") }

    private func paragraph(_ text: String, _ size: CGFloat, _ weight: UIFont.Weight = .regular,
                           color: CGColor = ReportStyle.textColor) -> NSAttributedString {
        TextBox.attributed(text, style: ReportStyle.style(size, weight, color: color))
    }

    private func joined(_ parts: [NSAttributedString]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                let separator = NSMutableAttributedString(string: "\n")
                if part.length > 0 {
                    separator.setAttributes(part.attributes(at: 0, effectiveRange: nil), range: NSRange(location: 0, length: 1))
                }
                result.append(separator)
            }
            result.append(part)
        }
        return result
    }

    /// Adds text at the cursor, continuing on new pages when needed (never shrinks it).
    private func appendFlowingText(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
                                   color: CGColor = ReportStyle.textColor, flow: Flow, spacingAfter: CGFloat) {
        var rest = text
        let width = flow.content.width
        while !rest.isEmpty {
            let style = ReportStyle.style(size, weight, color: color)
            let attributed = TextBox.attributed(rest, style: style)
            let height = TextBox.measure(attributed, width: width).height
            if height <= flow.remaining {
                flow.add(.text(attributed, CGRect(x: flow.content.minX, y: flow.y, width: width, height: height)))
                flow.y += height + spacingAfter
                return
            }
            let parts = TextBox.split(rest, style: style, width: width, height: flow.remaining)
            if parts.head.isEmpty {
                if flow.isAtTop { // Should not happen with real content; avoid an endless loop.
                    flow.add(.text(attributed, CGRect(x: flow.content.minX, y: flow.y, width: width, height: flow.remaining)))
                    flow.newPage()
                    return
                }
                flow.newPage()
                continue
            }
            let head = TextBox.attributed(parts.head, style: style)
            let headHeight = TextBox.measure(head, width: width).height
            flow.add(.text(head, CGRect(x: flow.content.minX, y: flow.y, width: width, height: headHeight)))
            flow.newPage()
            rest = parts.tail
        }
    }

    // MARK: Title block (first page — never a separate empty cover)

    private func appendTitleBlock(_ flow: Flow) {
        let settings = snapshot.settings
        let project = snapshot.project
        let content = flow.content
        let reportTitle = settings.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? project.title : settings.title.trimmingCharacters(in: .whitespacesAndNewlines)

        var logoWidth: CGFloat = 0
        if let aspect = logoAspect, aspect > 0 {
            let maxSize = CGSize(width: 130, height: 52)
            var size = CGSize(width: maxSize.height * aspect, height: maxSize.height)
            if size.width > maxSize.width { size = CGSize(width: maxSize.width, height: maxSize.width / aspect) }
            flow.add(.logo(CGRect(x: content.maxX - size.width, y: content.minY, width: size.width, height: size.height)))
            logoWidth = size.width + 12
        }

        let titleString = paragraph(reportTitle, ReportStyle.titleSize, .bold)
        let titleWidth = content.width - logoWidth
        let titleHeight = TextBox.measure(titleString, width: titleWidth).height
        flow.add(.text(titleString, CGRect(x: content.minX, y: flow.y, width: titleWidth, height: titleHeight)))
        flow.y += titleHeight + 4

        var rows: [(String, String)] = []
        if reportTitle != project.title { rows.append((strings.t("report.field.project"), project.title)) }
        if settings.includeProjectAddress, !project.siteAddress.isEmpty {
            rows.append((strings.t("report.field.siteAddress"), project.siteAddress))
        }
        if settings.includeClient, !project.clientName.isEmpty { rows.append((strings.t("report.field.client"), project.clientName)) }
        if settings.includeWorkDate, let workDate = project.workDate {
            rows.append((strings.t("report.field.workDate"), formatting.workDateString(workDate)))
        }
        if settings.includeExecutor {
            let executor = [snapshot.branding.executorName, snapshot.branding.contactText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !executor.isEmpty { rows.append((strings.t("report.field.preparedBy"), executor)) }
        }
        let created = LocalDateTime(date: snapshot.createdAt, offsetSeconds: snapshot.createdOffsetSeconds)
        rows.append((strings.t("report.field.created"), formatting.dateTimeString(created, offsetSeconds: snapshot.createdOffsetSeconds)))
        let countText = settings.template == .standard
            ? strings.t("report.count.photos", snapshot.photos.count)
            : strings.t("report.count.pairs", snapshot.pairs.count)
        rows.append((strings.t("report.field.contents"), countText))

        let rowWidth = content.width - logoWidth
        for (label, value) in rows {
            let line = NSMutableAttributedString(attributedString: paragraph(label + separator, ReportStyle.bodySize, .semibold))
            line.append(paragraph(value, ReportStyle.bodySize))
            let height = TextBox.measure(line, width: rowWidth).height
            flow.add(.text(line, CGRect(x: content.minX, y: flow.y, width: rowWidth, height: height)))
            flow.y += height + 1
        }
        if logoWidth > 0 { flow.y = max(flow.y, content.minY + 56) }

        let summary = settings.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            flow.y += 8
            let heading = paragraph(strings.t("report.field.summary"), ReportStyle.bodySize, .semibold)
            let headingHeight = TextBox.measure(heading, width: content.width).height
            flow.add(.text(heading, CGRect(x: content.minX, y: flow.y, width: content.width, height: headingHeight)))
            flow.y += headingHeight + 2
            appendFlowingText(summary, size: ReportStyle.bodySize, flow: flow, spacingAfter: 0)
        }

        // Legend: sources of times and places.
        var legend = [strings.t("report.legend.time")]
        if settings.includePhotoLocations || settings.includeCoordinates { legend.append(strings.t("report.legend.location")) }
        legend.append(strings.t("report.legend.disclaimer"))
        flow.y += 8
        appendFlowingText(legend.joined(separator: "\n"), size: ReportStyle.technicalSize, color: ReportStyle.secondaryColor,
                          flow: flow, spacingAfter: 6)
        if flow.remaining > 10 {
            flow.add(.rule(CGRect(x: content.minX, y: flow.y, width: content.width, height: 0.5)))
            flow.y += 12
        }
    }

    // MARK: Photo metadata

    private func timeLine(_ photo: ReportSnapshot.PhotoInfo) -> String {
        strings.t("report.field.taken") + separator + ProvenanceText.time(photo.dateInfo, isImported: photo.isImported,
                                                                      strings: strings, formatting: formatting)
    }

    private func locationLines(_ photo: ReportSnapshot.PhotoInfo) -> [String] {
        let settings = snapshot.settings
        guard let location = photo.location else { return [] }
        var lines: [String] = []
        if settings.includePhotoLocations, let address = location.displayAddress {
            let prefix = location.isApproximate && location.displayAddressKind == .geocoded ? "≈ " : ""
            lines.append(strings.t("report.field.location") + separator + prefix + address + " · "
                         + ProvenanceText.locationLabel(location, strings: strings))
        }
        if settings.includeCoordinates, let coordinates = CoordinateFormatting.string(location) {
            lines.append(strings.t("report.field.coordinates") + separator + coordinates
                         + " · " + ProvenanceText.coordinateLabel(location, strings: strings))
        }
        return lines
    }

    private func technicalText(_ photo: ReportSnapshot.PhotoInfo) -> NSAttributedString {
        let lines = [timeLine(photo)] + locationLines(photo)
        return joined(lines.map { paragraph($0, ReportStyle.technicalSize, color: ReportStyle.secondaryColor) })
    }

    private func standardMeta(_ photo: ReportSnapshot.PhotoInfo, number: Int) -> NSAttributedString {
        let caption = photo.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = caption.isEmpty
            ? strings.t("report.photo.number", number)
            : "\(number). \(caption)"
        return joined([paragraph(heading, ReportStyle.bodySize, caption.isEmpty ? .semibold : .regular), technicalText(photo)])
    }

    private func aspectFit(_ aspect: CGFloat, in box: CGRect) -> CGRect {
        guard box.width > 0, box.height > 0, aspect > 0 else { return box }
        var size: CGSize
        if aspect > box.width / box.height {
            size = CGSize(width: box.width, height: box.width / aspect)
        } else {
            size = CGSize(width: box.height * aspect, height: box.height)
        }
        size = CGSize(width: floor(size.width), height: floor(size.height))
        return CGRect(x: box.midX - size.width / 2, y: box.minY, width: size.width, height: size.height)
    }

    // MARK: Standard (up to two photos per page)

    private func layoutStandard(_ flow: Flow) {
        let content = flow.content
        let maxImageHeight = floor((content.height - ReportStyle.itemGap) / 2) - 66
        for (index, photo) in snapshot.photos.enumerated() {
            let meta = standardMeta(photo, number: index + 1)
            let metaHeight = TextBox.measure(meta, width: content.width).height
            let idealHeight = min(floor(content.width / photo.aspectRatio), maxImageHeight)

            while true {
                if flow.itemsOnPage >= 2 { flow.newPage(); continue }
                let available = flow.remaining
                if idealHeight + ReportStyle.gap + metaHeight <= available {
                    place(photo, meta: meta, metaHeight: metaHeight, imageHeight: idealHeight, flow: flow)
                    break
                }
                let reduced = floor(available - ReportStyle.gap - metaHeight)
                if reduced >= ReportStyle.minImageHeight {
                    place(photo, meta: meta, metaHeight: metaHeight, imageHeight: reduced, flow: flow)
                    break
                }
                if flow.isAtTop {
                    // Text is longer than a page: image plus as much text as fits, the rest continues.
                    placeWithContinuation(photo, number: index + 1, imageHeight: min(idealHeight, floor(content.height * 0.5)), flow: flow)
                    break
                }
                flow.newPage()
            }
        }
    }

    private func place(_ photo: ReportSnapshot.PhotoInfo, meta: NSAttributedString, metaHeight: CGFloat,
                       imageHeight: CGFloat, flow: Flow) {
        let box = CGRect(x: flow.content.minX, y: flow.y, width: flow.content.width, height: imageHeight)
        let imageRect = aspectFit(photo.aspectRatio, in: box)
        flow.add(.frame(imageRect))
        flow.add(.photo(photo.id, imageRect))
        let textRect = CGRect(x: flow.content.minX, y: imageRect.maxY + ReportStyle.gap, width: flow.content.width, height: metaHeight)
        flow.add(.text(meta, textRect))
        flow.y = textRect.maxY + ReportStyle.itemGap
        flow.itemsOnPage += 1
    }

    private func placeWithContinuation(_ photo: ReportSnapshot.PhotoInfo, number: Int, imageHeight: CGFloat, flow: Flow) {
        let box = CGRect(x: flow.content.minX, y: flow.y, width: flow.content.width, height: imageHeight)
        let imageRect = aspectFit(photo.aspectRatio, in: box)
        flow.add(.frame(imageRect))
        flow.add(.photo(photo.id, imageRect))
        flow.y = imageRect.maxY + ReportStyle.gap
        let caption = photo.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = caption.isEmpty ? strings.t("report.photo.number", number) : "\(number). \(caption)"
        appendFlowingText(heading, size: ReportStyle.bodySize, flow: flow, spacingAfter: 2)
        let technical = ([timeLine(photo)] + locationLines(photo)).joined(separator: "\n")
        appendFlowingText(technical, size: ReportStyle.technicalSize, color: ReportStyle.secondaryColor, flow: flow,
                          spacingAfter: ReportStyle.itemGap)
        flow.itemsOnPage = 2 // keep the next photo on a fresh page
    }

    // MARK: Before / After (one pair per page)

    private struct PairArrangement {
        let sideBySide: Bool
        let imageHeight: CGFloat
        let score: CGFloat
    }

    private func layoutPairs(_ flow: Flow) {
        let content = flow.content
        for (index, pair) in snapshot.pairs.enumerated() {
            guard let before = snapshot.photo(pair.beforeID), let after = snapshot.photo(pair.afterID) else { continue }
            if index > 0 || flow.itemsOnPage > 0 { flow.newPage() }

            let title = pair.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let headingText = title.isEmpty ? strings.t("report.pair.number", index + 1) : "\(index + 1). \(title)"
            let heading = paragraph(headingText, ReportStyle.headingSize, .semibold)
            let headingHeight = TextBox.measure(heading, width: content.width).height
            let caption = pair.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let captionString = paragraph(caption, ReportStyle.bodySize)
            let captionHeight = caption.isEmpty ? 0 : TextBox.measure(captionString, width: content.width).height + ReportStyle.gap * 2

            let beforeMeta = technicalText(before)
            let afterMeta = technicalText(after)
            let label = paragraph(strings.t("report.before"), 10, .bold, color: ReportStyle.accentColor)
            let labelHeight = TextBox.measure(label, width: content.width).height

            func arrangement(reservingCaption: Bool, available: CGFloat) -> PairArrangement? {
                let reserve = reservingCaption ? captionHeight : 0
                let space = available - headingHeight - ReportStyle.gap - reserve
                // Side by side.
                let column = (content.width - ReportStyle.columnGap) / 2
                let metaSide = max(TextBox.measure(beforeMeta, width: column).height, TextBox.measure(afterMeta, width: column).height)
                let sideHeight = floor(space - labelHeight - metaSide - 2 * ReportStyle.gap)
                // Stacked.
                let metaStack = TextBox.measure(beforeMeta, width: content.width).height + TextBox.measure(afterMeta, width: content.width).height
                let stackHeight = floor((space - 2 * labelHeight - metaStack - 4 * ReportStyle.gap - ReportStyle.itemGap) / 2)

                func score(_ width: CGFloat, _ height: CGFloat) -> CGFloat {
                    guard height >= ReportStyle.minPairImageHeight else { return -1 }
                    let a = aspectFit(before.aspectRatio, in: CGRect(x: 0, y: 0, width: width, height: height))
                    let b = aspectFit(after.aspectRatio, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return min(a.width * a.height, b.width * b.height)
                }
                let side = score(column, sideHeight)
                let stack = score(content.width, stackHeight)
                if side < 0 && stack < 0 { return nil }
                return side >= stack
                    ? PairArrangement(sideBySide: true, imageHeight: sideHeight, score: side)
                    : PairArrangement(sideBySide: false, imageHeight: stackHeight, score: stack)
            }

            var chosen = arrangement(reservingCaption: true, available: flow.remaining)
                ?? arrangement(reservingCaption: false, available: flow.remaining)
            if chosen == nil, !flow.isAtTop {
                flow.newPage()
                chosen = arrangement(reservingCaption: true, available: flow.remaining)
                    ?? arrangement(reservingCaption: false, available: flow.remaining)
            }
            let layout = chosen ?? PairArrangement(sideBySide: true, imageHeight: ReportStyle.minPairImageHeight, score: 0)

            flow.add(.text(heading, CGRect(x: content.minX, y: flow.y, width: content.width, height: headingHeight)))
            flow.y += headingHeight + ReportStyle.gap

            let beforeLabel = paragraph(strings.t("report.before"), 10, .bold, color: ReportStyle.accentColor)
            let afterLabel = paragraph(strings.t("report.after"), 10, .bold, color: ReportStyle.accentColor)
            if layout.sideBySide {
                let column = (content.width - ReportStyle.columnGap) / 2
                var bottom = flow.y
                for (offset, item) in [(0, (before, beforeLabel, beforeMeta)), (1, (after, afterLabel, afterMeta))] {
                    let x = content.minX + CGFloat(offset) * (column + ReportStyle.columnGap)
                    var y = flow.y
                    flow.add(.text(item.1, CGRect(x: x, y: y, width: column, height: labelHeight)))
                    y += labelHeight + ReportStyle.gap / 2
                    let rect = aspectFit(item.0.aspectRatio, in: CGRect(x: x, y: y, width: column, height: layout.imageHeight))
                    flow.add(.frame(rect))
                    flow.add(.photo(item.0.id, rect))
                    y = rect.maxY + ReportStyle.gap
                    let metaHeight = TextBox.measure(item.2, width: column).height
                    flow.add(.text(item.2, CGRect(x: x, y: y, width: column, height: metaHeight)))
                    bottom = max(bottom, y + metaHeight)
                }
                flow.y = bottom + ReportStyle.gap
            } else {
                for item in [(before, beforeLabel, beforeMeta), (after, afterLabel, afterMeta)] {
                    flow.add(.text(item.1, CGRect(x: content.minX, y: flow.y, width: content.width, height: labelHeight)))
                    flow.y += labelHeight + ReportStyle.gap / 2
                    let rect = aspectFit(item.0.aspectRatio, in: CGRect(x: content.minX, y: flow.y, width: content.width, height: layout.imageHeight))
                    flow.add(.frame(rect))
                    flow.add(.photo(item.0.id, rect))
                    flow.y = rect.maxY + ReportStyle.gap
                    let metaHeight = TextBox.measure(item.2, width: content.width).height
                    flow.add(.text(item.2, CGRect(x: content.minX, y: flow.y, width: content.width, height: metaHeight)))
                    flow.y += metaHeight + ReportStyle.itemGap / 2
                }
            }
            flow.itemsOnPage = 1

            if !caption.isEmpty {
                flow.y += ReportStyle.gap
                if flow.remaining < 30 {
                    flow.newPage()
                    let continued = paragraph(headingText + " " + strings.t("report.continued"), ReportStyle.headingSize, .semibold)
                    let height = TextBox.measure(continued, width: content.width).height
                    flow.add(.text(continued, CGRect(x: content.minX, y: flow.y, width: content.width, height: height)))
                    flow.y += height + ReportStyle.gap
                    flow.itemsOnPage = 1
                }
                appendFlowingText(caption, size: ReportStyle.bodySize, flow: flow, spacingAfter: ReportStyle.itemGap)
            }
        }
    }
}
