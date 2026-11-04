// The mark family: the `ChartKind` a chart's mark-named constructor sets,
// and its Vega-Lite `mark` string. The variant set mirrors the schema's
// `Mark` enum (fourteen primitives) plus its three composites
// (`boxplot` / `errorbar` / `errorband`, legal as bare strings through the
// schema's `CompositeMark` union) — the vendored
// `.github/fixtures/vega_lite_v6_5_0.schema.json` is the list's home.

///|
/// The mark type of a chart, mapped to a Vega-Lite top-level `mark`:
/// `Bar → "bar"`, `Line → "line"`, `Point → "point"`, `Area → "area"`,
/// `Tick → "tick"`, `Rect → "rect"`, `Rule → "rule"`, `Circle → "circle"`,
/// `Square → "square"`, `Trail → "trail"`, `Text → "text"`,
/// `Arc → "arc"`, `Image → "image"`, `Geoshape → "geoshape"`, and the
/// composites `Boxplot → "boxplot"`, `Errorbar → "errorbar"`,
/// `Errorband → "errorband"`.
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
  Image
  Geoshape
  Boxplot
  Errorbar
  Errorband
}

///|
pub extend ChartKind with Eq::{equal, not_equal}

///|
pub extend ChartKind with Debug::{to_repr}

///|
/// The Vega-Lite `mark` string for the chart kind, one arm per variant so
/// a kind added to the enum fails compilation here until its string is
/// written.
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
    Image => "image"
    Geoshape => "geoshape"
    Boxplot => "boxplot"
    Errorbar => "errorbar"
    Errorband => "errorband"
  }
}
