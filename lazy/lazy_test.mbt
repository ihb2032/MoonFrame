///|
/// Blackbox behavior tests for the lazy layer's contract: builders are
/// total and only defer; `collect` is a faithful deferred executor —
/// bitwise-equal to the eager chain, node by node and composed; the two
/// entry points agree; and every failure surfaces at collect time as the
/// underlying eager operator's error. Plan-rendering snapshots live in
/// `logical_plan_test.mbt`; the shared fixture frames live here.

///|
/// 4×3 mixed frame: a plain Int column, a nullable Int column, and a
/// String key column — enough surface for every deferred verb.
fn sales_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_ints("qty", [5, 120, 80, 200]),
    @series.Series::from_int_options("bonus", [Some(1), None, Some(3), None]),
    @series.Series::from_strings("region", ["west", "east", "west", "east"]),
  ])
}

///|
/// Join left side: order ids and amounts (3×2).
fn orders_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_ints("id", [1, 2, 3]),
    @series.Series::from_ints("amount", [10, 20, 30]),
  ])
}

///|
/// Join right side: partially overlapping ids (3×2) — id 1 is only on the
/// left, id 4 only here, so Inner / Left / Right / Outer all differ.
fn cities_df() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_ints("id", [2, 3, 4]),
    @series.Series::from_strings("city", ["bern", "cork", "delft"]),
  ])
}

///|
test "an unmodified plan collects back to the source frame" {
  let df = sales_df()
  let out = lazy_frame(df).collect()
  assert_eq(out, df)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "lazy_frame wraps a frame as a Scan leaf" {
  let df = sales_df()
  assert_eq(lazy_frame(df).explain(), "SCAN [4×3]")
  assert_eq(lazy_frame(df).collect(), df)
}

///|
test "each deferred verb collects to its eager equivalent" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  assert_eq(lazy_frame(df).filter(predicate).collect(), df.filter(predicate))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  assert_eq(
    lazy_frame(df).with_columns(derived).collect(),
    df.with_columns(derived),
  )
  let projection = [
    @expr.col("region"),
    @expr.col("qty").sum().with_alias("total"),
  ]
  assert_eq(lazy_frame(df).select(projection).collect(), df.select(projection))
  let keys = [
    (@expr.col("bonus"), @frame.SortOrder::Asc, @frame.NullOrder::NullsLast),
    (@expr.col("qty"), @frame.SortOrder::Desc, @frame.NullOrder::NullsFirst),
  ]
  assert_eq(lazy_frame(df).sort(keys).collect(), df.sort(keys))
  assert_eq(lazy_frame(df).head(2).collect(), df.head(2))
  assert_eq(lazy_frame(df).tail(2).collect(), df.tail(2))
  assert_eq(lazy_frame(df).slice(1, 3).collect(), df.slice(1, 3))
}

///|
test "each whole-frame reduction collects to its eager equivalent" {
  // qty (Int, all-valid), bonus (nullable Int), region (String) exercise the
  // numeric, nullable-numeric, and non-numeric (nulled) cell rules together.
  let df = sales_df()
  assert_eq(lazy_frame(df).sum().collect(), df.sum())
  assert_eq(lazy_frame(df).mean().collect(), df.mean())
  assert_eq(lazy_frame(df).min().collect(), df.min())
  assert_eq(lazy_frame(df).max().collect(), df.max())
  assert_eq(lazy_frame(df).count().collect(), df.count())
  assert_eq(lazy_frame(df).null_count().collect(), df.null_count())
}

///|
test "a reduction caps an optimized pipeline; a filter above it stays above" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  // Reduction over a filtered input: the input still optimizes, collect matches
  // the eager chain, and the reduction renders at the top.
  let capped = lazy_frame(df).filter(predicate).sum()
  assert_eq(capped.collect(), df.filter(predicate).sum())
  assert_true(capped.explain(optimized=true).has_prefix("SUM"))
  // A filter *above* the reduction can't sink past it (that would filter the
  // input rows and change the sum) — the reduction is a barrier.
  let above = lazy_frame(df).sum().filter(@expr.col("qty").gt(@expr.lit_int(0)))
  assert_eq(
    above.collect(),
    df.sum().filter(@expr.col("qty").gt(@expr.lit_int(0))),
  )
  assert_true(above.explain(optimized=true).has_prefix("FILTER"))
}

