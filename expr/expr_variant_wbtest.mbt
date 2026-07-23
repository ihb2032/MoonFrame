// Whitebox coverage guard for the handwritten `Expr` equality. The blackbox
// suite compares variants through `==`, but the "one representative per variant"
// list it needs was a silent sync point: forgetting to add a rep for a new
// variant would quietly stop testing it (and the count lived in a hand-bumped
// comment). `expr_variant_tag` closes that — an exhaustive, wildcard-free match,
// so a new `Expr` variant is a compile error HERE (at the equality test) until
// its arm exists, landing the author beside the `reps` list they must also
// extend. The seven production match-sites already force the variant to be
// handled; this brings the same compile signal to the equality test. Whitebox
// because matching `Expr`'s variants needs in-package visibility.

///|
/// A distinct tag per `Expr` variant, in declaration order — exhaustive and
/// wildcard-free on purpose, so adding a variant forces an arm here (a compile
/// error at this test file) rather than silently dropping its equality coverage.
fn expr_variant_tag(e : Expr) -> Int {
  match e {
    Col(_) => 0
    Lit(_) => 1
    LitSeries(_) => 2
    Binary(_, _, _) => 3
    Unary(_, _) => 4
    Agg(_, _) => 5
    Str(_, _) => 6
    Cast(_, _) => 7
    Alias(_, _) => 8
    Ternary(_, _, _) => 9
    FillNull(_, _) => 10
    FillNan(_, _) => 11
    IsIn(_, _) => 12
    IsBetween(_, _, _, _) => 13
    Map(_, _, _) => 14
    MapBatches(_, _, _, _) => 15
  }
}

///|
test "equality: each variant is unequal to every other variant" {
  // One representative of each `Expr` variant, in `expr_variant_tag` order.
  let reps : ReadOnlyArray[Expr] = [
    col("a"),
    lit_int(1),
    lit_series(@series.Series::from_ints("s", [1])),
    col("a") + col("b"),
    -col("a"),
    col("a").sum(),
    col("a").str_to_uppercase(),
    col("a").cast(@types.DataType::Float),
    col("a").with_alias("z"),
    when(col("c")).then(lit_int(1)).otherwise(lit_int(0)),
    col("a").fill_null(lit_int(0)),
    col("a").fill_nan(lit_float(0.0)),
    col("a").is_in([@types.Scalar::Int(1)]),
    col("a").is_between(lit_int(0), lit_int(10)),
    map_many(label="m", [col("a")], fn(vs) { vs[0] }),
    col("a").map_batches(label="mb", fn(s) { s }),
  ]
  // The reps carry one of every variant, in tag order with no gap — so the count
  // is derived from `expr_variant_tag` rather than hand-maintained, a duplicated
  // or misordered rep is caught, and a variant added to `expr_variant_tag` above
  // (a compile error there) is not left untested here.
  let tags = Array::makei(reps.length(), i => expr_variant_tag(reps[i]))
  assert_eq(tags, Array::makei(reps.length(), i => i))
  // Comparing every ordered pair of distinct variants exercises each per-variant
  // arm of the handwritten structural equality as the *first* operand — the arm
  // a future variant addition is forced to extend.
  for i in 0..<reps.length() {
    for j in 0..<reps.length() {
      if i != j {
        assert_not_eq(reps[i], reps[j])
      }
    }
  }
}
