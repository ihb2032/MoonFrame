// The parameter family: interactive bindings — a variable parameter
// bound to an input widget or an expression, and a selection parameter
// driven by direct manipulation (a click-set point, a drag-drawn
// interval) — plus the conditional encoding that reacts to one. A
// chart's `params` array declares them; encodings reference them by
// name. Transcribed from the vendored vega_lite_v6_5_0.schema.json and
// schema-walked through the corpus guard; reached through `@chart`
// qualification as part of the deep mirror family.
//
// The static arms of the schema's unions are mirrored here. The Vega
// event-stream grammar stays a `String` (its named events — "click",
// "dblclick", "[touchdown, touchup]" — cover the common triggers); the
// per-property expression arms (an `ExprRef` in place of a number) are
// the reactive-binding surface the schema attaches to nearly every
// value, and the mirror takes plain values there.

///|
/// An input widget a parameter binds to: a checkbox, a radio / select
/// menu, a range slider, a free-text input, or a direct element binding
/// (an existing DOM element's events). `pub(all)` so callers build the
/// variants; the options-carrying ones take copies at the builders.
#derive(Eq, Debug)
pub(all) enum VegaBind {
  Checkbox(VegaBindCheckbox)
  RadioSelect(VegaBindRadioSelect)
  Range(VegaBindRange)
  Input(VegaBindInput)
  Direct(VegaBindDirect)
}

///|
pub extend VegaBind with Eq::{equal, not_equal}

///|
pub extend VegaBind with Debug::{to_repr}

///|
/// A checkbox binding for a boolean parameter.
#derive(Eq, Debug)
pub struct VegaBindCheckbox {
  debounce : Double?
  element : String?
  name : String?
}

///|
pub extend VegaBindCheckbox with Eq::{equal, not_equal}

///|
pub extend VegaBindCheckbox with Debug::{to_repr}

///|
/// Build a checkbox binding; every property optional.
pub fn VegaBindCheckbox::VegaBindCheckbox(
  debounce? : Double,
  element? : String,
  name? : String,
) -> VegaBindCheckbox {
  { debounce, element, name, }
}

///|
/// A radio-button / dropdown binding: the options to choose among, and
/// optional display labels for them.
#derive(Eq, Debug)
pub struct VegaBindRadioSelect {
  debounce : Double?
  element : String?
  name : String?
  priv labels : Array[String]?
  priv options : Array[Json]
}

///|
pub extend VegaBindRadioSelect with Eq::{equal, not_equal}

///|
pub extend VegaBindRadioSelect with Debug::{to_repr}

///|
/// Build a radio / select binding from the caller's options (copied)
/// and optional labels (copied); the rest optional.
pub fn VegaBindRadioSelect::VegaBindRadioSelect(
  options : Array[Json],
  labels? : Array[String],
  debounce? : Double,
  element? : String,
  name? : String,
) -> VegaBindRadioSelect {
  {
    debounce,
    element,
    name,
    labels: match labels {
      Some(l) => Some(l.copy())
      None => None
    },
    options: options.copy(),
  }
}

///|
/// The option list, copied — reading the field itself would hand the
/// caller the array the binding holds.
pub fn VegaBindRadioSelect::options(self : VegaBindRadioSelect) -> Array[Json] {
  self.options.copy()
}

///|
/// The option labels, copied for the same reason.
pub fn VegaBindRadioSelect::labels(
  self : VegaBindRadioSelect,
) -> Array[String]? {
  match self.labels {
    Some(l) => Some(l.copy())
    None => None
  }
}

///|
/// A range-slider binding with its bounds and step.
#derive(Eq, Debug)
pub struct VegaBindRange {
  debounce : Double?
  element : String?
  name : String?
  max : Double?
  min : Double?
  step : Double?
}

///|
pub extend VegaBindRange with Eq::{equal, not_equal}

///|
pub extend VegaBindRange with Debug::{to_repr}

///|
/// Build a range binding; every property optional (the schema requires
/// only the input kind, which the variant carries).
pub fn VegaBindRange::VegaBindRange(
  debounce? : Double,
  element? : String,
  name? : String,
  max? : Double,
  min? : Double,
  step? : Double,
) -> VegaBindRange {
  { debounce, element, name, max, min, step, }
}

///|
/// A free-text input binding, with an autocomplete hint and a
/// placeholder.
#derive(Eq, Debug)
pub struct VegaBindInput {
  debounce : Double?
  element : String?
  name : String?
  autocomplete : String?
  placeholder : String?
}

