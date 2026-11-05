// Blackbox tests for the `plot` sugar layer: each mark method builds the
// same `ChartSpec` its mirror constructor builds (pinned by `Eq` on the
// spec), the refinements do what their docstrings say, and the terminals
// are the existing format / write functions over the bound frame — so a
// golden `to_json` here is byte-identical to the mirror's output.

///|
/// Three columns — `cat` (`String`), `val` (`Int`), `grp` (`String`) —
/// one row: enough for a nominal x, a quantitative y, and a `color`.
fn plot_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("val", [1]),
    @series.Series::from_strings("grp", ["a"]),
  ])
}

// ── marks: each method is its ChartSpec counterpart ─────────────────

///|
test "plot: the x/y marks build their ChartSpec counterparts" {
  let df = plot_df()
  // The line-tail marks.
  assert_eq(
    @chart.plot(df).line(x="cat", y="val").spec(),
    @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")),
  )
  assert_eq(
    @chart.plot(df).point(x="cat", y="val").spec(),
    @chart.ChartSpec::point(@chart.field("cat"), @chart.field("val")),
  )
  assert_eq(
    @chart.plot(df).tick(x="cat", y="val").spec(),
    @chart.ChartSpec::tick(@chart.field("cat"), @chart.field("val")),
  )
  assert_eq(
    @chart.plot(df).circle(x="cat", y="val").spec(),
    @chart.ChartSpec::circle(@chart.field("cat"), @chart.field("val")),
  )
  assert_eq(
    @chart.plot(df).square(x="cat", y="val").spec(),
    @chart.ChartSpec::square(@chart.field("cat"), @chart.field("val")),
  )
  assert_eq(
    @chart.plot(df).trail(x="cat", y="val").spec(),
    @chart.ChartSpec::trail(@chart.field("cat"), @chart.field("val")),
  )
  // The bar-tail marks (x2 / y2 for a ranged mark).
  assert_eq(
    @chart.plot(df).rect(x="cat", y="val", x2="grp").spec(),
    @chart.ChartSpec::rect(
      @chart.field("cat"),
      @chart.field("val"),
      x2=@chart.field("grp"),
    ),
  )
  assert_eq(
    @chart.plot(df).rule(x="cat", y="val", y2="grp").spec(),
    @chart.ChartSpec::rule(
      @chart.field("cat"),
      @chart.field("val"),
      y2=@chart.field("grp"),
    ),
  )
  // Boxplot: the x/y tail without detail / x2 / y2.
  assert_eq(
    @chart.plot(df).boxplot(x="cat", y="val").spec(),
    @chart.ChartSpec::boxplot(@chart.field("cat"), @chart.field("val")),
  )
}

///|
test "plot: bar and area carry the optional channels and the chrome" {
  let df = plot_df()
  // The full optional set of the bar tail, plus the title / width /
  // height chrome — the constructor's whole parameter list, forwarded.
  assert_eq(
    @chart.plot(df)
    .bar(
      x="cat",
      y="val",
      color="grp",
      size="val",
      opacity="grp",
      tooltip="cat",
      detail="grp",
      x2="val",
      y2="cat",
      title="T",
      width=@chart.VegaExtent::Px(400),
      height=@chart.VegaExtent::Step(20),
    )
    .spec(),
    @chart.ChartSpec::bar(
      @chart.field("cat"),
      @chart.field("val"),
      color=@chart.field("grp"),
      size=@chart.field("val"),
      opacity=@chart.field("grp"),
      tooltip=@chart.field("cat"),
      detail=@chart.field("grp"),
      x2=@chart.field("val"),
      y2=@chart.field("cat"),
      title="T",
      width=@chart.VegaExtent::Px(400),
      height=@chart.VegaExtent::Step(20),
    ),
  )
  assert_eq(
    @chart.plot(df).area(x="cat", y="val", color="grp", title="T").spec(),
    @chart.ChartSpec::area(
      @chart.field("cat"),
      @chart.field("val"),
      color=@chart.field("grp"),
      title="T",
    ),
  )
}

///|
test "plot: the marks that take a third required channel" {
  let df = plot_df()
  assert_eq(
    @chart.plot(df).text(x="cat", y="val", text="grp").spec(),
    @chart.ChartSpec::text(
      @chart.field("cat"),
      @chart.field("val"),
      @chart.field("grp"),
    ),
  )
  assert_eq(
    @chart.plot(df).image(x="cat", y="val", url="grp").spec(),
    @chart.ChartSpec::image(
      @chart.field("cat"),
      @chart.field("val"),
      @chart.field("grp"),
    ),
  )
  // The polar and single-channel marks.
  assert_eq(
    @chart.plot(df).arc(theta="cat", radius="val").spec(),
    @chart.ChartSpec::arc(@chart.field("cat"), radius=@chart.field("val")),
  )
  assert_eq(
    @chart.plot(df).geoshape(shape="cat", color="grp").spec(),
    @chart.ChartSpec::geoshape(@chart.field("cat"), color=@chart.field("grp")),
  )
}

