// Blackbox tests for the ranking selections `DataFrame::top_k` /
// `bottom_k` — the `k` rows at one end of a `by` ordering, through the sort
// kernel with nulls pinned last. Pinned: the end each verb selects, the
// deterministic sorted output order, `reverse~` flipping the end, stable
// ties, the null rule at both ends and under `reverse`, saturation, and the
// argument validation.

///|
/// Ranking fixture: `v` scrambling its order so a sorted answer proves the
/// selection, `id` identifying rows for the tie test.
fn rank_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("id", [1, 2, 3, 4]),
    Series::from_ints("v", [10, 30, 20, 40]),
  ])
}

///|
test "top_k / bottom_k select their end, in sorted order" {
  let df = rank_df()
  assert_eq(df.top_k(2, by=[@expr.col("v")]).get_column("v").to_scalars(), [
    @types.Scalar::Int(40),
    @types.Scalar::Int(30),
  ])
  assert_eq(df.bottom_k(2, by=[@expr.col("v")]).get_column("v").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
  ])
}

///|
test "reverse~ flips which end each verb names" {
  let df = rank_df()
  assert_eq(
    df.top_k(2, by=[@expr.col("v")], reverse=true).get_column("v").to_scalars(),
    [@types.Scalar::Int(10), @types.Scalar::Int(20)],
  )
  assert_eq(
    df
    .bottom_k(2, by=[@expr.col("v")], reverse=true)
    .get_column("v")
    .to_scalars(),
    [@types.Scalar::Int(40), @types.Scalar::Int(30)],
  )
}

///|
test "nulls rank last at both ends, surfacing only past the non-null rows" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(5), None, Some(3)]),
  ])
  // Descending with nulls last: [5, 3, null] — the top two are non-null.
  assert_eq(df.top_k(2, by=[@expr.col("v")]).get_column("v").to_scalars(), [
    @types.Scalar::Int(5),
    @types.Scalar::Int(3),
  ])
  // k reaching past the non-null rows takes the null row too.
  assert_eq(df.top_k(3, by=[@expr.col("v")]).get_column("v").to_scalars(), [
    @types.Scalar::Int(5),
    @types.Scalar::Int(3),
    @types.Scalar::Null,
  ])
  // Ascending with nulls last: [3, 5, null] — the same preference at the
  // other end.
  assert_eq(df.bottom_k(2, by=[@expr.col("v")]).get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(5),
  ])
}

///|
test "ties stay stable — the earlier row ranks first" {
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2, 3, 4]),
    Series::from_ints("v", [2, 2, 1, 1]),
  ])
  // Descending [2, 2, 1, 1]: the top three keep input order among equals.
  let r = df.top_k(3, by=[@expr.col("v")])
  assert_eq(r.get_column("id").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  assert_eq(r.get_column("v").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(2),
    @types.Scalar::Int(1),
  ])
}

///|
test "saturation: k = 0 is empty, k past the rows is the whole sorted frame" {
  let df = rank_df()
  assert_eq(df.top_k(0, by=[@expr.col("v")]).shape(), (0, 2))
  assert_eq(df.top_k(99, by=[@expr.col("v")]).shape(), (4, 2))
  assert_eq(df.top_k(99, by=[@expr.col("v")]).get_column("v").to_scalars(), [
    @types.Scalar::Int(40),
    @types.Scalar::Int(30),
    @types.Scalar::Int(20),
    @types.Scalar::Int(10),
  ])
}

///|
test "multi-key ranking breaks ties on the later key" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_ints("v", [2, 1, 3]),
  ])
  let r = df.top_k(2, by=[@expr.col("k"), @expr.col("v")])
  // Descending by (k, v): ("b", 3) then ("a", 2).
  assert_eq(r.get_column("k").to_scalars(), [
    @types.Scalar::String("b"),
    @types.Scalar::String("a"),
  ])
  assert_eq(r.get_column("v").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(2),
  ])
}

///|
test "a negative k or an empty by raises InvalidOperation" {
  assert_true(
    (Ok(rank_df().top_k(-1, by=[@expr.col("v")])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(rank_df().bottom_k(-1, by=[@expr.col("v")])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_true(
    (Ok(rank_df().top_k(1, by=[])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a missing ranking key surfaces the sort kernel's ColumnNotFound" {
  assert_true(
    (Ok(rank_df().top_k(1, by=[@expr.col("zzz")])) catch { e => Err(e) })
    is Err(@types.DataError::ColumnNotFound(_)),
  )
}
