// The composition layer: a `Chart` is either a single view (a `ChartSpec`)
// or a composition operator over child charts — layering, vertical /
// horizontal / wrapped concatenation, faceting, and repetition — and every
// child shares the frame the top-level call inlines as `data.values`.
// The wrappers mirror the schema's own operator specs (`LayerSpec`,
// `ConcatSpec`, `FacetSpec`, `RepeatSpec`): each carries exactly the
// chrome and layout its operator supports, the resolve block for shared
// versus independent scales / axes / legends, and typed row / column
// unions for the alignment, centering, and spacing. Transcribed from the
// vendored vega_lite_v6_5_0.schema.json and schema-walked through the
// corpus guard; every type but `Chart` itself is deep-family, reached
// through `@chart` qualification.

///|
/// A resolve mode: `Independent → "independent"` (each sub-view its own)
/// and `Shared → "shared"` (one for the composition). `pub(all)` so
/// callers can name the variants inside a resolve map.
#derive(Eq, Debug)
pub(all) enum VegaResolveMode {
  Independent
  Shared
}

///|
pub extend VegaResolveMode with Eq::{equal, not_equal}

///|
pub extend VegaResolveMode with Debug::{to_repr}

///|
/// The resolve mode's schema string.
fn vega_resolve_mode_string(v : VegaResolveMode) -> String {
  match v {
    Independent => "independent"
    Shared => "shared"
  }
}

///|
/// A side setting for one value: row, column, or both.
#derive(Eq, Debug)
pub struct VegaRowColDouble {
  row : Double?
  column : Double?
}

///|
pub extend VegaRowColDouble with Eq::{equal, not_equal}

///|
pub extend VegaRowColDouble with Debug::{to_repr}

///|
/// A per-side spacing.
pub fn VegaRowColDouble::VegaRowColDouble(
  row? : Double,
  column? : Double,
) -> VegaRowColDouble {
  { row, column, }
}

///|
/// A per-side boolean (a centering flag).
#derive(Eq, Debug)
pub struct VegaRowColBool {
  row : Bool?
  column : Bool?
}

///|
pub extend VegaRowColBool with Eq::{equal, not_equal}

///|
pub extend VegaRowColBool with Debug::{to_repr}

///|
/// A per-side centering flag.
pub fn VegaRowColBool::VegaRowColBool(
  row? : Bool,
  column? : Bool,
) -> VegaRowColBool {
  { row, column, }
}

///|
/// A per-side alignment.
#derive(Eq, Debug)
pub struct VegaRowColAlign {
  row : VegaLayoutAlign?
  column : VegaLayoutAlign?
}

///|
pub extend VegaRowColAlign with Eq::{equal, not_equal}

///|
pub extend VegaRowColAlign with Debug::{to_repr}

///|
/// A per-side alignment.
pub fn VegaRowColAlign::VegaRowColAlign(
  row? : VegaLayoutAlign,
  column? : VegaLayoutAlign,
) -> VegaRowColAlign {
  { row, column, }
}

///|
/// A composition's sub-view spacing: one number, or per-side values.
#derive(Eq, Debug)
pub(all) enum VegaSpacing {
  Px(Double)
  Sides(VegaRowColDouble)
}

///|
pub extend VegaSpacing with Eq::{equal, not_equal}

///|
pub extend VegaSpacing with Debug::{to_repr}

///|
/// A composition's centering: one flag for both sides, or per-side flags.
#derive(Eq, Debug)
pub(all) enum VegaCenter {
  All(Bool)
  Sides(VegaRowColBool)
}

///|
pub extend VegaCenter with Eq::{equal, not_equal}

///|
pub extend VegaCenter with Debug::{to_repr}

///|
/// A composition's alignment: one mode for both sides, or per-side modes.
#derive(Eq, Debug)
pub(all) enum VegaAlignMode {
  Layout(VegaLayoutAlign)
  Sides(VegaRowColAlign)
}

///|
pub extend VegaAlignMode with Eq::{equal, not_equal}

///|
pub extend VegaAlignMode with Debug::{to_repr}

///|
/// A composition's bounds calculation: `Full → "full"` (the default,
// each sub-view sized to its full extent) and `Flush → "flush"` (the

///|
/// sub-views' outer edges only, for tighter grids).
#derive(Eq, Debug)
pub(all) enum VegaBounds {
  Full
  Flush
}

///|
pub extend VegaBounds with Eq::{equal, not_equal}

///|
pub extend VegaBounds with Debug::{to_repr}

