// Blackbox tests for the config tree: the mark-style union, every
// subtree and scalar the theme carries, the style index, and the
// copy-back contracts. The corpus beside this walks a themed chart
// against the vendored schema.

///|
/// The fixture frame the config tests render against.
fn config_df() -> @frame.DataFrame raise @types.DataError {
  corpus_df()
}

///|
/// One themed chart, carrying one of every subtree and scalar.
fn themed_spec(config : @chart.VegaConfig) -> String raise @types.DataError {
  @chart.format_vega_lite(
    config_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        config~,
      ),
    ),
  )
}

///|
test "a theme carries its scalars and every mark block" {
  let style = @chart.VegaMarkStyle::VegaMarkStyle(
    color="steelblue",
    fill_opacity=0.8,
    stroke_dash=[4.0, 2.0],
    bin_spacing=2,
  )
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      background="#fafafa",
      font="sans-serif",
      count_title="Rows",
      field_title="verbal",
      aria=false,
      line_break="\n",
      mark=style,
      bar=style,
      point=@chart.VegaMarkStyle::VegaMarkStyle(filled=true),
      number_format=".2f",
      time_format="%b %Y",
    ),
  )
  assert_true(spec.contains("\"background\":\"#fafafa\""))
  assert_true(spec.contains("\"font\":\"sans-serif\""))
  assert_true(spec.contains("\"countTitle\":\"Rows\""))
  assert_true(spec.contains("\"fieldTitle\":\"verbal\""))
  assert_true(spec.contains("\"aria\":false"))
  assert_true(spec.contains("\"lineBreak\":\"\\n\""))
  assert_true(spec.contains("\"mark\":{"))
  assert_true(spec.contains("\"binSpacing\":2"))
  assert_true(spec.contains("\"bar\":{"))
  assert_true(spec.contains("\"point\":{\"filled\":true}"))
  assert_true(spec.contains("\"numberFormat\":\".2f\""))
  assert_true(spec.contains("\"timeFormat\":\"%b %Y\""))
}

///|
test "a theme carries its guide, view, and layout subtrees" {
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      scale=@chart.VegaScaleConfig::VegaScaleConfig(
        clamp=true,
        max_font_size=40,
        point_padding=0.5,
      ),
      axis=@chart.VegaAxis::VegaAxis(grid=false),
      axis_x=@chart.VegaAxis::VegaAxis(domain=false),
      axis_quantitative=@chart.VegaAxis::VegaAxis(
        tick_count=@chart.VegaTickInterval::Count(5),
      ),
      legend=@chart.VegaLegendConfig::VegaLegendConfig(
        orient=@chart.VegaLegendOrient::Right,
      ),
      header=@chart.VegaHeader::VegaHeader(label_angle=-30),
      title=@chart.VegaTitleConfig::VegaTitleConfig(
        anchor=@chart.VegaAnchor::End,
      ),
      view=@chart.VegaViewConfig::VegaViewConfig(step=24, fill="#fff", stroke_dash=[
        1.0,
      ]),
      selection=@chart.VegaSelectionConfig::VegaSelectionConfig(
        interval=@chart.VegaIntervalSelect::VegaIntervalSelect(zoom="wheel!"),
      ),
      concat=@chart.VegaCompositionConfig::VegaCompositionConfig(
        columns=2,
        spacing=16,
      ),
      facet=@chart.VegaCompositionConfig::VegaCompositionConfig(spacing=12),
      number_format="d",
    ),
  )
  assert_true(
    spec.contains(
      "\"scale\":{\"clamp\":true,\"maxFontSize\":40,\"pointPadding\":0.5}",
    ),
  )
  assert_true(spec.contains("\"axis\":{\"grid\":false}"))
  assert_true(spec.contains("\"axisX\":{\"domain\":false}"))
  assert_true(spec.contains("\"axisQuantitative\":{\"tickCount\":5}"))
  assert_true(spec.contains("\"legend\":{\"orient\":\"right\"}"))
  assert_true(spec.contains("\"header\":{\"labelAngle\":-30}"))
  assert_true(spec.contains("\"title\":{\"anchor\":\"end\"}"))
  assert_true(spec.contains("\"numberFormat\":\"d\""))
  assert_true(spec.contains("\"step\":24"))
  assert_true(spec.contains("\"zoom\":\"wheel!\""))
  assert_true(spec.contains("\"concat\":{\"columns\":2,\"spacing\":16}"))
  assert_true(spec.contains("\"facet\":{\"spacing\":12}"))
}

