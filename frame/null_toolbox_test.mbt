// Blackbox tests for the null / NaN toolbox additions: the directional
// fills (`fill_null_forward` / `_backward`, `limit?` capping consecutive
// slots), the frame-wide `fill_nan`, and the expression probes `is_finite`
// / `is_infinite` and the `clip` clamp. Evaluated eagerly and (for the
// frame verbs) through the lazy mirrors.

///|
/// Forward fill: leading nulls stay, the nearest present value above fills
/// the rest; `limit` caps the consecutive slots one value may fill.
test "forward_fill takes the value above, honoring the limit" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [
      None,
      Some(1),
      None,
      None,
      None,
      Some(5),
      None,
    ]),
  ])
  let filled = df.fill_null_forward()
  // The fill verbs rebuild a frame; the shape invariants ride the
  // representative outputs.
  assert_eq(filled.check_invariants(), Ok(()))
  assert_eq(filled.get_column("v").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(5),
    @types.Scalar::Int(5),
  ])
  // limit = 2: the three-slot gap after the 1 keeps its tail null.
  assert_eq(df.fill_null_forward(limit=2).get_column("v").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Null,
    @types.Scalar::Int(5),
    @types.Scalar::Int(5),
  ])
  // A limit below 1 raises.
  assert_true(
    (Ok(df.fill_null_forward(limit=0)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "backward_fill is the mirror; strings fill too" {
  let df = DataFrame::DataFrame([
    Series::from_string_options("s", [Some("a"), None, None, Some("d"), None]),
  ])
  assert_eq(df.fill_null_backward().get_column("s").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("d"),
    @types.Scalar::String("d"),
    @types.Scalar::String("d"),
    @types.Scalar::Null,
  ])
  // A column with no nulls passes through untouched.
  let full = DataFrame::DataFrame([Series::from_ints("i", [1, 2])])
  assert_eq(full.fill_null_backward(), full)
}

///|
test "the expression fills mirror the frame verbs, per column" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [None, Some(2), None, Some(4)]),
  ])
  assert_eq(
    df.select([@expr.col("v").forward_fill()]).get_column("v").to_scalars(),
    [
      @types.Scalar::Null,
      @types.Scalar::Int(2),
      @types.Scalar::Int(2),
      @types.Scalar::Int(4),
    ],
  )
  assert_eq(
    df.select([@expr.col("v").backward_fill()]).get_column("v").to_scalars(),
    [
      @types.Scalar::Int(2),
      @types.Scalar::Int(2),
      @types.Scalar::Int(4),
      @types.Scalar::Int(4),
    ],
  )
}

///|
test "fill_nan replaces NaN in Float columns and nothing else" {
  let nan : Double = @double.not_a_number
  let df = DataFrame::DataFrame([
    // A NaN and a null side by side: the NaN replaces, the null is missing,
    // not NaN, and passes through.
    Series::from_float_options("f", [Some(1.0), Some(nan), None]),
    Series::from_ints("i", [1, 2, 3]),
  ])
  let r = df.fill_nan(9.0)
  assert_eq(r.get_column("f").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(9.0),
    @types.Scalar::Null,
  ])
  assert_eq(r.get_column("i").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
}

