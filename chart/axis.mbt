// The axis family: a typed mirror of the schema's `Axis` object, transcribed
// from the vendored vega_lite_v6_5_0.schema.json and schema-walked through
// the corpus guard. Reached through `@chart` qualification — part of the
// deep mirror family the facade deliberately does not re-export.
//
// The static arms of the schema's unions are mirrored here; the arms that
// carry expressions, conditions, or parameter references (ExprRef /
// Conditional* / ParameterExtent) land with the params stage, so a union
// whose remaining arm is a plain value exposes that plain value directly
// (a `Double` where the schema says `number | ExprRef`).

///|
/// A label-flush setting: the boolean, or a pixel alignment threshold.
#derive(Eq, Debug)
pub(all) enum VegaLabelFlush {
  Bool(Bool)
  Amount(Double)
}

///|
pub extend VegaLabelFlush with Eq::{equal, not_equal}

///|
pub extend VegaLabelFlush with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_label_flush_emit_json(v : VegaLabelFlush) -> Json {
  match v {
    Bool(b) => Json::boolean(b)
    Amount(n) => Json::number(n)
  }
}

///|
/// A label-bound culling setting: the boolean, a pixel radius, or `Flush` (flush only).
#derive(Eq, Debug)
pub(all) enum VegaLabelBound {
  Bool(Bool)
  Amount(Double)
  Flush
}

///|
pub extend VegaLabelBound with Eq::{equal, not_equal}

///|
pub extend VegaLabelBound with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_label_bound_emit_json(v : VegaLabelBound) -> Json {
  match v {
    Bool(b) => Json::boolean(b)
    Amount(n) => Json::number(n)
    Flush => Json::string("flush")
  }
}

///|
/// A tick band strategy for banded axes: center or extent.
#derive(Eq, Debug)
pub(all) enum VegaTickBand {
  Center
  Extent
}

///|
pub extend VegaTickBand with Eq::{equal, not_equal}

///|
pub extend VegaTickBand with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_tick_band_string(v : VegaTickBand) -> String {
  match v {
    Center => "center"
    Extent => "extent"
  }
}

///|
/// An axis definition for a position channel, the schema's `Axis` in full
/// static form — the domain line, the grid, the ticks, the labels, and the
/// axis title, each styled, plus the orientation, the offset, explicit tick
/// `values`, and a tick count in any of its three forms (a number, a
/// calendar interval, or an interval with a step multiplier). Every property
/// is optional; unset ones fall to the runtime's defaults. The one
/// exception is `disable`: the schema carries it on the config axis alone
/// (`AxisConfig`, the default every axis inherits), not on a channel's
/// own axis definition — so the channel-side emission drops a set one
/// and only the config emitters place it. The array-carrying ones
/// (`domain_dash`, `grid_dash`, `tick_dash`, `values`) are copied at
/// construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaAxis {
  disable : Bool?
  aria : Bool?
  band_position : Double?
  description : String?
  domain : Bool?
  domain_cap : VegaCap?
  domain_color : String?
  priv domain_dash : Array[Double]?
  domain_dash_offset : Double?
  domain_opacity : Double?
  domain_width : Double?
  format : String?
  format_type : String?
  grid : Bool?
  grid_cap : VegaCap?
  grid_color : String?
  priv grid_dash : Array[Double]?
  grid_dash_offset : Double?
  grid_opacity : Double?
  grid_width : Double?
  label_align : VegaAlign?
  label_angle : Double?
  label_baseline : VegaBaseline?
  label_bound : VegaLabelBound?
  label_color : String?
  label_expr : String?
  label_flush : VegaLabelFlush?
  label_flush_offset : Double?
  label_font : String?
  label_font_size : Double?
  label_font_style : String?
  label_font_weight : VegaFontWeight?
  label_limit : Double?
  label_line_height : Double?
  label_offset : Double?
  label_opacity : Double?
  label_overlap : VegaLabelOverlap?
  label_padding : Double?
  label_separation : Double?
  labels : Bool?
  max_extent : Double?
  min_extent : Double?
  offset : Double?
  orient : VegaAxisOrient?
  position : Double?
  style : String?
  tick_band : VegaTickBand?
  tick_cap : VegaCap?
  tick_color : String?
  tick_count : VegaTickInterval?
  priv tick_dash : Array[Double]?
  tick_dash_offset : Double?
  tick_extra : Bool?
  tick_min_step : Double?
  tick_offset : Double?
  tick_opacity : Double?
  tick_round : Bool?
  tick_size : Double?
  tick_width : Double?
  ticks : Bool?
  title : String?
  title_align : VegaAlign?
  title_anchor : VegaAnchor?
  title_angle : Double?
  title_baseline : VegaBaseline?
  title_color : String?
  title_font : String?
  title_font_size : Double?
  title_font_style : String?
  title_font_weight : VegaFontWeight?
  title_limit : Double?
  title_line_height : Double?
  title_opacity : Double?
  title_padding : Double?
  title_x : Double?
  title_y : Double?
  translate : Double?
  priv values : Array[Json]?
  zindex : Double?
}

