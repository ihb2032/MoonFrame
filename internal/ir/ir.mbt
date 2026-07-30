// The expression AST, module-internal. `ExprNode` and its operator tags are
// the shape a `@expr.Expr` wraps and the shape `frame`'s evaluator and `lazy`'s
// optimizer walk. Keeping them in an `internal/` package makes them a hard,
// language-enforced boundary — a downstream module cannot import this package
// at all — rather than a documentation convention, so the AST genuinely cannot
// leak into the public surface. The public `Expr` handle lives in `expr` — it
// is buildable but **opaque** (no variants to match from outside); only the
// in-module engine reads the `ExprNode` stored inside it. The
// constructible-by-callers `ClosedInterval` lives in `types`.
//
// A node's children are `ExprNode`, not the `@expr.Expr` wrapper: the wrapper
// references this package for its field, so this package cannot reference the
// wrapper back without a cycle. `expr` bridges the two — its constructors
// unwrap child `Expr`s to `ExprNode`, and its walks wrap `ExprNode` children
// back into `Expr`.

///|
/// The expression AST. `pub(all)` so `expr` can construct nodes and the engine
/// (`frame` / `lazy`) can `match` them, but reachable only inside this module.
/// The variant tour lives on the `@expr.Expr` docstring, the public face.
pub(all) enum ExprNode {
  Col(String)
  Lit(@types.Scalar)
  LitSeries(@series.Series)
  Binary(BinOp, ExprNode, ExprNode)
  Unary(UnOp, ExprNode)
  Agg(AggOp, ExprNode)
  Str(StrOp, ExprNode)
  Cast(ExprNode, @types.DataType)
  Alias(ExprNode, String)
  Ternary(ExprNode, ExprNode, ExprNode)
  FillNull(ExprNode, ExprNode)
  FillNan(ExprNode, ExprNode)
  IsIn(ExprNode, ArrayView[@types.Scalar])
  IsBetween(ExprNode, ExprNode, ExprNode, @types.ClosedInterval)
  Map(
    String,
    ArrayView[ExprNode],
    (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError
  )
  MapBatches(
    String,
    ArrayView[ExprNode],
    Bool,
    (Array[@series.Series]) -> @series.Series raise @types.DataError
  )
}

///|
/// The immediate sub-nodes of a node, left to right — the one place the AST's
/// recursive shape is encoded. Every uniform tree walk rides this: the engine's
/// `referenced_columns` / `output_name` (via `@expr.Expr`) and the lazy
/// optimizer's `row_stable` / `group_cell_stable`. A new variant declares its
/// child structure once, here. A `Ternary` lists all three arms, condition
/// first; a `Map` a fresh copy of its inputs, so a caller cannot alias — and
/// mutate — the node's own array. Leaves (`Col` / `Lit` / `LitSeries`) have
/// none. Total.
pub fn ExprNode::children(self : ExprNode) -> Array[ExprNode] {
  match self {
    Col(_) | Lit(_) | LitSeries(_) => []
    Binary(_, l, r) => [l, r]
    Unary(_, e) | Agg(_, e) | Str(_, e) | Cast(e, _) | Alias(e, _) => [e]
    Ternary(c, t, f) => [c, t, f]
    FillNull(o, v) | FillNan(o, v) => [o, v]
    IsIn(e, _) => [e]
    IsBetween(x, lo, hi, _) => [x, lo, hi]
    Map(_, inputs, _) => inputs.to_owned()
    MapBatches(_, inputs, _, _) => inputs.to_owned()
  }
}

///|
/// Binary operator tag carried by `Binary`. `And` / `Or` are the Kleene
/// three-valued logical connectives (`&` / `|` at the call site).
pub(all) enum BinOp {
  Add
  Sub
  Mul
  Div
  FloorDiv
  Mod
  Pow
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
pub extend BinOp with Eq::{equal, not_equal}

///|
pub extend BinOp with Debug::{to_repr}

///|
/// Unary operator tag carried by `Unary`. `Neg` is numeric negation, `Not` is
/// Kleene logical negation, the null probes `IsNull` / `IsNotNull` read validity
/// only, the NaN probes `IsNan` / `IsNotNan` test for the IEEE `NaN` value, and
/// `Round` carries its decimal-place count.
pub(all) enum UnOp {
  Neg
  Not
  IsNull
  IsNotNull
  IsNan
  IsNotNan
  Abs
  Floor
  Ceil
  Sign
  Round(Int)
} derive(Eq, Debug)

///|
pub extend UnOp with Eq::{equal, not_equal}

///|
pub extend UnOp with Debug::{to_repr}

///|
/// Aggregation tag carried by `Agg`. `Sum` / `Mean` propagate NaN and
/// `Std` / `Var` carry it through the mean; `Min` / `Max` and `Median` skip it;
/// `Count` counts non-null cells and `NUnique` the distinct non-null values;
/// `First` / `Last` are positional. Mirrored one-to-one by `@series.ReduceOp`,
/// the reduction kernel's vocabulary (`frame`'s `reduce_op_of_agg` maps between
/// them) — a variant added here must be added there too.
pub(all) enum AggOp {
  Sum
  Mean
  Min
  Max
  Count
  Std
  Var
  Median
  NUnique
  First
  Last
} derive(Eq, Debug)

///|
pub extend AggOp with Eq::{equal, not_equal}

///|
pub extend AggOp with Debug::{to_repr}

///|
/// String-operation tag carried by `Str` — one variant per method of the
/// `Expr::str_*` namespace, the parameterised ones carrying their literal
/// arguments so a tag is self-contained and structurally comparable. The regex
/// variants (`ContainsRegex` / `ReplaceRegex` / `ReplaceAllRegex` / `Extract` /
/// `CountMatches`) carry a POSIX pattern; the rest are literal.
pub(all) enum StrOp {
  ToUppercase
  ToLowercase
  StripChars
  LenChars
  Contains(String)
  StartsWith(String)
  EndsWith(String)
  Replace(String, String)
  ReplaceAll(String, String)
  Reverse
  PadStart(Int, Char)
  PadEnd(Int, Char)
  ContainsRegex(String)
  ReplaceRegex(String, String)
  ReplaceAllRegex(String, String)
  Extract(String, Int)
  CountMatches(String)
  Slice(Int, Int?)
  LenBytes
  StripCharsCustom(String)
  SplitGet(String, Int)
  ZFill(Int)
} derive(Eq, Debug)

///|
pub extend StrOp with Eq::{equal, not_equal}

///|
pub extend StrOp with Debug::{to_repr}
