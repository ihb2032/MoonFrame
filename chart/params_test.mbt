// Blackbox tests for the parameter family: the widget bindings, the two
// selection triggers with their shared and specific keys, the parameter
// declarations, the conditional encoding, and the array-ownership
// contracts. The corpus beside this walks parameter-bearing charts
// against the vendored schema.

///|
/// The fixture frame the parameter tests render against.
fn params_df() -> @frame.DataFrame raise @types.DataError {
  corpus_df()
}

///|
test "every bind widget emits its own shape" {
  let cases = [
    (
      @chart.VegaBind::Checkbox(
        @chart.VegaBindCheckbox::VegaBindCheckbox(debounce=10, name="show"),
      ),
      "{\"input\":\"checkbox\",\"debounce\":10,\"name\":\"show\"}",
    ),
    (
      @chart.VegaBind::RadioSelect(
        @chart.VegaBindRadioSelect::VegaBindRadioSelect(
          [Json::string("a"), Json::string("b")],
          labels=["A", "B"],
        ),
      ),
      "{\"input\":\"radio\",\"options\":[\"a\",\"b\"],\"labels\":[\"A\",\"B\"]}",
    ),
    (
      @chart.VegaBind::Range(
        @chart.VegaBindRange::VegaBindRange(min=0, max=100, step=5),
      ),
      "{\"input\":\"range\",\"max\":100,\"min\":0,\"step\":5}",
    ),
    (
      @chart.VegaBind::Input(
        @chart.VegaBindInput::VegaBindInput(placeholder="pick a region"),
      ),
      "{\"input\":\"text\",\"placeholder\":\"pick a region\"}",
    ),
    (
      @chart.VegaBind::Direct(
        @chart.VegaBindDirect::VegaBindDirect(element="#slider", event="input"),
      ),
      "{\"element\":\"#slider\",\"event\":\"input\"}",
    ),
  ]
  for c in cases {
    let (bind, expected) = c
    let spec = @chart.format_vega_lite(
      params_df(),
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          params=[
            @chart.VegaParam::Variable(
              @chart.VegaVariableParam::VegaVariableParam(
                name="p",
                value=Json::number(1),
                bind~,
              ),
            ),
          ],
        ),
      ),
    )
    assert_true(spec.contains("\"bind\":" + expected))
  }
}

