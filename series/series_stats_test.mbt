// Blackbox tests for Series reductions in `series_stats.mbt`.

// ── count ────────────────────────────────────────────────────────────

///|
test "count is non-null count" {
  // Mixed.
  let s = Series::from_int_options("x", [Some(1), None, Some(3), None])
  assert_eq(s.count(), 2)
  // No nulls.
  assert_eq(Series::from_ints("x", [1, 2, 3]).count(), 3)
  // All-null.
  assert_eq(Series::from_int_options("x", [None, None]).count(), 0)
  // Empty.
  assert_eq(Series::from_ints("x", []).count(), 0)
}

// ── sum ──────────────────────────────────────────────────────────────

///|
test "sum on Int series ignores nulls" {
  let s = Series::from_int_options("x", [Some(1), None, Some(2), Some(3), None])
  assert_eq(s.sum(), @types.Scalar::Int(6))
}

///|
test "sum on Float series ignores nulls" {
  let s = Series::from_float_options("x", [Some(1.5), None, Some(2.5)])
  assert_eq(s.sum(), @types.Scalar::Float(4.0))
}

///|
test "sum on empty / all-null numeric is the additive identity" {
  assert_eq(Series::from_ints("x", []).sum(), @types.Scalar::Int(0))
  assert_eq(
    Series::from_int_options("x", [None, None]).sum(),
    @types.Scalar::Int(0),
  )
  assert_eq(Series::from_floats("x", []).sum(), @types.Scalar::Float(0.0))
  assert_eq(
    Series::from_float_options("x", [None]).sum(),
    @types.Scalar::Float(0.0),
  )
}

///|
test "sum on Bool / String is TypeMismatch" {
  assert_true(
    (try? Series::from_bools("x", [true]).sum()) is Err(TypeMismatch(_)),
  )
  assert_true(
    (try? Series::from_strings("x", ["a"]).sum()) is Err(TypeMismatch(_)),
  )
}

///|
test "sum on Float accumulates in 64-bit to limit drift" {
  // 16777216 = 2^24. In 32-bit Float, 2^24 + 1 rounds back to 2^24, so a
  // naive 32-bit accumulator would lose both 1.0s and report 16777216.
  // Accumulating in Double keeps them: the result is 16777218.
  let s = Series::from_floats("x", [16777216.0, 1.0, 1.0])
  assert_eq(s.sum(), @types.Scalar::Float(16777218.0))
}

///|
test "sum / mean propagate Float NaN as a value (only Null is missing)" {
  let nan : Double = @double.not_a_number
  // Polars semantics: NaN is a valid float value, so it is summed in and
  // propagates — any non-null NaN makes the whole sum / mean NaN. (Null,
  // by contrast, is still skipped.)
  let s = Series::from_floats("x", [1.0, nan, 3.0])
  assert_true(s.sum().as_float().is_nan())
  assert_true(s.mean().is_nan())
  // Null is skipped while the NaN still propagates through the rest.
  let mixed = Series::from_float_options("x", [Some(1.0), None, Some(nan)])
  assert_true(mixed.sum().as_float().is_nan())
  assert_true(mixed.mean().is_nan())
  // All-NaN is all-values, not all-missing: sum and mean are NaN, not the
  // additive identity / InvalidOperation an all-NULL column would give.
  let all_nan = Series::from_floats("x", [nan, nan])
  assert_true(all_nan.sum().as_float().is_nan())
  assert_true(all_nan.mean().is_nan())
}

// ── mean ─────────────────────────────────────────────────────────────

///|
test "mean on Int series promotes to Float" {
  let s = Series::from_int_options("x", [Some(1), None, Some(3)])
  assert_eq(s.mean(), (2.0 : Double))
}

///|
test "mean on Float series ignores nulls" {
  let s = Series::from_float_options("x", [Some(1.0), Some(2.0), None])
  assert_eq(s.mean(), (1.5 : Double))
}

///|
test "mean on empty / all-null numeric is InvalidOperation" {
  assert_true(
    (try? Series::from_ints("x", []).mean()) is Err(InvalidOperation(_)),
  )
  assert_true(
    (try? Series::from_int_options("x", [None, None]).mean())
    is Err(InvalidOperation(_)),
  )
  assert_true(
    (try? Series::from_floats("x", []).mean()) is Err(InvalidOperation(_)),
  )
  assert_true(
    (try? Series::from_float_options("x", [None]).mean())
    is Err(InvalidOperation(_)),
  )
}

///|
test "mean on Bool / String is TypeMismatch" {
  assert_true(
    (try? Series::from_bools("x", [true, false]).mean()) is Err(TypeMismatch(_)),
  )
  assert_true(
    (try? Series::from_strings("x", ["a"]).mean()) is Err(TypeMismatch(_)),
  )
}

// ── min_value / max_value ────────────────────────────────────────────

