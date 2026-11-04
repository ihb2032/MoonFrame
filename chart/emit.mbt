// The emitter half of the export: the functions that turn a `ChartSpec`
// into Vega-Lite JSON. Every key spelled here is a key the vendored
// `.github/fixtures/vega_lite_v6_5_0.schema.json` knows, and the corpus
// guard walks the emitted specs against that schema — a misspelled key or
// an enum string the schema never listed fails the build, which is the
// machine-checked half of a hand-written mirror's fidelity.

///|
/// The dtype backing a channel's type inference: a field channel's column
/// dtype (`get_column` doubles as the existence check — the one reason
/// `format_vega_lite` raises), `None` for a channel with no column to
/// read — a `Count` aggregate (it tallies rows per group) or a
/// constant / datum definition.
fn channel_dtype(
  df : @frame.DataFrame,
  channel : VegaChannel,
) -> @types.DataType? raise @types.DataError {
  if channel.aggregate is Some(Count) || channel.field is None {
    None
  } else {
    Some(df.get_column(channel.field.unwrap()).dtype())
  }
}

///|
/// Build one Vega-Lite encoding-channel object. A constant channel emits
/// only its `value` (the schema's value definition carries no `type`; the
/// `constant` builder sets nothing else). A datum channel emits its
/// `datum`. A field channel emits `{"field": <name>, "type": <vega-type>}`
/// plus its declared modifiers — `aggregate`, `bin`, `timeUnit`, `sort`,
/// `stack`, `bandPosition`, `title`, `format` — each present only when
/// set; a `Count` aggregate emits no `field` key (its aggregate tallies
/// rows per group) and its ignored `field` never reaches the spec. The
/// `type` follows the dtype→type rule — a numeric column (`Int` / `Float`
/// / `Decimal`) is `"quantitative"`, a `Date` / `Timestamp` column is
/// `"temporal"` (its ISO cells sort chronologically, and a temporal axis
/// orders by time rather than by first appearance), every other dtype is
/// `"nominal"` — unless the channel carries an explicit `type_override`;
/// a channel with no column to read (count, and anything the builders
/// cannot build) is `"quantitative"` — a row count is a quantity by
/// definition.
fn encoding_channel(
  key : String,
  channel : VegaChannel,
  dtype : @types.DataType?,
) -> Json {
  let ch : Map[String, Json] = Map([])
  if channel.value is Some(value) {
    // The value definition: the constant itself, nothing else — the
    // `constant` builder sets no modifiers, and the schema's ValueDef
    // carries no `type`.
    ch["value"] = value
    return Json::object(ch)
  }
  if channel.datum is Some(datum) {
    // The datum definition: a constant that passes through the channel's
    // scale rather than being shown verbatim.
    ch["datum"] = datum
    return Json::object(ch)
  }
  if channel.field is Some(field) && !(channel.aggregate is Some(Count)) {
    ch["field"] = Json::string(escape_vega_field(field))
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
  if channel.sort is Some(sort) && !is_secondary_key(key) {
    ch["sort"] = sort_json(sort)
  }
  if channel.stack is Some(stack) && allows_stack_key(key) {
    ch["stack"] = stack_json(stack)
  }
  if channel.band_position is Some(band) {
    ch["bandPosition"] = Json::number(band)
  }
  if channel.title is Some(title) {
    ch["title"] = Json::string(title)
  }
  if channel.format is Some(format) && allows_format_key(key) {
    ch["format"] = Json::string(format)
  }
  if !is_secondary_key(key) {
    ch["type"] = Json::string(channel_type_string(channel, dtype))
  }
  Json::object(ch)
}

///|
/// The secondary channels — the `2` / error forms that share their
/// primary's scale (`x2`, `y2`, `theta2`, `radius2`, the four error
/// channels, the far geo corners). The schema's field definition for one
/// carries no `type` (the primary's scale decides it), no `sort`, no
/// `format`, no `stack`; a modifier set on a secondary channel through a
/// struct the builders cannot build is dropped here rather than emitted
/// into a spec the schema would reject.
fn is_secondary_key(key : String) -> Bool {
  key == "x2" ||
  key == "y2" ||
  key == "theta2" ||
  key == "radius2" ||
  key == "xError" ||
  key == "xError2" ||
  key == "yError" ||
  key == "yError2" ||
  key == "longitude2" ||
  key == "latitude2"
}

///|
/// The channels whose field definition may carry a `format` — the
/// string-bearing family (`text`, `tooltip`, `href`, `url`); a position
/// or color channel formats its axis or legend instead, so the schema
/// carries no `format` on their definitions.
fn allows_format_key(key : String) -> Bool {
  key == "text" || key == "tooltip" || key == "href" || key == "url"
}

///|
/// The channels a `stack` belongs to — the stackable positions (`x`,
/// `y`) and the polar angles / radii (`theta`, `radius`).
fn allows_stack_key(key : String) -> Bool {
  key == "x" || key == "y" || key == "theta" || key == "radius"
}

///|
/// The field `type` of a channel: an explicit `type_override` wins;
/// otherwise the dtype→type rule over the channel's column, or
/// `"quantitative"` when there is no column to read.
fn channel_type_string(
  channel : VegaChannel,
  dtype : @types.DataType?,
) -> String {
  if channel.type_override is Some(t) {
    vega_type_string(t)
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
    "quantitative"
  }
}

///|
/// The schema's `Type` string for a `VegaType` variant.
fn vega_type_string(t : VegaType) -> String {
  match t {
    Quantitative => "quantitative"
    Nominal => "nominal"
    Ordinal => "ordinal"
    Temporal => "temporal"
    Geojson => "geojson"
  }
}

///|
/// The JSON of a channel `bin`: `On` is `true` (the runtime picks the
/// bins), `Binned` is the `"binned"` marker, and `Params` is the parameter
/// object with every set field of the `VegaBinParams` (the `divide` /
/// `steps` arrays and the `extent` min / max pair included).
fn bin_json(bin : VegaBin) -> Json {
  match bin {
    On => Json::boolean(true)
    Binned => Json::string("binned")
    Params(params) => {
      let obj : Map[String, Json] = Map([])
      if params.maxbins is Some(maxbins) {
        obj["maxbins"] = Json::number(maxbins.to_double())
      }
      if params.anchor is Some(anchor) {
        obj["anchor"] = Json::number(anchor)
      }
      if params.base is Some(base) {
        obj["base"] = Json::number(base)
      }
      if params.nice is Some(nice) {
        obj["nice"] = Json::boolean(nice)
      }
      if params.step is Some(step) {
        obj["step"] = Json::number(step)
      }
      if params.minstep is Some(minstep) {
        obj["minstep"] = Json::number(minstep)
      }
      if params.binned is Some(binned) {
        obj["binned"] = Json::boolean(binned)
      }
      if params.extent is Some(extent) {
        let (lo, hi) = extent
        obj["extent"] = Json::array([Json::number(lo), Json::number(hi)])
      }
      if params.divide is Some(divide) {
        obj["divide"] = Json::array(divide.map(fn(d) { Json::number(d) }))
      }
      if params.steps is Some(steps) {
        obj["steps"] = Json::array(steps.map(fn(s) { Json::number(s) }))
      }
      Json::object(obj)
    }
  }
}

///|
/// The JSON of a channel `sort`: the bare orders as strings, a by-channel
/// sort as the channel's name (prefixed `-` for the descending form), a
/// by-field sort as `{"field", "order"?}`, an explicit list as the array
/// itself (in that order), and `Off` as `null`.
fn sort_json(sort : VegaChannelSort) -> Json {
  match sort {
    Ascending => Json::string("ascending")
    Descending => Json::string("descending")
    ByChannel(channel, descending) => {
      let name = sort_channel_string(channel)
      match descending {
        Some(true) => Json::string("-" + name)
        _ => Json::string(name)
      }
    }
    ByField(field_name, order) => {
      let obj : Map[String, Json] = Map([])
      obj["field"] = Json::string(field_name)
      if order is Some(o) {
        obj["order"] = Json::string(
          if o is Ascending {
            "ascending"
          } else {
            "descending"
          },
        )
      }
      Json::object(obj)
    }
    Values(order) => Json::array(order.copy())
    Off => Json::null()
  }
}

///|
/// The schema's `SortByChannel` string for a `VegaSortChannel` variant —
/// the camelCase channel names verbatim (`"fillOpacity"`, `"strokeWidth"`).
fn sort_channel_string(channel : VegaSortChannel) -> String {
  match channel {
    X => "x"
    Y => "y"
    Color => "color"
    Fill => "fill"
    Stroke => "stroke"
    StrokeWidth => "strokeWidth"
    Size => "size"
    Shape => "shape"
    FillOpacity => "fillOpacity"
    StrokeOpacity => "strokeOpacity"
    Opacity => "opacity"
    Text => "text"
  }
}

///|
/// The JSON of a position channel's `stack`: the three stack offsets as
/// strings and `Off` as `null`.
fn stack_json(stack : VegaStack) -> Json {
  match stack {
    Zero => Json::string("zero")
    Center => Json::string("center")
    Normalize => Json::string("normalize")
    Off => Json::null()
  }
}

///|
/// The JSON of a top-level `width` / `height`: a pixel count as a number,
/// `"container"` as the responsive string, and a step size as
/// `{"step": n}`.
fn extent_json(extent : VegaExtent) -> Json {
  match extent {
    Px(px) => Json::number(px.to_double())
    Container => Json::string("container")
    Step(step) => {
      let obj : Map[String, Json] = Map([])
      obj["step"] = Json::number(step.to_double())
      Json::object(obj)
    }
  }
}

///|
/// The JSON of a top-level `autosize` string.
fn autosize_json(autosize : VegaAutoSize) -> Json {
  Json::string(
    match autosize {
      Pad => "pad"
      Fit => "fit"
      FitX => "fit-x"
      FitY => "fit-y"
      None => "none"
    },
  )
}

///|
/// The JSON of a top-level `padding`: one number on all sides, or the
/// per-side object with the sides that are set.
fn padding_json(padding : VegaPadding) -> Json {
  match padding {
    Px(px) => Json::number(px.to_double())
    Sides(sides) => {
      let obj : Map[String, Json] = Map([])
      if sides.top is Some(top) {
        obj["top"] = Json::number(top.to_double())
      }
      if sides.right is Some(right) {
        obj["right"] = Json::number(right.to_double())
      }
      if sides.bottom is Some(bottom) {
        obj["bottom"] = Json::number(bottom.to_double())
      }
      if sides.left is Some(left) {
        obj["left"] = Json::number(left.to_double())
      }
      Json::object(obj)
    }
  }
}

///|
/// Add one channel to the encoding object when the spec carries it,
/// resolving its column against `df` (a missing column raises
/// `ColumnNotFound(name)` — `channel_dtype` is where the name is checked).
fn put_channel(
  encoding : Map[String, Json],
  key : String,
  df : @frame.DataFrame,
  channel : VegaChannel?,
) -> Unit raise @types.DataError {
  if channel is Some(ch) {
    encoding[key] = encoding_channel(key, ch, channel_dtype(df, ch))
  }
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