///|
test "is_finite / is_infinite split NaN, infinity, and the rest" {
  let inf : Double = @double.infinity
  let nan : Double = @double.not_a_number
  let df = DataFrame::DataFrame([
    Series::from_float_options("f", [Some(1.0), Some(nan), Some(inf), None]),
  ])
  assert_eq(
    df.select([@expr.col("f").is_finite()]).get_column("f").to_scalars(),
    [
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(false),
      @types.Scalar::Null,
    ],
  )
  assert_eq(
    df.select([@expr.col("f").is_infinite()]).get_column("f").to_scalars(),
    [
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(true),
      @types.Scalar::Null,
    ],
  )
  // An Int cell is always finite, never infinite; a String operand raises.
  let i = DataFrame::DataFrame([Series::from_ints("i", [3])])
  assert_eq(
    i.select([@expr.col("i").is_finite()]).get_column("i").to_scalars(),
    [@types.Scalar::Bool(true)],
  )
  assert_eq(
    i.select([@expr.col("i").is_infinite()]).get_column("i").to_scalars(),
    [@types.Scalar::Bool(false)],
  )
  let s = DataFrame::DataFrame([Series::from_strings("s", ["a"])])
  assert_true(
    (Ok(s.select([@expr.col("s").is_finite()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  assert_true(
    (Ok(s.select([@expr.col("s").is_infinite()])) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  // A nullable Int column keeps its nulls under the probe (the `Builtin`
  // arm).
  let ni = DataFrame::DataFrame([Series::from_int_options("i", [Some(1), None])])
  assert_eq(
    ni.select([@expr.col("i").is_finite()]).get_column("i").to_scalars(),
    [@types.Scalar::Bool(true), @types.Scalar::Null],
  )
  // An all-valid Float column takes the numeric fast path.
  let fast = DataFrame::DataFrame([Series::from_floats("f", [1.0, inf])])
  assert_eq(
    fast.select([@expr.col("f").is_finite()]).get_column("f").to_scalars(),
    [@types.Scalar::Bool(true), @types.Scalar::Bool(false)],
  )
}

///|
test "clip clamps into the bounds, nulls and NaN passing through" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(1), Some(5), Some(9), None]),
  ])
  assert_eq(
    df
    .select([
      @expr.col("v").clip(lower=@expr.lit_int(2), upper=@expr.lit_int(7)),
    ])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(2),
      @types.Scalar::Int(5),
      @types.Scalar::Int(7),
      @types.Scalar::Null,
    ],
  )
  // One-sided clamps; both omitted is the identity.
  assert_eq(
    df
    .select([@expr.col("v").clip(lower=@expr.lit_int(3))])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(3),
      @types.Scalar::Int(5),
      @types.Scalar::Int(9),
      @types.Scalar::Null,
    ],
  )
  assert_eq(
    df.select([@expr.col("v").clip()]).get_column("v").to_scalars(),
    df.get_column("v").to_scalars(),
  )
  // A Float bound promotes; a NaN cell compares false against both bounds
  // and passes through.
  let nan : Double = @double.not_a_number
  let f = DataFrame::DataFrame([Series::from_floats("f", [0.5, nan, 4.0])])
  let clamped = f
    .select([@expr.col("f").clip(upper=@expr.lit_float(3.0))])
    .get_column("f")
    .to_scalars()
  assert_eq(clamped[0], @types.Scalar::Float(0.5))
  assert_true(clamped[1] is @types.Scalar::Float(v) && v.is_nan())
  assert_eq(clamped[2], @types.Scalar::Float(3.0))
}

///|
test "clip with a degenerate pair clamps everything to the upper bound" {
  // `lower` above `upper`: every cell is lifted then pressed back down,
  // so the whole column lands on `upper`. A null cell still passes through
  // untouched.
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(1), Some(5), Some(9), None]),
  ])
  assert_eq(
    df
    .select([
      @expr.col("v").clip(lower=@expr.lit_int(7), upper=@expr.lit_int(3)),
    ])
    .get_column("v")
    .to_scalars(),
    [
      @types.Scalar::Int(3),
      @types.Scalar::Int(3),
      @types.Scalar::Int(3),
      @types.Scalar::Null,
    ],
  )
  // The degenerate Float pair keeps a NaN cell in place: no comparison
  // holds against it on either pass.
  let nan : Double = @double.not_a_number
  let f = DataFrame::DataFrame([Series::from_floats("f", [0.5, nan, 4.0])])
  let clamped = f
    .select([
      @expr.col("f").clip(
        lower=@expr.lit_float(3.0),
        upper=@expr.lit_float(1.0),
      ),
    ])
    .get_column("f")
    .to_scalars()
  assert_eq(clamped[0], @types.Scalar::Float(1.0))
  assert_true(clamped[1] is @types.Scalar::Float(v) && v.is_nan())
  assert_eq(clamped[2], @types.Scalar::Float(1.0))
}

///|

///|
test "backward_fill honors the limit like the forward mirror" {
  let df = DataFrame::DataFrame([
    Series::from_string_options("s", [Some("a"), None, None, Some("d"), None]),
  ])
  // limit = 1: only the slot adjacent to its source fills; the two-slot
  // gap past the "a" keeps its far end null, and the trailing run has no
  // source below it at all.
  assert_eq(df.fill_null_backward(limit=1).get_column("s").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::Null,
    @types.Scalar::String("d"),
    @types.Scalar::String("d"),
    @types.Scalar::Null,
  ])
}

