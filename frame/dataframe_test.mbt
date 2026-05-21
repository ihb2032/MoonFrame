// Blackbox tests for `DataFrame`. RowView lives in `row_view_test.mbt`.

// ── Constructors: new ────────────────────────────────────────────────

///|
test "new builds a frame from equal-length, uniquely named columns" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ]).unwrap()
  assert_eq(df.shape(), (3, 2))
  assert_eq(df.nrows(), 3)
  assert_eq(df.ncols(), 2)
  assert_eq(df.columns(), ["a", "b"])
}

///|
test "new with zero columns yields a 0×0 frame" {
  let df = DataFrame::new([]).unwrap()
  assert_eq(df.shape(), (0, 0))
  assert_true(df.is_empty())
  assert_eq(df.columns(), [])
}

///|
test "new rejects columns of unequal length" {
  let r = DataFrame::new([
    Series::from_ints("a", [1, 2]),
    Series::from_ints("b", [1, 2, 3]),
  ])
  assert_eq(r, Err(@types.DataError::LengthMismatch))
}

///|
test "new rejects duplicate column names" {
  let r = DataFrame::new([
    Series::from_ints("a", [1]),
    Series::from_ints("a", [2]),
  ])
  assert_eq(r, Err(@types.DataError::DuplicateColumn("a")))
}

// ── Constructors: empty ──────────────────────────────────────────────

///|
test "empty(schema) builds a 0-row frame with the schema's dtypes" {
  let schema = @types.Schema::new([
    @types.Field::new("i", @types.DataType::Int),
    @types.Field::new("f", @types.DataType::Float),
    @types.Field::new("b", @types.DataType::Bool),
    @types.Field::new("s", @types.DataType::String),
  ]).unwrap()
  let df = DataFrame::empty(schema).unwrap()
  assert_eq(df.shape(), (0, 4))
  assert_true(df.is_empty())
  assert_eq(df.columns(), ["i", "f", "b", "s"])
  // Every column has the right dtype and zero length.
  assert_eq(df.get_column("i").unwrap().dtype(), @types.DataType::Int)
  assert_eq(df.get_column("f").unwrap().dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").unwrap().dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").unwrap().dtype(), @types.DataType::String)
  assert_eq(df.get_column("i").unwrap().len(), 0)
}

///|
test "empty(empty schema) yields a 0×0 frame" {
  let schema = @types.Schema::new([]).unwrap()
  let df = DataFrame::empty(schema).unwrap()
  assert_eq(df.shape(), (0, 0))
  assert_true(df.is_empty())
}

///|
test "empty rejects Null-dtype fields with Unsupported" {
  let schema = @types.Schema::new([
    @types.Field::new("ok", @types.DataType::Int),
    @types.Field::new("nope", @types.DataType::Null),
  ]).unwrap()
  assert_true(DataFrame::empty(schema) is Err(Unsupported(_)))
}

// ── Constructors: from_rows ──────────────────────────────────────────

///|
test "from_rows builds a frame, mixing nulls and concrete cells" {
  let schema = @types.Schema::new([
    @types.Field::new("i", @types.DataType::Int),
    @types.Field::new("f", @types.DataType::Float),
    @types.Field::new("b", @types.DataType::Bool),
    @types.Field::new("s", @types.DataType::String),
  ]).unwrap()
  let df = DataFrame::from_rows(schema, [
    [
      @types.Scalar::Int(1),
      @types.Scalar::Float(1.5),
      @types.Scalar::Bool(true),
      @types.Scalar::String("a"),
    ],
    [
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Null,
      @types.Scalar::Null,
    ],
    [
      @types.Scalar::Int(3),
      @types.Scalar::Float(3.5),
      @types.Scalar::Bool(false),
      @types.Scalar::String("c"),
    ],
  ]).unwrap()
  assert_eq(df.shape(), (3, 4))
  // Row 0 was concrete in every column.
  assert_eq(df.get(0, "i"), Ok(@types.Scalar::Int(1)))
  assert_eq(df.get(0, "f"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(df.get(0, "b"), Ok(@types.Scalar::Bool(true)))
  assert_eq(df.get(0, "s"), Ok(@types.Scalar::String("a")))
  // Row 1 was all-null.
  assert_eq(df.get(1, "i"), Ok(@types.Scalar::Null))
  assert_eq(df.get(1, "f"), Ok(@types.Scalar::Null))
  assert_eq(df.get(1, "b"), Ok(@types.Scalar::Null))
  assert_eq(df.get(1, "s"), Ok(@types.Scalar::Null))
  // Per-column null_count == 1 in every column.
  assert_eq(df.get_column("i").unwrap().null_count(), 1)
  assert_eq(df.get_column("f").unwrap().null_count(), 1)
  assert_eq(df.get_column("b").unwrap().null_count(), 1)
  assert_eq(df.get_column("s").unwrap().null_count(), 1)
}

///|
test "from_rows with empty rows produces a 0×N frame" {
  let schema = @types.Schema::new([@types.Field::new("x", @types.DataType::Int)]).unwrap()
  let df = DataFrame::from_rows(schema, []).unwrap()
  assert_eq(df.shape(), (0, 1))
  assert_true(df.is_empty())
}

///|
test "from_rows rejects rows of the wrong width" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::Int),
  ]).unwrap()
  let r = DataFrame::from_rows(schema, [[@types.Scalar::Int(1)]])
  assert_eq(r, Err(@types.DataError::LengthMismatch))
}