///|
/// The scale-resolution block of a composition: which channels resolve
/// independently and which share one scale, per channel. A channel left
/// unset follows the composition's default.
#derive(Eq, Debug)
pub struct VegaScaleResolve {
  x : VegaResolveMode?
  y : VegaResolveMode?
  color : VegaResolveMode?
  fill : VegaResolveMode?
  stroke : VegaResolveMode?
  opacity : VegaResolveMode?
  fill_opacity : VegaResolveMode?
  stroke_opacity : VegaResolveMode?
  stroke_width : VegaResolveMode?
  stroke_dash : VegaResolveMode?
  size : VegaResolveMode?
  shape : VegaResolveMode?
  angle : VegaResolveMode?
  theta : VegaResolveMode?
  radius : VegaResolveMode?
  x_offset : VegaResolveMode?
  y_offset : VegaResolveMode?
}

///|
pub extend VegaScaleResolve with Eq::{equal, not_equal}

///|
pub extend VegaScaleResolve with Debug::{to_repr}

///|
/// Build a per-channel scale-resolution block; every channel optional.
pub fn VegaScaleResolve::VegaScaleResolve(
  x? : VegaResolveMode,
  y? : VegaResolveMode,
  color? : VegaResolveMode,
  fill? : VegaResolveMode,
  stroke? : VegaResolveMode,
  opacity? : VegaResolveMode,
  fill_opacity? : VegaResolveMode,
  stroke_opacity? : VegaResolveMode,
  stroke_width? : VegaResolveMode,
  stroke_dash? : VegaResolveMode,
  size? : VegaResolveMode,
  shape? : VegaResolveMode,
  angle? : VegaResolveMode,
  theta? : VegaResolveMode,
  radius? : VegaResolveMode,
  x_offset? : VegaResolveMode,
  y_offset? : VegaResolveMode,
) -> VegaScaleResolve {
  {
    x,
    y,
    color,
    fill,
    stroke,
    opacity,
    fill_opacity,
    stroke_opacity,
    stroke_width,
    stroke_dash,
    size,
    shape,
    angle,
    theta,
    radius,
    x_offset,
    y_offset,
  }
}

///|
/// The axis-resolution block of a composition: the two position axes.
#derive(Eq, Debug)
pub struct VegaAxisResolve {
  x : VegaResolveMode?
  y : VegaResolveMode?
}

///|
pub extend VegaAxisResolve with Eq::{equal, not_equal}

///|
pub extend VegaAxisResolve with Debug::{to_repr}

///|
/// Build a per-axis resolution block; each axis optional.
pub fn VegaAxisResolve::VegaAxisResolve(
  x? : VegaResolveMode,
  y? : VegaResolveMode,
) -> VegaAxisResolve {
  { x, y, }
}

///|
/// The legend-resolution block of a composition: which mark-property
/// channels share one legend across sub-views.
#derive(Eq, Debug)
pub struct VegaLegendResolve {
  color : VegaResolveMode?
  fill : VegaResolveMode?
  stroke : VegaResolveMode?
  opacity : VegaResolveMode?
  fill_opacity : VegaResolveMode?
  stroke_opacity : VegaResolveMode?
  stroke_width : VegaResolveMode?
  stroke_dash : VegaResolveMode?
  size : VegaResolveMode?
  shape : VegaResolveMode?
  angle : VegaResolveMode?
}

///|
pub extend VegaLegendResolve with Eq::{equal, not_equal}

///|
pub extend VegaLegendResolve with Debug::{to_repr}

///|
/// Build a per-channel legend-resolution block; every channel optional.
pub fn VegaLegendResolve::VegaLegendResolve(
  color? : VegaResolveMode,
  fill? : VegaResolveMode,
  stroke? : VegaResolveMode,
  opacity? : VegaResolveMode,
  fill_opacity? : VegaResolveMode,
  stroke_opacity? : VegaResolveMode,
  stroke_width? : VegaResolveMode,
  stroke_dash? : VegaResolveMode,
  size? : VegaResolveMode,
  shape? : VegaResolveMode,
  angle? : VegaResolveMode,
) -> VegaLegendResolve {
  {
    color,
    fill,
    stroke,
    opacity,
    fill_opacity,
    stroke_opacity,
    stroke_width,
    stroke_dash,
    size,
    shape,
    angle,
  }
}

///|
/// A composition's resolve block: scale, axis, and legend resolution.
#derive(Eq, Debug)
pub struct VegaResolve {
  scale : VegaScaleResolve?
  axis : VegaAxisResolve?
  legend : VegaLegendResolve?
}

///|
pub extend VegaResolve with Eq::{equal, not_equal}

///|
pub extend VegaResolve with Debug::{to_repr}