///|
pub extend VegaAxis with Eq::{equal, not_equal}

///|
pub extend VegaAxis with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaAxis::VegaAxis(
  disable? : Bool,
  aria? : Bool,
  band_position? : Double,
  description? : String,
  domain? : Bool,
  domain_cap? : VegaCap,
  domain_color? : String,
  domain_dash? : Array[Double],
  domain_dash_offset? : Double,
  domain_opacity? : Double,
  domain_width? : Double,
  format? : String,
  format_type? : String,
  grid? : Bool,
  grid_cap? : VegaCap,
  grid_color? : String,
  grid_dash? : Array[Double],
  grid_dash_offset? : Double,
  grid_opacity? : Double,
  grid_width? : Double,
  label_align? : VegaAlign,
  label_angle? : Double,
  label_baseline? : VegaBaseline,
  label_bound? : VegaLabelBound,
  label_color? : String,
  label_expr? : String,
  label_flush? : VegaLabelFlush,
  label_flush_offset? : Double,
  label_font? : String,
  label_font_size? : Double,
  label_font_style? : String,
  label_font_weight? : VegaFontWeight,
  label_limit? : Double,
  label_line_height? : Double,
  label_offset? : Double,
  label_opacity? : Double,
  label_overlap? : VegaLabelOverlap,
  label_padding? : Double,
  label_separation? : Double,
  labels? : Bool,
  max_extent? : Double,
  min_extent? : Double,
  offset? : Double,
  orient? : VegaAxisOrient,
  position? : Double,
  style? : String,
  tick_band? : VegaTickBand,
  tick_cap? : VegaCap,
  tick_color? : String,
  tick_count? : VegaTickInterval,
  tick_dash? : Array[Double],
  tick_dash_offset? : Double,
  tick_extra? : Bool,
  tick_min_step? : Double,
  tick_offset? : Double,
  tick_opacity? : Double,
  tick_round? : Bool,
  tick_size? : Double,
  tick_width? : Double,
  ticks? : Bool,
  title? : String,
  title_align? : VegaAlign,
  title_anchor? : VegaAnchor,
  title_angle? : Double,
  title_baseline? : VegaBaseline,
  title_color? : String,
  title_font? : String,
  title_font_size? : Double,
  title_font_style? : String,
  title_font_weight? : VegaFontWeight,
  title_limit? : Double,
  title_line_height? : Double,
  title_opacity? : Double,
  title_padding? : Double,
  title_x? : Double,
  title_y? : Double,
  translate? : Double,
  values? : Array[Json],
  zindex? : Double,
) -> VegaAxis {
  {
    disable,
    aria,
    band_position,
    description,
    domain,
    domain_cap,
    domain_color,
    domain_dash: match domain_dash {
      Some(a) => Some(a.copy())
      None => None
    },
    domain_dash_offset,
    domain_opacity,
    domain_width,
    format,
    format_type,
    grid,
    grid_cap,
    grid_color,
    grid_dash: match grid_dash {
      Some(a) => Some(a.copy())
      None => None
    },
    grid_dash_offset,
    grid_opacity,
    grid_width,
    label_align,
    label_angle,
    label_baseline,
    label_bound,
    label_color,
    label_expr,
    label_flush,
    label_flush_offset,
    label_font,
    label_font_size,
    label_font_style,
    label_font_weight,
    label_limit,
    label_line_height,
    label_offset,
    label_opacity,
    label_overlap,
    label_padding,
    label_separation,
    labels,
    max_extent,
    min_extent,
    offset,
    orient,
    position,
    style,
    tick_band,
    tick_cap,
    tick_color,
    tick_count,
    tick_dash: match tick_dash {
      Some(a) => Some(a.copy())
      None => None
    },
    tick_dash_offset,
    tick_extra,
    tick_min_step,
    tick_offset,
    tick_opacity,
    tick_round,
    tick_size,
    tick_width,
    ticks,
    title,
    title_align,
    title_anchor,
    title_angle,
    title_baseline,
    title_color,
    title_font,
    title_font_size,
    title_font_style,
    title_font_weight,
    title_limit,
    title_line_height,
    title_opacity,
    title_padding,
    title_x,
    title_y,
    translate,
    values: match values {
      Some(a) => Some(a.copy())
      None => None
    },
    zindex,
  }
}

