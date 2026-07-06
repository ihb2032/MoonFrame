// Micro-benchmarks for the `Series` layer — the `Numeric` fast path against
// the general `Builtin` backend, plus construction and windowing. Run them
// with `moon bench`; under `moon test` every block executes once, so the
// benches stay compiled and cannot bit-rot.

///|
/// Deterministic scrambled `Int64` data of length `n`. A cheap wrap-on-
/// overflow hash stands in for an RNG (unavailable in this toolchain), so keys
/// are unsorted and spread across ~100k distinct values.
fn scrambled_ints(n : Int) -> Array[Int64] {
  Array::makei(n, i => {
    let x = i.to_int64()
    (x * 2654435761L + 1013904223L) % 100000L
  })
}

///|
/// Deterministic `Double` data of length `n`.
fn scrambled_floats(n : Int) -> Array[Double] {
  Array::makei(n, i => (i % 100000).to_double() * 1.5)
}

///|
test "series construction: Numeric vs Builtin vs Float" (b : @bench.T) {
  for n in [1000, 100000, 1000000] {
    let ints = scrambled_ints(n)
    let floats = scrambled_floats(n)
    b.bench(name="construct/from_ints(numeric)/\{n}", () => {
      b.keep(Series::from_ints("x", ints))
    })
    b.bench(name="construct/from_builtin(builtin)/\{n}", () => {
      b.keep(Series::from_builtin("x", @column.BuiltinColumn::from_ints(ints)))
    })
    b.bench(name="construct/from_floats/\{n}", () => {
      b.keep(Series::from_floats("x", floats))
    })
  }
}

///|
test "series reductions: Numeric fast path vs Builtin" (b : @bench.T) {
  for n in [1000, 100000, 1000000] {
    let ints = scrambled_ints(n)
    let numeric = Series::from_ints("x", ints)
    let builtin = Series::from_builtin(
      "x",
      @column.BuiltinColumn::from_ints(ints),
    )
    b.bench(name="sum/numeric/\{n}", () => {
      b.keep(numeric.sum() catch { _ => @types.Scalar::Null })
    })
    b.bench(name="sum/builtin/\{n}", () => {
      b.keep(builtin.sum() catch { _ => @types.Scalar::Null })
    })
    b.bench(name="mean/numeric/\{n}", () => {
      b.keep(numeric.mean() catch { _ => 0.0 })
    })
    b.bench(name="mean/builtin/\{n}", () => {
      b.keep(builtin.mean() catch { _ => 0.0 })
    })
    b.bench(name="min/numeric/\{n}", () => b.keep(numeric.min()))
    b.bench(name="min/builtin/\{n}", () => b.keep(builtin.min()))
    b.bench(name="max/numeric/\{n}", () => b.keep(numeric.max()))
    b.bench(name="count/numeric/\{n}", () => b.keep(numeric.count()))
  }
}

///|
test "series windowing: gather / slice" (b : @bench.T) {
  let n = 100000
  let s = Series::from_ints("x", scrambled_ints(n))
  let reverse = Array::makei(n, i => n - 1 - i)
  b.bench(name="gather/reverse/\{n}", () => b.keep(gather_series(s, reverse)))
  b.bench(name="slice/first-half/\{n}", () => b.keep(slice_series(s, 0, n / 2)))
}