///|
test "the frame fills validate the limit whatever the data" {
  // A frame whose columns carry no nulls still rejects a cap below 1 —
  // the expression form raises unconditionally, and the two surfaces agree.
  let full = DataFrame::DataFrame([Series::from_ints("i", [1, 2])])
  assert_true(
    (Ok(full.fill_null_forward(limit=0)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(full.fill_null_backward(limit=0)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "the expression fill raises from the kernel, surfaces agreeing" {
  // The expression path goes straight to the kernel (no frame-level
  // short-circuit), so this pins that both surfaces reject a cap below 1 —
  // and keeps the kernel's own check exercised.
  let df = DataFrame::DataFrame([Series::from_ints("i", [1, 2])])
  assert_true(
    (Ok(df.select([@expr.col("i").forward_fill(limit=0)])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "clip with a column bound keeps the operand's name and clamps it" {
  // The composition alone would name itself after the bound (it sits in
  // the `then` branch), handing `with_columns` the bound's name — the
  // bound column replaced by the clipped operand, the operand left
  // unclamped. The operand keeps its own name instead.
  let df = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("x", @types.DataType::Int),
      @types.Field::Field("z", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Int(5L), @types.Scalar::Int(7L)],
      [@types.Scalar::Int(9L), @types.Scalar::Int(7L)],
    ],
  )
  let out = df.with_columns([@expr.col("x").clip(upper=@expr.col("z"))])
  assert_true(out.columns().contains("x"))
  assert_true(out.columns().contains("z"))
  assert_eq(out.item(1, "x"), @types.Scalar::Int(7L))
  assert_eq(out.item(1, "z"), @types.Scalar::Int(7L))
}

///|
test "a null bound cell leaves the operand cell untouched" {
  // Clip's null-bound reading: a null bound is no bound on that side,
  // not a null answer — the old nested-`when` lowering propagated the
  // comparison's null into the selection and nulled a present operand cell.
  let df = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("x", @types.DataType::Int),
      @types.Field::Field("lo", @types.DataType::Int),
      @types.Field::Field("hi", @types.DataType::Int),
    ]),
    [
      // x below a present lo -> lifted; x inside against a null lo -> kept;
      // x above a present hi -> pressed; both bounds null -> kept.
      [@types.Scalar::Int(1L), @types.Scalar::Int(2L), @types.Scalar::Int(9L)],
      [@types.Scalar::Int(5L), @types.Scalar::Null, @types.Scalar::Int(9L)],
      [@types.Scalar::Int(9L), @types.Scalar::Int(2L), @types.Scalar::Int(7L)],
      [@types.Scalar::Int(4L), @types.Scalar::Null, @types.Scalar::Null],
    ],
  )
  let out = df.select([
    @expr.col("x").clip(lower=@expr.col("lo"), upper=@expr.col("hi")),
  ])
  assert_eq(out.item(0, "x"), @types.Scalar::Int(2L))
  assert_eq(out.item(1, "x"), @types.Scalar::Int(5L))
  assert_eq(out.item(2, "x"), @types.Scalar::Int(7L))
  assert_eq(out.item(3, "x"), @types.Scalar::Int(4L))
}

///|
test "a null operand cell stays null under either bound" {
  // The other half of the reading: the bounds are not applied to a null
  // operand cell — the Kleene chain keeps it null.
  let df = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("x", @types.DataType::Float),
      @types.Field::Field("lo", @types.DataType::Float),
    ]),
    [
      [@types.Scalar::Null, @types.Scalar::Float(1.0)],
      [@types.Scalar::Float(0.5), @types.Scalar::Float(1.0)],
    ],
  )
  let out = df.select([@expr.col("x").clip(lower=@expr.col("lo"))])
  assert_eq(out.item(0, "x"), @types.Scalar::Null)
  assert_eq(out.item(1, "x"), @types.Scalar::Float(1.0))
}

///|
test "clip's fast pass: Float columns, column bounds, and the mixed fall-through" {
  // A Float column with Float bounds rides the single-buffer pass —
  // including a per-row column bound (not a literal) and a null bound
  // cell, which means "no bound on that side" for that row alone.
  let df = DataFrame::DataFrame([
    Series::from_float_options("v", [Some(0.5), None, Some(9.5), Some(5.0)]),
    Series::from_float_options("lo", [Some(1.0), Some(1.0), None, Some(1.0)]),
  ])
  let out = df.select([
    @expr.col("v")
    .clip(lower=@expr.col("lo"), upper=@expr.lit_float(8.0))
    .with_alias("c"),
  ])
  // Row 0 lifts to 1.0; row 1's null operand stays null; row 2's null
  // lower bound passes 9.5 through and the upper presses it to 8.0; row 3
  // sits inside.
  assert_eq(out.get_column("c").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Null,
    @types.Scalar::Float(8.0),
    @types.Scalar::Float(5.0),
  ])
  // A NaN operand fails both comparisons and keeps its cell — the fast
  // pass and the composed kernels agree cell for cell.
  let nan : Double = @double.not_a_number
  let ndf = DataFrame::DataFrame([Series::from_floats("v", [nan, 0.0])])
  let nout = ndf.select([
    @expr.col("v")
    .clip(lower=@expr.lit_float(1.0), upper=@expr.lit_float(7.0))
    .with_alias("c"),
  ])
  let ncells = nout.get_column("c").to_scalars()
  assert_true(ncells[0] is @types.Scalar::Float(v) && v.is_nan())
  assert_eq(ncells[1], @types.Scalar::Float(1.0))
  // An Int column against a Float bound is the mixed shape the fast pass
  // declines: the composed comparison kernels serve it with their exact
  // cross-type reading (2 < 1.5 is false, 2 > 8.5 is false — unchanged).
  let idf = DataFrame::DataFrame([Series::from_ints("i", [2])])
  let iout = idf.select([
    @expr.col("i")
    .clip(lower=@expr.lit_float(1.5), upper=@expr.lit_float(8.5))
    .with_alias("c"),
  ])
  // The composed mixed comparison promotes: the value is untouched but
  // the column reads Float.
  assert_eq(iout.get_column("c").to_scalars(), [@types.Scalar::Float(2.0)])
  // And the mixed lower bound that bites: 1 < 1.5 lifts to 1.5 exactly —
  // the composed path's cross-type semantics, precise across the type
  // boundary. (2 does not lift: it is not below the bound.)
  let small = DataFrame::DataFrame([Series::from_ints("i", [1])])
  let lift = small.select([
    @expr.col("i").clip(lower=@expr.lit_float(1.5)).with_alias("c"),
  ])
  assert_eq(lift.get_column("c").to_scalars(), [@types.Scalar::Float(1.5)])
}

