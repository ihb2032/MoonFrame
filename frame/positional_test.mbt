// Blackbox tests for the positional expression family — `shift` / `diff`,
// the `cum_*` running aggregates, `rank`, `arg_sort`, and the positional
// reductions `arg_min` / `arg_max`. Evaluated through `with_columns` /
// `select` over eager frames, so what is pinned is the contract the
// docstrings state: the `LAG` / `LEAD` reading of `shift`, the null-slot /
// `NaN` rules of the running aggregates, every `RankMethod`'s tie table,
// the permutation `arg_sort` emits, and the window-local position the arg
// reductions return.

///|
fn int_col(name : String, vals : Array[Int64?]) -> Series {
  Series::from_int_options(name, vals)
}

///|
test "shift is LAG / LEAD with a fillable edge" {
  let df = DataFrame::DataFrame([int_col("v", [Some(10), Some(20), Some(30)])])
  let s = df.select([@expr.col("v").shift(1).with_alias("s")])
  assert_eq(s.get_column("s").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
  ])
  // A negative n is LEAD — values move up.
  let lead = df.select([@expr.col("v").shift(-1).with_alias("l")])
  assert_eq(lead.get_column("l").to_scalars(), [
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
    @types.Scalar::Null,
  ])
  // n = 0 is the identity.
  let id = df.select([@expr.col("v").shift(0).with_alias("i")])
  assert_eq(id.get_column("i").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
  // A fill replaces the vacated edge; the dtype is kept.
  let filled = df.select([
    @expr.col("v").shift(1, fill_value=@types.Scalar::Int(0)).with_alias("f"),
  ])
  assert_eq(filled.get_column("f").dtype(), @types.DataType::Int)
  assert_eq(filled.get_column("f").to_scalars(), [
    @types.Scalar::Int(0),
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
  ])
}

///|
test "shift moves nulls as values, and a mistyped fill raises" {
  let df = DataFrame::DataFrame([int_col("v", [Some(1), None, Some(3)])])
  let s = df.select([@expr.col("v").shift(1).with_alias("s")])
  assert_eq(s.get_column("s").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Null,
  ])
  assert_true(
    (Ok(
      df.select([
        @expr.col("v")
        .shift(1, fill_value=@types.Scalar::Float(9.0))
        .with_alias("x"),
      ]),
    ) catch {
      e => Err(e)
    })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  // Strings shift too — the family is dtype-agnostic in the operand.
  let str_df = DataFrame::DataFrame([Series::from_strings("s", ["a", "b"])])
  assert_eq(
    str_df.select([@expr.col("s").shift(1)]).get_column("s").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::String("a")],
  )
}

///|
test "diff is self minus the shifted self, nulls propagating" {
  let df = DataFrame::DataFrame([int_col("v", [Some(1), Some(2), Some(4)])])
  assert_eq(df.select([@expr.col("v").diff()]).get_column("v").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(
    df.select([@expr.col("v").diff(n=2)]).get_column("v").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Null, @types.Scalar::Int(3)],
  )
  // A null operand nulls both differences that touch it.
  let nullable = DataFrame::DataFrame([int_col("v", [Some(1), None, Some(4)])])
  assert_eq(
    nullable.select([@expr.col("v").diff()]).get_column("v").to_scalars(),
    [@types.Scalar::Null, @types.Scalar::Null, @types.Scalar::Null],
  )
  // Float keeps Float.
  let f = DataFrame::DataFrame([Series::from_floats("f", [1.0, 3.0])])
  assert_eq(f.select([@expr.col("f").diff()]).get_column("f").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::Float(2.0),
  ])
}

///|
test "cum_sum / cum_prod run over the non-null cells; nulls keep their slot" {
  let df = DataFrame::DataFrame([int_col("v", [Some(10), None, Some(8)])])
  assert_eq(
    df.select([@expr.col("v").cum_sum()]).get_column("v").to_scalars(),
    [@types.Scalar::Int(10), @types.Scalar::Null, @types.Scalar::Int(18)],
  )
  assert_eq(
    df.select([@expr.col("v").cum_prod()]).get_column("v").to_scalars(),
    [@types.Scalar::Int(10), @types.Scalar::Null, @types.Scalar::Int(80)],
  )
  // reverse accumulates from the end, a null slot keeping its null.
  assert_eq(
    df
    .select([@expr.col("v").cum_sum(reverse=true)])
    .get_column("v")
    .to_scalars(),
    [@types.Scalar::Int(18), @types.Scalar::Null, @types.Scalar::Int(8)],
  )
  // A Float NaN enters the running sum and stays.
  let nan : Double = @double.not_a_number
  let f = DataFrame::DataFrame([Series::from_floats("f", [1.0, nan, 2.0])])
  assert_true(
    match f.select([@expr.col("f").cum_sum()]).get_column("f").get(2) {
      @types.Scalar::Float(v) => v.is_nan()
      _ => false
    },
  )
}