///|
test "a theme carries its composite marks, ranges, style index, locale" {
  let styles : Map[String, @chart.VegaMarkStyle] = Map([])
  styles["cell"] = @chart.VegaMarkStyle::VegaMarkStyle(stroke="#ddd")
  let style = styles
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      boxplot=@chart.VegaBoxPlotConfig::VegaBoxPlotConfig(
        extent="min-max",
        size=14,
        median=@chart.VegaMarkStyle::VegaMarkStyle(color="black"),
      ),
      errorbar=@chart.VegaErrorBarConfig::VegaErrorBarConfig(thickness=2),
      errorband=@chart.VegaErrorBandConfig::VegaErrorBandConfig(
        interpolate=@chart.VegaMarkInterpolate::Linear,
      ),
      range=@chart.VegaRangeConfig::VegaRangeConfig(
        category=["#1f77b4", "#ff7f0e"],
        ramp=["#fff", "#000"],
      ),
      style~,
      locale=@chart.VegaLocaleConfig::VegaLocaleConfig(
        number=Json::object({ "decimal": Json::string(",") }),
      ),
      projection=@chart.VegaProjection::VegaProjection(
        type_=@chart.VegaProjectionType::Mercator,
      ),
      params=[Json::object({ "name": Json::string("p") })],
      tooltip_format=@chart.VegaFormatConfig::VegaFormatConfig(
        number_format=".1f",
      ),
      custom_format_types=true,
    ),
  )
  assert_true(
    spec.contains(
      "\"boxplot\":{\"extent\":\"min-max\",\"median\":{\"color\":\"black\"},\"size\":14}",
    ),
  )
  assert_true(spec.contains("\"errorbar\":{\"thickness\":2}"))
  assert_true(spec.contains("\"errorband\":{\"interpolate\":\"linear\"}"))
  assert_true(spec.contains("\"category\":[\"#1f77b4\",\"#ff7f0e\"]"))
  assert_true(spec.contains("\"style\":{\"cell\":{\"stroke\":\"#ddd\"}}"))
  assert_true(spec.contains("\"decimal\":\",\""))
  assert_true(spec.contains("\"projection\":{\"type\":\"mercator\"}"))
  assert_true(spec.contains("\"params\":[{\"name\":\"p\"}]"))
  assert_true(spec.contains("\"tooltipFormat\":{\"numberFormat\":\".1f\"}"))
  assert_true(spec.contains("\"customFormatTypes\":true"))
}

///|
test "the theme's arrays and style map copy at construction and on read" {
  let dash = [4.0]
  let style = @chart.VegaMarkStyle::VegaMarkStyle(stroke_dash=dash)
  dash.set(0, 9.0)
  assert_eq(style.stroke_dash(), Some([4.0]))
  style.stroke_dash().unwrap().set(0, 9.0)
  assert_eq(style.stroke_dash(), Some([4.0]))
  let style : Map[String, @chart.VegaMarkStyle] = Map([])
  style["cell"] = @chart.VegaMarkStyle::VegaMarkStyle(stroke="#ddd")
  let config = @chart.VegaConfig::VegaConfig(style~)
  style["cell"] = @chart.VegaMarkStyle::VegaMarkStyle(stroke="#000")
  assert_eq(config.style()["cell"].stroke, Some("#ddd"))
  let copied = config.style()
  copied["cell"] = @chart.VegaMarkStyle::VegaMarkStyle(stroke="#111")
  assert_eq(config.style()["cell"].stroke, Some("#ddd"))
  let ps = [Json::number(1)]
  let with_params = @chart.VegaConfig::VegaConfig(params=ps)
  let bare_theme = @chart.VegaConfig::VegaConfig()
  assert_true(bare_theme.params() is None)
  ps.set(0, Json::number(9))
  assert_eq(with_params.params().map(fn(v) { v.length() }), Some(1))
  let ranges = ["a"]
  let rc = @chart.VegaRangeConfig::VegaRangeConfig(category=ranges)
  ranges.set(0, "z")
  assert_eq(rc.category(), Some(["a"]))
  rc.category().unwrap().set(0, "z")
  assert_eq(rc.category(), Some(["a"]))
}

