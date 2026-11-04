// Vega-Lite v5 chart-spec export for `DataFrame`. `format_vega_lite`
// produces a complete, standalone Vega-Lite v5 top-level specification —
// `$schema` + optional `title` / `width` / `height` + `mark` + `encoding`
// + an inline `data.values` array — as a JSON string. The output drops
// straight into the Vega editor (<https://vega.github.io/editor/>) or any
// Vega-Lite runtime and renders without further wiring, so there is no
// private chart-data shape to learn: it is the standard declarative spec.
//
// The builder covers Vega-Lite's single-view spec: one `mark` and its
// encoding channels, each channel optionally declaring an `aggregate` /
// `bin` / `sort` for the Vega-Lite runtime to compute at render time.
// Which channels a mark consumes is the Vega-Lite encoding table's to
// state (<https://vega.github.io/vega-lite/docs/encoding.html>); this
// package states only its own rules — the dtype→type inference, the
// column-resolution order, and the field-name escaping. Multi-view
// composition (`layer` / `facet` / `concat`), `transform`, and `config`
// are outside the export.
//
// This is its own package rather than a method on `DataFrame` or a corner
// of `io`: chart-spec export is serialisation to an external interchange
// format, not pure rendering (`frame` keeps `to_markdown` / `to_html`)
// and not tabular interchange (`io` owns the CSV / JSON / NDJSON readers
// and writers). It stays aligned with the JSON serialisers' cell
// conventions by driving the same records walk as `format_json` /
// `format_ndjson` — the `@io`-internal `df_to_json_records` seam — so a
// `data.values` cell follows exactly the same conventions as a
// JSON-records cell (nulls and non-finite floats become JSON `null`).
//
// Unlike `format_json` (which is **total**), `format_vega_lite`
// `raise`s: a `ChartSpec` names the channels' `x` / `y` / `color` …
// columns, and a name that is absent from the frame surfaces as
// `ColumnNotFound` rather than producing a spec that references a
// non-existent field.

///|
/// The mark type of a chart, mapped to a Vega-Lite top-level `mark`:
/// `Bar → "bar"`, `Line → "line"`, `Point → "point"`, `Area → "area"`,
/// `Tick → "tick"`, `Rect → "rect"`, `Rule → "rule"`, `Circle → "circle"`,
/// `Square → "square"`, `Trail → "trail"`, `Text → "text"`,
/// `Arc → "arc"`, `Boxplot → "boxplot"`.
/// `pub(all)` so callers can name the variants when building a `ChartSpec`
/// (though the `ChartSpec` constructors set the kind for you).
#derive(Eq, Debug)
pub(all) enum ChartKind {
  Bar
  Line
  Point
  Area
  Tick
  Rect
  Rule
  Circle
  Square
  Trail
  Text
  Arc
  Boxplot
}

///|
pub extend ChartKind with Eq::{equal, not_equal}

///|
pub extend ChartKind with Debug::{to_repr}

///|
/// A Vega-Lite field `type`, used to override the dtype-based inference of
/// any channel. `pub(all)` so callers can name the variants in a
/// channel's `type_override`. `Quantitative` is a continuous measure (a
/// color gradient), `Nominal` an unordered category (distinct colors per
/// value), `Ordinal` an ordered category, and `Temporal` a time field.
#derive(Eq, Debug)
pub(all) enum VegaType {
  Quantitative
  Nominal
  Ordinal
  Temporal
}

///|
pub extend VegaType with Eq::{equal, not_equal}

///|
pub extend VegaType with Debug::{to_repr}

///|
/// A Vega-Lite channel `aggregate`, declared for the Vega-Lite runtime to
/// compute at render time (MoonFrame emits it, it does not evaluate it):
/// `Sum → "sum"`, `Mean → "mean"`, `Median → "median"`, `Min → "min"`,
/// `Max → "max"`, `Count → "count"`. `Count` tallies the rows of each
/// group and needs no column — a count channel is exempt from column
/// resolution and its field `type` is `"quantitative"`.
/// `pub(all)` so callers can name the variants in a channel's `aggregate`.
#derive(Eq, Debug)
pub(all) enum VegaAggregate {
  Sum
  Mean
  Median
  Min
  Max
  Count
}

///|
pub extend VegaAggregate with Eq::{equal, not_equal}

///|
pub extend VegaAggregate with Debug::{to_repr}

