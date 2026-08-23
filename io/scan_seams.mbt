// The file-backed engine seams behind the lazy scan sources: the
// projection and predicate push-down entries `lazy` calls for `scan_csv`
// / `scan_ndjson`. Every entry is `#doc(hidden)` + `#internal(engine)` —
// absent from the generated interface, flagged for downstream callers —
// and pinned, signature and consumers, in `engine_seams.snapshot`. Each
// is a thin file wrapper: `read_text` plus the string-level projected
// core in its format file (`parse_csv_str_projected` /
// `parse_ndjson_str_projected`), which is where the per-format contract
// lives.
//
// The push-down contract all four share — a pushed-down read differs
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
//     parsing them a second time (`assemble_pruned_frame` phase 2).
//
// A new format's seam follows this file's shape: one thin entry per
// push-down, the string-level projected core staying with its format.
// Filesystem errors surface as `raise IoError(message)`, exactly as the
// eager readers'.

///|
/// Read a CSV file, keeping only the rows the predicate selects — the
/// file-backed entry behind the lazy `scan_csv` source's **predicate
/// push-down**. Two phases over one tokenisation of the whole file:
/// build only the `key_columns` and ask `keep` — a callback the lazy
/// layer builds from the absorbed predicate — which rows survive; then
/// build the `projection` columns for those rows alone. Taking names and
/// a callback rather than an expression keeps `io` below the expression
/// language: the reader knows *which* columns to resolve and which rows
/// survived, never *why*. Dtypes match an eager
/// `read_csv(...).filter(...)` cell for cell; the rest of what is (and
/// is not) observable is the shared seam contract in this file's header.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn read_csv_pruned(
  path : String,
  options : CsvReadOptions,
  projection : Array[String]?,
  key_columns : Array[String],
  keep : (@frame.DataFrame) -> Array[Int] raise @types.DataError,
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_csv_str_projected(
    content,
    options,
    projection,
    pruner=(key_columns, keep),
  )
}

///|
/// Read a CSV file, building only the columns named in `projection` —
/// the file-backed entry behind the lazy `scan_csv` source's projection
/// pushdown. Identical to `read_csv` except that a column whose header
/// name is not in `projection` is never inferred, parsed, or
/// materialised (see `parse_csv_str_projected` for the precise contract,
/// including the one behavioural consequence: a parse error confined to
/// a dropped column does not surface).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn read_csv_projected(
  path : String,
  options : CsvReadOptions,
  projection : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_csv_str_projected(content, options, Some(projection))
}

///|
/// Read an NDJSON file, keeping only the rows the predicate selects —
/// the NDJSON twin of `read_csv_pruned`, behind the lazy `scan_ndjson`
/// source's **predicate push-down**. Every line is still parsed and
/// validated (a malformed or non-object line fails exactly as in a full
/// read); the push-down skips the *typed* build of the columns the
/// predicate does not read, for the records it drops. Dtype inference
/// still walks every record, so dtypes match an eager read-then-filter;
/// the rest is the shared seam contract in this file's header.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn read_ndjson_pruned(
  path : String,
  options : JsonReadOptions,
  projection : Array[String]?,
  key_columns : Array[String],
  keep : (@frame.DataFrame) -> Array[Int] raise @types.DataError,
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_ndjson_str_projected(
    content,
    options,
    projection,
    pruner=(key_columns, keep),
  )
}

///|
/// Read an NDJSON file, building only the columns named in `projection`
/// — the file-backed entry behind the lazy `scan_ndjson` source's
/// projection pushdown. Identical to `read_ndjson` except that a column
/// whose header name is not in `projection` is never inferred or built
/// (see `frame_from_json_records` for the precise contract, including
/// the one behavioural consequence: a parse error confined to a dropped
/// column does not surface).
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn read_ndjson_projected(
  path : String,
  options : JsonReadOptions,
  projection : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_ndjson_str_projected(content, options, Some(projection))
}
