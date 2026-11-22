// Whitebox battery for the morsel pipeline: the executor's equivalence
// contract — a tree-shaped plan's collection, and its first error, are
// exactly the memoised interpreter's — over deterministic shapes chosen
// to sit on every span boundary (flow-safe runs, blocking runs, joins,
// aggregations, and the all-constant selection that gates a `Select`
// out of the flow), plus the span shapes themselves and the
// DAG-shaped fallback the interpreter keeps.

///|
/// The equivalence oracle's frame: enough columns for a join, a
/// grouping, and a selection, with nulls and repeated keys in play.
fn pipeline_frame() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_string_options("k", [Some("a"), None, Some("b"), Some("a")]),
    Series::from_int_options("v", [Some(1), None, Some(3), Some(2)]),
    Series::from_string_options("s", [Some("x"), Some("y"), None, Some("x")]),
  ])
}

///|
/// Both engines on one plan — the pipeline (a tree-shaped plan's own
/// executor) and the memoised interpreter (the DAG fallback and the
/// oracle). The asserting half lives in the tests: `assert_eq` raises
/// the test context's own error, not this helper's.
fn both_engines(
  plan : LogicalPlan,
) -> (DataFrame, DataFrame) raise @types.DataError {
  (plan.build_pipeline().run(), plan.execute_memoised())
}

///|
/// Assert the two engines' frames agree — shape, columns, every cell.
fn assert_agree(pair : (DataFrame, DataFrame)) -> Unit raise {
  let (pipelined, memoised) = pair
  assert_eq(pipelined.shape(), memoised.shape())
  assert_eq(pipelined.columns(), memoised.columns())
  for name in memoised.columns() {
    assert_eq(
      pipelined.get_column(name).to_scalars(),
      memoised.get_column(name).to_scalars(),
    )
  }
}

///|
test "a pure flow chain agrees with the interpreter" {
  // Every verb here is flow-safe — the whole plan is one source and one
  // `Flow`, and the batches ride the verbs in flight.
  assert_agree(
    both_engines(
      LazyFrame::LazyFrame(pipeline_frame())
      .filter(@expr.col("v").gt(@expr.lit_int(0)))
      .select([
        @expr.col("k"),
        (@expr.col("v") * @expr.lit_int(10)).with_alias("d"),
      ])
      .with_columns([(@expr.col("d") + @expr.lit_int(1)).with_alias("e")])
      .rename([("k", "key")])
      .drop([@expr.col("d")])
      .drop_nulls().plan,
    ),
  )
}

///|
test "flow and blocking stretches agree with the interpreter" {
  // Blocking verbs between flow-safe ones: the span sequence alternates,
  // and each blocking stretch materialises once for its whole run.
  let base = LazyFrame::LazyFrame(pipeline_frame())
  assert_agree(
    both_engines(
      base
      .filter(@expr.col("v").gt(@expr.lit_int(0)))
      .sort([(@expr.col("v"), true, false)])
      .filter(@expr.col("k").is_not_null())
      .head(3)
      .select([@expr.col("k"), @expr.col("v")]).plan,
    ),
  )
  assert_agree(
    both_engines(
      base
      .tail(2)
      .slice(1, length=2)
      .gather_every(2, offset=0)
      .top_k(2, by=[@expr.col("v")])
      .drop_nulls(subset=[@expr.col("v")]).plan,
    ),
  )
  assert_agree(
    both_engines(
      base
      .bottom_k(2, by=[@expr.col("v")])
      .unique()
      .reverse()
      .with_row_index(name="idx").plan,
    ),
  )
  assert_agree(
    both_engines(
      base
      .fill_null_forward()
      .group_by([@expr.col("k")])
      .agg([@expr.col("v").sum()]).plan,
    ),
  )
  assert_agree(
    both_engines(
      base
      .group_by([@expr.col("k")])
      .agg([
        @expr.col("v").sum().with_alias("s"),
        @expr.col("v").mean().with_alias("m"),
      ]).plan,
    ),
  )
}

///|
test "a value fill agrees over a single-dtype frame" {
  // `fill_null` fills every column with the one value, so its frame
  // carries a single dtype — an Int column with nulls to fill.
  let single = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(1), None, Some(3)]),
  ])
  assert_agree(
    both_engines(
      LazyFrame::LazyFrame(single).fill_null(@types.Scalar::Int(0)).plan,
    ),
  )
}

///|
test "a join subtree agrees with the interpreter" {
  // The join is a source switch — both sides run whole, and the stages
  // above flow from the joined frame.
  let left = LazyFrame::LazyFrame(pipeline_frame())
    .filter(@expr.col("v").gt(@expr.lit_int(0)))
    .select([@expr.col("k"), @expr.col("v")])
  let right = LazyFrame::LazyFrame(pipeline_frame())
    .sort([(@expr.col("v"), false, true)])
    .select([
      @expr.col("k"),
      (@expr.col("v") * @expr.lit_int(2)).with_alias("w"),
    ])
  assert_agree(
    both_engines(
      left
      .join(right, JoinOptions::on([@expr.col("k")]))
      .filter(@expr.col("v").gt(@expr.lit_int(1)))
      .head(4).plan,
    ),
  )
}

