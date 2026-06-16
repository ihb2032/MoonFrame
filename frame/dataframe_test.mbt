// Blackbox tests for `DataFrame`. Row access (`row` / `rows`) lives in
// `row_test.mbt`.

// ── Constructors: new ────────────────────────────────────────────────

///|
test "new builds a frame from equal-length, uniquely named columns" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
  assert_eq(df.shape(), (3, 2))
  assert_eq(df.nrows(), 3)
  assert_eq(df.ncols(), 2)
  assert_eq(df.columns(), ["a", "b"])
}

///|
test "new with zero columns yields a 0×0 frame" {
  let df = DataFrame::new([])
  assert_eq(df.shape(), (0, 0))
  assert_true(df.is_empty())
  assert_eq(df.columns(), [])
}

///|
test "new rejects columns of unequal length" {
  let r = try? DataFrame::new([
    Series::from_ints("a", [1, 2]),
    Series::from_ints("b", [1, 2, 3]),
  ])
  assert_eq(r, Err(@types.DataError::LengthMismatch))
}

///|
test "new rejects duplicate column names" {
  let r = try? DataFrame::new([
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
  ])
  let df = DataFrame::empty(schema)
  assert_eq(df.shape(), (0, 4))
  assert_true(df.is_empty())
  assert_eq(df.columns(), ["i", "f", "b", "s"])
  // Every column has the right dtype and zero length.
  assert_eq(df.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("f").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(df.get_column("s").dtype(), @types.DataType::String)
  assert_eq(df.get_column("i").len(), 0)
}

///|
test "empty(empty schema) yields a 0×0 frame" {
  let schema = @types.Schema::new([])
  let df = DataFrame::empty(schema)
  assert_eq(df.shape(), (0, 0))
  assert_true(df.is_empty())
}

///|
test "empty rejects Null-dtype fields with Unsupported" {
  let schema = @types.Schema::new([
    @types.Field::new("ok", @types.DataType::Int),
    @types.Field::new("nope", @types.DataType::Null),
  ])
  assert_true((try? DataFrame::empty(schema)) is Err(Unsupported(_)))
}

// ── Constructors: from_rows ──────────────────────────────────────────

///|
test "from_rows builds a frame, mixing nulls and concrete cells" {
  let schema = @types.Schema::new([
    @types.Field::new("i", @types.DataType::Int),
    @types.Field::new("f", @types.DataType::Float),
    @types.Field::new("b", @types.DataType::Bool),
    @types.Field::new("s", @types.DataType::String),
  ])
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
  ])
  assert_eq(df.shape(), (3, 4))
  // Row 0 was concrete in every column.
  assert_eq(df.item(0, "i"), @types.Scalar::Int(1))
  assert_eq(df.item(0, "f"), @types.Scalar::Float(1.5))
  assert_eq(df.item(0, "b"), @types.Scalar::Bool(true))
  assert_eq(df.item(0, "s"), @types.Scalar::String("a"))
  // Row 1 was all-null.
  assert_eq(df.item(1, "i"), @types.Scalar::Null)
  assert_eq(df.item(1, "f"), @types.Scalar::Null)
  assert_eq(df.item(1, "b"), @types.Scalar::Null)
  assert_eq(df.item(1, "s"), @types.Scalar::Null)
  // Per-column null_count == 1 in every column.
  assert_eq(df.get_column("i").null_count(), 1)
  assert_eq(df.get_column("f").null_count(), 1)
  assert_eq(df.get_column("b").null_count(), 1)
  assert_eq(df.get_column("s").null_count(), 1)
}

///|
test "from_rows with empty rows produces a 0×N frame" {
  let schema = @types.Schema::new([@types.Field::new("x", @types.DataType::Int)])
  let df = DataFrame::from_rows(schema, [])
  assert_eq(df.shape(), (0, 1))
  assert_true(df.is_empty())
}

