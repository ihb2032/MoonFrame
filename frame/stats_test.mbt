// Blackbox tests for the whole-frame reductions `DataFrame::sum` / `mean` /
// `min` / `max` / `count`, each returning a 1-row `DataFrame` (one cell per
// source column). The per-cell reductions delegate to the shared kernel
// (covered exhaustively by the kernel's own cross-surface suite), so
// the tests here focus on the frame-level behaviour:
//   (1) shape — a 1-row frame, names and order preserved (0-column → 1×0);
//   (2) the uniform numeric-only rule — numeric columns reduce, non-numeric
//       columns become a `Null` cell kept in their source dtype (`mean`
//       retypes numeric to `Float`; `count` is the non-null count as `Int`
//       for every dtype);
//   (3) the empty / all-null edges — `sum` is the additive identity while
//       `mean` / `min` / `max` are a `Null` cell (not `InvalidOperation`);
//   (4) the single-column scalar path through `Series`, which is what
//       `df.sum("col")` reads through.

///|
/// Mixed-dtype fixture: an `Int` column with a null cell, a `Float` column
/// with a null cell, a fully-valid `Bool` column, and a `String` column.
/// Exercises every dtype branch each reduction may encounter.
fn stats_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_int_options("i", [Some(1), None, Some(2), Some(3)]),
    Series::from_float_options("f", [
      Some((1.0 : Double)),
      Some((2.0 : Double)),
      None,
      Some((4.0 : Double)),
    ]),
    Series::from_bools("b", [true, false, true, true]),
    Series::from_strings("s", ["banana", "apple", "cherry", "banana"]),
  ])
}

// ── sum ──────────────────────────────────────────────────────────────

