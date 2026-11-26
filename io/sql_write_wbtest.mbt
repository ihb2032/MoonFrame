// Whitebox tests of the SQL writer's two unreachable refusals and its
// decimal text: the cells the writer refuses before a statement is sent
// are met here at the function they would have reached, and the digit
// text is read off cells the frame-level tests never bind.

///|
fn dec(text : String) -> @types.Dec128 {
  @types.Dec128::parse_opt(text).unwrap()
}

///|
/// The error `run` raised; a call that goes through fails the test.
fn raised(run : () -> Unit raise @types.DataError) -> @types.DataError raise {
  let outcome : Result[Unit, @types.DataError] = Ok(run()) catch { e => Err(e) }
  match outcome {
    Ok(_) => fail("the call was expected to refuse")
    Err(e) => e
  }
}

///|
test "a decimal cell is its digit text at the column's scale" {
  // A cell smaller than the unit takes zeros ahead of the point, a whole
  // one zeros after it, and the scale fixes where the point falls.
  assert_eq(sql_decimal_text(dec("0.05"), 2, "d"), "0.05")
  assert_eq(sql_decimal_text(dec("-0.25"), 2, "d"), "-0.25")
  assert_eq(sql_decimal_text(dec("7"), 2, "d"), "7.00")
  assert_eq(sql_decimal_text(dec("1234.5"), 3, "d"), "1234.500")
  assert_eq(sql_decimal_text(dec("0"), 2, "d"), "0.00")
  assert_eq(sql_decimal_text(dec("-0.00"), 2, "d"), "0.00")
  // No fraction digits: no point.
  assert_eq(sql_decimal_text(dec("42"), 0, "d"), "42")
  // A cell written at a scale narrower than its own exponent counts is
  // lifted by zeros.
  assert_eq(sql_decimal_text(dec("1E+3"), 2, "d"), "1000.00")
}

///|
test "a NaN decimal cell has no digit text to bind" {
  assert_true(
    raised(fn() -> Unit raise @types.DataError {
      ignore(sql_decimal_text(@types.Dec128::nan(), 2, "d"))
    })
    is @types.DataError::InvalidOperation(m) &&
    m.contains("column \"d\" carries a NaN or infinite decimal cell"),
  )
}

///|
test "a nested cell reaching the binder is refused" {
  // The columns are planned before a statement is sent, so a list or a
  // struct column refuses before any cell is bound; a nested cell that
  // reached the binder all the same refuses here.
  let list = @types.Scalar::List(@types.ListValue::ListValue([]))
  assert_true(
    raised(fn() -> Unit raise @types.DataError {
      ignore(sql_value(list, 0, false, "l"))
    })
    is @types.DataError::Unsupported(m) &&
    m.contains("column \"l\" carries a nested cell"),
  )
  let record = @types.Scalar::Struct(@types.StructValue::StructValue([]))
  assert_true(
    raised(fn() -> Unit raise @types.DataError {
      ignore(sql_value(record, 0, false, "s"))
    })
    is @types.DataError::Unsupported(m) &&
    m.contains("column \"s\" carries a nested cell"),
  )
}
