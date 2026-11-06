// The legend family: a typed mirror of the schema's `Legend` object, transcribed
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
/// A legend type: discrete symbols or a continuous gradient.
#derive(Eq, Debug)
pub(all) enum VegaLegendType {
  Symbol
  Gradient
}

///|
pub extend VegaLegendType with Eq::{equal, not_equal}

///|
pub extend VegaLegendType with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_legend_type_string(v : VegaLegendType) -> String {
  match v {
    Symbol => "symbol"
    Gradient => "gradient"
  }
}

///|
/// A legend definition for a mark-property channel, the schema's `Legend`
/// in full static form — discrete symbols or a continuous gradient, the
/// gradient and symbol geometry, the label and title styling, the
/// orientation (a side or a corner), explicit `values`, and a legend grid
/// (columns, paddings, alignment). `symbol_type` stays a free `String`
/// by the schema's own choice: its `SymbolShape` is an unenumerated
/// string, because a custom SVG path (a path string, not a name) is a
/// legal symbol — an enum here would reject what the format accepts.
/// Every property is optional; unset ones fall to the runtime's
/// defaults. The array-carrying ones (`symbol_dash`, `values`) are
/// copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaLegend {
  aria : Bool?
  clip_height : Double?
  column_padding : Double?
  columns : Double?
  corner_radius : Double?
  description : String?
  direction : VegaDirection?
  fill_color : String?
  format : String?
  format_type : String?
  gradient_length : Double?
  gradient_opacity : Double?
  gradient_stroke_color : String?
  gradient_stroke_width : Double?
  gradient_thickness : Double?
  grid_align : VegaLayoutAlign?
  label_align : VegaAlign?
  label_baseline : VegaBaseline?
  label_color : String?
  label_expr : String?
  label_font : String?
  label_font_size : Double?
  label_font_style : String?
  label_font_weight : VegaFontWeight?
  label_limit : Double?
  label_offset : Double?
  label_opacity : Double?
  label_overlap : VegaLabelOverlap?
  label_padding : Double?
  label_separation : Double?
  legend_x : Double?
  legend_y : Double?
  offset : Double?
  orient : VegaLegendOrient?
  padding : Double?
  row_padding : Double?
  stroke_color : String?
  priv symbol_dash : Array[Double]?
  symbol_dash_offset : Double?
  symbol_fill_color : String?
  symbol_limit : Double?
  symbol_offset : Double?
  symbol_opacity : Double?
  symbol_size : Double?
  symbol_stroke_color : String?
  symbol_stroke_width : Double?
  symbol_type : String?
  tick_count : VegaTickInterval?
  tick_min_step : Double?
  title : String?
  title_align : VegaAlign?
  title_anchor : VegaAnchor?
  title_baseline : VegaBaseline?
  title_color : String?
  title_font : String?
  title_font_size : Double?
  title_font_style : String?
  title_font_weight : VegaFontWeight?
  title_limit : Double?
  title_line_height : Double?
  title_opacity : Double?
  title_orient : VegaTitleOrient?
  title_padding : Double?
  type_ : VegaLegendType?
  priv values : Array[Json]?
  zindex : Double?
}

///|
pub extend VegaLegend with Eq::{equal, not_equal}