///|
pub extend VegaBindInput with Eq::{equal, not_equal}

///|
pub extend VegaBindInput with Debug::{to_repr}

///|
/// Build a text-input binding; every property optional.
pub fn VegaBindInput::VegaBindInput(
  debounce? : Double,
  element? : String,
  name? : String,
  autocomplete? : String,
  placeholder? : String,
) -> VegaBindInput {
  { debounce, element, name, autocomplete, placeholder, }
}

///|
/// A direct binding to an existing element's events (no widget is
/// created; the element is addressed by selector).
#derive(Eq, Debug)
pub struct VegaBindDirect {
  debounce : Double?
  element : String
  event : String?
}

///|
pub extend VegaBindDirect with Eq::{equal, not_equal}

///|
pub extend VegaBindDirect with Debug::{to_repr}

///|
/// Bind directly to the element matched by the selector; the event name
/// and a debounce are optional.
pub fn VegaBindDirect::VegaBindDirect(
  element~ : String,
  debounce? : Double,
  event? : String,
) -> VegaBindDirect {
  { debounce, element, event, }
}

///|
/// How a selection composed across facets resolves: `Global` (one
/// selection across all views, the default), `Union` (per-view, unioned
/// on read), `Intersect` (per-view, intersected).
#derive(Eq, Debug)
pub(all) enum VegaSelectionResolution {
  Global
  Union
  Intersect
}

///|
pub extend VegaSelectionResolution with Eq::{equal, not_equal}

///|
pub extend VegaSelectionResolution with Debug::{to_repr}

///|
/// The schema string for each variant.
fn vega_selection_resolution_string(v : VegaSelectionResolution) -> String {
  match v {
    Global => "global"
    Union => "union"
    Intersect => "intersect"
  }
}

///|
/// A point selection: discrete values picked by click (shift-click
/// toggling), projected onto the given fields or encoding channels.
#derive(Eq, Debug)
pub struct VegaPointSelect {
  on : String?
  clear : String?
  priv fields : Array[String]?
  priv encodings : Array[String]?
  nearest : Bool?
  toggle : Bool?
  resolve : VegaSelectionResolution?
}

///|
pub extend VegaPointSelect with Eq::{equal, not_equal}

///|
pub extend VegaPointSelect with Debug::{to_repr}

///|
/// Build a point selection; the event names are Vega event-stream
/// strings, every property optional. The array properties are copied.
pub fn VegaPointSelect::VegaPointSelect(
  on? : String,
  clear? : String,
  fields? : Array[String],
  encodings? : Array[String],
  nearest? : Bool,
  toggle? : Bool,
  resolve? : VegaSelectionResolution,
) -> VegaPointSelect {
  {
    on,
    clear,
    fields: match fields {
      Some(f) => Some(f.copy())
      None => None
    },
    encodings: match encodings {
      Some(e) => Some(e.copy())
      None => None
    },
    nearest,
    toggle,
    resolve,
  }
}

///|
/// The projected fields, copied.
pub fn VegaPointSelect::fields(self : VegaPointSelect) -> Array[String]? {
  match self.fields {
    Some(f) => Some(f.copy())
    None => None
  }
}

///|
/// The projected encoding channels, copied.
pub fn VegaPointSelect::encodings(self : VegaPointSelect) -> Array[String]? {
  match self.encodings {
    Some(e) => Some(e.copy())
    None => None
  }
}

///|
/// The brush mark of an interval selection: its fill and stroke
/// styling.
#derive(Eq, Debug)
pub struct VegaBrush {
  fill : String?
  fill_opacity : Double?
  stroke : String?
  stroke_opacity : Double?
  stroke_width : Double?
  priv stroke_dash : Array[Double]?
  stroke_dash_offset : Double?
  cursor : String?
}

///|
pub extend VegaBrush with Eq::{equal, not_equal}

///|
pub extend VegaBrush with Debug::{to_repr}

///|
/// Build a brush styling; every property optional, the dash list
/// copied.
pub fn VegaBrush::VegaBrush(
  fill? : String,
  fill_opacity? : Double,
  stroke? : String,
  stroke_opacity? : Double,
  stroke_width? : Double,
  stroke_dash? : Array[Double],
  stroke_dash_offset? : Double,
  cursor? : String,
) -> VegaBrush {
  {
    fill,
    fill_opacity,
    stroke,
    stroke_opacity,
    stroke_width,
    stroke_dash: match stroke_dash {
      Some(d) => Some(d.copy())
      None => None
    },
    stroke_dash_offset,
    cursor,
  }
}