///|
test "sum reduces numeric columns and nulls non-numeric, as a 1-row frame" {
  let r = stats_df().sum()
  // A single row, columns in declaration order.
  assert_eq(r.shape(), (1, 4))
  assert_eq(r.columns(), ["i", "f", "b", "s"])
  // 1 + 2 + 3 = 6 (the null is skipped); 1.0 + 2.0 + 4.0 = 7.0.
  assert_eq(r.item(0, "i"), @types.Scalar::Int(6))
  assert_eq(r.item(0, "f"), @types.Scalar::Float(7.0))
  // Non-numeric columns become a Null cell, kept in their source dtype, so
  // the result schema matches the source schema.
  assert_eq(r.item(0, "b"), @types.Scalar::Null)
  assert_eq(r.item(0, "s"), @types.Scalar::Null)
  assert_eq(r.get_column("i").dtype(), @types.DataType::Int)
  assert_eq(r.get_column("f").dtype(), @types.DataType::Float)
  assert_eq(r.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(r.get_column("s").dtype(), @types.DataType::String)
}

// ── mean ─────────────────────────────────────────────────────────────

///|
test "mean reduces numeric columns to Float, nulls non-numeric" {
  let r = stats_df().mean()
  assert_eq(r.shape(), (1, 4))
  // Int column promoted to Float, nulls skipped: (1 + 2 + 3) / 3 = 2.0.
  assert_eq(r.item(0, "i"), @types.Scalar::Float(2.0))
  assert_eq(r.get_column("i").dtype(), @types.DataType::Float)
  // Float column: (1.0 + 2.0 + 4.0) / 3 ≈ 2.333 — avoid pinning the digits.
  assert_true(
    match r.item(0, "f") {
      @types.Scalar::Float(m) => m > 2.3 && m < 2.4
      _ => false
    },
  )
  // Non-numeric → Null cell, kept in source dtype (mean retypes only numeric).
  assert_eq(r.item(0, "b"), @types.Scalar::Null)
  assert_eq(r.item(0, "s"), @types.Scalar::Null)
  assert_eq(r.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(r.get_column("s").dtype(), @types.DataType::String)
}

///|
test "mean of an empty / all-null numeric column is a Null cell" {
  // An all-null numeric column → Null mean cell (not InvalidOperation); the
  // output column is still retyped to Float.
  let allnull = DataFrame::DataFrame([
    Series::from_int_options("a", [None, None]),
    Series::from_float_options("b", [None, None]),
  ])
  let r = allnull.mean()
  assert_eq(r.shape(), (1, 2))
  assert_eq(r.item(0, "a"), @types.Scalar::Null)
  assert_eq(r.item(0, "b"), @types.Scalar::Null)
  assert_eq(r.get_column("a").dtype(), @types.DataType::Float)
  // An empty (0-row) numeric column likewise → Null mean cell.
  let empty = DataFrame::empty(
    @types.Schema::Schema([@types.Field::Field("a", @types.DataType::Int)]),
  )
  assert_eq(empty.mean().item(0, "a"), @types.Scalar::Null)
}

// ── min / max ────────────────────────────────────────────────────────

///|
test "min reduces numeric columns and nulls non-numeric" {
  let r = stats_df().min()
  assert_eq(r.shape(), (1, 4))
  assert_eq(r.item(0, "i"), @types.Scalar::Int(1))
  assert_eq(r.item(0, "f"), @types.Scalar::Float(1.0))
  // Bool / String are nulled, not ordered — the uniform numeric-only rule
  // (a typed extremum over any dtype is `Series::min`).
  assert_eq(r.item(0, "b"), @types.Scalar::Null)
  assert_eq(r.item(0, "s"), @types.Scalar::Null)
  assert_eq(r.get_column("b").dtype(), @types.DataType::Bool)
  assert_eq(r.get_column("s").dtype(), @types.DataType::String)
}

///|
test "max reduces numeric columns and nulls non-numeric" {
  let r = stats_df().max()
  assert_eq(r.shape(), (1, 4))
  assert_eq(r.item(0, "i"), @types.Scalar::Int(3))
  assert_eq(r.item(0, "f"), @types.Scalar::Float(4.0))
  assert_eq(r.item(0, "b"), @types.Scalar::Null)
  assert_eq(r.item(0, "s"), @types.Scalar::Null)
}

// ── count ────────────────────────────────────────────────────────────

///|
test "count is the non-null cell count for every column, as a 1-row Int frame" {
  let r = stats_df().count()
  assert_eq(r.shape(), (1, 4))
  // "i" and "f" carry one null each → 3; "b" and "s" have none → 4.
  assert_eq(r.item(0, "i"), @types.Scalar::Int(3))
  assert_eq(r.item(0, "f"), @types.Scalar::Int(3))
  assert_eq(r.item(0, "b"), @types.Scalar::Int(4))
  assert_eq(r.item(0, "s"), @types.Scalar::Int(4))
  // Every output column is Int, regardless of the source dtype.
  for name in ["i", "f", "b", "s"] {
    assert_eq(r.get_column(name).dtype(), @types.DataType::Int)
  }
}

// ── edges: 0-row, 0-column ───────────────────────────────────────────

///|
test "reductions on a 0-row frame: sum is the identity, count is zero" {
  let df = DataFrame::empty(
    @types.Schema::Schema([
      @types.Field::Field("i", @types.DataType::Int),
      @types.Field::Field("f", @types.DataType::Float),
      @types.Field::Field("s", @types.DataType::String),
    ]),
  )
  // sum → additive identity for numeric, Null for non-numeric; still 1 row.
  let s = df.sum()
  assert_eq(s.shape(), (1, 3))
  assert_eq(s.item(0, "i"), @types.Scalar::Int(0))
  assert_eq(s.item(0, "f"), @types.Scalar::Float(0.0))
  assert_eq(s.item(0, "s"), @types.Scalar::Null)
  // count → 0 for every column.
  let c = df.count()
  assert_eq(c.shape(), (1, 3))
  assert_eq(c.item(0, "i"), @types.Scalar::Int(0))
  assert_eq(c.item(0, "s"), @types.Scalar::Int(0))
  // min / max on an empty numeric column → Null cell.
  assert_eq(df.min().item(0, "i"), @types.Scalar::Null)
  assert_eq(df.max().item(0, "f"), @types.Scalar::Null)
}

///|
test "reductions on a 0-column frame are the 1x0 summary row" {
  // One summary row per source frame, whatever its own shape: with no column
  // to reduce, the row is simply empty. `nby0` covers the source that has
  // rows of its own, so the height cannot be coming from there either.
  for df in [DataFrame::DataFrame([]), nby0(3)] {
    assert_eq(df.sum().shape(), (1, 0))
    assert_eq(df.mean().shape(), (1, 0))
    assert_eq(df.min().shape(), (1, 0))
    assert_eq(df.max().shape(), (1, 0))
    assert_eq(df.count().shape(), (1, 0))
    assert_eq(df.sum().check_invariants(), Ok(()))
  }
}

// ── single-column scalar (migration target) ──────────────────────────

///|
test "a single column's scalar reduction goes through its Series" {
  let df = stats_df()
  // The retired `df.sum("i")` is now `df.get_column("i").sum()`
  // (= Polars `df["i"].sum()`); `min` / `count` are likewise total.
  assert_eq(df.get_column("i").sum(), @types.Scalar::Int(6))
  assert_eq(df.get_column("i").min(), @types.Scalar::Int(1))
  assert_eq(df.get_column("b").count(), 4)
  // An unknown column still raises `ColumnNotFound` at the lookup.
  assert_eq(
    Ok(df.get_column("missing")) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}
// Blackbox tests for `DataFrame::null_count`.
//
// Invariants asserted on every successful summary:
//   (1) check_invariants() == Ok(()) — the formal structural spec
//   (2) result.columns() == df.columns() — names + order preserved
//   (3) every column in the result is dtype Int (the count itself)
//   (4) result.shape() == (1, df.ncols()) — including the 0-column edge
//       case, which is the 1×0 summary
//   (5) the cell in result column `c` equals df.get_column(c).null_count()

// ── Happy paths ──────────────────────────────────────────────────────

///|
test "null_count summarises each column into a single-cell Int" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(1), None, Some(3), None]),
    Series::from_float_options("b", [
      Some((1.5 : Double)),
      Some((2.5 : Double)),
      None,
      Some((4.5 : Double)),
    ]),
    Series::from_strings("s", ["w", "x", "y", "z"]),
  ])
  let out = df.null_count()
  assert_eq(out.check_invariants(), Ok(()))
  // Shape: exactly one row, one column per input column.
  assert_eq(out.shape(), (1, 3))
  // Column names + order match the input verbatim.
  assert_eq(out.columns(), df.columns())
  // Each column in the summary is dtype Int (the count is always an Int).
  for name in out.columns() {
    assert_eq(out.get_column(name).dtype(), @types.DataType::Int)
  }
  // Per-cell values: 2 nulls in "a", 1 null in "b", 0 nulls in "s".
  assert_eq(out.item(0, "a"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "b"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "s"), @types.Scalar::Int(0))
}

