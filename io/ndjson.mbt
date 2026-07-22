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
// each line valid JSON, and an `Int` keeps its dtype and round-trips exactly
// across the full `Int64` range — it is written as verbatim decimal text and
// recovered from the number's preserved `repr` (json.mbt Caveat 2), even
// though the `@json` number model is `Double`.
//
// Reading is lenient about line endings: lines are split on `\n`, a
// trailing `\r` (CRLF input) is tolerated as JSON whitespace by
// `@json.parse`, and blank / whitespace-only lines are skipped — so the
// writer's trailing newline (and any incidental blank lines) round-trip
// without producing phantom rows.

///|
/// Parse an NDJSON string (one JSON object per line) into a `DataFrame`.
///
/// Pipeline:
///   1. Split `content` on `\n`. Each non-blank line is parsed with
///      `@json.parse`; a malformed line surfaces as
///      `ParseError(Message("line N: ..."))` (1-based). Blank / whitespace-only
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
/// Raises:
/// - `ParseError(Message(...))` — a malformed line or a line whose value is
///   not a JSON object.
/// - `ParseError(Cell(...))` — a non-null cell does not fit its inferred
///   dtype, unless `options.on_parse_error` is `Null`, which downgrades that
///   cell to a null instead.
/// - Whatever `DataFrame::new` propagates.
pub fn parse_ndjson_str(
  content : String,
  options? : JsonReadOptions = JsonReadOptions(),
) -> @frame.DataFrame raise @types.DataError {
  parse_ndjson_str_projected(content, options, None)
}

///|
/// Shared core behind `parse_ndjson_str` and `read_ndjson_projected`: the full
/// line-split / per-line parse pipeline documented on `parse_ndjson_str`, with
/// one extra knob — `projection`. `None` builds every column; `Some(names)`
/// builds only the named columns (in first-seen header order), the
/// projection-pushdown path the lazy `scan_ndjson` source uses. Every line is
/// still parsed (streaming is v0.6), and record validation runs before the
/// column filter — so a projected read fails on a malformed or non-object line
/// exactly as a full read does; only a parse error confined to a dropped column
/// goes unraised (see `frame_from_json_records`).
fn parse_ndjson_str_projected(
  content : String,
  options : JsonReadOptions,
  projection : Array[String]?,
  predicate? : @expr.Expr,
) -> @frame.DataFrame raise @types.DataError {
  // Strip a leading UTF-8 BOM (shared with the CSV / JSON readers) before the
  // line split, so a BOM on the first record line doesn't make `@json.parse`
  // reject it at column 0 while later lines parse — an asymmetric failure on
  // Excel-saved files.
  let content = strip_utf8_bom(content)
  // Materialise the line views so the loop can carry a 1-based index
  // for diagnostics (the same `for i, x in ...` idiom the other readers
  // use). The views borrow `content`, so this is cheap.
  let lines = content.split("\n").to_array()
  let records : Array[Json] = []
  // Parallel to `records`: the 1-based physical file line each kept record came
  // from, so a build-stage type error reports the true line despite the blank
  // lines skipped between records (which shift the record index off the line).
  let record_lines : Array[Int] = []
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
          @types.ParseErrorDetail::Message(
            "line \{i + 1}: invalid JSON: \{err}",
          ),
        )
    }
    records.push(json)
    record_lines.push(i + 1)
  }
  frame_from_json_records(
    records,
    options.infer_schema_rows,
    options.on_parse_error,
    projection,
    Some(record_lines),
    predicate?,
  )
}

///|
/// Read an NDJSON file. `options` defaults to `JsonReadOptions()`, so
/// `read_ndjson(path)` is the default-options read. Filesystem errors surface
/// as `raise IoError(message)`.
pub fn read_ndjson(
  path : String,
  options? : JsonReadOptions = JsonReadOptions(),
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_ndjson_str(content, options~)
}

///|
/// Read an NDJSON file, keeping only the rows `predicate` selects — the
/// file-backed entry behind the lazy `scan_ndjson` source's **predicate
/// push-down**, and the NDJSON twin of `read_csv_pruned`. An `#internal`
/// engine seam.
///
/// Every line is still parsed and validated (a malformed or non-object line
/// fails exactly as in a full read); the push-down skips the *typed* build of
/// the columns the predicate does not read, for the records it drops. Dtype
/// inference still walks every record, so dtypes match an eager
/// read-then-filter, and a dropped record's cell error in a non-key column no
/// longer surfaces — the same trade projection push-down documents.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn read_ndjson_pruned(
  path : String,
  options : JsonReadOptions,
  projection : Array[String]?,
  predicate : @expr.Expr,
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_ndjson_str_projected(content, options, projection, predicate~)
}

///|
/// Read an NDJSON file, building only the columns named in `projection` — the
/// file-backed entry behind the lazy `scan_ndjson` source's projection
/// pushdown. Identical to `read_ndjson` except that a column whose
/// header name is not in `projection` is never inferred or built (see
/// `frame_from_json_records` for the precise contract, including the one
/// behavioural consequence: a parse error confined to a dropped column does not
/// surface). Filesystem errors surface as `raise IoError(message)`.
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

///|
/// Render a `DataFrame` as an NDJSON string: one flat JSON object per
/// row, each terminated by `\n` (including the last, matching the CSV
/// writer's per-row LF and Polars' `write_ndjson`). A 0-row frame
/// renders the empty string.
///
/// Per-cell conventions are shared with `format_json_records` via
/// `scalar_to_json`: `Null → null`; `Int` → JSON number (no fractional part;
/// exact across the full `Int64` range via the preserved `repr`); finite
/// `Float` → JSON number, non-finite (`NaN` /
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
/// `raise IoError(message)`. A string cell (or column name) holding an
/// unpaired UTF-16 surrogate is refused with `raise InvalidOperation` —
/// the UTF-8 file encoding would swallow the following code unit and
/// corrupt the line framing.
pub fn write_ndjson(
  path : String,
  df : @frame.DataFrame,
) -> Unit raise @types.DataError {
  let content = format_ndjson(df)
  write_text(path, content)
}
