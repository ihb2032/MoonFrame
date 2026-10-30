// Micro-benchmarks contrasting eager and lazy execution of the same pipeline.
// The lazy path runs through the predicate/projection-pushdown optimizer
// before executing. Run them with `moon bench`; under `moon test` every block
// executes once, so the benches stay compiled and cannot bit-rot.

///|
/// An `n`-row fact frame: an integer `key` with 1000 distinct groups, a
/// scrambled integer `value`, and a float `fvalue`. Byte-identical twin of
/// the eager bench's fixture, so the eager side of each contrast below
/// matches the operator benches over there — change one, change both. (Each
/// blackbox test package has its own namespace, so the twin is a copy, not an
/// import.)
fn fact_frame(n : Int32) -> @frame.DataFrame raise @types.DataError {
  let keys = Array::makei(n, i => (i % 1000).to_int64())
  let values = Array::makei(n, i => {
    let x = i.to_int64()
    (x * 2654435761L + 1013904223L) % 100000L
  })
  let fvalues = Array::makei(n, i => (i % 100000).to_double() * 1.5)
  @frame.DataFrame::DataFrame([
    @series.Series::from_ints("key", keys),
    @series.Series::from_ints("value", values),
    @series.Series::from_floats("fvalue", fvalues),
  ])
}

///|
test "eager vs lazy: filter + group_by + sum @ 100k" (b : @bench.T) {
  let n = 100000
  let df = fact_frame(n)
  b.bench(name="eager/filter+groupby+sum/\{n}", () => {
    b.keep(
      df
      .filter(@expr.col("value").gt(@expr.lit_int(25000L)))
      .group_by([@expr.col("key")])
      .agg([@expr.col("value").sum()]) catch {
        _ => df
      },
    )
  })
  b.bench(name="lazy/filter+groupby+sum/\{n}", () => {
    b.keep(
      LazyFrame::LazyFrame(df)
      .filter(@expr.col("value").gt(@expr.lit_int(25000L)))
      .group_by([@expr.col("key")])
      .agg([@expr.col("value").sum()])
      .collect() catch {
        _ => df
      },
    )
  })
}

///|
test "lazy: projection + filter collect @ 100k" (b : @bench.T) {
  let n = 100000
  let df = fact_frame(n)
  b.bench(name="lazy/select+filter/\{n}", () => {
    b.keep(
      LazyFrame::LazyFrame(df)
      .filter(@expr.col("value").gt(@expr.lit_int(25000L)))
      .select([@expr.col("key"), @expr.col("value")])
      .collect() catch {
        _ => df
      },
    )
  })
}

///|
/// The star-share question, measured where it could cost: over a file
/// source. The same logical query spelled with a shared base — one
/// `scan_csv` value on both sides of the join, the natural CTE-style
/// reuse — against two independently built scans, whose optimizer runs
/// free (the shared plan's stands down). The measured answer at 100k rows
/// (eight columns, one filter, a two-column right projection): the shared
/// side WINS by a fifth — the memoised executor parses the file once for
/// both consumers, while the "optimised" independent pair parses it twice
/// (the absorbed filter still walks every row for its predicate columns,
/// and the narrowed right read is a second pass over the file). The
/// star-share exit is a tax only on shapes whose pushdown would save more
/// than a second parse — this pair pins the common shape where the
/// as-built DAG path is already the better deal, the number any
/// depth-limited DAG rewrite would have to beat before it is worth
/// building.
test "star-shared vs independent csv scans @ 100k" (b : @bench.T) {
  let n = 100000
  let fallback = fact_frame(1)
  let path = "_build/lazy_star_share_bench.csv"
  let buf = StringBuilder()
  buf.write_string("key,value,fvalue,c1,c2,c3,c4,c5\n")
  for i = 0; i < n; i = i + 1 {
    let x = i.to_int64()
    let value = (x * 2654435761L + 1013904223L) % 100000L
    buf.write_string(
      "\{i % 1000},\{value},\{(i % 100000) * 15},pad\{i},x,y,z,w\n",
    )
  }
  @fs.write_string_to_file(path, buf.to_string()) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  fn shared() -> @frame.DataFrame raise @types.DataError {
    let lf = scan_csv(path)
    lf
    .filter(@expr.col("value").gt(@expr.lit_int(25000L)))
    .join(
      lf.select([@expr.col("key"), @expr.col("fvalue")]),
      @frame.JoinOptions::on([@expr.col("key")]),
    )
    .collect()
  }
  fn independent() -> @frame.DataFrame raise @types.DataError {
    let l = scan_csv(path)
    let r = scan_csv(path)
    l
    .filter(@expr.col("value").gt(@expr.lit_int(25000L)))
    .join(
      r.select([@expr.col("key"), @expr.col("fvalue")]),
      @frame.JoinOptions::on([@expr.col("key")]),
    )
    .collect()
  }
  // The two spellings are the same query: their results agree before the
  // timings mean anything.
  assert_eq(shared(), independent())
  b.bench(name="star-shared/optimizer-stands-down/\{n}", () => {
    b.keep(shared() catch { _ => fallback })
  })
  b.bench(name="star-independent/pushdown-runs/\{n}", () => {
    b.keep(independent() catch { _ => fallback })
  })
}
