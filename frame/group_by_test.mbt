// Blackbox tests for `DataFrame::group_by` / `GroupedDataFrame::agg`.
//
// `agg` takes reduction expressions; these tests drive it with the
// bare-column reductions `col(c).<agg>()`, aliased to the `"<col>_<kind>"`
// names the retired `AggSpec` produced, so they double as a regression pin
// on that behaviour. The expression-specific surface (compound / derived
// reductions, the reduction-shape gate, naming and backend rules) lives in
// agg_expr_test.mbt; here the focus is group partitioning and the per-group
// dtype-of-result behaviour.
//
// Invariants asserted across the happy-path tests:
//   (1) check_invariants() == Ok(()) — every agg result routes through
//       DataFrame::DataFrame, so it must satisfy the structural spec.
//   (2) output column order = key columns (in `keys` order) then one
//       column per aggregation expression (in expression order).
//   (3) group (row) order = first appearance of the key tuple.
//
// Reductions reuse the `Series` statistics, so null / NaN / dtype rules
// are inherited; the tests pin the group-partitioning and the
// per-group dtype-of-result behaviour rather than re-deriving the Series
// stat semantics.

///|
/// Five-row sales fixture: two String keys, an Int measure, a Float
/// measure. Grouped by `region` it splits into `east` (rows 0, 2, 3) and
/// `west` (rows 1, 4); `east` appears first.
fn sales_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("region", ["east", "west", "east", "east", "west"]),
    Series::from_strings("product", [
      "widget", "widget", "gadget", "widget", "gadget",
    ]),
    Series::from_ints("quantity", [10, 5, 2, 6, 4]),
    Series::from_floats("revenue", [100.0, 50.0, 30.0, 70.0, 20.0]),
  ])
}

// ── Single key, every reduction ──────────────────────────────────────

