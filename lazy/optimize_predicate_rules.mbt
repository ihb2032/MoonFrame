// The expression soundness analyses behind the predicate pass, fused into one
// walk. Three properties classify a tree — row locality, signed-zero safety,
// and group-cell stability — and they used to be three separate walks with
// three per-member classifications drifting alongside each other. They share
// everything that matters: the same tree, the same combinator-versus-fence
// shape, and (for one arm) each other's verdicts. So one bottom-up pass now
// computes all three at once, and the per-node classification — which variants
// and tag members fence which property — lives in a single match, the table
// every property is read from. A new operator adds one row there; a new
// property adds one column plus its propagation statement.

///|
/// The three soundness properties of an expression tree, computed together:
/// `row_local` (the `row_stable` verdict — no cell of the tree can observe
/// which rows exist), `zero_sign_safe` (no cell can tell `-0.0` from `+0.0`),
/// and `group_cell` (the `group_cell_stable` verdict — a reduction-shaped
/// tree whose per-group cell cannot move when groups appear or vanish around
/// it). Each field's full soundness argument is stated on the wrapper that
/// reads it; this struct is only the bundle the one walk fills.
priv struct ExprProps {
  row_local : Bool
  zero_sign_safe : Bool
  group_cell : Bool
}

///|
/// The three properties of a whole tree, in one iterative walk. Discovery
/// emits every node ahead of its descendants while recording each node's
/// child count; iterating that emission backwards then visits every child
/// before its parent, so a node's children's properties sit on the value
/// stack by the time the node itself reaches the classification table.
/// Explicit stacks, not the call stack — a deeply nested expression analyzes
/// without overflowing and aborting, like every engine walk. Total.
fn expr_props(expr : @ir.ExprNode) -> ExprProps {
  let discover : Array[@ir.ExprNode] = [expr]
  let order : Array[@ir.ExprNode] = []
  let arities : Array[Int] = []
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
  let values : Array[ExprProps] = []
  for i = order.length() - 1; i >= 0; i = i - 1 {
    // The popped properties come off in reverse child order; no table arm
    // depends on order (combinators conjoin, and the one single-child query
    // is the `Agg` arm's operand), so the reversal is left un-fixed.
    let kids : Array[ExprProps] = []
    for _ in 0..<arities[i] {
      kids.push(values[values.length() - 1])
      let _ = values.pop()
    }
    values.push(classify(order[i], kids))
  }
  values[values.length() - 1]
}