///|
/// A zero-column schema collapses to `0×0` no matter how many
/// (necessarily width-0) rows are passed — `from_rows` agrees with
/// `DataFrame::new([])` rather than minting a column-less `N×0` frame
/// (which would report `is_empty() == false` and violate INV7).
test "from_rows with an empty schema collapses to 0×0" {
  let schema = @types.Schema::new([])
  let df = DataFrame::from_rows(schema, [[], [], []])
  assert_eq(df.shape(), (0, 0))
  assert_true(df.is_empty())
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "from_rows rejects rows of the wrong width" {
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::Int),
  ])
  let r = try? DataFrame::from_rows(schema, [[@types.Scalar::Int(1)]])
  assert_eq(r, Err(@types.DataError::LengthMismatch))
}

///|
test "from_rows rejects dtype mismatches on every concrete dtype" {
  // Int column expecting Int gets a Float — TypeMismatch.
  let s_i = @types.Schema::new([@types.Field::new("x", @types.DataType::Int)])
  assert_true(
    (try? DataFrame::from_rows(s_i, [[@types.Scalar::Float(1.0)]]))
    is Err(TypeMismatch(_)),
  )
  // Float column expecting Float gets a String.
  let s_f = @types.Schema::new([@types.Field::new("x", @types.DataType::Float)])
  assert_true(
    (try? DataFrame::from_rows(s_f, [[@types.Scalar::String("x")]]))
    is Err(TypeMismatch(_)),
  )
  // Bool column expecting Bool gets an Int.
  let s_b = @types.Schema::new([@types.Field::new("x", @types.DataType::Bool)])
  assert_true(
    (try? DataFrame::from_rows(s_b, [[@types.Scalar::Int(1)]]))
    is Err(TypeMismatch(_)),
  )
  // String column expecting String gets a Bool.
  let s_s = @types.Schema::new([@types.Field::new("x", @types.DataType::String)])
  assert_true(
    (try? DataFrame::from_rows(s_s, [[@types.Scalar::Bool(true)]]))
    is Err(TypeMismatch(_)),
  )
}

///|
test "from_rows rejects Null-dtype fields with Unsupported" {
  let schema = @types.Schema::new([
    @types.Field::new("n", @types.DataType::Null),
  ])
  assert_true(
    (try? DataFrame::from_rows(schema, [[@types.Scalar::Null]]))
    is Err(Unsupported(_)),
  )
}

// ── Inspection ───────────────────────────────────────────────────────

///|
test "schema mirrors the column dtypes and names in order" {
  let df = DataFrame::new([
    Series::from_ints("a", [1]),
    Series::from_floats("b", [1.5]),
  ])
  assert_eq(df.schema().field_names(), ["a", "b"])
  assert_eq(df.schema().field("a").dtype(), @types.DataType::Int)
  assert_eq(df.schema().field("b").dtype(), @types.DataType::Float)
}

///|
test "columns returns names in declaration order, fresh array per call" {
  let df = DataFrame::new([
    Series::from_ints("first", [1]),
    Series::from_ints("second", [2]),
  ])
  let names_a = df.columns()
  let names_b = df.columns()
  // Mutating one copy must not affect the other or the frame.
  names_a.push("ghost")
  assert_eq(names_b, ["first", "second"])
  assert_eq(df.ncols(), 2)
}

///|
test "to_scalar_matrix materialises every cell column-major, Null for nulls" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None]),
    Series::from_strings("s", ["x", "y"]),
  ])
  // One inner array per column, each `nrows` long; `m[c][r]` is the cell at
  // column c, row r, and a null slot reads as `Scalar::Null`.
  let m = df.to_scalar_matrix()
  assert_eq(m, [
    [@types.Scalar::Int(1), @types.Scalar::Null],
    [@types.Scalar::String("x"), @types.Scalar::String("y")],
  ])
  // Same result as the column-wise materialisation it factors out.
  assert_eq(m, df.column_series().map(s => s.to_scalars()))
}

