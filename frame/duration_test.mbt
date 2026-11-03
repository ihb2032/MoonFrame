// The `Duration` dtype acceptance suite — the fourth I64 rider's shape:
// microsecond spans, ISO 8601 days-and-time rendering, the temporal
// arithmetic that produces and consumes them, ordering / grouping / join
// over the raw spans, and the fences (no numeric arithmetic, no sum, no
// cast either side, no reader parser).

///|
fn spans_frame() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_duration_options("d", [
      Some(0L),
      Some(86_400_000_000L),
      None,
      Some(-1L),
    ]),
    Series::from_ints("v", [1, 2, 3, 4]),
  ])
}

///|
test "a Duration column renders ISO 8601 days-and-time" {
  assert_eq(@types.Scalar::Duration(0L).to_string(), "PT0.000000S")
  assert_eq(
    @types.Scalar::Duration(86_400_000_000L).to_string(),
    "P1DT0.000000S",
  )
  // Two hours, three minutes, and 61 microseconds past a day.
  assert_eq(
    @types.Scalar::Duration(
      86_400_000_000L + 7_200_000_000L + 180_000_000L + 61L,
    ).to_string(),
    "P1DT2H3M0.000061S",
  )
  assert_eq(@types.Scalar::Duration(-1L).to_string(), "-PT0.000001S")
  assert_eq(
    @types.Scalar::Duration(3_600_000_000L).to_string(),
    "PT1H0.000000S",
  )
  // `MIN`'s own magnitude is not a positive `Int64`; the rendering still
  // answers, negated whole.
  let far = @types.Scalar::Duration(-9_223_372_036_854_775_808L).to_string()
  assert_true(far.contains("-") && far.contains("D") && far.contains("S"))
}

///|
test "the debug form is the raw payload, the Show form the ISO spelling" {
  assert_eq(
    @types.Scalar::Duration(86_400_000_000L).to_repr().to_string(),
    "Duration(86400000000)",
  )
}

///|
test "timestamp − timestamp and date − date produce Duration" {
  let df = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Timestamp),
      @types.Field::Field("b", @types.DataType::Timestamp),
      @types.Field::Field("c", @types.DataType::Date),
      @types.Field::Field("e", @types.DataType::Date),
    ]),
    [
      [
        @types.Scalar::Timestamp(1_704_121_460_123_456L),
        @types.Scalar::Timestamp(1_704_067_200_000_000L),
        @types.Scalar::Date(2L),
        @types.Scalar::Date(5L),
      ],
      [
        @types.Scalar::Timestamp(0L),
        @types.Scalar::Null,
        @types.Scalar::Date(2L),
        @types.Scalar::Date(2L),
      ],
    ],
  )
  let out = df.select([
    (@expr.col("a") - @expr.col("b")).with_alias("gap"),
    (@expr.col("c") - @expr.col("e")).with_alias("day_gap"),
  ])
  assert_eq(out.get_column("gap").dtype(), @types.DataType::Duration)
  assert_eq(out.get_column("gap").to_scalars(), [
    @types.Scalar::Duration(542_601_234_56L),
    @types.Scalar::Null,
  ])
  // Three days, as a microsecond span.
  assert_eq(out.get_column("day_gap").to_scalars(), [
    @types.Scalar::Duration(-259_200_000_000L),
    @types.Scalar::Duration(0L),
  ])
}

///|
test "an instant ± a Duration stays a microsecond instant" {
  let df = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("t", @types.DataType::Timestamp),
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("s", @types.DataType::Duration),
    ]),
    [
      [
        @types.Scalar::Timestamp(0L),
        @types.Scalar::Date(0L),
        @types.Scalar::Duration(61L),
      ],
      [
        @types.Scalar::Null,
        @types.Scalar::Date(-1L),
        @types.Scalar::Duration(-86_400_000_000L),
      ],
    ],
  )
  let out = df.select([
    (@expr.col("t") + @expr.col("s")).with_alias("shifted"),
    (@expr.col("t") - @expr.col("s")).with_alias("back"),
    (@expr.col("d") + @expr.col("s")).with_alias("from_date"),
  ])
  assert_eq(out.get_column("shifted").dtype(), @types.DataType::Timestamp)
  assert_eq(out.item(0, "shifted").to_string(), "1970-01-01T00:00:00.000061")
  assert_true(out.item(1, "shifted") is @types.Scalar::Null)
  assert_eq(out.item(0, "back").to_string(), "1969-12-31T23:59:59.999939")
  // A Date plus a Duration promotes to Timestamp — the sub-day half the
  // date dtype cannot hold.
  assert_eq(out.get_column("from_date").dtype(), @types.DataType::Timestamp)
  assert_eq(out.item(0, "from_date").to_string(), "1970-01-01T00:00:00.000061")
  assert_eq(out.item(1, "from_date").to_string(), "1969-12-30T00:00:00.000000")
}

