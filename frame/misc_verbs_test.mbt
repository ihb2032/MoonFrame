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
  // Different seeds give different sequences — pinned directly: the draw
  // is a deterministic function of the seed, so two fixed seeds have two
  // fixed answers, and asserting both fixes what "different" means here.
  assert_eq(df.sample(5, seed=7).get_column("v").to_scalars(), [
    Int(0),
    Int(1),
    Int(3),
    Int(2),
    Int(4),
  ])
  assert_eq(df.sample(5, seed=8).get_column("v").to_scalars(), [
    Int(1),
    Int(2),
    Int(3),
    Int(0),
    Int(4),
  ])
  assert_true(
    df.sample(5, seed=8).get_column("v").to_scalars() !=
    df.sample(5, seed=7).get_column("v").to_scalars(),
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
  // n past the row count raises (no silent saturation,
  // and an unshuffled whole frame would disagree with sample(n = nrows));
  // n = 0 is empty; negative raises.
  assert_true(
    (Ok(df.sample(99)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
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
  // n = 0 on an empty frame draws nothing — there is no draw to divide by
  // zero on, so no raise.
  assert_eq(empty.sample(0, with_replacement=true).shape(), (0, 1))
  // Without replacement an empty frame cannot supply rows either: n past
  // the (zero) row count raises, exactly as on a populated frame.
  assert_true(
    (Ok(empty.sample(3)) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "mode keeps the first-appearing spelling of a folded key" {
  // `-0.0` and `+0.0` fold to one key cell; the winner reads at the
  // key's first appearance, not at the occurrence that tipped the count
  // — the first-appearing-value promise in the reducer's docstring.
  let df = DataFrame::DataFrame([Series::from_floats("s", [0.0, -0.0, 5.0])])
  let out = df.select([@expr.col("s").mode()]).get_column("s")
  assert_true(out.to_scalars() is [@types.Scalar::Float(v)] && 1.0 / v > 0.0)
}

///|
test "an omitted seed is seed = 0" {
  // The docstring promises it and bootstrap-style callers depend on
  // knowing it: leaving the seed out shares one sequence with an explicit
  // zero, so two independent seedless draws are two identical draws.
  let df = DataFrame::DataFrame([Series::from_ints("v", [0, 1, 2, 3, 4])])
  assert_eq(df.sample(3), df.sample(3, seed=0))
  assert_eq(df.sample(5), df.sample(5, seed=0))
}

///|
test "shuffle is a deterministic seeded permutation of the whole frame" {
  let df = DataFrame::DataFrame([
    Series::from_ints("v", [0, 1, 2, 3, 4]),
    Series::from_strings("s", ["a", "b", "c", "d", "e"]),
  ])
  let a = df.shuffle(seed=7)
  assert_eq(a, df.shuffle(seed=7))
  assert_eq(a.shape(), (5, 2))
  assert_eq(a.check_invariants(), Ok(()))
  // Pinned: what seed 7 actually permutes to — the draw is a deterministic
  // function of the seed, exactly as `sample`'s.
  assert_eq(a.get_column("v").to_scalars(), [
    Int(2),
    Int(3),
    Int(1),
    Int(4),
    Int(0),
  ])
  assert_true(
    a.get_column("v").to_scalars() !=
    df.shuffle(seed=8).get_column("v").to_scalars(),
  )
  // The multiset survives: sorted, a shuffled column is the input column.
  assert_eq(
    a.sort([(@expr.col("v"), false, false)]).get_column("v").to_scalars(),
    [Int(0), Int(1), Int(2), Int(3), Int(4)],
  )
  // Rows move together: every (v, s) pair of the shuffle is one of the
  // input's own pairs.
  for i in 0..<5 {
    let pair = (
      a.get_column("v").to_scalars()[i],
      a.get_column("s").to_scalars()[i],
    )
    let pair : (@types.Scalar, @types.Scalar) = pair
    assert_true(
      pair is (@types.Scalar::Int(v), @types.Scalar::String(s)) &&
      ["a", "b", "c", "d", "e"][v.to_int()] == s,
    )
  }
  // The omitted seed is seed = 0, exactly as `sample`.
  assert_eq(df.shuffle(), df.shuffle(seed=0))
}

///|
test "shuffle edges: empty and one-row frames are their own permutation" {
  let empty = DataFrame::DataFrame([Series::from_ints("v", [])])
  assert_eq(empty.shuffle(seed=1).shape(), (0, 1))
  let one = DataFrame::DataFrame([Series::from_ints("v", [9])])
  assert_eq(one.shuffle(seed=1).get_column("v").to_scalars(), [Int(9)])
}
