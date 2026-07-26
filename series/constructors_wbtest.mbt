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
