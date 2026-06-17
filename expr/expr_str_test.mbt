///|
/// Blackbox tests for the string namespace at the expression layer: the
/// `Show` / `explain` rendering of every `str_*` method (including the
/// quoting / escaping of literal arguments), the `Str` arm of the handwritten
/// `Eq` (which has a wildcard fallthrough, so it is pinned by hand), and the
/// introspection primitives — `children`, `output_name`, and
/// `referenced_columns` — treating the wrapper transparently. The per-cell
/// evaluation semantics live in `frame`'s `str_ops_test.mbt`.

///|
test "str: every namespace method renders as a postfix call" {
  inspect(col("s").str_to_uppercase(), content="col(s).str_to_uppercase()")
  inspect(col("s").str_to_lowercase(), content="col(s).str_to_lowercase()")
  inspect(col("s").str_strip_chars(), content="col(s).str_strip_chars()")
  inspect(col("s").str_len_chars(), content="col(s).str_len_chars()")
  inspect(col("s").str_contains("a"), content="col(s).str_contains(\"a\")")
  inspect(
    col("s").str_starts_with("a"),
    content="col(s).str_starts_with(\"a\")",
  )
  inspect(col("s").str_ends_with("z"), content="col(s).str_ends_with(\"z\")")
  inspect(
    col("s").str_replace("a", "b"),
    content="col(s).str_replace(\"a\", \"b\")",
  )
  inspect(
    col("s").str_replace_all("a", "b"),
    content="col(s).str_replace_all(\"a\", \"b\")",
  )
}

///|
test "str: a parameter is quoted and escaped like a string literal" {
  // Each argument escapes `"` / `\` / control characters so a plan line stays
  // unambiguous and on one line — the same rule `write_scalar` applies to a
  // `lit_str`.
  inspect(
    col("s").str_contains("a\"b"),
    content="col(s).str_contains(\"a\\\"b\")",
  )
  inspect(
    col("s").str_replace("x\n", "\t"),
    content="col(s).str_replace(\"x\\n\", \"\\t\")",
  )
}

///|
test "str: structural equality compares the op tag and the operand" {
  // Same op + same operand → equal.
  assert_eq(col("s").str_to_uppercase(), col("s").str_to_uppercase())
  assert_eq(col("s").str_contains("a"), col("s").str_contains("a"))
  // A differing operation, a differing literal argument, or a differing
  // operand each breaks equality — `Contains("a")` and `Contains("b")` are
  // distinct tags.
  assert_eq(col("s").str_to_uppercase() == col("s").str_to_lowercase(), false)
  assert_eq(col("s").str_contains("a") == col("s").str_contains("b"), false)
  assert_eq(col("s").str_to_uppercase() == col("t").str_to_uppercase(), false)
}

///|
test "str: children, naming, and column references see through the wrapper" {
  // A `Str` node exposes its single operand, and both naming and reference
  // collection treat it transparently — the operation keeps the source
  // column's name unless an alias overrides it.
  assert_eq(col("s").str_to_uppercase().children(), [col("s")])
  assert_eq(col("s").str_contains("a").children(), [col("s")])
  assert_eq(col("s").str_to_uppercase().output_name(), "s")
  assert_eq(col("s").str_to_uppercase().with_alias("up").output_name(), "up")
  assert_eq(col("s").str_replace("a", "b").referenced_columns().to_array(), [
    "s",
  ])
}
