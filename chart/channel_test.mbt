// Blackbox tests for the `VegaChannel` family: the modifier enums, their
// emitted Vega-Lite keys, and the array-ownership contracts on the
// builders. The big enums (`VegaAggregate`'s twenty-five ops,
// `VegaTimeUnit`'s eighty units) are covered by generated tables that
// name every variant with the exact schema string it must emit — the
// same table shape the schema generator wrote the enums from, so a
// variant and its expected spelling live one line apart.

///|
/// The fixture frame every channel test renders against.
fn channel_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x", "y"]),
    @series.Series::from_ints("val", [1, 2]),
    @series.Series::from_timestamp_options("ts", [
      Some(1_704_067_200_000_000L),
      Some(1_704_075_840_000_000L),
    ]),
  ])
}

///|
/// `format_vega_lite` of a one-channel spec reading `key` of the `y`
/// channel — the reader the tables below share.
fn y_key(spec : String, key : String) -> String {
  let parsed = @json.parse(spec) catch { _ => return "<unparsable>" }
  match parsed {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("y") {
            Some(Object(c)) =>
              match c.get(key) {
                Some(String(t)) => t
                Some(True) => "true"
                Some(False) => "false"
                _ => "<missing>"
              }
            _ => "<missing>"
          }
        _ => "<missing>"
      }
    _ => "<unparsable>"
  }
}

///|
test "each VegaAggregate variant emits the schema's own aggregate string" {
  let df = channel_df()
  let cases = [
    (@chart.VegaAggregate::Argmax, "argmax"),
    (@chart.VegaAggregate::Argmin, "argmin"),
    (@chart.VegaAggregate::Average, "average"),
    (@chart.VegaAggregate::Count, "count"),
    (@chart.VegaAggregate::Distinct, "distinct"),
    (@chart.VegaAggregate::Max, "max"),
    (@chart.VegaAggregate::Mean, "mean"),
    (@chart.VegaAggregate::Median, "median"),
    (@chart.VegaAggregate::Min, "min"),
    (@chart.VegaAggregate::Missing, "missing"),
    (@chart.VegaAggregate::Product, "product"),
    (@chart.VegaAggregate::Q1, "q1"),
    (@chart.VegaAggregate::Q3, "q3"),
    (@chart.VegaAggregate::CI0, "ci0"),
    (@chart.VegaAggregate::CI1, "ci1"),
    (@chart.VegaAggregate::Stderr, "stderr"),
    (@chart.VegaAggregate::Stdev, "stdev"),
    (@chart.VegaAggregate::Stdevp, "stdevp"),
    (@chart.VegaAggregate::Sum, "sum"),
    (@chart.VegaAggregate::Valid, "valid"),
    (@chart.VegaAggregate::Values, "values"),
    (@chart.VegaAggregate::Variance, "variance"),
    (@chart.VegaAggregate::Variancep, "variancep"),
    (@chart.VegaAggregate::Exponential, "exponential"),
    (@chart.VegaAggregate::Exponentialb, "exponentialb"),
  ]
  for case in cases {
    let (op, expected) = case
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::bar(
          @chart.field("cat"),
          @chart.field("val", aggregate=op),
        ),
      ),
    )
    assert_eq(y_key(spec, "aggregate"), expected)
    // The aggregation is declared, not applied: dtype inference stands
    // untouched, and the field key survives — except for Count, the one
    // aggregate that reads no column.
    assert_eq(y_key(spec, "type"), "quantitative")
    if !(op is @chart.VegaAggregate::Count) {
      assert_eq(y_key(spec, "field"), "val")
    } else {
      assert_eq(y_key(spec, "field"), "<missing>")
    }
  }
}