///|
test "a whole-frame reduction on an empty frame matches eager" {
  let empty = @frame.DataFrame::new([
    @series.Series::from_ints("a", []),
    @series.Series::from_strings("b", []),
  ])
  assert_eq(lazy_frame(empty).sum().collect(), empty.sum())
  assert_eq(lazy_frame(empty).count().collect(), empty.count())
  assert_eq(lazy_frame(empty).null_count().collect(), empty.null_count())
}

///|
test "is_in / is_between are row-stable predicates through the optimizer" {
  let df = sales_df()
  // `is_in` as a filter over a projection: row-stable, so the optimizer sinks
  // it below the select — collect stays faithful to the eager chain.
  let inx = @expr.col("region").is_in([
    @types.Scalar::String("west"),
    @types.Scalar::String("north"),
  ])
  let proj = [@expr.col("region"), @expr.col("qty")]
  assert_eq(
    lazy_frame(df).select(proj).filter(inx).collect(),
    df.select(proj).filter(inx),
  )
  // `is_between` inside an aggregation, with the `is_in` key-filter above it:
  // pushing that filter below the aggregate walks `group_cell_stable` over the
  // `is_between` cell and `row_stable` over the `is_in` predicate, and the
  // result must still match eager.
  let keys = [@expr.col("region")]
  let aggs = [
    @expr.col("qty")
    .sum()
    .is_between(@expr.lit_int(0), @expr.lit_int(1000))
    .with_alias("ok"),
  ]
  let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(inx)
  assert_eq(plan.collect(), df.group_by(keys).agg(aggs).filter(inx))
  assert_eq(plan.collect().check_invariants(), Ok(()))
}

///|
test "a dtype-changing map under a grouped reduction collects like eager" {
  // The deferred dtype probe must behave identically through the lazy
  // Aggregate node: the closure's Int output types the reduction, not the
  // Map's String input column.
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("g", ["x", "x", "y"]),
    @series.Series::from_strings("s", ["a", "bb", "ccc"]),
  ])
  let strlen = @expr.col("s").map_elements(label="len", s => {
    match s {
      @types.Scalar::String(v) => @types.Scalar::Int(v.length().to_int64())
      _ => @types.Scalar::Null
    }
  })
  let aggs = [strlen.sum().with_alias("total")]
  let out = lazy_frame(df).group_by([@expr.col("g")]).agg(aggs).collect()
  assert_eq(out, df.group_by([@expr.col("g")]).agg(aggs))
  assert_eq(out.get_column("total").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(3),
  ])
}

///|
test "a batched map collects like eager, row-wise and as a group reduction" {
  let df = @frame.DataFrame::new([
    @series.Series::from_strings("g", ["x", "x", "y"]),
    @series.Series::from_ints("v", [10, 20, 30]),
  ])
  // Row-wise (returns_scalar=false) through with_columns.
  let doubled = @expr.col("v").map_batches(label="double", s => {
    @series.Series::from_ints(
      s.name(),
      s
      .to_scalars()
      .map(sc => {
        match sc {
          @types.Scalar::Int(x) => x * 2
          _ => 0
        }
      }),
    )
  })
  let rowwise = lazy_frame(df).with_columns([doubled.with_alias("v2")])
  assert_eq(rowwise.collect(), df.with_columns([doubled.with_alias("v2")]))
  // Reducing (returns_scalar=true) as a custom aggregation.
  let total = @expr.col("v").map_batches(label="sum", returns_scalar=true, s => {
    @series.Series::from_ints("sum", [s.sum().as_int()])
  })
  let reduced = lazy_frame(df)
    .group_by([@expr.col("g")])
    .agg([total.with_alias("t")])
  assert_eq(
    reduced.collect(),
    df.group_by([@expr.col("g")]).agg([total.with_alias("t")]),
  )
}

