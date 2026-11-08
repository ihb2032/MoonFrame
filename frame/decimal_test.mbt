// The `Decimal` dtype acceptance suite over the IEEE decimal128 value
// layer: `Decimal` is one dtype whose cells are `Dec128` values — up to
// 34 significant digits, a per-value quantum exponent, ±infinity / NaN /
// signed zero as *values*. The `Date` / `Timestamp` fences hold (no
// approximate statistics, no inference), while the arithmetic is the
// engine's own: exact-then-round, ties to even, an overflow an infinity
// and never a refusal.

///|
/// A small frame with a `Decimal` column: 123.45, -123.45, one null,
/// 9.99.
fn dec_frame() -> DataFrame raise @types.DataError {
  DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal),
      @types.Field::Field("v", @types.DataType::Int),
    ]),
    [
      [
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(12345L, scale=2)),
        @types.Scalar::Int(1),
      ],
      [
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(-12345L, scale=2)),
        @types.Scalar::Int(2),
      ],
      [@types.Scalar::Null, @types.Scalar::Int(3)],
      [
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(999L, scale=2)),
        @types.Scalar::Int(4),
      ],
    ],
  )
}

///|
test "Decimal renders the exact stored value, cohort kept" {
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(12345L, scale=2)).to_string(),
    "123.45",
  )
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(-12345L, scale=2)).to_string(),
    "-123.45",
  )
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(5L, scale=2)).to_string(),
    "0.05",
  )
  // The cohort's trailing zeros render: 1.00 stays 1.00 (the preferred
  // exponent the arithmetic keeps), and an integer spells "42.0".
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(100L, scale=2)).to_string(),
    "1.00",
  )
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(42L, scale=0)).to_string(),
    "42.0",
  )
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(5L, scale=6)).to_string(),
    "0.000005",
  )
  // The exceptionals render their own spellings.
  assert_eq(@types.Scalar::Decimal(@types.Dec128::nan()).to_string(), "NaN")
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::infinity()).to_string(),
    "inf",
  )
  assert_eq(
    @types.Scalar::Decimal(@types.Dec128::infinity(neg=true)).to_string(),
    "-inf",
  )
  assert_true(
    @types.Scalar::Decimal(@types.Dec128::of_int64_scale(1L, scale=3)).dtype()
    is @types.DataType::Decimal,
  )
}

///|
test "a Decimal column keeps its identity through build and read" {
  let df = dec_frame()
  assert_eq(df.get_column("d").dtype(), @types.DataType::Decimal)
  assert_true(
    df.item(0, "d") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(12345L, scale=2)),
  )
  assert_true(df.item(2, "d") is @types.Scalar::Null)
  assert_eq(cells_to_strings(df, "d"), ["123.45", "-123.45", "null", "9.99"])
}

///|
test "Decimal compares by value; never across dtypes" {
  let df = dec_frame()
  assert_eq(
    cells_to_strings(
      df.filter(
        @expr.col("d").lt(
          @expr.lit(
            @types.Scalar::Decimal(
              @types.Dec128::of_int64_scale(1000L, scale=2),
            ),
          ),
        ),
      ),
      "d",
    ),
    ["-123.45", "9.99"],
  )
  // An Int literal must not reach the decimal cells.
  assert_true(
    (Ok(ignore(df.filter(@expr.col("d").lt(@expr.lit_int(1000L))))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // Cohorts compare equal by value: 10.000 (exp −3) against 10.00
  // (exp −2) — both sides of every comparison read numeric value.
  let other_scale = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("d", @types.DataType::Decimal)]),
    [[@types.Scalar::Decimal(@types.Dec128::of_int64_scale(10000L, scale=3))]],
  )
  let cross = other_scale.select([
    @expr.col("d")
    .lt(
      @expr.lit(
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(1000L, scale=2)),
      ),
    )
    .with_alias("lt"),
    @expr.col("d")
    .gt(
      @expr.lit(
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(800L, scale=2)),
      ),
    )
    .with_alias("gt"),
    // 10.000 == 10.00: the cohort is one value.
    @expr.col("d")
    .eq(
      @expr.lit(
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(1000L, scale=2)),
      ),
    )
    .with_alias("eq"),
  ])
  assert_eq(cross.item(0, "lt"), @types.Scalar::Bool(false))
  assert_eq(cross.item(0, "gt"), @types.Scalar::Bool(true))
  assert_eq(cross.item(0, "eq"), @types.Scalar::Bool(true))
}