///|
test "each VegaTimeUnit variant emits the schema's own timeUnit string" {
  let df = channel_df()
  let cases = [
    (@chart.VegaTimeUnit::Year, "year"),
    (@chart.VegaTimeUnit::Quarter, "quarter"),
    (@chart.VegaTimeUnit::Month, "month"),
    (@chart.VegaTimeUnit::Week, "week"),
    (@chart.VegaTimeUnit::Day, "day"),
    (@chart.VegaTimeUnit::Dayofyear, "dayofyear"),
    (@chart.VegaTimeUnit::Date, "date"),
    (@chart.VegaTimeUnit::Hours, "hours"),
    (@chart.VegaTimeUnit::Minutes, "minutes"),
    (@chart.VegaTimeUnit::Seconds, "seconds"),
    (@chart.VegaTimeUnit::Milliseconds, "milliseconds"),
    (@chart.VegaTimeUnit::UtcYear, "utcyear"),
    (@chart.VegaTimeUnit::UtcQuarter, "utcquarter"),
    (@chart.VegaTimeUnit::UtcMonth, "utcmonth"),
    (@chart.VegaTimeUnit::UtcWeek, "utcweek"),
    (@chart.VegaTimeUnit::UtcDay, "utcday"),
    (@chart.VegaTimeUnit::UtcDayofyear, "utcdayofyear"),
    (@chart.VegaTimeUnit::UtcDate, "utcdate"),
    (@chart.VegaTimeUnit::UtcHours, "utchours"),
    (@chart.VegaTimeUnit::UtcMinutes, "utcminutes"),
    (@chart.VegaTimeUnit::UtcSeconds, "utcseconds"),
    (@chart.VegaTimeUnit::UtcMilliseconds, "utcmilliseconds"),
    (@chart.VegaTimeUnit::Yearquarter, "yearquarter"),
    (@chart.VegaTimeUnit::Yearquartermonth, "yearquartermonth"),
    (@chart.VegaTimeUnit::Yearmonth, "yearmonth"),
    (@chart.VegaTimeUnit::Yearmonthdate, "yearmonthdate"),
    (@chart.VegaTimeUnit::Yearmonthdatehours, "yearmonthdatehours"),
    (
      @chart.VegaTimeUnit::Yearmonthdatehoursminutes,
      "yearmonthdatehoursminutes",
    ),
    (
      @chart.VegaTimeUnit::Yearmonthdatehoursminutesseconds,
      "yearmonthdatehoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::Yearweek, "yearweek"),
    (@chart.VegaTimeUnit::Yearweekday, "yearweekday"),
    (@chart.VegaTimeUnit::Yearweekdayhours, "yearweekdayhours"),
    (@chart.VegaTimeUnit::Yearweekdayhoursminutes, "yearweekdayhoursminutes"),
    (
      @chart.VegaTimeUnit::Yearweekdayhoursminutesseconds,
      "yearweekdayhoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::Yeardayofyear, "yeardayofyear"),
    (@chart.VegaTimeUnit::Quartermonth, "quartermonth"),
    (@chart.VegaTimeUnit::Monthdate, "monthdate"),
    (@chart.VegaTimeUnit::Monthdatehours, "monthdatehours"),
    (@chart.VegaTimeUnit::Monthdatehoursminutes, "monthdatehoursminutes"),
    (
      @chart.VegaTimeUnit::Monthdatehoursminutesseconds,
      "monthdatehoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::Weekday, "weekday"),
    (@chart.VegaTimeUnit::Weekdayhours, "weekdayhours"),
    (@chart.VegaTimeUnit::Weekdayhoursminutes, "weekdayhoursminutes"),
    (
      @chart.VegaTimeUnit::Weekdayhoursminutesseconds,
      "weekdayhoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::Dayhours, "dayhours"),
    (@chart.VegaTimeUnit::Dayhoursminutes, "dayhoursminutes"),
    (@chart.VegaTimeUnit::Dayhoursminutesseconds, "dayhoursminutesseconds"),
    (@chart.VegaTimeUnit::Hoursminutes, "hoursminutes"),
    (@chart.VegaTimeUnit::Hoursminutesseconds, "hoursminutesseconds"),
    (@chart.VegaTimeUnit::Minutesseconds, "minutesseconds"),
    (@chart.VegaTimeUnit::Secondsmilliseconds, "secondsmilliseconds"),
    (@chart.VegaTimeUnit::UtcYearquarter, "utcyearquarter"),
    (@chart.VegaTimeUnit::UtcYearquartermonth, "utcyearquartermonth"),
    (@chart.VegaTimeUnit::UtcYearmonth, "utcyearmonth"),
    (@chart.VegaTimeUnit::UtcYearmonthdate, "utcyearmonthdate"),
    (@chart.VegaTimeUnit::UtcYearmonthdatehours, "utcyearmonthdatehours"),
    (
      @chart.VegaTimeUnit::UtcYearmonthdatehoursminutes,
      "utcyearmonthdatehoursminutes",
    ),
    (
      @chart.VegaTimeUnit::UtcYearmonthdatehoursminutesseconds,
      "utcyearmonthdatehoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::UtcYearweek, "utcyearweek"),
    (@chart.VegaTimeUnit::UtcYearweekday, "utcyearweekday"),
    (@chart.VegaTimeUnit::UtcYearweekdayhours, "utcyearweekdayhours"),
    (
      @chart.VegaTimeUnit::UtcYearweekdayhoursminutes,
      "utcyearweekdayhoursminutes",
    ),
    (
      @chart.VegaTimeUnit::UtcYearweekdayhoursminutesseconds,
      "utcyearweekdayhoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::UtcYeardayofyear, "utcyeardayofyear"),
    (@chart.VegaTimeUnit::UtcQuartermonth, "utcquartermonth"),
    (@chart.VegaTimeUnit::UtcMonthdate, "utcmonthdate"),
    (@chart.VegaTimeUnit::UtcMonthdatehours, "utcmonthdatehours"),
    (@chart.VegaTimeUnit::UtcMonthdatehoursminutes, "utcmonthdatehoursminutes"),
    (
      @chart.VegaTimeUnit::UtcMonthdatehoursminutesseconds,
      "utcmonthdatehoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::UtcWeekday, "utcweekday"),
    (@chart.VegaTimeUnit::UtcWeekdayhours, "utcweekdayhours"),
    (@chart.VegaTimeUnit::UtcWeekdayhoursminutes, "utcweekdayhoursminutes"),
    (
      @chart.VegaTimeUnit::UtcWeekdayhoursminutesseconds,
      "utcweekdayhoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::UtcDayhours, "utcdayhours"),
    (@chart.VegaTimeUnit::UtcDayhoursminutes, "utcdayhoursminutes"),
    (
      @chart.VegaTimeUnit::UtcDayhoursminutesseconds,
      "utcdayhoursminutesseconds",
    ),
    (@chart.VegaTimeUnit::UtcHoursminutes, "utchoursminutes"),
    (@chart.VegaTimeUnit::UtcHoursminutesseconds, "utchoursminutesseconds"),
    (@chart.VegaTimeUnit::UtcMinutesseconds, "utcminutesseconds"),
    (@chart.VegaTimeUnit::UtcSecondsmilliseconds, "utcsecondsmilliseconds"),
  ]
  for case in cases {
    let (unit, expected) = case
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::line(
          @chart.field("ts", time_unit=unit),
          @chart.field("val"),
        ),
      ),
    )
    assert_eq(channel_key(spec, "x", "timeUnit"), expected)
  }
}

///|
test "a count channel emits aggregate count with no field" {
  inspect(
    @chart.format_vega_lite(
      channel_df(),
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.VegaChannel::count()),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"aggregate":"count","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1,"ts":"2024-01-01T00:00:00.000000"},{"cat":"y","val":2,"ts":"2024-01-01T02:24:00.000000"}]}}
    ),
  )
}

///|
test "a count channel skips column resolution entirely" {
  // `field("nox", aggregate=Count)` names a column the frame does not
  // have, and that is fine — the count aggregate ignores the field, so
  // no `ColumnNotFound` is raised and no `field` key is emitted. This is
  // the histogram shape: a binned x with a row-count y.
  let spec = @chart.format_vega_lite(
    channel_df(),
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field("val", bin=@chart.VegaBin::On),
        @chart.field("nox", aggregate=Count),
      ),
    ),
  )
  assert_eq(y_key(spec, "aggregate"), "count")
  assert_eq(y_key(spec, "field"), "<missing>")
  assert_eq(y_key(spec, "type"), "quantitative")
  assert_eq(channel_key(spec, "x", "bin"), "true")
}

///|
test "each VegaBin form emits its own shape" {
  let df = channel_df()
  // `On` is the bare boolean; `Params` the object with every set field.
  let on = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field("val", bin=@chart.VegaBin::On),
        @chart.VegaChannel::count(),
      ),
    ),
  )
  assert_eq(channel_key(on, "x", "bin"), "true")
  let params = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field(
          "val",
          bin=@chart.VegaBin::Params(
            @chart.VegaBinParams::VegaBinParams(
              maxbins=20,
              anchor=0.0,
              base=10,
              nice=true,
              step=5.0,
              minstep=1.0,
              binned=false,
              extent=(0.0, 100.0),
              divide=[5.0, 2.0],
              steps=[1.0, 2.0, 5.0],
            ),
          ),
        ),
        @chart.VegaChannel::count(),
      ),
    ),
  )
  let parsed = @json.parse(params) catch { _ => Json::null() }
  let bin = match parsed {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("x") {
            Some(Object(x)) =>
              match x.get("bin") {
                Some(b) => b
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  // The bin object emits in the params' fixed key order, so its
  // stringified form is a stable pin.
  // The bin object emits in the params' fixed key order, so its
  // stringified form is a stable pin.
  if bin is Object(_) {
    assert_eq(
      bin.stringify(),
      "{\"maxbins\":20,\"anchor\":0,\"base\":10,\"nice\":true,\"step\":5,\"minstep\":1,\"binned\":false,\"extent\":[0,100],\"divide\":[5,2],\"steps\":[1,2,5]}",
    )
  } else {
    fail("bin key missing from the emitted channel")
  }
  // `Binned` is the marker string: the data is already binned.
  let binned = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field("val", bin=@chart.VegaBin::Binned),
        @chart.field("val"),
      ),
    ),
  )
  assert_eq(channel_key(binned, "x", "bin"), "binned")
}

