// Blackbox tests for a nested literal on the expression surface: the
// rendered spelling and the one-cell column it evaluates to.

///|
fn lv(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn sv(a : @types.Scalar, b : @types.Scalar) -> @types.Scalar {
  @types.Scalar::Struct(
    @types.StructValue::StructValue([
      @types.FieldValue::FieldValue("a", a),
      @types.FieldValue::FieldValue("b", b),
    ]),
  )
}

///|
test "a nested literal renders in its value form" {
  inspect(
    lit(lv([@types.Scalar::Int(1), @types.Scalar::Int(2)])).to_string(),
    content="[1, 2]",
  )
  inspect(lit(lv([])).to_string(), content="[]")
  inspect(
    lit(lv([@types.Scalar::String("a"), @types.Scalar::Null])).to_string(),
    content="[\"a\", null]",
  )
  inspect(
    lit(sv(@types.Scalar::Int(1), @types.Scalar::Bool(true))).to_string(),
    content="{\"a\": 1, \"b\": true}",
  )
  // Inside a larger expression the literal keeps that spelling.
  inspect(
    col("l").eq(lit(lv([@types.Scalar::Int(1)]))).to_string(),
    content="(col(l) == [1])",
  )
}
