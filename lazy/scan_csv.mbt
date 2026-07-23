///|
/// The lazy CSV source: `scan_csv(path)` builds a `LazyFrame` whose leaf is a
/// deferred read of `path` — the streaming-friendly counterpart of eager
/// `read_csv`. Nothing is read or parsed until `collect`: the builder is
/// total, like every other `LazyFrame` constructor, so a missing file or a
/// malformed CSV only surfaces then (as the eager reader's `IoError` /
/// `ParseError` / `DuplicateColumn`). The payoff over
/// `lazy_frame(read_csv(path))` is projection push-down — the optimizer
/// narrows the leaf to the columns the pipeline provably consumes, and only
/// those are parsed, so
/// `scan_csv("sales.csv").select([col("region"), col("revenue")]).collect()`
/// never builds the columns it drops. (Because a dropped column is never
/// parsed, a parse error confined to one — a malformed cell no consumer reads
/// — does not surface, exactly as in Polars' projection push-down; this is
/// the one place a narrowed scan diverges from a full eager read.)
///
/// `options` (delimiter, header, null strings, inference window, parse-error
/// policy, strict quotes, …) defaults to `CsvReadOptions()`, mirroring eager
/// `read_csv`. It is captured into the plan and applied by the reader at
/// collect time; projection push-down narrows which columns those options
/// parse, never which options apply. The projection starts `None` (read every
/// column) — only the optimizer fills it.
pub fn scan_csv(
  path : String,
  options? : @io.CsvReadOptions = @io.CsvReadOptions(),
) -> LazyFrame {
  // The one mutable container in the options — the null-token list — is
  // already copied by `CsvReadOptions(...)`, the only way to build one, so
  // the captured plan cannot observe a later mutation of the caller's array.
  { plan: Scan(Csv(path, options, None, None)) }
}