///|
test "min_value / max_value on Int series ignore nulls" {
  let s = Series::from_int_options("x", [Some(3), None, Some(1), Some(2), None])
  assert_eq(s.min_value(), @types.Scalar::Int(1))
  assert_eq(s.max_value(), @types.Scalar::Int(3))
}

///|
test "min_value / max_value on Float series ignore nulls" {
  let s = Series::from_float_options("x", [Some(2.5), None, Some(0.5)])
  assert_eq(s.min_value(), @types.Scalar::Float(0.5))
  assert_eq(s.max_value(), @types.Scalar::Float(2.5))
}

///|
test "min_value / max_value on Bool series follow false < true" {
  let mixed = Series::from_bools("x", [true, false, true])
  assert_eq(mixed.min_value(), @types.Scalar::Bool(false))
  assert_eq(mixed.max_value(), @types.Scalar::Bool(true))
  // Uniform inputs: best stays at the first cell, no `<` / `>` updates.
  let all_true = Series::from_bools("x", [true, true])
  assert_eq(all_true.min_value(), @types.Scalar::Bool(true))
  assert_eq(all_true.max_value(), @types.Scalar::Bool(true))
  let all_false = Series::from_bools("x", [false, false])
  assert_eq(all_false.min_value(), @types.Scalar::Bool(false))
  assert_eq(all_false.max_value(), @types.Scalar::Bool(false))
}

///|
test "min_value / max_value on String series use lexicographic order" {
  let s = Series::from_string_options("x", [
    Some("banana"),
    None,
    Some("apple"),
    Some("cherry"),
  ])
  assert_eq(s.min_value(), @types.Scalar::String("apple"))
  assert_eq(s.max_value(), @types.Scalar::String("cherry"))
  // Length-differing case: true lexicographic ranks "apple" before "fig"
  // (a < f), whereas the built-in shortlex `<` would rank the shorter
  // "fig" first. Pins the dictionary-order contract.
  let lens = Series::from_strings("x", ["fig", "apple"])
  assert_eq(lens.min_value(), @types.Scalar::String("apple"))
  assert_eq(lens.max_value(), @types.Scalar::String("fig"))
}

///|
test "min_value / max_value on empty / all-null return Null across every dtype" {
  // Every (op, dtype) pair must hit its dedicated `None` branch.
  // Int.
  assert_eq(Series::from_ints("x", []).min_value(), @types.Scalar::Null)
  assert_eq(Series::from_ints("x", []).max_value(), @types.Scalar::Null)
  assert_eq(
    Series::from_int_options("x", [None, None]).min_value(),
    @types.Scalar::Null,
  )
  assert_eq(
    Series::from_int_options("x", [None, None]).max_value(),
    @types.Scalar::Null,
  )
  // Float.
  assert_eq(Series::from_floats("x", []).min_value(), @types.Scalar::Null)
  assert_eq(Series::from_floats("x", []).max_value(), @types.Scalar::Null)
  assert_eq(
    Series::from_float_options("x", [None]).min_value(),
    @types.Scalar::Null,
  )
  assert_eq(
    Series::from_float_options("x", [None]).max_value(),
    @types.Scalar::Null,
  )
  // Bool.
  assert_eq(Series::from_bools("x", []).min_value(), @types.Scalar::Null)
  assert_eq(Series::from_bools("x", []).max_value(), @types.Scalar::Null)
  assert_eq(
    Series::from_bool_options("x", [None]).min_value(),
    @types.Scalar::Null,
  )
  assert_eq(
    Series::from_bool_options("x", [None]).max_value(),
    @types.Scalar::Null,
  )
  // String.
  assert_eq(Series::from_strings("x", []).min_value(), @types.Scalar::Null)
  assert_eq(Series::from_strings("x", []).max_value(), @types.Scalar::Null)
  assert_eq(
    Series::from_string_options("x", [None]).min_value(),
    @types.Scalar::Null,
  )
  assert_eq(
    Series::from_string_options("x", [None]).max_value(),
    @types.Scalar::Null,
  )
}

///|
test "min_value / max_value skip Float NaN (treated as missing, like sort)" {
  let nan : Double = @double.not_a_number
  // A leading NaN is skipped, so it does not become the result.
  let nan_first = Series::from_floats("x", [nan, 1.0])
  assert_eq(nan_first.min_value(), @types.Scalar::Float(1.0))
  assert_eq(nan_first.max_value(), @types.Scalar::Float(1.0))
  // Interior NaN cells are ignored.
  let nan_later = Series::from_floats("x", [1.0, nan, 0.5])
  assert_eq(nan_later.min_value(), @types.Scalar::Float(0.5))
  assert_eq(nan_later.max_value(), @types.Scalar::Float(1.0))
  // All-NaN collapses to Null (every cell skipped), like an all-null series.
  let all_nan = Series::from_floats("x", [nan, nan])
  assert_eq(all_nan.min_value(), @types.Scalar::Null)
  assert_eq(all_nan.max_value(), @types.Scalar::Null)
}