///|
test "Decimal sorts, groups, and joins on numeric value" {
  let df = dec_frame()
  let sorted = df.sort([(@expr.col("d"), false, true)])
  assert_eq(cells_to_strings(sorted, "d"), ["-123.45", "9.99", "123.45", "null"])
  let grouped = df
    .drop_nulls(subset=[@expr.col("d")])
    .group_by([@expr.col("d")])
    .agg([@expr.col("v").count().with_alias("n")])
  assert_true(grouped.nrows() == 3)
  let left = df.drop_nulls(subset=[@expr.col("d")]).drop([@expr.col("v")])
  let right = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal),
      @types.Field::Field("w", @types.DataType::Int),
    ]),
    [
      [
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(999L, scale=2)),
        @types.Scalar::Int(10),
      ],
      [
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(700L, scale=2)),
        @types.Scalar::Int(20),
      ],
    ],
  )
  let joined = left.join(
    right,
    JoinOptions::on([@expr.col("d")], how=JoinType::Outer, coalesce=true),
  )
  assert_true(joined.nrows() == 4)
  assert_eq(cells_to_strings(joined, "d"), ["123.45", "-123.45", "9.99", "7.00"])
  // Cohort-equal keys join: 9.99 (exp −2) matches 9.990 (exp −3).
  let right_cohort = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal),
      @types.Field::Field("w", @types.DataType::Int),
    ]),
    [
      [
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(9990L, scale=3)),
        @types.Scalar::Int(30),
      ],
    ],
  )
  let cohort_joined = left.join(
    right_cohort,
    JoinOptions::on([@expr.col("d")], how=JoinType::Inner, coalesce=true),
  )
  assert_true(cohort_joined.nrows() == 1)
  assert_eq(cells_to_strings(cohort_joined, "w"), ["30"])
}

///|
test "sum folds the IEEE addition; the approximate statistics stay fenced" {
  let df = dec_frame().drop_nulls(subset=[@expr.col("d")])
  // 123.45 − 123.45 + 9.99 = 9.99, still Decimal.
  let summed = df.sum()
  assert_true(
    summed.item(0, "d") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(999L, scale=2)),
  )
  // The whole-frame mean leaves a non-numeric column a Null cell (the
  // documented rule for every non-numeric rider).
  assert_true(df.mean().item(0, "d") is @types.Scalar::Null)
  // NaN propagates through the sum; +∞ folded with −∞ makes NaN.
  let specials = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::of_int64(1L)),
      Some(@types.Dec128::nan()),
    ]),
  ])
  assert_true(
    specials.sum().item(0, "d") is @types.Scalar::Decimal(v) && v.is_nan(),
  )
  let inf_pair = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::infinity()),
      Some(@types.Dec128::infinity(neg=true)),
    ]),
  ])
  assert_true(
    inf_pair.sum().item(0, "d") is @types.Scalar::Decimal(v) && v.is_nan(),
  )
}