///|
test "null_count on a fully-valid frame returns all-zero counts" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3]),
    Series::from_strings("s", ["x", "y", "z"]),
  ])
  let out = df.null_count()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(0))
  assert_eq(out.item(0, "s"), @types.Scalar::Int(0))
}

///|
test "null_count on an all-null column reports the full row count" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [None, None, None, None, None]),
    Series::from_string_options("s", [
      Some("x"),
      None,
      Some("y"),
      None,
      Some("z"),
    ]),
  ])
  let out = df.null_count()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(5))
  assert_eq(out.item(0, "s"), @types.Scalar::Int(2))
}

///|
test "null_count on a 0-row frame reports zero for every column" {
  let schema = @types.Schema::Schema([
    @types.Field::Field("a", @types.DataType::Int),
    @types.Field::Field("b", @types.DataType::Float),
  ])
  let df = DataFrame::empty(schema)
  let out = df.null_count()
  assert_eq(out.check_invariants(), Ok(()))
  // Shape is (1, 2): the summary always has one row per source column,
  // independent of the source row count.
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(0))
  assert_eq(out.item(0, "b"), @types.Scalar::Int(0))
}

///|
test "null_count on a 0-column frame is a 1x0 summary" {
  // The summary row exists for every source frame; a source with no columns
  // just leaves it with no cells. Its own height is irrelevant — a 0×0 and an
  // N×0 frame summarise alike.
  for df in [DataFrame::DataFrame([]), nby0(3)] {
    let out = df.null_count()
    assert_eq(out.check_invariants(), Ok(()))
    assert_eq(out.shape(), (1, 0))
    assert_eq(out.columns(), df.columns())
  }
}

