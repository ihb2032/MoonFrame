// Blackbox tests for `@ops.filter` and `@ops.filter_try`.
//
// Invariants asserted on every successful filter:
//   (1) check_invariants() == Ok(()) — formal spec from frame/invariants.mbt
//   (2) result.schema() == df.schema() — filter is row-only, never
//       touches columns
//   (3) result.columns() == df.columns() — column order + names stable
//   (4) result.nrows() equals the number of `true` predicate returns
//   (5) every cell in `result` matches the corresponding cell in `df`
//       at the kept row index

///|
/// Four-row, three-column fixture covering Int / String / nullable
/// Float so predicates can exercise the typed accessors, null
/// inspection, and arithmetic-style filtering against the same data.
fn filter_df() -> @frame.DataFrame {
  @frame.DataFrame::new([
    @frame.Series::from_ints("a", [1, 2, 3, 4]),
    @frame.Series::from_strings("b", ["w", "x", "y", "z"]),
    @frame.Series::from_float_options("c", [
      Some((1.5 : Double)),
      None,
      Some((3.5 : Double)),
      Some((4.5 : Double)),
    ]),
  ]).unwrap()
}

// ── filter — happy paths ─────────────────────────────────────────────

///|
test "filter keeps every row when predicate is constantly true" {
  let df = filter_df()
  let out = filter(df, fn(_view) { true }).unwrap()
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
  let out = filter(df, fn(_view) { false }).unwrap()
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
  let out = filter(df, fn(view) { view.get_int("a").unwrap() > 2 }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(3)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(4)))
  assert_eq(out.get(0, "b"), Ok(@types.Scalar::String("y")))
  assert_eq(out.get(1, "b"), Ok(@types.Scalar::String("z")))
  assert_eq(out.get(0, "c"), Ok(@types.Scalar::Float(3.5)))
  assert_eq(out.get(1, "c"), Ok(@types.Scalar::Float(4.5)))
}

///|
test "filter uses RowView::index to keep even-indexed rows" {
  let df = filter_df()
  let out = filter(df, fn(view) { view.index() % 2 == 0 }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 3))
  // Rows 0 and 2 from the original fixture.
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(1)))
  assert_eq(out.get(1, "a"), Ok(@types.Scalar::Int(3)))
}

///|
test "filter on a 0x0 frame is a structural identity (predicate never runs)" {
  let df = @frame.DataFrame::new([]).unwrap()
  // The predicate would panic if invoked — proves it isn't.
  let out = filter(df, fn(_view) { abort("predicate must not run on 0 rows") }).unwrap()
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
  ]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  let out = filter(df, fn(_view) { abort("predicate must not run on 0 rows") }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 2))
}

///|
test "filter keeps only null-bearing rows when predicate is is_null" {
  let df = filter_df()
  // Row 1 has c = Null.
  let out = filter(df, fn(view) { view.is_null("c").unwrap() }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (1, 3))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(2)))
  assert_eq(out.get(0, "c"), Ok(@types.Scalar::Null))
}

///|
test "filter on a single-row frame keeps or drops that one row" {
  let df = @frame.DataFrame::new([@frame.Series::from_ints("a", [42])]).unwrap()
  let kept = filter(df, fn(_view) { true }).unwrap()
  assert_eq(kept.check_invariants(), Ok(()))
  assert_eq(kept.shape(), (1, 1))
  assert_eq(kept.get(0, "a"), Ok(@types.Scalar::Int(42)))
  let dropped = filter(df, fn(_view) { false }).unwrap()
  assert_eq(dropped.check_invariants(), Ok(()))
  assert_eq(dropped.shape(), (0, 1))
}

// ── filter_try — happy paths ─────────────────────────────────────────

///|
test "filter_try keeps every row when predicate is constantly Ok(true)" {
  let df = filter_df()
  let out = filter_try(df, fn(_view) { Ok(true) }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out, df)
}

///|
test "filter_try drops every row when predicate is constantly Ok(false)" {
  let df = filter_df()
  let out = filter_try(df, fn(_view) { Ok(false) }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), df.schema())
  assert_eq(out.shape(), (0, 3))
}

