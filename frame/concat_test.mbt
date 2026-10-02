// Blackbox tests for `DataFrame::vstack` — vertical concatenation. Pinned:
// the row concatenation with `self`'s names and order, exact per-position
// dtype checking, the 0-row edges, and that the assembled columns satisfy
// the frame invariants (including the gather-style backend
// canonicalisation).

///|
test "vstack appends the rows under self's names, keeping the schema" {
  let top = DataFrame::DataFrame([
    Series::from_ints("a", [1, 2]),
    Series::from_strings("b", ["x", "y"]),
  ])
  // The bottom frame's names differ — position matches, names do not
  // travel (Polars' rule).
  let bottom = DataFrame::DataFrame([
    Series::from_ints("z", [3]),
    Series::from_strings("w", ["xy"]),
  ])
  let r = top.vstack(bottom)
  assert_eq(r.shape(), (3, 2))
  assert_eq(r.columns(), ["a", "b"])
  assert_eq(r.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  assert_eq(r.get_column("b").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("y"),
    @types.Scalar::String("xy"),
  ])
  assert_eq(r.check_invariants(), Ok(()))
}

///|
test "vstack carries nulls from either side, keeping the dtype" {
  let top = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(1), None]),
  ])
  let bottom = DataFrame::DataFrame([Series::from_ints("b", [3])])
  let r = top.vstack(bottom)
  assert_eq(r.get_column("a").dtype(), @types.DataType::Int)
  assert_eq(r.get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Null,
    @types.Scalar::Int(3),
  ])
}

///|
test "a 0-row side is the schema-preserving no-op either way" {
  let empty = DataFrame::DataFrame([Series::from_ints("a", [])])
  let two = DataFrame::DataFrame([Series::from_ints("a", [1, 2])])
  assert_eq(empty.vstack(two).get_column("a").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(two.vstack(empty).shape(), (2, 1))
  // 0-column frames stack their heights: nothing in the rows, more of them.
  assert_eq(DataFrame::DataFrame([]).vstack(nby0(2)).shape(), (2, 0))
}

///|
test "mismatched column counts and dtypes raise TypeMismatch" {
  let one = DataFrame::DataFrame([Series::from_ints("a", [1])])
  let two_cols = DataFrame::DataFrame([
    Series::from_ints("a", [1]),
    Series::from_ints("b", [2]),
  ])
  assert_true(
    (Ok(one.vstack(two_cols)) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  // An Int column under a Float one: exact checking, no promotion.
  let f = DataFrame::DataFrame([Series::from_floats("a", [1.0])])
  assert_true(
    (Ok(one.vstack(f)) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
}