///|
test "nested self-joins execute each shared subplan once, not once per occurrence" {
  // `lf.join(lf, …)` shares one plan object under both Join inputs; 26
  // nestings make a DAG whose tree expansion holds 2^26 nodes. The
  // memoised executor runs each distinct node once, so this collects
  // instantly and equals the eager chain — the per-occurrence fold
  // OOM-aborted at depth ~24.
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1])])
  let opts = @frame.JoinOptions::on([@expr.col("a")])
  let mut lf = lazy_frame(df)
  let mut eager = df
  for _ in 0..<26 {
    lf = lf.join(lf, opts)
    eager = eager.join(eager, opts)
  }
  let out = lf.collect()
  assert_eq(out, eager)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a shared subplan renders once, with a marker on re-encounter" {
  // The right Join input is the same node object as the left, so the
  // printer marks the repeat instead of re-expanding it — explain stays
  // linear (and total) on DAG-shaped plans.
  let df = @frame.DataFrame::new([@series.Series::from_ints("a", [1])])
  let shared = lazy_frame(df).filter(@expr.col("a").gt(@expr.lit_int(0)))
  let joined = shared.join(shared, @frame.JoinOptions::on([@expr.col("a")]))
  inspect(
    joined.explain(),
    content=(
      #|JOIN Inner on [col(a)]
      #|  FILTER (col(a) > 0)
      #|    SCAN [1×1]
      #|  FILTER (col(a) > 0) (shared, rendered above)
    ),
  )
  // A DAG-shaped plan skips the rewrite passes (the tree-wise rebuild
  // would duplicate every shared subplan), so the optimized view is the
  // as-built plan.
  assert_eq(joined.explain(optimized=true), joined.explain())
  // Two equal-but-separate builds share nothing, so both sides expand.
  let left = lazy_frame(df).filter(@expr.col("a").gt(@expr.lit_int(0)))
  let right = lazy_frame(df).filter(@expr.col("a").gt(@expr.lit_int(0)))
  let separate = left.join(right, @frame.JoinOptions::on([@expr.col("a")]))
  inspect(
    separate.explain(),
    content=(
      #|JOIN Inner on [col(a)]
      #|  FILTER (col(a) > 0)
      #|    SCAN [1×1]
      #|  FILTER (col(a) > 0)
      #|    SCAN [1×1]
    ),
  )
}

///|
test "builders copy their array arguments — later mutation is unobservable" {
  let df = sales_df()
  let sel = [@expr.col("qty")]
  let planned_select = lazy_frame(df).select(sel)
  sel.clear()
  assert_eq(planned_select.collect(), df.select([@expr.col("qty")]))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let planned_wc = lazy_frame(df).with_columns(derived)
  ignore(derived.pop())
  assert_eq(
    planned_wc.collect(),
    df.with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]),
  )
  let keys = [
    (@expr.col("qty"), @frame.SortOrder::Desc, @frame.NullOrder::NullsLast),
  ]
  let planned_sort = lazy_frame(df).sort(keys)
  keys.clear()
  assert_eq(
    planned_sort.collect(),
    df.sort([
      (@expr.col("qty"), @frame.SortOrder::Desc, @frame.NullOrder::NullsLast),
    ]),
  )
  let dropped = [@expr.col("bonus")]
  let planned_drop = lazy_frame(df).drop(dropped)
  dropped.push(@expr.col("qty"))
  assert_eq(planned_drop.collect(), df.drop([@expr.col("bonus")]))
  let pairs = [("qty", "quantity")]
  let planned_rename = lazy_frame(df).rename(pairs)
  pairs.push(("region", "zone"))
  assert_eq(planned_rename.collect(), df.rename([("qty", "quantity")]))
  let subset = [@expr.col("bonus")]
  let planned_dn = lazy_frame(df).drop_nulls(subset~)
  subset.clear()
  assert_eq(planned_dn.collect(), df.drop_nulls(subset=[@expr.col("bonus")]))
  let gkeys = [@expr.col("region")]
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let grouped = lazy_frame(df).group_by(gkeys)
  gkeys.clear()
  let planned_agg = grouped.agg(aggs)
  aggs.clear()
  assert_eq(
    planned_agg.collect(),
    df
    .group_by([@expr.col("region")])
    .agg([@expr.col("qty").sum().with_alias("total")]),
  )
}

