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

// ── Join and aggregation carry the height too ───────────────────────

///|
test "a cross join of two N×0 frames keeps the product height" {
  // The Cartesian product is `left.nrows * right.nrows` rows of nothing:
  // with no column on either side, only the row plan carries the count.
  let out = nby0(2).join(nby0(3), JoinOptions::cross())
  assert_eq(out.shape(), (6, 0))
  assert_eq(out.check_invariants(), Ok(()))
  // A zero-row side still annihilates the product.
  assert_eq(nby0(0).join(nby0(3), JoinOptions::cross()).shape(), (0, 0))
  assert_eq(nby0(2).join(nby0(0), JoinOptions::cross()).shape(), (0, 0))
  // One side with a column pins the same height the plan does — the case
  // where an inferred height happened to agree.
  let mixed = nby0(2).join(
    DataFrame::DataFrame([Series::from_ints("k", [1, 2, 3])]),
    JoinOptions::cross(),
  )
  assert_eq(mixed.shape(), (6, 1))
}

///|
test "a keyed join between N×0 frames keeps its matched rows" {
  // A non-cross join needs a key, and a column-less frame can still supply
  // one: a literal broadcasts over the frame's height, so every left row
  // pairs with every right row — the same product, through the hash path.
  let out = nby0(2).join(nby0(3), JoinOptions::on([@expr.lit_int(1)]))
  assert_eq(out.shape(), (6, 0))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "group_by([]).agg([]) keeps the grand-total group" {
  // Every row lands in the one group, and nothing is projected out of it:
  // one row, no columns.
  let out = shape_df().group_by([]).agg([])
  assert_eq(out.shape(), (1, 0))
  assert_eq(out.check_invariants(), Ok(()))
  // The same over a source that already has no columns — the group exists
  // without a key column to witness it.
  assert_eq(nby0(4).group_by([]).agg([]).shape(), (1, 0))
  // A frame with no rows has no groups at all, so this one really is 0×0.
  assert_eq(nby0(0).group_by([]).agg([]).shape(), (0, 0))
  assert_eq(DataFrame::DataFrame([]).group_by([]).agg([]).shape(), (0, 0))
}

///|
test "agg([]) under real keys stays a distinct over the key tuples" {
  // The neighbouring shape: zero expressions, but the key columns still head
  // the output, so the height was never in doubt there.
  let df = DataFrame::DataFrame([Series::from_ints("g", [1, 1, 2])])
  assert_eq(df.group_by([@expr.col("g")]).agg([]).shape(), (2, 1))
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

///|
test "the table renderers draw nothing for an N×0 frame" {
  // Both renderers are built out of cells, and this frame has none — so the
  // rows it does have cannot appear. Pinned because the output is identical to
  // the empty frame's while the frames are not: `shape` is what tells them
  // apart, and a renderer that started emitting bare rows would be a silent
  // change to a documented, `String`-typed public surface.
  let df = nby0(2)
  assert_eq(df.to_markdown(), "")
  assert_eq(df.to_html(), "")
  assert_eq(df.to_markdown(), DataFrame::DataFrame([]).to_markdown())
  assert_false(df.is_empty())
  assert_eq(df.shape(), (2, 0))
}

///|
/// The one shape where a stray height reaches the frame: with columns, the
/// length check forces `nrows >= 0`, but at zero columns it has nothing to
/// range over — so `from_parts` closes INV7 itself rather than trusting the
/// caller, and a legitimate `N×0` still builds.
test "from_parts refuses a negative height, and keeps building N×0" {
  assert_eq(
    Ok(@frame.DataFrame::from_parts([], -1)) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::InvalidOperation(
        "a frame's row count cannot be negative: -1",
      ),
    ),
  )
  // The check is the same for a frame with columns, which the length check
  // would otherwise reject as a mismatch.
  assert_true(
    (Ok(@frame.DataFrame::from_parts([@series.Series::from_ints("a", [1])], -1)) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  assert_eq(@frame.DataFrame::from_parts([], 4).shape(), (4, 0))
  assert_eq(@frame.DataFrame::from_parts([], 0).shape(), (0, 0))
}
