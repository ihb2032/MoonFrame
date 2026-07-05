// Blackbox tests for `Series` (structural surface). Statistics live in
// `series_stats_test.mbt`.

// ── Constructors ─────────────────────────────────────────────────────

///|
test "new / from_builtin wrap an existing column" {
  let col = @column.BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  // `new` takes a `ColumnStorage` (v0.3); `from_builtin` wraps a
  // `BuiltinColumn` into one — the two end up equal.
  let a = Series::new("age", @column.ColumnStorage::from_builtin(col))
  let b = Series::from_builtin("age", col)
  assert_eq(a.name(), "age")
  assert_eq(a.dtype(), @types.DataType::Int)
  assert_eq(a.len(), 3)
  assert_eq(a.null_count(), 1)
  assert_eq(a.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(a, b)
}

///|
test "from_ints / from_int_options" {
  let raw = Series::from_ints("x", [1, 2, 3])
  assert_eq(raw.dtype(), @types.DataType::Int)
  assert_eq(raw.len(), 3)
  assert_eq(raw.null_count(), 0)
  // No-null raw constructor lands on the Numeric fast path...
  assert_eq(raw.storage_kind(), @column.StorageKind::Numeric)
  let opt = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(opt.null_count(), 1)
  assert_eq(opt.get(1), @types.Scalar::Null)
  // ...the nullable option constructor stays Builtin.
  assert_eq(opt.storage_kind(), @column.StorageKind::Builtin)
}

///|
test "from_floats / from_float_options" {
  let raw = Series::from_floats("x", [1.5, 2.5])
  assert_eq(raw.dtype(), @types.DataType::Float)
  assert_eq(raw.null_count(), 0)
  let opt = Series::from_float_options("x", [None, Some(1.0)])
  assert_eq(opt.null_count(), 1)
}

///|
test "from_bools / from_bool_options" {
  let raw = Series::from_bools("flag", [true, false, true])
  assert_eq(raw.dtype(), @types.DataType::Bool)
  let opt = Series::from_bool_options("flag", [Some(true), None, None])
  assert_eq(opt.null_count(), 2)
}

///|
test "from_strings / from_string_options" {
  let raw = Series::from_strings("name", ["a", "b"])
  assert_eq(raw.dtype(), @types.DataType::String)
  let opt = Series::from_string_options("name", [Some("x"), None])
  assert_eq(opt.len(), 2)
  assert_eq(opt.null_count(), 1)
}

///|
// Defensive copy at the Series boundary: a Series is independent of the
// caller's array, on both backends (Numeric for raw ints, Builtin for strings).
test "raw Series constructors copy their input" {
  let ints : Array[Int64] = [1, 2, 3]
  let si = Series::from_ints("x", ints)
  ints[0] = 99
  assert_eq(si.get(0), @types.Scalar::Int(1))
  let strs = ["a", "b"]
  let ss = Series::from_strings("s", strs)
  strs[0] = "z"
  assert_eq(ss.get(0), @types.Scalar::String("a"))
}

///|
test "structural equality compares name + storage" {
  assert_eq(Series::from_ints("a", [1, 2]), Series::from_ints("a", [1, 2]))
  // Same content, different name → not equal.
  assert_not_eq(Series::from_ints("a", [1, 2]), Series::from_ints("b", [1, 2]))
  // Same name, different content → not equal.
  assert_not_eq(Series::from_ints("a", [1, 2]), Series::from_ints("a", [1, 3]))
}

// ── Inspection ───────────────────────────────────────────────────────

///|
test "is_empty true on zero-length, false otherwise" {
  let empty = Series::from_ints("x", [])
  assert_true(empty.is_empty())
  assert_eq(empty.len(), 0)
  let one = Series::from_ints("x", [0])
  assert_false(one.is_empty())
}

///|
test "is_null returns the validity for in-bounds, IndexOutOfBounds otherwise" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(s.is_null(0), false)
  assert_eq(s.is_null(1), true)
  assert_eq(
    Ok(s.is_null(-1)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(s.is_null(3)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(3)),
  )
}

///|
test "get returns Scalar / Null / IndexOutOfBounds" {
  let s = Series::from_int_options("x", [Some(7), None])
  assert_eq(s.get(0), @types.Scalar::Int(7))
  assert_eq(s.get(1), @types.Scalar::Null)
  assert_eq(
    Ok(s.get(5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
}

///|
test "storage exposes the underlying column unchanged" {
  let col = @column.BuiltinColumn::from_strings(["x", "y"])
  let s = Series::from_builtin("c", col)
  // `storage()` returns a `ColumnStorage` (v0.3) — the Builtin column wrapped.
  assert_eq(s.storage(), @column.ColumnStorage::from_builtin(col))
}

// ── rename ───────────────────────────────────────────────────────────

///|
test "rename returns a new series with the new name, sharing storage" {
  let s = Series::from_ints("a", [1, 2])
  let r = s.rename("b")
  assert_eq(r.name(), "b")
  // Original unaffected.
  assert_eq(s.name(), "a")
  assert_eq(r.storage(), s.storage())
}

// ── slice ────────────────────────────────────────────────────────────

///|
test "slice mid-range produces a sub-series preserving name + nulls" {
  let s = Series::from_int_options("x", [Some(10), None, Some(30), Some(40)])
  let part = s.slice(1, 3)
  assert_eq(part.name(), "x")
  assert_eq(part.len(), 2)
  assert_eq(part.get(0), @types.Scalar::Null)
  assert_eq(part.get(1), @types.Scalar::Int(30))
}

///|
test "slice bubbles column-level errors" {
  let s = Series::from_ints("x", [1, 2, 3])
  assert_eq(
    Ok(s.slice(-1, 2)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
  assert_eq(
    Ok(s.slice(0, 5)) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_true(
    (Ok(s.slice(2, 1)) catch { e => Err(e) }) is Err(InvalidOperation(_)),
  )
}

// ── gather ───────────────────────────────────────────────────────────

///|
test "gather collects with duplicates and preserves nulls" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  let out = s.gather([2, 1, 0, 1])
  assert_eq(out.name(), "x")
  assert_eq(out.len(), 4)
  assert_eq(out.get(0), @types.Scalar::Int(3))
  assert_eq(out.get(1), @types.Scalar::Null)
  assert_eq(out.get(3), @types.Scalar::Null)
}

///|
test "gather with empty index array returns empty series" {
  let s = Series::from_ints("x", [1, 2])
  let out = s.gather([])
  assert_true(out.is_empty())
  assert_eq(out.name(), "x")
  assert_eq(out.dtype(), @types.DataType::Int)
}

///|
test "gather out-of-bounds reports the first offender" {
  let s = Series::from_ints("x", [1, 2])
  assert_eq(
    Ok(s.gather([0, 5])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(5)),
  )
  assert_eq(
    Ok(s.gather([-1])) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(-1)),
  )
}

// ── drop_nulls ───────────────────────────────────────────────────────

///|
test "drop_nulls removes every null, shrinking length" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None, Some(5)])
  let cleaned = s.drop_nulls()
  assert_eq(cleaned.name(), "x")
  assert_eq(cleaned.len(), 3)
  assert_eq(cleaned.null_count(), 0)
  assert_eq(cleaned.get(0), @types.Scalar::Int(1))
  assert_eq(cleaned.get(1), @types.Scalar::Int(3))
  assert_eq(cleaned.get(2), @types.Scalar::Int(5))
}

///|
test "drop_nulls is a no-op when there are no nulls" {
  let s = Series::from_ints("x", [1, 2, 3])
  let out = s.drop_nulls()
  assert_eq(out, s)
}

///|
test "drop_nulls on all-null produces an empty series" {
  let s = Series::from_int_options("x", [None, None])
  let out = s.drop_nulls()
  assert_eq(out.len(), 0)
  assert_eq(out.dtype(), @types.DataType::Int)
}

///|
test "drop_nulls on empty series returns empty series" {
  let s = Series::from_int_options("x", [])
  let out = s.drop_nulls()
  assert_true(out.is_empty())
}

// ── fill_null ────────────────────────────────────────────────────────

///|
test "fill_null on Int series fills nulls with the given Int" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None])
  let out = s.fill_null(@types.Scalar::Int(0))
  assert_eq(out.null_count(), 0)
  assert_eq(out.get(0), @types.Scalar::Int(1))
  assert_eq(out.get(1), @types.Scalar::Int(0))
  assert_eq(out.get(2), @types.Scalar::Int(3))
  assert_eq(out.get(3), @types.Scalar::Int(0))
}

