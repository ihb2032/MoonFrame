// JSON record-style serialisation for `DataFrame`: the "records" /
// "row-orientation" wire shape — one top-level array of flat objects
// (`[{...}, ...]`), the canonical layout that pandas, polars, and most
// JSON tooling produce by default. This file is the format's own face:
// the read options, the string / file entry points, and the `@json`
// payload adapter. Everything the JSON family shares — the
// records → frame core (also driven by NDJSON), the cell mapping (also
// feeding chart export), and the round-trip caveats — lives in
// `json_core.mbt`; the line-delimited sibling (NDJSON / JSON Lines)
// lives in `ndjson.mbt`.

///|
/// Options that control how a JSON records payload is parsed into a
/// `DataFrame`.
///
/// - `infer_schema_rows` — number of leading records inspected when
///   guessing each column's dtype. `0` (or any value `<= 0`) lifts the
///   cap and scans every record (Polars' `infer_schema_length=None`).
///   Records past a finite window are still parsed under the chosen
///   dtype; one that doesn't fit is handled per `on_parse_error`.
/// - `on_parse_error` — what to do when a non-null cell past the
///   inference window fails to parse under its column's locked-in dtype:
///   `Raise` (default) fails with `ParseError(Cell(...))`; `Null`
///   downgrades the offending cell to a null and continues (Polars'
///   `ignore_errors=True`). See `OnParseError`.
///
/// The NDJSON reader shares this type: the two formats differ in framing,
/// not in what there is to configure.
pub struct JsonReadOptions {
  infer_schema_rows : Int
  on_parse_error : OnParseError
}

///|
/// Build read options. Both fields have defaults: scan the first 100 records
/// for inference and fail the read on a cell that doesn't fit its inferred
/// dtype. `JsonReadOptions::JsonReadOptions()` is the all-defaults reader; name only what
/// differs, as in `JsonReadOptions::JsonReadOptions(on_parse_error=Null)`.
pub fn JsonReadOptions::JsonReadOptions(
  infer_schema_rows? : Int = DEFAULT_INFER_SCHEMA_ROWS,
  on_parse_error? : OnParseError = Raise,
) -> JsonReadOptions {
  { infer_schema_rows, on_parse_error }
}

///|
/// Parse a JSON records string (`[ {...}, ... ]`) into a `DataFrame`.
///
/// `@json.parse` produces the `Json` AST; a top-level value that is not
/// an array surfaces as `ParseError`. The array's elements are then
/// handed to `frame_from_json_records`, which validates each is an
/// object, collects headers in first-seen order across all records,
/// infers one dtype per column, and materialises the frame (see that
/// helper for the per-column rules). An empty array — like empty or
/// whitespace-only input — yields a 0×0 frame.
///
/// Raises:
/// - `ParseError(Message(...))` — malformed JSON, a top-level value that is
///   not an array, or a record that is not an object.
/// - `ParseError(Cell(...))` — a non-null cell does not fit the column's
///   inferred dtype, unless `options.on_parse_error` is `Null`, which
///   downgrades that cell to a null instead.
/// - Whatever `DataFrame::from_parts` propagates (duplicate-header is
///   pre-empted upstream; length-mismatch cannot fire because every
///   column is built off `records.length()`).
pub fn parse_json_str(
  content : String,
  options? : JsonReadOptions = JsonReadOptions::JsonReadOptions(),
) -> @frame.DataFrame raise @types.DataError {
  // Strip a leading UTF-8 BOM (shared with the CSV / NDJSON readers); `@json.parse`
  // rejects a stray `U+FEFF` at column 0, so a file saved by Excel would otherwise
  // fail to read. Done first, so a BOM-only file still short-circuits as empty.
  let content = strip_utf8_bom(content)
  // Treat a blank payload (empty or whitespace-only) as "no payload" and
  // short-circuit to a 0×0 frame, so callers can stream JSON without
  // special-casing it — and so a whitespace-only file matches the NDJSON
  // reader (which skips blank lines) rather than raising on an absent
  // top-level value.
  if content.is_blank() {
    return @frame.DataFrame::DataFrame([])
  }
  let json = parse_json_payload(content)
  let records = match json {
    Array(arr) => arr
    _ =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "expected a JSON array of objects at the top level",
        ),
      )
  }
  frame_from_json_records(
    records,
    options.infer_schema_rows,
    options.on_parse_error,
    None,
    // JSON-array records have no source line of their own; build-stage errors
    // are numbered by record (1-based array index).
    None,
  )
}

///|
/// Read a JSON records file. `options` defaults to `JsonReadOptions::JsonReadOptions()`, so
/// `read_json(path)` is the default-options read. Filesystem errors surface
/// as `raise IoError(message)`.
pub fn read_json(
  path : String,
  options? : JsonReadOptions = JsonReadOptions::JsonReadOptions(),
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_json_str(content, options~)
}

///|
/// Render a `DataFrame` as a JSON records string `[ {...}, ... ]`.
///
/// Per cell:
/// - `Null` → JSON `null`
/// - `Int`  → JSON number (no fractional part)
/// - `Float`→ JSON number for finite values. `NaN` / `±Infinity` have
///   no JSON literal, so they are emitted as `null` (matching pandas'
///   `to_json`) to keep the output valid JSON — a round-trip reads a
///   non-finite cell back as a null.
/// - `Bool` → JSON `true` / `false`
/// - `String` → JSON string (escaping `"`, `\`, control chars via the
///   builtin stringifier — we deliberately do **not** roll our own
///   escape so any future Unicode spec tweaks land transparently)
///
/// Keys appear in the column declaration order, preserved by the
/// builtin `Map` (linked-hash-map) used for each record object.
pub fn format_json(df : @frame.DataFrame) -> String {
  Json::array(df_to_json_records(df)).stringify()
}

///|
/// Write a `DataFrame` to a JSON records file. Filesystem errors
/// surface as `raise IoError(message)`. A string cell (or column name)
/// holding an unpaired UTF-16 surrogate is refused with `raise
/// InvalidOperation` — the UTF-8 file encoding would swallow the
/// following code unit and corrupt the JSON framing.
pub fn write_json(
  path : String,
  df : @frame.DataFrame,
) -> Unit raise @types.DataError {
  let content = format_json(df)
  write_text(path, content)
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// Re-raise `@json.parse`'s failure as this module's `ParseError`, so the
/// parser's main pipeline sees one error type and stays in straight-line
/// `match` form. The
/// concrete `ParseError` is rendered through its `Show` impl so the
/// caller sees the same diagnostic the standard library would.
fn parse_json_payload(content : String) -> Json raise @types.DataError {
  @json.parse(content.view()) catch {
    err =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message("invalid JSON: \{err}"),
      )
  }
}
