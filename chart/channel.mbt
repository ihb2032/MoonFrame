// The encoding-channel family: the `VegaChannel` definition a chart's
// channels are built from, the enums its modifiers name, and the free
// functions that build one. The property lists mirrored here are the
// Vega-Lite 6.5.0 schema's own (vendored at
// `.github/fixtures/vega_lite_v6_5_0.schema.json`), which the corpus guard
// checks the emitted specs against — the schema is the home of the format's
// facts; these docstrings state only MoonFrame's rules over them (the
// dtype→type inference, the resolution order, the escaping).

///|
/// A Vega-Lite field `type`, used to override the dtype-based inference of
/// any channel. `pub(all)` so callers can name the variants in a channel's
/// `type_override`. `Quantitative` is a continuous measure (a color
/// gradient), `Nominal` an unordered category (distinct colors per value),
/// `Ordinal` an ordered category, `Temporal` a time field, and `Geojson` a
/// GeoJSON feature collection carried in a `String` column (a geoshape
/// channel; the dtype rule never infers it — a `String` column is nominal
/// unless a caller says otherwise).
#derive(Eq, Debug)
pub(all) enum VegaType {
  Quantitative
  Nominal
  Ordinal
  Temporal
  Geojson
}

///|
pub extend VegaType with Eq::{equal, not_equal}

///|
pub extend VegaType with Debug::{to_repr}

///|
/// A Vega-Lite channel `aggregate`, declared for the Vega-Lite runtime to
/// compute at render time (MoonFrame emits it, it does not evaluate it):
/// one variant per operation the schema's `AggregateOp` lists. `Count`
/// tallies the rows of each group and needs no column — a count channel is
/// exempt from column resolution and its field `type` is
/// `"quantitative"`; `ArgMax` / `ArgMin` may also carry a field in the
/// schema's object form, which the string form emitted here does not (a
/// bare field under the same aggregate serves the common case).
/// `pub(all)` so callers can name the variants in a channel's `aggregate`.
#derive(Eq, Debug)
pub(all) enum VegaAggregate {
  Argmax
  Argmin
  Average
  Count
  Distinct
  Max
  Mean
  Median
  Min
  Missing
  Product
  Q1
  Q3
  CI0
  CI1
  Stderr
  Stdev
  Stdevp
  Sum
  Valid
  Values
  Variance
  Variancep
  Exponential
  Exponentialb
}

///|
pub extend VegaAggregate with Eq::{equal, not_equal}

///|
pub extend VegaAggregate with Debug::{to_repr}

///|
/// A sort order: `Ascending → "ascending"`, `Descending → "descending"`.
/// The order half of a `VegaChannelSort`'s by-field form; a bare order is
/// also a complete sort on its own. `pub(all)` so callers can name the
/// variants.
#derive(Eq, Debug)
pub(all) enum VegaSort {
  Ascending
  Descending
}

///|
pub extend VegaSort with Eq::{equal, not_equal}

///|
pub extend VegaSort with Debug::{to_repr}

///|
/// A channel another channel's sort may be keyed on — the schema's
/// `SortByChannel` list (`"x"` … `"-text"`): `X → "x"`, `Color → "color"`,
/// `FillOpacity → "fillOpacity"`, `Text → "text"`, and so on through the
/// twelve. `pub(all)` so callers can name the variant inside a
/// `VegaChannelSort`.
#derive(Eq, Debug)
pub(all) enum VegaSortChannel {
  X
  Y
  Color
  Fill
  Stroke
  StrokeWidth
  Size
  Shape
  FillOpacity
  StrokeOpacity
  Opacity
  Text
}

///|
pub extend VegaSortChannel with Eq::{equal, not_equal}

///|
pub extend VegaSortChannel with Debug::{to_repr}

///|
/// A Vega-Lite channel `sort`, the complete schema union: `Ascending` /
/// `Descending` (the bare orders), `ByChannel` (sort by another channel's
/// values, the descending flag spelling the schema's `-x` forms),
/// `ByField` (sort by a data field, optionally in a given order),
/// `Values` (sort by an explicit list of the channel's values, in that
/// order), and `Off` (`null`, which turns sorting off). `pub(all)` so
/// callers can name the variants; build the `Values` form through
/// `VegaChannelSort::values`, which copies the caller's array.
#derive(Eq, Debug)
pub(all) enum VegaChannelSort {
  Ascending
  Descending
  ByChannel(VegaSortChannel, Bool?)
  ByField(String, VegaSort?)
  Values(Array[Json])
  Off
}

