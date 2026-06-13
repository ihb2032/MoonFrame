///|
/// Blackbox snapshots for the handwritten `Show` / `explain` rendering and
/// behaviour tests for the introspection pair `referenced_columns` /
/// `output_name`. Every rendering arm — the twelve binary symbols, four
/// unary forms, five aggregation suffixes, cast / alias / ternary, and
/// each literal kind — is pinned here, since `explain` output is demo-
/// and (from L1 on) plan-printer-facing; the naming rule's clauses are
/// pinned clause by clause, since the eager materialisers in `frame` and
/// the lazy optimizer's pruning both lean on them.

///|
test "show: the documented alias form" {
  let profit = (col("revenue") - col("cost")).with_alias("profit")
  inspect(profit, content="(col(revenue) - col(cost)) as profit")
  // `explain` is exactly the `Show` rendering, as a String.
  assert_eq(profit.explain(), profit.to_string())
  assert_eq(profit.explain(), "(col(revenue) - col(cost)) as profit")
}

///|
test "show: every binary operator symbol" {
  let a = col("a")
  let b = col("b")
  inspect(a + b, content="(col(a) + col(b))")
  inspect(a - b, content="(col(a) - col(b))")
  inspect(a * b, content="(col(a) * col(b))")
  inspect(a / b, content="(col(a) / col(b))")
  inspect(a.eq(b), content="(col(a) == col(b))")
  inspect(a.ne(b), content="(col(a) != col(b))")
  inspect(a.lt(b), content="(col(a) < col(b))")
  inspect(a.le(b), content="(col(a) <= col(b))")
  inspect(a.gt(b), content="(col(a) > col(b))")
  inspect(a.ge(b), content="(col(a) >= col(b))")
  inspect(a & b, content="(col(a) & col(b))")
  inspect(a | b, content="(col(a) | col(b))")
}

///|
test "show: every literal kind" {
  inspect(lit_int(42), content="42")
  inspect(lit_float(1.5), content="1.5")
  inspect(lit_str("west"), content="\"west\"")
  inspect(lit_bool(true), content="true")
  inspect(lit(@types.Scalar::Null), content="null")
}

///|
test "show: a string literal escapes embedded quotes and backslashes" {
  // The quoted literal form escapes `"` / `\` so a literal stays
  // distinguishable and unambiguous in `explain` output.
  inspect(lit_str("a\"b\\c"), content="\"a\\\"b\\\\c\"")
}

///|
test "show: a string literal escapes control characters" {
  // Control characters become `\n` / `\r` / `\t` so a literal can never
  // inject a spurious line into the `explain` tree.
  inspect(lit_str("a\nb\tc\rd"), content="\"a\\nb\\tc\\rd\"")
}

///|
test "show: every unary form" {
  inspect(-col("x"), content="(-col(x))")
  inspect(col("p").not(), content="(not col(p))")
  inspect(col("x").is_null(), content="col(x).is_null()")
  inspect(col("x").is_not_null(), content="col(x).is_not_null()")
}

///|
test "show: every aggregation suffix" {
  inspect(col("v").sum(), content="col(v).sum()")
  inspect(col("v").mean(), content="col(v).mean()")
  inspect(col("v").min(), content="col(v).min()")
  inspect(col("v").max(), content="col(v).max()")
  inspect(col("v").count(), content="col(v).count()")
}

///|
test "show: cast renders the target dtype" {
  inspect(col("x").cast(@types.DataType::Float), content="col(x).cast(Float)")
}

///|
test "show: ternary mirrors its construction chain" {
  inspect(
    when(col("s").ge(lit_int(60)))
    .then(lit_str("pass"))
    .otherwise(lit_str("fail")),
    content="when((col(s) >= 60)).then(\"pass\").otherwise(\"fail\")",
  )
}

///|
test "show: deep nesting stays fully parenthesised" {
  inspect(
    (col("a") + col("b")) * (col("c") - lit_int(1)),
    content="((col(a) + col(b)) * (col(c) - 1))",
  )
}

///|
test "referenced_columns: depth-first, first-reference order, deduplicated" {
  let cols = ((col("revenue") - col("cost")) / col("revenue"))
    .with_alias("margin")
    .referenced_columns()
    .to_array()
  assert_eq(cols, ["revenue", "cost"])
}

///|
test "referenced_columns: a pure-literal tree references nothing" {
  assert_eq((lit_int(1) + lit_float(0.5)).referenced_columns().to_array(), [])
}

///|
test "referenced_columns: a ternary's condition counts" {
  // Unlike output naming, pushdown must keep condition columns alive.
  let cols = when(col("c").gt(lit_int(0)))
    .then(col("t"))
    .otherwise(col("f"))
    .referenced_columns()
    .to_array()
  assert_eq(cols, ["c", "t", "f"])
}

///|
test "referenced_columns: wrappers are transparent" {
  assert_eq((-col("x")).referenced_columns().to_array(), ["x"])
  assert_eq(
    col("x").sum().cast(@types.DataType::Float).referenced_columns().to_array(),
    ["x"],
  )
  assert_eq(col("x").is_null().referenced_columns().to_array(), ["x"])
}

///|
test "output_name: an alias wins anywhere on the naming path" {
  assert_eq((col("a") + col("b")).with_alias("net").output_name(), "net")
  // A nested alias on the leftmost path outranks the column beneath it.
  assert_eq((col("a").with_alias("x") + col("b")).output_name(), "x")
}

///|
test "output_name: otherwise the leftmost column reference names the tree" {
  assert_eq((col("a") + col("b")).output_name(), "a")
  // A literal left arm is nameless, so the right arm gets to name it.
  assert_eq((lit_int(1) + col("b")).output_name(), "b")
}

///|
test "output_name: unary, aggregation, and cast wrappers are transparent" {
  assert_eq((-col("a")).output_name(), "a")
  assert_eq(col("a").sum().output_name(), "a")
  assert_eq(col("a").cast(@types.DataType::Float).output_name(), "a")
}

///|
test "output_name: ternary names from then, falls back to otherwise, never the condition" {
  let cond = col("c").gt(lit_int(0))
  assert_eq(when(cond).then(col("t")).otherwise(col("f")).output_name(), "t")
  assert_eq(when(cond).then(lit_int(1)).otherwise(col("f")).output_name(), "f")
  assert_eq(
    when(cond).then(lit_int(1)).otherwise(lit_int(0)).output_name(),
    "literal",
  )
}

///|
test "output_name: a column-less tree falls back to \"literal\"" {
  assert_eq(lit_int(42).output_name(), "literal")
  assert_eq((lit_int(1) + lit_float(0.5)).output_name(), "literal")
}
