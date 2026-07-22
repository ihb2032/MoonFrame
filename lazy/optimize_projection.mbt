///|
/// The projection pass: a top-down required-columns analysis that narrows each
/// scan — the in-memory `Scan` (by inserting a bare-column `Select`) and the
/// `ScanCsv` / `ScanNdjson` file sources (by writing their projection field) —
/// to the columns its consumers provably read. `push_projection` walks the plan
/// iteratively over `ProjStep`; the small requirement helpers (`columns_read`,
/// `widened`, `narrow_scan`, `sorted_names`, `add_all`) sit beside it. The
/// per-node requirement rules and the pass ordering rationale are on `optimize`
/// in `optimize.mbt`.

///|
/// One step of the iterative projection pass: `Visit` descends into a node
/// under the requirement it inherits; `Rebuild1` / `RebuildJoin` reassemble a
/// node from its rebuilt child(ren) once they sit on the value stack. Lifting
/// the pass off the call stack (the `LogicalPlan` analogue of `eval_expr`'s
/// `EvalStep`) lets an arbitrarily deep plan optimize without overflowing.
priv enum ProjStep {
  Visit(LogicalPlan, @set.Set[String]?)
  Rebuild1((LogicalPlan) -> LogicalPlan)
  RebuildJoin(@frame.JoinOptions)
}

