// Blackbox tests for the guide trees: every enum variant emits its exact
// schema string (a table per enum), every family constructor takes a
// kitchen-sink spec with every property set, and every union arm emits its
// own JSON shape — so no emitter branch and no enum arm ships unexercised.
// The corpus test beside this one additionally walks the emitted specs
// against the vendored schema.

///|
/// The fixture frame the guide sinks render against (the corpus frame —
/// one cat / val / grp / ts column set reaches every dtype family).
fn guides_df() -> @frame.DataFrame raise @types.DataError {
  corpus_df()
}

///|
/// One subtree of an emitted spec, navigated by key path and stringified
/// whole. A kitchen-sink assert compares this against the exact expected
/// object, so a misspelled key, a dropped key, or an extra one all turn
/// the assert red — a `contains` check on a short needle passes beside
/// any of those.
fn emitted_subtree(spec : String, path : Array[String]) -> String {
  let parsed = @json.parse(spec) catch { _ => return "<unparseable>" }
  let mut node = parsed
  for key in path {
    node = match node {
      Object(obj) =>
        match obj.get(key) {
          Some(v) => v
          None => return "<missing key: " + key + ">"
        }
      _ => return "<not an object at: " + key + ">"
    }
  }
  node.stringify()
}

///|
test "VegaScale carries every property it declares" {
  let family = @chart.VegaScale::VegaScale(
    type_=@chart.VegaScaleType::Linear,
    domain=@chart.VegaDomain::Unaggregated,
    domain_min=1.5,
    domain_max=1.5,
    domain_mid=1.5,
    range=@chart.VegaRange::Named(@chart.VegaRangeName::Width),
    range_min=@chart.VegaRangeBound::Number(1.5),
    range_max=@chart.VegaRangeBound::Number(1.5),
    scheme=@chart.VegaScheme::Name("blues"),
    reverse=true,
    round=true,
    clamp=true,
    zero=true,
    exponent=1.5,
    base=1.5,
    constant=1.5,
    interpolate=@chart.VegaInterpolate::Kind(@chart.VegaInterpolateKind::Rgb),
    nice=@chart.VegaNice::Bool(true),
    align=1.5,
    padding=1.5,
    padding_inner=1.5,
    padding_outer=1.5,
    bins=@chart.VegaBins::Values([1.0]),
  )
  let spec = @chart.format_vega_lite(
    guides_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        y=@chart.field("val"),
        x=@chart.field("val", scale=Config(family)),
      ),
    ),
  )
  // The whole scale object, key for key — every declared property under
  // its schema key, and nothing else.
  assert_eq(
    emitted_subtree(spec, ["encoding", "x", "scale"]),
    "{\"type\":\"linear\",\"domain\":\"unaggregated\",\"domainMin\":1.5,\"domainMax\":1.5,\"domainMid\":1.5,\"range\":\"width\",\"rangeMin\":1.5,\"rangeMax\":1.5,\"scheme\":\"blues\",\"reverse\":true,\"round\":true,\"clamp\":true,\"zero\":true,\"exponent\":1.5,\"base\":1.5,\"constant\":1.5,\"interpolate\":\"rgb\",\"nice\":true,\"align\":1.5,\"padding\":1.5,\"paddingInner\":1.5,\"paddingOuter\":1.5,\"bins\":[1]}",
  )
}

