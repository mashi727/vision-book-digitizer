import CoreGraphics
import Foundation
import PDFKit

enum RenderError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case locked(String)
    case empty(String)
    case pageFailed(Int)

    var description: String {
        switch self {
        case .cannotOpen(let p): "cannot open PDF: \(p)"
        case .locked(let p): "PDF is password protected: \(p)"
        case .empty(let p): "PDF has no pages: \(p)"
        case .pageFailed(let n): "failed to render page \(n)"
        }
    }
}

struct PDFRenderer {
    let document: PDFDocument
    let path: String

    init(url: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw RenderError.cannotOpen(url.path) }
        guard !doc.isLocked else { throw RenderError.locked(url.path) }
        guard doc.pageCount > 0 else { throw RenderError.empty(url.path) }
        document = doc
        path = url.path
    }

    var pageCount: Int { document.pageCount }

    var metadataTitle: String? {
        let t = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        let trimmed = t?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Renders a 0-based page at `dpi`. Uses CGPDFPage.getDrawingTransform so the
    /// page's /Rotate entry is honored without hand-rolling the rotation math.
    func render(pageIndex: Int, dpi: Double) throws -> CGImage {
        guard let page = document.page(at: pageIndex), let cgPage = page.pageRef else {
            throw RenderError.pageFailed(pageIndex + 1)
        }
        let box = CGPDFBox.cropBox
        let boxRect = cgPage.getBoxRect(box)
        guard boxRect.width > 0, boxRect.height > 0 else { throw RenderError.pageFailed(pageIndex + 1) }

        let rotation = ((cgPage.rotationAngle % 360) + 360) % 360
        let quarterTurned = rotation == 90 || rotation == 270
        let ptW = quarterTurned ? boxRect.height : boxRect.width
        let ptH = quarterTurned ? boxRect.width : boxRect.height

        let scale = dpi / 72.0
        let pxW = max(1, Int((ptW * scale).rounded()))
        let pxH = max(1, Int((ptH * scale).rounded()))

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderError.pageFailed(pageIndex + 1) }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)

        let dest = CGRect(x: 0, y: 0, width: ptW, height: ptH)
        ctx.concatenate(cgPage.getDrawingTransform(box, rect: dest, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: boxRect)
        ctx.drawPDFPage(cgPage)

        guard let image = ctx.makeImage() else { throw RenderError.pageFailed(pageIndex + 1) }
        return image
    }
}