///|
/// A Vega-Lite channel `sort`: the order the channel's scale lays out its
/// values — `Ascending → "ascending"`, `Descending → "descending"`.
/// `pub(all)` so callers can name the variants in a channel's `sort`.
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
/// One encoding-channel definition: the column `field` plus optional
/// pass-through modifiers, each emitted as its Vega-Lite channel key.
/// `aggregate` declares an aggregation over the column (a `Count`
/// aggregate ignores the field — no column is read, and the channel's
/// `type` is `"quantitative"`); `bin` declares binning (emitted as
/// `"bin": true` / `false` — a histogram pairs `bin` on x with an
/// aggregated y); `sort` orders the channel's scale; `type_override`
/// replaces the dtype-inferred field `type` on this one channel. The
/// modifiers are declared, not computed — the Vega-Lite runtime evaluates
/// them at render time. Build one with `field` (or `VegaChannel::count`
/// for the row count); fields are read-only outside the package.
#derive(Eq, Debug)
pub struct VegaChannel {
  field : String
  aggregate : VegaAggregate?
  bin : Bool?
  sort : VegaSort?
  type_override : VegaType?
}

///|
pub extend VegaChannel with Eq::{equal, not_equal}

///|
pub extend VegaChannel with Debug::{to_repr}

///|
/// The plain encoding channel for column `name`, with any of the
/// `VegaChannel` modifiers named — e.g. `field("revenue", aggregate=Sum)`,
/// `field("price", bin=true)`, `field("region", sort=Descending)`,
/// `field("cluster", type_override=Nominal)`. The `col` idiom of the
/// chart export: a free function, so the facade re-exports it and the
/// common call stays two words short.
pub fn field(
  name : String,
  aggregate? : VegaAggregate,
  bin? : Bool,
  sort? : VegaSort,
  type_override? : VegaType,
) -> VegaChannel {
  { field: name, aggregate, bin, sort, type_override, }
}

///|
/// The `count` aggregate with no field: it tallies the rows of each
/// group. Emits `{"aggregate":"count","type":"quantitative"}` with no
/// `field` key, and is the one channel exempt from column resolution — a
/// histogram is `ChartSpec::bar(field("price", bin=true),
/// VegaChannel::count())`.
pub fn VegaChannel::count() -> VegaChannel {
  {
    field: "",
    aggregate: Some(Count),
    bin: None,
    sort: None,
    type_override: None,
  }
}

///|
/// A chart specification: the `mark` kind, its encoding channels (each a
/// `VegaChannel`, built with `field`), and an optional `title` /
/// `width` / `height`. Fields are read-only outside the package — build a
/// spec through one of the mark-named constructors (`ChartSpec::bar(x, y)`
/// / `line` / `point` / `area` / `tick` / `rect` / `rule` / `circle` /
/// `square` / `trail` / `boxplot`, the polar `ChartSpec::arc(theta)`, and
/// `ChartSpec::text(x, y, text)`), naming the channels that mark consumes
/// as needed:
///
///   `ChartSpec::bar(field("region"), field("revenue"), title="Revenue")`
///
/// Every channel's column resolves against the frame at
/// `format_vega_lite` time in a fixed order — `x`, `y`, `x2`, `y2`,
/// `color`, `size`, `opacity`, `tooltip`, `detail`, `theta`, `radius`,
/// `radius2`, `text` — and the first name absent from the frame raises
/// `ColumnNotFound` (a count channel reads no column). Each channel's
/// dtype decides its Vega-Lite field `type` (the dtype→type rule
/// `format_vega_lite`'s doc states) unless the channel's `type_override`
/// replaces it; `aggregate` / `bin` / `sort` pass through to the Vega-Lite
/// runtime, which computes them at render time.
#derive(Eq, Debug)
pub struct ChartSpec {
  kind : ChartKind
  x : VegaChannel?
  y : VegaChannel?
  x2 : VegaChannel?
  y2 : VegaChannel?
  color : VegaChannel?
  size : VegaChannel?
  opacity : VegaChannel?
  tooltip : VegaChannel?
  detail : VegaChannel?
  theta : VegaChannel?
  radius : VegaChannel?
  radius2 : VegaChannel?
  text : VegaChannel?
  title : String?
  width : Int32?
  height : Int32?
}

///|
pub extend ChartSpec with Eq::{equal, not_equal}

///|
pub extend ChartSpec with Debug::{to_repr}

///|
/// A bar chart of `y` against `x` (Vega-Lite `mark: "bar"`); a `size`
/// channel is the bar thickness, and `x2` / `y2` name the bar's far end
/// for a ranged bar.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::bar(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  x2? : VegaChannel,
  y2? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Bar,
    x: Some(x),
    y: Some(y),
    x2,
    y2,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A line chart of `y` against `x` (Vega-Lite `mark: "line"`); a `detail`
