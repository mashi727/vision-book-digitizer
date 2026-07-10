import CoreGraphics
import Foundation

struct PageResult: Sendable {
    var index: Int
    var markdown: String
    var figureCount: Int
}

@main
enum VBook {
    static func main() async {
        do {
            try await run(parseOptions(Array(CommandLine.arguments.dropFirst())))
        } catch let error as OptionError {
            fail("\(error)\n\n\(usage)")
        } catch {
            fail("\(error)")
        }
    }

    static func run(_ options: Options) async throws {
        let renderer = try PDFRenderer(url: options.input)

        let title = options.title
            ?? renderer.metadataTitle
            ?? options.input.deletingPathExtension().lastPathComponent
        let stem = sanitizeFileName(title)

        let outputDir = options.outputDir ?? URL(fileURLWithPath: stem)
        let imagesDirName = "\(stem)_images"
        let imagesDir = outputDir.appendingPathComponent(imagesDirName)

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        if options.extractFigures {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }

        // `clamped(to:)` would silently collapse an out-of-range request onto the
        // last page, so reject it instead.
        let range = options.pages ?? 1...renderer.pageCount
        guard range.lowerBound <= renderer.pageCount else {
            fail("--pages \(range.lowerBound)-\(range.upperBound) is outside a "
                + "\(renderer.pageCount)-page document")
        }
        let pageNumbers = Array(range.lowerBound...min(range.upperBound, renderer.pageCount))

        var figureOptions = FigureOptions()
        figureOptions.minAreaFraction = options.minFigureAreaFraction
        figureOptions.marginFraction = options.marginFraction

        log(options, "Digitizing \(pageNumbers.count) page(s) at \(Int(options.dpi)) DPI…")

        var results: [PageResult] = []
        results.reserveCapacity(pageNumbers.count)

        for chunk in pageNumbers.chunked(into: options.jobs) {
            let images = try chunk.map { try renderer.render(pageIndex: $0 - 1, dpi: options.dpi) }

            try await withThrowingTaskGroup(of: PageResult.self) { group in
                for (image, pageNumber) in zip(images, chunk) {
                    group.addTask {
                        try await process(
                            image: image, pageNumber: pageNumber, options: options,
                            figureOptions: figureOptions, imagesDir: imagesDir,
                            imagesDirName: imagesDirName)
                    }
                }
                for try await result in group { results.append(result) }
            }
            log(options, "  … \(min(results.count, pageNumbers.count))/\(pageNumbers.count)")
        }

        results.sort { $0.index < $1.index }
        let figures = results.reduce(0) { $0 + $1.figureCount }

        var document = "# \(title)\n\n"
        document += results.map(\.markdown).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !document.hasSuffix("\n") { document += "\n" }

        let markdownURL = outputDir.appendingPathComponent("\(stem).md")
        try document.write(to: markdownURL, atomically: true, encoding: .utf8)

        if options.extractFigures, figures == 0 {
            try? FileManager.default.removeItem(at: imagesDir)
        }

        log(options, "Done. \(markdownURL.path) — \(figures) figure(s) extracted.")
    }

    static func process(
        image: CGImage, pageNumber: Int, options: Options, figureOptions: FigureOptions,
        imagesDir: URL, imagesDirName: String
    ) async throws -> PageResult {
        let page = try await recognizePage(image, languages: options.languages)

        var blocks: [PlacedBlock] = []
        var figureRects: [CGRect] = []
        var figureCount = 0

        if options.extractFigures {
            let rects = detectFigures(image: image, page: page, options: figureOptions)
            for (n, rect) in rects.enumerated() {
                let name = String(format: "p%03d-fig%02d.png", pageNumber, n + 1)
                let url = imagesDir.appendingPathComponent(name)
                do {
                    try writeFigure(from: image, normalizedRect: rect, padding: 0.005, to: url)
                } catch {
                    FileHandle.standardError.write(
                        Data("warning: page \(pageNumber): \(error)\n".utf8))
                    continue
                }
                figureCount += 1
                figureRects.append(rect)
                blocks.append(PlacedBlock(
                    rect: rect,
                    block: .figure(path: "\(imagesDirName)/\(name)", alt: "図 \(pageNumber)-\(n + 1)")))
            }
        }

        // Line art reads as stray glyphs often enough that anything sitting inside
        // a figure has to belong to the figure, not to the running text.
        func insideFigure(_ rect: CGRect) -> Bool {
            figureRects.contains { containment(of: rect, in: $0) > 0.8 }
        }

        for paragraph in page.paragraphs where !insideFigure(paragraph.rect) {
            blocks.append(PlacedBlock(
                rect: paragraph.rect,
                block: paragraph.isHeading ? .heading(paragraph.text) : .paragraph(paragraph.text)))
        }
        for table in page.tables where !insideFigure(table.rect) {
            blocks.append(PlacedBlock(rect: table.rect, block: .table(table.rows)))
        }
        for list in page.lists where !insideFigure(list.rect) {
            blocks.append(PlacedBlock(rect: list.rect, block: .list(list.items)))
        }

        let ordered = readingOrder(blocks, direction: page.direction)
        var markdown = renderMarkdown(ordered)
        if options.pageMarkers {
            markdown = "<!-- page \(pageNumber) -->\n\n" + markdown
        }
        return PageResult(index: pageNumber, markdown: markdown, figureCount: figureCount)
    }

    static func log(_ options: Options, _ message: String) {
        guard !options.quiet else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("vbook: " + message + "\n").utf8))
        exit(1)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
