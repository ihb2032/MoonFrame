// The config main tree — the VegaConfig theme object that carries every
// subtree and scalar the config schema lists. Reached through `@chart`
// qualification; emitted under the `config` key at the top level.

///|
/// A chart's theme: the per-mark style defaults, the scale / axis /
/// legend / header / title defaults, the view frame, the named ranges
/// and style index, the composition grid, the selection defaults, the
/// locale and format defaults, and the top-level scalars (background,
/// padding, autosize, font, countTitle, fieldTitle, aria, lineBreak).
/// Every property is optional; unset ones fall to the runtime's own
/// defaults. The `style` index maps a style name to its mark-style
/// block; the map is copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaConfig {
  background : String?
  autosize : VegaAutoSize?
  padding : VegaPadding?
  font : String?
  count_title : String?
  field_title : String?
  aria : Bool?
  line_break : String?
  priv params : Array[Json]?
  mark : VegaMarkStyle?
  bar : VegaMarkStyle?
  line : VegaMarkStyle?
  point : VegaMarkStyle?
  area : VegaMarkStyle?
  tick : VegaMarkStyle?
  rect : VegaMarkStyle?
  rule : VegaMarkStyle?
  circle : VegaMarkStyle?
  square : VegaMarkStyle?
  trail : VegaMarkStyle?
  text : VegaMarkStyle?
  image : VegaMarkStyle?
  arc : VegaMarkStyle?
  geoshape : VegaMarkStyle?
  boxplot : VegaBoxPlotConfig?
  errorbar : VegaErrorBarConfig?
  errorband : VegaErrorBandConfig?
  scale : VegaScaleConfig?
  axis : VegaAxis?
  axis_x : VegaAxis?
  axis_y : VegaAxis?
  axis_left : VegaAxis?
  axis_right : VegaAxis?
  axis_top : VegaAxis?
  axis_bottom : VegaAxis?
  axis_band : VegaAxis?
  axis_point : VegaAxis?
  axis_discrete : VegaAxis?
  axis_quantitative : VegaAxis?
  axis_temporal : VegaAxis?
  legend : VegaLegend?
  header : VegaHeader?
  header_row : VegaHeader?
  header_column : VegaHeader?
  header_facet : VegaHeader?
  title : VegaTitleParams?
  view : VegaViewConfig?
  projection : VegaProjection?
  selection : VegaSelectionConfig?
  range : VegaRangeConfig?
  priv style : Map[String, VegaMarkStyle]
  concat : VegaCompositionConfig?
  facet : VegaCompositionConfig?
  locale : VegaLocaleConfig?
  format : VegaFormatConfig?
  number_format : String?
  number_format_type : String?
  normalized_number_format : String?
  normalized_number_format_type : String?
  time_format : String?
  time_format_type : String?
  tooltip_format : VegaFormatConfig?
  custom_format_types : Bool?
}

///|
pub extend VegaConfig with Eq::{equal, not_equal}

///|
pub extend VegaConfig with Debug::{to_repr}

