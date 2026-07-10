import Foundation

struct Options {
    var input: URL
    var outputDir: URL?
    var title: String?
    var languages: [String] = ["ja", "en"]
    var dpi: Double = 300
    var pages: ClosedRange<Int>?
    var extractFigures = true
    var minFigureAreaFraction: Double = 0.015
    var marginFraction: Double = 0.03
    var jobs: Int = 1
    var pageMarkers = false
    var quiet = false
}

enum OptionError: Error, CustomStringConvertible {
    case missingInput
    case missingValue(String)
    case badValue(String, String)
    case unknown(String)

    var description: String {
        switch self {
        case .missingInput: "input PDF path is required"
        case .missingValue(let f): "option \(f) requires a value"
        case .badValue(let f, let v): "invalid value for \(f): \(v)"
        case .unknown(let f): "unknown option: \(f)"
        }
    }
}

let usage = """
vbook — Digitize a scanned book (PDF) into Markdown + extracted figure images.
        Uses Apple's Vision framework (macOS 26+). Handles vertical (縦書き) and
        horizontal Japanese text; reading order is recovered by Vision itself.

USAGE
  vbook <input.pdf> [options]

OPTIONS
  -o, --output-dir <dir>    Output directory (default: ./<title>)
  -t, --title <name>        Book title; also names the .md file
                            (default: PDF metadata title, else the file name)
  -l, --lang <a,b,...>      Recognition languages (default: ja,en)
      --dpi <n>             Page rendering DPI (default: 300)
      --pages <n|a-b>       Only process these 1-based pages
      --no-figures          Skip figure detection and extraction
      --min-figure-area <f> Minimum figure area as a fraction of the page
                            (default: 0.015)
      --margin <f>          Ignore this fraction of each page edge when looking
                            for figures, to reject scan shadows (default: 0.03)
  -j, --jobs <n>            Pages processed concurrently (default: 1). Text
                            recognition is serialized regardless, because Vision
                            crashes when run concurrently; higher values only
                            overlap rendering and figure detection.
      --page-markers        Emit <!-- page N --> comments into the Markdown
  -q, --quiet               Suppress progress output
  -h, --help                Show this help

OUTPUT
  <output-dir>/<title>.md
  <output-dir>/<title>_images/p001-fig01.png
"""

func parseOptions(_ argv: [String]) throws -> Options {
    var positional: [String] = []
    var opts: Options? = nil
    var outputDir: URL?
    var title: String?
    var languages = ["ja", "en"]
    var dpi = 300.0
    var pages: ClosedRange<Int>?
    var extractFigures = true
    var minArea = 0.015
    var margin = 0.03
    var jobs = 4
    var pageMarkers = false
    var quiet = false

    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < argv.count else { throw OptionError.missingValue(flag) }
        return argv[i]
    }

    while i < argv.count {
        let a = argv[i]
        switch a {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "-o", "--output-dir":
            outputDir = URL(fileURLWithPath: try value(a))
        case "-t", "--title":
            title = try value(a)
        case "-l", "--lang", "--languages":
            languages = try value(a).split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        case "--dpi":
            let v = try value(a)
            guard let d = Double(v), d >= 72, d <= 1200 else { throw OptionError.badValue(a, v) }
            dpi = d
        case "--pages":
            let v = try value(a)
            pages = try parsePageRange(v, flag: a)
        case "--no-figures":
            extractFigures = false
        case "--min-figure-area":
            let v = try value(a)
            guard let d = Double(v), d > 0, d < 1 else { throw OptionError.badValue(a, v) }
            minArea = d
        case "--margin":
            let v = try value(a)
            guard let d = Double(v), d >= 0, d < 0.4 else { throw OptionError.badValue(a, v) }
            margin = d
        case "-j", "--jobs":
            let v = try value(a)
            guard let n = Int(v), n >= 1, n <= 32 else { throw OptionError.badValue(a, v) }
            jobs = n
        case "--page-markers":
            pageMarkers = true
        case "-q", "--quiet":
            quiet = true
        default:
            if a.hasPrefix("-") && a != "-" { throw OptionError.unknown(a) }
            positional.append(a)
        }
        i += 1
    }

    guard let first = positional.first else { throw OptionError.missingInput }
    opts = Options(input: URL(fileURLWithPath: first))
    opts!.outputDir = outputDir
    opts!.title = title
    opts!.languages = languages
    opts!.dpi = dpi
    opts!.pages = pages
    opts!.extractFigures = extractFigures
    opts!.minFigureAreaFraction = minArea
    opts!.marginFraction = margin
    opts!.jobs = jobs
    opts!.pageMarkers = pageMarkers
    opts!.quiet = quiet
    return opts!
}

private func parsePageRange(_ s: String, flag: String) throws -> ClosedRange<Int> {
    if let n = Int(s), n >= 1 { return n...n }
    let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
    guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a >= 1, b >= a else {
        throw OptionError.badValue(flag, s)
    }
    return a...b
}
