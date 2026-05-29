// Markdown table rendering for `DataFrame`. The output follows the
// GitHub-flavored pipe-table layout (header / dashed separator / data
// rows) and pads every column to the maximum width of its header and
// rendered cells so the source text is also pleasant to read in a
// fixed-width terminal. Null cells render as the empty string,
// delegating to `Scalar::to_string`.
//
// v0.1 picks GFM tables specifically because they are the lingua
// franca of MoonFrame's two output targets — `README.md` snippets and
// JupyterBook-style notebooks — and they round-trip through every
// Markdown parser we care about without a dedicated renderer
// dependency. The renderer therefore lives in-tree as a small,
// self-contained function rather than pulling in a third-party
// Markdown crate.

///|
/// Render a `DataFrame` as a GitHub-flavored Markdown table.
///
/// The output is three blocks of pipe-bounded rows:
///   1. header — column names, one cell per column;
///   2. separator — dashes sized to each column;
///   3. data — one row per record, in declaration order.
///
/// Column widths are aligned to `max(header, every rendered cell)`,
/// with a 3-character minimum so the dash separator never collapses
/// below the GFM-required floor. Null cells render as the empty
/// string, matching `Scalar::to_string`.
///
/// Empty frames degrade gracefully:
///   - 0 columns → returns the empty string;
///   - N columns / 0 rows → header + separator with no data rows.
pub fn to_markdown(df : @frame.DataFrame) -> String {
  format_markdown(df, df.nrows())
}

///|
/// Render a `DataFrame` as a Markdown table, capping the output at the
/// first `limit` rows. When `df` has more rows than `limit`, the
/// truncated count is appended below the table as
/// `... (N more rows)`. Negative `limit` is clamped to 0, so a frame that
/// has rows still renders as header + separator + the `... (N more rows)`
/// banner; only a genuinely 0-row frame is header + separator alone.
pub fn to_markdown_with_limit(df : @frame.DataFrame, limit : Int) -> String {
  let nrows = df.nrows()
  let shown = if limit < 0 { 0 } else if limit > nrows { nrows } else { limit }
  let body = format_markdown(df, shown)
  if shown < nrows {
    let extra = nrows - shown
    body + "... (" + extra.to_string() + " more rows)\n"
  } else {
    body
  }
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// Render the first `shown` rows of `df` as a Markdown table. The
/// header / separator are emitted whenever `df` has at least one
/// column, regardless of `shown` — a header-only table is still
/// useful shape information for callers limiting output.
fn format_markdown(df : @frame.DataFrame, shown : Int) -> String {
  // `raw_names` is used to look cells up in the frame; `names` is the
  // GFM-escaped form used for both width computation and rendering, so
  // a column name containing `|` / newline can't corrupt the table.
  let raw_names = df.columns()
  let ncols = raw_names.length()
  if ncols == 0 {
    return ""
  }
  let names = raw_names.map(escape_md_cell)
  // Pre-render every visible cell so column widths can be computed in
  // one forward pass before any layout. The cost is one `Scalar`
  // allocation per cell, which is negligible compared to the I/O the
  // caller is about to do with the resulting string.
  let cells : Array[Array[String]] = []
  for r in 0..<shown {
    let row : Array[String] = []
    for name in raw_names {
      // `df.get(r, name)` cannot fail here: `name` comes from
      // `df.columns()` (so it exists) and `r` ranges over `[0, shown)`
      // where `shown <= df.nrows()`.
      let scalar = df.get(r, name).unwrap()
      row.push(escape_md_cell(scalar.to_string()))
    }
    cells.push(row)
  }
  let widths : Array[Int] = []
  for c, name in names {
    let mut w = char_count(name)
    for r in 0..<shown {
      let cw = char_count(cells[r][c])
      if cw > w {
        w = cw
      }
    }
    // GFM requires at least three dashes per separator cell — pad to
    // a 3-char minimum so a short header (e.g. "a") doesn't produce
    // `|-|` which some lenient parsers still accept but stricter ones
    // (cmark, pulldown-cmark) reject.
    if w < 3 {
      w = 3
    }
    widths.push(w)
  }
  let buf = StringBuilder::new()
  write_row(buf, names, widths)
  // Separator row: dashes of `widths[c]` per column, padded with one
  // space on each side to match the data-row layout.
  buf.write_char('|')
  for c in 0..<ncols {
    buf.write_char(' ')
    for _ in 0..<widths[c] {
      buf.write_char('-')
    }
    buf.write_char(' ')
    buf.write_char('|')
  }
  buf.write_char('\n')
  for r in 0..<shown {
    write_row(buf, cells[r], widths)
  }
  buf.to_string()
}

///|
/// Emit one pipe-bounded row with each cell left-aligned and right-
/// padded with spaces to its column width.
fn write_row(
  buf : StringBuilder,
  row : Array[String],
  widths : Array[Int],
) -> Unit {
  buf.write_char('|')
  for c, cell in row {
    buf.write_char(' ')
    buf.write_string(cell)
    let pad = widths[c] - char_count(cell)
    for _ in 0..<pad {
      buf.write_char(' ')
    }
    buf.write_char(' ')
    buf.write_char('|')
  }
  buf.write_char('\n')
}

///|
/// Count Unicode codepoints in `s`. `String.length()` returns UTF-16
/// units which over-counts surrogate-pair characters; the alignment
/// pass wants one column per visual codepoint so a name containing a
/// supplementary-plane glyph lines up with shorter ASCII neighbours.
fn char_count(s : String) -> Int {
  s.iter().count()
}

///|
/// Escape a value for a GFM table cell. A literal backslash is doubled
/// (`\` → `\\`) and a literal `|` is rewritten to `\|`, so neither a bare
/// pipe nor a backslash sitting just before a pipe can split the cell
/// into extra columns. (Without the backslash rule, a cell containing
/// `\|` would emit `\\|` — an escaped backslash followed by a *bare*,
/// table-splitting pipe.) CR / LF collapse to a single space so a
/// multi-line value can't terminate the table row mid-cell. Everything
/// else passes through. Width alignment runs on the escaped form (callers
/// escape before measuring), so the two-character expansions are
/// accounted for.
fn escape_md_cell(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s.iter() {
    if ch == '\\' {
      buf.write_char('\\')
      buf.write_char('\\')
    } else if ch == '|' {
      buf.write_char('\\')
      buf.write_char('|')
    } else if ch == '\n' || ch == '\r' {
      buf.write_char(' ')
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}
