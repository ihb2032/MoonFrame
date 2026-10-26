///|
/// Blackbox battery for the projection pass — the top-down required-columns
/// analysis that narrows each scan source (an inserted `Select` over the
/// in-memory `Scan`, or the projection field written onto a `CSV` / `NDJSON`
/// file source) to the columns its consumers provably read. The
/// *equivalence* tests pin `collect ≡ eager` exactly on the pipelines where
/// the narrowing fires and the guards where it must not; the *structural*
/// tests snapshot `explain(optimized=true)` against the as-built
/// `explain()` — the before/after pair.

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
  let keys = [(@expr.col("bonus"), false, true)]
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
    LazyFrame::LazyFrame(df).slice(1, length=2).select(projection).collect(),
    df.slice(1, length=2).select(projection),
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
    .sort([(@expr.col("bonus"), false, true)])
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
    base.slice(1, length=2).select(qty).explain(optimized=true),
    "SELECT [col(qty)]\n" +
    "  SLICE [1: 2]\n" +
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
test "join splits its requirement: each side narrows to its own readers" {
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
  // A selection *above* the join splits its requirement across the sides:
  // the left keeps only its key column (`amount` is dead), while the right
  // needs its key and the selected `city` — its whole output, so its scan
  // narrows to nothing.
  let above = LazyFrame::LazyFrame(orders_df())
    .join(LazyFrame::LazyFrame(cities_df()), opts)
    .select([@expr.col("city")])
  assert_eq(
    above.explain(optimized=true),
    "SELECT [col(city)]\n" +
    "  JOIN Inner on [col(id)]\n" +
    "    SELECT [col(id)]\n" +
    "      SCAN [3×2]\n" +
    "    SCAN [3×2]",
  )
  assert_eq(
    above.collect(),
    orders_df().join(cities_df(), opts).select([@expr.col("city")]),
  )
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
// in-memory `Scan`, whose narrowing *inserts* a `SELECT`, a CSV file scan narrows
// in place: the projected columns ride on the node as `SCAN_CSV "path"
// [cols]`. The sibling tests pin the file-backed collect equivalences.

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

///|
test "a semi join narrows its right side to the key columns" {
  // The existence filters probe the right side and never emit its columns,
  // so a selection above the join leaves the right scan with nothing but
  // the join key — the one place a side narrows below its own readers.
  let l = orders_df()
  let r = cities_df()
  let plan = LazyFrame::LazyFrame(l)
    .join(
      LazyFrame::LazyFrame(r),
      @frame.JoinOptions::on([@expr.col("id")], how=Semi),
    )
    .select([@expr.col("amount")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(amount)]\n" +
    "  JOIN Semi on [col(id)]\n" +
    "    SCAN [3×2]\n" +
    "    SELECT [col(id)]\n" +
    "      SCAN [3×2]",
  )
  assert_eq(
    plan.collect(),
    l
    .join(r, @frame.JoinOptions::on([@expr.col("id")], how=Semi))
    .select([@expr.col("amount")]),
  )
}

///|
test "a required suffixed right name narrows the right side to its source" {
  // A clash renames the right `amount` to `amount_right` in the join
  // output; the selection reading the suffixed spelling maps back to the
  // right source column, so the right side keeps key and `amount` while
  // its unrelated `extra` is dead. The left keeps its clashing `amount`
  // too — the clash only stands while both columns exist, so the left
  // column is load-bearing (dead itself, but narrowing it would rename the
  // right one back to bare `amount` and break the selection).
  let l = orders_df()
  let r = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [2, 3, 4]),
    @series.Series::from_ints("amount", [1, 2, 3]),
    @series.Series::from_strings("extra", ["x", "y", "z"]),
  ])
  let opts = @frame.JoinOptions::on([@expr.col("id")])
  let plan = LazyFrame::LazyFrame(l)
    .join(LazyFrame::LazyFrame(r), opts)
    .select([@expr.col("amount_right")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(amount_right)]\n" +
    "  JOIN Inner on [col(id)]\n" +
    "    SCAN [3×2]\n" +
    "    SELECT [col(id), col(amount)]\n" +
    "      SCAN [3×3]",
  )
  assert_eq(plan.collect(), l.join(r, opts).select([@expr.col("amount_right")]))
}

