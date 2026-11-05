// The config tree: a chart's theme — per-mark style defaults, scale /
// axis / legend / header / title defaults, the view frame, named range
// and style indexes, the composition grid, locale formats, and the
// top-level scalars. Transcribed from the vendored
// vega_lite_v6_5_0.schema.json and schema-walked through the corpus
// guard; reached through `@chart` qualification as part of the deep
// mirror family.
//
// The static arms of the schema's unions are mirrored; expression arms
// (`ExprRef` in place of a value) stay out — a config value is a value.

///|
/// A mark-style block: the shared `MarkConfig` base with the per-mark
/// extras (a bar's `binSpacing` and band sizes, a tick's `thickness`, the
/// line / point toggles) folded in. `config.mark`, every per-mark block
/// (`config.bar` … `config.trail`), the composite-mark sub-parts (a
/// boxplot's box and median, an errorbar's rule and ticks), and
/// `config.style` entries all take this one struct — a property the schema
/// accepts for one mark but not another is the runtime's to reject, not
/// the type's. Every property is optional; the `strokeDash` array is
/// copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaMarkStyle {
  align : VegaAlign?
  angle : Double?
  aria : Bool?
  aria_role : String?
  aria_role_description : String?
  aspect : Bool?
  baseline : VegaBaseline?
  blend : String?
  color : String?
  corner_radius : Double?
  corner_radius_bottom_left : Double?
  corner_radius_bottom_right : Double?
  corner_radius_top_left : Double?
  corner_radius_top_right : Double?
  cursor : VegaCursor?
  description : String?
  dir : String?
  dx : Double?
  dy : Double?
  ellipsis : String?
  end_angle : Double?
  fill : String?
  fill_opacity : Double?
  filled : Bool?
  font : String?
  font_size : Double?
  font_style : String?
  font_weight : VegaFontWeight?
  height : Double?
  href : String?
  inner_radius : Double?
  interpolate : String?
  invalid : String?
  limit : Double?
  line : Bool?
  line_break : String?
  line_height : Double?
  opacity : Double?
  order : Bool?
  orient : VegaOrient?
  outer_radius : Double?
  pad_angle : Double?
  point : String?
  radius : Double?
  radius2 : Double?
  shape : String?
  size : Double?
  smooth : Bool?
  start_angle : Double?
  stroke : String?
  stroke_cap : VegaCap?
  priv stroke_dash : Array[Double]?
  stroke_dash_offset : Double?
  stroke_join : VegaJoin?
  stroke_miter_limit : Double?
  stroke_offset : Double?
  stroke_opacity : Double?
  stroke_width : Double?
  tension : Double?
  text : String?
  theta : Double?
  theta2 : Double?
  time : Double?
  time_unit_band_position : Double?
  time_unit_band_size : Double?
  tooltip : Json?
  url : String?
  width : Double?
  x : Json?
  x2 : Json?
  y : Json?
  y2 : Json?
  bin_spacing : Double?
  continuous_band_size : Double?
  discrete_band_size : Double?
  band_size : Double?
  min_band_size : Double?
  thickness : Double?
}

///|
pub extend VegaMarkStyle with Eq::{equal, not_equal}