///|
pub extend VegaLegend with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaLegend::VegaLegend(
  aria? : Bool,
  clip_height? : Double,
  column_padding? : Double,
  columns? : Double,
  corner_radius? : Double,
  description? : String,
  direction? : VegaDirection,
  fill_color? : String,
  format? : String,
  format_type? : String,
  gradient_length? : Double,
  gradient_opacity? : Double,
  gradient_stroke_color? : String,
  gradient_stroke_width? : Double,
  gradient_thickness? : Double,
  grid_align? : VegaLayoutAlign,
  label_align? : VegaAlign,
  label_baseline? : VegaBaseline,
  label_color? : String,
  label_expr? : String,
  label_font? : String,
  label_font_size? : Double,
  label_font_style? : String,
  label_font_weight? : VegaFontWeight,
  label_limit? : Double,
  label_offset? : Double,
  label_opacity? : Double,
  label_overlap? : VegaLabelOverlap,
  label_padding? : Double,
  label_separation? : Double,
  legend_x? : Double,
  legend_y? : Double,
  offset? : Double,
  orient? : VegaLegendOrient,
  padding? : Double,
  row_padding? : Double,
  stroke_color? : String,
  symbol_dash? : Array[Double],
  symbol_dash_offset? : Double,
  symbol_fill_color? : String,
  symbol_limit? : Double,
  symbol_offset? : Double,
  symbol_opacity? : Double,
  symbol_size? : Double,
  symbol_stroke_color? : String,
  symbol_stroke_width? : Double,
  symbol_type? : String,
  tick_count? : VegaTickInterval,
  tick_min_step? : Double,
  title? : String,
  title_align? : VegaAlign,
  title_anchor? : VegaAnchor,
  title_baseline? : VegaBaseline,
  title_color? : String,
  title_font? : String,
  title_font_size? : Double,
  title_font_style? : String,
  title_font_weight? : VegaFontWeight,
  title_limit? : Double,
  title_line_height? : Double,
  title_opacity? : Double,
  title_orient? : VegaTitleOrient,
  title_padding? : Double,
  type_? : VegaLegendType,
  values? : Array[Json],
  zindex? : Double,
) -> VegaLegend {
  {
    aria,
    clip_height,
    column_padding,
    columns,
    corner_radius,
    description,
    direction,
    fill_color,
    format,
    format_type,
    gradient_length,
    gradient_opacity,
    gradient_stroke_color,
    gradient_stroke_width,
    gradient_thickness,
    grid_align,
    label_align,
    label_baseline,
    label_color,
    label_expr,
    label_font,
    label_font_size,
    label_font_style,
    label_font_weight,
    label_limit,
    label_offset,
    label_opacity,
    label_overlap,
    label_padding,
    label_separation,
    legend_x,
    legend_y,
    offset,
    orient,
    padding,
    row_padding,
    stroke_color,
    symbol_dash: match symbol_dash {
      Some(a) => Some(a.copy())
      None => None
    },
    symbol_dash_offset,
    symbol_fill_color,
    symbol_limit,
    symbol_offset,
    symbol_opacity,
    symbol_size,
    symbol_stroke_color,
    symbol_stroke_width,
    symbol_type,
    tick_count,
    tick_min_step,
    title,
    title_align,
    title_anchor,
    title_baseline,
    title_color,
    title_font,
    title_font_size,
    title_font_style,
    title_font_weight,
    title_limit,
    title_line_height,
    title_opacity,
    title_orient,
    title_padding,
    type_,
    values: match values {
      Some(a) => Some(a.copy())
      None => None
    },
    zindex,
  }
}

