// Blackbox tests for `JoinType` / `JoinOptions`.
//
// `JoinOptions`' fields are private outside the package, so these tests pin
// the three constructors' defaults and their named overrides *through the
// derived `Eq`* — e.g. naming a parameter with its default value must yield a
// value equal to the bare call, while a non-default must not. The end-to-end
// join behaviour they imply (inner default, `"_right"` suffix) is exercised
// against real frames in `join_test.mbt`.

///|
test "JoinType equality" {
  assert_eq(JoinType::Inner, JoinType::Inner)
  assert_eq(JoinType::Right, JoinType::Right)
  assert_eq(JoinType::Outer, JoinType::Outer)
  assert_not_eq(JoinType::Inner, JoinType::Left)
  assert_not_eq(JoinType::Inner, JoinType::Cross)
  assert_not_eq(JoinType::Left, JoinType::Cross)
  // The two v0.3 additions are distinct from each other and the v0.2 set.
  assert_not_eq(JoinType::Inner, JoinType::Right)
  assert_not_eq(JoinType::Inner, JoinType::Outer)
  assert_not_eq(JoinType::Left, JoinType::Right)
  assert_not_eq(JoinType::Right, JoinType::Outer)
  assert_not_eq(JoinType::Outer, JoinType::Cross)
}

///|
test "cross builds a keyless Cross spec" {
  // `cross()` is `on([])` switched to `how = Cross` (same default suffix /
  // coalesce), and differs from a keyed inner spec.
  assert_eq(JoinOptions::cross(), JoinOptions::on([], how=JoinType::Cross))
  assert_not_eq(JoinOptions::cross(), JoinOptions::on([]))
  assert_not_eq(JoinOptions::cross(), JoinOptions::on([@expr.col("id")]))
  // The suffix is the one knob a cross join still honours.
  assert_eq(
    JoinOptions::cross(suffix="_r"),
    JoinOptions::on([], how=JoinType::Cross, suffix="_r"),
  )
  assert_not_eq(JoinOptions::cross(suffix="_r"), JoinOptions::cross())
}

///|
test "on / left_on copy their key arrays" {
  // Mutating the caller's array after building the options must not alter
  // the join specification (pinned through the derived `Eq`).
  let keys = [@expr.col("id")]
  let base = JoinOptions::on(keys)
  keys.push(@expr.col("v"))
  assert_eq(base, JoinOptions::on([@expr.col("id")]))
  let lkeys = [@expr.col("a")]
  let rkeys = [@expr.col("b")]
  let both = JoinOptions::left_on(lkeys, right_on=rkeys)
  lkeys.clear()
  rkeys.push(@expr.col("c"))
  assert_eq(
    both,
    JoinOptions::left_on([@expr.col("a")], right_on=[@expr.col("b")]),
  )
}

///|
test "on defaults to an inner join with the _right suffix and auto coalesce" {
  let base = JoinOptions::on([@expr.col("id")])
  // Naming the defaults explicitly must reproduce the same options.
  assert_eq(JoinOptions::on([@expr.col("id")], how=JoinType::Inner), base)
  assert_eq(JoinOptions::on([@expr.col("id")], suffix="_right"), base)
  // A non-default value must differ, on each knob independently.
  assert_not_eq(JoinOptions::on([@expr.col("id")], how=JoinType::Left), base)
  assert_not_eq(JoinOptions::on([@expr.col("id")], suffix="_r"), base)
  assert_not_eq(JoinOptions::on([@expr.col("id")], coalesce=true), base)
  assert_not_eq(JoinOptions::on([@expr.col("id")], coalesce=false), base)
  // The two forced coalesce values are distinct from each other, so an
  // omitted `coalesce` is a third (automatic) state rather than a default.
  assert_not_eq(
    JoinOptions::on([@expr.col("id")], coalesce=true),
    JoinOptions::on([@expr.col("id")], coalesce=false),
  )
}

///|
test "the on knobs are independent of each other" {
  // Setting one leaves the others at their defaults, so any subset can be
  // named in any order and still describe the same options.
  assert_eq(
    JoinOptions::on([@expr.col("id")], how=JoinType::Left, suffix="_r"),
    JoinOptions::on([@expr.col("id")], suffix="_r", how=JoinType::Left),
  )
  assert_eq(
    JoinOptions::on([@expr.col("id")], suffix="_r"),
    JoinOptions::on([@expr.col("id")], how=JoinType::Inner, suffix="_r"),
  )
  assert_eq(
    JoinOptions::on([@expr.col("id")], how=JoinType::Left, coalesce=true),
    JoinOptions::on([@expr.col("id")], coalesce=true, how=JoinType::Left),
  )
}

///|
test "on carries the key list (distinct key sets give distinct options)" {
  assert_eq(
    JoinOptions::on([@expr.col("a"), @expr.col("b")]),
    JoinOptions::on([@expr.col("a"), @expr.col("b")]),
  )
  assert_not_eq(
    JoinOptions::on([@expr.col("a"), @expr.col("b")]),
    JoinOptions::on([@expr.col("b"), @expr.col("a")]),
  )
  assert_not_eq(
    JoinOptions::on([@expr.col("a")]),
    JoinOptions::on([@expr.col("a"), @expr.col("b")]),
  )
  // A derived key is a distinct option from the bare column it builds on.
  assert_not_eq(
    JoinOptions::on([@expr.col("a") * @expr.lit_int(2)]),
    JoinOptions::on([@expr.col("a")]),
  )
}

///|
test "left_on pairs both sides at once, defaults matching on" {
  let sided = JoinOptions::left_on([@expr.col("a")], right_on=[@expr.col("b")])
  // Same defaults as `on` (inner, `_right` suffix, coalesce auto).
  assert_eq(
    JoinOptions::left_on(
      [@expr.col("a")],
      right_on=[@expr.col("b")],
      how=JoinType::Inner,
    ),
    sided,
  )
  assert_eq(
    JoinOptions::left_on(
      [@expr.col("a")],
      right_on=[@expr.col("b")],
      suffix="_right",
    ),
    sided,
  )
  // A sided join keyed left=a / right=b is distinct from an `on([a])` join
  // (different key plumbing) and from the same keys swapped.
  assert_not_eq(sided, JoinOptions::on([@expr.col("a")]))
  assert_not_eq(
    sided,
    JoinOptions::left_on([@expr.col("b")], right_on=[@expr.col("a")]),
  )
  // Each side is carried independently, and the knobs behave as on `on`.
  assert_not_eq(
    sided,
    JoinOptions::left_on([@expr.col("a")], right_on=[@expr.col("x")]),
  )
  assert_not_eq(
    sided,
    JoinOptions::left_on(
      [@expr.col("a")],
      right_on=[@expr.col("b")],
      how=JoinType::Left,
    ),
  )
}