///|
test "plot: the error composites carry their error channels" {
  let df = plot_df()
  assert_eq(
    @chart.plot(df)
    .errorbar(x="cat", y="val", y_error="grp", y_error2="cat")
    .spec(),
    @chart.ChartSpec::errorbar(
      @chart.field("cat"),
      @chart.field("val"),
      y_error=@chart.field("grp"),
      y_error2=@chart.field("cat"),
    ),
  )
  assert_eq(
    @chart.plot(df)
    .errorband(x="cat", y="val", x_error="grp", detail="cat")
    .spec(),
    @chart.ChartSpec::errorband(
      @chart.field("cat"),
      @chart.field("val"),
      x_error=@chart.field("grp"),
      detail=@chart.field("cat"),
    ),
  )
}

// ── refinement: encode and the chrome setters ───────────────────────

///|
test "plot: encode replaces the given channels and keeps the rest" {
  let df = plot_df()
  // A y rebuilt with an aggregate; x untouched.
  assert_eq(
    @chart.plot(df)
    .bar(x="cat", y="val")
    .encode(y=@chart.field("val", aggregate=Sum))
    .spec(),
    @chart.ChartSpec::bar(
      @chart.field("cat"),
      @chart.field("val", aggregate=Sum),
    ),
  )
  // A channel the mark constructor does not carry — the general
  // constructor spells the same spec.
  assert_eq(
    @chart.plot(df)
    .point(x="cat", y="val")
    .encode(stroke=@chart.field("grp"))
    .spec(),
    @chart.ChartSpec::of(
      Point,
      x=@chart.field("cat"),
      y=@chart.field("val"),
      stroke=@chart.field("grp"),
    ),
  )
}

///|
test "plot: the chrome setters overwrite title, width, and height" {
  let df = plot_df()
  assert_eq(
    @chart.plot(df)
    .bar(x="cat", y="val")
    .title("After")
    .width(@chart.VegaExtent::Px(320))
    .height(@chart.VegaExtent::Container)
    .spec(),
    @chart.ChartSpec::bar(
      @chart.field("cat"),
      @chart.field("val"),
      title="After",
      width=@chart.VegaExtent::Px(320),
      height=@chart.VegaExtent::Container,
    ),
  )
}

// ── hatches: the underlying spec and chart ──────────────────────────

///|
test "plot: chart hands out the single-view Chart" {
  let df = plot_df()
  let spec = @chart.ChartSpec::bar(
    @chart.field("cat"),
    @chart.field("val"),
    title="T",
  )
  assert_eq(
    @chart.plot(df).bar(x="cat", y="val", title="T").chart(),
    @chart.Chart::of(spec),
  )
}

// ── terminals: the format / write functions over the bound frame ────

///|
test "plot: to_json emits the complete Vega-Lite spec" {
  let df = plot_df()
  inspect(
    @chart.plot(df).bar(x="cat", y="val", color="grp", title="T").to_json(),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","title":"T","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"color":{"field":"grp","type":"nominal"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "plot: encode with an aggregate reaches the emitted spec" {
  let df = plot_df()
  inspect(
    @chart.plot(df)
    .bar(x="cat", y="val")
    .encode(y=@chart.field("val", aggregate=Sum))
    .to_json(),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","aggregate":"sum","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "plot: to_json and to_html are the format functions over the frame" {
  let df = plot_df()
  let p = @chart.plot(df).line(x="cat", y="val")
  assert_eq(
    p.to_json(),
    @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")),
      ),
    ),
  )
  assert_eq(
    p.to_html(),
    @chart.format_vega_html(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")),
      ),
    ),
  )
}

///|
test "plot: write_json and write_html round-trip to disk" {
  let df = plot_df()
  let p = @chart.plot(df).bar(x="cat", y="val", title="Disk")
  let json_path = "_build/plot_test_write.json"
  p.write_json(json_path)
  // The file holds exactly what `to_json` produces.
  assert_eq(@fs.read_file_to_string(json_path), p.to_json())
  let html_path = "_build/plot_test_write.html"
  p.write_html(html_path)
  assert_eq(@fs.read_file_to_string(html_path), p.to_html())
}

///|
test "plot: an unknown column raises ColumnNotFound at the terminal" {
  let df = plot_df()
  let result = Ok(@chart.plot(df).bar(x="nope", y="val").to_json()) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ColumnNotFound(_)))
}