///|
/// The per-node classification table — the one place a variant or tag member
/// declares what it fences. For each property a node is either a *fence*
/// (false regardless of its children) or a *combinator* (the conjunction of
/// its children's); the arms below say which, per property, and the
/// exhaustive matches carry no wildcard so a variant or member added later
/// fails compilation here until someone vouches for it — the silent default,
/// descent, would be the unsound verdict for anything that can observe rows,
/// a zero's sign, or a group's membership. `kids` holds the children's
/// already-computed properties, and its conjunction is the combinator
/// verdict for every property at once.
fn classify(node : @ir.ExprNode, kids : Array[ExprProps]) -> ExprProps {
  fn kids_and(kids : Array[ExprProps]) -> ExprProps {
    let mut row = true
    let mut zero = true
    let mut gcs = true
    for k in kids {
      row = row && k.row_local
      zero = zero && k.zero_sign_safe
      gcs = gcs && k.group_cell
    }
    { row_local: row, zero_sign_safe: zero, group_cell: gcs, }
  }

  match node {
    // A column read is row-local and zero-sign-blind, but a group cell it
    // feeds reads whatever rows the group kept — never stable.
    @ir.ExprNode::Col(_) =>
      { row_local: true, zero_sign_safe: true, group_cell: false, }
    // The null literal is a null cell by definition — a group cell nulls.
    // Every other literal is a fence-free leaf on all three properties.
    @ir.ExprNode::Lit(value) =>
      {
        row_local: true,
        zero_sign_safe: true,
        group_cell: !(value is @types.Scalar::Null),
      }
    // A literal series is positional data (its own height): not row-local,
    // not reduction-shaped, but blind to a zero's sign.
    @ir.ExprNode::LitSeries(_) =>
      { row_local: false, zero_sign_safe: true, group_cell: false, }
    // Division and a negative exponent are the operators that make a zero's
    // sign observable (`1.0 / +0.0 = +inf` but `1.0 / -0.0 = -inf`); every
    // other member treats `-0.0` and `+0.0` as equal and descends. All
    // members are row-local and group-cell combinators.
    @ir.ExprNode::Binary(op, _, _) => {
      let combined = kids_and(kids)
      {
        row_local: combined.row_local,
        zero_sign_safe: match op {
          @ir.BinOp::Div | @ir.BinOp::FloorDiv | @ir.BinOp::Pow => false
          @ir.BinOp::Add
          | @ir.BinOp::Sub
          | @ir.BinOp::Mul
          | @ir.BinOp::Mod
          | @ir.BinOp::Eq
          | @ir.BinOp::Ne
          | @ir.BinOp::Lt
          | @ir.BinOp::Le
          | @ir.BinOp::Gt
          | @ir.BinOp::Ge
          | @ir.BinOp::And
          | @ir.BinOp::Or => combined.zero_sign_safe
        },
        group_cell: combined.group_cell,
      }
    }
    // The `Dt*` quartet raises on a *value* — a day count outside the
    // calendar domain — so a dropped row can drop the very cell that would
    // have raised: a row-locality fence, like `Cast`. Every other member is
    // row-local (raises only on the dtype, a scope-independent fact); `Round`
    // reads only its place count.
    @ir.ExprNode::Unary(op, _) => {
      let combined = kids_and(kids)
      {
        row_local: match op {
          @ir.UnOp::DtYear
          | @ir.UnOp::DtMonth
          | @ir.UnOp::DtDay
          | @ir.UnOp::DtWeekday => false
          @ir.UnOp::Neg
          | @ir.UnOp::Not
          | @ir.UnOp::IsNull
          | @ir.UnOp::IsNotNull
          | @ir.UnOp::IsNan
          | @ir.UnOp::IsNotNan
          | @ir.UnOp::IsFinite
          | @ir.UnOp::IsInfinite
          | @ir.UnOp::Abs
          | @ir.UnOp::Floor
          | @ir.UnOp::Ceil
          | @ir.UnOp::Sign
          | @ir.UnOp::Round(_) => combined.row_local
        },
        zero_sign_safe: combined.zero_sign_safe,
        group_cell: combined.group_cell,
      }
    }
    // An aggregation is scope-bound (its cell reads the whole scope) and its
    // rejection can be value-dependent — a row-locality fence. Its group-cell
    // verdict is the reduce table's, *and* the operand's row locality: a
    // `sum(col.cast(Int))` still raises on the cells its operand meets, so a
    // value-raising operand fences exactly as a top-level cast does. The
    // zero-sign verdict descends (an aggregation over zero-sign-blind cells
    // cannot expose a sign the cells do not carry).
    @ir.ExprNode::Agg(op, _) => {
      let combined = kids_and(kids)
      {
        row_local: false,
        zero_sign_safe: combined.zero_sign_safe,
        group_cell: match op {
          @series.ReduceOp::Sum
          | @series.ReduceOp::Count
          | @series.ReduceOp::NUnique
          | @series.ReduceOp::Mean
          | @series.ReduceOp::Min
          | @series.ReduceOp::Max => combined.row_local
          @series.ReduceOp::Std
          | @series.ReduceOp::Var
          | @series.ReduceOp::Median
          // An order statistic read at `q * (m - 1)`: its cell depends on the
          // whole value multiset, so a group whose cell a predicate reads
          // changes when rows sink in or out of it.
          | @series.ReduceOp::Quantile(_, _)
          // `arg_min` / `arg_max` name a *position* — the row a sinking
          // filter removes is exactly the one the arg could point at.
          // `mode` names the multiset's most frequent value — a sinking
          // filter changes frequencies.
          | @series.ReduceOp::ArgMin
          | @series.ReduceOp::ArgMax
          | @series.ReduceOp::Mode
          | @series.ReduceOp::First
          | @series.ReduceOp::Last => false
        },
      }
    }
    // The string namespace is row-local throughout — every member enumerated
    // so a new one fails compilation here rather than silently inheriting
    // the descent — and the regex family raises only on its pattern's
    // compile, hoisted out of the per-cell map: a fact of the pattern, not
    // of the rows present.
    @ir.ExprNode::Str(op, _) => {
      let combined = kids_and(kids)
      {
        row_local: match op {
          @ir.StrOp::ToUppercase
          | @ir.StrOp::ToLowercase
          | @ir.StrOp::StripChars
          | @ir.StrOp::LenChars
          | @ir.StrOp::Contains(_)
          | @ir.StrOp::StartsWith(_)
          | @ir.StrOp::EndsWith(_)
          | @ir.StrOp::Replace(_, _)
          | @ir.StrOp::ReplaceAll(_, _)
          | @ir.StrOp::Reverse
          | @ir.StrOp::PadStart(_, _)
          | @ir.StrOp::PadEnd(_, _)
          | @ir.StrOp::ContainsRegex(_)
          | @ir.StrOp::ReplaceRegex(_, _)
          | @ir.StrOp::ReplaceAllRegex(_, _)
          | @ir.StrOp::Extract(_, _)
          | @ir.StrOp::CountMatches(_)
          | @ir.StrOp::Slice(_, _)
          | @ir.StrOp::LenBytes
          | @ir.StrOp::StripCharsCustom(_)
          | @ir.StrOp::SplitGet(_, _)
          | @ir.StrOp::ZFill(_) => combined.row_local
        },
        zero_sign_safe: combined.zero_sign_safe,
        group_cell: combined.group_cell,
      }
    }
    // A positional transform reads its neighbors — row-locality and
    // group-cell fences; its cells expose no zero sign of their own.
    @ir.ExprNode::Positional(_, _) => {
      let combined = kids_and(kids)
      {
        row_local: false,
        zero_sign_safe: combined.zero_sign_safe,
        group_cell: false,
      }
    }
    // A cast's rejection is value-dependent (both directions of the
    // conversion); a map's closure is opaque to row locality and group cells
    // (null- or raise-valued on the cells it meets). Both still descend for
    // the zero-sign verdict: cells blind to a sign cannot expose one. A
    // `MapBatches` is the map rule over whole series.
    @ir.ExprNode::Cast(_, _) => {
      let combined = kids_and(kids)
      {
        row_local: false,
        zero_sign_safe: combined.zero_sign_safe,
        group_cell: false,
      }
    }
    @ir.ExprNode::Map(_, _, _) | @ir.ExprNode::MapBatches(_, _, _, _) => {
      let combined = kids_and(kids)
      {
        row_local: false,
        zero_sign_safe: combined.zero_sign_safe,
        group_cell: false,
      }
    }
    // The combinators: the alias wrapper, selections, and fills conjoin all
    // three properties cell-wise.
    @ir.ExprNode::Alias(_, _)
    | @ir.ExprNode::Ternary(_, _, _)
    | @ir.ExprNode::FillNull(_, _)
    | @ir.ExprNode::FillNan(_, _)
    | @ir.ExprNode::IsIn(_, _)
    | @ir.ExprNode::IsBetween(_, _, _, _) => kids_and(kids)
  }
}

