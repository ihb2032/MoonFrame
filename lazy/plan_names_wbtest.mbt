// The output-name walk, arm by arm: every `FrameOp` member and plan node
// names its output exactly or gives up (`None`), and the joins read the
// answer for attribution — so each arm's set is pinned here, including the
// give-ups. Package-private (`output_names`), like the walk it tests.

///|
/// Frames through `io`, so no `series` import is needed (the `lazy` package
/// imports it only for `test`).
fn names_frame() -> @frame.DataFrame raise @types.DataError {
  @io.parse_csv_str("a,b,c\n1,4,7\n2,5,8\n3,6,9")
}

///|
/// The right-side twin sharing the `a` column (a name clash for the suffix
/// rule) and adding `d`.
fn names_other() -> @frame.DataFrame raise @types.DataError {
  @io.parse_csv_str("a,d\n1,10\n2,20\n3,30")
}

///|
/// Assert a plan's name set is exactly `expected`; a separate assertion
/// covers the `None` give-ups, so this one refusing a `None` is the point.
fn assert_output_names(plan : LogicalPlan, expected : Array[String]) -> Unit {
  guard plan.output_names() is Some(names) else {
    abort("expected a known name set, got None")
  }
  let want = @set.Set(expected)
  names.each(name => {
    if !want.contains(name) {
      abort("unexpected name \{name}")
    }
  })
  want.each(name => if !names.contains(name) { abort("missing name \{name}") })
}

///|
test "output_names: the in-memory scan names its frame's columns" {
  assert_output_names(LazyFrame::LazyFrame(names_frame()).plan, ["a", "b", "c"])
}

///|
test "output_names: a file source's header is not statically knowable" {
  // `scan_csv` builds the deferred file scan without reading anything, so
  // no file needs to exist for its name set to read `None`.
  let scanned = scan_csv("names.csv")
  assert_true(scanned.plan.output_names() is None)
}

///|
test "output_names: a selection outputs its expressions' names" {
  let plan = LazyFrame::LazyFrame(names_frame()).select([
      @expr.col("a"),
      (@expr.col("b") * @expr.lit_int(2)).with_alias("dbl"),
    ]).plan
  assert_output_names(plan, ["a", "dbl"])
}

///|
test "output_names: with_columns keeps its input and adds what it defines" {
  let plan = LazyFrame::LazyFrame(names_frame()).with_columns([
      (@expr.col("a") + @expr.lit_int(1)).with_alias("d"),
    ]).plan
  assert_output_names(plan, ["a", "b", "c", "d"])
}

///|
test "output_names: the row verbs pass their input's names through" {
  let base = LazyFrame::LazyFrame(names_frame())
  let gate = @expr.col("a").gt(@expr.lit_int(1))
  let pass_through : Array[LogicalPlan] = [
    base.filter(gate).plan,
    base.sort([(@expr.col("b"), true, false)]).plan,
    base.head(2).plan,
    base.tail(2).plan,
    base.slice(1, length=1).plan,
    base.gather_every(2).plan,
    base.top_k(2, by=[@expr.col("b")]).plan,
    base.bottom_k(2, by=[@expr.col("b")]).plan,
    base.unique().plan,
    base.reverse().plan,
    base.drop_nulls().plan,
    base.fill_null(@types.Scalar::Int(0)).plan,
    base.fill_null_forward().plan,
    base.fill_nan(0.0).plan,
  ]
  for plan in pass_through {
    assert_output_names(plan, ["a", "b", "c"])
  }
}

///|
test "output_names: drop removes the named columns" {
  let plan = LazyFrame::LazyFrame(names_frame()).drop([@expr.col("b")]).plan
  assert_output_names(plan, ["a", "c"])
}

///|
test "output_names: rename applies its pairs" {
  let plan = LazyFrame::LazyFrame(names_frame()).rename([("a", "x")]).plan
  assert_output_names(plan, ["x", "b", "c"])
}

///|
test "output_names: rename_with runs its closure on the real names" {
  let plan = LazyFrame::LazyFrame(names_frame()).rename_with(name => name + "_c").plan
  assert_output_names(plan, ["a_c", "b_c", "c_c"])
}

///|
test "output_names: with_row_index adds the index column" {
  let plan = LazyFrame::LazyFrame(names_frame()).with_row_index(name="idx").plan
  assert_output_names(plan, ["a", "b", "c", "idx"])
}

