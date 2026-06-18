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
// parallel to `format_json_records`, and it shares that file's
// `scalar_to_json` cell mapping through the common `df_to_json_records`
// helper — so a `data.values` cell follows exactly the same conventions
// as a JSON-records cell (nulls and non-finite floats become JSON `null`).
//
// Unlike `format_json_records` (which is **total**), `format_vega_lite`
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
/// A Vega-Lite field `type`, used to override the dtype-based inference for the
/// `color` channel. `pub(all)` so callers can name the variants when calling
/// `with_color_type`. `Quantitative` is a continuous measure (a color
/// gradient), `Nominal` an unordered category (distinct colors per value),
/// `Ordinal` an ordered category, and `Temporal` a time field.
pub(all) enum VegaType {
  Quantitative
  Nominal
  Ordinal
  Temporal
} derive(Eq, Debug)

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
/// private outside the package — build a spec through one of the
/// mark-named constructors (`ChartSpec::bar(x, y)` / `line` / `point` /
/// `area`) and chain `with_color(column)` / `with_title(text)`:
///
///   `ChartSpec::bar("region", "revenue").with_title("Revenue by region")`
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
/// A bar chart of `y` against `x` (Vega-Lite `mark: "bar"`).
pub fn ChartSpec::bar(x : String, y : String) -> ChartSpec {
  { kind: Bar, x, y, color: None, title: None, color_type: None }
}

///|
/// A line chart of `y` against `x` (Vega-Lite `mark: "line"`).
pub fn ChartSpec::line(x : String, y : String) -> ChartSpec {
  { kind: Line, x, y, color: None, title: None, color_type: None }
}

///|
/// A scatter (point) chart of `y` against `x` (Vega-Lite `mark: "point"`).
pub fn ChartSpec::point(x : String, y : String) -> ChartSpec {
  { kind: Point, x, y, color: None, title: None, color_type: None }
}

///|
/// An area chart of `y` against `x` (Vega-Lite `mark: "area"`).
pub fn ChartSpec::area(x : String, y : String) -> ChartSpec {
  { kind: Area, x, y, color: None, title: None, color_type: None }
}

///|
/// Return a copy of this spec that maps `column` to the Vega-Lite `color`
/// encoding (grouping / colouring the marks by that column). Chainable.
pub fn ChartSpec::with_color(self : ChartSpec, column : String) -> ChartSpec {
  {
    kind: self.kind,
    x: self.x,
    y: self.y,
    color: Some(column),
    title: self.title,
    color_type: self.color_type,
  }
}

///|
/// Return a copy of this spec that overrides the `color` channel's Vega-Lite
/// field `type`, instead of inferring it from the column dtype. Use `Nominal`
/// (or `Ordinal`) to render a *numeric* grouping column — a cluster id, a year
/// — as distinct per-group colors rather than the continuous gradient that
/// `quantitative` (the numeric default) would produce. Only the `color`
/// channel honours this; `x` / `y` keep dtype inference. Chainable.
pub fn ChartSpec::with_color_type(
  self : ChartSpec,
  color_type : VegaType,
) -> ChartSpec {
  {
    kind: self.kind,
    x: self.x,
    y: self.y,
    color: self.color,
    title: self.title,
    color_type: Some(color_type),
  }
}

///|
/// Return a copy of this spec carrying the chart `title`. Chainable.
pub fn ChartSpec::with_title(self : ChartSpec, title : String) -> ChartSpec {
  {
    kind: self.kind,
    x: self.x,
    y: self.y,
    color: self.color,
    title: Some(title),
    color_type: self.color_type,
  }
}

///|
/// Render `df` and `spec` as a complete Vega-Lite v5 specification JSON
/// string: `$schema` (pinned to the Vega-Lite v5 schema URL) + optional
/// `title` + `mark` (from `spec.kind`) + `encoding` (`x` / `y` and, when
/// set, `color`, each `{field, type}` with the `type` inferred from the
/// column dtype: numeric → `"quantitative"`, otherwise → `"nominal"`) +
/// `data.values` (the frame inlined as JSON records, sharing
/// `format_json_records`' cell mapping — null and non-finite-float cells
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
  let obj : Map[String, Json] = {}
  obj["$schema"] = Json::string(
    "https://vega.github.io/schema/vega-lite/v5.json",
  )
  if spec.title is Some(title) {
    obj["title"] = Json::string(title)
  }
  obj["mark"] = Json::string(chart_mark(spec.kind))
  let encoding : Map[String, Json] = {}
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
  let data : Map[String, Json] = {}
  data["values"] = Json::array(df_to_json_records(df))
  obj["data"] = Json::object(data)
  Json::object(obj).stringify()
}

///|
/// Write a Vega-Lite v5 spec for `df` / `spec` to `path`. Mirrors
/// `write_json_records`: a `ColumnNotFound` from `format_vega_lite` (a spec
/// column absent from `df`) propagates unchanged, and a filesystem failure
/// surfaces as `raise IoError(message)`.
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
  let channel : Map[String, Json] = {}
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
/// to a missing nested path and silently plot nothing. Prefixing `\`, `.`,
/// `[`, and `]` with a backslash makes the name a literal field access (the
/// JSON stringifier then escapes the backslash itself). A single forward pass,
/// total.
fn escape_vega_field(name : String) -> String {
  let buf = StringBuilder::new()
  for ch in name.iter() {
    if ch == '\\' || ch == '.' || ch == '[' || ch == ']' {
      buf.write_char('\\')
      buf.write_char(ch)
    } else {
      buf.write_char(ch)
    }
  }
  buf.to_string()
}