///|
/// Whether an expression's cells cannot observe which rows exist — the
/// predicate pass's row-locality gate. A row-local expression raises, if at
/// all, only on scope-independent facts (a dtype, a pattern's compile), so
/// dropping rows before it evaluates provably changes nothing about the
/// surviving cells or the raised errors. Computed as the `row_local` field
/// of the fused analysis.
fn row_stable(expr : @ir.ExprNode) -> Bool {
  expr_props(expr).row_local
}

///|
/// Whether `expr` cannot observe the sign of a zero — the extra gate the
/// `Aggregate` predicate pushdown needs to stay sound on a `Float` group key.
/// `KeyCell` folds `-0.0` and `+0.0` into one group, but the group's output row
/// keeps its *representative* row's signed key, so a predicate that can tell
/// the two apart disagrees between a group's individual rows (filtered below
/// the aggregate) and that representative (filtered above it). Division and a
/// negative exponent are the operators in the vocabulary that make a zero's
/// sign observable — `1.0 / +0.0 = +inf` but `1.0 / -0.0 = -inf`, and
/// `(+0.0) ** -1.0 = +inf` but `(-0.0) ** -1.0 = -inf`, while `+` / `-` / `*`
/// / `%` and every comparison treat `-0.0` and `+0.0` as equal (remainder can
/// carry a zero's sign into its result but no comparison downstream can read it
/// back out) — so a signed-zero-safe predicate gives every row of a folded
/// group the same verdict and may sink below the aggregate, while one that
/// divides or exponentiates could drop only part of the group and must stay
/// above. Computed as the `zero_sign_safe` field of the fused analysis.
fn signed_zero_safe(expr : @ir.ExprNode) -> Bool {
  expr_props(expr).zero_sign_safe
}

