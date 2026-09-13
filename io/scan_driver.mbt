// The file-format scan drivers behind the lazy scan sources: a driver is the
// `@scan.ScanDriver` face one readable format puts on its read, and these two
// are the whole of what `lazy` knows about CSV and NDJSON. A new scannable
// format adds a driver here (beside its options type) plus its `scan_*`
// builder in `lazy` — execution, projection / predicate push-down and plan
// rendering come from the driver interface, not from per-format branches in
// the engine.
//
// The push-down contract each driver honours — a pushed-down read differs
// from an eager read only in the work it skips, never in the frame it
// yields — lives once in `scan_seams.mbt`'s header, beside the string-level
// projected cores both drivers call. Taking the predicate as an `Expr` looks
// like a layering exception, but only its column names and a row-selection
// callback reach the reader core: the format never learns the expression
// language, only *which* columns to resolve and which rows survived.
//
// Both drivers extract `ScanBatch` through `DataFrame`'s public accessors —
// the eager cores they wrap still assemble a frame (assembly is the
// `io → frame` edge's remaining job), and the batch is the driver face on
// the same result.

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
  @scan.ScanDriver::driver(() => "CSV \"\{@text.escape_debug(path)}\"", (
    projection,
    predicate,
  ) => {
    let content = read_text(path)
    let frame = match predicate {
      Some(pred) =>
        parse_csv_str_projected(
          content,
          options,
          projection,
          pruner=(
            predicate_columns(pred),
            df => @frame.filter_row_indices(df, pred),
          ),
        )
      None => parse_csv_str_projected(content, options, projection)
    }
    batch_of(frame)
  })
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
  @scan.ScanDriver::driver(() => "NDJSON \"\{@text.escape_debug(path)}\"", (
    projection,
    predicate,
  ) => {
    let content = read_text(path)
    let frame = match predicate {
      Some(pred) =>
        parse_ndjson_str_projected(
          content,
          options,
          projection,
          pruner=(
            predicate_columns(pred),
            df => @frame.filter_row_indices(df, pred),
          ),
        )
      None => parse_ndjson_str_projected(content, options, projection)
    }
    batch_of(frame)
  })
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
