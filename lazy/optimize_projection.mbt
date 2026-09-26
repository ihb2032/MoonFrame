///|
/// The projection pass's file map: `push_projection` is the iterative walk
/// over `ProjStep`, and the small requirement helpers (`columns_read`,
/// `widened`, `narrow_scan_source`, `add_all`) sit beside
/// it. The pass itself and its per-node requirement rules are documented on
/// `push_projection`.

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
/// scan source — the in-memory source (by inserting a `Select`) and the CSV /
/// NDJSON file sources (by writing their projection field) — to the columns its
/// consumers provably read. The per-node requirement rules are in
/// the file header; this walks them iteratively — `Visit` computes each child's
/// requirement and schedules its rebuild, the rebuild pops the rebuilt
/// child(ren) off an explicit value stack — so a deeply nested plan optimizes
/// without overflowing and aborting (total at any depth). Every narrowing
/// decision and requirement is bit-for-bit the recursion's.
///
/// # The requirement rules
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
/// Deliberately deferred: pruning dead expressions from `Select` /
/// `WithColumns` lists (changes which expressions evaluate, hence which
/// *errors* a failing plan reports), narrowing or predicate-splitting
/// through `Join`, sinking filters below `Sort`, and streaming a file source
/// (the reader still tokenises the whole file; push-down skips the *typed*
/// build of dropped rows, not the read).
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
          // Each scan source narrows its own way (`narrow_scan_source`): the
          // in-memory frame gets a `Select` inserted, a file source writes the
          // requirement into its projection field.
          Scan(source) => values.push(narrow_scan_source(node, source, req))
          // A bare-column `Select` sitting directly on an in-memory scan is
          // *already* the narrowing that `narrow_scan_source` would insert
          // below it, so letting the scan narrow too would stack a second,
          // identical projection — and re-optimizing would stack another every
          // pass. Keep this `Select` as the narrowing and hand the scan no
          // requirement, so the pass is idempotent and a bare projection over
          // an in-memory frame is never doubled. Only in-memory: a file
          // source narrows by writing its projection field (no inserted node),
          // which already recomputes to the same set.
          Unary(input, op) if already_narrows_inmemory(input, op) => {
            work.push(Rebuild1(c => Unary(c, op)))
            work.push(Visit(input, None))
          }
          // Every unary op rebuilds identically over its rewritten child; only
          // the requirement it hands its input differs (`frame_op_required`).
          Unary(input, op) => {
            work.push(Rebuild1(c => Unary(c, op)))
            work.push(Visit(input, frame_op_required(op, req)))
          }
          // Barrier: both sides keep their full output; each restarts its pass.
          Join(left, right, options) => {
            work.push(RebuildJoin(options))
            work.push(Visit(right, None))
            work.push(Visit(left, None))
          }
          // By-name originator, like a `Select`: keys + aggregated expressions.
          Aggregate(input, keys, exprs) => {
            let needed = columns_read(exprs)
            add_all(needed, columns_read(keys))
            work.push(Rebuild1(c => Aggregate(c, keys, exprs)))
            work.push(Visit(input, Some(needed)))
          }
        }
      Rebuild1(f) => values.push(f(pop_top(values)))
      RebuildJoin(options) => rejoin(values, options)
    }
  }
  pop_top(values)
}

