// Blackbox tests for the `group_by` convenience verbs — `GroupedDataFrame`
// methods sugar over `agg` with the op applied to every non-key column. The
// aggregation kernel's own dtype / null / `NaN` rules are pinned by the
// cross-surface suite; what is pinned here is the *expansion*: which columns
// a verb aggregates (every non-key one, in source order), what the key
// columns head, the dtype-total ops on a mixed frame, `len`'s column-blind
// row counts against `count`'s per-column non-null counts, and the
// numeric-only ops surfacing `agg`'s `TypeMismatch` on a non-numeric column.

///|
/// Numeric fixture: one key column, an `Int` value column with a null, and a
/// `Float` value column with a null — the "a" group holds [3, 1, 2] / [1.0,
/// 2.0, null], the all-null-in-`v` group "b" holds [None] / [4.0].
fn conv_nums_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "a", "b"]),
    Series::from_int_options("v", [Some(3), Some(1), Some(2), None]),
    Series::from_float_options("f", [Some(1.0), Some(2.0), None, Some(4.0)]),
  ])
}

///|
/// Mixed fixture: a `String` non-key column, for the dtype-total ops and the
/// numeric-only ops' `TypeMismatch`.
fn conv_mixed_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "a", "b"]),
    Series::from_int_options("v", [Some(3), Some(1), Some(2), None]),
    Series::from_strings("tag", ["x", "x", "y", "z"]),
  ])
}

///|
test "sum aggregates every non-key column; an all-null group is the identity" {
  let r = conv_nums_df().group_by([@expr.col("k")]).sum()
  assert_eq(r.columns(), ["k", "v", "f"])
  assert_eq(r.get_column("v").to_scalars(), [
    @types.Scalar::Int(6),
    @types.Scalar::Int(0),
  ])
  // 1.0 + 2.0 and 4.0 — group "a"'s null skipped, "b" reduced to its own
  // column's cells.
  assert_eq(r.get_column("f").to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(4.0),
  ])
  assert_eq(r.check_invariants(), Ok(()))
}

///|
test "mean / median / quantile take every non-key column" {
  let g = conv_nums_df().group_by([@expr.col("k")])
  let mean = g.mean()
  assert_eq(mean.get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  assert_eq(mean.get_column("f").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(4.0),
  ])
  let median = g.median()
  assert_eq(median.get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  // The default interpolation is Nearest: over [1, 2, 3] the 0.5 quantile
  // names position 1.0 — the middle cell; Linear agrees there, and differs
  // from Nearest on the "f" group's two present values [1.0, 2.0] (position
  // 0.5: Linear averages, Nearest rounds up).
  let q = g.quantile(0.5)
  assert_eq(q.get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
  assert_eq(q.get_column("f").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(4.0),
  ])
  let ql = g.quantile(0.5, interpolation=@series.QuantileInterpolation::Linear)
  assert_eq(ql.get_column("f").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(4.0),
  ])
}

///|
test "std and variance are exact on a whole-middle fixture, null on sparse" {
  // [2, 4, 6]: every Welford mean is whole, so variance 4 / std 2 exactly;
  // group "b" has one non-null cell — no sample denominator, a Null cell.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "a", "b"]),
    Series::from_ints("v", [2, 4, 6, 5]),
  ])
  let g = df.group_by([@expr.col("k")])
  assert_eq(g.variance().get_column("v").to_scalars(), [
    @types.Scalar::Float(4.0),
    @types.Scalar::Null,
  ])
  assert_eq(g.std().get_column("v").to_scalars(), [
    @types.Scalar::Float(2.0),
    @types.Scalar::Null,
  ])
}

///|
test "min / max are dtype-total: String columns reduce, all-null a Null cell" {
  let g = conv_mixed_df().group_by([@expr.col("k")])
  assert_eq(g.min().get_column("v").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
  ])
  // Lexicographic: min("x", "x", "y") = "x"; max = "y".
  assert_eq(g.min().get_column("tag").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("z"),
  ])
  assert_eq(g.max().get_column("tag").to_scalars(), [
    @types.Scalar::String("y"),
    @types.Scalar::String("z"),
  ])
}

///|
test "first / last are positional per group" {
  let g = conv_mixed_df().group_by([@expr.col("k")])
  assert_eq(g.first().get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Null,
  ])
  assert_eq(g.last().get_column("tag").to_scalars(), [
    @types.Scalar::String("y"),
    @types.Scalar::String("z"),
  ])
}

///|
test "count counts non-null cells per column; len counts rows, one column" {
  let g = conv_mixed_df().group_by([@expr.col("k")])
  let c = g.count()
  assert_eq(c.columns(), ["k", "v", "tag"])
  assert_eq(c.get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(0),
  ])
  assert_eq(c.get_column("tag").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(1),
  ])
  let l = g.len()
  // One Int column named "len", after the key columns — nulls included
  // ("b"'s single null row counts).
  assert_eq(l.columns(), ["k", "len"])
  assert_eq(l.get_column("len").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(1),
  ])
  assert_eq(l.get_column("len").dtype(), @types.DataType::Int)
}

///|
test "n_unique counts distinct non-null cells per column" {
  let r = conv_mixed_df().group_by([@expr.col("k")]).n_unique()
  assert_eq(r.get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(0),
  ])
  assert_eq(r.get_column("tag").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
}

///|
test "a numeric-only verb raises TypeMismatch on a non-numeric column" {
  // `sum` over the String "tag" column is the aggregation kernel's
  // `TypeMismatch`, exactly as an explicit `agg([col("tag").sum()])` raises.
  assert_true(
    (Ok(conv_mixed_df().group_by([@expr.col("k")]).sum()) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}

///|
test "a frame whose every column is a key reduces to the distinct keys" {
  // A two-column frame grouped by both columns leaves no non-key column:
  // the convenience degenerates to `agg([])`, the distinct key tuples —
  // (a, x), (a, y), (b, z) in first-appearance order.
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_strings("tag", ["x", "y", "z"]),
  ])
  let r = df.group_by([@expr.col("k"), @expr.col("tag")]).sum()
  assert_eq(r.columns(), ["k", "tag"])
  assert_eq(r.nrows(), 3)
  assert_eq(r.get_column("tag").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("y"),
    @types.Scalar::String("z"),
  ])
}

///|
test "a 0-row frame yields zero groups for every convenience" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", []),
    Series::from_ints("v", []),
  ])
  let g = df.group_by([@expr.col("k")])
  assert_eq(g.sum().shape(), (0, 2))
  assert_eq(g.len().shape(), (0, 2))
  assert_eq(g.n_unique().shape(), (0, 2))
}

///|
test "an empty-keys group_by aggregates every column as one grand total" {
  let r = conv_nums_df().group_by([]).len()
  assert_eq(r.shape(), (1, 1))
  assert_eq(r.get_column("len").to_scalars(), [@types.Scalar::Int(4)])
}
