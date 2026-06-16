///|
/// The query optimizer: two **total** plan→plan rewrites — pure tree
/// walking, no raise, no abort — that `collect` runs in front of the
/// executor and `explain(optimized=true)` renders for inspection. The
/// predicate pass runs first and sinks `Filter` nodes toward the scan so
/// rows drop as early as possible; the projection pass then runs a
/// required-columns analysis and narrows each `Scan` to the columns its
/// consumers provably read, so dead columns never ride through row-level
/// work. The inviolable contract is the executor's own:
/// `execute(optimize(p))` is bitwise-equal to `execute(p)` for every plan
/// that collects. Neither pass ever alters a user-written node's *content*
/// (predicates, expression lists, keys stay verbatim); the predicate pass
/// re-orders whole `Filter` nodes downward, and the projection pass only
/// *inserts* a narrowing `Select` of bare column references directly over
/// a `Scan`.
///
/// Error faithfulness under re-ordering: a plan that fails to collect
/// still fails after optimization. When exactly one stage is broken, it
/// fails with the *same* `DataError` — every error the evaluator can
/// produce (`ColumnNotFound`, dtype-level `TypeMismatch`,
/// `DuplicateColumn`, the reduction-shape `InvalidOperation`) is decided
/// by names, dtypes, and expression shape, none of which the rewrites
/// disturb. When *several* stages are independently broken, sinking a
/// filter below another broken stage can change which of their errors
/// surfaces first — both are real errors of the same plan, and which one
/// wins was an artifact of stage order to begin with. The one failure
/// mode that would be value-dependent — `cast`'s parse / range rejection,
/// where dropping a row could drop the very cell that raises — is fenced
/// off entirely: no `Filter` ever crosses a stage whose expressions
/// contain a `Cast` (see `row_stable`).
///
/// # The predicate pass
///
/// A filter may sink below a stage only when dropping rows first provably
/// cannot change the stage's output on the surviving rows, its errors, or
/// the filter's own verdicts:
///
/// - `Select` — crossed when every selected expression is `row_stable`
///   *and* the selection preserves its input's row count (it reads at
///   least one column, mapping rows one-to-one rather than collapsing to a
///   single literal row: an all-constant selection collapses any input,
///   even zero rows, to one row, so a dropping filter must stay above it),
///   and every column the predicate reads appears in the selection as a
///   *bare* `col(name)` (so the predicate sees the same values below, and
///   a predicate the selection would have starved of its column still
///   fails identically — a computed or renamed column fences the filter
///   above).
/// - `WithColumns` — crossed under the same `row_stable` rule when the
///   stage *defines* none of the predicate's columns (a defined name has
///   different values — or no existence at all — below the stage; its
///   pass-through columns are identical on both sides by construction).
/// - `Aggregate` — crossed when the predicate is `row_stable` and reads
///   only *bare-column* keys (a key written as `col(name)`: every row of a
///   group shares its key tuple, so filtering groups after aggregation and
///   filtering their rows before it drop exactly the same groups, in the
///   same first-appearance order — and a bare key's output column holds its
///   input column verbatim, so the predicate reads identical values below).
///   A *derived* key (any non-`Col` expression) outputs a computed column
///   whose name need not exist in the input at all, so a predicate over it
///   stays above; predicates over aggregation *outputs* read non-key names
///   and stay above the same way. Every aggregation must also be
///   `group_cell_stable` — its per-group cell can neither be null nor raise
///   on values: `sum` / `count` and non-null literals qualify, `mean` /
///   `min` / `max` do not (an all-null group yields a null cell, and
///   dropping that group would flip the stitched column's backend from
///   `Builtin` to `Numeric`, which the structural `Series` equality
///   observes), and `cast` does not (a dropped group could be the one whose
///   value fails to convert).
/// - Everything else stops the descent. `Head` / `Tail` / `Slice` pick
///   rows by *position*, and filtering re-numbers positions. `Sort` and
///   another `Filter` are value-safe to cross for row-stable predicates
///   but are deliberately left in place: crossing a filter re-orders
///   which predicate evaluates first, and crossing a sort buys nothing
///   until the executor can exploit sortedness. `Join` needs column
///   provenance through suffix renaming to split a predicate across its
///   sides, deferred with the projection pass's join narrowing — but
///   both sides restart their own descent, so filters inside either
///   side still sink. `Scan` is the floor.
///
/// # The projection pass
///
/// A top-down "required columns" analysis:
///
/// - `None` — the consumer may observe this node's *entire* output
///   (the plan root, or anything under a barrier node): its layout must
///   survive untouched, so no narrowing happens at this node's leaves
///   unless a descendant re-establishes a requirement of its own.
/// - `Some(s)` — the consumer reads only the named columns, **by name**,
///   and is insensitive to the node's column order and to extra columns.
///   Only the two by-name readers originate this: `Select` and
///   `Aggregate`, whose outputs are fully determined by their expression
///   / key lists. The layout-preserving nodes (`Filter` / `Sort` /
///   `Head` / `Tail` / `Slice`) pass the requirement through, widened by
///   the columns they read themselves; `WithColumns` subtracts the names
///   its expressions *define* (those need not exist in its input) and
///   adds the names they *read*. `Join` stays a barrier — splitting a
///   requirement across two sides whose outputs interleave under suffix
///   renaming is column provenance, deferred — but both sides restart
///   their own pass, so a `Select` deep under a join still narrows its
///   own scan.
///
/// Why the order insensitivity matters: narrowing a `with_columns` input
/// can turn an in-place column *replacement* into an *append* (the
/// replaced name no longer exists in the narrowed input), perturbing the
/// intermediate column order. That perturbation is only ever visible to
/// the requirement's originator — a by-name reader — never to the plan
/// root, which always starts at `None`. The `Aggregate` executor reads
/// its keys in key-list order, not input order, so it qualifies too.
///
/// Running the predicate pass first keeps the analysis honest: a sunk
/// filter is just another layout-preserving node by the time the
/// projection pass sees it, so its predicate columns stay alive at the
/// scan, and the narrowing `Select` lands *under* the sunk filter.
///
/// Deliberately deferred: pruning dead expressions from `Select` /
/// `WithColumns` lists (changes which expressions evaluate, hence which
/// *errors* a failing plan reports), narrowing or predicate-splitting
/// through `Join`, and sinking filters below `Sort`. `optimize` is also
/// not idempotent — re-optimizing an already-rewritten plan would stack
/// another (harmless) narrowing select — which is moot in practice:
/// plans are immutable, and each `collect` or `explain(optimized=true)`
/// call rewrites the as-built plan exactly once.
fn optimize(plan : LogicalPlan) -> LogicalPlan {
  push_projection(push_predicates(plan), None)
}

