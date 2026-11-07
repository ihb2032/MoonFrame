// The frame-first entry into the chart export: `plot(df)` binds the
// frame once, the mark methods name their channels as plain column
// names, and the terminals render without re-passing the data. This
// layer is sugar over the mirror — each method constructs the same
// `ChartSpec` the corresponding mark-named constructor builds
// (`FramePlot::bar` wraps each column name in `field`), so the
// format's facts keep their one home in the mirror and its vendored
// schema; a chain here emits what the mirror emits, byte for byte.
//
// The chain has two stages. `FramePlot` — what `plot` returns —
// carries the frame and picks a mark; `Plot` refines the chosen view:
// `encode` swaps a channel for a full `VegaChannel`, the chrome
// setters adjust title and size, the hatches hand out the underlying
// `ChartSpec` / `Chart`, and the terminals serialise. The split keeps
// the ordering honest at compile time — chrome before a mark has
// nothing to attach to, so the chain starts with a mark or it does
// not type-check.
//
// The data work stays on the frame: filter and aggregate the
// `DataFrame` before `plot`, the way the rest of the library does it.
// Spec-level transforms and params belong to the mirror
// (`ChartSpec::of`).

///|
/// Bind `df` as the data of a chart and pick its mark: the returned
/// `FramePlot` carries a mark method per `ChartSpec` constructor, each
/// taking plain column names where the mirror takes a `VegaChannel`.
/// The frame is held for the terminals, so it appears once, here,
/// rather than at every render call:
///
///   `plot(df).bar(x="region", y="revenue").write_html("out.html")`
pub fn plot(df : @frame.DataFrame) -> FramePlot {
  { df, }
}

///|
/// The mark-picking stage of a plot. Each method is the sugar of its
/// `ChartSpec` counterpart — the same channels, named as columns, plus
/// the constructor's `title` / `width` / `height` chrome. A bare column
/// name wraps in `field`, so the channel's emitted `type` follows its
/// column's dtype at render time. To encode something other than a
/// bare column (an aggregate, a bin, a constant), mark with the plain
/// column and replace the channel afterwards through `Plot::encode`
/// with one built by `field` / `constant` / `datum`. Marking again is
/// a fresh `plot(df)`.
pub struct FramePlot {
  priv df : @frame.DataFrame
}

///|

///|
/// A mark method's optional column argument into an optional channel —
/// every method spells its channel picks this way, so the wrap lives
/// here once. `field` carries an optional parameter, so the call cannot
/// be curried into `map` directly.
fn opt_field(name : String?) -> VegaChannel? {
  name.map(v => field(v))
}