///|
/// The projection pass: a top-down required-columns analysis that narrows each
/// scan — the in-memory `Scan` (by inserting a `Select`) and the `ScanCsv` /
/// `ScanNdjson` file sources (by writing their projection field) — to the
/// columns its consumers provably read. The per-node requirement rules are in
/// the file header; this walks them iteratively — `Visit` computes each child's
/// requirement and schedules its rebuild, the rebuild pops the rebuilt
/// child(ren) off an explicit value stack — so a deeply nested plan optimizes
/// without overflowing and aborting (total at any depth). Every narrowing
/// decision and requirement is bit-for-bit the recursion's.
fn push_projection(
  plan : LogicalPlan,
  required : @set.Set[String]?,
) -> LogicalPlan {
  let work : Array[ProjStep] = [Visit(plan, required)]
  let values : Array[LogicalPlan] = []
  while work.length() > 0 {
    match pop_top(work) {
      Visit(node, req) =>
        match node {
          // Narrowing point: insert a `Select` only when the requirement is a
          // proper, non-empty subset of the scan's columns (header rationale).
          Scan(df) =>
            values.push(
              match req {
                None => Scan(df)
                Some(needed) => {
                  let cols = df.columns()
                  let survivors = cols.filter(name => needed.contains(name))
                  if survivors.length() > 0 &&
                    survivors.length() < cols.length() {
                    Select(Scan(df), survivors.map(name => @expr.col(name)))
                  } else {
                    Scan(df)
                  }
                }
              },
            )
          // File sources' narrowing point: write the requirement into the
          // node's own projection field (`narrow_scan`).
          ScanCsv(path, options, _, predicate) =>
            values.push(
              narrow_scan(node, req, columns => {
                ScanCsv(path, options, Some(columns), predicate)
              }),
            )
          ScanNdjson(path, options, _, predicate) =>
            values.push(
              narrow_scan(node, req, columns => {
                ScanNdjson(path, options, Some(columns), predicate)
              }),
            )
          // By-name originator: the input needs exactly the columns the
          // expressions read.
          Select(input, exprs) => {
            work.push(Rebuild1(c => Select(c, exprs)))
            work.push(Visit(input, Some(columns_read(exprs))))
          }
          // Layout-preserving: subtract the names this stage defines, add the
          // names it reads.
          WithColumns(input, exprs) => {
            let downstream : @set.Set[String]? = match req {
              None => None
              Some(needed) => {
                let defined : @set.Set[String] = @set.Set([])
                for expr in exprs {
                  defined.add(expr.output_name())
                }
                let pass : @set.Set[String] = @set.Set([])
                needed.each(name => {
                  if !defined.contains(name) {
                    pass.add(name)
                  }
                })
                add_all(pass, columns_read(exprs))
                Some(pass)
              }
            }
            work.push(Rebuild1(c => WithColumns(c, exprs)))
            work.push(Visit(input, downstream))
          }
          // Layout-preserving pass-throughs: the predicate / sort keys stay
          // alive alongside whatever the parent needs.
          Filter(input, predicate) => {
            work.push(Rebuild1(c => Filter(c, predicate)))
            work.push(
              Visit(input, widened(req, predicate.referenced_columns())),
            )
          }
          Sort(input, by) => {
            let keys : @set.Set[String] = @set.Set([])
            for key in by {
              let (expr, _, _) = key
              add_all(keys, expr.referenced_columns())
            }
            work.push(Rebuild1(c => Sort(c, by)))
            work.push(Visit(input, widened(req, keys)))
          }
          // Pure row windows read no columns: the requirement passes through.
          Head(input, n) => {
            work.push(Rebuild1(c => Head(c, n)))
            work.push(Visit(input, req))
          }
          Tail(input, n) => {
            work.push(Rebuild1(c => Tail(c, n)))
            work.push(Visit(input, req))
          }
          Slice(input, start, end) => {
            work.push(Rebuild1(c => Slice(c, start, end)))
            work.push(Visit(input, req))
          }
          // Barrier: both sides keep their full output; each restarts its pass.
          Join(left, right, options) => {
            work.push(RebuildJoin(options))
            work.push(Visit(right, None))
            work.push(Visit(left, None))
          }
          // By-name originator, like `Select`: keys + aggregated expressions.
          Aggregate(input, keys, exprs) => {
            let needed = columns_read(exprs)
            add_all(needed, columns_read(keys))
            work.push(Rebuild1(c => Aggregate(c, keys, exprs)))
            work.push(Visit(input, Some(needed)))
          }
          // Barriers (like `Join`): the input keeps its whole output (`None`).
          Drop(input, exprs) => {
            work.push(Rebuild1(c => Drop(c, exprs)))
            work.push(Visit(input, None))
          }
          Rename(input, pairs) => {
            work.push(Rebuild1(c => Rename(c, pairs)))
            work.push(Visit(input, None))
          }
          RenameWith(input, f) => {
            work.push(Rebuild1(c => RenameWith(c, f)))
            work.push(Visit(input, None))
          }
          Unique(input, keep, subset) => {
            work.push(Rebuild1(c => Unique(c, keep, subset)))
            work.push(Visit(input, None))
          }
          DropNulls(input, subset) => {
            work.push(Rebuild1(c => DropNulls(c, subset)))
            work.push(Visit(input, None))
          }
          FillNull(input, value) => {
            work.push(Rebuild1(c => FillNull(c, value)))
            work.push(Visit(input, None))
          }
          // Barrier: a whole-frame reduction reads every column, so the input
          // keeps its full output (`None`).
          Reduce(input, op) => {
            work.push(Rebuild1(c => Reduce(c, op)))
            work.push(Visit(input, None))
          }
        }
      Rebuild1(f) => values.push(f(pop_top(values)))
      RebuildJoin(options) => {
        // Right is on top (pushed last), left just below.
        let right = pop_top(values)
        let left = pop_top(values)
        values.push(Join(left, right, options))
      }
    }
  }
  pop_top(values)
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
/// Narrow a file source (`ScanCsv` / `ScanNdjson`) to the required columns,
/// shared by both because they differ only in the node constructor `rebuild`
/// wraps. The file's columns aren't known until it is parsed, so there is
/// nothing to intersect here: the requirement is written verbatim into the
/// node's projection (sorted, for a deterministic `explain`), and the reader
/// filters it against the real header at collect time, keeping the file's own
/// column order. An unbounded requirement (`None`) or an empty one — an
/// all-literal consumer that reads no source column — leaves the scan whole
/// (mirroring the in-memory `Scan` guard), so the read still yields its columns
/// and a row count rather than collapsing to nothing. A required name absent
/// from the file is simply never built; whichever expression references it
/// raises the same `ColumnNotFound` it would in the unoptimized plan.
fn narrow_scan(
  plan : LogicalPlan,
  required : @set.Set[String]?,
  rebuild : (Array[String]) -> LogicalPlan,
) -> LogicalPlan {
  match required {
    None => plan
    Some(needed) => {
      let columns = sorted_names(needed)
      if columns.is_empty() {
        plan
      } else {
        rebuild(columns)
      }
    }
  }
}

///|
/// A name set as a sorted array — the deterministic column list the
/// projection pass writes into a file source's projection. Core `Set`
/// iteration is
/// unordered, so without this `explain(optimized=true)` would vary run to
/// run. Ordering routes through `@types.compare_string_lex` (dictionary
/// order), like every other user-facing ordering in MoonFrame, rather than
/// the built-in shortlex `Compare` on `String`; it is presentation only,
/// since the reader re-derives the read order from the file's own header.
fn sorted_names(names : @set.Set[String]) -> Array[String] {
  let arr : Array[String] = []
  names.each(name => arr.push(name))
  arr.sort_by((a, b) => @text.compare_string_lex(a, b))
  arr
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