///|
/// The brush dash list, copied.
pub fn VegaBrush::stroke_dash(self : VegaBrush) -> Array[Double]? {
  match self.stroke_dash {
    Some(d) => Some(d.copy())
    None => None
  }
}

///|
/// An interval selection: a continuous range drawn by drag, with
/// panning and zooming, and the brush it draws styled.
#derive(Eq, Debug)
pub struct VegaIntervalSelect {
  on : String?
  clear : String?
  translate : String?
  zoom : String?
  mark : VegaBrush?
  priv fields : Array[String]?
  priv encodings : Array[String]?
  resolve : VegaSelectionResolution?
}

///|
pub extend VegaIntervalSelect with Eq::{equal, not_equal}

///|
pub extend VegaIntervalSelect with Debug::{to_repr}

///|
/// Build an interval selection; the event names are Vega event-stream
/// strings, every property optional. The array properties are copied.
pub fn VegaIntervalSelect::VegaIntervalSelect(
  on? : String,
  clear? : String,
  translate? : String,
  zoom? : String,
  mark? : VegaBrush,
  fields? : Array[String],
  encodings? : Array[String],
  resolve? : VegaSelectionResolution,
) -> VegaIntervalSelect {
  {
    on,
    clear,
    translate,
    zoom,
    mark,
    fields: match fields {
      Some(f) => Some(f.copy())
      None => None
    },
    encodings: match encodings {
      Some(e) => Some(e.copy())
      None => None
    },
    resolve,
  }
}

///|
/// The projected fields, copied.
pub fn VegaIntervalSelect::fields(self : VegaIntervalSelect) -> Array[String]? {
  match self.fields {
    Some(f) => Some(f.copy())
    None => None
  }
}

///|
/// The projected encoding channels, copied.
pub fn VegaIntervalSelect::encodings(
  self : VegaIntervalSelect,
) -> Array[String]? {
  match self.encodings {
    Some(e) => Some(e.copy())
    None => None
  }
}

///|
/// A selection's interactive trigger: a point or an interval.
#derive(Eq, Debug)
pub(all) enum VegaSelect {
  Point(VegaPointSelect)
  Interval(VegaIntervalSelect)
}

///|
pub extend VegaSelect with Eq::{equal, not_equal}

///|
pub extend VegaSelect with Debug::{to_repr}

///|
/// A parameter a chart declares: a variable (a value, bound to a widget
/// or driven by an expression) or a selection (direct manipulation).
/// `pub(all)` so callers build the two variants through the named
/// builders below.
#derive(Eq, Debug)
pub(all) enum VegaParam {
  Variable(VegaVariableParam)
  Selection(VegaSelectionParam)
}

///|
pub extend VegaParam with Eq::{equal, not_equal}

///|
pub extend VegaParam with Debug::{to_repr}

///|
/// A variable parameter: a named value a chart's expressions reference,
/// optionally bound to an input widget, initialised, or computed by an
/// expression over other parameters. `react` (whether updates propagate
/// downstream) defaults to true in the schema; `None` leaves it there.
#derive(Eq, Debug)
pub struct VegaVariableParam {
  name : String
  value : Json?
  bind : VegaBind?
  expr : String?
  react : Bool?
}

///|
pub extend VegaVariableParam with Eq::{equal, not_equal}

///|
pub extend VegaVariableParam with Debug::{to_repr}

///|
/// Build a variable parameter: the name every expression references,
/// and any of the initial value, the input binding, and the driving
/// expression.
pub fn VegaVariableParam::VegaVariableParam(
  name~ : String,
  value? : Json,
  bind? : VegaBind,
  expr? : String,
  react? : Bool,
) -> VegaVariableParam {
  { name, value, bind, expr, react, }
}

///|
/// A selection parameter: a named direct-manipulation selection — the
/// click-drawn points or the drag-drawn interval — optionally bound to
/// a widget (legend-style interval binding) and initialised.
#derive(Eq, Debug)
pub struct VegaSelectionParam {
  name : String
  select : VegaSelect
  bind : VegaBind?
  priv value : Array[Json]?
  priv views : Array[String]?
}

///|
pub extend VegaSelectionParam with Eq::{equal, not_equal}

///|
pub extend VegaSelectionParam with Debug::{to_repr}

