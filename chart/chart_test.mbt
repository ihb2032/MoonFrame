// Blackbox tests for `@chart.format_vega_lite` / `@chart.write_vega_lite`
// and the `ChartKind` / `VegaChannel` / `ChartSpec` builders.
//
// The renderer assembles a Vega-Lite v6 spec through the builtin `@json`,
// so these tests pin the *spec layout* MoonFrame imposes — `$schema` /
// chrome (`name` / `description` / `title` / `autosize` / `background` /
// `padding` / `width` / `height`) / `mark` / `encoding` (field + inferred
// `type` + the channel's declared modifiers) / inlined `data.values` —
// plus the column-name validation (`ColumnNotFound`, in the `ChartSpec`
// doc's fixed channel order) and the cell conventions inherited from
// `format_json` (null / non-finite floats → JSON `null`). One test parses
// the output back with `@json.parse` to self-certify it is well-formed
// JSON; the corpus test beside this one additionally walks every emitted
// corpus spec against the vendored schema.
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
test "format_vega_lite: bar chart emits a complete Vega-Lite v6 spec" {
  // The canonical case pins the whole shape: pinned `$schema`, `mark`,
  // both encoding channels (nominal x / quantitative y, inferred from the
  // column dtypes), and the frame inlined as `data.values`.
  inspect(
    @chart.format_vega_lite(
      catval_df(),
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
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
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("it's \"q\"")),
    ),
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
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("price.usd")),
        ),
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
  // type. Covers all five VegaType variants — geojson never comes from
  // inference, only from an override.
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
    (@chart.VegaType::Geojson, "geojson"),
  ]
  for case in cases {
    let (vt, expected) = case
    let spec = @chart.format_vega_lite(
      df,
      @chart.Chart::of(
        @chart.ChartSpec::point(
          @chart.field("cat"),
          @chart.field("val"),
          color=@chart.field("g", type_override=vt),
        ),
      ),
    )
    assert_eq(channel_key(spec, "color", "type"), expected)
  }
}

