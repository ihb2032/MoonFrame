// The HTML twin of the spec export: the same Vega-Lite v6 specification
// `format_vega_lite` emits, embedded in a standalone HTML document that
// renders it. The document loads the Vega runtime — three scripts pinned
// to vega@6.4.0 / vega-lite@6.5.0 / vega-embed@7.3.0, the pairing the
// official embedding guide states for Vega-Lite 6
// (<https://vega.github.io/vega-lite/usage/embed.html>), with vega-lite
// held at the mirrored schema's own version — from a public CDN, so
// opening the file needs network access; the specification and its
// inlined data travel inside the document itself. The browser renders
// the interactive chart and shows vega-embed's default action links:
// image export (SVG / PNG), the spec source, and the online editor.
// Rendering stays in the browser because that is where the Vega-Lite
// runtime lives — this adds no dependency and no backend constraint,
// remaining a pure emitter.
//
// The specification is embedded as a JavaScript expression inside a
// `<script>` element, where JSON is valid source. A literal `<` in the
// JSON — a field name or a string cell can carry one — would let chart
// data close the element early (`</script>` inside a string cell), so
// every literal `<` is rewritten to its JSON escape `\u003c` before
// embedding: the same JSON value, with no `<` character left in the
// block. The two line-separator code points (U+2028 / U+2029), valid in
// JSON strings but not in JavaScript string literals before ES2019, are
// rewritten the same way.

///|
/// Render `df` and `chart` as a standalone HTML document that displays
/// the chart: the specification `format_vega_lite` emits, embedded as a
/// JavaScript expression, plus the three pinned runtime scripts
/// (vega@6.4.0, vega-lite@6.5.0 — the mirrored schema's own version —
/// and vega-embed@7.3.0, loaded from a public CDN). Opening the file in
/// a browser renders the interactive chart; vega-embed's default action
/// links offer SVG / PNG export, the spec source, and the online
/// editor. The spec and its inlined data travel inside the document, so
/// the file is self-contained apart from the CDN scripts — viewing
/// needs network access.
///
/// Each field channel names a column of `df`, resolved in the fixed
/// order the `ChartSpec` doc states, and the first name absent from the
/// frame raises `ColumnNotFound(name)`. This is not **total**, for the
/// same full set of reasons `format_vega_lite`'s doc enumerates — the
/// `ColumnNotFound` family (a channel column, a facet channel's column,
/// a repeat field-list name) and the `InvalidOperation` family (a
/// constant a position or offset channel's value definition refuses, a
/// channel carrying both a `field` and a repeat reference, a facet sort
/// keyed on another channel, a composition child of an illegal shape
/// for its host, and a composition with nothing to compose); the spec
/// emission underneath is the shared one. Before embedding, every
/// literal `<` in the emitted JSON
/// is rewritten to its `\u003c` JSON escape, and the U+2028 / U+2029
/// line separators likewise, so chart data cannot close the host
/// `<script>` element early; the embedded text is the same JSON value,
/// readable by any standards-compliant JSON reader.
pub fn format_vega_html(
  df : @frame.DataFrame,
  chart : Chart,
) -> String raise @types.DataError {
  vega_embed_html(json_for_script(format_vega_lite(df, chart)))
}

///|
/// Write the HTML document `format_vega_html` produces to `path`. A
/// `ColumnNotFound` from the spec emission (a spec column absent from
/// `df`) propagates unchanged, a filesystem failure surfaces as
/// `raise IoError(message)`, and content holding an unpaired UTF-16
/// surrogate is refused with `raise InvalidOperation`.
pub fn write_vega_html(
  path : String,
  df : @frame.DataFrame,
  chart : Chart,
) -> Unit raise @types.DataError {
  let content = format_vega_html(df, chart)
  @io.write_text(path, content)
}

///|
/// The emitted JSON made safe to embed inside a `<script>` element:
/// every literal `<` becomes its `\u003c` JSON escape, and the U+2028 /
/// U+2029 line separators (valid in JSON strings, invalid in
/// JavaScript string literals before ES2019) become theirs. Each
/// rewrite replaces a character that can only occur inside a JSON
/// string literal, and a JSON string holding the escape sequence itself
/// carries it backslash-escaped (`\\u003c`), so the rewrite cannot hit
/// an escape already present: the result spells the same JSON value.
fn json_for_script(json : String) -> String {
  json
  .replace(old="<", new="\\u003c")
  .replace(old="\u{2028}", new="\\u2028")
  .replace(old="\u{2029}", new="\\u2029")
}

///|
/// The document itself: a minimal HTML5 page whose three pinned script
/// tags load the Vega runtime from a public CDN, and whose single
/// inline call hands the embedded specification to `vegaEmbed` — the
/// container the runtime renders the interactive chart into, with its
/// default action links (image export, the spec source, the online
/// editor).
fn vega_embed_html(spec : String) -> String {
  "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>Chart</title>\n" +
  "<script src=\"https://cdn.jsdelivr.net/npm/vega@6.4.0\"></script>\n" +
  "<script src=\"https://cdn.jsdelivr.net/npm/vega-lite@6.5.0\"></script>\n" +
  "<script src=\"https://cdn.jsdelivr.net/npm/vega-embed@7.3.0\"></script>\n" +
  "</head>\n<body>\n<div id=\"vis\"></div>\n" +
  "<script>vegaEmbed('#vis', \{spec});</script>\n" +
  "</body>\n</html>\n"
}
