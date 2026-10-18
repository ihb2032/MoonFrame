// Blackbox battery for the optimizer's second generation: the slice pass
// (a `HEAD` / `TAIL` / `SLICE` window sinking toward the scan) and the two
// local rules the fixed-point loop iterates — clustering adjacent
// `WITH_COLUMNS` stages and folding column-free subtrees to literals. Each
// rule's *equivalence* test pins `collect ≡ eager` on the pipelines where it
// fires and on the guards where it must not; the *structural* tests snapshot
// `explain(optimized=true)` against the as-built `explain()`.

///|
test "slice pushdown: a head sinks past a row-stable with_columns" {
  let df = sales_df()
  let doubled = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let lf = LazyFrame::LazyFrame(df).with_columns(doubled).head(2)
  // The window must not change the collected values — it only moves.
  assert_eq(lf.collect(), df.with_columns(doubled).head(2))
  // And it moves: below the stage it crossed, above the scan.
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [(col(qty) * 2) as dbl]\n  HEAD 2\n    SCAN [4×3]",
  )
}

///|
test "slice pushdown: a head sinks past a row-preserving select" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).select([@expr.col("qty")]).head(2)
  assert_eq(lf.collect(), df.select([@expr.col("qty")]).head(2))
  assert_eq(
    lf.explain(optimized=true),
    "SELECT [col(qty)]\n  HEAD 2\n    SELECT [col(qty)]\n      SCAN [4×3]",
  )
}

///|
test "slice pushdown: a value-raising stage fences the window" {
  let df = sales_df()
  // A cast can reject a *value*: pruning rows before it would drop the very
  // cell that raises, so the window stays above the stage.
  let casted = [@expr.col("qty").cast(@types.DataType::Float).with_alias("f")]
  let lf = LazyFrame::LazyFrame(df).with_columns(casted).head(2)
  assert_eq(lf.collect(), df.with_columns(casted).head(2))
  assert_eq(
    lf.explain(optimized=true),
    "HEAD 2\n  WITH_COLUMNS [col(qty).cast(Float) as f]\n    SCAN [4×3]",
  )
}

///|
test "slice pushdown: a filter floors the window" {
  let df = sales_df()
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let lf = LazyFrame::LazyFrame(df).filter(predicate).head(2)
  assert_eq(lf.collect(), df.filter(predicate).head(2))
  // Crossing the filter would pick from a different row set — it floors.
  assert_eq(
    lf.explain(optimized=true),
    "HEAD 2\n  FILTER (col(qty) > 50)\n    SCAN [4×3]",
  )
}

///|
test "slice pushdown: an all-constant selection fences the window" {
  let df = sales_df()
  // `select([1 as one])` collapses any input to one row; a window above it
  // addresses pre-collapse rows and must stay.
  let lf = LazyFrame::LazyFrame(df).select([@expr.lit_int(1)]).head(2)
  assert_eq(lf.collect(), df.select([@expr.lit_int(1)]).head(2))
  assert_eq(lf.explain(optimized=true), "HEAD 2\n  SELECT [1]\n    SCAN [4×3]")
}

///|
test "slice pushdown: a tail sinks and keeps its from-the-end reading" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df)
    .with_columns([@expr.col("qty").neg().with_alias("nq")])
    .tail(2)
  assert_eq(
    lf.collect(),
    df.with_columns([@expr.col("qty").neg().with_alias("nq")]).tail(2),
  )
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [(-col(qty)) as nq]\n  TAIL 2\n    SCAN [4×3]",
  )
}

///|
test "clustering: adjacent disjoint with_columns stages merge" {
  let df = sales_df()
  let inner = [(@expr.col("qty") + @expr.lit_int(1)).with_alias("plus")]
  let outer = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let lf = LazyFrame::LazyFrame(df).with_columns(inner).with_columns(outer)
  assert_eq(lf.collect(), df.with_columns(inner).with_columns(outer))
  // One stage: the outer list does not read the inner's definitions, so both
  // evaluate against the same input and the stage collapses.
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [(col(qty) + 1) as plus, (col(qty) * 2) as dbl]\n  SCAN [4×3]",
  )
}

