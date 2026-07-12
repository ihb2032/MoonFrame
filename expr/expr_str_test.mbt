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
  inspect(col("s").str_reverse(), content="col(s).str_reverse()")
  // The pad width renders bare, the fill as a `'x'` char literal; a defaulted
  // `str_pad_end` carries the space fill.
  inspect(
    col("s").str_pad_start(5, fill='0'),
    content="col(s).str_pad_start(5, '0')",
  )
  inspect(col("s").str_pad_end(5), content="col(s).str_pad_end(5, ' ')")
  inspect(
    col("s").str_contains_regex("a.c"),
    content="col(s).str_contains_regex(\"a.c\")",
  )
  inspect(
    col("s").str_replace_regex("a", "b"),
    content="col(s).str_replace_regex(\"a\", \"b\")",
  )
  inspect(
    col("s").str_replace_all_regex("a", "b"),
    content="col(s).str_replace_all_regex(\"a\", \"b\")",
  )
  // The pattern renders quoted, the group index bare (default 0 shown).
  inspect(
    col("s").str_extract("[0-9]+"),
    content="col(s).str_extract(\"[0-9]+\", 0)",
  )
  inspect(
    col("s").str_extract("(a)", group=1),
    content="col(s).str_extract(\"(a)\", 1)",
  )
  inspect(
    col("s").str_count_matches("x"),
    content="col(s).str_count_matches(\"x\")",
  )
}

///|
test "str: a parameter is quoted and escaped like a string literal" {
  // Each argument escapes `"` / `\` / control characters so a plan line stays
  // unambiguous and on one line — the same rule a rendered `lit_str` follows
  // (`@types.format_scalar_literal`).
  inspect(
    col("s").str_contains("a\"b"),
    content="col(s).str_contains(\"a\\\"b\")",
  )
  inspect(
    col("s").str_replace("x\n", "\t"),
    content="col(s).str_replace(\"x\\n\", \"\\t\")",
  )
  // A control fill character escapes the same way inside the char literal.
  inspect(
    col("s").str_pad_start(3, fill='\t'),
    content="col(s).str_pad_start(3, '\\t')",
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
  // The parameterised pad tag distinguishes on both width and fill.
  assert_eq(
    col("s").str_pad_start(3, fill='0'),
    col("s").str_pad_start(3, fill='0'),
  )
  assert_eq(
    col("s").str_pad_start(3, fill='0') == col("s").str_pad_start(4, fill='0'),
    false,
  )
  assert_eq(
    col("s").str_pad_start(3, fill='0') == col("s").str_pad_start(3, fill='x'),
    false,
  )
  assert_eq(col("s").str_reverse() == col("s").str_to_uppercase(), false)
  // A regex op is distinct from its literal namesake and from a differing
  // pattern.
  assert_eq(col("s").str_contains_regex("a"), col("s").str_contains_regex("a"))
  assert_eq(
    col("s").str_contains_regex("a") == col("s").str_contains_regex("b"),
    false,
  )
  assert_eq(
    col("s").str_contains_regex("a") == col("s").str_contains("a"),
    false,
  )
  // `Extract` distinguishes on both pattern and group index.
  assert_eq(
    col("s").str_extract("a", group=1),
    col("s").str_extract("a", group=1),
  )
  assert_eq(
    col("s").str_extract("a", group=1) == col("s").str_extract("a", group=2),
    false,
  )
  assert_eq(col("s").str_extract("a") == col("s").str_extract("b"), false)
  assert_eq(
    col("s").str_count_matches("a") == col("s").str_count_matches("b"),
    false,
  )
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
