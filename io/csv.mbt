// CSV serialisation for `DataFrame`. The reader sits on top of NyaCSV
// for tokenisation and adds three pieces v0.1 needs: header / no-header
// switching, per-column type inference (Int → Float → Bool → String),
// and a configurable null-string mapping. The writer mirrors the
// reader, rendering each cell via `Scalar::to_string` and quoting only
// when a cell would otherwise be ambiguous (contains the delimiter, a
// double quote, or a line break).

///|
/// Options that control how a CSV input is parsed into a `DataFrame`.
///
/// - `has_header` — when `true`, the first row supplies column names.
///   When `false`, every row is treated as data and column names are
///   synthesised as `"column1"`, `"column2"`, … in declaration order.
/// - `delimiter` — field separator passed through to NyaCSV.
/// - `infer_schema_rows` — number of leading rows scanned when guessing
///   each column's dtype. Cells past the limit are still parsed under
///   the chosen dtype, so a misdetected column surfaces as
///   `ParseError` rather than a silent string fallback.
/// - `null_values` — raw strings that should be treated as null cells
///   (both for type inference, which skips them, and for the final
///   typed column, where they become `None`). The default `[""]`
///   matches the empty string only, which is how an absent CSV cell is
///   typically represented.
pub(all) struct CsvReadOptions {
  has_header : Bool
  delimiter : Char
  infer_schema_rows : Int
  null_values : Array[String]
}

///|
/// Default read options: header on, comma delimiter, scan the first
/// 100 rows for inference, and treat the empty string as null.
pub fn CsvReadOptions::default() -> CsvReadOptions {
  {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: [""],
  }
}

///|
/// Options that control how a `DataFrame` is rendered as CSV text.
///
/// - `header` — when `true`, the first emitted row is the column
///   names; when `false`, only data rows are written.
/// - `delimiter` — field separator written between cells.
/// - `null_value` — the literal string written in place of a null
///   cell. The default empty string round-trips with the reader's
///   default `null_values`.
pub(all) struct CsvWriteOptions {
  header : Bool
  delimiter : Char
  null_value : String
}

///|
/// Default write options: header on, comma delimiter, null cells
/// emitted as the empty string.
pub fn CsvWriteOptions::default() -> CsvWriteOptions {
  { header: true, delimiter: ',', null_value: "" }
}

///|
/// Parse a CSV-encoded string into a `DataFrame`. The pipeline is:
///   1. NyaCSV tokenises the text into headers + rows. NyaCSV always
///      treats the first row as a header, so the `has_header = false`
///      case re-folds that row into the data section and synthesises
///      `column1`, `column2`, … names.
///   2. Per-column type inference walks the first `infer_schema_rows`
///      non-null cells in order `Int → Float → Bool → String`. The
///      first option that accepts every probed cell wins; a column
///      with no non-null probes lands on `String` (no information to
///      disambiguate).
///   3. Null mapping replaces any raw cell whose verbatim string sits
///      in `null_values` with `None`. The mapping runs after
///      tokenisation, so quoted empty cells (`""`) and bare empty
///      cells are both honoured.
///   4. Each column is assembled into a typed `Series` and the result
///      is wrapped through `DataFrame::new`.
///
/// Errors:
/// - `Err(DuplicateColumn(name))` — two headers share a name.
/// - `Err(ParseError(...))` — a non-null cell does not parse under
///   the inferred dtype for its column (typically because a sample
///   row outside the inference window is malformed for the inferred
///   type).
/// - Whatever `DataFrame::new` propagates — for v0.1 this is limited
///   to `DuplicateColumn` / `LengthMismatch`, neither of which can
///   actually fire here (uniqueness is checked above; every column
///   is built off the same `rows.length()`).
pub fn parse_csv_str(
  content : String,
  options : CsvReadOptions,
) -> Result[@frame.DataFrame, @types.DataError] {
  // Short-circuit empty input. NyaCSV would otherwise produce a CSV
  // with no headers and no rows, which would collapse to an empty
  // 0×0 frame — handled the same way here, just without the parse.
  if content.is_empty() {
    return @frame.DataFrame::new([])
  }
  let csv_options : @nyacsv.CSVOptions = {
    delimiter: options.delimiter,
    allow_newlines_in_quotes: true,
    quote_char: '"',
    skip_empty_lines: true,
    trim_spaces: false,
  }
  let csv = @nyacsv.CSV::parse_string(content, options=csv_options)
  // Settle the headers / rows split based on `has_header`. NyaCSV
  // always lifts the first record into `header()`, so the
  // `has_header = false` branch has to push it back into the data
  // section and synthesise names.
  let headers : Array[String] = []
  let rows : Array[Array[String]] = []
  if options.has_header {
    for h in csv.header() {
      headers.push(h)
    }
    for r in csv.data() {
      rows.push(r)
    }
  } else {
    let first = csv.header()
    if !first.is_empty() {
      rows.push(first)
    }
    for r in csv.data() {
      rows.push(r)
    }
    let ncols_local = if rows.is_empty() { 0 } else { rows[0].length() }
    for i in 0..<ncols_local {
      headers.push("column" + (i + 1).to_string())
    }
  }
  let ncols = headers.length()
  if ncols == 0 {
    return @frame.DataFrame::new([])
  }
  // Reject duplicate headers up front. `DataFrame::new` would catch
  // this via `Schema::new`, but we surface it before any per-cell
  // work so a malformed header doesn't waste an inference pass.
  let seen : Map[String, Unit] = {}
  for name in headers {
    if seen.contains(name) {
      return Err(@types.DataError::DuplicateColumn(name))
    }
    seen[name] = ()
  }
  // Infer one dtype per column, then build the column.
  let series : Array[@frame.Series] = []
  for col in 0..<ncols {
    let name = headers[col]
    let dt = infer_column_dtype(
      rows,
      col,
      options.infer_schema_rows,
      options.null_values,
    )
    match build_column(name, dt, rows, col, options.null_values) {
      Err(e) => return Err(e)
      Ok(s) => series.push(s)
    }
  }
  @frame.DataFrame::new(series)
}

