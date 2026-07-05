///|
/// Blackbox behavior tests for `DataFrame::select` — the single expression
/// projection verb. Covers: bare-column projection (order, cells, backends)
/// as the drop-in for the old names-only `select`, the output-height rule
/// (all-scalar → one row, mixed → broadcast to the frame), naming and
/// column order, within-call duplicate detection, the empty selection,
/// zero-row frames, the evaluation-time error paths, and a block of
/// historical pins asserting `select([col(n), ...])` reproduces exactly the
/// projection the names-based `select([n, ...])` used to give. The
/// evaluator's dtype / null / broadcast semantics live in
/// `expr_eval_test.mbt`.

///|
fn sel_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_ints("b", [10, 20, 30]),
    Series::from_strings("region", ["west", "east", "west"]),
  ])
}

///|
/// Three-column fixture for the historical pins: an Int, a String, and a
/// nullable Float so the projection tests can observe null preservation on
/// column `c`.
fn select_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("b", ["x", "y", "z"]),
    Series::from_float_options("c", [Some(1.5), None, Some(2.5)]),
  ])
}

///|
test "bare-column projection reorders and preserves cells, backends kept" {
  let df = DataFrame::new([
    Series::from_ints("n", [1, 2, 3]),
    Series::from_int_options("m", [Some(1), None, Some(3)]),
  ])
  // Projecting [m, n] reverses the source order and keeps every cell, the
  // null in `m` included — the bare-`col` projection that replaced the old
  // `select(["m", "n"])`.
  let out = df.select([@expr.col("m"), @expr.col("n")])
  assert_eq(out.columns(), ["m", "n"])
  assert_eq(out.get_column("m").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
    @types.Scalar::Int(3),
  ])
  assert_eq(out.get_column("n").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  // `col(...)` references keep their source backend through the gather.
  assert_eq(out.get_column("n").storage_kind(), @column.StorageKind::Numeric)
  assert_eq(out.get_column("m").storage_kind(), @column.StorageKind::Builtin)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "derived columns build a brand-new frame in expression order" {
  let out = sel_df().select([
    (@expr.col("a") + @expr.col("b")).with_alias("total"),
    @expr.col("a").gt(@expr.lit_int(1)).with_alias("big"),
  ])
  assert_eq(out.columns(), ["total", "big"])
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(11),
    @types.Scalar::Int(22),
    @types.Scalar::Int(33),
  ])
  assert_eq(out.get_column("big").to_scalars(), [
    @types.Scalar::Bool(false),
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(true),
  ])
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "output naming: alias, leftmost column reference, literal fallback" {
  let out = sel_df().select([
    @expr.col("b") + @expr.lit_int(1), // leftmost Col → "b"
    (@expr.col("a") * @expr.col("b")).with_alias("prod"),
    @expr.lit_str("x"), // column-less tree → "literal"
  ])
  assert_eq(out.columns(), ["b", "prod", "literal"])
}

///|
test "selecting a derived expression equals deriving then selecting" {
  // Equivalence with the with_columns path: the projection of a derived
  // column is the same column with_columns would have appended.
  let expr = (@expr.col("a") + @expr.col("b")).with_alias("t")
  assert_eq(
    sel_df().select([expr]),
    sel_df().with_columns([expr]).select([@expr.col("t")]),
  )
}

