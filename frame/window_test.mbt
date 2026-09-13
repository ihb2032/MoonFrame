// Blackbox tests for the row-window verbs — `head` / `tail` / `slice` /
// `gather` — split from `dataframe_test.mbt` alongside the verbs' move to
// `window.mbt`. The verbs keep a frame's schema verbatim and move or trim
// rows; that name lookup keeps working after a transform is pinned back in
// `dataframe_test.mbt`, whose "name lookup survives transforms" section is
// about the schema index rather than about this family.

// ── head / tail ──────────────────────────────────────────────────────

///|
test "head returns the first n rows with the same schema" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let two = df.head(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.item(0, "a"), @types.Scalar::Int(1))
  assert_eq(two.item(1, "b"), @types.Scalar::String("x"))
  // Schema is preserved verbatim.
  assert_eq(two.schema(), df.schema())
}

///|
test "head clamps n > nrows to nrows" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  let all = df.head(99)
  assert_eq(all.shape(), (3, 1))
}

///|
test "head clamps n < 0 to 0" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  let empty = df.head(-5)
  assert_eq(empty.shape(), (0, 1))
  assert_true(empty.is_empty())
}

///|
test "tail returns the last n rows with the same schema" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let two = df.tail(2)
  assert_eq(two.shape(), (2, 2))
  assert_eq(two.item(0, "a"), @types.Scalar::Int(3))
  assert_eq(two.item(1, "b"), @types.Scalar::String("z"))
}

///|
test "tail clamps n > nrows and n < 0" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  let all = df.tail(99)
  assert_eq(all.shape(), (3, 1))
  let empty = df.tail(-1)
  assert_true(empty.is_empty())
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice mid-range produces a sub-frame preserving names + nulls" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(10), None, Some(30), Some(40)]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let part = df.slice(1, 3)
  assert_eq(part.shape(), (2, 2))
  assert_eq(part.item(0, "a"), @types.Scalar::Null)
  assert_eq(part.item(1, "a"), @types.Scalar::Int(30))
  assert_eq(part.item(0, "b"), @types.Scalar::String("x"))
}

///|
test "slice [start, start) returns an empty frame" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3])])
  let zero = df.slice(2, 2)
  assert_eq(zero.shape(), (0, 1))
}

///|
test "slice reports invalid bounds with the appropriate error" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3])])
  assert_eq(
    Ok(df.slice(-1, 2)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(df.slice(0, 5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_true(
    (Ok(df.slice(2, 1)) catch { e => Err(e) }) is Err(InvalidOperation(_)),
  )
  // A negative `end` is an out-of-range index, not a misordered pair: every
  // valid `start` is greater than it, so testing `end` for `> nrows` alone
  // would have reported the ordering error and hidden the real offender.
  assert_eq(
    Ok(df.slice(0, -1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  // `start` is still reported first when both are out of range.
  assert_eq(
    Ok(df.slice(-2, -1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-2)),
  )
}

// ── gather ─────────────────────────────────────────────────────────────

///|
test "gather collects rows in arbitrary order across every column" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [10, 20, 30]),
    Series::from_strings("b", ["x", "y", "z"]),
  ])
  let out = df.gather([2, 0, 0])
  assert_eq(out.shape(), (3, 2))
  assert_eq(out.item(0, "a"), @types.Scalar::Int(30))
  assert_eq(out.item(0, "b"), @types.Scalar::String("z"))
  assert_eq(out.item(2, "a"), @types.Scalar::Int(10))
}

///|
test "gather with empty indices produces an empty frame of the same schema" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2])])
  let out = df.gather([])
  assert_true(out.is_empty())
  assert_eq(out.schema(), df.schema())
}

///|
test "gather rejects out-of-bounds indices with the first offender" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2])])
  assert_eq(
    Ok(df.gather([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(df.gather([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}
