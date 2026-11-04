// Blackbox tests for `@chart.format_vega_lite` / `@chart.write_vega_lite`
// and the `ChartKind` / `VegaChannel` / `ChartSpec` builders.
//
// The renderer assembles a Vega-Lite v5 spec through the builtin `@json`,
// so these tests pin the *spec layout* MoonFrame imposes — `$schema` /
// `title` / `width` / `height` / `mark` / `encoding` (field + inferred
// `type` + the channel's declared `aggregate` / `bin` / `sort`) / inlined
// `data.values` — plus the column-name validation (`ColumnNotFound`, in
// the `ChartSpec` doc's fixed channel order) and the cell conventions
// inherited from `format_json` (null / non-finite floats → JSON `null`).
// One test parses the output back with `@json.parse` to self-certify it
// is well-formed JSON.
//
// `id_double` (defeats constant folding for the non-finite-float test)
// is a blackbox-test helper; this package defines its own copy, since
// helpers do not cross package boundaries even between test suites.

///|
/// Identity that defeats compile-time constant folding, so `x / 0.0`
/// evaluates to a runtime ±Infinity / NaN rather than being rejected as
/// a constant division by zero.
fn id_double(x : Double) -> Double {
  x
}

///|
/// Two-column fixture: a nominal `cat` (`String`) and a quantitative
/// `val` (`Int`), single row — the smallest frame that exercises both
/// encoding-`type` branches.
fn catval_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("val", [1]),
  ])
}

///|
/// Three-column fixture adding a `grp` (`String`) column for the `color`
/// encoding.
fn catvalgrp_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("val", [1]),
    @series.Series::from_strings("grp", ["a"]),
  ])
}

// ── format_vega_lite: spec layout ───────────────────────────────────

///|
test "format_vega_lite: bar chart emits a complete Vega-Lite v5 spec" {
  // The canonical case pins the whole shape: pinned `$schema`, `mark`,
  // both encoding channels (nominal x / quantitative y, inferred from the
  // column dtypes), and the frame inlined as `data.values`.
  inspect(
    @chart.format_vega_lite(
      catval_df(),
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
}

///|
test "format_vega_lite: quotes in a column name are escaped in the Vega field path" {
  // Vega compiles the field into a datum accessor expression, where a bare
  // quote terminates the string early and the exported spec throws at
  // compile time instead of rendering.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("it's \"q\"", [1]),
  ])
  let spec = @chart.format_vega_lite(
    df,
    @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("it's \"q\"")),
  )
  let field = match @json.parse(spec) {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("y") {
            Some(Object(y)) =>
              match y.get("field") {
                Some(String(f)) => f
                _ => "<missing>"
              }
            _ => "<missing>"
          }
        _ => "<missing>"
      }
    _ => "<missing>"
  }
  // The parsed field carries one backslash before each quote character.
  assert_eq(field, "it\\'s \\\"q\\\"")
}

///|
test "format_vega_lite: a `.` in a column name is escaped in the Vega field path" {
  // Vega-Lite reads an unescaped `.` as nested-object access, so a column
  // literally named `price.usd` must be escaped to `price\.usd` to resolve to
  // the real column rather than silently plotting nothing.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("price.usd", [1]),
  ])
  let field = match
    @json.parse(
      @chart.format_vega_lite(
        df,
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("price.usd")),
      ),
    ) {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("y") {
            Some(Object(y)) =>
              match y.get("field") {
                Some(String(f)) => f
                _ => "<missing>"
              }
            _ => "<missing>"
          }
        _ => "<missing>"
      }
    _ => "<missing>"
  }
  // The parsed field is the literal escaped path (one backslash before `.`).
  assert_eq(field, "price\\.usd")
}

