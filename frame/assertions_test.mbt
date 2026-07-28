///|
/// Bring the `@test` versions of `assert_eq` / `assert_not_eq` into scope
/// for every `*_test.mbt` in this package. The prelude versions are
/// deprecated in favor of these Debug-based assertions.
using @test {assert_eq, assert_not_eq}

///|
/// `Series` moved to the `series` package; bind it unqualified for the
/// blackbox tests in this package (which build fixtures via `Series::from_*`),
/// mirroring the same `using` in the package's main scope.
using @series {type Series}

///|
/// Two expressions are the same tree when they render the same, and two lists
/// when they render pairwise. `Expr` carries no `==`: its tree is
/// module-internal, and comparing trees would have made how an operator lowers
/// a promise to callers. Rendering is the stable way to ask "did this verb
/// build the expression I meant".
fn assert_same_expr(a : @expr.Expr, b : @expr.Expr) -> Unit raise {
  assert_eq(a.to_string(), b.to_string())
}

///|
/// The negative half of `assert_same_expr`.
fn assert_diff_expr(a : @expr.Expr, b : @expr.Expr) -> Unit raise {
  assert_not_eq(a.to_string(), b.to_string())
}

///|
/// The list form, for the selectors that return one expression per column.
fn assert_same_exprs(
  a : Array[@expr.Expr],
  b : Array[@expr.Expr],
) -> Unit raise {
  assert_eq(a.map(e => e.to_string()), b.map(e => e.to_string()))
}

///|
/// Join options compare on what they mean: the join kind, the suffix, the
/// coalesce choice, and the keys as rendered. The keys are expressions, so
/// there is no `==` on the whole value any more.
fn join_shape(
  o : JoinOptions,
) -> (JoinType, String, Bool?, Array[String], Array[String], Array[String]) {
  (
    o.how,
    o.suffix,
    o.coalesce,
    o.on_keys().map(e => e.to_string()),
    o.left_keys().map(e => e.to_string()),
    o.right_keys().map(e => e.to_string()),
  )
}

///|
/// Two join options that must mean the same join.
fn assert_same_join(a : JoinOptions, b : JoinOptions) -> Unit raise {
  assert_eq(join_shape(a), join_shape(b))
}

///|
/// The negative half of `assert_same_join`.
fn assert_diff_join(a : JoinOptions, b : JoinOptions) -> Unit raise {
  assert_not_eq(join_shape(a), join_shape(b))
}