///|
test "cum_min / cum_max skip NaN and run reversed too" {
  let f = DataFrame::DataFrame([
    Series::from_floats("f", [3.0, @double.not_a_number, 1.0]),
  ])
  assert_eq(f.select([@expr.col("f").cum_min()]).get_column("f").to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(1.0),
  ])
  assert_eq(f.select([@expr.col("f").cum_max()]).get_column("f").to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(3.0),
  ])
  let i = DataFrame::DataFrame([int_col("v", [Some(1), Some(5), Some(3)])])
  assert_eq(i.select([@expr.col("v").cum_max()]).get_column("v").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(5),
    @types.Scalar::Int(5),
  ])
  assert_eq(
    i
    .select([@expr.col("v").cum_min(reverse=true)])
    .get_column("v")
    .to_scalars(),
    [@types.Scalar::Int(1), @types.Scalar::Int(3), @types.Scalar::Int(3)],
  )
}

///|
test "the Float cumulative members carry the same rules" {
  let df = DataFrame::DataFrame([
    Series::from_float_options("f", [Some(2.0), None, Some(3.0)]),
  ])
  assert_eq(
    df.select([@expr.col("f").cum_prod()]).get_column("f").to_scalars(),
    [@types.Scalar::Float(2.0), @types.Scalar::Null, @types.Scalar::Float(6.0)],
  )
  assert_eq(
    df.select([@expr.col("f").cum_min()]).get_column("f").to_scalars(),
    [@types.Scalar::Float(2.0), @types.Scalar::Null, @types.Scalar::Float(2.0)],
  )
  assert_eq(
    df.select([@expr.col("f").cum_max()]).get_column("f").to_scalars(),
    [@types.Scalar::Float(2.0), @types.Scalar::Null, @types.Scalar::Float(3.0)],
  )
}

///|
test "cum_count is dtype-blind, a null slot repeating the prior count" {
  let df = DataFrame::DataFrame([
    Series::from_string_options("s", [Some("x"), Some("k"), None, Some("d")]),
  ])
  assert_eq(
    df.select([@expr.col("s").cum_count()]).get_column("s").to_scalars(),
    [
      @types.Scalar::Int(1),
      @types.Scalar::Int(2),
      @types.Scalar::Int(2),
      @types.Scalar::Int(3),
    ],
  )
  assert_eq(
    df
    .select([@expr.col("s").cum_count(reverse=true)])
    .get_column("s")
    .to_scalars(),
    [
      @types.Scalar::Int(3),
      @types.Scalar::Int(2),
      @types.Scalar::Int(1),
      @types.Scalar::Int(1),
    ],
  )
}

///|
test "the cum_* arithmetic and extremum members are numeric-only" {
  let df = DataFrame::DataFrame([Series::from_strings("s", ["a"])])
  for
    e in [
      @expr.col("s").cum_sum(),
      @expr.col("s").cum_prod(),
      @expr.col("s").cum_min(),
      @expr.col("s").cum_max(),
    ] {
    assert_true(
      (Ok(df.select([e.with_alias("x")])) catch { e2 => Err(e2) })
      is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
    )
  }
}

///|
test "rank numbers ties per method — Polars' own example" {
  // [3, 6, 1, 1, 6]: the tie groups are the two 1s (sorted slots [0, 2))
  // and the two 6s ([3, 5)).
  let df = DataFrame::DataFrame([
    int_col("v", [Some(3), Some(6), Some(1), Some(1), Some(6)]),
  ])
  fn ranked(
    how : @types.RankMethod,
  ) -> Array[@types.Scalar] raise @types.DataError {
    df.select([@expr.col("v").rank(how~)]).get_column("v").to_scalars()
  }
  assert_eq(ranked(Average), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(4.5),
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(4.5),
  ])
  assert_eq(ranked(Min), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(4),
  ])
  assert_eq(ranked(Max), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(5),
    @types.Scalar::Int(2),
    @types.Scalar::Int(2),
    @types.Scalar::Int(5),
  ])
  assert_eq(ranked(Dense), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
    @types.Scalar::Int(1),
    @types.Scalar::Int(1),
    @types.Scalar::Int(3),
  ])
  // Ordinal keeps input order among equals.
  assert_eq(ranked(Ordinal), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(5),
  ])
  // Descending flips the value order only — ties still keep input order:
  // the two 6s take the top span's average, the 3 the middle slot, the two
  // 1s the bottom span's.
  let desc = df.select([@expr.col("v").rank(descending=true)]).get_column("v")
  assert_eq(desc.to_scalars(), [
    @types.Scalar::Float(3.0),
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(4.5),
    @types.Scalar::Float(4.5),
    @types.Scalar::Float(1.5),
  ])
}

