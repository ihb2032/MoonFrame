// The facet family: the header a faceted row / column draws
// (`VegaHeader`) and the facet channel definition itself
// (`VegaFacetChannel`, the schema's `FacetFieldDef` — a field definition
// carrying its own header). Transcribed from the vendored
// vega_lite_v6_5_0.schema.json and schema-walked through the corpus
// guard; reached through `@chart` qualification as part of the deep
// mirror family.
//
// The static arms of the schema's unions are mirrored; expression and
// parameter arms land with the params stage.

///|
/// A facet header, the schema's `Header` in static form — the facet labels
/// and the facet title, each styled (font, size, weight, color, alignment,
/// angle, orientation, padding), a label expression, and whether labels
/// draw at all. Every property is optional; unset ones fall to the header
/// config's defaults.
#derive(Eq, Debug)
pub struct VegaHeader {
  format : String?
  format_type : String?
  label_align : VegaAlign?
  label_anchor : VegaAnchor?
  label_angle : Double?
  label_baseline : VegaBaseline?
  label_color : String?
  label_expr : String?
  label_font : String?
  label_font_size : Double?
  label_font_style : String?
  label_font_weight : VegaFontWeight?
  label_limit : Double?
  label_line_height : Double?
  label_orient : VegaOrient?
  label_padding : Double?
  labels : Bool?
  orient : VegaOrient?
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
  title_orient : VegaOrient?
  title_padding : Double?
}

///|
pub extend VegaHeader with Eq::{equal, not_equal}

///|
pub extend VegaHeader with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaHeader::VegaHeader(
  format? : String,
  format_type? : String,
  label_align? : VegaAlign,
  label_anchor? : VegaAnchor,
  label_angle? : Double,
  label_baseline? : VegaBaseline,
  label_color? : String,
  label_expr? : String,
  label_font? : String,
  label_font_size? : Double,
  label_font_style? : String,
  label_font_weight? : VegaFontWeight,
  label_limit? : Double,
  label_line_height? : Double,
  label_orient? : VegaOrient,
  label_padding? : Double,
  labels? : Bool,
  orient? : VegaOrient,
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
  title_orient? : VegaOrient,
  title_padding? : Double,
) -> VegaHeader {
  {
    format,
    format_type,
    label_align,
    label_anchor,
    label_angle,
    label_baseline,
    label_color,
    label_expr,
    label_font,
    label_font_size,
    label_font_style,
    label_font_weight,
    label_limit,
    label_line_height,
    label_orient,
    label_padding,
    labels,
    orient,
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
    title_orient,
    title_padding,
  }
}

///|
/// The emitted JSON object of a `VegaHeader`, every set property
/// under its schema key.
fn vega_header_emit_json(x : VegaHeader) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.format is Some(v) {
    obj["format"] = Json::string(v)
  }
  if x.format_type is Some(v) {
    obj["formatType"] = Json::string(v)
  }
  if x.label_align is Some(v) {
    obj["labelAlign"] = Json::string(vega_align_string(v))
  }
  if x.label_anchor is Some(v) {
    obj["labelAnchor"] = Json::string(vega_anchor_string(v))
  }
  if x.label_angle is Some(v) {
    obj["labelAngle"] = Json::number(v)
  }
  if x.label_baseline is Some(v) {
    obj["labelBaseline"] = Json::string(vega_baseline_string(v))
  }
  if x.label_color is Some(v) {
    obj["labelColor"] = Json::string(v)
  }
  if x.label_expr is Some(v) {
    obj["labelExpr"] = Json::string(v)
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
  if x.label_orient is Some(v) {
    obj["labelOrient"] = Json::string(vega_orient_string(v))
  }
  if x.label_padding is Some(v) {
    obj["labelPadding"] = Json::number(v)
  }
  if x.labels is Some(v) {
    obj["labels"] = Json::boolean(v)
  }
  if x.orient is Some(v) {
    obj["orient"] = Json::string(vega_orient_string(v))
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
  if x.title_orient is Some(v) {
    obj["titleOrient"] = Json::string(vega_orient_string(v))
  }
  if x.title_padding is Some(v) {
    obj["titlePadding"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// A facet channel definition, the schema's `FacetFieldDef` — the field a
/// `row` / `column` facet groups by, with the aggregation / binning /
/// time-unit / sorting modifiers of an encoding channel and the facet's
/// own `header`. The grid-level alignment, centering, and spacing belong
/// to the facet operator itself (`VegaFacet`), not to the channel — the
/// schema's `FacetFieldDef` carries no such keys. The channel-host `sort`
/// is narrower than an encoding channel's too: `FacetFieldDef.sort` has
/// no bare-channel form, so a `ByChannel` sort raises `InvalidOperation`
/// at emission (sort by a field or by an explicit order instead). Every
/// property is optional except in spirit: a facet channel without a
/// `field` facets on nothing, and the schema requires one.
#derive(Eq, Debug)
pub struct VegaFacetChannel {
  field : String?
  aggregate : VegaAggregate?
  bin : VegaBin?
  time_unit : VegaTimeUnit?
  sort : VegaChannelSort?
  type_override : VegaType?
  title : String?
  band_position : Double?
  header : VegaHeader?
}

///|
pub extend VegaFacetChannel with Eq::{equal, not_equal}

///|
pub extend VegaFacetChannel with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaFacetChannel::VegaFacetChannel(
  field? : String,
  aggregate? : VegaAggregate,
  bin? : VegaBin,
  time_unit? : VegaTimeUnit,
  sort? : VegaChannelSort,
  type_override? : VegaType,
  title? : String,
  band_position? : Double,
  header? : VegaHeader,
) -> VegaFacetChannel {
  {
    field,
    aggregate,
    bin,
    time_unit,
    sort,
    type_override,
    title,
    band_position,
    header,
  }
}
