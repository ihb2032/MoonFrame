// The two storage-taking constructors are package-private, so their own tests
// compile inside the package rather than beside it: `Series::new` takes a
// `ColumnStorage` and `from_builtin` a `BuiltinColumn`, and neither has a
// caller outside `series`. What the blackbox suite pins instead is the public
// shape — the `from_*` constructors and the accessors — which is what a caller
// can actually reach.

///|
test "new / from_builtin wrap an existing column" {
  let col = @column.BuiltinColumn::from_int_options([Some(1), None, Some(3)])
  // `new` takes a `ColumnStorage`; `from_builtin` wraps a `BuiltinColumn` into
  // one — the two end up equal.
  let a = Series::new("age", @column.ColumnStorage::Builtin(col))
  let b = Series::from_builtin("age", col)
  assert_eq(a.name(), "age")
  assert_eq(a.dtype(), @types.DataType::Int)
  assert_eq(a.len(), 3)
  assert_eq(a.null_count(), 1)
  assert_eq(a.storage_kind(), @column.StorageKind::Builtin)
  assert_eq(a, b)
}

///|
test "from_i64_options checks the decimal envelope on the seam" {
  // The seam carries dtypes the engine authored; a decimal one still meets
  // the envelope, so `check_decimal_scale`'s every-constructor claim needs
  // no seam exception. In-scale riders build as before.
  let ok = Ok(
    Series::from_i64_options("m", @types.DataType::Decimal(2), [Some(5L)]),
  ) catch {
    e => Err(e)
  }
  assert_true(ok is Ok(_))
  let over = Ok(
    Series::from_i64_options("m", @types.DataType::Decimal(19), [Some(5L)]),
  ) catch {
    e => Err(e)
  }
  assert_true(over is Err(@types.DataError::InvalidOperation(_)))
}
