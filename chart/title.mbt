// The title family: a typed mirror of the schema's `TitleParams` object, transcribed
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
/// A chart title in its parameter form, the schema's `TitleParams` — the
/// text (the schema requires it; a params form without one is refused by the
/// schema, not by the type), an optional subtitle with its own styling, and
/// the anchor, orientation, alignment, font, offset, and z-order of the
/// whole block. Every property is optional; unset ones fall to the
/// runtime's title defaults.
#derive(Eq, Debug)
pub struct VegaTitleParams {
  text : String?
  align : VegaAlign?
  anchor : VegaAnchor?
  angle : Double?
  aria : Bool?
  baseline : VegaBaseline?
  color : String?
  dx : Double?
  dy : Double?
  font : String?
  font_size : Double?
  font_style : String?
  font_weight : VegaFontWeight?
  frame : VegaTitleFrame?
  limit : Double?
  line_height : Double?
  offset : Double?
  orient : VegaTitleOrient?
  style : String?
  subtitle : String?
  subtitle_color : String?
  subtitle_font : String?
  subtitle_font_size : Double?
  subtitle_font_style : String?
  subtitle_font_weight : VegaFontWeight?
  subtitle_line_height : Double?
  subtitle_padding : Double?
  zindex : Double?
}

///|
pub extend VegaTitleParams with Eq::{equal, not_equal}

///|
pub extend VegaTitleParams with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaTitleParams::VegaTitleParams(
  text? : String,
  align? : VegaAlign,
  anchor? : VegaAnchor,
  angle? : Double,
  aria? : Bool,
  baseline? : VegaBaseline,
  color? : String,
  dx? : Double,
  dy? : Double,
  font? : String,
  font_size? : Double,
  font_style? : String,
  font_weight? : VegaFontWeight,
  frame? : VegaTitleFrame,
  limit? : Double,
  line_height? : Double,
  offset? : Double,
  orient? : VegaTitleOrient,
  style? : String,
  subtitle? : String,
  subtitle_color? : String,
  subtitle_font? : String,
  subtitle_font_size? : Double,
  subtitle_font_style? : String,
  subtitle_font_weight? : VegaFontWeight,
  subtitle_line_height? : Double,
  subtitle_padding? : Double,
  zindex? : Double,
) -> VegaTitleParams {
  {
    text,
    align,
    anchor,
    angle,
    aria,
    baseline,
    color,
    dx,
    dy,
    font,
    font_size,
    font_style,
    font_weight,
    frame,
    limit,
    line_height,
    offset,
    orient,
    style,
    subtitle,
    subtitle_color,
    subtitle_font,
    subtitle_font_size,
    subtitle_font_style,
    subtitle_font_weight,
    subtitle_line_height,
    subtitle_padding,
    zindex,
  }
}

///|
/// The emitted JSON object of a `VegaTitleParams`, every set property
/// under its schema key.
fn vega_title_params_emit_json(x : VegaTitleParams) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.text is Some(v) {
    obj["text"] = Json::string(v)
  }
  if x.align is Some(v) {
    obj["align"] = Json::string(vega_align_string(v))
  }
  if x.anchor is Some(v) {
    obj["anchor"] = Json::string(vega_anchor_string(v))
  }
  if x.angle is Some(v) {
    obj["angle"] = Json::number(v)
  }
  if x.aria is Some(v) {
    obj["aria"] = Json::boolean(v)
  }
  if x.baseline is Some(v) {
    obj["baseline"] = Json::string(vega_baseline_string(v))
  }
  if x.color is Some(v) {
    obj["color"] = Json::string(v)
  }
  if x.dx is Some(v) {
    obj["dx"] = Json::number(v)
  }
  if x.dy is Some(v) {
    obj["dy"] = Json::number(v)
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
  if x.frame is Some(v) {
    obj["frame"] = Json::string(vega_title_frame_string(v))
  }
  if x.limit is Some(v) {
    obj["limit"] = Json::number(v)
  }
  if x.line_height is Some(v) {
    obj["lineHeight"] = Json::number(v)
  }
  if x.offset is Some(v) {
    obj["offset"] = Json::number(v)
  }
  if x.orient is Some(v) {
    obj["orient"] = Json::string(vega_title_orient_string(v))
  }
  if x.style is Some(v) {
    obj["style"] = Json::string(v)
  }
  if x.subtitle is Some(v) {
    obj["subtitle"] = Json::string(v)
  }
  if x.subtitle_color is Some(v) {
    obj["subtitleColor"] = Json::string(v)
  }
  if x.subtitle_font is Some(v) {
    obj["subtitleFont"] = Json::string(v)
  }
  if x.subtitle_font_size is Some(v) {
    obj["subtitleFontSize"] = Json::number(v)
  }
  if x.subtitle_font_style is Some(v) {
    obj["subtitleFontStyle"] = Json::string(v)
  }
  if x.subtitle_font_weight is Some(v) {
    obj["subtitleFontWeight"] = vega_font_weight_emit_json(v)
  }
  if x.subtitle_line_height is Some(v) {
    obj["subtitleLineHeight"] = Json::number(v)
  }
  if x.subtitle_padding is Some(v) {
    obj["subtitlePadding"] = Json::number(v)
  }
  if x.zindex is Some(v) {
    obj["zindex"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// A chart title: plain text, or the parameter form with styling and a subtitle.
#derive(Eq, Debug)
pub(all) enum VegaTitle {
  Text(String)
  Params(VegaTitleParams)
}

///|
pub extend VegaTitle with Eq::{equal, not_equal}

///|
pub extend VegaTitle with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_title_emit_json(v : VegaTitle) -> Json {
  match v {
    Text(t) => Json::string(t)
    Params(p) => vega_title_params_emit_json(p)
  }
}
