// The CSV write path: `CsvWriteOptions`, the `format_csv` renderer, the
// `write_csv` entry point, and the quoting
// rule (`write_quoted`), split from `csv.mbt` so reading and writing read
// apart. `validate_csv_delimiter` stays beside the reader: both directions
// reject the same delimiter set through it.

///|
/// Options that control how a `DataFrame` is rendered as CSV text.
///
/// - `header` — when `true`, the first emitted row is the column
///   names; when `false`, only data rows are written.
/// - `delimiter` — field separator written between cells.
/// - `null_value` — the literal string written in place of a null
///   cell. The default empty string round-trips with the reader's
///   default `null_values`.
/// - `sanitize_formulas` — when `true`, a `String` cell beginning with
///   `=`, `+`, `-`, `@`, a tab, or a carriage return is prefixed with a
///   single quote so a spreadsheet reads it as text. Deliberately lossy:
///   such a cell reads back with the leading quote. Defaults to `false`.
pub struct CsvWriteOptions {
  header : Bool
  delimiter : Char
  null_value : String
  sanitize_formulas : Bool
}

///|
/// Build write options. Every field has a default: header on, comma
/// delimiter, null cells emitted as the empty string, and no formula
/// sanitisation. `CsvWriteOptions()` is the all-defaults writer; name only
/// what differs, as in `CsvWriteOptions(delimiter=';')`.
#as_free_fn
pub fn CsvWriteOptions::CsvWriteOptions(
  header? : Bool = true,
  delimiter? : Char = ',',
  null_value? : String = "",
  sanitize_formulas? : Bool = false,
) -> CsvWriteOptions {
  { header, delimiter, null_value, sanitize_formulas }
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
///   narrowing the JSON writer documents. Negative zero is one such whole
///   value: `-0.0` writes as `0`, so its sign (observable under division)
///   does not survive the round-trip. A `String` cell with significant
///   leading / trailing whitespace is written bare (only the delimiter, a
///   quote, `\r`, or `\n` force quoting), so this reader round-trips it
///   (`trim_spaces` off), but an RFC-4180 consumer that trims surrounding
///   whitespace may drop it. A `String` cell whose text equals a reader null
///   token — the default `null_value` is the empty string `""`, so this
///   includes empty strings, plus any custom `null_values` entry — is read
///   back as null and cannot be distinguished from a true null. A `String`
///   cell whose text parses as another dtype is likewise re-inferred on read:
///   inference is content-based with no header type hints, so a column of
///   numeric-looking strings (`"01"`, `"2"`) returns as `Int` / `Float` —
///   dropping any leading zeros — and `"true"` / `"false"` as `Bool`, the
///   dtype-from-content narrowing inherent to typeless CSV (matching Polars'
///   `read_csv`). Quote / escape handling is otherwise round-trip safe.
/// - When `sanitize_formulas` is `true`, a `String` cell beginning with
///   `=`, `+`, `-`, `@`, tab, or carriage return is prefixed with an
///   apostrophe before CSV quoting. This opt-in, intentionally lossy
///   transformation prevents spreadsheet applications from interpreting
///   such cells as formulas. It does not affect headers, nulls, numbers,
///   booleans, or other strings; the default `false` preserves exact output.
/// - Raises `InvalidOperation` if `options.delimiter` is a double quote or a
///   line terminator (`\n` / `\r`): those collide with the hard-coded quote
///   character and the row terminator, so no escaping could make the output
///   frame fields unambiguously (see `validate_csv_delimiter`).
pub fn format_csv(
  df : @frame.DataFrame,
  options? : CsvWriteOptions = CsvWriteOptions(),
) -> String raise @types.DataError {
  validate_csv_delimiter(options.delimiter)
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
        file_start=i == 0,
      )
    }
    buf.write_char('\n')
  }
  let nrows = df.nrows()
  // Materialise the whole frame once (column-major) through the shared
  // `to_scalar_matrix`; `cols[c][r]` is then a plain in-bounds read, so no
  // per-cell `item` raise.
  let cols = df.to_scalar_matrix()
  for r in 0..<nrows {
    for c in 0..<names.length() {
      if c > 0 {
        buf.write_char(options.delimiter)
      }
      let scalar = cols[c][r]
      let rendered = render_csv_scalar(
        scalar,
        options.null_value,
        options.sanitize_formulas,
      )
      write_quoted(
        buf,
        rendered,
        options.delimiter,
        force_empty_quote=single_column,
        // With no header row the first data cell sits at byte 0 of the file.
        file_start=!options.header && r == 0 && c == 0,
      )
    }
    buf.write_char('\n')
  }
  buf.to_string()
}

///|
/// Write a `DataFrame` to a CSV file. `options` defaults to
/// `CsvWriteOptions()`, so `write_csv(path, df)` is the default-options
/// write. `IOError` from the file system surfaces as
/// `raise IoError(message)`. A string cell (or column name) holding an
/// unpaired UTF-16 surrogate is refused with `raise InvalidOperation` — the
/// UTF-8 file encoding would swallow the following delimiter and silently
/// shift every later cell boundary.
/// `CsvWriteOptions(sanitize_formulas=true)` applies the same
/// spreadsheet-safety transformation documented by `format_csv` before writing.
pub fn write_csv(
  path : String,
  df : @frame.DataFrame,
  options? : CsvWriteOptions = CsvWriteOptions(),
) -> Unit raise @types.DataError {
  let content = format_csv(df, options~)
  write_text(path, content)
}

// ── internals ──────────────────────────────────────────────────────────

///|
fn render_csv_scalar(
  scalar : @types.Scalar,
  null_value : String,
  sanitize_formulas : Bool,
) -> String {
  match scalar {
    @types.Scalar::Null => null_value
    @types.Scalar::String(value) =>
      if sanitize_formulas && starts_spreadsheet_formula(value) {
        let buf = StringBuilder::new()
        buf.write_string("'")
        buf.write_string(value)
        buf.to_string()
      } else {
        value
      }
    _ => scalar.to_string()
  }
}

///|
fn starts_spreadsheet_formula(value : String) -> Bool {
  match value.view().get_char(0) {
    Some(ch) =>
      ch == '=' ||
      ch == '+' ||
      ch == '-' ||
      ch == '@' ||
      ch == '\t' ||
      ch == '\r'
    None => false
  }
}

///|
/// Append `cell` to `buf`, quoting only when needed. A cell needs
/// quoting iff it contains the delimiter, a double quote, `\r`, or
/// `\n` — or, for the file's very first field (`file_start`), when it
/// begins with U+FEFF: bare at byte 0 that character would be stripped as
/// a byte-order mark on read-back, silently renaming the column (or
/// deleting the cell's first character); a leading `"` shields it.
/// Interior double quotes are doubled per RFC 4180.
fn write_quoted(
  buf : StringBuilder,
  cell : String,
  delimiter : Char,
  force_empty_quote~ : Bool,
  file_start~ : Bool,
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
    .any(ch => ch == delimiter || ch == '"' || ch == '\n' || ch == '\r') ||
    (file_start && cell.view().get_char(0) == Some('\u{FEFF}'))
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
