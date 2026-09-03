///|
/// Blackbox battery for the projection pass — the top-down required-columns
/// analysis that narrows each scan source (an inserted `Select` over the
/// in-memory `Scan`, or the projection field written onto a `CSV` / `NDJSON`
/// file source) to the columns its consumers provably read. The
/// *equivalence* tests pin `collect ≡ eager` exactly on the pipelines where
/// the narrowing fires and the guards where it must not; the *structural*
/// tests snapshot `explain(optimized=true)` against the as-built
/// `explain()` — the before/after pair. The predicate pass's battery lives
/// in `optimize_predicates_test.mbt`, the cross-pass shapes in
/// `optimize_test.mbt`; the shared fixture frames live in `lazy_test.mbt`.

///|
test "narrowed scan: a single-column selection still collects equal" {
  let df = sales_df()
  // Only `qty` is read; `bonus` / `region` are pruned at the scan.
  let exprs = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")]
  let out = LazyFrame::LazyFrame(df).select(exprs).collect()
  assert_eq(out, df.select(exprs))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "filter predicate columns stay alive through the pushdown" {
  let df = sales_df()
  // The selection reads `region` only, but the filter needs `qty`: the
  // narrowed scan must keep both (and may drop `bonus`).
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let projection = [@expr.col("region")]
  assert_eq(
    LazyFrame::LazyFrame(df).filter(predicate).select(projection).collect(),
    df.filter(predicate).select(projection),
  )
}

///|
test "a ternary's condition columns stay alive through the pushdown" {
  let df = sales_df()
  // The label only *outputs* literal/region values, but its condition
  // reads `qty` — `referenced_columns` must keep it in the scan.
  let label = @expr.when(@expr.col("qty").gt(@expr.lit_int(100)))
    .then(@expr.lit_str("big"))
    .otherwise(@expr.col("region"))
    .with_alias("label")
  assert_eq(
    LazyFrame::LazyFrame(df).select([label]).collect(),
    df.select([label]),
  )
}

///|
test "with_columns replacement: narrowing turns replace into append, by-name reads agree" {
  let df = sales_df()
  // `bonus` is *redefined* from `qty`, then read by the selection. The
  // pushdown drops the original `bonus` from the scan (a defined name is
  // served by the with_columns stage itself), so the eager side replaces
  // in place while the optimized side appends — and the by-name
  // selection above must make the difference unobservable.
  let redefine = [(@expr.col("qty") * @expr.lit_int(2)).with_alias("bonus")]
  let projection = [@expr.col("bonus"), @expr.col("region")]
  assert_eq(
    LazyFrame::LazyFrame(df).with_columns(redefine).select(projection).collect(),
    df.with_columns(redefine).select(projection),
  )
}

///|
test "with_columns: a brand-new derived name needs nothing from the scan" {
  let df = sales_df()
  let fresh = [(@expr.col("qty") + @expr.lit_int(1)).with_alias("next")]
  let projection = [@expr.col("next")]
  assert_eq(
    LazyFrame::LazyFrame(df).with_columns(fresh).select(projection).collect(),
    df.with_columns(fresh).select(projection),
  )
}

///|
test "aggregate prunes columns no key or aggregation reads" {
  let df = sales_df()
  // Keys read `region`, the aggregations read `qty` — `bonus` is dead.
  let aggs = [
    @expr.col("qty").sum().with_alias("total"),
    (@expr.col("qty").max() - @expr.col("qty").min()).with_alias("spread"),
  ]
  assert_eq(
    LazyFrame::LazyFrame(df).group_by([@expr.col("region")]).agg(aggs).collect(),
    df.group_by([@expr.col("region")]).agg(aggs),
  )
}

///|
test "sort keys stay alive through the pushdown" {
  let df = sales_df()
  let keys = [
    (@expr.col("bonus"), @types.SortOrder::Asc, @types.NullOrder::NullsLast),
  ]
  let projection = [@expr.col("region")]
  assert_eq(
    LazyFrame::LazyFrame(df).sort(keys).select(projection).collect(),
    df.sort(keys).select(projection),
  )
}

///|
test "row windows pass the requirement through to the scan" {
  let df = sales_df()
  let projection = [@expr.col("qty")]
  assert_eq(
    LazyFrame::LazyFrame(df).head(2).select(projection).collect(),
    df.head(2).select(projection),
  )
  assert_eq(
    LazyFrame::LazyFrame(df).tail(2).select(projection).collect(),
    df.tail(2).select(projection),
  )
  assert_eq(
    LazyFrame::LazyFrame(df).slice(1, 3).select(projection).collect(),
    df.slice(1, 3).select(projection),
  )
}

///|
test "join sides narrow independently below the barrier" {
  let l = orders_df()
  let r = cities_df()
  let opts = @frame.JoinOptions::on([@expr.col("id")])
  // The left side's own selection prunes `amount` before the join.
  assert_eq(
    LazyFrame::LazyFrame(l)
    .select([@expr.col("id")])
    .join(LazyFrame::LazyFrame(r), opts)
    .collect(),
    l.select([@expr.col("id")]).join(r, opts),
  )
  // A selection *above* the join must not narrow either side.
  assert_eq(
    LazyFrame::LazyFrame(l)
    .join(LazyFrame::LazyFrame(r), opts)
    .select([@expr.col("city")])
    .collect(),
    l.join(r, opts).select([@expr.col("city")]),
  )
}

///|
test "guard: an all-literal selection inserts nothing and still collapses to one row" {
  let df = sales_df()
  let one = [@expr.lit_int(1).with_alias("one")]
  let out = LazyFrame::LazyFrame(df).select(one).collect()
  assert_eq(out, df.select(one))
  assert_eq(out.nrows(), 1)
}

///|
test "guard: a selection reading every column leaves the scan whole" {
  let df = sales_df()
  let all = [@expr.col("qty"), @expr.col("bonus"), @expr.col("region")]
  assert_eq(LazyFrame::LazyFrame(df).select(all).collect(), df.select(all))
}

///|
test "the flagship pipeline narrows through every stage" {
  let df = sales_df()
  let predicate = @expr.col("region").eq(@expr.lit_str("west"))
  let derived = [(@expr.col("qty") * @expr.lit_int(3)).with_alias("adj")]
  let projection = [@expr.col("adj")]
  let out = LazyFrame::LazyFrame(df)
    .filter(predicate)
    .with_columns(derived)
    .select(projection)
    .collect()
  assert_eq(out, df.filter(predicate).with_columns(derived).select(projection))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "a zero-row frame narrows and collects equal" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a", []),
    @series.Series::from_strings("b", []),
  ])
  let projection = [@expr.col("a")]
  let out = LazyFrame::LazyFrame(df).select(projection).collect()
  assert_eq(out, df.select(projection))
  assert_eq(out.nrows(), 0)
}

