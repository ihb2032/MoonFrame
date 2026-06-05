// Property-based tests (quickcheck) for the `frame` package. These assert
// structural invariants over randomly generated frames, complementing the
// example-based tests: sorting is idempotent, and `group_by` partitions rows
// without loss or duplication.

///|
/// A non-empty `Array[Int64]` of length `1..=max_len`, each element drawn from
/// `[lo, hi]`. Drives the single-column numeric-frame properties below.
fn gen_i64_array(max_len : Int, lo : Int, hi : Int) -> @gen.Gen[Array[Int64]] {
  @gen.int_range(1, max_len).bind(n => {
    @gen.int_range(lo, hi).fmap(x => x.to_int64()).array_with_size(n)
  })
}

///|
/// Sorting an already-sorted frame changes nothing — idempotence holds for any
/// data (duplicates, negatives, any length).
fn prop_sort_idempotent(xs : Array[Int64]) -> Bool {
  try {
    let df = DataFrame::new([Series::from_ints("x", xs)])
    let once = df.sort_by([("x", Asc, NullsLast)])
    once == once.sort_by([("x", Asc, NullsLast)])
  } catch {
    _ => false
  }
}

///|
test "property: sort_by is idempotent" {
  @qc.quick_check(
    @qc.forall(gen_i64_array(30, -1000, 1000), prop_sort_idempotent),
  )
}

///|
/// `group_by` partitions rows with neither loss nor duplication: tag every row
/// with a `1`, and the per-group sums must total exactly the row count.
fn prop_group_by_no_row_loss(keys : Array[Int64]) -> Bool {
  let n = keys.length()
  try {
    let df = DataFrame::new([
      Series::from_ints("k", keys),
      Series::from_ints("ones", Array::make(n, (1 : Int64))),
    ])
    let summed = df.group_by(["k"]).agg([AggSpec::sum("ones")]).sum("ones_sum")
    summed == @types.Scalar::Int(n.to_int64())
  } catch {
    _ => false
  }
}

///|
test "property: group_by loses no rows" {
  // Small key range (0..5) so groups actually collide.
  @qc.quick_check(
    @qc.forall(gen_i64_array(30, 0, 5), prop_group_by_no_row_loss),
  )
}