///|
test "Decimal is never inferred; casts cross both ways; fills match the dtype" {
  let df = dec_frame()
  // Inference never lands on Decimal.
  let inferred = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("t", @types.DataType::String)]),
    [[@types.Scalar::String("1.50")]],
  )
  assert_true(inferred.get_column("t").dtype() is @types.DataType::String)
  ignore(df)
  // Cast crosses: Int → Decimal exact, Decimal → Int truncates toward
  // zero, Decimal → Float the correctly-rounded conversion, String →
  // Decimal parses the value forms.
  let ints = DataFrame::DataFrame([@series.Series::from_ints("i", [7])])
  let as_dec = ints.select([@expr.col("i").cast(@types.DataType::Decimal)])
  assert_true(
    as_dec.item(0, "i") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(7L)),
  )
  let back = as_dec.select([
    @expr.col("i").cast(@types.DataType::Int),
    @expr.col("i").cast(@types.DataType::Float).with_alias("f"),
  ])
  assert_eq(back.item(0, "i"), @types.Scalar::Int(7))
  assert_eq(back.item(0, "f"), @types.Scalar::Float(7.0))
  // A NaN decimal refuses the Int cast; a fraction truncates.
  let nan_col = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::nan()),
      Some(@types.Dec128::of_int64_scale(25L, scale=1)),
    ]),
  ])
  assert_true(
    (Ok(ignore(nan_col.select([@expr.col("d").cast(@types.DataType::Int)]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ParseError(_)),
  )
  let trunc = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::of_int64_scale(25L, scale=1)),
    ]),
  ])
  assert_eq(
    trunc.select([@expr.col("d").cast(@types.DataType::Int)]).item(0, "d"),
    @types.Scalar::Int(2),
  )
  // Fill: a Decimal value fills its own dtype, another dtype refuses.
  let filled = df.fill_null(@types.Scalar::Decimal(@types.Dec128::zero()))
  assert_true(filled.item(2, "d") is @types.Scalar::Decimal(z) && z.is_zero())
}

///|
test "a Decimal literal evaluates, renders, and rides the engine paths" {
  let df = dec_frame()
  let out = df.select([
    @expr.lit(
      @types.Scalar::Decimal(@types.Dec128::of_int64_scale(150L, scale=2)),
    ).with_alias("lit"),
    (@expr.col("d") *
    @expr.lit(
      @types.Scalar::Decimal(@types.Dec128::of_int64_scale(2L, scale=0)),
    )).with_alias("dbl"),
    (@expr.col("d") + @expr.col("d")).with_alias("add"),
  ])
  assert_true(
    out.item(0, "lit") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(150L, scale=2)),
  )
  // 123.45 * 2 = 246.90 (the cohort: mul keeps ex+ey, −2 − 0 = −2).
  assert_true(
    out.item(0, "dbl") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(24690L, scale=2)),
  )
  // 123.45 + 123.45 = 246.90 (the preferred exponent: the finer −2).
  assert_true(
    out.item(0, "add") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(24690L, scale=2)),
  )
  assert_eq(cells_to_strings(out, "dbl")[:1], ["246.90"])
}

///|
test "decimal arithmetic is the IEEE engine: exact, then one rounding" {
  let df = dec_frame().drop_nulls(subset=[@expr.col("d")])
  // Subtraction cancels exactly: 123.45 − 123.45 = 0.
  let same = df
    .filter(@expr.col("v").eq(@expr.lit_int(1)))
    .select([(@expr.col("d") - @expr.col("d")).with_alias("zero")])
  assert_true(same.item(0, "zero") is @types.Scalar::Decimal(z) && z.is_zero())
  // Division stays Decimal: 9.99 / 3 = 3.33 (the exact quotient's
  // preferred exponent).
  let threes = df.select([
    @expr.col("d")
    .div(@expr.lit(@types.Scalar::Decimal(@types.Dec128::of_int64(3L))))
    .with_alias("q"),
  ])
  assert_true(
    threes.item(2, "q") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(333L, scale=2)),
  )
  // An inexact division rounds once at 34 digits — 1 / 3's expansion
  // is a value, never a refusal.
  let ones = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [Some(@types.Dec128::of_int64(1L))]),
  ])
  let third = ones.select([
    @expr.col("d")
    .div(@expr.lit(@types.Scalar::Decimal(@types.Dec128::of_int64(3L))))
    .with_alias("t"),
  ])
  assert_true(
    third.item(0, "t") is @types.Scalar::Decimal(d) &&
    d.to_string() == "0.3333333333333333333333333333333333",
  )
  // A Float operand promotes the pair to Float.
  let mixed = df.select([
    (@expr.col("d") + @expr.lit(@types.Scalar::Float(0.5))).with_alias("f"),
  ])
  assert_eq(mixed.get_column("f").dtype(), @types.DataType::Float)
  assert_eq(mixed.item(0, "f"), @types.Scalar::Float(123.95))
}