///|
test "both selection triggers emit their shared and specific keys" {
  let point = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("val"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Selection(
            @chart.VegaSelectionParam::VegaSelectionParam(
              name="picked",
              select=@chart.VegaSelect::Point(
                @chart.VegaPointSelect::VegaPointSelect(
                  on="click",
                  clear="dblclick",
                  fields=["cat"],
                  encodings=["x"],
                  nearest=true,
                  toggle=false,
                  resolve=@chart.VegaSelectionResolution::Global,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(
    point.contains(
      "\"select\":{\"type\":\"point\",\"on\":\"click\",\"clear\":\"dblclick\",\"fields\":[\"cat\"],\"encodings\":[\"x\"],\"resolve\":\"global\",\"nearest\":true,\"toggle\":false}",
    ),
  )
  let interval = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Area,
        x=@chart.field("ts"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Selection(
            @chart.VegaSelectionParam::VegaSelectionParam(
              name="brush",
              select=@chart.VegaSelect::Interval(
                @chart.VegaIntervalSelect::VegaIntervalSelect(
                  translate="[mousedown, window:mouseup] > window:mousemove!",
                  zoom="wheel!",
                  mark=@chart.VegaBrush::VegaBrush(
                    fill="#669eff",
                    fill_opacity=0.2,
                    stroke_dash=[4.0, 2.0],
                  ),
                  encodings=["x"],
                  resolve=@chart.VegaSelectionResolution::Union,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(
    interval.contains(
      "\"select\":{\"type\":\"interval\",\"encodings\":[\"x\"],\"resolve\":\"union\",\"translate\":\"[mousedown, window:mouseup] > window:mousemove!\",\"zoom\":\"wheel!\",\"mark\":{\"fill\":\"#669eff\",\"fillOpacity\":0.2,\"strokeDash\":[4,2]}}",
    ),
  )
}

///|
test "a variable parameter carries its value, expression, and react" {
  let spec = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Variable(
            @chart.VegaVariableParam::VegaVariableParam(
              name="cutoff",
              value=Json::number(10),
            ),
          ),
          @chart.VegaParam::Variable(
            @chart.VegaVariableParam::VegaVariableParam(
              name="scale",
              expr="cutoff * 2",
              react=false,
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(spec.contains("\"name\":\"cutoff\",\"value\":10}"))
  assert_true(
    spec.contains("\"name\":\"scale\",\"expr\":\"cutoff * 2\",\"react\":false}"),
  )
}

///|
test "a selection parameter binds to a legend-style widget and inits" {
  let spec = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Area,
        x=@chart.field("ts"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Selection(
            @chart.VegaSelectionParam::VegaSelectionParam(
              name="brush",
              select=@chart.VegaSelect::Interval(
                @chart.VegaIntervalSelect::VegaIntervalSelect(encodings=["x"]),
              ),
              bind=@chart.VegaBind::Range(
                @chart.VegaBindRange::VegaBindRange(min=0),
              ),
              value=[Json::number(1), Json::number(2)],
              views=["view1", "view2"],
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(spec.contains("\"bind\":{\"input\":\"range\",\"min\":0}"))
  assert_true(spec.contains("\"value\":[1,2]"))
  assert_true(spec.contains("\"views\":[\"view1\",\"view2\"]"))
}

///|
test "a conditional encoding highlights what the predicate selects" {
  let spec = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("val"),
        y=@chart.field("val"),
        color=@chart.field(
          "grp",
          condition=@chart.VegaCondition::When(
            @chart.VegaPredicate::Expr("datum.val > 1"),
            Json::string("orangered"),
          ),
        ),
      ),
    ),
  )
  // The condition arm merges the predicate into the arm's definition;
  // the base definition stays the else.
  assert_true(
    spec.contains(
      "\"color\":{\"field\":\"grp\",\"condition\":{\"test\":\"datum.val > 1\",\"value\":\"orangered\"},\"type\":\"nominal\"}",
    ),
  )
}

///|
test "the array-carrying params are copied at construction and on read" {
  let options = [Json::string("a")]
  let radio = @chart.VegaBindRadioSelect::VegaBindRadioSelect(options)
  options.set(0, Json::string("z"))
  assert_eq(radio.options(), [Json::string("a")])
  radio.options().set(0, Json::string("z"))
  assert_eq(radio.options(), [Json::string("a")])
  let fields = ["cat"]
  let point = @chart.VegaPointSelect::VegaPointSelect(fields~)
  fields.set(0, "mutated")
  assert_eq(point.fields(), Some(["cat"]))
  let encodings = ["x"]
  let interval = @chart.VegaIntervalSelect::VegaIntervalSelect(encodings~)
  encodings.set(0, "y")
  assert_eq(interval.encodings(), Some(["x"]))
  assert_eq(interval.fields(), None)
  assert_eq(point.encodings(), None)
  let dash = [4.0]
  let brush = @chart.VegaBrush::VegaBrush(stroke_dash=dash)
  dash.set(0, 9.0)
  assert_eq(brush.stroke_dash(), Some([4.0]))
  let value = [Json::number(1)]
  let views = ["v1"]
  let selection = @chart.VegaSelectionParam::VegaSelectionParam(
    name="s",
    select=@chart.VegaSelect::Point(@chart.VegaPointSelect::VegaPointSelect()),
    value~,
    views~,
  )
  value.set(0, Json::number(9))
  views.set(0, "mutated")
  assert_eq(selection.value().map(fn(v) { v.length() }), Some(1))
  assert_eq(selection.views(), Some(["v1"]))
  // A bare selection reads both halves back as unset.
  let bare = @chart.VegaSelectionParam::VegaSelectionParam(
    name="s",
    select=@chart.VegaSelect::Point(@chart.VegaPointSelect::VegaPointSelect()),
  )
  assert_eq(bare.value(), None)
  assert_eq(bare.views(), None)
  // A chart's params list is copied, and read back copied again.
  let params = [
    @chart.VegaParam::Variable(
      @chart.VegaVariableParam::VegaVariableParam(name="p"),
    ),
  ]
  let chart = @chart.ChartSpec::of(
    @chart.ChartKind::Bar,
    x=@chart.field("cat"),
    y=@chart.field("val"),
    params~,
  )
  params.set(
    0,
    @chart.VegaParam::Variable(
      @chart.VegaVariableParam::VegaVariableParam(name="q"),
    ),
  )
  match chart.params() {
    Some(list) =>
      match list[0] {
        Variable(v) => assert_eq(v.name, "p")
        _ => fail("expected the unmutated variable parameter")
      }
    None => fail("params list missing")
  }
  let bare_chart = @chart.ChartSpec::of(
    @chart.ChartKind::Bar,
    x=@chart.field("cat"),
    y=@chart.field("val"),
  )
  assert_true(bare_chart.params() is None)
}

///|
test "the remaining widget, brush, and accessor arms all fire" {
  // Radio labels unset; interval fields set and point encodings set at
  // construction; every brush stroke property and input autocomplete;
  // the direct binding's debounce; the checkbox element.
  let radio_bare = @chart.VegaBindRadioSelect::VegaBindRadioSelect([
    Json::string("a"),
  ])
  assert_eq(radio_bare.labels(), None)
  let radio_labeled = @chart.VegaBindRadioSelect::VegaBindRadioSelect(
    [Json::string("a")],
    labels=["A"],
  )
  assert_eq(radio_labeled.labels(), Some(["A"]))
  radio_labeled.labels().unwrap().set(0, "Z")
  assert_eq(radio_labeled.labels(), Some(["A"]))
  let point_enc = @chart.VegaPointSelect::VegaPointSelect(encodings=["x"])
  assert_eq(point_enc.fields(), None)
  assert_eq(point_enc.encodings(), Some(["x"]))
  let interval_fields = @chart.VegaIntervalSelect::VegaIntervalSelect(fields=[
    "cat",
  ])
  assert_eq(interval_fields.fields(), Some(["cat"]))
  assert_eq(interval_fields.encodings(), None)
  let brush_bare = @chart.VegaBrush::VegaBrush()
  assert_eq(brush_bare.stroke_dash(), None)
  let spec = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Area,
        x=@chart.field("ts"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Selection(
            @chart.VegaSelectionParam::VegaSelectionParam(
              name="brush",
              select=@chart.VegaSelect::Interval(
                @chart.VegaIntervalSelect::VegaIntervalSelect(
                  mark=@chart.VegaBrush::VegaBrush(
                    stroke="#333",
                    stroke_opacity=0.5,
                    stroke_width=1,
                    stroke_dash_offset=2,
                    cursor="crosshair",
                    stroke_dash=[1.0],
                  ),
                  resolve=@chart.VegaSelectionResolution::Intersect,
                ),
              ),
            ),
          ),
          @chart.VegaParam::Variable(
            @chart.VegaVariableParam::VegaVariableParam(
              name="q",
              bind=@chart.VegaBind::Input(
                @chart.VegaBindInput::VegaBindInput(
                  autocomplete="region",
                  element="#search",
                ),
              ),
            ),
          ),
          @chart.VegaParam::Variable(
            @chart.VegaVariableParam::VegaVariableParam(
              name="d",
              bind=@chart.VegaBind::Direct(
                @chart.VegaBindDirect::VegaBindDirect(
                  element="#btn",
                  debounce=50,
                ),
              ),
            ),
          ),
          @chart.VegaParam::Variable(
            @chart.VegaVariableParam::VegaVariableParam(
              name="c",
              bind=@chart.VegaBind::Checkbox(
                @chart.VegaBindCheckbox::VegaBindCheckbox(element="#box"),
              ),
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(spec.contains("\"stroke\":\"#333\""))
  assert_true(spec.contains("\"strokeOpacity\":0.5"))
  assert_true(spec.contains("\"strokeWidth\":1"))
  assert_true(spec.contains("\"strokeDashOffset\":2"))
  assert_true(spec.contains("\"cursor\":\"crosshair\""))
  assert_true(spec.contains("\"resolve\":\"intersect\""))
  assert_true(spec.contains("\"autocomplete\":\"region\""))
  assert_true(spec.contains("\"element\":\"#search\""))
  assert_true(spec.contains("\"debounce\":50"))
  assert_true(spec.contains("\"element\":\"#box\""))
}

///|
test "selector fields escape like every other field reference" {
  // The projected fields are column names, so a dotted one selects on
  // the literal column rather than a nested path — the same escape the
  // encoding channels, lookup, and predicates apply.
  let spec = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("val"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Selection(
            @chart.VegaSelectionParam::VegaSelectionParam(
              name="picked",
              select=@chart.VegaSelect::Point(
                @chart.VegaPointSelect::VegaPointSelect(fields=["price.usd"]),
              ),
            ),
          ),
          @chart.VegaParam::Selection(
            @chart.VegaSelectionParam::VegaSelectionParam(
              name="brush",
              select=@chart.VegaSelect::Interval(
                @chart.VegaIntervalSelect::VegaIntervalSelect(fields=[
                  "price.usd",
                ]),
              ),
            ),
          ),
        ],
      ),
    ),
  )
  // The emitted JSON escapes the escape itself: the field text is
  // `price\.usd`, which the JSON stringifier writes with the backslash
  // doubled.
  assert_true(spec.contains("\"fields\":[\"price\\\\.usd\"]"))
}

///|
test "a radio / select binding may render as a dropdown" {
  // The schema's BindRadioSelect.input enum lists radio and select; the
  // default emission stays "radio", and input=Select spells the other
  // arm.
  let dropdown = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Variable(
            @chart.VegaVariableParam::VegaVariableParam(
              name="region",
              bind=@chart.VegaBind::RadioSelect(
                @chart.VegaBindRadioSelect::VegaBindRadioSelect(
                  [Json::string("north"), Json::string("south")],
                  input=@chart.VegaRadioSelectInput::Select,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(
    dropdown.contains(
      "\"bind\":{\"input\":\"select\",\"options\":[\"north\",\"south\"]}",
    ),
  )
  let radio = @chart.VegaBindRadioSelect::VegaBindRadioSelect([
    Json::string("a"),
  ])
  assert_true(radio.input is None)
  // The explicit radio arm spells the same input as the unset default.
  let explicit_radio = @chart.format_vega_lite(
    params_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        params=[
          @chart.VegaParam::Variable(
            @chart.VegaVariableParam::VegaVariableParam(
              name="region",
              bind=@chart.VegaBind::RadioSelect(
                @chart.VegaBindRadioSelect::VegaBindRadioSelect(
                  [Json::string("north")],
                  input=@chart.VegaRadioSelectInput::Radio,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  )
  assert_true(
    explicit_radio.contains(
      "\"bind\":{\"input\":\"radio\",\"options\":[\"north\"]}",
    ),
  )
}