///|
test "fill_null on Float series fills nulls with the given Float" {
  let s = Series::from_float_options("x", [None, Some(2.5)])
  let out = s.fill_null(@types.Scalar::Float(1.5))
  assert_eq(out.get(0), @types.Scalar::Float(1.5))
  assert_eq(out.get(1), @types.Scalar::Float(2.5))
}

///|
test "fill_null on Bool series fills nulls with the given Bool" {
  let s = Series::from_bool_options("x", [Some(true), None, None])
  let out = s.fill_null(@types.Scalar::Bool(false))
  assert_eq(out.get(0), @types.Scalar::Bool(true))
  assert_eq(out.get(1), @types.Scalar::Bool(false))
  assert_eq(out.get(2), @types.Scalar::Bool(false))
}

///|
test "fill_null on String series fills nulls with the given String" {
  let s = Series::from_string_options("x", [Some("a"), None])
  let out = s.fill_null(@types.Scalar::String("z"))
  assert_eq(out.get(0), @types.Scalar::String("a"))
  assert_eq(out.get(1), @types.Scalar::String("z"))
}

///|
test "fill_null rejects Scalar::Null fill values" {
  let s = Series::from_int_options("x", [Some(1), None])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Null)) catch { e => Err(e) })
    is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null rejects dtype-mismatched Int fill" {
  let s = Series::from_floats("x", [1.0])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Int(0))) catch { e => Err(e) })
    is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null rejects dtype-mismatched Float fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Float(0.0))) catch { e => Err(e) })
    is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null rejects dtype-mismatched Bool fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::Bool(true))) catch { e => Err(e) })
    is Err(TypeMismatch(_)),
  )
}

