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
///   synthesised as `"column1"`, `"column2"`, … in declaration order; the
///   **first data row fixes the column count**, so a later wider row's
///   trailing cells are dropped under the lenient default (set
///   `strict_column_count = true` to reject a ragged row instead).
/// - `delimiter` — field separator passed through to NyaCSV.
/// - `infer_schema_rows` — number of leading rows scanned when guessing
///   each column's dtype. `0` (or any value `<= 0`) lifts the cap and
///   scans every row (Polars' `infer_schema_length=None`), trading a
///   slower inference pass for never mis-guessing a column from a prefix.
///   Cells past a finite window are still parsed under the chosen dtype;
///   one that doesn't fit is handled per `on_parse_error`.
/// - `null_values` — raw strings that should be treated as null cells
///   (both for type inference, which skips them, and for the final
///   typed column, where they become `None`). The default `[""]`
///   matches the empty string only, which is how an absent CSV cell is
///   typically represented.
/// - `strict_column_count` — when `true`, every data row must have
///   exactly as many cells as the header declares; a ragged row (too
///   few or too many cells) `raise ParseError` instead of being
///   silently null-padded (short row) or truncated (long row). Defaults
///   to `false`, preserving the lenient behaviour that tolerates ragged
///   rows (a permissive CSV idiom, and what the v0.1 reader did).
/// - `on_parse_error` — what to do when a non-null cell past the
///   inference window fails to parse under its column's locked-in dtype.
///   `Raise` (default) fails the whole read with `ParseError`; `Null`
///   downgrades the offending cell to a null cell and keeps the column's
///   inferred dtype (Polars' `ignore_errors=True`). See `OnParseError`.
/// - `allow_nonfinite_floats` — when `true` (default), the float probe
///   accepts the `nan` / `inf` / `infinity` literals `@string.parse_double`
///   recognises, so a column of those tokens infers as `Float`. When
///   `false`, the probe rejects them, so such a column falls back to
///   `String` instead of being silently retyped to `Float` (a
///   non-finite token past the window is then a parse failure handled per
///   `on_parse_error`).
pub(all) struct CsvReadOptions {
  has_header : Bool
  delimiter : Char
  infer_schema_rows : Int
  null_values : Array[String]
  strict_column_count : Bool
  on_parse_error : OnParseError
  allow_nonfinite_floats : Bool
}

