// The lazy file sources: `scan_csv` / `scan_ndjson` / `scan_json` build a
// `LazyFrame` whose leaf is a deferred read of the path, absorbing the
// projection and first-predicate push-downs — one file per format kept the
// eager readers apart; one file for all three keeps the lazy twins beside
// the push-down contract they share.

///|
/// The lazy CSV source: `scan_csv(path)` builds a `LazyFrame` whose leaf is a
/// **deferred read** of `path` — the push-down-aware counterpart of eager
/// `read_csv`. Nothing is read or parsed until `collect`: the builder is
/// total, like every other `LazyFrame` constructor, so a missing file or a
/// malformed CSV only surfaces then (as the eager reader's `IoError` /
/// `ParseError` / `DuplicateColumn`). It is not a *streaming* read — the reader
/// still tokenises the whole file, and streaming it is tracked as future
/// work.
///
/// The payoff over `LazyFrame::LazyFrame(read_csv(path))` is that this leaf
/// absorbs both push-downs, so the work it skips is work the eager pipeline
/// does:
/// - **projection** — the optimizer narrows the leaf to the columns the
///   pipeline provably consumes, and only those are parsed, so
///   `scan_csv("sales.csv").select([col("region"), col("revenue")]).collect()`
///   never builds the columns it drops;
/// - **predicate** — a filter sitting on the leaf moves into the read: the
///   reader builds the predicate's columns, asks which rows survive, then parses
///   the remaining columns for the survivors alone. Only the first such filter
///   is absorbed; a second stays a node above the scan.
///
/// Both prune cells an eager read-then-filter would have parsed, which is the
/// one way a narrowed scan diverges from a full eager read: a `ParseError`
/// confined to a dropped column, or to a row the predicate drops in a column the
/// predicate does not read, does not surface. Dtype inference still walks the
/// whole file, so dtypes and the surviving cells match the eager read exactly.
///
/// `options` (delimiter, header, null strings, inference window, parse-error
/// policy, strict quotes, dtype pins, …) defaults to `CsvReadOptions::CsvReadOptions()`, mirroring eager
/// `read_csv`. It is captured into the plan and applied by the reader at
/// collect time; projection push-down narrows which columns those options
/// parse, never which options apply. The projection starts `None` (read every
/// column) — only the optimizer fills it.
pub fn scan_csv(
  path : String,
  options~ : @io.CsvReadOptions = @io.CsvReadOptions::CsvReadOptions(),
) -> LazyFrame {
  // The one mutable container in the options — the null-token list — is
  // already copied by `CsvReadOptions::CsvReadOptions(...)`, the only way to build one, so
  // the captured plan cannot observe a later mutation of the caller's array.
  // The driver record is plain data: building it reads nothing, so the
  // builder stays total like every other LazyFrame constructor.
  { plan: fresh_file_scan(@io.csv_scan_driver(path, options)), }
}

///|
/// The plan leaf both `scan_*` builders return: a deferred read through
/// `driver` with no projection and no predicate — a fresh leaf reads every
/// column and filters nothing; only the optimizer fills those.
fn fresh_file_scan(driver : @scan.ScanDriver) -> LogicalPlan {
  Scan(File({ driver, projection: None, predicate: None, }))
}

///|
/// The lazy NDJSON source: `scan_ndjson(path)` builds a `LazyFrame` whose leaf
/// is a **deferred read** of `path` — the push-down-aware counterpart of eager
/// `read_ndjson`, and the line-oriented sibling of `scan_csv`. Like every
/// `LazyFrame` constructor it is total: nothing is read or parsed until
/// `collect`, so a missing file or a malformed line only surfaces then (as the
/// eager reader's `IoError` / `ParseError`). It is not a *streaming* read —
/// the reader still parses every line — and it absorbs the same two push-downs
/// `scan_csv` documents: projection (only the consumed columns are built) and
/// the first predicate sitting on the leaf (the surviving rows' cells are the
/// only ones built past the predicate's own columns). So a parse error confined
/// to a dropped column, or to a dropped row, does not surface; the surviving
/// cells and the inferred dtypes match an eager read exactly. (The
/// single-array shape has its own source, `scan_json`.)
///
/// `options` (inference window, parse-error policy, dtype pins, …) defaults to
/// `JsonReadOptions::JsonReadOptions()`, mirroring eager `read_ndjson`. It is captured into the
/// plan and applied by the reader at collect time; projection push-down narrows
/// which columns those options parse, never which options apply. The projection
/// starts `None` (read every column) — only the optimizer fills it.
pub fn scan_ndjson(
  path : String,
  options~ : @io.JsonReadOptions = @io.JsonReadOptions::JsonReadOptions(),
) -> LazyFrame {
  { plan: fresh_file_scan(@io.ndjson_scan_driver(path, options)), }
}

///|
/// The lazy JSON source: `scan_json(path)` builds a `LazyFrame` whose leaf is
/// a **deferred read** of `path` — the push-down-aware counterpart of eager
/// `read_json`, for the single top-level array of records
/// (`[{...}, {...}]`). Like every `LazyFrame` constructor it is total:
/// nothing is read or parsed until `collect`, so a missing file, malformed
/// JSON, or a non-object record only surfaces then (as the eager reader's
/// `IoError` / `ParseError`).
///
/// The one-way shape of the format sets what the push-downs can prune: the
/// top-level array must be parsed whole to find its records, so the pruning
/// both push-downs bring is at the *assembly* — projection leaves the
/// dropped columns uninferred and unbuilt, and the first predicate sitting
/// on the leaf builds only the surviving rows' cells past the predicate's
/// own columns. The parse itself is never skipped, which is also why this
/// is not a *streaming* read. A `ParseError` confined to a dropped column
/// or to a dropped row therefore does not surface, and the surviving cells
/// and dtypes match an eager read exactly — the contract the other two
/// scan sources honour, at the granularity this format allows.
///
/// `options` defaults to `JsonReadOptions::JsonReadOptions()`, mirroring eager
/// `read_json`, and is captured into the plan and applied at collect time;
/// projection push-down narrows which columns those options parse, never
/// which options apply.
pub fn scan_json(
  path : String,
  options~ : @io.JsonReadOptions = @io.JsonReadOptions::JsonReadOptions(),
) -> LazyFrame {
  { plan: fresh_file_scan(@io.json_scan_driver(path, options)), }
}