// ── The predicate pass ──────────────────────────────────────────────────

///|
/// One bottom-up recursion of the predicate pass: push every input first
/// (`map_children` carries the recursion to each child), then sink a
/// `Filter` into its now-rewritten input through `place_filter`. Every
/// other node is already done once its children are pushed, so only
/// `Filter` needs a local step. Bottom-up order is what lets a stack of
/// filters sink as a unit — the lower filter is already in place when the
/// upper one descends onto it — while their relative evaluation order never
/// changes. Total: every arm is plain data work.
fn push_predicates(plan : LogicalPlan) -> LogicalPlan {
  let pushed = map_children(plan, push_predicates)
  match pushed {
    Filter(input, predicate) => place_filter(input, predicate)
    _ => pushed
  }
}

///|
/// Rebuild `plan` with `f` applied to each of its child plans, leaving the
/// node's own payload (expression lists, keys, predicate, sort spec, join
/// options) verbatim — the structural-recursion primitive the plan→plan
/// passes share, the `LogicalPlan` analogue of `Expr::children`. A leaf
/// (`Scan`) has no child plans and returns unchanged; `Join` maps both
/// sides. The one place that enumerates the IR's recursive shape, so a new
/// node declares its recursion here once rather than in every pass. Total.
fn map_children(
  plan : LogicalPlan,
  f : (LogicalPlan) -> LogicalPlan,
) -> LogicalPlan {
  match plan {
    Scan(_) => plan
    Select(input, exprs) => Select(f(input), exprs)
    WithColumns(input, exprs) => WithColumns(f(input), exprs)
    Filter(input, predicate) => Filter(f(input), predicate)
    Sort(input, by) => Sort(f(input), by)
    Head(input, n) => Head(f(input), n)
    Tail(input, n) => Tail(f(input), n)
    Slice(input, start, end) => Slice(f(input), start, end)
    Join(left, right, options) => Join(f(left), f(right), options)
    Aggregate(input, keys, exprs) => Aggregate(f(input), keys, exprs)
  }
}

