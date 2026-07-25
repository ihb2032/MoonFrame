// The expression AST, module-internal. `ExprNode` and its operator tags are
// the shape a `@expr.Expr` wraps and the shape `frame`'s evaluator and `lazy`'s
// optimizer walk. Keeping them in an `internal/` package makes them a hard,
// language-enforced boundary — a downstream module cannot import this package
// at all — rather than a documentation convention, so the AST genuinely cannot
// leak into the public surface. The public, buildable-and-matchable `Expr`
// handle lives in `expr`; the constructible-by-callers `ClosedInterval` lives
// in `types`.
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
  IsIn(ExprNode, Array[@types.Scalar])
  IsBetween(ExprNode, ExprNode, ExprNode, @types.ClosedInterval)
  Map(
    String,
    Array[ExprNode],
    (Array[@types.Scalar]) -> @types.Scalar raise @types.DataError
  )
  MapBatches(
    String,
    Array[ExprNode],
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
    Map(_, inputs, _) => inputs.copy()
    MapBatches(_, inputs, _, _) => inputs.copy()
  }
}

///|
/// Structural equality, handwritten because the `Map` / `MapBatches` closures
/// have no `Eq`, so the enum cannot `derive` one. Two `Map` nodes are equal on
/// `(label, inputs)` with the function opaque; `MapBatches` also compares its
/// `returns_scalar` flag. Every other variant compares recursively. The
/// `@expr.Expr` wrapper derives its `Eq` off this, so `DataFrame` / `LogicalPlan`
/// equality reaches here.
pub impl Eq for ExprNode with fn equal(self, other) {
  nodes_structurally_equal(self, other)
}

///|
pub extend ExprNode with Eq::{equal, not_equal}

///|
/// Structural equality over an explicit work-stack of node pairs rather than
/// the call stack: a deeply nested tree (`col("a") + col("a") + …` tens of
/// thousands deep) would otherwise overflow the native stack and abort. Each
/// iteration matches the first operand wildcard-free and then the second, so a
/// differing variant short-circuits to `false` and a newly added `ExprNode`
/// variant fails to compile here until its case is written.
fn nodes_structurally_equal(first : ExprNode, second : ExprNode) -> Bool {
  let stack : Array[(ExprNode, ExprNode)] = [(first, second)]
  for ;; {
    match stack.pop() {
      None => break
      Some((a, b)) =>
        match a {
          Col(x) =>
            match b {
              Col(y) => if x != y { return false }
              _ => return false
            }
          Lit(x) =>
            match b {
              Lit(y) => if x != y { return false }
              _ => return false
            }
          LitSeries(x) =>
            match b {
              LitSeries(y) => if x != y { return false }
              _ => return false
            }
          Binary(o1, l1, r1) =>
            match b {
              Binary(o2, l2, r2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((l1, l2))
                stack.push((r1, r2))
              }
              _ => return false
            }
          Unary(o1, e1) =>
            match b {
              Unary(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Agg(o1, e1) =>
            match b {
              Agg(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Str(o1, e1) =>
            match b {
              Str(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Cast(e1, t1) =>
            match b {
              Cast(e2, t2) => {
                if t1 != t2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Alias(e1, n1) =>
            match b {
              Alias(e2, n2) => {
                if n1 != n2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Ternary(c1, t1, f1) =>
            match b {
              Ternary(c2, t2, f2) => {
                stack.push((c1, c2))
                stack.push((t1, t2))
                stack.push((f1, f2))
              }
              _ => return false
            }
          FillNull(o1, v1) =>
            match b {
              FillNull(o2, v2) => {
                stack.push((o1, o2))
                stack.push((v1, v2))
              }
              _ => return false
            }
          FillNan(o1, v1) =>
            match b {
              FillNan(o2, v2) => {
                stack.push((o1, o2))
                stack.push((v1, v2))
              }
              _ => return false
            }
          IsIn(e1, m1) =>
            match b {
              IsIn(e2, m2) => {
                if m1 != m2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          IsBetween(x1, l1, h1, c1) =>
            match b {
              IsBetween(x2, l2, h2, c2) => {
                if c1 != c2 {
                  return false
                }
                stack.push((x1, x2))
                stack.push((l1, l2))
                stack.push((h1, h2))
              }
              _ => return false
            }
          Map(l1, i1, _) =>
            match b {
              Map(l2, i2, _) => {
                if l1 != l2 || i1.length() != i2.length() {
                  return false
                }
                for k in 0..<i1.length() {
                  stack.push((i1[k], i2[k]))
                }
              }
              _ => return false
            }
          MapBatches(l1, i1, rs1, _) =>
            match b {
              MapBatches(l2, i2, rs2, _) => {
                if l1 != l2 || rs1 != rs2 || i1.length() != i2.length() {
                  return false
                }
                for k in 0..<i1.length() {
                  stack.push((i1[k], i2[k]))
                }
              }
              _ => return false
            }
        }
    }
  }
  true
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