///|
test "VegaAxis carries every property it declares" {
  let family = @chart.VegaAxis::VegaAxis(
    // `disable` is config-axis-only (the schema's AxisConfig): the
    // channel-side emission drops a set one, which the expected object
    // below pins.
    disable=true,
    aria=true,
    band_position=1.5,
    description="s",
    domain=true,
    domain_cap=@chart.VegaCap::Butt,
    domain_color="s",
    domain_dash=[1.0, 2.0],
    domain_dash_offset=1.5,
    domain_opacity=1.5,
    domain_width=1.5,
    format="s",
    format_type="s",
    grid=true,
    grid_cap=@chart.VegaCap::Butt,
    grid_color="s",
    grid_dash=[1.0, 2.0],
    grid_dash_offset=1.5,
    grid_opacity=1.5,
    grid_width=1.5,
    label_align=@chart.VegaAlign::Left,
    label_angle=1.5,
    label_baseline=@chart.VegaBaseline::Alphabetic,
    label_bound=@chart.VegaLabelBound::Flush,
    label_color="s",
    label_expr="s",
    label_flush=@chart.VegaLabelFlush::Bool(true),
    label_flush_offset=1.5,
    label_font="s",
    label_font_size=1.5,
    label_font_style="s",
    label_font_weight=@chart.VegaFontWeight::Bold,
    label_limit=1.5,
    label_line_height=1.5,
    label_offset=1.5,
    label_opacity=1.5,
    label_overlap=@chart.VegaLabelOverlap::Parity,
    label_padding=1.5,
    label_separation=1.5,
    labels=true,
    max_extent=1.5,
    min_extent=1.5,
    offset=1.5,
    orient=@chart.VegaAxisOrient::Top,
    position=1.5,
    style="s",
    tick_band=@chart.VegaTickBand::Center,
    tick_cap=@chart.VegaCap::Butt,
    tick_color="s",
    tick_count=@chart.VegaTickInterval::Count(5.0),
    tick_dash=[1.0, 2.0],
    tick_dash_offset=1.5,
    tick_extra=true,
    tick_min_step=1.5,
    tick_offset=1.5,
    tick_opacity=1.5,
    tick_round=true,
    tick_size=1.5,
    tick_width=1.5,
    ticks=true,
    title="s",
    title_align=@chart.VegaAlign::Left,
    title_anchor=@chart.VegaAnchor::Start,
    title_angle=1.5,
    title_baseline=@chart.VegaBaseline::Alphabetic,
    title_color="s",
    title_font="s",
    title_font_size=1.5,
    title_font_style="s",
    title_font_weight=@chart.VegaFontWeight::Bold,
    title_limit=1.5,
    title_line_height=1.5,
    title_opacity=1.5,
    title_padding=1.5,
    title_x=1.5,
    title_y=1.5,
    translate=1.5,
    values=[Json::number(1.0), Json::string("a")],
    zindex=1.5,
  )
  let spec = @chart.format_vega_lite(
    guides_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        y=@chart.field("val"),
        x=@chart.field("val", axis=@chart.VegaAxisRef::Config(family)),
      ),
    ),
  )
  // The whole channel-side axis object — every declared property under
  // its schema key, `disable` left out (the config shape alone carries
  // it), and nothing else.
  assert_eq(
    emitted_subtree(spec, ["encoding", "x", "axis"]),
    "{\"aria\":true,\"bandPosition\":1.5,\"description\":\"s\",\"domain\":true,\"domainCap\":\"butt\",\"domainColor\":\"s\",\"domainDash\":[1,2],\"domainDashOffset\":1.5,\"domainOpacity\":1.5,\"domainWidth\":1.5,\"format\":\"s\",\"formatType\":\"s\",\"grid\":true,\"gridCap\":\"butt\",\"gridColor\":\"s\",\"gridDash\":[1,2],\"gridDashOffset\":1.5,\"gridOpacity\":1.5,\"gridWidth\":1.5,\"labelAlign\":\"left\",\"labelAngle\":1.5,\"labelBaseline\":\"alphabetic\",\"labelBound\":\"flush\",\"labelColor\":\"s\",\"labelExpr\":\"s\",\"labelFlush\":true,\"labelFlushOffset\":1.5,\"labelFont\":\"s\",\"labelFontSize\":1.5,\"labelFontStyle\":\"s\",\"labelFontWeight\":\"bold\",\"labelLimit\":1.5,\"labelLineHeight\":1.5,\"labelOffset\":1.5,\"labelOpacity\":1.5,\"labelOverlap\":\"parity\",\"labelPadding\":1.5,\"labelSeparation\":1.5,\"labels\":true,\"maxExtent\":1.5,\"minExtent\":1.5,\"offset\":1.5,\"orient\":\"top\",\"position\":1.5,\"style\":\"s\",\"tickBand\":\"center\",\"tickCap\":\"butt\",\"tickColor\":\"s\",\"tickCount\":5,\"tickDash\":[1,2],\"tickDashOffset\":1.5,\"tickExtra\":true,\"tickMinStep\":1.5,\"tickOffset\":1.5,\"tickOpacity\":1.5,\"tickRound\":true,\"tickSize\":1.5,\"tickWidth\":1.5,\"ticks\":true,\"title\":\"s\",\"titleAlign\":\"left\",\"titleAnchor\":\"start\",\"titleAngle\":1.5,\"titleBaseline\":\"alphabetic\",\"titleColor\":\"s\",\"titleFont\":\"s\",\"titleFontSize\":1.5,\"titleFontStyle\":\"s\",\"titleFontWeight\":\"bold\",\"titleLimit\":1.5,\"titleLineHeight\":1.5,\"titleOpacity\":1.5,\"titlePadding\":1.5,\"titleX\":1.5,\"titleY\":1.5,\"translate\":1.5,\"values\":[1,\"a\"],\"zindex\":1.5}",
  )
}

