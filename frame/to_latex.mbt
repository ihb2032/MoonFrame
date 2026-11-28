// LaTeX table rendering for `DataFrame`. The output is a booktabs-ruled
// `tabular` — a `\toprule`, a header row under a `\midrule`, one row a
// record, a `\bottomrule` — inside a `table` environment when a caption, a
// label or a placement is given, or a `longtable` when asked, which carries
// the heads and feet a table that breaks across pages needs. A null cell
// renders as the text the options name for it, every other as
// `Scalar::to_string` spells it; a column name and a string cell have the
// characters LaTeX reserves rewritten to their escaped spellings.
//
// Like `to_markdown` and `to_html`, this is a pure, dependency-free
// renderer that sits on `DataFrame` (the IO boundary: the rendering here is
// pure, and only external serialisation writes to the outside).

///|
/// Options for `DataFrame::to_latex`. Fields are read-only outside the
/// package — build them through `LatexOptions::LatexOptions(...)`, naming only
/// what differs from the defaults:
///
///   * `columns` — the columns to render, in the order named. `None` (the
///     default) renders every column of the frame in its own order.
///   * `header` — when `true` (the default) a header row of column names
///     follows the top rule.
///   * `index` — when `true` (the default) a leading column carries each
///     row's position, from 0, under an empty header cell.
///   * `na_rep` — the text a null cell renders as; `NaN` by default.
///   * `escape` — when `true` (the default) the characters LaTeX reserves
///     (`& % $ # _ { } ~ ^ \`) in a column name and a string cell are
///     rewritten to their escaped spellings, and a line break inside a cell
///     becomes a space. Pass `escape=false` for cells that already carry
///     LaTeX.
///   * `column_format` — the column specification of the `tabular` /
///     `longtable` (`lrr`, `|c|c|`). `None` (the default) derives one: `l`
///     for the index column, then `r` for a column of `Int` / `Float` /
///     `Decimal` and `l` for any other.
///   * `longtable` — when `true` the table is a `longtable`, which breaks
///     across pages; `false` by default.
///   * `caption`, `label`, `position` — the caption text, the `\label` to
///     reference the table by, and the float placement (`htbp`). `None`
///     (the default) omits each. A table with none of the three is a bare
///     `tabular`; with any it sits inside a `table` environment. Each is
///     written as given: a caption is not escaped.
///   * `bold_rows` — when `true` the index column's cells are set in
///     `\textbf`; `false` by default.
///   * `decimal` — what stands between a float's and a decimal's integer and
///     fractional part, `.` by default.
#derive(Eq, Debug)
pub struct LatexOptions {
  priv columns : Array[String]?
  header : Bool
  index : Bool
  na_rep : String
  escape : Bool
  column_format : String?
  longtable : Bool
  caption : String?
  label : String?
  position : String?
  bold_rows : Bool
  decimal : String
}

///|
pub extend LatexOptions with Eq::{equal, not_equal}

///|
pub extend LatexOptions with Debug::{to_repr}

///|
/// The columns the options name, `None` for every column of the frame in
/// its own order. A copy, so mutating it cannot alter the options.
pub fn LatexOptions::columns(self : LatexOptions) -> Array[String]? {
  self.columns.map(names => names.copy())
}

///|
/// Build render options. Omitting a parameter keeps its default: every
/// column in the frame's order, a header row, an index column, `NaN` for a
/// null cell, escaping on, a derived column specification, a `tabular`, no
/// caption / label / position, plain index cells and `.` as the decimal
/// separator. `LatexOptions::LatexOptions()` is the default rendering; name
/// only what differs, as in `LatexOptions::LatexOptions(caption="Sales",
/// label="tab:sales", position="htbp")`. `columns` is copied, so mutating it
/// afterwards cannot alter the options.
pub fn LatexOptions::LatexOptions(
  columns? : Array[String],
  header~ : Bool = true,
  index~ : Bool = true,
  na_rep~ : String = "NaN",
  escape~ : Bool = true,
  column_format? : String,
  longtable~ : Bool = false,
  caption? : String,
  label? : String,
  position? : String,
  bold_rows~ : Bool = false,
  decimal~ : String = ".",
) -> LatexOptions {
  let kept = columns.map(names => names.copy())
  {
    columns: kept,
    header,
    index,
    na_rep,
    escape,
    column_format,
    longtable,
    caption,
    label,
    position,
    bold_rows,
    decimal,
  }
}