///|
test "the column / row verbs collect to their eager equivalents" {
  let df = sales_df()
  assert_eq(
    lazy_frame(df).drop([@expr.col("bonus")]).collect(),
    df.drop([@expr.col("bonus")]),
  )
  assert_eq(
    lazy_frame(df).rename([("qty", "quantity")]).collect(),
    df.rename([("qty", "quantity")]),
  )
  assert_eq(
    lazy_frame(df).rename_with(name => "col_\{name}").collect(),
    df.rename_with(name => "col_\{name}"),
  )
  assert_eq(lazy_frame(df).unique().collect(), df.unique())
  // Every keep strategy matches its eager counterpart, so the lazy verb is a
  // faithful deferral rather than a first-only shortcut.
  for
    keep in [
      @frame.KeepStrategy::First,
      @frame.KeepStrategy::Last,
      @frame.KeepStrategy::None,
    ] {
    assert_eq(lazy_frame(df).unique(keep~).collect(), df.unique(keep~))
  }
  // A subset key defers the same way, and an unknown name surfaces at collect.
  assert_eq(
    lazy_frame(df).unique(subset=[@expr.col("region")]).collect(),
    df.unique(subset=[@expr.col("region")]),
  )
  assert_true(
    (Ok(lazy_frame(df).unique(subset=[@expr.col("nope")]).collect()) catch {
      e => Err(e)
    })
    is Err(@types.DataError::ColumnNotFound("nope")),
  )
  assert_eq(lazy_frame(df).drop_nulls().collect(), df.drop_nulls())
  assert_eq(
    lazy_frame(df).drop_nulls(subset=[@expr.col("bonus")]).collect(),
    df.drop_nulls(subset=[@expr.col("bonus")]),
  )
  // Frame-wide fill_null fills the dtype-compatible columns (the Int `bonus`).
  assert_eq(
    lazy_frame(df).fill_null(@types.Scalar::Int(0)).collect(),
    df.fill_null(@types.Scalar::Int(0)),
  )
}

///|
test "the column / row verbs render in explain, with each fill-value form" {
  let df = sales_df()
  inspect(
    lazy_frame(df).drop([@expr.col("bonus")]).explain(),
    content=(
      #|DROP [col(bonus)]
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).rename([("qty", "quantity")]).explain(),
    content=(
      #|RENAME [qty -> quantity]
      #|  SCAN [4×3]
    ),
  )
  // The callable form's closure is opaque, so it renders as a bare label.
  inspect(
    lazy_frame(df).rename_with(name => "col_\{name}").explain(),
    content=(
      #|RENAME_WITH
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).unique().explain(),
    content=(
      #|UNIQUE
      #|  SCAN [4×3]
    ),
  )
  // A non-default keep strategy shows in the plan line; the default stays bare.
  inspect(
    lazy_frame(df).unique(keep=Last).explain(),
    content=(
      #|UNIQUE keep=Last
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).unique(keep=None).explain(),
    content=(
      #|UNIQUE keep=None
      #|  SCAN [4×3]
    ),
  )
  // A subset key renders next to the verb, before any keep marker.
  inspect(
    lazy_frame(df).unique(subset=[@expr.col("region")]).explain(),
    content=(
      #|UNIQUE ON [col(region)]
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).unique(subset=[@expr.col("region")], keep=Last).explain(),
    content=(
      #|UNIQUE ON [col(region)] keep=Last
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).drop_nulls().explain(),
    content=(
      #|DROP_NULLS
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).drop_nulls(subset=[@expr.col("bonus")]).explain(),
    content=(
      #|DROP_NULLS [col(bonus)]
      #|  SCAN [4×3]
    ),
  )
  // fill_null renders every scalar value form (through
  // `@types.format_scalar_literal`), including a whole-valued Float, which
  // keeps its `.0` so it stays distinct from an Int literal.
  inspect(
    lazy_frame(df).fill_null(@types.Scalar::Int(0)).explain(),
    content=(
      #|FILL_NULL 0
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).fill_null(@types.Scalar::Float(1.5)).explain(),
    content=(
      #|FILL_NULL 1.5
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).fill_null(@types.Scalar::Float(1.0)).explain(),
    content=(
      #|FILL_NULL 1.0
      #|  SCAN [4×3]
    ),
  )
  // Negative zero keeps its sign — the two zeros evaluate observably
  // differently under division, so the plan line must distinguish them.
  inspect(
    lazy_frame(df).fill_null(@types.Scalar::Float(-0.0)).explain(),
    content=(
      #|FILL_NULL -0.0
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).fill_null(@types.Scalar::Bool(true)).explain(),
    content=(
      #|FILL_NULL true
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).fill_null(@types.Scalar::String("x")).explain(),
    content=(
      #|FILL_NULL "x"
      #|  SCAN [4×3]
    ),
  )
  inspect(
    lazy_frame(df).fill_null(@types.Scalar::Null).explain(),
    content=(
      #|FILL_NULL null
      #|  SCAN [4×3]
    ),
  )
}