/// channel splits the line into one per group without coloring them.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::line(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Line,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A scatter (point) chart of `y` against `x` (Vega-Lite `mark:
/// "point"`); a `size` channel is the symbol area, an `opacity` channel
/// the per-point transparency.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::point(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Point,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// An area chart of `y` against `x` (Vega-Lite `mark: "area"`); `x2` /
/// `y2` name the band's far edge for a ranged area.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::area(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  x2? : VegaChannel,
  y2? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Area,
    x: Some(x),
    y: Some(y),
    x2,
    y2,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A tick chart of `y` against `x` (Vega-Lite `mark: "tick"`) — a dense
/// column of short strokes, one per row; a `size` channel is the tick
/// thickness.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::tick(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Tick,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A rectangle chart of `y` against `x` (Vega-Lite `mark: "rect"`) — the
/// heatmap grid; `x2` / `y2` name each cell's far corner for explicit
/// spans.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::rect(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  x2? : VegaChannel,
  y2? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Rect,
    x: Some(x),
    y: Some(y),
    x2,
    y2,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A rule chart of `y` against `x` (Vega-Lite `mark: "rule"`) — a line
/// spanning the plot, one per row; `x2` / `y2` name the rule's far
/// endpoint, and a rule with only x and y2 (or y and x2) draws a
/// zero-width segment at each row.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::rule(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  x2? : VegaChannel,
  y2? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Rule,
    x: Some(x),
    y: Some(y),
    x2,
    y2,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A scatter chart of filled circles of `y` against `x` (Vega-Lite
/// `mark: "circle"`); a `size` channel is the circle area.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::circle(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Circle,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A scatter chart of filled squares of `y` against `x` (Vega-Lite
/// `mark: "square"`); a `size` channel is the square area.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::square(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Square,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A trail chart of `y` against `x` (Vega-Lite `mark: "trail"`) — a line
/// whose stroke width follows the `size` channel at each point.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::trail(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Trail,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// A polar arc chart (Vega-Lite `mark: "arc"`): the `theta` channel is
/// the slice angle (a pie names a `color` grouping), `radius2` cuts the
/// center out for a donut, and a `radius` channel varies the slice
/// length for a rose.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::arc(
  theta : VegaChannel,
  color? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  radius? : VegaChannel,
  radius2? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Arc,
    x: None,
    y: None,
    x2: None,
    y2: None,
    size: None,
    detail: None,
    text: None,
    theta: Some(theta),
    color,
    opacity,
    tooltip,
    radius,
    radius2,
    title,
    width,
    height,
  }
}

///|
/// A text chart of `y` against `x` (Vega-Lite `mark: "text"`) — the
/// `text` channel's cell drawn as a label at each point; a `size`
/// channel is the font size.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::text(
  x : VegaChannel,
  y : VegaChannel,
  text : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Text,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail: None,
    theta: None,
    radius: None,
    radius2: None,
    text: Some(text),
    title,
    width,
    height,
  }
}

///|
/// A box-and-whisker summary of `y` for each `x` group (Vega-Lite `mark:
/// "boxplot"`); the Vega-Lite runtime computes the quartiles and whiskers
/// itself, so a plain x / y pair is a complete box plot.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::boxplot(
  x : VegaChannel,
  y : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  title? : String,
  width? : Int32,
  height? : Int32,
) -> ChartSpec {
  {
    kind: Boxplot,
    x: Some(x),
    y: Some(y),
    x2: None,
    y2: None,
    color,
    size,
    opacity,
    tooltip,
    detail: None,
    theta: None,
    radius: None,
    radius2: None,
    text: None,
    title,
    width,
    height,
  }
}

