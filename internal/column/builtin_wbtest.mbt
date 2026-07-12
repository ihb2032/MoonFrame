// Whitebox tests for `BuiltinColumn`'s placeholder-normalisation invariant.
// Every public constructor / cast / transform writes the canonical placeholder,
// so a *violation* — a stray value in a null slot — can only be built
// field-by-field, reachable here inside the package. (Mirrors how `frame`'s
// invariants_wbtest reaches states the public API cannot.)

///|
test "placeholders_normalized flags a leaked value in a null slot, per dtype" {
  // validity: row 0 valid, row 1 null — a Bitmap is dtype-agnostic, so one mask
  // serves every dtype. Each column leaves a non-placeholder value in null row
  // 1, exercising the false arm of the predicate's `data` match on all four
  // dtypes.
  let mask = Bitmap::from_options([Some(0L), None])
  let leak_i : BuiltinColumn = { data: Int([0L, 99L]), validity: mask }
  assert_false(leak_i.placeholders_normalized())
  let leak_f : BuiltinColumn = { data: Float([0.0, 9.9]), validity: mask }
  assert_false(leak_f.placeholders_normalized())
  let leak_b : BuiltinColumn = { data: Bool([false, true]), validity: mask }
  assert_false(leak_b.placeholders_normalized())
  let leak_s : BuiltinColumn = { data: String(["", "leak"]), validity: mask }
  assert_false(leak_s.placeholders_normalized())
  // The same validity with the canonical placeholder in the null slot passes.
  let ok_i : BuiltinColumn = { data: Int([0L, 0L]), validity: mask }
  assert_true(ok_i.placeholders_normalized())
}
