///|
/// The lazy CSV source: `scan_csv(path)` builds a `LazyFrame` whose leaf is a
/// **deferred read** of `path` — the push-down-aware counterpart of eager
/// `read_csv`. Nothing is read or parsed until `collect`: the builder is
/// total, like every other `LazyFrame` constructor, so a missing file or a
/// malformed CSV only surfaces then (as the eager reader's `IoError` /
/// `ParseError` / `DuplicateColumn`). It is not a *streaming* read — the reader
/// still tokenises the whole file, and streaming it is tracked as future work in
/// [`docs/api.md`](../docs/api.md).
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
/// policy, strict quotes, …) defaults to `CsvReadOptions::CsvReadOptions()`, mirroring eager
/// `read_csv`. It is captured into the plan and applied by the reader at
/// collect time; projection push-down narrows which columns those options
/// parse, never which options apply. The projection starts `None` (read every
/// column) — only the optimizer fills it.
pub fn scan_csv(
  path : String,
  options? : @io.CsvReadOptions = @io.CsvReadOptions::CsvReadOptions(),
) -> LazyFrame {
  // The one mutable container in the options — the null-token list — is
  // already copied by `CsvReadOptions::CsvReadOptions(...)`, the only way to build one, so
  // the captured plan cannot observe a later mutation of the caller's array.
  { plan: Scan(Csv(path, options, None, None)) }
}