///|
test "an all-constant selection blocks and still agrees" {
  // A selection reading no column collapses its input to one row — the
  // flow gate keeps it out of the flow (a per-batch run would collapse
  // each batch), and the blocked run answers the interpreter's row.
  assert_agree(
    both_engines(
      LazyFrame::LazyFrame(pipeline_frame()).select([
        @expr.lit_int(7).with_alias("c"),
      ]).plan,
    ),
  )
  // A mixed selection with one column-reading expression stays
  // frame-tall and flows.
  assert_agree(
    both_engines(
      LazyFrame::LazyFrame(pipeline_frame()).select([
        @expr.col("v"),
        @expr.lit_int(7).with_alias("c"),
      ]).plan,
    ),
  )
}

///|
test "the span shapes the builder draws" {
  // Same-kind verbs fold into one span; the kinds never merge — a
  // flow pair, a blocking sort, a window pair, a flowing select.
  let built = LazyFrame::LazyFrame(pipeline_frame())
  .filter(@expr.col("v").gt(@expr.lit_int(0)))
  .rename([("k", "key")])
  .sort([(@expr.col("v"), true, false)])
  .head(2)
  .tail(1)
  .select([@expr.col("key")]).plan.build_pipeline()
  assert_eq(built.spans.length(), 4)
  assert_true(built.spans[0] is Flow(_))
  assert_true(built.spans[1] is Block(_))
  assert_true(built.spans[2] is StateFlow(_))
  assert_true(built.spans[3] is Flow(_))
  match (built.spans[0], built.spans[1], built.spans[2]) {
    (Flow(first), Block(second), StateFlow(windows)) => {
      assert_eq(first.length(), 2)
      assert_eq(second.length(), 1)
      assert_eq(windows.length(), 2)
    }
    _ => fail("the span kinds were just asserted")
  }
}

///|
test "the flow gate reads the verbs' own expressions" {
  // The row-local gates the optimizer lends the executor: an
  // aggregating expression in a `WithColumns` blocks (its value is
  // frame-wide), a reading selection flows, a column-free selection
  // blocks (it collapses rows).
  assert_true(
    op_span_kind(Filter(@expr.col("v").gt(@expr.lit_int(0)))) is Flowing,
  )
  assert_true(op_span_kind(Select([@expr.col("v")])) is Flowing)
  assert_true(op_span_kind(Select([@expr.lit_int(1)])) is Blocking)
  assert_true(
    op_span_kind(
      WithColumns([(@expr.col("v") * @expr.lit_int(2)).with_alias("d")]),
    )
    is Flowing,
  )
  assert_true(
    op_span_kind(WithColumns([@expr.col("v").sum().with_alias("t")]))
    is Blocking,
  )
  assert_true(op_span_kind(Rename([("k", "key")])) is Flowing)
  assert_true(op_span_kind(Sort([(@expr.col("v"), true, false)])) is Blocking)
  assert_true(op_span_kind(Reverse) is Blocking)
  // The positional windows with a running place ride their own span —
  // forward bounds only; the far-end shapes keep the whole frame.
  assert_true(op_span_kind(Head(3)) is Windowed)
  assert_true(op_span_kind(Head(-3)) is Blocking)
  assert_true(op_span_kind(Tail(3)) is Windowed)
  assert_true(op_span_kind(Tail(-3)) is Blocking)
  assert_true(op_span_kind(Slice(1, Some(2))) is Windowed)
  assert_true(op_span_kind(Slice(-1, None)) is Blocking)
  assert_true(op_span_kind(Slice(1, Some(-2))) is Blocking)
  assert_true(op_span_kind(GatherEvery(2, 0)) is Windowed)
  assert_true(op_span_kind(GatherEvery(0, 0)) is Blocking)
  assert_true(op_span_kind(WithRowIndex("i", 0L)) is Windowed)
}

///|
test "the engines raise the same error on a failing stage" {
  // A flow stage naming a missing column: the pipeline's per-batch run
  // and the interpreter's whole-frame run raise the same error on the
  // same first batch — error parity, not just value parity.
  let plan = LazyFrame::LazyFrame(pipeline_frame()).filter(
      @expr.col("nope").gt(@expr.lit_int(0)),
    ).plan
  let pipelined = Ok(ignore(plan.build_pipeline().run())) catch { e => Err(e) }
  let memoised = Ok(ignore(plan.execute_memoised())) catch { e => Err(e) }
  match (pipelined, memoised) {
    (Err(p), Err(m)) => assert_eq(p.to_string(), m.to_string())
    _ => fail("both engines were expected to fail")
  }
}

