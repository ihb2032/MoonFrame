// The guide trees' remaining arms: the union forms the kitchen sinks do
// not take, the parameter sub-objects, the array accessors' copy-back
// contract, the bare constructors' unset arms, and every mark-named
// constructor's title wrap. Each assertion goes through
// `format_vega_lite`, so what is covered is what callers receive.

///|
test "a scale carries every union form its properties accept" {
  let df = corpus_df()
  let domain_values = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              domain=@chart.VegaDomain::Values([
                Json::number(1),
                Json::number(2),
              ]),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(domain_values.contains("\"domain\":[1,2]"))
  let domain_unaggregated = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(domain=@chart.VegaDomain::Unaggregated),
          ),
        ),
      ),
    ),
  )
  assert_true(domain_unaggregated.contains("\"domain\":\"unaggregated\""))
  let range_values = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              range=@chart.VegaRange::Values([
                Json::number(0),
                Json::number(100),
              ]),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(range_values.contains("\"range\":[0,100]"))
  let range_named = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              range_min=@chart.VegaRangeBound::Named("category"),
              range_max=@chart.VegaRangeBound::Number(100),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(range_named.contains("\"rangeMin\":\"category\""))
  assert_true(range_named.contains("\"rangeMax\":100"))
  // scheme: the parameter form with extent and count
  let scheme = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              scheme=@chart.VegaScheme::Params(
                @chart.VegaSchemeParams::VegaSchemeParams(
                  name="blues",
                  extent=[0.0, 1.0],
                  count=5.0,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(
    scheme.contains(
      "\"scheme\":{\"name\":\"blues\",\"extent\":[0,1],\"count\":5}",
    ),
  )
  // nice: a tick count, a bare interval, and an interval with a step
  let nice = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(nice=@chart.VegaNice::Ticks(7)),
          ),
        ),
      ),
    ),
  )
  assert_true(nice.contains("\"nice\":7"))
  let nice_interval = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              nice=@chart.VegaNice::Interval(@chart.VegaTimeInterval::Year),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(nice_interval.contains("\"nice\":\"year\""))
  let nice_step = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              nice=@chart.VegaNice::Step(@chart.VegaTimeInterval::Month, 2),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(
    nice_step.contains("\"nice\":{\"interval\":\"month\",\"step\":2}"),
  )
  // interpolate: cubehelix with a gamma; bins: the parameter form
  let interpolate = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              interpolate=@chart.VegaInterpolate::Params(
                @chart.VegaInterpolateParams::VegaInterpolateParams(
                  type_=@chart.VegaInterpolateParamType::Cubehelix,
                  gamma=0.5,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(
    interpolate.contains(
      "\"interpolate\":{\"type\":\"cubehelix\",\"gamma\":0.5}",
    ),
  )
  let bins = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field(
          "val",
          scale=@chart.VegaScaleRef::Config(
            @chart.VegaScale::VegaScale(
              bins=@chart.VegaBins::Params(
                @chart.VegaBinsParams::VegaBinsParams(step=1, start=0, stop=10),
              ),
            ),
          ),
        ),
      ),
    ),
  )
  assert_true(bins.contains("\"bins\":{\"step\":1,\"start\":0,\"stop\":10}"))
}

///|
test "an axis carries the label and tick forms the sink leaves" {
  let df = corpus_df()
  let spec = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          axis=@chart.VegaAxisRef::Config(
            @chart.VegaAxis::VegaAxis(
              label_bound=@chart.VegaLabelBound::Amount(3),
              label_flush=@chart.VegaLabelFlush::Amount(4),
              label_overlap=@chart.VegaLabelOverlap::Bool(false),
              tick_count=@chart.VegaTickInterval::Interval(
                @chart.VegaTimeInterval::Month,
              ),
            ),
          ),
        ),
        y=@chart.field("val"),
      ),
    ),
  )
  assert_true(spec.contains("\"labelBound\":3"))
  assert_true(spec.contains("\"labelFlush\":4"))
  assert_true(spec.contains("\"labelOverlap\":false"))
  assert_true(spec.contains("\"tickCount\":\"month\""))
  let step = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          axis=@chart.VegaAxisRef::Config(
            @chart.VegaAxis::VegaAxis(
              tick_count=@chart.VegaTickInterval::Step(
                @chart.VegaTimeInterval::Month,
                2,
              ),
            ),
          ),
        ),
        y=@chart.field("val"),
      ),
    ),
  )
  assert_true(
    step.contains("\"tickCount\":{\"interval\":\"month\",\"step\":2}"),
  )
  let booleans = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          axis=@chart.VegaAxisRef::Config(
            @chart.VegaAxis::VegaAxis(
              label_bound=@chart.VegaLabelBound::Bool(true),
              label_flush=@chart.VegaLabelFlush::Bool(true),
              label_overlap=@chart.VegaLabelOverlap::Greedy,
            ),
          ),
        ),
        y=@chart.field("val"),
      ),
    ),
  )
  assert_true(booleans.contains("\"labelBound\":true"))
  assert_true(booleans.contains("\"labelFlush\":true"))
  assert_true(booleans.contains("\"labelOverlap\":\"greedy\""))
}