///|
test "a shift that leaves the range refuses; the other pairs decline" {
  let df = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("t", @types.DataType::Timestamp),
      @types.Field::Field("s", @types.DataType::Duration),
    ]),
    [
      [
        @types.Scalar::Timestamp(9_223_372_036_854_775_807L),
        @types.Scalar::Duration(1L),
      ],
    ],
  )
  assert_true(
    (Ok(ignore(df.select([(@expr.col("t") + @expr.col("s")).with_alias("x")]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // Duration with Duration, and Duration with a numeric, are not
  // temporal pairs — the numeric path refuses them.
  let spans = spans_frame().drop_nulls(subset=[@expr.col("d")])
  assert_true(
    (Ok(
      ignore(spans.select([(@expr.col("d") + @expr.col("d")).with_alias("x")])),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  assert_true(
    (Ok(
      ignore(
        spans.select([(@expr.col("d") + @expr.lit_int(1)).with_alias("x")]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // And `sum` stays fenced (a summed span is arithmetic, not a reduction
  // the exactness contract covers).
  assert_true(
    (Ok(ignore(spans.get_column("d").sum())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "Duration orders, groups, joins, and reduces its extremes" {
  let df = spans_frame()
  let sorted = df.sort([(@expr.col("d"), false, true)])
  assert_eq(cells_to_strings(sorted, "d"), [
    "-PT0.000001S", "PT0.000000S", "P1DT0.000000S", "null",
  ])
  assert_eq(df.get_column("d").min().to_string(), "-PT0.000001S")
  assert_eq(df.get_column("d").max().to_string(), "P1DT0.000000S")
  // Group / join key on the raw spans — the null span its own group, so
  // four groups over the four distinct keys.
  let grouped = df
    .group_by([@expr.col("d")])
    .agg([@expr.col("v").sum().with_alias("total")])
  assert_eq(grouped.nrows(), 4)
  let joined = df.join(
    DataFrame::DataFrame([
      Series::from_duration_options("d", [Some(0L)]),
      Series::from_ints("w", [10]),
    ]),
    @frame.JoinOptions::on([@expr.col("d")], how=@frame.JoinType::Inner),
  )
  assert_eq(joined.nrows(), 1)
  assert_eq(joined.item(0, "w"), @types.Scalar::Int(10))
}

///|
test "Duration fills, casts, and interchanges as text" {
  let df = spans_frame()
  let filled = df.with_columns([
    @expr.col("d")
    .fill_null(@expr.lit(@types.Scalar::Duration(0L)))
    .with_alias("f"),
  ])
  assert_eq(filled.get_column("f").dtype(), @types.DataType::Duration)
  assert_eq(filled.item(2, "f").to_string(), "PT0.000000S")
  // An Int scalar must not fill through the shared buffer.
  assert_true(
    (Ok(ignore(df.get_column("d").fill_null(@types.Scalar::Int(0L)))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // Cast refuses both sides.
  assert_true(
    (Ok(ignore(df.get_column("d").cast(@types.DataType::String))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  // The writers render the ISO spelling; the readers read it back as
  // text (there is no Duration parser).
  let csv = @io.format_csv(df)
  assert_true(csv.contains("P1DT0.000000S"))
  let json = @io.format_json(df)
  assert_true(json.contains("-PT0.000001S"))
  assert_eq(
    @io.parse_csv_str(csv).get_column("d").dtype(),
    @types.DataType::String,
  )
  // And a `dtypes` pin refuses it.
  let opts = @io.CsvReadOptions::CsvReadOptions(
    dtypes=Map([("d", @types.DataType::Duration)]),
  )
  assert_true(
    (Ok(@io.parse_csv_str(csv, options=opts)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "an empty Duration column and a whole-frame extremum exist" {
  let df = DataFrame::empty(
    @types.Schema::Schema([@types.Field::Field("d", @types.DataType::Duration)]),
  )
  assert_eq(df.get_column("d").dtype(), @types.DataType::Duration)
  assert_true(df.get_column("d").len() == 0)
  // The whole-frame min / max answers for the orderable rider.
  let frame = spans_frame()
  let summary = frame.min()
  assert_eq(summary.item(0, "d").to_string(), "-PT0.000001S")
  assert_eq(frame.max().item(0, "d").to_string(), "P1DT0.000000S")
}

///|
test "the fraction magnitude renders through each pad width" {
  assert_eq(@types.Scalar::Duration(123L).to_string(), "PT0.000123S")
  assert_eq(@types.Scalar::Duration(1234L).to_string(), "PT0.001234S")
  assert_eq(@types.Scalar::Duration(12345L).to_string(), "PT0.012345S")
  assert_eq(@types.Scalar::Duration(123456L).to_string(), "PT0.123456S")
  println(@types.Scalar::Duration(123456L))
}

///|
test "a Duration literal evaluates, renders, and fills through the engine" {
  let df = spans_frame()
  let out = df.select([
    @expr.lit(@types.Scalar::Duration(61L)).with_alias("tick"),
  ])
  assert_eq(out.get_column("tick").dtype(), @types.DataType::Duration)
  assert_eq(out.item(0, "tick").to_string(), "PT0.000061S")
  // The explain rendering carries the value form.
  let explained = @expr.lit(@types.Scalar::Duration(-1L))
    .with_alias("back")
    .to_string()
  assert_true(explained.contains("-PT0.000001S"))
  // A map closure returning Duration cells fixes that dtype; a mixed
  // minority nulls.
  let mapped = df.with_columns([
    @expr.col("v")
    .map_elements(label="span", (c : @types.Scalar) => {
      @types.Scalar::Duration(c.as_int() * 1_000_000L)
    })
    .with_alias("spans"),
  ])
  assert_eq(mapped.get_column("spans").dtype(), @types.DataType::Duration)
  assert_eq(mapped.item(0, "spans").to_string(), "PT1.000000S")
  // `Series::from_scalars` with an explicit dtype builds the projection,
  // and an off-type cell under it raises.
  let s = @series.Series::from_scalars(
    "d",
    [@types.Scalar::Duration(0L), @types.Scalar::Null],
    dtype=@types.DataType::Duration,
  )
  assert_eq(s.dtype(), @types.DataType::Duration)
  assert_true(
    (Ok(
      ignore(
        @series.Series::from_scalars(
          "d",
          [@types.Scalar::Int(1L)],
          dtype=@types.DataType::Duration,
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // The distinctness toolbox reads the spans as keys — four distinct
  // spans, the null its own.
  assert_eq(df.get_column("d").n_unique(), 4)
  // An outer join coalescing an unmatched Duration key fills through the
  // shared buffer's rider spelling.
  let joined = spans_frame().join(
    DataFrame::DataFrame([
      Series::from_duration_options("d", [Some(123L)]),
      Series::from_ints("w", [10]),
    ]),
    @frame.JoinOptions::on(
      [@expr.col("d")],
      how=@frame.JoinType::Outer,
      coalesce=true,
    ),
  )
  assert_true(joined.get_column("d").dtype() is @types.DataType::Duration)
  // Four left rows plus the right's unmatched span.
  assert_eq(joined.nrows(), 5)
  // Casting *to* Duration refuses, like every other rider target.
  assert_true(
    (Ok(ignore(df.get_column("v").cast(@types.DataType::Duration))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
}

///|
test "the checked temporal refusals fire on each shape" {
  fn dates_frame(a : Int64, b : Int64) -> DataFrame raise @types.DataError {
    DataFrame::from_rows(
      @types.Schema::Schema([
        @types.Field::Field("a", @types.DataType::Date),
        @types.Field::Field("b", @types.DataType::Date),
      ]),
      [[@types.Scalar::Date(a), @types.Scalar::Date(b)]],
    )
  }
  // A day difference that overflows the microsecond span.
  let huge_days = dates_frame(
    9_223_372_036_854_775_807L, -9_223_372_036_854_775_808L,
  )
  assert_true(
    (Ok(
      ignore(
        huge_days.select([(@expr.col("a") - @expr.col("b")).with_alias("x")]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // A timestamp difference off the far end: subtracting MIN from a
  // non-negative instant.
  let ts = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Timestamp),
      @types.Field::Field("b", @types.DataType::Timestamp),
    ]),
    [
      [
        @types.Scalar::Timestamp(0L),
        @types.Scalar::Timestamp(-9_223_372_036_854_775_808L),
      ],
    ],
  )
  assert_true(
    (Ok(ignore(ts.select([(@expr.col("a") - @expr.col("b")).with_alias("x")]))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // A Date whose microsecond instant plus the span leaves the range, and
  // a Timestamp shifted past MIN.
  let shift_frame = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("t", @types.DataType::Timestamp),
      @types.Field::Field("s", @types.DataType::Duration),
    ]),
    [
      [
        @types.Scalar::Date(9_223_372_036_854_775_807L),
        @types.Scalar::Timestamp(-9_223_372_036_854_775_808L),
        @types.Scalar::Duration(1L),
      ],
    ],
  )
  assert_true(
    (Ok(
      ignore(
        shift_frame.select([(@expr.col("d") + @expr.col("s")).with_alias("x")]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(
      ignore(
        shift_frame.select([(@expr.col("t") - @expr.col("s")).with_alias("x")]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "the remaining temporal overflow shapes and engine reads" {
  // A day count that fits but scales past the microsecond range, in both
  // the difference and the shift spelling.
  fn dates(a : Int64, b : Int64) -> DataFrame raise @types.DataError {
    DataFrame::from_rows(
      @types.Schema::Schema([
        @types.Field::Field("a", @types.DataType::Date),
        @types.Field::Field("b", @types.DataType::Date),
      ]),
      [[@types.Scalar::Date(a), @types.Scalar::Date(b)]],
    )
  }
  assert_true(
    (Ok(
      ignore(
        dates(9_223_372_036_854_775_807L, 0L).select([
          (@expr.col("a") - @expr.col("b")).with_alias("x"),
        ]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // A day count whose instant fits, and a span that shifts it past MAX.
  let day_plus = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("d", @types.DataType::Date),
      @types.Field::Field("s", @types.DataType::Duration),
    ]),
    [
      [
        @types.Scalar::Date(1L),
        @types.Scalar::Duration(9_223_372_036_854_775_807L),
      ],
    ],
  )
  assert_true(
    (Ok(
      ignore(
        day_plus.select([(@expr.col("d") + @expr.col("s")).with_alias("x")]),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // Subtracting MIN from a negative instant is the one difference that
  // lands exactly on MAX — the subtrahend-MIN arm's success half.
  let to_the_max = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("a", @types.DataType::Timestamp),
      @types.Field::Field("b", @types.DataType::Timestamp),
    ]),
    [
      [
        @types.Scalar::Timestamp(-1L),
        @types.Scalar::Timestamp(-9_223_372_036_854_775_808L),
      ],
    ],
  )
  assert_eq(
    to_the_max
    .select([(@expr.col("a") - @expr.col("b")).with_alias("x")])
    .item(0, "x"),
    @types.Scalar::Duration(9_223_372_036_854_775_807L),
  )
  // The scalar's own dtype read, and the from-rows off-type refusal.
  assert_eq(@types.Scalar::Duration(0L).dtype(), @types.DataType::Duration)
  assert_true(
    (Ok(
      ignore(
        DataFrame::from_rows(
          @types.Schema::Schema([
            @types.Field::Field("d", @types.DataType::Duration),
          ]),
          [[@types.Scalar::Int(1L)]],
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // A Duration scalar filling a non-Duration column is the arm's own
  // mismatch refusal.
  assert_true(
    (Ok(
      ignore(
        spans_frame().get_column("v").fill_null(@types.Scalar::Duration(0L)),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "the Series-level fill and the mixed-cell projection" {
  let filled = spans_frame()
    .get_column("d")
    .fill_null(@types.Scalar::Duration(0L))
  assert_eq(filled.dtype(), @types.DataType::Duration)
  assert_eq(filled.get(2).to_string(), "PT0.000000S")
  // A map closure mixing Duration and Int cells fixes Duration and nulls
  // the minority — the projection's off-type contract.
  let mixed = spans_frame().with_columns([
    @expr.col("v")
    .map_elements(label="mix", (c : @types.Scalar) => {
      if c.as_int() == 1 {
        @types.Scalar::Duration(0L)
      } else {
        @types.Scalar::Int(99L)
      }
    })
    .with_alias("mixed"),
  ])
  assert_eq(mixed.get_column("mixed").dtype(), @types.DataType::Duration)
  assert_true(mixed.item(0, "mixed") is @types.Scalar::Duration(0L))
  assert_true(mixed.item(1, "mixed") is @types.Scalar::Null)
}