///|
test "clustering: a reader of the inner definitions stays separate" {
  let df = sales_df()
  let inner = [(@expr.col("qty") + @expr.lit_int(1)).with_alias("plus")]
  // The outer stage reads `plus` — below the merge point that name does not
  // exist, so the stages cannot merge.
  let outer = [(@expr.col("plus") * @expr.lit_int(2)).with_alias("dbl")]
  let lf = LazyFrame::LazyFrame(df).with_columns(inner).with_columns(outer)
  assert_eq(lf.collect(), df.with_columns(inner).with_columns(outer))
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [(col(plus) * 2) as dbl]\n  WITH_COLUMNS [(col(qty) + 1) as plus]\n    SCAN [4×3]",
  )
}

///|
test "clustering: colliding definitions stay separate" {
  let df = sales_df()
  let inner = [(@expr.col("qty") + @expr.lit_int(1)).with_alias("v")]
  let outer = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("v")]
  let lf = LazyFrame::LazyFrame(df).with_columns(inner).with_columns(outer)
  assert_eq(lf.collect(), df.with_columns(inner).with_columns(outer))
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [(col(qty) * 2) as v]\n  WITH_COLUMNS [(col(qty) + 1) as v]\n    SCAN [4×3]",
  )
}

///|
test "folding: literal arithmetic collapses to the literal it evaluates to" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).with_columns([
    (@expr.lit_int(1) + @expr.lit_int(2)).with_alias("three"),
  ])
  assert_eq(
    lf.collect(),
    df.with_columns([(@expr.lit_int(1) + @expr.lit_int(2)).with_alias("three")]),
  )
  // The fold stays *under* the alias — the alias is the column's name.
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [3 as three]\n  SCAN [4×3]",
  )
}

///|
test "folding: a column-free subtree inside a column expression folds" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).select([
    (@expr.col("qty") + @expr.lit_int(2) * @expr.lit_int(3)).with_alias(
      "shifted",
    ),
  ])
  assert_eq(
    lf.collect(),
    df.select([
      (@expr.col("qty") + @expr.lit_int(2) * @expr.lit_int(3)).with_alias(
        "shifted",
      ),
    ]),
  )
  assert_eq(
    lf.explain(optimized=true),
    "SELECT [(col(qty) + 6) as shifted]\n  SELECT [col(qty)]\n    SCAN [4×3]",
  )
}

///|
test "folding: a raising evaluation keeps the subtree verbatim" {
  let df = sales_df()
  // `\"x\"` cannot cast to Int — the fold consults the evaluator, it raises,
  // and the cast stays exactly where the as-built plan reports the error.
  let lf = LazyFrame::LazyFrame(df).with_columns([
    @expr.lit_str("x").cast(@types.DataType::Int).with_alias("bad"),
  ])
  let got : Result[@frame.DataFrame, @types.DataError] = Ok(lf.collect()) catch {
    e => Err(e)
  }
  assert_true(got is Err(@types.DataError::ParseError(_)))
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [\"x\".cast(Int) as bad]\n  SCAN [4×3]",
  )
}

///|
test "folding: a null result stays a subtree, not a Null literal" {
  // `5 // 0` evaluates to null; folding it to `Lit(Null)` would make the
  // collected plan refuse (`no Null-dtype column backend`) what the
  // as-built one returns. The subtree stays and collect agrees with eager.
  let df = sales_df()
  let z = @expr.lit_int(5).floor_div(@expr.lit_int(0)).with_alias("z")
  let lf = LazyFrame::LazyFrame(df).with_columns([z])
  assert_eq(lf.collect(), df.with_columns([z]))
}

///|
test "folding: a null from a string probe stays a subtree too" {
  // The same shape through `str_extract` missing its pattern: the null
  // cell collects exactly as the eager verb produces it.
  let df = sales_df()
  let z = @expr.lit_str("abc").str_extract("[0-9]+").with_alias("z")
  let lf = LazyFrame::LazyFrame(df).with_columns([z])
  assert_eq(lf.collect(), df.with_columns([z]))
}

///|
test "folding: aggregations and map closures are left untouched" {
  let df = sales_df()
  // An `Agg` reduces a whole scope, a map closure runs per row — neither may
  // be consulted on an empty frame at optimize time.
  let mapped = @expr.col("qty").map_elements(label="m", s => s)
  let lf = LazyFrame::LazyFrame(df).select([
    @expr.col("qty").sum().with_alias("total"),
    mapped.with_alias("m"),
  ])
  assert_eq(
    lf.collect(),
    df.select([
      @expr.col("qty").sum().with_alias("total"),
      mapped.with_alias("m"),
    ]),
  )
  assert_eq(
    lf.explain(optimized=true),
    "SELECT [col(qty).sum() as total, map(\"m\", [col(qty)]) as m]\n  SELECT [col(qty)]\n    SCAN [4×3]",
  )
}

