// Whitebox tests for the guide enums: the schema-string functions are
// package-private, so the per-variant tables live inside the package. The
// emission itself is additionally walked against the vendored schema by
// the corpus test.

///|
test "each VegaAlign variant emits the schema's own string" {
  let cases = [
    (VegaAlign::Left, "left"),
    (VegaAlign::Center, "center"),
    (VegaAlign::Right, "right"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_align_string(v), expected)
  }
}

///|
test "each VegaBaseline variant emits the schema's own string" {
  let cases = [
    (VegaBaseline::Alphabetic, "alphabetic"),
    (VegaBaseline::Top, "top"),
    (VegaBaseline::Middle, "middle"),
    (VegaBaseline::Bottom, "bottom"),
    (VegaBaseline::LineTop, "line-top"),
    (VegaBaseline::LineBottom, "line-bottom"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_baseline_string(v), expected)
  }
}

///|
test "each VegaAnchor variant emits the schema's own string" {
  let cases = [
    (VegaAnchor::Start, "start"),
    (VegaAnchor::Middle, "middle"),
    (VegaAnchor::End, "end"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_anchor_string(v), expected)
  }
}

///|
test "each VegaAxisOrient variant emits the schema's own string" {
  let cases = [
    (VegaAxisOrient::Top, "top"),
    (VegaAxisOrient::Bottom, "bottom"),
    (VegaAxisOrient::Left, "left"),
    (VegaAxisOrient::Right, "right"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_axis_orient_string(v), expected)
  }
}

///|
test "each VegaLegendOrient variant emits the schema's own string" {
  let cases = [
    (VegaLegendOrient::None, "none"),
    (VegaLegendOrient::Left, "left"),
    (VegaLegendOrient::Right, "right"),
    (VegaLegendOrient::Top, "top"),
    (VegaLegendOrient::Bottom, "bottom"),
    (VegaLegendOrient::TopLeft, "top-left"),
    (VegaLegendOrient::TopRight, "top-right"),
    (VegaLegendOrient::BottomLeft, "bottom-left"),
    (VegaLegendOrient::BottomRight, "bottom-right"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_legend_orient_string(v), expected)
  }
}

///|
test "each VegaTitleOrient variant emits the schema's own string" {
  let cases = [
    (VegaTitleOrient::None, "none"),
    (VegaTitleOrient::Left, "left"),
    (VegaTitleOrient::Right, "right"),
    (VegaTitleOrient::Top, "top"),
    (VegaTitleOrient::Bottom, "bottom"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_title_orient_string(v), expected)
  }
}

///|
test "each VegaCap variant emits the schema's own string" {
  let cases = [
    (VegaCap::Butt, "butt"),
    (VegaCap::Round, "round"),
    (VegaCap::Square, "square"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_cap_string(v), expected)
  }
}

///|
test "each VegaJoin variant emits the schema's own string" {
  let cases = [
    (VegaJoin::Miter, "miter"),
    (VegaJoin::Round, "round"),
    (VegaJoin::Bevel, "bevel"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_join_string(v), expected)
  }
}

///|
test "each VegaLayoutAlign variant emits the schema's own string" {
  let cases = [
    (VegaLayoutAlign::All, "all"),
    (VegaLayoutAlign::Each, "each"),
    (VegaLayoutAlign::None, "none"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_layout_align_string(v), expected)
  }
}

///|
test "each VegaTitleFrame variant emits the schema's own string" {
  let cases = [
    (VegaTitleFrame::Bounds, "bounds"),
    (VegaTitleFrame::Group, "group"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_title_frame_string(v), expected)
  }
}

///|
test "each VegaDirection variant emits the schema's own string" {
  let cases = [
    (VegaDirection::Horizontal, "horizontal"),
    (VegaDirection::Vertical, "vertical"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_direction_string(v), expected)
  }
}

///|
test "each VegaCursor variant emits the schema's own string" {
  let cases = [
    (VegaCursor::Auto, "auto"),
    (VegaCursor::Default, "default"),
    (VegaCursor::None, "none"),
    (VegaCursor::ContextMenu, "context-menu"),
    (VegaCursor::Help, "help"),
    (VegaCursor::Pointer, "pointer"),
    (VegaCursor::Progress, "progress"),
    (VegaCursor::Wait, "wait"),
    (VegaCursor::Cell, "cell"),
    (VegaCursor::Crosshair, "crosshair"),
    (VegaCursor::Text, "text"),
    (VegaCursor::VerticalText, "vertical-text"),
    (VegaCursor::Alias, "alias"),
    (VegaCursor::Copy, "copy"),
    (VegaCursor::Move, "move"),
    (VegaCursor::NoDrop, "no-drop"),
    (VegaCursor::NotAllowed, "not-allowed"),
    (VegaCursor::EResize, "e-resize"),
    (VegaCursor::NResize, "n-resize"),
    (VegaCursor::NeResize, "ne-resize"),
    (VegaCursor::NwResize, "nw-resize"),
    (VegaCursor::SResize, "s-resize"),
    (VegaCursor::SeResize, "se-resize"),
    (VegaCursor::SwResize, "sw-resize"),
    (VegaCursor::WResize, "w-resize"),
    (VegaCursor::EwResize, "ew-resize"),
    (VegaCursor::NsResize, "ns-resize"),
    (VegaCursor::NeswResize, "nesw-resize"),
    (VegaCursor::NwseResize, "nwse-resize"),
    (VegaCursor::ColResize, "col-resize"),
    (VegaCursor::RowResize, "row-resize"),
    (VegaCursor::AllScroll, "all-scroll"),
    (VegaCursor::ZoomIn, "zoom-in"),
    (VegaCursor::ZoomOut, "zoom-out"),
    (VegaCursor::Grab, "grab"),
    (VegaCursor::Grabbing, "grabbing"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_cursor_string(v), expected)
  }
}