///|
test "rank leaves nulls null, orders NaN last, and ranks every dtype" {
  let nullable = DataFrame::DataFrame([int_col("v", [Some(1), None, Some(1)])])
  assert_eq(
    nullable.select([@expr.col("v").rank(how=Min)]).get_column("v").to_scalars(),
    [@types.Scalar::Int(1), @types.Scalar::Null, @types.Scalar::Int(1)],
  )
  // NaN ranks past every value, the total order `sort` uses.
  let nan : Double = @double.not_a_number
  let f = DataFrame::DataFrame([Series::from_floats("f", [1.0, nan, 2.0])])
  assert_eq(
    f.select([@expr.col("f").rank(how=Min)]).get_column("f").to_scalars(),
    [@types.Scalar::Int(1), @types.Scalar::Int(3), @types.Scalar::Int(2)],
  )
  let s = DataFrame::DataFrame([Series::from_strings("s", ["b", "a", "b"])])
  assert_eq(
    s.select([@expr.col("s").rank(how=Min)]).get_column("s").to_scalars(),
    [@types.Scalar::Int(2), @types.Scalar::Int(1), @types.Scalar::Int(2)],
  )
  let b = DataFrame::DataFrame([Series::from_bools("b", [true, false, true])])
  assert_eq(
    b.select([@expr.col("b").rank(how=Min)]).get_column("b").to_scalars(),
    [@types.Scalar::Int(2), @types.Scalar::Int(1), @types.Scalar::Int(2)],
  )
}

///|
test "arg_sort emits the stable permutation, nulls placed per the flag" {
  let df = DataFrame::DataFrame([int_col("v", [Some(30), Some(10), Some(20)])])
  assert_eq(
    df.select([@expr.col("v").arg_sort()]).get_column("v").to_scalars(),
    [@types.Scalar::Int(1), @types.Scalar::Int(2), @types.Scalar::Int(0)],
  )
  assert_eq(
    df
    .select([@expr.col("v").arg_sort(descending=true)])
    .get_column("v")
    .to_scalars(),
    [@types.Scalar::Int(0), @types.Scalar::Int(2), @types.Scalar::Int(1)],
  )
  // Feeding the permutation to `gather` sorts the frame — the round trip
  // the verb exists for.
  let perm = df.select([@expr.col("v").arg_sort()]).get_column("v").to_scalars()
  let idx : Array[Int] = perm.map(c => {
    match c {
      @types.Scalar::Int(i) => i.to_int()
      _ => 0
    }
  })
  assert_eq(df.gather(idx).get_column("v").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(20),
    @types.Scalar::Int(30),
  ])
  // Nulls first by default (the sort kernel's placement), last under the
  // flag — a String operand covers the fourth backend order.
  let ns = DataFrame::DataFrame([
    Series::from_string_options("s", [None, Some("c"), Some("a")]),
  ])
  assert_eq(
    ns.select([@expr.col("s").arg_sort()]).get_column("s").to_scalars(),
    [@types.Scalar::Int(0), @types.Scalar::Int(2), @types.Scalar::Int(1)],
  )
  assert_eq(
    ns
    .select([@expr.col("s").arg_sort(nulls_last=true)])
    .get_column("s")
    .to_scalars(),
    [@types.Scalar::Int(2), @types.Scalar::Int(1), @types.Scalar::Int(0)],
  )
}

///|
test "arg_min / arg_max return the window-local position, first on ties" {
  let df = DataFrame::DataFrame([int_col("v", [Some(30), Some(10), Some(20)])])
  assert_eq(
    df.select([@expr.col("v").arg_min()]).get_column("v").to_scalars(),
    [@types.Scalar::Int(1)],
  )
  assert_eq(
    df.select([@expr.col("v").arg_max()]).get_column("v").to_scalars(),
    [@types.Scalar::Int(0)],
  )
  // A tie keeps the earliest position; NaN skips like `min`.
  let ties = DataFrame::DataFrame([
    Series::from_floats("f", [@double.not_a_number, 1.0, 1.0]),
  ])
  assert_eq(
    ties.select([@expr.col("f").arg_min()]).get_column("f").to_scalars(),
    [@types.Scalar::Int(1)],
  )
  // Total over every dtype: Bool `false < true`, String lexicographic.
  let b = DataFrame::DataFrame([Series::from_bools("b", [true, false])])
  assert_eq(b.select([@expr.col("b").arg_min()]).get_column("b").to_scalars(), [
    @types.Scalar::Int(1),
  ])
  let s = DataFrame::DataFrame([Series::from_strings("s", ["b", "a"])])
  assert_eq(s.select([@expr.col("s").arg_min()]).get_column("s").to_scalars(), [
    @types.Scalar::Int(1),
  ])
  // An all-null scope reduces to null.
  let nulls = DataFrame::DataFrame([int_col("v", [None, None])])
  assert_eq(
    nulls.select([@expr.col("v").arg_max()]).get_column("v").to_scalars(),
    [@types.Scalar::Null],
  )
}

///|
test "grouped arg_min is the position within the group" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    int_col("v", [Some(30), Some(10), Some(20)]),
  ])
  let out = df
    .group_by([@expr.col("k")])
    .agg([
      @expr.col("v").arg_min().with_alias("am"),
      @expr.col("v").arg_max().with_alias("ax"),
    ])
  // Group "a" holds [30, 10] — min at local 1, max at local 0; group "b"
  // a single row, both 0.
  assert_eq(out.get_column("am").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(0),
  ])
  assert_eq(out.get_column("ax").to_scalars(), [
    @types.Scalar::Int(0),
    @types.Scalar::Int(0),
  ])
}
