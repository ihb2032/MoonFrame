// Backend-parity harness: a logical numeric column has two physical
// representations — the general `Builtin` (Arrow data + validity bitmap) and
// the unboxed all-valid `Numeric` fast path — and *every* public `Series`
// operation must return the same value, dtype, null-ness, and error variant on
// both, regardless of which backend a value happens to sit on. This is the
// standing guard against the class of bug where one backend decides an
// out-of-range index crashes and the other returns null (the backend-flip
// hazard behind the collect/execute divergence fixed earlier): every op is run
// on both backends of the same column and the two results are asserted
// identical, NaN- and null-aware, including adversarial gather / slice / get
// indices (out-of-bounds, negative, `Int::MAX`).

///|
/// Float equality that counts two `NaN`s as equal (so a reduction that
/// legitimately produces `NaN` on both backends compares equal) — otherwise
/// exact, so a signed-zero or ordinary value still compares by value.
fn same_scalar(a : @types.Scalar, b : @types.Scalar) -> Bool {
  match (a, b) {
    (@types.Scalar::Float(x), @types.Scalar::Float(y)) =>
      x == y || (x != x && y != y)
    _ => a == b
  }
}

///|
/// NaN-aware `Double` equality, for the `Double`-returning reductions.
fn same_double(a : Double, b : Double) -> Bool {
  a == b || (a != a && b != b)
}

///|
/// Two series are logically equal when they agree on dtype, length, and every
/// cell (NaN- and null-aware). Deliberately backend-*insensitive*: a result may
/// canonicalise onto either backend, but its values must match.
fn same_series(a : Series, b : Series) -> Bool {
  guard a.dtype() == b.dtype() && a.len() == b.len() else { return false }
  let sa = a.to_scalars()
  let sb = b.to_scalars()
  for i in 0..<sa.length() {
    if !same_scalar(sa[i], sb[i]) {
      return false
    }
  }
  true
}

///|
/// A `Scalar`-returning fallible op agrees when both sides return equal values
/// or both raise the same `DataError` variant.
fn same_scalar_result(
  a : Result[@types.Scalar, @types.DataError],
  b : Result[@types.Scalar, @types.DataError],
) -> Bool {
  match (a, b) {
    (Ok(x), Ok(y)) => same_scalar(x, y)
    (Err(e1), Err(e2)) => e1 == e2
    _ => false
  }
}

///|
/// A `Double`-returning fallible op agrees when both return equal values
/// (NaN-aware) or both raise the same error.
fn same_double_result(
  a : Result[Double, @types.DataError],
  b : Result[Double, @types.DataError],
) -> Bool {
  match (a, b) {
    (Ok(x), Ok(y)) => same_double(x, y)
    (Err(e1), Err(e2)) => e1 == e2
    _ => false
  }
}

///|
/// A `Series`-returning fallible op agrees when both return logically-equal
/// series or both raise the same error.
fn same_series_result(
  a : Result[Series, @types.DataError],
  b : Result[Series, @types.DataError],
) -> Bool {
  match (a, b) {
    (Ok(x), Ok(y)) => same_series(x, y)
    (Err(e1), Err(e2)) => e1 == e2
    _ => false
  }
}

