// Blackbox tests for `@chart.format_vega_html` / `@chart.write_vega_html`
// — the HTML document twin of the spec export: the shell's shape, the
// embedding contract (the emitted JSON, script-safe), and the same raise
// paths the spec emitter and the file writer carry.

///|
test "format_vega_html wraps the spec in the vega-embed shell" {
  let df = catval_df()
  let html = @chart.format_vega_html(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val"),
        title="Bands",
      ),
    ),
  )
  inspect(
    html,
    content=(
      #|<!DOCTYPE html>
      #|<html>
      #|<head>
      #|<meta charset="utf-8">
      #|<title>Chart</title>
      #|<script src="https://cdn.jsdelivr.net/npm/vega@6.4.0"></script>
      #|<script src="https://cdn.jsdelivr.net/npm/vega-lite@6.5.0"></script>
      #|<script src="https://cdn.jsdelivr.net/npm/vega-embed@7.3.0"></script>
      #|</head>
      #|<body>
      #|<div id="vis"></div>
      #|<script>vegaEmbed('#vis', {"$schema":"https://vega.github.io/schema/vega-lite/v6.json","title":"Bands","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}});</script>
      #|</body>
      #|</html>
      #|
    ),
  )
}

///|
test "the embedded spec is the emitted JSON verbatim" {
  // A frame whose data carries none of the rewritten characters embeds
  // the JSON exactly as the spec emitter produces it.
  let df = catval_df()
  let chart = @chart.Chart::of(
    @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")),
  )
  let html = @chart.format_vega_html(df, chart)
  assert_true(html.contains(@chart.format_vega_lite(df, chart)))
}

///|
test "chart data cannot close the spec's script element" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("label", ["</script>", "a\u{2028}b\u{2029}c"]),
    @series.Series::from_ints("v", [1, 2]),
  ])
  let chart = @chart.Chart::of(
    @chart.ChartSpec::bar(@chart.field("label"), @chart.field("v")),
  )
  let spec = @chart.format_vega_lite(df, chart)
  // The payload does carry the characters the rewrite exists for.
  assert_true(spec.contains("</script>"))
  let html = @chart.format_vega_html(df, chart)
  // The raw payload never appears; every rewritten character shows up
  // as its JSON escape.
  assert_true(!html.contains(spec))
  assert_true(html.contains("\\u003c/script>"))
  assert_true(html.contains("\\u2028"))
  assert_true(html.contains("\\u2029"))
}

///|
test "a channel naming an absent column raises ColumnNotFound" {
  let df = catval_df()
  let result = Ok(
    @chart.format_vega_html(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("ghost")),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(result, Err(@types.DataError::ColumnNotFound("ghost")))
}

///|
test "write_vega_html writes the document to disk verbatim" {
  let path = "_build/io_chart_test_write.html"
  let df = catval_df()
  let chart = @chart.Chart::of(
    @chart.ChartSpec::bar(
      @chart.field("cat"),
      @chart.field("val"),
      title="Disk",
    ),
  )
  @chart.write_vega_html(path, df, chart)
  // The file holds exactly what `format_vega_html` produces.
  let on_disk = @fs.read_file_to_string(path)
  assert_eq(on_disk, @chart.format_vega_html(df, chart))
}

///|
test "write_vega_html: invalid path surfaces as IoError" {
  // Aim the writer at a directory that doesn't exist so the underlying
  // `@fs` call fails; the `IOError` is promoted to `DataError::IoError`
  // (same shape as the spec writer's error test).
  let df = catval_df()
  let result = Ok(
    @chart.write_vega_html(
      "_build/no_such_dir_io_chart_test/file.html",
      df,
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}
