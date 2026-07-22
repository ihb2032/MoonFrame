// HTML table rendering for `DataFrame`. The output is a standard
// `<table>` — optional `class` / `<caption>`, a `<thead>` header row,
// a `<tbody>` of data rows, and (when the row count is capped) a
// `<tfoot>` truncation banner — so it drops straight into a web page or
// a notebook's rich-display slot. Null cells render as an empty
// `<td></td>`, delegating to `Scalar::to_string` (which maps `Null` to
// the empty string), so a null and a genuine empty-string cell are
// indistinguishable in the output (the renderer carries no null marker).
//
// Like `to_markdown`, this is a pure, dependency-free renderer that
// lives on `DataFrame` rather than in `io` (the v0.2 IO-1 boundary:
// rendering stays in `frame`, only external serialisation lives in
// `io`). Values are read column-major through `column_series()` /
// `to_scalars()`, exactly as `to_markdown` does, so the v0.3 Stage 2
// `Series::storage` change is invisible here.

///|
/// Options for `DataFrame::to_html`. Fields are read-only outside the
/// package — build them through `HtmlOptions(...)`, naming only what differs
/// from the defaults:
///
///   * `max_rows` — cap the number of data rows. `None` (the default)
///     renders every row; `Some(n)` shows the first `n` and appends a
///     `<tfoot>` banner (`... (K more rows)`) for the remainder. A
///     negative `n` clamps to 0 (header + banner, no data rows),
///     matching `to_markdown`'s `max_rows`.
///   * `table_class` — value of the `<table class="...">` attribute.
///     `None` (the default) omits the attribute.
///   * `caption` — text of a leading `<caption>` element. `None` (the
///     default) omits it.
///   * `escape` — when `true` (the default) every emitted string —
///     caption, header names, cell values, and the class attribute — has
///     `&` / `<` / `>` / `"` / `'` rewritten to their HTML entities, so
///     untrusted data can't inject markup. Pass `escape=false` for
///     trusted input that intentionally carries HTML.
pub struct HtmlOptions {
  max_rows : Int?
  table_class : String?
  caption : String?
  escape : Bool
} derive(Eq, Debug)

///|
pub extend HtmlOptions with Eq::{equal, not_equal}

///|
pub extend HtmlOptions with Debug::{to_repr}

///|
/// Build render options. Omitting a parameter keeps its default: every row
/// rendered, no `class`, no `<caption>`, and HTML escaping on. `HtmlOptions()`
/// is the default rendering; name only what differs, as in
/// `HtmlOptions(max_rows=20, caption="Summary")`.
#as_free_fn
pub fn HtmlOptions::HtmlOptions(
  max_rows? : Int,
  table_class? : String,
  caption? : String,
  escape? : Bool = true,
) -> HtmlOptions {
  { max_rows, table_class, caption, escape }
}

///|
/// Render a `DataFrame` as an HTML `<table>`. `options` defaults to
/// `HtmlOptions()` — all rows, no `class` / `<caption>`, HTML-escaped — and
/// otherwise supplies an optional `class` / `<caption>`, a row cap with a
/// `<tfoot>` `... (K more rows)` banner, and optional escaping.
///
/// The output is a `<thead>` with one `<th>` per column followed by a
/// `<tbody>` with one `<tr>` per record (a `<td>` per cell, in
/// declaration order); a null cell renders as `<td></td>`. `&` / `<` /
/// `>` / `"` / `'` are escaped to their HTML entities.
///
/// Empty frames degrade gracefully:
///   - 0 columns → returns the empty string (MoonFrame's own choice for a
///     degenerate frame);
///   - N columns / 0 rows → header with an empty `<tbody>`.
///
/// Total — pure string assembly over already-validated frame data, and
/// `options.max_rows` is clamped into `[0, nrows]`, so no input can fail.
pub fn DataFrame::to_html(
  self : DataFrame,
  options? : HtmlOptions = HtmlOptions(),
) -> String {
  let nrows = self.nrows()
  let shown = match options.max_rows {
    None => nrows
    Some(n) => clamp_take(n, nrows)
  }
  format_html(self, shown, options)
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// Render the first `shown` rows of `df` as an HTML table under
/// `options`. When `shown < df.nrows()` a `<tfoot>` banner reports the
/// hidden remainder. Unlike `to_markdown`'s banner (appended *after* the
/// table text), the HTML banner is a `<tfoot>` *inside* `<table>`, so the
/// truncation decision is made here rather than in the public wrappers.
///
/// A 0-column frame renders as the empty string (there is no table to
/// draw); otherwise the header / `<tbody>` are always emitted, so a
/// 0-row frame is still a useful header + empty `<tbody>`.
fn format_html(df : DataFrame, shown : Int, options : HtmlOptions) -> String {
  let names = df.columns()
  let ncols = names.length()
  if ncols == 0 {
    return ""
  }
  let escape = options.escape
  // Pre-render the visible cells once (raw strings, the column-major frame read
  // transposed into per-row cells); each is HTML-escaped on write below.
  let cells = table_cell_matrix(df, shown)
  let buf = StringBuilder::new()
  buf <+ "<table"
  if options.table_class is Some(cls) {
    buf <+ " class=\"\{html_escape(cls, escape)}\""
  }
  buf <+ ">\n"
  if options.caption is Some(text) {
    buf <+ "<caption>\{html_escape(text, escape)}</caption>\n"
  }
  // Header.
  buf <+ "<thead>\n<tr>"
  for name in names {
    buf <+ "<th>\{html_escape(name, escape)}</th>"
  }
  buf <+ "</tr>\n</thead>\n"
  // Body — one `<tr>` per visible record. A null cell renders empty
  // (`Scalar::to_string` maps `Null` to "").
  buf <+ "<tbody>\n"
  for r in 0..<shown {
    buf <+ "<tr>"
    for c in 0..<ncols {
      buf <+ "<td>\{html_escape(cells[r][c], escape)}</td>"
    }
    buf <+ "</tr>\n"
  }
  buf <+ "</tbody>\n"
  // Truncation banner, spanning every column. The banner text is fixed
  // (digits + ASCII), so it needs no escaping.
  let nrows = df.nrows()
  if shown < nrows {
    buf <+
      "<tfoot>\n<tr><td colspan=\"\{ncols}\">\{more_rows_banner(nrows - shown)}</td></tr>\n</tfoot>\n"
  }
  buf <+ "</table>\n"
  buf.to_string()
}

///|
/// HTML-escape `s` when `escape` is `true`: `&` → `&amp;`, `<` → `&lt;`,
/// `>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`. Processing
/// codepoint-by-codepoint means the `&` rule can't double-escape the `&` it
/// just introduced. When `escape` is `false`, `s` is returned verbatim
/// (trusted input). The full conventional set (including `'`) is escaped, so
/// a cell or caption is safe in both `"`-quoted and `'`-quoted attribute
/// contexts, not only the `>`-delimited text the renderer emits today.
fn html_escape(s : String, escape : Bool) -> String {
  if !escape {
    return s
  }
  let buf = StringBuilder::new()
  for ch in s.iter() {
    match ch {
      '&' => buf.write_string("&amp;")
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '"' => buf.write_string("&quot;")
      '\'' => buf.write_string("&#39;")
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}