///|
test "VegaLegend carries every property it declares" {
  let family = @chart.VegaLegend::VegaLegend(
    aria=true,
    clip_height=1.5,
    column_padding=1.5,
    columns=1.5,
    corner_radius=1.5,
    description="s",
    direction=@chart.VegaDirection::Horizontal,
    fill_color="s",
    format="s",
    format_type="s",
    gradient_length=1.5,
    gradient_opacity=1.5,
    gradient_stroke_color="s",
    gradient_stroke_width=1.5,
    gradient_thickness=1.5,
    grid_align=@chart.VegaLayoutAlign::All,
    label_align=@chart.VegaAlign::Left,
    label_baseline=@chart.VegaBaseline::Alphabetic,
    label_color="s",
    label_expr="s",
    label_font="s",
    label_font_size=1.5,
    label_font_style="s",
    label_font_weight=@chart.VegaFontWeight::Bold,
    label_limit=1.5,
    label_offset=1.5,
    label_opacity=1.5,
    label_overlap=@chart.VegaLabelOverlap::Parity,
    label_padding=1.5,
    label_separation=1.5,
    legend_x=1.5,
    legend_y=1.5,
    offset=1.5,
    orient=@chart.VegaLegendOrient::None,
    padding=1.5,
    row_padding=1.5,
    stroke_color="s",
    symbol_dash=[1.0, 2.0],
    symbol_dash_offset=1.5,
    symbol_fill_color="s",
    symbol_limit=1.5,
    symbol_offset=1.5,
    symbol_opacity=1.5,
    symbol_size=1.5,
    symbol_stroke_color="s",
    symbol_stroke_width=1.5,
    symbol_type="s",
    tick_count=@chart.VegaTickInterval::Count(5.0),
    tick_min_step=1.5,
    title="s",
    title_align=@chart.VegaAlign::Left,
    title_anchor=@chart.VegaAnchor::Start,
    title_baseline=@chart.VegaBaseline::Alphabetic,
    title_color="s",
    title_font="s",
    title_font_size=1.5,
    title_font_style="s",
    title_font_weight=@chart.VegaFontWeight::Bold,
    title_limit=1.5,
    title_line_height=1.5,
    title_opacity=1.5,
    title_orient=@chart.VegaTitleOrient::None,
    title_padding=1.5,
    type_=@chart.VegaLegendType::Symbol,
    values=[Json::number(1.0), Json::string("a")],
    zindex=1.5,
  )
  let spec = @chart.format_vega_lite(
    guides_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        color=@chart.field("grp", legend=@chart.VegaLegendRef::Config(family)),
      ),
    ),
  )
  // The whole legend object, key for key.
  assert_eq(
    emitted_subtree(spec, ["encoding", "color", "legend"]),
    "{\"aria\":true,\"clipHeight\":1.5,\"columnPadding\":1.5,\"columns\":1.5,\"cornerRadius\":1.5,\"description\":\"s\",\"direction\":\"horizontal\",\"fillColor\":\"s\",\"format\":\"s\",\"formatType\":\"s\",\"gradientLength\":1.5,\"gradientOpacity\":1.5,\"gradientStrokeColor\":\"s\",\"gradientStrokeWidth\":1.5,\"gradientThickness\":1.5,\"gridAlign\":\"all\",\"labelAlign\":\"left\",\"labelBaseline\":\"alphabetic\",\"labelColor\":\"s\",\"labelExpr\":\"s\",\"labelFont\":\"s\",\"labelFontSize\":1.5,\"labelFontStyle\":\"s\",\"labelFontWeight\":\"bold\",\"labelLimit\":1.5,\"labelOffset\":1.5,\"labelOpacity\":1.5,\"labelOverlap\":\"parity\",\"labelPadding\":1.5,\"labelSeparation\":1.5,\"legendX\":1.5,\"legendY\":1.5,\"offset\":1.5,\"orient\":\"none\",\"padding\":1.5,\"rowPadding\":1.5,\"strokeColor\":\"s\",\"symbolDash\":[1,2],\"symbolDashOffset\":1.5,\"symbolFillColor\":\"s\",\"symbolLimit\":1.5,\"symbolOffset\":1.5,\"symbolOpacity\":1.5,\"symbolSize\":1.5,\"symbolStrokeColor\":\"s\",\"symbolStrokeWidth\":1.5,\"symbolType\":\"s\",\"tickCount\":5,\"tickMinStep\":1.5,\"title\":\"s\",\"titleAlign\":\"left\",\"titleAnchor\":\"start\",\"titleBaseline\":\"alphabetic\",\"titleColor\":\"s\",\"titleFont\":\"s\",\"titleFontSize\":1.5,\"titleFontStyle\":\"s\",\"titleFontWeight\":\"bold\",\"titleLimit\":1.5,\"titleLineHeight\":1.5,\"titleOpacity\":1.5,\"titleOrient\":\"none\",\"titlePadding\":1.5,\"type\":\"symbol\",\"values\":[1,\"a\"],\"zindex\":1.5}",
  )
}

