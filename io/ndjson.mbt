// NDJSON (Newline-Delimited JSON, a.k.a. JSON Lines / `.ndjson` /
// `.jsonl`) serialisation for `DataFrame`. The wire shape is one flat
// JSON object per line (`{...}\n{...}\n...`) — the streaming-friendly
// sibling of the single-array "records" layout in `json.mbt`. Polars'
// `read_ndjson` / `write_ndjson` and pandas' `read_json(lines=True)` /
// `to_json(lines=True)` speak the same format.
//
// Everything *after* the framing is shared with the JSON-records reader:
// per-line objects are collected into the same `Array[Json]` and handed
// to `frame_from_json_records`, so header collection (first-seen order
// across all rows, sparse rows contribute their own columns), per-column
// type inference (`Int → Float → Bool → String`, nulls passing through),
// and typed-column construction behave identically. The writer reuses
// `scalar_to_json`, so the same cell conventions hold — notably a
// non-finite `Float` (`NaN` / `±Infinity`) is emitted as `null` to keep
// each line valid JSON, and an `Int` beyond ±2^53 keeps its dtype but
// loses precision on a round-trip (the `@json` number model is `Double`).
//
// Reading is lenient about line endings: lines are split on `\n`, a
// trailing `\r` (CRLF input) is tolerated as JSON whitespace by
// `@json.parse`, and blank / whitespace-only lines are skipped — so the
// writer's trailing newline (and any incidental blank lines) round-trip
// without producing phantom rows.

///|
/// Options that control how an NDJSON payload is parsed into a
/// `DataFrame`.
///
/// - `infer_schema_rows` — number of leading records inspected when
///   guessing each column's dtype. `0` (or any value `<= 0`) lifts the
///   cap and scans every record (Polars' `infer_schema_length=None`).
///   Records past a finite window are still parsed under the chosen
///   dtype; one that doesn't fit is handled per `on_parse_error`.
/// - `on_parse_error` — what to do when a non-null cell past the
///   inference window fails to parse under its column's locked-in dtype:
///   `Raise` (default) fails the whole read with `ParseError`; `Null`
///   downgrades the offending cell to a null and continues (Polars'
///   `ignore_errors=True`). See `OnParseError`.
///
/// (Same meanings and defaults as `JsonReadOptions` / the CSV reader —
/// NDJSON keeps its own options type so the two formats can diverge later.)
pub(all) struct NdjsonReadOptions {
  infer_schema_rows : Int
  on_parse_error : OnParseError
}

///|
/// Default read options: scan the first 100 records for inference and
/// fail the read on a cell that doesn't fit its inferred dtype
/// (`on_parse_error = Raise`).
pub fn NdjsonReadOptions::default() -> NdjsonReadOptions {
  { infer_schema_rows: 100, on_parse_error: Raise }
}

///|
/// Parse an NDJSON string (one JSON object per line) into a `DataFrame`.
///
/// Pipeline:
///   1. Split `content` on `\n`. Each non-blank line is parsed with
///      `@json.parse`; a malformed line surfaces as
///      `ParseError("line N: ...")` (1-based). Blank / whitespace-only
///      lines are skipped, so the writer's trailing newline — and any
///      incidental blank lines — never produce phantom records.
///   2. The parsed values are handed to `frame_from_json_records`,
///      which validates each is an object, collects headers in
///      first-seen order across all records (sparse records → null
///      cells), infers one dtype per column, and materialises the
///      frame (see that helper, shared with `parse_json_records_str`,
///      for the per-column rules).
///
/// Empty input — or input that is entirely blank lines — yields a 0×0
/// frame, matching `parse_json_records_str`'s empty-array behaviour.
///
/// Errors:
/// - `Err(ParseError(...))` — a malformed line, a line whose value is
///   not a JSON object, or a non-null cell that does not fit its
///   column's inferred dtype (the last unless `options.on_parse_error`
///   is `Null`, which downgrades that cell to a null instead).
/// - Whatever `DataFrame::new` propagates.
pub fn parse_ndjson_str(
  content : String,
  options : NdjsonReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  // Materialise the line views so the loop can carry a 1-based index
  // for diagnostics (the same `for i, x in ...` idiom the other readers
  // use). The views borrow `content`, so this is cheap.
  let lines = content.split("\n").to_array()
  let records : Array[Json] = []
  for i, line in lines {
    // Skip blank / whitespace-only lines: the trailing `\n` the writer
    // emits leaves an empty final segment, and hand-written NDJSON may
    // carry stray blank lines. `@json.parse` tolerates a trailing `\r`
    // (CRLF) and surrounding spaces as JSON whitespace, so a real
    // record needs no trimming before parsing.
    if line.is_blank() {
      continue
    }
    let json = @json.parse(line) catch {
      err =>
        raise @types.DataError::ParseError(
          "line \{i + 1}: invalid JSON: " + err.to_string(),
        )
    }
    records.push(json)
  }
  frame_from_json_records(
    records,
    options.infer_schema_rows,
    options.on_parse_error,
  )
}

///|
/// Read an NDJSON file using the default options.
pub fn read_ndjson(path : String) -> @frame.DataFrame raise @types.DataError {
  read_ndjson_with_options(path, NdjsonReadOptions::default())
}

///|
/// Read an NDJSON file with custom options. Filesystem errors surface
/// as `raise IoError(message)`.
pub fn read_ndjson_with_options(
  path : String,
  options : NdjsonReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  let content = @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  parse_ndjson_str(content, options)
}

///|
/// Render a `DataFrame` as an NDJSON string: one flat JSON object per
/// row, each terminated by `\n` (including the last, matching the CSV
/// writer's per-row LF and Polars' `write_ndjson`). A 0-row frame
/// renders the empty string.
///
/// Per-cell conventions are shared with `format_json_records` via
/// `scalar_to_json`: `Null → null`; `Int` → JSON number (exact up to
/// ±2^53); finite `Float` → JSON number, non-finite (`NaN` /
/// `±Infinity`) → `null` so each line stays valid JSON; `Bool` →
/// `true` / `false`; `String` → escaped JSON string. Keys appear in
/// `df.columns()` order, preserved by the linked-hash-map `Map` backing
/// each record object.
pub fn format_ndjson(df : @frame.DataFrame) -> String {
  // Share the column-major record walk with `format_json_records` /
  // `format_vega_lite` (see `df_to_json_records`); NDJSON differs only in
  // the framing — one object per line, each terminated by `\n`.
  let buf = StringBuilder::new()
  for obj in df_to_json_records(df) {
    buf.write_string(obj.stringify())
    buf.write_char('\n')
  }
  buf.to_string()
}

///|
/// Write a `DataFrame` to an NDJSON file. Filesystem errors surface as
/// `raise IoError(message)`.
pub fn write_ndjson(
  path : String,
  df : @frame.DataFrame,
) -> Unit raise @types.DataError {
  let content = format_ndjson(df)
  @fs.write_string_to_file(path, content) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}