///|
test "a bare theme emits an empty config, and unset stays absent" {
  let bare = themed_spec(@chart.VegaConfig::VegaConfig())
  assert_true(bare.contains("\"config\":{}"))
  let plain = @chart.format_vega_lite(
    config_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
      ),
    ),
  )
  assert_true(!plain.contains("\"config\""))
  assert_true(!plain.contains("\"usermeta\""))
  let meta = @chart.format_vega_lite(
    config_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        usermeta=Json::object({ "owner": Json::string("dashboard") }),
      ),
    ),
  )
  assert_true(meta.contains("\"usermeta\":{\"owner\":\"dashboard\"}"))
}

///|
test "a mark-style block carries its every property" {
  let style = @chart.VegaMarkStyle::VegaMarkStyle(
    align=@chart.VegaAlign::Center,
    angle=15,
    aria=true,
    aria_role="img",
    aria_role_description="a chart",
    aspect=true,
    baseline=@chart.VegaBaseline::Middle,
    blend="multiply",
    color="#333",
    corner_radius=2,
    corner_radius_bottom_left=1,
    corner_radius_bottom_right=1,
    corner_radius_top_left=1,
    corner_radius_top_right=1,
    cursor=@chart.VegaCursor::Pointer,
    description="d",
    dir="ltr",
    dx=1,
    dy=1,
    ellipsis="…",
    end_angle=6,
    fill="#eee",
    fill_opacity=0.5,
    filled=true,
    font="mono",
    font_size=12,
    font_style="italic",
    font_weight=@chart.VegaFontWeight::Bold,
    height=10,
    href="https://example.com",
    inner_radius=4,
    interpolate=@chart.VegaMarkInterpolate::Linear,
    invalid="filter",
    limit=100,
    line=true,
    line_break="\n",
    line_height=14,
    opacity=0.9,
    order=true,
    orient=@chart.VegaOrient::Top,
    outer_radius=20,
    pad_angle=0.1,
    point="transparent",
    radius=8,
    radius2=4,
    shape="circle",
    size=60,
    smooth=true,
    start_angle=0,
    stroke="#000",
    stroke_cap=@chart.VegaCap::Round,
    stroke_dash=[1.0, 2.0],
    stroke_dash_offset=3,
    stroke_join=@chart.VegaJoin::Bevel,
    stroke_miter_limit=2,
    stroke_offset=1,
    stroke_opacity=0.8,
    stroke_width=2,
    tension=0.5,
    text="hello",
    theta=1,
    theta2=2,
    time=3,
    time_unit_band_position=0.5,
    time_unit_band_size=1,
    tooltip=Json::boolean(true),
    url="https://example.com/i.png",
    width=10,
    x=Json::number(1),
    x2=Json::number(2),
    y=Json::number(3),
    y2=Json::number(4),
    bin_spacing=1,
    continuous_band_size=2,
    discrete_band_size=1,
    band_size=3,
    min_band_size=1,
    thickness=2,
  )
  let spec = @chart.format_vega_lite(
    config_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("val"),
        y=@chart.field("val"),
        config=@chart.VegaConfig::VegaConfig(mark=style),
      ),
    ),
  )
  // Spot-check one property from each group; the whole block is one
  // JSON object under "mark".
  for
    needle in [
      "\"align\":\"center\"", "\"angle\":15", "\"aria\":true", "\"ariaRole\":\"img\"",
      "\"ariaRoleDescription\":\"a chart\"", "\"aspect\":true", "\"baseline\":\"middle\"",
      "\"blend\":\"multiply\"", "\"cursor\":\"pointer\"", "\"dir\":\"ltr\"", "\"ellipsis\":\"…\"",
      "\"endAngle\":6", "\"filled\":true", "\"fontWeight\":\"bold\"", "\"href\":\"https://example.com\"",
      "\"innerRadius\":4", "\"interpolate\":\"linear\"", "\"invalid\":\"filter\"",
      "\"line\":true", "\"orient\":\"top\"", "\"outerRadius\":20", "\"padAngle\":0.1",
      "\"point\":\"transparent\"", "\"shape\":\"circle\"", "\"smooth\":true", "\"startAngle\":0",
      "\"strokeCap\":\"round\"", "\"strokeJoin\":\"bevel\"", "\"tension\":0.5", "\"timeUnitBandPosition\":0.5",
      "\"tooltip\":true", "\"binSpacing\":1", "\"bandSize\":3", "\"thickness\":2",
    ] {
    assert_true(spec.contains(needle))
  }
}