///|
pub extend VegaChannelSort with Eq::{equal, not_equal}

///|
pub extend VegaChannelSort with Debug::{to_repr}

///|
/// The `Values` form of a `VegaChannelSort` from a caller's array: the
/// spec keeps its own copy, so an array the caller mutates afterwards
/// cannot move a chart already built from it. Each element is a value of
/// the sorted column — a number, a string, a boolean — as a `Json` leaf.
pub fn VegaChannelSort::values(order : Array[Json]) -> VegaChannelSort {
  Values(order.copy())
}

///|
/// A Vega-Lite channel `bin`: `On` (`"bin": true`, the runtime picks the
/// bins), `Params` (an explicit `VegaBinParams`), and `Binned` (the
/// `"binned"` marker: the data is already binned — the start maps to x and
/// the end to x2, so a binned histogram pairs `Binned` on x with the
/// pre-binned end in x2). `pub(all)` so callers can name the variants.
#derive(Eq, Debug)
pub(all) enum VegaBin {
  On
  Params(VegaBinParams)
  Binned
}

///|
pub extend VegaBin with Eq::{equal, not_equal}

///|
pub extend VegaBin with Debug::{to_repr}

///|
/// Explicit binning parameters, the schema's `BinParams`: the maximum bin
/// count the binning method aims for (`maxbins`), an anchor to force as a
/// bin boundary (`anchor`), a number base and allowable subdivision
/// factors (`base`, `divide`), a required step size or the list to choose
/// from (`step`, `steps`), a minimum allowed step (`minstep`), nice round
/// boundaries (`nice`), already-binned data (`binned`), and an explicit
/// value range (`extent`, a min / max pair). Fields are read-only outside
/// the package — build one through the same-named constructor, which
/// copies the array parameters it takes, and read `divide` / `steps` back
/// through their accessors, which copy again.
#derive(Eq, Debug)
pub struct VegaBinParams {
  maxbins : Int32?
  anchor : Double?
  base : Double?
  nice : Bool?
  step : Double?
  minstep : Double?
  binned : Bool?
  extent : (Double, Double)?
  priv divide : Array[Double]?
  priv steps : Array[Double]?
}

///|
pub extend VegaBinParams with Eq::{equal, not_equal}

///|
pub extend VegaBinParams with Debug::{to_repr}

///|
/// Build explicit binning parameters; every parameter optional, unset ones
/// left to the runtime's defaults. `divide` and `steps` are copied, so an
/// array the caller mutates afterwards cannot move a chart already built.
pub fn VegaBinParams::VegaBinParams(
  maxbins? : Int32,
  anchor? : Double,
  base? : Double,
  nice? : Bool,
  step? : Double,
  minstep? : Double,
  binned? : Bool,
  extent? : (Double, Double),
  divide? : Array[Double],
  steps? : Array[Double],
) -> VegaBinParams {
  {
    maxbins,
    anchor,
    base,
    nice,
    step,
    minstep,
    binned,
    extent,
    divide: match divide {
      Some(a) => Some(a.copy())
      None => None
    },
    steps: match steps {
      Some(a) => Some(a.copy())
      None => None
    },
  }
}

///|
/// The `divide` subdivision factors, copied — reading the field itself
/// would hand the caller the array the spec holds.
pub fn VegaBinParams::divide(self : VegaBinParams) -> Array[Double]? {
  self.divide.map(fn(d) { d.copy() })
}

///|
/// The `steps` candidate step sizes, copied for the same reason.
pub fn VegaBinParams::steps(self : VegaBinParams) -> Array[Double]? {
  self.steps.map(fn(s) { s.copy() })
}