///|
test "null_count preserves column order even when names sort differently" {
  // The output column order is the input order, not lexicographic.
  let df = DataFrame::DataFrame([
    Series::from_int_options("z", [Some(1), None]),
    Series::from_int_options("a", [None, None]),
    Series::from_int_options("m", [Some(1), Some(2)]),
  ])
  let out = df.null_count()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["z", "a", "m"])
  assert_eq(out.item(0, "z"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "m"), @types.Scalar::Int(0))
}

///|
test "null_count covers every dtype branch" {
  // Int / Float / Bool / String — make sure each dtype contributes a
  // correct null count (the implementation goes through Series, which
  // delegates to BuiltinColumn::null_count which is dtype-agnostic, but
  // a regression here would silently miss one branch).
  let df = DataFrame::DataFrame([
    Series::from_int_options("i", [Some(1), None]),
    Series::from_float_options("f", [None, Some((2.0 : Double))]),
    Series::from_bool_options("b", [None, Some(true)]),
    Series::from_string_options("s", [Some("x"), None]),
  ])
  let out = df.null_count()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "i"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "f"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "b"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "s"), @types.Scalar::Int(1))
}

// ── Per-cell consistency with Series::null_count ─────────────────────

///|
test "null_count cell value equals the source series' null_count" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(1), None, Some(3)]),
    Series::from_float_options("b", [None, None, Some((1.0 : Double))]),
  ])
  let out = df.null_count()
  assert_eq(out.check_invariants(), Ok(()))
  for name in df.columns() {
    let expected = df.get_column(name).null_count()
    assert_eq(out.item(0, name), @types.Scalar::Int(expected.to_int64()))
  }
}
// Blackbox tests for `DataFrame::describe`.
//
// Invariants asserted on every successful summary:
//   (1) check_invariants() == Ok(()) — the formal structural spec
//   (2) result.columns() == fixed schema (regardless of input)
//   (3) result.nrows() == df.ncols() (one row per source column)
//   (4) result column dtypes are pinned: column, dtype, min, max are
//       String; count, null_count, n_unique are Int; mean is Float
//       (nullable)
//
// Coverage targets:
//   - The empty-columns shortcut (0 source columns ⇒ 0 result rows).
//   - Both arms of `s.mean_opt()`, the total accessor `describe` reads: a
//     value (numeric column with at least one non-null cell) AND `None`
//     (non-numeric column, or an empty / all-null numeric one).
//   - the min/max null branch (empty / all-null column) AND
//     is_null=false (column with at least one non-null cell).
//   - Every concrete dtype (Int / Float / Bool / String) reaches the
//     min / max rendering path at least once.

///|
/// Expected output schema for every `describe` result. Pinned in one
/// place so a schema change announces itself in exactly one test name
/// rather than rippling through every assertion.
fn describe_schema() -> Array[String] {
  ["column", "dtype", "count", "null_count", "n_unique", "mean", "min", "max"]
}

///|
/// Mixed-dtype fixture covering Int (nullable), Float (nullable), Bool,
/// and String. Picked so:
///   - `mean_opt` yields a value for "i" and "f"
///   - `mean_opt` yields `None` for "b" and "s" (non-numeric)
///   - the min/max non-null branch fires for every column
fn describe_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_int_options("i", [Some(1), None, Some(3), Some(5)]),
    Series::from_float_options("f", [
      Some((1.0 : Double)),
      Some((2.0 : Double)),
      None,
      Some((3.0 : Double)),
    ]),
    Series::from_bools("b", [true, false, true, true]),
    Series::from_strings("s", ["banana", "apple", "cherry", "banana"]),
  ])
}

// ── Structural invariants ────────────────────────────────────────────

///|
test "describe schema is fixed regardless of source shape" {
  let df = describe_df()
  let out = df.describe()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), describe_schema())
  // One row per source column, eight schema columns.
  assert_eq(out.shape(), (4, 8))
}

///|
test "describe column dtypes are pinned" {
  let df = describe_df()
  let out = df.describe()
  assert_eq(out.get_column("column").dtype(), @types.DataType::String)
  assert_eq(out.get_column("dtype").dtype(), @types.DataType::String)
  assert_eq(out.get_column("count").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("null_count").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("n_unique").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("mean").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("min").dtype(), @types.DataType::String)
  assert_eq(out.get_column("max").dtype(), @types.DataType::String)
}