///|
test "filter_try selects rows via a fallible typed accessor" {
  let df = filter_df()
  // Promote "a" through get_float and keep rows where it's > 2.0.
  // get_float on Int dtype is allowed (promotes via Scalar::as_float).
  let out = filter_try(df, fn(view) {
    match view.get_float("a") {
      Err(e) => Err(e)
      Ok(v) => Ok(v > 2.0)
    }
  }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (2, 3))
  assert_eq(out.get(0, "a"), Ok(@types.Scalar::Int(3)))
}

///|
test "filter_try on a 0x0 frame is a structural identity (predicate never runs)" {
  let df = @frame.DataFrame::new([]).unwrap()
  let out = filter_try(df, fn(_view) {
    abort("predicate must not run on 0 rows")
  }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.shape(), (0, 0))
}

///|
test "filter_try on a 0-row frame preserves the schema and never invokes the predicate" {
  let schema = @types.Schema::new([@types.Field::new("a", @types.DataType::Int)]).unwrap()
  let df = @frame.DataFrame::empty(schema).unwrap()
  let out = filter_try(df, fn(_view) {
    abort("predicate must not run on 0 rows")
  }).unwrap()
  assert_eq(out.check_invariants(), Ok(()))
  assert_eq(out.schema(), schema)
  assert_eq(out.shape(), (0, 1))
}

// ── filter_try — error propagation ───────────────────────────────────

///|
test "filter_try propagates Err from the predicate on the first row" {
  let df = filter_df()
  let out = filter_try(df, fn(_view) {
    Err(@types.DataError::InvalidOperation("boom"))
  })
  assert_eq(out, Err(@types.DataError::InvalidOperation("boom")))
}

///|
test "filter_try short-circuits on the first failing row, discarding earlier matches" {
  let df = filter_df()
  // Accept rows 0 and 1, then fail on row 2. The output must be the
  // error, not a frame containing rows 0 and 1.
  let out = filter_try(df, fn(view) {
    if view.index() < 2 {
      Ok(true)
    } else {
      Err(
        @types.DataError::InvalidOperation(
          "stop at " + view.index().to_string(),
        ),
      )
    }
  })
  assert_eq(out, Err(@types.DataError::InvalidOperation("stop at 2")))
}

///|
test "filter_try surfaces ColumnNotFound from RowView::get_int" {
  let df = filter_df()
  let out = filter_try(df, fn(view) {
    match view.get_int("missing") {
      Err(e) => Err(e)
      Ok(v) => Ok(v > 0)
    }
  })
  assert_eq(out, Err(@types.DataError::ColumnNotFound("missing")))
}

///|
test "filter_try surfaces TypeMismatch when get_int hits the wrong dtype" {
  let df = filter_df()
  // Column "b" is String — get_int should yield TypeMismatch on its
  // very first call (row 0), so the whole filter aborts there.
  // Use a pattern match because the TypeMismatch message text is a
  // shared diagnostic from Scalar::as_int, not pinned in this test.
  let out = filter_try(df, fn(view) {
    match view.get_int("b") {
      Err(e) => Err(e)
      Ok(v) => Ok(v > 0)
    }
  })
  assert_true(out is Err(@types.DataError::TypeMismatch(_)))
}

///|
test "filter_try surfaces TypeMismatch when a typed accessor hits a null cell" {
  let df = filter_df()
  // Row 1 has c = Null; get_float on a null cell returns TypeMismatch
  // (via Scalar::as_float). Rows before row 1 must be accepted then
  // discarded once row 1 fails.
  let out = filter_try(df, fn(view) {
    match view.get_float("c") {
      Err(e) => Err(e)
      Ok(v) => Ok(v > 0.0)
    }
  })
  assert_true(out is Err(@types.DataError::TypeMismatch(_)))
}

// ── Cross-API equivalence ────────────────────────────────────────────

///|
test "filter_try with Ok-only predicate produces the same frame as filter" {
  let df = filter_df()
  let by_filter = filter(df, fn(view) { view.get_int("a").unwrap() % 2 == 1 }).unwrap()
  let by_filter_try = filter_try(df, fn(view) {
    match view.get_int("a") {
      Err(e) => Err(e)
      Ok(v) => Ok(v % 2 == 1)
    }
  }).unwrap()
  assert_eq(by_filter.check_invariants(), Ok(()))
  assert_eq(by_filter, by_filter_try)
}
