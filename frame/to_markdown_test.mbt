// Blackbox tests for `DataFrame::to_markdown` / `to_markdown_with_limit`.
//
// The renderer is deterministic — given a DataFrame, the output bytes
// are fixed — so we exercise it primarily through exact-string
// assertions. Each test pins one concrete aspect: empty frame, the
// header-only shape, null rendering, column-width alignment, the
// 3-character minimum, and the row-limit truncation banner.

// ── shape edge cases ────────────────────────────────────────────────

///|
test "to_markdown: empty frame returns the empty string" {
  let df = DataFrame::new([])
  assert_eq(df.to_markdown(), "")
}

///|
test "to_markdown: zero rows still emits header + separator" {
  // `DataFrame::empty` produces a schema-only frame with 0 records.
  // The renderer must still surface the column layout — that's the
  // whole point of having a schema in the first place.
  let schema = @types.Schema::new([
    @types.Field("a", @types.DataType::Int),
    @types.Field("b", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let expected =
    #|| a   | b   |
    #|| --- | --- |
    #|
  assert_eq(df.to_markdown(), expected)
}

// ── basic rendering ─────────────────────────────────────────────────

///|
test "to_markdown: simple Int + String frame" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
  let expected =
    #|| a   | b   |
    #|| --- | --- |
    #|| 1   | x   |
    #|| 2   | y   |
    #|| 3   | z   |
    #|
  assert_eq(df.to_markdown(), expected)
}

///|
test "to_markdown: null cells render as the empty string" {
  let df = DataFrame::new([
    Series::from_int_options("n", [Some(1), None, Some(3)]),
    Series::from_string_options("s", [Some("a"), Some("b"), None]),
  ])
  let expected =
    #|| n   | s   |
    #|| --- | --- |
    #|| 1   | a   |
    #||     | b   |
    #|| 3   |     |
    #|
  assert_eq(df.to_markdown(), expected)
}

///|
test "to_markdown: escapes pipe and newline in headers and cells" {
  // A `|` in a header or cell is escaped to `\|` so it doesn't split
  // the GFM cell; CR / LF become a space so a multi-line value can't
  // terminate the row mid-cell. Width alignment runs on the escaped
  // text, so the `\|` expansion is measured correctly.
  let df = DataFrame::new([Series::from_strings("a|b", ["x|y", "p\r\nq"])])
  let expected =
    #|| a\|b |
    #|| ---- |
    #|| x\|y |
    #|| p  q |
    #|
  assert_eq(df.to_markdown(), expected)
}

///|
test "to_markdown: a backslash before a pipe can't split the row" {
  // The cell `\|` must not render as `\\|` (escaped backslash + a bare,
  // table-splitting pipe). The backslash is doubled and the pipe escaped,
  // so the rendered cell is `\\\|` and the data row keeps exactly its two
  // bounding pipes.
  let df = DataFrame::new([Series::from_strings("v", ["\\|"])])
  let expected =
    #|| v    |
    #|| ---- |
    #|| \\\| |
    #|
  assert_eq(df.to_markdown(), expected)
}

// ── width / alignment ───────────────────────────────────────────────

///|
test "to_markdown: column width aligns to widest header / cell" {
  // Header "identifier" is the widest entry in its column at 10
  // chars; widths for the numeric column come from the header (1)
  // and the widest cell ("22" → 2) and then bump to the 3-char
  // separator minimum.
  let df = DataFrame::new([
    Series::from_strings("identifier", ["x", "yyy", "zzzzz"]),
    Series::from_ints("n", [1, 22, 3]),
  ])
  let expected =
    #|| identifier | n   |
    #|| ---------- | --- |
    #|| x          | 1   |
    #|| yyy        | 22  |
    #|| zzzzz      | 3   |
    #|
  assert_eq(df.to_markdown(), expected)
}

///|
test "to_markdown: column width respects the 3-char dash minimum" {
  // The header and every cell are single characters; without the
  // minimum the separator would collapse to `|-|` which stricter
  // CommonMark parsers reject. The renderer pads to 3 dashes.
  let df = DataFrame::new([Series::from_strings("a", ["1", "2"])])
  let expected =
    #|| a   |
    #|| --- |
    #|| 1   |
    #|| 2   |
    #|
  assert_eq(df.to_markdown(), expected)
}

// ── to_markdown_with_limit ──────────────────────────────────────────

///|
test "to_markdown_with_limit: truncates and appends `... (N more rows)`" {
  // The blank line before the banner ends the GFM table, so the banner
  // renders as the paragraph below it — glued to the last row it would
  // parse as one more single-cell table ROW.
  let df = DataFrame::new([Series::from_ints("n", [1, 2, 3, 4, 5])])
  let expected =
    #|| n   |
    #|| --- |
    #|| 1   |
    #|| 2   |
    #|
    #|... (3 more rows)
    #|
  assert_eq(df.to_markdown_with_limit(2), expected)
}

///|
test "to_markdown_with_limit: limit >= nrows shows every row, no banner" {
  let df = DataFrame::new([Series::from_ints("n", [1, 2])])
  let expected =
    #|| n   |
    #|| --- |
    #|| 1   |
    #|| 2   |
    #|
  // limit == nrows and limit > nrows must produce identical output.
  assert_eq(df.to_markdown_with_limit(2), expected)
  assert_eq(df.to_markdown_with_limit(100), expected)
}

///|
test "to_markdown_with_limit: limit=0 shows header + separator + banner" {
  // shown=0 means the width pass only sees the header, so the
  // column width is just the header width bumped to the 3-char min.
  let df = DataFrame::new([Series::from_ints("n", [1, 2, 3])])
  let expected =
    #|| n   |
    #|| --- |
    #|
    #|... (3 more rows)
    #|
  assert_eq(df.to_markdown_with_limit(0), expected)
}

///|
test "to_markdown_with_limit: negative limit is clamped to 0" {
  let df = DataFrame::new([Series::from_ints("n", [1, 2])])
  let expected =
    #|| n   |
    #|| --- |
    #|
    #|... (2 more rows)
    #|
  assert_eq(df.to_markdown_with_limit(-5), expected)
}