///|
test "is_empty fires on 0 rows even with columns declared" {
  let df = DataFrame::new([Series::from_ints("x", [])])
  assert_true(df.is_empty())
  assert_eq(df.shape(), (0, 1))
}

// ── Accessors ────────────────────────────────────────────────────────

///|
test "get_column hits the O(1) name_to_index cache" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2]),
    Series::from_strings("b", ["x", "y"]),
  ])
  // The returned series must equal the one we constructed.
  assert_eq(df.get_column("a"), Series::from_ints("a", [1, 2]))
  assert_eq(df.get_column("b").dtype(), @types.DataType::String)
  assert_eq(
    try? df.get_column("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "get_column_at validates the positional index" {
  let df = DataFrame::new([
    Series::from_ints("a", [1]),
    Series::from_ints("b", [2]),
  ])
  assert_eq(df.get_column_at(0).name(), "a")
  assert_eq(df.get_column_at(1).name(), "b")
  assert_eq(
    try? df.get_column_at(-1),
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    try? df.get_column_at(5),
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
}

///|
test "get returns Scalar / Null and surfaces the right error variant" {
  let df = DataFrame::new([
    Series::from_int_options("x", [Some(7), None, Some(9)]),
  ])
  assert_eq(df.item(0, "x"), @types.Scalar::Int(7))
  assert_eq(df.item(1, "x"), @types.Scalar::Null)
  // Row OOB bubbles IndexOutOfBounds from Series::get.
  assert_eq(try? df.item(5, "x"), Err(@types.DataError::IndexOutOfBounds(5)))
  // Column missing bubbles ColumnNotFound from get_column.
  assert_eq(
    try? df.item(0, "missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

// ── head / tail ──────────────────────────────────────────────────────

///|
test "head returns the first n rows with the same schema" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let two = df.head(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(two.item(1, "b"), @types.Scalar::String("x"))
  // Schema is preserved verbatim.
  assert_eq(two.schema(), df.schema())
}

///|
test "head clamps n > nrows to nrows" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2, 3])])
  let all = df.head(99)
  assert_eq(all.shape(), (3, 1))
}

///|
test "head clamps n < 0 to 0" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2, 3])])
  let empty = df.head(-5)
  assert_eq(empty.shape(), (0, 1))
  assert_true(empty.is_empty())
}

///|
test "tail returns the last n rows with the same schema" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let two = df.tail(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.item(0, "a"), @types.Scalar::Int(3))
  assert_eq(two.item(1, "b"), @types.Scalar::String("z"))
}

///|
test "tail clamps n > nrows and n < 0" {
  let df = DataFrame::new([Series::from_ints("a", [1, 2, 3])])
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
  ])
  let part = df.slice(1, 3)
  assert_eq(part.shape(), (2, 2))
  assert_eq(part.item(0, "a"), @types.Scalar::Null)
  assert_eq(part.item(1, "a"), @types.Scalar::Int(30))
  assert_eq(part.item(0, "b"), @types.Scalar::String("x"))
}

///|
test "slice [start, start) returns an empty frame" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2, 3])])
  let zero = df.slice(2, 2)
  assert_eq(zero.shape(), (0, 1))
}

///|
test "slice reports invalid bounds with the appropriate error" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2, 3])])
  assert_eq(try? df.slice(-1, 2), Err(@types.DataError::IndexOutOfBounds(-1)))
  assert_eq(try? df.slice(0, 5), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_true((try? df.slice(2, 1)) is Err(InvalidOperation(_)))
}

// ── take ─────────────────────────────────────────────────────────────

///|
test "take gathers rows in arbitrary order across every column" {
  let df = DataFrame::new([
    Series::from_ints("a", [10, 20, 30]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
  let out = df.take([2, 0, 0])
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(30))
  assert_eq(out.item(0, "b"), @types.Scalar::String("z"))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(10))
}

///|
test "take with empty indices produces an empty frame of the same schema" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2])])
  let out = df.take([])
  assert_true(out.is_empty())
  assert_eq(out.schema(), df.schema())
}

