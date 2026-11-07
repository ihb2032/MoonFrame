// Whitebox pin for the read-side tag mapping: a converted annotation no
// MoonFrame dtype carries refuses the column — the literal-free reading
// twin of `converted_tag` maps only the four annotations the writer spells.

///|
test "schema mapping: an unknown converted tag refuses the column" {
  assert_true(map_from_schema(1, Some(99), None) is None)
  assert_true(map_from_schema(2, Some(99), None) is None)
}