// ── Per-row content: every dtype ──────────────────────────────────────

///|
test "describe row 0 summarises the Int column" {
  let df = describe_df()
  let out = df.describe()
  // Column "i": values [1, None, 3, 5] → count=3, null=1, unique=3,
  // mean=3.0, min=1, max=5.
  assert_eq(out.item(0, "column"), @types.Scalar::String("i"))
  assert_eq(out.item(0, "dtype"), @types.Scalar::String("Int"))
  assert_eq(out.item(0, "count"), @types.Scalar::Int(3))
  assert_eq(out.item(0, "null_count"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "n_unique"), @types.Scalar::Int(3))
  assert_eq(out.item(0, "mean"), @types.Scalar::Float(3.0))
  assert_eq(out.item(0, "min"), @types.Scalar::String("1"))
  assert_eq(out.item(0, "max"), @types.Scalar::String("5"))
}

///|
test "describe row 1 summarises the Float column" {
  let df = describe_df()
  let out = df.describe()
  // Column "f": values [1.0, 2.0, None, 3.0] → count=3, null=1,
  // unique=3, mean=2.0, min=1.0, max=3.0.
  assert_eq(out.item(1, "column"), @types.Scalar::String("f"))
  assert_eq(out.item(1, "dtype"), @types.Scalar::String("Float"))
  assert_eq(out.item(1, "count"), @types.Scalar::Int(3))
  assert_eq(out.item(1, "null_count"), @types.Scalar::Int(1))
  assert_eq(out.item(1, "n_unique"), @types.Scalar::Int(3))
  assert_eq(out.item(1, "mean"), @types.Scalar::Float(2.0))
  // Double::to_string emits "1" / "3" — confirm the cells are non-null.
  let min_cell = out.item(1, "min")
  let max_cell = out.item(1, "max")
  assert_true(not(min_cell.is_null()))
  assert_true(not(max_cell.is_null()))
}

///|
test "describe row 2 summarises the Bool column (mean is Null)" {
  let df = describe_df()
  let out = df.describe()
  // Column "b": values [true, false, true, true] → count=4, null=0,
  // unique=2 (true / false), mean=Null (TypeMismatch collapses to
  // null), min=false, max=true.
  assert_eq(out.item(2, "column"), @types.Scalar::String("b"))
  assert_eq(out.item(2, "dtype"), @types.Scalar::String("Bool"))
  assert_eq(out.item(2, "count"), @types.Scalar::Int(4))
  assert_eq(out.item(2, "null_count"), @types.Scalar::Int(0))
  assert_eq(out.item(2, "n_unique"), @types.Scalar::Int(2))
  assert_eq(out.item(2, "mean"), @types.Scalar::Null)
  // Bool::to_string emits "true" / "false".
  assert_eq(out.item(2, "min"), @types.Scalar::String("false"))
  assert_eq(out.item(2, "max"), @types.Scalar::String("true"))
}

///|
test "describe row 3 summarises the String column (mean is Null)" {
  let df = describe_df()
  let out = df.describe()
  // Column "s": values ["banana","apple","cherry","banana"] → count=4,
  // null=0, unique=3, mean=Null, min="apple", max="cherry".
  assert_eq(out.item(3, "column"), @types.Scalar::String("s"))
  assert_eq(out.item(3, "dtype"), @types.Scalar::String("String"))
  assert_eq(out.item(3, "count"), @types.Scalar::Int(4))
  assert_eq(out.item(3, "null_count"), @types.Scalar::Int(0))
  assert_eq(out.item(3, "n_unique"), @types.Scalar::Int(3))
  assert_eq(out.item(3, "mean"), @types.Scalar::Null)
  assert_eq(out.item(3, "min"), @types.Scalar::String("apple"))
  assert_eq(out.item(3, "max"), @types.Scalar::String("cherry"))
}

// ── Empty / all-null branches ────────────────────────────────────────

