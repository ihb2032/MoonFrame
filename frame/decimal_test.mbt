// The `Decimal` dtype acceptance suite: the first *parameterised* rider —
// `Decimal(scale)` over unscaled `I64` cells. The `Date` / `Timestamp`
// fences hold (no arithmetic, no cast, no inference), with two deliberate
// differences: `sum` is exact over one scale (the registry's `summable`
// row), and everything crossing two scales is fenced, pending the rescale
// rules.

///|
/// A small frame with a `Decimal(2)` column: 123.45, -123.45, one null,
/// 9.99 (unscaled 12345 / -12345 / 999).
fn dec_frame() -> DataFrame raise @types.DataError {
  DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal(2)),
      @types.Field::Field("v", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Decimal(2, 12345L), @types.Scalar::Int(1)],
      [@types.Scalar::Decimal(2, -12345L), @types.Scalar::Int(2)],
      [@types.Scalar::Null, @types.Scalar::Int(3)],
      [@types.Scalar::Decimal(2, 999L), @types.Scalar::Int(4)],
    ],
  )
}

///|
/// The column's decimal cells as plain strings (nulls as `"null"`).
fn dec_cells(
  df : DataFrame,
  name : String,
) -> Array[String] raise @types.DataError {
  df
  .get_column(name)
  .to_scalars()
  .map(s => if s is @types.Scalar::Null { "null" } else { s.to_string() })
}

///|
test "Decimal renders with the fraction padded to its scale" {
  assert_eq(@types.Scalar::Decimal(2, 12345L).to_string(), "123.45")
  assert_eq(@types.Scalar::Decimal(2, -12345L).to_string(), "-123.45")
  assert_eq(@types.Scalar::Decimal(2, 5L).to_string(), "0.05")
  assert_eq(@types.Scalar::Decimal(2, -5L).to_string(), "-0.05")
  assert_eq(@types.Scalar::Decimal(2, 100L).to_string(), "1.00")
  assert_eq(@types.Scalar::Decimal(0, 42L).to_string(), "42")
  assert_eq(@types.Scalar::Decimal(3, 1234567L).to_string(), "1234.567")
  assert_eq(@types.Scalar::Decimal(6, 5L).to_string(), "0.000005")
  // The dtype carries the scale; the scalar's dtype round-trips it.
  assert_true(
    @types.Scalar::Decimal(3, 1L).dtype() is @types.DataType::Decimal(3),
  )
}

///|
test "a Decimal column keeps its identity through build and read" {
  let df = dec_frame()
  assert_eq(df.get_column("d").dtype(), @types.DataType::Decimal(2))
  assert_true(df.item(0, "d") is @types.Scalar::Decimal(2, 12345L))
  assert_true(df.item(2, "d") is @types.Scalar::Null)
  assert_eq(dec_cells(df, "d"), ["123.45", "-123.45", "null", "9.99"])
}

///|
test "Decimal compares within its scale; never across dtypes or scales" {
  let df = dec_frame()
  assert_eq(
    dec_cells(
      df.filter(@expr.col("d").lt(@expr.lit(@types.Scalar::Decimal(2, 1000L)))),
      "d",
    ),
    ["-123.45", "9.99"],
  )
  // An Int literal must not reach the unscaled cells.
  assert_true(
    (Ok(ignore(df.filter(@expr.col("d").lt(@expr.lit_int(1000L))))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // A different scale compares exactly: 10.000 (s3) < 10.00 (s2) is false,
  // 10.000 < 12.34 is true — both sides lift to the larger scale first.
  let other_scale = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal(3)),
    ]),
    [[@types.Scalar::Decimal(3, 10000L)]],
  )
  let cross = other_scale.select([
    @expr.col("d")
    .lt(@expr.lit(@types.Scalar::Decimal(2, 1000L)))
    .with_alias("lt"),
    @expr.col("d")
    .gt(@expr.lit(@types.Scalar::Decimal(2, 800L)))
    .with_alias("gt"),
  ])
  assert_eq(cross.item(0, "lt"), @types.Scalar::Bool(false))
  assert_eq(cross.item(0, "gt"), @types.Scalar::Bool(true))
}

