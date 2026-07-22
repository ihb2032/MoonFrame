///|
/// The lazy NDJSON source: `scan_ndjson(path)` builds a `LazyFrame` whose leaf
/// is a deferred read of `path` — the streaming-friendly counterpart of eager
/// `read_ndjson`, and the line-oriented sibling of `scan_csv`. Like every
/// `LazyFrame` constructor it is total: nothing is read or parsed until
/// `collect`, so a missing file or a malformed line only surfaces then (as the
/// eager reader's `IoError` / `ParseError`). Projection push-down narrows the
/// leaf to the columns the pipeline consumes, and only those are built — so a
/// dropped column is never materialised. (Because a dropped column is never
/// built, a parse error confined to one does not surface, exactly as in
/// `scan_csv`. There is no `scan_json` for the single-array shape `[{...}]`,
/// which must be parsed whole to find its records — so nothing can be pruned at
/// read time, the same reason Polars has `scan_ndjson` but no `scan_json`.)
///
/// `options` (inference window, parse-error policy) defaults to
/// `JsonReadOptions()`, mirroring eager `read_ndjson`. It is captured into the
/// plan and applied by the reader at collect time; projection push-down narrows
/// which columns those options parse, never which options apply. The projection
/// starts `None` (read every column) — only the optimizer fills it.
pub fn scan_ndjson(
  path : String,
  options? : @io.JsonReadOptions = @io.JsonReadOptions(),
) -> LazyFrame {
  { plan: ScanNdjson(path, options, None, None) }
}