///|
test "a file source side keeps its whole read (its names are unknowable)" {
  // A file source's header exists only at collect, so a requirement cannot
  // be attributed to that side — it reads every column (no projection is
  // written), the barrier treatment, while the left side narrows to key
  // and selection.
  let l = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2, 3]),
    @series.Series::from_ints("amount", [10, 20, 30]),
    @series.Series::from_strings("note", ["a", "b", "c"]),
  ])
  let plan = l
    |> LazyFrame::LazyFrame
    |> lf => {
      lf.join(scan_csv("cities.csv"), @frame.JoinOptions::on([@expr.col("id")]))
    }
    |> lf => { lf.select([@expr.col("amount")]) }
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(amount)]\n" +
    "  JOIN Inner on [col(id)]\n" +
    "    SELECT [col(id), col(amount)]\n" +
    "      SCAN [3×3]\n" +
    "    SCAN_CSV \"cities.csv\"",
  )
}

///|
test "a sided-key join splits its requirement through the paired keys" {
  // `left_on` / `right_on` read different columns on the two sides — the
  // key reads are per-side here, unlike an `on` join's shared list. Each
  // side keeps its key plus the selection's column; the unrelated
  // (`id` on the left, `extra` on the right) narrows away.
  let l = orders_df()
  let r = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("n", [20, 30, 40]),
    @series.Series::from_strings("tag", ["p", "q", "r"]),
    @series.Series::from_strings("extra", ["x", "y", "z"]),
  ])
  let opts = @frame.JoinOptions::left_on([@expr.col("amount")], right_on=[
    @expr.col("n"),
  ])
  let plan = LazyFrame::LazyFrame(l)
    .join(LazyFrame::LazyFrame(r), opts)
    .select([@expr.col("tag")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(tag)]\n" +
    "  JOIN Inner left_on [col(amount)] right_on [col(n)]\n" +
    "    SELECT [col(amount)]\n" +
    "      SCAN [3×2]\n" +
    "    SELECT [col(n), col(tag)]\n" +
    "      SCAN [3×3]",
  )
  assert_eq(plan.collect(), l.join(r, opts).select([@expr.col("tag")]))
}

///|
test "a derived on-key and an unknowable left side keep their sides whole" {
  // A derived key (`on` over a computed expression) names no column of
  // its own, and a file source on the *left* has no knowable names — the
  // left side keeps everything it has, while the right side still narrows
  // to its key reads (a derived key's referenced columns) plus the
  // selection, dropping its unrelated `note`.
  let r = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2, 3]),
    @series.Series::from_ints("amount", [10, 20, 30]),
    @series.Series::from_strings("note", ["a", "b", "c"]),
  ])
  let opts = @frame.JoinOptions::on([@expr.col("id") + @expr.lit_int(0)])
  let plan = scan_csv("orders.csv")
    .join(LazyFrame::LazyFrame(r), opts)
    .select([@expr.col("amount")])
  assert_eq(
    plan.explain(optimized=true),
    "SELECT [col(amount)]\n" +
    "  JOIN Inner on [(col(id) + 0)]\n" +
    "    SCAN_CSV \"orders.csv\"\n" +
    "    SELECT [col(id), col(amount)]\n" +
    "      SCAN [3×3]",
  )
}

///|
test "a deep unary chain under a join collects without overflowing: output_names is iterative" {
  // The name walk rides collect through the joins' requirement splits; its
  // `Unary` arm formerly recursed, so a 20 000-deep select chain under a
  // join with a by-name reader above overflowed the native stack and
  // aborted. The post-order value-stack fold keeps every walk on the heap.
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a", [1, 2, 3]),
    @series.Series::from_ints("b", [10, 20, 30]),
  ])
  let right = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("a", [1, 2, 3]),
    @series.Series::from_strings("junk", ["x", "y", "z"]),
  ])
  let mut lf = LazyFrame::LazyFrame(df)
  for _ in 0..<20000 {
    lf = lf.select([@expr.col("a"), @expr.col("b")])
  }
  let joined = lf
    .join(LazyFrame::LazyFrame(right), @frame.JoinOptions::on([@expr.col("a")]))
    .select([@expr.col("b")])
  assert_eq(joined.collect().shape(), (3, 1))
}

