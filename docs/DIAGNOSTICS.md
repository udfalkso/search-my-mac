# Local timing diagnostics

The app automatically writes JSON lines to `/tmp/searchmymac-<uid>.log`
(`/tmp/searchmymac-501.log` on the current development machine). No environment
variable is needed. Restart into a newly built app to activate new logging.

To disable file logging in code, set
`DiagnosticConfiguration.fileLoggingEnabled` to `false` in
`Sources/SearchMyMacCore/DiagnosticLog.swift`, then rebuild. It currently defaults
to `true`. Disabling it stops new writes and preserves existing logs; the
separate opt-in console profiling switch is unaffected.

Each event includes a wall-clock timestamp, process/session identifiers, process
uptime, stage, and optional request ID, stage-local elapsed time, and details.
Use timestamps and matching request IDs to compare different stages; elapsed
times start at each trace's creation, not at one shared request-wide origin.

Events cover launch, reopen, search scheduling/debounce, engine entry, lexical
backend selection, SQLite execution, semantic embedding/vector work, result
assignment/view appearance, history refresh, cancellation/errors, and Word
launch/navigation outcomes. Query text and file-type filters are included with
the developer's authorization. Document contents, document paths, script source,
and raw error messages are not logged.

Writes run on a utility queue and do not block the UI. The file is owner-only,
limited to 5 MB, and is truncated when the next event would exceed that limit.
It persists across launches until that limit or temporary-directory cleanup;
capture it promptly after a problem. Multiple processes coordinate writes with
a file lock. Diagnostic write failures do not interrupt the app.

`SMM_PROFILE_SEARCH=1` additionally emits search timings to stderr and unified
logging. No telemetry or upload is performed.