///|
test "each VegaScaleType variant emits the schema's own string" {
  let cases = [
    (VegaScaleType::Linear, "linear"),
    (VegaScaleType::Log, "log"),
    (VegaScaleType::Pow, "pow"),
    (VegaScaleType::Sqrt, "sqrt"),
    (VegaScaleType::Symlog, "symlog"),
    (VegaScaleType::Identity, "identity"),
    (VegaScaleType::Sequential, "sequential"),
    (VegaScaleType::Time, "time"),
    (VegaScaleType::Utc, "utc"),
    (VegaScaleType::Quantile, "quantile"),
    (VegaScaleType::Quantize, "quantize"),
    (VegaScaleType::Threshold, "threshold"),
    (VegaScaleType::Bin_ordinal, "bin-ordinal"),
    (VegaScaleType::Ordinal, "ordinal"),
    (VegaScaleType::Point, "point"),
    (VegaScaleType::Band, "band"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_scale_type_string(v), expected)
  }
}

///|
test "each VegaRangeName variant emits the schema's own string" {
  let cases = [
    (VegaRangeName::Width, "width"),
    (VegaRangeName::Height, "height"),
    (VegaRangeName::Symbol, "symbol"),
    (VegaRangeName::Category, "category"),
    (VegaRangeName::Ordinal, "ordinal"),
    (VegaRangeName::Ramp, "ramp"),
    (VegaRangeName::Diverging, "diverging"),
    (VegaRangeName::Heatmap, "heatmap"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_range_name_string(v), expected)
  }
}

///|
test "each VegaTimeInterval variant emits the schema's own string" {
  let cases = [
    (VegaTimeInterval::Millisecond, "millisecond"),
    (VegaTimeInterval::Second, "second"),
    (VegaTimeInterval::Minute, "minute"),
    (VegaTimeInterval::Hour, "hour"),
    (VegaTimeInterval::Day, "day"),
    (VegaTimeInterval::Week, "week"),
    (VegaTimeInterval::Month, "month"),
    (VegaTimeInterval::Year, "year"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_time_interval_string(v), expected)
  }
}

///|
test "each VegaInterpolateKind variant emits the schema's own string" {
  let cases = [
    (VegaInterpolateKind::Rgb, "rgb"),
    (VegaInterpolateKind::Lab, "lab"),
    (VegaInterpolateKind::Hcl, "hcl"),
    (VegaInterpolateKind::Hsl, "hsl"),
    (VegaInterpolateKind::Hsl_long, "hsl-long"),
    (VegaInterpolateKind::Hcl_long, "hcl-long"),
    (VegaInterpolateKind::Cubehelix, "cubehelix"),
    (VegaInterpolateKind::Cubehelix_long, "cubehelix-long"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_interpolate_kind_string(v), expected)
  }
}

///|
test "each VegaTickBand variant emits the schema's own string" {
  let cases = [
    (VegaTickBand::Center, "center"),
    (VegaTickBand::Extent, "extent"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_tick_band_string(v), expected)
  }
}

///|
test "each VegaLegendType variant emits the schema's own string" {
  let cases = [
    (VegaLegendType::Symbol, "symbol"),
    (VegaLegendType::Gradient, "gradient"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_legend_type_string(v), expected)
  }
}

///|
test "each VegaProjectionType variant emits the schema's own string" {
  let cases = [
    (VegaProjectionType::Albers, "albers"),
    (VegaProjectionType::AlbersUsa, "albersUsa"),
    (VegaProjectionType::AzimuthalEqualArea, "azimuthalEqualArea"),
    (VegaProjectionType::AzimuthalEquidistant, "azimuthalEquidistant"),
    (VegaProjectionType::ConicConformal, "conicConformal"),
    (VegaProjectionType::ConicEqualArea, "conicEqualArea"),
    (VegaProjectionType::ConicEquidistant, "conicEquidistant"),
    (VegaProjectionType::EqualEarth, "equalEarth"),
    (VegaProjectionType::Equirectangular, "equirectangular"),
    (VegaProjectionType::Gnomonic, "gnomonic"),
    (VegaProjectionType::Identity, "identity"),
    (VegaProjectionType::Mercator, "mercator"),
    (VegaProjectionType::NaturalEarth1, "naturalEarth1"),
    (VegaProjectionType::Orthographic, "orthographic"),
    (VegaProjectionType::Stereographic, "stereographic"),
    (VegaProjectionType::TransverseMercator, "transverseMercator"),
  ]
  for c in cases {
    let (v, expected) = c
    assert_eq(vega_projection_type_string(v), expected)
  }
}
