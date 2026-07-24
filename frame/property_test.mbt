// Property-based tests (quickcheck) for the `frame` package. These assert
// structural invariants over randomly generated frames, complementing the
// example-based tests: sorting is idempotent and stable, and `group_by`
// partitions rows without loss or duplication.

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
    let df = DataFrame::DataFrame([Series::from_ints("x", xs)])
    let once = df.sort([(@expr.col("x"), Asc, NullsLast)])
    once == once.sort([(@expr.col("x"), Asc, NullsLast)])
  } catch {
    _ => false
  }
}

///|
test "property: sort is idempotent" {
  @qc.quick_check(
    @qc.forall(gen_i64_array(30, -1000, 1000), prop_sort_idempotent),
  )
}

///|
/// Whether `df` is ordered by `key` in the requested direction and preserves
/// increasing original row ids inside every equal-key run. The ids are unique
/// and start in input order, so the second condition is exactly sort stability.
fn sorted_stably(
  df : DataFrame,
  ascending : Bool,
) -> Bool raise @types.DataError {
  for i in 1..<df.nrows() {
    guard (
        df.item(i - 1, "key"),
        df.item(i, "key"),
        df.item(i - 1, "row_id"),
        df.item(i, "row_id"),
      )
      is (
        @types.Scalar::Int(previous_key),
        @types.Scalar::Int(key),
        @types.Scalar::Int(previous_id),
        @types.Scalar::Int(id),
      ) else {
      return false
    }
    if ascending {
      if previous_key > key || (previous_key == key && previous_id >= id) {
        return false
      }
    } else if previous_key < key || (previous_key == key && previous_id >= id) {
      return false
    }
  }
  true
}

///|
/// Both sort directions preserve the input subsequence of every equal key.
/// The deliberately tiny key domain makes collisions common across generated
/// arrays instead of leaving stability vacuously true most of the time.
fn prop_sort_stable(keys : Array[Int64]) -> Bool {
  try {
    let df = DataFrame::DataFrame([
      Series::from_ints("key", keys),
      Series::from_ints(
        "row_id",
        Array::makei(keys.length(), i => i.to_int64()),
      ),
    ])
    let ascending = df.sort([(@expr.col("key"), Asc, NullsLast)])
    let descending = df.sort([(@expr.col("key"), Desc, NullsLast)])
    sorted_stably(ascending, true) && sorted_stably(descending, false)
  } catch {
    _ => false
  }
}

///|
test "property: sort preserves equal-key input order" {
  @qc.quick_check(@qc.forall(gen_i64_array(50, 0, 5), prop_sort_stable))
}

///|
/// `group_by` partitions rows with neither loss nor duplication: tag every row
/// with a `1`, and the per-group sums must total exactly the row count.
fn prop_group_by_no_row_loss(keys : Array[Int64]) -> Bool {
  let n = keys.length()
  try {
    let df = DataFrame::DataFrame([
      Series::from_ints("k", keys),
      Series::from_ints("ones", Array::make(n, (1 : Int64))),
    ])
    let summed = df
      .group_by([@expr.col("k")])
      .agg([@expr.col("ones").sum().with_alias("ones_sum")])
      .get_column("ones_sum")
      .sum()
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
