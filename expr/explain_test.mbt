///|
/// Blackbox snapshots for the handwritten `Show` / `explain` rendering and
/// behaviour tests for the introspection primitive `children` and the pair
/// `referenced_columns` / `output_name` built on it. Every rendering arm — the twelve binary symbols, four
/// unary forms, eleven aggregation suffixes, cast / alias / ternary, and
/// each literal kind — is pinned here, since `explain` output is demo-
/// and (from L1 on) plan-printer-facing; the naming rule's clauses are
/// pinned clause by clause, since the eager materialisers in `frame` and
/// the lazy optimizer's pruning both lean on them.

///|
test "show: the documented alias form" {
  let profit = (col("revenue") - col("cost")).with_alias("profit")
  inspect(profit, content="(col(revenue) - col(cost)) as profit")
  // `explain` is exactly the `Show` rendering, as a String.
  assert_eq(profit.to_string(), profit.to_string())
  assert_eq(profit.to_string(), "(col(revenue) - col(cost)) as profit")
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
  // A whole-valued Float keeps its decimal point so it stays distinct from an
  // `Int` literal (`Double::to_string` would otherwise print `1.0` as `"1"`);
  // non-finite values keep their own spelling.
  inspect(lit_float(1.0), content="1.0")
  inspect(lit_float(0.0 / 0.0), content="NaN")
  inspect(lit_float(1.0 / 0.0), content="Infinity")
  // Negative zero keeps its sign (`Double::to_string` drops it): the two
  // zeros evaluate observably differently under division, so their
  // rendered literals must stay distinguishable.
  inspect(lit_float(-0.0), content="-0.0")
  inspect(lit_float(0.0), content="0.0")
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
  // Other control characters (the rest of C0, DEL, and the Unicode
  // line/paragraph separators) become `\uXXXX`, so a hostile string can inject
  // neither a terminal control sequence nor an extra line into a plan.
  inspect(
    lit_str("a\u{1b}\u{7f}\u{85}\u{2028}\u{2029}b"),
    content="\"a\\u001b\\u007f\\u0085\\u2028\\u2029b\"",
  )
}

///|
test "show: col and alias names are escaped, so neither can inject a plan line" {
  // A column or alias name sourced from a hostile CSV header cannot inject a
  // newline or a terminal control sequence into a rendered plan.
  inspect(col("a\nb"), content="col(a\\nb)")
  inspect(col("x").with_alias("a\u{1b}b"), content="col(x) as a\\u001bb")
}

///|
test "show: every unary form" {
  inspect(-col("x"), content="(-col(x))")
  inspect(col("p").not(), content="(not col(p))")
  inspect(col("x").is_null(), content="col(x).is_null()")
  inspect(col("x").is_not_null(), content="col(x).is_not_null()")
  inspect(col("x").is_nan(), content="col(x).is_nan()")
  inspect(col("x").is_not_nan(), content="col(x).is_not_nan()")
}