///|
/// The `symbol_dash` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaLegend::symbol_dash(self : VegaLegend) -> Array[Double]? {
  match self.symbol_dash {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The `values` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaLegend::values(self : VegaLegend) -> Array[Json]? {
  match self.values {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaLegend`, every set property
/// under its schema key.
fn vega_legend_emit_json(x : VegaLegend) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.aria is Some(v) {
    obj["aria"] = Json::boolean(v)
  }
  if x.clip_height is Some(v) {
    obj["clipHeight"] = Json::number(v)
  }
  if x.column_padding is Some(v) {
    obj["columnPadding"] = Json::number(v)
  }
  if x.columns is Some(v) {
    obj["columns"] = Json::number(v)
  }
  if x.corner_radius is Some(v) {
    obj["cornerRadius"] = Json::number(v)
  }
  if x.description is Some(v) {
    obj["description"] = Json::string(v)
  }
  if x.direction is Some(v) {
    obj["direction"] = Json::string(vega_direction_string(v))
  }
  if x.fill_color is Some(v) {
    obj["fillColor"] = Json::string(v)
  }
  if x.format is Some(v) {
    obj["format"] = Json::string(v)
  }
  if x.format_type is Some(v) {
    obj["formatType"] = Json::string(v)
  }
  if x.gradient_length is Some(v) {
    obj["gradientLength"] = Json::number(v)
  }
  if x.gradient_opacity is Some(v) {
    obj["gradientOpacity"] = Json::number(v)
  }
  if x.gradient_stroke_color is Some(v) {
    obj["gradientStrokeColor"] = Json::string(v)
  }
  if x.gradient_stroke_width is Some(v) {
    obj["gradientStrokeWidth"] = Json::number(v)
  }
  if x.gradient_thickness is Some(v) {
    obj["gradientThickness"] = Json::number(v)
  }
  if x.grid_align is Some(v) {
    obj["gridAlign"] = Json::string(vega_layout_align_string(v))
  }
  if x.label_align is Some(v) {
    obj["labelAlign"] = Json::string(vega_align_string(v))
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
  if x.legend_x is Some(v) {
    obj["legendX"] = Json::number(v)
  }
  if x.legend_y is Some(v) {
    obj["legendY"] = Json::number(v)
  }
  if x.offset is Some(v) {
    obj["offset"] = Json::number(v)
  }
  if x.orient is Some(v) {
    obj["orient"] = Json::string(vega_legend_orient_string(v))
  }
  if x.padding is Some(v) {
    obj["padding"] = Json::number(v)
  }
  if x.row_padding is Some(v) {
    obj["rowPadding"] = Json::number(v)
  }
  if x.stroke_color is Some(v) {
    obj["strokeColor"] = Json::string(v)
  }
  if x.symbol_dash is Some(v) {
    obj["symbolDash"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.symbol_dash_offset is Some(v) {
    obj["symbolDashOffset"] = Json::number(v)
  }
  if x.symbol_fill_color is Some(v) {
    obj["symbolFillColor"] = Json::string(v)
  }
  if x.symbol_limit is Some(v) {
    obj["symbolLimit"] = Json::number(v)
  }
  if x.symbol_offset is Some(v) {
    obj["symbolOffset"] = Json::number(v)
  }
  if x.symbol_opacity is Some(v) {
    obj["symbolOpacity"] = Json::number(v)
  }
  if x.symbol_size is Some(v) {
    obj["symbolSize"] = Json::number(v)
  }
  if x.symbol_stroke_color is Some(v) {
    obj["symbolStrokeColor"] = Json::string(v)
  }
  if x.symbol_stroke_width is Some(v) {
    obj["symbolStrokeWidth"] = Json::number(v)
  }
  if x.symbol_type is Some(v) {
    obj["symbolType"] = Json::string(v)
  }
  if x.tick_count is Some(v) {
    obj["tickCount"] = vega_tick_interval_emit_json(v)
  }
  if x.tick_min_step is Some(v) {
    obj["tickMinStep"] = Json::number(v)
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
  if x.title_orient is Some(v) {
    obj["titleOrient"] = Json::string(vega_title_orient_string(v))
  }
  if x.title_padding is Some(v) {
    obj["titlePadding"] = Json::number(v)
  }
  if x.type_ is Some(v) {
    obj["type"] = Json::string(vega_legend_type_string(v))
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
/// The config-side legend defaults, the schema's `LegendConfig` — the
/// intersection of `VegaLegend` (the channel legend) with the keys the
/// config host accepts. A legend configured through a channel may name
/// the format it renders (`format` / `formatType`), rewrite its labels
/// (`labelExpr`), pin its tick floor (`tickMinStep`), pick its kind
/// (`type`), and list its entries (`values`); the config default may do
/// none of those — those keys do not exist on `LegendConfig`, so the
/// config type does not carry them and a caller cannot set them here.
/// Every property is optional; unset ones fall to the runtime's
/// defaults. The `symbol_dash` array is copied at construction and
/// copied again on read.
#derive(Eq, Debug)
pub struct VegaLegendConfig {
  aria : Bool?
  clip_height : Double?
  column_padding : Double?
  columns : Double?
  corner_radius : Double?
  description : String?
  direction : VegaDirection?
  fill_color : String?
  gradient_length : Double?
  gradient_opacity : Double?
  gradient_stroke_color : String?
  gradient_stroke_width : Double?
  gradient_thickness : Double?
  grid_align : VegaLayoutAlign?
  label_align : VegaAlign?
  label_baseline : VegaBaseline?
  label_color : String?
  label_font : String?
  label_font_size : Double?
  label_font_style : String?
  label_font_weight : VegaFontWeight?
  label_limit : Double?
  label_offset : Double?
  label_opacity : Double?
  label_overlap : VegaLabelOverlap?
  label_padding : Double?
  label_separation : Double?
  legend_x : Double?
  legend_y : Double?
  offset : Double?
  orient : VegaLegendOrient?
  padding : Double?
  row_padding : Double?
  stroke_color : String?
  priv symbol_dash : Array[Double]?
  symbol_dash_offset : Double?
  symbol_fill_color : String?
  symbol_limit : Double?
  symbol_offset : Double?
  symbol_opacity : Double?
  symbol_size : Double?
  symbol_stroke_color : String?
  symbol_stroke_width : Double?
  symbol_type : String?
  tick_count : VegaTickInterval?
  title : String?
  title_align : VegaAlign?
  title_anchor : VegaAnchor?
  title_baseline : VegaBaseline?
  title_color : String?
  title_font : String?
  title_font_size : Double?
  title_font_style : String?
  title_font_weight : VegaFontWeight?
  title_limit : Double?
  title_line_height : Double?
  title_opacity : Double?
  title_orient : VegaTitleOrient?
  title_padding : Double?
  zindex : Double?
}

///|
pub extend VegaLegendConfig with Eq::{equal, not_equal}

///|
pub extend VegaLegendConfig with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaLegendConfig::VegaLegendConfig(
  aria? : Bool,
  clip_height? : Double,
  column_padding? : Double,
  columns? : Double,
  corner_radius? : Double,
  description? : String,
  direction? : VegaDirection,
  fill_color? : String,
  gradient_length? : Double,
  gradient_opacity? : Double,
  gradient_stroke_color? : String,
  gradient_stroke_width? : Double,
  gradient_thickness? : Double,
  grid_align? : VegaLayoutAlign,
  label_align? : VegaAlign,
  label_baseline? : VegaBaseline,
  label_color? : String,
  label_font? : String,
  label_font_size? : Double,
  label_font_style? : String,
  label_font_weight? : VegaFontWeight,
  label_limit? : Double,
  label_offset? : Double,
  label_opacity? : Double,
  label_overlap? : VegaLabelOverlap,
  label_padding? : Double,
  label_separation? : Double,
  legend_x? : Double,
  legend_y? : Double,
  offset? : Double,
  orient? : VegaLegendOrient,
  padding? : Double,
  row_padding? : Double,
  stroke_color? : String,
  symbol_dash? : Array[Double],
  symbol_dash_offset? : Double,
  symbol_fill_color? : String,
  symbol_limit? : Double,
  symbol_offset? : Double,
  symbol_opacity? : Double,
  symbol_size? : Double,
  symbol_stroke_color? : String,
  symbol_stroke_width? : Double,
  symbol_type? : String,
  tick_count? : VegaTickInterval,
  title? : String,
  title_align? : VegaAlign,
  title_anchor? : VegaAnchor,
  title_baseline? : VegaBaseline,
  title_color? : String,
  title_font? : String,
  title_font_size? : Double,
  title_font_style? : String,
  title_font_weight? : VegaFontWeight,
  title_limit? : Double,
  title_line_height? : Double,
  title_opacity? : Double,
  title_orient? : VegaTitleOrient,
  title_padding? : Double,
  zindex? : Double,
) -> VegaLegendConfig {
  {
    aria,
    clip_height,
    column_padding,
    columns,
    corner_radius,
    description,
    direction,
    fill_color,
    gradient_length,
    gradient_opacity,
    gradient_stroke_color,
    gradient_stroke_width,
    gradient_thickness,
    grid_align,
    label_align,
    label_baseline,
    label_color,
    label_font,
    label_font_size,
    label_font_style,
    label_font_weight,
    label_limit,
    label_offset,
    label_opacity,
    label_overlap,
    label_padding,
    label_separation,
    legend_x,
    legend_y,
    offset,
    orient,
    padding,
    row_padding,
    stroke_color,
    symbol_dash: match symbol_dash {
      Some(a) => Some(a.copy())
      None => None
    },
    symbol_dash_offset,
    symbol_fill_color,
    symbol_limit,
    symbol_offset,
    symbol_opacity,
    symbol_size,
    symbol_stroke_color,
    symbol_stroke_width,
    symbol_type,
    tick_count,
    title,
    title_align,
    title_anchor,
    title_baseline,
    title_color,
    title_font,
    title_font_size,
    title_font_style,
    title_font_weight,
    title_limit,
    title_line_height,
    title_opacity,
    title_orient,
    title_padding,
    zindex,
  }
}

///|
/// The `symbol_dash` values, copied — reading the field itself
/// would hand the caller the array the config holds.
pub fn VegaLegendConfig::symbol_dash(self : VegaLegendConfig) -> Array[Double]? {
  match self.symbol_dash {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaLegendConfig`, every set property
/// under its schema key.
fn vega_legend_config_emit_json(x : VegaLegendConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.aria is Some(v) {
    obj["aria"] = Json::boolean(v)
  }
  if x.clip_height is Some(v) {
    obj["clipHeight"] = Json::number(v)
  }
  if x.column_padding is Some(v) {
    obj["columnPadding"] = Json::number(v)
  }
  if x.columns is Some(v) {
    obj["columns"] = Json::number(v)
  }
  if x.corner_radius is Some(v) {
    obj["cornerRadius"] = Json::number(v)
  }
  if x.description is Some(v) {
    obj["description"] = Json::string(v)
  }
  if x.direction is Some(v) {
    obj["direction"] = Json::string(vega_direction_string(v))
  }
  if x.fill_color is Some(v) {
    obj["fillColor"] = Json::string(v)
  }
  if x.gradient_length is Some(v) {
    obj["gradientLength"] = Json::number(v)
  }
  if x.gradient_opacity is Some(v) {
    obj["gradientOpacity"] = Json::number(v)
  }
  if x.gradient_stroke_color is Some(v) {
    obj["gradientStrokeColor"] = Json::string(v)
  }
  if x.gradient_stroke_width is Some(v) {
    obj["gradientStrokeWidth"] = Json::number(v)
  }
  if x.gradient_thickness is Some(v) {
    obj["gradientThickness"] = Json::number(v)
  }
  if x.grid_align is Some(v) {
    obj["gridAlign"] = Json::string(vega_layout_align_string(v))
  }
  if x.label_align is Some(v) {
    obj["labelAlign"] = Json::string(vega_align_string(v))
  }
  if x.label_baseline is Some(v) {
    obj["labelBaseline"] = Json::string(vega_baseline_string(v))
  }
  if x.label_color is Some(v) {
    obj["labelColor"] = Json::string(v)
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
  if x.legend_x is Some(v) {
    obj["legendX"] = Json::number(v)
  }
  if x.legend_y is Some(v) {
    obj["legendY"] = Json::number(v)
  }
  if x.offset is Some(v) {
    obj["offset"] = Json::number(v)
  }
  if x.orient is Some(v) {
    obj["orient"] = Json::string(vega_legend_orient_string(v))
  }
  if x.padding is Some(v) {
    obj["padding"] = Json::number(v)
  }
  if x.row_padding is Some(v) {
    obj["rowPadding"] = Json::number(v)
  }
  if x.stroke_color is Some(v) {
    obj["strokeColor"] = Json::string(v)
  }
  if x.symbol_dash is Some(v) {
    obj["symbolDash"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.symbol_dash_offset is Some(v) {
    obj["symbolDashOffset"] = Json::number(v)
  }
  if x.symbol_fill_color is Some(v) {
    obj["symbolFillColor"] = Json::string(v)
  }
  if x.symbol_limit is Some(v) {
    obj["symbolLimit"] = Json::number(v)
  }
  if x.symbol_offset is Some(v) {
    obj["symbolOffset"] = Json::number(v)
  }
  if x.symbol_opacity is Some(v) {
    obj["symbolOpacity"] = Json::number(v)
  }
  if x.symbol_size is Some(v) {
    obj["symbolSize"] = Json::number(v)
  }
  if x.symbol_stroke_color is Some(v) {
    obj["symbolStrokeColor"] = Json::string(v)
  }
  if x.symbol_stroke_width is Some(v) {
    obj["symbolStrokeWidth"] = Json::number(v)
  }
  if x.symbol_type is Some(v) {
    obj["symbolType"] = Json::string(v)
  }
  if x.tick_count is Some(v) {
    obj["tickCount"] = vega_tick_interval_emit_json(v)
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
  if x.title_orient is Some(v) {
    obj["titleOrient"] = Json::string(vega_title_orient_string(v))
  }
  if x.title_padding is Some(v) {
    obj["titlePadding"] = Json::number(v)
  }
  if x.zindex is Some(v) {
    obj["zindex"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// A mark-property channel's legend: a configuration, or `Off` (the schema's `null`, which removes the legend).
#derive(Eq, Debug)
pub(all) enum VegaLegendRef {
  Off
  Config(VegaLegend)
}

///|
pub extend VegaLegendRef with Eq::{equal, not_equal}

///|
pub extend VegaLegendRef with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_legend_ref_emit_json(v : VegaLegendRef) -> Json {
  match v {
    Off => Json::null()
    Config(l) => vega_legend_emit_json(l)
  }
}