///|
test "every font weight and the roll rotation emit their own shapes" {
  let df = corpus_df()
  let weights = [
    (@chart.VegaFontWeight::Normal, "\"fontWeight\":\"normal\""),
    (@chart.VegaFontWeight::Bolder, "\"fontWeight\":\"bolder\""),
    (@chart.VegaFontWeight::Weight(300), "\"fontWeight\":300"),
  ]
  for w in weights {
    let (weight, expected) = w
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          title=@chart.VegaTitle::Params(
            @chart.VegaTitleParams::VegaTitleParams(
              text="T",
              font_weight=weight,
            ),
          ),
        ),
      ),
    )
    assert_true(spec.contains(expected))
  }
  let lighter = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        title=@chart.VegaTitle::Params(
          @chart.VegaTitleParams::VegaTitleParams(
            text="T",
            subtitle_font_weight=@chart.VegaFontWeight::Lighter,
          ),
        ),
      ),
    ),
  )
  assert_true(lighter.contains("\"subtitleFontWeight\":\"lighter\""))
  let roll = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Geoshape,
        shape=@chart.field("grp"),
        projection=@chart.VegaProjection::VegaProjection(
          rotate=@chart.VegaRotate::LonLatRoll(1.0, 2.0, 3.0),
        ),
      ),
    ),
  )
  assert_true(roll.contains("\"rotate\":[1,2,3]"))
}

///|
test "the guide refs carry Off, and a bare family emits an empty object" {
  let df = corpus_df()
  let off = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          scale=@chart.VegaScaleRef::Off,
          axis=@chart.VegaAxisRef::Off,
        ),
        y=@chart.field("val"),
        color=@chart.field("grp", legend=@chart.VegaLegendRef::Off),
      ),
    ),
  )
  assert_true(off.contains("\"scale\":null"))
  assert_true(off.contains("\"axis\":null"))
  assert_true(off.contains("\"legend\":null"))
  // A family constructed bare emits `{}` for its guide — every property
  // unset is every property at the runtime's default.
  let bare = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field(
          "cat",
          scale=@chart.VegaScaleRef::Config(@chart.VegaScale::VegaScale()),
        ),
        y=@chart.field(
          "val",
          axis=@chart.VegaAxisRef::Config(@chart.VegaAxis::VegaAxis()),
        ),
        color=@chart.field(
          "grp",
          legend=@chart.VegaLegendRef::Config(@chart.VegaLegend::VegaLegend()),
        ),
        projection=@chart.VegaProjection::VegaProjection(),
        view=@chart.VegaViewBackground::VegaViewBackground(),
        title=@chart.VegaTitle::Params(
          @chart.VegaTitleParams::VegaTitleParams(),
        ),
      ),
    ),
  )
  assert_true(bare.contains("\"scale\":{}"))
  assert_true(bare.contains("\"axis\":{}"))
  assert_true(bare.contains("\"legend\":{}"))
  assert_true(bare.contains("\"projection\":{}"))
  assert_true(bare.contains("\"view\":{}"))
}