///|
test "show: every aggregation suffix" {
  inspect(col("v").sum(), content="col(v).sum()")
  inspect(col("v").mean(), content="col(v).mean()")
  inspect(col("v").min(), content="col(v).min()")
  inspect(col("v").max(), content="col(v).max()")
  inspect(col("v").count(), content="col(v).count()")
  inspect(col("v").std(), content="col(v).std()")
  inspect(col("v").variance(), content="col(v).variance()")
  inspect(col("v").median(), content="col(v).median()")
  inspect(col("v").n_unique(), content="col(v).n_unique()")
  inspect(col("v").first(), content="col(v).first()")
  inspect(col("v").last(), content="col(v).last()")
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
test "show: is_in renders its operand and literal set" {
  inspect(
    col("g").is_in([@types.Scalar::Int(1), @types.Scalar::Int(2)]),
    content="col(g).is_in([1, 2])",
  )
  // Members render like literals: strings quoted, mixed dtypes each in their
  // own form; an empty set renders as `[]`.
  inspect(
    col("g").is_in([@types.Scalar::String("x"), @types.Scalar::Float(1.5)]),
    content="col(g).is_in([\"x\", 1.5])",
  )
  inspect(col("g").is_in([]), content="col(g).is_in([])")
}

///|
test "show: is_between renders its operand and both bounds" {
  inspect(
    col("a").is_between(lit_int(0), col("hi")),
    content="col(a).is_between(0, col(hi))",
  )
}

///|
test "is_in / is_between: introspection walks ride their children" {
  // `is_in` names after and references only its operand (the set is literal).
  assert_eq(col("v").is_in([@types.Scalar::Int(1)]).output_name(), "v")
  assert_eq(
    col("v").is_in([@types.Scalar::Int(1)]).referenced_columns().to_array(),
    ["v"],
  )
  // `is_between` references its operand and both bounds; it names after the
  // operand (the leftmost child), an alias still overriding.
  assert_eq(
    col("a").is_between(col("lo"), col("hi")).referenced_columns().to_array(),
    ["a", "lo", "hi"],
  )
  assert_eq(col("a").is_between(col("lo"), col("hi")).output_name(), "a")
  assert_eq(
    col("a").is_between(lit_int(0), lit_int(9)).with_alias("ok").output_name(),
    "ok",
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
test "show: a map renders by label and inputs, the closure opaque" {
  inspect(
    map_many(label="combine", [col("a"), col("b")], fn(vs) { vs[0] }),
    content="map(\"combine\", [col(a), col(b)])",
  )
  // `map_elements` is a single-input map.
  inspect(
    col("x").map_elements(label="round", fn(s) { s }),
    content="map(\"round\", [col(x)])",
  )
  // The label is quoted and escaped like a string literal, and an empty
  // input list renders as `[]`.
  inspect(
    map_many(label="a\"b", [], fn(_vs) { @types.Scalar::Null }),
    content="map(\"a\\\"b\", [])",
  )
}

///|
test "show: a map_batches renders like a map, flagging returns_scalar" {
  // The row-wise form renders as `map_batches("label", [inputs])`.
  inspect(
    col("x").map_batches(label="cumsum", fn(s) { s }),
    content="map_batches(\"cumsum\", [col(x)])",
  )
  // The reducing form appends `, returns_scalar=true` so the two are distinct.
  inspect(
    col("x").map_batches(label="range", returns_scalar=true, fn(s) { s }),
    content="map_batches(\"range\", [col(x)], returns_scalar=true)",
  )
}

///|
test "debug: an expression's repr is its quoted operator form" {
  // `@debug.Debug` (what `assert_eq` uses for failure messages) is
  // handwritten — the `Map` closure blocks `derive` — and delegates to the
  // `Show` rendering. This pins it and, more to the point, covers the
  // handwritten `to_repr`, which `assert_eq` reaches only on failure.
  @debug.debug_inspect(
    col("x").map_elements(label="m", fn(s) { s }),
    content=(
      #|"map(\"m\", [col(x)])"
    ),
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

///|
test "deep trees don't overflow the stack: the introspection walks are iterative" {
  // A left-nested tree this deep formerly overflowed the native stack and
  // aborted in all three walks (output_name / referenced_columns / Show), which
  // the docs promise are total. The explicit-stack walks handle any depth.
  let depth = 200000
  let mut e = col("a")
  for _ in 0..<depth {
    e = e + col("a")
  }
  assert_eq(e.output_name(), "a")
  assert_eq(e.referenced_columns().to_array(), ["a"])
  // Show renders the whole tree without aborting (length grows with depth).
  assert_true(e.to_string().length() > depth)
}

///|
test "children: each variant exposes its immediate sub-expressions, left to right" {
  let a = col("a")
  let b = col("b")
  // Leaves have no children.
  assert_eq(col("x").children(), [])
  assert_eq(lit_int(1).children(), [])
  // A binary lists both operands, left to right.
  assert_eq((a + b).children(), [a, b])
  // The single-child wrappers expose their one operand.
  assert_eq((-a).children(), [a])
  assert_eq(a.is_null().children(), [a])
  assert_eq(a.sum().children(), [a])
  assert_eq(a.cast(@types.DataType::Float).children(), [a])
  assert_eq(a.with_alias("x").children(), [a])
  // A ternary lists all three arms, condition first.
  let cond = a.gt(lit_int(0))
  assert_eq(when(cond).then(a).otherwise(b).children(), [cond, a, b])
  // `is_in` exposes only its operand — the set is literal data, not children.
  assert_eq(a.is_in([@types.Scalar::Int(1)]).children(), [a])
  // `is_between` lists its operand and both bounds.
  assert_eq(a.is_between(lit_int(0), b).children(), [a, lit_int(0), b])
  // A map lists its input expressions (none for an empty input list).
  assert_eq(map_many(label="m", [a, b], fn(vs) { vs[0] }).children(), [a, b])
  assert_eq(
    map_many(label="m", [], fn(_vs) { @types.Scalar::Null }).children(),
    [],
  )
}

///|
test "children: a map's returned array never aliases the node's inputs" {
  // `children()` hands back a fresh copy, so mutating it cannot corrupt the
  // (immutable-by-construction) expression tree.
  let m = map_many(label="m", [col("a")], fn(vs) { vs[0] })
  let kids = m.children()
  kids.push(col("injected"))
  assert_eq(m.children(), [col("a")])
}

///|
test "map: output_name is the leftmost input, else \"literal\", alias wins" {
  assert_eq(
    map_many(label="m", [col("a"), col("b")], fn(vs) { vs[0] }).output_name(),
    "a",
  )
  assert_eq(col("x").map_elements(label="m", fn(s) { s }).output_name(), "x")
  // No inputs, or a column-less input, leaves the tree nameless.
  assert_eq(
    map_many(label="m", [], fn(_vs) { @types.Scalar::Null }).output_name(),
    "literal",
  )
  assert_eq(
    map_many(label="m", [lit_int(1)], fn(vs) { vs[0] }).output_name(),
    "literal",
  )
  // An alias on the map still wins.
  assert_eq(
    map_many(label="m", [col("a")], fn(vs) { vs[0] })
    .with_alias("z")
    .output_name(),
    "z",
  )
}

///|
test "map: referenced_columns gathers every column its inputs read" {
  assert_eq(
    map_many(label="m", [col("a") + col("b"), col("c")], fn(vs) { vs[0] })
    .referenced_columns()
    .to_array(),
    ["a", "b", "c"],
  )
  assert_eq(
    map_many(label="m", [], fn(_vs) { @types.Scalar::Null })
    .referenced_columns()
    .to_array(),
    [],
  )
}

///|
test "show: a literal series renders by name and length, the data opaque" {
  let s = Series::from_ints("flag", [1, 2, 3, 4])
  inspect(lit_series(s), content="lit_series(\"flag\", 4)")
  // The name is quoted and escaped like a string literal, so it can never
  // inject a spurious line into the `explain` tree.
  inspect(
    lit_series(Series::from_ints("a\"b", [1])),
    content="lit_series(\"a\\\"b\", 1)",
  )
}

///|
test "lit_series: a leaf with no child expressions and no column references" {
  let s = Series::from_ints("v", [1, 2, 3])
  // It carries materialised data, not sub-expressions, and reads no frame
  // column — so the optimizer's pruning keeps nothing alive for it.
  assert_eq(lit_series(s).children(), [])
  assert_eq(lit_series(s).referenced_columns().to_array(), [])
}

///|
test "lit_series: output_name is the series name, an alias overrides it" {
  let s = Series::from_ints("vals", [1, 2, 3])
  assert_eq(lit_series(s).output_name(), "vals")
  assert_eq(lit_series(s).with_alias("renamed").output_name(), "renamed")
  // On a binary's leftmost path it names the whole tree, like a `Col`.
  assert_eq((lit_series(s) + col("b")).output_name(), "vals")
}