///|
/// Run every public `Series` operation on both backends of the same logical
/// column and assert the two agree. `bt` is `Builtin`-backed, `nu` is
/// `Numeric`-backed; the caller guarantees they hold the same values.
fn assert_backend_parity(bt : Series, nu : Series) -> Unit raise {
  // The two are the same logical column on different backends.
  assert_eq(bt.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(nu.storage_kind(), @column.StorageKind::Numeric)
  assert_true(same_series(bt, nu))

  // Total accessors.
  assert_eq(bt.len(), nu.len())
  assert_eq(bt.dtype(), nu.dtype())
  assert_eq(bt.is_empty(), nu.is_empty())
  assert_eq(bt.null_count(), nu.null_count())
  assert_true(same_scalar(bt.first(), nu.first()))
  assert_true(same_scalar(bt.last(), nu.last()))
  assert_eq(bt.count(), nu.count())
  assert_eq(bt.n_unique(), nu.n_unique())
  assert_true(same_scalar(bt.min(), nu.min()))
  assert_true(same_scalar(bt.max(), nu.max()))
  match (bt.mean_opt(), nu.mean_opt()) {
    (Some(x), Some(y)) => assert_true(same_double(x, y))
    (None, None) => ()
    _ => fail("mean_opt backend mismatch")
  }

  // Fallible reductions.
  assert_true(
    same_scalar_result(
      Ok(bt.sum()) catch {
        e => Err(e)
      },
      Ok(nu.sum()) catch {
        e => Err(e)
      },
    ),
  )
  assert_true(
    same_double_result(
      Ok(bt.mean()) catch {
        e => Err(e)
      },
      Ok(nu.mean()) catch {
        e => Err(e)
      },
    ),
  )
  assert_true(
    same_double_result(
      Ok(bt.std()) catch {
        e => Err(e)
      },
      Ok(nu.std()) catch {
        e => Err(e)
      },
    ),
  )
  assert_true(
    same_double_result(
      Ok(bt.variance()) catch {
        e => Err(e)
      },
      Ok(nu.variance()) catch {
        e => Err(e)
      },
    ),
  )
  assert_true(
    same_double_result(
      Ok(bt.median()) catch {
        e => Err(e)
      },
      Ok(nu.median()) catch {
        e => Err(e)
      },
    ),
  )

  // Total transforms.
  assert_true(same_series(bt.drop_nulls(), nu.drop_nulls()))
  assert_true(same_series(bt.rename("z"), nu.rename("z")))

  // Fallible transforms: cast to both numeric dtypes and to a non-numeric one.
  for
    target in [
      @types.DataType::Int,
      @types.DataType::Float,
      @types.DataType::Bool,
    ] {
    assert_true(
      same_series_result(
        Ok(bt.cast(target)) catch {
          e => Err(e)
        },
        Ok(nu.cast(target)) catch {
          e => Err(e)
        },
      ),
    )
  }
  assert_true(
    same_series_result(
      Ok(bt.fill_null(@types.Scalar::Int(0))) catch {
        e => Err(e)
      },
      Ok(nu.fill_null(@types.Scalar::Int(0))) catch {
        e => Err(e)
      },
    ),
  )

  // Adversarial indexed access: valid, out-of-bounds, negative, and Int::MAX
  // indices must produce the SAME result or the SAME error on both backends —
  // never a crash on one and a null on the other.
  let n = bt.len()
  for i in [0, n - 1, n, -1, 2147483647] {
    assert_true(
      same_scalar_result(
        Ok(bt.get(i)) catch {
          e => Err(e)
        },
        Ok(nu.get(i)) catch {
          e => Err(e)
        },
      ),
    )
    assert_true(
      match
        (
          Ok(bt.is_null(i)) catch {
            e => Err(e)
          },
          Ok(nu.is_null(i)) catch {
            e => Err(e)
          },
        ) {
        (Ok(x), Ok(y)) => x == y
        (Err(e1), Err(e2)) => e1 == e2
        _ => false
      },
    )
    assert_true(
      same_series_result(
        Ok(bt.gather([i])) catch {
          e => Err(e)
        },
        Ok(nu.gather([i])) catch {
          e => Err(e)
        },
      ),
    )
  }
  // Slice with a valid window, a zero-length window, and an out-of-range one.
  for window in [(0, n), (0, 0), (1, n + 5)] {
    let (start, len) = window
    assert_true(
      same_series_result(
        Ok(bt.slice(start, len)) catch {
          e => Err(e)
        },
        Ok(nu.slice(start, len)) catch {
          e => Err(e)
        },
      ),
    )
  }
  // A multi-index gather mixing valid and invalid indices.
  assert_true(
    same_series_result(
      Ok(bt.gather([0, n - 1, n])) catch {
        e => Err(e)
      },
      Ok(nu.gather([0, n - 1, n])) catch {
        e => Err(e)
      },
    ),
  )
}

///|
/// Drive `assert_backend_parity` over a spread of all-valid numeric columns —
/// the only columns that *can* take the `Numeric` backend. Covers an `Int`
/// column straddling zero, a `Float` column with a signed zero, a `Float`
/// column carrying a `NaN` value (all-valid: `NaN` is a value, not a null), a
/// single-cell column, and the empty column.
test "every Series op agrees across the Builtin and Numeric backends" {
  let nan = 0.0 / 0.0
  let int_cols = [
    Series::from_ints("a", [0L, 1L, -1L, 5L, 100L, -50L]),
    Series::from_ints("a", [42L]),
    Series::from_ints("a", []),
  ]
  let float_cols = [
    Series::from_floats("a", [0.0, -0.0, 1.5, -2.5, 100.0]),
    Series::from_floats("a", [1.0, nan, 2.0]),
    Series::from_floats("a", [3.5]),
    Series::from_floats("a", []),
  ]
  for s in int_cols {
    assert_backend_parity(s.to_builtin(), s.to_numeric())
  }
  for s in float_cols {
    assert_backend_parity(s.to_builtin(), s.to_numeric())
  }
}