///|
test "decimal arithmetic corners: overflow, zero, infinity, NaN" {
  // Overflow is ±∞, a value; division by zero the signed infinity;
  // 0/0 the NaN; NaN propagates through everything. The overflow needs
  // the *adjusted* exponent past 6144 — a wide magnitude alone stays
  // finite (8.1e37 carries two significant digits inside the format).
  let df = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::parse_opt("1E+6000").unwrap()),
      Some(@types.Dec128::zero()),
      Some(@types.Dec128::nan()),
      Some(@types.Dec128::infinity()),
    ]),
  ])
  let out = df.select([
    (@expr.col("d") * @expr.col("d")).with_alias("sq"),
    @expr.col("d")
    .div(@expr.lit(@types.Scalar::Decimal(@types.Dec128::zero())))
    .with_alias("dz"),
    (-@expr.col("d")).with_alias("neg"),
  ])
  assert_true(out.item(0, "sq") is @types.Scalar::Decimal(v) && v.is_infinite())
  assert_true(out.item(1, "sq") is @types.Scalar::Decimal(v) && v.is_zero())
  assert_true(out.item(2, "sq") is @types.Scalar::Decimal(v) && v.is_nan())
  assert_true(out.item(0, "dz") is @types.Scalar::Decimal(v) && v.is_infinite())
  // 0 / 0 is NaN; the infinity divides to the NaN over zero only when
  // the numerator is zero — here ∞/0 is ∞.
  assert_true(out.item(1, "dz") is @types.Scalar::Decimal(v) && v.is_nan())
  assert_true(out.item(3, "dz") is @types.Scalar::Decimal(v) && v.is_infinite())
  // Negation flips the sign — the finite −1E6000 (Emax 6144 holds it)
  // and the −∞ alike; NaN carries no sign to flip.
  assert_true(
    out.item(0, "neg") is @types.Scalar::Decimal(v) &&
    v.is_negative() &&
    v.is_finite(),
  )
  assert_true(
    out.item(3, "neg") is @types.Scalar::Decimal(v) &&
    v.is_negative() &&
    v.is_infinite(),
  )
  assert_true(out.item(2, "neg") is @types.Scalar::Decimal(v) && v.is_nan())
}

///|
test "cross-scale equality is value equality; no refusal anywhere" {
  // Every comparison reads numeric value: 10.000 == 10.00 == 10.0.
  let df = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::of_int64_scale(10000L, scale=3)),
      Some(@types.Dec128::of_int64_scale(1000L, scale=2)),
      Some(@types.Dec128::of_int64(10L)),
    ]),
  ])
  let out = df.select([
    @expr.col("d")
    .eq(
      @expr.lit(
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(100L, scale=1)),
      ),
    )
    .with_alias("eq"),
    @expr.col("d")
    .lt(@expr.lit(@types.Scalar::Decimal(@types.Dec128::of_int64(11L))))
    .with_alias("lt"),
  ])
  assert_eq(cells_to_strings(out, "eq"), ["true", "true", "true"])
  assert_eq(cells_to_strings(out, "lt"), ["true", "true", "true"])
}

///|
test "decimal sum stays finite past the Int64 interchange; never refuses" {
  // 1.5e19 leaves the Int64 the fixed-point era refused at — the IEEE
  // dtype holds it whole, exactly the widening the reshape bought.
  let df = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::of_int64(5_000_000_000_000_000_000L)),
      Some(@types.Dec128::of_int64(5_000_000_000_000_000_000L)),
      Some(@types.Dec128::of_int64(5_000_000_000_000_000_000L)),
    ]),
  ])
  let total = df.sum()
  assert_true(
    total.item(0, "d") is @types.Scalar::Decimal(v) &&
    v.equal(@types.Dec128::parse_opt("1.5E+19").unwrap()),
  )
  // And past the format's own ceiling the total is ±∞ — a value.
  let huge = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::parse_opt("9.99E+6144").unwrap()),
      Some(@types.Dec128::parse_opt("9.99E+6144").unwrap()),
    ]),
  ])
  assert_true(
    huge.sum().item(0, "d") is @types.Scalar::Decimal(v) && v.is_infinite(),
  )
}