///|
test "folding: a fold inside a filter predicate keeps the verdict" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).filter(@expr.lit_bool(true))
  assert_eq(lf.collect(), df)
  assert_eq(lf.explain(optimized=true), "FILTER true\n  SCAN [4×3]")
}

///|
test "folding: a folded child rebuilds its unary, ternary, and interval parents" {
  let df = sales_df()
  // Parents whose *children* fold while they themselves cannot — a folded
  // child is one the fold produced (`(1 + 2) > 1` becomes a literal), not a
  // bare `lit` leaf, which never reports a change: the negative of a column
  // expression, a ternary over a folded condition (wrapped in a string
  // transform, so the rebuilt ternary rebuilds its parent in turn), and an
  // interval probe with folded bounds.
  let folded_cond = @expr.lit_int(1).add(@expr.lit_int(2)).gt(@expr.lit_int(1))
  let lazy_exprs = [
    @expr.col("qty")
    .add(@expr.lit_int(2) * @expr.lit_int(3))
    .neg()
    .with_alias("n"),
    @expr.when(folded_cond)
    .then(@expr.col("region"))
    .otherwise(@expr.lit_str("none"))
    .str_to_uppercase()
    .with_alias("picked"),
    @expr.col("qty")
    .is_between(
      @expr.lit_int(1) + @expr.lit_int(4),
      @expr.lit_int(2) * @expr.lit_int(5),
    )
    .with_alias("mid"),
  ]
  assert_eq(
    LazyFrame::LazyFrame(df).select(lazy_exprs).collect(),
    df.select(lazy_exprs),
  )
  assert_eq(
    LazyFrame::LazyFrame(df).select(lazy_exprs).explain(optimized=true),
    "SELECT [(-(col(qty) + 6)) as n, when(true).then(col(region)).otherwise(\"none\").str_to_uppercase() as picked, col(qty).is_between(5, 10) as mid]\n  SELECT [col(qty), col(region)]\n    SCAN [4×3]",
  )
}

///|
test "folding: a filter predicate folds where a column-free subtree sits in it" {
  let df = sales_df()
  // `50 < 40 + 20` — the right side is column-free, so the predicate keeps
  // its column but loses the arithmetic.
  let lf = LazyFrame::LazyFrame(df).filter(
    @expr.col("qty").lt(@expr.lit_int(40) + @expr.lit_int(20)),
  )
  assert_eq(
    lf.collect(),
    df.filter(@expr.col("qty").lt(@expr.lit_int(40) + @expr.lit_int(20))),
  )
  assert_eq(lf.explain(optimized=true), "FILTER (col(qty) < 60)\n  SCAN [4×3]")
}

///|
test "folding: an aggregation's expressions fold" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df)
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("qty")
      .add(@expr.lit_int(2) * @expr.lit_int(3))
      .sum()
      .with_alias("shifted_total"),
    ])
  assert_eq(
    lf.collect(),
    df
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("qty")
      .add(@expr.lit_int(2) * @expr.lit_int(3))
      .sum()
      .with_alias("shifted_total"),
    ]),
  )
  assert_eq(
    lf.explain(optimized=true),
    "AGGREGATE [(col(qty) + 6).sum() as shifted_total] BY [col(region)]\n  SELECT [col(qty), col(region)]\n    SCAN [4×3]",
  )
}

///|
test "folding: a sort key's column-free subtree folds" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).sort([
    (@expr.col("qty").add(@expr.lit_int(1) + @expr.lit_int(1)), true, false),
  ])
  assert_eq(
    lf.collect(),
    df.sort([
      (@expr.col("qty").add(@expr.lit_int(1) + @expr.lit_int(1)), true, false),
    ]),
  )
  assert_eq(
    lf.explain(optimized=true),
    "SORT [(col(qty) + 2) Desc NullsFirst]\n  SCAN [4×3]",
  )
}