///|
test "errors keep surfacing at collect time, unchanged by the rewrite" {
  let df = sales_df()
  // A missing column in the selection: the inserted narrowing select
  // keeps only existing columns, so the user's expression still reports
  // the same `ColumnNotFound`.
  assert_eq(
    Ok(LazyFrame::LazyFrame(df).select([@expr.col("ghost")]).collect()) catch {
      e => Err(e)
    },
    Err(@types.DataError::ColumnNotFound("ghost")),
  )
  // A missing column in a filter under a selection: parity with eager.
  let predicate = @expr.col("ghost").is_null()
  let projection = [@expr.col("qty")]
  assert_eq(
    Ok(LazyFrame::LazyFrame(df).filter(predicate).select(projection).collect()) catch {
      e => Err(e)
    },
    Ok(df.filter(predicate).select(projection)) catch {
      e => Err(e)
    },
  )
}

///|
test "a bare scan is untouched (no requirement at the root)" {
  assert_eq(
    LazyFrame::LazyFrame(sales_df()).explain(optimized=true),
    "SCAN [4×3]",
  )
}

///|
test "select: a proper-subset requirement narrows the scan, in scan column order" {
  let plan = LazyFrame::LazyFrame(sales_df()).select([
    (@expr.col("bonus") + @expr.col("qty")).with_alias("t"),
  ])
  // The inserted projection follows the *frame's* column order
  // (qty before bonus), not the expression's reference order.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [(col(bonus) + col(qty)) as t]\n" +
    "  SELECT [col(qty), col(bonus)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "select guard: reading every column inserts nothing" {
  let plan = LazyFrame::LazyFrame(sales_df()).select([
    @expr.col("qty"),
    @expr.col("bonus"),
    @expr.col("region"),
  ])
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "select guard: an all-literal selection inserts nothing" {
  let plan = LazyFrame::LazyFrame(sales_df()).select([
    @expr.lit_int(1).with_alias("one"),
  ])
  assert_eq(plan.explain(optimized=true), "SELECT [1 as one]\n  SCAN [4×3]")
}

///|
test "select: a missing column is not kept alive, the rest narrow as usual" {
  let plan = LazyFrame::LazyFrame(sales_df()).select([
    @expr.col("qty"),
    @expr.col("ghost"),
  ])
  // `ghost` exists nowhere, so only `qty` survives at the scan; the
  // user's expression still raises its own `ColumnNotFound` at collect.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty), col(ghost)]\n" +
    "  SELECT [col(qty)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "filter: the requirement passes through, widened by the predicate's columns" {
  let predicate = @expr.col("qty").gt(@expr.lit_int(50))
  let plan = LazyFrame::LazyFrame(sales_df())
    .filter(predicate)
    .select([@expr.col("region")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n" +
    "  FILTER (col(qty) > 50)\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
  // At the root the requirement is unbounded: a bare filter's layout may
  // be observed in full, so nothing narrows.
  let bare = LazyFrame::LazyFrame(sales_df()).filter(predicate)
  assert_eq(bare.explain(optimized=true), bare.explain())
}

///|
test "sort: the requirement passes through, widened by the sort keys" {
  let plan = LazyFrame::LazyFrame(sales_df())
    .sort([
      (@expr.col("bonus"), @types.SortOrder::Asc, @types.NullOrder::NullsLast),
    ])
    .select([@expr.col("qty")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  SORT [col(bonus) Asc NullsLast]\n" +
    "    SELECT [col(qty), col(bonus)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "row windows pass the requirement through verbatim" {
  let base = LazyFrame::LazyFrame(sales_df())
  let qty = [@expr.col("qty")]
  assert_eq(
    base.head(2).select(qty).explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  HEAD 2\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    base.tail(1).select(qty).explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  TAIL 1\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
  assert_eq(
    base.slice(1, 3).select(qty).explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  SLICE [1, 3)\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns: defined names are subtracted, read names added" {
  let plan = LazyFrame::LazyFrame(sales_df())
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl")])
    .select([@expr.col("dbl"), @expr.col("region")])
  // `dbl` is served by the with_columns stage itself; the scan only owes
  // `region` (selected) and `qty` (read by the derivation).
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(dbl), col(region)]\n" +
    "  WITH_COLUMNS [(col(qty) * 2) as dbl]\n" +
    "    SELECT [col(qty), col(region)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns: redefining a selected column keeps only what it reads" {
  let plan = LazyFrame::LazyFrame(sales_df())
    .with_columns([(@expr.col("qty") * @expr.lit_int(2)).with_alias("bonus")])
    .select([@expr.col("bonus")])
  // The selected `bonus` is a *defined* name: the original scan column
  // is dead, and only the derivation's input `qty` survives.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(bonus)]\n" +
    "  WITH_COLUMNS [(col(qty) * 2) as bonus]\n" +
    "    SELECT [col(qty)]\n" +
    "      SCAN [4×3]",
  )
}

///|
test "with_columns at the root is a no-op (its full layout is the result)" {
  let plan = LazyFrame::LazyFrame(sales_df()).with_columns([
    (@expr.col("qty") * @expr.lit_int(2)).with_alias("dbl"),
  ])
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "join is a barrier, but each side restarts its own pass" {
  let opts = @frame.JoinOptions::on([@expr.col("id")])
  // A selection *below* the left side narrows that side's scan — the bare
  // `select` is itself that narrowing, so nothing is inserted beneath it.
  let narrowed_side = LazyFrame::LazyFrame(orders_df())
    .select([@expr.col("id")])
    .join(LazyFrame::LazyFrame(cities_df()), opts)
  assert_eq(
    narrowed_side.explain(optimized=true),
    "JOIN Inner on [col(id)]\n" +
    "  SELECT [col(id)]\n" +
    "    SCAN [3×2]\n" +
    "  SCAN [3×2]",
  )
  // A selection *above* the join narrows neither side: splitting a
  // requirement across suffix-renamed sides is O2-grade provenance.
  let above = LazyFrame::LazyFrame(orders_df())
    .join(LazyFrame::LazyFrame(cities_df()), opts)
    .select([@expr.col("city")])
  assert_eq(above.explain(optimized=true), above.explain())
}

///|
test "aggregate: keys and aggregation reads survive, the rest narrows" {
  let plan = LazyFrame::LazyFrame(sales_df())
    .group_by([@expr.col("region")])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total] BY [col(region)]\n" +
    "  SELECT [col(qty), col(region)]\n" +
    "    SCAN [4×3]",
  )
}

///|
test "aggregate guard: reading every column inserts nothing" {
  let plan = LazyFrame::LazyFrame(sales_df())
    .group_by([@expr.col("region")])
    .agg([
      @expr.col("qty").sum().with_alias("a"),
      @expr.col("bonus").max().with_alias("b"),
    ])
  assert_eq(plan.explain(optimized=true), plan.explain())
}

///|
test "nested selects: the outer requirement never prunes the inner expression list" {
  let plan = LazyFrame::LazyFrame(sales_df())
    .select([
      (@expr.col("qty") + @expr.col("bonus")).with_alias("t"),
      @expr.col("region"),
    ])
    .select([@expr.col("t")])
  // Dead-expression elimination is deferred: the inner select still
  // evaluates `region`, and — reading every scan column — it also
  // inserts nothing below itself.
  assert_eq(plan.explain(optimized=true), plan.explain())
}

// ── The CSV source's projection push-down ────────────────────────────────
//
// Structural snapshots only — `explain` never reads the file. Unlike the
// in-memory `Scan`, whose narrowing *inserts* a `SELECT`, a CSV scan (`Scan(Csv(...))`) narrows
// in place: the projected columns ride on the node as `SCAN_CSV "path"
// [cols]`. The file-backed collect equivalences live in `scan_csv_test.mbt`.

///|
test "scan_csv: a selection writes its columns into the scan, no inserted select" {
  let plan = scan_csv("sales.csv").select([@expr.col("region")])
  // As built there is no projection; optimized, the read narrows in place —
  // and (unlike an in-memory Scan) no extra SELECT is inserted.
  assert_eq(plan.explain(), "SELECT [col(region)]\n  SCAN_CSV \"sales.csv\"")
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n  SCAN_CSV \"sales.csv\" [region]",
  )
}

///|
test "scan_csv: the written projection is sorted for a deterministic explain" {
  // One expression reads two columns; the file's order is unknown at optimize
  // time, so the projection is sorted (bonus before qty).
  let plan = scan_csv("sales.csv").select([
    (@expr.col("qty") + @expr.col("bonus")).with_alias("t"),
  ])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [(col(qty) + col(bonus)) as t]\n" +
    "  SCAN_CSV \"sales.csv\" [bonus, qty]",
  )
}

///|
test "scan_csv guard: an all-literal selection writes no projection" {
  let plan = scan_csv("sales.csv").select([@expr.lit_int(1).with_alias("one")])
  // No source column is read, so the scan stays whole — it still yields rows.
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [1 as one]\n  SCAN_CSV \"sales.csv\"",
  )
}

///|
test "scan_csv: a bare scan at the root writes no projection" {
  assert_eq(
    scan_csv("sales.csv").explain(optimized=true),
    "SCAN_CSV \"sales.csv\"",
  )
}

///|
test "scan_csv: an aggregation narrows the scan to its keys and reads" {
  let plan = scan_csv("sales.csv")
    .group_by([@expr.col("region")])
    .agg([@expr.col("qty").sum().with_alias("total")])
  assert_eq(
    plan.explain(optimized=true),
    "AGGREGATE [col(qty).sum() as total] BY [col(region)]\n" +
    "  SCAN_CSV \"sales.csv\" [qty, region]",
  )
}

///|
test "scan_ndjson narrows in place like scan_csv, only the label differs" {
  // The shared narrow_scan / render_scan_source path serves both sources, so a
  // selection writes the projection straight onto the SCAN_NDJSON node.
  let plan = scan_ndjson("events.ndjson").select([@expr.col("region")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(region)]\n  SCAN_NDJSON \"events.ndjson\" [region]",
  )
  // A filter is absorbed here too, leaving the projection at the consumer's
  // own columns.
  let with_filter = scan_ndjson("events.ndjson")
    .filter(@expr.col("qty").gt(@expr.lit_int(50)))
    .select([@expr.col("region")])
  assert_eq(
    with_filter.explain(optimized=true),
    "SELECT [col(region)]\n" +
    "  SCAN_NDJSON \"events.ndjson\" [region] WHERE (col(qty) > 50)",
  )
  // Bare at the root: no requirement, so no projection is written.
  assert_eq(
    scan_ndjson("events.ndjson").explain(optimized=true),
    "SCAN_NDJSON \"events.ndjson\"",
  )
}
