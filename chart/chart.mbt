// Vega-Lite v6 chart-spec export for `DataFrame`. `format_vega_lite`
// produces a complete, standalone Vega-Lite v6 top-level specification —
// `$schema` + the optional chrome (`name` / `description` / `title` /
// `autosize` / `background` / `padding` / `width` / `height`) + `mark` +
// `encoding` + an inline `data.values` array — as a JSON string. The
// output drops straight into the Vega editor
// (<https://vega.github.io/editor/>) or any Vega-Lite v6 runtime and
// renders without further wiring, so there is no private chart-data shape
// to learn: it is the standard declarative spec.
//
// The export is a typed mirror of the format, held honest by a vendored
// copy of the schema itself: the property lists transcribed into these
// types are `.github/fixtures/vega_lite_v6_5_0.schema.json`'s (the home
// of the format's facts), and the corpus guard
// (`.github/scripts/check_vega_corpus.py`) walks the emitted specs of
// `chart/corpus/` against that schema, so a key the schema does not know
// fails the build rather than shipping as a plausible-looking spec. The
// mirror's surface is split two ways: the main face a caller builds a
// chart from (the spec type, the mark enum, the channel family, its
// builders) rides the facade, and the deep spec-object trees the later
// mirror stages add (scales, axes, legends, transforms, config) are
// reached through `@chart` qualification — the facade-surface guard pins
// the line both ways.
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
// `raise`s: a `ChartSpec` names its channels' columns, and a name absent
// from the frame surfaces as `ColumnNotFound` rather than producing a
// spec that references a non-existent field.

///|
/// A chart specification: the `mark` kind, its encoding channels (each a
/// `VegaChannel`, built with `field` / `constant` / `datum`), and the
/// optional top-level chrome (`title`, `width` / `height` as a
/// `VegaExtent`, `name`, `description`, `autosize`, `padding`,
/// `background`). Fields are read-only outside the package — build a
/// spec through one of the mark-named constructors (`ChartSpec::bar(x,
/// y)` / `line` / `point` / `area` / `tick` / `rect` / `rule` / `circle`
/// / `square` / `trail` / `boxplot`, the polar `ChartSpec::arc(theta)`,
/// `ChartSpec::text(x, y, text)`, `ChartSpec::image(x, y, url)`,
/// `ChartSpec::geoshape(shape)`, and the error composites
/// `ChartSpec::errorbar` / `errorband`), each naming the channels that
/// mark commonly consumes — or through `ChartSpec::of`, the general form
/// that carries every channel and every chrome property there is:
///
///   `ChartSpec::bar(field("region"), field("revenue"), title="Revenue")`
///
/// Every field channel's column resolves against the frame at
/// `format_vega_lite` time in a fixed order — `x`, `y`, `x2`, `y2`,
/// `xError`, `xError2`, `yError`, `yError2`, `xOffset`, `yOffset`,
/// `longitude`, `longitude2`, `latitude`, `latitude2`, `theta`,
/// `theta2`, `radius`, `radius2`, `color`, `fill`, `stroke`, `opacity`,
/// `fillOpacity`, `strokeOpacity`, `strokeWidth`, `strokeDash`, `size`,
/// `shape`, `angle`, `time`, `text`, `tooltip`, `href`, `url`,
/// `description` (the ARIA channel, `description_channel` here because
/// the top-level prose description takes the plain name), `key`,
/// `detail`, `order` — and the first name absent from the frame raises
/// `ColumnNotFound` (a count channel reads no column). Each channel's
/// dtype decides its Vega-Lite field `type` (the dtype→type rule
/// `format_vega_lite`'s doc states) unless the channel's `type_override`
/// replaces it; the declared modifiers pass through to the Vega-Lite
/// runtime, which computes them at render time.
#derive(Eq, Debug)
pub struct ChartSpec {
  kind : ChartKind
  x : VegaChannel?
  y : VegaChannel?
  x2 : VegaChannel?
  y2 : VegaChannel?
  x_error : VegaChannel?
  x_error2 : VegaChannel?
  y_error : VegaChannel?
  y_error2 : VegaChannel?
  x_offset : VegaChannel?
  y_offset : VegaChannel?
  longitude : VegaChannel?
  longitude2 : VegaChannel?
  latitude : VegaChannel?
  latitude2 : VegaChannel?
  theta : VegaChannel?
  theta2 : VegaChannel?
  radius : VegaChannel?
  radius2 : VegaChannel?
  color : VegaChannel?
  fill : VegaChannel?
  stroke : VegaChannel?
  opacity : VegaChannel?
  fill_opacity : VegaChannel?
  stroke_opacity : VegaChannel?
  stroke_width : VegaChannel?
  stroke_dash : VegaChannel?
  size : VegaChannel?
  shape : VegaChannel?
  angle : VegaChannel?
  time : VegaChannel?
  text : VegaChannel?
  tooltip : VegaChannel?
  href : VegaChannel?
  url : VegaChannel?
  description_channel : VegaChannel?
  key : VegaChannel?
  detail : VegaChannel?
  order : VegaChannel?
  title : VegaTitle?
  width : VegaExtent?
  height : VegaExtent?
  name : String?
  description : String?
  autosize : VegaAutoSize?
  padding : VegaPadding?
  background : String?
  projection : VegaProjection?
  view : VegaViewBackground?
  priv transform : Array[VegaTransform]?
  priv params : Array[VegaParam]?
  config : VegaConfig?
  usermeta : Json?
}

