///|
test "a nested dtype refuses the cast and the scalar build" {
  // The nested dtypes exist for the IPC and JSON readers ahead; the
  // column layer refuses them until their storage is designed.
  let target = @types.DataType::List(@types.DataType::Int)
  let cast = Ok(ignore(Series::from_ints("v", [1]).cast(target))) catch {
    e => Err(e)
  }
  assert_true(
    cast is Err(@types.DataError::Unsupported(m)) && m.contains("cast to List"),
  )
  let built = Ok(ignore(Series::from_scalars("l", [], dtype=target))) catch {
    e => Err(e)
  }
  assert_true(
    built is Err(@types.DataError::Unsupported(m2)) && m2.contains("dtype List"),
  )
}

///|
test "the struct twin of the nested refusals" {
  let target = @types.DataType::Struct([("a", @types.DataType::Int)])
  let cast = Ok(ignore(Series::from_ints("v", [1]).cast(target))) catch {
    e => Err(e)
  }
  assert_true(
    cast is Err(@types.DataError::Unsupported(m)) &&
    m.contains("cast to Struct"),
  )
  let built = Ok(ignore(Series::from_scalars("s", [], dtype=target))) catch {
    e => Err(e)
  }
  assert_true(
    built is Err(@types.DataError::Unsupported(m2)) &&
    m2.contains("dtype Struct"),
  )
}
