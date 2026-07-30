///|
/// The lazy NDJSON source: `scan_ndjson(path)` builds a `LazyFrame` whose leaf
/// is a **deferred read** of `path` — the push-down-aware counterpart of eager
/// `read_ndjson`, and the line-oriented sibling of `scan_csv`. Like every
/// `LazyFrame` constructor it is total: nothing is read or parsed until
/// `collect`, so a missing file or a malformed line only surfaces then (as the
/// eager reader's `IoError` / `ParseError`). It is not a *streaming* read — the
/// reader still parses every line — and it absorbs the same two push-downs
/// `scan_csv` documents: projection (only the consumed columns are built) and
/// the first predicate sitting on the leaf (the surviving rows' cells are the
/// only ones built past the predicate's own columns). So a parse error confined
/// to a dropped column, or to a dropped row, does not surface; the surviving
/// cells and the inferred dtypes match an eager read exactly. (There is no
/// `scan_json` for the single-array shape `[{...}]`, which must be parsed whole
/// to find its records — so nothing can be pruned at read time, the same reason
/// Polars has `scan_ndjson` but no `scan_json`.)
///
/// `options` (inference window, parse-error policy) defaults to
/// `JsonReadOptions::JsonReadOptions()`, mirroring eager `read_ndjson`. It is captured into the
/// plan and applied by the reader at collect time; projection push-down narrows
/// which columns those options parse, never which options apply. The projection
/// starts `None` (read every column) — only the optimizer fills it.
pub fn scan_ndjson(
  path : String,
  options? : @io.JsonReadOptions = @io.JsonReadOptions::JsonReadOptions(),
) -> LazyFrame {
  { plan: Scan(Ndjson(path, options, None, None)) }
}