///|
test "folding: a folded operand rebuilds its cast, fill, and positional parents" {
  let df = sales_df()
  // The `qty + (1 + 1)` operand folds to `qty + 2` under three parents that
  // cannot fold themselves: a cast, a fill, and a running sum.
  let shifted = @expr.col("qty").add(@expr.lit_int(1) + @expr.lit_int(1))
  let exprs = [
    shifted.cast(@types.DataType::Float).with_alias("f"),
    shifted.fill_null(@expr.lit_int(0)).with_alias("filled"),
    @expr.col("qty")
    .cast(@types.DataType::Float)
    .fill_nan(@expr.lit_int(1) + @expr.lit_int(2))
    .with_alias("denaned"),
    shifted.cum_sum().with_alias("running"),
    shifted.is_in([@types.Scalar::Int(7)]).with_alias("hit"),
  ]
  let lf = LazyFrame::LazyFrame(df).select(exprs)
  assert_eq(lf.collect(), df.select(exprs))
  assert_eq(
    lf.explain(optimized=true),
    "SELECT [(col(qty) + 2).cast(Float) as f, (col(qty) + 2).fill_null(0) as filled, col(qty).cast(Float).fill_nan(3) as denaned, (col(qty) + 2).cum_sum() as running, (col(qty) + 2).is_in([7]) as hit]\n  SELECT [col(qty)]\n    SCAN [4×3]",
  )
}

///|
test "window fusion: two heads keep the smaller bound" {
  let df = sales_df()
  // Either order: the tighter bound decides, and the inner window is gone.
  let lf = LazyFrame::LazyFrame(df).head(5).head(3)
  assert_eq(lf.collect(), df.head(5).head(3))
  assert_eq(lf.explain(optimized=true), "HEAD 3\n  SCAN [4×3]")
  let lf2 = LazyFrame::LazyFrame(df).head(3).head(5)
  assert_eq(lf2.collect(), df.head(3).head(5))
  assert_eq(lf2.explain(optimized=true), "HEAD 3\n  SCAN [4×3]")
}

///|
test "window fusion: two tails keep the smaller bound" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).tail(3).tail(2)
  assert_eq(lf.collect(), df.tail(3).tail(2))
  assert_eq(lf.explain(optimized=true), "TAIL 2\n  SCAN [4×3]")
}

///|
test "window fusion: three heads chain into one" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).head(9).head(3).head(2)
  assert_eq(lf.collect(), df.head(9).head(3).head(2))
  assert_eq(lf.explain(optimized=true), "HEAD 2\n  SCAN [4×3]")
}

///|
test "window fusion: two non-negative slices compose by offsets and spans" {
  let df = sales_df()
  // `[1, 11)` then `[2, 5)` over it: the composite reads `[3, 6)` — offset
  // 3, three rows available, two asked.
  let lf = LazyFrame::LazyFrame(df).slice(1, length=10).slice(2, length=2)
  assert_eq(lf.collect(), df.slice(1, length=10).slice(2, length=2))
  assert_eq(lf.explain(optimized=true), "SLICE [3: 2]\n  SCAN [4×3]")
}

///|
test "window fusion: an outer slice starting past the inner span is empty" {
  let df = sales_df()
  // The inner window supplies rows `[2, 4)`; the outer asks from offset 3
  // for one row — row 3 of the inner's two. Available span under the outer
  // start is 1, asked 1.
  let lf = LazyFrame::LazyFrame(df).slice(2).slice(1, length=1)
  assert_eq(lf.collect(), df.slice(2).slice(1, length=1))
  // And starting past the end: available goes negative, clamped to an empty
  // window — same rows as the as-built chain (none).
  let lf2 = LazyFrame::LazyFrame(df).slice(2, length=2).slice(2, length=1)
  assert_eq(lf2.collect(), df.slice(2, length=2).slice(2, length=1))
  assert_eq(lf2.collect().nrows(), 0)
}

///|
test "window fusion: opposite ends and negative offsets stay separate" {
  let df = sales_df()
  // `head` over `tail` addresses opposite ends — no composite, two windows.
  let lf = LazyFrame::LazyFrame(df).tail(3).head(2)
  assert_eq(lf.collect(), df.tail(3).head(2))
  assert_eq(lf.explain(optimized=true), "HEAD 2\n  TAIL 3\n    SCAN [4×3]")
}