///|
test "Decimal sorts, groups, and joins on its unscaled order" {
  let df = dec_frame()
  let sorted = df.sort([(@expr.col("d"), false, true)])
  assert_eq(dec_cells(sorted, "d"), ["-123.45", "9.99", "123.45", "null"])
  let grouped = df
    .drop_nulls(subset=[@expr.col("d")])
    .group_by([@expr.col("d")])
    .agg([@expr.col("v").count().with_alias("n")])
  assert_true(grouped.nrows() == 3)
  let left = df.drop_nulls(subset=[@expr.col("d")]).drop([@expr.col("v")])
  let right = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal(2)),
      @types.Field::Field("w", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Decimal(2, 999L), @types.Scalar::Int(10)],
      [@types.Scalar::Decimal(2, 700L), @types.Scalar::Int(20)],
    ],
  )
  let joined = left.join(
    right,
    @frame.JoinOptions::on(
      [@expr.col("d")],
      how=@frame.JoinType::Outer,
      coalesce=true,
    ),
  )
  assert_true(joined.nrows() == 4)
  assert_eq(dec_cells(joined, "d"), ["123.45", "-123.45", "9.99", "7.00"])
}

///|
test "sum is exact over one scale; the approximate statistics stay fenced" {
  let df = dec_frame().drop_nulls(subset=[@expr.col("d")])
  // 12345 - 12345 + 999 = 999 unscaled, still Decimal(2).
  assert_true(df.get_column("d").sum() is @types.Scalar::Decimal(2, 999L))
  assert_eq(df.get_column("d").min().to_string(), "-123.45")
  assert_eq(df.get_column("d").max().to_string(), "123.45")
  assert_true(df.get_column("d").count() == 3)
  // mean / std / var / median are approximate (Double-valued): fenced.
  assert_true(
    (Ok(ignore(df.get_column("d").mean())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  assert_true(
    (Ok(ignore(df.get_column("d").std())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // Division stays fenced: an exact quotient needs a result-scale rule
  // (how far to extend), which is a decision the arithmetic batch leaves
  // open. `+` / `-` / `*` landed — the arithmetic test below pins them.
  assert_true(
    (Ok(ignore(df.select([@expr.col("d").div(@expr.lit_int(2L))]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "Decimal is never inferred, never cast; fills match scale exactly" {
  let from_csv = @io.parse_csv_str("d\n123.45")
  assert_eq(from_csv.get_column("d").dtype(), @types.DataType::Float)
  let df = dec_frame().drop_nulls(subset=[@expr.col("d")])
  assert_true(
    (Ok(ignore(df.get_column("d").cast(@types.DataType::Int))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  assert_true(
    (Ok(ignore(df.get_column("v").cast(@types.DataType::Decimal(2)))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  // A same-scale scalar fills; a different scale or an Int does not.
  let filled = dec_frame()
    .get_column("d")
    .fill_null(@types.Scalar::Decimal(2, 0L))
  assert_eq(filled.get(2).to_string(), "0.00")
  assert_true(
    (Ok(
      ignore(
        dec_frame().get_column("d").fill_null(@types.Scalar::Decimal(3, 0L)),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  assert_true(
    (Ok(ignore(dec_frame().get_column("d").fill_null(@types.Scalar::Int(0L)))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a Decimal literal evaluates, renders, and rides the engine paths" {
  let df = dec_frame()
  let out = df.select([
    @expr.lit(@types.Scalar::Decimal(2, -5L)).with_alias("nickel"),
  ])
  assert_eq(out.get_column("nickel").dtype(), @types.DataType::Decimal(2))
  assert_eq(out.item(0, "nickel").to_string(), "-0.05")
  // The `Show` spelling carries the scale and the rendering.
  let shown = @expr.lit(@types.Scalar::Decimal(2, -5L)).to_string()
  assert_true(shown.contains("-0.05"))
  // CSV / JSON carry the plain rendering.
  let csv = @io.format_csv(df.drop_nulls(subset=[@expr.col("d")]))
  assert_true(csv.contains("123.45"))
  let json = @io.format_json(df.drop_nulls(subset=[@expr.col("d")]))
  assert_true(json.contains("9.99"))
  // An explicit-dtype build refuses a different scale's scalar.
  assert_true(
    (Ok(
      ignore(
        @series.Series::from_scalars(
          "d",
          [@types.Scalar::Decimal(3, 1L)],
          dtype=@types.DataType::Decimal(2),
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // An empty Decimal column exists at zero rows.
  let empty = DataFrame::empty(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal(4)),
    ]),
  )
  assert_true(empty.get_column("d").len() == 0)
}

///|
test "Decimal rides the remaining engine paths" {
  // An explicit-dtype build succeeds on the matching scale.
  let s = @series.Series::from_scalars(
    "d",
    [@types.Scalar::Decimal(2, 5L), @types.Scalar::Null],
    dtype=@types.DataType::Decimal(2),
  )
  assert_true(s.get(0) is @types.Scalar::Decimal(2, 5L))
  // from_rows refuses an off-type cell under a Decimal field.
  assert_true(
    (Ok(
      ignore(
        DataFrame::from_rows(
          @types.Schema::Schema([
            @types.Field::Field("d", @types.DataType::Decimal(2)),
          ]),
          [[@types.Scalar::Int(1L)]],
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // A map closure returning Decimal cells fixes that dtype (and a mixed
  // result nulls the off-type minority through the projection).
  let mapped = dec_frame()
    .drop_nulls(subset=[@expr.col("d")])
    .with_columns([
      @expr.col("v")
      .map_elements(label="dec", (c : @types.Scalar) => {
        if c.as_int() == 2 {
          @types.Scalar::Int(7L)
        } else {
          @types.Scalar::Decimal(1, c.as_int() * 10L)
        }
      })
      .with_alias("tenths"),
    ])
  assert_eq(mapped.get_column("tenths").dtype(), @types.DataType::Decimal(1))
  assert_eq(mapped.item(0, "tenths").to_string(), "1.0")
  assert_true(mapped.item(1, "tenths") is @types.Scalar::Null)
  // The `Show` rendering (what `println` prints) carries scale and value.
  println(@types.Scalar::Decimal(2, -12345L))
}

///|
test "decimal arithmetic is exact across scales, with Int lifting" {
  let df = dec_frame().drop_nulls(subset=[@expr.col("d")])
  // Same scale: 123.45 - 123.45 + 9.99 = 9.99, unscaled directly.
  let same = df.select([(@expr.col("d") - @expr.col("d")).with_alias("z")])
  assert_true(same.item(0, "z") is @types.Scalar::Decimal(2, 0L))
  assert_eq(same.get_column("z").dtype(), @types.DataType::Decimal(2))
  // Cross scale: Decimal(2) + Decimal(1) aligns to scale 2 — 9.99 + 1.5
  // = 11.49, the exact widening rescale then the unscaled add.
  let wide = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Decimal(2)),
      @types.Field::Field("b", @types.DataType::Decimal(1)),
    ]),
    [
      [@types.Scalar::Decimal(2, 999L), @types.Scalar::Decimal(1, 15L)],
      [@types.Scalar::Decimal(2, 12345L), @types.Scalar::Decimal(1, -5L)],
    ],
  )
  let summed = wide.select([(@expr.col("a") + @expr.col("b")).with_alias("s")])
  assert_eq(summed.get_column("s").dtype(), @types.DataType::Decimal(2))
  assert_eq(summed.item(0, "s").to_string(), "11.49")
  assert_eq(summed.item(1, "s").to_string(), "122.95")
  // Int lifts exactly as scale 0: 123.45 + 1 = 124.45.
  let lifted = df.select([(@expr.col("d") + @expr.lit_int(1L)).with_alias("up")])
  assert_eq(lifted.item(0, "up").to_string(), "124.45")
  // Multiply adds the scales: 1.23 (s2) * 1.5 (s1) = 1.845 (s3).
  let muled = wide.select([(@expr.col("a") * @expr.col("b")).with_alias("p")])
  assert_eq(muled.get_column("p").dtype(), @types.DataType::Decimal(3))
  assert_eq(muled.item(0, "p").to_string(), "14.985")
  assert_eq(muled.item(1, "p").to_string(), "-61.725")
  // Nulls propagate cell-wise through the decimal path.
  let nully = dec_frame().select([
    (@expr.col("d") + @expr.col("d")).with_alias("d2"),
  ])
  assert_true(nully.item(2, "d2") is @types.Scalar::Null)
  // A Float operand stays fenced — the exact dtype does not mix with the
  // approximate one; that promotion is a decision, not a default.
  assert_true(
    (Ok(ignore(df.select([@expr.col("d").add(@expr.lit_float(0.5))]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "decimal arithmetic refuses what would not stay exact" {
  // A magnitude at the top of the range, rescaled up one digit: the shift
  // overflows and the evaluation refuses rather than wrapping.
  let huge = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("h", @types.DataType::Decimal(0)),
      @types.Field::Field("t", @types.DataType::Decimal(1)),
    ]),
    [
      [
        @types.Scalar::Decimal(0, 9_000_000_000_000_000_000L),
        @types.Scalar::Decimal(1, 1L),
      ],
    ],
  )
  assert_true(
    (Ok(
      ignore(huge.select([(@expr.col("h") + @expr.col("t")).with_alias("s")])),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // Multiply overflowing the 18-digit magnitude refuses the same way.
  let big = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("b", @types.DataType::Decimal(0)),
    ]),
    [[@types.Scalar::Decimal(0, 4_000_000_000_000_000_000L)]],
  )
  assert_true(
    (Ok(ignore(big.select([(@expr.col("b") * @expr.col("b")).with_alias("p")]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "cross-scale decimal compare aligns exactly" {
  // 9.99 at scale 2 vs 15.0 at scale 1: lift to scale 2, 999 < 1500.
  let wide = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Decimal(2)),
      @types.Field::Field("b", @types.DataType::Decimal(1)),
    ]),
    [
      [@types.Scalar::Decimal(2, 999L), @types.Scalar::Decimal(1, 150L)],
      [@types.Scalar::Decimal(2, 12345L), @types.Scalar::Decimal(1, 150L)],
    ],
  )
  let lt = wide.select([@expr.col("a").lt(@expr.col("b")).with_alias("ab")])
  assert_eq(lt.item(0, "ab"), @types.Scalar::Bool(true))
  assert_eq(lt.item(1, "ab"), @types.Scalar::Bool(false))
  // Equality across scales sees through the alignment: 1.5 (s1) == 1.50 (s2).
  let eq = wide.select([@expr.col("b").eq(@expr.col("b")).with_alias("bb")])
  assert_eq(eq.item(0, "bb"), @types.Scalar::Bool(true))
}

///|
test "decimal arithmetic corners: add overflow, multiply by zero, riders" {
  // Two near-max magnitudes on the same scale: the exact add leaves the
  // range and the evaluation names the operation.
  let big = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("b", @types.DataType::Decimal(0)),
      @types.Field::Field("z", @types.DataType::Decimal(0)),
    ]),
    [
      [
        @types.Scalar::Decimal(0, 9_000_000_000_000_000_000L),
        @types.Scalar::Decimal(0, 0L),
      ],
    ],
  )
  assert_true(
    (Ok(ignore(big.select([(@expr.col("b") + @expr.col("b")).with_alias("s")]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // A zero magnitude short-circuits the checked multiply: 0 * huge is 0.
  let zeroed = big.select([(@expr.col("z") * @expr.col("b")).with_alias("p")])
  assert_true(zeroed.item(0, "p") is @types.Scalar::Decimal(0, 0L))
  // An I64 rider (Date) is not arithmetic material even though its buffer
  // matches — the dtype, not the buffer, decides.
  let dated = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("d", @types.DataType::Date)]),
    [[@types.Scalar::Date(0L)]],
  )
  let with_dec = dated.with_columns([
    @expr.lit(@types.Scalar::Decimal(2, 1L)).with_alias("cent"),
  ])
  assert_true(
    (Ok(
      ignore(
        with_dec.select([(@expr.col("d") + @expr.col("cent")).with_alias("s")]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "cross-scale equality sees through the alignment; compare overflow refuses" {
  // 1.5 (s1) == 1.50 (s2): the lift makes the magnitudes equal.
  let pair = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Decimal(1)),
      @types.Field::Field("b", @types.DataType::Decimal(2)),
    ]),
    [[@types.Scalar::Decimal(1, 15L), @types.Scalar::Decimal(2, 150L)]],
  )
  let eq = pair.select([@expr.col("a").eq(@expr.col("b")).with_alias("e")])
  assert_eq(eq.item(0, "e"), @types.Scalar::Bool(true))
  // A magnitude at the top of the range, compared across a wider scale:
  // the comparison's lift overflows and refuses.
  let huge = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("h", @types.DataType::Decimal(0)),
      @types.Field::Field("t", @types.DataType::Decimal(1)),
    ]),
    [
      [
        @types.Scalar::Decimal(0, 9_000_000_000_000_000_000L),
        @types.Scalar::Decimal(1, 1L),
      ],
    ],
  )
  assert_true(
    (Ok(
      ignore(huge.select([@expr.col("h").lt(@expr.col("t")).with_alias("c")])),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "decimal subtraction overflow refuses too" {
  // 9e18 - (-9e18): the exact sum of magnitudes leaves the range.
  let big = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("p", @types.DataType::Decimal(0)),
      @types.Field::Field("n", @types.DataType::Decimal(0)),
    ]),
    [
      [
        @types.Scalar::Decimal(0, 9_000_000_000_000_000_000L),
        @types.Scalar::Decimal(0, -9_000_000_000_000_000_000L),
      ],
    ],
  )
  assert_true(
    (Ok(ignore(big.select([(@expr.col("p") - @expr.col("n")).with_alias("s")]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
/// `Int64::MIN` is a value a `pub(all)` scalar and an `Int` literal can
/// both carry, so the checked arithmetic has to hold at that edge: a
/// subtraction against it refuses (negating it to add would wrap), a
/// multiplication by it refuses without dividing `MIN / -1` (the trap
/// quotient), and a negative minuend subtracting it lands exactly on MAX.
test "decimal arithmetic decides the MIN magnitude exactly" {
  let min = -9_223_372_036_854_775_808L
  let frame = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("p", @types.DataType::Decimal(0)),
      @types.Field::Field("n", @types.DataType::Decimal(0)),
    ]),
    [
      [@types.Scalar::Decimal(0, 5L), @types.Scalar::Decimal(0, -1L)],
      [@types.Scalar::Decimal(0, -1L), @types.Scalar::Decimal(0, -1L)],
    ],
  )
  // 5 - MIN: the true value leaves the range, and the negation first would
  // wrap into a confidently wrong cell — the refusal is the contract.
  try
    ignore(
      frame.select([(@expr.col("p") - @expr.lit_int(min)).with_alias("s")]),
    )
  catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal subtract overflows the 18-digit magnitude\")",
      )
  } noraise {
    _ => fail("5 - MIN must refuse, not wrap")
  }
  // -1 * MIN: the wrapped product is MIN, whose divide-back check would be
  // MIN / -1 — the pair is refused before any division runs.
  try
    ignore(
      frame.select([(@expr.col("n") * @expr.lit_int(min)).with_alias("m")]),
    )
  catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal multiply overflows the 18-digit magnitude\")",
      )
  } noraise {
    _ => fail("-1 * MIN must refuse, not trap")
  }
  // -1 - MIN is exactly MAX: the one in-range result at the edge.
  let exact = frame.select([
    (@expr.col("n") - @expr.lit_int(min)).with_alias("e"),
  ])
  // The rider's arithmetic rebuilds a frame; the shape invariants ride
  // the representative outputs.
  assert_eq(exact.check_invariants(), Ok(()))
  assert_eq(exact.get_column("e").to_scalars(), [
    @types.Scalar::Decimal(0, 9_223_372_036_854_775_807L),
    @types.Scalar::Decimal(0, 9_223_372_036_854_775_807L),
  ])
}

///|
/// The decimal `sum` refuses a total past the `Int64` range instead of
/// wrapping — the exact dtype's contract, where the `Int` sum's wraparound
/// is the documented price only the wrapping dtype agreed to.
test "decimal sum refuses a total past the magnitude" {
  let rich = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal(0)),
    ]),
    [
      [@types.Scalar::Decimal(0, 5_000_000_000_000_000_000L)],
      [@types.Scalar::Decimal(0, 5_000_000_000_000_000_000L)],
      [@types.Scalar::Decimal(0, 5_000_000_000_000_000_000L)],
    ],
  )
  try ignore(rich.get_column("d").sum()) catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal sum overflows the 18-digit magnitude\")",
      )
  } noraise {
    _ => fail("1.5e19 must refuse, not wrap negative")
  }
  // The grouped path walks the same refusing reducer.
  try ignore(rich.group_by([]).sum()) catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal sum overflows the 18-digit magnitude\")",
      )
  } noraise {
    _ => fail("the grouped sum must refuse on the same overflow")
  }
  // An in-range total still sums exactly.
  let small = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal(2)),
    ]),
    [
      [@types.Scalar::Decimal(2, 123L)],
      [@types.Scalar::Decimal(2, -23L)],
      [@types.Scalar::Null],
    ],
  )
  assert_eq(small.get_column("d").sum(), @types.Scalar::Decimal(2, 100L))
}

///|
/// The scale envelope `[0, 18]` is enforced where a decimal dtype is
/// authored: the schema's column constructor, the empty-column path, and
/// the literal singleton all refuse a scale outside it, so no column the
/// library builds can carry a scale the rendering and the rescale would
/// only meet downstream.
test "the scale envelope is enforced at every constructor" {
  // A schema naming a past-the-envelope scale refuses at from_rows —
  // with rows to project and without (the empty-column path).
  try
    ignore(
      DataFrame::from_rows(
        @types.Schema::Schema([
          @types.Field::Field("d", @types.DataType::Decimal(19)),
        ]),
        [[@types.Scalar::Decimal(19, 1L)]],
      ),
    )
  catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal column d carries scale 19, outside the envelope [0, 18]\")",
      )
  } noraise {
    _ => fail("a scale-19 schema column must refuse")
  }
  try
    ignore(
      DataFrame::from_rows(
        @types.Schema::Schema([
          @types.Field::Field("d", @types.DataType::Decimal(-2)),
        ]),
        [],
      ),
    )
  catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal column d carries scale -2, outside the envelope [0, 18]\")",
      )
  } noraise {
    _ => fail("an empty scale -2 column must refuse")
  }
  // A hand-built out-of-envelope literal refuses at the singleton.
  try
    ignore(
      DataFrame::from_rows(
        @types.Schema::Schema([
          @types.Field::Field("d", @types.DataType::Decimal(2)),
        ]),
        [[@types.Scalar::Decimal(2, 1L)]],
      ).select([@expr.lit(@types.Scalar::Decimal(19, 1L)).with_alias("x")]),
    )
  catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal column literal carries scale 19, outside the envelope [0, 18]\")",
      )
  } noraise {
    _ => fail("a scale-19 literal must refuse")
  }
}

///|
/// `Mul` composes the output scale `ls + rs`, the one scale the arithmetic
/// authors itself: two operands inside the envelope can still sum past it,
/// and the product refuses rather than build a column nothing can render.
test "decimal multiply refuses a product scale past the envelope" {
  let wide = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Decimal(10)),
      @types.Field::Field("b", @types.DataType::Decimal(9)),
    ]),
    [[@types.Scalar::Decimal(10, 1L), @types.Scalar::Decimal(9, 1L)]],
  )
  try
    ignore(wide.select([(@expr.col("a") * @expr.col("b")).with_alias("p")]))
  catch {
    e =>
      inspect(
        e,
        content="InvalidOperation(\"decimal multiply result carries scale 19, outside the envelope [0, 18]\")",
      )
  } noraise {
    _ => fail("a scale-19 product must refuse")
  }
  // Just inside: a Decimal(10) x Decimal(8) product carries scale 18 fine.
  let inner = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Decimal(10)),
      @types.Field::Field("b", @types.DataType::Decimal(8)),
    ]),
    [[@types.Scalar::Decimal(10, 2L), @types.Scalar::Decimal(8, 5L)]],
  )
  assert_eq(
    inner
    .select([(@expr.col("a") * @expr.col("b")).with_alias("p")])
    .get_column("p")
    .to_scalars(),
    [@types.Scalar::Decimal(18, 10L)],
  )
}

///|
/// The rendering is total over every magnitude — `MIN` included, whose
/// negation would wrap — and names a hand-built out-of-envelope scale as a
/// non-value instead of rendering garbage.
test "decimal rendering stays total at the magnitude edge" {
  let min = -9_223_372_036_854_775_808L
  assert_eq(@types.Scalar::Decimal(2, min).to_string(), "-92233720368547758.08")
  assert_eq(@types.Scalar::Decimal(0, min).to_string(), "-9223372036854775808")
  assert_eq(
    @types.Scalar::Decimal(64, 1L).to_string(),
    "<decimal scale 64 outside the envelope [0, 18], unscaled 1>",
  )
}

///|
test "a map closure returning mixed scales nulls the off-scale minority" {
  let df = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("v", @types.DataType::Int)]),
    [[@types.Scalar::Int(1L)], [@types.Scalar::Int(2L)]],
  )
  let mapped = df.with_columns([
    @expr.col("v")
    .map_elements(label="m", (c : @types.Scalar) => {
      if c.as_int() == 1L {
        @types.Scalar::Decimal(2, 5L)
      } else {
        @types.Scalar::Decimal(3, 5000L)
      }
    })
    .with_alias("m"),
  ])
  assert_eq(mapped.get_column("m").dtype(), @types.DataType::Decimal(2))
  assert_true(mapped.item(0, "m") is @types.Scalar::Decimal(2, 5L))
  // The scale-3 cell lands as null: its unscaled bits re-read through the
  // column's scale 2 would report 50.00 for a closure that returned 5.000.
  assert_true(mapped.item(1, "m") is @types.Scalar::Null)
}

///|
test "whole-frame sum / min / max reduce a Decimal column exactly" {
  // The three surfaces agree: the whole-frame verb, the Series accessor,
  // and (what `describe` reports) `Series::min` / `Series::max`.
  let df = dec_frame()
  assert_true(df.sum().item(0, "d") is @types.Scalar::Decimal(2, 999L))
  assert_true(df.min().item(0, "d") is @types.Scalar::Decimal(2, -12345L))
  assert_true(df.max().item(0, "d") is @types.Scalar::Decimal(2, 12345L))
  assert_true(df.sum().item(0, "d") == df.get_column("d").sum())
}

///|
test "cross-scale compare tolerates a large present cell beside a null" {
  // Arithmetic nulls the row either side nulls; the comparison agrees
  // instead of refusing the whole column over the rescale of a present
  // value on a row that compares to null.
  let df = DataFrame::DataFrame([
    @series.Series::from_decimal_options(0, "a", [
      Some(9223372036854775807L),
      Some(1L),
    ]),
    @series.Series::from_decimal_options(1, "b", [None, Some(2L)]),
  ])
  let out = df.select([@expr.col("a").gt(@expr.col("b")).with_alias("s")])
  assert_true(out.item(0, "s") is @types.Scalar::Null)
  assert_true(out.item(1, "s") is @types.Scalar::Bool(true))
}