///|
/// `ChartSpec::bar` with its channels taken as column names.
/// `ChartSpec::bar` with its channels taken as column names.
pub fn FramePlot::bar(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  x2? : String,
  y2? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::bar(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      x2?=opt_field(x2),
      y2?=opt_field(y2),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::line` with its channels taken as column names.
pub fn FramePlot::line(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::line(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::point` with its channels taken as column names.
pub fn FramePlot::point(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::point(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::area` with its channels taken as column names.
pub fn FramePlot::area(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  x2? : String,
  y2? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::area(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      x2?=opt_field(x2),
      y2?=opt_field(y2),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::tick` with its channels taken as column names.
pub fn FramePlot::tick(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::tick(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::rect` with its channels taken as column names.
pub fn FramePlot::rect(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  x2? : String,
  y2? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::rect(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      x2?=opt_field(x2),
      y2?=opt_field(y2),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::rule` with its channels taken as column names.
pub fn FramePlot::rule(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  x2? : String,
  y2? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::rule(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      x2?=opt_field(x2),
      y2?=opt_field(y2),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::circle` with its channels taken as column names.
pub fn FramePlot::circle(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::circle(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::square` with its channels taken as column names.
pub fn FramePlot::square(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::square(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::trail` with its channels taken as column names.
pub fn FramePlot::trail(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::trail(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::text` with its channels taken as column names.
pub fn FramePlot::text(
  self : FramePlot,
  x~ : String,
  y~ : String,
  text~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::text(
      field(x),
      field(y),
      field(text),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::arc` with its channels taken as column names.
pub fn FramePlot::arc(
  self : FramePlot,
  theta~ : String,
  color? : String,
  opacity? : String,
  tooltip? : String,
  radius? : String,
  radius2? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::arc(
      field(theta),
      color?=opt_field(color),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      radius?=opt_field(radius),
      radius2?=opt_field(radius2),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::image` with its channels taken as column names.
pub fn FramePlot::image(
  self : FramePlot,
  x~ : String,
  y~ : String,
  url~ : String,
  opacity? : String,
  tooltip? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::image(
      field(x),
      field(y),
      field(url),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::geoshape` with its channels taken as column names.
pub fn FramePlot::geoshape(
  self : FramePlot,
  shape~ : String,
  color? : String,
  opacity? : String,
  tooltip? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::geoshape(
      field(shape),
      color?=opt_field(color),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::boxplot` with its channels taken as column names.
pub fn FramePlot::boxplot(
  self : FramePlot,
  x~ : String,
  y~ : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::boxplot(
      field(x),
      field(y),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::errorbar` with its channels taken as column names.
pub fn FramePlot::errorbar(
  self : FramePlot,
  x~ : String,
  y~ : String,
  x_error? : String,
  x_error2? : String,
  y_error? : String,
  y_error2? : String,
  color? : String,
  size? : String,
  opacity? : String,
  tooltip? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::errorbar(
      field(x),
      field(y),
      x_error?=opt_field(x_error),
      x_error2?=opt_field(x_error2),
      y_error?=opt_field(y_error),
      y_error2?=opt_field(y_error2),
      color?=opt_field(color),
      size?=opt_field(size),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// `ChartSpec::errorband` with its channels taken as column names.
pub fn FramePlot::errorband(
  self : FramePlot,
  x~ : String,
  y~ : String,
  x_error? : String,
  x_error2? : String,
  y_error? : String,
  y_error2? : String,
  color? : String,
  opacity? : String,
  tooltip? : String,
  detail? : String,
  title? : String,
  width? : VegaExtent,
  height? : VegaExtent,
) -> Plot {
  {
    df: self.df,
    spec: ChartSpec::errorband(
      field(x),
      field(y),
      x_error?=opt_field(x_error),
      x_error2?=opt_field(x_error2),
      y_error?=opt_field(y_error),
      y_error2?=opt_field(y_error2),
      color?=opt_field(color),
      opacity?=opt_field(opacity),
      tooltip?=opt_field(tooltip),
      detail?=opt_field(detail),
      title?,
      width?,
      height?,
    ),
  }
}

///|
/// A marked plot over a bound frame: refine the encoding, set the
/// chrome, or render. `encode` replaces the channels it is given and
/// keeps the rest; the chrome setters overwrite the title / width /
/// height; the hatches hand out the underlying `ChartSpec` and `Chart`
/// for what the chain does not name (scales, axes, config,
/// composition); the terminals serialise — `to_json` is
/// `format_vega_lite` over the bound frame, `to_html` its page form,
/// and `write_json` / `write_html` the file-writing pair.
pub struct Plot {
  priv df : @frame.DataFrame
  priv spec : ChartSpec
}

///|
/// The `Plot::encode` merge rule: a channel given as `Some` replaces
/// the spec's; one left out keeps the spec's.
fn channel_or(old : VegaChannel?, new : VegaChannel?) -> VegaChannel? {
  match new {
    Some(_) => new
    None => old
  }
}

///|
/// Replace the given encoding channels with full `VegaChannel`s —
/// e.g. `plot(df).bar(x="region",
/// y="revenue").encode(y=field("revenue", aggregate=Sum))`. A channel
/// named here overwrites the mark's; one left out keeps its current
/// value. A channel cannot be cleared through this method — take the
/// `spec()` hatch for that. The parameter set is `ChartSpec::of`'s
/// channel list.
pub fn Plot::encode(
  self : Plot,
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
) -> Plot {
  {
    df: self.df,
    spec: {
      ..self.spec,
      x: channel_or(self.spec.x, x),
      y: channel_or(self.spec.y, y),
      x2: channel_or(self.spec.x2, x2),
      y2: channel_or(self.spec.y2, y2),
      x_error: channel_or(self.spec.x_error, x_error),
      x_error2: channel_or(self.spec.x_error2, x_error2),
      y_error: channel_or(self.spec.y_error, y_error),
      y_error2: channel_or(self.spec.y_error2, y_error2),
      x_offset: channel_or(self.spec.x_offset, x_offset),
      y_offset: channel_or(self.spec.y_offset, y_offset),
      longitude: channel_or(self.spec.longitude, longitude),
      longitude2: channel_or(self.spec.longitude2, longitude2),
      latitude: channel_or(self.spec.latitude, latitude),
      latitude2: channel_or(self.spec.latitude2, latitude2),
      theta: channel_or(self.spec.theta, theta),
      theta2: channel_or(self.spec.theta2, theta2),
      radius: channel_or(self.spec.radius, radius),
      radius2: channel_or(self.spec.radius2, radius2),
      color: channel_or(self.spec.color, color),
      fill: channel_or(self.spec.fill, fill),
      stroke: channel_or(self.spec.stroke, stroke),
      opacity: channel_or(self.spec.opacity, opacity),
      fill_opacity: channel_or(self.spec.fill_opacity, fill_opacity),
      stroke_width: channel_or(self.spec.stroke_width, stroke_width),
      stroke_dash: channel_or(self.spec.stroke_dash, stroke_dash),
      size: channel_or(self.spec.size, size),
      shape: channel_or(self.spec.shape, shape),
      angle: channel_or(self.spec.angle, angle),
      time: channel_or(self.spec.time, time),
      text: channel_or(self.spec.text, text),
      tooltip: channel_or(self.spec.tooltip, tooltip),
      href: channel_or(self.spec.href, href),
      url: channel_or(self.spec.url, url),
      description_channel: channel_or(
        self.spec.description_channel,
        description_channel,
      ),
      key: channel_or(self.spec.key, key),
      detail: channel_or(self.spec.detail, detail),
      order: channel_or(self.spec.order, order),
    },
  }
}

///|
/// Set the top-level title — the `title` chrome the mark methods also
/// carry, settable after the mark.
pub fn Plot::title(self : Plot, title : String) -> Plot {
  { df: self.df, spec: { ..self.spec, title: Some(VegaTitle::Text(title)), }, }
}

///|
/// Set the top-level width.
pub fn Plot::width(self : Plot, width : VegaExtent) -> Plot {
  { df: self.df, spec: { ..self.spec, width: Some(width), }, }
}

///|
/// Set the top-level height.
pub fn Plot::height(self : Plot, height : VegaExtent) -> Plot {
  { df: self.df, spec: { ..self.spec, height: Some(height), }, }
}

///|
/// The underlying single-view `Chart` — the composition layer
/// (layering, concatenation, faceting) builds over `Chart`s.
pub fn Plot::chart(self : Plot) -> Chart {
  Chart::of(self.spec)
}

///|
/// The underlying `ChartSpec` — a functional update over its fields
/// reaches the chrome the chain leaves unnamed.
pub fn Plot::spec(self : Plot) -> ChartSpec {
  self.spec
}

///|
/// Render as a Vega-Lite v6 JSON spec — `format_vega_lite` over the
/// bound frame and the built spec.
pub fn Plot::to_json(self : Plot) -> String raise @types.DataError {
  format_vega_lite(self.df, self.chart())
}

///|
/// Render as a self-contained HTML page — `format_vega_html` over the
/// bound frame and the built spec.
pub fn Plot::to_html(self : Plot) -> String raise @types.DataError {
  format_vega_html(self.df, self.chart())
}

///|
/// Write the Vega-Lite JSON spec to `path` — `write_vega_lite` over
/// the bound frame.
pub fn Plot::write_json(
  self : Plot,
  path : String,
) -> Unit raise @types.DataError {
  write_vega_lite(path, self.df, self.chart())
}

///|
/// Write the self-contained chart page to `path` — `write_vega_html`
/// over the bound frame.
pub fn Plot::write_html(
  self : Plot,
  path : String,
) -> Unit raise @types.DataError {
  write_vega_html(path, self.df, self.chart())
}
