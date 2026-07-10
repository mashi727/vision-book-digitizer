import CoreGraphics
import Foundation

struct FigureOptions: Sendable {
    var minAreaFraction: Double = 0.015
    var marginFraction: Double = 0.03
    /// Long side of the downsampled image used for the connected-component pass.
    var analysisLongSide: Int = 1400
    var cellSize: Int = 4
    var mergeGapFraction: Double = 0.02
    /// Text quads are dilated by this multiple of the median line thickness before
    /// being subtracted, so ruby, diacritics and stroke tails don't survive as ink.
    var textDilation: CGFloat = 0.7
    var minDensity: Double = 0.02
    var minSideFraction: Double = 0.05
    var maxFiguresPerPage: Int = 12
}

/// A page only counts as running text — and therefore may not host a figure that
/// spans it — when it has both many lines and real text coverage. Area alone is a
/// bad test: Vision reports a lone graphic shape as a one-character line with a
/// large bounding box.
private let textPageMinLines = 5
private let textPageMinAreaFraction: CGFloat = 0.02
private let fullPageCoverage = 0.92

/// Finds figure regions by removing recognized text from the page's ink and
/// grouping what remains. Returns normalized rects (origin bottom-left).
func detectFigures(image: CGImage, page: PageOCR, options: FigureOptions) -> [CGRect] {
    let (width, height) = analysisSize(image, longSide: options.analysisLongSide)
    guard width > 8, height > 8 else { return [] }
    guard let gray = grayscaleBuffer(image, width: width, height: height) else { return [] }

    let threshold = otsuThreshold(gray.pixels)
    let shortSide = CGFloat(min(width, height))
    let dilation = min(max(1.0, options.textDilation * page.lineThickness * shortSide), 0.02 * shortSide)
    guard let text = textMaskBuffer(page.lineQuads, width: width, height: height, dilation: dilation)
    else { return [] }

    let cell = max(2, options.cellSize)
    let gridW = (width + cell - 1) / cell
    let gridH = (height + cell - 1) / cell

    let marginX = Int(Double(width) * options.marginFraction)
    let marginY = Int(Double(height) * options.marginFraction)

    var occupied = [Bool](repeating: false, count: gridW * gridH)
    for y in marginY..<(height - marginY) {
        let grow = gray.bytesPerRow * y
        let trow = text.bytesPerRow * y
        let gy = y / cell
        for x in marginX..<(width - marginX) {
            guard gray.pixels[grow + x] < threshold else { continue }
            guard text.pixels[trow + x] < 128 else { continue }
            occupied[gy * gridW + x / cell] = true
        }
    }

    var components = connectedComponents(occupied, gridW: gridW, gridH: gridH)
    debugLog("threshold=\(threshold) dilation=\(String(format: "%.1f", dilation)) "
        + "grid=\(gridW)x\(gridH) lines=\(page.lineQuads.count) "
        + "textArea=\(String(format: "%.4f", page.textAreaFraction)) components=\(components.count)")

    let minCells = 12
    components = components.filter { $0.cells >= minCells }
    debugLog("  after minCells: \(components.count)")

    let gap = max(1, Int(Double(min(gridW, gridH)) * options.mergeGapFraction))
    var boxes = mergeBoxes(components.map(\.box), gap: gap)

    let pageCells = Double(gridW * gridH)
    let minSideW = Double(gridW) * options.minSideFraction
    let minSideH = Double(gridH) * options.minSideFraction

    debugLog("  merged boxes: \(boxes.count)")
    boxes = boxes.filter { box in
        let w = Double(box.maxX - box.minX + 1)
        let h = Double(box.maxY - box.minY + 1)
        let area = (w * h) / pageCells
        let density = Double(cellsInside(components, box: box)) / (w * h)
        let keep = w >= minSideW && h >= minSideH && area >= options.minAreaFraction
            && density >= options.minDensity
        debugLog(String(format: "    box %dx%d area=%.4f density=%.3f -> %@",
                        Int(w), Int(h), area, density, keep ? "keep" : "drop"))
        return keep
    }

    // A box covering nearly the whole page is either a full-page plate or a dark
    // scan whose ink test failed. Only a page without running text can be a plate.
    let isTextPage = page.lineQuads.count >= textPageMinLines
        && page.textAreaFraction > textPageMinAreaFraction
    if isTextPage {
        boxes = boxes.filter { Double(boxArea($0)) / pageCells <= fullPageCoverage }
    }

    boxes.sort { boxArea($0) > boxArea($1) }
    boxes = Array(boxes.prefix(options.maxFiguresPerPage))

    return boxes.map { box in
        let x0 = Double(box.minX * cell) / Double(width)
        let x1 = Double(min(width, (box.maxX + 1) * cell)) / Double(width)
        let yTop = Double(box.minY * cell) / Double(height)
        let yBottom = Double(min(height, (box.maxY + 1) * cell)) / Double(height)
        return CGRect(x: x0, y: 1 - yBottom, width: x1 - x0, height: yBottom - yTop)
    }
}

// MARK: - Rasterization

private struct Buffer {
    var pixels: [UInt8]
    var bytesPerRow: Int
}

private func analysisSize(_ image: CGImage, longSide: Int) -> (Int, Int) {
    let w = image.width, h = image.height
    guard max(w, h) > longSide else { return (w, h) }
    let scale = Double(longSide) / Double(max(w, h))
    return (max(1, Int(Double(w) * scale)), max(1, Int(Double(h) * scale)))
}

