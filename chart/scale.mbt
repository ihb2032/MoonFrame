// The scale family: a typed mirror of the schema's `Scale` object, transcribed
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
/// A scale type, one variant per schema value.
#derive(Eq, Debug)
pub(all) enum VegaScaleType {
  Linear
  Log
  Pow
  Sqrt
  Symlog
  Identity
  Sequential
  Time
  Utc
  Quantile
  Quantize
  Threshold
  Bin_ordinal
  Ordinal
  Point
  Band
}

///|
pub extend VegaScaleType with Eq::{equal, not_equal}

///|
pub extend VegaScaleType with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_scale_type_string(v : VegaScaleType) -> String {
  match v {
    Linear => "linear"
    Log => "log"
    Pow => "pow"
    Sqrt => "sqrt"
    Symlog => "symlog"
    Identity => "identity"
    Sequential => "sequential"
    Time => "time"
    Utc => "utc"
    Quantile => "quantile"
    Quantize => "quantize"
    Threshold => "threshold"
    Bin_ordinal => "bin-ordinal"
    Ordinal => "ordinal"
    Point => "point"
    Band => "band"
  }
}

///|
/// A named range: width, height, symbol, category, ordinal, ramp, diverging, or heatmap.
#derive(Eq, Debug)
pub(all) enum VegaRangeName {
  Width
  Height
  Symbol
  Category
  Ordinal
  Ramp
  Diverging
  Heatmap
}

///|
pub extend VegaRangeName with Eq::{equal, not_equal}

///|
pub extend VegaRangeName with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_range_name_string(v : VegaRangeName) -> String {
  match v {
    Width => "width"
    Height => "height"
    Symbol => "symbol"
    Category => "category"
    Ordinal => "ordinal"
    Ramp => "ramp"
    Diverging => "diverging"
    Heatmap => "heatmap"
  }
}

///|
/// A scale domain: an explicit list of values, or the "unaggregated" marker (the data's own extent before aggregation).
#derive(Eq, Debug)
pub(all) enum VegaDomain {
  Values(Array[Json])
  Unaggregated
}

///|
pub extend VegaDomain with Eq::{equal, not_equal}

///|
pub extend VegaDomain with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_domain_emit_json(v : VegaDomain) -> Json {
  match v {
    Values(vs) => Json::array(vs.copy())
    Unaggregated => Json::string("unaggregated")
  }
}

///|
/// A scale range: a named one or an explicit list of values.
#derive(Eq, Debug)
pub(all) enum VegaRange {
  Named(VegaRangeName)
  Values(Array[Json])
}

///|
pub extend VegaRange with Eq::{equal, not_equal}

///|
pub extend VegaRange with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_range_emit_json(v : VegaRange) -> Json {
  match v {
    Named(n) => Json::string(vega_range_name_string(n))
    Values(vs) => Json::array(vs.copy())
  }
}

///|
/// The parameter form of a color scheme: the scheme's name, an extent
/// pair into a diverging scheme, and a color count for discrete ones. The
/// `extent` array is copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaSchemeParams {
  name : String?
  priv extent : Array[Double]?
  count : Double?
}

///|
pub extend VegaSchemeParams with Eq::{equal, not_equal}

///|
pub extend VegaSchemeParams with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaSchemeParams::VegaSchemeParams(
  name? : String,
  extent? : Array[Double],
  count? : Double,
) -> VegaSchemeParams {
  {
    name,
    extent: match extent {
      Some(a) => Some(a.copy())
      None => None
    },
    count,
  }
}

///|
/// The `extent` values, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaSchemeParams::extent(self : VegaSchemeParams) -> Array[Double]? {
  match self.extent {
    Some(a) => Some(a.copy())
    None => None
  }
}