///|
/// A Vega-Lite `timeUnit`, the complete schema closure: the eleven
/// calendar units (`Year` … `Milliseconds`), their `Utc` counterparts, and
/// every consecutive-unit concatenation the schema enumerates
/// (`YearQuarter`, `MonthDateHours`, `UtcSecondsMilliseconds`, …). Each
/// variant emits its schema string verbatim (`Dayofyear → "dayofyear"`,
/// `UtcWeekdayHours → "utcweekdayhours"`). `pub(all)` so callers can name
/// the variants in a channel's `time_unit`.
#derive(Eq, Debug)
pub(all) enum VegaTimeUnit {
  Year
  Quarter
  Month
  Week
  Day
  Dayofyear
  Date
  Hours
  Minutes
  Seconds
  Milliseconds
  UtcYear
  UtcQuarter
  UtcMonth
  UtcWeek
  UtcDay
  UtcDayofyear
  UtcDate
  UtcHours
  UtcMinutes
  UtcSeconds
  UtcMilliseconds
  Yearquarter
  Yearquartermonth
  Yearmonth
  Yearmonthdate
  Yearmonthdatehours
  Yearmonthdatehoursminutes
  Yearmonthdatehoursminutesseconds
  Yearweek
  Yearweekday
  Yearweekdayhours
  Yearweekdayhoursminutes
  Yearweekdayhoursminutesseconds
  Yeardayofyear
  Quartermonth
  Monthdate
  Monthdatehours
  Monthdatehoursminutes
  Monthdatehoursminutesseconds
  Weekday
  Weekdayhours
  Weekdayhoursminutes
  Weekdayhoursminutesseconds
  Dayhours
  Dayhoursminutes
  Dayhoursminutesseconds
  Hoursminutes
  Hoursminutesseconds
  Minutesseconds
  Secondsmilliseconds
  UtcYearquarter
  UtcYearquartermonth
  UtcYearmonth
  UtcYearmonthdate
  UtcYearmonthdatehours
  UtcYearmonthdatehoursminutes
  UtcYearmonthdatehoursminutesseconds
  UtcYearweek
  UtcYearweekday
  UtcYearweekdayhours
  UtcYearweekdayhoursminutes
  UtcYearweekdayhoursminutesseconds
  UtcYeardayofyear
  UtcQuartermonth
  UtcMonthdate
  UtcMonthdatehours
  UtcMonthdatehoursminutes
  UtcMonthdatehoursminutesseconds
  UtcWeekday
  UtcWeekdayhours
  UtcWeekdayhoursminutes
  UtcWeekdayhoursminutesseconds
  UtcDayhours
  UtcDayhoursminutes
  UtcDayhoursminutesseconds
  UtcHoursminutes
  UtcHoursminutesseconds
  UtcMinutesseconds
  UtcSecondsmilliseconds
}

///|
pub extend VegaTimeUnit with Eq::{equal, not_equal}

///|
pub extend VegaTimeUnit with Debug::{to_repr}

///|
/// A Vega-Lite position-channel `stack` for stacked bar / area:
/// `Zero → "zero"` (baseline stacking, the default when a mark stacks),
/// `Center → "center"`, `Normalize → "normalize"` (each stack rescaled to
/// full height), and `Off` (`null`, which turns stacking off — the
/// layered form). `pub(all)` so callers can name the variants.
#derive(Eq, Debug)
pub(all) enum VegaStack {
  Zero
  Center
  Normalize
  Off
}

///|
pub extend VegaStack with Eq::{equal, not_equal}

///|
pub extend VegaStack with Debug::{to_repr}

///|
/// A top-level `width` / `height`: `Px` (a fixed number of pixels),
/// `Container` (`"container"`, responsive sizing — not combinable with
/// row / column facet channels), and `Step` (`{"step": n}`, the size of
/// one discrete step, so a discrete axis sizes itself by its category
/// count). `pub(all)` so callers can name the variants in a constructor's
/// `width` / `height`.
#derive(Eq, Debug)
pub(all) enum VegaExtent {
  Px(Int32)
  Container
  Step(Int32)
}

///|
pub extend VegaExtent with Eq::{equal, not_equal}

///|
pub extend VegaExtent with Debug::{to_repr}

///|
/// A top-level `autosize`: `Pad → "pad"` (the default; the view grows to
/// fit axes and legends), `Fit → "fit"`, `FitX → "fit-x"`, `FitY →
/// "fit-y"` (each dimension shrinks the chart into the given total size),
/// and `None → "none"` (no automatic fitting). `pub(all)` so callers can
/// name the variants.
#derive(Eq, Debug)
pub(all) enum VegaAutoSize {
  Pad
  Fit
  FitX
  FitY
  None
}

///|
pub extend VegaAutoSize with Eq::{equal, not_equal}

///|
pub extend VegaAutoSize with Debug::{to_repr}

///|
/// A top-level `padding`: `Px` (the same number on all four sides) or
/// `Sides` (per-side values, the sides unset left to the runtime's
/// default). `pub(all)` so callers can name the variants.
#derive(Eq, Debug)
pub(all) enum VegaPadding {
  Px(Int32)
  Sides(VegaSides)
}

///|
pub extend VegaPadding with Eq::{equal, not_equal}

///|
pub extend VegaPadding with Debug::{to_repr}

