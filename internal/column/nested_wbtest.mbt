// Whitebox pins for the nested dtypes at the column layer: the storage
// is not designed yet, so every build path refuses naming the dtype.

///|
test "from_scalars refuses the nested dtypes" {
  let cells : Array[@types.Scalar] = []
  let list = Ok(
    ignore(
      BuiltinColumn::from_scalars(
        @types.DataType::List(@types.DataType::Int),
        cells,
        name="l",
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    list is Err(@types.DataError::Unsupported(m)) && m.contains("dtype List"),
  )
  let struct_d = Ok(
    ignore(
      BuiltinColumn::from_scalars(
        @types.DataType::Struct([("a", @types.DataType::Int)]),
        cells,
        name="s",
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    struct_d is Err(@types.DataError::Unsupported(m2)) &&
    m2.contains("dtype Struct"),
  )
}