///|
test "every config leaf fires: view, scale, range, format, composites" {
  let style = @chart.VegaMarkStyle::VegaMarkStyle()
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      view=@chart.VegaViewConfig::VegaViewConfig(
        clip=true,
        continuous_height=300,
        continuous_width=400,
        discrete_height=@chart.VegaDiscreteSize::Step(20),
        discrete_width=@chart.VegaDiscreteSize::Step(24),
        corner_radius=2,
        cursor=@chart.VegaCursor::Grab,
        fill_opacity=1,
        opacity=1,
        stroke="#000",
        stroke_cap=@chart.VegaCap::Butt,
        stroke_dash=[1.0],
        stroke_dash_offset=1,
        stroke_join=@chart.VegaJoin::Miter,
        stroke_miter_limit=4,
        stroke_opacity=1,
        stroke_width=1,
      ),
      scale=@chart.VegaScaleConfig::VegaScaleConfig(
        animation_duration=500,
        band_padding_inner=0.1,
        band_padding_outer=0.2,
        band_with_nested_offset_padding_inner=0.3,
        band_with_nested_offset_padding_outer=0.4,
        bar_band_padding_inner=0.5,
        continuous_padding=1,
        frames_per_second=60,
        invalid=true,
        max_band_size=100,
        max_opacity=1,
        max_size=200,
        max_stroke_width=10,
        min_band_size=1,
        min_font_size=8,
        min_opacity=0,
        min_size=1,
        min_stroke_width=0,
        offset_band_padding_inner=0.6,
        offset_band_padding_outer=0.7,
        quantile_count=10,
        quantize_count=20,
        rect_band_padding_inner=0.8,
        round=true,
        tick_band_padding_inner=0.9,
        use_unaggregated_domain=true,
        x_reverse=true,
        zero=true,
      ),
      selection=@chart.VegaSelectionConfig::VegaSelectionConfig(
        point=@chart.VegaPointSelect::VegaPointSelect(nearest=true),
      ),
      range=@chart.VegaRangeConfig::VegaRangeConfig(
        ordinal=["o"],
        diverging=["d"],
        heatmap=["h"],
        symbol=["s"],
      ),
      boxplot=@chart.VegaBoxPlotConfig::VegaBoxPlotConfig(
        box=style,
        outliers=style,
        rule=style,
        ticks=style,
        extent=1,
        size=9,
      ),
      errorbar=@chart.VegaErrorBarConfig::VegaErrorBarConfig(
        extent="stdev",
        rule=style,
        ticks=style,
        size=8,
        thickness=1,
      ),
      errorband=@chart.VegaErrorBandConfig::VegaErrorBandConfig(
        extent="ci",
        band=style,
        borders=style,
        tension=0.9,
      ),
      locale=@chart.VegaLocaleConfig::VegaLocaleConfig(
        time=Json::object({ "dateTime": Json::string("%A") }),
      ),
      number_format_type="currency",
      normalized_number_format=".0%",
      normalized_number_format_type="currency",
      time_format="%Y",
      time_format_type="time",
    ),
  )
  for
    needle in [
      "\"clip\":true", "\"continuousHeight\":300", "\"continuousWidth\":400", "\"discreteHeight\":{\"step\":20}",
      "\"discreteWidth\":{\"step\":24}", "\"cornerRadius\":2", "\"cursor\":\"grab\"",
      "\"fillOpacity\":1", "\"opacity\":1", "\"strokeCap\":\"butt\"", "\"strokeDashOffset\":1",
      "\"strokeJoin\":\"miter\"", "\"strokeMiterLimit\":4", "\"strokeOpacity\":1",
      "\"animationDuration\":500", "\"bandPaddingInner\":0.1", "\"bandPaddingOuter\":0.2",
      "\"bandWithNestedOffsetPaddingInner\":0.3", "\"bandWithNestedOffsetPaddingOuter\":0.4",
      "\"barBandPaddingInner\":0.5", "\"continuousPadding\":1", "\"framesPerSecond\":60",
      "\"maxBandSize\":100", "\"maxOpacity\":1", "\"maxSize\":200", "\"maxStrokeWidth\":10",
      "\"minBandSize\":1", "\"minFontSize\":8", "\"minOpacity\":0", "\"minSize\":1",
      "\"minStrokeWidth\":0", "\"offsetBandPaddingInner\":0.6", "\"offsetBandPaddingOuter\":0.7",
      "\"quantileCount\":10", "\"quantizeCount\":20", "\"rectBandPaddingInner\":0.8",
      "\"round\":true", "\"tickBandPaddingInner\":0.9", "\"useUnaggregatedDomain\":true",
      "\"xReverse\":true", "\"zero\":true", "\"point\":{\"nearest\":true}", "\"ordinal\":[\"o\"]",
      "\"diverging\":[\"d\"]", "\"heatmap\":[\"h\"]", "\"symbol\":[\"s\"]", "\"box\":{}",
      "\"outliers\":{}", "\"ticks\":{}", "\"extent\":1", "\"size\":9", "\"extent\":\"stdev\"",
      "\"extent\":\"ci\"", "\"band\":{}", "\"borders\":{}", "\"tension\":0.9", "\"dateTime\":\"%A\"",
      "\"numberFormatType\":\"currency\"", "\"normalizedNumberFormat\":\".0%\"",
      "\"normalizedNumberFormatType\":\"currency\"", "\"timeFormat\":\"%Y\"", "\"timeFormatType\":\"time\"",
    ] {
    assert_true(spec.contains(needle))
  }
}