///|
/// The emitted JSON object of a `VegaSchemeParams`, every set property
/// under its schema key.
fn vega_scheme_params_emit_json(x : VegaSchemeParams) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.name is Some(v) {
    obj["name"] = Json::string(v)
  }
  if x.extent is Some(v) {
    obj["extent"] = Json::array(v.map(fn(n) { Json::number(n) }))
  }
  if x.count is Some(v) {
    obj["count"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// A color scheme: its name, or the parameter form with extent / count.
#derive(Eq, Debug)
pub(all) enum VegaScheme {
  Name(String)
  Params(VegaSchemeParams)
}

///|
pub extend VegaScheme with Eq::{equal, not_equal}

///|
pub extend VegaScheme with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_scheme_emit_json(v : VegaScheme) -> Json {
  match v {
    Name(n) => Json::string(n)
    Params(p) => vega_scheme_params_emit_json(p)
  }
}

///|
/// A calendar interval, one variant per schema value.
#derive(Eq, Debug)
pub(all) enum VegaTimeInterval {
  Millisecond
  Second
  Minute
  Hour
  Day
  Week
  Month
  Year
}

///|
pub extend VegaTimeInterval with Eq::{equal, not_equal}

///|
pub extend VegaTimeInterval with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_time_interval_string(v : VegaTimeInterval) -> String {
  match v {
    Millisecond => "millisecond"
    Second => "second"
    Minute => "minute"
    Hour => "hour"
    Day => "day"
    Week => "week"
    Month => "month"
    Year => "year"
  }
}

///|
/// A tick count or spacing: a plain count, a calendar interval, or an interval with a step multiplier.
#derive(Eq, Debug)
pub(all) enum VegaTickInterval {
  Count(Double)
  Interval(VegaTimeInterval)
  Step(VegaTimeInterval, Double)
}

///|
pub extend VegaTickInterval with Eq::{equal, not_equal}

///|
pub extend VegaTickInterval with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_tick_interval_emit_json(v : VegaTickInterval) -> Json {
  match v {
    Count(n) => Json::number(n)
    Interval(i) => Json::string(vega_time_interval_string(i))
    Step(interval, step) => {
      let obj : Map[String, Json] = Map([])
      obj["interval"] = Json::string(vega_time_interval_string(interval))
      obj["step"] = Json::number(step)
      Json::object(obj)
    }
  }
}

///|
/// A nice-domain setting: the boolean, a tick count, a calendar interval, or an interval with a step multiplier.
#derive(Eq, Debug)
pub(all) enum VegaNice {
  Bool(Bool)
  Ticks(Double)
  Interval(VegaTimeInterval)
  Step(VegaTimeInterval, Double)
}

///|
pub extend VegaNice with Eq::{equal, not_equal}

///|
pub extend VegaNice with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_nice_emit_json(v : VegaNice) -> Json {
  match v {
    Bool(b) => Json::boolean(b)
    Ticks(n) => Json::number(n)
    Interval(i) => Json::string(vega_time_interval_string(i))
    Step(interval, step) => {
      let obj : Map[String, Json] = Map([])
      obj["interval"] = Json::string(vega_time_interval_string(interval))
      obj["step"] = Json::number(step)
      Json::object(obj)
    }
  }
}

///|
/// A color interpolation, one variant per schema value.
#derive(Eq, Debug)
pub(all) enum VegaInterpolateKind {
  Rgb
  Lab
  Hcl
  Hsl
  Hsl_long
  Hcl_long
  Cubehelix
  Cubehelix_long
}

///|
pub extend VegaInterpolateKind with Eq::{equal, not_equal}

///|
pub extend VegaInterpolateKind with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_interpolate_kind_string(v : VegaInterpolateKind) -> String {
  match v {
    Rgb => "rgb"
    Lab => "lab"
    Hcl => "hcl"
    Hsl => "hsl"
    Hsl_long => "hsl-long"
    Hcl_long => "hcl-long"
    Cubehelix => "cubehelix"
    Cubehelix_long => "cubehelix-long"
  }
}

///|
/// The interpolation kinds the parameter form may name — the schema's
/// `ScaleInterpolateParams.type` enum, narrower than the named kinds
/// (`VegaInterpolateKind`): the parameter form carries the gamma-carrying
/// rgb and cubehelix interpolations alone. `pub(all)` so callers can name
/// the variants.
#derive(Eq, Debug)
pub(all) enum VegaInterpolateParamType {
  Rgb
  Cubehelix
  Cubehelix_long
}

///|
pub extend VegaInterpolateParamType with Eq::{equal, not_equal}

///|
pub extend VegaInterpolateParamType with Debug::{to_repr}

///|
/// The schema string for each variant, one arm per variant.
fn vega_interpolate_param_type_string(v : VegaInterpolateParamType) -> String {
  match v {
    Rgb => "rgb"
    Cubehelix => "cubehelix"
    Cubehelix_long => "cubehelix-long"
  }
}

///|
/// The parameter form of an rgb / cubehelix interpolation: the kind
/// (required — the schema's `ScaleInterpolateParams` demands its `type`)
/// and a gamma.
#derive(Eq, Debug)
pub struct VegaInterpolateParams {
  type_ : VegaInterpolateParamType
  gamma : Double?
}

///|
pub extend VegaInterpolateParams with Eq::{equal, not_equal}

///|
pub extend VegaInterpolateParams with Debug::{to_repr}

///|
/// Build one: the interpolation kind is required (an emission without
/// one is a spec the schema would reject), the gamma optional.
pub fn VegaInterpolateParams::VegaInterpolateParams(
  type_~ : VegaInterpolateParamType,
  gamma? : Double,
) -> VegaInterpolateParams {
  { type_, gamma, }
}

///|
/// The emitted JSON object of a `VegaInterpolateParams`, every set property
/// under its schema key.
fn vega_interpolate_params_emit_json(x : VegaInterpolateParams) -> Json {
  let obj : Map[String, Json] = Map([])
  obj["type"] = Json::string(vega_interpolate_param_type_string(x.type_))
  if x.gamma is Some(v) {
    obj["gamma"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// A scale interpolation: a named kind, or an rgb / cubehelix
/// interpolation with a gamma.
#derive(Eq, Debug)
pub(all) enum VegaInterpolate {
  Kind(VegaInterpolateKind)
  Params(VegaInterpolateParams)
}

///|
pub extend VegaInterpolate with Eq::{equal, not_equal}

///|
pub extend VegaInterpolate with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_interpolate_emit_json(v : VegaInterpolate) -> Json {
  match v {
    Kind(k) => Json::string(vega_interpolate_kind_string(k))
    Params(p) => vega_interpolate_params_emit_json(p)
  }
}

///|
/// Explicit bin boundaries for a scale: a step size, or start and stop bounds.
#derive(Eq, Debug)
pub struct VegaBinsParams {
  step : Double?
  start : Double?
  stop : Double?
}

///|
pub extend VegaBinsParams with Eq::{equal, not_equal}

///|
pub extend VegaBinsParams with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaBinsParams::VegaBinsParams(
  step? : Double,
  start? : Double,
  stop? : Double,
) -> VegaBinsParams {
  { step, start, stop, }
}

///|
/// The emitted JSON object of a `VegaBinsParams`, every set property
/// under its schema key.
fn vega_bins_params_emit_json(x : VegaBinsParams) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.step is Some(v) {
    obj["step"] = Json::number(v)
  }
  if x.start is Some(v) {
    obj["start"] = Json::number(v)
  }
  if x.stop is Some(v) {
    obj["stop"] = Json::number(v)
  }
  Json::object(obj)
}

///|
/// Scale bins: an explicit list of boundary values, or the parameter form.
#derive(Eq, Debug)
pub(all) enum VegaBins {
  Values(Array[Double])
  Params(VegaBinsParams)
}

///|
pub extend VegaBins with Eq::{equal, not_equal}

///|
pub extend VegaBins with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_bins_emit_json(v : VegaBins) -> Json {
  match v {
    Values(vs) => Json::array(vs.map(fn(n) { Json::number(n) }))
    Params(p) => vega_bins_params_emit_json(p)
  }
}

///|
/// A range endpoint: a number or a named value (a discrete scale's named range).
#derive(Eq, Debug)
pub(all) enum VegaRangeBound {
  Number(Double)
  Named(String)
}

///|
pub extend VegaRangeBound with Eq::{equal, not_equal}

///|
pub extend VegaRangeBound with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_range_bound_emit_json(v : VegaRangeBound) -> Json {
  match v {
    Number(n) => Json::number(n)
    Named(s) => Json::string(s)
  }
}

///|
/// A scale definition, the schema's `Scale` in full static form: the
/// type (a log y-axis, a band x-axis), the domain (explicit values or the
/// unaggregated marker), the range (named or explicit), a color scheme with
/// its extent / count parameters, niceness (a boolean, a tick count, or a
/// calendar interval with a step), interpolation, zero / clamp / reverse /
/// round, the numeric-typed extras (an exponent, a log base, a symlog
/// constant), the band geometry (align, paddings), and explicit bins. Each
/// property is optional; unset ones fall to the runtime's defaults. The
/// array-carrying ones (`domain` values, `range` values, `bins` values) are
/// copied at construction and copied again on read.
#derive(Eq, Debug)
pub struct VegaScale {
  type_ : VegaScaleType?
  domain : VegaDomain?
  domain_min : Double?
  domain_max : Double?
  domain_mid : Double?
  range : VegaRange?
  range_min : VegaRangeBound?
  range_max : VegaRangeBound?
  scheme : VegaScheme?
  reverse : Bool?
  round : Bool?
  clamp : Bool?
  zero : Bool?
  exponent : Double?
  base : Double?
  constant : Double?
  interpolate : VegaInterpolate?
  nice : VegaNice?
  align : Double?
  padding : Double?
  padding_inner : Double?
  padding_outer : Double?
  bins : VegaBins?
}

///|
pub extend VegaScale with Eq::{equal, not_equal}

///|
pub extend VegaScale with Debug::{to_repr}

///|
/// Build one with every property optional; the array
/// properties are copied, so an array the caller mutates
/// afterwards cannot move a chart already built.
pub fn VegaScale::VegaScale(
  type_? : VegaScaleType,
  domain? : VegaDomain,
  domain_min? : Double,
  domain_max? : Double,
  domain_mid? : Double,
  range? : VegaRange,
  range_min? : VegaRangeBound,
  range_max? : VegaRangeBound,
  scheme? : VegaScheme,
  reverse? : Bool,
  round? : Bool,
  clamp? : Bool,
  zero? : Bool,
  exponent? : Double,
  base? : Double,
  constant? : Double,
  interpolate? : VegaInterpolate,
  nice? : VegaNice,
  align? : Double,
  padding? : Double,
  padding_inner? : Double,
  padding_outer? : Double,
  bins? : VegaBins,
) -> VegaScale {
  {
    type_,
    domain,
    domain_min,
    domain_max,
    domain_mid,
    range,
    range_min,
    range_max,
    scheme,
    reverse,
    round,
    clamp,
    zero,
    exponent,
    base,
    constant,
    interpolate,
    nice,
    align,
    padding,
    padding_inner,
    padding_outer,
    bins,
  }
}

///|
/// The emitted JSON object of a `VegaScale`, every set property
/// under its schema key.
fn vega_scale_emit_json(x : VegaScale) -> Json {
  let obj : Map[String, Json] = Map([])
  if x.type_ is Some(v) {
    obj["type"] = Json::string(vega_scale_type_string(v))
  }
  if x.domain is Some(v) {
    obj["domain"] = vega_domain_emit_json(v)
  }
  if x.domain_min is Some(v) {
    obj["domainMin"] = Json::number(v)
  }
  if x.domain_max is Some(v) {
    obj["domainMax"] = Json::number(v)
  }
  if x.domain_mid is Some(v) {
    obj["domainMid"] = Json::number(v)
  }
  if x.range is Some(v) {
    obj["range"] = vega_range_emit_json(v)
  }
  if x.range_min is Some(v) {
    obj["rangeMin"] = vega_range_bound_emit_json(v)
  }
  if x.range_max is Some(v) {
    obj["rangeMax"] = vega_range_bound_emit_json(v)
  }
  if x.scheme is Some(v) {
    obj["scheme"] = vega_scheme_emit_json(v)
  }
  if x.reverse is Some(v) {
    obj["reverse"] = Json::boolean(v)
  }
  if x.round is Some(v) {
    obj["round"] = Json::boolean(v)
  }
  if x.clamp is Some(v) {
    obj["clamp"] = Json::boolean(v)
  }
  if x.zero is Some(v) {
    obj["zero"] = Json::boolean(v)
  }
  if x.exponent is Some(v) {
    obj["exponent"] = Json::number(v)
  }
  if x.base is Some(v) {
    obj["base"] = Json::number(v)
  }
  if x.constant is Some(v) {
    obj["constant"] = Json::number(v)
  }
  if x.interpolate is Some(v) {
    obj["interpolate"] = vega_interpolate_emit_json(v)
  }
  if x.nice is Some(v) {
    obj["nice"] = vega_nice_emit_json(v)
  }
  if x.align is Some(v) {
    obj["align"] = Json::number(v)
  }
  if x.padding is Some(v) {
    obj["padding"] = Json::number(v)
  }
  if x.padding_inner is Some(v) {
    obj["paddingInner"] = Json::number(v)
  }
  if x.padding_outer is Some(v) {
    obj["paddingOuter"] = Json::number(v)
  }
  if x.bins is Some(v) {
    obj["bins"] = vega_bins_emit_json(v)
  }
  Json::object(obj)
}

///|
/// A channel's scale: a configuration, or `Off` (the schema's `null`, which removes the scale and plots values as given).
#derive(Eq, Debug)
pub(all) enum VegaScaleRef {
  Off
  Config(VegaScale)
}

///|
pub extend VegaScaleRef with Eq::{equal, not_equal}

///|
pub extend VegaScaleRef with Debug::{to_repr}

///|
/// The JSON of each form, per the schema's union arms.
fn vega_scale_ref_emit_json(v : VegaScaleRef) -> Json {
  match v {
    Off => Json::null()
    Config(s) => vega_scale_emit_json(s)
  }
}
