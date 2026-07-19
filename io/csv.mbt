// CSV serialisation for `DataFrame`. The reader sits on top of NyaCSV
// for tokenisation and adds four pieces v0.1 needs: header / no-header
// switching, per-column type inference (Int → Float → Bool → String),
// a configurable null-string mapping, and opt-in strict quote validation.
// The writer mirrors the
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
    infer_schema_rows: DEFAULT_INFER_SCHEMA_ROWS,
    null_values: [""],
    strict_column_count: false,
    on_parse_error: Raise,
    allow_nonfinite_floats: true,
  }
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
/// - `ParseError(...)` — when `strict_quotes` is `true`, the input contains
///   an unterminated quoted field, text after a closing quote, or a quote
///   inside an unquoted field; or a non-null cell does not parse under
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
/// By default, tokenisation keeps NyaCSV's lenient quote handling. An
/// unterminated quoted field at end-of-input is read as a complete field
/// (`1,"unclosed` → last cell `unclosed`); text after a closing quote is
/// folded into the same field (`"ab"cd` → `abcd`); and a lone quote inside
/// an unquoted field is kept literally (`ab"cd` → `ab"cd`). A strict
/// RFC-4180 reader rejects all three; set `strict_quotes=true` to run a
/// linear validation pass before tokenisation and reject them as `ParseError`.
pub fn parse_csv_str(
  content : String,
  options : CsvReadOptions,
  strict_quotes? : Bool = false,
) -> @frame.DataFrame raise @types.DataError {
  parse_csv_str_projected(content, options, None, strict_quotes)
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
///   the columns a pipeline consumes. A requested name that matches no header
///   is silently ignored (lenient projection, as in Polars): the public
///   `read_csv_projected` does not raise `ColumnNotFound` for an unknown
///   column, it just yields the ones that match. The lazy path only ever
///   requests real columns, and a stray `col("missing")` is still caught
///   downstream by `select`. A projection matching **no** header falls back
///   to a full read (`effective_projection`): building zero columns would
///   lose the file's row count and flip the surfaced error downstream.
///
/// Every whole-input check runs *before* the projection filter and so is
/// unaffected by it — strict quote validation, the empty-input short-circuit,
/// duplicate-header rejection, and the optional ragged-row guard all see the
/// full input, so a projected read fails on malformed quoting, a malformed
/// header, or a ragged row exactly as a full read would. The single behavioural
/// difference is the
/// deliberate point of the feature: a non-null cell that fails to parse under
/// its column's inferred dtype only surfaces (`on_parse_error = Raise`) for a
/// column that is actually built, so a parse error confined to a *dropped*
/// column is not raised — that column is never parsed.
fn parse_csv_str_projected(
  content : String,
  options : CsvReadOptions,
  projection : Array[String]?,
  strict_quotes : Bool,
) -> @frame.DataFrame raise @types.DataError {
  // Refuse a delimiter that collides with the quote character or a row
  // terminator before parsing — the same configurations `format_csv` rejects,
  // so a value the writer can't emit unambiguously can't be read back either.
  validate_csv_delimiter(options.delimiter)
  // Strip a leading UTF-8 BOM (U+FEFF) before anything else, so a BOM-only file
  // still reads as empty. Shared with the JSON / NDJSON readers via
  // `strip_utf8_bom` so the formats can't drift apart.
  let content = strip_utf8_bom(content)
  // Short-circuit empty input. NyaCSV would otherwise produce a CSV
  // with no headers and no rows, which would collapse to an empty
  // 0×0 frame — handled the same way here, just without the parse.
  if content.is_empty() {
    return @frame.DataFrame::new([])
  }
  if strict_quotes {
    validate_csv_quotes(content, options.delimiter)
  }
  let csv_options : @nyacsv.CSVOptions = {
    delimiter: options.delimiter,
    allow_newlines_in_quotes: true,
    quote_char: '"',
    skip_empty_lines: true,
    trim_spaces: false,
  }
  let csv = @nyacsv.CSV::parse_string(content, options=csv_options)
  let (headers, rows) = split_csv_records(csv, options)
  let ncols = headers.length()
  if ncols == 0 {
    return @frame.DataFrame::new([])
  }
  validate_csv_shape(headers, rows, options)
  // Infer one dtype per column, then build the column — skipping any the
  // projection drops. `build_column` raises `ParseError` for a cell that
  // doesn't fit the inferred dtype. The surviving columns keep the file's own
  // header order (a filtered projection, never a reorder), so a projected read
  // is column-for-column a sub-frame of the full read.
  // Build the null-token test once: an O(1) `Map` membership check shared by
  // inference and the typed build, so a large `null_values` list does not turn
  // every cell scan into an O(k) linear probe.
  let null_set : Map[String, Unit] = Map([])
  for v in options.null_values {
    null_set[v] = ()
  }
  let is_null = fn(v : String) -> Bool { null_set.contains(v) }
  // A projection matching no header falls back to a full read (see
  // `effective_projection`) so the row count survives for the as-built
  // error to surface downstream.
  let projection = effective_projection(projection, headers)
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
        is_null,
        options.allow_nonfinite_floats,
      )
      series.push(
        build_column(
          name,
          dt,
          rows,
          col,
          is_null,
          options.on_parse_error,
          options.allow_nonfinite_floats,
        ),
      )
    }
  }
  @frame.DataFrame::new(series)
}