///|
/// Internal enumeration of the four dtypes CSV inference can pick. We
/// keep this separate from `@types.DataType` so the builder match is
/// exhaustive without an unreachable `Null` arm — inference never
/// produces `Null`, and propagating that fact through the type system
/// is cheaper than guarding every call site.
priv enum InferredDtype {
  InferredInt
  InferredFloat
  InferredBool
  InferredString
}

///|
/// Read a CSV file using the default options.
pub fn read_csv(path : String) -> Result[@frame.DataFrame, @types.DataError] {
  read_csv_with_options(path, CsvReadOptions::default())
}

///|
/// Read a CSV file with custom options. `IOError` from the file system
/// surfaces as `Err(IoError(message))`.
pub fn read_csv_with_options(
  path : String,
  options : CsvReadOptions,
) -> Result[@frame.DataFrame, @types.DataError] {
  try @fs.read_file_to_string(path) catch {
    @fs.IOError(msg) => Err(@types.DataError::IoError(msg))
  } noraise {
    content => parse_csv_str(content, options)
  }
}

///|
/// Render a `DataFrame` as a CSV string.
///
/// - Header (when `options.header == true`): column names joined by
///   `options.delimiter`, each quoted only when it would otherwise be
///   ambiguous.
/// - Each row: cells joined by `options.delimiter`, terminated by `\n`
///   (LF). Null cells are written as `options.null_value`; other cells
///   render via `Scalar::to_string`.
/// - Quoting: a cell containing the delimiter, a double quote, `\r`,
///   or `\n` is wrapped in double quotes; interior double quotes are
///   doubled (`"` → `""`). Cells that need no quoting are written
///   verbatim so the output matches the simple "no quotes" CSV idiom
///   whenever possible.
pub fn format_csv_str(
  df : @frame.DataFrame,
  options : CsvWriteOptions,
) -> String {
  let buf = StringBuilder::new()
  let names = df.columns()
  if options.header {
    for i, name in names {
      if i > 0 {
        buf.write_char(options.delimiter)
      }
      write_quoted(buf, name, options.delimiter)
    }
    buf.write_char('\n')
  }
  let nrows = df.nrows()
  for r in 0..<nrows {
    for c, name in names {
      if c > 0 {
        buf.write_char(options.delimiter)
      }
      // `get(r, name)` cannot fail here: every column came from
      // `df.columns()` (so it exists) and `r` ranges over `[0, nrows)`.
      let scalar = df.get(r, name).unwrap()
      let rendered = if scalar.is_null() {
        options.null_value
      } else {
        scalar.to_string()
      }
      write_quoted(buf, rendered, options.delimiter)
    }
    buf.write_char('\n')
  }
  buf.to_string()
}

