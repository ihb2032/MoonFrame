///|
/// The crossing-soundness rules for the predicate pass (`place_filter` in
/// `optimize_predicates.mbt`): the per-expression analyses that decide whether
/// dropping rows before a stage can change its output, its errors, or the
/// predicate's own verdicts. `row_stable` (row-local, non-value-raising),
/// `signed_zero_safe` (signed-zero safety on a `Float` group key),
/// `group_cell_stable` (an aggregation's per-group cell is neither null nor
/// value-raising), and the pass-through tests (`reads_only_bare_columns`,
/// `preserves_row_count`, `defines_none_of`).

///|
/// Whether evaluating `expr` is invariant under dropping *other* rows of
/// its scope: each output cell depends only on its own row (literals
/// broadcast), and no cell can raise on a value. Aggregations fail the
/// first half — their value is computed over the whole scope, so a
/// filtered scope changes it. `Cast` fails the second half — its parse /
/// range rejection raises on the *values* it meets, so dropping a row
/// can drop the very cell that would have raised. `Map` fails it the same
/// way — its opaque closure can `raise` on the values it meets — so a `Map`
/// is a value barrier, exactly like `Cast`. A `LitSeries` is a *shape*
/// barrier: a frame-tall literal column is positional (cell `i` is row `i`),
/// so dropping rows before the stage would leave it mismatched against the
/// now-shorter frame — pushing a filter past it could turn a working plan
/// into a `LengthMismatch`, so no filter crosses it either. Everything else
/// (column reads, scalar literals, the operators, the total unary probes,
/// the string-namespace transforms, aliasing, ternary selection) is
/// row-local and raises only on scope-independent facts (names, dtypes) —
/// a `Str` op is per-cell and total, raising only the dtype-level
/// `TypeMismatch` of a non-String operand.
fn row_stable(expr : @expr.Expr) -> Bool {
  // Iterative tree walk (explicit stack, not the call stack) so a deeply nested
  // predicate cannot overflow and abort during optimization — total at any
  // depth, as this function's doc promises. Every node must be row-local;
  // `children()` drives the descent, so a new `Expr` variant is covered the
  // moment it declares its children.
  let stack : Array[@expr.Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          @expr.Expr::Agg(_, _)
          | @expr.Expr::Cast(_, _)
          | @expr.Expr::Map(_, _, _)
          | @expr.Expr::LitSeries(_) => return false
          @expr.Expr::Col(_)
          | @expr.Expr::Lit(_)
          | @expr.Expr::Binary(_, _, _)
          | @expr.Expr::Unary(_, _)
          | @expr.Expr::Str(_, _)
          | @expr.Expr::Alias(_, _)
          | @expr.Expr::Ternary(_, _, _)
          | @expr.Expr::FillNull(_, _)
          | @expr.Expr::FillNan(_, _)
          | @expr.Expr::IsIn(_, _)
          | @expr.Expr::IsBetween(_, _, _) =>
            for child in e.children() {
              stack.push(child)
            }
        }
    }
  }
  true
}

///|
/// `row_stable` over a stage's whole expression list — one scope-bound or
/// value-raising expression fences the stage.
fn all_row_stable(exprs : Array[@expr.Expr]) -> Bool {
  exprs.all(row_stable)
}

///|
/// Whether `expr` cannot observe the sign of a zero — the extra gate the
/// `Aggregate` predicate pushdown needs to stay sound on a `Float` group key.
/// `KeyCell` folds `-0.0` and `+0.0` into one group, but the group's output row
/// keeps its *representative* row's signed key, so a predicate that can tell the
/// two apart disagrees between a group's individual rows (filtered below the
/// aggregate) and that representative (filtered above it). Division and a
/// negative exponent are the operators in the vocabulary that make a zero's sign
/// observable — `1.0 / +0.0 = +inf` but `1.0 / -0.0 = -inf`, and
/// `(+0.0) ** -1.0 = +inf` but `(-0.0) ** -1.0 = -inf`, while `+` / `-` / `*`
/// / `%` and every comparison treat `-0.0` and `+0.0` as equal (remainder can
/// carry a zero's sign into its result but no comparison downstream can read it
/// back out) — so a signed-zero-safe predicate gives every row of a folded group
/// the same verdict and may sink below the aggregate, while one that divides or
/// exponentiates could drop only part of the group and must stay above. Walks
/// `children()` like `row_stable`, so a future `Expr` variant is covered without
/// a wildcard.
fn signed_zero_safe(expr : @expr.Expr) -> Bool {
  // Iterative walk like `row_stable`: a deeply nested predicate stays total
  // instead of overflowing the call stack during optimization.
  let stack : Array[@expr.Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          @expr.Expr::Binary(
            @expr.BinOp::Div
            | @expr.BinOp::FloorDiv
            | @expr.BinOp::Pow,
            _,
            _
          ) => return false
          _ =>
            for child in e.children() {
              stack.push(child)
            }
        }
    }
  }
  true
}