///|
test "group_by single key with all five default-named aggregations" {
  let out = sales_df()
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("quantity").count().with_alias("quantity_count"),
      @expr.col("quantity").sum().with_alias("quantity_sum"),
      @expr.col("quantity").mean().with_alias("quantity_mean"),
      @expr.col("quantity").min().with_alias("quantity_min"),
      @expr.col("quantity").max().with_alias("quantity_max"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  // Key column first, then one column per expression, default-named.
  assert_eq(out.columns(), [
    "region", "quantity_count", "quantity_sum", "quantity_mean", "quantity_min",
    "quantity_max",
  ])
  // Two groups, in first-appearance order: east, west.
  assert_eq(out.shape(), (2, 6))
  assert_eq(out.item(0, "region"), @types.Scalar::String("east"))
  assert_eq(out.item(1, "region"), @types.Scalar::String("west"))
  // east: quantity = [10, 2, 6] → count 3, sum 18, mean 6.0, min 2, max 10.
  assert_eq(out.item(0, "quantity_count"), @types.Scalar::Int(3))
  assert_eq(out.item(0, "quantity_sum"), @types.Scalar::Int(18))
  assert_eq(out.item(0, "quantity_mean"), @types.Scalar::Float(6.0))
  assert_eq(out.item(0, "quantity_min"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "quantity_max"), @types.Scalar::Int(10))
  // west: quantity = [5, 4] → count 2, sum 9, mean 4.5, min 4, max 5.
  assert_eq(out.item(1, "quantity_count"), @types.Scalar::Int(2))
  assert_eq(out.item(1, "quantity_sum"), @types.Scalar::Int(9))
  assert_eq(out.item(1, "quantity_mean"), @types.Scalar::Float(4.5))
  assert_eq(out.item(1, "quantity_min"), @types.Scalar::Int(4))
  assert_eq(out.item(1, "quantity_max"), @types.Scalar::Int(5))
}

///|
test "group_by aggregates a second measure column (Float sum)" {
  let out = sales_df()
    .group_by([@expr.col("region")])
    .agg([@expr.col("revenue").sum().with_alias("revenue_sum")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["region", "revenue_sum"])
  // east revenue = [100, 30, 70] → 200.0; west = [50, 20] → 70.0.
  assert_eq(out.item(0, "revenue_sum"), @types.Scalar::Float(200.0))
  assert_eq(out.item(1, "revenue_sum"), @types.Scalar::Float(70.0))
}

// ── Multi key ────────────────────────────────────────────────────────

///|
test "group_by multiple keys partitions by the key tuple" {
  let out = sales_df()
    .group_by([@expr.col("region"), @expr.col("product")])
    .agg([@expr.col("quantity").sum().with_alias("quantity_sum")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["region", "product", "quantity_sum"])
  // Four distinct (region, product) tuples, in first-appearance order:
  // (east,widget), (west,widget), (east,gadget), (west,gadget).
  assert_eq(out.shape(), (4, 3))
  assert_eq(out.item(0, "region"), @types.Scalar::String("east"))
  assert_eq(out.item(0, "product"), @types.Scalar::String("widget"))
  assert_eq(out.item(0, "quantity_sum"), @types.Scalar::Int(16)) // rows 0,3 → 10+6
  assert_eq(out.item(1, "region"), @types.Scalar::String("west"))
  assert_eq(out.item(1, "product"), @types.Scalar::String("widget"))
  assert_eq(out.item(1, "quantity_sum"), @types.Scalar::Int(5))
  assert_eq(out.item(2, "region"), @types.Scalar::String("east"))
  assert_eq(out.item(2, "product"), @types.Scalar::String("gadget"))
  assert_eq(out.item(2, "quantity_sum"), @types.Scalar::Int(2))
  assert_eq(out.item(3, "region"), @types.Scalar::String("west"))
  assert_eq(out.item(3, "product"), @types.Scalar::String("gadget"))
  assert_eq(out.item(3, "quantity_sum"), @types.Scalar::Int(4))
}

// ── Aliases ──────────────────────────────────────────────────────────

///|
test "with_alias overrides the aggregated column name" {
  let out = sales_df()
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("quantity").sum().with_alias("total_q"),
      @expr.col("revenue").mean().with_alias("avg_rev"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["region", "total_q", "avg_rev"])
  assert_eq(out.item(0, "total_q"), @types.Scalar::Int(18))
}

// ── Group order (first appearance) ───────────────────────────────────

///|
test "group order follows first appearance, not sorted order" {
  // Keys first seen as z, a, m — the result must preserve that order
  // rather than sorting to a, m, z.
  let df = DataFrame::DataFrame([
    Series::from_strings("g", ["z", "a", "z", "a", "m"]),
    Series::from_ints("v", [1, 2, 3, 4, 5]),
  ])
  let out = df
    .group_by([@expr.col("g")])
    .agg([@expr.col("v").sum().with_alias("v_sum")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "g"), @types.Scalar::String("z"))
  assert_eq(out.item(1, "g"), @types.Scalar::String("a"))
  assert_eq(out.item(2, "g"), @types.Scalar::String("m"))
  assert_eq(out.item(0, "v_sum"), @types.Scalar::Int(4)) // rows 0,2 → 1+3
  assert_eq(out.item(1, "v_sum"), @types.Scalar::Int(6)) // rows 1,3 → 2+4
  assert_eq(out.item(2, "v_sum"), @types.Scalar::Int(5)) // row 4
}

// ── Null keys ────────────────────────────────────────────────────────

///|
test "a null key forms its own group, distinct from an empty string" {
  // Column has "a", null, "" (empty string), "a". The null and the empty
  // string must NOT collapse together, and the null must survive as its
  // own group rather than being dropped.
  let df = DataFrame::DataFrame([
    Series::from_string_options("k", [Some("a"), None, Some(""), Some("a")]),
    Series::from_ints("v", [1, 2, 3, 4]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([@expr.col("v").sum().with_alias("v_sum")])
  assert_eq(out.check_invariants(), Ok(()))
  // Three groups in first-appearance order: "a", null, "".
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.item(0, "k"), @types.Scalar::String("a"))
  assert_eq(out.item(1, "k"), @types.Scalar::Null)
  assert_eq(out.item(2, "k"), @types.Scalar::String(""))
  assert_eq(out.item(0, "v_sum"), @types.Scalar::Int(5)) // rows 0,3 → 1+4
  assert_eq(out.item(1, "v_sum"), @types.Scalar::Int(2)) // row 1
  assert_eq(out.item(2, "v_sum"), @types.Scalar::Int(3)) // row 2
}

// ── Float NaN keys collapse into one group ───────────────────────────

///|
test "Float NaN keys collapse into a single group" {
  let nan : Double = @double.not_a_number
  // Keys nan, 1.0, nan — the two NaNs must land in the SAME group (they
  // render "NaN"), giving two groups, not three.
  let df = DataFrame::DataFrame([
    Series::from_floats("k", [nan, 1.0, nan]),
    Series::from_ints("v", [1, 2, 3]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([@expr.col("v").sum().with_alias("v_sum")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 2))
  // NaN group (rows 0,2) first, then the 1.0 group (row 1).
  assert_eq(out.item(0, "v_sum"), @types.Scalar::Int(4))
  assert_eq(out.item(1, "v_sum"), @types.Scalar::Int(2))
}

///|
test "Float -0.0 and +0.0 keys collapse into a single group" {
  // +0.0 and -0.0 are IEEE-equal and both render "0", so they must land in
  // the SAME group — exercising the `KFloat` zero-fold in `row_key.mbt`
  // (without it the two would hash to distinct keys). Keys 0.0, -0.0, 1.5,
  // 0.0 give two groups: the zero group (rows 0, 1, 3) then the 1.5 group
  // (row 2).
  let df = DataFrame::DataFrame([
    Series::from_floats("k", [0.0, -0.0, 1.5, 0.0]),
    Series::from_ints("v", [1, 2, 3, 4]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([@expr.col("v").sum().with_alias("v_sum")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 2))
  // Zero group first (sum 1 + 2 + 4 = 7), then the 1.5 group (3).
  assert_eq(out.item(0, "k"), @types.Scalar::Float(0.0))
  assert_eq(out.item(0, "v_sum"), @types.Scalar::Int(7))
  assert_eq(out.item(1, "k"), @types.Scalar::Float(1.5))
  assert_eq(out.item(1, "v_sum"), @types.Scalar::Int(3))
}

// ── Dtype preservation ───────────────────────────────────────────────

///|
test "group_by preserves the key column dtype (Int key)" {
  let df = DataFrame::DataFrame([
    Series::from_ints("k", [1, 1, 2]),
    Series::from_ints("v", [10, 20, 30]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([@expr.col("v").sum().with_alias("v_sum")])
  assert_eq(out.check_invariants(), Ok(()))
  // Key column keeps Int dtype (not stringified).
  assert_eq(out.get_column("k").dtype(), @types.DataType::Int)
  assert_eq(out.item(0, "k"), @types.Scalar::Int(1))
  assert_eq(out.item(1, "k"), @types.Scalar::Int(2))
  assert_eq(out.item(0, "v_sum"), @types.Scalar::Int(30))
  assert_eq(out.item(1, "v_sum"), @types.Scalar::Int(30))
}

///|
test "sum keeps the source numeric dtype; mean is always Float" {
  let out = sales_df()
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("quantity").sum().with_alias("quantity_sum"), // Int source → Int
      @expr.col("revenue").sum().with_alias("revenue_sum"), // Float source → Float
      @expr.col("quantity").mean().with_alias("quantity_mean"), // → Float
    ])
  assert_eq(out.get_column("quantity_sum").dtype(), @types.DataType::Int)
  assert_eq(out.get_column("revenue_sum").dtype(), @types.DataType::Float)
  assert_eq(out.get_column("quantity_mean").dtype(), @types.DataType::Float)
}

///|
test "agg: a group whose Int sum exceeds 2^63 still means within range" {
  // Per-group mean reduces through the same kernel as `Series::mean`, so an
  // `Int64`-accumulator wrap would surface here too: group "a" sums to 2^63,
  // which would flip its mean negative. It must stay 2^62.
  let two_62 : Int64 = 4611686018427387904
  let out = DataFrame::DataFrame([
      Series::from_strings("g", ["a", "a", "b"]),
      Series::from_ints("v", [two_62, two_62, 1]),
    ])
    .group_by([@expr.col("g")])
    .agg([@expr.col("v").mean().with_alias("v_mean")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "v_mean"), @types.Scalar::Float(two_62.to_double()))
  assert_eq(out.item(1, "v_mean"), @types.Scalar::Float(1.0))
}

// ── Nulls within a group ─────────────────────────────────────────────

///|
test "count excludes nulls; an all-null group reduces to identity / null" {
  // Group "a": one value, one null. Group "b": two nulls.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b", "b"]),
    Series::from_int_options("v", [Some(1), None, None, None]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").count().with_alias("v_count"),
      @expr.col("v").sum().with_alias("v_sum"),
      @expr.col("v").mean().with_alias("v_mean"),
      @expr.col("v").min().with_alias("v_min"),
      @expr.col("v").max().with_alias("v_max"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  // Group a: count 1 (null skipped), sum 1, mean 1.0, min 1, max 1.
  assert_eq(out.item(0, "v_count"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "v_sum"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "v_mean"), @types.Scalar::Float(1.0))
  assert_eq(out.item(0, "v_min"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "v_max"), @types.Scalar::Int(1))
  // Group b (all null): count 0, sum 0 (identity), mean/min/max null.
  assert_eq(out.item(1, "v_count"), @types.Scalar::Int(0))
  assert_eq(out.item(1, "v_sum"), @types.Scalar::Int(0))
  assert_eq(out.item(1, "v_mean"), @types.Scalar::Null)
  assert_eq(out.item(1, "v_min"), @types.Scalar::Null)
  assert_eq(out.item(1, "v_max"), @types.Scalar::Null)
}

///|
test "agg: an all-null Float group means a null cell" {
  // The all-null *Int* group above exercises the Int mean arm's empty-group
  // path; the Float arm needs its own: a group whose Float cells are all null
  // (validity 0, distinct from a NaN value) has no present cell, so its mean
  // is a null cell rather than NaN or a hard failure.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_float_options("v", [Some(1.0), Some(3.0), None]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([@expr.col("v").mean().with_alias("v_mean")])
  assert_eq(out.check_invariants(), Ok(()))
  // Group a = [1.0, 3.0] → mean 2.0; group b = [null] → null mean.
  assert_eq(out.item(0, "v_mean"), @types.Scalar::Float(2.0))
  assert_eq(out.item(1, "v_mean"), @types.Scalar::Null)
}

///|
test "Float NaN propagates through sum / mean but is skipped by min / max within a group" {
  let nan : Double = @double.not_a_number
  // The null / NaN distinction, per group:
  //   "a" = [1.0, NaN]      — a value plus a NaN
  //   "b" = [2.0, null]     — a value plus a missing cell
  //   "c" = [NaN, NaN]      — all NaN
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b", "b", "c", "c"]),
    Series::from_float_options("v", [
      Some(1.0),
      Some(nan),
      Some(2.0),
      None,
      Some(nan),
      Some(nan),
    ]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").sum().with_alias("v_sum"),
      @expr.col("v").mean().with_alias("v_mean"),
      @expr.col("v").min().with_alias("v_min"),
      @expr.col("v").max().with_alias("v_max"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  // Group a: NaN is a value that propagates → sum and mean are NaN; min /
  // max skip NaN (Polars' regular min / max) → 1.0.
  assert_true(out.item(0, "v_sum").as_float().is_nan())
  assert_true(out.item(0, "v_mean").as_float().is_nan())
  assert_eq(out.item(0, "v_min"), @types.Scalar::Float(1.0))
  assert_eq(out.item(0, "v_max"), @types.Scalar::Float(1.0))
  // Group b: the null is skipped (not propagated like NaN) → a finite sum
  // and mean of 2.0, min / max 2.0.
  assert_eq(out.item(1, "v_sum"), @types.Scalar::Float(2.0))
  assert_eq(out.item(1, "v_mean"), @types.Scalar::Float(2.0))
  assert_eq(out.item(1, "v_min"), @types.Scalar::Float(2.0))
  assert_eq(out.item(1, "v_max"), @types.Scalar::Float(2.0))
  // Group c (all NaN): sum / mean propagate to NaN; min / max skip every
  // cell → null (as for an all-null group).
  assert_true(out.item(2, "v_sum").as_float().is_nan())
  assert_true(out.item(2, "v_mean").as_float().is_nan())
  assert_eq(out.item(2, "v_min"), @types.Scalar::Null)
  assert_eq(out.item(2, "v_max"), @types.Scalar::Null)
}

// ── min / max over every dtype ───────────────────────────────────────

///|
/// Fixture exercising `min` / `max` across all four dtypes with a group
/// that has values (`A`) and a group that is entirely null (`B`).
fn extrema_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("k", ["A", "A", "B"]),
    Series::from_int_options("vi", [Some(3), Some(1), None]),
    Series::from_float_options("vf", [Some(1.5), Some(2.5), None]),
    Series::from_bool_options("vb", [Some(true), Some(false), None]),
    Series::from_string_options("vs", [Some("x"), Some("z"), None]),
  ])
}

///|
test "min over Int / Float / Bool / String, all-null group → null" {
  let out = extrema_df()
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("vi").min().with_alias("vi_min"),
      @expr.col("vf").min().with_alias("vf_min"),
      @expr.col("vb").min().with_alias("vb_min"),
      @expr.col("vs").min().with_alias("vs_min"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  // Group A has values; each min keeps the source dtype.
  assert_eq(out.item(0, "vi_min"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "vf_min"), @types.Scalar::Float(1.5))
  assert_eq(out.item(0, "vb_min"), @types.Scalar::Bool(false)) // false < true
  assert_eq(out.item(0, "vs_min"), @types.Scalar::String("x"))
  // Group B is all null → null cell for every dtype.
  assert_eq(out.item(1, "vi_min"), @types.Scalar::Null)
  assert_eq(out.item(1, "vf_min"), @types.Scalar::Null)
  assert_eq(out.item(1, "vb_min"), @types.Scalar::Null)
  assert_eq(out.item(1, "vs_min"), @types.Scalar::Null)
  // Result dtypes match the source columns.
  assert_eq(out.get_column("vb_min").dtype(), @types.DataType::Bool)
  assert_eq(out.get_column("vs_min").dtype(), @types.DataType::String)
}

///|
test "max over Int / Float / Bool / String, all-null group → null" {
  let out = extrema_df()
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("vi").max().with_alias("vi_max"),
      @expr.col("vf").max().with_alias("vf_max"),
      @expr.col("vb").max().with_alias("vb_max"),
      @expr.col("vs").max().with_alias("vs_max"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.item(0, "vi_max"), @types.Scalar::Int(3))
  assert_eq(out.item(0, "vf_max"), @types.Scalar::Float(2.5))
  assert_eq(out.item(0, "vb_max"), @types.Scalar::Bool(true)) // true > false
  assert_eq(out.item(0, "vs_max"), @types.Scalar::String("z"))
  assert_eq(out.item(1, "vi_max"), @types.Scalar::Null)
  assert_eq(out.item(1, "vf_max"), @types.Scalar::Null)
  assert_eq(out.item(1, "vb_max"), @types.Scalar::Null)
  assert_eq(out.item(1, "vs_max"), @types.Scalar::Null)
}

// ── Empty aggregations → distinct ────────────────────────────────────

///|
test "empty specs degenerates to distinct key combinations" {
  // Single key: distinct regions, in first-appearance order.
  let one = sales_df().group_by([@expr.col("region")]).agg([])
  assert_eq(one.check_invariants(), Ok(()))
  assert_eq(one.columns(), ["region"])
  assert_eq(one.shape(), (2, 1))
  assert_eq(one.item(0, "region"), @types.Scalar::String("east"))
  assert_eq(one.item(1, "region"), @types.Scalar::String("west"))
  // Multi key: distinct (region, product) tuples.
  let many = sales_df()
    .group_by([@expr.col("region"), @expr.col("product")])
    .agg([])
  assert_eq(many.check_invariants(), Ok(()))
  assert_eq(many.columns(), ["region", "product"])
  assert_eq(many.shape(), (4, 2))
}

// ── Empty / degenerate frames ────────────────────────────────────────

///|
test "group_by on a 0-row frame yields 0 groups with the key+agg schema" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", []),
    Series::from_ints("v", []),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").sum().with_alias("v_sum"),
      @expr.col("v").count().with_alias("v_count"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  // Zero groups → zero rows, but the schema (key + agg columns) stands.
  assert_eq(out.shape(), (0, 3))
  assert_eq(out.columns(), ["k", "v_sum", "v_count"])
}

///|
test "empty keys aggregate the whole frame as a single group" {
  let out = sales_df()
    .group_by([])
    .agg([
      @expr.col("quantity").sum().with_alias("quantity_sum"),
      @expr.col("quantity").count().with_alias("quantity_count"),
    ])
  assert_eq(out.check_invariants(), Ok(()))
  // No key columns; one grand-total row.
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.columns(), ["quantity_sum", "quantity_count"])
  assert_eq(out.item(0, "quantity_sum"), @types.Scalar::Int(27)) // 10+5+2+6+4
  assert_eq(out.item(0, "quantity_count"), @types.Scalar::Int(5))
}

///|
test "empty keys and empty specs collapse to a 0x0 frame" {
  let out = sales_df().group_by([]).agg([])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

// ── Composite-key injectivity ────────────────────────────────────────

///|
test "group_by: multi-key composite is injective across field boundaries" {
  // Naively concatenated, ("a","bc") and ("ab","c") both spell "abc" and
  // would collapse into one group. The composite key-cell tuple keeps
  // them apart → two groups.
  let df = DataFrame::DataFrame([
    Series::from_strings("k1", ["a", "ab"]),
    Series::from_strings("k2", ["bc", "c"]),
    Series::from_ints("v", [1, 2]),
  ])
  let out = df.group_by([@expr.col("k1"), @expr.col("k2")]).agg([])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 2))
}

// ── Error cases ──────────────────────────────────────────────────────

///|
test "group_by raises ColumnNotFound for an unknown key column" {
  let df = sales_df()
  assert_eq(
    Ok(df.group_by([@expr.col("nope")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nope")),
  )
}

///|
test "group_by raises DuplicateColumn for a key column named twice" {
  let df = sales_df()
  // A key repeated in `keys` would otherwise have `agg` emit two
  // identically-named "region" columns; it is rejected up front at the
  // repeat, in `keys` order.
  assert_eq(
    Ok(df.group_by([@expr.col("region"), @expr.col("region")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("region")),
  )
  // A *missing* key still surfaces as ColumnNotFound at its first
  // appearance, before the duplicate at the second is examined.
  assert_eq(
    Ok(df.group_by([@expr.col("nope"), @expr.col("nope")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nope")),
  )
}

///|
test "agg raises ColumnNotFound for an unknown aggregation column" {
  let grouped = sales_df().group_by([@expr.col("region")])
  assert_eq(
    Ok(grouped.agg([@expr.col("nope").sum()])) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("nope")),
  )
}

///|
test "Sum / Mean on a non-numeric column raises TypeMismatch" {
  let grouped = sales_df().group_by([@expr.col("region")])
  // product is a String column.
  assert_true(
    (Ok(grouped.agg([@expr.col("product").sum()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  assert_true(
    (Ok(grouped.agg([@expr.col("product").mean()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  // Also a Bool column: sum and mean are both undefined.
  let bgrouped = extrema_df().group_by([@expr.col("k")])
  assert_true(
    (Ok(bgrouped.agg([@expr.col("vb").sum()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
  assert_true(
    (Ok(bgrouped.agg([@expr.col("vb").mean()])) catch { e => Err(e) })
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(_))
    ),
  )
}

///|
test "colliding output column names raise DuplicateColumn" {
  let grouped = sales_df().group_by([@expr.col("region")])
  // Two expressions with the same aliased name.
  assert_eq(
    Ok(
      grouped.agg([
        @expr.col("quantity").sum().with_alias("quantity_sum"),
        @expr.col("quantity").sum().with_alias("quantity_sum"),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("quantity_sum")),
  )
  // An alias that shadows a key column.
  assert_eq(
    Ok(grouped.agg([@expr.col("quantity").sum().with_alias("region")])) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("region")),
  )
}

// ── Expression keys ──────────────────────────────────────────────────

///|
test "a derived key buckets rows by the computed value, named by its alias" {
  // The key is an expression, not a bare column: group by whether quantity
  // exceeds 5. quantity = [10, 5, 2, 6, 4] ⇒ gt(5) = [T, F, F, T, F], so two
  // groups in first-appearance order: big=true (rows 0, 3), big=false
  // (rows 1, 2, 4).
  let out = sales_df()
    .group_by([@expr.col("quantity").gt(@expr.lit_int(5)).with_alias("big")])
    .agg([@expr.col("quantity").sum().with_alias("q")])
  assert_eq(out.check_invariants(), Ok(()))
  // The materialised key column heads the output, named by its alias and
  // carrying the derived (Bool) dtype.
  assert_eq(out.columns(), ["big", "q"])
  assert_eq(out.get_column("big").dtype(), @types.DataType::Bool)
  assert_eq(out.shape(), (2, 2))
  assert_eq(out.item(0, "big"), @types.Scalar::Bool(true))
  assert_eq(out.item(0, "q"), @types.Scalar::Int(16)) // 10 + 6
  assert_eq(out.item(1, "big"), @types.Scalar::Bool(false))
  assert_eq(out.item(1, "q"), @types.Scalar::Int(11)) // 5 + 2 + 4
}

///|
test "a derived key with no alias takes its leftmost column's name" {
  // No alias ⇒ the output-name rule falls through to the leftmost column
  // reference (`quantity`), even though the key's value is a derived Bool.
  let out = sales_df()
    .group_by([@expr.col("quantity").gt(@expr.lit_int(5))])
    .agg([@expr.col("revenue").sum().with_alias("r")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["quantity", "r"])
  assert_eq(out.get_column("quantity").dtype(), @types.DataType::Bool)
}

///|
test "a length-1 key broadcasts every row into one group named literal" {
  // A literal key evaluates to length 1, broadcasting over the frame, so
  // every row shares it: one grand group, the key column named `"literal"`.
  let out = sales_df()
    .group_by([@expr.lit_int(1)])
    .agg([@expr.col("quantity").sum().with_alias("q")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["literal", "q"])
  assert_eq(out.shape(), (1, 2))
  assert_eq(out.item(0, "literal"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "q"), @types.Scalar::Int(27)) // 10 + 5 + 2 + 6 + 4
}

///|
test "group_by mixes a bare key and a derived key in a composite tuple" {
  // region = [east, west, east, east, west], quantity > 5 = [T, F, F, T, F].
  // Composite (region, big) groups, in first-appearance order:
  //   (east, true)  rows 0, 3 → 16
  //   (west, false) rows 1, 4 → 9
  //   (east, false) row 2     → 2
  let out = sales_df()
    .group_by([
      @expr.col("region"),
      @expr.col("quantity").gt(@expr.lit_int(5)).with_alias("big"),
    ])
    .agg([@expr.col("quantity").sum().with_alias("q")])
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.columns(), ["region", "big", "q"])
  assert_eq(out.shape(), (3, 3))
  assert_eq(out.item(0, "region"), @types.Scalar::String("east"))
  assert_eq(out.item(0, "big"), @types.Scalar::Bool(true))
  assert_eq(out.item(0, "q"), @types.Scalar::Int(16))
  assert_eq(out.item(1, "region"), @types.Scalar::String("west"))
  assert_eq(out.item(1, "big"), @types.Scalar::Bool(false))
  assert_eq(out.item(1, "q"), @types.Scalar::Int(9))
  assert_eq(out.item(2, "region"), @types.Scalar::String("east"))
  assert_eq(out.item(2, "big"), @types.Scalar::Bool(false))
  assert_eq(out.item(2, "q"), @types.Scalar::Int(2))
}

///|
test "a key expression whose dtypes do not unify raises structured TypeMismatch" {
  // region is String, quantity is Int — `+` cannot unify them, and the key
  // evaluation surfaces the error at `group_by`, in `keys` order.
  assert_eq(
    Ok(sales_df().group_by([@expr.col("region") + @expr.col("quantity")])) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Operation(
          "add",
          @types.DataType::String,
          @types.DataType::Int,
        ),
      ),
    ),
  )
}

///|
test "two keys producing the same output name raise DuplicateColumn" {
  // Distinct expressions, same alias ⇒ two identically-named key columns,
  // rejected up front at the second key (its evaluation succeeds first).
  assert_eq(
    Ok(
      sales_df().group_by([
        @expr.col("region").with_alias("k"),
        @expr.col("product").with_alias("k"),
      ]),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("k")),
  )
}

// The corrupted-`groups` handle case moved to the whitebox
// `group_by_wbtest.mbt`: `GroupedDataFrame`'s fields are now `priv`, so the
// handle can only be corrupted from inside the package.
