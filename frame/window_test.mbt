// Blackbox tests for the row-window verbs — `head` / `tail` / `slice` /
// `gather` — one family to a file, matching the verbs' own home. The verbs
// keep a frame's schema verbatim and move or trim rows; that name lookup
// keeps working after a transform is pinned in the type-core suite, whose
// "name lookup survives transforms" section is about the schema index
// rather than about this family.

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
test "head with a negative n keeps every row but the last |n|, as Polars" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  // head(-1) drops the final row.
  let but_last = df.head(-1)
  assert_eq(but_last.shape(), (2, 1))
  assert_eq(but_last.item(1, "a"), @types.Scalar::Int(2))
  // |n| reaching past the frame leaves nothing.
  assert_eq(df.head(-5).shape(), (0, 1))
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
test "tail clamps n > nrows; a negative n keeps every row but the first |n|" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2, 3])])
  let all = df.tail(99)
  assert_eq(all.shape(), (3, 1))
  // tail(-1) drops the leading row.
  let but_first = df.tail(-1)
  assert_eq(but_first.shape(), (2, 1))
  assert_eq(but_first.item(0, "a"), @types.Scalar::Int(2))
  assert_eq(df.tail(-5).shape(), (0, 1))
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice mid-range produces a sub-frame preserving names + nulls" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(10), None, Some(30), Some(40)]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
  let part = df.slice(1, length=2)
  assert_eq(part.shape(), (2, 2))
  assert_eq(part.item(0, "a"), @types.Scalar::Null)
  assert_eq(part.item(1, "a"), @types.Scalar::Int(30))
  assert_eq(part.item(0, "b"), @types.Scalar::String("x"))
}

///|
test "slice [start, start) returns an empty frame" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3])])
  let zero = df.slice(2, length=0)
  assert_eq(zero.shape(), (0, 1))
}

///|
test "slice saturates like Polars: negative offset from the end, omitted length to the end" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3, 4, 5])])
  // Omitted length runs to the end.
  assert_eq(df.slice(2).shape(), (3, 1))
  assert_eq(df.slice(2).item(0, "x"), @types.Scalar::Int(3))
  assert_eq(df.slice(2).item(2, "x"), @types.Scalar::Int(5))
  // A negative offset counts from the end; -1 names the last row.
  assert_eq(df.slice(-1).shape(), (1, 1))
  assert_eq(df.slice(-1).item(0, "x"), @types.Scalar::Int(5))
  assert_eq(df.slice(-2).item(0, "x"), @types.Scalar::Int(4))
  // An offset reaching past either end saturates there.
  assert_eq(df.slice(-99).shape(), (5, 1))
  assert_eq(df.slice(99).shape(), (0, 1))
}

///|
test "slice saturates the length: past the end keeps what remains, negative is empty" {
  let df = DataFrame::DataFrame([Series::from_ints("x", [1, 2, 3, 4, 5])])
  assert_eq(df.slice(1, length=99).shape(), (4, 1))
  assert_eq(df.slice(1, length=99).item(0, "x"), @types.Scalar::Int(2))
  assert_eq(df.slice(-3, length=2).item(0, "x"), @types.Scalar::Int(3))
  assert_eq(df.slice(-3, length=2).item(1, "x"), @types.Scalar::Int(4))
  assert_eq(df.slice(2, length=-5).shape(), (0, 1))
  // `tail(n)` is `slice(-n)` against the known height — same window either way.
  assert_eq(df.slice(-2).item(0, "x"), df.tail(2).item(0, "x"))
  assert_eq(df.slice(-2).shape(), df.tail(2).shape())
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

// ── bracket access ──────────────────────────────────────────────────

///|
test "df[name] reads a column; df[a:b] is the bracket-slice sugar" {
  let df = DataFrame::DataFrame([
    Series::from_ints("x", [1, 2, 3, 4, 5]),
    Series::from_strings("tag", ["a", "b", "c", "d", "e"]),
  ])
  // The column bracket is get_column.
  assert_eq(df["x"].dtype(), @types.DataType::Int)
  assert_true(
    (Ok(df["missing"]) catch { e => Err(e) })
    is Err(@types.DataError::ColumnNotFound("missing")),
  )
  // The slice bracket is slice_between: half-open, omitted to the end,
  // negative from the end, crossed bounds empty.
  assert_eq(df[1:3].shape(), (2, 2))
  assert_eq(df[1:3].item(0, "x"), @types.Scalar::Int(2))
  assert_eq(df[2:].shape(), (3, 2))
  assert_eq(df[:2].shape(), (2, 2))
  assert_eq(df[:].shape(), (5, 2))
  assert_eq(df[:-1].shape(), (4, 2))
  assert_eq(df[-2:].item(0, "tag"), @types.Scalar::String("d"))
  assert_eq(df[3:1].shape(), (0, 2))
  // Same kernel, so the two spellings agree on a shared window.
  assert_eq(df[1:3], df.slice(1, length=2))
}