///|
/// Render `df` and `spec` as a complete Vega-Lite v5 specification JSON
/// string: `$schema` (pinned to the Vega-Lite v5 schema URL) + optional
/// `title` + optional `width` / `height` + `mark` (from `spec.kind`) +
/// `encoding` (the spec's channels, each `{field, type}` plus its
/// declared `aggregate` / `bin` / `sort`) + `data.values` (the frame
/// inlined as JSON records, sharing `format_json`'s cell mapping — null
/// and non-finite-float cells become JSON `null`). A frame with the
/// encoded columns but zero rows yields `"data":{"values":[]}`.
///
/// Each encoding channel's field `type` follows its column's dtype — the
/// single statement of the dtype→type rule: a numeric column (`Int` /
/// `Float` / `Decimal`) is `"quantitative"`, a `Date` / `Timestamp` column
/// is `"temporal"` (its ISO cells — `data.values`' date units, via the JSON
/// records' ISO mapping — sort chronologically, and a temporal axis orders
/// by time rather than by first appearance), and every other dtype is
/// `"nominal"` — unless the channel carries an explicit `type_override`.
/// A count channel reads no column and is `"quantitative"`.
///
/// The spec's channels are resolved in a fixed order — `x`, `y`, `x2`,
/// `y2`, `color`, `size`, `opacity`, `tooltip`, `detail`, `theta`,
/// `radius`, `radius2`, `text` — and the first name absent from `df`
/// raises `ColumnNotFound(name)`; this is the one reason the function is
/// not **total** (it accepts column names, and a name can be wrong). The
/// declared `aggregate` / `bin` / `sort` are not computed here — the
/// Vega-Lite runtime evaluates them at render time. The emitted text is
/// always valid JSON (it is built through `@json` and stringified), so it
/// round-trips through any standards-compliant JSON / Vega-Lite reader.
pub fn format_vega_lite(
  df : @frame.DataFrame,
  spec : ChartSpec,
) -> String raise @types.DataError {
  let obj : Map[String, Json] = Map([])
  obj["$schema"] = Json::string(
    "https://vega.github.io/schema/vega-lite/v5.json",
  )
  if spec.title is Some(title) {
    obj["title"] = Json::string(title)
  }
  if spec.width is Some(width) {
    obj["width"] = Json::number(width.to_double())
  }
  if spec.height is Some(height) {
    obj["height"] = Json::number(height.to_double())
  }
  // The Vega-Lite `mark` string for the chart kind.
  obj["mark"] = Json::string(mark_string(spec.kind))
  // Resolve the channels in the fixed order the `ChartSpec` doc states —
  // x, y, x2, y2, color, size, opacity, tooltip, detail, theta, radius,
  // radius2, text — so a missing column raises `ColumnNotFound` in that
  // order. `channel_dtype` doubles as the existence check and the dtype
  // source for Vega-Lite's field-`type` inference; a count channel reads
  // no column.
  let encoding : Map[String, Json] = Map([])
  if spec.x is Some(x) {
    encoding["x"] = encoding_channel(x, channel_dtype(df, x))
  }
  if spec.y is Some(y) {
    encoding["y"] = encoding_channel(y, channel_dtype(df, y))
  }
  if spec.x2 is Some(x2) {
    encoding["x2"] = encoding_channel(x2, channel_dtype(df, x2))
  }
  if spec.y2 is Some(y2) {
    encoding["y2"] = encoding_channel(y2, channel_dtype(df, y2))
  }
  if spec.color is Some(color) {
    encoding["color"] = encoding_channel(color, channel_dtype(df, color))
  }
  if spec.size is Some(size) {
    encoding["size"] = encoding_channel(size, channel_dtype(df, size))
  }
  if spec.opacity is Some(opacity) {
    encoding["opacity"] = encoding_channel(opacity, channel_dtype(df, opacity))
  }
  if spec.tooltip is Some(tooltip) {
    encoding["tooltip"] = encoding_channel(tooltip, channel_dtype(df, tooltip))
  }
  if spec.detail is Some(detail) {
    encoding["detail"] = encoding_channel(detail, channel_dtype(df, detail))
  }
  if spec.theta is Some(theta) {
    encoding["theta"] = encoding_channel(theta, channel_dtype(df, theta))
  }
  if spec.radius is Some(radius) {
    encoding["radius"] = encoding_channel(radius, channel_dtype(df, radius))
  }
  if spec.radius2 is Some(radius2) {
    encoding["radius2"] = encoding_channel(radius2, channel_dtype(df, radius2))
  }
  if spec.text is Some(text) {
    encoding["text"] = encoding_channel(text, channel_dtype(df, text))
  }
  obj["encoding"] = Json::object(encoding)
  let data : Map[String, Json] = Map([])
  data["values"] = Json::array(@io.df_to_json_records(df))
  obj["data"] = Json::object(data)
  Json::object(obj).stringify()
}