///|
pub extend VegaMarkStyle with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaMarkStyle::VegaMarkStyle(
  align? : VegaAlign,
  angle? : Double,
  aria? : Bool,
  aria_role? : String,
  aria_role_description? : String,
  aspect? : Bool,
  baseline? : VegaBaseline,
  blend? : String,
  color? : String,
  corner_radius? : Double,
  corner_radius_bottom_left? : Double,
  corner_radius_bottom_right? : Double,
  corner_radius_top_left? : Double,
  corner_radius_top_right? : Double,
  cursor? : VegaCursor,
  description? : String,
  dir? : String,
  dx? : Double,
  dy? : Double,
  ellipsis? : String,
  end_angle? : Double,
  fill? : String,
  fill_opacity? : Double,
  filled? : Bool,
  font? : String,
  font_size? : Double,
  font_style? : String,
  font_weight? : VegaFontWeight,
  height? : Double,
  href? : String,
  inner_radius? : Double,
  interpolate? : String,
  invalid? : String,
  limit? : Double,
  line? : Bool,
  line_break? : String,
  line_height? : Double,
  opacity? : Double,
  order? : Bool,
  orient? : VegaOrient,
  outer_radius? : Double,
  pad_angle? : Double,
  point? : String,
  radius? : Double,
  radius2? : Double,
  shape? : String,
  size? : Double,
  smooth? : Bool,
  start_angle? : Double,
  stroke? : String,
  stroke_cap? : VegaCap,
  stroke_dash? : Array[Double],
  stroke_dash_offset? : Double,
  stroke_join? : VegaJoin,
  stroke_miter_limit? : Double,
  stroke_offset? : Double,
  stroke_opacity? : Double,
  stroke_width? : Double,
  tension? : Double,
  text? : String,
  theta? : Double,
  theta2? : Double,
  time? : Double,
  time_unit_band_position? : Double,
  time_unit_band_size? : Double,
  tooltip? : Json,
  url? : String,
  width? : Double,
  x? : Json,
  x2? : Json,
  y? : Json,
  y2? : Json,
  bin_spacing? : Double,
  continuous_band_size? : Double,
  discrete_band_size? : Double,
  band_size? : Double,
  min_band_size? : Double,
  thickness? : Double,
) -> VegaMarkStyle {
  {
    align,
    angle,
    aria,
    aria_role,
    aria_role_description,
    aspect,
    baseline,
    blend,
    color,
    corner_radius,
    corner_radius_bottom_left,
    corner_radius_bottom_right,
    corner_radius_top_left,
    corner_radius_top_right,
    cursor,
    description,
    dir,
    dx,
    dy,
    ellipsis,
    end_angle,
    fill,
    fill_opacity,
    filled,
    font,
    font_size,
    font_style,
    font_weight,
    height,
    href,
    inner_radius,
    interpolate,
    invalid,
    limit,
    line,
    line_break,
    line_height,
    opacity,
    order,
    orient,
    outer_radius,
    pad_angle,
    point,
    radius,
    radius2,
    shape,
    size,
    smooth,
    start_angle,
    stroke,
    stroke_cap,
    stroke_dash: match stroke_dash {
      Some(a) => Some(a.copy())
      None => None
    },
    stroke_dash_offset,
    stroke_join,
    stroke_miter_limit,
    stroke_offset,
    stroke_opacity,
    stroke_width,
    tension,
    text,
    theta,
    theta2,
    time,
    time_unit_band_position,
    time_unit_band_size,
    tooltip,
    url,
    width,
    x,
    x2,
    y,
    y2,
    bin_spacing,
    continuous_band_size,
    discrete_band_size,
    band_size,
    min_band_size,
    thickness,
  }
}