///|
/// Whether an aggregation expression's per-group cell is provably
/// independent of *which other groups exist*: never null (so the stitched
/// column's `Builtin` / `Numeric` backend cannot flip when groups
/// disappear — `agg` converges an all-valid numeric column onto
/// `Numeric`, and structural equality sees the difference) and never
/// raising on values (so a dropped group cannot take its error with it).
/// `sum` / `count` / `n_unique` always produce a non-null value, but only
/// over a `row_stable` operand — a `sum(col.cast(Int))` or `sum(col.map(…))`
/// still raises on the cells its operand meets, so a value-raising operand
/// (a nested `Cast` / `Map`, or an `Agg` / `LitSeries`) fences the filter
/// above exactly as a top-level cast does; `mean` / `min` /
/// `max` / `std` / `var` / `median` go null on an all-null (or, for the
/// sample statistics, single-value) group, and `first` / `last` go null on a
/// null leading / trailing cell; a `cast`'s rejection is value-dependent, as is a
/// `map`'s opaque closure (null- or raise-valued on the cells it meets);
/// the null literal is a null cell by definition; a bare column — or a
/// `lit_series`, equally row-wise — is not reduction-shaped at all (the
/// executor raises structurally — fencing keeps that error exactly where the
/// as-built plan reports it). The
/// combinators preserve the property cell-wise: arithmetic, comparison,
/// and the Kleene connectives over non-null cells stay non-null, as do
/// the unary wrappers, the string-namespace transforms, and a ternary over
/// a non-null condition.
fn group_cell_stable(expr : @expr.Expr) -> Bool {
  // Iterative walk like `row_stable`: total at any predicate depth. An `Agg`
  // node is terminal here — its verdict is its op's (the reducing ops fence,
  // `Sum`/`Count`/`NUnique` defer to `row_stable` of the operand) — so its
  // operand is never pushed for further `group_cell_stable` descent.
  let stack : Array[@expr.Expr] = [expr]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          @expr.Expr::Col(_) => return false
          @expr.Expr::Lit(value) =>
            match value {
              @types.Scalar::Null => return false
              @types.Scalar::Int(_)
              | @types.Scalar::Float(_)
              | @types.Scalar::Bool(_)
              | @types.Scalar::String(_) => ()
            }
          @expr.Expr::Agg(op, operand) =>
            match op {
              @expr.AggOp::Sum | @expr.AggOp::Count | @expr.AggOp::NUnique =>
                if !row_stable(operand) {
                  return false
                }
              @expr.AggOp::Mean
              | @expr.AggOp::Min
              | @expr.AggOp::Max
              | @expr.AggOp::Std
              | @expr.AggOp::Var
              | @expr.AggOp::Median
              | @expr.AggOp::First
              | @expr.AggOp::Last => return false
            }
          @expr.Expr::Cast(_, _)
          | @expr.Expr::Map(_, _, _)
          | @expr.Expr::LitSeries(_) => return false
          @expr.Expr::Binary(_, _, _)
          | @expr.Expr::Unary(_, _)
          | @expr.Expr::Str(_, _)
          | @expr.Expr::Alias(_, _)
          | @expr.Expr::FillNull(_, _)
          | @expr.Expr::FillNan(_, _)
          | @expr.Expr::Ternary(_, _, _)
          | @expr.Expr::IsIn(_, _)
          | @expr.Expr::IsBetween(_, _, _) =>
            for child in e.children() {
              stack.push(child)
            }
        }
    }
  }
  true
}

///|
/// `group_cell_stable` over an aggregation's whole expression list — one
/// unstable cell fences the aggregation (an empty list is vacuously
/// stable: a keys-only aggregation has no stitched columns to flip).
fn all_group_cells_stable(exprs : Array[@expr.Expr]) -> Bool {
  exprs.all(group_cell_stable)
}

///|
/// Whether every column the predicate reads appears in `exprs` as a
/// *bare* `col(name)` — the pass-through test shared by the `Select`
/// (projection list) and `Aggregate` (key list) crossing rules. A bare
/// `col(name)` re-emits its input column verbatim, so the predicate sees
/// identical values below the stage, and a column the stage does not
/// output stays missing on both sides of the swap. A computed or renamed
/// occurrence does not count, even under the same output name: its values
/// are the stage's, not the input's. A *derived* key (any non-`Col`
/// expression) likewise fails the test — its output name need not exist in
/// the input at all. Vacuously true for a column-less (all-literal)
/// predicate.
fn reads_only_bare_columns(
  predicate : @expr.Expr,
  exprs : Array[@expr.Expr],
) -> Bool {
  for name in predicate.referenced_columns() {
    if !has_bare_column(exprs, name) {
      return false
    }
  }
  true
}

///|
/// Whether the selection list contains `name` as a bare `col(name)` item.
fn has_bare_column(exprs : Array[@expr.Expr], name : String) -> Bool {
  for expr in exprs {
    match expr {
      @expr.Expr::Col(n) => if n == name { return true }
      _ => ()
    }
  }
  false
}

///|
/// Whether the selection's output height tracks its input's — i.e. it is
/// *not* an all-constant projection. `select` collapses any input,
/// even zero rows, to a single row when every expression is column-free (a
/// literal or an arithmetic of literals), because each such column is
/// length 1 and nothing fixes the height at the frame's. A filter may only
/// sink past a selection that keeps rows one-for-one: pushing a *dropping*
/// predicate below a collapsing selection would let it act on the
/// pre-collapse rows, then re-materialise the one literal row the as-built
/// collapse-then-filter had dropped (0 rows built, 1 row optimized).
/// Reached only after `all_row_stable` has excluded aggregations and
/// casts, so an expression is frame-tall exactly when it reads a column.
fn preserves_row_count(exprs : Array[@expr.Expr]) -> Bool {
  for expr in exprs {
    if !expr.referenced_columns().is_empty() {
      return true
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
