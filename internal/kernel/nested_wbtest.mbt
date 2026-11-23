// Whitebox pins for the nested literal at the kernel's singleton build:
// the one-cell column it becomes under the dtype the value names, and
// the refusal for a value that leaves a position unnamed. The shape rule
// itself (`Scalar::named_dtype`) is the types package's, pinned there.

///|
fn lv(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn fv(name : String, value : @types.Scalar) -> @types.FieldValue {
  @types.FieldValue::FieldValue(name, value)
}

///|
test "the singleton builder builds a named nested literal" {
  // A list: its element dtype read off its first naming element — an
  // empty list ahead of it is passed over, a null beside it fits.
  let s = singleton_series(lv([@types.Scalar::Int(1), @types.Scalar::Null]))
  assert_eq(s.len(), 1)
  assert_eq(s.dtype(), @types.DataType::List(@types.DataType::Int))
  assert_eq(s.get(0), lv([@types.Scalar::Int(1), @types.Scalar::Null]))
  let nested = singleton_series(lv([lv([]), lv([@types.Scalar::Int(2)])]))
  assert_eq(
    nested.dtype(),
    @types.DataType::List(@types.DataType::List(@types.DataType::Int)),
  )
  assert_eq(nested.get(0), lv([lv([]), lv([@types.Scalar::Int(2)])]))
  // A struct: every field names its dtype.
  let struct_s = singleton_series(
    @types.Scalar::Struct(
      @types.StructValue::StructValue([
        fv("a", @types.Scalar::Int(1)),
        fv("b", lv([@types.Scalar::String("x")])),
      ]),
    ),
  )
  assert_eq(struct_s.len(), 1)
}

///|
test "the singleton builder refuses a nested literal that names no dtype" {
  let cases : Array[@types.Scalar] = [
    lv([]),
    lv([@types.Scalar::Null]),
    lv([lv([])]),
    @types.Scalar::Struct(
      @types.StructValue::StructValue([
        fv("a", @types.Scalar::Int(1)),
        fv("b", @types.Scalar::Null),
      ]),
    ),
    @types.Scalar::Struct(@types.StructValue::StructValue([fv("a", lv([]))])),
  ]
  for value in cases {
    let refused = Ok(ignore(singleton_series(value))) catch { e => Err(e) }
    assert_true(
      refused is Err(@types.DataError::Unsupported(m)) &&
      m.contains("nested literal"),
    )
  }
}