///|
test "fill_null rejects dtype-mismatched String fill" {
  let s = Series::from_ints("x", [1])
  assert_true(
    (Ok(s.fill_null(@types.Scalar::String("z"))) catch { e => Err(e) })
    is Err(TypeMismatch(_)),
  )
}

// ── cast (Int / Float / String targets) ──────────────────────────────
// `cast(dtype)` is the single cross-dtype entry; the per-source-dtype
// behaviour pinned below is what the retired `to_int` / `to_float` /
// `to_string_series` convenience wrappers used to expose.

///|
test "cast dispatches by target dtype" {
  let s = Series::from_ints("x", [1, 2, 3])
  assert_eq(s.cast(@types.DataType::Int).dtype(), @types.DataType::Int)
  assert_eq(s.cast(@types.DataType::Float).dtype(), @types.DataType::Float)
  assert_eq(s.cast(@types.DataType::String).dtype(), @types.DataType::String)
  assert_true(
    (Ok(s.cast(@types.DataType::Bool)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
  assert_true(
    (Ok(s.cast(@types.DataType::Null)) catch { e => Err(e) })
    is Err(Unsupported(_)),
  )
}

///|
test "cast to Int: identity / Float→Int / Bool→Int / String→Int" {
  let i = Series::from_ints("x", [1, 2])
  // cast borrows the Builtin road, so an identity Int→Int cast materialises
  // onto the Builtin backend — it equals the widened original, not `i` itself.
  assert_eq(i.cast(@types.DataType::Int), i.to_builtin())
  assert_eq(
    i.cast(@types.DataType::Int).storage_kind(),
    @column.StorageKind::Builtin,
  )
  let f = Series::from_floats("x", [1.5, 2.7])
  let f_to_i = f.cast(@types.DataType::Int)
  assert_eq(f_to_i.get(0), @types.Scalar::Int(1))
  let b = Series::from_bools("x", [true, false])
  let b_to_i = b.cast(@types.DataType::Int)
  assert_eq(b_to_i.get(0), @types.Scalar::Int(1))
  assert_eq(b_to_i.get(1), @types.Scalar::Int(0))
  let bad = Series::from_strings("x", ["nope"])
  assert_true(
    (Ok(bad.cast(@types.DataType::Int)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "cast to Float: identity / Int→Float / Bool→Float / String→Float" {
  let f = Series::from_floats("x", [1.0])
  // Same as the Int cast: identity Float→Float materialises onto the Builtin
  // backend.
  assert_eq(f.cast(@types.DataType::Float), f.to_builtin())
  let i = Series::from_ints("x", [3])
  assert_eq(i.cast(@types.DataType::Float).get(0), @types.Scalar::Float(3.0))
  let b = Series::from_bools("x", [true, false])
  let b_to_f = b.cast(@types.DataType::Float)
  assert_eq(b_to_f.get(0), @types.Scalar::Float(1.0))
  assert_eq(b_to_f.get(1), @types.Scalar::Float(0.0))
  let bad = Series::from_strings("x", ["x"])
  assert_true(
    (Ok(bad.cast(@types.DataType::Float)) catch { e => Err(e) })
    is Err(ParseError(_)),
  )
}

///|
test "cast to String renders value-style across dtypes" {
  let i = Series::from_int_options("x", [Some(7), None])
  let s_i = i.cast(@types.DataType::String)
  assert_eq(s_i.get(0), @types.Scalar::String("7"))
  assert_eq(s_i.get(1), @types.Scalar::Null)
  let f = Series::from_floats("x", [1.5])
  assert_eq(
    f.cast(@types.DataType::String).get(0),
    @types.Scalar::String("1.5"),
  )
  let b = Series::from_bools("x", [true, false])
  let s_b = b.cast(@types.DataType::String)
  assert_eq(s_b.get(0), @types.Scalar::String("true"))
  assert_eq(s_b.get(1), @types.Scalar::String("false"))
  let s = Series::from_strings("x", ["already"])
  assert_eq(s.cast(@types.DataType::String), s)
}

// ── storage backend control: storage_kind / to_numeric / to_builtin ──

///|
test "row gathers canonicalise an all-valid result; zero-copy slices preserve the backend" {
  // A no-null numeric column is Numeric; slicing / gathering / dropping
  // nulls keeps it on the fast path (a row subset is still all-valid).
  let s = Series::from_ints("x", [10, 20, 30, 40])
  assert_eq(s.storage_kind(), @column.StorageKind::Numeric)
  assert_eq(s.slice(1, 3).storage_kind(), @column.StorageKind::Numeric)
  assert_eq(s.gather([3, 0, 0]).storage_kind(), @column.StorageKind::Numeric)
  assert_eq(s.drop_nulls().storage_kind(), @column.StorageKind::Numeric)
  // A Builtin column whose nulls a *gather* drops canonicalises onto the
  // Numeric fast path: the backend is a function of the gathered content, so a
  // `gather` / `drop_nulls` / `filter` / `take` cannot leave an all-valid
  // numeric column off the fast path — the invariant the query optimizer
  // relies on for `collect ≡ eager`.
  let b = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(b.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(b.gather([0, 2]).storage_kind(), @column.StorageKind::Numeric)
  assert_eq(b.drop_nulls().storage_kind(), @column.StorageKind::Numeric)
  // A `slice` is a zero-copy view that keeps the source backend (no rebuild),
  // so a window still carrying a null stays Builtin.
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
test "to_numeric: success, already-Numeric, and round-trip equivalence" {
  // Builtin all-valid Int / Float move to the fast path.
  let bi = Series::from_int_options("x", [Some(1), Some(2), Some(3)])
  assert_eq(bi.storage_kind(), @column.StorageKind::Builtin)
  let ni = bi.to_numeric()
  assert_eq(ni.storage_kind(), @column.StorageKind::Numeric)
  // Values are unchanged by the backend swap.
  assert_eq(ni.to_scalars(), bi.to_scalars())
  let bf = Series::from_float_options("y", [Some(1.5), Some(2.5)])
  assert_eq(bf.to_numeric().storage_kind(), @column.StorageKind::Numeric)
  // Already Numeric → returned unchanged.
  let already = Series::from_ints("z", [7, 8])
  assert_eq(already.to_numeric(), already)
}

///|
test "to_numeric: rejects nulls and non-numeric columns" {
  let with_null = Series::from_int_options("x", [Some(1), None])
  assert_true(
    (Ok(with_null.to_numeric()) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  let strings = Series::from_strings("x", ["a", "b"])
  assert_true(
    (Ok(strings.to_numeric()) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
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
test "to_builtin: total, lossless round-trip from Numeric" {
  let n = Series::from_ints("x", [1, 2, 3])
  let b = n.to_builtin()
  assert_eq(b.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(b.to_scalars(), n.to_scalars())
  // Numeric → Builtin → Numeric returns to the original.
  assert_eq(b.to_numeric(), n)
  // Already Builtin → unchanged.
  let already = Series::from_int_options("x", [Some(1), None])
  assert_eq(already.to_builtin(), already)
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
