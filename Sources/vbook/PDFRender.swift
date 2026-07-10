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

    /// Renders a 0-based page at `dpi`, but never magnifies a scanned page beyond
    /// the resolution of its own embedded image, and never past `maxLongSide`
    /// pixels. Uses CGPDFPage.getDrawingTransform so the page's /Rotate entry is
    /// honored without hand-rolling the rotation math.
    func render(pageIndex: Int, dpi: Double, maxLongSide: Int = 6000) throws -> CGImage {
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

        var scale = dpi / 72.0

        // A page that is essentially one scanned image has no detail above that
        // image's own resolution; upscaling it just multiplies memory and the load
        // on Vision. Cap the scale to the image's native pixels-per-point.
        if let native = nativeScale(cgPage, pageWidthPt: boxRect.width, pageHeightPt: boxRect.height) {
            scale = min(scale, native)
        }
        // Absolute ceiling so a pathological page can't allocate an enormous bitmap.
        let longSidePt = max(ptW, ptH)
        if longSidePt * scale > Double(maxLongSide) {
            scale = Double(maxLongSide) / longSidePt
        }
        scale = max(scale, 1.0 / 72.0)

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
        debugLog("render page \(pageIndex + 1): \(pxW)x\(pxH) "
            + "(scale \(String(format: "%.2f", scale)), \(Int(scale * 72)) DPI)")
        return image
    }
}

/// Largest embedded-image resolution on the page, expressed as pixels per point
/// (so it can be compared directly with a DPI-derived scale). Returns nil when the
/// page has no raster image — a vector/text page that should honor the full DPI.
private func nativeScale(_ page: CGPDFPage, pageWidthPt: CGFloat, pageHeightPt: CGFloat) -> Double? {
    guard pageWidthPt > 0, pageHeightPt > 0, let dict = page.dictionary else { return nil }
    let maxShortSide = largestImageShortSide(inResourcesOf: dict, depth: 0)
    guard maxShortSide > 0 else { return nil }

    // A full-page image's short side maps to the page's short side, which fixes the
    // pixels-per-point ratio regardless of orientation.
    let shortSidePt = min(pageWidthPt, pageHeightPt)
    return Double(maxShortSide) / Double(shortSidePt)
}

/// Walks the XObject resources (recursing into Form XObjects) and returns the
/// largest `min(width, height)` found among embedded images, in pixels.
private func largestImageShortSide(inResourcesOf node: CGPDFDictionaryRef, depth: Int) -> Int {
    guard depth < 8 else { return 0 }
    var resources: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(node, "Resources", &resources), let res = resources else { return 0 }
    var xobjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects), let xo = xobjects else { return 0 }

    final class Box { var value = 0 }
    let largest = Box()

    CGPDFDictionaryApplyBlock(xo, { _, value, _ in
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(value, .stream, &stream), let s = stream,
              let sdict = CGPDFStreamGetDictionary(s) else { return true }

        var subtype: UnsafePointer<Int8>?
        CGPDFDictionaryGetName(sdict, "Subtype", &subtype)
        let kind = subtype.map { String(cString: $0) }

        if kind == "Image" {
            var w = 0, h = 0
            CGPDFDictionaryGetInteger(sdict, "Width", &w)
            CGPDFDictionaryGetInteger(sdict, "Height", &h)
            if w > 0, h > 0 { largest.value = max(largest.value, min(w, h)) }
        } else if kind == "Form" {
            largest.value = max(largest.value, largestImageShortSide(inResourcesOf: sdict, depth: depth + 1))
        }
        return true
    }, nil)

    return largest.value
}
