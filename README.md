# vision-book-digitizer

Turn a scanned book (PDF) into a Markdown file plus a folder of extracted figure
images, entirely offline, using Apple's Vision framework.

It handles **vertical Japanese text (縦書き)** as well as horizontal text. Reading
order — right-to-left columns, line rejoining, paragraph grouping — is recovered by
Vision's `RecognizeDocumentsRequest`, not by hand-rolled geometry.

```
$ vbook 吾輩は猫である.pdf -o out

out/
├── 吾輩は猫である.md
└── 吾輩は猫である_images/
    ├── p003-fig01.png
    └── p012-fig01.png
```

## Requirements

- **macOS 26 (Tahoe) or later.** `RecognizeDocumentsRequest` and
  `RecognizedTextObservation.textDirection` are macOS 26 APIs; there is no
  fallback path for older systems.
- Swift 6.2+ toolchain (Xcode 26 or the matching Command Line Tools).

## Install

```bash
swift build -c release
cp .build/release/vbook /usr/local/bin/
```

## Usage

```
vbook <input.pdf> [options]

  -o, --output-dir <dir>    Output directory (default: ./<title>)
  -t, --title <name>        Book title; also names the .md file
                            (default: PDF metadata title, else the file name)
  -l, --lang <a,b,...>      Recognition languages (default: ja,en)
      --dpi <n>             Page rendering DPI (default: 300)
      --pages <n|a-b>       Only process these 1-based pages
      --no-figures          Skip figure detection and extraction
      --min-figure-area <f> Minimum figure area as a fraction of the page (default: 0.015)
      --margin <f>          Ignore this fraction of each page edge when looking for
                            figures, to reject scan shadows (default: 0.03)
  -j, --jobs <n>            Pages recognized concurrently (default: 4)
      --page-markers        Emit <!-- page N --> comments into the Markdown
  -q, --quiet               Suppress progress output
  -h, --help                Show this help
```

Set `VBOOK_DEBUG=1` to print the figure detector's per-page decisions to stderr.

## How it works

1. **Render.** Each page is drawn through `CGPDFPage.getDrawingTransform`, so the
   page's `/Rotate` entry is honored, at `--dpi` (default 300; the PDF user space is
   72 dpi, so the scale factor is `dpi / 72`). A page that is one full-page scanned
   image is never magnified past that image's own pixel resolution — upscaling a
   scan adds no detail and multiplies memory — while vector/text pages still honor
   the full DPI.
2. **Recognize.** `RecognizeDocumentsRequest` returns a document tree: title,
   paragraphs, tables, lists, and per-line `textDirection`. A page is treated as
   vertical when most of its lines report `.topToBottom`.
3. **Find figures.** Vision has no figure-detection API, so the tool subtracts what
   Vision *did* recognize: the page is binarized (Otsu), the recognized text quads
   are rasterized and dilated into a mask, the mask is removed from the ink, and the
   surviving ink is grouped by 8-connected component labeling on a coarse grid.
   Nearby components are merged, filtered by area and density, and cropped out of
   the full-resolution render as PNG.
4. **Emit.** Paragraphs, tables, lists, and figures are sorted back into reading
   order — right-to-left by column for vertical pages, top-to-bottom for horizontal
   — and written as Markdown. Hard-wrapped lines are rejoined with no separator for
   CJK text and with a space for Latin text.

## Mapping to Markdown

| Source | Markdown |
| --- | --- |
| Heading (Vision's `title`, or a short paragraph typeset ≥1.3× the body) | `## …` |
| Paragraph | plain text, lines rejoined |
| Table | pipe table |
| List | `- item` |
| Detected figure | `![図 3-1](<title>_images/p003-fig01.png)` |

Text that falls inside a detected figure is dropped: line art reliably OCRs as
stray glyphs (a crossed box becomes `XX`, a filled ellipse becomes `•`).

## Performance and stability

Text recognition is **serialized**: Vision's `RecognizeDocumentsRequest` segfaults
intermittently when several recognitions run concurrently in one process, so all
recognition passes through a single async gate. `--jobs` therefore defaults to 1
and, when raised, only overlaps the cheaper rendering and figure-detection stages.
A 120-page scanned book runs in about 100 s at ~0.4 GB peak memory.

## Known limitations

- **Vision's `RecognizedTextObservation.isTitle` is off by one line** — it flags the
  line *after* the heading. This tool ignores it and uses the container-level title
  plus a type-size heuristic instead.
- Vision's `title` is often `nil` on vertical pages; the size heuristic covers that.
- Rare kanji are occasionally dropped (`獰悪` → `悪`, `零下` → `下`). Vision offers
  `customWords`, which this tool does not yet expose.
- Tables are only recognized as tables when Vision says so, which in practice means
  ruled tables. Space-aligned columns come out as separate paragraphs.
- Figure detection is a heuristic, not a model. Dense line art next to text may be
  merged with it; faint halftones may be missed. Tune with `--min-figure-area`,
  `--margin`, and `VBOOK_DEBUG=1`.
- A page that is one full-bleed plate is emitted as a single figure. A page with
  five or more text lines never yields a figure that spans the whole page.

## Related

[`macos-vision-ocr`](https://github.com/mashi727/macos-vision-ocr) is the earlier,
smaller tool by the same author: one Swift file, `VNRecognizeTextRequest`, PDF to
plain text. It does not reconstruct reading order, so it scrambles vertical text.

## License

[MIT](LICENSE) © mashi727