///|
test "a scan-source path with control characters is escaped in explain" {
  // A hostile file path cannot inject a control sequence or a line break into
  // a rendered plan: the ESC and the newline both become escapes, so the line stays single and safe.
  inspect(
    scan_csv("a\u{1b}\nb").explain(),
    content=(
      #|SCAN_CSV "a\u001b\nb"
    ),
  )
}

///|
test "head, tail, and limit inherit the eager total clamp" {
  let df = sales_df()
  // Beyond the frame: every row survives, nothing raises.
  assert_eq(lazy_frame(df).head(100).collect(), df)
  assert_eq(lazy_frame(df).tail(100).collect(), df)
  // Negative n clamps to zero rows, mirroring eager head.
  assert_eq(lazy_frame(df).head(-1).collect(), df.head(-1))
  assert_eq(lazy_frame(df).head(-1).collect().nrows(), 0)
  // limit is head under its SQL name.
  assert_eq(lazy_frame(df).limit(2).collect(), df.head(2))
}

///|
test "every join type collects to its eager equivalent" {
  let l = orders_df()
  let r = cities_df()
  for
    how in [
      @frame.JoinType::Inner,
      @frame.JoinType::Left,
      @frame.JoinType::Right,
      @frame.JoinType::Outer,
    ] {
    let opts = @frame.JoinOptions::on([@expr.col("id")], how~)
    assert_eq(
      lazy_frame(l).join(lazy_frame(r), opts).collect(),
      l.join(r, opts),
    )
  }
  let cross = @frame.JoinOptions::cross()
  assert_eq(
    lazy_frame(l).join(lazy_frame(r), cross).collect(),
    l.join(r, cross),
  )
}

///|
test "a composite pipeline collects bitwise-equal to the eager chain" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(10))
  let derived = [(@expr.col("qty") - @expr.col("bonus")).with_alias("net")]
  let keys = [
    (@expr.col("net"), @frame.SortOrder::Desc, @frame.NullOrder::NullsLast),
  ]
  let projection = [@expr.col("region"), @expr.col("net")]
  let lazy_out = lazy_frame(df)
    .filter(predicate)
    .with_columns(derived)
    .sort(keys)
    .select(projection)
    .head(2)
    .collect()
  let eager_out = df
    .filter(predicate)
    .with_columns(derived)
    .sort(keys)
    .select(projection)
    .head(2)
  assert_eq(lazy_out, eager_out)
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "join inputs run their own deferred sub-pipelines" {
  let l = orders_df()
  let r = cities_df()
  let amount_gate = @expr.col("amount").ge(@expr.lit_int(20))
  let opts = @frame.JoinOptions::on(
    [@expr.col("id")],
    how=@frame.JoinType::Left,
  )
  let lazy_out = lazy_frame(l)
    .filter(amount_gate)
    .join(lazy_frame(r).head(2), opts)
    .collect()
  assert_eq(lazy_out, l.filter(amount_gate).join(r.head(2), opts))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "join on left_on / right_on and derived keys collects to the eager equivalent" {
  let l = @frame.DataFrame::new([
    @series.Series::from_ints("lk", [1, 2, 3]),
    @series.Series::from_strings("lv", ["a", "b", "c"]),
  ])
  let r = @frame.DataFrame::new([
    @series.Series::from_ints("rk", [2, 3, 4]),
    @series.Series::from_ints("rv", [20, 30, 40]),
  ])
  // Differently-named keys via left_on / right_on.
  let sided = @frame.JoinOptions::left_on([@expr.col("lk")], right_on=[
    @expr.col("rk"),
  ])
  assert_eq(
    lazy_frame(l).join(lazy_frame(r), sided).collect(),
    l.join(r, sided),
  )
  // A derived key on the right side, paired with a bare left key.
  let derived = @frame.JoinOptions::left_on([@expr.col("lk")], right_on=[
    @expr.col("rk") - @expr.lit_int(1),
  ])
  assert_eq(
    lazy_frame(l).join(lazy_frame(r), derived).collect(),
    l.join(r, derived),
  )
}

///|
test "builders share structure: extending a plan leaves the base intact" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(10))
  let base = lazy_frame(df).filter(predicate)
  let eager = df.filter(predicate)
  // Two diverging extensions of the same base…
  let first = base.head(2)
  let last = base.tail(1)
  assert_not_eq(first.collect(), last.collect())
  assert_eq(first.collect(), eager.head(2))
  assert_eq(last.collect(), eager.tail(1))
  // …and the base plan itself is untouched by either.
  assert_eq(base.collect(), eager)
}

