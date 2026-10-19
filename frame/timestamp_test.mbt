// The `Timestamp` dtype acceptance suite, the `Date` suite's shape over the
// second I64 rider: microseconds since the epoch, riding the registry, ISO
// rendering with a six-digit fraction, comparison / sort / group / join over
// the raw counts, and the same fences (no arithmetic, no cross-dtype compare,
// no cast, no inference, `dt_*` stays Date-only).

///|
/// A small frame with a `Timestamp` column: the epoch-midnight of 2024, a
/// day plus two hours into 2024, one null, and 2024-01-02 midnight.
fn ts_frame() -> DataFrame raise @types.DataError {
  DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("t", @types.DataType::Timestamp),
      @types.Field::Field("v", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Timestamp(1704067200000000L), @types.Scalar::Int(1)],
      [@types.Scalar::Timestamp(1704161060000000L), @types.Scalar::Int(2)],
      [@types.Scalar::Null, @types.Scalar::Int(3)],
      [@types.Scalar::Timestamp(1704153600000000L), @types.Scalar::Int(4)],
    ],
  )
}

///|
test "a Timestamp column keeps its identity through build and read" {
  let df = ts_frame()
  assert_eq(df.get_column("t").dtype(), @types.DataType::Timestamp)
  assert_true(df.item(0, "t") is @types.Scalar::Timestamp(1704067200000000L))
  assert_true(df.item(2, "t") is @types.Scalar::Null)
  assert_eq(df.item(0, "t").to_string(), "2024-01-01T00:00:00.000000")
  assert_eq(df.item(1, "t").to_string(), "2024-01-02T02:04:20.000000")
  assert_eq(cells_to_strings(df, "t"), [
    "2024-01-01T00:00:00.000000", "2024-01-02T02:04:20.000000", "null", "2024-01-02T00:00:00.000000",
  ])
}