///|
/// The column requirement a unary `FrameOp` hands its input — the `Unary`
/// node's half of `push_projection`, so a new unary verb declares its pruning
/// behaviour here alone. A by-name originator (`Select`) requires exactly what
/// it reads; the layout-preserving readers (`Filter` / `Sort`) widen the
/// parent's requirement by their own reads; `WithColumns` subtracts the names
/// it defines and adds the ones it reads; a pure row window (`Head` / `Tail` /
/// `Slice`) passes the requirement through unchanged; every other op is a
/// barrier whose input keeps its whole output (`None`).
fn frame_op_required(
  op : FrameOp,
  req : @set.Set[String]?,
) -> @set.Set[String]? {
  match op {
    Select(exprs) => Some(columns_read(exprs))
    WithColumns(exprs) =>
      match req {
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
    Filter(predicate) => widened(req, predicate.referenced_columns())
    Sort(by) => {
      let keys : @set.Set[String] = @set.Set([])
      for key in by {
        let (expr, _, _) = key
        add_all(keys, expr.referenced_columns())
      }
      widened(req, keys)
    }
    Head(_) | Tail(_) | Slice(_, _) => req
    Drop(_)
    | Rename(_)
    | RenameWith(_)
    | Reverse
    | WithRowIndex(_, _)
    | Unique(_, _)
    | DropNulls(_)
    | FillNull(_)
    | Reduce(_) => None
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
/// Whether a kept-column count means the in-memory scan actually narrows:
/// at least one column kept and at least one dropped. The single statement
/// of the in-memory narrowing condition — `narrow_scan_source` inserts its
/// `Select` under it, and `already_narrows_inmemory` recognises that
/// `Select` by it — so the guard and the narrowing it guards cannot drift
/// apart (a drift would stack a second `Select` on re-optimization).
fn inmemory_narrows_to(kept : Int, total : Int) -> Bool {
  kept > 0 && kept < total
}

///|
/// Whether `op` sitting on `input` is a bare-column `Select` that already
/// narrows an in-memory scan — the shape `narrow_scan_source` would otherwise
/// insert a duplicate of. True when `input` is `Scan(InMemory(df))` and `op` is
/// a `Select` whose entries are all bare `col(name)` naming a *proper, non-empty
/// subset* of `df`'s columns: exactly the requirement the scan would narrow to,
/// so the `Select` is that narrowing and no second one is needed. A `Select`
/// that reads every column (nothing to narrow) or computes (not a pure
/// projection) is not this shape and narrows — or not — through the normal path.
fn already_narrows_inmemory(input : LogicalPlan, op : FrameOp) -> Bool {
  guard input is Scan(InMemory(df)) && op is Select(exprs) else { return false }
  let cols = df.columns()
  // The scan's names as a membership set, built once. Scanning the name array
  // per expression instead would cost `O(exprs · columns)` on every `Select`
  // over an in-memory scan — which a wide frame pays in full, since a projection
  // that keeps most columns reaches the last expression before answering.
  let available : @set.Set[String] = @set.Set(cols)
  let read : @set.Set[String] = @set.Set([])
  for expr in exprs {
    // Any computed entry, or a name the scan lacks, means this is not a clean
    // projection onto the scan's columns: it either transforms or raises
    // `ColumnNotFound`, so it is not the narrowing the scan would insert. Let
    // the normal path narrow to whatever real columns it does read.
    guard expr.node() is @ir.ExprNode::Col(name) && available.contains(name) else {
      return false
    }
    read.add(name)
  }
  inmemory_narrows_to(read.length(), cols.length())
}

///|
/// Narrow one `Scan` source to the required columns — the `Scan` leaf's half of
/// the projection pass, so a new scannable format declares its narrowing here
/// alone. The in-memory source gets a bare-column `Select` inserted only when
/// the requirement is a proper, non-empty subset of its columns (it carries no
/// projection field); a file source writes the requirement into its own
/// projection (sorted, for a deterministic `explain` — the file's columns
/// aren't known until it is parsed, so there is nothing to intersect here, and
/// the reader filters the requirement against the real header at collect time,
/// keeping the file's own column order; the driver and any absorbed predicate
/// ride along verbatim). An unbounded requirement (`None`) or an empty one —
/// an all-literal consumer that reads no source column — leaves the scan whole
/// (mirroring the in-memory guard), so the read still yields its columns
/// and a row count rather than collapsing to nothing. A required name absent
/// from the file is simply never built; whichever expression references it
/// raises the same `ColumnNotFound` it would in the unoptimized plan.
fn narrow_scan_source(
  node : LogicalPlan,
  source : ScanSource,
  req : @set.Set[String]?,
) -> LogicalPlan {
  match source {
    InMemory(df) =>
      match req {
        None => node
        Some(needed) => {
          let cols = df.columns()
          let survivors = cols.filter(name => needed.contains(name))
          if inmemory_narrows_to(survivors.length(), cols.length()) {
            Unary(node, Select(survivors.map(name => @expr.col(name))))
          } else {
            node
          }
        }
      }
    File(fs) =>
      match req {
        None => node
        Some(needed) => {
          // The name set as a sorted array — the deterministic column list
          // written into the file source's projection. Core `Set` iteration
          // is unordered, so without the sort `explain(optimized=true)`
          // would vary run to run; ordering is dictionary order, like every
          // other user-facing ordering in MoonFrame. It is presentation
          // only — the reader re-derives the read order from the file's own
          // header.
          let columns : Array[String] = []
          needed.each(name => columns.push(name))
          columns.sort_by((a, b) => @text.compare_string_lex(a, b))
          if columns.is_empty() {
            node
          } else {
            Scan(File({ ..fs, projection: Some(columns), }))
          }
        }
      }
  }
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
