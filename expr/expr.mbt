///|
/// A composable, introspectable column expression tree — the reified
/// upgrade over the closure-based surfaces (`filter`'s row predicate,
/// `with_column`'s pre-materialised `Series`). An `Expr` is *data*: the
/// evaluator in `frame` pattern-matches
/// it, and the v0.4 lazy layer will print and rewrite it — none of which a
/// closure can offer.
///
/// The enum is `pub` (read-only): other packages — including `frame`, whose
/// evaluator `match`es the tree cross-package — can inspect it but cannot
/// construct variants (`[4036]`). The only way to build an `Expr` is the
/// constructor functions (`col` / `lit` / `lit_*` / `when`), the operator
/// impls and the methods in `expr_ops.mbt`, so every tree is well-formed by
/// construction. Building an expression is **total** — unknown columns and
/// dtype mismatches surface at evaluation time (in `frame`), never here.
///
/// Variant tour (construction route in parentheses):
/// - `Col` / `Lit` — leaves (`col`, `lit` / `lit_*`);
/// - `Binary` — arithmetic `+ - * /`, comparisons `eq/ne/lt/le/gt/ge`,
///   Kleene logic `&`/`|` (also `.land()`/`.lor()` — `and`/`or` are
///   reserved words);
/// - `Unary` — `-e`, `.not()`, `.is_null()`, `.is_not_null()`;
/// - `Agg` — `.sum()/.mean()/.min()/.max()/.count()`, reducing its operand
///   to a single value per evaluation scope;
/// - `Cast` — `.cast(dtype)`;
/// - `Alias` — `.with_alias(name)` (`alias` is a reserved word), naming the
///   result column;
/// - `Ternary` — `when(cond).then(a).otherwise(b)`.
pub enum Expr {
  Col(String)
  Lit(@types.Scalar)
  Binary(BinOp, Expr, Expr)
  Unary(UnOp, Expr)
  Agg(AggOp, Expr)
  Cast(Expr, @types.DataType)
  Alias(Expr, String)
  Ternary(Expr, Expr, Expr)
} derive(Eq, Debug)

///|
/// Binary operator tag carried by `Expr::Binary`. `pub` read-only rather
/// than `priv`: a `pub` enum cannot carry a `priv` payload (`[4046]`), and
/// the evaluator in `frame` must `match` the tag cross-package. Inert from
/// the outside — no public API returns a bare `BinOp`, so users never name
/// one; it is not re-exported through the facade.
///
/// `And` / `Or` are the Kleene three-valued logical connectives (`&` / `|`
/// at the call site), not bitwise operations; the comparison tags produce
/// `Bool` columns under the evaluator's null-propagation rules.
pub enum BinOp {
  Add
  Sub
  Mul
  Div
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
  And
  Or
} derive(Eq, Debug)

///|
/// Unary operator tag carried by `Expr::Unary` — same read-only-not-`priv`
/// rationale as `BinOp`. `Neg` is numeric negation (`-e`), `Not` is Kleene
/// logical negation (`not(null) = null`), and the null probes
/// `IsNull` / `IsNotNull` read validity only, so they are total and never
/// produce a null themselves.
pub enum UnOp {
  Neg
  Not
  IsNull
  IsNotNull
} derive(Eq, Debug)

///|
/// Aggregation tag carried by `Expr::Agg` — same read-only-not-`priv`
/// rationale as `BinOp`. Evaluation inherits the `Series` reduction
/// semantics wholesale: `Sum` / `Mean` propagate NaN, `Min` / `Max` skip
/// it, `Count` counts non-null cells.
pub enum AggOp {
  Sum
  Mean
  Min
  Max
  Count
} derive(Eq, Debug)
