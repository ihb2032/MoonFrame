// Blackbox tests for `DataFrame::filter`.
//
// `filter` takes a single `(RowView) -> Bool raise DataError` predicate
// (the v0.1 `filter` / `filter_try` split is gone): a total predicate
// simply never raises, a fallible one may. Invariants asserted on every
// successful filter:
//   (1) check_invariants() == Ok(()) — formal spec from invariants.mbt
//   (2) result.schema() == df.schema() — filter is row-only
//   (3) result.columns() == df.columns() — column order + names stable
//   (4) result.nrows() equals the number of `true` predicate returns
//   (5) a raising predicate short-circuits the scan and propagates

///|
/// Four-row, three-column fixture covering Int / String / nullable
/// Float so predicates can exercise the typed accessors, null
/// inspection, and arithmetic-style filtering against the same data.
fn filter_df() -> DataFrame raise @types.DataError {
  DataFrame::new([
    Series::from_ints("a", [1, 2, 3, 4]),
    Series::from_strings("b", ["w", "x", "y", "z"]),
    Series::from_float_options("c", [
      Some((1.5 : Double)),
      None,
      Some((3.5 : Double)),
      Some((4.5 : Double)),
    ]),
  ])
}

// ── Total predicates — happy paths ───────────────────────────────────

///|
test "filter keeps every row when predicate is constantly true" {
  let df = filter_df()
  let out = df.filter(_view => true)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  // Row count and cell values are preserved verbatim.
  assert_eq(out.shape(), df.shape())
  assert_eq(out, df)
}

///|
test "filter drops every row when predicate is constantly false, schema kept" {
  let df = filter_df()
  let out = df.filter(_view => false)
  assert_eq(out.check_invariants(), Ok(()))
  // The distinguishing property of filter vs select([]): columns
  // survive, only rows go to zero.
  assert_eq(out.schema(), df.schema())
  assert_eq(out.columns(), df.columns())
  assert_eq(out.shape(), (0, 3))
  assert_eq(out.nrows(), 0)
  assert_eq(out.ncols(), df.ncols())
}

///|
test "filter selects rows by the predicate's truth pattern" {
  let df = filter_df()
  // Keep rows where column "a" > 2 (i.e. rows 2 and 3 → values 3, 4).
  // `get_int` now raises on a bad access, so the predicate is fallible —
  // a single `filter` signature accepts it.
  let out = df.filter(view => view.get_int("a") > 2)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.get(0, "a"), @types.Scalar::Int(3))
  assert_eq(out.get(1, "a"), @types.Scalar::Int(4))
  assert_eq(out.get(0, "b"), @types.Scalar::String("y"))
  assert_eq(out.get(1, "b"), @types.Scalar::String("z"))
  assert_eq(out.get(0, "c"), @types.Scalar::Float(3.5))
  assert_eq(out.get(1, "c"), @types.Scalar::Float(4.5))
}

///|
test "filter uses RowView::index to keep even-indexed rows" {
  let df = filter_df()
  let out = df.filter(view => view.index() % 2 == 0)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 3))
  // Rows 0 and 2 from the original fixture.
  assert_eq(out.get(0, "a"), @types.Scalar::Int(1))
  assert_eq(out.get(1, "a"), @types.Scalar::Int(3))
}

///|
test "filter selects rows via a promoting typed accessor" {
  let df = filter_df()
  // Promote "a" through get_float and keep rows where it's > 2.0.
  // get_float on Int dtype is allowed (promotes via Scalar::as_float).
  let out = df.filter(view => view.get_float("a") > 2.0)
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.get(0, "a"), @types.Scalar::Int(3))
}

///|
test "filter keeps only null-bearing rows when predicate is is_null" {
  let df = filter_df()
  // Row 1 has c = Null.
  let out = df.filter(view => view.is_null("c"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (1, 3))
  assert_eq(out.get(0, "a"), @types.Scalar::Int(2))
  assert_eq(out.get(0, "c"), @types.Scalar::Null)
}

// ── Zero-row frames — predicate never runs ───────────────────────────

///|
test "filter on a 0x0 frame is a structural identity (predicate never runs)" {
  let df = DataFrame::new([])
  // The predicate would abort if invoked — proves it isn't.
  let out = df.filter(_view => abort("predicate must not run on 0 rows"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "filter on a 0-row, N-column frame preserves the schema" {
  // Build a 0-row frame via DataFrame::empty so the schema has fields
  // but nrows == 0. The predicate must not run.
  let schema = @types.Schema::new([
    @types.Field::new("a", @types.DataType::Int),
    @types.Field::new("b", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let out = df.filter(_view => abort("predicate must not run on 0 rows"))
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

///|
test "filter on a single-row frame keeps or drops that one row" {
  let df = DataFrame::new([Series::from_ints("a", [42])])
  let kept = df.filter(_view => true)
  assert_eq(kept.check_invariants(), Ok(()))
  assert_eq(kept.shape(), (1, 1))
  assert_eq(kept.get(0, "a"), @types.Scalar::Int(42))
  let dropped = df.filter(_view => false)
  assert_eq(dropped.check_invariants(), Ok(()))
  assert_eq(dropped.shape(), (0, 1))
}

// ── Fallible predicates — error propagation ──────────────────────────

///|
test "filter propagates a raise from the predicate on the first row" {
  let df = filter_df()
  let out = try? df.filter(_view => {
    raise @types.DataError::InvalidOperation("boom")
  })
  assert_eq(out, Err(@types.DataError::InvalidOperation("boom")))
}

///|
test "filter short-circuits on the first failing row, discarding earlier matches" {
  let df = filter_df()
  // Accept rows 0 and 1, then fail on row 2. The output must be the
  // error, not a frame containing rows 0 and 1.
  let out = try? df.filter(view => {
    if view.index() < 2 {
      true
    } else {
      raise @types.DataError::InvalidOperation(
        "stop at " + view.index().to_string(),
      )
    }
  })
  assert_eq(out, Err(@types.DataError::InvalidOperation("stop at 2")))
}

///|
test "filter surfaces ColumnNotFound from RowView::get_int" {
  let df = filter_df()
  let out = try? df.filter(view => view.get_int("missing") > 0)
  assert_eq(out, Err(@types.DataError::ColumnNotFound("missing")))
}

///|
test "filter surfaces TypeMismatch when get_int hits the wrong dtype" {
  let df = filter_df()
  // Column "b" is String — get_int yields TypeMismatch on row 0, so the
  // whole filter aborts there. Pattern-match because the message text is
  // a shared diagnostic from Scalar::as_int, not pinned in this test.
  let out = try? df.filter(view => view.get_int("b") > 0)
  assert_true(out is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "filter surfaces TypeMismatch when a typed accessor hits a null cell" {
  let df = filter_df()
  // Row 1 has c = Null; get_float on a null cell raises TypeMismatch
  // (via Scalar::as_float). Rows before row 1 are accepted then
  // discarded once row 1 fails.
  let out = try? df.filter(view => view.get_float("c") > 0.0)
  assert_true(out is Err(@types.DataError::TypeMismatch(_)))
}
