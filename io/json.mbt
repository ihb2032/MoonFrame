// JSON record-style serialisation for `DataFrame`: the "records" /
// "row-orientation" wire shape — one top-level array of flat objects
// (`[{...}, ...]`), the canonical layout most JSON tooling produces by
// default. This file is the format's own face:
// the read options, the string / file entry points, and the `@json`
// payload adapter. Everything the JSON family shares — the
// records → frame core (also driven by NDJSON), the cell mapping (also
// feeding chart export), and the round-trip caveats — is factored into
// the shared core the whole family drives; the line-delimited sibling
// (NDJSON / JSON Lines) is a format face of its own.

///|
/// Options that control how a JSON records payload is parsed into a
/// `DataFrame`.
///
/// - `infer_schema_rows` — number of leading records inspected when
///   guessing each column's dtype. `0` (or any value `<= 0`) lifts the
///   cap and scans every record. Records past a finite window are still
///   parsed under the chosen
///   dtype; one that doesn't fit is handled per `on_parse_error`.
/// - `on_parse_error` — what to do when a non-null cell past the
///   inference window fails to parse under its column's locked-in dtype:
///   `Raise` (default) fails with `ParseError(Cell(...))`; `Null`
///   downgrades the offending cell to a null and continues.
/// - `reject_duplicate_keys` — whether an object repeating a key is an
///   error. The default `false` keeps the common JSON reading: a
///   repeated key survives only as its **last** value, the earlier
///   ones silently dropped. `true` rejects the read instead —
///   `ParseError(Message(...))` naming the key and the line / column it
///   repeated at — so a payload that would silently lose cells fails
///   loudly. The check rides the parser itself (which reports whichever
///   trouble it meets first: a repeat ahead of a syntax error surfaces as
///   the repeat, and vice versa).
/// - `allow_nonfinite_floats` — when `true` (default), a number whose
///   magnitude overflows `Double` (e.g. `1e999`) infers the column as
///   `Float` holding `±Infinity`. When `false`, such a number is not
///   `Float` evidence — the column stays `String`, the CSV reader's
///   `allow_nonfinite_floats` rule, so a silent retype to `Float(∞)`
///   cannot happen either way a file is read.
/// - `dtypes` — per-column dtype overrides that pin a column's type
///   instead of inferring it, as a name → `DataType` map. Only the four
///   dtypes a reader can parse (`Int` / `Float` / `Bool` / `String`) can
///   be pinned — anything else is refused with `InvalidOperation` at read
///   time, as is a name the input does not carry (a pin is an assertion
///   about the input; a misspelt one fails rather than silently does
///   nothing). Columns not named keep their inferred dtype. A pinned
///   column skips inference entirely, and a cell that does not parse
///   under the pin — a JSON `String` in a column pinned `Int`, say, since
///   JSON has strong types and no `"1" → 1` coercion — is handled per
///   `on_parse_error`. The map is copied, so mutating it afterwards
///   cannot alter the options; read it back through the `dtypes()`
///   accessor.
///
/// The NDJSON reader shares this type: the two formats differ in framing,
/// not in what there is to configure.
pub struct JsonReadOptions {
  infer_schema_rows : Int32
  on_parse_error : OnParseError
  reject_duplicate_keys : Bool
  allow_nonfinite_floats : Bool
  priv dtypes : Map[String, @types.DataType]
}

///|
/// The per-column dtype overrides. A fresh `Map` is returned, so a caller
/// cannot reach into the options and change what the reader pins — the
/// same reason the constructor copies its input.
pub fn JsonReadOptions::dtypes(
  self : JsonReadOptions,
) -> Map[String, @types.DataType] {
  copy_dtypes(self.dtypes)
}

///|
/// Build read options. Every field has a default: scan the first 100 records
/// for inference, fail the read on a cell that doesn't fit its inferred
/// dtype, let a repeated object key keep its last value (the common JSON
/// reading), and accept overflow-to-`Infinity` numbers as `Float` cells. `JsonReadOptions::JsonReadOptions()` is the all-defaults reader; name only what
/// differs, as in `JsonReadOptions::JsonReadOptions(on_parse_error=Null)`.
/// `dtypes` is copied, so mutating the map afterwards cannot alter the
/// options.
pub fn JsonReadOptions::JsonReadOptions(
  infer_schema_rows~ : Int32 = DEFAULT_INFER_SCHEMA_ROWS,
  on_parse_error~ : OnParseError = Raise,
  reject_duplicate_keys~ : Bool = false,
  allow_nonfinite_floats~ : Bool = true,
  dtypes~ : Map[String, @types.DataType] = Map([]),
) -> JsonReadOptions {
  {
    infer_schema_rows,
    on_parse_error,
    reject_duplicate_keys,
    allow_nonfinite_floats,
    dtypes: copy_dtypes(dtypes),
  }
}