///|
/// Build a theme; every property optional. The `style` index maps
/// style names to their mark-style blocks, and is copied at
/// construction.
pub fn VegaConfig::VegaConfig(
  background? : String,
  autosize? : VegaAutoSize,
  padding? : VegaPadding,
  font? : String,
  count_title? : String,
  field_title? : String,
  aria? : Bool,
  line_break? : String,
  params? : Array[Json],
  mark? : VegaMarkStyle,
  bar? : VegaMarkStyle,
  line? : VegaMarkStyle,
  point? : VegaMarkStyle,
  area? : VegaMarkStyle,
  tick? : VegaMarkStyle,
  rect? : VegaMarkStyle,
  rule? : VegaMarkStyle,
  circle? : VegaMarkStyle,
  square? : VegaMarkStyle,
  trail? : VegaMarkStyle,
  text? : VegaMarkStyle,
  image? : VegaMarkStyle,
  arc? : VegaMarkStyle,
  geoshape? : VegaMarkStyle,
  boxplot? : VegaBoxPlotConfig,
  errorbar? : VegaErrorBarConfig,
  errorband? : VegaErrorBandConfig,
  scale? : VegaScaleConfig,
  axis? : VegaAxis,
  axis_x? : VegaAxis,
  axis_y? : VegaAxis,
  axis_left? : VegaAxis,
  axis_right? : VegaAxis,
  axis_top? : VegaAxis,
  axis_bottom? : VegaAxis,
  axis_band? : VegaAxis,
  axis_point? : VegaAxis,
  axis_discrete? : VegaAxis,
  axis_quantitative? : VegaAxis,
  axis_temporal? : VegaAxis,
  legend? : VegaLegend,
  header? : VegaHeader,
  header_row? : VegaHeader,
  header_column? : VegaHeader,
  header_facet? : VegaHeader,
  title? : VegaTitleParams,
  view? : VegaViewConfig,
  projection? : VegaProjection,
  selection? : VegaSelectionConfig,
  range? : VegaRangeConfig,
  style~ : Map[String, VegaMarkStyle] = Map([]),
  concat? : VegaCompositionConfig,
  facet? : VegaCompositionConfig,
  locale? : VegaLocaleConfig,
  format? : VegaFormatConfig,
  number_format? : String,
  number_format_type? : String,
  normalized_number_format? : String,
  normalized_number_format_type? : String,
  time_format? : String,
  time_format_type? : String,
  tooltip_format? : VegaFormatConfig,
  custom_format_types? : Bool,
) -> VegaConfig {
  {
    background,
    autosize,
    padding,
    font,
    count_title,
    field_title,
    aria,
    line_break,
    params: match params {
      Some(ps) => Some(ps.copy())
      None => None
    },
    mark,
    bar,
    line,
    point,
    area,
    tick,
    rect,
    rule,
    circle,
    square,
    trail,
    text,
    image,
    arc,
    geoshape,
    boxplot,
    errorbar,
    errorband,
    scale,
    axis,
    axis_x,
    axis_y,
    axis_left,
    axis_right,
    axis_top,
    axis_bottom,
    axis_band,
    axis_point,
    axis_discrete,
    axis_quantitative,
    axis_temporal,
    legend,
    header,
    header_row,
    header_column,
    header_facet,
    title,
    view,
    projection,
    selection,
    range,
    style: style.copy(),
    concat,
    facet,
    locale,
    format,
    number_format,
    number_format_type,
    normalized_number_format,
    normalized_number_format_type,
    time_format,
    time_format_type,
    tooltip_format,
    custom_format_types,
  }
}

///|
/// The params list, copied — reading the field itself would hand the
/// caller the array the theme holds.
pub fn VegaConfig::params(self : VegaConfig) -> Array[Json]? {
  match self.params {
    Some(ps) => Some(ps.copy())
    None => None
  }
}

///|
/// The style index, copied — reading the field itself would hand the
/// caller the map the theme holds.
pub fn VegaConfig::style(self : VegaConfig) -> Map[String, VegaMarkStyle] {
  self.style.copy()
}

