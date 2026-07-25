///|
/// A composable column expression — the reified upgrade over the closure-based
/// surfaces (the v0.1 row-predicate closure) and pre-materialised `Series`
/// columns. An `Expr` is built through the constructor functions
/// (`col` / `lit` / `lit_*` / `when`), the operator impls, and the methods in
/// `expr_ops.mbt`, so every tree is well-formed by construction. Building one is
/// **total** — unknown columns and dtype mismatches surface at evaluation time
/// (in `frame`), never here.
///
/// The type is **opaque**: it wraps an `@ir.ExprNode` AST and exposes no
/// variants. Outside this package an expression is a value you build and pass
/// on, or render with `to_string` — there is no matching on its shape. The AST
/// itself lives in the module-internal `internal/ir` package, which a
/// downstream module cannot import at all, so it is not — and cannot become —
/// part of the public API or the compatibility promise: a node can be added
/// whenever an operator is, without breaking any caller. The engine reads the
/// shape through the `node()` accessor; `frame` and `lazy` are in-module and
/// match `@ir.ExprNode` directly.
///
/// The wrapped AST carries `@ir.ExprNode` children, not `Expr`, so this package
/// bridges the two: a constructor unwraps its child `Expr`s with `.node`, and a
/// walk (in `explain.mbt`) wraps `ExprNode` children back into `Expr`. The
/// nodes, in construction-route order:
/// - `Col` / `Lit` / `LitSeries` — leaves (`col`, `lit` / `lit_*`,
///   `lit_series`); a `LitSeries` embeds a pre-materialised `@series.Series`;
/// - `Binary` — arithmetic `+ - * /`, comparisons, Kleene `&` / `|`;
/// - `Unary` — `-e`, `.not()`, the null / NaN probes, and `.abs()` / `.floor()`
///   / `.ceil()` / `.sign()` / `.round()`;
/// - `Agg` — `.sum()` / `.mean()` / … reductions;
/// - `Str` — the `.str_*` namespace;
/// - `Cast` — `.cast(dtype)`; `Alias` — `.with_alias(name)`;
/// - `Ternary` — `when(c).then(a).otherwise(b)`;
/// - `FillNull` / `FillNan` — `.fill_null(v)` / `.fill_nan(v)`, dedicated nodes
///   (not lowered to a `Ternary`) so the operand appears once and a chained
///   coalesce stays linear;
/// - `IsIn` / `IsBetween` — the membership / range predicates, likewise
///   dedicated so the operand is evaluated once;
/// - `Map` / `MapBatches` — the row-wise / batched closure escape hatches
///   (`.map_elements()` / `map_many()` / `.map_batches()`), the function opaque
///   so each is identified by its `(label, inputs)` (`MapBatches` also by its
///   `returns_scalar` flag).
pub struct Expr {
  priv node : @ir.ExprNode
}

///|
/// The engine's read seam onto the opaque `Expr`, returning the wrapped AST.
/// `#doc(hidden)` keeps it out of the generated interface; the `@ir.ExprNode` it
/// returns is module-internal regardless, so the AST cannot leak either way.
/// `frame` / `lazy` enter a tree walk through this. Total.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::node(self : Expr) -> @ir.ExprNode {
  self.node
}

///|
/// Wrap an `@ir.ExprNode` into the opaque handle — the inverse of `node`, used
/// inside this package by the constructors and the introspection walks.
fn Expr::of(node : @ir.ExprNode) -> Expr {
  { node, }
}

///|
/// Structural equality, delegated to the handwritten `@ir.ExprNode` equality
/// (the `Map` / `MapBatches` closures block a derived one). This is what
/// `DataFrame` / the lazy `LogicalPlan` reach through their derived `Eq` when a
/// structure embeds an `Expr`.
pub impl Eq for Expr with fn equal(self, other) {
  self.node == other.node
}

///|
pub extend Expr with Eq::{equal, not_equal}