///|
test "format_vega_lite: a type_override replaces the color channel's inferred type" {
  // A numeric grouping column ("g") would infer `quantitative` (a
  // continuous gradient); the channel's type_override forces the chosen
  // type. Covers all four VegaType variants.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("val", [1]),
    @series.Series::from_ints("g", [1]),
  ])
  let cases = [
    (@chart.VegaType::Quantitative, "quantitative"),
    (@chart.VegaType::Nominal, "nominal"),
    (@chart.VegaType::Ordinal, "ordinal"),
    (@chart.VegaType::Temporal, "temporal"),
  ]
  for case in cases {
    let (vt, expected) = case
    let spec = @chart.format_vega_lite(
      df,
      @chart.ChartSpec::point(
        @chart.field("cat"),
        @chart.field("val"),
        color=@chart.field("g", type_override=vt),
      ),
    )
    assert_eq(channel_key(spec, "color", "type"), expected)
  }
}

///|
test "format_vega_lite: each ChartKind maps to its Vega-Lite mark" {
  // Parse the output and read the `mark` field back, so all thirteen
  // `ChartKind` arms are exercised without thirteen near-identical spec
  // strings — and the parse doubles as a well-formedness check.
  let df = catval_df()
  let cases = [
    (@chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")), "bar"),
    (@chart.ChartSpec::line(@chart.field("cat"), @chart.field("val")), "line"),
    (@chart.ChartSpec::point(@chart.field("cat"), @chart.field("val")), "point"),
    (@chart.ChartSpec::area(@chart.field("cat"), @chart.field("val")), "area"),
    (@chart.ChartSpec::tick(@chart.field("cat"), @chart.field("val")), "tick"),
    (@chart.ChartSpec::rect(@chart.field("cat"), @chart.field("val")), "rect"),
    (@chart.ChartSpec::rule(@chart.field("cat"), @chart.field("val")), "rule"),
    (
      @chart.ChartSpec::circle(@chart.field("cat"), @chart.field("val")),
      "circle",
    ),
    (
      @chart.ChartSpec::square(@chart.field("cat"), @chart.field("val")),
      "square",
    ),
    (@chart.ChartSpec::trail(@chart.field("cat"), @chart.field("val")), "trail"),
    (
      @chart.ChartSpec::text(
        @chart.field("cat"),
        @chart.field("val"),
        @chart.field("cat"),
      ),
      "text",
    ),
    (@chart.ChartSpec::arc(@chart.field("val")), "arc"),
    (
      @chart.ChartSpec::boxplot(@chart.field("cat"), @chart.field("val")),
      "boxplot",
    ),
  ]
  for case in cases {
    let (spec, expected_mark) = case
    let mark = match @json.parse(@chart.format_vega_lite(df, spec)) {
      Object(obj) =>
        match obj.get("mark") {
          Some(String(m)) => m
          _ => "<missing>"
        }
      _ => "<not-an-object>"
    }
    assert_eq(mark, expected_mark)
  }
}

///|
test "format_vega_lite: title injects a top-level title" {
  inspect(
    @chart.format_vega_lite(
      catval_df(),
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val"),
        title="Sales",
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","title":"Sales","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
}

///|
test "format_vega_lite: width and height inject top-level view sizes" {
  // The sizes follow `title` in the emitted object and are plain JSON
  // numbers; unset sizes are omitted (the canonical case has none).
  inspect(
    @chart.format_vega_lite(
      catval_df(),
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val"),
        title="Sales",
        width=320,
        height=240,
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","title":"Sales","width":320,"height":240,"mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
}

///|
test "format_vega_lite: color adds a color encoding channel" {
  inspect(
    @chart.format_vega_lite(
      catvalgrp_df(),
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val"),
        color=@chart.field("grp"),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"color":{"field":"grp","type":"nominal"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: size, opacity, tooltip, and detail channels follow color" {
  // The four remaining non-polar channels, one spec — the emission order
  // matches the fixed resolution order (size, opacity, tooltip, detail
  // after color, which this spec leaves unset).
  inspect(
    @chart.format_vega_lite(
      catvalgrp_df(),
      @chart.ChartSpec::point(
        @chart.field("cat"),
        @chart.field("val"),
        size=@chart.field("val"),
        opacity=@chart.field("val"),
        tooltip=@chart.field("grp"),
        detail=@chart.field("grp"),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"point","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"size":{"field":"val","type":"quantitative"},"opacity":{"field":"val","type":"quantitative"},"tooltip":{"field":"grp","type":"nominal"},"detail":{"field":"grp","type":"nominal"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: x2 and y2 emit the ranged-mark end channels" {
  inspect(
    @chart.format_vega_lite(
      catvalgrp_df(),
      @chart.ChartSpec::rect(
        @chart.field("cat"),
        @chart.field("val"),
        x2=@chart.field("grp"),
        y2=@chart.field("val"),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"rect","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"x2":{"field":"grp","type":"nominal"},"y2":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: each VegaAggregate maps to its Vega-Lite aggregate" {
  // The five column aggregates read back from the y channel; the count
  // aggregate has its own no-field test below.
  let cases = [
    (@chart.VegaAggregate::Sum, "sum"),
    (@chart.VegaAggregate::Mean, "mean"),
    (@chart.VegaAggregate::Median, "median"),
    (@chart.VegaAggregate::Min, "min"),
    (@chart.VegaAggregate::Max, "max"),
  ]
  for case in cases {
    let (op, expected) = case
    let spec = @chart.format_vega_lite(
      catval_df(),
      @chart.ChartSpec::bar(
        @chart.field("cat"),
        @chart.field("val", aggregate=op),
      ),
    )
    assert_eq(channel_key(spec, "y", "aggregate"), expected)
    // An aggregate is declared, not applied: the field and its dtype
    // inference are unchanged.
    assert_eq(channel_key(spec, "y", "field"), "val")
    assert_eq(channel_key(spec, "y", "type"), "quantitative")
  }
}

///|
test "format_vega_lite: a count channel emits aggregate count with no field" {
  // A count tallies rows per group, so no column is read: the channel
  // carries no `field` key, and its type is quantitative by definition.
  inspect(
    @chart.format_vega_lite(
      catval_df(),
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.VegaChannel::count()),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"aggregate":"count","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
}

///|
test "format_vega_lite: a count channel skips column resolution entirely" {
  // `field("nox", aggregate=Count)` names a column the frame does not
  // have, and that is fine — the count aggregate ignores the field, so
  // no `ColumnNotFound` is raised and no `field` key is emitted. This is
  // the histogram shape: a binned x with a row-count y.
  let spec = @chart.format_vega_lite(
    catval_df(),
    @chart.ChartSpec::bar(
      @chart.field("val", bin=true),
      @chart.field("nox", aggregate=Count),
    ),
  )
  assert_eq(channel_key(spec, "y", "aggregate"), "count")
  assert_eq(channel_key(spec, "y", "field"), "<missing>")
  assert_eq(channel_key(spec, "y", "type"), "quantitative")
  assert_eq(channel_key(spec, "x", "bin"), "true")
}

///|
test "format_vega_lite: bin emits the channel's bin key as given" {
  // `bin=true` declares binning (the Vega-Lite runtime picks the bins);
  // `bin=false` is emitted as an explicit false rather than dropped —
  // the caller said so.
  let binned = @chart.format_vega_lite(
    catval_df(),
    @chart.ChartSpec::point(@chart.field("val", bin=true), @chart.field("val")),
  )
  assert_eq(channel_key(binned, "x", "bin"), "true")
  let unbinned = @chart.format_vega_lite(
    catval_df(),
    @chart.ChartSpec::point(@chart.field("val", bin=false), @chart.field("val")),
  )
  assert_eq(channel_key(unbinned, "x", "bin"), "false")
}

///|
test "format_vega_lite: a sort channel orders the channel's scale" {
  let ascending = @chart.format_vega_lite(
    catval_df(),
    @chart.ChartSpec::bar(
      @chart.field("cat", sort=@chart.VegaSort::Ascending),
      @chart.field("val"),
    ),
  )
  assert_eq(channel_key(ascending, "x", "sort"), "ascending")
  let descending = @chart.format_vega_lite(
    catval_df(),
    @chart.ChartSpec::bar(
      @chart.field("cat", sort=@chart.VegaSort::Descending),
      @chart.field("val"),
    ),
  )
  assert_eq(channel_key(descending, "x", "sort"), "descending")
}

///|
test "format_vega_lite: an arc pie emits theta with its color grouping" {
  // A pie is an arc mark with a theta measure and a color grouping; the
  // emission order follows the fixed resolution order, so `color` lands
  // before `theta` even though the constructor names theta first.
  inspect(
    @chart.format_vega_lite(
      catvalgrp_df(),
      @chart.ChartSpec::arc(
        @chart.field("val", aggregate=Sum),
        color=@chart.field("grp"),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"arc","encoding":{"color":{"field":"grp","type":"nominal"},"theta":{"field":"val","aggregate":"sum","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: radius and radius2 emit the arc's polar channels" {
  // A rose varies the slice length with radius; a donut cuts the center
  // out with radius2. Both resolve like any other channel.
  let spec = @chart.format_vega_lite(
    catvalgrp_df(),
    @chart.ChartSpec::arc(
      @chart.field("val"),
      color=@chart.field("cat"),
      radius=@chart.field("grp"),
      radius2=@chart.field("val"),
    ),
  )
  assert_eq(channel_key(spec, "radius", "field"), "grp")
  assert_eq(channel_key(spec, "radius", "type"), "nominal")
  assert_eq(channel_key(spec, "radius2", "field"), "val")
  assert_eq(channel_key(spec, "radius2", "type"), "quantitative")
}

///|
test "format_vega_lite: field type follows column dtype (Float→quantitative, Bool→nominal)" {
  // Complements the canonical case (Int→quantitative, String→nominal): a
  // Float column is quantitative and a Bool column is nominal.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_floats("ratio", [1.5]),
    @series.Series::from_bools("flag", [true]),
  ])
  inspect(
    @chart.format_vega_lite(
      df,
      @chart.ChartSpec::point(@chart.field("ratio"), @chart.field("flag")),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"point","encoding":{"x":{"field":"ratio","type":"quantitative"},"y":{"field":"flag","type":"nominal"}},"data":{"values":[{"ratio":1.5,"flag":true}]}}
    ),
  )
}

///|
test "format_vega_lite: null and non-finite float cells become JSON null" {
  // `data.values` reuses `format_json`' cell mapping: an explicit
  // null, and a non-finite Float (±Infinity / NaN, which have no JSON
  // literal), all render as `null`.
  let inf = id_double(1.0) / id_double(0.0)
  let nan = id_double(0.0) / id_double(0.0)
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("label", ["a", "b", "c", "d"]),
    @series.Series::from_float_options("amount", [
      Some(1.5),
      None,
      Some(inf),
      Some(nan),
    ]),
  ])
  inspect(
    @chart.format_vega_lite(
      df,
      @chart.ChartSpec::bar(@chart.field("label"), @chart.field("amount")),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"label","type":"nominal"},"y":{"field":"amount","type":"quantitative"}},"data":{"values":[{"label":"a","amount":1.5},{"label":"b","amount":null},{"label":"c","amount":null},{"label":"d","amount":null}]}}
    ),
  )
}

///|
test "format_vega_lite: a frame with columns but no rows yields empty data.values" {
  let schema = @types.Schema::Schema([
    @types.Field::Field("cat", @types.DataType::String),
    @types.Field::Field("val", @types.DataType::Int),
  ])
  let empty = @frame.DataFrame::empty(schema)
  inspect(
    @chart.format_vega_lite(
      empty,
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[]}}
    ),
  )
}

///|
test "format_vega_lite: output is well-formed JSON (parses back to an object)" {
  // The most complex spec (title + color) round-trips through the builtin
  // JSON reader, self-certifying it is a legal Vega-Lite v5 document.
  let spec = @chart.format_vega_lite(
    catvalgrp_df(),
    @chart.ChartSpec::area(
      @chart.field("cat"),
      @chart.field("val"),
      title="T",
      color=@chart.field("grp"),
    ),
  )
  assert_true((Ok(@json.parse(spec)) catch { e => Err(e) }) is Ok(Object(_)))
}

// ── format_vega_lite: column validation (fixed channel order) ───────

///|
test "format_vega_lite: an unknown x column raises ColumnNotFound first" {
  // Both x and y are absent; x is resolved first, so its name surfaces.
  let df = catval_df()
  assert_eq(
    Ok(
      @chart.format_vega_lite(
        df,
        @chart.ChartSpec::bar(@chart.field("nox"), @chart.field("noy")),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nox")),
  )
}

///|
test "format_vega_lite: an unknown y column raises ColumnNotFound" {
  let df = catval_df()
  assert_eq(
    Ok(
      @chart.format_vega_lite(
        df,
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("noy")),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("noy")),
  )
}

///|
test "format_vega_lite: an unknown color column raises ColumnNotFound" {
  let df = catval_df()
  assert_eq(
    Ok(
      @chart.format_vega_lite(
        df,
        @chart.ChartSpec::bar(
          @chart.field("cat"),
          @chart.field("val"),
          color=@chart.field("nocolor"),
        ),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nocolor")),
  )
}

///|
test "format_vega_lite: y is validated before the color column" {
  // y is missing and color is missing; y is resolved first, so the error
  // names y — pinning the x → y → color head of the resolution order.
  let df = catval_df()
  assert_eq(
    Ok(
      @chart.format_vega_lite(
        df,
        @chart.ChartSpec::bar(
          @chart.field("cat"),
          @chart.field("noy"),
          color=@chart.field("nocolor"),
        ),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("noy")),
  )
}

///|
test "format_vega_lite: color is validated before the size column" {
  // color is missing and size is missing; color is resolved first, so the
  // error names color — pinning the color → size stretch of the order.
  let df = catvalgrp_df()
  assert_eq(
    Ok(
      @chart.format_vega_lite(
        df,
        @chart.ChartSpec::bar(
          @chart.field("cat"),
          @chart.field("val"),
          color=@chart.field("nocolor"),
          size=@chart.field("nosize"),
        ),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nocolor")),
  )
}

// ── write_vega_lite: filesystem path ────────────────────────────────

///|
test "write_vega_lite writes the spec to disk verbatim" {
  let path = "_build/io_chart_test_write.json"
  let df = catval_df()
  let spec = @chart.ChartSpec::bar(
    @chart.field("cat"),
    @chart.field("val"),
    title="Disk",
  )
  @chart.write_vega_lite(path, df, spec)
  // The file holds exactly what `format_vega_lite` produces.
  let on_disk = @fs.read_file_to_string(path)
  assert_eq(on_disk, @chart.format_vega_lite(df, spec))
}

///|
test "write_vega_lite: invalid path surfaces as IoError" {
  // Aim the writer at a directory that doesn't exist so the underlying
  // `@fs` call fails; the `IOError` is promoted to `DataError::IoError`
  // (same shape as the JSON / CSV writer error tests).
  let df = catval_df()
  let result = Ok(
    @chart.write_vega_lite(
      "_build/no_such_dir_io_chart_test/file.json",
      df,
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}

///|
test "a Date channel encodes as temporal" {
  // A Date x-axis is a time scale, not a nominal category: the dtype registry's
  // Date row drives the Vega type through the frame's column dtype.
  let df = @frame.DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("v", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Date(19723L), @types.Scalar::Int(1)],
      [@types.Scalar::Date(19724L), @types.Scalar::Int(2)],
    ],
  )
  let json = @chart.format_vega_lite(
    df,
    @chart.ChartSpec::line(@chart.field("d"), @chart.field("v")),
  )
  assert_true(json.contains("\"type\":\"temporal\""))
  // `temporal` is only correct if the data cells are ISO date strings — that
  // is the cross-package half of the contract (the JSON records' date
  // mapping), and a change to the unit spelling would leave the `"type"`
  // assertion green while Vega silently stops reading the dates. Pin the
  // units too.
  assert_true(json.contains("\"d\":\"2024-01-01\""))
  assert_true(json.contains("\"d\":\"2024-01-02\""))
}

///|
test "a Duration channel encodes as temporal" {
  // The temporal arm of the dtype rule has three dtypes; a Duration
  // column rides the same `temporal` verdict as Date and Timestamp.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_duration_options("dur", [Some(3600_000_000_000L)]),
    @series.Series::from_ints("val", [1]),
  ])
  let spec = @chart.format_vega_lite(
    df,
    @chart.ChartSpec::line(@chart.field("dur"), @chart.field("val")),
  )
  assert_eq(channel_key(spec, "x", "type"), "temporal")
}

///|
/// One key of one channel, parsed out of the emitted spec: a string key
/// reads back verbatim, a boolean key as `"true"` / `"false"`, and an
/// absent key (a count channel's `field`) as `"<missing>"`.
fn channel_key(spec : String, channel : String, key : String) -> String {
  let parsed = @json.parse(spec) catch { _ => return "<missing>" }
  match parsed {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get(channel) {
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
    _ => "<missing>"
  }
}

///|
test "format_vega_lite: a Timestamp axis is temporal, a Decimal measure quantitative" {
  // The rider dtype rule: a `Timestamp` column serialises to its ISO
  // string, and Vega-Lite orders a temporal axis by time rather than by
  // first appearance; a `Decimal` measure is a quantity, not a category.
  let ts_df = @frame.DataFrame::DataFrame([
    @series.Series::from_timestamp_options("ts", [
      Some(1_704_067_200_000_000L),
      Some(1_704_075_840_000_000L),
    ]),
    @series.Series::from_ints("val", [1, 2]),
  ])
  let ts_spec = @chart.format_vega_lite(
    ts_df,
    @chart.ChartSpec::line(@chart.field("ts"), @chart.field("val")),
  )
  assert_eq(channel_key(ts_spec, "x", "type"), "temporal")
  assert_eq(channel_key(ts_spec, "y", "type"), "quantitative")
  let dec_df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_decimal_options(2, "val", [Some(150L)]),
  ])
  let dec_spec = @chart.format_vega_lite(
    dec_df,
    @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
  )
  assert_eq(channel_key(dec_spec, "y", "type"), "quantitative")
}

///|
test "format_vega_lite: brackets and a trailing backslash in a column name are escaped" {
  // Bracket access is Vega's array indexing, so an unescaped `[` changes
  // the field from a name to an index expression; and a name ending in a
  // backslash is the boundary case of escaping the escape character
  // itself. Six characters are escaped in total (`\ . [ ] ' "`) — these
  // pin the two the dot / quote tests leave unnamed.
  let bracket = "a[0].b"
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints(bracket, [1]),
    @series.Series::from_ints("trail\\", [2]),
  ])
  let spec = @chart.format_vega_lite(
    df,
    @chart.ChartSpec::bar(@chart.field("cat"), @chart.field(bracket)),
  )
  let field = match @json.parse(spec) {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("y") {
            Some(Object(y)) =>
              match y.get("field") {
                Some(String(f)) => f
                _ => "<missing>"
              }
            _ => "<missing>"
          }
        _ => "<missing>"
      }
    _ => "<missing>"
  }
  assert_eq(field, "a\\[0\\]\\.b")
  let spec2 = @chart.format_vega_lite(
    df,
    @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("trail\\")),
  )
  let field2 = match @json.parse(spec2) {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("y") {
            Some(Object(y)) =>
              match y.get("field") {
                Some(String(f)) => f
                _ => "<missing>"
              }
            _ => "<missing>"
          }
        _ => "<missing>"
      }
    _ => "<missing>"
  }
  assert_eq(field2, "trail\\\\")
}
