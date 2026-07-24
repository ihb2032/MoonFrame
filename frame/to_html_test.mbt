// Blackbox tests for `DataFrame::to_html` / `to_html`.
//
// The renderer is deterministic — a given DataFrame plus options maps to
// fixed output bytes — so we pin each aspect with an exact-string
// assertion: the shape edge cases (empty / header-only), null rendering,
// HTML escaping (and the `escape=false` bypass), the row cap with its
// `<tfoot>` banner, and the `class` / `caption` options.

// ── shape edge cases ────────────────────────────────────────────────

///|
test "to_html: empty frame (0x0) returns the empty string" {
  let df = DataFrame::DataFrame([])
  assert_eq(df.to_html(), "")
}

///|
test "to_html: zero rows still emits header + empty tbody" {
  // A schema-only frame must still surface the column layout; the
  // `<tbody>` is present but carries no `<tr>` (as pandas' `to_html`
  // renders a 0-row frame).
  let schema = @types.Schema([
    @types.Field("a", @types.DataType::Int),
    @types.Field("b", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>a</th><th>b</th></tr>
    #|</thead>
    #|<tbody>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(), expected)
}

// ── basic rendering ─────────────────────────────────────────────────

///|
test "to_html: simple Int + String frame" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>a</th><th>b</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>1</td><td>x</td></tr>
    #|<tr><td>2</td><td>y</td></tr>
    #|<tr><td>3</td><td>z</td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(), expected)
}

///|
test "to_html: null cells render as empty <td></td>" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("n", [Some(1), None, Some(3)]),
    Series::from_string_options("s", [Some("a"), Some("b"), None]),
  ])
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>n</th><th>s</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>1</td><td>a</td></tr>
    #|<tr><td></td><td>b</td></tr>
    #|<tr><td>3</td><td></td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(), expected)
}

///|
test "to_html: wide Unicode column names and cells pass through" {
  // Non-ASCII codepoints (including a supplementary-plane emoji) are not
  // markup-significant, so they survive the escape pass verbatim.
  let df = DataFrame::DataFrame([
    Series::from_strings("地区", ["华东"]),
    Series::from_strings("trend", ["📈"]),
  ])
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>地区</th><th>trend</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>华东</td><td>📈</td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(), expected)
}

///|
test "to_html: equals to_html with default options" {
  let df = DataFrame::DataFrame([Series::from_ints("n", [1, 2])])
  assert_eq(df.to_html(), df.to_html(options=HtmlOptions()))
}

// ── escaping ────────────────────────────────────────────────────────

///|
test "to_html: escapes &, <, >, \", ' in headers and cells (default)" {
  // Both column names carry a `<` / `&`; the cells exercise every
  // escaped character plus ordinary text, so the `&amp;`/`&lt;`/`&gt;`/
  // `&quot;`/`&#39;` rules (and the verbatim fall-through) are all covered.
  let df = DataFrame::DataFrame([
    Series::from_strings("x<y", ["<script>alert(1)</script>"]),
    Series::from_strings("a&b", ["he said \"hi\" & it's left"]),
  ])
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>x&lt;y</th><th>a&amp;b</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>&lt;script&gt;alert(1)&lt;/script&gt;</td><td>he said &quot;hi&quot; &amp; it&#39;s left</td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(), expected)
}

///|
test "to_html: escape=false passes markup through verbatim" {
  let df = DataFrame::DataFrame([Series::from_strings("h", ["<b>bold</b>"])])
  let opts : HtmlOptions = HtmlOptions(escape=false)
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>h</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td><b>bold</b></td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(options=opts), expected)
}

// ── max_rows truncation ─────────────────────────────────────────────

///|
test "to_html: max_rows truncates with a tfoot banner" {
  let df = DataFrame::DataFrame([Series::from_ints("n", [1, 2, 3, 4, 5])])
  let opts : HtmlOptions = HtmlOptions(max_rows=2)
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>n</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>1</td></tr>
    #|<tr><td>2</td></tr>
    #|</tbody>
    #|<tfoot>
    #|<tr><td colspan="1">... (3 more rows)</td></tr>
    #|</tfoot>
    #|</table>
    #|
  assert_eq(df.to_html(options=opts), expected)
}

///|
test "to_html: negative max_rows clamps to 0 (header + banner)" {
  let df = DataFrame::DataFrame([Series::from_ints("n", [1, 2])])
  let opts : HtmlOptions = HtmlOptions(max_rows=-3)
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>n</th></tr>
    #|</thead>
    #|<tbody>
    #|</tbody>
    #|<tfoot>
    #|<tr><td colspan="1">... (2 more rows)</td></tr>
    #|</tfoot>
    #|</table>
    #|
  assert_eq(df.to_html(options=opts), expected)
}

///|
test "to_html: max_rows >= nrows shows all rows, no banner" {
  let df = DataFrame::DataFrame([Series::from_ints("n", [1, 2])])
  let opts : HtmlOptions = HtmlOptions(max_rows=100)
  let expected =
    #|<table>
    #|<thead>
    #|<tr><th>n</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>1</td></tr>
    #|<tr><td>2</td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(options=opts), expected)
}

// ── class / caption ─────────────────────────────────────────────────

///|
test "to_html: with_table_class sets the class attribute" {
  let df = DataFrame::DataFrame([Series::from_ints("n", [1])])
  let opts : HtmlOptions = HtmlOptions(table_class="dataframe")
  let expected =
    #|<table class="dataframe">
    #|<thead>
    #|<tr><th>n</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>1</td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(options=opts), expected)
}

///|
test "to_html: with_caption emits an escaped caption" {
  let df = DataFrame::DataFrame([Series::from_ints("n", [1])])
  let opts : HtmlOptions = HtmlOptions(caption="Sales & totals")
  let expected =
    #|<table>
    #|<caption>Sales &amp; totals</caption>
    #|<thead>
    #|<tr><th>n</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>1</td></tr>
    #|</tbody>
    #|</table>
    #|
  assert_eq(df.to_html(options=opts), expected)
}

///|
test "to_html: class + caption + max_rows compose" {
  let df = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "east", "north"]),
    Series::from_ints("n", [10, 5, 7]),
  ])
  let opts : HtmlOptions = HtmlOptions(
    table_class="dataframe",
    caption="Top regions",
    max_rows=2,
  )
  let expected =
    #|<table class="dataframe">
    #|<caption>Top regions</caption>
    #|<thead>
    #|<tr><th>region</th><th>n</th></tr>
    #|</thead>
    #|<tbody>
    #|<tr><td>west</td><td>10</td></tr>
    #|<tr><td>east</td><td>5</td></tr>
    #|</tbody>
    #|<tfoot>
    #|<tr><td colspan="2">... (1 more row)</td></tr>
    #|</tfoot>
    #|</table>
    #|
  assert_eq(df.to_html(options=opts), expected)
}