///|
test "a shared-subplan plan keeps the interpreter's path" {
  // A self-join sharing one LazyFrame value on both sides is a
  // DAG-shaped plan: `execute` falls back to the memoised interpreter
  // (each shared subplan runs once), and the answer agrees with the
  // pipeline the same plan would run tree-shaped.
  let shared = LazyFrame::LazyFrame(pipeline_frame()).filter(
    @expr.col("v").gt(@expr.lit_int(0)),
  )
  let dag = shared.join(shared, JoinOptions::on([@expr.col("k")])).plan
  assert_true(dag.has_shared_subplan())
  assert_agree(both_engines(dag))
}

///|
test "a DAG over a file source keeps the interpreter's read" {
  // The interpreter's file-scan half (its `drain_batches` walk) runs only
  // on the DAG fallback now — a tree-shaped plan's file source goes
  // through the pipeline's own cursor — so the shared-subplan shape here
  // sits on a file source: a silent driver answering one batch, joined
  // with itself.
  let silent = LazyFrame::file_scan(
    silent_driver(true),
    may_carry_temporal=false,
  ).select([@expr.lit_int(1).with_alias("v")])
  let dag = silent.join(silent, JoinOptions::on([@expr.col("v")])).plan
  assert_true(dag.has_shared_subplan())
  let (pipelined, memoised) = both_engines(dag)
  assert_eq(pipelined.shape(), memoised.shape())
}

///|
test "a DAG over a convenience aggregation keeps the interpreter's verb" {
  // The interpreter's `AggregateAll` arm runs only on the fallback too —
  // a shared frame on both sides of a join, aggregated whole.
  let shared = LazyFrame::LazyFrame(pipeline_frame()).select([
    @expr.col("k"),
    @expr.col("v"),
  ])
  let dag = shared
    .join(shared, JoinOptions::on([@expr.col("k")]))
    .group_by([@expr.col("k")])
    .sum().plan
  assert_true(dag.has_shared_subplan())
  assert_agree(both_engines(dag))
}

///|
test "a source coarser than the morsel cap answers in windows" {
  // An in-memory frame taller than the engine's row cap reaches the
  // spans in cap-sized batches — the stacked answer still equals
  // `collect`, cell for cell.
  let tall : Array[Int64?] = []
  for i in 0..<70_000 {
    tall.push(Some(i.to_int64()))
  }
  let frame = DataFrame::DataFrame([Series::from_int_options("v", tall)])
  let lf = LazyFrame::LazyFrame(frame).filter(
    @expr.col("v").gt(@expr.lit_int(-1)),
  )
  let stream = lf.collect_batches()
  let heights : Array[Int32] = []
  let mut stacked : DataFrame? = None
  while true {
    match stream.next() {
      Some(batch) => {
        heights.push(batch.nrows())
        stacked = match stacked {
          None => Some(batch)
          Some(acc) => Some(acc.vstack(batch))
        }
      }
      None => break
    }
  }
  // 70_000 rows over the 65_536 cap: a full morsel and the remainder.
  assert_eq(heights, [65_536, 4_464])
  match stacked {
    Some(acc) => {
      assert_eq(acc.shape(), lf.collect().shape())
      assert_eq(
        acc.get_column("v").to_scalars().length(),
        lf.collect().get_column("v").to_scalars().length(),
      )
    }
    None => fail("the stream answered no batch")
  }
}

///|
test "positional windows ride the flow across batch boundaries" {
  // A source coarser than the cap answers in two batches, and every
  // windowed verb keeps its place across the seam: the spans agree with
  // the interpreter cell for cell (which agrees with the eager chain —
  // the fuzz's own contract).
  let tall : Array[Int64?] = []
  for i in 0..<70_000 {
    tall.push(Some(i.to_int64()))
  }
  let frame = DataFrame::DataFrame([Series::from_int_options("v", tall)])
  let base = LazyFrame::LazyFrame(frame)
  // A forward count that ends past the first batch's seam.
  assert_agree(both_engines(base.head(66_000).plan))
  // A trailing window wider than the whole source.
  assert_agree(both_engines(base.tail(80_000).plan))
  // A trailing window that keeps a straddling front in its buffer.
  assert_agree(both_engines(base.tail(66_000).plan))
  // A forward slice whose window crosses the seam.
  assert_agree(both_engines(base.slice(65_530, length=12).plan))
  // A stride whose points fall in both batches.
  assert_agree(both_engines(base.gather_every(65_537, offset=3).plan))
  // A row numbering across the seam, from a non-zero offset.
  assert_agree(both_engines(base.with_row_index(name="idx", offset=41L).plan))
  // Windowed verbs chained: a tail flushed into a head's budget.
  assert_agree(both_engines(base.tail(66_500).head(100).plan))
}

///|
test "windowed shapes the eager path still owns" {
  // The far-end shapes keep the whole-frame path — the eager error and
  // the eager rows — and still agree between the engines.
  let base = LazyFrame::LazyFrame(pipeline_frame())
  assert_agree(both_engines(base.head(-2).plan))
  assert_agree(both_engines(base.tail(-2).plan))
  assert_agree(both_engines(base.slice(-1).plan))
}