///|
test "window fusion: a window still crosses stages before fusing" {
  let df = sales_df()
  // The outer head fuses with the inner tail — wait, no: the composite here
  // is head-over-tail, which has no fusion. The pinned shape shows the
  // outer window sitting above the crossed stage and the inner window.
  let lf = LazyFrame::LazyFrame(df)
    .with_columns([@expr.col("qty").neg().with_alias("nq")])
    .head(3)
    .head(2)
  assert_eq(
    lf.collect(),
    df.with_columns([@expr.col("qty").neg().with_alias("nq")]).head(3).head(2),
  )
  assert_eq(
    lf.explain(optimized=true),
    "WITH_COLUMNS [(-col(qty)) as nq]\n  HEAD 2\n    SCAN [4×3]",
  )
}

///|
test "window fusion: an unbounded outer slice takes the inner span" {
  let df = sales_df()
  // The outer window asks `from offset 2 to the end` of the inner's
  // `[1, 5)` — the composite is `[3, 5)`: offset 3, the two available rows.
  let lf = LazyFrame::LazyFrame(df).slice(1, length=4).slice(2)
  assert_eq(lf.collect(), df.slice(1, length=4).slice(2))
  assert_eq(lf.explain(optimized=true), "SLICE [3: 2]\n  SCAN [4×3]")
}

///|
test "window fusion: two unbounded slices compose to one unbounded" {
  let df = sales_df()
  // Neither window bounds its length: the composite reads `[3, end)`.
  let lf = LazyFrame::LazyFrame(df).slice(1).slice(2)
  assert_eq(lf.collect(), df.slice(1).slice(2))
  assert_eq(lf.explain(optimized=true), "SLICE [3: ]\n  SCAN [4×3]")
}

///|
/// A negative `n` is the Polars "drop from the far end" window, not a
/// tight bound: `min` would pick it as the tighter head while eager reads
/// it as the *wider* one, so the pair stays a floor and collects exactly
/// the eager chain.
test "window fusion: negative bounds stay separate" {
  let df = sales_df()
  // Eager: head(3) keeps 3 rows, head(-2) drops the last 2 of those — 1 row.
  // A fused Head(min(3, -2) = -2) would keep all but 2 of the 4 — 2 rows.
  let lf = LazyFrame::LazyFrame(df).head(3).head(-2)
  assert_eq(lf.collect(), df.head(3).head(-2))
  assert_eq(lf.collect().nrows(), 1)
  // Both orders, and the tail twin.
  let lf2 = LazyFrame::LazyFrame(df).head(-2).head(3)
  assert_eq(lf2.collect(), df.head(-2).head(3))
  let lf3 = LazyFrame::LazyFrame(df).tail(3).tail(-1)
  assert_eq(lf3.collect(), df.tail(3).tail(-1))
  assert_eq(lf3.collect().nrows(), 2)
}

///|
/// Two saturating offsets whose sum leaves `Int32` compose to a start no
/// row count can reach — the eager chain answers "empty", so the fused
/// form must not wrap the sum into a from-the-tail offset. The pair stays
/// a floor.
test "window fusion: offsets whose sum wraps stay separate" {
  let df = sales_df()
  let lf = LazyFrame::LazyFrame(df).slice(1_500_000_000).slice(1_500_000_000)
  assert_eq(lf.collect(), df.slice(1_500_000_000).slice(1_500_000_000))
  assert_eq(lf.collect().nrows(), 0)
  // Just inside the representable range still fuses — and saturates to the
  // same empty window the eager chain gives.
  let lf2 = LazyFrame::LazyFrame(df).slice(1_000_000_000).slice(1_000_000_000)
  assert_eq(lf2.collect(), df.slice(1_000_000_000).slice(1_000_000_000))
  assert_eq(lf2.collect().nrows(), 0)
  assert_eq(lf2.explain(optimized=true), "SLICE [2000000000: ]\n  SCAN [4×3]")
}

///|
test "a negative-length slice never fuses: the wrapped reach reads no rows" {
  // `slice(0, length = INT32_MIN)` is an empty window to the eager chain
  // (a negative length reads as zero rows), and the outer window over
  // nothing is nothing. The fused composite's `blen - ao` would wrap past
  // `Int32::MIN` into a large positive span reading real rows, so the
  // fusion refuses and the chain collects exactly what the eager verbs
  // give: zero rows.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("v", [1L, 2L, 3L, 4L, 5L, 6L]),
  ])
  let plan = LazyFrame::LazyFrame(df)
    .slice(0, length=-2147483648)
    .slice(1, length=5)
  let out = plan.collect()
  assert_eq(out.nrows(), 0)
  assert_eq(out, df.slice(0, length=-2147483648).slice(1, length=5))
}