///|
test "the mark-style leaves the sink left dark all fire" {
  let style = @chart.VegaMarkStyle::VegaMarkStyle(
    height=10,
    href="https://example.com",
    inner_radius=4,
    invalid="filter",
  )
  let spec = themed_spec(@chart.VegaConfig::VegaConfig(point=style))
  assert_true(spec.contains("\"height\":10"))
  assert_true(spec.contains("\"href\":\"https://example.com\""))
  assert_true(spec.contains("\"innerRadius\":4"))
  assert_true(spec.contains("\"invalid\":\"filter\""))
}

///|
test "theme chrome, format leaves, and accessors complete their arms" {
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      autosize=@chart.VegaAutoSize::Fit,
      padding=@chart.VegaPadding::Px(10),
      number_format_type="currency",
      normalized_number_format=".0%",
      normalized_number_format_type="currency",
      time_format="%Y",
      time_format_type="time",
      header_row=@chart.VegaHeader::VegaHeader(labels=false),
      header_column=@chart.VegaHeader::VegaHeader(labels=false),
      header_facet=@chart.VegaHeader::VegaHeader(labels=false),
    ),
  )
  assert_true(spec.contains("\"autosize\":\"fit\""))
  assert_true(spec.contains("\"padding\":10"))
  assert_true(spec.contains("\"headerRow\":{\"labels\":false}"))
  assert_true(spec.contains("\"headerColumn\":{\"labels\":false}"))
  assert_true(spec.contains("\"headerFacet\":{\"labels\":false}"))
  assert_true(spec.contains("\"numberFormatType\":\"currency\""))
  assert_true(spec.contains("\"normalizedNumberFormat\":\".0%\""))
  assert_true(spec.contains("\"normalizedNumberFormatType\":\"currency\""))
  assert_true(spec.contains("\"timeFormat\":\"%Y\""))
  assert_true(spec.contains("\"timeFormatType\":\"time\""))
  // The view's stroke-dash and the range lists read their None arms.
  let bare_view = @chart.VegaViewConfig::VegaViewConfig()
  assert_eq(bare_view.stroke_dash(), None)
  let bare_range = @chart.VegaRangeConfig::VegaRangeConfig()
  assert_eq(bare_range.category(), None)
  assert_eq(bare_range.ordinal(), None)
  assert_eq(bare_range.ramp(), None)
  assert_eq(bare_range.diverging(), None)
  assert_eq(bare_range.heatmap(), None)
  assert_eq(bare_range.symbol(), None)
  // And the set arms of the same accessors copy back.
  let full_range = @chart.VegaRangeConfig::VegaRangeConfig(
    ordinal=["o"],
    ramp=["r"],
    diverging=["d"],
    heatmap=["h"],
    symbol=["s"],
  )
  assert_eq(full_range.ordinal(), Some(["o"]))
  assert_eq(full_range.ramp(), Some(["r"]))
  assert_eq(full_range.diverging(), Some(["d"]))
  assert_eq(full_range.heatmap(), Some(["h"]))
  assert_eq(full_range.symbol(), Some(["s"]))
  let view_dash = @chart.VegaViewConfig::VegaViewConfig(stroke_dash=[2.0])
  assert_eq(view_dash.stroke_dash(), Some([2.0]))
  // A mark style built bare carries no dash and reads None back.
  let bare_style = @chart.VegaMarkStyle::VegaMarkStyle()
  assert_eq(bare_style.stroke_dash(), None)
  // The theme itself takes the cursor-bearing style to fire the
  // cursor-string arm.
  let cursor_style = @chart.VegaMarkStyle::VegaMarkStyle(
    cursor=@chart.VegaCursor::Crosshair,
  )
  let cursor_spec = themed_spec(
    @chart.VegaConfig::VegaConfig(mark=cursor_style),
  )
  assert_true(cursor_spec.contains("\"cursor\":\"crosshair\""))
}

