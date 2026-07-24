// Blackbox tests for the whole-frame reductions `DataFrame::sum` / `mean` /
// `min` / `max` / `count`, each returning a 1-row `DataFrame` (one cell per
// source column). The per-cell reductions delegate to the shared kernel
// (covered exhaustively in `series_stats_test.mbt` / `reduce_test.mbt`), so
// the tests here focus on the frame-level behaviour:
//   (1) shape — a 1-row frame, names and order preserved (0-column → 0×0);
//   (2) the uniform numeric-only rule — numeric columns reduce, non-numeric
//       columns become a `Null` cell kept in their source dtype (`mean`
//       retypes numeric to `Float`; `count` is the non-null count as `Int`
//       for every dtype);
//   (3) the empty / all-null edges — `sum` is the additive identity while
//       `mean` / `min` / `max` are a `Null` cell (not `InvalidOperation`);
//   (4) the single-column scalar path through `Series` (the v0.4
//       `df.sum("col")` migration target).

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
test "reductions on a 0-column frame collapse to 0x0" {
  let df = DataFrame::DataFrame([])
  assert_eq(df.sum().shape(), (0, 0))
  assert_eq(df.mean().shape(), (0, 0))
  assert_eq(df.min().shape(), (0, 0))
  assert_eq(df.max().shape(), (0, 0))
  assert_eq(df.count().shape(), (0, 0))
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
