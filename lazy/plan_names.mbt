// The output-column-name walk: which column names a plan stage provably
// outputs, for the joins' push-down decisions — splitting a requirement
// across a `Join`'s sides and attributing a predicate's columns to one side
// both ask "which names does this subtree output", and the answer must be
// *exact*: over-approximating would attribute a right-only name to the left
// and sink a predicate into a side that lacks its column, so every arm
// either computes the precise set or gives up (`None`), and `None`
// propagates — a side whose names are unknown is a side nothing splits
// into. This is the name-set counterpart of the decimal value-fence's
// risk walk (`decimal_names_in_plan`): that one propagates a *risk*
// over-approximation (a file source reads as no decimal columns), while
// this one computes
// names exactly (a file source's header is known only at collect, so its
// set is `None`); the two share the rename / suffix shapes they spell but
// answer different questions at different precisions, and neither could
// serve the other's callers.
//
// The `Join` arm is the *exact* union — left names, a clash-free right
// name under its own name, a clashing one under `name + suffix` only. The
// split's attribution and the requirement split both make *positive*
// claims from this set ("this name is a left/right output column"), so an
// over-offered name — a suffix spelling no clash actually produced — would
// attribute a predicate to a side that lacks its column, and a good plan
// would break (the suffixed spelling may be perfectly live one join up,
// reading a genuinely clashing column of *that* join). Key coalescing is
// deliberately *not* resolved here: a coalesced key keeps the left
// spelling (already in the left set), and the suffixed right spelling of a
// clashing key is then genuinely absent — exactly what this set says —
// while resolving it would duplicate frame's `coalesce_key_names` rule on
// this side of the package boundary.

///|
/// The column names a plan stage outputs, or `None` when they are not
/// statically knowable — a file source (its header exists only at collect),
/// a pivot or unpivot (column selection or names come from data), a
/// whole-frame reduction (its one output column is the eager verb's to
/// name), a whole-scope aggregation (its non-key column list exists only on
/// the collected frame), or anything built above one of those. Total, like
/// every plan walk: plain data work in every arm.
fn LogicalPlan::output_names(self : LogicalPlan) -> @set.Set[String]? {
  match self {
    Scan(InMemory(df)) => {
      let names = @set.Set([])
      for name in df.columns() {
        names.add(name)
      }
      Some(names)
    }
    Scan(File(_)) => None
    Unary(input, op) => frame_op_names(op, input.output_names())
    Join(left, right, options) =>
      match options.how {
        // The existence filters keep the left schema alone; the right side
        // is read for its keys only, and no right name survives to an
        // output column.
        Semi | Anti => left.output_names()
        Inner | Left | Right | Outer | Cross => {
          let left_names = left.output_names()
          let right_names = right.output_names()
          match (left_names, right_names) {
            (Some(l), Some(r)) => {
              // The bare `on` keys: a clashing one is exactly the column
              // key coalescing may drop from the right (frame's rule,
              // resolved at collect), so neither spelling is offered for
              // it — the left spelling is already in the set, and offering
              // the suffixed one could attribute a predicate to a name the
              // join never outputs. Under-offering is the safe direction:
              // it only declines a sink.
              let on_keys = bare_on_key_names(options)
              let merged = @set.Set([])
              l.each(name => merged.add(name))
              // A clash-free right column keeps its name; a clashing one is
              // output under the suffixed spelling only — the exact output
              // vocabulary, since the joins read this set for positive
              // attribution.
              r.each(name => {
                if l.contains(name) {
                  if !on_keys.contains(name) {
                    merged.add(name + options.suffix)
                  }
                } else {
                  merged.add(name)
                }
              })
              Some(merged)
            }
            _ => None
          }
        }
      }
    Aggregate(_, keys, exprs) => {
      let names = @set.Set([])
      for expr in keys {
        names.add(expr.output_name())
      }
      for expr in exprs {
        names.add(expr.output_name())
      }
      Some(names)
    }
    // The aggregated column list exists only on the collected input frame
    // (every non-key column, whichever those are), so nothing above this
    // node can attribute a name to a side of it.
    AggregateAll(_, _, _) => None
  }
}

///|
/// The `Unary` node's half of the name walk — how one `FrameOp` reshapes
/// its input's name set, so a new verb declares its naming here alone.
/// `below` is the input's set, already computed; a verb that cannot name
/// its output statically (or sits over an input that cannot) yields `None`.
/// The row verbs (filter / sort / windows / unique / fills) rename nothing;
/// the reshapers are spelled per verb below.
fn frame_op_names(op : FrameOp, below : @set.Set[String]?) -> @set.Set[String]? {
  match op {
    Select(exprs) => {
      let names = @set.Set([])
      for expr in exprs {
        names.add(expr.output_name())
      }
      Some(names)
    }
    WithColumns(exprs) =>
      match below {
        None => None
        Some(names) => {
          for expr in exprs {
            names.add(expr.output_name())
          }
          Some(names)
        }
      }
    Filter(_)
    | Sort(_)
    | Head(_)
    | Tail(_)
    | Slice(_, _)
    | GatherEvery(_, _)
    | TopK(_, _, _)
    | BottomK(_, _, _)
    | Unique(_, _)
    | Reverse
    | DropNulls(_)
    | FillNull(_)
    | FillNullDir(_, _)
    | FillNan(_) => below
    Drop(exprs) =>
      match below {
        None => None
        Some(names) => {
          let dropped = @set.Set([])
          for expr in exprs {
            dropped.add(expr.output_name())
          }
          let kept = @set.Set([])
          names.each(name => if !dropped.contains(name) { kept.add(name) })
          Some(kept)
        }
      }
    Rename(pairs) =>
      match below {
        None => None
        Some(names) => {
          let renamed = @set.Set([])
          // Indexed access rather than a tuple pattern: the coverage
          // reporter's parser cannot parse a tuple pattern in a `for`
          // header, and a source it cannot parse fails the coverage gate.
          names.each(name => {
            let mut target = name
            for pair in pairs {
              if pair.0 == name {
                target = pair.1
                break
              }
            }
            renamed.add(target)
          })
          Some(renamed)
        }
      }
    // The closure is total and collect runs it on exactly these column
    // names, so running it here reads the mapping rather than guessing it
    // — the same precedent as the decimal walk.
    RenameWith(f) =>
      match below {
        None => None
        Some(names) => {
          let renamed = @set.Set([])
          names.each(name => renamed.add(f(name)))
          Some(renamed)
        }
      }
    WithRowIndex(name, _) =>
      match below {
        None => None
        Some(names) => {
          names.add(name)
          Some(names)
        }
      }
    // The reshapers whose output names are data- or collect-shaped: a
    // pivot's column names come from the values it pivots on, an unpivot's
    // index / value split exists only against the collected frame's real
    // columns, and a whole-frame reduction names its single column at the
    // eager verb. Each is a `None` the joins read as "this side's names are
    // unknown — do not split into it".
    Pivot(_, _, _, _) | Unpivot(_, _, _, _) | Reduce(_) => None
  }
}

///|
/// The names of an `on` join's bare `col(name)` keys — the columns that key
/// coalescing may drop from the right side at collect. Empty for a sided or
/// cross join (those never coalesce) and for derived `on` keys (a computed
/// key outputs no column of its own).
fn bare_on_key_names(options : @frame.JoinOptions) -> @set.Set[String] {
  let names = @set.Set([])
  for key in options.on_keys() {
    match key.node() {
      @ir.ExprNode::Col(name) => names.add(name)
      _ => ()
    }
  }
  names
}