///|
test "format_vega_lite: each ChartKind maps to its Vega-Lite mark" {
  // Parse the output and read the `mark` field back, so all seventeen
  // `ChartKind` arms are exercised without seventeen near-identical spec
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
      @chart.ChartSpec::image(
        @chart.field("cat"),
        @chart.field("val"),
        @chart.field("cat"),
      ),
      "image",
    ),
    (@chart.ChartSpec::geoshape(@chart.field("cat")), "geoshape"),
    (
      @chart.ChartSpec::boxplot(@chart.field("cat"), @chart.field("val")),
      "boxplot",
    ),
    (
      @chart.ChartSpec::errorbar(
        @chart.field("cat"),
        @chart.field("val"),
        y_error=@chart.field("val"),
      ),
      "errorbar",
    ),
    (
      @chart.ChartSpec::errorband(
        @chart.field("cat"),
        @chart.field("val"),
        y_error=@chart.field("val"),
      ),
      "errorband",
    ),
  ]
  for case in cases {
    let (spec, expected_mark) = case
    let mark = match
      @json.parse(@chart.format_vega_lite(df, @chart.Chart::of(spec))) {
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
      @chart.Chart::of(
        @chart.ChartSpec::bar(
          @chart.field("cat"),
          @chart.field("val"),
          title="Sales",
        ),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","title":"Sales","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
}

///|
test "format_vega_lite: the three width / height forms emit their own shapes" {
  // `Px` is a plain number, `Step` the `{"step": n}` object; both land
  // between `title` and `mark`, and unset sizes stay absent (the
  // canonical case has none).
  inspect(
    @chart.format_vega_lite(
      catval_df(),
      @chart.Chart::of(
        @chart.ChartSpec::bar(
          @chart.field("cat"),
          @chart.field("val"),
          title="Sales",
          width=@chart.VegaExtent::Px(320),
          height=@chart.VegaExtent::Step(24),
        ),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","title":"Sales","width":320,"height":{"step":24},"mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
  let container = @chart.format_vega_lite(
    catval_df(),
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        width=@chart.VegaExtent::Container,
      ),
    ),
  )
  let width = match @json.parse(container) {
    Object(obj) =>
      match obj.get("width") {
        Some(String(w)) => w
        _ => "<missing>"
      }
    _ => "<missing>"
  }
  assert_eq(width, "container")
}

///|
test "format_vega_lite: the top-level chrome emits in its fixed order" {
  // `name`, `description`, `title`, `autosize`, `background`, `padding`
  // — one spec carrying all of them, `padding` in its per-side form with
  // two of four sides set.
  inspect(
    @chart.format_vega_lite(
      catval_df(),
      @chart.Chart::of(
        @chart.ChartSpec::of(
          @chart.ChartKind::Bar,
          x=@chart.field("cat"),
          y=@chart.field("val"),
          name="revenue-chart",
          description="Revenue by region",
          title=@chart.VegaTitle::Text("Revenue"),
          autosize=@chart.VegaAutoSize::FitX,
          background="#f8f8f8",
          padding=@chart.VegaPadding::Sides(
            @chart.VegaSides::VegaSides(top=10, left=5),
          ),
        ),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","name":"revenue-chart","description":"Revenue by region","title":"Revenue","autosize":"fit-x","background":"#f8f8f8","padding":{"top":10,"left":5},"mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
}

///|
test "format_vega_lite: color adds a color encoding channel" {
  inspect(
    @chart.format_vega_lite(
      catvalgrp_df(),
      @chart.Chart::of(
        @chart.ChartSpec::bar(
          @chart.field("cat"),
          @chart.field("val"),
          color=@chart.field("grp"),
        ),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"color":{"field":"grp","type":"nominal"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: size, opacity, tooltip, and detail channels follow color" {
  // The four channels a `point` commonly adds, one spec — the emission
  // order matches the fixed resolution order (size, opacity, tooltip,
  // detail after color, which this spec leaves unset).
  inspect(
    @chart.format_vega_lite(
      catvalgrp_df(),
      @chart.Chart::of(
        @chart.ChartSpec::point(
          @chart.field("cat"),
          @chart.field("val"),
          size=@chart.field("val"),
          opacity=@chart.field("val"),
          tooltip=@chart.field("grp"),
          detail=@chart.field("grp"),
        ),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"point","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"opacity":{"field":"val","type":"quantitative"},"size":{"field":"val","type":"quantitative"},"tooltip":{"field":"grp","type":"nominal"},"detail":{"field":"grp","type":"nominal"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: x2 and y2 emit the ranged-mark end channels" {
  inspect(
    @chart.format_vega_lite(
      catvalgrp_df(),
      @chart.Chart::of(
        @chart.ChartSpec::rect(
          @chart.field("cat"),
          @chart.field("val"),
          x2=@chart.field("grp"),
          y2=@chart.field("val"),
        ),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"rect","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"x2":{"field":"grp"},"y2":{"field":"val"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: the error, offset, geo, and prop channels ride ChartSpec::of" {
  // The channels no mark-named constructor carries — error bars' four,
  // the offsets, the geo pair, the fill / stroke family, and the v6
  // `time` channel — emitted by the general constructor, one key each.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("val", [1]),
    @series.Series::from_ints("err", [1]),
    @series.Series::from_floats("lon", [1.5]),
    @series.Series::from_floats("lat", [1.5]),
    @series.Series::from_timestamp_options("ts", [Some(1_704_067_200_000_000L)]),
  ])
  let spec = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field("cat"),
        y=@chart.field("val"),
        x_error=@chart.field("err"),
        x_error2=@chart.field("err"),
        y_error=@chart.field("err"),
        y_error2=@chart.field("err"),
        x_offset=@chart.field("err"),
        y_offset=@chart.field("err"),
        longitude=@chart.field("lon"),
        latitude=@chart.field("lat"),
        fill=@chart.field("cat"),
        stroke=@chart.field("cat"),
        fill_opacity=@chart.field("val"),
        stroke_opacity=@chart.field("val"),
        stroke_width=@chart.field("val"),
        stroke_dash=@chart.field("val"),
        shape=@chart.field("cat"),
        angle=@chart.field("val"),
        time=@chart.field("ts"),
        href=@chart.field("cat"),
        url=@chart.field("cat"),
        description_channel=@chart.field("cat"),
        key=@chart.field("cat"),
        order=@chart.field("val"),
      ),
    ),
  )
  let encoding = match @json.parse(spec) {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) => enc
        _ => Map([])
      }
    _ => Map([])
  }
  // Every channel the spec named is present, under its Vega key.
  let keys = [
    "xError", "xError2", "yError", "yError2", "xOffset", "yOffset", "longitude",
    "latitude", "fill", "stroke", "fillOpacity", "strokeOpacity", "strokeWidth",
    "strokeDash", "shape", "angle", "time", "href", "url", "description", "key",
    "order",
  ]
  for key in keys {
    assert_true(encoding.get(key) is Some(Object(_)))
  }
  // The ts column drives the time channel's temporal inference.
  assert_eq(channel_key(spec, "time", "type"), "temporal")
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
      @chart.Chart::of(
        @chart.ChartSpec::point(@chart.field("ratio"), @chart.field("flag")),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"point","encoding":{"x":{"field":"ratio","type":"quantitative"},"y":{"field":"flag","type":"nominal"}},"data":{"values":[{"ratio":1.5,"flag":true}]}}
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
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("label"), @chart.field("amount")),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"bar","encoding":{"x":{"field":"label","type":"nominal"},"y":{"field":"amount","type":"quantitative"}},"data":{"values":[{"label":"a","amount":1.5},{"label":"b","amount":null},{"label":"c","amount":null},{"label":"d","amount":null}]}}
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
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
      ),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v6.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[]}}
    ),
  )
}

///|
test "format_vega_lite: output is well-formed JSON (parses back to an object)" {
  // The most complex spec (title + color) round-trips through the builtin
  // JSON reader, self-certifying it is a legal Vega-Lite v6 document.
  let spec = @chart.format_vega_lite(
    catvalgrp_df(),
    @chart.Chart::of(
      @chart.ChartSpec::area(
        @chart.field("cat"),
        @chart.field("val"),
        title="T",
        color=@chart.field("grp"),
      ),
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
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("nox"), @chart.field("noy")),
        ),
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
        @chart.Chart::of(
          @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("noy")),
        ),
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
        @chart.Chart::of(
          @chart.ChartSpec::bar(
            @chart.field("cat"),
            @chart.field("val"),
            color=@chart.field("nocolor"),
          ),
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
        @chart.Chart::of(
          @chart.ChartSpec::bar(
            @chart.field("cat"),
            @chart.field("noy"),
            color=@chart.field("nocolor"),
          ),
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
        @chart.Chart::of(
          @chart.ChartSpec::bar(
            @chart.field("cat"),
            @chart.field("val"),
            color=@chart.field("nocolor"),
            size=@chart.field("nosize"),
          ),
        ),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nocolor")),
  )
}

///|
test "format_vega_lite: an unknown detail column raises after size and opacity" {
  // detail resolves after size / opacity in the fixed order — the deepest
  // channel a mark-named constructor carries.
  let df = catvalgrp_df()
  assert_eq(
    Ok(
      @chart.format_vega_lite(
        df,
        @chart.Chart::of(
          @chart.ChartSpec::line(
            @chart.field("cat"),
            @chart.field("val"),
            size=@chart.field("val"),
            opacity=@chart.field("val"),
            detail=@chart.field("nodetail"),
          ),
        ),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nodetail")),
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
  @chart.write_vega_lite(path, df, @chart.Chart::of(spec))
  // The file holds exactly what `format_vega_lite` produces.
  let on_disk = @fs.read_file_to_string(path)
  assert_eq(on_disk, @chart.format_vega_lite(df, @chart.Chart::of(spec)))
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
      @chart.Chart::of(
        @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
      ),
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
    @chart.Chart::of(
      @chart.ChartSpec::line(@chart.field("d"), @chart.field("v")),
    ),
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
test "a Duration channel encodes as quantitative microseconds" {
  // A Duration column is quantitative, and its data.values cells leave
  // as microsecond counts: Vega's temporal has no ISO-duration parser,
  // so a temporal type would hand the runtime strings it cannot read.
  // Both halves move together — the type and the cell form.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_duration_options("dur", [Some(3600_000_000_000L), None]),
    @series.Series::from_ints("val", [1, 2]),
  ])
  let spec = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::line(@chart.field("dur"), @chart.field("val")),
    ),
  )
  assert_eq(channel_key(spec, "x", "type"), "quantitative")
  // The cell is the count, not the ISO spelling; a null cell stays null.
  assert_true(spec.contains("\"dur\":3600000000000"))
  assert_true(spec.contains("\"dur\":null"))
  assert_true(!spec.contains("PT1H"))
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
                Some(Number(n, ..)) => n.to_string()
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
    @chart.Chart::of(
      @chart.ChartSpec::line(@chart.field("ts"), @chart.field("val")),
    ),
  )
  assert_eq(channel_key(ts_spec, "x", "type"), "temporal")
  assert_eq(channel_key(ts_spec, "y", "type"), "quantitative")
  let dec_df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_decimal_options(2, "val", [Some(150L)]),
  ])
  let dec_spec = @chart.format_vega_lite(
    dec_df,
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("val")),
    ),
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
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field(bracket)),
    ),
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
    @chart.Chart::of(
      @chart.ChartSpec::bar(@chart.field("cat"), @chart.field("trail\\")),
    ),
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