///|
/// Build a resolve block; each half optional.
pub fn VegaResolve::VegaResolve(
  scale? : VegaScaleResolve,
  axis? : VegaAxisResolve,
  legend? : VegaLegendResolve,
) -> VegaResolve {
  { scale, axis, legend, }
}

///|
/// A layered chart: one `layer` array of child charts drawn in the same
/// coordinate system (a line over its points, a rule over the bars), plus
/// the chrome a layer spec carries — `title`, `name`, `description`,
/// `width` / `height`, the `view` background, a `projection`, and the
/// `resolve` block. The children are copied at construction, so an array
/// the caller mutates afterwards cannot move a chart already built; read
/// them back through `layer`, which copies again.
#derive(Eq, Debug)
pub struct VegaLayer {
  priv layer : Array[Chart]
  title : VegaTitle?
  name : String?
  description : String?
  width : VegaExtent?
  height : VegaExtent?
  view : VegaViewBackground?
  projection : VegaProjection?
  resolve : VegaResolve?
  priv transform : Array[VegaTransform]?
}

///|
pub extend VegaLayer with Eq::{equal, not_equal}

///|
pub extend VegaLayer with Debug::{to_repr}

///|
/// Layer the given charts, one over the next in order, sharing the frame
/// the top-level call inlines. The array is copied; the rest optional.
pub fn VegaLayer::VegaLayer(
  layer : Array[Chart],
  title? : VegaTitle,
  name? : String,
  description? : String,
  width? : VegaExtent,
  height? : VegaExtent,
  view? : VegaViewBackground,
  projection? : VegaProjection,
  resolve? : VegaResolve,
  transform? : Array[VegaTransform],
) -> VegaLayer {
  {
    layer: layer.copy(),
    title,
    name,
    description,
    width,
    height,
    view,
    projection,
    resolve,
    transform: match transform {
      Some(ts) => Some(ts.copy())
      None => None
    },
  }
}

///|
/// The layered children, copied — reading the field itself would hand
/// the caller the array the chart holds.
pub fn VegaLayer::layer(self : VegaLayer) -> Array[Chart] {
  self.layer.copy()
}

///|
/// A concatenated chart — `VConcat` stacks its children vertically,
/// `HConcat` lays them out horizontally, and `Concat` wraps them into a
/// grid with a `columns` count — plus the layout a concat spec carries
/// (alignment, bounds, centering, spacing, the wrap column count) and
/// the chrome (`title`, `name`, `description`, `resolve`). The children
/// are copied at construction; read them back through `concat`, which
/// copies again.
#derive(Eq, Debug)
pub struct VegaConcat {
  priv concat : Array[Chart]
  align : VegaAlignMode?
  bounds : VegaBounds?
  center : VegaCenter?
  spacing : VegaSpacing?
  columns : Double?
  title : VegaTitle?
  name : String?
  description : String?
  resolve : VegaResolve?
  priv transform : Array[VegaTransform]?
}

///|
pub extend VegaConcat with Eq::{equal, not_equal}

///|
pub extend VegaConcat with Debug::{to_repr}

///|
/// Concatenate the given charts; the array is copied, the rest optional.
/// `columns` is the wrap count of a `Concat` grid (a `VConcat` /
/// `HConcat` ignores it — their direction fixes the layout).
pub fn VegaConcat::VegaConcat(
  concat : Array[Chart],
  align? : VegaAlignMode,
  bounds? : VegaBounds,
  center? : VegaCenter,
  spacing? : VegaSpacing,
  columns? : Double,
  title? : VegaTitle,
  name? : String,
  description? : String,
  resolve? : VegaResolve,
  transform? : Array[VegaTransform],
) -> VegaConcat {
  {
    concat: concat.copy(),
    align,
    bounds,
    center,
    spacing,
    columns,
    title,
    name,
    description,
    resolve,
    transform: match transform {
      Some(ts) => Some(ts.copy())
      None => None
    },
  }
}

///|
/// The concatenated children, copied for the same reason.
pub fn VegaConcat::concat(self : VegaConcat) -> Array[Chart] {
  self.concat.copy()
}

///|
/// A faceted chart: small multiples of the child `spec`, one per value of
/// the `row` / `column` facet channels (a group-by drawn as a grid),
/// plus the layout a facet spec carries and the chrome. The child
/// renders against the same frame as the whole chart.
#derive(Eq, Debug)
pub struct VegaFacet {
  row : VegaFacetChannel?
  column : VegaFacetChannel?
  spec : Chart
  align : VegaAlignMode?
  bounds : VegaBounds?
  center : VegaCenter?
  spacing : VegaSpacing?
  columns : Double?
  title : VegaTitle?
  name : String?
  description : String?
  resolve : VegaResolve?
  priv transform : Array[VegaTransform]?
}