///|
test "building a doomed plan succeeds; the error waits for collect" {
  let plan = lazy_frame(sales_df()).filter(
    @expr.col("zzz").gt(@expr.lit_int(0)),
  )
  // Building and introspecting are total even though collecting will fail
  // — inspect first, compute later.
  assert_eq(plan.explain(), "FILTER (col(zzz) > 0)\n  SCAN [4×3]")
  assert_eq(
    Ok(plan.collect()) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
}

///|
test "collect surfaces the eager operators' errors unchanged" {
  let df = sales_df()
  // Non-Bool predicate → the eager filter TypeMismatch.
  assert_eq(
    Ok(lazy_frame(df).filter(@expr.col("qty")).collect()) catch {
      e => Err(e)
    },
    Err(
      @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "filter predicate must be Bool, got Int",
        ),
      ),
    ),
  )
  // Out-of-range slice bound → IndexOutOfBounds(end), as in eager slice.
  assert_eq(
    Ok(lazy_frame(df).slice(2, 99).collect()) catch {
      e => Err(e)
    },
    Err(@types.DataError::IndexOutOfBounds(99)),
  )
  // Inverted slice window and a missing sort column: equal to the eager
  // errors, message for message.
  assert_eq(
    Ok(lazy_frame(df).slice(3, 1).collect()) catch {
      e => Err(e)
    },
    Ok(df.slice(3, 1)) catch {
      e => Err(e)
    },
  )
  let bad_keys = [
    (@expr.col("zzz"), @frame.SortOrder::Asc, @frame.NullOrder::NullsFirst),
  ]
  assert_eq(
    Ok(lazy_frame(df).sort(bad_keys).collect()) catch {
      e => Err(e)
    },
    Ok(df.sort(bad_keys)) catch {
      e => Err(e)
    },
  )
}

