///|
/// A composable column expression — the reified upgrade over the closure-based
/// surfaces (the original row-predicate closure) and pre-materialised `Series`
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
/// downstream module cannot import at all, so no caller can name a node, match
/// one, or hold one: adding a node for a new operator breaks nobody.
///
/// The shape is not observable either: there is no `==` on an expression. One
/// existed, comparing the two trees, and it made *how an operator lowers* a
/// promise to callers — normalising a tree or merging two node kinds would
/// have changed what compared equal without changing what any expression
/// means. `to_string()` is what a caller inspects with instead; it renders
/// what it prints, so two literal series differing only in their cells render
/// alike.
///
/// The engine reads the shape through the `node()` accessor; `frame` and
/// `lazy` are in-module and match `@ir.ExprNode` directly.
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
