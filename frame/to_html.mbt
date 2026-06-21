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
/// Options for `DataFrame::to_html_with_options`. Fields are read-only
/// outside the package — build them through `HtmlOptions::default()` and
/// chain the `with_*` setters:
///
///   * `max_rows` — cap the number of data rows. `None` (the default)
///     renders every row; `Some(n)` shows the first `n` and appends a
///     `<tfoot>` banner (`... (K more rows)`) for the remainder. A
///     negative `n` clamps to 0 (header + banner, no data rows),
///     matching `to_markdown_with_limit`.
///   * `table_class` — value of the `<table class="...">` attribute.
///     `None` (the default) omits the attribute.
///   * `caption` — text of a leading `<caption>` element. `None` (the
///     default) omits it.
///   * `escape` — when `true` (the default) every emitted string —
///     caption, header names, cell values, and the class attribute — has
///     `&` / `<` / `>` / `"` rewritten to their HTML entities, so
///     untrusted data can't inject markup. Set `false` (via
///     `with_escape`) to pass strings through verbatim for trusted input
///     that intentionally carries HTML.
pub struct HtmlOptions {
  max_rows : Int?
  table_class : String?
  caption : String?
  escape : Bool
} derive(Eq, Debug)

///|
/// The default options: render all rows, no `class`, no `<caption>`, and
/// HTML-escape every emitted string. Chain `with_max_rows` /
/// `with_table_class` / `with_caption` / `with_escape` to override.
pub fn HtmlOptions::default() -> HtmlOptions {
  { max_rows: None, table_class: None, caption: None, escape: true }
}

///|
/// Return a copy of these options that caps the rendered table at the
/// first `n` data rows, appending a `<tfoot>` `... (K more rows)` banner
/// for the remainder. A negative `n` clamps to 0. Chainable.
pub fn HtmlOptions::with_max_rows(self : HtmlOptions, n : Int) -> HtmlOptions {
  {
    max_rows: Some(n),
    table_class: self.table_class,
    caption: self.caption,
    escape: self.escape,
  }
}

///|
/// Return a copy of these options whose `<table>` carries
/// `class="<cls>"`. Chainable.
pub fn HtmlOptions::with_table_class(
  self : HtmlOptions,
  cls : String,
) -> HtmlOptions {
  {
    max_rows: self.max_rows,
    table_class: Some(cls),
    caption: self.caption,
    escape: self.escape,
  }
}

///|
/// Return a copy of these options that prepends a `<caption>` element
/// containing `text`. Chainable.
pub fn HtmlOptions::with_caption(
  self : HtmlOptions,
  text : String,
) -> HtmlOptions {
  {
    max_rows: self.max_rows,
    table_class: self.table_class,
    caption: Some(text),
    escape: self.escape,
  }
}

///|
/// Return a copy of these options with HTML escaping set to `escape`.
/// Pass `false` to emit strings verbatim (trusted input that carries
/// intentional markup). Chainable.
pub fn HtmlOptions::with_escape(
  self : HtmlOptions,
  escape : Bool,
) -> HtmlOptions {
  {
    max_rows: self.max_rows,
    table_class: self.table_class,
    caption: self.caption,
    escape,
  }
}

///|
/// Render a `DataFrame` as an HTML `<table>`, using the default options
/// (all rows, no `class` / `<caption>`, HTML-escaped).
///
/// The output is a `<thead>` with one `<th>` per column followed by a
/// `<tbody>` with one `<tr>` per record (a `<td>` per cell, in
/// declaration order); a null cell renders as `<td></td>`. `&` / `<` /
/// `>` / `"` are escaped to their HTML entities.
///
/// Empty frames degrade gracefully:
///   - 0 columns → returns the empty string (MoonFrame's own choice for a
///     degenerate frame);
///   - N columns / 0 rows → header with an empty `<tbody>`.
///
/// Total — pure string assembly over already-validated frame data.
pub fn DataFrame::to_html(self : DataFrame) -> String {
  format_html(self, self.nrows(), HtmlOptions::default())
}

///|
/// Render a `DataFrame` as an HTML `<table>` under `options` — an
/// optional `class` / `<caption>`, an optional row cap with a `<tfoot>`
/// `... (K more rows)` banner, and optional escaping. See `HtmlOptions`.
///
/// Total — `options.max_rows` is clamped into `[0, nrows]`, so no input
/// can fail.
pub fn DataFrame::to_html_with_options(
  self : DataFrame,
  options : HtmlOptions,
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
  buf.write_string("<table")
  if options.table_class is Some(cls) {
    buf.write_string(" class=\"")
    buf.write_string(html_escape(cls, escape))
    buf.write_char('"')
  }
  buf.write_string(">\n")
  if options.caption is Some(text) {
    buf.write_string("<caption>")
    buf.write_string(html_escape(text, escape))
    buf.write_string("</caption>\n")
  }
  // Header.
  buf.write_string("<thead>\n<tr>")
  for name in names {
    buf.write_string("<th>")
    buf.write_string(html_escape(name, escape))
    buf.write_string("</th>")
  }
  buf.write_string("</tr>\n</thead>\n")
  // Body — one `<tr>` per visible record. A null cell renders empty
  // (`Scalar::to_string` maps `Null` to "").
  buf.write_string("<tbody>\n")
  for r in 0..<shown {
    buf.write_string("<tr>")
    for c in 0..<ncols {
      buf.write_string("<td>")
      buf.write_string(html_escape(cells[r][c], escape))
      buf.write_string("</td>")
    }
    buf.write_string("</tr>\n")
  }
  buf.write_string("</tbody>\n")
  // Truncation banner, spanning every column. The banner text is fixed
  // (digits + ASCII), so it needs no escaping.
  let nrows = df.nrows()
  if shown < nrows {
    buf.write_string("<tfoot>\n<tr><td colspan=\"")
    buf.write_string(ncols.to_string())
    buf.write_string("\">")
    buf.write_string(more_rows_banner(nrows - shown))
    buf.write_string("</td></tr>\n</tfoot>\n")
  }
  buf.write_string("</table>\n")
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
