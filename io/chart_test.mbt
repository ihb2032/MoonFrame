// Blackbox tests for `@io.format_vega_lite` / `@io.write_vega_lite` and
// the `ChartKind` / `ChartSpec` builders.
//
// The renderer assembles a Vega-Lite v5 spec through the builtin `@json`,
// so these tests pin the *spec layout* MoonFrame imposes — `$schema` /
// `title` / `mark` / `encoding` (field + inferred `type`) / inlined
// `data.values` — plus the column-name validation (`ColumnNotFound`,
// left-to-right) and the cell conventions inherited from
// `format_json_records` (null / non-finite floats → JSON `null`). One
// test parses the output back with `@json.parse` to self-certify it is
// well-formed JSON.
//
// `id_double` (defeats constant folding for the non-finite-float test) is
// defined in `json_test.mbt` and shared across this package's blackbox
// tests.

///|
/// Two-column fixture: a nominal `cat` (`String`) and a quantitative
/// `val` (`Int`), single row — the smallest frame that exercises both
/// encoding-`type` branches.
fn catval_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("val", [1]),
  ])
}

///|
/// Three-column fixture adding a `grp` (`String`) column for the `color`
/// encoding.
fn catvalgrp_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
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
    @io.format_vega_lite(catval_df(), @io.ChartSpec::bar("cat", "val")),
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
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("it's \"q\"", [1]),
  ])
  let spec = @io.format_vega_lite(df, @io.ChartSpec::bar("cat", "it's \"q\""))
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
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("price.usd", [1]),
  ])
  let field = match
    @json.parse(
      @io.format_vega_lite(df, @io.ChartSpec::bar("cat", "price.usd")),
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
test "format_vega_lite: color_type overrides the color channel's field type" {
  // A numeric grouping column ("g") would infer `quantitative` (a continuous
  // gradient); color_type forces the chosen type. Covers all four
  // VegaType variants.
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("cat", ["x"]),
    @series.Series::from_ints("val", [1]),
    @series.Series::from_ints("g", [1]),
  ])
  let cases = [
    (@io.VegaType::Quantitative, "quantitative"),
    (@io.VegaType::Nominal, "nominal"),
    (@io.VegaType::Ordinal, "ordinal"),
    (@io.VegaType::Temporal, "temporal"),
  ]
  for case in cases {
    let (vt, expected) = case
    let spec = @io.ChartSpec::point("cat", "val", color="g", color_type=vt)
    let got = match @json.parse(@io.format_vega_lite(df, spec)) {
      Object(obj) =>
        match obj.get("encoding") {
          Some(Object(enc)) =>
            match enc.get("color") {
              Some(Object(c)) =>
                match c.get("type") {
                  Some(String(t)) => t
                  _ => "<missing>"
                }
              _ => "<missing>"
            }
          _ => "<missing>"
        }
      _ => "<missing>"
    }
    assert_eq(got, expected)
  }
}

///|
test "format_vega_lite: each ChartKind maps to its Vega-Lite mark" {
  // Parse the output and read the `mark` field back, so all four
  // `ChartKind` arms are exercised without four near-identical spec
  // strings — and the parse doubles as a well-formedness check.
  let df = catval_df()
  let cases = [
    (@io.ChartSpec::bar("cat", "val"), "bar"),
    (@io.ChartSpec::line("cat", "val"), "line"),
    (@io.ChartSpec::point("cat", "val"), "point"),
    (@io.ChartSpec::area("cat", "val"), "area"),
  ]
  for case in cases {
    let (spec, expected_mark) = case
    let mark = match @json.parse(@io.format_vega_lite(df, spec)) {
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
    @io.format_vega_lite(
      catval_df(),
      @io.ChartSpec::bar("cat", "val", title="Sales"),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","title":"Sales","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[{"cat":"x","val":1}]}}
    ),
  )
}

///|
test "format_vega_lite: color adds a color encoding channel" {
  inspect(
    @io.format_vega_lite(
      catvalgrp_df(),
      @io.ChartSpec::bar("cat", "val", color="grp"),
    ),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"},"color":{"field":"grp","type":"nominal"}},"data":{"values":[{"cat":"x","val":1,"grp":"a"}]}}
    ),
  )
}

