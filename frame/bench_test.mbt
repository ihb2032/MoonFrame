// Micro-benchmarks for `DataFrame` operators — filter, with_columns, unique,
// inner join, sort, and group-by aggregation. Run them with `moon bench`;
// under `moon test` every block executes once, so the benches stay compiled
// and cannot bit-rot.

///|
/// An `n`-row fact frame: an integer `key` with 1000 distinct groups, a
/// scrambled integer `value`, and a float `fvalue`. The scramble is a cheap
/// wrap-on-overflow hash (no RNG in this toolchain), so `value` is unsorted.
fn fact_frame(n : Int) -> DataFrame raise @types.DataError {
  let keys = Array::makei(n, i => (i % 1000).to_int64())
  let values = Array::makei(n, i => {
    let x = i.to_int64()
    (x * 2654435761L + 1013904223L) % 100000L
  })
  let fvalues = Array::makei(n, i => (i % 100000).to_double() * 1.5)
  DataFrame::new([
    Series::from_ints("key", keys),
    Series::from_ints("value", values),
    Series::from_floats("fvalue", fvalues),
  ])
}

///|
/// A `groups`-row dimension frame keyed by `key`, for the join benchmark.
fn dim_frame(groups : Int) -> DataFrame raise @types.DataError {
  DataFrame::new([
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
  b.bench(name="unique/\{n}", () => b.keep(df.unique()))
  b.bench(name="join/inner/1000-keys/\{n}", () => {
    b.keep(df.join(dim, JoinOptions::on([@expr.col("key")])) catch { _ => df })
  })
}

///|
test "frame sort scaling" (b : @bench.T) {
  for n in [1000, 100000, 1000000] {
    let df = fact_frame(n)
    b.bench(name="sort/value-asc/\{n}", () => {
      b.keep(df.sort([(@expr.col("value"), Asc, NullsLast)]) catch { _ => df })
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