///|
test "VegaTitleParams carries every property it declares" {
  let family = @chart.VegaTitleParams::VegaTitleParams(
    text="s",
    align=@chart.VegaAlign::Left,
    anchor=@chart.VegaAnchor::Start,
    angle=1.5,
    aria=true,
    baseline=@chart.VegaBaseline::Alphabetic,
    color="s",
    dx=1.5,
    dy=1.5,
    font="s",
    font_size=1.5,
    font_style="s",
    font_weight=@chart.VegaFontWeight::Bold,
    frame=@chart.VegaTitleFrame::Bounds,
    limit=1.5,
    line_height=1.5,
    offset=1.5,
    orient=@chart.VegaTitleOrient::None,
    style="s",
    subtitle="s",
    subtitle_color="s",
    subtitle_font="s",
    subtitle_font_size=1.5,
    subtitle_font_style="s",
    subtitle_font_weight=@chart.VegaFontWeight::Bold,
    subtitle_line_height=1.5,
    subtitle_padding=1.5,
    zindex=1.5,
  )
  let spec = @chart.format_vega_lite(
    guides_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        title=@chart.VegaTitle::Params(family),
      ),
    ),
  )
  // The whole title-params object, key for key.
  assert_eq(
    emitted_subtree(spec, ["title"]),
    "{\"text\":\"s\",\"align\":\"left\",\"anchor\":\"start\",\"angle\":1.5,\"aria\":true,\"baseline\":\"alphabetic\",\"color\":\"s\",\"dx\":1.5,\"dy\":1.5,\"font\":\"s\",\"fontSize\":1.5,\"fontStyle\":\"s\",\"fontWeight\":\"bold\",\"frame\":\"bounds\",\"limit\":1.5,\"lineHeight\":1.5,\"offset\":1.5,\"orient\":\"none\",\"style\":\"s\",\"subtitle\":\"s\",\"subtitleColor\":\"s\",\"subtitleFont\":\"s\",\"subtitleFontSize\":1.5,\"subtitleFontStyle\":\"s\",\"subtitleFontWeight\":\"bold\",\"subtitleLineHeight\":1.5,\"subtitlePadding\":1.5,\"zindex\":1.5}",
  )
}

