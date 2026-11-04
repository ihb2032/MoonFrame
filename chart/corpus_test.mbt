// The corpus: golden emitted specs, committed under `chart/corpus/`, one
// per feature family of the export. Every run re-emits each spec and
// compares against the committed file, so the corpus cannot fall behind
// the emitter; the guard `.github/scripts/check_vega_corpus.py` then
// walks each committed spec against the vendored Vega-Lite 6.5.0 schema,
// so a key or enum string the schema does not know fails the build. That
// is the machine-checked half of the hand-written mirror's fidelity.
//
// Refresh (after an intended emission change):
//   MOONFRAME_VEGA_CORPUS_REFRESH=1 moon test -p ihb2032/MoonFrame/chart
// then review the corpus diffs the way a snapshot diff is reviewed —
// every changed byte is a change to what callers' charts look like.

///|
/// The frame every corpus spec renders against: the same column set the
/// channel tests use, so a corpus spec can reach any dtype family.
fn corpus_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x", "y"]),
    @series.Series::from_ints("val", [1, 2]),
    @series.Series::from_strings("grp", ["a", "b"]),
    @series.Series::from_timestamp_options("ts", [
      Some(1_704_067_200_000_000L),
      Some(1_704_075_840_000_000L),
    ]),
  ])
}

///|
/// The corpus itself: one spec per feature family, in the order the
/// files are named.
fn corpus_specs() -> Array[(String, @chart.ChartSpec)] {
  [
    (
      "bar_basic.json",
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val"),
        color=@chart.field("grp"),
      ),
    ),
    (
      "chrome_full.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        name="revenue-chart",
        description="Revenue by region",
        title="Revenue",
        autosize=@chart.VegaAutoSize::FitX,
        background="#f8f8f8",
        padding=@chart.VegaPadding::Sides(
          @chart.VegaSides::VegaSides(top=10, left=5),
        ),
        width=@chart.VegaExtent::Px(320),
        height=@chart.VegaExtent::Step(24),
      ),
    ),
    (
      "pie_arc_sum.json",
      @chart.ChartSpec::arc(
        @chart.field("val", aggregate=Sum),
        color=@chart.field("grp"),
      ),
    ),
    (
      "donut_arc.json",
      @chart.ChartSpec::arc(
        @chart.field("val", aggregate=Sum),
        color=@chart.field("grp"),
        radius2=@chart.field("val"),
      ),
    ),
    (
      "histogram_bin_count.json",
      @chart.ChartSpec::bar(
        @chart.field(
          "val",
          bin=@chart.VegaBin::Params(
            @chart.VegaBinParams::VegaBinParams(maxbins=20, extent=(0.0, 3.0)),
          ),
        ),
        @chart.VegaChannel::count(),
      ),
    ),
    (
      "line_timeunit.json",
      @chart.ChartSpec::line(
        @chart.field("ts", time_unit=@chart.VegaTimeUnit::Month),
        @chart.field("val", aggregate=Sum),
      ),
    ),
    (
      "scatter_of_channels.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        x_error=@chart.field("val"),
        x_error2=@chart.field("val"),
        y_error=@chart.field("val"),
        y_error2=@chart.field("val"),
        x_offset=@chart.field("val"),
        y_offset=@chart.field("val"),
        fill=@chart.field("grp"),
        stroke=@chart.field("grp"),
        fill_opacity=@chart.field("val"),
        stroke_opacity=@chart.field("val"),
        stroke_width=@chart.field("val"),
        stroke_dash=@chart.field("val"),
        shape=@chart.field("grp"),
        angle=@chart.field("val"),
        time=@chart.field("ts"),
        href=@chart.field("grp"),
        url=@chart.field("grp"),
        description_channel=@chart.field("grp"),
        key=@chart.field("grp"),
        order=@chart.field("val"),
      ),
    ),
    (
      "errorbar_channels.json",
      @chart.ChartSpec::errorbar(
        @chart.field("cat"),
        @chart.field("val"),
        y_error=@chart.field("val"),
        y_error2=@chart.field("val"),
      ),
    ),
    (
      "geoshape_geojson.json",
      @chart.ChartSpec::geoshape(
        @chart.field("cat", type_override=@chart.VegaType::Geojson),
      ),
    ),
    (
      "image_url.json",
      @chart.ChartSpec::image(
        @chart.field("cat"),
        @chart.field("val"),
        @chart.field("grp"),
      ),
    ),
    (
      "sort_forms.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          sort=@chart.VegaChannelSort::ByChannel(
            @chart.VegaSortChannel::Size,
            Some(true),
          ),
        ),
        y=@chart.field("val"),
        color=@chart.field(
          "grp",
          sort=@chart.VegaChannelSort::ByField(
            "val",
            Some(@chart.VegaSort::Descending),
          ),
        ),
      ),
    ),
    (
      "constant_datum_stack.json",
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          sort=@chart.VegaChannelSort::values([
            Json::string("y"),
            Json::string("x"),
          ]),
        ),
        y=@chart.field("val", stack=@chart.VegaStack::Normalize, format="d"),
        color=@chart.constant(Json::string("steelblue")),
        size=@chart.datum(Json::number(60.0)),
      ),
    ),
    (
      "boxplot_plain.json",
      @chart.ChartSpec::boxplot(@chart.field("cat"), @chart.field("val")),
    ),
  ]
}

///|
test "corpus: every committed spec matches the emitter byte for byte" {
  let df = corpus_df()
  let refresh = @env.get_env_var("MOONFRAME_VEGA_CORPUS_REFRESH") is Some("1")
  for entry in corpus_specs() {
    let (file, spec) = entry
    let emitted = @chart.format_vega_lite(df, spec)
    let path = "chart/corpus/" + file
    if refresh {
      @fs.write_string_to_file(path, emitted)
    } else {
      assert_eq(emitted, @fs.read_file_to_string(path))
    }
  }
  if refresh {
    println(
      "corpus: refreshed — review the diffs, then rerun without the variable",
    )
  }
}