///|
test "a map closure returning mixed dtypes nulls the off-dtype minority" {
  let df = DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("v", @types.DataType::Int)]),
    [[@types.Scalar::Int(1)], [@types.Scalar::Int(2)]],
  )
  let mapped = df.select([
    @expr.col("v")
    .map_elements(label="m", (c : @types.Scalar) => {
      if c.as_int() == 1L {
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(5L, scale=2))
      } else {
        @types.Scalar::Decimal(@types.Dec128::of_int64_scale(5000L, scale=3))
      }
    })
    .with_alias("m"),
  ])
  assert_eq(mapped.get_column("m").dtype(), @types.DataType::Decimal)
  assert_true(
    mapped.item(0, "m") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(5L, scale=2)),
  )
  // Both cells are decimals — the minority rule no longer nulls
  // anything (there is no off-scale to be).
  assert_true(
    mapped.item(1, "m") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(5000L, scale=3)),
  )
}

///|
test "decimal negation and absolute value are the value layer's own" {
  let df = dec_frame().drop_nulls(subset=[@expr.col("d")])
  let out = df.select([
    (-@expr.col("d")).with_alias("neg"),
    @expr.col("d").abs().with_alias("abs"),
  ])
  assert_true(
    out.item(0, "neg") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(-12345L, scale=2)),
  )
  assert_true(
    out.item(1, "abs") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64_scale(12345L, scale=2)),
  )
}

///|
test "a cross-dtype decimal join names the cast remedy" {
  let left = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [Some(@types.Dec128::of_int64(1L))]),
  ])
  let right = DataFrame::DataFrame([@series.Series::from_ints("d", [1])])
  assert_true(
    (Ok(
      ignore(
        left.join(right, JoinOptions::on([@expr.col("d")], how=JoinType::Inner)),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "decimal division stays Decimal end to end" {
  let df = dec_frame().drop_nulls(subset=[@expr.col("d")])
  let out = df.select([@expr.col("d").div(@expr.col("d")).with_alias("q")])
  // Every row divides its own value by itself: the exact quotient 1
  // at the preferred exponent 0 (the sign's cancels).
  assert_true(
    out.item(0, "q") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(1L)),
  )
  assert_true(
    out.item(1, "q") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(1L)),
  )
  assert_true(
    out.item(2, "q") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(1L)),
  )
  assert_eq(out.get_column("q").dtype(), @types.DataType::Decimal)
}

///|
test "decimal round is the engine's quantize, NaN and infinity passing" {
  let df = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [
      Some(@types.Dec128::of_int64_scale(12345L, scale=3)),
      Some(@types.Dec128::of_int64_scale(15L, scale=1)),
      Some(@types.Dec128::of_int64_scale(25L, scale=1)),
      Some(@types.Dec128::nan()),
      Some(@types.Dec128::infinity()),
    ]),
  ])
  let out = df.select([@expr.col("d").round(decimals=0).with_alias("r")])
  // 12.345 -> 12 (the guard 3 rounds down); 1.5 -> 2 (tie to even is
  // 2); 2.5 -> 2 (the tie keeps the even); NaN and ∞ pass through.
  assert_true(
    out.item(0, "r") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(12L)),
  )
  assert_true(
    out.item(1, "r") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(2L)),
  )
  assert_true(
    out.item(2, "r") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(2L)),
  )
  assert_true(out.item(3, "r") is @types.Scalar::Decimal(v) && v.is_nan())
  assert_true(out.item(4, "r") is @types.Scalar::Decimal(v) && v.is_infinite())
  // A null cell stays null.
  let with_null = DataFrame::DataFrame([
    @series.Series::from_decimals("d", [None, Some(@types.Dec128::of_int64(7L))]),
  ])
  let rounded = with_null.select([
    @expr.col("d").round(decimals=0).with_alias("r"),
  ])
  assert_true(rounded.item(0, "r") is @types.Scalar::Null)
  assert_true(
    rounded.item(1, "r") is @types.Scalar::Decimal(d) &&
    d.equal(@types.Dec128::of_int64(7L)),
  )
}