///|
/// Sink one predicate into `input` as deep as the crossing rules allow
/// (see the header), wrapping the floor it reaches in the `Filter` node.
/// Each hop reproduces the crossed stage verbatim above the descending
/// filter, so `place_filter(input, p)` is always plan-equivalent to
/// `Filter(input, p)` — the hops are exactly the swaps proven safe.
fn place_filter(input : LogicalPlan, predicate : @expr.Expr) -> LogicalPlan {
  match input {
    Select(inner, exprs) =>
      if all_row_stable(exprs) &&
        preserves_row_count(exprs) &&
        reads_only_bare_columns(predicate, exprs) {
        Select(place_filter(inner, predicate), exprs)
      } else {
        Filter(input, predicate)
      }
    WithColumns(inner, exprs) =>
      if all_row_stable(exprs) && defines_none_of(exprs, predicate) {
        WithColumns(place_filter(inner, predicate), exprs)
      } else {
        Filter(input, predicate)
      }
    Aggregate(inner, keys, exprs) =>
      if row_stable(predicate) &&
        reads_only_keys(predicate, keys) &&
        all_group_cells_stable(exprs) {
        Aggregate(place_filter(inner, predicate), keys, exprs)
      } else {
        Filter(input, predicate)
      }
    Scan(_)
    | Filter(_, _)
    | Sort(_, _)
    | Head(_, _)
    | Tail(_, _)
    | Slice(_, _, _)
    | Join(_, _, _) => Filter(input, predicate)
  }
}

///|
/// Whether evaluating `expr` is invariant under dropping *other* rows of
/// its scope: each output cell depends only on its own row (literals
/// broadcast), and no cell can raise on a value. Aggregations fail the
/// first half — their value is computed over the whole scope, so a
/// filtered scope changes it. `Cast` fails the second half — its parse /
/// range rejection raises on the *values* it meets, so dropping a row
/// can drop the very cell that would have raised. `Map` fails it the same
/// way — its opaque closure can `raise` on the values it meets — so a `Map`
/// is a value barrier, exactly like `Cast`. Everything else (column reads,
/// literals, the operators, the total unary probes, aliasing, ternary
/// selection) is row-local and raises only on scope-independent facts
/// (names, dtypes).
fn row_stable(expr : @expr.Expr) -> Bool {
  match expr {
    @expr.Expr::Agg(_, _) | @expr.Expr::Cast(_, _) | @expr.Expr::Map(_, _, _) =>
      false
    @expr.Expr::Col(_)
    | @expr.Expr::Lit(_)
    | @expr.Expr::Binary(_, _, _)
    | @expr.Expr::Unary(_, _)
    | @expr.Expr::Alias(_, _)
    | @expr.Expr::Ternary(_, _, _) => {
      for child in expr.children() {
        if !row_stable(child) {
          return false
        }
      }
      true
    }
  }
}