///|
test "Timestamp compares instant-wise; an Int never reaches the cells" {
  let df = ts_frame()
  assert_eq(
    cells_to_strings(
      df.filter(
        @expr.col("t").lt(
          @expr.lit(@types.Scalar::Timestamp(1704153600000000L)),
        ),
      ),
      "t",
    ),
    ["2024-01-01T00:00:00.000000"],
  )
  // The shared I64 buffer must not let a raw microsecond `Int` literal in.
  assert_true(
    (Ok(ignore(df.filter(@expr.col("t").lt(@expr.lit_int(1704153600000000L))))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "Timestamp sorts chronologically and reduces positionally" {
  let df = ts_frame()
  let sorted = df.sort([(@expr.col("t"), false, true)])
  // The rider rebuilds frames through the shared verbs; the shape
  // invariants ride the representative outputs.
  assert_eq(sorted.check_invariants(), Ok(()))
  assert_eq(cells_to_strings(sorted, "t"), [
    "2024-01-01T00:00:00.000000", "2024-01-02T00:00:00.000000", "2024-01-02T02:04:20.000000",
    "null",
  ])
  assert_eq(df.get_column("t").min().to_string(), "2024-01-01T00:00:00.000000")
  assert_eq(df.get_column("t").max().to_string(), "2024-01-02T02:04:20.000000")
}

///|
test "Timestamp groups by instant; arithmetic reductions are fenced" {
  let df = ts_frame().drop_nulls(subset=[@expr.col("t")])
  let grouped = df
    .group_by([@expr.col("t")])
    .agg([@expr.col("v").sum().with_alias("total")])
  assert_true(grouped.nrows() == 3)
  assert_true(
    (Ok(ignore(df.get_column("t").sum())) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "Timestamp renders ISO and interchanges as text" {
  let df = ts_frame().drop_nulls(subset=[@expr.col("t")])
  let csv = @io.format_csv(df)
  assert_true(csv.contains("2024-01-01T00:00:00.000000"))
  let json = @io.format_json(df)
  assert_true(json.contains("2024-01-02T02:04:20.000000"))
  assert_true(df.describe().to_markdown().contains("Timestamp"))
}

///|
test "Timestamp is never inferred, never cast; dt_* stays Date-only" {
  let from_csv = @io.parse_csv_str("t\n2024-01-01T00:00:00.000000")
  assert_eq(from_csv.get_column("t").dtype(), @types.DataType::String)
  let df = ts_frame().drop_nulls(subset=[@expr.col("t")])
  assert_true(
    (Ok(ignore(df.get_column("t").cast(@types.DataType::Int))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  assert_true(
    (Ok(ignore(df.get_column("t").cast(@types.DataType::Timestamp))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
  // The calendar verbs are Date's: a Timestamp column does not quietly read
  // its cells as day counts.
  assert_true(
    (Ok(ignore(df.select([@expr.col("t").dt_year()]))) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "a Timestamp literal evaluates and fills through the expression engine" {
  let df = ts_frame()
  let out = df.select([
    @expr.lit(@types.Scalar::Timestamp(0L)).with_alias("epoch"),
  ])
  assert_eq(out.get_column("epoch").dtype(), @types.DataType::Timestamp)
  assert_eq(out.item(0, "epoch").to_string(), "1970-01-01T00:00:00.000000")
  // fill_null with a Timestamp keeps the column a Timestamp.
  let filled = df.with_columns([
    @expr.col("t")
    .fill_null(@expr.lit(@types.Scalar::Timestamp(0L)))
    .with_alias("tf"),
  ])
  assert_eq(filled.get_column("tf").dtype(), @types.DataType::Timestamp)
  assert_eq(filled.item(2, "tf").to_string(), "1970-01-01T00:00:00.000000")
  // An Int scalar must not fill through the shared buffer.
  assert_true(
    (Ok(ignore(df.get_column("t").fill_null(@types.Scalar::Int(0L)))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "an outer join coalesces a Timestamp key to the present side's instant" {
  let left = ts_frame()
    .drop_nulls(subset=[@expr.col("t")])
    .drop([@expr.col("v")])
  let right = DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("t", @types.DataType::Timestamp),
      @types.Field::Field("w", @types.DataType::Int),
    ]),
    [
      [@types.Scalar::Timestamp(1704067200000000L), @types.Scalar::Int(10)],
      [@types.Scalar::Timestamp(1704240000000000L), @types.Scalar::Int(20)],
    ],
  )
  let joined = left.join(
    right,
    @frame.JoinOptions::on(
      [@expr.col("t")],
      how=@frame.JoinType::Outer,
      coalesce=true,
    ),
  )
  // The 2024-01-03 instant exists only on the right: the coalesced key
  // carries its timestamp, the left side's cells are null.
  assert_true(joined.nrows() == 4)
  assert_eq(joined.get_column("t").dtype(), @types.DataType::Timestamp)
  assert_eq(cells_to_strings(joined, "t"), [
    "2024-01-01T00:00:00.000000", "2024-01-02T02:04:20.000000", "2024-01-02T00:00:00.000000",
    "2024-01-03T00:00:00.000000",
  ])
}

///|
test "an empty Timestamp column exists at zero rows" {
  let df = DataFrame::empty(
    @types.Schema::Schema([@types.Field::Field("t", @types.DataType::Timestamp)]),
  )
  assert_eq(df.get_column("t").dtype(), @types.DataType::Timestamp)
  assert_true(df.get_column("t").len() == 0)
}

///|
test "Timestamp rides the remaining engine paths" {
  // `Series::from_scalars` with an explicit target builds the column through
  // the same projection (off-type cells null under the dtype gate).
  let s = @series.Series::from_scalars(
    "t",
    [
      @types.Scalar::Timestamp(0L),
      @types.Scalar::Null,
      @types.Scalar::Timestamp(1704067200000000L),
    ],
    dtype=@types.DataType::Timestamp,
  )
  assert_eq(s.dtype(), @types.DataType::Timestamp)
  assert_true(s.get(1) is @types.Scalar::Null)
  // The `Series::fill_null` surface (the expression engine's fill rides the
  // ternary kernel, not this one): a Timestamp scalar fills, an Int does not.
  let filled = s.fill_null(@types.Scalar::Timestamp(-1L)).to_scalars()
  assert_eq(filled[1].to_string(), "1969-12-31T23:59:59.999999")
  assert_true(
    (Ok(ignore(s.fill_null(@types.Scalar::Int(0L)))) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // A `map_elements` closure returning Timestamp cells fixes that dtype.
  let mapped = ts_frame()
    .drop_nulls(subset=[@expr.col("t")])
    .with_columns([
      @expr.col("v")
      .map_elements(label="ts", (c : @types.Scalar) => {
        @types.Scalar::Timestamp(c.as_int() * 60_000_000L)
      })
      .with_alias("minute_marks"),
    ])
  assert_eq(
    mapped.get_column("minute_marks").dtype(),
    @types.DataType::Timestamp,
  )
  assert_eq(
    mapped.item(0, "minute_marks").to_string(),
    "1970-01-01T00:01:00.000000",
  )
  // The expression literal renders its value form in its `Show` spelling
  // (the rendering `LazyFrame::explain` prints).
  let explained = @expr.lit(@types.Scalar::Timestamp(-1L))
    .with_alias("before")
    .to_string()
  assert_true(explained.contains("1969-12-31T23:59:59.999999"))
  // An Int column cast *to* Timestamp refuses (the target arm of the gate).
  assert_true(
    (Ok(ignore(ts_frame().get_column("v").cast(@types.DataType::Timestamp))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::Unsupported(_)),
  )
}

///|
test "the microsecond fraction pads each magnitude to six digits" {
  // One value per order of magnitude, epoch-day plus the fraction.
  fn at(frac : Int64) -> Int64 {
    1704067200000000L + frac
  }

  assert_eq(
    @types.Scalar::Timestamp(at(1L)).to_string(),
    "2024-01-01T00:00:00.000001",
  )
  assert_eq(
    @types.Scalar::Timestamp(at(12L)).to_string(),
    "2024-01-01T00:00:00.000012",
  )
  assert_eq(
    @types.Scalar::Timestamp(at(123L)).to_string(),
    "2024-01-01T00:00:00.000123",
  )
  assert_eq(
    @types.Scalar::Timestamp(at(1234L)).to_string(),
    "2024-01-01T00:00:00.001234",
  )
  assert_eq(
    @types.Scalar::Timestamp(at(12345L)).to_string(),
    "2024-01-01T00:00:00.012345",
  )
  // The debug form carries the same rendering.
  // The debug form is the derived raw payload; the  rendering (what
  //  prints) carries the ISO spelling.
  assert_eq(
    @types.Scalar::Timestamp(at(123456L)).to_repr().to_string(),
    "Timestamp(1704067200123456)",
  )
  println(@types.Scalar::Timestamp(at(123456L)))
}

///|
test "off-type cells refuse or null per each layer's contract" {
  // `from_scalars` with an explicit dtype raises on the first off-type cell.
  assert_true(
    (Ok(
      ignore(
        @series.Series::from_scalars(
          "t",
          [@types.Scalar::Int(1L)],
          dtype=@types.DataType::Timestamp,
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // `from_rows` refuses an off-type cell under a Timestamp field the same way.
  assert_true(
    (Ok(
      ignore(
        DataFrame::from_rows(
          @types.Schema::Schema([
            @types.Field::Field("t", @types.DataType::Timestamp),
          ]),
          [[@types.Scalar::Int(1L)]],
        ),
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
  // A map closure mixing Timestamp and Int cells fixes Timestamp (the first
  // non-null) and nulls the minority — the projection's off-type contract.
  let mixed = ts_frame()
    .drop_nulls(subset=[@expr.col("t")])
    .with_columns([
      @expr.col("v")
      .map_elements(label="mix", (c : @types.Scalar) => {
        if c.as_int() == 1 {
          @types.Scalar::Timestamp(0L)
        } else {
          @types.Scalar::Int(99L)
        }
      })
      .with_alias("mixed"),
    ])
  assert_eq(mixed.get_column("mixed").dtype(), @types.DataType::Timestamp)
  assert_true(mixed.item(0, "mixed") is @types.Scalar::Timestamp(0L))
  assert_true(mixed.item(1, "mixed") is @types.Scalar::Null)
  // A Timestamp scalar does not fill an Int column (the gate's other side).
  assert_true(
    (Ok(
      ignore(ts_frame().get_column("v").fill_null(@types.Scalar::Timestamp(0L))),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}