///|
test "output_names: the reshapes and the reduction give up" {
  let base = LazyFrame::LazyFrame(names_frame())
  assert_true(
    base.pivot(on=[@expr.col("a")], index=[@expr.col("b")]).plan.output_names()
    is None,
  )
  assert_true(
    base.unpivot(on=[@expr.col("a")], index=[@expr.col("b")]).plan.output_names()
    is None,
  )
  assert_true(base.sum().plan.output_names() is None)
}

///|
test "output_names: an aggregation outputs its keys and cells" {
  let plan = LazyFrame::LazyFrame(names_frame())
    .group_by([@expr.col("a")])
    .agg([@expr.col("b").sum().with_alias("total")]).plan
  assert_output_names(plan, ["a", "total"])
}

///|
test "output_names: a whole-scope aggregation gives up" {
  let plan = LazyFrame::LazyFrame(names_frame())
    .group_by([@expr.col("a")])
    .sum().plan
  assert_true(plan.output_names() is None)
}

///|
test "output_names: the existence joins keep the left schema alone" {
  for how in [@frame.JoinType::Semi, @frame.JoinType::Anti] {
    let plan = LazyFrame::LazyFrame(names_frame()).join(
        LazyFrame::LazyFrame(names_other()),
        @frame.JoinOptions::on([@expr.col("a")], how~),
      ).plan
    assert_output_names(plan, ["a", "b", "c"])
  }
}

///|
test "output_names: a merging join unions both sides, suffixed on a clash" {
  let plan = LazyFrame::LazyFrame(names_frame()).join(
      LazyFrame::LazyFrame(names_other()),
      // Paired keys never coalesce, so the right key column survives under
      // its suffixed name too.
      @frame.JoinOptions::left_on([@expr.col("a")], right_on=[@expr.col("a")]),
    ).plan
  // Left `a` keeps its name; the right `a` clashes and is offered under its
  // suffixed spelling only (paired keys never coalesce, so that column
  // genuinely survives), while the clash-free `d` keeps its own — the
  // exact output vocabulary, with nothing over-offered.
  assert_output_names(plan, ["a", "a_right", "b", "c", "d"])
}

///|
test "output_names: a coalescible bare on-key offers no suffixed spelling" {
  // An `on` join over a bare clashing key coalesces by default (inner /
  // left / right), so the right key column is dropped and `a_right` never
  // exists — the set offers neither spelling for it beyond the left `a`
  // already present. Under-offering only declines a sink; offering the
  // phantom spelling would attribute a predicate to a name the join never
  // outputs.
  let plan = LazyFrame::LazyFrame(names_frame()).join(
      LazyFrame::LazyFrame(names_other()),
      @frame.JoinOptions::on([@expr.col("a")]),
    ).plan
  assert_output_names(plan, ["a", "b", "c", "d"])
}

///|
test "output_names: a join over an unknowable side gives up" {
  let plan = LazyFrame::LazyFrame(names_frame()).join(
      scan_csv("names.csv"),
      @frame.JoinOptions::on([@expr.col("a")]),
    ).plan
  assert_true(plan.output_names() is None)
}

///|
test "output_names: an unknowable input gives up through every reshaper" {
  // A file source's `None` rides up through the reshaping verbs — each
  // one's `None` arm is the give-up, so a join above any of them sees an
  // unattributable side.
  let base = scan_csv("names.csv")
  let unknowable : Array[LogicalPlan] = [
    base.with_columns([(@expr.col("a") + @expr.lit_int(1)).with_alias("d")]).plan,
    base.drop([@expr.col("a")]).plan,
    base.rename([("a", "x")]).plan,
    base.rename_with(name => name + "_c").plan,
    base.with_row_index(name="idx").plan,
  ]
  for plan in unknowable {
    assert_true(plan.output_names() is None)
  }
}

///|
test "bare_on_key_names: bare keys only, derived and sided contribute none" {
  // The helper reads an `on` list's bare columns alone — a derived key
  // names no column (its `_` arm), and a sided or cross join carries no
  // `on` list at all.
  let bare = bare_on_key_names(
    @frame.JoinOptions::on([@expr.col("a"), @expr.col("b")]),
  )
  assert_true(bare.contains("a"))
  assert_true(bare.contains("b"))
  let derived = bare_on_key_names(
    @frame.JoinOptions::on([@expr.col("a") + @expr.lit_int(1)]),
  )
  let mut derived_count = 0
  derived.each(_ => derived_count = derived_count + 1)
  assert_eq(derived_count, 0)
  let sided = bare_on_key_names(
    @frame.JoinOptions::left_on([@expr.col("a")], right_on=[@expr.col("b")]),
  )
  let mut sided_count = 0
  sided.each(_ => sided_count = sided_count + 1)
  assert_eq(sided_count, 0)
}
