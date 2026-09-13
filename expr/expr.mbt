///|
/// A composable column expression — the reified upgrade over the closure-based
/// surfaces (the original row-predicate closure) and pre-materialised `Series`
/// columns. An `Expr` is built through the constructor functions
/// (`col` / `lit` / `lit_*` / `when`), the operator impls, and the methods,
/// so every tree is well-formed by construction; the `when` chain stages
/// through the `WhenThen` / `WhenThenElse` types below, completing as a
/// `Ternary`. Building one is
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
/// The engine reads the shape through four accessors beside the type —
/// `node()` hands over the wrapped AST, and `children()` /
/// `referenced_columns()` / `output_name()` answer its introspection
/// questions. `frame` and `lazy` are in-module and match `@ir.ExprNode`
/// directly.
///
/// The wrapped AST carries `@ir.ExprNode` children, not `Expr`, so this package
/// bridges the two: a constructor unwraps its child `Expr`s with `.node`, and
/// the `children` accessor below wraps `ExprNode` children back into `Expr`. The
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
/// The immediate sub-expressions of a node, left to right, as opaque `Expr`
/// handles — the wrapper-level face of `@ir.ExprNode::children`, which is the
/// single place that encodes the tree's recursive shape. A new variant declares
/// its child structure once, in `ExprNode`, and every walk takes its *descent*
/// from there: this handle-level face, the `internal/ir` analyses behind
/// `referenced_columns` / `output_name`, and the lazy optimizer's `row_stable` /
/// `group_cell_stable` (which walk the raw `@ir.ExprNode` children directly).
/// What a variant does not inherit is what those walks *decide* about it — the
/// naming and pushdown analyses classify variant by variant, under exhaustive
/// `match`es that stop compiling until the new one is classified. Total — it only
/// inspects shape.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::children(self : Expr) -> Array[Expr] {
  // The AST's shape lives on `@ir.ExprNode::children`; wrap each raw child back
  // into the opaque `Expr` this returns, so a caller walks the handle.
  self.node.children().map(Expr::of)
}

///|
/// Every column name the tree references, as a set — the handle-level face of
/// `@ir.ExprNode::referenced_columns` (the analysis itself lives in
/// `internal/ir`, beside the AST). A `Ternary`'s condition counts. Total.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::referenced_columns(self : Expr) -> @set.Set[String] {
  self.node.referenced_columns()
}

///|
/// The output-column name this expression produces (Polars' naming rule: an
/// alias wins, else the leftmost column reference, else `"literal"`) — the
/// handle-level face of `@ir.ExprNode::output_name`. Total.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn Expr::output_name(self : Expr) -> String {
  self.node.output_name()
}

///|
/// Wrap an `@ir.ExprNode` into the opaque handle — the inverse of `node`, used
/// inside this package by the constructors and the introspection walks.
fn Expr::of(node : @ir.ExprNode) -> Expr {
  { node, }
}

///|
/// First step of the conditional chain
/// `when(cond).then(a).otherwise(b)` — holds the `Bool` condition until
/// `then` supplies the matching branch. Constructible only through `when`,
/// which is a `pub` function and so cannot return a `priv` type — that, and
/// nothing else, is why the struct is `pub`. Its field is private, so the only
/// thing a caller can do with a `WhenThen` is call `then`.
pub struct WhenThen {
  priv cond : Expr
}

///|
/// Second step of the conditional chain — condition plus `then` branch,
/// waiting for `otherwise` to complete the expression. Same private-field
/// rationale as `WhenThen`: the only move is `otherwise`.
pub struct WhenThenElse {
  priv cond : Expr
  priv then_value : Expr
}

///|
/// Open a conditional expression: `when(cond).then(a).otherwise(b)`
/// evaluates to `a` where `cond` is `true`, `b` where it is `false`, and
/// null where `cond` is null. The chain is the only construction route, so
/// a conditional is complete by the time it becomes an `Expr`.
pub fn when(cond : Expr) -> WhenThen {
  { cond, }
}

///|
/// Supply the branch taken where the condition is `true`.
pub fn WhenThen::then(self : WhenThen, value : Expr) -> WhenThenElse {
  { cond: self.cond, then_value: value, }
}

///|
/// Supply the branch taken where the condition is `false`, completing the
/// conditional as a `Ternary` expression node.
pub fn WhenThenElse::otherwise(self : WhenThenElse, value : Expr) -> Expr {
  Expr::of(
    @ir.ExprNode::Ternary(self.cond.node, self.then_value.node, value.node),
  )
}
