// JSON record-style serialisation for `DataFrame`. The shape on the
// wire is an array of flat objects (`[{...}, ...]`), the canonical
// "records" / "row-orientation" layout that pandas, polars, and most
// JSON-Lines tooling produce by default. Per-column type inference
// mirrors the CSV reader — Int → Float → Bool → String, with nulls
// passing through transparently — so the round-trip
// `read_csv → write_json_records → read_json` preserves dtypes for most
// frames whose JSON values stay within the four v0.1 dtypes.
//
// Caveat 1 — integral-valued `Float`. JSON has a single number type and
// `Double::to_string` drops the fractional part of a whole value
// (`2.0` → `"2"`), so a `Float` column whose cells are all integral is
// re-inferred as `Int` on read-back (`json_value_as_int` accepts any
// `Number` equal to its truncation). The dtype narrows `Float → Int`;
// the values themselves are unchanged. This is inherent to JSON's
// typeless numbers — and it is the one place CSV and JSON inference
// diverge: the CSV reader keeps `"2.0"` as `Float` only because the
// *text* still carries the decimal point, which a JSON number does not.
//
// Caveat 2 — large `Int64`. JSON numbers (and `@json`'s reader) are
// IEEE-754 `Double`, so an `Int64` whose magnitude exceeds 2^53 has no exact
// `Double` value. To keep it lossless, `scalar_to_json` writes every `Int`
// with its verbatim decimal text (`Json::number(.., repr=..)`), and
// `json_value_as_int` recovers the exact `Int64` from that text on read-back
// (`@json.parse` parks an out-of-`Double`-range integer as `±Infinity` but
// preserves its digits in `Number.repr`). So a full-range `Int64` round-trips
// exactly, dtype and value intact — only an external JSON integer beyond
// `Int64`'s own range (|v| ≥ 2^63) is unrepresentable and infers as `Float`.
// When such a large integer lands in a `Float` column instead (a sibling cell
// is fractional, so inference picks `Float`), `json_value_as_float` likewise
// recovers the nearest finite `Double` from the preserved digits rather than
// corrupting the cell to `Infinity`.
//
// Caveat 3 — all-non-finite / all-null `Float`. `scalar_to_json` maps every
// `NaN` / `±Infinity` to JSON `null` (no JSON literal exists for them), so a
// `Float` column that is *entirely* non-finite and/or null writes as all
// `null`. On read-back, an all-null column carries no dtype signal and infers
// as `String` (the all-null default), narrowing `Float → String`. This is
// inherent to JSON's lack of a `NaN` literal plus schemaless inference; a
// column with at least one finite value keeps its `Float` dtype. (Same applies
// to NDJSON, which shares `scalar_to_json` and the inference core.)
//
// All parsing and stringification goes through the builtin `@json`
// package so we get standards-conformant string escaping, the
// `NaN` / `Infinity` rendering convention, and number formatting for
// free.
//
// The line-delimited sibling (NDJSON / JSON Lines) lives in
// `ndjson.mbt`; it shares this file's `frame_from_json_records` records
// → frame core and `scalar_to_json` cell mapping, differing only in the
// framing (one object per line vs. one top-level array).

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
///   `Raise` (default) fails the whole read with `ParseError`; `Null`
///   downgrades the offending cell to a null and continues (Polars'
///   `ignore_errors=True`). See `OnParseError`.
pub(all) struct JsonReadOptions {
  infer_schema_rows : Int
  on_parse_error : OnParseError
}