///|
test "a narrowed join keeps the suffix clash that fails the full join" {
  // left natively carries `value_right`; right's `value` renames to exactly
  // that spelling through the clash, so the full join raises
  // `DuplicateColumn` at collect. The requirement split must not dissolve
  // the clash by dropping both participants when no consumer reads them —
  // a plan that fails to collect still fails after optimization.
  let left = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2]),
    @series.Series::from_ints("value", [10, 20]),
    @series.Series::from_ints("value_right", [100, 200]),
  ])
  let right = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2]),
    @series.Series::from_ints("value", [7, 8]),
    @series.Series::from_strings("junk", ["x", "y"]),
  ])
  let opts = @frame.JoinOptions::on([@expr.col("id")])
  // The eager join fails on the double `value_right`.
  assert_true(
    (Ok(left.join(right, opts)) catch { e => Err(e) })
    is Err(@types.DataError::DuplicateColumn(_)),
  )
  // The lazy plan with no by-name reader keeps that failure.
  let unread = LazyFrame::LazyFrame(left).join(
    LazyFrame::LazyFrame(right),
    opts,
  )
  assert_true(
    (Ok(unread.collect()) catch { e => Err(e) })
    is Err(@types.DataError::DuplicateColumn(_)),
  )
  // And a reader of an unrelated column cannot dissolve it either: the
  // clash's participants are pinned into both sides' requirements.
  let narrowed = LazyFrame::LazyFrame(left)
    .join(LazyFrame::LazyFrame(right), opts)
    .select([@expr.col("junk")])
  assert_true(
    (Ok(narrowed.collect()) catch { e => Err(e) })
    is Err(@types.DataError::DuplicateColumn(_)),
  )
  // The same clash spelling arising inside the right frame alone — its
  // `value` renames onto its own native `value_right` — is pinned too.
  let right_native = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2]),
    @series.Series::from_ints("value", [7, 8]),
    @series.Series::from_ints("value_right", [70, 80]),
  ])
  let inner_clash = LazyFrame::LazyFrame(left)
    .join(LazyFrame::LazyFrame(right_native), opts)
    .select([@expr.col("junk")])
  assert_true(
    (Ok(inner_clash.collect()) catch { e => Err(e) })
    is Err(@types.DataError::DuplicateColumn(_)),
  )
}

///|
test "a right join's projection narrows both sides with the rename swapped" {
  // The swapped-left-join reading moves the suffix onto the left side, so
  // the requirement split runs with the sides exchanged: the right side's
  // requirement is the plain by-name one, the left's may map a suffixed
  // spelling back. Collect parity pins the narrowing against the eager
  // reading.
  let l = orders_df()
  let r = cities_df()
  let opts = @frame.JoinOptions::on([@expr.col("id")], how=Right)
  let narrowed = LazyFrame::LazyFrame(l)
    .join(LazyFrame::LazyFrame(r), opts)
    .select([@expr.col("city")])
  assert_eq(narrowed.collect(), l.join(r, opts).select([@expr.col("city")]))
  // The clash side: a left `city` would ride suffixed, and a select of
  // that suffixed spelling maps back onto the left column.
  let l_city = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("id", [1, 2]),
    @series.Series::from_strings("city", ["oslo", "lima"]),
  ])
  let clash_opts = @frame.JoinOptions::on([@expr.col("id")], how=Right)
  let suffixed = LazyFrame::LazyFrame(l_city)
    .join(LazyFrame::LazyFrame(r), clash_opts)
    .select([@expr.col("city_right")])
  assert_eq(
    suffixed.collect(),
    l_city.join(r, clash_opts).select([@expr.col("city_right")]),
  )
}