///|
test "all-scalar expressions collapse to a one-row summary frame" {
  let out = sel_df().select([
    @expr.col("a").sum().with_alias("total"),
    @expr.col("a").mean().with_alias("avg"),
    @expr.col("a").count().with_alias("n"),
    @expr.lit_str("summary").with_alias("tag"),
  ])
  assert_eq(out.shape(), (1, 4))
  assert_eq(out.get_column("total").get(0), @types.Scalar::Int(6))
  assert_eq(out.get_column("avg").get(0), @types.Scalar::Float(2.0))
  assert_eq(out.get_column("n").get(0), @types.Scalar::Int(3))
  assert_eq(out.get_column("tag").get(0), @types.Scalar::String("summary"))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "mixed selection broadcasts scalar results to the frame height" {
  let out = sel_df().select([
    @expr.col("a"),
    @expr.col("a").sum().with_alias("total"),
    @expr.lit_int(7).with_alias("seven"),
  ])
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  assert_eq(
    out.get_column("total").to_scalars(),
    Array::make(3, @types.Scalar::Int(6)),
  )
  assert_eq(
    out.get_column("seven").to_scalars(),
    Array::make(3, @types.Scalar::Int(7)),
  )
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "select([]) collapses to the 0x0 frame" {
  let out = sel_df().select([])
  assert_eq(out.shape(), (0, 0))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "single-row frame: frame-tall and scalar results coincide at one row" {
  let df = DataFrame::new([Series::from_ints("a", [5])])
  let out = df.select([@expr.col("a"), @expr.col("a").sum().with_alias("t")])
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.get_column("a").get(0), @types.Scalar::Int(5))
  assert_eq(out.get_column("t").get(0), @types.Scalar::Int(5))
}

///|
test "zero-row frame: a frame-tall result pins the height at zero" {
  let df = DataFrame::new([Series::from_ints("a", [])])
  let out = df.select([@expr.col("a"), @expr.col("a").sum().with_alias("t")])
  assert_eq(out.shape(), (0, 2))
  assert_eq(out.get_column("t").dtype(), @types.DataType::Int)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "zero-row frame: an all-scalar selection still yields its one-row summary" {
  let df = DataFrame::new([Series::from_ints("a", [])])
  let out = df.select([
    @expr.col("a").sum().with_alias("t"),
    @expr.col("a").count().with_alias("n"),
    @expr.col("a").mean().with_alias("avg"),
  ])
  assert_eq(out.shape(), (1, 3))
  assert_eq(out.get_column("t").get(0), @types.Scalar::Int(0))
  assert_eq(out.get_column("n").get(0), @types.Scalar::Int(0))
  assert_eq(out.get_column("avg").get(0), @types.Scalar::Null)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "duplicate output names raise DuplicateColumn at the second expression" {
  // Two column-less trees both name themselves "literal".
  assert_eq(
    Ok(sel_df().select([@expr.lit_int(1), @expr.lit_int(2)])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("literal")),
  )
  // The same column referenced twice without an alias collides on its name.
  assert_eq(
    Ok(sel_df().select([@expr.col("a"), @expr.col("a") + @expr.lit_int(1)])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("a")),
  )
  // Detection runs in expression order: the collision at the second
  // expression fires before the third (itself unevaluable) is touched.
  assert_eq(
    Ok(sel_df().select([@expr.lit_int(1), @expr.lit_int(2), @expr.col("zzz")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("literal")),
  )
}

///|
test "evaluation errors surface: unknown column, dtype mismatch" {
  assert_eq(
    Ok(sel_df().select([@expr.col("zzz")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
  assert_eq(
    Ok(sel_df().select([@expr.col("region") + @expr.col("a")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::TypeMismatch("cannot add String and Int")),
  )
}

// ── Historical pins ───────────────────────────────────────────────────
// `select([col(n), ...])` must reproduce the projection the names-based
// `select([n, ...])` used to give: same order, same cells, same errors.

///|
test "historical pin: bare-column select projects in requested order" {
  let df = select_df()
  let out = df.select([@expr.col("c"), @expr.col("a")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["c", "a"])
  assert_eq(out.schema().field_names(), out.columns())
  assert_eq(out.get_column("c").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("a").dtype(), @types.DataType::Int)
  // Row count is preserved.
  assert_eq(out.nrows(), df.nrows())
}

///|
test "historical pin: a single bare column yields a one-column frame" {
  let out = select_df().select([@expr.col("b")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (3, 1))
  assert_eq(out.columns(), ["b"])
  assert_eq(out.item(0, "b"), @types.Scalar::String("x"))
}

///|
test "historical pin: selecting every column in order equals the original" {
  let df = select_df()
  let out = df.select([@expr.col("a"), @expr.col("b"), @expr.col("c")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "historical pin: bare-column select preserves cells, nulls included" {
  let out = select_df().select([@expr.col("a"), @expr.col("c")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(3))
  assert_eq(out.item(1, "c"), @types.Scalar::Null)
  assert_eq(out.item(0, "c"), @types.Scalar::Float(1.5))
}

///|
test "historical pin: duplicate bare columns, and missing wins over duplicate" {
  let df = select_df()
  // A bare column repeated collides on its own name.
  assert_eq(
    Ok(df.select([@expr.col("a"), @expr.col("a")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("a")),
  )
  // First error in expression order: the missing `z` evaluates (and fails)
  // before the later duplicate `a` is ever named.
  assert_eq(
    Ok(df.select([@expr.col("z"), @expr.col("a"), @expr.col("a")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("z")),
  )
}

///|
test "select does not propagate a nullable=false flag (it is advisory)" {
  // A nullable=false field only originates from an explicit from_rows schema;
  // select rebuilds through DataFrame::new, which names every output column with
  // Field::new (nullable=true). So the declared flag is not carried across the
  // op — pinning the advisory contract the Field doc promises, so a future
  // change that inferred or propagated nullability has to be deliberate.
  let schema = @types.Schema::new([
    @types.Field::with_nullable("id", @types.DataType::Int, false),
  ])
  let df = DataFrame::from_rows(schema, [
    [@types.Scalar::Int(1)],
    [@types.Scalar::Int(2)],
  ])
  // from_rows honours the declared flag on the source frame.
  assert_false(df.schema().field("id").nullable())
  // select rebuilds the schema via Field::new, so the projected column resets
  // to nullable=true — the flag did not propagate.
  let projected = df.select([@expr.col("id")])
  assert_true(projected.schema().field("id").nullable())
}
