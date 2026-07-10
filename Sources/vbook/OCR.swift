import CoreGraphics
import Foundation
import Vision

enum PageDirection: Sendable {
    case horizontal
    case vertical
}

struct TextBlock: Sendable {
    var text: String
    var rect: CGRect
    var isHeading: Bool
}

/// A paragraph typeset this much larger than the page's body text is a heading,
/// as long as it is short. Vision's own `title` misses vertical headings.
private let headingThicknessRatio: CGFloat = 1.3
private let headingMaxCharacters = 40

struct TableBlock: Sendable {
    var rows: [[String]]
    var rect: CGRect
}

struct ListBlock: Sendable {
    var items: [String]
    var rect: CGRect
}

/// One page of recognized content. All rects are in Vision's normalized space:
/// origin bottom-left, x and y in 0...1.
struct PageOCR: Sendable {
    var direction: PageDirection = .horizontal
    var paragraphs: [TextBlock] = []
    var tables: [TableBlock] = []
    var lists: [ListBlock] = []
    var lineQuads: [[CGPoint]] = []
    /// Median thickness of a text line across the writing direction.
    var lineThickness: CGFloat = 0.02
    /// Share of the page covered by recognized text lines. Near zero on a plate.
    var textAreaFraction: CGFloat = 0
}

func recognizePage(_ image: CGImage, languages: [String]) async throws -> PageOCR {
    var request = RecognizeDocumentsRequest()
    request.textRecognitionOptions.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
    request.textRecognitionOptions.useLanguageCorrection = true

    let observations = try await request.perform(on: image)
    guard let doc = observations.first?.document else { return PageOCR() }

    let lines = doc.text.lines
    guard !lines.isEmpty else { return PageOCR() }

    var page = PageOCR()
    let verticalLines = lines.filter { $0.textDirection == .topToBottom }.count
    page.direction = verticalLines * 2 > lines.count ? .vertical : .horizontal
    page.lineQuads = lines.map(quadPoints)

    let vertical = page.direction == .vertical
    // A lone graphic mistaken for one glyph can make the median absurd, and the
    // figure detector scales its text dilation by this value.
    page.lineThickness = min(max(medianThickness(lines, vertical: vertical) ?? 0.02, 0.002), 0.06)
    page.textAreaFraction = min(1, lines
        .map { boundingRect(quadPoints($0)) }
        .reduce(0) { $0 + $1.width * $1.height })

    page.tables = doc.tables.map {
        TableBlock(rows: $0.rows.map { $0.map { cell in cell.content.text.transcript } }, rect: tableRect($0))
    }
    page.lists = doc.lists.map {
        ListBlock(items: $0.items.map(\.itemString), rect: listRect($0))
    }

    // Vision's `isTitle` on a line is offset by one line in practice; the
    // container-level title is reliable, so match paragraphs against it.
    let title = doc.title?.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let occupied = page.tables.map(\.rect) + page.lists.map(\.rect)

    for paragraph in doc.paragraphs {
        let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        let rect = textRect(paragraph)
        guard !occupied.contains(where: { containment(of: rect, in: $0) > 0.6 }) else { continue }

        let matchesTitle = title.map { !$0.isEmpty && text == $0 } ?? false
        let thickness = medianThickness(paragraph.lines, vertical: vertical) ?? 0
        let looksLikeHeading = thickness >= headingThicknessRatio * page.lineThickness
            && text.count <= headingMaxCharacters
        page.paragraphs.append(
            TextBlock(text: text, rect: rect, isHeading: matchesTitle || looksLikeHeading))
    }
    return page
}

private func medianThickness(_ lines: [RecognizedTextObservation], vertical: Bool) -> CGFloat? {
    let values = lines
        .map { boundingRect(quadPoints($0)) }
        .map { vertical ? $0.width : $0.height }
        .sorted()
    guard !values.isEmpty else { return nil }
    return values[values.count / 2]
}

private func quadPoints(_ o: RecognizedTextObservation) -> [CGPoint] {
    [o.topLeft.cgPoint, o.topRight.cgPoint, o.bottomRight.cgPoint, o.bottomLeft.cgPoint]
}

private func textRect(_ t: DocumentObservation.Container.Text) -> CGRect {
    unionRect(t.lines.map { boundingRect(quadPoints($0)) })
}

private func tableRect(_ t: DocumentObservation.Container.Table) -> CGRect {
    unionRect(t.rows.flatMap { $0 }.map { textRect($0.content.text) })
}

private func listRect(_ l: DocumentObservation.Container.List) -> CGRect {
    unionRect(l.items.map { textRect($0.content.text) })
}