///|
pub extend ChartSpec with Eq::{equal, not_equal}

///|
pub extend ChartSpec with Debug::{to_repr}

///|
/// The parameter declarations, copied — reading the field itself would
/// hand the caller the array the spec holds.
pub fn ChartSpec::params(self : ChartSpec) -> Array[VegaParam]? {
  match self.params {
    Some(ps) => Some(ps.copy())
    None => None
  }
}

///|
/// The transform pipeline, copied — reading the field itself would
/// hand the caller the array the spec holds.
pub fn ChartSpec::transform(self : ChartSpec) -> Array[VegaTransform]? {
  match self.transform {
    Some(ts) => Some(ts.copy())
    None => None
  }
}

///|
/// The blank a constructor fills in: a spec of the given kind with every
/// channel and every chrome property unset, so each mark-named
/// constructor names only what it sets.
fn empty_channel_spec(kind : ChartKind) -> ChartSpec {
  {
    kind,
    x: None,
    y: None,
    x2: None,
    y2: None,
    x_error: None,
    x_error2: None,
    y_error: None,
    y_error2: None,
    x_offset: None,
    y_offset: None,
    longitude: None,
    longitude2: None,
    latitude: None,
    latitude2: None,
    theta: None,
    theta2: None,
    radius: None,
    radius2: None,
    color: None,
    fill: None,
    stroke: None,
    opacity: None,
    fill_opacity: None,
    stroke_opacity: None,
    stroke_width: None,
    stroke_dash: None,
    size: None,
    shape: None,
    angle: None,
    time: None,
    text: None,
    tooltip: None,
    href: None,
    url: None,
    description_channel: None,
    key: None,
    detail: None,
    order: None,
    title: None,
    width: None,
    height: None,
    name: None,
    description: None,
    autosize: None,
    padding: None,
    background: None,
    projection: None,
    view: None,
    transform: None,
    params: None,
    config: None,
    usermeta: None,
  }
}

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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Bar),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    x2,
    y2,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Line),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Point),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Area),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    x2,
    y2,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Tick),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Rect),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    x2,
    y2,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Rule),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    x2,
    y2,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Circle),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Square),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Trail),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    detail,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Text),
    x: Some(x),
    y: Some(y),
    text: Some(text),
    color,
    size,
    opacity,
    tooltip,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Arc),
    theta: Some(theta),
    color,
    opacity,
    tooltip,
    radius,
    radius2,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
    width,
    height,
  }
}

