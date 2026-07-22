// Vega-Lite v5 chart-spec export for `DataFrame`. `format_vega_lite`
// produces a complete, standalone Vega-Lite v5 top-level specification —
// `$schema` + optional `title` + `mark` + `encoding` + an inline
// `data.values` array — as a JSON string. The output drops straight into
// the Vega editor (<https://vega.github.io/editor/>) or any Vega-Lite
// runtime and renders without further wiring, so there is no private
// chart-data shape to learn: it is the standard declarative spec.
//
// This lives in `io` rather than on `DataFrame` because it is a
// serialisation to an external interchange format (the IO-1 boundary:
// `frame` keeps pure rendering like `to_markdown` / `to_html`; `io` owns
// the parsers and the JSON/CSV/NDJSON serialisers). It is a free function
// parallel to `format_json`, and it shares that file's
// `scalar_to_json` cell mapping through the common `df_to_json_records`
// helper — so a `data.values` cell follows exactly the same conventions
// as a JSON-records cell (nulls and non-finite floats become JSON `null`).
//
// Unlike `format_json` (which is **total**), `format_vega_lite`
// `raise`s: a `ChartSpec` names the `x` / `y` / `color` columns, and a
// name that is absent from the frame surfaces as `ColumnNotFound` rather
// than producing a spec that references a non-existent field.

///|
/// The mark type of a chart, mapped to a Vega-Lite top-level `mark`:
/// `Bar → "bar"`, `Line → "line"`, `Point → "point"`, `Area → "area"`.
/// `pub(all)` so callers can name the variants when building a `ChartSpec`
/// (though the `ChartSpec::bar` / `line` / `point` / `area` constructors
/// set the kind for you).
pub(all) enum ChartKind {
  Bar
  Line
  Point
  Area
} derive(Eq, Debug)

///|
pub extend ChartKind with Eq::{equal, not_equal}

///|
pub extend ChartKind with Debug::{to_repr}

///|
/// A Vega-Lite field `type`, used to override the dtype-based inference for the
/// `color` channel. `pub(all)` so callers can name the variants in a
/// constructor's `color_type`. `Quantitative` is a continuous measure (a color
/// gradient), `Nominal` an unordered category (distinct colors per value),
/// `Ordinal` an ordered category, and `Temporal` a time field.
pub(all) enum VegaType {
  Quantitative
  Nominal
  Ordinal
  Temporal
} derive(Eq, Debug)

///|
pub extend VegaType with Eq::{equal, not_equal}

///|
pub extend VegaType with Debug::{to_repr}

///|
/// The Vega-Lite `type` string for a `VegaType`.
fn vega_type_string(t : VegaType) -> String {
  match t {
    Quantitative => "quantitative"
    Nominal => "nominal"
    Ordinal => "ordinal"
    Temporal => "temporal"
  }
}

///|
/// A chart specification: the `mark` kind, the `x` / `y` encoding columns,
/// an optional `color` grouping column, and an optional `title`. Fields are
/// read-only outside the package — build a spec through one of the
/// mark-named constructors (`ChartSpec::bar(x, y)` / `line` / `point` /
/// `area`), naming `color` / `color_type` / `title` as needed:
///
///   `ChartSpec::bar("region", "revenue", title="Revenue by region")`
///
/// `x` / `y` / `color` are column names resolved against the frame at
/// `format_vega_lite` time (a missing name raises `ColumnNotFound`); each
/// column's dtype decides its Vega-Lite field `type` (numeric →
/// `quantitative`, otherwise → `nominal`), unless `color_type` overrides the
/// `color` channel — e.g. a numeric grouping column (a cluster id) rendered as
/// `Nominal` distinct colors rather than a continuous gradient.
pub struct ChartSpec {
  kind : ChartKind
  x : String
  y : String
  color : String?
  title : String?
  color_type : VegaType?
} derive(Eq, Debug)

///|
pub extend ChartSpec with Eq::{equal, not_equal}

///|
pub extend ChartSpec with Debug::{to_repr}

///|
/// A bar chart of `y` against `x` (Vega-Lite `mark: "bar"`).
///
/// `color` maps a column to the Vega-Lite `color` encoding (grouping /
/// colouring the marks by it); `color_type` overrides that channel's field
/// `type` instead of inferring it from the column dtype — use `Nominal` (or
/// `Ordinal`) to render a *numeric* grouping column, a cluster id or a year,
/// as distinct per-group colors rather than the continuous gradient
/// `quantitative` would produce (only `color` honours this; `x` / `y` keep
/// dtype inference). `title` carries the chart title. Omitting any of them
/// leaves it out of the rendered spec.
pub fn ChartSpec::bar(
  x : String,
  y : String,
  color? : String,
  color_type? : VegaType,
  title? : String,
) -> ChartSpec {
  { kind: Bar, x, y, color, title, color_type }
}

///|
/// A line chart of `y` against `x` (Vega-Lite `mark: "line"`).
///
/// `color` maps a column to the Vega-Lite `color` encoding (grouping /
/// colouring the marks by it); `color_type` overrides that channel's field
/// `type` instead of inferring it from the column dtype — use `Nominal` (or
/// `Ordinal`) to render a *numeric* grouping column, a cluster id or a year,
/// as distinct per-group colors rather than the continuous gradient
/// `quantitative` would produce (only `color` honours this; `x` / `y` keep
/// dtype inference). `title` carries the chart title. Omitting any of them
/// leaves it out of the rendered spec.
pub fn ChartSpec::line(
  x : String,
  y : String,
  color? : String,
  color_type? : VegaType,
  title? : String,
) -> ChartSpec {
  { kind: Line, x, y, color, title, color_type }
}