///|
/// Settle the headers / rows split of a parsed CSV based on `has_header`.
/// NyaCSV always lifts the first record into `header()`, so the
/// `has_header = false` branch pushes it back into the data section and
/// synthesises `column1..columnN` names.
fn split_csv_records(
  csv : @nyacsv.CSV,
  options : CsvReadOptions,
) -> (Array[String], Array[Array[String]]) {
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
    let ncols = if rows.is_empty() { 0 } else { rows[0].length() }
    for i in 0..<ncols {
      headers.push("column\{i + 1}")
    }
  }
  (headers, rows)
}

///|
/// Whole-shape validation ahead of any per-cell work: reject a duplicate
/// header up front (`DataFrame::new` would catch it via `Schema::new`, but
/// surfacing it here spares a wasted inference pass), and — when
/// `strict_column_count` is on — `raise ParseError` for a data row whose
/// cell count differs from the header's, rather than silently null-padding
/// (short row) or truncating (long row) in the lenient `cell_value` path.
/// Checked after the header settles, so a malformed header surfaces first;
/// the 1-based index is over the data rows (the header is not counted).
fn validate_csv_shape(
  headers : Array[String],
  rows : Array[Array[String]],
  options : CsvReadOptions,
) -> Unit raise @types.DataError {
  let seen : Map[String, Unit] = Map([])
  for name in headers {
    if seen.contains(name) {
      raise @types.DataError::DuplicateColumn(name)
    }
    seen[name] = ()
  }
  if options.strict_column_count {
    let ncols = headers.length()
    for i, row in rows {
      if row.length() != ncols {
        raise @types.DataError::ParseError(
          "row \{i + 1}: expected \{ncols} columns, got \{row.length()}",
        )
      }
    }
  }
}

///|
/// Read a CSV file using the default options.
pub fn read_csv(path : String) -> @frame.DataFrame raise @types.DataError {
  read_csv_with_options(path, CsvReadOptions::default())
}

///|
/// Read a CSV file with custom options. `IOError` from the file system
/// surfaces as `raise IoError(message)`. Set `strict_quotes=true` to reject
/// malformed quoting before NyaCSV tokenisation, as documented by
/// `parse_csv_str`.
pub fn read_csv_with_options(
  path : String,
  options : CsvReadOptions,
  strict_quotes? : Bool = false,
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_csv_str(content, options, strict_quotes~)
}

///|
/// Read a CSV file, building only the columns named in `projection` — the
/// file-backed entry behind the lazy `scan_csv` source's projection
/// pushdown. Identical to `read_csv_with_options` except that a column whose
/// header name is not in `projection` is never inferred, parsed, or
/// materialised (see `parse_csv_str_projected` for the precise contract,
/// including the one behavioural consequence: a parse error confined to a
/// dropped column does not surface). `IOError` from the file system surfaces
/// as `raise IoError(message)`. `strict_quotes=true` validates the whole input
/// before applying the projection.
pub fn read_csv_projected(
  path : String,
  options : CsvReadOptions,
  projection : Array[String],
  strict_quotes? : Bool = false,
) -> @frame.DataFrame raise @types.DataError {
  let content = read_text(path)
  parse_csv_str_projected(content, options, Some(projection), strict_quotes)
}