///|
/// Default read options: header on, comma delimiter, scan the first
/// 100 rows for inference, treat the empty string as null, tolerate
/// ragged rows (`strict_column_count = false`), fail the read on a cell
/// that doesn't fit its inferred dtype (`on_parse_error = Raise`), and
/// accept non-finite float literals (`allow_nonfinite_floats = true`).
pub fn CsvReadOptions::default() -> CsvReadOptions {
  {
    has_header: true,
    delimiter: ',',
    infer_schema_rows: 100,
    null_values: [""],
    strict_column_count: false,
    on_parse_error: Raise,
    allow_nonfinite_floats: true,
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
///      rows in order `Int → Float → Bool → String` (a null cell within
///      them is skipped but still counts toward the window). The
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
/// Raises:
/// - `DuplicateColumn(name)` — two headers share a name.
/// - `ParseError(...)` — a non-null cell does not parse under
///   the inferred dtype for its column (typically because a sample
///   row outside the inference window is malformed for the inferred
///   type), unless `options.on_parse_error` is `Null`, which downgrades
///   that cell to a null instead of failing the read; or — when
///   `options.strict_column_count` is `true` — a data row's cell count
///   differs from the header's (reported as `row N: expected C columns,
///   got G`, 1-based over the data rows).
/// - Whatever `DataFrame::new` propagates — for v0.1 this is limited
///   to `DuplicateColumn` / `LengthMismatch`, neither of which can
///   actually fire here (uniqueness is checked above; every column
///   is built off the same `rows.length()`).
///
/// Limitation: tokenisation is delegated to NyaCSV, which treats an
/// unterminated quoted field at end-of-input as a complete field rather
/// than a malformed one — `1,"unclosed` reads as a row whose last cell is
/// `unclosed`, not a `ParseError`. No quote-balance pre-scan is performed.
pub fn parse_csv_str(
  content : String,
  options : CsvReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  parse_csv_str_projected(content, options, None)
}

///|
/// Shared core behind `parse_csv_str` and `read_csv_projected`: the full
/// parse pipeline documented on `parse_csv_str`, with one extra knob —
/// `projection`.
///
/// - `None` — build every column (the eager `read_csv` / `parse_csv_str`
///   behaviour).
/// - `Some(names)` — build only the columns whose header name appears in
///   `names`, in the file's own header order, leaving the rest uninferred,
///   unparsed, and unmaterialised. This is the projection-pushdown path the
///   lazy `scan_csv` source uses: the optimizer narrows the read to exactly
///   the columns a pipeline consumes.
///
/// Every whole-input check runs *before* the projection filter and so is
/// unaffected by it — the empty-input short-circuit, the duplicate-header
/// rejection, and the optional ragged-row guard all see the full header / row
/// matrix, so a projected read fails on a malformed header or a ragged row
/// exactly as a full read would. The single behavioural difference is the
/// deliberate point of the feature: a non-null cell that fails to parse under
/// its column's inferred dtype only surfaces (`on_parse_error = Raise`) for a
/// column that is actually built, so a parse error confined to a *dropped*
/// column is not raised — that column is never parsed.
fn parse_csv_str_projected(
  content : String,
  options : CsvReadOptions,
  projection : Array[String]?,
) -> @frame.DataFrame raise @types.DataError {
  // Strip a leading UTF-8 BOM (U+FEFF). Excel and many Windows tools prepend
  // one; left in place it leaks into the first column's name, so a later
  // `get_column("id")` on an `id,…` header misses. Matches Polars / pandas
  // (`utf-8-sig`). Done first, so a BOM-only file still reads as empty.
  let content = if content.view().get_char(0) == Some('\u{FEFF}') {
    content.view().view(start_offset=1).to_owned()
  } else {
    content
  }
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
      headers.push("column\{i + 1}")
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
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
  }
  // Optional ragged-row guard. When `strict_column_count` is on, a data
  // row whose cell count differs from the header's `raise ParseError`
  // rather than being silently null-padded (short row) or truncated
  // (long row) by the lenient `cell_value` path below. Checked after the
  // header validates, so a malformed header surfaces first; the 1-based
  // index is over the data rows (the header is not counted).
  if options.strict_column_count {
    for i, row in rows {
      if row.length() != ncols {
        raise @types.DataError::ParseError(
          "row \{i + 1}: expected \{ncols} columns, got \{row.length()}",
        )
      }
    }
  }
  // Infer one dtype per column, then build the column — skipping any the
  // projection drops. `build_column` raises `ParseError` for a cell that
  // doesn't fit the inferred dtype. The surviving columns keep the file's own
  // header order (a filtered projection, never a reorder), so a projected read
  // is column-for-column a sub-frame of the full read.
  let series : Array[@series.Series] = []
  for col in 0..<ncols {
    let name = headers[col]
    let included = match projection {
      None => true
      Some(names) => names.contains(name)
    }
    if included {
      let dt = infer_column_dtype(
        rows,
        col,
        options.infer_schema_rows,
        options.null_values,
        options.allow_nonfinite_floats,
      )
      series.push(
        build_column(
          name,
          dt,
          rows,
          col,
          options.null_values,
          options.on_parse_error,
          options.allow_nonfinite_floats,
        ),
      )
    }
  }
  @frame.DataFrame::new(series)
}

///|
/// Read a CSV file using the default options.
pub fn read_csv(path : String) -> @frame.DataFrame raise @types.DataError {
  read_csv_with_options(path, CsvReadOptions::default())
}

///|
/// Read a CSV file with custom options. `IOError` from the file system
/// surfaces as `raise IoError(message)`.
pub fn read_csv_with_options(
  path : String,
  options : CsvReadOptions,
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_csv_str(content, options)
}

///|
/// Read a CSV file, building only the columns named in `projection` — the
/// file-backed entry behind the lazy `scan_csv` source's projection
/// pushdown. Identical to `read_csv_with_options` except that a column whose
/// header name is not in `projection` is never inferred, parsed, or
/// materialised (see `parse_csv_str_projected` for the precise contract,
/// including the one behavioural consequence: a parse error confined to a
/// dropped column does not surface). `IOError` from the file system surfaces
/// as `raise IoError(message)`.
pub fn read_csv_projected(
  path : String,
  options : CsvReadOptions,
  projection : Array[String],
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_csv_str_projected(content, options, Some(projection))
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
///   whenever possible. The lone exception: in a single-column frame an
///   empty cell (or an empty column name) is written as `""` rather than a
///   bare blank, so the row is not a blank line the reader would skip.
/// - Round-trip caveat: cells render via `Scalar::to_string`, so a `Float`
///   whose value is a whole number is written without a fractional part
///   (`2.0` → `2`) and is re-inferred as `Int` on read — the same dtype
///   narrowing the JSON writer documents. A `String` cell with significant
///   leading / trailing whitespace is written bare (only the delimiter, a
///   quote, `\r`, or `\n` force quoting), so this reader round-trips it
///   (`trim_spaces` off), but an RFC-4180 consumer that trims surrounding
///   whitespace may drop it. Quote / escape handling is otherwise round-trip
///   safe.
pub fn format_csv(df : @frame.DataFrame, options : CsvWriteOptions) -> String {
  let buf = StringBuilder::new()
  let names = df.columns()
  // A single-column frame is the only shape whose rows can render as a bare
  // empty line (any wider row carries a delimiter), which the reader's
  // `skip_empty_lines` would discard — losing the row (or, for the header,
  // the column name). Force such empty cells / names to `""` so the line
  // stays non-empty; the reader maps the quoted-empty token back to null via
  // `null_values`, exactly as it does a bare empty cell in a wider row.
  let single_column = names.length() == 1
  if options.header {
    for i, name in names {
      if i > 0 {
        buf.write_char(options.delimiter)
      }
      write_quoted(
        buf,
        name,
        options.delimiter,
        force_empty_quote=single_column,
      )
    }
    buf.write_char('\n')
  }
  let nrows = df.nrows()
  // Materialise the whole frame once (column-major) through the shared
  // `to_scalar_matrix`; `cols[c][r]` is then a plain in-bounds read, so no
  // per-cell `get` `Result`.
  let cols = df.to_scalar_matrix()
  for r in 0..<nrows {
    for c in 0..<names.length() {
      if c > 0 {
        buf.write_char(options.delimiter)
      }
      let scalar = cols[c][r]
      let rendered = if scalar.is_null() {
        options.null_value
      } else {
        scalar.to_string()
      }
      write_quoted(
        buf,
        rendered,
        options.delimiter,
        force_empty_quote=single_column,
      )
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
) -> Unit raise @types.DataError {
  write_csv_with_options(path, df, CsvWriteOptions::default())
}

///|
/// Write a `DataFrame` to a CSV file with custom options. `IOError`
/// from the file system surfaces as `raise IoError(message)`.
pub fn write_csv_with_options(
  path : String,
  df : @frame.DataFrame,
  options : CsvWriteOptions,
) -> Unit raise @types.DataError {
  let content = format_csv(df, options)
  write_text(path, content)
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
/// Probe the first `limit` rows of `col` to pick a dtype (a null cell is
/// skipped but still counts toward the window). `Int → Float → Bool →
/// String` in order; whichever option accepts every probed cell wins. A
/// column whose probe window is entirely null defaults to `String`. Adapts
/// the CSV cell source (`String` cells from the row matrix) onto the shared
/// `infer_dtype` core.
fn infer_column_dtype(
  rows : Array[Array[String]],
  col : Int,
  limit : Int,
  null_values : Array[String],
  allow_nonfinite_floats : Bool,
) -> InferredDtype {
  infer_dtype(
    rows.length(),
    limit,
    i => cell_value(rows, i, col),
    v => is_null_value(v, null_values),
    v => parse_int_opt(v) is Some(_),
    v => parse_float_opt(v, allow_nonfinite_floats) is Some(_),
    v => parse_bool_opt(v) is Some(_),
  )
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
  @types.parse_decimal_int_opt(s)
}

///|
/// `Some(value)` when `s` parses as a `Double` via `@string.parse_double`;
/// `None` on parse failure.
///
/// Strings containing `_` are rejected up front: `@string.parse_double`
/// accepts underscore grouping (`1_000` → `1000.0`), but — like the
/// `0x` / `0o` / `0b` forms screened out of `parse_int_opt` — that is not
/// how CSV numbers are written, and pandas / polars keep such cells as
/// strings.
///
/// `allow_nonfinite` gates the `nan` / `inf` / `infinity` literals
/// `parse_double` recognises: when `true` they are accepted and become
/// `Double` NaN / ±Infinity (the historical default); when `false` they
/// are rejected (`None`), so a column of such tokens stays `String` rather
/// than being silently retyped to `Float`. The same predicate gates both
/// the inference probe and the typed-column build, so the two agree on
/// whether a non-finite literal counts as a `Float`.
fn parse_float_opt(s : String, allow_nonfinite : Bool) -> Double? {
  match @types.parse_plain_double_opt(s) {
    Some(x) =>
      if !allow_nonfinite && (x.is_nan() || x.is_inf()) {
        None
      } else {
        Some(x)
      }
    None => None
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
/// run here; a non-null cell that fails to parse (the type was already
/// locked in by the inference pass) is handled per `on_parse_error` —
/// `Raise` surfaces `ParseError`, `Null` downgrades it to a null cell.
/// `allow_nonfinite_floats` matches the inference probe so a `Float`
/// column accepts (or rejects) `nan` / `inf` consistently on both passes.
fn build_column(
  name : String,
  dtype : InferredDtype,
  rows : Array[Array[String]],
  col : Int,
  null_values : Array[String],
  on_parse_error : OnParseError,
  allow_nonfinite_floats : Bool,
) -> @series.Series raise @types.DataError {
  let n = rows.length()
  let cell = fn(i : Int) -> String { cell_value(rows, i, col) }
  let isnull = fn(v : String) -> Bool { is_null_value(v, null_values) }
  match dtype {
    InferInt =>
      build_typed_column(
        name,
        n,
        cell,
        isnull,
        parse_int_opt,
        (i, v) => {
          @types.DataError::ParseError(
            "column \"\{name}\" row \{i + 1}: cannot parse \"\{v}\" as Int",
          )
        },
        on_parse_error,
        @series.Series::from_int_options,
      )
    InferFloat =>
      build_typed_column(
        name,
        n,
        cell,
        isnull,
        v => parse_float_opt(v, allow_nonfinite_floats),
        (i, v) => {
          @types.DataError::ParseError(
            "column \"\{name}\" row \{i + 1}: cannot parse \"\{v}\" as Float",
          )
        },
        on_parse_error,
        @series.Series::from_float_options,
      )
    InferBool =>
      build_typed_column(
        name,
        n,
        cell,
        isnull,
        parse_bool_opt,
        (i, v) => {
          @types.DataError::ParseError(
            "column \"\{name}\" row \{i + 1}: cannot parse \"\{v}\" as Bool",
          )
        },
        on_parse_error,
        @series.Series::from_bool_options,
      )
    InferString => {
      let values : Array[String?] = Array::makei(n, i => {
        let v = cell(i)
        if isnull(v) {
          None
        } else {
          Some(v)
        }
      })
      @series.Series::from_string_options(name, values)
    }
  }
}

///|
/// Append `cell` to `buf`, quoting only when needed. A cell needs
/// quoting iff it contains the delimiter, a double quote, `\r`, or
/// `\n`. Interior double quotes are doubled per RFC 4180.
fn write_quoted(
  buf : StringBuilder,
  cell : String,
  delimiter : Char,
  force_empty_quote? : Bool = false,
) -> Unit {
  // An empty cell that would otherwise leave its line bare (a single-column
  // row) is written as `""` so the reader cannot mistake it for a skippable
  // blank line. The quoted-empty token maps back to null via `null_values`.
  if force_empty_quote && cell.is_empty() {
    buf.write_string("\"\"")
    return
  }
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