///|
test "each VegaChannelSort form emits its own shape" {
  let df = channel_df()
  let bare = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field("cat", sort=@chart.VegaChannelSort::Ascending),
        @chart.field("val", sort=@chart.VegaChannelSort::Descending),
      ),
    ),
  )
  assert_eq(channel_key(bare, "x", "sort"), "ascending")
  assert_eq(y_key(bare, "sort"), "descending")
  let by_channel = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field(
          "cat",
          sort=ByChannel(@chart.VegaSortChannel::Size, Some(true)),
        ),
        @chart.field("val"),
      ),
    ),
  )
  assert_eq(channel_key(by_channel, "x", "sort"), "-size")
  let plain_channel = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field(
          "cat",
          sort=@chart.VegaChannelSort::ByChannel(
            @chart.VegaSortChannel::X,
            None,
          ),
        ),
        @chart.field("val"),
      ),
    ),
  )
  assert_eq(channel_key(plain_channel, "x", "sort"), "x")
  let by_field = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field(
          "cat",
          sort=@chart.VegaChannelSort::ByField(
            "val",
            Some(@chart.VegaSort::Descending),
          ),
        ),
        @chart.field("val"),
      ),
    ),
  )
  let by_field_sort = @json.parse(by_field) catch { _ => Json::null() }
  let by_field_value = match by_field_sort {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("x") {
            Some(Object(x)) =>
              match x.get("sort") {
                Some(v) => v
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  assert_eq(
    by_field_value.stringify(),
    "{\"field\":\"val\",\"order\":\"descending\"}",
  )
  let off = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field("cat", sort=@chart.VegaChannelSort::Off),
        @chart.field("val"),
      ),
    ),
  )
  // `null` reads back as the JSON null, which the key reader spells
  // "<missing>" — present but not a string.
  let parsed = @json.parse(off) catch { _ => Json::null() }
  let sort = match parsed {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("x") {
            Some(Object(x)) =>
              match x.get("sort") {
                Some(s) => s
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  assert_eq(sort.stringify(), "null")
}

///|
test "each VegaSortChannel variant emits the schema's channel name" {
  let df = channel_df()
  let cases = [
    (@chart.VegaSortChannel::X, "x"),
    (@chart.VegaSortChannel::Y, "y"),
    (@chart.VegaSortChannel::Color, "color"),
    (@chart.VegaSortChannel::Fill, "fill"),
    (@chart.VegaSortChannel::Stroke, "stroke"),
    (@chart.VegaSortChannel::StrokeWidth, "strokeWidth"),
    (@chart.VegaSortChannel::Size, "size"),
    (@chart.VegaSortChannel::Shape, "shape"),
    (@chart.VegaSortChannel::FillOpacity, "fillOpacity"),
    (@chart.VegaSortChannel::StrokeOpacity, "strokeOpacity"),
    (@chart.VegaSortChannel::Opacity, "opacity"),
    (@chart.VegaSortChannel::Text, "text"),
  ]
  for case in cases {
    let (channel, expected) = case
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::bar(
          @chart.field(
            "cat",
            sort=@chart.VegaChannelSort::ByChannel(channel, None),
          ),
          @chart.field("val"),
        ),
      ),
    )
    assert_eq(channel_key(spec, "x", "sort"), expected)
  }
}