///|
/// The per-side half of a `VegaPadding`; build one through the
/// same-named constructor with any of the four sides named.
#derive(Eq, Debug)
pub struct VegaSides {
  top : Int32?
  right : Int32?
  bottom : Int32?
  left : Int32?
}

///|
pub extend VegaSides with Eq::{equal, not_equal}

///|
pub extend VegaSides with Debug::{to_repr}

///|
/// Per-side padding with any of the four sides named.
pub fn VegaSides::VegaSides(
  top? : Int32,
  right? : Int32,
  bottom? : Int32,
  left? : Int32,
) -> VegaSides {
  { top, right, bottom, left, }
}

///|
/// A reference to a repeat variable — the placeholder a child spec inside
/// a `Repeat` composition names where a plain field reference would name a
/// column: `Row → {"repeat": "row"}`, `Column → {"repeat": "column"}`.
/// The schema's `RepeatRef` enum also lists `"repeat"` and `"layer"`,
/// which belong to hosts this mirror does not build (a wrapped
/// repeat-of-concats and a layer-level field spec), so the two variants
/// here are the reachable set. `pub(all)` so callers can name the
/// variants; a channel carrying one is built with `VegaChannel::repeat`.
#derive(Eq, Debug)
pub(all) enum VegaRepeatRef {
  Row
  Column
}

///|
pub extend VegaRepeatRef with Eq::{equal, not_equal}

///|
pub extend VegaRepeatRef with Debug::{to_repr}

///|
/// The schema's `RepeatRef` string for a variant, one arm per variant.
fn repeat_ref_string(reference : VegaRepeatRef) -> String {
  match reference {
    Row => "row"
    Column => "column"
  }
}

///|
/// One encoding-channel definition: a column `field` plus optional
/// pass-through modifiers, or — instead of a field — a reference to a
/// repeat variable (`repeat_ref`, the placeholder a child spec inside a
/// `Repeat` composition resolves per panel) or a constant `value` or a
/// constant `datum` (the schema's value / datum definitions; a channel
/// is exactly one of the four, and the builders keep it that way — a
/// `field` and a `repeat_ref` on one channel raise `InvalidOperation` at
/// emission, since the schema's `field` slot holds one or the other).
/// `aggregate` declares an aggregation over the column (a `Count`
/// aggregate ignores the field — no column is read, and the channel's
/// `type` is `"quantitative"`); `bin` declares binning; `time_unit`
/// truncates a temporal column to calendar units; `sort` orders the
/// channel's scale; `type_override` replaces the dtype-inferred field
/// `type` on this one channel; `title` names the axis / legend entry and
/// `format` formats its ticks (a number / time format pattern); `stack`
/// overrides position stacking; `band_position` places a mark within its
/// band (0 start, 0.5 middle, 1 end). The modifiers are declared, not
/// computed — the Vega-Lite runtime evaluates them at render time. Build
/// one with `field` / `VegaChannel::repeat` / `constant` / `datum`;
/// fields are read-only outside the package.
#derive(Eq, Debug)
pub struct VegaChannel {
  field : String?
  repeat_ref : VegaRepeatRef?
  aggregate : VegaAggregate?
  bin : VegaBin?
  time_unit : VegaTimeUnit?
  sort : VegaChannelSort?
  type_override : VegaType?
  title : String?
  format : String?
  stack : VegaStack?
  band_position : Double?
  scale : VegaScaleRef?
  axis : VegaAxisRef?
  legend : VegaLegendRef?
  condition : VegaCondition?
  value : Json?
  datum : Json?
}

///|
pub extend VegaChannel with Eq::{equal, not_equal}

///|
pub extend VegaChannel with Debug::{to_repr}

///|
/// The field-reference encoding channel for column `name`, with any of
/// the `VegaChannel` modifiers named — e.g. `field("revenue",
/// aggregate=Sum)`, `field("price", bin=On)`, `field("ts",
/// time_unit=Month)`, `field("region", sort=Descending)`, `field("g",
/// type_override=Nominal)`. The `col` idiom of the chart export: a free
/// function, so the facade re-exports it and the common call stays two
/// words short.
pub fn field(
  name : String,
  aggregate? : VegaAggregate,
  bin? : VegaBin,
  time_unit? : VegaTimeUnit,
  sort? : VegaChannelSort,
  type_override? : VegaType,
  title? : String,
  format? : String,
  stack? : VegaStack,
  band_position? : Double,
  scale? : VegaScaleRef,
  axis? : VegaAxisRef,
  legend? : VegaLegendRef,
  condition? : VegaCondition,
) -> VegaChannel {
  {
    field: Some(name),
    repeat_ref: None,
    aggregate,
    bin,
    time_unit,
    sort,
    type_override,
    title,
    format,
    stack,
    band_position,
    scale,
    axis,
    legend,
    condition,
    value: None,
    datum: None,
  }
}