///|
/// Parse a JSON records string (`[ {...}, ... ]`) into a `DataFrame`.
///
/// `@json.parse` produces the `Json` AST; a top-level value that is not
/// an array surfaces as `ParseError`. The array's elements are then
/// handed to `frame_from_json_records`, which validates each is an
/// object, collects headers in first-seen order across all records,
/// infers one dtype per column, and materialises the frame. An empty
/// array — like empty or whitespace-only input — yields a 0×0 frame.
///
/// Raises:
/// - `ParseError(Message(...))` — malformed JSON, a top-level value that is
///   not an array, or a record that is not an object.
/// - `InvalidOperation` — `options.dtypes` names a column the input does
///   not carry, or pins a dtype that has no read parser (anything but
///   `Int` / `Float` / `Bool` / `String`).
/// - `ParseError(Cell(...))` — a non-null cell does not fit the column's
///   inferred dtype, unless `options.on_parse_error` is `Null`, which
///   downgrades that cell to a null instead.
/// - Whatever `DataFrame::from_parts` propagates (duplicate-header is
///   pre-empted upstream; length-mismatch cannot fire because every
///   column is built off `records.length()`).
pub fn parse_json_str(
  content : String,
  options~ : JsonReadOptions = JsonReadOptions::JsonReadOptions(),
) -> @frame.DataFrame raise @types.DataError {
  parse_json_str_projected(content, options, None, None)
}

///|
/// Shared core behind `parse_json_str` and the JSON scan driver's read: the
/// full array-parse / records pipeline `parse_json_str` runs, with the two
/// knobs the lazy `scan_json` source pushes in — `projection` builds only
/// the named columns (in first-seen header order), and `pruner` keeps only
/// the rows its callback selects, the same pair the CSV / NDJSON projected
/// cores honour. The top-level array must still be parsed whole to find its
/// records, so what the knobs prune is the *assembly* — record validation
/// and header collection run before the filter, and a projected / pruned
/// read fails on malformed input exactly as a full one does; only a parse
/// error confined to a dropped column or row goes unraised, because those
/// cells are never built.
fn parse_json_str_projected(
  content : String,
  options : JsonReadOptions,
  projection : Array[String]?,
  pruner : RowPruner?,
) -> @frame.DataFrame raise @types.DataError {
  // Strip a leading UTF-8 BOM (shared with the CSV / NDJSON readers); `@json.parse`
  // rejects a stray `U+FEFF` at column 0, so a file saved by Excel would otherwise
  // fail to read. Done first, so a BOM-only file still short-circuits as empty.
  let content = strip_utf8_bom(content)
  // Treat a blank payload (empty or whitespace-only) as "no payload" and
  // short-circuit to a 0×0 frame, so callers can stream JSON without
  // special-casing it — and so a whitespace-only file matches the NDJSON
  // reader (which skips blank lines) rather than raising on an absent
  // top-level value. The dtype pins are still asserted: no payload means
  // no columns, so every pinned name is a false assertion — the same
  // check an empty array takes below, or a misspelt pin rides the blank
  // file as a silent 0×0 success.
  if content.is_blank() {
    check_override_columns(options.dtypes, [])
    return @frame.DataFrame::DataFrame([])
  }
  // The strict duplicate-key reading rides the parser itself — it reports
  // the repeat with a line / column, and off by default (the common JSON
  // last-wins reading) it costs nothing.
  let json = @json.parse(
    content.view(),
    reject_duplicate_keys=options.reject_duplicate_keys,
  ) catch {
    // The parser's repeat diagnostic, re-homed in this module's error type
    // with the key named and the position it repeated at — the whole
    // document parses in one call, so the parser's line is the file's own
    // (see `duplicate_key_detail` for the per-line reader's spelling).
    DuplicateKey(pos, key) =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          duplicate_key_detail(key, pos.line, pos.column, single_line=false),
        ),
      )
    // Re-raise every other parse failure as this module's `ParseError`, so
    // the parser's main pipeline sees one error type and stays in
    // straight-line `match` form; the concrete `ParseError` is rendered
    // through its `Show` impl so the caller sees the same diagnostic the
    // standard library would.
    err =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message("invalid JSON: \{err}"),
      )
  }
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
    projection,
    // JSON-array records have no source line of their own; build-stage errors
    // are numbered by record (1-based array index).
    None,
    pruner?,
    allow_nonfinite=options.allow_nonfinite_floats,
    dtypes=options.dtypes,
  )
}

///|
/// Read a JSON records file. `options` defaults to `JsonReadOptions::JsonReadOptions()`, so
/// `read_json(path)` is the default-options read. Filesystem errors surface
/// as `raise IoError(message)`.
pub fn read_json(
  path : String,
  options~ : JsonReadOptions = JsonReadOptions::JsonReadOptions(),
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
///   no JSON literal, so they are emitted as `null` to keep the output
///   valid JSON — a round-trip reads a non-finite cell back as a null.
/// - `Bool` → JSON `true` / `false`
/// - `String` → JSON string (escaping `"`, `\`, control chars via the
///   builtin stringifier — we deliberately do **not** roll our own
///   escape so any future Unicode spec tweaks land transparently)
/// - `Date` / `Timestamp` / `Decimal` → JSON string holding the cell's
///   value-form rendering (ISO calendar text / ISO instant / fixed-point
///   decimal); the readers never infer these dtypes, so a round-trip
///   reads the column back as `String` / `Float` respectively.
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