///|
/// Default read options: scan the first 100 records for inference and
/// fail the read on a cell that doesn't fit its inferred dtype
/// (`on_parse_error = Raise`).
pub fn JsonReadOptions::default() -> JsonReadOptions {
  { infer_schema_rows: DEFAULT_INFER_SCHEMA_ROWS, on_parse_error: Raise }
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
/// - `ParseError(...)` — malformed JSON, a top-level value that
///   is not an array, a record that is not an object, or a non-null
///   cell that does not fit the column's inferred dtype (the last
///   unless `options.on_parse_error` is `Null`, which downgrades that
///   cell to a null instead of failing the read).
/// - Whatever `DataFrame::new` propagates (duplicate-header is
///   pre-empted upstream; length-mismatch cannot fire because every
///   column is built off `records.length()`).
pub fn parse_json_records_str(
  content : String,
  options : JsonReadOptions,
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
    return @frame.DataFrame::new([])
  }
  let json = parse_json_payload(content)
  let records = match json {
    Array(arr) => arr
    _ =>
      raise @types.DataError::ParseError(
        "expected a JSON array of objects at the top level",
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
/// Shared "records → `DataFrame`" core for the JSON-records and NDJSON
/// readers. Both produce an `Array[Json]` of candidate records — the
/// array reader from one top-level `[...]`, the NDJSON reader from one
/// object per line — and from there the pipeline is identical:
///   1. Validate every element is a `Json::Object`, pulling the inner
///      `Map` out for downstream passes (so inference / build don't
///      have to re-match).
///   2. Collect headers in first-seen order across **all** records, so
///      a sparse record (missing some keys) still contributes its own
///      columns and gets nulls for the missing fields.
///   3. Infer each column's dtype over the first `infer_schema_rows`
///      rows in priority order `Int → Float → Bool → String` (a null cell
///      within them is skipped but still counts toward the window);
///      the first dtype that accepts every probed cell wins, and an
///      all-null column defaults to `String` (same convention as the
///      CSV reader — no information to disambiguate).
///   4. Materialise each column into a typed `Series` and wrap through
///      `DataFrame::new`.
///
/// An empty record set, or records that are all empty objects
/// (`[{}, {}, ...]`, which would be N rows of zero columns that
/// `DataFrame::new` cannot model), collapse to a 0×0 frame — the same
/// shape both readers' empty-input paths produce. A cell that doesn't
/// fit its column's inferred dtype is handled per `on_parse_error`
/// (raise `ParseError`, or downgrade the cell to a null), shared by both
/// readers so JSON-array and NDJSON input agree on the policy.
///
/// `projection` narrows which columns are built: `None` builds every column
/// (the eager `read_*` behaviour), `Some(names)` builds only the columns whose
/// header name appears in `names`, in first-seen header order, leaving the rest
/// uninferred and unbuilt — the projection-pushdown path the lazy `scan_ndjson`
/// source uses. Record validation and header collection run *before* the
/// filter, so a projected read still fails on a non-object record exactly as a
/// full read does; only a parse error confined to a dropped column goes
/// unraised, because that column is never built.
///
/// `source_lines` (parallel to `records`) lets a line-oriented caller number
/// build-stage type errors by physical file line: `Some(lines)` reports
/// `line N` (the NDJSON reader, whose skipped blank lines shift the record
/// index off the line), `None` reports `record N` (the JSON-array reader,
/// whose records have no line of their own).
fn frame_from_json_records(
  records : Array[Json],
  infer_schema_rows : Int,
  on_parse_error : OnParseError,
  projection : Array[String]?,
  source_lines : Array[Int]?,
) -> @frame.DataFrame raise @types.DataError {
  if records.is_empty() {
    return @frame.DataFrame::new([])
  }
  let objs : Array[Map[String, Json]] = Array::new(capacity=records.length())
  let headers : Array[String] = []
  let header_set : Map[String, Unit] = Map([])
  for i, rec in records {
    match rec {
      Object(obj) => {
        // `@json.parse` already collapsed any duplicate keys within this one
        // object (last value wins) before we see the `Map`, so `{"a":1,"a":2}`
        // reads as a single `a = 2` with no diagnostic — there is no per-object
        // `DuplicateColumn` signal (cross-record headers are collected first-seen).
        for k, _ in obj {
          if !header_set.contains(k) {
            header_set[k] = ()
            headers.push(k)
          }
        }
        objs.push(obj)
      }
      _ =>
        // Carry the locator, like every other error in these readers: in a
        // large file "which record" is the whole diagnostic.
        raise @types.DataError::ParseError(
          "\{json_record_locator(source_lines, i)}: expected each record to be a JSON object",
        )
    }
  }
  let ncols = headers.length()
  if ncols == 0 {
    return @frame.DataFrame::new([])
  }
  // Build one typed column per header, skipping any the projection drops; the
  // surviving columns keep first-seen header order, so a projected read is
  // column-for-column a sub-frame of the full read. A projection matching no
  // header falls back to a full read (see `effective_projection`) so the row
  // count survives for the as-built error to surface downstream.
  let projection = effective_projection(projection, headers)
  let series : Array[@series.Series] = []
  for name in headers {
    let included = match projection {
      None => true
      Some(names) => names.contains(name)
    }
    if included {
      let dt = infer_json_column_dtype(objs, name, infer_schema_rows)
      series.push(
        build_json_column(name, dt, objs, on_parse_error, source_lines),
      )
    }
  }
  @frame.DataFrame::new(series)
}

///|
/// Read a JSON records file using the default options.
pub fn read_json(path : String) -> @frame.DataFrame raise @types.DataError {
  read_json_with_options(path, JsonReadOptions::default())
}

///|
/// Read a JSON records file with custom options. Filesystem errors
/// surface as `raise IoError(message)`.
pub fn read_json_with_options(
  path : String,
  options : JsonReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_json_records_str(content, options)
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
pub fn format_json_records(df : @frame.DataFrame) -> String {
  Json::array(df_to_json_records(df)).stringify()
}

///|
/// Write a `DataFrame` to a JSON records file. Filesystem errors
/// surface as `raise IoError(message)`. A string cell (or column name)
/// holding an unpaired UTF-16 surrogate is refused with `raise
/// InvalidOperation` — the UTF-8 file encoding would swallow the
/// following code unit and corrupt the JSON framing.
pub fn write_json_records(
  path : String,
  df : @frame.DataFrame,
) -> Unit raise @types.DataError {
  let content = format_json_records(df)
  write_text(path, content)
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// Wrap `@json.parse`'s raising convention behind a `Result` so the
/// parser's main pipeline stays in straight-line `match` form. The
/// concrete `ParseError` is rendered through its `Show` impl so the
/// caller sees the same diagnostic the standard library would.
fn parse_json_payload(content : String) -> Json raise @types.DataError {
  @json.parse(content.view()) catch {
    err => raise @types.DataError::ParseError("invalid JSON: \{err}")
  }
}

///|
/// Materialise `df` as an array of flat JSON record objects — one
/// `Json::object` per row, keys in column-declaration order, every cell
/// mapped through `scalar_to_json` (so nulls and non-finite floats land on
/// JSON `null`). Shared by the three records-shaped emitters:
/// `format_json_records` wraps the array in one top-level `[...]`,
/// `format_ndjson` stringifies one object per line, and `format_vega_lite`
/// inlines it as a Vega-Lite `data.values` array — so the cell conventions
/// stay identical across all three without re-implementing the row walk.
fn df_to_json_records(df : @frame.DataFrame) -> Array[Json] {
  let names = df.columns()
  let nrows = df.nrows()
  // Materialise the whole frame once (column-major) through the shared
  // `to_scalar_matrix` so a record is assembled by plain `cols[c][r]` reads
  // rather than per-cell `item`.
  let cols = df.to_scalar_matrix()
  Array::makei(nrows, r => {
    let obj : Map[String, Json] = Map([])
    for c, name in names {
      obj[name] = scalar_to_json(cols[c][r])
    }
    Json::object(obj)
  })
}

///|
/// Map a `@types.Scalar` into the corresponding `Json` value. `Int` is
/// written as a JSON number carrying its verbatim decimal text as the
/// number's `repr` (`Json::number(v.to_double(), repr=v.to_string())`), so the
/// emitted token is the exact integer even when its magnitude exceeds 2^53 and
/// the `Double` value alone would round — `json_value_as_int` recovers the
/// exact `Int64` from that text on read-back. A finite `Float` becomes a JSON
/// number. A
/// non-finite `Float` (`NaN` / `±Infinity`) has no JSON literal —
/// `@json.stringify` would emit the bare tokens `NaN` / `Infinity` /
/// `-Infinity`, which is invalid JSON that neither
/// `parse_json_records_str` nor a standards-compliant parser can read
/// back — so it is mapped to `null` (matching pandas' `to_json`),
/// keeping the emitted text valid JSON. `Bool` lands on the `true` /
/// `false` variants; `String` passes through and is escaped by the
/// stringifier; `Null` lands on JSON `null`.
fn scalar_to_json(s : @types.Scalar) -> Json {
  match s {
    @types.Scalar::Null => Json::null()
    @types.Scalar::Int(v) => Json::number(v.to_double(), repr=v.to_string())
    @types.Scalar::Float(v) =>
      if v.is_nan() || v.is_inf() {
        Json::null()
      } else if v == 0.0 && v.reinterpret_as_int64() != 0L {
        // A repr-less number renders through `Double`'s Show, which drops
        // the sign of negative zero — the token `0` would read back as
        // `+0.0` (and `1.0 / x` flip from `-inf` to `+inf`). Pin the exact
        // token instead; the reader's `parse_float_opt("-0.0")` keeps the
        // sign.
        Json::number(v, repr="-0.0")
      } else {
        Json::number(v)
      }
    @types.Scalar::Bool(v) => Json::boolean(v)
    @types.Scalar::String(v) => Json::string(v)
  }
}

///|
/// Fetch the value of `name` from `obj`. A missing field on a sparse
/// record is treated as a null cell — every record was already
/// validated as a JSON object by `parse_json_records_str` before
/// reaching this helper, so the lookup boils down to a single map
/// access.
fn lookup_field(obj : Map[String, Json], name : String) -> Json {
  match obj.get(name) {
    Some(v) => v
    None => Json::null()
  }
}

///|
/// Walk the first `limit` records of `name` and pick the narrowest
/// dtype that accepts every non-null cell. Priority order matches
/// the CSV reader: `Int → Float → Bool → String`. A column whose
/// probe window is entirely null falls back to `String` (no signal).
/// A column that mixes dtypes (e.g. `1` then `"hi"`) also lands on
/// `String`, where `build_json_column` re-renders numeric cells via their
/// string form. Adapts the JSON cell source (`Json` values looked up by
/// key) onto the shared `infer_dtype` core.
fn infer_json_column_dtype(
  objs : Array[Map[String, Json]],
  name : String,
  limit : Int,
) -> InferredDtype {
  infer_dtype(
    objs.length(),
    limit~,
    cell=i => lookup_field(objs[i], name),
    is_null=j => j is Null,
    is_int=j => json_value_as_int(j) is Some(_),
    is_float=j => json_value_as_float(j) is Some(_),
    is_bool=j => json_value_as_bool(j) is Some(_),
  )
}

///|
/// Try to read `j` as an `Int64`. For a finite `Number` the check is
/// value-based: accept it when it is exactly integer-valued
/// (`n == n.trunc()`) and within `Int64` range (checked by
/// `@types.double_fits_int64`, since `Int64::MAX` isn't exactly representable
/// as a `Double`), so a token like `1.0e2` lands as `Int(100)`, matching
/// pandas / polars on equivalent CSV. A `Number` whose magnitude overflowed
/// the `Double` (parsed as `±Infinity`) is recovered from its preserved `repr`
/// digits via `parse_int_opt`: a plain in-range decimal becomes the exact
/// `Int64`, while anything else (a genuine `1e100` float, or an integer beyond
/// `Int64`'s range) stays `None` and infers as `Float`.
///
/// Booleans, strings, and null are intentionally rejected — JSON has
/// strong types and silently promoting `true → 1` would surprise
/// callers used to pandas / polars semantics.
fn json_value_as_int(j : Json) -> Int64? {
  match j {
    // A `Double`-overflowing integer is parsed as ±Infinity with its exact
    // decimal preserved in `repr`; a finite `Number` never carries one. So a
    // present `repr` means recover the precise `Int64` from that text — a plain
    // in-range decimal wins, anything else (a real `1e100`, or an integer past
    // `Int64`) stays `None` and infers as `Float` — and the writer emits every
    // `Int`'s exact decimal via `Json::number(.., repr=..)`. A finite `Number`
    // takes the value-based path: integer-valued and within `Int64` range
    // becomes `Int`, matching the integral-float-stays-`Int` rule.
    Number(_, repr=Some(text)) => parse_int_opt(text)
    Number(n, repr=None) =>
      if n != n.trunc() {
        None
      } else if !@types.double_fits_int64(n) {
        None
      } else {
        Some(n.to_int64())
      }
    _ => None
  }
}

///|
/// Try to read `j` as a `Double`. Accepts any `Number`. Booleans,
/// strings, and null are rejected for the same reason as
/// `json_value_as_int`.
fn json_value_as_float(j : Json) -> Double? {
  match j {
    // `@json.parse` parks a `Double`-overflowing integer as `±Infinity` but
    // keeps its exact digits in `repr`; re-parsing those digits recovers the
    // nearest finite `Double` — as the CSV reader's `parse_double` does — rather
    // than the lossy Infinity. `parse_float_opt` routes through that same
    // `@string.parse_double` (and accepts the non-finite forms), so a magnitude
    // that overflows `Double` itself folds back to the original Infinity `n`. A
    // finite `Number` (`repr=None`) takes its value directly.
    Number(n, repr=Some(text)) => Some(parse_float_opt(text, true).unwrap_or(n))
    Number(n, repr=None) => Some(n)
    _ => None
  }
}

///|
/// Try to read `j` as a `Bool`. Only the JSON `true` / `false`
/// variants are accepted; `Number(1)` / `Number(0)` are deliberately
/// **not** treated as booleans, matching `parse_csv_str`'s
/// `parse_bool_opt` rule (numeric `0` / `1` round-trip as `Int`,
/// which the inference order picks up first).
fn json_value_as_bool(j : Json) -> Bool? {
  match j {
    True => Some(true)
    False => Some(false)
    _ => None
  }
}

///|
/// Render any JSON value as a flat string for the `String`-fallback
/// column builder. Numbers render via `Double::to_string` (a whole-valued
/// number with no preserved `repr` loses its fractional part — `2.0` → `"2"`,
/// the String-fallback analogue of the module's integral-`Float` Caveat 1),
/// booleans render `true` / `false`, strings pass through verbatim, and any
/// composite (`Array` / `Object`) falls through to `@json.stringify`.
/// `Null` is filtered out upstream — the build loop calls
/// `values.push(None)` for null cells without invoking this helper —
/// so the catch-all only fires on composites in practice.
fn json_value_to_string_fallback(j : Json) -> String {
  match j {
    True => "true"
    False => "false"
    // Prefer the preserved `repr` so a `Double`-overflowing integer renders as
    // its exact digits rather than "Infinity" when it lands in a String column.
    Number(n, repr~) =>
      match repr {
        Some(text) => text
        None => n.to_string()
      }
    String(s) => s
    _ => (j : Json).stringify()
  }
}

///|
/// Locate a record in a build-stage error message: a 1-based **file line**
/// when the caller supplies a per-record line map (the NDJSON reader, whose
/// blank-line skipping makes the record index diverge from the physical line),
/// or a 1-based **record** number for the JSON-array reader (where records have
/// no line of their own). `source_lines` is parallel to the record array, so
/// the index is always in range.
fn json_record_locator(source_lines : Array[Int]?, i : Int) -> String {
  match source_lines {
    Some(lines) => "line \{lines[i]}"
    None => "record \{i + 1}"
  }
}

///|
/// Materialise one column from the record array using the dtype
/// chosen by inference. Mirrors `build_column` in `csv.mbt`: each
/// branch walks the records in row order and converts the cell into
/// the typed array slot; a value past the inference window that fails
/// to match the locked-in dtype is handled per `on_parse_error`
/// (`Raise` → `ParseError`, `Null` → a null cell).
fn build_json_column(
  name : String,
  dtype : InferredDtype,
  objs : Array[Map[String, Json]],
  on_parse_error : OnParseError,
  source_lines : Array[Int]?,
) -> @series.Series raise @types.DataError {
  let n = objs.length()
  let cell = fn(i : Int) -> Json { lookup_field(objs[i], name) }
  let isnull = fn(c : Json) -> Bool { c is Null }
  match dtype {
    InferInt =>
      build_typed_column(
        name,
        n,
        cell~,
        is_null=isnull,
        parse=json_value_as_int,
        err=(i, c) => {
          @types.DataError::ParseError(
            "column \"\{name}\" \{json_record_locator(source_lines, i)}: JSON value is not an Int (\"\{json_value_to_string_fallback(c)}\")",
          )
        },
        on_parse_error~,
        build=@series.Series::from_int_options,
      )
    InferFloat =>
      build_typed_column(
        name,
        n,
        cell~,
        is_null=isnull,
        parse=json_value_as_float,
        err=(i, c) => {
          @types.DataError::ParseError(
            "column \"\{name}\" \{json_record_locator(source_lines, i)}: JSON value is not a number (\"\{json_value_to_string_fallback(c)}\")",
          )
        },
        on_parse_error~,
        build=@series.Series::from_float_options,
      )
    InferBool =>
      build_typed_column(
        name,
        n,
        cell~,
        is_null=isnull,
        parse=json_value_as_bool,
        err=(i, c) => {
          @types.DataError::ParseError(
            "column \"\{name}\" \{json_record_locator(source_lines, i)}: JSON value is not a Bool (\"\{json_value_to_string_fallback(c)}\")",
          )
        },
        on_parse_error~,
        build=@series.Series::from_bool_options,
      )
    InferString =>
      build_string_column(name, n, cell, isnull, c => {
        json_value_to_string_fallback(c)
      })
  }
}
