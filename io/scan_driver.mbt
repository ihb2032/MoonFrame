// The file-format scan drivers behind the lazy scan sources: a driver is the
// `ScanDriver` face one readable format puts on its read, and these two
// are the whole of what `lazy` knows about CSV and NDJSON. A new scannable
// format adds a driver here (beside its options type) plus its `scan_*`
// builder in `lazy` — execution, projection / predicate push-down and plan
// rendering come from the driver interface, not from per-format branches in
// the engine.
//
// Taking the predicate as an `Expr` looks like a layering exception, but
// only its column names and a row-selection callback reach the reader core:
// the format never learns the expression language, only *which* columns to
// resolve and which rows survived. Both drivers extract `ScanBatch` through
// `DataFrame`'s public accessors — the eager cores they wrap still assemble
// a frame (assembly is the `io → frame` edge's remaining job), and the batch
// is the driver face on the same result.
//
// The push-down contract both drivers honour — a pushed-down read differs
// from an eager read only in the work it skips, never in the frame it
// yields:
//
//   - Whole-input checks run first and see the full input: strict quote
//     validation, BOM stripping, the empty-input short-circuit, malformed
//     or non-object records, duplicate headers, the ragged-row guard. A
//     pushed-down read fails on malformed input exactly as a full one.
//   - Dtype inference always walks the whole file, so a pruned read locks
//     in the dtypes an eager `read_csv(..).filter(..)` would — the typed
//     build, not the inference, is what the push-down skips.
//   - The one observable trade is that same skipping: a `ParseError`
//     confined to a dropped column (projection) or to a row the predicate
//     drops in a column it does not read (pruning) never surfaces,
//     because those cells are never parsed.
//   - Row identity survives pruning: each kept record's original file
//     row / line threads through to the error locator, so a parse error
//     in a kept row still reports its true position.
//   - The pruned read reuses its already-built key columns rather than
//     parsing them a second time (the core's phase 2).
//
// The string-level cores themselves (`parse_csv_str_projected` /
// `parse_ndjson_str_projected`) live with their format files, package-private
// to `io`.

///|
/// The one driver skeleton both format drivers ride: read the file, turn an
/// absorbed predicate into the pruner contract (its key columns plus the
/// row-selection callback — the single place that pairing is spelled), and
/// wrap the format core's frame as a batch. A format driver is then its
/// label and its projected / pruned core, nothing else.
fn file_scan_driver(
  path : String,
  label : String,
  read : (String, Array[String]?, RowPruner?) -> @frame.DataFrame raise @types.DataError,
) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(() => label, (projection, predicate) => {
    let pruner : RowPruner? = predicate.map(pred => {
      (predicate_columns(pred), df => @frame.filter_row_indices(df, pred))
    })
    batch_of(read(read_text(path), projection, pruner))
  })
}

///|
/// The CSV scan driver: a path plus the options to parse it under, read at
/// `scan` time through the same projected / pruned core the eager reader
/// uses. Built by `csv_scan_driver`, which hands `lazy` the driver record.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn csv_scan_driver(
  path : String,
  options : CsvReadOptions,
) -> @scan.ScanDriver {
  file_scan_driver(path, "CSV \"\{@text.escape_debug(path)}\"", (
    content,
    projection,
    pruner,
  ) => parse_csv_str_projected(content, options, projection, pruner))
}

///|
/// The NDJSON scan driver — the line-oriented twin of `csv_scan_driver`,
/// reading through the NDJSON projected / pruned core.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn ndjson_scan_driver(
  path : String,
  options : JsonReadOptions,
) -> @scan.ScanDriver {
  file_scan_driver(path, "NDJSON \"\{@text.escape_debug(path)}\"", (
    content,
    projection,
    pruner,
  ) => parse_ndjson_str_projected(content, options, projection, pruner))
}

///|
/// A frame's columns plus its row count — the batch the driver returns. The
/// height rides separately so a projection matching no column keeps the
/// file's rows (the `N×0` shape) rather than collapsing to zero.
fn batch_of(df : @frame.DataFrame) -> @scan.ScanBatch {
  @scan.ScanBatch::batch(df.column_series(), df.nrows())
}

///|
/// The column names an absorbed predicate reads — all the reader core needs
/// to build its key columns and prune. Order is irrelevant: the reader
/// filters its own header order by membership.
fn predicate_columns(predicate : @expr.Expr) -> Array[String] {
  let names : Array[String] = []
  for name in predicate.referenced_columns() {
    names.push(name)
  }
  names
}
