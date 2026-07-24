// Blackbox tests for `DataFrame::reverse` / `with_row_index`.

///|
fn order_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("n", [1, 2, 3]),
    Series::from_strings("s", ["a", "b", "c"]),
  ])
}

///|
test "reverse flips the row order and leaves the schema alone" {
  let df = order_df()
  let out = df.reverse()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.item(0, "n"), @types.Scalar::Int(3))
  assert_eq(out.item(2, "n"), @types.Scalar::Int(1))
  assert_eq(out.item(0, "s"), @types.Scalar::String("c"))
  // Reversing twice is the identity.
  assert_eq(out.reverse(), df)
  // Degenerate shapes are returned unchanged rather than re-gathered.
  let single = DataFrame::DataFrame([Series::from_ints("n", [7])])
  assert_eq(single.reverse(), single)
  let empty = DataFrame::DataFrame([Series::from_ints("n", [])])
  assert_eq(empty.reverse(), empty)
}

///|
test "with_row_index prepends a dense counter" {
  let df = order_df()
  let out = df.with_row_index()
  assert_eq(out.check_invariants(), Ok(()))
  // The counter lands first, ahead of the frame's own columns.
  assert_eq(out.columns(), ["index", "n", "s"])
  assert_eq(out.get_column("index").dtype(), @types.DataType::Int)
  assert_eq(out.item(0, "index"), @types.Scalar::Int(0))
  assert_eq(out.item(2, "index"), @types.Scalar::Int(2))
  // Custom name and offset.
  let renamed = df.with_row_index(name="row", offset=10)
  assert_eq(renamed.columns(), ["row", "n", "s"])
  assert_eq(renamed.item(0, "row"), @types.Scalar::Int(10))
  assert_eq(renamed.item(2, "row"), @types.Scalar::Int(12))
  // A 0-row frame gets an empty counter, not a missing column.
  let empty = DataFrame::DataFrame([Series::from_ints("n", [])])
  assert_eq(empty.with_row_index().columns(), ["index", "n"])
  assert_eq(empty.with_row_index().nrows(), 0)
}

///|
test "with_row_index rejects a name the frame already carries" {
  let df = order_df()
  assert_true(
    (Ok(df.with_row_index(name="n")) catch { e => Err(e) })
    is Err(@types.DataError::DuplicateColumn("n")),
  )
}

///|
test "with_row_index rejects an offset the counter would overflow" {
  // The 3-row counter needs `offset ..= offset + 2`. One short of the top,
  // MoonBit's wrapping `+` would hand back MAX-1, MAX, MIN — a column that
  // runs backwards at the last row instead of counting.
  let df = order_df()
  let max = 9223372036854775807L
  assert_true(
    (Ok(df.with_row_index(offset=max - 1)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // The last offset that still fits is accepted, and reaches exactly the top.
  let fits = df.with_row_index(offset=max - 2)
  assert_eq(fits.item(2, "index"), @types.Scalar::Int(max))
  // A 0-row frame has no counter to overflow, so any offset is fine.
  let empty = DataFrame::DataFrame([Series::from_ints("n", [])])
  assert_eq(empty.with_row_index(offset=max).nrows(), 0)
  // The bound is one-sided: counting only ever goes up, so the far negative
  // end is reachable.
  let low = df.with_row_index(offset=-9223372036854775808L)
  assert_eq(low.item(0, "index"), @types.Scalar::Int(-9223372036854775808L))
}