///|
/// The all-unset channel every constant-style builder starts from.
fn empty_channel() -> VegaChannel {
  {
    field: None,
    repeat_ref: None,
    aggregate: None,
    bin: None,
    time_unit: None,
    sort: None,
    type_override: None,
    title: None,
    format: None,
    stack: None,
    band_position: None,
    scale: None,
    axis: None,
    legend: None,
    condition: None,
    value: None,
    datum: None,
  }
}

///|
/// A constant-value encoding channel: the channel shows the given JSON
/// value for every row (the schema's value definition — a fixed color, a
/// fixed size) instead of reading a column. Its `type` inference has no
/// column to read, so the emitted definition carries only the value (and
/// any `title` / `format` set on the channel through a builder is
/// unreachable — use `field` when a column is wanted).
pub fn constant(value : Json) -> VegaChannel {
  { ..empty_channel(), value: Some(value), }
}

///|
/// A constant-datum encoding channel: like `constant`, but the value
/// passes through the channel's scale (a scale type must fit — a number
/// under a linear scale) rather than being shown verbatim. The schema's
/// datum definition.
pub fn datum(value : Json) -> VegaChannel {
  { ..empty_channel(), datum: Some(value), }
}

///|
/// The `count` aggregate with no field: it tallies the rows of each
/// group. Emits `{"aggregate":"count","type":"quantitative"}` with no
/// `field` key, and is the one aggregate exempt from column resolution —
/// a histogram is `ChartSpec::bar(field("price", bin=On),
/// VegaChannel::count())`.
pub fn VegaChannel::count() -> VegaChannel {
  { ..empty_channel(), aggregate: Some(Count), }
}

///|
/// The repeat-reference encoding channel: instead of naming one column,
/// the channel names the repeat variable of the enclosing `Repeat`
/// composition — each panel resolves it to the field that panel repeats
/// over. Accepts the same pass-through modifiers as `field`; the
/// dtype→type rule has no single column to read (the column varies per
/// panel), so an unset `type_override` types the channel
/// `"quantitative"` — set `type_override` when the repeated fields are
/// temporal or nominal. A `Count` aggregate ignores the reference the
/// way it ignores a field.
pub fn VegaChannel::repeat(
  repeat_ref~ : VegaRepeatRef,
  aggregate? : VegaAggregate,
  bin? : VegaBin,
  time_unit? : VegaTimeUnit,
  sort? : VegaChannelSort,
  type_override? : VegaType,
  title? : String,
  format? : String,
  stack? : VegaStack,
  band_position? : Double,
  scale? : VegaScaleRef,
  axis? : VegaAxisRef,
  legend? : VegaLegendRef,
  condition? : VegaCondition,
) -> VegaChannel {
  {
    field: None,
    repeat_ref: Some(repeat_ref),
    aggregate,
    bin,
    time_unit,
    sort,
    type_override,
    title,
    format,
    stack,
    band_position,
    scale,
    axis,
    legend,
    condition,
    value: None,
    datum: None,
  }
}

