// Whitebox battery for the option-cell adapters: the inference / build
// cores guarantee a present, non-null cell to the probes and parsers
// (`is_null` filters first), so each adapter's `None` arm — the missing
// cell's verdict on a question the cores never ask of it — is pinned here
// rather than through a reader. Package-private, like the adapters.

///|
test "cell adapters: a missing cell is null, probes nothing, renders empty" {
  // is_null: a missing cell is null regardless of the caller's mapping;
  // a present cell maps by it.
  assert_true(cell_is_null(_ => false, None))
  assert_false(cell_is_null(v => v == "NA", Some("x")))
  assert_true(cell_is_null(v => v == "NA", Some("NA")))
  // probe: a missing cell answers no dtype.
  assert_false(cell_probe(_ => true, None))
  assert_true(cell_probe(v => v == "1", Some("1")))
  // parse: a missing cell yields no value.
  assert_true(cell_parse((v : String) => Some(v.length()), None) is None)
  assert_true(
    cell_parse((v : String) => Some(v.length()), Some("ab")) is Some(2),
  )
  // render: a missing cell has no text.
  assert_eq(cell_text(None), "")
  assert_eq(cell_text(Some("x")), "x")
}