/// Row 0 of the returned buffer is the top of the page: CGBitmapContext memory
/// starts at the pixel that becomes (0,0) of the CGImage, which is top-left.
private func grayscaleBuffer(_ image: CGImage, width: Int, height: Int) -> Buffer? {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return copyOut(ctx, width: width, height: height)
}

private func textMaskBuffer(_ quads: [[CGPoint]], width: Int, height: Int, dilation: CGFloat) -> Buffer? {
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.setStrokeColor(gray: 1, alpha: 1)
    ctx.setLineWidth(dilation * 2)
    ctx.setLineJoin(.round)

    // Quads are in Vision's y-up normalized space, which matches CGContext user
    // space, so no flip is needed here.
    for quad in quads where quad.count == 4 {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: quad[0].x * CGFloat(width), y: quad[0].y * CGFloat(height)))
        for p in quad.dropFirst() {
            path.addLine(to: CGPoint(x: p.x * CGFloat(width), y: p.y * CGFloat(height)))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
    }
    return copyOut(ctx, width: width, height: height)
}

private func copyOut(_ ctx: CGContext, width: Int, height: Int) -> Buffer? {
    guard let data = ctx.data else { return nil }
    let bytesPerRow = ctx.bytesPerRow
    let count = bytesPerRow * height
    let p = data.bindMemory(to: UInt8.self, capacity: count)
    return Buffer(pixels: Array(UnsafeBufferPointer(start: p, count: count)), bytesPerRow: bytesPerRow)
}

// MARK: - Thresholding

func otsuThreshold(_ pixels: [UInt8]) -> UInt8 {
    var histogram = [Int](repeating: 0, count: 256)
    for v in pixels { histogram[Int(v)] += 1 }
    let total = pixels.count
    guard total > 0 else { return 128 }

    var sum = 0.0
    for i in 0..<256 { sum += Double(i) * Double(histogram[i]) }

    var sumBackground = 0.0
    var weightBackground = 0
    var best = 0.0
    var threshold = 128

    for t in 0..<256 {
        weightBackground += histogram[t]
        guard weightBackground > 0 else { continue }
        let weightForeground = total - weightBackground
        guard weightForeground > 0 else { break }
        sumBackground += Double(t) * Double(histogram[t])
        let meanBackground = sumBackground / Double(weightBackground)
        let meanForeground = (sum - sumBackground) / Double(weightForeground)
        let variance = Double(weightBackground) * Double(weightForeground)
            * (meanBackground - meanForeground) * (meanBackground - meanForeground)
        if variance > best {
            best = variance
            threshold = t
        }
    }
    return UInt8(threshold)
}

// MARK: - Connected components

struct GridBox: Sendable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
}

private struct Component {
    var box: GridBox
    var cells: Int
}

private func boxArea(_ b: GridBox) -> Int { (b.maxX - b.minX + 1) * (b.maxY - b.minY + 1) }

private func connectedComponents(_ occupied: [Bool], gridW: Int, gridH: Int) -> [Component] {
    var seen = [Bool](repeating: false, count: occupied.count)
    var result: [Component] = []
    var stack: [Int] = []

    for start in 0..<occupied.count where occupied[start] && !seen[start] {
        seen[start] = true
        stack.removeAll(keepingCapacity: true)
        stack.append(start)

        var box = GridBox(minX: start % gridW, minY: start / gridW, maxX: start % gridW, maxY: start / gridW)
        var cells = 0

        while let index = stack.popLast() {
            cells += 1
            let x = index % gridW, y = index / gridW
            box.minX = min(box.minX, x); box.maxX = max(box.maxX, x)
            box.minY = min(box.minY, y); box.maxY = max(box.maxY, y)

            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < gridW, ny >= 0, ny < gridH else { continue }
                    let n = ny * gridW + nx
                    guard occupied[n], !seen[n] else { continue }
                    seen[n] = true
                    stack.append(n)
                }
            }
        }
        result.append(Component(box: box, cells: cells))
    }
    return result
}

private func cellsInside(_ components: [Component], box: GridBox) -> Int {
    components.reduce(0) { total, c in
        let inside = c.box.minX >= box.minX && c.box.maxX <= box.maxX
            && c.box.minY >= box.minY && c.box.maxY <= box.maxY
        return total + (inside ? c.cells : 0)
    }
}

private func mergeBoxes(_ boxes: [GridBox], gap: Int) -> [GridBox] {
    var boxes = boxes
    var merged = true
    while merged {
        merged = false
        outer: for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                if near(boxes[i], boxes[j], gap: gap) {
                    boxes[i] = GridBox(
                        minX: min(boxes[i].minX, boxes[j].minX),
                        minY: min(boxes[i].minY, boxes[j].minY),
                        maxX: max(boxes[i].maxX, boxes[j].maxX),
                        maxY: max(boxes[i].maxY, boxes[j].maxY))
                    boxes.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
    }
    return boxes
}

private func near(_ a: GridBox, _ b: GridBox, gap: Int) -> Bool {
    let xOverlap = a.minX - gap <= b.maxX && b.minX - gap <= a.maxX
    let yOverlap = a.minY - gap <= b.maxY && b.minY - gap <= a.maxY
    return xOverlap && yOverlap
}