///|
test "a deferred group-by collects to the eager agg equivalent" {
  let df = sales_df()
  let aggs = [
    @expr.col("qty").sum().with_alias("total"),
    @expr.col("bonus").mean().with_alias("avg_bonus"),
    (@expr.col("qty") * @expr.col("bonus")).sum().with_alias("weighted"),
    (@expr.col("qty").max() - @expr.col("qty").min()).with_alias("spread"),
  ]
  let lazy_out = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .collect()
  assert_eq(lazy_out, df.group_by([@expr.col("region")]).agg(aggs))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "a deferred derived-key group-by collects to the eager equivalent" {
  let df = sales_df()
  // The grouping key is an expression, not a bare column: bucket on
  // qty > 50. Both faces evaluate it at collect / call time, so the lazy
  // result stays bitwise-equal to the eager one.
  let keys = [@expr.col("qty").gt(@expr.lit_int(50)).with_alias("big")]
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let lazy_out = lazy_frame(df).group_by(keys).agg(aggs).collect()
  assert_eq(lazy_out, df.group_by(keys).agg(aggs))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "multi-key and empty aggregation lists mirror eager group-by" {
  let df = sales_df()
  let count = [@expr.col("bonus").count().with_alias("n")]
  assert_eq(
    lazy_frame(df)
    .group_by([@expr.col("region"), @expr.col("qty")])
    .agg(count)
    .collect(),
    df.group_by([@expr.col("region"), @expr.col("qty")]).agg(count),
  )
  // No aggregations: the distinct-over-keys frame, exactly as eager.
  assert_eq(
    lazy_frame(df).group_by([@expr.col("region")]).agg([]).collect(),
    df.group_by([@expr.col("region")]).agg([]),
  )
}

///|
test "a group-by pipeline composes with the other deferred verbs" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(10))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let aggs = [@expr.col("dbl").sum().with_alias("total")]
  let keys = [
    (@expr.col("total"), @frame.SortOrder::Desc, @frame.NullOrder::NullsLast),
  ]
  let lazy_out = lazy_frame(df)
    .filter(predicate)
    .with_columns(derived)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .sort(keys)
    .head(1)
    .collect()
  let eager_out = df
    .filter(predicate)
    .with_columns(derived)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .sort(keys)
    .head(1)
  assert_eq(lazy_out, eager_out)
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "one LazyGroupBy serves diverging aggregations" {
  let df = sales_df()
  let grouped = lazy_frame(df).group_by([@expr.col("region")])
  let total = [@expr.col("qty").sum().with_alias("total")]
  let n = [@expr.col("qty").count().with_alias("n")]
  // Two aggregations off the same LazyGroupBy fork the plan — neither
  // disturbs the other, like every other shared builder.
  assert_eq(
    grouped.agg(total).collect(),
    df.group_by([@expr.col("region")]).agg(total),
  )
  assert_eq(grouped.agg(n).collect(), df.group_by([@expr.col("region")]).agg(n))
}

///|
test "group-by building is total; the errors wait for collect" {
  let df = sales_df()
  // Missing key: the plan builds and explains, then collect surfaces the
  // eager group_by's ColumnNotFound.
  let missing = lazy_frame(df).group_by([@expr.col("zzz")]).agg([])
  assert_eq(missing.explain(), "AGGREGATE [] BY [col(zzz)]\n  SCAN [4×3]")
  assert_eq(
    Ok(missing.collect()) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("zzz")),
  )
  // Repeated key → the eager group_by DuplicateColumn, at the repeat.
  assert_eq(
    Ok(
      lazy_frame(df)
      .group_by([@expr.col("region"), @expr.col("region")])
      .agg([])
      .collect(),
    ) catch {
      e => Err(e)
    },
    Err(@types.DataError::DuplicateColumn("region")),
  )
  // A bare column is not reduction-shaped → the eager agg
  // InvalidOperation, message for message.
  assert_eq(
    Ok(
      lazy_frame(df)
      .group_by([@expr.col("region")])
      .agg([@expr.col("qty")])
      .collect(),
    ) catch {
      e => Err(e)
    },
    Ok(df.group_by([@expr.col("region")]).agg([@expr.col("qty")])) catch {
      e => Err(e)
    },
  )
  // Summing a String column → the eager agg TypeMismatch.
  assert_eq(
    Ok(
      lazy_frame(df)
      .group_by([@expr.col("qty")])
      .agg([@expr.col("region").sum()])
      .collect(),
    ) catch {
      e => Err(e)
    },
    Ok(df.group_by([@expr.col("qty")]).agg([@expr.col("region").sum()])) catch {
      e => Err(e)
    },
  )
}

///|
test "a zero-row source aggregates to zero groups" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("qty", []),
    @series.Series::from_strings("region", []),
  ])
  let aggs = [@expr.col("qty").sum().with_alias("total")]
  let lazy_out = lazy_frame(df)
    .group_by([@expr.col("region")])
    .agg(aggs)
    .collect()
  assert_eq(lazy_out, df.group_by([@expr.col("region")]).agg(aggs))
  assert_eq(lazy_out.shape(), (0, 2))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}

///|
test "a zero-row source flows through the whole pipeline" {
  let df = @frame.DataFrame::new([
    @series.Series::from_ints("qty", []),
    @series.Series::from_strings("region", []),
  ])
  let predicate = @expr.col("qty").gt(@expr.lit_int(0))
  let derived = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let lazy_out = lazy_frame(df)
    .filter(predicate)
    .with_columns(derived)
    .head(5)
    .collect()
  let eager_out = df.filter(predicate).with_columns(derived).head(5)
  assert_eq(lazy_out, eager_out)
  assert_eq(lazy_out.shape(), (0, 3))
  assert_eq(lazy_out.check_invariants(), Ok(()))
}