///|
/// The config's JSON object, every set property under its schema key.
fn vega_config_emit_json(c : VegaConfig) -> Json {
  let obj : Map[String, Json] = Map([])
  if c.background is Some(v) {
    obj["background"] = Json::string(v)
  }
  if c.autosize is Some(v) {
    obj["autosize"] = autosize_json(v)
  }
  if c.padding is Some(v) {
    obj["padding"] = padding_json(v)
  }
  if c.font is Some(v) {
    obj["font"] = Json::string(v)
  }
  if c.count_title is Some(v) {
    obj["countTitle"] = Json::string(v)
  }
  if c.field_title is Some(v) {
    obj["fieldTitle"] = Json::string(v)
  }
  if c.aria is Some(v) {
    obj["aria"] = Json::boolean(v)
  }
  if c.line_break is Some(v) {
    obj["lineBreak"] = Json::string(v)
  }
  if c.params is Some(v) {
    obj["params"] = Json::array(v.copy())
  }
  if c.mark is Some(v) {
    obj["mark"] = vega_mark_style_emit_json(v)
  }
  for
    entry in [
      ("bar", c.bar),
      ("line", c.line),
      ("point", c.point),
      ("area", c.area),
      ("tick", c.tick),
      ("rect", c.rect),
      ("rule", c.rule),
      ("circle", c.circle),
      ("square", c.square),
      ("trail", c.trail),
      ("text", c.text),
      ("image", c.image),
      ("arc", c.arc),
      ("geoshape", c.geoshape),
    ] {
    let (key, style) = entry
    if style is Some(v) {
      obj[key] = vega_mark_style_emit_json(v)
    }
  }
  if c.boxplot is Some(v) {
    obj["boxplot"] = vega_box_plot_config_emit_json(v)
  }
  if c.errorbar is Some(v) {
    obj["errorbar"] = vega_error_bar_config_emit_json(v)
  }
  if c.errorband is Some(v) {
    obj["errorband"] = vega_error_band_config_emit_json(v)
  }
  if c.scale is Some(v) {
    obj["scale"] = vega_scale_config_emit_json(v)
  }
  if c.axis is Some(v) {
    obj["axis"] = vega_axis_emit_json(v)
  }
  for
    entry in [
      ("axisX", c.axis_x),
      ("axisY", c.axis_y),
      ("axisLeft", c.axis_left),
      ("axisRight", c.axis_right),
      ("axisTop", c.axis_top),
      ("axisBottom", c.axis_bottom),
      ("axisBand", c.axis_band),
      ("axisPoint", c.axis_point),
      ("axisDiscrete", c.axis_discrete),
      ("axisQuantitative", c.axis_quantitative),
      ("axisTemporal", c.axis_temporal),
    ] {
    let (key, axis) = entry
    if axis is Some(v) {
      obj[key] = vega_axis_emit_json(v)
    }
  }
  if c.legend is Some(v) {
    obj["legend"] = vega_legend_emit_json(v)
  }
  if c.header is Some(v) {
    obj["header"] = vega_header_emit_json(v)
  }
  for
    entry in [
      ("headerRow", c.header_row),
      ("headerColumn", c.header_column),
      ("headerFacet", c.header_facet),
    ] {
    let (key, header) = entry
    if header is Some(v) {
      obj[key] = vega_header_emit_json(v)
    }
  }
  if c.title is Some(v) {
    obj["title"] = vega_title_params_emit_json(v)
  }
  if c.view is Some(v) {
    obj["view"] = vega_view_config_emit_json(v)
  }
  if c.projection is Some(v) {
    obj["projection"] = vega_projection_emit_json(v)
  }
  if c.selection is Some(v) {
    obj["selection"] = vega_selection_config_emit_json(v)
  }
  if c.range is Some(v) {
    obj["range"] = vega_range_config_emit_json(v)
  }
  if c.style.length() > 0 {
    let styles : Map[String, Json] = Map([])
    for entry in c.style {
      let (name, style) = entry
      styles[name] = vega_mark_style_emit_json(style)
    }
    obj["style"] = Json::object(styles)
  }
  if c.concat is Some(v) {
    obj["concat"] = vega_composition_config_emit_json(v)
  }
  if c.facet is Some(v) {
    obj["facet"] = vega_composition_config_emit_json(v)
  }
  if c.locale is Some(v) {
    obj["locale"] = vega_locale_config_emit_json(v)
  }
  if c.format is Some(v) {
    obj["format"] = vega_format_config_emit_json(v)
  }
  if c.number_format is Some(v) {
    obj["numberFormat"] = Json::string(v)
  }
  if c.number_format_type is Some(v) {
    obj["numberFormatType"] = Json::string(v)
  }
  if c.normalized_number_format is Some(v) {
    obj["normalizedNumberFormat"] = Json::string(v)
  }
  if c.normalized_number_format_type is Some(v) {
    obj["normalizedNumberFormatType"] = Json::string(v)
  }
  if c.time_format is Some(v) {
    obj["timeFormat"] = Json::string(v)
  }
  if c.time_format_type is Some(v) {
    obj["timeFormatType"] = Json::string(v)
  }
  if c.tooltip_format is Some(v) {
    obj["tooltipFormat"] = vega_format_config_emit_json(v)
  }
  if c.custom_format_types is Some(v) {
    obj["customFormatTypes"] = Json::boolean(v)
  }
  Json::object(obj)
}