///|
/// The `domain_dash` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaAxis::domain_dash(self : VegaAxis) -> Array[Double]? {
  match self.domain_dash {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `grid_dash` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaAxis::grid_dash(self : VegaAxis) -> Array[Double]? {
  match self.grid_dash {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `tick_dash` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaAxis::tick_dash(self : VegaAxis) -> Array[Double]? {
  match self.tick_dash {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `values` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaAxis::values(self : VegaAxis) -> Array[Json]? {
  match self.values {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaAxis`, every set property
/// under its schema key. `config_side` says whether the emission is a
/// config axis (`config.axis` and its per-orientation keys, the schema's
/// `AxisConfig`) — the one shape that carries `disable`. A channel's own
/// axis definition does not, so that side leaves a set `disable` out
/// rather than emitting a key the schema would reject.
fn vega_axis_emit_json(x : VegaAxis, config_side : Bool) -> Json {
  let obj : Map[String, Json] = Map([])
  if config_side && x.disable is Some(v) {
    obj["disable"] = Json::boolean(v)
  }
  if x.aria is Some(v) {
    obj["aria"] = Json::boolean(v)
  }
  if x.band_position is Some(v) {
    obj["bandPosition"] = Json::number(v)
  }
  if x.description is Some(v) {
    obj["description"] = Json::string(v)
  }
  if x.domain is Some(v) {
    obj["domain"] = Json::boolean(v)
  }
  if x.domain_cap is Some(v) {
    obj["domainCap"] = Json::string(vega_cap_string(v))
  }
  if x.domain_color is Some(v) {
    obj["domainColor"] = Json::string(v)
  }
  if x.domain_dash is Some(v) {
    obj["domainDash"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.domain_dash_offset is Some(v) {
    obj["domainDashOffset"] = Json::number(v)
  }
  if x.domain_opacity is Some(v) {
    obj["domainOpacity"] = Json::number(v)
  }
  if x.domain_width is Some(v) {
    obj["domainWidth"] = Json::number(v)
  }
  if x.format is Some(v) {
    obj["format"] = Json::string(v)
  }
  if x.format_type is Some(v) {
    obj["formatType"] = Json::string(v)
  }
  if x.grid is Some(v) {
    obj["grid"] = Json::boolean(v)
  }
  if x.grid_cap is Some(v) {
    obj["gridCap"] = Json::string(vega_cap_string(v))
  }
  if x.grid_color is Some(v) {
    obj["gridColor"] = Json::string(v)
  }
  if x.grid_dash is Some(v) {
    obj["gridDash"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.grid_dash_offset is Some(v) {
    obj["gridDashOffset"] = Json::number(v)
  }
  if x.grid_opacity is Some(v) {
    obj["gridOpacity"] = Json::number(v)
  }
  if x.grid_width is Some(v) {
    obj["gridWidth"] = Json::number(v)
  }
  if x.label_align is Some(v) {
    obj["labelAlign"] = Json::string(vega_align_string(v))
  }
  if x.label_angle is Some(v) {
    obj["labelAngle"] = Json::number(v)
  }
  if x.label_baseline is Some(v) {
    obj["labelBaseline"] = Json::string(vega_baseline_string(v))
  }
  if x.label_bound is Some(v) {
    obj["labelBound"] = vega_label_bound_emit_json(v)
  }
  if x.label_color is Some(v) {
    obj["labelColor"] = Json::string(v)
  }
  if x.label_expr is Some(v) {
    obj["labelExpr"] = Json::string(v)
  }
  if x.label_flush is Some(v) {
    obj["labelFlush"] = vega_label_flush_emit_json(v)
  }
  if x.label_flush_offset is Some(v) {
    obj["labelFlushOffset"] = Json::number(v)
  }
  if x.label_font is Some(v) {
    obj["labelFont"] = Json::string(v)
  }
  if x.label_font_size is Some(v) {
    obj["labelFontSize"] = Json::number(v)
  }
  if x.label_font_style is Some(v) {
    obj["labelFontStyle"] = Json::string(v)
  }
  if x.label_font_weight is Some(v) {
    obj["labelFontWeight"] = vega_font_weight_emit_json(v)
  }
  if x.label_limit is Some(v) {
    obj["labelLimit"] = Json::number(v)
  }
  if x.label_line_height is Some(v) {
    obj["labelLineHeight"] = Json::number(v)
  }
  if x.label_offset is Some(v) {
    obj["labelOffset"] = Json::number(v)
  }
  if x.label_opacity is Some(v) {
    obj["labelOpacity"] = Json::number(v)
  }
  if x.label_overlap is Some(v) {
    obj["labelOverlap"] = vega_label_overlap_emit_json(v)
  }
  if x.label_padding is Some(v) {
    obj["labelPadding"] = Json::number(v)
  }
  if x.label_separation is Some(v) {
    obj["labelSeparation"] = Json::number(v)
  }
  if x.labels is Some(v) {
    obj["labels"] = Json::boolean(v)
  }
  if x.max_extent is Some(v) {
    obj["maxExtent"] = Json::number(v)
  }
  if x.min_extent is Some(v) {
    obj["minExtent"] = Json::number(v)
  }
  if x.offset is Some(v) {
    obj["offset"] = Json::number(v)
  }
  if x.orient is Some(v) {
    obj["orient"] = Json::string(vega_axis_orient_string(v))
  }
  if x.position is Some(v) {
    obj["position"] = Json::number(v)
  }
  if x.style is Some(v) {
    obj["style"] = Json::string(v)
  }
  if x.tick_band is Some(v) {
    obj["tickBand"] = Json::string(vega_tick_band_string(v))
  }
  if x.tick_cap is Some(v) {
    obj["tickCap"] = Json::string(vega_cap_string(v))
  }
  if x.tick_color is Some(v) {
    obj["tickColor"] = Json::string(v)
  }
  if x.tick_count is Some(v) {
    obj["tickCount"] = vega_tick_interval_emit_json(v)
  }
  if x.tick_dash is Some(v) {
    obj["tickDash"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.tick_dash_offset is Some(v) {
    obj["tickDashOffset"] = Json::number(v)
  }
  if x.tick_extra is Some(v) {
    obj["tickExtra"] = Json::boolean(v)
  }
  if x.tick_min_step is Some(v) {
    obj["tickMinStep"] = Json::number(v)
  }
  if x.tick_offset is Some(v) {
    obj["tickOffset"] = Json::number(v)
  }
  if x.tick_opacity is Some(v) {
    obj["tickOpacity"] = Json::number(v)
  }
  if x.tick_round is Some(v) {
    obj["tickRound"] = Json::boolean(v)
  }
  if x.tick_size is Some(v) {
    obj["tickSize"] = Json::number(v)
  }
  if x.tick_width is Some(v) {
    obj["tickWidth"] = Json::number(v)
  }
  if x.ticks is Some(v) {
    obj["ticks"] = Json::boolean(v)
  }
  if x.title is Some(v) {
    obj["title"] = Json::string(v)
  }
  if x.title_align is Some(v) {
    obj["titleAlign"] = Json::string(vega_align_string(v))
  }
  if x.title_anchor is Some(v) {
    obj["titleAnchor"] = Json::string(vega_anchor_string(v))
  }
  if x.title_angle is Some(v) {
    obj["titleAngle"] = Json::number(v)
  }
  if x.title_baseline is Some(v) {
    obj["titleBaseline"] = Json::string(vega_baseline_string(v))
  }
  if x.title_color is Some(v) {
    obj["titleColor"] = Json::string(v)
  }
  if x.title_font is Some(v) {
    obj["titleFont"] = Json::string(v)
  }
  if x.title_font_size is Some(v) {
    obj["titleFontSize"] = Json::number(v)
  }
  if x.title_font_style is Some(v) {
    obj["titleFontStyle"] = Json::string(v)
  }
  if x.title_font_weight is Some(v) {
    obj["titleFontWeight"] = vega_font_weight_emit_json(v)
  }
  if x.title_limit is Some(v) {
    obj["titleLimit"] = Json::number(v)
  }
  if x.title_line_height is Some(v) {
    obj["titleLineHeight"] = Json::number(v)
  }
  if x.title_opacity is Some(v) {
    obj["titleOpacity"] = Json::number(v)
  }
  if x.title_padding is Some(v) {
    obj["titlePadding"] = Json::number(v)
  }
  if x.title_x is Some(v) {
    obj["titleX"] = Json::number(v)
  }
  if x.title_y is Some(v) {
    obj["titleY"] = Json::number(v)
  }
  if x.translate is Some(v) {
    obj["translate"] = Json::number(v)
  }
  if x.values is Some(v) {
    obj["values"] = Json::array(v.copy())
  }
  if x.zindex is Some(v) {
    obj["zindex"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// A position channel's axis: a configuration, or `Off` (the schema's `null`, which removes the axis).
#derive(Eq, Debug)
pub(all) enum VegaAxisRef {
  Off
  Config(VegaAxis)
}

///|
pub extend VegaAxisRef with Eq::{equal, not_equal}

///|
pub extend VegaAxisRef with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms. A channel axis is
/// the config-side-`false` emission: a `disable` set on it is left out
/// (see `vega_axis_emit_json`).
fn vega_axis_ref_emit_json(v : VegaAxisRef) -> Json {
  match v {
    Off => Json::null()
    Config(a) => vega_axis_emit_json(a, false)
  }
}