///|
pub extend VegaFacet with Eq::{equal, not_equal}

///|
pub extend VegaFacet with Debug::{to_repr}

///|
/// Facet the given child chart by a `row` and / or `column` channel; the
/// rest of the layout and chrome is optional.
pub fn VegaFacet::VegaFacet(
  spec : Chart,
  row? : VegaFacetChannel,
  column? : VegaFacetChannel,
  align? : VegaAlignMode,
  bounds? : VegaBounds,
  center? : VegaCenter,
  spacing? : VegaSpacing,
  columns? : Double,
  title? : VegaTitle,
  name? : String,
  description? : String,
  resolve? : VegaResolve,
  transform? : Array[VegaTransform],
) -> VegaFacet {
  {
    row,
    column,
    spec,
    align,
    bounds,
    center,
    spacing,
    columns,
    title,
    name,
    description,
    resolve,
    transform: match transform {
      Some(ts) => Some(ts.copy())
      None => None
    },
  }
}

///|
/// A repeated chart: the child `spec` re-rendered once per field of the
/// `row` and / or `column` field lists (the same mark over many columns,
/// no encoding change needed), plus the layout and chrome. The field
/// lists are copied at construction; read them back through `row` /
/// `column`, which copy again.
#derive(Eq, Debug)
pub struct VegaRepeat {
  priv row : Array[String]?
  priv column : Array[String]?
  spec : Chart
  align : VegaAlignMode?
  bounds : VegaBounds?
  center : VegaCenter?
  spacing : VegaSpacing?
  columns : Double?
  title : VegaTitle?
  name : String?
  description : String?
  resolve : VegaResolve?
  priv transform : Array[VegaTransform]?
}

///|
pub extend VegaRepeat with Eq::{equal, not_equal}

///|
pub extend VegaRepeat with Debug::{to_repr}

///|
/// Repeat the given child chart over `row` and / or `column` field
/// lists; the arrays are copied, the rest of the layout optional.
pub fn VegaRepeat::VegaRepeat(
  spec : Chart,
  row? : Array[String],
  column? : Array[String],
  align? : VegaAlignMode,
  bounds? : VegaBounds,
  center? : VegaCenter,
  spacing? : VegaSpacing,
  columns? : Double,
  title? : VegaTitle,
  name? : String,
  description? : String,
  resolve? : VegaResolve,
  transform? : Array[VegaTransform],
) -> VegaRepeat {
  {
    row: match row {
      Some(r) => Some(r.copy())
      None => None
    },
    column: match column {
      Some(c) => Some(c.copy())
      None => None
    },
    spec,
    align,
    bounds,
    center,
    spacing,
    columns,
    title,
    name,
    description,
    resolve,
    transform: match transform {
      Some(ts) => Some(ts.copy())
      None => None
    },
  }
}

///|
/// The repeated-over row fields, copied.
pub fn VegaRepeat::row(self : VegaRepeat) -> Array[String]? {
  match self.row {
    Some(r) => Some(r.copy())
    None => None
  }
}

///|
/// The repeated-over column fields, copied.
pub fn VegaRepeat::column(self : VegaRepeat) -> Array[String]? {
  match self.column {
    Some(c) => Some(c.copy())
    None => None
  }
}

///|
/// A chart: a single view (a `ChartSpec`, wrapped through `Chart::of`)
/// or a composition over child charts — `Layer` (children in one
/// coordinate system), `VConcat` / `HConcat` / `Concat` (a vertical,
/// horizontal, or wrapped grid), `Facet` (small multiples by a row /
/// column channel), and `Repeat` (the same view over a field list).
/// Compositions nest: a concat's child may itself be a layer or a
/// facet. `pub(all)` so callers build the variants; `Chart::of` wraps a
/// single view, and the operator constructors (`VegaLayer::VegaLayer`,
/// …) build the compositions.
#derive(Eq, Debug)
pub(all) enum Chart {
  Single(ChartSpec)
  Layer(VegaLayer)
  VConcat(VegaConcat)
  HConcat(VegaConcat)
  Concat(VegaConcat)
  Facet(VegaFacet)
  Repeat(VegaRepeat)
}

///|
pub extend Chart with Eq::{equal, not_equal}

///|
pub extend Chart with Debug::{to_repr}

///|
/// A single-view chart from a `ChartSpec` — the wrap `format_vega_lite`
/// callers hand a bare spec through.
pub fn Chart::of(spec : ChartSpec) -> Chart {
  Single(spec)
}

