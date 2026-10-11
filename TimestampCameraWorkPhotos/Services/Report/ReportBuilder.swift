import CoreGraphics
import Foundation
import UIKit

/// Renders a snapshot to a PDF file page by page with UIGraphicsPDFRenderer. Text stays real
/// (selectable, searchable); photos are downsampled one at a time and embedded as JPEG.
struct ReportBuilder {
    let snapshot: ReportSnapshot
    let files: FileStore

    struct Result {
        let pageCount: Int
    }

    /// - Parameters:
    ///   - progress: called with (pagesDone, totalPages) from the rendering thread.
    ///   - isCancelled: checked between pages; a cancelled build throws `reportCancelled`.
    func build(to url: URL, progress: @escaping (Int, Int) -> Void, isCancelled: @escaping () -> Bool) throws -> Result {
        let logo = loadLogo()
        let engine = ReportLayoutEngine(snapshot: snapshot, logoAspect: logo.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) })
        let pages = engine.makePages()
        let total = pages.count
        let pageRect = CGRect(origin: .zero, size: snapshot.settings.pageSize.pointSize)
        let strings = engine.strings

        let format = UIGraphicsPDFRendererFormat()
        let title = snapshot.settings.title.isEmpty ? snapshot.project.title : snapshot.settings.title
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: snapshot.appName
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        var cancelled = false
        var missingPhoto = false
        let quality = snapshot.settings.quality

        do {
            try renderer.writePDF(to: url) { context in
                for (index, page) in pages.enumerated() {
                    if isCancelled() { cancelled = true; break }
                    context.beginPage()
                    let cg = context.cgContext
                    for element in page.elements {
                        autoreleasepool {
                            switch element {
                            case let .text(string, rect):
                                TextBox.draw(string, in: rect, context: cg)
                            case let .photo(id, rect):
                                if !drawPhoto(id: id, in: rect, quality: quality, context: cg) { missingPhoto = true }
                            case let .frame(rect):
                                cg.setStrokeColor(ReportStyle.frameColor)
                                cg.setLineWidth(0.75)
                                cg.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
                            case let .rule(rect):
                                cg.setFillColor(ReportStyle.ruleColor)
                                cg.fill(rect)
                            case let .logo(rect):
                                if let logo { drawImage(logo, in: rect, context: cg) }
                            }
                        }
                    }
                    drawHeaderFooter(pageIndex: index, total: total, pageRect: pageRect, strings: strings, context: cg)
                    if snapshot.isProPreview { drawPreviewWatermark(pageRect: pageRect, strings: strings, context: cg) }
                    progress(index + 1, total)
                    if missingPhoto { break }
                }
            }
        } catch {
            throw AppError.wrap(error, default: .reportGenerationFailed)
        }
        if cancelled { throw AppError(.reportCancelled) }
        // A report with a hole instead of a photo is never presented as successful.
        if missingPhoto { throw AppError(.reportPhotoMissing) }
        return Result(pageCount: total)
    }

    /// Reads the file back and checks the page count before the report is shown as ready.
    static func verify(url: URL, expectedPages: Int) -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { return false }
        return document.numberOfPages == expectedPages && document.page(at: 1) != nil
    }

    // MARK: Drawing

    private func drawPhoto(id: UUID, in rect: CGRect, quality: ReportQuality, context: CGContext) -> Bool {
        guard let info = snapshot.photo(id), let url = try? files.url(forRelative: info.originalPath),
              FileManager.default.fileExists(atPath: url.path),
              let decoded = ImageLoader.orientedImage(url: url, maxPixel: quality.maxPixel),
              let jpeg = ImageLoader.jpegData(decoded, quality: quality.jpegQuality),
              let image = ImageLoader.jpegBackedImage(jpeg) else { return false }
        drawImage(image, in: rect, context: context)
        return true
    }

    /// The PDF context has a top-left origin; CGContext.draw expects bottom-left, so flip locally.
    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private func drawHeaderFooter(pageIndex: Int, total: Int, pageRect: CGRect, strings: LocalizedStrings, context: CGContext) {
        let margin = ReportStyle.margin
        let width = pageRect.width - 2 * margin
        let small = ReportStyle.style(ReportStyle.technicalSize, color: ReportStyle.secondaryColor)

        if pageIndex > 0 {
            let title = snapshot.settings.title.isEmpty ? snapshot.project.title : snapshot.settings.title
            let header = TextBox.attributed(title, style: small)
            context.saveGState()
            TextBox.draw(header, in: CGRect(x: margin, y: margin, width: width * 0.7, height: 14), context: context)
            context.setFillColor(ReportStyle.ruleColor)
            context.fill(CGRect(x: margin, y: margin + 16, width: width, height: 0.5))
            context.restoreGState()
        }
        if snapshot.isProPreview {
            var right = small
            right.alignment = .right
            right.color = ReportStyle.accentColor
            right.font = ReportStyle.font(ReportStyle.technicalSize, .semibold)
            let banner = TextBox.attributed(strings.t("report.preview.banner"), style: right)
            TextBox.draw(banner, in: CGRect(x: margin + width * 0.3, y: margin, width: width * 0.7, height: 14), context: context)
        }

        let footerY = pageRect.height - margin - 14
        var numberStyle = small
        numberStyle.alignment = .right
        let number = TextBox.attributed("\(pageIndex + 1) / \(total)", style: numberStyle)
        TextBox.draw(number, in: CGRect(x: margin + width - 80, y: footerY, width: 80, height: 14), context: context)
        if snapshot.branding.showCreatedWith {
            let created = TextBox.attributed(strings.t("report.footer.createdWith", snapshot.appName), style: small)
            TextBox.draw(created, in: CGRect(x: margin, y: footerY, width: width - 90, height: 14), context: context)
        }
    }

    private func drawPreviewWatermark(pageRect: CGRect, strings: LocalizedStrings, context: CGContext) {
        let style = TextBox.Style(font: ReportStyle.font(64, .heavy), color: UIColor(red: 0.07, green: 0.36, blue: 0.8, alpha: 0.10).cgColor,
                                  alignment: .center)
        let text = TextBox.attributed(strings.t("report.preview.watermark"), style: style)
        let size = TextBox.measure(text, width: pageRect.width * 1.2)
        context.saveGState()
        context.translateBy(x: pageRect.midX, y: pageRect.midY)
        context.rotate(by: -.pi / 5)
        TextBox.draw(text, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), context: context)
        context.restoreGState()
    }

    private func loadLogo() -> CGImage? {
        guard let path = snapshot.branding.logoPath, let url = try? files.url(forRelative: path) else { return nil }
        return ImageLoader.orientedImage(url: url, maxPixel: 600)
    }
}
