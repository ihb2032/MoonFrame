// Blackbox coverage pins for the kernel's decimal arms the expr layer
// reaches cross-package (where the coverage gate does not count): the
// is_in fast paths' abandonment shapes, read through the package's own
// pub entries.

///|
test "is_in's bool fast path abandons on a cross-dtype member" {
  let bools = @series.Series::from_bools("b", [true, false])
  let members : Array[@types.Scalar] = [
    @types.Scalar::Bool(true),
    @types.Scalar::Int(1),
  ]
  assert_true(
    (Ok(ignore(eval_is_in(bools, members.exact_view()))) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}

///|
test "is_in's decimal fast path answers its shapes" {
  let dec = @series.Series::from_decimals("d", [
    Some(@types.Dec128::of_int64(1L)),
    Some(@types.Dec128::nan()),
    None,
  ])
  let members : Array[@types.Scalar] = [
    @types.Scalar::Null,
    @types.Scalar::Decimal(@types.Dec128::nan()),
    @types.Scalar::Decimal(@types.Dec128::of_int64(1L)),
  ]
  let out = eval_is_in(dec, members.exact_view())
  assert_eq(out.to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
    @types.Scalar::Null,
  ])
  // A cross-dtype member abandons the fast path for the exact
  // compare — which raises the cross-dtype mismatch, the dtype
  // distinctness the fast path exists to keep.
  let mixed : Array[@types.Scalar] = [@types.Scalar::Int(1)]
  assert_true(
    (Ok(ignore(eval_is_in(dec, mixed.exact_view()))) catch { e => Err(e) })
    is Err(@types.DataError::TypeMismatch(_)),
  )
}