///|
/// The JSON of a composition's alignment: one mode or the per-side
/// object with the sides that are set.
fn vega_align_mode_emit_json(v : VegaAlignMode) -> Json {
  match v {
    Layout(m) => Json::string(vega_layout_align_string(m))
    Sides(sides) => {
      let obj : Map[String, Json] = Map([])
      if sides.row is Some(row) {
        obj["row"] = Json::string(vega_layout_align_string(row))
      }
      if sides.column is Some(column) {
        obj["column"] = Json::string(vega_layout_align_string(column))
      }
      Json::object(obj)
    }
  }
}

///|
/// The JSON of a composition's centering: one flag or the per-side
/// object.
fn vega_center_emit_json(v : VegaCenter) -> Json {
  match v {
    All(b) => Json::boolean(b)
    Sides(sides) => {
      let obj : Map[String, Json] = Map([])
      if sides.row is Some(row) {
        obj["row"] = Json::boolean(row)
      }
      if sides.column is Some(column) {
        obj["column"] = Json::boolean(column)
      }
      Json::object(obj)
    }
  }
}

///|
/// The JSON of a composition's spacing: one number or the per-side
/// object.
fn vega_spacing_emit_json(v : VegaSpacing) -> Json {
  match v {
    Px(n) => Json::number(n)
    Sides(sides) => {
      let obj : Map[String, Json] = Map([])
      if sides.row is Some(row) {
        obj["row"] = Json::number(row)
      }
      if sides.column is Some(column) {
        obj["column"] = Json::number(column)
      }
      Json::object(obj)
    }
  }
}

///|
/// The schema string of a bounds calculation.
fn vega_bounds_string(v : VegaBounds) -> String {
  match v {
    Full => "full"
    Flush => "flush"
  }
}

///|
/// The JSON of a resolve block: the scale / axis / legend maps with the
/// channels that are set.
fn vega_resolve_emit_json(v : VegaResolve) -> Json {
  let obj : Map[String, Json] = Map([])
  if v.scale is Some(scale) {
    let m : Map[String, Json] = Map([])
    put_resolve_mode(m, "x", scale.x)
    put_resolve_mode(m, "y", scale.y)
    put_resolve_mode(m, "color", scale.color)
    put_resolve_mode(m, "fill", scale.fill)
    put_resolve_mode(m, "stroke", scale.stroke)
    put_resolve_mode(m, "opacity", scale.opacity)
    put_resolve_mode(m, "fillOpacity", scale.fill_opacity)
    put_resolve_mode(m, "strokeOpacity", scale.stroke_opacity)
    put_resolve_mode(m, "strokeWidth", scale.stroke_width)
    put_resolve_mode(m, "strokeDash", scale.stroke_dash)
    put_resolve_mode(m, "size", scale.size)
    put_resolve_mode(m, "shape", scale.shape)
    put_resolve_mode(m, "angle", scale.angle)
    put_resolve_mode(m, "theta", scale.theta)
    put_resolve_mode(m, "radius", scale.radius)
    put_resolve_mode(m, "xOffset", scale.x_offset)
    put_resolve_mode(m, "yOffset", scale.y_offset)
    obj["scale"] = Json::object(m)
  }
  if v.axis is Some(axis) {
    let m : Map[String, Json] = Map([])
    put_resolve_mode(m, "x", axis.x)
    put_resolve_mode(m, "y", axis.y)
    obj["axis"] = Json::object(m)
  }
  if v.legend is Some(legend) {
    let m : Map[String, Json] = Map([])
    put_resolve_mode(m, "color", legend.color)
    put_resolve_mode(m, "fill", legend.fill)
    put_resolve_mode(m, "stroke", legend.stroke)
    put_resolve_mode(m, "opacity", legend.opacity)
    put_resolve_mode(m, "fillOpacity", legend.fill_opacity)
    put_resolve_mode(m, "strokeOpacity", legend.stroke_opacity)
    put_resolve_mode(m, "strokeWidth", legend.stroke_width)
    put_resolve_mode(m, "strokeDash", legend.stroke_dash)
    put_resolve_mode(m, "size", legend.size)
    put_resolve_mode(m, "shape", legend.shape)
    put_resolve_mode(m, "angle", legend.angle)
    obj["legend"] = Json::object(m)
  }
  Json::object(obj)
}

///|
/// One resolve-mode entry, present only when set.
fn put_resolve_mode(
  obj : Map[String, Json],
  key : String,
  mode : VegaResolveMode?,
) -> Unit {
  if mode is Some(m) {
    obj[key] = Json::string(vega_resolve_mode_string(m))
  }
}