///|
test "the guide array accessors hand back fresh copies" {
  let dash = [1.0, 2.0]
  let vals = [Json::number(1), Json::string("a")]
  let axis = @chart.VegaAxis::VegaAxis(
    domain_dash=dash,
    grid_dash=dash,
    tick_dash=dash,
    values=vals,
  )
  dash.set(0, 9.0)
  vals.set(0, Json::number(9))
  assert_eq(axis.domain_dash(), Some([1.0, 2.0]))
  assert_eq(axis.grid_dash(), Some([1.0, 2.0]))
  assert_eq(axis.tick_dash(), Some([1.0, 2.0]))
  // values equality is elementwise through the emitted JSON
  assert_eq(axis.values().map(fn(v) { v.length() }), Some(2))
  match axis.values() {
    Some(copy) => {
      copy.set(0, Json::number(9))
      assert_eq(axis.values().map(fn(v) { v.length() }), Some(2))
    }
    None => fail("values accessor returned None")
  }
  // The rest were constructed from the same arrays before the mutation
  // (dash = [9, 2] by now), and each keeps its own copy.
  let legend = @chart.VegaLegend::VegaLegend(symbol_dash=[1.0, 2.0], values=[
    Json::number(1),
    Json::string("a"),
  ])
  assert_eq(legend.symbol_dash(), Some([1.0, 2.0]))
  assert_eq(legend.values().map(fn(v) { v.length() }), Some(2))
  let scheme = @chart.VegaSchemeParams::VegaSchemeParams(name="blues", extent=[
    1.0, 2.0,
  ])
  assert_eq(scheme.extent(), Some([1.0, 2.0]))
  let projection = @chart.VegaProjection::VegaProjection(parallels=[1.0, 2.0])
  assert_eq(projection.parallels(), Some([1.0, 2.0]))
  let view = @chart.VegaViewBackground::VegaViewBackground(stroke_dash=[
    1.0, 2.0,
  ])
  assert_eq(view.stroke_dash(), Some([1.0, 2.0]))
  // A family constructed without its array property reads the property
  // back as unset — the accessors' empty arm.
  let bare_axis = @chart.VegaAxis::VegaAxis()
  assert_eq(bare_axis.domain_dash(), None)
  assert_eq(bare_axis.grid_dash(), None)
  assert_eq(bare_axis.tick_dash(), None)
  assert_eq(bare_axis.values(), None)
  let bare_legend = @chart.VegaLegend::VegaLegend()
  assert_eq(bare_legend.symbol_dash(), None)
  assert_eq(bare_legend.values(), None)
  let bare_scheme = @chart.VegaSchemeParams::VegaSchemeParams()
  assert_eq(bare_scheme.extent(), None)
  let bare_projection = @chart.VegaProjection::VegaProjection()
  assert_eq(bare_projection.parallels(), None)
  let bare_view = @chart.VegaViewBackground::VegaViewBackground()
  assert_eq(bare_view.stroke_dash(), None)
}

///|
test "every mark-named constructor wraps its plain title" {
  let df = corpus_df()
  let specs = [
    @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::line(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::point(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::area(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::tick(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::rect(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::rule(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::circle(
      @chart.field("cat"),
      @chart.field("val"),
      title="T",
    ),
    @chart.ChartSpec::square(
      @chart.field("cat"),
      @chart.field("val"),
      title="T",
    ),
    @chart.ChartSpec::trail(@chart.field("cat"), @chart.field("val"), title="T"),
    @chart.ChartSpec::text(
      @chart.field("cat"),
      @chart.field("val"),
      @chart.field("cat"),
      title="T",
    ),
    @chart.ChartSpec::arc(@chart.field("val"), title="T"),
    @chart.ChartSpec::image(
      @chart.field("cat"),
      @chart.field("val"),
      @chart.field("grp"),
      title="T",
    ),
    @chart.ChartSpec::geoshape(@chart.field("grp"), title="T"),
    @chart.ChartSpec::boxplot(
      @chart.field("cat"),
      @chart.field("val"),
      title="T",
    ),
    @chart.ChartSpec::errorbar(
      @chart.field("cat"),
      @chart.field("val"),
      title="T",
    ),
    @chart.ChartSpec::errorband(
      @chart.field("cat"),
      @chart.field("val"),
      title="T",
    ),
  ]
  for spec in specs {
    assert_true(
      @chart.format_vega_lite(df, @chart.Chart::of(spec)).contains(
        "\"title\":\"T\"",
      ),
    )
  }
}
