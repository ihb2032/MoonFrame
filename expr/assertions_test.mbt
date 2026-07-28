///|
/// Bring the `@test` versions of `assert_eq` / `assert_not_eq` into scope
/// for every `*_test.mbt` in this package. The prelude versions are
/// deprecated in favor of these Debug-based assertions.
using @test {assert_eq, assert_not_eq}

///|
/// `lit_series` embeds a `@series.Series`; bind the type unqualified for the
/// blackbox tests that build literal-series fixtures via `Series::from_*`.
using @series {type Series}

///|
/// Two expressions are the same tree when they render the same. `Expr` has no
/// `==`: the tree it wraps is module-internal, and an equality over it would
/// have made *how an operator lowers* a promise to callers — a normalisation
/// or a merged node would change what compared equal. Rendering is the stable
/// way to ask "did the builder produce the expression I meant", so it is what
/// these suites assert with. What rendering cannot tell apart — a `LitSeries`'
/// cells, which show as a name and a length — is asserted inside the package
/// instead, against the node itself.
fn assert_same_expr(a : Expr, b : Expr) -> Unit raise {
  assert_eq(a.to_string(), b.to_string())
}

///|
/// The negative half of `assert_same_expr`: two expressions that must not be
/// the same tree.
fn assert_diff_expr(a : Expr, b : Expr) -> Unit raise {
  assert_not_eq(a.to_string(), b.to_string())
}

///|
/// The list form, for the walks that return an expression's children.
fn assert_same_exprs(a : Array[Expr], b : Array[Expr]) -> Unit raise {
  assert_eq(a.map(e => e.to_string()), b.map(e => e.to_string()))
}
