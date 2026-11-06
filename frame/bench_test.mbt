// Micro-benchmarks for `DataFrame` operators — filter, with_columns, unique,
// inner join, sort, and group-by aggregation. Run them with `moon bench`;
// under `moon test` every block executes once, so the benches stay compiled
// and cannot bit-rot.

///|
/// An `n`-row fact frame: an integer `key` with 1000 distinct groups, a
/// scrambled integer `value`, and a float `fvalue`. The scramble is a cheap
/// wrap-on-overflow hash (no RNG in this toolchain), so `value` is unsorted.
/// Byte-identical twin: the lazy bench builds the same rows so its
/// eager-vs-lazy contrast stays comparable to these operator benches —
/// change one, change both.
fn fact_frame(n : Int32) -> DataFrame raise @types.DataError {
  let keys = Array::makei(n, i => (i % 1000).to_int64())
  let values = Array::makei(n, i => {
    let x = i.to_int64()
    (x * 2654435761L + 1013904223L) % 100000L
  })
  let fvalues = Array::makei(n, i => (i % 100000).to_double() * 1.5)
  DataFrame::DataFrame([
    Series::from_ints("key", keys),
    Series::from_ints("value", values),
    Series::from_floats("fvalue", fvalues),
  ])
}

///|
/// A `groups`-row dimension frame keyed by `key`, for the join benchmark.
fn dim_frame(groups : Int32) -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_ints("key", Array::makei(groups, i => i.to_int64())),
    Series::from_strings("kname", Array::makei(groups, i => "g\{i}")),
  ])
}

///|
test "frame light operators @ 100k" (b : @bench.T) {
  let n = 100000
  let df = fact_frame(n)
  let dim = dim_frame(1000)
  b.bench(name="filter/value>50k/\{n}", () => {
    b.keep(
      df.filter(@expr.col("value").gt(@expr.lit_int(50000L))) catch {
        _ => df
      },
    )
  })
  b.bench(name="with_columns/derived-bool/\{n}", () => {
    b.keep(
      df.with_columns([
        @expr.col("value").gt(@expr.lit_int(50000L)).with_alias("hot"),
      ]) catch {
        _ => df
      },
    )
  })
  b.bench(name="unique/\{n}", () => b.keep(df.unique() catch { _ => df }))
  b.bench(name="join/inner/1000-keys/\{n}", () => {
    b.keep(df.join(dim, JoinOptions::on([@expr.col("key")])) catch { _ => df })
  })
}

///|
test "frame sort scaling" (b : @bench.T) {
  for n in [1000, 100000, 1000000] {
    let df = fact_frame(n)
    b.bench(name="sort/value-asc/\{n}", () => {
      b.keep(df.sort([(@expr.col("value"), false, true)]) catch { _ => df })
    })
  }
}

///|
test "frame group_by+sum scaling" (b : @bench.T) {
  for n in [1000, 100000, 1000000] {
    let df = fact_frame(n)
    b.bench(name="group_by+sum/1000-groups/\{n}", () => {
      b.keep(
        df.group_by([@expr.col("key")]).agg([@expr.col("value").sum()]) catch {
          _ => df
        },
      )
    })
  }
}

// Micro-benchmarks contrasting eager and lazy execution of the same pipeline.
// The lazy path runs through the predicate/projection-pushdown optimizer
// before executing. Run them with `moon bench`; under `moon test` every block
// executes once, so the benches stay compiled and cannot bit-rot.
// The fixture `fact_frame` above is shared with the eager benches, so the
// eager side of each contrast below matches the operator benches over
// there — change one, change both.

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
  fn shared() -> DataFrame raise @types.DataError {
    let lf = @io.scan_csv(path)
    lf
    .filter(@expr.col("value").gt(@expr.lit_int(25000L)))
    .join(
      lf.select([@expr.col("key"), @expr.col("fvalue")]),
      JoinOptions::on([@expr.col("key")]),
    )
    .collect()
  }
  fn independent() -> DataFrame raise @types.DataError {
    let l = @io.scan_csv(path)
    let r = @io.scan_csv(path)
    l
    .filter(@expr.col("value").gt(@expr.lit_int(25000L)))
    .join(
      r.select([@expr.col("key"), @expr.col("fvalue")]),
      JoinOptions::on([@expr.col("key")]),
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