///|
test "describe on a 0-row numeric frame routes mean / min / max to Null" {
  // Empty Int column → Series::mean raises InvalidOperation,
  // Series::min / max return Scalar::Null. Both map to the
  // The min/max null branch.
  let schema = @types.Schema::Schema([
    @types.Field::Field("a", @types.DataType::Int),
    @types.Field::Field("b", @types.DataType::Float),
  ])
  let df = DataFrame::empty(schema)
  let out = df.describe()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 8))
  // Both rows: count=0, null=0, unique=0, mean=Null, min=Null, max=Null.
  for i in 0..<2 {
    assert_eq(out.item(i, "count"), @types.Scalar::Int(0))
    assert_eq(out.item(i, "null_count"), @types.Scalar::Int(0))
    assert_eq(out.item(i, "n_unique"), @types.Scalar::Int(0))
    assert_eq(out.item(i, "mean"), @types.Scalar::Null)
    assert_eq(out.item(i, "min"), @types.Scalar::Null)
    assert_eq(out.item(i, "max"), @types.Scalar::Null)
  }
}

///|
test "describe on an all-null numeric column routes mean / min / max to Null" {
  // `mean_opt`'s `None` arm reached by the empty-scope route here (numeric
  // column with zero non-null cells), distinct from the non-numeric route
  // covered by the Bool / String rows above.
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [None, None, None]),
  ])
  let out = df.describe()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "count"), @types.Scalar::Int(0))
  assert_eq(out.item(0, "null_count"), @types.Scalar::Int(3))
  assert_eq(out.item(0, "n_unique"), @types.Scalar::Int(0))
  assert_eq(out.item(0, "mean"), @types.Scalar::Null)
  assert_eq(out.item(0, "min"), @types.Scalar::Null)
  assert_eq(out.item(0, "max"), @types.Scalar::Null)
}

///|
test "describe on an all-null String column produces typed-null extrema" {
  // String column with no non-null cells: the min/max
  // is_null=true branch still applies to a non-numeric column.
  let df = DataFrame::DataFrame([Series::from_string_options("s", [None, None])])
  let out = df.describe()
  assert_eq(out.item(0, "dtype"), @types.Scalar::String("String"))
  assert_eq(out.item(0, "count"), @types.Scalar::Int(0))
  assert_eq(out.item(0, "null_count"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "min"), @types.Scalar::Null)
  assert_eq(out.item(0, "max"), @types.Scalar::Null)
}

// ── Edge: zero columns ───────────────────────────────────────────────

///|
test "describe on a 0-column frame collapses to a 0x8 result" {
  let df = DataFrame::DataFrame([])
  let out = df.describe()
  assert_eq(out.check_invariants(), Ok(()))
  // No source columns → no output rows, but the eight schema columns
  // are still present so downstream code can rely on the result shape.
  assert_eq(out.shape(), (0, 8))
  assert_eq(out.columns(), describe_schema())
}

// ── All-non-numeric mix (mean's raise path on every row) ─────────────

///|
test "describe on an all-String frame leaves mean Null for every row" {
  // Every source column is non-numeric → every `s.mean_opt()` is `None`
  // → every mean cell is Null.
  let df = DataFrame::DataFrame([
    Series::from_strings("a", ["x", "y"]),
    Series::from_strings("b", ["m", "n"]),
  ])
  let out = df.describe()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 8))
  for i in 0..<2 {
    assert_eq(out.item(i, "mean"), @types.Scalar::Null)
  }
}

// ── Column-order preservation ────────────────────────────────────────

///|
test "describe preserves source column order in the `column` row labels" {
  let df = DataFrame::DataFrame([
    Series::from_ints("z", [1, 2]),
    Series::from_ints("a", [3, 4]),
    Series::from_ints("m", [5, 6]),
  ])
  let out = df.describe()
  // Source declaration order is z, a, m — preserved verbatim, not
  // lexicographic.
  assert_eq(out.item(0, "column"), @types.Scalar::String("z"))
  assert_eq(out.item(1, "column"), @types.Scalar::String("a"))
  assert_eq(out.item(2, "column"), @types.Scalar::String("m"))
}

// ── Local helpers ────────────────────────────────────────────────────

///|
/// Tiny `Bool` negation — keeps the inline assertion readable.
fn not(b : Bool) -> Bool {
  if b {
    false
  } else {
    true
  }
}
