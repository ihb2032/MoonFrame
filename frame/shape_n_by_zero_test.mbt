// `N×0` — rows but no columns — is a real shape, not a degenerate `0×0`.
// These tests pin the entry points that mint one and the row transforms that
// carry a height through a column-less frame.

///|
/// An `n`-row, 0-column frame, built the way the public API reaches one: an
/// empty schema over `n` width-0 rows.
fn nby0(n : Int) -> DataFrame raise @types.DataError {
  DataFrame::from_rows(@types.Schema::Schema([]), Array::makei(n, _ => []))
}

///|
fn shape_df() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
  ])
}

// ── Minting an N×0 frame ────────────────────────────────────────────

///|
test "the three projections to zero columns all keep the height" {
  let df = shape_df()
  let by_select = df.select([])
  let by_drop = df.drop([@expr.col("a"), @expr.col("b")])
  let by_rows = nby0(4)
  for out in [by_select, by_drop, by_rows] {
    assert_eq(out.shape(), (4, 0))
    assert_false(out.is_empty())
    assert_eq(out.check_invariants(), Ok(()))
  }
  // Same shape, same schema, no columns to differ in: they are one value.
  assert_eq(by_select, by_drop)
  assert_eq(by_select, by_rows)
}

///|
test "an N×0 frame is not equal to the 0×0 frame" {
  // The distinction the shape model exists to draw: both have no columns,
  // but only one has rows.
  assert_not_eq(nby0(3), DataFrame::DataFrame([]))
  assert_eq(DataFrame::DataFrame([]).shape(), (0, 0))
}

// ── Row access ──────────────────────────────────────────────────────

///|
test "an N×0 frame has N empty rows" {
  let df = nby0(3)
  assert_eq(df.rows(), [[], [], []])
  assert_eq(df.row(0), [])
  assert_eq(df.row(2), [])
  assert_true((Ok(df.row(3)) catch { e => Err(e) }) is Err(IndexOutOfBounds(3)))
}

///|
test "an N×0 frame round-trips through its own schema and rows" {
  // `from_rows(df.schema(), df.rows())` is the identity for every frame —
  // it was not, while a column-less frame's height was clamped away.
  let df = nby0(5)
  assert_eq(DataFrame::from_rows(df.schema(), df.rows()), df)
}

// ── Row transforms carry the height ─────────────────────────────────

///|
test "head / tail / slice / gather / reverse do their arithmetic on an N×0 frame" {
  let df = nby0(5)
  assert_eq(df.head(2).shape(), (2, 0))
  assert_eq(df.tail(3).shape(), (3, 0))
  assert_eq(df.slice(1, 4).shape(), (3, 0))
  assert_eq(df.gather([0, 0, 4]).shape(), (3, 0))
  assert_eq(df.reverse().shape(), (5, 0))
  // Clamping still applies: asking for more rows than there are yields all.
  assert_eq(df.head(99).shape(), (5, 0))
  for out in [df.head(2), df.tail(3), df.slice(1, 4), df.reverse()] {
    assert_eq(out.check_invariants(), Ok(()))
  }
}

///|
test "filter drops rows of an N×0 frame through a column-less predicate" {
  // The eager mirror of a scan-level predicate that reads no column: with no
  // column to read, the literal mask still broadcasts over the real height.
  let df = nby0(4)
  assert_eq(df.filter(@expr.lit_bool(true)).shape(), (4, 0))
  assert_eq(df.filter(@expr.lit_bool(false)).shape(), (0, 0))
}

///|
test "unique collapses an N×0 frame to a single empty row" {
  // Every row of a column-less frame is the same (empty) tuple, so exactly
  // one survives — and none survive when there were none to begin with.
  assert_eq(nby0(4).unique().shape(), (1, 0))
  assert_eq(nby0(0).unique().shape(), (0, 0))
}

///|
test "with_columns re-grows an N×0 frame to its original height" {
  // The round trip that makes `N×0` worth representing: project everything
  // away, then compute a new column over the rows that are still there.
  let df = nby0(3).with_columns([@expr.lit_int(7).with_alias("k")])
  assert_eq(df.shape(), (3, 1))
  assert_eq(df.get_column("k").to_scalars(), [
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
    @types.Scalar::Int(7),
  ])
  assert_eq(df.check_invariants(), Ok(()))
}

///|
test "with_row_index numbers the rows of an N×0 frame" {
  let df = nby0(3).with_row_index(name="i")
  assert_eq(df.shape(), (3, 1))
  assert_eq(df.get_column("i").to_scalars(), [
    @types.Scalar::Int(0),
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
}