///|
/// Build a selection parameter: the name, the trigger, and any binding,
/// initial value (per projected field), or facet views it spans. The
/// array properties are copied.
pub fn VegaSelectionParam::VegaSelectionParam(
  name~ : String,
  select~ : VegaSelect,
  bind? : VegaBind,
  value? : Array[Json],
  views? : Array[String],
) -> VegaSelectionParam {
  {
    name,
    select,
    bind,
    value: match value {
      Some(v) => Some(v.copy())
      None => None
    },
    views: match views {
      Some(v) => Some(v.copy())
      None => None
    },
  }
}

///|
/// The initial selection, copied.
pub fn VegaSelectionParam::value(self : VegaSelectionParam) -> Array[Json]? {
  match self.value {
    Some(v) => Some(v.copy())
    None => None
  }
}

///|
/// The facet views the selection spans, copied.
pub fn VegaSelectionParam::views(self : VegaSelectionParam) -> Array[String]? {
  match self.views {
    Some(v) => Some(v.copy())
    None => None
  }
}

///|
/// A conditional encoding arm: when the predicate holds, the channel
/// shows the constant value — the highlight-on-hover shape, a base
/// color with a brighter one for the hovered subset. The schema's
/// condition for a mark-property channel carries exactly `test` (the
/// predicate) and `value` (the constant); the base definition on the
/// channel itself is the else. `pub(all)` so callers build the one
/// variant.
#derive(Eq, Debug)
pub(all) enum VegaCondition {
  When(VegaPredicate, Json)
}

///|
pub extend VegaCondition with Eq::{equal, not_equal}

///|
pub extend VegaCondition with Debug::{to_repr}

// ── emitters ──────────────────────────────────────────────────────────

///|
/// The JSON of a bind widget.
fn vega_bind_emit_json(b : VegaBind) -> Json {
  let obj : Map[String, Json] = Map([])
  match b {
    Checkbox(c) => {
      obj["input"] = Json::string("checkbox")
      put_bind_common(obj, c.debounce, c.element, c.name)
      Json::object(obj)
    }
    RadioSelect(r) => {
      obj["input"] = Json::string("radio")
      obj["options"] = Json::array(r.options.copy())
      if r.labels is Some(labels) {
        obj["labels"] = Json::array(labels.map(fn(l) { Json::string(l) }))
      }
      put_bind_common(obj, r.debounce, r.element, r.name)
      Json::object(obj)
    }
    Range(r) => {
      obj["input"] = Json::string("range")
      if r.max is Some(max) {
        obj["max"] = Json::number(max)
      }
      if r.min is Some(min) {
        obj["min"] = Json::number(min)
      }
      if r.step is Some(step) {
        obj["step"] = Json::number(step)
      }
      put_bind_common(obj, r.debounce, r.element, r.name)
      Json::object(obj)
    }
    Input(i) => {
      obj["input"] = Json::string("text")
      if i.autocomplete is Some(autocomplete) {
        obj["autocomplete"] = Json::string(autocomplete)
      }
      if i.placeholder is Some(placeholder) {
        obj["placeholder"] = Json::string(placeholder)
      }
      put_bind_common(obj, i.debounce, i.element, i.name)
      Json::object(obj)
    }
    Direct(dir) => {
      obj["element"] = Json::string(dir.element)
      if dir.debounce is Some(debounce) {
        obj["debounce"] = Json::number(debounce)
      }
      if dir.event is Some(event) {
        obj["event"] = Json::string(event)
      }
      Json::object(obj)
    }
  }
}

///|
/// The three keys every widget binding shares.
fn put_bind_common(
  obj : Map[String, Json],
  debounce : Double?,
  element : String?,
  name : String?,
) -> Unit {
  if debounce is Some(d) {
    obj["debounce"] = Json::number(d)
  }
  if element is Some(e) {
    obj["element"] = Json::string(e)
  }
  if name is Some(n) {
    obj["name"] = Json::string(n)
  }
}