///|
/// State of the strict CSV quote validator. The validator mirrors RFC-4180's
/// field grammar without tokenising or allocating cells; NyaCSV remains the
/// parser after this pass succeeds.
priv enum CsvQuoteState {
  CsvFieldStart
  CsvUnquoted
  CsvQuoted
  CsvAfterQuote
}

///|
/// Reject the three malformed quote shapes NyaCSV otherwise accepts:
/// an opening quote without a close, non-separator text after a close, and a
/// quote inside an unquoted field. A doubled quote while quoted is an escape;
/// CR / LF are record separators outside quotes and ordinary content inside.
fn validate_csv_quotes(
  content : String,
  delimiter : Char,
) -> Unit raise @types.DataError {
  let mut state = CsvFieldStart
  for ch in content {
    state = match state {
      CsvFieldStart =>
        if ch == '"' {
          CsvQuoted
        } else if ch == delimiter || ch == '\r' || ch == '\n' {
          CsvFieldStart
        } else {
          CsvUnquoted
        }
      CsvUnquoted =>
        if ch == '"' {
          raise @types.DataError::ParseError(
            "malformed CSV quote: quote inside an unquoted field",
          )
        } else if ch == delimiter || ch == '\r' || ch == '\n' {
          CsvFieldStart
        } else {
          CsvUnquoted
        }
      CsvQuoted => if ch == '"' { CsvAfterQuote } else { CsvQuoted }
      CsvAfterQuote =>
        if ch == '"' {
          CsvQuoted
        } else if ch == delimiter || ch == '\r' || ch == '\n' {
          CsvFieldStart
        } else {
          raise @types.DataError::ParseError(
            "malformed CSV quote: unexpected character after a closing quote",
          )
        }
    }
  }
  if state is CsvQuoted {
    raise @types.DataError::ParseError(
      "malformed CSV quote: unterminated quoted field",
    )
  }
}

///|
/// Reject a delimiter that can't unambiguously frame fields. The quote
/// character is hard-coded as `'"'` and rows end at `'\n'` / `'\r'`, so a
/// delimiter equal to any of those collapses the field / record / quote
/// structure into one byte — a write emits unparseable output and a read splits
/// on the wrong boundary. A supplementary-plane (non-BMP) delimiter is rejected
/// too: the tokenizer matches one UTF-16 code unit at a time, so a delimiter
/// stored as a surrogate pair is never recognised and every cell would merge
/// into one column on a round-trip. Shared by `format_csv` and the reader so
/// both refuse the same configurations up front. (pandas / polars leave this as
/// GIGO; MoonFrame rejects it rather than corrupt a round-trip silently.)
fn validate_csv_delimiter(delimiter : Char) -> Unit raise @types.DataError {
  if delimiter == '"' || delimiter == '\n' || delimiter == '\r' {
    raise @types.DataError::InvalidOperation(
      "CSV delimiter must not be a double quote or a line terminator (\\n / \\r)",
    )
  }
  // `Char::to_int` is the Unicode code point; > 0xFFFF is the supplementary
  // plane, which UTF-16 stores as a surrogate pair the per-code-unit tokenizer
  // can never match.
  if delimiter.to_int() > 0xFFFF {
    raise @types.DataError::InvalidOperation(
      "CSV delimiter must be a single UTF-16 code unit (a Basic-Multilingual-Plane character)",
    )
  }
  // U+FEFF can never frame the first field unambiguously: every read strips
  // a leading U+FEFF as a byte-order mark before tokenizing, so a file whose
  // first field is empty loses its leading delimiter on read-back and every
  // cell of that record shifts left — the silent-corruption class this
  // validation exists to reject.
  if delimiter == '\u{FEFF}' {
    raise @types.DataError::InvalidOperation(
      "CSV delimiter must not be U+FEFF (stripped as a byte-order mark on read)",
    )
  }
}

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
  is_null : (String) -> Bool,
  allow_nonfinite_floats : Bool,
) -> InferredDtype {
  infer_dtype(
    rows.length(),
    limit,
    i => cell_value(rows, i, col),
    is_null,
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
  isnull : (String) -> Bool,
  on_parse_error : OnParseError,
  allow_nonfinite_floats : Bool,
) -> @series.Series raise @types.DataError {
  let n = rows.length()
  let cell = fn(i : Int) -> String { cell_value(rows, i, col) }
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
    InferString => build_string_column(name, n, cell, isnull, v => v)
  }
}