///|
test "clip declines the fast pass for mixed, rider, and non-numeric shapes" {
  // Each shape the fast pass refuses lands on the composed kernels, whose
  // verdicts are the contract: a Float column against an Int bound mixes
  // types exactly (0.5 < 1 lifts to 1), and every non-numeric or rider
  // pair raises the same `TypeMismatch` an eager comparison would.
  let fdf = DataFrame::DataFrame([Series::from_floats("v", [0.5])])
  let mixed = fdf.select([
    @expr.col("v").clip(lower=@expr.lit_int(1)).with_alias("c"),
  ])
  assert_eq(mixed.get_column("c").to_scalars(), [@types.Scalar::Float(1.0)])
  // A Date operand and a Date bound both refuse: raw day-counts must not
  // clamp, and the composed comparison raises on the pair.
  let ddf = DataFrame::DataFrame([
    Series::from_date_options("d", [Some(11016L)]),
    Series::from_ints("i", [1]),
  ])
  let as_operand : Result[DataFrame, @types.DataError] = Ok(
    ddf.select([@expr.col("d").clip(lower=@expr.lit_int(0)).with_alias("c")]),
  ) catch {
    e => Err(e)
  }
  assert_true(as_operand is Err(@types.DataError::TypeMismatch(_)))
  let as_bound : Result[DataFrame, @types.DataError] = Ok(
    ddf.select([@expr.col("i").clip(lower=@expr.col("d")).with_alias("c")]),
  ) catch {
    e => Err(e)
  }
  assert_true(as_bound is Err(@types.DataError::TypeMismatch(_)))
  // A string bound on an Int column: same refusal.
  let sdf = DataFrame::DataFrame([
    Series::from_ints("i", [1]),
    Series::from_strings("s", ["lo"]),
  ])
  let str_bound : Result[DataFrame, @types.DataError] = Ok(
    sdf.select([@expr.col("i").clip(lower=@expr.col("s")).with_alias("c")]),
  ) catch {
    e => Err(e)
  }
  assert_true(str_bound is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "clip's mixed upper bound also rides the composed kernels" {
  // The fast pass refuses either side independently: a Float column with
  // an Int upper bound declines just as its lower-bound mirror does.
  let fdf = DataFrame::DataFrame([Series::from_floats("v", [9.5])])
  let mixed = fdf.select([
    @expr.col("v").clip(upper=@expr.lit_int(8)).with_alias("c"),
  ])
  assert_eq(mixed.get_column("c").to_scalars(), [@types.Scalar::Float(8.0)])
  // The integer mirror: an Int column against a Float upper bound declines
  // the fast pass on its upper side alone and presses through the composed
  // comparison (2 > 1.5, so 2 presses down to exactly 1.5).
  let idf = DataFrame::DataFrame([Series::from_ints("i", [2])])
  let imixed = idf.select([
    @expr.col("i").clip(upper=@expr.lit_float(1.5)).with_alias("c"),
  ])
  assert_eq(imixed.get_column("c").to_scalars(), [@types.Scalar::Float(1.5)])
}