///|
/// A scatter (point) chart of `y` against `x` (Vega-Lite `mark: "point"`).
///
/// `color` maps a column to the Vega-Lite `color` encoding (grouping /
/// colouring the marks by it); `color_type` overrides that channel's field
/// `type` instead of inferring it from the column dtype — use `Nominal` (or
/// `Ordinal`) to render a *numeric* grouping column, a cluster id or a year,
/// as distinct per-group colors rather than the continuous gradient
/// `quantitative` would produce (only `color` honours this; `x` / `y` keep
/// dtype inference). `title` carries the chart title. Omitting any of them
/// leaves it out of the rendered spec.
pub fn ChartSpec::point(
  x : String,
  y : String,
  color? : String,
  color_type? : VegaType,
  title? : String,
) -> ChartSpec {
  { kind: Point, x, y, color, title, color_type }
}

///|
/// A area chart of `y` against `x` (Vega-Lite `mark: "area"`).
///
/// `color` maps a column to the Vega-Lite `color` encoding (grouping /
/// colouring the marks by it); `color_type` overrides that channel's field
/// `type` instead of inferring it from the column dtype — use `Nominal` (or
/// `Ordinal`) to render a *numeric* grouping column, a cluster id or a year,
/// as distinct per-group colors rather than the continuous gradient
/// `quantitative` would produce (only `color` honours this; `x` / `y` keep
/// dtype inference). `title` carries the chart title. Omitting any of them
/// leaves it out of the rendered spec.
pub fn ChartSpec::area(
  x : String,
  y : String,
  color? : String,
  color_type? : VegaType,
  title? : String,
) -> ChartSpec {
  { kind: Area, x, y, color, title, color_type }
}

///|
/// Render `df` and `spec` as a complete Vega-Lite v5 specification JSON
/// string: `$schema` (pinned to the Vega-Lite v5 schema URL) + optional
/// `title` + `mark` (from `spec.kind`) + `encoding` (`x` / `y` and, when
/// set, `color`, each `{field, type}` with the `type` inferred from the
/// column dtype: numeric → `"quantitative"`, otherwise → `"nominal"`) +
/// `data.values` (the frame inlined as JSON records, sharing
/// `format_json`' cell mapping — null and non-finite-float cells
/// become JSON `null`). A frame with the encoded columns but zero rows
/// yields `"data":{"values":[]}`.
///
/// The spec's `x` / `y` / `color` columns are resolved left-to-right; the
/// first name absent from `df` raises `ColumnNotFound(name)` — this is the
/// one reason the function is not **total** (it accepts column names, and a
/// name can be wrong). The emitted text is always valid JSON (it is built
/// through `@json` and stringified), so it round-trips through any
/// standards-compliant JSON / Vega-Lite reader.
pub fn format_vega_lite(
  df : @frame.DataFrame,
  spec : ChartSpec,
) -> String raise @types.DataError {
  // Resolve the referenced columns left-to-right — x, then y, then the
  // optional color — so a missing column raises `ColumnNotFound` in that
  // order. `get_column` doubles as the existence check and the dtype
  // source for Vega-Lite's field-`type` inference.
  let x_dtype = df.get_column(spec.x).dtype()
  let y_dtype = df.get_column(spec.y).dtype()
  let obj : Map[String, Json] = Map([])
  obj["$schema"] = Json::string(
    "https://vega.github.io/schema/vega-lite/v5.json",
  )
  if spec.title is Some(title) {
    obj["title"] = Json::string(title)
  }
  obj["mark"] = Json::string(chart_mark(spec.kind))
  let encoding : Map[String, Json] = Map([])
  encoding["x"] = encoding_channel(spec.x, x_dtype, None)
  encoding["y"] = encoding_channel(spec.y, y_dtype, None)
  if spec.color is Some(color) {
    encoding["color"] = encoding_channel(
      color,
      df.get_column(color).dtype(),
      spec.color_type,
    )
  }
  obj["encoding"] = Json::object(encoding)
  let data : Map[String, Json] = Map([])
  data["values"] = Json::array(df_to_json_records(df))
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
  write_text(path, content)
}

// ── internals ──────────────────────────────────────────────────────────

///|
/// Map a `ChartKind` to its Vega-Lite `mark` string.
fn chart_mark(kind : ChartKind) -> String {
  match kind {
    Bar => "bar"
    Line => "line"
    Point => "point"
    Area => "area"
  }
}

///|
/// Build one Vega-Lite encoding-channel object `{"field": <name>, "type":
/// <vega-type>}`. An explicit `type_override` wins; otherwise the field `type`
/// follows the column dtype: a numeric column (`Int` / `Float`) is
/// `"quantitative"`; everything else (`String` / `Bool`, and an all-null
/// `Null` column) is `"nominal"`.
fn encoding_channel(
  field : String,
  dtype : @types.DataType,
  type_override : VegaType?,
) -> Json {
  let channel : Map[String, Json] = Map([])
  channel["field"] = Json::string(escape_vega_field(field))
  let vtype = match type_override {
    Some(t) => vega_type_string(t)
    None => if dtype.is_numeric() { "quantitative" } else { "nominal" }
  }
  channel["type"] = Json::string(vtype)
  Json::object(channel)
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
  let buf = StringBuilder::new()
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