///|
test "take rejects out-of-bounds indices with the first offender" {
  let df = DataFrame::new([Series::from_ints("x", [1, 2])])
  assert_eq(try? df.take([0, 5]), Err(@types.DataError::IndexOutOfBounds(5)))
  assert_eq(try? df.take([-1]), Err(@types.DataError::IndexOutOfBounds(-1)))
}

// ── name_to_index cache survives transforms ──────────────────────────

///|
test "head / tail / slice / take all keep get_column working" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  // After every transform, every declared column must still be
  // reachable by name (i.e. the name_to_index cache survives).
  let after_head = df.head(2)
  assert_eq(after_head.get_column("a").len(), 2)
  assert_eq(after_head.get_column("b").len(), 2)
  let after_tail = df.tail(2)
  assert_eq(after_tail.get_column("a").get(0), @types.Scalar::Int(3))
  let after_slice = df.slice(1, 3)
  assert_eq(after_slice.get_column("b").get(1), @types.Scalar::String("y"))
  let after_take = df.take([3, 0])
  assert_eq(after_take.get_column("a").get(0), @types.Scalar::Int(4))
  assert_eq(after_take.get_column("a").get(1), @types.Scalar::Int(1))
}

///|
test "head / tail / slice copy every dtype, valid and null cells" {
  // `head` / `tail` / `slice` route each column through `slice_series` →
  // `ColumnStorage::slice_total` → `BuiltinColumn::slice_unchecked`, whose
  // data copy has a branch per `ColumnData` dtype (the validity is a shared
  // zero-copy view). Slice a frame whose four columns each carry a null
  // inside the kept range so every dtype branch runs and the view carries
  // the nulls through.
  let df = DataFrame::new([
    Series::from_int_options("i", [Some(1), None, Some(3), Some(4)]),
    Series::from_float_options("f", [Some(1.0), Some(2.0), None, Some(4.0)]),
    Series::from_bool_options("b", [None, Some(true), Some(false), Some(true)]),
    Series::from_string_options("s", [Some("a"), Some("b"), None, Some("d")]),
  ])
  // head(3) keeps rows [0, 3): each column has both a valid and a null
  // cell in that range.
  let h = df.head(3)
  assert_eq(h.nrows(), 3)
  assert_eq(h.check_invariants(), Ok(()))
  assert_eq(h.item(0, "i"), @types.Scalar::Int(1))
  assert_eq(h.item(1, "i"), @types.Scalar::Null)
  assert_eq(h.item(0, "f"), @types.Scalar::Float(1.0))
  assert_eq(h.item(2, "f"), @types.Scalar::Null)
  assert_eq(h.item(0, "b"), @types.Scalar::Null)
  assert_eq(h.item(1, "b"), @types.Scalar::Bool(true))
  assert_eq(h.item(0, "s"), @types.Scalar::String("a"))
  assert_eq(h.item(2, "s"), @types.Scalar::Null)
  // tail / slice exercise the same helper with a non-zero start offset.
  let t = df.tail(2)
  assert_eq(t.item(0, "f"), @types.Scalar::Null)
  assert_eq(t.check_invariants(), Ok(()))
  let sl = df.slice(1, 4)
  assert_eq(sl.nrows(), 3)
  assert_eq(sl.item(1, "f"), @types.Scalar::Null)
  assert_eq(sl.check_invariants(), Ok(()))
}

///|
test "head null_count is correct on Builtin columns (zero-copy view)" {
  // After the slice unification `head` / `tail` / `slice` share the validity
  // buffer (zero-copy). `head(k)` yields an offset-0 view, so null_count /
  // count must count only the kept window — not the parent's rows past `k`
  // that linger in the shared final byte.
  let df = DataFrame::new([
    Series::from_bools("b", [true, true, true]),
    Series::from_int_options("i", [Some(1), None, Some(3)]),
  ])
  let h = df.head(2)
  assert_eq(h.get_column("b").null_count(), 0)
  assert_eq(h.get_column("b").count(), 2)
  // The null at row 1 is inside head(2) and must survive; the valid row 2
  // (just outside the window) must not mask it.
  assert_eq(h.get_column("i").null_count(), 1)
  // The DataFrame-level null_count surfaces the same per-column truth.
  assert_eq(h.null_count().item(0, "i"), @types.Scalar::Int(1))
}