///|
test "a dotted column name escapes through every field reference" {
  // The escaping contract: an encoding `field` escapes (established),
  // and so does every other reference to the same column — a facet
  // channel, a repeat list, a predicate's comparison field, a
  // transform's group-by, an aggregate's input, and a by-field sort.
  // Output names (`as`) do not escape: they name the new field.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("a.b", ["x", "y"]),
    @series.Series::from_strings("c[0]", ["1", "2"]),
    @series.Series::from_ints("val", [1, 2]),
  ])
  let spec = @chart.format_vega_lite(
    df,
    @chart.Chart::of(
      @chart.ChartSpec::of(
        @chart.ChartKind::Point,
        x=@chart.field(
          "a.b",
          sort=@chart.VegaChannelSort::ByField("c[0]", None),
        ),
        y=@chart.field("val"),
        transform=[
          @chart.VegaTransform::Filter(
            @chart.VegaFilterTransform::VegaFilterTransform(
              filter=@chart.VegaPredicate::Equal("a.b", Json::string("x"), None),
            ),
          ),
          @chart.VegaTransform::Aggregate(
            @chart.VegaAggregateTransform::VegaAggregateTransform(
              aggregate=[
                @chart.VegaAggField::VegaAggField(
                  op=@chart.VegaAggregate::Sum,
                  field="val",
                  as_="total",
                ),
              ],
              groupby=["a.b", "c[0]"],
            ),
          ),
        ],
      ),
    ),
  )
  // The emitted JSON text carries the backslash-escaped spelling (the
  // stringifier doubles the backslash); the parsed values read back as
  // the single-escaped field name.
  let parsed = @json.parse(spec) catch { _ => Json::null() }
  let x_field = match parsed {
    Object(obj) =>
      match obj.get("encoding") {
        Some(Object(enc)) =>
          match enc.get("x") {
            Some(Object(c)) =>
              match c.get("field") {
                Some(f) => f
                _ => Json::null()
              }
            _ => Json::null()
          }
        _ => Json::null()
      }
    _ => Json::null()
  }
  assert_eq(x_field, Json::string("a\\.b"))
  assert_true(spec.contains("\"groupby\":[\"a\\\\.b\",\"c\\\\[0\\\\]\"]"))
  assert_true(spec.contains("\"sort\":{\"field\":\"c\\\\[0\\\\]\"}"))
  assert_true(spec.contains("\"field\":\"a\\\\.b\",\"equal\":\"x\""))
  // The output name is emitted as written, unescaped.
  assert_true(spec.contains("\"as\":\"total\""))
  // And the record keys stay the raw column names — only references
  // escape, never the data itself.
  assert_true(spec.contains("\"a.b\":\"x\""))
  // The facet and repeat paths escape the same way.
  let faceted = @chart.format_vega_lite(
    df,
    @chart.Chart::Facet(
      @chart.VegaFacet::VegaFacet(
        @chart.Chart::of(
          @chart.ChartSpec::point(@chart.field("val"), @chart.field("val")),
        ),
        row=@chart.VegaFacetChannel::VegaFacetChannel(field="a.b"),
      ),
    ),
  )
  assert_true(faceted.contains("\"row\":{\"field\":\"a\\\\.b\""))
  let repeated = @chart.format_vega_lite(
    df,
    @chart.Chart::Repeat(
      @chart.VegaRepeat::VegaRepeat(
        @chart.Chart::of(
          @chart.ChartSpec::line(@chart.field("val"), @chart.field("val")),
        ),
        column=["a.b", "c[0]"],
      ),
    ),
  )
  assert_true(repeated.contains("\"column\":[\"a\\\\.b\",\"c\\\\[0\\\\]\"]"))
}