///|
test "a Values sort emits the caller's list, copied" {
  let order = [Json::string("b"), Json::string("a")]
  let spec = @chart.ChartSpec::bar(
    @chart.field("cat", sort=@chart.VegaChannelSort::values(order)),
    @chart.field("val"),
  )
  // Mutating the caller's array after the build cannot move the spec —
  // the builder copied it.
  order.set(0, Json::string("zzz"))
  let emitted = @chart.format_vega_lite(channel_df(), @chart.Chart::of(spec))
  let parsed = @json.parse(emitted) catch { _ => Json::null() }
  let sort = match parsed {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("x") {
            Some(Object(x)) =>
              match x.get("sort") {
                Some(s) => s
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  assert_eq(sort.stringify(), "[\"b\",\"a\"]")
}

///|
test "VegaBinParams copies divide and steps at construction and on read" {
  let divide = [5.0, 2.0]
  let steps = [1.0, 5.0]
  let params = @chart.VegaBinParams::VegaBinParams(divide~, steps~)
  divide.set(0, 99.0)
  steps.set(0, 99.0)
  // The params kept their own copies of both arrays...
  assert_eq(params.divide(), Some([5.0, 2.0]))
  assert_eq(params.steps(), Some([1.0, 5.0]))
  // ...and each read hands back a fresh copy.
  let first = params.divide()
  match first {
    Some(arr) => {
      arr.set(0, 99.0)
      assert_eq(params.divide(), Some([5.0, 2.0]))
    }
    None => fail("divide accessor returned None")
  }
}

///|
test "constant and datum channels emit value and datum definitions" {
  let df = channel_df()
  let spec = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        Point,
        x=@chart.field("val"),
        y=@chart.field("val"),
        color=@chart.constant(Json::string("steelblue")),
        size=@chart.datum(Json::number(60.0)),
      ),
    ),
  )
  assert_eq(channel_key(spec, "color", "value"), "steelblue")
  // A value definition carries no `type` — the key reader's
  // "<missing>" is the assertion.
  assert_eq(channel_key(spec, "color", "type"), "<missing>")
  let size_channel = @json.parse(spec) catch { _ => Json::null() }
  let size_datum = match size_channel {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("size") {
            Some(Object(c)) =>
              match c.get("datum") {
                Some(v) => v
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  assert_eq(size_datum.stringify(), "60")
}

///|
test "stack overrides emit the schema's stack strings and null" {
  let df = channel_df()
  let cases = [
    (@chart.VegaStack::Zero, "zero"),
    (@chart.VegaStack::Center, "center"),
    (@chart.VegaStack::Normalize, "normalize"),
  ]
  for case in cases {
    let (stack, expected) = case
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val", stack~)),
      ),
    )
    assert_eq(y_key(spec, "stack"), expected)
  }
  let off = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val", stack=@chart.VegaStack::Off),
      ),
    ),
  )
  let parsed = @json.parse(off) catch { _ => Json::null() }
  let stack = match parsed {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("y") {
            Some(Object(y)) =>
              match y.get("stack") {
                Some(s) => s
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  assert_eq(stack.stringify(), "null")
}

///|
test "each VegaAutoSize variant emits the schema's autosize string" {
  let df = channel_df()
  let cases = [
    (@chart.VegaAutoSize::Pad, "pad"),
    (@chart.VegaAutoSize::Fit, "fit"),
    (@chart.VegaAutoSize::FitX, "fit-x"),
    (@chart.VegaAutoSize::FitY, "fit-y"),
    (@chart.VegaAutoSize::None, "none"),
  ]
  for case in cases {
    let (autosize, expected) = case
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::of(
          Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          autosize~,
        ),
      ),
    )
    let got = match @json.parse(spec) {
      Object(obj) =>
        match obj.get("autosize") {
          Some(String(a)) => a
          _ => "<missing>"
        }
      _ => "<unparsable>"
    }
    assert_eq(got, expected)
  }
}