///|
test "VegaViewBackground carries every property it declares" {
  let family = @chart.VegaViewBackground::VegaViewBackground(
    corner_radius=1.5,
    cursor=@chart.VegaCursor::Auto,
    fill="s",
    fill_opacity=1.5,
    opacity=1.5,
    stroke="s",
    stroke_cap=@chart.VegaCap::Butt,
    stroke_dash=[1.0, 2.0],
    stroke_dash_offset=1.5,
    stroke_join=@chart.VegaJoin::Miter,
    stroke_miter_limit=1.5,
    stroke_opacity=1.5,
    stroke_width=1.5,
    style="s",
  )
  let spec = @chart.format_vega_lite(
    guides_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        view=family,
      ),
    ),
  )
  // The whole view-background object, key for key.
  assert_eq(
    emitted_subtree(spec, ["view"]),
    "{\"cornerRadius\":1.5,\"cursor\":\"auto\",\"fill\":\"s\",\"fillOpacity\":1.5,\"opacity\":1.5,\"stroke\":\"s\",\"strokeCap\":\"butt\",\"strokeDash\":[1,2],\"strokeDashOffset\":1.5,\"strokeJoin\":\"miter\",\"strokeMiterLimit\":1.5,\"strokeOpacity\":1.5,\"strokeWidth\":1.5,\"style\":\"s\"}",
  )
}

///|
test "VegaProjection carries every property it declares" {
  let family = @chart.VegaProjection::VegaProjection(
    type_=@chart.VegaProjectionType::Albers,
    center=(1.5, 2.5),
    clip_angle=1.5,
    clip_extent=((1.5, 2.5), (3.5, 4.5)),
    coefficient=1.5,
    distance=1.5,
    extent=((1.5, 2.5), (3.5, 4.5)),
    fraction=1.5,
    lobes=1.5,
    parallel=1.5,
    parallels=[1.0, 2.0],
    point_radius=1.5,
    precision=1.5,
    radius=1.5,
    ratio=1.5,
    reflect_x=true,
    reflect_y=true,
    rotate=@chart.VegaRotate::LonLat(1.0, 2.0),
    scale=1.5,
    size=(1.5, 2.5),
    spacing=1.5,
    tilt=1.5,
    translate=(1.5, 2.5),
  )
  let spec = @chart.format_vega_lite(
    guides_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        projection=family,
      ),
    ),
  )
  // The whole projection object, key for key.
  assert_eq(
    emitted_subtree(spec, ["projection"]),
    "{\"type\":\"albers\",\"center\":[1.5,2.5],\"clipAngle\":1.5,\"clipExtent\":[[1.5,2.5],[3.5,4.5]],\"coefficient\":1.5,\"distance\":1.5,\"extent\":[[1.5,2.5],[3.5,4.5]],\"fraction\":1.5,\"lobes\":1.5,\"parallel\":1.5,\"parallels\":[1,2],\"pointRadius\":1.5,\"precision\":1.5,\"radius\":1.5,\"ratio\":1.5,\"reflectX\":true,\"reflectY\":true,\"rotate\":[1,2],\"scale\":1.5,\"size\":[1.5,2.5],\"spacing\":1.5,\"tilt\":1.5,\"translate\":[1.5,2.5]}",
  )
}