///|
/// The schema's `timeUnit` string for a `VegaTimeUnit` — generated
/// verbatim from the vendored schema's own enum lists, one arm per
/// variant, so a unit added there is a spelling mismatch here rather than
/// a silent pass-through.
fn time_unit_string(t : VegaTimeUnit) -> String {
  match t {
    Year => "year"
    Quarter => "quarter"
    Month => "month"
    Week => "week"
    Day => "day"
    Dayofyear => "dayofyear"
    Date => "date"
    Hours => "hours"
    Minutes => "minutes"
    Seconds => "seconds"
    Milliseconds => "milliseconds"
    UtcYear => "utcyear"
    UtcQuarter => "utcquarter"
    UtcMonth => "utcmonth"
    UtcWeek => "utcweek"
    UtcDay => "utcday"
    UtcDayofyear => "utcdayofyear"
    UtcDate => "utcdate"
    UtcHours => "utchours"
    UtcMinutes => "utcminutes"
    UtcSeconds => "utcseconds"
    UtcMilliseconds => "utcmilliseconds"
    Yearquarter => "yearquarter"
    Yearquartermonth => "yearquartermonth"
    Yearmonth => "yearmonth"
    Yearmonthdate => "yearmonthdate"
    Yearmonthdatehours => "yearmonthdatehours"
    Yearmonthdatehoursminutes => "yearmonthdatehoursminutes"
    Yearmonthdatehoursminutesseconds => "yearmonthdatehoursminutesseconds"
    Yearweek => "yearweek"
    Yearweekday => "yearweekday"
    Yearweekdayhours => "yearweekdayhours"
    Yearweekdayhoursminutes => "yearweekdayhoursminutes"
    Yearweekdayhoursminutesseconds => "yearweekdayhoursminutesseconds"
    Yeardayofyear => "yeardayofyear"
    Quartermonth => "quartermonth"
    Monthdate => "monthdate"
    Monthdatehours => "monthdatehours"
    Monthdatehoursminutes => "monthdatehoursminutes"
    Monthdatehoursminutesseconds => "monthdatehoursminutesseconds"
    Weekday => "weekday"
    Weekdayhours => "weekdayhours"
    Weekdayhoursminutes => "weekdayhoursminutes"
    Weekdayhoursminutesseconds => "weekdayhoursminutesseconds"
    Dayhours => "dayhours"
    Dayhoursminutes => "dayhoursminutes"
    Dayhoursminutesseconds => "dayhoursminutesseconds"
    Hoursminutes => "hoursminutes"
    Hoursminutesseconds => "hoursminutesseconds"
    Minutesseconds => "minutesseconds"
    Secondsmilliseconds => "secondsmilliseconds"
    UtcYearquarter => "utcyearquarter"
    UtcYearquartermonth => "utcyearquartermonth"
    UtcYearmonth => "utcyearmonth"
    UtcYearmonthdate => "utcyearmonthdate"
    UtcYearmonthdatehours => "utcyearmonthdatehours"
    UtcYearmonthdatehoursminutes => "utcyearmonthdatehoursminutes"
    UtcYearmonthdatehoursminutesseconds => "utcyearmonthdatehoursminutesseconds"
    UtcYearweek => "utcyearweek"
    UtcYearweekday => "utcyearweekday"
    UtcYearweekdayhours => "utcyearweekdayhours"
    UtcYearweekdayhoursminutes => "utcyearweekdayhoursminutes"
    UtcYearweekdayhoursminutesseconds => "utcyearweekdayhoursminutesseconds"
    UtcYeardayofyear => "utcyeardayofyear"
    UtcQuartermonth => "utcquartermonth"
    UtcMonthdate => "utcmonthdate"
    UtcMonthdatehours => "utcmonthdatehours"
    UtcMonthdatehoursminutes => "utcmonthdatehoursminutes"
    UtcMonthdatehoursminutesseconds => "utcmonthdatehoursminutesseconds"
    UtcWeekday => "utcweekday"
    UtcWeekdayhours => "utcweekdayhours"
    UtcWeekdayhoursminutes => "utcweekdayhoursminutes"
    UtcWeekdayhoursminutesseconds => "utcweekdayhoursminutesseconds"
    UtcDayhours => "utcdayhours"
    UtcDayhoursminutes => "utcdayhoursminutes"
    UtcDayhoursminutesseconds => "utcdayhoursminutesseconds"
    UtcHoursminutes => "utchoursminutes"
    UtcHoursminutesseconds => "utchoursminutesseconds"
    UtcMinutesseconds => "utcminutesseconds"
    UtcSecondsmilliseconds => "utcsecondsmilliseconds"
  }
}

///|
/// The schema's `AggregateOp` string for a `VegaAggregate`, generated
/// from the vendored schema's enum the same way.
fn aggregate_string(op : VegaAggregate) -> String {
  match op {
    Argmax => "argmax"
    Argmin => "argmin"
    Average => "average"
    Count => "count"
    Distinct => "distinct"
    Max => "max"
    Mean => "mean"
    Median => "median"
    Min => "min"
    Missing => "missing"
    Product => "product"
    Q1 => "q1"
    Q3 => "q3"
    CI0 => "ci0"
    CI1 => "ci1"
    Stderr => "stderr"
    Stdev => "stdev"
    Stdevp => "stdevp"
    Sum => "sum"
    Valid => "valid"
    Values => "values"
    Variance => "variance"
    Variancep => "variancep"
    Exponential => "exponential"
    Exponentialb => "exponentialb"
  }
}