///|
test "min_value / max_value Bool flip when the running extremum must change" {
  // Exercises the tie-break `then` arms: `max` starts at `false` and must
  // switch up to `true`; `min` starts at `true` and must switch down to
  // `false`. (When `true` precedes `false` for `max`, the running max is
  // already `true` and the `then` arm never fires.)
  assert_eq(
    Series::from_bools("x", [false, true]).max_value(),
    @types.Scalar::Bool(true),
  )
  assert_eq(
    Series::from_bools("y", [true, false]).min_value(),
    @types.Scalar::Bool(false),
  )
}

// ── backend equivalence (Numeric fast path vs Builtin) ────────────────

///|
test "reductions agree on the Numeric fast path and the Builtin path" {
  // The v0.3 fix routes a `Numeric`-backed series' reductions to the
  // bitmap-free fold; this pins that the fast path can never diverge from the
  // general `Builtin` path on the same values (`to_builtin()` forces Builtin).
  let ints = Series::from_ints("x", [3, 1, 4, 1, 5, 9, 2, 6])
  let bints = ints.to_builtin()
  assert_eq(ints.storage_kind(), @column.StorageKind::Numeric)
  assert_eq(bints.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(ints.sum(), bints.sum())
  assert_eq(ints.mean(), bints.mean())
  assert_eq(ints.min_value(), bints.min_value())
  assert_eq(ints.max_value(), bints.max_value())
  // Float with a NaN cell: sum / mean propagate NaN, min / max skip it — both
  // backends must reach the same verdict on every reduction.
  let nan : Double = @double.not_a_number
  let flts = Series::from_floats("x", [2.5, nan, 1.0, 4.0])
  let bflts = flts.to_builtin()
  assert_eq(flts.storage_kind(), @column.StorageKind::Numeric)
  assert_true(flts.sum().as_float().is_nan() && bflts.sum().as_float().is_nan())
  assert_true(flts.mean().is_nan() && bflts.mean().is_nan())
  assert_eq(flts.min_value(), bflts.min_value())
  assert_eq(flts.max_value(), bflts.max_value())
}

// ── unique_count ─────────────────────────────────────────────────────

///|
test "unique_count counts distinct non-null values" {
  let s = Series::from_int_options("x", [
    Some(1),
    None,
    Some(2),
    Some(1),
    Some(3),
    None,
  ])
  assert_eq(s.unique_count(), 3)
}

///|
test "unique_count is 0 for empty / all-null series" {
  assert_eq(Series::from_ints("x", []).unique_count(), 0)
  assert_eq(Series::from_int_options("x", [None, None, None]).unique_count(), 0)
}

///|
test "unique_count works on every dtype" {
  assert_eq(Series::from_floats("x", [1.0, 1.0, 2.0]).unique_count(), 2)
  assert_eq(
    Series::from_bools("x", [true, false, true, false]).unique_count(),
    2,
  )
  assert_eq(Series::from_strings("x", ["a", "b", "a", "c"]).unique_count(), 3)
}

///|
test "unique_count collapses all NaN Float cells into a single bucket" {
  let nan : Double = @double.not_a_number
  let s = Series::from_floats("x", [nan, nan, 1.0])
  assert_eq(s.unique_count(), 2)
}

///|
test "unique_count folds -0.0 and +0.0 into one value (matching group_by)" {
  // `-0.0` and `+0.0` are IEEE-equal and share a `group_by` group, so they
  // are one distinct value: `unique_count` keys by the same `KeyCell`
  // normalisation rather than `Double::to_string`, which could split them.
  let s = Series::from_floats("x", [0.0, -0.0, 1.0])
  assert_eq(s.unique_count(), 2)
}

// ── mean_opt ─────────────────────────────────────────────────────────

///|
/// `mean_opt` is the total form of `Series::mean`: `Some(mean)` for a numeric
/// series with at least one non-null cell, `None` exactly where `mean` raises
/// (non-numeric `TypeMismatch`, empty / all-null `InvalidOperation`). Hitting
/// both the `Some` and the `None` arms keeps this package's own suite covering
/// the accessor `frame`'s `DataFrame::describe` reads across the boundary.
test "mean_opt is Some for numeric-with-values and None where mean would raise" {
  assert_eq(Series::from_ints("x", [1, 2, 3]).mean_opt(), Some(2.0))
  assert_eq(
    Series::from_float_options("x", [Some(1.0), None, Some(3.0)]).mean_opt(),
    Some(2.0),
  )
  // `None` exactly where `Series::mean` raises:
  assert_eq(Series::from_strings("s", ["a", "b"]).mean_opt(), None) // TypeMismatch
  assert_eq(Series::from_int_options("e", []).mean_opt(), None) // empty
  assert_eq(Series::from_int_options("n", [None, None]).mean_opt(), None) // all-null
}
