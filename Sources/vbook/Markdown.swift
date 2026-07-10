import CoreGraphics
import Foundation

enum Block: Sendable {
    case heading(String)
    case paragraph(String)
    case table([[String]])
    case list([String])
    case figure(path: String, alt: String)
}

struct PlacedBlock: Sendable {
    var rect: CGRect
    var block: Block
}

/// Vision emits lines in reading order, but figures are found separately, so the
/// merged sequence has to be re-sorted. Bands are quantized to absorb baseline
/// jitter between a figure's box and the text lines beside it.
func readingOrder(_ blocks: [PlacedBlock], direction: PageDirection) -> [PlacedBlock] {
    let tolerance: CGFloat = 0.02
    func band(_ v: CGFloat) -> Int { Int((v / tolerance).rounded()) }

    return blocks.enumerated().sorted { a, b in
        switch direction {
        case .horizontal:
            let ka = band(1 - a.element.rect.maxY), kb = band(1 - b.element.rect.maxY)
            if ka != kb { return ka < kb }
            if a.element.rect.minX != b.element.rect.minX { return a.element.rect.minX < b.element.rect.minX }
        case .vertical:
            let ka = band(1 - a.element.rect.maxX), kb = band(1 - b.element.rect.maxX)
            if ka != kb { return ka < kb }
            if a.element.rect.maxY != b.element.rect.maxY { return a.element.rect.maxY > b.element.rect.maxY }
        }
        return a.offset < b.offset
    }.map(\.element)
}

func renderMarkdown(_ blocks: [PlacedBlock]) -> String {
    var chunks: [String] = []
    for placed in blocks {
        switch placed.block {
        case .heading(let text):
            chunks.append("## " + joinWrappedLines(text))
        case .paragraph(let text):
            chunks.append(escapeBlockStart(joinWrappedLines(text)))
        case .table(let rows):
            let table = markdownTable(rows)
            if !table.isEmpty { chunks.append(table) }
        case .list(let items):
            let list = items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { "- " + joinWrappedLines($0) }
            if !list.isEmpty { chunks.append(list.joined(separator: "\n")) }
        case .figure(let path, let alt):
            chunks.append("![\(alt)](\(encodeMarkdownPath(path)))")
        }
    }
    return chunks.joined(separator: "\n\n")
}

/// Vision hard-wraps a paragraph at the rendered line breaks. Japanese lines are
/// rejoined with no separator; Latin lines need the space back.
func joinWrappedLines(_ text: String) -> String {
    var out = ""
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }
        guard let previous = out.unicodeScalars.last, let next = line.unicodeScalars.first else {
            out = line
            continue
        }
        if previous.isASCII && next.isASCII {
            out += " " + line
        } else {
            out += line
        }
    }
    return out
}

func markdownTable(_ rows: [[String]]) -> String {
    guard let header = rows.first, !header.isEmpty else { return "" }
    let columns = rows.map(\.count).max() ?? header.count

    func cell(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
    func line(_ row: [String]) -> String {
        var cells = row.map(cell)
        while cells.count < columns { cells.append("") }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    var out = [line(header), "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"]
    out.append(contentsOf: rows.dropFirst().map(line))
    return out.joined(separator: "\n")
}

/// Keeps recognized text from being reinterpreted as Markdown structure.
private func escapeBlockStart(_ text: String) -> String {
    guard let first = text.first else { return text }
    if "#>-+*".contains(first) { return "\\" + text }
    return text
}

/// Leaves Japanese characters intact — every Markdown renderer accepts them raw —
/// and escapes only what would terminate the link destination.
private func encodeMarkdownPath(_ path: String) -> String {
    path.replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: " ", with: "%20")
        .replacingOccurrences(of: "(", with: "%28")
        .replacingOccurrences(of: ")", with: "%29")
}

/// Strips characters that are illegal or hostile in a file name, keeping Japanese.
func sanitizeFileName(_ name: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    let cleaned = name.unicodeScalars
        .map { illegal.contains($0) ? "_" : Character($0) }
        .reduce(into: "") { $0.append($1) }
    let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "book" : String(trimmed.prefix(120))
}