///|
test "from_rows rejects dtype mismatches on every concrete dtype" {
  // Int column expecting Int gets a Float — TypeMismatch.
  let s_i = @types.Schema::new([@types.Field::new("x", @types.DataType::Int)]).unwrap()
  assert_true(
    DataFrame::from_rows(s_i, [[@types.Scalar::Float(1.0)]])
    is Err(TypeMismatch(_)),
  )
  // Float column expecting Float gets a String.
  let s_f = @types.Schema::new([@types.Field::new("x", @types.DataType::Float)]).unwrap()
  assert_true(
    DataFrame::from_rows(s_f, [[@types.Scalar::String("x")]])
    is Err(TypeMismatch(_)),
  )
  // Bool column expecting Bool gets an Int.
  let s_b = @types.Schema::new([@types.Field::new("x", @types.DataType::Bool)]).unwrap()
  assert_true(
    DataFrame::from_rows(s_b, [[@types.Scalar::Int(1)]]) is Err(TypeMismatch(_)),
  )
  // String column expecting String gets a Bool.
  let s_s = @types.Schema::new([@types.Field::new("x", @types.DataType::String)]).unwrap()
  assert_true(
    DataFrame::from_rows(s_s, [[@types.Scalar::Bool(true)]])
    is Err(TypeMismatch(_)),
  )
}

///|
test "from_rows rejects Null-dtype fields with Unsupported" {
  let schema = @types.Schema::new([
    @types.Field::new("n", @types.DataType::Null),
  ]).unwrap()
  assert_true(
    DataFrame::from_rows(schema, [[@types.Scalar::Null]]) is Err(Unsupported(_)),
  )
}

// ── Inspection ───────────────────────────────────────────────────────

///|
test "schema mirrors the column dtypes and names in order" {
  let df = DataFrame::new([
    Series::from_ints("a", [1]),
    Series::from_floats("b", [1.5]),
  ]).unwrap()
  assert_eq(df.schema().field_names(), ["a", "b"])
  assert_eq(df.schema().field("a").unwrap().dtype(), @types.DataType::Int)
  assert_eq(df.schema().field("b").unwrap().dtype(), @types.DataType::Float)
}

///|
test "columns returns names in declaration order, fresh array per call" {
  let df = DataFrame::new([
    Series::from_ints("first", [1]),
    Series::from_ints("second", [2]),
  ]).unwrap()
  let names_a = df.columns()
  let names_b = df.columns()
  // Mutating one copy must not affect the other or the frame.
  names_a.push("ghost")
  assert_eq(names_b, ["first", "second"])
  assert_eq(df.ncols(), 2)
}

///|
test "is_empty fires on 0 rows even with columns declared" {
  let df = DataFrame::new([Series::from_ints("x", [])]).unwrap()
  assert_true(df.is_empty())
  assert_eq(df.shape(), (0, 1))
}

// ── Accessors ────────────────────────────────────────────────────────

///|
test "get_column hits the O(1) name_to_index cache" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2]),
    Series::from_strings("b", ["x", "y"]),
  ]).unwrap()
  // The returned series must equal the one we constructed.
  assert_eq(df.get_column("a").unwrap(), Series::from_ints("a", [1, 2]))
  assert_eq(df.get_column("b").unwrap().dtype(), @types.DataType::String)
  assert_eq(
    df.get_column("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "get_column_at validates the positional index" {
  let df = DataFrame::new([
    Series::from_ints("a", [1]),
    Series::from_ints("b", [2]),
  ]).unwrap()
  assert_eq(df.get_column_at(0).unwrap().name(), "a")
  assert_eq(df.get_column_at(1).unwrap().name(), "b")
  assert_eq(df.get_column_at(-1), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(df.get_column_at(5), Err(@types.DataError::IndexOutOfBounds(5)))
}

///|
test "get returns Scalar / Null and surfaces the right error variant" {
  let df = DataFrame::new([
    Series::from_int_options("x", [Some(7), None, Some(9)]),
  ]).unwrap()
  assert_eq(df.get(0, "x"), Ok(@types.Scalar::Int(7)))
  assert_eq(df.get(1, "x"), Ok(@types.Scalar::Null))
  // Row OOB bubbles IndexOutOfBounds from Series::get.
  assert_eq(df.get(5, "x"), Err(@types.DataError::IndexOutOfBounds(5)))
  // Column missing bubbles ColumnNotFound from get_column.
  assert_eq(
    df.get(0, "missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

// ── row / RowView is integration-tested in row_view_test.mbt ─────────

///|
test "row validates the row index before handing out a view" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2])]).unwrap()
  assert_eq(df.row(0).unwrap().index(), 0)
  assert_eq(df.row(1).unwrap().index(), 1)
  assert_eq(df.row(-1), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(df.row(2), Err(@types.DataError::IndexOutOfBounds(2)))
}

// ── head / tail ──────────────────────────────────────────────────────

///|
test "head returns the first n rows with the same schema" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ]).unwrap()
  let two = df.head(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(two.get(1, "b"), Ok(@types.Scalar::String("x")))
  // Schema is preserved verbatim.
  assert_eq(two.schema(), df.schema())
}