///|
/// Write a `DataFrame` to a CSV file using the default options.
pub fn write_csv(
  path : String,
  df : @frame.DataFrame,
) -> Result[Unit, @types.DataError] {
  write_csv_with_options(path, df, CsvWriteOptions::default())
}

///|
/// Write a `DataFrame` to a CSV file with custom options. `IOError`
/// from the file system surfaces as `Err(IoError(message))`.
pub fn write_csv_with_options(
  path : String,
  df : @frame.DataFrame,
  options : CsvWriteOptions,
) -> Result[Unit, @types.DataError] {
  let content = format_csv_str(df, options)
  try @fs.write_string_to_file(path, content) catch {
    @fs.IOError(msg) => Err(@types.DataError::IoError(msg))
  } noraise {
    _ => Ok(())
  }
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// Read the cell at `(row_idx, col)` from a NyaCSV-produced data
/// matrix. Short rows (fewer cells than the header declares) fall
/// through to the empty string, which the null-mapping then turns
/// into `None` when the empty string is in `null_values`.
fn cell_value(rows : Array[Array[String]], row_idx : Int, col : Int) -> String {
  let row = rows[row_idx]
  if col < row.length() {
    row[col]
  } else {
    ""
  }
}

///|
/// Whether a raw cell value should be treated as null.
fn is_null_value(value : String, null_values : Array[String]) -> Bool {
  null_values.contains(value)
}

///|
/// Probe the first `limit` non-null cells of `col` to pick a dtype.
/// `Int → Float → Bool → String` in order; whichever option accepts
/// every probed cell wins. A column whose probe window is entirely
/// null defaults to `String`.
fn infer_column_dtype(
  rows : Array[Array[String]],
  col : Int,
  limit : Int,
  null_values : Array[String],
) -> InferredDtype {
  let n = rows.length()
  let scan = if limit > n { n } else { limit }
  let mut all_int = true
  let mut all_float = true
  let mut all_bool = true
  let mut saw_any = false
  for i in 0..<scan {
    let v = cell_value(rows, i, col)
    if is_null_value(v, null_values) {
      continue
    }
    saw_any = true
    if all_int && parse_int_opt(v) is None {
      all_int = false
    }
    if all_float && parse_float_opt(v) is None {
      all_float = false
    }
    if all_bool && parse_bool_opt(v) is None {
      all_bool = false
    }
    if !all_int && !all_float && !all_bool {
      break
    }
  }
  if !saw_any {
    return InferredString
  }
  if all_int {
    InferredInt
  } else if all_float {
    InferredFloat
  } else if all_bool {
    InferredBool
  } else {
    InferredString
  }
}

///|
/// `Some(value)` when `s` is a plain base-10 integer literal that fits in
/// a 64-bit `Int64`; `None` otherwise.
///
/// We pre-screen with `@types.is_decimal_int_literal` because
/// `@string.parse_int64` defaults to `base=0`, which would otherwise accept
/// `0x` / `0o` / `0b` prefixes (`0xFF` → 255) and underscore grouping
/// (`1_000` → 1000). Those forms are kept as strings by pandas / polars,
/// so accepting them during inference would silently retype columns of
/// hex codes, IDs, or formatted numbers. Restricting to decimal keeps
/// inference predictable. The same predicate gates the `@column`
/// String→`Int` cast, so inference and an explicit cast agree.
fn parse_int_opt(s : String) -> Int64? {
  if !@types.is_decimal_int_literal(s) {
    return None
  }
  try @string.parse_int64(s.view()) catch {
    _ => None
  } noraise {
    n => Some(n)
  }
}

///|
/// `Some(value)` when `s` parses as a `Double` via `@string.parse_double`;
/// `None` on parse failure.
///
/// Strings containing `_` are rejected up front: `@string.parse_double`
/// accepts underscore grouping (`1_000` → `1000.0`), but — like the
/// `0x` / `0o` / `0b` forms screened out of `parse_int_opt` — that is not
/// how CSV numbers are written, and pandas / polars keep such cells as
/// strings. The `inf` / `nan` literals that `parse_double` recognises
/// are still accepted and become `Double` ±Infinity / NaN values.
fn parse_float_opt(s : String) -> Double? {
  if s.iter().any(c => c == '_') {
    return None
  }
  try @string.parse_double(s.view()) catch {
    _ => None
  } noraise {
    x => Some(x)
  }
}

///|
/// `Some(true)` / `Some(false)` for the literal strings `true` /
/// `false` in any ASCII casing; `None` otherwise. Numeric `0` / `1`
/// are intentionally **not** accepted — those round-trip as `Int`,
/// which the inference order picks up first.
fn parse_bool_opt(s : String) -> Bool? {
  if s.equal_ignore_ascii_case("true") {
    Some(true)
  } else if s.equal_ignore_ascii_case("false") {
    Some(false)
  } else {
    None
  }
}

///|
/// Materialise one column from the raw row matrix using the dtype
/// chosen by inference. The same null-mapping rules used by inference
/// run here; non-null cells that fail to parse become
/// `Err(ParseError(...))` since the type was already locked in by the
/// inference pass.
fn build_column(
  name : String,
  dtype : InferredDtype,
  rows : Array[Array[String]],
  col : Int,
  null_values : Array[String],
) -> Result[@frame.Series, @types.DataError] {
  let n = rows.length()
  match dtype {
    InferredInt => {
      let values : Array[Int64?] = Array::new(capacity=n)
      for i in 0..<n {
        let v = cell_value(rows, i, col)
        if is_null_value(v, null_values) {
          values.push(None)
        } else {
          match parse_int_opt(v) {
            Some(x) => values.push(Some(x))
            None =>
              return Err(
                @types.DataError::ParseError(
                  "column \"" +
                  name +
                  "\" row " +
                  i.to_string() +
                  ": cannot parse \"" +
                  v +
                  "\" as Int",
                ),
              )
          }
        }
      }
      Ok(@frame.Series::from_int_options(name, values))
    }
    InferredFloat => {
      let values : Array[Double?] = Array::new(capacity=n)
      for i in 0..<n {
        let v = cell_value(rows, i, col)
        if is_null_value(v, null_values) {
          values.push(None)
        } else {
          match parse_float_opt(v) {
            Some(x) => values.push(Some(x))
            None =>
              return Err(
                @types.DataError::ParseError(
                  "column \"" +
                  name +
                  "\" row " +
                  i.to_string() +
                  ": cannot parse \"" +
                  v +
                  "\" as Float",
                ),
              )
          }
        }
      }
      Ok(@frame.Series::from_float_options(name, values))
    }
    InferredBool => {
      let values : Array[Bool?] = Array::new(capacity=n)
      for i in 0..<n {
        let v = cell_value(rows, i, col)
        if is_null_value(v, null_values) {
          values.push(None)
        } else {
          match parse_bool_opt(v) {
            Some(x) => values.push(Some(x))
            None =>
              return Err(
                @types.DataError::ParseError(
                  "column \"" +
                  name +
                  "\" row " +
                  i.to_string() +
                  ": cannot parse \"" +
                  v +
                  "\" as Bool",
                ),
              )
          }
        }
      }
      Ok(@frame.Series::from_bool_options(name, values))
    }
    InferredString => {
      let values : Array[String?] = Array::new(capacity=n)
      for i in 0..<n {
        let v = cell_value(rows, i, col)
        if is_null_value(v, null_values) {
          values.push(None)
        } else {
          values.push(Some(v))
        }
      }
      Ok(@frame.Series::from_string_options(name, values))
    }
  }
}

///|
/// Append `cell` to `buf`, quoting only when needed. A cell needs
/// quoting iff it contains the delimiter, a double quote, `\r`, or
/// `\n`. Interior double quotes are doubled per RFC 4180.
fn write_quoted(buf : StringBuilder, cell : String, delimiter : Char) -> Unit {
  let needs_quote = cell
    .iter()
    .any(ch => ch == delimiter || ch == '"' || ch == '\n' || ch == '\r')
  if !needs_quote {
    buf.write_string(cell)
    return
  }
  buf.write_char('"')
  for ch in cell.iter() {
    if ch == '"' {
      buf.write_char('"')
      buf.write_char('"')
    } else {
      buf.write_char(ch)
    }
  }
  buf.write_char('"')
}