///|
/// Whether an aggregation expression's per-group cell is provably
/// independent of *which other groups exist*: never changing value,
/// null-ness, or raised error when groups appear or disappear around it.
/// The gate is the group-invariance argument stated once in the
/// crossing-rules header of `push_predicates`, the pass driver this rule
/// serves; per op it says:
/// `sum` / `count` / `n_unique` always produce a non-null value, and
/// `mean` / `min` / `max` are pure functions of their group's cells
/// (null exactly when an all-null group makes them so) — all four cross
/// **only over a `row_stable` operand**, because a `sum(col.cast(Int))` or
/// `sum(col.map(…))` still raises on the cells its operand meets, so a
/// value-raising operand (a nested `Cast` / `Map`, or an `Agg` /
/// `LitSeries`) fences the filter above exactly as a top-level cast does.
/// The sample statistics (`std` / `var` / `median`) and `first` / `last`
/// stay fenced as a conservative bound — loosening them wants the same
/// argument per op and no consumer has asked for it.
/// A `cast`'s rejection is value-dependent, as is a
/// `map`'s opaque closure (null- or raise-valued on the cells it meets);
/// the null literal is a null cell by definition; a bare column — or a
/// `lit_series`, equally row-wise — is not reduction-shaped at all (the
/// executor raises structurally — fencing keeps that error exactly where the
/// as-built plan reports it). The
/// combinators preserve the property cell-wise: arithmetic, comparison,
/// and the Kleene connectives over non-null cells stay non-null, as do the
/// unary wrappers, the string-namespace transforms, and a ternary over a
/// non-null condition. Computed as the `group_cell` field of the fused
/// analysis.
fn group_cell_stable(expr : @ir.ExprNode) -> Bool {
  expr_props(expr).group_cell
}

///|
/// Whether the selection list contains `name` as a bare `col(name)` item.
/// "Bare" is a read concept with several readers, and each chooses its
/// alias stance deliberately rather than by one shared definition: this
/// predicate and the aggregate crossing's key test take the strict
/// spelling (`col(name)` alone — an aliased column is a different node);
/// frame's projection bookkeeping peels the alias layers first (a rename
/// still reads the column beneath); join's key coalescing does not (an
/// aliased key keeps its own output name). A new reader of the concept
/// must pick a stance on purpose and say so beside its match, the
/// `leftmost_name` precedent.
fn has_bare_column(exprs : Array[@expr.Expr], name : String) -> Bool {
  for expr in exprs {
    match expr.node() {
      @ir.ExprNode::Col(n) => if n == name { return true }
      _ => ()
    }
  }
  false
}

///|
/// Whether the stage defines none of the predicate's columns — the
/// `WithColumns` crossing rule. A defined name is served by the stage
/// itself: below it, the name either does not exist or (a replacement)
/// holds the original values the stage was about to overwrite, so a
/// predicate reading one must stay above.
fn defines_none_of(exprs : Array[@expr.Expr], predicate : @expr.Expr) -> Bool {
  let refs = predicate.referenced_columns()
  for expr in exprs {
    if refs.contains(expr.output_name()) {
      return false
    }
  }
  true
}

///|
/// Whether every expression in the list is row-local — the shared gate both
/// descending passes consult (the predicate pass states the argument; this
/// is the same verdict read from the fused analysis).
fn all_row_stable(exprs : Array[@expr.Expr]) -> Bool {
  exprs.all(e => row_stable(e.node()))
}

///|
/// Whether the selection's output height tracks its input's — it is *not*
/// an all-constant projection. A column-free selection collapses any input,
/// even zero rows, to a single row, so a window crossing it would pick from
/// rows that never survive the collapse. Reached only after `all_row_stable`
/// has excluded the aggregations and casts, so an expression is frame-tall
/// exactly when it reads a column.
fn preserves_row_count(exprs : Array[@expr.Expr]) -> Bool {
  for expr in exprs {
    if !expr.referenced_columns().is_empty() {
      return true
    }
  }
  false
}