///|
/// Write a Vega-Lite v5 spec for `df` / `spec` to `path`. Mirrors
/// `write_json`: a `ColumnNotFound` from `format_vega_lite` (a spec
/// column absent from `df`) propagates unchanged, a filesystem failure
/// surfaces as `raise IoError(message)`, and content holding an unpaired
/// UTF-16 surrogate is refused with `raise InvalidOperation`.
pub fn write_vega_lite(
  path : String,
  df : @frame.DataFrame,
  spec : ChartSpec,
) -> Unit raise @types.DataError {
  let content = format_vega_lite(df, spec)
  @io.write_text(path, content)
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// The Vega-Lite `mark` string for the chart kind.
fn mark_string(kind : ChartKind) -> String {
  match kind {
    Bar => "bar"
    Line => "line"
    Point => "point"
    Area => "area"
    Tick => "tick"
    Rect => "rect"
    Rule => "rule"
    Circle => "circle"
    Square => "square"
    Trail => "trail"
    Text => "text"
    Arc => "arc"
    Boxplot => "boxplot"
  }
}

///|
/// The dtype backing a channel's type inference: a non-count channel's
/// column dtype (`get_column` doubles as the existence check), `None` for
/// a count channel — it reads no column, so there is no dtype to infer
/// from and its `type` is `"quantitative"`.
fn channel_dtype(
  df : @frame.DataFrame,
  channel : VegaChannel,
) -> @types.DataType? raise @types.DataError {
  if channel.aggregate is Some(Count) {
    None
  } else {
    Some(df.get_column(channel.field).dtype())
  }
}

///|
/// Build one Vega-Lite encoding-channel object: `{"field": <name>,
/// "type": <vega-type>}` plus the channel's declared `"aggregate"` /
/// `"bin"` / `"sort"` keys, each present only when set. A count channel
/// emits no `field` key (its aggregate tallies rows per group) and its
/// `type` is `"quantitative"`; its ignored `field` never reaches the
/// spec. An explicit `type_override` on the channel wins over inference;
/// otherwise the field `type` follows the column dtype: a numeric column
/// (`Int` / `Float` / `Decimal`) is `"quantitative"`, a `Date` /
/// `Timestamp` column is `"temporal"` (its ISO cells sort
/// chronologically, and a temporal axis orders by time rather than by
/// first appearance), and every other dtype is `"nominal"`.
fn encoding_channel(channel : VegaChannel, dtype : @types.DataType?) -> Json {
  let ch : Map[String, Json] = Map([])
  if !(channel.aggregate is Some(Count)) {
    ch["field"] = Json::string(escape_vega_field(channel.field))
  }
  if channel.aggregate is Some(op) {
    ch["aggregate"] = Json::string(
      // The Vega-Lite `aggregate` string for a `VegaAggregate`.
      match op {
        Sum => "sum"
        Mean => "mean"
        Median => "median"
        Min => "min"
        Max => "max"
        Count => "count"
      },
    )
  }
  if channel.bin is Some(bin) {
    ch["bin"] = Json::boolean(bin)
  }
  if channel.sort is Some(sort) {
    ch["sort"] = Json::string(
      if sort is Ascending {
        "ascending"
      } else {
        "descending"
      },
    )
  }
  ch["type"] = Json::string(
    if channel.type_override is Some(t) {
      // The Vega-Lite `type` string for a `VegaType`.
      match t {
        Quantitative => "quantitative"
        Nominal => "nominal"
        Ordinal => "ordinal"
        Temporal => "temporal"
      }
    } else if dtype is Some(d) {
      if d.is_numeric() || d is @types.DataType::Decimal(_) {
        "quantitative"
      } else if d is @types.DataType::Date ||
        d is @types.DataType::Timestamp ||
        d is @types.DataType::Duration {
        "temporal"
      } else {
        "nominal"
      }
    } else {
      // A count channel: no column, so no dtype — a row count is a
      // quantity by definition.
      "quantitative"
    },
  )
  Json::object(ch)
}

///|
/// Escape a column name for use as a Vega-Lite encoding `field`. Vega-Lite
/// reads an unescaped `.` as nested-object access and `[...]` as array
/// indexing, so a column literally named `price.usd` or `a[0]` would resolve
/// to a missing nested path and silently plot nothing. Quote characters are
/// worse: Vega compiles the field into a `datum[...]` accessor expression,
/// where a bare `'` or `"` terminates the string early and the generated
/// expression fails to parse — the exported spec throws at compile time
/// instead of rendering. Prefixing `\`, `.`, `[`, `]`, `'`, and `"` with a
/// backslash makes the name a literal field access (the JSON stringifier
/// then escapes the backslash itself). A single forward pass, total.
fn escape_vega_field(name : String) -> String {
  let buf = StringBuilder()
  for ch in name.iter() {
    if ch == '\\' ||
      ch == '.' ||
      ch == '[' ||
      ch == ']' ||
      ch == '\'' ||
      ch == '"' {
      buf.write_char('\\')
      buf.write_char(ch)
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}
