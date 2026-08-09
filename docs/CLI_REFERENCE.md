# `smm` CLI Reference for AI Tools

`smm` searches the local Search My Mac index from a shell. It is intended for
automation and AI agents that need to locate relevant user files without walking
the filesystem themselves.

The command is installed at `/usr/local/bin/smm` by the Search My Mac installer.
The executable lives inside the installed app bundle so its behavior matches the
currently installed app version.

## Safety and operating model

- `smm` searches the existing local index. It does not enumerate folders,
  extract files, download cloud placeholders, or trigger indexing.
- It opens the manifest and vector data read-only, and never writes search
  history, saved searches, or other index state.
- It does not expand the caller's macOS permissions. Treat returned paths and
  snippets as private user data; only open a result when the user task warrants
  it.
- Semantic and Hybrid queries require that the user has enabled Semantic Search
  in Search My Mac and that at least one section has been embedded. The CLI uses
  local CPU inference so it works in automation environments where Metal is
  unavailable. No query or document text is sent to a network service.

## Invocation

```sh
smm [search] <query> [options]
```

`search` is optional. Quote multi-word queries to preserve the intended query.
Without an explicit output option, `smm` writes a single JSON object to stdout.
Errors and usage messages are written to stderr. Exit status is `0` for success,
`1` for a runtime error, and `2` for invalid arguments.

Examples:

```sh
smm "quarterly revenue"
smm "Maryland license" --mode hybrid --type pdf --limit 5
smm "project launch notes" --path ~/Documents --jsonl
smm "invoice" --after 2026-01-01 --paths
```

## Options

| Option | Meaning |
| --- | --- |
| `--mode text\|semantic\|hybrid` | Search mode. Default: `text`. |
| `-n`, `--limit N` | Maximum results, from 1 through 200. Default: 10. |
| `--path DIR` | Restrict results to a folder. Repeatable. `~` is expanded. |
| `--type EXT[,EXT...]` | Restrict results by extension. Repeatable; commas are accepted. Leading `.` is optional. |
| `--after DATE` | Include files modified on or after an ISO date/time. |
| `--before DATE` | Include files modified before an ISO date/time. |
| `--semantic-weight 0...1` | Semantic share for Hybrid reciprocal-rank fusion. Default: `0.35`. |
| `--format json\|jsonl\|paths\|text` | Output format. |
| `--json`, `--jsonl`, `--paths`, `--text` | Shortcuts for `--format`. |
| `-h`, `--help` | Print usage. |

Dates accept `YYYY-MM-DD` or an ISO-8601 timestamp. More than one `--path`
filter is an OR restriction; likewise, more than one file type accepts any of
those types.

## Output formats

### JSON (default)

A single object suitable for a structured tool call:

```json
{
  "query": "quarterly revenue",
  "requested_mode": "hybrid",
  "effective_mode": "hybrid",
  "result_count": 1,
  "results": [
    {
      "path": "/Users/example/Documents/Q1 report.pdf",
      "filename": "Q1 report.pdf",
      "file_type": "pdf",
      "modified_at": "2026-01-15T14:30:00Z",
      "score": 0.84,
      "snippets": [
        { "location": "Page 3", "text": "Revenue increased…" }
      ]
    }
  ]
}
```

`effective_mode` can be `text` when semantic search cannot yet return any
embedded passages. Agents should use this field rather than assuming the
requested mode was available.

### JSONL

One result object per line, with the same result fields shown above. This is the
most convenient format for streaming or line-oriented parsers:

```sh
smm "renewal terms" --jsonl
```

### Paths

One absolute result path per line, no metadata or snippets:

```sh
smm "budget" --type xlsx --paths
```

### Text

Human-readable numbered paths with up to three snippets per result.

## Choosing a mode

- Use `text` for exact names, identifiers, quoted phrases, filenames, or when
  predictable lexical matching matters most.
- Use `semantic` for concepts expressed with different wording. It performs a
  local query embedding and nearest-neighbor vector retrieval.
- Use `hybrid` for general discovery. It fuses lexical and semantic candidates;
  start with the default `--semantic-weight 0.35`. Lower the weight for
  identifier-heavy work; raise it moderately for conceptual exploration.

## Recommended AI workflow

1. Start with a narrow, purposeful query and `--limit 5` or `10`.
2. Add `--path` and `--type` filters when the user identifies a likely folder or
   document class.
3. Use `--json` or `--jsonl`, inspect filenames, paths, and small snippets, then
   decide whether opening a returned file is necessary and authorized.
4. If a semantic request reports `effective_mode: "text"`, explain that local
   semantic indexing has not become available yet rather than silently claiming
   a semantic search was performed.
5. Do not run broad repeated queries simply to reproduce a filesystem inventory;
   the index is designed for targeted retrieval.

## Troubleshooting

- **`command not found: smm`** — install the Search My Mac package or invoke the
  helper inside the app bundle at
  `/Applications/Search My Mac.app/Contents/Helpers/smm`.
- **Semantic Search is not installed** — ask the user to enable it in Search My
  Mac Settings. Do not attempt to download a model from an AI workflow.
- **No semantic sections are ready** — the app is still building semantic
  coverage. Text search remains available immediately.
- **No results** — check scope with `--path`, type filters, and whether Search
  My Mac has indexed the relevant location.