///|
/// An image chart of `y` against `x` (Vega-Lite `mark: "image"`) — the
/// `url` channel's cell (an image URL) drawn at each point.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::image(
  x : VegaChannel,
  y : VegaChannel,
  url : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Image),
    x: Some(x),
    y: Some(y),
    url: Some(url),
    opacity,
    tooltip,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
    width,
    height,
  }
}

///|
/// A geographic-shape chart (Vega-Lite `mark: "geoshape"`): the `shape`
/// channel names the GeoJSON column (`field("geo", type_override=Geojson)`
/// — the dtype rule never infers geojson from a `String` column).
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::geoshape(
  shape : VegaChannel,
  color? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Geoshape),
    shape: Some(shape),
    color,
    opacity,
    tooltip,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
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
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Boxplot),
    x: Some(x),
    y: Some(y),
    color,
    size,
    opacity,
    tooltip,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
    width,
    height,
  }
}

///|
/// An error-bar chart of `y` against `x` (Vega-Lite `mark: "errorbar"`)
/// — a point with an error interval; the interval comes from an error
/// channel (`x_error` / `y_error`, optionally with its far end in
/// `x_error2` / `y_error2`) or, absent one, from the channel's own
/// spread, which the runtime computes.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::errorbar(
  x : VegaChannel,
  y : VegaChannel,
  x_error? : VegaChannel,
  x_error2? : VegaChannel,
  y_error? : VegaChannel,
  y_error2? : VegaChannel,
  color? : VegaChannel,
  size? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Errorbar),
    x: Some(x),
    y: Some(y),
    x_error,
    x_error2,
    y_error,
    y_error2,
    color,
    size,
    opacity,
    tooltip,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
    width,
    height,
  }
}

