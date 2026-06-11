///|
/// A composable, introspectable column expression tree — the reified
/// upgrade over the closure-based surfaces (`filter`'s row predicate,
/// `AggSpec`'s single-column reductions, `with_column`'s pre-materialised
/// `Series`). An `Expr` is *data*: the evaluator in `frame` pattern-matches
/// it, and the v0.4 lazy layer will print and rewrite it — none of which a
/// closure can offer.
///
/// The enum is `pub` (read-only): other packages — including `frame`, whose
/// evaluator `match`es the tree cross-package — can inspect it but cannot
/// construct variants (`[4036]`). The only way to build an `Expr` is the
/// constructor functions (`col` / `lit` / `lit_*`) and the operator impls
/// in `expr_ops.mbt`, so every tree is well-formed by construction.
/// Building an expression is **total** — unknown columns and dtype
/// mismatches surface at evaluation time (in `frame`), never here.
///
/// S0 spike subset: `Col` / `Lit` / `Binary` with `BinOp::{Add; And}` —
/// one arithmetic and one Kleene-logical operator, enough to drive the
/// evaluator's variant × dtype double match through the 100 %-coverage
/// gate. E1 grows the full surface (Sub / Mul / Div, comparisons, `Unary`,
/// `Agg`, `Cast`, `Alias`, `Ternary`) on this exact shape.
pub enum Expr {
  Col(String)
  Lit(@types.Scalar)
  Binary(BinOp, Expr, Expr)
} derive(Eq, Debug)

///|
/// Binary operator tag carried by `Expr::Binary`. `pub` read-only rather
/// than `priv`: a `pub` enum cannot carry a `priv` payload (`[4046]`), and
/// the evaluator in `frame` must `match` the tag cross-package. Inert from
/// the outside — no public API returns a bare `BinOp`, so users never name
/// one; it is not re-exported through the facade.
pub enum BinOp {
  Add
  And
} derive(Eq, Debug)
