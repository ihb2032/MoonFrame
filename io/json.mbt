// JSON record-style serialisation for `DataFrame`. The shape on the
// wire is an array of flat objects (`[{...}, ...]`), the canonical
// "records" / "row-orientation" layout that pandas, polars, and most
// JSON-Lines tooling produce by default. Per-column type inference
// mirrors the CSV reader — Int → Float → Bool → String, with nulls
// passing through transparently — so the round-trip
// `read_csv → write_json_records → read_json` preserves dtypes for
// any frame whose JSON values stay within the four v0.1 dtypes.
//
// All parsing and stringification goes through the builtin `@json`
// package so we get standards-conformant string escaping, the
// `NaN` / `Infinity` rendering convention, and number formatting for
// free.

///|
/// Options that control how a JSON records payload is parsed into a
/// `DataFrame`.
///
/// - `infer_schema_rows` — number of leading records inspected when
///   guessing each column's dtype. Records past this window are still
///   parsed under the chosen dtype, so a misdetected column surfaces
///   as `ParseError` rather than a silent string fallback.
pub(all) struct JsonReadOptions {
  infer_schema_rows : Int
}

///|
/// Default read options: scan the first 100 records for inference.
pub fn JsonReadOptions::default() -> JsonReadOptions {
  { infer_schema_rows: 100 }
}

///|
/// Parse a JSON records string (`[ {...}, ... ]`) into a `DataFrame`.
///
/// Pipeline:
///   1. `@json.parse` produces a `Json` AST. Anything other than a
///      top-level array surfaces as `ParseError`.
///   2. Each element must be a `Json::Object`. Headers are collected
///      in first-seen order across **all** records, so a sparse
///      record (missing some keys) still contributes its own columns
///      and gets nulls for the missing fields.
///   3. Per-column dtype inference walks the first
///      `infer_schema_rows` non-null cells in priority order
///      `Int → Float → Bool → String`. The first dtype that accepts
///      every probed cell wins; an all-null column defaults to
///      `String` (same convention as the CSV reader — no information
///      to disambiguate).
///   4. Each column is materialised into a typed `Series` and wrapped
///      through `DataFrame::new`.
///
/// Errors:
/// - `Err(ParseError(...))` — malformed JSON, a top-level value that
///   is not an array, a record that is not an object, or a non-null
///   cell that does not fit the column's inferred dtype.
/// - Whatever `DataFrame::new` propagates (duplicate-header is
///   pre-empted upstream; length-mismatch cannot fire because every
///   column is built off `records.length()`).
pub fn parse_json_records_str(
  content : String,
  options : JsonReadOptions,
) -> Result[@frame.DataFrame, @types.DataError] {
  // Mirror `parse_csv_str`'s empty-input short-circuit so callers can
  // stream JSON without special-casing the "no payload" case.
  if content.is_empty() {
    return @frame.DataFrame::new([])
  }
  let json = match parse_json_payload(content) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let records = match json {
    Array(arr) => arr
    _ =>
      return Err(
        @types.DataError::ParseError(
          "expected a JSON array of objects at the top level",
        ),
      )
  }
  if records.is_empty() {
    return @frame.DataFrame::new([])
  }
  // First pass: validate that every element is an object, pull the
  // inner `Map` out for downstream passes (so inference / build don't
  // have to re-match), and collect headers in first-seen order across
  // *all* records. Walking every record means a sparse-on-the-left
  // set still produces every column the data contains.
  let objs : Array[Map[String, Json]] = Array::new(capacity=records.length())
  let headers : Array[String] = []
  let header_set : Map[String, Unit] = {}
  for rec in records {
    match rec {
      Object(obj) => {
        for k, _ in obj {
          if !header_set.contains(k) {
            header_set[k] = ()
            headers.push(k)
          }
        }
        objs.push(obj)
      }
      _ =>
        return Err(
          @types.DataError::ParseError(
            "expected each record to be a JSON object",
          ),
        )
    }
  }
  let ncols = headers.length()
  if ncols == 0 {
    // `[{}, {}, ...]` degenerates to N rows of zero columns, which
    // `DataFrame::new` cannot model. Collapse to an empty 0×0 frame
    // — the same shape the empty-input branch produces.
    return @frame.DataFrame::new([])
  }
  let series : Array[@frame.Series] = []
  for name in headers {
    let dt = infer_json_column_dtype(objs, name, options.infer_schema_rows)
    match build_json_column(name, dt, objs) {
      Err(e) => return Err(e)
      Ok(s) => series.push(s)
    }
  }
  @frame.DataFrame::new(series)
}

///|
/// Read a JSON records file using the default options.
pub fn read_json(path : String) -> Result[@frame.DataFrame, @types.DataError] {
  read_json_with_options(path, JsonReadOptions::default())
}

///|
/// Read a JSON records file with custom options. Filesystem errors
/// surface as `Err(IoError(message))`.
pub fn read_json_with_options(
  path : String,
  options : JsonReadOptions,
) -> Result[@frame.DataFrame, @types.DataError] {
  try @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => Err(@types.DataError::IoError(msg))
  } noraise {
    content => parse_json_records_str(content, options)
  }
}

