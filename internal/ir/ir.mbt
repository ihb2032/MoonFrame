// The expression AST, module-internal. `ExprNode` and its operator tags are
// the shape an `Expr` wraps and the shape `frame`'s evaluator and `lazy`'s
// optimizer walk. Keeping them in an internal package makes them a hard,
// language-enforced boundary — a downstream module cannot import this package
// at all — rather than a documentation convention, so the AST genuinely cannot
// leak into the public surface. The public `Expr` handle above it
// is buildable but **opaque** (no variants to match from outside); only the
// in-module engine reads the `ExprNode` stored inside it. The
// constructible-by-callers `ClosedInterval` belongs to the value-type layer.
//
// A node's children are `ExprNode`, not the `Expr` wrapper: the wrapper
// references this package for its field, so this package cannot reference the
// wrapper back without a cycle. `expr` bridges the two — its constructors
// unwrap child `Expr`s to `ExprNode`, and its walks wrap `ExprNode` children
// back into `Expr`.

///|
/// The expression AST. `pub(all)` so `expr` can construct nodes and the engine
/// (`frame` / `lazy`) can `match` them, but reachable only inside this module.
/// The variant tour is carried by the public `Expr` handle's documentation, the
/// public face.
pub(all) enum ExprNode {
  Col(String)
  Lit(@types.Scalar)
  LitSeries(@series.Series)
  Binary(BinOp, ExprNode, ExprNode)
  Unary(UnOp, ExprNode)
  Agg(@series.ReduceOp, ExprNode)
  Str(StrOp, ExprNode)
  Positional(PositionalOp, ExprNode)
  Cast(ExprNode, @types.DataType)
  Alias(ExprNode, String)
  Ternary(ExprNode, ExprNode, ExprNode)
  FillNull(ExprNode, ExprNode)
  FillNan(ExprNode, ExprNode)
  Diff(ExprNode, Int32)
  Clip(ExprNode, ExprNode?, ExprNode?)
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
/// recursive *shape* is encoded, and only the shape. Every walk rides this for
/// its descent: the engine's `referenced_columns` / `output_name` (via
/// the `Expr` handle) and the lazy optimizer's `row_stable` /
/// `group_cell_stable`.
/// What none of them inherits from here is the *semantics* of a new variant.
/// `referenced_columns` alone is uniform enough to be automatic; the others
/// classify per variant — naming (the `leftmost_name` rule, where
/// `Alias` / `LitSeries` / `Ternary` mean something particular) and pushdown
/// soundness (row-local vs value barrier vs shape barrier) are decisions, so a
/// variant added here fails to compile against their exhaustive `match`es until
/// each one is made. The demand reaches one level further for the operator
/// tags: a variant that only *carries* a tag would hand a new member the
/// container's verdict silently, so the soundness matches enumerate the tag
/// members too (`UnOp` / `StrOp` in `row_stable`, `BinOp` in
/// `signed_zero_safe`, `ReduceOp` in `group_cell_stable`). That is the
/// intended sequence, not an inconvenience.
///
/// A `Ternary` lists all three arms, condition
/// first; a `Map` a fresh copy of its inputs, so a caller cannot alias — and
/// mutate — the node's own array. Leaves (`Col` / `Lit` / `LitSeries`) have
/// none. Total.
pub fn ExprNode::children(self : ExprNode) -> Array[ExprNode] {
  match self {
    Col(_) | Lit(_) | LitSeries(_) => []
    Binary(_, l, r) => [l, r]
    Unary(_, e)
    | Agg(_, e)
    | Str(_, e)
    | Positional(_, e)
    | Cast(e, _)
    | Alias(e, _) => [e]
    Ternary(c, t, f) => [c, t, f]
    FillNull(o, v) | FillNan(o, v) => [o, v]
    Diff(e, _) => [e]
    // Only the bounds that exist are children; an omitted side is no node at
    // all, so the walk never sees a `None` as a child.
    Clip(x, lo, hi) => {
      let kids : Array[ExprNode] = [x]
      if lo is Some(l) {
        kids.push(l)
      }
      if hi is Some(h) {
        kids.push(h)
      }
      kids
    }
    IsIn(e, _) => [e]
    IsBetween(x, lo, hi, _) => [x, lo, hi]
    Map(_, inputs, _) => inputs.to_owned()
    MapBatches(_, inputs, _, _) => inputs.to_owned()
  }
}

///|
/// Rewrite every `Col` reference through `mapping`, keeping any name the
/// mapping does not carry. The tree-shaped twin of `children`: the same
/// shape-only walk, rebuilding each node over its rewritten children with
/// every other payload — operator tags, literals, aliases, the `Map` /
/// `MapBatches` closures — carried verbatim, so the result evaluates the
/// same expression against a frame that bears the new spellings. Total.
/// Exhaustive on purpose, like `children`: a variant added to `ExprNode`
/// fails this match until its sub-nodes are carried through, so a column
/// reference can never hide under an unrewritten payload.
///
/// Iterative, like every engine walk: the tree is discovered with an
/// explicit stack (`children` per node) into a post-order, then rebuilt in
/// reverse discovery order so each node's children are renamed before the
/// node itself. No recursion — a machine-built predicate of any depth
/// renames without overflowing the stack. The rebuild `match` stays
/// exhaustive for the same reason the recursive form was: a new variant
/// fails compilation here until its rebuild arm exists.
pub fn ExprNode::rename_columns(
  self : ExprNode,
  mapping : Map[String, String],
) -> ExprNode {
  let discover : Array[ExprNode] = [self]
  let order : Array[ExprNode] = []
  let arities : Array[Int32] = []
  for ;; {
    match discover.pop() {
      None => break
      Some(node) => {
        let kids = node.children()
        order.push(node)
        arities.push(kids.length())
        for k in kids {
          discover.push(k)
        }
      }
    }
  }
  let values : Array[ExprNode] = []
  for i = order.length() - 1; i >= 0; i = i - 1 {
    let node = order[i]
    // Pop the rewritten children and restore input order — the value stack
    // yields them last-first, and the rebuild below slots children
    // positionally (an operand and its bounds are not interchangeable).
    let popped : Array[ExprNode] = []
    for _ in 0..<arities[i] {
      popped.push(values[values.length() - 1])
      let _ = values.pop()
    }
    let kids : Array[ExprNode] = Array::makei(popped.length(), k => {
      popped[popped.length() - 1 - k]
    })
    values.push(
      match node {
        Col(name) =>
          match mapping.get(name) {
            Some(renamed) => Col(renamed)
            None => node
          }
        Lit(_) | LitSeries(_) => node
        Binary(op, _, _) => Binary(op, kids[0], kids[1])
        Unary(op, _) => Unary(op, kids[0])
        Agg(op, _) => Agg(op, kids[0])
        Str(op, _) => Str(op, kids[0])
        Positional(op, _) => Positional(op, kids[0])
        Cast(_, target) => Cast(kids[0], target)
        Alias(_, name) => Alias(kids[0], name)
        Ternary(_, _, _) => Ternary(kids[0], kids[1], kids[2])
        FillNull(_, _) => FillNull(kids[0], kids[1])
        FillNan(_, _) => FillNan(kids[0], kids[1])
        Diff(_, n) => Diff(kids[0], n)
        // The kids array carries only the bounds that exist (the `children`
        // order: operand, then lower, then upper), so the original node's
        // `Option` structure decides which slot each renamed kid returns to.
        Clip(_, lo, hi) => {
          fn take(present : Bool, idx : Int32) -> ExprNode? {
            if present {
              Some(kids[idx])
            } else {
              None
            }
          }
          Clip(
            kids[0],
            take(lo is Some(_), 1),
            take(hi is Some(_), if lo is Some(_) { 2 } else { 1 }),
          )
        }
        IsIn(_, members) => IsIn(kids[0], members)
        IsBetween(_, _, _, closed) =>
          IsBetween(kids[0], kids[1], kids[2], closed)
        Map(label, _, f) => Map(label, kids, f)
        MapBatches(label, _, returns_bool, f) =>
          MapBatches(label, kids, returns_bool, f)
      },
    )
  }
  values[values.length() - 1]
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
/// only, the NaN probes `IsNan` / `IsNotNan` test for the IEEE `NaN` value,
/// the finiteness probes `IsFinite` / `IsInfinite` the IEEE `NaN` /
/// infinity split (an `Int` cell is always finite, never either), the
/// `Dt*` quartet reads a `Date` cell's calendar components (ISO weekday,
/// Monday 1 through Sunday 7), and
/// `Round` carries its decimal-place count.
pub(all) enum UnOp {
  Neg
  Not
  IsNull
  IsNotNull
  IsNan
  IsNotNan
  IsFinite
  IsInfinite
  DtYear
  DtMonth
  DtDay
  DtWeekday
  Abs
  Floor
  Ceil
  Sign
  Round(Int32)
} derive(Eq, Debug)

///|
pub extend UnOp with Eq::{equal, not_equal}

///|
pub extend UnOp with Debug::{to_repr}

///|
/// String-operation tag carried by `Str` — the lowered forms of the
/// `Expr::str_*` namespace, the parameterised ones carrying their literal
/// arguments so a tag is self-contained and structurally comparable. Not one
/// variant per method: a method whose argument selects the matching mode lowers
/// to a different tag per mode, which is why the regex variants
/// (`ContainsRegex` / `ReplaceRegex` / `ReplaceAllRegex` / `Extract` /
/// `CountMatches`, each carrying a POSIX pattern) outnumber the `literal?`-taking
/// methods that reach them, and why `StripChars` and `StripCharsCustom` are two
/// tags for one method.
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
  PadStart(Int32, Char)
  PadEnd(Int32, Char)
  ContainsRegex(String)
  ReplaceRegex(String, String)
  ReplaceAllRegex(String, String)
  Extract(String, Int32)
  CountMatches(String)
  Slice(Int32, Int32?)
  LenBytes
  StripCharsCustom(String)
  SplitGet(String, Int32)
  ZFill(Int32)
} derive(Eq, Debug)

///|
pub extend StrOp with Eq::{equal, not_equal}

///|
/// Which statistic a `Rolling` window computes: `sum` / `mean` / `min` /
/// `max` / `std` / `var` / `median`. Named by no public signature — the
/// builders spell the verb, the tag carries it — so it stays inside the
/// AST package.
pub(all) enum RollStat {
  Sum
  Mean
  Min
  Max
  Std
  Var
  Median
} derive(Eq, Debug)

///|
pub extend RollStat with Eq::{equal, not_equal}

///|
pub extend RollStat with Debug::{to_repr}

///|
/// Positional operator tag carried by `Positional` — the history-dependent
/// transforms whose cell at row `i` reads the operand's cells at other rows:
/// `Shift(n, fill)` moves values by `n` (positive `n` = SQL `LAG` — a value
/// lands `n` rows below — vacated slots taking `fill`, `Null` for a plain
/// gap); the `Cum*` family accumulates with the `Bool` flag naming
/// `reverse` (a null slot keeps its null, the running aggregate skips it);
/// `Rank(method, descending)` numbers the non-null cells per
/// `@types.RankMethod`; `ArgSort(descending, nulls_last)` emits the stable
/// permutation that would sort the operand. Every member keeps the
/// operand's dtype except `CumCount` / `Rank` non-`Average` / `ArgSort`
/// (`Int`) and `Rank(Average)` (`Float`).
///
/// `Rolling(stat, window, min_samples, center)` is the windowed half: the
/// `stat` over a `window`-wide trailing window (centred under `center`,
/// the label at the middle with `floor(window/2)` elements before it),
/// computed only where the window holds at least `min_samples` non-null
/// cells (`None` = every cell). Numeric only; `Sum` /
/// `Min` / `Max` keep the operand dtype, the rest are `Float`.
pub(all) enum PositionalOp {
  Shift(Int32, @types.Scalar)
  CumSum(Bool)
  CumMin(Bool)
  CumMax(Bool)
  CumProd(Bool)
  CumCount(Bool)
  Rank(@types.RankMethod, Bool)
  ArgSort(Bool, Bool)
  Rolling(RollStat, Int32, Int32?, Bool)
  ForwardFill(Int32?)
  BackwardFill(Int32?)
  UniqueCounts
  IsFirstDistinct
  IsLastDistinct
} derive(Eq, Debug)

///|
pub extend PositionalOp with Eq::{equal, not_equal}

///|
pub extend PositionalOp with Debug::{to_repr}

///|
pub extend StrOp with Debug::{to_repr}