///|
test "a channel title rides any field definition, format the string family" {
  // `format` is legal only on the string-bearing channels (text, tooltip,
  // href, url) — the schema carries none on a position definition, so a
  // format set on y is dropped rather than emitted into an invalid spec.
  let spec = @chart.format_vega_lite(
    channel_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val", title="Revenue €", format=".2f"),
        tooltip=@chart.field("val", format=".2f"),
      ),
    ),
  )
  assert_eq(y_key(spec, "title"), "Revenue €")
  assert_eq(y_key(spec, "format"), "<missing>")
  assert_eq(channel_key(spec, "tooltip", "format"), ".2f")
}

///|
test "padding's two forms and a band position complete their arms" {
  let df = channel_df()
  // `Px` padding (one number, all sides) and the per-side form with all
  // four sides named — the chrome test leaves the right / bottom arms
  // and the plain-number form unexercised.
  let px = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        padding=@chart.VegaPadding::Px(8),
      ),
    ),
  )
  let px_padding = match @json.parse(px) {
    Object(obj) =>
      match obj.get("padding") {
        Some(Number(n, ..)) => n.to_string()
        _ => "<missing>"
      }
    _ => "<unparsable>"
  }
  assert_eq(px_padding, "8")
  let full_sides = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Bar,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        padding=@chart.VegaPadding::Sides(
          @chart.VegaSides::VegaSides(top=1, right=2, bottom=3, left=4),
        ),
      ),
    ),
  )
  let sides = match @json.parse(full_sides) {
    Object(obj) =>
      match obj.get("padding") {
        Some(Object(p)) => Json::object(p).stringify()
        _ => "<missing>"
      }
    _ => "<unparsable>"
  }
  assert_eq(sides, "{\"top\":1,\"right\":2,\"bottom\":3,\"left\":4}")
  // A by-field sort with the ascending order spelled, and a band position.
  let spec = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(
        @chart.field(
          "cat",
          sort=@chart.VegaChannelSort::ByField("val", Some(Ascending)),
          band_position=0.5,
        ),
        @chart.field("val"),
      ),
    ),
  )
  let ascending_sort = @json.parse(spec) catch { _ => Json::null() }
  let ascending_value = match ascending_sort {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("x") {
            Some(Object(x)) =>
              match x.get("sort") {
                Some(v) => v
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  assert_eq(
    ascending_value.stringify(),
    "{\"field\":\"val\",\"order\":\"ascending\"}",
  )
  assert_eq(channel_key(spec, "x", "bandPosition"), "0.5")
}
