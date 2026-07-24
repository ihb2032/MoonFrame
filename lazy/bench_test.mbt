// Micro-benchmarks contrasting eager and lazy execution of the same pipeline.
// The lazy path runs through the predicate/projection-pushdown optimizer
// before executing. Run them with `moon bench`; under `moon test` every block
// executes once, so the benches stay compiled and cannot bit-rot.

///|
/// An `n`-row fact frame: an integer `key` with 1000 distinct groups, a
/// scrambled integer `value`, and a float `fvalue`.
fn fact_frame(n : Int) -> @frame.DataFrame raise @types.DataError {
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
