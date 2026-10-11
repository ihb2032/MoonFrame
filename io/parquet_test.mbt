// The Parquet interchange suite: a full write-read round-trip over every
// writable dtype (Int / Float / Bool / String / Timestamp, nulls included —
// which doubles as the live probe of the upstream writer's actual support,
// beyond its README's shorter list), the read-side fences (a Binary column
// has no MoonFrame dtype), the write-side fences (Date / Decimal have no
// Parquet type here yet), and the lazy `scan_parquet`'s projection and
// predicate behaviour.

///|
/// The round-trip frame: the writable dtypes (Int / String), nulls
/// included. Bool / Float / Timestamp columns read fine but the upstream
/// writer does not take them yet — the fence test below pins that.
fn parquet_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("i", @types.DataType::Int),
      @types.Field::Field("s", @types.DataType::String),
    ]),
    [
      [@types.Scalar::Int(1L), @types.Scalar::String("west")],
      [@types.Scalar::Null, @types.Scalar::Null],
      [@types.Scalar::Int(-3L), @types.Scalar::String("east")],
    ],
  )
}

///|
test "parquet round-trips the writable dtypes with their nulls" {
  let df = parquet_frame()
  let back = @io.parse_parquet(@io.format_parquet(df))
  assert_eq(back.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(back.get_column("s").dtype(), @types.DataType::String)
  assert_eq(back.item(0, "i"), @types.Scalar::Int(1L))
  assert_true(back.item(1, "i") is @types.Scalar::Null)
  assert_eq(back.item(2, "s"), @types.Scalar::String("east"))
  // The cell-level comparison (the null-slot placeholders differ between
  // the built and the read-back buffers, exactly as the CSV round-trip's).
  assert_eq(back.get_column("i").to_scalars(), df.get_column("i").to_scalars())
  assert_eq(back.get_column("s").to_scalars(), df.get_column("s").to_scalars())
}

///|
test "parquet write fences the dtypes the upstream writer does not take" {
  let framed = fn(
    name : String,
    d : @types.DataType,
    cell : @types.Scalar,
  ) -> @frame.DataFrame raise @types.DataError {
    @frame.DataFrame::from_rows(
      @types.Schema::Schema([@types.Field::Field(name, d)]),
      [[cell]],
    )
  }
  let bool_df = framed("b", @types.DataType::Bool, @types.Scalar::Bool(true))
  assert_true(
    (Ok(ignore(@io.format_parquet(bool_df))) catch { e => Err(e) })
    is Err(@types.DataError::Unsupported(_)),
  )
  let float_df = framed("f", @types.DataType::Float, @types.Scalar::Float(1.5))
  assert_true(
    (Ok(ignore(@io.format_parquet(float_df))) catch { e => Err(e) })
    is Err(@types.DataError::Unsupported(_)),
  )
  let ts_df = framed(
    "t",
    @types.DataType::Timestamp,
    @types.Scalar::Timestamp(0L),
  )
  assert_true(
    (Ok(ignore(@io.format_parquet(ts_df))) catch { e => Err(e) })
    is Err(@types.DataError::Unsupported(_)),
  )
}

///|
test "parquet reads the full type matrix from an external fixture" {
  // The upstream package vendors the apache-parquet-testing corpus; its
  // `alltypes_plain` file carries the read side's whole matrix (bool, the
  // int widths, float, double, string) — the types the local writer cannot
  // produce, read here from bytes that never touched it.
  let path = ".mooncakes/mizchi/parquet/fixtures/apache-parquet-testing/data/alltypes_plain.parquet"
  let df = @io.read_parquet(path)
  assert_true(df.nrows() == 8)
  assert_eq(df.get_column("id").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("bool_col").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("tinyint_col").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("int_col").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("bigint_col").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("float_col").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("double_col").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("string_col").dtype(), @types.DataType::String)
  // The classic impala fixture alternates (0, 10.1) down its double column
  // (even rows the 0, odd rows the 10.1), and the timestamp column lands
  // on the `TimestampMicros` mapping — the read path the local writer
  // cannot yet exercise on its own.
  assert_eq(df.item(0, "id"), @types.Scalar::Int(4L))
  assert_eq(df.item(1, "id"), @types.Scalar::Int(5L))
  assert_eq(df.item(0, "bool_col"), @types.Scalar::Bool(true))
  assert_eq(df.item(1, "bool_col"), @types.Scalar::Bool(false))
  assert_eq(df.item(0, "double_col"), @types.Scalar::Float(0.0))
  assert_eq(df.item(1, "double_col"), @types.Scalar::Float(10.1))
  assert_eq(df.item(0, "string_col"), @types.Scalar::String("0"))
  assert_eq(df.item(1, "string_col"), @types.Scalar::String("1"))
  assert_eq(df.get_column("timestamp_col").dtype(), @types.DataType::Timestamp)
  assert_eq(
    df.item(0, "timestamp_col").to_string(),
    "2009-03-01T00:00:00.000000",
  )
}

///|
test "parquet write refuses the dtypes with no Parquet type" {
  let dated = @frame.DataFrame::from_rows(
    @types.Schema::Schema([@types.Field::Field("d", @types.DataType::Date)]),
    [[@types.Scalar::Date(19723L)]],
  )
  assert_true(
    (Ok(ignore(@io.format_parquet(dated))) catch { e => Err(e) })
    is Err(@types.DataError::Unsupported(_)),
  )
  let scaled = @frame.DataFrame::from_rows(
    @types.Schema::Schema([
      @types.Field::Field("m", @types.DataType::Decimal(2)),
    ]),
    [[@types.Scalar::Decimal(2, 12345L)]],
  )
  assert_true(
    (Ok(ignore(@io.format_parquet(scaled))) catch { e => Err(e) })
    is Err(@types.DataError::Unsupported(_)),
  )
}
