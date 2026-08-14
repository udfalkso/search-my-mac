# Local document extraction bakeoff

Evaluated on August 14, 2026 on Apple silicon using the committed fixture sets
from `firecrawl/anydoc` v0.1.9 (`e754e1d`) and `firecrawl/pdf-inspector` v1.14.2.
The existing `DocumentExtractor` was compared with warm release builds of the
Rust parsers. These are directional fixture results, not a replacement for the
pre-release corpus and energy tests.

## Office and ebook formats

| Fixture | Existing result | anydoc result |
| --- | ---: | ---: |
| DOC | 28.2 ms, 1,100 bytes | 2.3 ms, 1,250 bytes |
| DOCX | 2.5 ms, 958 bytes | 1.8 ms, 1,316 bytes |
| ODT | 3.3 ms, 938 bytes | 2.5 ms, 1,322 bytes |
| RTF | 31.0 ms, 917 bytes | 2.3 ms, 1,321 bytes |
| PPT / PPTX / ODP | extraction failed | 0.5–2.2 ms, content extracted |
| XLS / XLSX / ODS | extraction failed | 1.3–2.0 ms, content extracted |
| EPUB | extraction failed | 1.7 ms, content extracted |

For the four formats both paths could read, anydoc also retained headings,
list numbering, merged-table structure, links, footnotes/endnotes, speaker
notes, and text-box content that the flattened system-reader output lost. This
justified adopting it for every supported non-PDF office/ebook container while
retaining the system readers as compatibility fallbacks.

## PDFs

On the two native-text layout fixtures, pdf-inspector was comparable in speed
and materially improved reading order and table reconstruction:

| Fixture | PDFKit | pdf-inspector |
| --- | ---: | ---: |
| Multi-column financial page | 27.3 ms, flat text | 25.0 ms, structured tables/reading order |
| Forecast table and prose | 3.9 ms, flat text | 7.1 ms, reconstructed table and prose |

The parser correctly marked scanned, vector-text, and suspect Identity-H pages
as needing OCR rather than returning questionable text. PDFKit could still read
useful text from the tested Identity-H and vector fixtures. The production
decision is therefore per-page hybrid routing: use pdf-inspector output only
when it passes its quality checks, otherwise try PDFKit and then local Vision
OCR. Page labels and the existing OCR-page cap remain unchanged.

The manifest persists an extraction recipe version per source. Existing office,
ebook, and PDF rows written before this integration become stale on upgrade and
are re-extracted once through the normal pausable startup reconciliation. This
includes successful legacy extraction as well as failures; unrelated formats
retain version zero and are not re-extracted.