///|
test "head clamps n > nrows to nrows" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2, 3])]).unwrap()
  let all = df.head(99)
  assert_eq(all.shape(), (3, 1))
}

///|
test "head clamps n < 0 to 0" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2, 3])]).unwrap()
  let empty = df.head(-5)
  assert_eq(empty.shape(), (0, 1))
  assert_true(empty.is_empty())
}

///|
test "tail returns the last n rows with the same schema" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ]).unwrap()
  let two = df.tail(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.get(0, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(two.get(1, "b"), Ok(@types.Scalar::String("z")))
}

///|
test "tail clamps n > nrows and n < 0" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2, 3])]).unwrap()
  let all = df.tail(99)
  assert_eq(all.shape(), (3, 1))
  let empty = df.tail(-1)
  assert_true(empty.is_empty())
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice mid-range produces a sub-frame preserving names + nulls" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(10), None, Some(30), Some(40)]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ]).unwrap()
  let part = df.slice(1, 3).unwrap()
  assert_eq(part.shape(), (2, 2))
  assert_eq(part.get(0, "a"), Ok(@types.Scalar::Null))
  assert_eq(part.get(1, "a"), Ok(@types.Scalar::Int(30)))
  assert_eq(part.get(0, "b"), Ok(@types.Scalar::String("x")))
}

///|
test "slice [start, start) returns an empty frame" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2, 3])]).unwrap()
  let zero = df.slice(2, 2).unwrap()
  assert_eq(zero.shape(), (0, 1))
}

///|
test "slice reports invalid bounds with the appropriate error" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2, 3])]).unwrap()
  assert_eq(df.slice(-1, 2), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(df.slice(0, 5), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_true(df.slice(2, 1) is Err(InvalidOperation(_)))
}

// ── take ─────────────────────────────────────────────────────────────

///|
test "take gathers rows in arbitrary order across every column" {
  let df = DataFrame::new([
    Series::from_ints("a", [10, 20, 30]),
    Series::from_strings("b", ["x", "y", "z"]),
  ]).unwrap()
  let out = df.take([2, 0, 0]).unwrap()
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(30)))
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::String("z")))
  assert_eq(out.get(2, "a"), Ok(@types.Scalar::Int(10)))
}

///|
test "take with empty indices produces an empty frame of the same schema" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2])]).unwrap()
  let out = df.take([]).unwrap()
  assert_true(out.is_empty())
  assert_eq(out.schema(), df.schema())
}

///|
test "take rejects out-of-bounds indices with the first offender" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2])]).unwrap()
  assert_eq(df.take([0, 5]), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_eq(df.take([-1]), Err(@types.DataError::IndexOutOfBounds(-1)))
}

// ── name_to_index cache survives transforms ──────────────────────────

///|
test "head / tail / slice / take all keep get_column working" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ]).unwrap()
  // After every transform, every declared column must still be
  // reachable by name (i.e. the name_to_index cache survives).
  let after_head = df.head(2)
  assert_eq(after_head.get_column("a").unwrap().len(), 2)
  assert_eq(after_head.get_column("b").unwrap().len(), 2)
  let after_tail = df.tail(2)
  assert_eq(
    after_tail.get_column("a").unwrap().get(0),
    Ok(@types.Scalar::Int(3)),
  )
  let after_slice = df.slice(1, 3).unwrap()
  assert_eq(
    after_slice.get_column("b").unwrap().get(1),
    Ok(@types.Scalar::String("y")),
  )
  let after_take = df.take([3, 0]).unwrap()
  assert_eq(
    after_take.get_column("a").unwrap().get(0),
    Ok(@types.Scalar::Int(4)),
  )
  assert_eq(
    after_take.get_column("a").unwrap().get(1),
    Ok(@types.Scalar::Int(1)),
  )
}

// ── structural equality ──────────────────────────────────────────────

///|
test "structural equality compares schema + columns + nrows" {
  let a = DataFrame::new([
    Series::from_ints("x", [1, 2]),
    Series::from_strings("y", ["a", "b"]),
  ]).unwrap()
  let b = DataFrame::new([
    Series::from_ints("x", [1, 2]),
    Series::from_strings("y", ["a", "b"]),
  ]).unwrap()
  assert_eq(a, b)
  // Differ in a column value.
  let c = DataFrame::new([
    Series::from_ints("x", [1, 2]),
    Series::from_strings("y", ["a", "c"]),
  ]).unwrap()
  assert_not_eq(a, c)
}