///|
test "the config legend block fires every leaf it carries" {
  let symbol_dash = [2.0]
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      legend=@chart.VegaLegendConfig::VegaLegendConfig(
        aria=true,
        clip_height=20,
        column_padding=4,
        columns=2,
        corner_radius=3,
        description="legend",
        direction=@chart.VegaDirection::Vertical,
        fill_color="#eee",
        gradient_length=100,
        gradient_opacity=0.9,
        gradient_stroke_color="#ccc",
        gradient_stroke_width=1,
        gradient_thickness=20,
        grid_align=@chart.VegaLayoutAlign::Each,
        label_align=@chart.VegaAlign::Left,
        label_baseline=@chart.VegaBaseline::Middle,
        label_color="#333",
        label_font="sans",
        label_font_size=11,
        label_font_style="italic",
        label_font_weight=@chart.VegaFontWeight::Bold,
        label_limit=90,
        label_offset=8,
        label_opacity=0.8,
        label_overlap=@chart.VegaLabelOverlap::Greedy,
        label_padding=2,
        label_separation=6,
        legend_x=1,
        legend_y=2,
        offset=10,
        orient=@chart.VegaLegendOrient::TopRight,
        padding=5,
        row_padding=3,
        stroke_color="#999",
        symbol_dash~,
        symbol_dash_offset=1,
        symbol_fill_color="#fff",
        symbol_limit=30,
        symbol_offset=4,
        symbol_opacity=0.9,
        symbol_size=64,
        symbol_stroke_color="#000",
        symbol_stroke_width=1,
        symbol_type="circle",
        tick_count=@chart.VegaTickInterval::Count(5),
        title="Legend",
        title_align=@chart.VegaAlign::Right,
        title_anchor=@chart.VegaAnchor::End,
        title_baseline=@chart.VegaBaseline::Top,
        title_color="#111",
        title_font="serif",
        title_font_size=13,
        title_font_style="normal",
        title_font_weight=@chart.VegaFontWeight::Weight(400),
        title_limit=100,
        title_line_height=16,
        title_opacity=0.9,
        title_orient=@chart.VegaTitleOrient::Top,
        title_padding=6,
        zindex=3,
      ),
    ),
  )
  for
    needle in [
      "\"aria\":true", "\"clipHeight\":20", "\"columnPadding\":4", "\"columns\":2",
      "\"cornerRadius\":3", "\"description\":\"legend\"", "\"direction\":\"vertical\"",
      "\"fillColor\":\"#eee\"", "\"gradientLength\":100", "\"gradientOpacity\":0.9",
      "\"gradientStrokeColor\":\"#ccc\"", "\"gradientStrokeWidth\":1", "\"gradientThickness\":20",
      "\"gridAlign\":\"each\"", "\"labelAlign\":\"left\"", "\"labelBaseline\":\"middle\"",
      "\"labelColor\":\"#333\"", "\"labelFont\":\"sans\"", "\"labelFontSize\":11",
      "\"labelFontStyle\":\"italic\"", "\"labelFontWeight\":\"bold\"", "\"labelLimit\":90",
      "\"labelOffset\":8", "\"labelOpacity\":0.8", "\"labelOverlap\":\"greedy\"",
      "\"labelPadding\":2", "\"labelSeparation\":6", "\"legendX\":1", "\"legendY\":2",
      "\"offset\":10", "\"orient\":\"top-right\"", "\"padding\":5", "\"rowPadding\":3",
      "\"strokeColor\":\"#999\"", "\"symbolDash\":[2]", "\"symbolDashOffset\":1",
      "\"symbolFillColor\":\"#fff\"", "\"symbolLimit\":30", "\"symbolOffset\":4",
      "\"symbolOpacity\":0.9", "\"symbolSize\":64", "\"symbolStrokeColor\":\"#000\"",
      "\"symbolStrokeWidth\":1", "\"symbolType\":\"circle\"", "\"tickCount\":5",
      "\"title\":\"Legend\"", "\"titleAlign\":\"right\"", "\"titleAnchor\":\"end\"",
      "\"titleBaseline\":\"top\"", "\"titleColor\":\"#111\"", "\"titleFont\":\"serif\"",
      "\"titleFontSize\":13", "\"titleFontStyle\":\"normal\"", "\"titleFontWeight\":400",
      "\"titleLimit\":100", "\"titleLineHeight\":16", "\"titleOpacity\":0.9", "\"titleOrient\":\"top\"",
      "\"titlePadding\":6", "\"zindex\":3",
    ] {
    assert_true(spec.contains(needle))
  }
  // The dash list is copied at construction and copies back on read.
  symbol_dash.set(0, 9)
  let legend = @chart.VegaLegendConfig::VegaLegendConfig(symbol_dash=[1])
  assert_eq(legend.symbol_dash(), Some([1]))
  assert_eq(@chart.VegaLegendConfig::VegaLegendConfig().symbol_dash(), None)
}