///|
/// Render a `DataFrame` as a JSON records string `[ {...}, ... ]`.
///
/// Per cell:
/// - `Null` → JSON `null`
/// - `Int`  → JSON number (no fractional part)
/// - `Float`→ JSON number (NaN / ±Infinity rendered per `@json`'s
///   convention as the strings `"NaN"`, `"Infinity"`, `"-Infinity"`,
///   matching the builtin `ToJson for Double` impl)
/// - `Bool` → JSON `true` / `false`
/// - `String` → JSON string (escaping `"`, `\`, control chars via the
///   builtin stringifier — we deliberately do **not** roll our own
///   escape so any future Unicode spec tweaks land transparently)
///
/// Keys appear in the column declaration order, preserved by the
/// builtin `Map` (linked-hash-map) used for each record object.
pub fn format_json_records(df : @frame.DataFrame) -> String {
  let names = df.columns()
  let nrows = df.nrows()
  // Materialise each column's cells once (column-major) so a record is
  // assembled by plain `cols[c][r]` reads rather than per-cell `get`.
  let cols = df.column_series().map(s => s.to_scalars())
  let arr : Array[Json] = Array::new(capacity=nrows)
  for r in 0..<nrows {
    let obj : Map[String, Json] = {}
    for c, name in names {
      obj[name] = scalar_to_json(cols[c][r])
    }
    arr.push(Json::object(obj))
  }
  Json::array(arr).stringify()
}

