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
  // A different scale is a different dtype: no cross-scale compare yet.
  let other_scale = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Decimal(3)),
    ]),
    [[@types.Scalar::Decimal(3, 10000L)]],
  )
  assert_true(
    (Ok(
      ignore(
        other_scale.filter(
          @expr.col("d").lt(@expr.lit(@types.Scalar::Decimal(2, 1000L))),
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
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
  // Arithmetic on the cells is fenced pending the rescale rules.
  assert_true(
    (Ok(ignore(df.select([@expr.col("d").add(@expr.lit_int(1L))]))) catch {
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