///|
/// An error-band chart of `y` against `x` (Vega-Lite `mark:
/// "errorband"`) — a line or area with a band around it; the band comes
/// from an error channel (`y_error` / `x_error`, optionally with its far
/// end in the `2` form) or, absent one, from the channel's own spread,
/// which the runtime computes.
///
/// The optional parameters carry the `ChartSpec` doc's channel contract.
pub fn ChartSpec::errorband(
  x : VegaChannel,
  y : VegaChannel,
  x_error? : VegaChannel,
  x_error2? : VegaChannel,
  y_error? : VegaChannel,
  y_error2? : VegaChannel,
  color? : VegaChannel,
  opacity? : VegaChannel,
  tooltip? : VegaChannel,
  detail? : VegaChannel,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> ChartSpec {
  {
    ..empty_channel_spec(Errorband),
    x: Some(x),
    y: Some(y),
    x_error,
    x_error2,
    y_error,
    y_error2,
    color,
    opacity,
    tooltip,
    detail,
    title: match title {
      Some(t) => Some(VegaTitle::Text(t))
      None => None
    },
    width,
    height,
  }
}

///|
/// The general form: a spec of any `kind` with any channel and any
/// top-level chrome property named — every encoding channel the schema's
/// `Encoding` lists (the mark-named constructors carry only the channels
/// their mark commonly consumes), plus `title`, `width`, `height`,
/// `name`, `description`, `autosize`, `padding`, and `background`.
/// Channels resolve in the fixed order the `ChartSpec` doc states.
pub fn ChartSpec::of(
  kind : ChartKind,
  x? : VegaChannel,
  y? : VegaChannel,
  x2? : VegaChannel,
  y2? : VegaChannel,
  x_error? : VegaChannel,
  x_error2? : VegaChannel,
  y_error? : VegaChannel,
  y_error2? : VegaChannel,
  x_offset? : VegaChannel,
  y_offset? : VegaChannel,
  longitude? : VegaChannel,
  longitude2? : VegaChannel,
  latitude? : VegaChannel,
  latitude2? : VegaChannel,
  theta? : VegaChannel,
  theta2? : VegaChannel,
  radius? : VegaChannel,
  radius2? : VegaChannel,
  color? : VegaChannel,
  fill? : VegaChannel,
  stroke? : VegaChannel,
  opacity? : VegaChannel,
  fill_opacity? : VegaChannel,
  stroke_opacity? : VegaChannel,
  stroke_width? : VegaChannel,
  stroke_dash? : VegaChannel,
  size? : VegaChannel,
  shape? : VegaChannel,
  angle? : VegaChannel,
  time? : VegaChannel,
  text? : VegaChannel,
  tooltip? : VegaChannel,
  href? : VegaChannel,
  url? : VegaChannel,
  description_channel? : VegaChannel,
  key? : VegaChannel,
  detail? : VegaChannel,
  order? : VegaChannel,
  title? : VegaTitle,
  width? : VegaExtent,
  height? : VegaExtent,
  name? : String,
  description? : String,
  autosize? : VegaAutoSize,
  padding? : VegaPadding,
  background? : String,
  projection? : VegaProjection,
  view? : VegaViewBackground,
  transform? : Array[VegaTransform],
  params? : Array[VegaParam],
  config? : VegaConfig,
  usermeta? : Json,
) -> ChartSpec {
  {
    ..empty_channel_spec(kind),
    x,
    y,
    x2,
    y2,
    x_error,
    x_error2,
    y_error,
    y_error2,
    x_offset,
    y_offset,
    longitude,
    longitude2,
    latitude,
    latitude2,
    theta,
    theta2,
    radius,
    radius2,
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
    time,
    text,
    tooltip,
    href,
    url,
    description_channel,
    key,
    detail,
    order,
    title,
    width,
    height,
    name,
    description,
    autosize,
    padding,
    background,
    projection,
    view,
    transform: match transform {
      Some(ts) => Some(ts.copy())
      None => None
    },
    params: match params {
      Some(ps) => Some(ps.copy())
      None => None
    },
    config,
    usermeta,
  }
}

///|
/// Render `df` and `spec` as a complete Vega-Lite v6 specification JSON
/// string: `$schema` (pinned to the Vega-Lite v6 schema URL) + the
/// optional chrome (`name`, `description`, `title`, `autosize`,
/// `background`, `padding`, `width`, `height`) + `mark` (from
/// `spec.kind`) + `encoding` (the spec's channels, each `{field, type}`
/// or a `value` / `datum` definition, plus its declared modifiers) +
/// `data.values` (the frame inlined as JSON records, sharing
/// `format_json`'s cell mapping — null and non-finite-float cells become
/// JSON `null`). A frame with the encoded columns but zero rows yields
/// `"data":{"values":[]}`.
///
/// Each field channel's `type` follows its column's dtype — the single
/// statement of the dtype→type rule: a numeric column (`Int` / `Float` /
/// `Decimal`) is `"quantitative"`, a `Date` / `Timestamp` column is
/// `"temporal"` (its ISO cells — `data.values`' date units, via the JSON
/// records' ISO mapping — sort chronologically, and a temporal axis
/// orders by time rather than by first appearance), and every other
/// dtype is `"nominal"` — unless the channel carries an explicit
/// `type_override`. A count channel reads no column and is
/// `"quantitative"`.
///
/// The spec's channels are resolved in the fixed order the `ChartSpec`
/// doc states (`x` first through `order` last), and the first name
/// absent from `df` raises `ColumnNotFound(name)`; this is the one
/// reason the function is not **total** (it accepts column names, and a
/// name can be wrong). The declared modifiers are not computed here —
/// the Vega-Lite runtime evaluates them at render time. The emitted text
/// is always valid JSON (it is built through `@json` and stringified),
/// so it round-trips through any standards-compliant JSON / Vega-Lite
/// reader.
pub fn format_vega_lite(
  df : @frame.DataFrame,
  chart : Chart,
) -> String raise @types.DataError {
  let obj : Map[String, Json] = Map([])
  obj["$schema"] = Json::string(
    "https://vega.github.io/schema/vega-lite/v6.json",
  )
  chart_emit(chart, df, obj)
  let data : Map[String, Json] = Map([])
  data["values"] = Json::array(@io.df_to_json_records(df))
  obj["data"] = Json::object(data)
  Json::object(obj).stringify()
}

///|
/// Emit one chart into `obj` — a single view's fields, or a composition
/// operator's own shape — without `$schema` and `data`: those belong to
/// the top level alone, so a nested child (a layer member, a facet's
/// spec) reuses this same emission over the shared frame.
fn chart_emit(
  chart : Chart,
  df : @frame.DataFrame,
  obj : Map[String, Json],
) -> Unit raise @types.DataError {
  match chart {
    Single(spec) => unit_emit(spec, df, obj)
    Layer(layer) => {
      obj["layer"] = Json::array(
        layer.layer.map(child => chart_child(child, df)),
      )
      put_layer_chrome(layer, obj)
    }
    VConcat(concat) => {
      obj["vconcat"] = Json::array(
        concat.concat.map(child => chart_child(child, df)),
      )
      put_concat_chrome(concat, obj, false)
    }
    HConcat(concat) => {
      obj["hconcat"] = Json::array(
        concat.concat.map(child => chart_child(child, df)),
      )
      put_concat_chrome(concat, obj, false)
    }
    Concat(concat) => {
      obj["concat"] = Json::array(
        concat.concat.map(child => chart_child(child, df)),
      )
      put_concat_chrome(concat, obj, true)
    }
    Facet(facet) => {
      // The facet's own channels resolve before its spec: the row /
      // column fields name columns of the shared frame, and a missing one
      // raises `ColumnNotFound` ahead of the child.
      let facet_obj : Map[String, Json] = Map([])
      if facet.row is Some(row) {
        facet_obj["row"] = facet_channel_json(row, resolve_facet(df, row))
      }
      if facet.column is Some(column) {
        facet_obj["column"] = facet_channel_json(
          column,
          resolve_facet(df, column),
        )
      }
      obj["facet"] = Json::object(facet_obj)
      obj["spec"] = chart_child(facet.spec, df)
      put_facet_chrome(facet, obj)
    }
    Repeat(repeat) => {
      let repeat_obj : Map[String, Json] = Map([])
      if repeat.row is Some(row) {
        repeat_obj["row"] = Json::array(row.map(fn(f) { Json::string(f) }))
      }
      if repeat.column is Some(column) {
        repeat_obj["column"] = Json::array(
          column.map(fn(f) { Json::string(f) }),
        )
      }
      obj["repeat"] = Json::object(repeat_obj)
      obj["spec"] = chart_child(repeat.spec, df)
      put_repeat_chrome(repeat, obj)
    }
  }
}

///|
/// One nested child as a JSON object — the same emission as the top
/// level, minus the `$schema` / `data` that belong there alone.
fn chart_child(
  chart : Chart,
  df : @frame.DataFrame,
) -> Json raise @types.DataError {
  let obj : Map[String, Json] = Map([])
  chart_emit(chart, df, obj)
  Json::object(obj)
}

///|
/// The layer spec's chrome: the title block, the names, the view size
/// and background, the projection, and the resolve block.
fn put_layer_chrome(layer : VegaLayer, obj : Map[String, Json]) -> Unit {
  if layer.name is Some(name) {
    obj["name"] = Json::string(name)
  }
  if layer.description is Some(description) {
    obj["description"] = Json::string(description)
  }
  if layer.title is Some(title) {
    obj["title"] = vega_title_emit_json(title)
  }
  if layer.width is Some(width) {
    obj["width"] = extent_json(width)
  }
  if layer.height is Some(height) {
    obj["height"] = extent_json(height)
  }
  if layer.view is Some(view) {
    obj["view"] = vega_view_background_emit_json(view)
  }
  if layer.projection is Some(projection) {
    obj["projection"] = vega_projection_emit_json(projection)
  }
  if layer.resolve is Some(resolve) {
    obj["resolve"] = vega_resolve_emit_json(resolve)
  }
  if layer.transform is Some(transforms) {
    obj["transform"] = vega_transforms_emit_json(transforms)
  }
}

///|
/// The concat family's chrome and layout: bounds, centering, and
/// spacing for all three; the alignment and wrap column count only for
/// the wrapped `Concat` (a vertical / horizontal concat's direction
/// fixes those); the title block, names, and resolve for all.
fn put_concat_chrome(
  concat : VegaConcat,
  obj : Map[String, Json],
  wrapped : Bool,
) -> Unit {
  if concat.bounds is Some(bounds) {
    obj["bounds"] = Json::string(vega_bounds_string(bounds))
  }
  if concat.center is Some(center) {
    obj["center"] = vega_center_emit_json(center)
  }
  if concat.spacing is Some(spacing) {
    obj["spacing"] = vega_spacing_emit_json(spacing)
  }
  if wrapped && concat.align is Some(align) {
    obj["align"] = vega_align_mode_emit_json(align)
  }
  if wrapped && concat.columns is Some(columns) {
    obj["columns"] = Json::number(columns)
  }
  if concat.name is Some(name) {
    obj["name"] = Json::string(name)
  }
  if concat.description is Some(description) {
    obj["description"] = Json::string(description)
  }
  if concat.title is Some(title) {
    obj["title"] = vega_title_emit_json(title)
  }
  if concat.resolve is Some(resolve) {
    obj["resolve"] = vega_resolve_emit_json(resolve)
  }
  if concat.transform is Some(transforms) {
    obj["transform"] = vega_transforms_emit_json(transforms)
  }
}

///|
/// The facet spec's chrome and layout: alignment, bounds, centering,
/// spacing, the wrap column count, the title block, the names, and the
/// resolve block.
fn put_facet_chrome(facet : VegaFacet, obj : Map[String, Json]) -> Unit {
  if facet.align is Some(align) {
    obj["align"] = vega_align_mode_emit_json(align)
  }
  if facet.bounds is Some(bounds) {
    obj["bounds"] = Json::string(vega_bounds_string(bounds))
  }
  if facet.center is Some(center) {
    obj["center"] = vega_center_emit_json(center)
  }
  if facet.spacing is Some(spacing) {
    obj["spacing"] = vega_spacing_emit_json(spacing)
  }
  if facet.columns is Some(columns) {
    obj["columns"] = Json::number(columns)
  }
  if facet.name is Some(name) {
    obj["name"] = Json::string(name)
  }
  if facet.description is Some(description) {
    obj["description"] = Json::string(description)
  }
  if facet.title is Some(title) {
    obj["title"] = vega_title_emit_json(title)
  }
  if facet.resolve is Some(resolve) {
    obj["resolve"] = vega_resolve_emit_json(resolve)
  }
  if facet.transform is Some(transforms) {
    obj["transform"] = vega_transforms_emit_json(transforms)
  }
}

///|
/// The repeat spec's chrome and layout — the same set a facet carries.
fn put_repeat_chrome(repeat : VegaRepeat, obj : Map[String, Json]) -> Unit {
  if repeat.align is Some(align) {
    obj["align"] = vega_align_mode_emit_json(align)
  }
  if repeat.bounds is Some(bounds) {
    obj["bounds"] = Json::string(vega_bounds_string(bounds))
  }
  if repeat.center is Some(center) {
    obj["center"] = vega_center_emit_json(center)
  }
  if repeat.spacing is Some(spacing) {
    obj["spacing"] = vega_spacing_emit_json(spacing)
  }
  if repeat.columns is Some(columns) {
    obj["columns"] = Json::number(columns)
  }
  if repeat.name is Some(name) {
    obj["name"] = Json::string(name)
  }
  if repeat.description is Some(description) {
    obj["description"] = Json::string(description)
  }
  if repeat.title is Some(title) {
    obj["title"] = vega_title_emit_json(title)
  }
  if repeat.resolve is Some(resolve) {
    obj["resolve"] = vega_resolve_emit_json(resolve)
  }
  if repeat.transform is Some(transforms) {
    obj["transform"] = vega_transforms_emit_json(transforms)
  }
}

///|
/// Resolve a facet channel's column against the frame — the facet
/// sibling of the encoding channels' existence check: a non-count
/// channel's field is read for its dtype (a count aggregate needs no
/// column), and a missing name raises `ColumnNotFound`.
fn resolve_facet(
  df : @frame.DataFrame,
  channel : VegaFacetChannel,
) -> @types.DataType? raise @types.DataError {
  if channel.aggregate is Some(Count) {
    None
  } else {
    match channel.field {
      Some(name) => Some(df.get_column(name).dtype())
      None => None
    }
  }
}

///|
/// One facet channel's JSON: the emitted field definition plus its
/// `type`, which a facet channel carries like any encoding channel —
/// inferred from the column dtype, or overridden; a count facet channel
/// carries no `type`. The facet host has no bare-channel sort form, so
/// `ByChannel` raises `InvalidOperation` here rather than emitting a
/// string the schema's `FacetFieldDef.sort` would reject.
fn facet_channel_json(
  channel : VegaFacetChannel,
  dtype : @types.DataType?,
) -> Json raise @types.DataError {
  let ch : Map[String, Json] = Map([])
  match (channel.field, dtype) {
    (Some(field), Some(d)) => {
      ch["field"] = Json::string(field)
      // The type rides directly after the field, as in an encoding
      // channel: inferred from the column dtype, or overridden; a count
      // facet channel carries neither — `resolve_facet` hands back no
      // dtype for one, so this arm is the present-field case alone.
      let inferred : String = if channel.type_override is Some(t) {
        vega_type_string(t)
      } else if d.is_numeric() || d is @types.DataType::Decimal(_) {
        "quantitative"
      } else if d is @types.DataType::Date ||
        d is @types.DataType::Timestamp ||
        d is @types.DataType::Duration {
        "temporal"
      } else {
        "nominal"
      }
      ch["type"] = Json::string(inferred)
    }
    _ => ()
  }
  if channel.aggregate is Some(op) {
    ch["aggregate"] = Json::string(aggregate_string(op))
  }
  if channel.bin is Some(bin) {
    ch["bin"] = bin_json(bin)
  }
  if channel.time_unit is Some(unit) {
    ch["timeUnit"] = Json::string(time_unit_string(unit))
  }
  if channel.sort is Some(sort) {
    match sort {
      ByChannel(_, _) =>
        raise @types.DataError::InvalidOperation(
          "a facet channel's sort cannot key on another channel (the schema's FacetFieldDef.sort has no bare-channel form); sort by a field or an explicit order instead",
        )
      _ => ch["sort"] = sort_json(sort)
    }
  }
  if channel.title is Some(title) {
    ch["title"] = Json::string(title)
  }
  if channel.band_position is Some(band) {
    ch["bandPosition"] = Json::number(band)
  }
  if channel.header is Some(header) {
    ch["header"] = vega_header_emit_json(header)
  }
  Json::object(ch)
}

///|
/// A single view's own fields: the chrome (`name`, `description`,
/// `title`, `autosize`, `background`, `padding`, `width`, `height`,
/// `view`, `projection`), the `mark`, and the `encoding` with its
/// channels resolved in the fixed order — everything but `$schema` and
/// `data`, which belong to the top level.
fn unit_emit(
  spec : ChartSpec,
  df : @frame.DataFrame,
  obj : Map[String, Json],
) -> Unit raise @types.DataError {
  if spec.name is Some(name) {
    obj["name"] = Json::string(name)
  }
  if spec.description is Some(description) {
    obj["description"] = Json::string(description)
  }
  if spec.title is Some(title) {
    obj["title"] = vega_title_emit_json(title)
  }
  if spec.autosize is Some(autosize) {
    obj["autosize"] = autosize_json(autosize)
  }
  if spec.background is Some(background) {
    obj["background"] = Json::string(background)
  }
  if spec.padding is Some(padding) {
    obj["padding"] = padding_json(padding)
  }
  if spec.width is Some(width) {
    obj["width"] = extent_json(width)
  }
  if spec.height is Some(height) {
    obj["height"] = extent_json(height)
  }
  if spec.view is Some(view) {
    obj["view"] = vega_view_background_emit_json(view)
  }
  if spec.projection is Some(projection) {
    obj["projection"] = vega_projection_emit_json(projection)
  }
  if spec.transform is Some(transforms) {
    obj["transform"] = vega_transforms_emit_json(transforms)
  }
  if spec.params is Some(params) {
    obj["params"] = vega_params_emit_json(params)
  }
  if spec.config is Some(config) {
    obj["config"] = vega_config_emit_json(config)
  }
  if spec.usermeta is Some(usermeta) {
    obj["usermeta"] = usermeta
  }
  // The Vega-Lite `mark` string for the chart kind.
  obj["mark"] = Json::string(mark_string(spec.kind))
  // Resolve the channels in the fixed order the `ChartSpec` doc states,
  // so a missing column raises `ColumnNotFound` in that order.
  // `channel_dtype` doubles as the existence check and the dtype source
  // for Vega-Lite's field-`type` inference; a count, constant, or datum
  // channel reads no column.
  let encoding : Map[String, Json] = Map([])
  put_channel(encoding, "x", df, spec.x)
  put_channel(encoding, "y", df, spec.y)
  put_channel(encoding, "x2", df, spec.x2)
  put_channel(encoding, "y2", df, spec.y2)
  put_channel(encoding, "xError", df, spec.x_error)
  put_channel(encoding, "xError2", df, spec.x_error2)
  put_channel(encoding, "yError", df, spec.y_error)
  put_channel(encoding, "yError2", df, spec.y_error2)
  put_channel(encoding, "xOffset", df, spec.x_offset)
  put_channel(encoding, "yOffset", df, spec.y_offset)
  put_channel(encoding, "longitude", df, spec.longitude)
  put_channel(encoding, "longitude2", df, spec.longitude2)
  put_channel(encoding, "latitude", df, spec.latitude)
  put_channel(encoding, "latitude2", df, spec.latitude2)
  put_channel(encoding, "theta", df, spec.theta)
  put_channel(encoding, "theta2", df, spec.theta2)
  put_channel(encoding, "radius", df, spec.radius)
  put_channel(encoding, "radius2", df, spec.radius2)
  put_channel(encoding, "color", df, spec.color)
  put_channel(encoding, "fill", df, spec.fill)
  put_channel(encoding, "stroke", df, spec.stroke)
  put_channel(encoding, "opacity", df, spec.opacity)
  put_channel(encoding, "fillOpacity", df, spec.fill_opacity)
  put_channel(encoding, "strokeOpacity", df, spec.stroke_opacity)
  put_channel(encoding, "strokeWidth", df, spec.stroke_width)
  put_channel(encoding, "strokeDash", df, spec.stroke_dash)
  put_channel(encoding, "size", df, spec.size)
  put_channel(encoding, "shape", df, spec.shape)
  put_channel(encoding, "angle", df, spec.angle)
  put_channel(encoding, "time", df, spec.time)
  put_channel(encoding, "text", df, spec.text)
  put_channel(encoding, "tooltip", df, spec.tooltip)
  put_channel(encoding, "href", df, spec.href)
  put_channel(encoding, "url", df, spec.url)
  put_channel(encoding, "description", df, spec.description_channel)
  put_channel(encoding, "key", df, spec.key)
  put_channel(encoding, "detail", df, spec.detail)
  put_channel(encoding, "order", df, spec.order)
  obj["encoding"] = Json::object(encoding)
}

///|
/// Write a Vega-Lite v6 spec for `df` / `chart` to `path`. Mirrors
/// `write_json`: a `ColumnNotFound` from `format_vega_lite` (a spec
/// column absent from `df`) propagates unchanged, a filesystem failure
/// surfaces as `raise IoError(message)`, and content holding an unpaired
/// UTF-16 surrogate is refused with `raise InvalidOperation`.
pub fn write_vega_lite(
  path : String,
  df : @frame.DataFrame,
  chart : Chart,
) -> Unit raise @types.DataError {
  let content = format_vega_lite(df, chart)
  @io.write_text(path, content)
}
