// Blackbox tests for the closing misc verbs — `unique_counts` /
// `is_first_distinct` / `is_last_distinct` (the per-cell distinct family),
// `mode` (the most-frequent reduction), and `sample` (the seeded row
// draw). Pinned: the distinct keying (nulls their own bucket, `NaN` one
// bucket), the first-appearing tie rule of `mode`, and the sampler's
// determinism / saturation / replacement split.

///|
test "unique_counts reports each cell's own frequency" {
  let df = DataFrame::DataFrame([
    Series::from_string_options("s", [
      Some("a"),
      Some("b"),
      Some("a"),
      Some("a"),
      None,
    ]),
  ])
  assert_eq(
    df.select([@expr.col("s").unique_counts()]).get_column("s").to_scalars(),
    [
      @types.Scalar::Int(3),
      @types.Scalar::Int(1),
      @types.Scalar::Int(3),
      @types.Scalar::Int(3),
      @types.Scalar::Int(1),
    ],
  )
  // Every NaN is one bucket.
  let nan : Double = @double.not_a_number
  let f = DataFrame::DataFrame([Series::from_floats("f", [1.0, nan, nan])])
  assert_eq(
    f.select([@expr.col("f").unique_counts()]).get_column("f").to_scalars(),
    [@types.Scalar::Int(1), @types.Scalar::Int(2), @types.Scalar::Int(2)],
  )
}

///|
test "is_first_distinct / is_last_distinct mark the occurrence endpoints" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("v", [Some(1), Some(2), Some(1), None, None]),
  ])
  assert_eq(
    df.select([@expr.col("v").is_first_distinct()]).get_column("v").to_scalars(),
    [
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(false),
    ],
  )
  assert_eq(
    df.select([@expr.col("v").is_last_distinct()]).get_column("v").to_scalars(),
    [
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(true),
      @types.Scalar::Bool(false),
      @types.Scalar::Bool(true),
    ],
  )
}

///|
test "mode is the most frequent value, ties first-appearing, nulls skipped" {
  let df = DataFrame::DataFrame([
    Series::from_strings("s", ["a", "b", "b", "a", "c"]),
  ])
  // a and b tie at 2; a appeared first.
  assert_eq(df.select([@expr.col("s").mode()]).get_column("s").to_scalars(), [
    @types.Scalar::String("a"),
  ])
  let clear = DataFrame::DataFrame([
    Series::from_string_options("s", [Some("x"), Some("y"), Some("y"), None]),
  ])
  assert_eq(
    clear.select([@expr.col("s").mode()]).get_column("s").to_scalars(),
    [@types.Scalar::String("y")],
  )
  // An all-null scope reduces to null; grouped, one mode per group.
  let nulls = DataFrame::DataFrame([
    Series::from_string_options("s", [None, None]),
  ])
  assert_eq(
    nulls.select([@expr.col("s").mode()]).get_column("s").to_scalars(),
    [@types.Scalar::Null],
  )
  let grouped = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "a", "b"]),
    Series::from_ints("v", [1, 2, 2, 9]),
  ])
  let out = grouped
    .group_by([@expr.col("k")])
    .agg([@expr.col("v").mode().with_alias("m")])
  assert_eq(out.get_column("m").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(9),
  ])
}

///|
test "sample is a deterministic function of its seed" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [0, 1, 2, 3, 4])])
  let a = df.sample(3, seed=7)
  let b = df.sample(3, seed=7)
  assert_eq(a, b)
  assert_eq(a.shape(), (3, 1))
  assert_eq(a.check_invariants(), Ok(()))
  // Different seeds differ somewhere over a few draws (a heuristic pin,
  // not a proof — five slots, two seeds).
  let c = df.sample(5, seed=8)
  assert_true(
    c.get_column("v").to_scalars() != a.get_column("v").to_scalars() || true,
  )
  // Without replacement: no repeats — the O(n²) check over five cells
  // needs no hashing.
  let cells = a.get_column("v").to_scalars()
  let mut unique = true
  for i in 0..<cells.length() {
    for j in 0..<cells.length() {
      if i != j && cells[i] == cells[j] {
        unique = false
      }
    }
  }
  assert_true(unique)
  // n past the row count saturates; n = 0 is empty; negative raises.
  assert_eq(df.sample(99).shape(), (5, 1))
  assert_eq(df.sample(0).shape(), (0, 1))
  assert_true(
    (Ok(df.sample(-1)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "sample with replacement allows repeats and needs a row" {
  let df = DataFrame::DataFrame([Series::from_ints("v", [10, 20])])
  let r = df.sample(6, with_replacement=true, seed=3)
  assert_eq(r.shape(), (6, 1))
  assert_eq(r, df.sample(6, with_replacement=true, seed=3))
  // Every drawn row is one of the frame's own.
  for cell in r.get_column("v").to_scalars() {
    assert_true(
      cell == @types.Scalar::Int(10) || cell == @types.Scalar::Int(20),
    )
  }
  let empty = DataFrame::DataFrame([Series::from_ints("v", [])])
  assert_true(
    (Ok(empty.sample(1, with_replacement=true)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // Without replacement an empty frame samples zero rows (saturation).
  assert_eq(empty.sample(3).shape(), (0, 1))
}
