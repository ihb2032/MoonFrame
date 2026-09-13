// Blackbox tests for the storage-backend machine (`backend.mbt`): a
// column's backend is a function of its content, asserted through the
// `storage_kind` / `is_canonical` seams. The differential harness in
// `backend_parity_test.mbt` guards the same machine at the cell level.

// ── storage backend: storage_kind / is_canonical / try_column_to_numeric ──

///|
test "row gathers canonicalise an all-valid result; slices preserve the backend" {
  // A no-null numeric column is Numeric; slicing / gathering / dropping
  // nulls keeps it on the fast path (a row subset is still all-valid).
  let s = Series::from_ints("x", [10, 20, 30, 40])
  assert_eq(s.storage_kind(), @column.StorageKind::Numeric)
  assert_eq(s.slice(1, 3).storage_kind(), @column.StorageKind::Numeric)
  assert_eq(s.gather([3, 0, 0]).storage_kind(), @column.StorageKind::Numeric)
  assert_eq(s.drop_nulls().storage_kind(), @column.StorageKind::Numeric)
  // A Builtin column whose nulls a *gather* drops canonicalises onto the
  // Numeric fast path: the backend is a function of the gathered content, so a
  // `gather` / `drop_nulls` / `filter` cannot leave an all-valid numeric column
  // off the fast path — the invariant the query optimizer relies on for
  // `collect ≡ eager`.
  let b = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(b.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(b.gather([0, 2]).storage_kind(), @column.StorageKind::Numeric)
  assert_eq(b.drop_nulls().storage_kind(), @column.StorageKind::Numeric)
  // A `slice` copies its row data but views the parent's validity rather than
  // rebuilding it, so it keeps the source backend: a window still carrying a
  // null stays Builtin.
  assert_eq(b.slice(0, 2).storage_kind(), @column.StorageKind::Builtin)
}

///|
test "Series equality is content-based, independent of the storage backend" {
  // The backends differ by construction (from_ints -> Numeric, all-Some
  // from_int_options -> Builtin), but the columns are logically identical, so
  // they compare equal — equality is by content, not representation.
  assert_eq(
    Series::from_ints("x", [1, 2, 3]),
    Series::from_int_options("x", [Some(1), Some(2), Some(3)]),
  )
  // Backend-preserving ops (slice / fill_null) vs canonicalising ops (gather /
  // from_ints) land on different backends yet compare equal on equal content.
  let b = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(b.gather([0]), b.slice(0, 1)) // both logically "x" = [1]
  assert_eq(
    b.fill_null(@types.Scalar::Int(2)),
    Series::from_ints("x", [1, 2, 3]),
  )
}

///|
test "Series::slice(0, k) null_count counts only the window (zero-copy view)" {
  // `Series::slice` shares the validity buffer (zero-copy), so a slice that
  // starts at row 0 is an offset-0 view over the parent's buffer. null_count
  // / count must see only the kept window, not the parent's rows past `k`.
  let allv = Series::from_bools("b", [true, true, true]).slice(0, 2)
  assert_eq(allv.null_count(), 0)
  assert_eq(allv.count(), 2)
  // A null inside the window stays counted; the valid row just past it must
  // not mask it.
  let withnull = Series::from_int_options("i", [Some(1), None, Some(3)]).slice(
    0, 2,
  )
  assert_eq(withnull.null_count(), 1)
  assert_eq(withnull.count(), 1)
}

///|
test "the two backends of one column are interchangeable, both ways round" {
  // The nullable constructor reaches `Builtin`, `try_column_to_numeric` moves
  // back to the fast path, and neither step touches a cell — which is what
  // lets the parity harness build its pair out of public API alone.
  let n = Series::from_ints("x", [1, 2, 3])
  assert_eq(n.storage_kind(), @column.StorageKind::Numeric)
  let b = Series::from_int_options("x", [Some(1), Some(2), Some(3)])
  assert_eq(b.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(b.to_scalars(), n.to_scalars())
  assert_eq(try_column_to_numeric(b), n)
  // A column carrying a null has no fast-path form: it stays as it is.
  let nullable = Series::from_int_options("x", [Some(1), None])
  assert_eq(try_column_to_numeric(nullable), nullable)
}

///|
test "is_canonical is exactly try_column_to_numeric's backend fixed point" {
  // Every arm of the predicate, pinned to the canonicaliser it mirrors:
  // is_canonical(s) is true exactly when try_column_to_numeric leaves the
  // backend unchanged (a canonical column is a no-op; a non-canonical one is
  // moved off its backend). Asserting both together stops the two drifting.
  fn check(s : Series, want : Bool) -> Unit raise {
    assert_eq(s.is_canonical(), want)
    assert_eq(s.storage_kind() == try_column_to_numeric(s).storage_kind(), want)
  }

  // Numeric backend: always canonical.
  check(Series::from_ints("x", [1, 2, 3]), true)
  check(Series::from_floats("x", [1.5, 2.5]), true)
  // Builtin, all-valid, numeric: NOT canonical — it can move onto Numeric.
  check(Series::from_int_options("x", [Some(1), Some(2)]), false)
  check(Series::from_float_options("x", [Some(1.5)]), false)
  // Builtin carrying a null: canonical — no bitmap-free backend to move to.
  check(Series::from_int_options("x", [Some(1), None]), true)
  check(Series::from_float_options("x", [None]), true)
  // Builtin Bool / String: canonical — the fast path is numeric-only.
  check(Series::from_bools("x", [true, false]), true)
  check(Series::from_bool_options("x", [Some(true), None]), true)
  check(Series::from_strings("x", ["a", "b"]), true)
  check(Series::from_string_options("x", [None, Some("z")]), true)
}

///|
test "gather_series: a stray out-of-range index is a null cell on both backends" {
  // The Numeric fast path reads the raw data array unguarded, so it is
  // gated by an all-in-bounds scan: the same misuse that used to abort the
  // process now falls to the guarded arm and yields a null — identical to
  // the Builtin backend's verdict, so behavior no longer depends on which
  // backend the engine happened to choose.
  let numeric = Series::from_ints("x", [1, 2, 3])
  assert_eq(numeric.storage_kind(), @column.StorageKind::Numeric)
  let g_num = gather_series(numeric, [2, 3, -1, 0])
  assert_eq(g_num.to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Null,
    @types.Scalar::Null,
    @types.Scalar::Int(1),
  ])
  let builtin = Series::from_int_options("x", [Some(1), Some(2), Some(3)])
  assert_eq(builtin.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(gather_series(builtin, [2, 3, -1, 0]), g_num)
  // An all-in-bounds gather still takes the allocation-free Numeric path.
  assert_eq(
    gather_series(numeric, [0, 2]).storage_kind(),
    @column.StorageKind::Numeric,
  )
  // Float arm of the same gate.
  let floats = Series::from_floats("x", [1.5, 2.5])
  assert_eq(gather_series(floats, [1, 9]).to_scalars(), [
    @types.Scalar::Float(2.5),
    @types.Scalar::Null,
  ])
}

///|
test "content-determined transforms return a canonical column for every source backend" {
  // A gather picks the backend from its *result's* content, so the output is
  // canonical whatever the source backend was — including a non-canonical
  // Builtin all-valid numeric source. One assertion per public
  // content-determined entry, so a newly added one gets a line here.
  let sources = [
    Series::from_ints("x", [1, 2, 3, 4]),
    Series::from_int_options("x", [Some(1), Some(2), Some(3), Some(4)]),
    Series::from_int_options("x", [Some(1), None, Some(3), None]),
    Series::from_floats("x", [1.5, 2.5, 3.5, 4.5]),
    Series::from_bools("x", [true, false, true, false]),
    Series::from_strings("x", ["a", "b", "c", "d"]),
  ]
  for src in sources {
    assert_true(src.gather([0, 2, 1]).is_canonical())
    assert_true(gather_series(src, [3, 1, 0]).is_canonical())
    assert_true(
      gather_series_opt(src, [Some(0), None, Some(2)], "x").is_canonical(),
    )
    assert_true(gather_series_opt(src, [Some(3), Some(1)], "x").is_canonical())
    assert_true(try_column_to_numeric(src).is_canonical())
  }
  // drop_nulls canonicalises only when it actually drops a null; on a null-free
  // source it is a backend-preserving no-op — the boundary of the invariant. A
  // source that starts with nulls ends all-valid and converges onto Numeric.
  assert_true(
    Series::from_int_options("x", [Some(1), None, Some(3)])
    .drop_nulls()
    .is_canonical(),
  )
  assert_true(
    Series::from_float_options("x", [None, Some(2.5)])
    .drop_nulls()
    .is_canonical(),
  )
  // The no-op boundary: drop_nulls leaves a null-free non-canonical source
  // (Builtin all-valid Int) unchanged, hence still non-canonical.
  let noop = Series::from_int_options("x", [Some(1), Some(2)])
  assert_eq(noop.drop_nulls().is_canonical(), false)
}