///|
/// `row_stable` over a stage's whole expression list — one scope-bound or
/// value-raising expression fences the stage.
fn all_row_stable(exprs : Array[@expr.Expr]) -> Bool {
  for expr in exprs {
    if !row_stable(expr) {
      return false
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
/// `sum` / `count` always produce a value; `mean` / `min` / `max` go null
/// on an all-null group; a `cast`'s rejection is value-dependent, as is a
/// `map`'s opaque closure (null- or raise-valued on the cells it meets);
/// the null literal is a null cell by definition; a bare column is not
/// reduction-shaped at all (the executor raises structurally — fencing
/// keeps that error exactly where the as-built plan reports it). The
/// combinators preserve the property cell-wise: arithmetic, comparison,
/// and the Kleene connectives over non-null cells stay non-null, as do
/// the unary wrappers and a ternary over a non-null condition.
fn group_cell_stable(expr : @expr.Expr) -> Bool {
  match expr {
    @expr.Expr::Col(_) => false
    @expr.Expr::Lit(value) =>
      match value {
        @types.Scalar::Null => false
        @types.Scalar::Int(_)
        | @types.Scalar::Float(_)
        | @types.Scalar::Bool(_)
        | @types.Scalar::String(_) => true
      }
    @expr.Expr::Agg(op, _) =>
      match op {
        @expr.AggOp::Sum | @expr.AggOp::Count => true
        @expr.AggOp::Mean | @expr.AggOp::Min | @expr.AggOp::Max => false
      }
    @expr.Expr::Cast(_, _) | @expr.Expr::Map(_, _, _) => false
    @expr.Expr::Binary(_, _, _)
    | @expr.Expr::Unary(_, _)
    | @expr.Expr::Alias(_, _)
    | @expr.Expr::Ternary(_, _, _) => {
      for child in expr.children() {
        if !group_cell_stable(child) {
          return false
        }
      }
      true
    }
  }
}

///|
/// `group_cell_stable` over an aggregation's whole expression list — one
/// unstable cell fences the aggregation (an empty list is vacuously
/// stable: a keys-only aggregation has no stitched columns to flip).
fn all_group_cells_stable(exprs : Array[@expr.Expr]) -> Bool {
  for expr in exprs {
    if !group_cell_stable(expr) {
      return false
    }
  }
  true
}

///|
/// Whether every column the predicate reads appears in the selection as
/// a *bare* `col(name)` — the pass-through that guarantees the predicate
/// sees identical values below the stage, and that a column the
/// selection does not output stays missing for the predicate on both
/// sides of the swap. A computed or renamed occurrence does not count,
/// even under the same output name: its values are the stage's, not the
/// input's. Vacuously true for a column-less (all-literal) predicate.
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

///|
/// Whether the predicate reads *bare-column* group keys only — the
/// `Aggregate` crossing rule. A key written as a bare `col(name)` produces
/// an output column whose cells are its input column `name` verbatim, row
/// for row across each group, so a predicate over it sees identical values
/// below the stage. A *derived* key (any non-`Col` expression) outputs a
/// computed column whose name need not exist in the input at all, so a
/// predicate over it could not be evaluated below — it must stay above.
/// Aggregation outputs, and names that exist nowhere, likewise keep the
/// filter above. Reuses `has_bare_column`, the same bare-pass-through test
/// the `Select` crossing rule applies to its projection list.
fn reads_only_keys(predicate : @expr.Expr, keys : Array[@expr.Expr]) -> Bool {
  for name in predicate.referenced_columns() {
    if !has_bare_column(keys, name) {
      return false
    }
  }
  true
}

// ── The projection pass ─────────────────────────────────────────────────

///|
/// One recursion of the required-columns pass: rebuild `plan` with every
/// input pushed through `push_projection` under the requirement this node
/// induces, and narrow a `Scan` when the requirement proves some of its
/// columns dead. Total: every arm is plain data work.
fn push_projection(
  plan : LogicalPlan,
  required : @set.Set[String]?,
) -> LogicalPlan {
  match plan {
    // The narrowing point. Keep the scan's own column order (a filtered
    // projection, never a reorder) and only insert when the requirement
    // is a proper, non-empty subset: an empty intersection means the
    // consumers read no scan column at all (an all-literal selection —
    // nothing to gain), and a full one means every column is live. A
    // required name missing from the frame is simply not kept alive —
    // whichever expression references it raises the same
    // `ColumnNotFound` at collect time as in the unoptimized plan.
    Scan(df) =>
      match required {
        None => Scan(df)
        Some(needed) => {
          let cols = df.columns()
          let survivors = cols.filter(name => needed.contains(name))
          if survivors.length() > 0 && survivors.length() < cols.length() {
            Select(Scan(df), survivors.map(name => @expr.col(name)))
          } else {
            Scan(df)
          }
        }
      }
    // By-name originator: the output is exactly the expression list, so
    // whatever the parent required of *this* node is fully served, and
    // the input only ever needs the columns the expressions read. (The
    // expression list itself is never pruned — see the header.)
    Select(input, exprs) =>
      Select(push_projection(input, Some(columns_read(exprs))), exprs)
    // Layout-preserving pass-through, widened by the names the
    // expressions read; the names they *define* are served by this node
    // itself, so they are subtracted — they need not (and for a brand-new
    // derived column, do not) exist in the input.
    WithColumns(input, exprs) => {
      let downstream : @set.Set[String]? = match required {
        None => None
        Some(needed) => {
          let defined : @set.Set[String] = @set.Set([])
          for expr in exprs {
            defined.add(expr.output_name())
          }
          let pass : @set.Set[String] = @set.Set([])
          needed.each(name => if !defined.contains(name) { pass.add(name) })
          add_all(pass, columns_read(exprs))
          Some(pass)
        }
      }
      WithColumns(push_projection(input, downstream), exprs)
    }
    // Layout-preserving pass-throughs: the predicate / sort keys must
    // stay alive alongside whatever the parent needs.
    Filter(input, predicate) =>
      Filter(
        push_projection(
          input,
          widened(required, predicate.referenced_columns()),
        ),
        predicate,
      )
    Sort(input, by) => {
      let keys : @set.Set[String] = @set.Set([])
      for key in by {
        let (expr, _, _) = key
        add_all(keys, expr.referenced_columns())
      }
      Sort(push_projection(input, widened(required, keys)), by)
    }
    // Pure row windows read no columns: the requirement passes through
    // verbatim.
    Head(input, n) => Head(push_projection(input, required), n)
    Tail(input, n) => Tail(push_projection(input, required), n)
    Slice(input, start, end) =>
      Slice(push_projection(input, required), start, end)
    // Barrier (narrowing through a join is deferred column provenance):
    // both sides must keep their full output — join key resolution,
    // suffix renaming, and the left-then-right output layout all read the
    // whole frame — but each side restarts its own top-down pass.
    Join(left, right, options) =>
      Join(push_projection(left, None), push_projection(right, None), options)
    // By-name originator, like `Select`: the output is the key columns
    // (gathered in key-list order, not input order) plus the aggregated
    // expressions, so the input needs exactly the columns the keys and the
    // expressions read — a derived key keeps its source columns alive the
    // same way an aggregation does.
    Aggregate(input, keys, exprs) => {
      let needed = columns_read(exprs)
      add_all(needed, columns_read(keys))
      Aggregate(push_projection(input, Some(needed)), keys, exprs)
    }
  }
}

///|
/// Union of every column the expressions read, via
/// `Expr::referenced_columns` (which deliberately includes a ternary's
/// condition columns — pruning must keep them alive).
fn columns_read(exprs : Array[@expr.Expr]) -> @set.Set[String] {
  let acc : @set.Set[String] = @set.Set([])
  for expr in exprs {
    add_all(acc, expr.referenced_columns())
  }
  acc
}

///|
/// Fold one name set into an accumulator (core `Set` has no in-place
/// union).
fn add_all(acc : @set.Set[String], names : @set.Set[String]) -> Unit {
  names.each(name => acc.add(name))
}

///|
/// The pass-through rule for layout-preserving nodes that read columns of
/// their own: an unbounded requirement stays unbounded (the node's whole
/// output may be observed, and `extra` is necessarily part of "whole"),
/// and a bounded one is widened — into a fresh set, never mutating the
/// caller's — by the names this node reads.
fn widened(
  required : @set.Set[String]?,
  extra : @set.Set[String],
) -> @set.Set[String]? {
  match required {
    None => None
    Some(needed) => {
      let acc : @set.Set[String] = @set.Set([])
      add_all(acc, needed)
      add_all(acc, extra)
      Some(acc)
    }
  }
}
