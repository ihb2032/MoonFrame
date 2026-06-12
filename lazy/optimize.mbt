///|
/// The query optimizer (S-opt spike: projection pushdown). A **total**
/// plan→plan rewrite — pure tree walking, no raise, no abort — that
/// `collect` runs in front of the executor. Its one inviolable contract
/// is the executor's own: `execute(optimize(p))` is bitwise-equal to
/// `execute(p)` for every plan that collects, and a failing plan still
/// fails with the same eager operator error. The rewrite never touches a
/// user-written node — it only *inserts* a narrowing `Select` of bare
/// column references directly over a `Scan` whose consumers provably read
/// a proper subset of its columns, so unused columns are dropped before
/// any row-level work instead of riding through every stage.
///
/// The analysis runs top-down as a "required columns" pass:
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
///   adds the names they *read*. `Join` stays a barrier in the spike —
///   splitting a requirement across two sides whose outputs interleave
///   under suffix renaming is O2-grade column provenance — but both
///   sides restart their own pass, so a `Select` deep under a join still
///   narrows its own scan.
///
/// Why the order insensitivity matters: narrowing a `with_columns` input
/// can turn an in-place column *replacement* into an *append* (the
/// replaced name no longer exists in the narrowed input), perturbing the
/// intermediate column order. That perturbation is only ever visible to
/// the requirement's originator — a by-name reader — never to the plan
/// root, which always starts at `None`. The `Aggregate` executor reads
/// its keys in key-list order, not input order, so it qualifies too.
///
/// Deliberately out of spike scope (O1/O2 follow-ups): pruning dead
/// expressions from `Select` / `WithColumns` lists (changes which
/// expressions evaluate, hence which *errors* a failing plan reports),
/// narrowing through `Join`, predicate pushdown, and an `explain`
/// before/after view. `optimize` is also not idempotent — re-optimizing
/// an already-rewritten plan would stack another (harmless) narrowing
/// select — which is moot in practice: plans are immutable and `collect`
/// optimizes the as-built plan exactly once per call.
fn optimize(plan : LogicalPlan) -> LogicalPlan {
  push_projection(plan, None)
}

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
        let (name, _, _) = key
        keys.add(name)
      }
      Sort(push_projection(input, widened(required, keys)), by)
    }
    // Pure row windows read no columns: the requirement passes through
    // verbatim.
    Head(input, n) => Head(push_projection(input, required), n)
    Tail(input, n) => Tail(push_projection(input, required), n)
    Slice(input, start, end) =>
      Slice(push_projection(input, required), start, end)
    // Barrier (spike scope): both sides must keep their full output —
    // join key resolution, suffix renaming, and the left-then-right
    // output layout all read the whole frame — but each side restarts
    // its own top-down pass.
    Join(left, right, options) =>
      Join(push_projection(left, None), push_projection(right, None), options)
    // By-name originator, like `Select`: the output is the key columns
    // (gathered in key-list order, not input order) plus the aggregated
    // expressions, so the input needs exactly the keys and the columns
    // the expressions read.
    Aggregate(input, keys, exprs) => {
      let needed = columns_read(exprs)
      for key in keys {
        needed.add(key)
      }
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