///|
/// The `stroke_dash` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaMarkStyle::stroke_dash(self : VegaMarkStyle) -> Array[Double]? {
  match self.stroke_dash {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaMarkStyle`, every set property
/// under its schema key.
fn vega_mark_style_emit_json(x : VegaMarkStyle) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.align is Some(v) {
    obj["align"] = Json::string(vega_align_string(v))
  }
  if x.angle is Some(v) {
    obj["angle"] = Json::number(v)
  }
  if x.aria is Some(v) {
    obj["aria"] = Json::boolean(v)
  }
  if x.aria_role is Some(v) {
    obj["ariaRole"] = Json::string(v)
  }
  if x.aria_role_description is Some(v) {
    obj["ariaRoleDescription"] = Json::string(v)
  }
  if x.aspect is Some(v) {
    obj["aspect"] = Json::boolean(v)
  }
  if x.baseline is Some(v) {
    obj["baseline"] = Json::string(vega_baseline_string(v))
  }
  if x.blend is Some(v) {
    obj["blend"] = Json::string(v)
  }
  if x.color is Some(v) {
    obj["color"] = Json::string(v)
  }
  if x.corner_radius is Some(v) {
    obj["cornerRadius"] = Json::number(v)
  }
  if x.corner_radius_bottom_left is Some(v) {
    obj["cornerRadiusBottomLeft"] = Json::number(v)
  }
  if x.corner_radius_bottom_right is Some(v) {
    obj["cornerRadiusBottomRight"] = Json::number(v)
  }
  if x.corner_radius_top_left is Some(v) {
    obj["cornerRadiusTopLeft"] = Json::number(v)
  }
  if x.corner_radius_top_right is Some(v) {
    obj["cornerRadiusTopRight"] = Json::number(v)
  }
  if x.cursor is Some(v) {
    obj["cursor"] = Json::string(vega_cursor_string(v))
  }
  if x.description is Some(v) {
    obj["description"] = Json::string(v)
  }
  if x.dir is Some(v) {
    obj["dir"] = Json::string(v)
  }
  if x.dx is Some(v) {
    obj["dx"] = Json::number(v)
  }
  if x.dy is Some(v) {
    obj["dy"] = Json::number(v)
  }
  if x.ellipsis is Some(v) {
    obj["ellipsis"] = Json::string(v)
  }
  if x.end_angle is Some(v) {
    obj["endAngle"] = Json::number(v)
  }
  if x.fill is Some(v) {
    obj["fill"] = Json::string(v)
  }
  if x.fill_opacity is Some(v) {
    obj["fillOpacity"] = Json::number(v)
  }
  if x.filled is Some(v) {
    obj["filled"] = Json::boolean(v)
  }
  if x.font is Some(v) {
    obj["font"] = Json::string(v)
  }
  if x.font_size is Some(v) {
    obj["fontSize"] = Json::number(v)
  }
  if x.font_style is Some(v) {
    obj["fontStyle"] = Json::string(v)
  }
  if x.font_weight is Some(v) {
    obj["fontWeight"] = vega_font_weight_emit_json(v)
  }
  if x.height is Some(v) {
    obj["height"] = Json::number(v)
  }
  if x.href is Some(v) {
    obj["href"] = Json::string(v)
  }
  if x.inner_radius is Some(v) {
    obj["innerRadius"] = Json::number(v)
  }
  if x.interpolate is Some(v) {
    obj["interpolate"] = Json::string(v)
  }
  if x.invalid is Some(v) {
    obj["invalid"] = Json::string(v)
  }
  if x.limit is Some(v) {
    obj["limit"] = Json::number(v)
  }
  if x.line is Some(v) {
    obj["line"] = Json::boolean(v)
  }
  if x.line_break is Some(v) {
    obj["lineBreak"] = Json::string(v)
  }
  if x.line_height is Some(v) {
    obj["lineHeight"] = Json::number(v)
  }
  if x.opacity is Some(v) {
    obj["opacity"] = Json::number(v)
  }
  if x.order is Some(v) {
    obj["order"] = Json::boolean(v)
  }
  if x.orient is Some(v) {
    obj["orient"] = Json::string(vega_orient_string(v))
  }
  if x.outer_radius is Some(v) {
    obj["outerRadius"] = Json::number(v)
  }
  if x.pad_angle is Some(v) {
    obj["padAngle"] = Json::number(v)
  }
  if x.point is Some(v) {
    obj["point"] = Json::string(v)
  }
  if x.radius is Some(v) {
    obj["radius"] = Json::number(v)
  }
  if x.radius2 is Some(v) {
    obj["radius2"] = Json::number(v)
  }
  if x.shape is Some(v) {
    obj["shape"] = Json::string(v)
  }
  if x.size is Some(v) {
    obj["size"] = Json::number(v)
  }
  if x.smooth is Some(v) {
    obj["smooth"] = Json::boolean(v)
  }
  if x.start_angle is Some(v) {
    obj["startAngle"] = Json::number(v)
  }
  if x.stroke is Some(v) {
    obj["stroke"] = Json::string(v)
  }
  if x.stroke_cap is Some(v) {
    obj["strokeCap"] = Json::string(vega_cap_string(v))
  }
  if x.stroke_dash is Some(v) {
    obj["strokeDash"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.stroke_dash_offset is Some(v) {
    obj["strokeDashOffset"] = Json::number(v)
  }
  if x.stroke_join is Some(v) {
    obj["strokeJoin"] = Json::string(vega_join_string(v))
  }
  if x.stroke_miter_limit is Some(v) {
    obj["strokeMiterLimit"] = Json::number(v)
  }
  if x.stroke_offset is Some(v) {
    obj["strokeOffset"] = Json::number(v)
  }
  if x.stroke_opacity is Some(v) {
    obj["strokeOpacity"] = Json::number(v)
  }
  if x.stroke_width is Some(v) {
    obj["strokeWidth"] = Json::number(v)
  }
  if x.tension is Some(v) {
    obj["tension"] = Json::number(v)
  }
  if x.text is Some(v) {
    obj["text"] = Json::string(v)
  }
  if x.theta is Some(v) {
    obj["theta"] = Json::number(v)
  }
  if x.theta2 is Some(v) {
    obj["theta2"] = Json::number(v)
  }
  if x.time is Some(v) {
    obj["time"] = Json::number(v)
  }
  if x.time_unit_band_position is Some(v) {
    obj["timeUnitBandPosition"] = Json::number(v)
  }
  if x.time_unit_band_size is Some(v) {
    obj["timeUnitBandSize"] = Json::number(v)
  }
  if x.tooltip is Some(v) {
    obj["tooltip"] = json_identity(v)
  }
  if x.url is Some(v) {
    obj["url"] = Json::string(v)
  }
  if x.width is Some(v) {
    obj["width"] = Json::number(v)
  }
  if x.x is Some(v) {
    obj["x"] = json_identity(v)
  }
  if x.x2 is Some(v) {
    obj["x2"] = json_identity(v)
  }
  if x.y is Some(v) {
    obj["y"] = json_identity(v)
  }
  if x.y2 is Some(v) {
    obj["y2"] = json_identity(v)
  }
  if x.bin_spacing is Some(v) {
    obj["binSpacing"] = Json::number(v)
  }
  if x.continuous_band_size is Some(v) {
    obj["continuousBandSize"] = Json::number(v)
  }
  if x.discrete_band_size is Some(v) {
    obj["discreteBandSize"] = Json::number(v)
  }
  if x.band_size is Some(v) {
    obj["bandSize"] = Json::number(v)
  }
  if x.min_band_size is Some(v) {
    obj["minBandSize"] = Json::number(v)
  }
  if x.thickness is Some(v) {
    obj["thickness"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The view frame's defaults: the continuous / discrete default sizes and
/// the per-category step, clipping, and the frame's own fill and stroke
/// styling.
#derive(Eq, Debug)
pub struct VegaViewConfig {
  clip : Bool?
  continuous_height : Double?
  continuous_width : Double?
  discrete_height : VegaExtent?
  discrete_width : VegaExtent?
  step : Double?
  corner_radius : Double?
  cursor : VegaCursor?
  fill : String?
  fill_opacity : Double?
  opacity : Double?
  stroke : String?
  stroke_cap : VegaCap?
  priv stroke_dash : Array[Double]?
  stroke_dash_offset : Double?
  stroke_join : VegaJoin?
  stroke_miter_limit : Double?
  stroke_opacity : Double?
  stroke_width : Double?
}

///|
pub extend VegaViewConfig with Eq::{equal, not_equal}

///|
pub extend VegaViewConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaViewConfig::VegaViewConfig(
  clip? : Bool,
  continuous_height? : Double,
  continuous_width? : Double,
  discrete_height? : VegaExtent,
  discrete_width? : VegaExtent,
  step? : Double,
  corner_radius? : Double,
  cursor? : VegaCursor,
  fill? : String,
  fill_opacity? : Double,
  opacity? : Double,
  stroke? : String,
  stroke_cap? : VegaCap,
  stroke_dash? : Array[Double],
  stroke_dash_offset? : Double,
  stroke_join? : VegaJoin,
  stroke_miter_limit? : Double,
  stroke_opacity? : Double,
  stroke_width? : Double,
) -> VegaViewConfig {
  {
    clip,
    continuous_height,
    continuous_width,
    discrete_height,
    discrete_width,
    step,
    corner_radius,
    cursor,
    fill,
    fill_opacity,
    opacity,
    stroke,
    stroke_cap,
    stroke_dash: match stroke_dash {
      Some(a) => Some(a.copy())
      None => None
    },
    stroke_dash_offset,
    stroke_join,
    stroke_miter_limit,
    stroke_opacity,
    stroke_width,
  }
}

///|
/// The `stroke_dash` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaViewConfig::stroke_dash(self : VegaViewConfig) -> Array[Double]? {
  match self.stroke_dash {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaViewConfig`, every set property
/// under its schema key.
fn vega_view_config_emit_json(x : VegaViewConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.clip is Some(v) {
    obj["clip"] = Json::boolean(v)
  }
  if x.continuous_height is Some(v) {
    obj["continuousHeight"] = Json::number(v)
  }
  if x.continuous_width is Some(v) {
    obj["continuousWidth"] = Json::number(v)
  }
  if x.discrete_height is Some(v) {
    obj["discreteHeight"] = extent_json(v)
  }
  if x.discrete_width is Some(v) {
    obj["discreteWidth"] = extent_json(v)
  }
  if x.step is Some(v) {
    obj["step"] = Json::number(v)
  }
  if x.corner_radius is Some(v) {
    obj["cornerRadius"] = Json::number(v)
  }
  if x.cursor is Some(v) {
    obj["cursor"] = Json::string(vega_cursor_string(v))
  }
  if x.fill is Some(v) {
    obj["fill"] = Json::string(v)
  }
  if x.fill_opacity is Some(v) {
    obj["fillOpacity"] = Json::number(v)
  }
  if x.opacity is Some(v) {
    obj["opacity"] = Json::number(v)
  }
  if x.stroke is Some(v) {
    obj["stroke"] = Json::string(v)
  }
  if x.stroke_cap is Some(v) {
    obj["strokeCap"] = Json::string(vega_cap_string(v))
  }
  if x.stroke_dash is Some(v) {
    obj["strokeDash"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.stroke_dash_offset is Some(v) {
    obj["strokeDashOffset"] = Json::number(v)
  }
  if x.stroke_join is Some(v) {
    obj["strokeJoin"] = Json::string(vega_join_string(v))
  }
  if x.stroke_miter_limit is Some(v) {
    obj["strokeMiterLimit"] = Json::number(v)
  }
  if x.stroke_opacity is Some(v) {
    obj["strokeOpacity"] = Json::number(v)
  }
  if x.stroke_width is Some(v) {
    obj["strokeWidth"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The scale engine's defaults: padding and size ranges per mark family,
/// the min / max clamps the runtime applies when a scale's range is
/// unspecified, rounding, and animation hints.
#derive(Eq, Debug)
pub struct VegaScaleConfig {
  animation_duration : Double?
  band_padding_inner : Double?
  band_padding_outer : Double?
  band_with_nested_offset_padding_inner : Double?
  band_with_nested_offset_padding_outer : Double?
  bar_band_padding_inner : Double?
  clamp : Bool?
  continuous_padding : Double?
  frames_per_second : Double?
  invalid : Bool?
  max_band_size : Double?
  max_font_size : Double?
  max_opacity : Double?
  max_size : Double?
  max_stroke_width : Double?
  min_band_size : Double?
  min_font_size : Double?
  min_opacity : Double?
  min_size : Double?
  min_stroke_width : Double?
  offset_band_padding_inner : Double?
  offset_band_padding_outer : Double?
  point_padding : Double?
  quantile_count : Double?
  quantize_count : Double?
  rect_band_padding_inner : Double?
  round : Bool?
  tick_band_padding_inner : Double?
  use_unaggregated_domain : Bool?
  x_reverse : Bool?
  zero : Bool?
}

///|
pub extend VegaScaleConfig with Eq::{equal, not_equal}

///|
pub extend VegaScaleConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaScaleConfig::VegaScaleConfig(
  animation_duration? : Double,
  band_padding_inner? : Double,
  band_padding_outer? : Double,
  band_with_nested_offset_padding_inner? : Double,
  band_with_nested_offset_padding_outer? : Double,
  bar_band_padding_inner? : Double,
  clamp? : Bool,
  continuous_padding? : Double,
  frames_per_second? : Double,
  invalid? : Bool,
  max_band_size? : Double,
  max_font_size? : Double,
  max_opacity? : Double,
  max_size? : Double,
  max_stroke_width? : Double,
  min_band_size? : Double,
  min_font_size? : Double,
  min_opacity? : Double,
  min_size? : Double,
  min_stroke_width? : Double,
  offset_band_padding_inner? : Double,
  offset_band_padding_outer? : Double,
  point_padding? : Double,
  quantile_count? : Double,
  quantize_count? : Double,
  rect_band_padding_inner? : Double,
  round? : Bool,
  tick_band_padding_inner? : Double,
  use_unaggregated_domain? : Bool,
  x_reverse? : Bool,
  zero? : Bool,
) -> VegaScaleConfig {
  {
    animation_duration,
    band_padding_inner,
    band_padding_outer,
    band_with_nested_offset_padding_inner,
    band_with_nested_offset_padding_outer,
    bar_band_padding_inner,
    clamp,
    continuous_padding,
    frames_per_second,
    invalid,
    max_band_size,
    max_font_size,
    max_opacity,
    max_size,
    max_stroke_width,
    min_band_size,
    min_font_size,
    min_opacity,
    min_size,
    min_stroke_width,
    offset_band_padding_inner,
    offset_band_padding_outer,
    point_padding,
    quantile_count,
    quantize_count,
    rect_band_padding_inner,
    round,
    tick_band_padding_inner,
    use_unaggregated_domain,
    x_reverse,
    zero,
  }
}

///|
/// The emitted JSON object of a `VegaScaleConfig`, every set property
/// under its schema key.
fn vega_scale_config_emit_json(x : VegaScaleConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.animation_duration is Some(v) {
    obj["animationDuration"] = Json::number(v)
  }
  if x.band_padding_inner is Some(v) {
    obj["bandPaddingInner"] = Json::number(v)
  }
  if x.band_padding_outer is Some(v) {
    obj["bandPaddingOuter"] = Json::number(v)
  }
  if x.band_with_nested_offset_padding_inner is Some(v) {
    obj["bandWithNestedOffsetPaddingInner"] = Json::number(v)
  }
  if x.band_with_nested_offset_padding_outer is Some(v) {
    obj["bandWithNestedOffsetPaddingOuter"] = Json::number(v)
  }
  if x.bar_band_padding_inner is Some(v) {
    obj["barBandPaddingInner"] = Json::number(v)
  }
  if x.clamp is Some(v) {
    obj["clamp"] = Json::boolean(v)
  }
  if x.continuous_padding is Some(v) {
    obj["continuousPadding"] = Json::number(v)
  }
  if x.frames_per_second is Some(v) {
    obj["framesPerSecond"] = Json::number(v)
  }
  if x.invalid is Some(v) {
    obj["invalid"] = Json::boolean(v)
  }
  if x.max_band_size is Some(v) {
    obj["maxBandSize"] = Json::number(v)
  }
  if x.max_font_size is Some(v) {
    obj["maxFontSize"] = Json::number(v)
  }
  if x.max_opacity is Some(v) {
    obj["maxOpacity"] = Json::number(v)
  }
  if x.max_size is Some(v) {
    obj["maxSize"] = Json::number(v)
  }
  if x.max_stroke_width is Some(v) {
    obj["maxStrokeWidth"] = Json::number(v)
  }
  if x.min_band_size is Some(v) {
    obj["minBandSize"] = Json::number(v)
  }
  if x.min_font_size is Some(v) {
    obj["minFontSize"] = Json::number(v)
  }
  if x.min_opacity is Some(v) {
    obj["minOpacity"] = Json::number(v)
  }
  if x.min_size is Some(v) {
    obj["minSize"] = Json::number(v)
  }
  if x.min_stroke_width is Some(v) {
    obj["minStrokeWidth"] = Json::number(v)
  }
  if x.offset_band_padding_inner is Some(v) {
    obj["offsetBandPaddingInner"] = Json::number(v)
  }
  if x.offset_band_padding_outer is Some(v) {
    obj["offsetBandPaddingOuter"] = Json::number(v)
  }
  if x.point_padding is Some(v) {
    obj["pointPadding"] = Json::number(v)
  }
  if x.quantile_count is Some(v) {
    obj["quantileCount"] = Json::number(v)
  }
  if x.quantize_count is Some(v) {
    obj["quantizeCount"] = Json::number(v)
  }
  if x.rect_band_padding_inner is Some(v) {
    obj["rectBandPaddingInner"] = Json::number(v)
  }
  if x.round is Some(v) {
    obj["round"] = Json::boolean(v)
  }
  if x.tick_band_padding_inner is Some(v) {
    obj["tickBandPaddingInner"] = Json::number(v)
  }
  if x.use_unaggregated_domain is Some(v) {
    obj["useUnaggregatedDomain"] = Json::boolean(v)
  }
  if x.x_reverse is Some(v) {
    obj["xReverse"] = Json::boolean(v)
  }
  if x.zero is Some(v) {
    obj["zero"] = Json::boolean(v)
  }
  Json::object(obj)
}

///|
/// The composition grid defaults: the wrap column count and the sub-view spacing.
#derive(Eq, Debug)
pub struct VegaCompositionConfig {
  columns : Double?
  spacing : Double?
}

///|
pub extend VegaCompositionConfig with Eq::{equal, not_equal}

///|
pub extend VegaCompositionConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaCompositionConfig::VegaCompositionConfig(
  columns? : Double,
  spacing? : Double,
) -> VegaCompositionConfig {
  { columns, spacing, }
}

///|
/// The emitted JSON object of a `VegaCompositionConfig`, every set property
/// under its schema key.
fn vega_composition_config_emit_json(x : VegaCompositionConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.columns is Some(v) {
    obj["columns"] = Json::number(v)
  }
  if x.spacing is Some(v) {
    obj["spacing"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The selection defaults: a point and / or interval trigger whose properties every selection of that kind inherits.
#derive(Eq, Debug)
pub struct VegaSelectionConfig {
  point : VegaPointSelect?
  interval : VegaIntervalSelect?
}

///|
pub extend VegaSelectionConfig with Eq::{equal, not_equal}

///|
pub extend VegaSelectionConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaSelectionConfig::VegaSelectionConfig(
  point? : VegaPointSelect,
  interval? : VegaIntervalSelect,
) -> VegaSelectionConfig {
  { point, interval, }
}

///|
/// The emitted JSON object of a `VegaSelectionConfig`, every set property
/// under its schema key.
fn vega_selection_config_emit_json(x : VegaSelectionConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.point is Some(v) {
    obj["point"] = vega_point_select_emit_json(v)
  }
  if x.interval is Some(v) {
    obj["interval"] = vega_interval_select_emit_json(v)
  }
  Json::object(obj)
}

///|
/// The named ranges: the color lists the `category` / `ordinal` / `ramp` /
/// `diverging` / `heatmap` range names resolve to, and the symbol shapes.
/// The lists are copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaRangeConfig {
  priv category : Array[String]?
  priv ordinal : Array[String]?
  priv ramp : Array[String]?
  priv diverging : Array[String]?
  priv heatmap : Array[String]?
  priv symbol : Array[String]?
}

///|
pub extend VegaRangeConfig with Eq::{equal, not_equal}

///|
pub extend VegaRangeConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaRangeConfig::VegaRangeConfig(
  category? : Array[String],
  ordinal? : Array[String],
  ramp? : Array[String],
  diverging? : Array[String],
  heatmap? : Array[String],
  symbol? : Array[String],
) -> VegaRangeConfig {
  {
    category: match category {
      Some(a) => Some(a.copy())
      None => None
    },
    ordinal: match ordinal {
      Some(a) => Some(a.copy())
      None => None
    },
    ramp: match ramp {
      Some(a) => Some(a.copy())
      None => None
    },
    diverging: match diverging {
      Some(a) => Some(a.copy())
      None => None
    },
    heatmap: match heatmap {
      Some(a) => Some(a.copy())
      None => None
    },
    symbol: match symbol {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The category color list, copied.
pub fn VegaRangeConfig::category(self : VegaRangeConfig) -> Array[String]? {
  match self.category {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The ordinal color list, copied.
pub fn VegaRangeConfig::ordinal(self : VegaRangeConfig) -> Array[String]? {
  match self.ordinal {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The ramp color list, copied.
pub fn VegaRangeConfig::ramp(self : VegaRangeConfig) -> Array[String]? {
  match self.ramp {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The diverging color list, copied.
pub fn VegaRangeConfig::diverging(self : VegaRangeConfig) -> Array[String]? {
  match self.diverging {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The heatmap color list, copied.
pub fn VegaRangeConfig::heatmap(self : VegaRangeConfig) -> Array[String]? {
  match self.heatmap {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The symbol list, copied.
pub fn VegaRangeConfig::symbol(self : VegaRangeConfig) -> Array[String]? {
  match self.symbol {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaRangeConfig`, every set property
/// under its schema key.
fn vega_range_config_emit_json(x : VegaRangeConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.category is Some(v) {
    obj["category"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.ordinal is Some(v) {
    obj["ordinal"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.ramp is Some(v) {
    obj["ramp"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.diverging is Some(v) {
    obj["diverging"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.heatmap is Some(v) {
    obj["heatmap"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  if x.symbol is Some(v) {
    obj["symbol"] = Json::array(v.map(fn(f) { Json::string(f) }))
  }
  Json::object(obj)
}

///|
/// The number / time formatting locales, as the locale definition objects the runtime consumes.
#derive(Eq, Debug)
pub struct VegaLocaleConfig {
  number : Json?
  time : Json?
}

///|
pub extend VegaLocaleConfig with Eq::{equal, not_equal}

///|
pub extend VegaLocaleConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaLocaleConfig::VegaLocaleConfig(
  number? : Json,
  time? : Json,
) -> VegaLocaleConfig {
  { number, time, }
}

///|
/// The emitted JSON object of a `VegaLocaleConfig`, every set property
/// under its schema key.
fn vega_locale_config_emit_json(x : VegaLocaleConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.number is Some(v) {
    obj["number"] = json_identity(v)
  }
  if x.time is Some(v) {
    obj["time"] = json_identity(v)
  }
  Json::object(obj)
}

///|
/// The default number / time format patterns and their format types.
#derive(Eq, Debug)
pub struct VegaFormatConfig {
  number_format : String?
  number_format_type : String?
  normalized_number_format : String?
  normalized_number_format_type : String?
  time_format : String?
  time_format_type : String?
}

///|
pub extend VegaFormatConfig with Eq::{equal, not_equal}

///|
pub extend VegaFormatConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaFormatConfig::VegaFormatConfig(
  number_format? : String,
  number_format_type? : String,
  normalized_number_format? : String,
  normalized_number_format_type? : String,
  time_format? : String,
  time_format_type? : String,
) -> VegaFormatConfig {
  {
    number_format,
    number_format_type,
    normalized_number_format,
    normalized_number_format_type,
    time_format,
    time_format_type,
  }
}

///|
/// The emitted JSON object of a `VegaFormatConfig`, every set property
/// under its schema key.
fn vega_format_config_emit_json(x : VegaFormatConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.number_format is Some(v) {
    obj["numberFormat"] = Json::string(v)
  }
  if x.number_format_type is Some(v) {
    obj["numberFormatType"] = Json::string(v)
  }
  if x.normalized_number_format is Some(v) {
    obj["normalizedNumberFormat"] = Json::string(v)
  }
  if x.normalized_number_format_type is Some(v) {
    obj["normalizedNumberFormatType"] = Json::string(v)
  }
  if x.time_format is Some(v) {
    obj["timeFormat"] = Json::string(v)
  }
  if x.time_format_type is Some(v) {
    obj["timeFormatType"] = Json::string(v)
  }
  Json::object(obj)
}

///|
/// The boxplot defaults: the whisker extent, the box / median / outlier / rule / tick styles, and the box size.
#derive(Eq, Debug)
pub struct VegaBoxPlotConfig {
  extent : Json?
  box : VegaMarkStyle?
  median : VegaMarkStyle?
  outliers : VegaMarkStyle?
  rule : VegaMarkStyle?
  ticks : VegaMarkStyle?
  size : Double?
}

///|
pub extend VegaBoxPlotConfig with Eq::{equal, not_equal}

///|
pub extend VegaBoxPlotConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaBoxPlotConfig::VegaBoxPlotConfig(
  extent? : Json,
  box? : VegaMarkStyle,
  median? : VegaMarkStyle,
  outliers? : VegaMarkStyle,
  rule? : VegaMarkStyle,
  ticks? : VegaMarkStyle,
  size? : Double,
) -> VegaBoxPlotConfig {
  { extent, box, median, outliers, rule, ticks, size, }
}

///|
/// The emitted JSON object of a `VegaBoxPlotConfig`, every set property
/// under its schema key.
fn vega_box_plot_config_emit_json(x : VegaBoxPlotConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.extent is Some(v) {
    obj["extent"] = json_identity(v)
  }
  if x.box is Some(v) {
    obj["box"] = vega_mark_style_emit_json(v)
  }
  if x.median is Some(v) {
    obj["median"] = vega_mark_style_emit_json(v)
  }
  if x.outliers is Some(v) {
    obj["outliers"] = vega_mark_style_emit_json(v)
  }
  if x.rule is Some(v) {
    obj["rule"] = vega_mark_style_emit_json(v)
  }
  if x.ticks is Some(v) {
    obj["ticks"] = vega_mark_style_emit_json(v)
  }
  if x.size is Some(v) {
    obj["size"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The errorbar defaults: the extent, the rule and tick styles, and the sizes.
#derive(Eq, Debug)
pub struct VegaErrorBarConfig {
  extent : Json?
  rule : VegaMarkStyle?
  ticks : VegaMarkStyle?
  size : Double?
  thickness : Double?
}

///|
pub extend VegaErrorBarConfig with Eq::{equal, not_equal}

///|
pub extend VegaErrorBarConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaErrorBarConfig::VegaErrorBarConfig(
  extent? : Json,
  rule? : VegaMarkStyle,
  ticks? : VegaMarkStyle,
  size? : Double,
  thickness? : Double,
) -> VegaErrorBarConfig {
  { extent, rule, ticks, size, thickness, }
}

///|
/// The emitted JSON object of a `VegaErrorBarConfig`, every set property
/// under its schema key.
fn vega_error_bar_config_emit_json(x : VegaErrorBarConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.extent is Some(v) {
    obj["extent"] = json_identity(v)
  }
  if x.rule is Some(v) {
    obj["rule"] = vega_mark_style_emit_json(v)
  }
  if x.ticks is Some(v) {
    obj["ticks"] = vega_mark_style_emit_json(v)
  }
  if x.size is Some(v) {
    obj["size"] = Json::number(v)
  }
  if x.thickness is Some(v) {
    obj["thickness"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The errorband defaults: the extent, the band and border styles, the interpolation, and the tension.
#derive(Eq, Debug)
pub struct VegaErrorBandConfig {
  extent : Json?
  band : VegaMarkStyle?
  borders : VegaMarkStyle?
  interpolate : String?
  tension : Double?
}

///|
pub extend VegaErrorBandConfig with Eq::{equal, not_equal}

///|
pub extend VegaErrorBandConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaErrorBandConfig::VegaErrorBandConfig(
  extent? : Json,
  band? : VegaMarkStyle,
  borders? : VegaMarkStyle,
  interpolate? : String,
  tension? : Double,
) -> VegaErrorBandConfig {
  { extent, band, borders, interpolate, tension, }
}

///|
/// The emitted JSON object of a `VegaErrorBandConfig`, every set property
/// under its schema key.
fn vega_error_band_config_emit_json(x : VegaErrorBandConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.extent is Some(v) {
    obj["extent"] = json_identity(v)
  }
  if x.band is Some(v) {
    obj["band"] = vega_mark_style_emit_json(v)
  }
  if x.borders is Some(v) {
    obj["borders"] = vega_mark_style_emit_json(v)
  }
  if x.interpolate is Some(v) {
    obj["interpolate"] = Json::string(v)
  }
  if x.tension is Some(v) {
    obj["tension"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// The JSON of a point trigger's config form.
fn vega_point_select_emit_json(p : VegaPointSelect) -> Json {
  vega_select_emit_json(Point(p))
}

///|
/// The JSON of an interval trigger's config form.
fn vega_interval_select_emit_json(i : VegaIntervalSelect) -> Json {
  vega_select_emit_json(Interval(i))
}
