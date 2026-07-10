import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageWriteError: Error, CustomStringConvertible {
    case cropFailed
    case encodeFailed(URL)

    var description: String {
        switch self {
        case .cropFailed: "failed to crop figure region"
        case .encodeFailed(let u): "failed to write \(u.path)"
        }
    }
}

/// Crops `normalizedRect` (Vision space, origin bottom-left) out of `image` and
/// writes it as PNG. `padding` is a fraction of the page's shorter side.
func writeFigure(
    from image: CGImage, normalizedRect: CGRect, padding: CGFloat, to url: URL
) throws {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let pad = padding * min(w, h)

    let x = normalizedRect.minX * w - pad
    let y = (1 - normalizedRect.maxY) * h - pad
    let width = normalizedRect.width * w + pad * 2
    let height = normalizedRect.height * h + pad * 2

    let clamped = CGRect(x: x, y: y, width: width, height: height)
        .intersection(CGRect(x: 0, y: 0, width: w, height: h))
    guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
          let cropped = image.cropping(to: clamped.integral)
    else { throw ImageWriteError.cropFailed }

    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ImageWriteError.encodeFailed(url) }
    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageWriteError.encodeFailed(url) }
}