///|
/// The JSON of a selection trigger.
fn vega_select_emit_json(s : VegaSelect) -> Json {
  match s {
    Point(p) => {
      let obj : Map[String, Json] = Map([])
      obj["type"] = Json::string("point")
      put_select_common(obj, p.on, p.clear, p.fields, p.encodings, p.resolve)
      if p.nearest is Some(nearest) {
        obj["nearest"] = Json::boolean(nearest)
      }
      if p.toggle is Some(toggle) {
        obj["toggle"] = Json::boolean(toggle)
      }
      Json::object(obj)
    }
    Interval(i) => {
      let obj : Map[String, Json] = Map([])
      obj["type"] = Json::string("interval")
      put_select_common(obj, i.on, i.clear, i.fields, i.encodings, i.resolve)
      if i.translate is Some(translate) {
        obj["translate"] = Json::string(translate)
      }
      if i.zoom is Some(zoom) {
        obj["zoom"] = Json::string(zoom)
      }
      if i.mark is Some(mark) {
        obj["mark"] = vega_brush_emit_json(mark)
      }
      Json::object(obj)
    }
  }
}

///|
/// The keys both trigger kinds share.
fn put_select_common(
  obj : Map[String, Json],
  on : String?,
  clear : String?,
  fields : Array[String]?,
  encodings : Array[String]?,
  resolve : VegaSelectionResolution?,
) -> Unit {
  if on is Some(o) {
    obj["on"] = Json::string(o)
  }
  if clear is Some(c) {
    obj["clear"] = Json::string(c)
  }
  if fields is Some(f) {
    obj["fields"] = Json::array(f.map(fn(x) { Json::string(x) }))
  }
  if encodings is Some(e) {
    obj["encodings"] = Json::array(e.map(fn(x) { Json::string(x) }))
  }
  if resolve is Some(r) {
    obj["resolve"] = Json::string(vega_selection_resolution_string(r))
  }
}

///|
/// The JSON of a brush styling.
fn vega_brush_emit_json(b : VegaBrush) -> Json {
  let obj : Map[String, Json] = Map([])
  if b.fill is Some(fill) {
    obj["fill"] = Json::string(fill)
  }
  if b.fill_opacity is Some(v) {
    obj["fillOpacity"] = Json::number(v)
  }
  if b.stroke is Some(stroke) {
    obj["stroke"] = Json::string(stroke)
  }
  if b.stroke_opacity is Some(v) {
    obj["strokeOpacity"] = Json::number(v)
  }
  if b.stroke_width is Some(v) {
    obj["strokeWidth"] = Json::number(v)
  }
  if b.stroke_dash is Some(dash) {
    obj["strokeDash"] = Json::array(dash.map(fn(n) { Json::number(n) }))
  }
  if b.stroke_dash_offset is Some(v) {
    obj["strokeDashOffset"] = Json::number(v)
  }
  if b.cursor is Some(cursor) {
    obj["cursor"] = Json::string(cursor)
  }
  Json::object(obj)
}

///|
/// The JSON of a parameter declaration.
fn vega_param_emit_json(p : VegaParam) -> Json {
  let obj : Map[String, Json] = Map([])
  match p {
    Variable(v) => {
      obj["name"] = Json::string(v.name)
      if v.value is Some(value) {
        obj["value"] = value
      }
      if v.bind is Some(bind) {
        obj["bind"] = vega_bind_emit_json(bind)
      }
      if v.expr is Some(expr) {
        obj["expr"] = Json::string(expr)
      }
      if v.react is Some(react) {
        obj["react"] = Json::boolean(react)
      }
      Json::object(obj)
    }
    Selection(s) => {
      obj["name"] = Json::string(s.name)
      obj["select"] = vega_select_emit_json(s.select)
      if s.bind is Some(bind) {
        obj["bind"] = vega_bind_emit_json(bind)
      }
      if s.value is Some(value) {
        obj["value"] = Json::array(value.copy())
      }
      if s.views is Some(views) {
        obj["views"] = Json::array(views.map(fn(v) { Json::string(v) }))
      }
      Json::object(obj)
    }
  }
}

///|
/// A parameter list as the schema's `params` array.
fn vega_params_emit_json(params : Array[VegaParam]) -> Json {
  Json::array(params.map(fn(p) { vega_param_emit_json(p) }))
}

///|
/// The JSON of a conditional encoding: the predicate and, merged in,
/// the definition it selects. The emitter runs in `encoding_channel`,
/// which resolves the arm's dtype from the outer channel (the condition
/// usually re-references the same field) and holds the recursion at one
/// level — a condition inside a condition is not a shape the schema
/// reaches.
fn vega_condition_emit_json(c : VegaCondition) -> Json {
  match c {
    When(predicate, value) => {
      let props : Map[String, Json] = Map([])
      props["test"] = vega_predicate_emit_json(predicate)
      props["value"] = value
      Json::object(props)
    }
  }
}
