// Blackbox tests for `JoinType` / `JoinOptions`.
//
// `JoinOptions`' fields are private outside the package, so these tests
// pin the constructor defaults and the `with_*` overrides *through the
// derived `Eq`* — e.g. re-setting a field to its default must yield a
// value equal to the bare `on(...)`, while setting it to a non-default
// must not. The end-to-end join behaviour they imply (inner default,
// `"_right"` suffix) is exercised against real frames in `join_test.mbt`.

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
  assert_eq(JoinOptions::cross(), JoinOptions::on([]).with_how(JoinType::Cross))
  assert_not_eq(JoinOptions::cross(), JoinOptions::on([]))
  assert_not_eq(JoinOptions::cross(), JoinOptions::on([@expr.col("id")]))
}

///|
test "on defaults to an inner join with the _right suffix" {
  let base = JoinOptions::on([@expr.col("id")])
  // Re-stating the defaults explicitly must reproduce the same options.
  assert_eq(base.with_how(JoinType::Inner), base)
  assert_eq(base.with_suffix("_right"), base)
  // A non-default value must differ.
  assert_not_eq(base.with_how(JoinType::Left), base)
  assert_not_eq(base.with_suffix("_r"), base)
}

///|
test "with_how overrides the join type, last write wins" {
  let base = JoinOptions::on([@expr.col("id")])
  assert_eq(base.with_how(JoinType::Left).with_how(JoinType::Inner), base)
  assert_eq(
    base.with_how(JoinType::Left),
    base.with_how(JoinType::Inner).with_how(JoinType::Left),
  )
}

///|
test "with_suffix overrides the suffix, last write wins" {
  let base = JoinOptions::on([@expr.col("id")])
  assert_eq(base.with_suffix("_x").with_suffix("_right"), base)
  assert_eq(base.with_suffix("_a"), base.with_suffix("_b").with_suffix("_a"))
}

///|
test "with_how and with_suffix are independent" {
  let base = JoinOptions::on([@expr.col("id")])
  // Setting how leaves the (default) suffix intact, and vice versa, so the
  // two orders of application agree.
  assert_eq(
    base.with_how(JoinType::Left).with_suffix("_r"),
    base.with_suffix("_r").with_how(JoinType::Left),
  )
  // Changing only the suffix keeps how at its inner default.
  assert_eq(
    base.with_suffix("_r"),
    base.with_suffix("_r").with_how(JoinType::Inner),
  )
}

///|
test "with_coalesce forces the coalesce flag, last write wins" {
  let base = JoinOptions::on([@expr.col("id")])
  // The bare `on` leaves coalesce auto (None), distinct from either forced
  // value, and the two forced values differ from each other.
  assert_not_eq(base.with_coalesce(true), base)
  assert_not_eq(base.with_coalesce(false), base)
  assert_not_eq(base.with_coalesce(true), base.with_coalesce(false))
  // Last write wins, and it is independent of how / suffix.
  assert_eq(
    base.with_coalesce(false).with_coalesce(true),
    base.with_coalesce(true),
  )
  assert_eq(
    base.with_how(JoinType::Left).with_coalesce(true),
    base.with_coalesce(true).with_how(JoinType::Left),
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
test "left_on / with_right_on build a sided spec, defaults matching on" {
  let sided = JoinOptions::left_on([@expr.col("a")]).with_right_on([
    @expr.col("b"),
  ])
  // Same defaults as `on` (inner, `_right` suffix, coalesce auto).
  assert_eq(sided.with_how(JoinType::Inner), sided)
  assert_eq(sided.with_suffix("_right"), sided)
  // A sided join keyed left=a / right=b is distinct from an `on([a])` join
  // (different key plumbing) and from the same keys swapped.
  assert_not_eq(sided, JoinOptions::on([@expr.col("a")]))
  assert_not_eq(
    sided,
    JoinOptions::left_on([@expr.col("b")]).with_right_on([@expr.col("a")]),
  )
  // `with_right_on` last write wins, and it leaves left_on / how intact.
  assert_eq(
    JoinOptions::left_on([@expr.col("a")])
    .with_right_on([@expr.col("x")])
    .with_right_on([@expr.col("b")]),
    sided,
  )
  assert_eq(
    sided.with_how(JoinType::Left),
    JoinOptions::left_on([@expr.col("a")])
    .with_how(JoinType::Left)
    .with_right_on([@expr.col("b")]),
  )
}
