// The view background family: a typed mirror of the schema's `ViewBackground` object, transcribed
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
/// The single-view plot's own background, the schema's `ViewBackground` —
/// a fill and stroke with their opacities and widths, a corner radius, a
/// dash pattern, a cursor, and a named style. Every property is optional;
/// unset ones fall to the view config's defaults. The `stroke_dash` array
/// is copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaViewBackground {
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
  style : String?
}

///|
pub extend VegaViewBackground with Eq::{equal, not_equal}

///|
pub extend VegaViewBackground with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaViewBackground::VegaViewBackground(
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
  style? : String,
) -> VegaViewBackground {
  {
    corner_radius,
    cursor,
    fill,
    fill_opacity,
    opacity,
    stroke,
    stroke_cap,
    stroke_dash: stroke_dash.map(a => a.copy()),
    stroke_dash_offset,
    stroke_join,
    stroke_miter_limit,
    stroke_opacity,
    stroke_width,
    style,
  }
}

///|
/// The `stroke_dash` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaViewBackground::stroke_dash(
  self : VegaViewBackground,
) -> Array[Double]? {
  self.stroke_dash.map(a => a.copy())
}

///|
/// The emitted JSON object of a `VegaViewBackground`, every set property
/// under its schema key.
fn vega_view_background_emit_json(x : VegaViewBackground) -> Json {
  let obj : Map[String, Json] = Map([])
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
  if x.style is Some(v) {
    obj["style"] = Json::string(v)
  }
  Json::object(obj)
}