// ── structural equality ──────────────────────────────────────────────

///|
test "structural equality compares schema + columns + nrows" {
  let a = DataFrame::new([
    Series::from_ints("x", [1, 2]),
    Series::from_strings("y", ["a", "b"]),
  ])
  let b = DataFrame::new([
    Series::from_ints("x", [1, 2]),
    Series::from_strings("y", ["a", "b"]),
  ])
  assert_eq(a, b)
  // Differ in a column value.
  let c = DataFrame::new([
    Series::from_ints("x", [1, 2]),
    Series::from_strings("y", ["a", "c"]),
  ])
  assert_not_eq(a, c)
}

// ── storage backend control: storage_kinds / to_numeric / to_builtin ──

///|
test "to_numeric converts eligible columns and keeps the rest (storage_kinds reflects it)" {
  let df = DataFrame::new([
    // Builtin, all-valid Int → converts to Numeric.
    Series::from_int_options("vi", [Some(1), Some(2), Some(3)]),
    // Builtin, all-valid Float → converts to Numeric.
    Series::from_float_options("vf", [Some(1.5), Some(2.5), Some(3.5)]),
    // Builtin, carries a null → kept (a NumericColumn can't hold nulls).
    Series::from_int_options("ni", [Some(1), None, Some(3)]),
    // Builtin, non-numeric → kept.
    Series::from_strings("s", ["a", "b", "c"]),
    // Already Numeric → returned unchanged.
    Series::from_ints("ai", [7, 8, 9]),
  ])
  assert_eq(df.storage_kinds(), [
    @column.StorageKind::Builtin,
    @column.StorageKind::Builtin,
    @column.StorageKind::Builtin,
    @column.StorageKind::Builtin,
    @column.StorageKind::Numeric,
  ])
  let n = df.to_numeric()
  // Eligible columns moved; nullable / non-numeric / already-Numeric kept.
  assert_eq(n.storage_kinds(), [
    @column.StorageKind::Numeric,
    @column.StorageKind::Numeric,
    @column.StorageKind::Builtin,
    @column.StorageKind::Builtin,
    @column.StorageKind::Numeric,
  ])
  // Total: a backend swap preserves names, dtypes, values, and invariants.
  assert_eq(n.schema(), df.schema())
  assert_eq(n.check_invariants(), Ok(()))
  for name in ["vi", "vf", "ni", "s", "ai"] {
    assert_eq(n.get_column(name).to_scalars(), df.get_column(name).to_scalars())
  }
}

///|
test "to_builtin materialises every column to Builtin and round-trips with to_numeric" {
  let df = DataFrame::new([
    Series::from_ints("a", [1, 2]),
    Series::from_floats("b", [1.5, 2.5]),
    Series::from_strings("c", ["x", "y"]),
  ])
  assert_eq(df.storage_kinds(), [
    @column.StorageKind::Numeric,
    @column.StorageKind::Numeric,
    @column.StorageKind::Builtin,
  ])
  let b = df.to_builtin()
  assert_eq(b.storage_kinds(), [
    @column.StorageKind::Builtin,
    @column.StorageKind::Builtin,
    @column.StorageKind::Builtin,
  ])
  // Lossless: values + invariants preserved, and to_numeric reverses it on
  // the numeric columns.
  assert_eq(b.check_invariants(), Ok(()))
  assert_eq(b.get_column("a").to_scalars(), df.get_column("a").to_scalars())
  assert_eq(b.to_numeric().storage_kinds(), [
    @column.StorageKind::Numeric,
    @column.StorageKind::Numeric,
    @column.StorageKind::Builtin,
  ])
}
