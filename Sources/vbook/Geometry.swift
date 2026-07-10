import CoreGraphics
import Foundation

func boundingRect(_ points: [CGPoint]) -> CGRect {
    guard let first = points.first else { return .zero }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for p in points.dropFirst() {
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

func unionRect(_ rects: [CGRect]) -> CGRect {
    guard var acc = rects.first else { return .zero }
    for r in rects.dropFirst() { acc = acc.union(r) }
    return acc
}

/// Fraction of `rect`'s area that lies inside `container`.
func containment(of rect: CGRect, in container: CGRect) -> CGFloat {
    let area = rect.width * rect.height
    guard area > 0 else { return 0 }
    let overlap = rect.intersection(container)
    guard !overlap.isNull else { return 0 }
    return (overlap.width * overlap.height) / area
}

private let debugEnabled = ProcessInfo.processInfo.environment["VBOOK_DEBUG"] != nil

func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data(("[vbook] " + message() + "\n").utf8))
}