///|
test "format_vega_lite: field type follows column dtype (Float→quantitative, Bool→nominal)" {
  // Complements the canonical case (Int→quantitative, String→nominal): a
  // Float column is quantitative and a Bool column is nominal.
  let df = @frame.DataFrame::new([
    @series.Series::from_floats("ratio", [1.5]),
    @series.Series::from_bools("flag", [true]),
  ])
  inspect(
    @io.format_vega_lite(df, @io.ChartSpec::point("ratio", "flag")),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"point","encoding":{"x":{"field":"ratio","type":"quantitative"},"y":{"field":"flag","type":"nominal"}},"data":{"values":[{"ratio":1.5,"flag":true}]}}
    ),
  )
}

///|
test "format_vega_lite: null and non-finite float cells become JSON null" {
  // `data.values` reuses `format_json_records`' cell mapping: an explicit
  // null, and a non-finite Float (±Infinity / NaN, which have no JSON
  // literal), all render as `null`.
  let inf = id_double(1.0) / id_double(0.0)
  let nan = id_double(0.0) / id_double(0.0)
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("label", ["a", "b", "c", "d"]),
    @series.Series::from_float_options("amount", [
      Some(1.5),
      None,
      Some(inf),
      Some(nan),
    ]),
  ])
  inspect(
    @io.format_vega_lite(df, @io.ChartSpec::bar("label", "amount")),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"label","type":"nominal"},"y":{"field":"amount","type":"quantitative"}},"data":{"values":[{"label":"a","amount":1.5},{"label":"b","amount":null},{"label":"c","amount":null},{"label":"d","amount":null}]}}
    ),
  )
}

///|
test "format_vega_lite: a frame with columns but no rows yields empty data.values" {
  let schema = @types.Schema::new([
    @types.Field("cat", @types.DataType::String),
    @types.Field("val", @types.DataType::Int),
  ])
  let empty = @frame.DataFrame::empty(schema)
  inspect(
    @io.format_vega_lite(empty, @io.ChartSpec::bar("cat", "val")),
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","mark":"bar","encoding":{"x":{"field":"cat","type":"nominal"},"y":{"field":"val","type":"quantitative"}},"data":{"values":[]}}
    ),
  )
}

///|
test "format_vega_lite: output is well-formed JSON (parses back to an object)" {
  // The most complex spec (title + color) round-trips through the builtin
  // JSON reader, self-certifying it is a legal Vega-Lite v5 document.
  let spec = @io.format_vega_lite(
    catvalgrp_df(),
    @io.ChartSpec::area("cat", "val", title="T", color="grp"),
  )
  assert_true((Ok(@json.parse(spec)) catch { e => Err(e) }) is Ok(Object(_)))
}

// ── format_vega_lite: column validation (left-to-right) ─────────────

///|
test "format_vega_lite: an unknown x column raises ColumnNotFound first" {
  // Both x and y are absent; x is resolved first, so its name surfaces.
  let df = catval_df()
  assert_eq(
    Ok(@io.format_vega_lite(df, @io.ChartSpec::bar("nox", "noy"))) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nox")),
  )
}

///|
test "format_vega_lite: an unknown y column raises ColumnNotFound" {
  let df = catval_df()
  assert_eq(
    Ok(@io.format_vega_lite(df, @io.ChartSpec::bar("cat", "noy"))) catch {
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
      @io.format_vega_lite(
        df,
        @io.ChartSpec::bar("cat", "val", color="nocolor"),
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
  // names y — pinning the x → y → color resolution order.
  let df = catval_df()
  assert_eq(
    Ok(
      @io.format_vega_lite(
        df,
        @io.ChartSpec::bar("cat", "noy", color="nocolor"),
      ),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("noy")),
  )
}

// ── write_vega_lite: filesystem path ────────────────────────────────

///|
test "write_vega_lite writes the spec to disk verbatim" {
  let path = "_build/io_chart_test_write.json"
  let df = catval_df()
  let spec = @io.ChartSpec::bar("cat", "val", title="Disk")
  @io.write_vega_lite(path, df, spec)
  // The file holds exactly what `format_vega_lite` produces.
  let on_disk = @fs.read_file_to_string(path)
  assert_eq(on_disk, @io.format_vega_lite(df, spec))
}

///|
test "write_vega_lite: invalid path surfaces as IoError" {
  // Aim the writer at a directory that doesn't exist so the underlying
  // `@fs` call fails; the `IOError` is promoted to `DataError::IoError`
  // (same shape as the JSON / CSV writer error tests).
  let df = catval_df()
  let result = Ok(
    @io.write_vega_lite(
      "_build/no_such_dir_io_chart_test/file.json",
      df,
      @io.ChartSpec::bar("cat", "val"),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::IoError(_)))
}