///|
/// Render a `DataFrame` as a LaTeX table. `options` defaults to
/// `LatexOptions::LatexOptions()` — every column in the frame's order, a
/// header row, an index column, `NaN` for a null cell, escaping on, a derived
/// column specification — and otherwise names what differs: a subset of the
/// columns, a `longtable`, a caption / label / placement, and the rest its
/// docstring lists.
///
/// The output is a booktabs-ruled `tabular`: a `\toprule`, the header row
/// and a `\midrule`, one row a record — its cells joined by ` & ` and the
/// row closed by `\\` — and a `\bottomrule`. With a caption, a label or a
/// placement the `tabular` sits inside a `table` environment, the caption
/// and the label above it. Under `longtable` it is a `longtable` instead:
/// the head repeated on every page, a foot naming the continuation, and the
/// last foot closed by the bottom rule.
///
/// A cell renders as `Scalar::to_string` spells it, with `options.decimal`
/// in place of the point of a float and a decimal, and `options.na_rep` for
/// a null. Under `options.escape` a column name or a string cell has
/// `& % $ # _ { } ~ ^ \` rewritten to their escaped spellings and a line
/// break becomes a space. The index column carries each row's position, from
/// 0, under an empty header cell, in `\textbf` under `options.bold_rows`. The
/// column specification is `options.column_format`, or derived: `l` for the
/// index column, `r` for a column of `Int` / `Float` / `Decimal`, `l` for any
/// other.
///
/// Raises `ColumnNotFound` for a column `options.columns` names that the
/// frame does not carry.
///
/// A frame with nothing to tabulate renders as the empty string, at any
/// height — a 0-column frame has no cells to draw, the `to_markdown` and
/// `to_html` rule — and `options.columns` naming no column renders as the
/// empty string too; columns with no row render as the header and the rules.
///
/// Total beyond the column lookup — pure string assembly over
/// already-validated frame data, every row rendered.
pub fn DataFrame::to_latex(
  self : DataFrame,
  options~ : LatexOptions = LatexOptions::LatexOptions(),
) -> String raise @types.DataError {
  // The columns kept, as the frame's own series: a name the frame does not
  // carry is the frame's own refusal.
  let kept : Array[@series.Series] = match options.columns {
    Some(names) => names.map(name => self.get_column(name))
    None => self.column_series()
  }
  if kept.is_empty() {
    return ""
  }
  let nrows = self.nrows()
  // Every cell rendered once, column by column, so a row is a walk over
  // ready strings.
  let rendered : Array[Array[String]] = kept.map(series => {
    series.to_scalars().map(cell => latex_cell(cell, options))
  })
  let header : Array[String] = []
  if options.index {
    header.push("")
  }
  for series in kept {
    header.push(latex_text(series.name(), options.escape))
  }
  let ncols = header.length()
  let spec = match options.column_format {
    Some(format) => format
    None => {
      let letters = StringBuilder()
      if options.index {
        letters.write_char('l')
      }
      for series in kept {
        letters.write_char(latex_alignment(series.dtype()))
      }
      letters.to_string()
    }
  }
  let placement = match options.position {
    Some(where_) => "[\{where_}]"
    None => ""
  }
  let wrapped = options.caption is Some(_) ||
    options.label is Some(_) ||
    options.position is Some(_)
  let buf = StringBuilder()
  if options.longtable {
    buf.write_string("\\begin{longtable}\{placement}{\{spec}}\n")
    if options.caption is Some(_) || options.label is Some(_) {
      latex_title(buf, options)
      buf.write_string(" \\\\\n")
    }
    latex_head(buf, options, header)
    buf.write_string("\\endfirsthead\n")
    if options.caption is Some(text) {
      buf.write_string("\\caption[]{\{text}} \\\\\n")
    }
    latex_head(buf, options, header)
    buf.write_string("\\endhead\n")
    buf.write_string(
      "\\midrule\n\\multicolumn{\{ncols}}{r}{Continued on next page} \\\\\n\\midrule\n\\endfoot\n",
    )
    buf.write_string("\\bottomrule\n\\endlastfoot\n")
  } else {
    if wrapped {
      buf.write_string("\\begin{table}\{placement}\n")
      if options.caption is Some(text) {
        buf.write_string("\\caption{\{text}}\n")
      }
      if options.label is Some(name) {
        buf.write_string("\\label{\{name}}\n")
      }
    }
    buf.write_string("\\begin{tabular}{\{spec}}\n\\toprule\n")
    if options.header {
      latex_row(buf, header)
      buf.write_string("\\midrule\n")
    }
  }
  let row : Array[String] = []
  for r in 0..<nrows {
    row.clear()
    if options.index {
      row.push(latex_position(r, options.bold_rows))
    }
    for column in rendered {
      row.push(column[r])
    }
    latex_row(buf, row)
  }
  if options.longtable {
    buf.write_string("\\end{longtable}\n")
  } else {
    buf.write_string("\\bottomrule\n\\end{tabular}\n")
    if wrapped {
      buf.write_string("\\end{table}\n")
    }
  }
  buf.to_string()
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// One row of the table: its cells joined by ` & `, the row closed by `\\`.
fn latex_row(buf : StringBuilder, cells : Array[String]) -> Unit {
  buf.write_string(cells.join(" & "))
  buf.write_string(" \\\\\n")
}

///|
/// The head of a `longtable`: the top rule, the header row and the rule
/// under it when the options keep a header.
fn latex_head(
  buf : StringBuilder,
  options : LatexOptions,
  header : Array[String],
) -> Unit {
  buf.write_string("\\toprule\n")
  if options.header {
    latex_row(buf, header)
    buf.write_string("\\midrule\n")
  }
}

///|
/// The caption and the label of a `longtable`'s first head, on one line and
/// each when the options name one. A continued page carries the caption
/// alone, bracketed so the list of tables does not repeat it.
fn latex_title(buf : StringBuilder, options : LatexOptions) -> Unit {
  let parts : Array[String] = []
  if options.caption is Some(text) {
    parts.push("\\caption{\{text}}")
  }
  if options.label is Some(name) {
    parts.push("\\label{\{name}}")
  }
  buf.write_string(parts.join(" "))
}

///|
/// The index column's cell for row `r`: its position, in `\textbf` under
/// `bold`.
fn latex_position(r : Int32, bold : Bool) -> String {
  if bold {
    "\\textbf{\{r}}"
  } else {
    r.to_string()
  }
}

///|
/// A cell's text: the null's spelling for a null, the escaped text for a
/// string, the decimal separator in a float's and a decimal's, and the
/// scalar's own spelling for every other value.
fn latex_cell(cell : @types.Scalar, options : LatexOptions) -> String {
  match cell {
    @types.Scalar::Null => options.na_rep
    @types.Scalar::String(text) => latex_text(text, options.escape)
    @types.Scalar::Float(value) =>
      latex_decimal(value.to_string(), options.decimal)
    @types.Scalar::Decimal(value) =>
      latex_decimal(value.to_string(), options.decimal)
    @types.Scalar::Int(value) => value.to_string()
    @types.Scalar::Bool(value) => value.to_string()
    @types.Scalar::Date(_) => cell.to_string()
    @types.Scalar::Timestamp(_) => cell.to_string()
    @types.Scalar::Duration(_) => cell.to_string()
    @types.Scalar::List(_) => cell.to_string()
    @types.Scalar::Struct(_) => cell.to_string()
  }
}

///|
/// A column's letter in a derived column specification: `r` for a column of
/// numbers the rows align on, `l` for any other.
fn latex_alignment(dtype : @types.DataType) -> Char {
  match dtype {
    @types.DataType::Int => 'r'
    @types.DataType::Float => 'r'
    @types.DataType::Decimal => 'r'
    @types.DataType::Bool => 'l'
    @types.DataType::String => 'l'
    @types.DataType::Date => 'l'
    @types.DataType::Timestamp => 'l'
    @types.DataType::Duration => 'l'
    @types.DataType::List(_) => 'l'
    @types.DataType::Struct(_) => 'l'
    @types.DataType::Null => 'l'
  }
}

///|
/// A float's or a decimal's spelling with `decimal` in place of its point.
fn latex_decimal(text : String, decimal : String) -> String {
  if decimal == "." {
    return text
  }
  let buf = StringBuilder()
  for ch in text.iter() {
    if ch == '.' {
      buf.write_string(decimal)
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}

///|
/// A column name or a string cell as LaTeX text. Under `escape` the ten
/// characters LaTeX reserves are rewritten to their escaped spellings —
/// `&` to `\&`, `~` to `\textasciitilde`, `\` to `\textbackslash`, and so
/// on — and a line break becomes a space, since one ends a table row. The
/// three spellings that are control words end in a space, which ends the
/// word: without it a letter following would be read as part of the name.
/// A string that already carries LaTeX passes through under `escape=false`.
fn latex_text(text : String, escape : Bool) -> String {
  if !escape {
    return text
  }
  let buf = StringBuilder()
  for ch in text.iter() {
    match ch {
      '&' => buf.write_string("\\&")
      '%' => buf.write_string("\\%")
      '$' => buf.write_string("\\$")
      '#' => buf.write_string("\\#")
      '_' => buf.write_string("\\_")
      '{' => buf.write_string("\\{")
      '}' => buf.write_string("\\}")
      '~' => buf.write_string("\\textasciitilde ")
      '^' => buf.write_string("\\textasciicircum ")
      '\\' => buf.write_string("\\textbackslash ")
      '\n' | '\r' => buf.write_char(' ')
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}
