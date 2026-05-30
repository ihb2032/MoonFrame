// Blackbox tests for `RowView`. Row construction goes through
// `DataFrame::row`, which is also exercised here.

///|
/// Reusable mixed-dtype frame for the dtype-coverage tests below.
/// Row 1 is all-null so every typed accessor has a null cell to refuse.
fn sample_frame() -> DataFrame {
  DataFrame::new([
    Series::from_int_options("i", [Some(7), None, Some(9)]),
    Series::from_float_options("f", [Some(1.5), None, Some(3.5)]),
    Series::from_bool_options("b", [Some(true), None, Some(false)]),
    Series::from_string_options("s", [Some("a"), None, Some("c")]),
  ]).unwrap()
}

// ── index ────────────────────────────────────────────────────────────

///|
test "index returns the row position the view was opened at" {
  let df = sample_frame()
  assert_eq(df.row(0).unwrap().index(), 0)
  assert_eq(df.row(2).unwrap().index(), 2)
}

// ── get / is_null ────────────────────────────────────────────────────

///|
test "get reads cells as Scalar; null cells return Scalar::Null" {
  let df = sample_frame()
  let r0 = df.row(0).unwrap()
  assert_eq(r0.get("i"), Ok(@types.Scalar::Int(7)))
  assert_eq(r0.get("f"), Ok(@types.Scalar::Float(1.5)))
  assert_eq(r0.get("b"), Ok(@types.Scalar::Bool(true)))
  assert_eq(r0.get("s"), Ok(@types.Scalar::String("a")))
  // Row 1 is all-null — every cell reads as Null.
  let r1 = df.row(1).unwrap()
  assert_eq(r1.get("i"), Ok(@types.Scalar::Null))
  assert_eq(r1.get("f"), Ok(@types.Scalar::Null))
  assert_eq(r1.get("b"), Ok(@types.Scalar::Null))
  assert_eq(r1.get("s"), Ok(@types.Scalar::Null))
}

///|
test "get reports unknown columns with ColumnNotFound" {
  let r = sample_frame().row(0).unwrap()
  assert_eq(r.get("missing"), Err(@types.DataError::ColumnNotFound("missing")))
}

///|
test "is_null differentiates concrete from null cells per dtype" {
  let df = sample_frame()
  let r0 = df.row(0).unwrap()
  assert_eq(r0.is_null("i"), Ok(false))
  assert_eq(r0.is_null("b"), Ok(false))
  let r1 = df.row(1).unwrap()
  assert_eq(r1.is_null("i"), Ok(true))
  assert_eq(r1.is_null("f"), Ok(true))
  assert_eq(r1.is_null("b"), Ok(true))
  assert_eq(r1.is_null("s"), Ok(true))
}

///|
test "is_null reports unknown columns with ColumnNotFound" {
  let r = sample_frame().row(0).unwrap()
  assert_eq(
    r.is_null("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

// ── get_int / get_float / get_bool / get_string ──────────────────────

///|
test "get_int reads Int cells and rejects mismatched / null cells" {
  let df = sample_frame()
  // Concrete Int cell on row 0.
  assert_eq(df.row(0).unwrap().get_int("i"), Ok(7))
  // Null cell on row 1 → TypeMismatch (Scalar::as_int rejects Null).
  assert_true(df.row(1).unwrap().get_int("i") is Err(TypeMismatch(_)))
  // Wrong dtype (Float column) → TypeMismatch.
  assert_true(df.row(0).unwrap().get_int("f") is Err(TypeMismatch(_)))
  // Unknown column → ColumnNotFound.
  assert_eq(
    df.row(0).unwrap().get_int("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "get_float reads Float cells and promotes Int cells" {
  let df = sample_frame()
  assert_eq(df.row(0).unwrap().get_float("f"), Ok((1.5 : Double)))
  // Int promoted to Float via Scalar::as_float.
  assert_eq(df.row(0).unwrap().get_float("i"), Ok((7.0 : Double)))
  // Null cell → TypeMismatch.
  assert_true(df.row(1).unwrap().get_float("f") is Err(TypeMismatch(_)))
  // Wrong dtype (Bool column) → TypeMismatch.
  assert_true(df.row(0).unwrap().get_float("b") is Err(TypeMismatch(_)))
  // Unknown column → ColumnNotFound.
  assert_eq(
    df.row(0).unwrap().get_float("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "get_bool reads Bool cells and rejects mismatched / null cells" {
  let df = sample_frame()
  assert_eq(df.row(0).unwrap().get_bool("b"), Ok(true))
  assert_eq(df.row(2).unwrap().get_bool("b"), Ok(false))
  // Null cell → TypeMismatch.
  assert_true(df.row(1).unwrap().get_bool("b") is Err(TypeMismatch(_)))
  // Wrong dtype → TypeMismatch.
  assert_true(df.row(0).unwrap().get_bool("i") is Err(TypeMismatch(_)))
  // Unknown column → ColumnNotFound.
  assert_eq(
    df.row(0).unwrap().get_bool("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}

///|
test "get_string reads String cells and rejects mismatched / null cells" {
  let df = sample_frame()
  assert_eq(df.row(0).unwrap().get_string("s"), Ok("a"))
  // Null cell → TypeMismatch.
  assert_true(df.row(1).unwrap().get_string("s") is Err(TypeMismatch(_)))
  // Wrong dtype → TypeMismatch.
  assert_true(df.row(0).unwrap().get_string("i") is Err(TypeMismatch(_)))
  // Unknown column → ColumnNotFound.
  assert_eq(
    df.row(0).unwrap().get_string("missing"),
    Err(@types.DataError::ColumnNotFound("missing")),
  )
}