///|
/// Write a `DataFrame` to a JSON records file. Filesystem errors
/// surface as `Err(IoError(message))`.
pub fn write_json_records(
  path : String,
  df : @frame.DataFrame,
) -> Result[Unit, @types.DataError] {
  let content = format_json_records(df)
  try @fs.write_string_to_file(path, content) catch {
    @fs.IOError(msg) => Err(@types.DataError::IoError(msg))
  } noraise {
    _ => Ok(())
  }
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// Wrap `@json.parse`'s raising convention behind a `Result` so the
/// parser's main pipeline stays in straight-line `match` form. The
/// concrete `ParseError` is rendered through its `Show` impl so the
/// caller sees the same diagnostic the standard library would.
fn parse_json_payload(content : String) -> Result[Json, @types.DataError] {
  try @json.parse(content.view()) catch {
    err => Err(@types.DataError::ParseError("invalid JSON: " + err.to_string()))
  } noraise {
    v => Ok(v)
  }
}

///|
/// Map a `@types.Scalar` into the corresponding `Json` value. The
/// promotion is straight-line: `Int` and `Float` both land on JSON
/// numbers (`Int64` widened to `Double`; `Float` is already `Double`);
/// `Bool` lands on the `true` / `false` variants; `String` passes
/// through unchanged and is escaped by the stringifier; `Null` lands
/// on JSON `null`.
fn scalar_to_json(s : @types.Scalar) -> Json {
  match s {
    @types.Scalar::Null => Json::null()
    @types.Scalar::Int(v) => Json::number(v.to_double())
    @types.Scalar::Float(v) => Json::number(v)
    @types.Scalar::Bool(v) => Json::boolean(v)
    @types.Scalar::String(v) => Json::string(v)
  }
}

///|
/// Internal enumeration of the four dtypes JSON inference can pick.
/// Kept separate from `@types.DataType` for the same reason the CSV
/// reader keeps its own `InferredDtype`: inference never produces
/// `Null`, and propagating that fact through the type system is
/// cheaper than guarding every call site.
priv enum InferredJsonDtype {
  JsonInt
  JsonFloat
  JsonBool
  JsonString
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
fn infer_json_column_dtype(
  objs : Array[Map[String, Json]],
  name : String,
  limit : Int,
) -> InferredJsonDtype {
  let n = objs.length()
  let scan = if limit > n { n } else { limit }
  let mut all_int = true
  let mut all_float = true
  let mut all_bool = true
  let mut all_string = true
  let mut saw_any = false
  for i in 0..<scan {
    let value = lookup_field(objs[i], name)
    if value is Null {
      continue
    }
    saw_any = true
    if all_int && json_value_as_int(value) is None {
      all_int = false
    }
    if all_float && json_value_as_float(value) is None {
      all_float = false
    }
    if all_bool && json_value_as_bool(value) is None {
      all_bool = false
    }
    if all_string && json_value_as_string(value) is None {
      all_string = false
    }
    if !all_int && !all_float && !all_bool && !all_string {
      break
    }
  }
  if !saw_any {
    return JsonString
  }
  if all_int {
    JsonInt
  } else if all_float {
    JsonFloat
  } else if all_bool {
    JsonBool
  } else if all_string {
    JsonString
  } else {
    // Mixed dtype within a single column (e.g. `1` then `"hi"`):
    // fall back to String. `build_json_column` will then re-render
    // numeric cells via their string form, matching the CSV
    // reader's behaviour when its inference window is mixed.
    JsonString
  }
}

///|
/// Try to read `j` as an `Int64`. Accepts `Number` values that are
/// exactly integer-valued (`n == n.trunc()`) and within `Int64` range —
/// guarded by the largest `Double` strictly below `2^63`
/// (`9223372036854774784`), since `Int64::MAX` isn't exactly
/// representable as a `Double`. The check is value-based rather than
/// repr-based because `@json.parse` only populates `Number.repr` for
/// overflow corner cases (Infinity / -Infinity), so anything written
/// like `1.0e2` lands as `Number(100.0, None)` — which we treat as
/// `Int(100)`, matching pandas / polars behaviour on equivalent CSV.
///
/// Booleans, strings, and null are intentionally rejected — JSON has
/// strong types and silently promoting `true → 1` would surprise
/// callers used to pandas / polars semantics.
fn json_value_as_int(j : Json) -> Int64? {
  match j {
    Number(n, ..) => {
      if n != n.trunc() {
        return None
      }
      if n < -9223372036854775808.0 || n > 9223372036854774784.0 {
        return None
      }
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
    Number(n, ..) => Some(n)
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
/// Try to read `j` as a `String`. Only the JSON `String` variant is
/// accepted; numbers / booleans / null are rejected so the inference
/// pass can distinguish "pure string column" from "mixed column that
/// should fall back to string".
fn json_value_as_string(j : Json) -> String? {
  match j {
    String(s) => Some(s)
    _ => None
  }
}

///|
/// Render any JSON value as a flat string for the `String`-fallback
/// column builder. Numbers render via `Double::to_string`, booleans
/// render `true` / `false`, strings pass through verbatim, and any
/// composite (`Array` / `Object`) falls through to `@json.stringify`.
/// `Null` is filtered out upstream — the build loop calls
/// `values.push(None)` for null cells without invoking this helper —
/// so the catch-all only fires on composites in practice.
fn json_value_to_string_fallback(j : Json) -> String {
  match j {
    True => "true"
    False => "false"
    Number(n, ..) => n.to_string()
    String(s) => s
    _ => (j : Json).stringify()
  }
}

///|
/// Materialise one column from the record array using the dtype
/// chosen by inference. Mirrors `build_column` in `csv.mbt`: each
/// branch walks the records in row order and converts the cell into
/// the typed array slot, producing a `ParseError` if a value past the
/// inference window fails to match the locked-in dtype.
fn build_json_column(
  name : String,
  dtype : InferredJsonDtype,
  objs : Array[Map[String, Json]],
) -> Result[@frame.Series, @types.DataError] {
  let n = objs.length()
  match dtype {
    JsonInt => {
      let values : Array[Int64?] = Array::new(capacity=n)
      for i in 0..<n {
        let cell = lookup_field(objs[i], name)
        if cell is Null {
          values.push(None)
          continue
        }
        match json_value_as_int(cell) {
          Some(x) => values.push(Some(x))
          None =>
            return Err(
              @types.DataError::ParseError(
                "column \"" +
                name +
                "\" record " +
                i.to_string() +
                ": JSON value is not an Int (\"" +
                json_value_to_string_fallback(cell) +
                "\")",
              ),
            )
        }
      }
      Ok(@frame.Series::from_int_options(name, values))
    }
    JsonFloat => {
      let values : Array[Double?] = Array::new(capacity=n)
      for i in 0..<n {
        let cell = lookup_field(objs[i], name)
        if cell is Null {
          values.push(None)
          continue
        }
        match json_value_as_float(cell) {
          Some(x) => values.push(Some(x))
          None =>
            return Err(
              @types.DataError::ParseError(
                "column \"" +
                name +
                "\" record " +
                i.to_string() +
                ": JSON value is not a number (\"" +
                json_value_to_string_fallback(cell) +
                "\")",
              ),
            )
        }
      }
      Ok(@frame.Series::from_float_options(name, values))
    }
    JsonBool => {
      let values : Array[Bool?] = Array::new(capacity=n)
      for i in 0..<n {
        let cell = lookup_field(objs[i], name)
        if cell is Null {
          values.push(None)
          continue
        }
        match json_value_as_bool(cell) {
          Some(x) => values.push(Some(x))
          None =>
            return Err(
              @types.DataError::ParseError(
                "column \"" +
                name +
                "\" record " +
                i.to_string() +
                ": JSON value is not a Bool (\"" +
                json_value_to_string_fallback(cell) +
                "\")",
              ),
            )
        }
      }
      Ok(@frame.Series::from_bool_options(name, values))
    }
    JsonString => {
      let values : Array[String?] = Array::new(capacity=n)
      for i in 0..<n {
        let cell = lookup_field(objs[i], name)
        if cell is Null {
          values.push(None)
        } else {
          values.push(Some(json_value_to_string_fallback(cell)))
        }
      }
      Ok(@frame.Series::from_string_options(name, values))
    }
  }
}