///|
test "the config title block fires every leaf it carries" {
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      title=@chart.VegaTitleConfig::VegaTitleConfig(
        align=@chart.VegaAlign::Center,
        anchor=@chart.VegaAnchor::Middle,
        angle=15,
        aria=false,
        baseline=@chart.VegaBaseline::Bottom,
        color="#222",
        dx=1,
        dy=2,
        font="sans",
        font_size=14,
        font_style="italic",
        font_weight=@chart.VegaFontWeight::Bold,
        frame=@chart.VegaTitleFrame::Group,
        limit=120,
        line_height=18,
        offset=8,
        orient=@chart.VegaTitleOrient::Bottom,
        subtitle_color="#666",
        subtitle_font="sans",
        subtitle_font_size=11,
        subtitle_font_style="normal",
        subtitle_font_weight=@chart.VegaFontWeight::Weight(300),
        subtitle_line_height=14,
        subtitle_padding=4,
        zindex=2,
      ),
    ),
  )
  for
    needle in [
      "\"align\":\"center\"", "\"anchor\":\"middle\"", "\"angle\":15", "\"aria\":false",
      "\"baseline\":\"bottom\"", "\"color\":\"#222\"", "\"dx\":1", "\"dy\":2", "\"font\":\"sans\"",
      "\"fontSize\":14", "\"fontStyle\":\"italic\"", "\"fontWeight\":\"bold\"", "\"frame\":\"group\"",
      "\"limit\":120", "\"lineHeight\":18", "\"offset\":8", "\"orient\":\"bottom\"",
      "\"subtitleColor\":\"#666\"", "\"subtitleFont\":\"sans\"", "\"subtitleFontSize\":11",
      "\"subtitleFontStyle\":\"normal\"", "\"subtitleFontWeight\":300", "\"subtitleLineHeight\":14",
      "\"subtitlePadding\":4", "\"zindex\":2",
    ] {
    assert_true(spec.contains(needle))
  }
}

///|
test "the tooltip format block fires every leaf, and a fixed discrete size" {
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      tooltip_format=@chart.VegaFormatConfig::VegaFormatConfig(
        number_format="d",
        number_format_type="currency",
        normalized_number_format=".0%",
        normalized_number_format_type="currency",
        time_format="%Y",
        time_format_type="time",
      ),
      view=@chart.VegaViewConfig::VegaViewConfig(
        discrete_height=@chart.VegaDiscreteSize::Px(200),
      ),
    ),
  )
  assert_true(spec.contains("\"tooltipFormat\":{"))
  assert_true(spec.contains("\"numberFormat\":\"d\""))
  assert_true(spec.contains("\"numberFormatType\":\"currency\""))
  assert_true(spec.contains("\"normalizedNumberFormat\":\".0%\""))
  assert_true(spec.contains("\"normalizedNumberFormatType\":\"currency\""))
  assert_true(spec.contains("\"timeFormat\":\"%Y\""))
  assert_true(spec.contains("\"timeFormatType\":\"time\""))
  assert_true(spec.contains("\"discreteHeight\":200"))
}

///|
test "a theme carries the per-orientation axis keys and the disable flag" {
  // config.axis and its per-orientation keys (axisXBand … axisYTemporal)
  // are the schema's AxisConfig — the one axis shape that carries
  // `disable`.
  let disabled = @chart.VegaAxis::VegaAxis(disable=true, grid=false)
  let spec = themed_spec(
    @chart.VegaConfig::VegaConfig(
      axis=disabled,
      axis_x_band=@chart.VegaAxis::VegaAxis(
        tick_count=@chart.VegaTickInterval::Count(5),
      ),
      axis_x_discrete=@chart.VegaAxis::VegaAxis(labels=false),
      axis_x_point=@chart.VegaAxis::VegaAxis(label_angle=-30),
      axis_x_quantitative=@chart.VegaAxis::VegaAxis(zindex=1),
      axis_x_temporal=@chart.VegaAxis::VegaAxis(format="%Y"),
      axis_y_band=@chart.VegaAxis::VegaAxis(tick_extra=true),
      axis_y_discrete=@chart.VegaAxis::VegaAxis(domain=true),
      axis_y_point=@chart.VegaAxis::VegaAxis(position=2),
      axis_y_quantitative=@chart.VegaAxis::VegaAxis(min_extent=10),
      axis_y_temporal=@chart.VegaAxis::VegaAxis(
        orient=@chart.VegaAxisOrient::Right,
      ),
    ),
  )
  assert_true(spec.contains("\"axis\":{\"disable\":true,\"grid\":false}"))
  for
    needle in [
      "\"axisXBand\":{\"tickCount\":5}", "\"axisXDiscrete\":{\"labels\":false}",
      "\"axisXPoint\":{\"labelAngle\":-30}", "\"axisXQuantitative\":{\"zindex\":1}",
      "\"axisXTemporal\":{\"format\":\"%Y\"}", "\"axisYBand\":{\"tickExtra\":true}",
      "\"axisYDiscrete\":{\"domain\":true}", "\"axisYPoint\":{\"position\":2}", "\"axisYQuantitative\":{\"minExtent\":10}",
      "\"axisYTemporal\":{\"orient\":\"right\"}",
    ] {
    assert_true(spec.contains(needle))
  }
}
