///|
/// The membership / range predicate kernels behind `Expr::is_in` and
/// `Expr::is_between`. Both yield a nullable `Bool` column and are built
/// entirely from the comparison (`eval_compare`) and Kleene (`eval_logic`)
/// kernels, so their semantics — exact `Int`/`Float` comparison, `String` /
/// `Bool` ordering, null propagation, and the `TypeMismatch` on an unorderable
/// pair — can never drift from `eq` / `ge` / `le` and the connectives.

///|
/// `is_in`: `true` where the cell equals one of `members`. The general path
/// (below) is an OR of `eq`, seeding the accumulator to `false` where the cell
/// is present and `null` where it is null — so an empty set is "member of
/// nothing" for a present cell and a null cell propagates — then ORing each
/// member's `eq` mask under the Kleene table. A `Null` member has no value to
/// equal (and no column form), so it matches nothing and is skipped; a member
/// whose dtype cannot compare with the column raises `TypeMismatch` from
/// `eval_compare`, exactly as `col.eq(lit(member))` would.
///
/// A `String` / `Bool` / `Int` column whose members are all of that same dtype
/// takes the O(n + m) `try_fast_is_in` fast path instead; everything with a
/// floating-point comparison subtlety stays on the exact general path.
fn eval_is_in(
  operand : Series,
  members : Array[@types.Scalar],
) -> Series raise @types.DataError {
  match try_fast_is_in(operand, members) {
    Some(result) => return result
    None => ()
  }
  let mut acc = Series::from_bool_options(
    operand.name(),
    map_present(operand.len(), validity_bools(operand.storage()), _ => false),
  )
  for m in members {
    if m.is_null() {
      continue
    }
    let (lhs, rhs) = broadcast_pair(operand, singleton_series(m))
    let mask = eval_compare(lhs, rhs, CmpVerb::Eq)
    // `acc` and `mask` are both `operand`-tall, so `eval_logic` (which assumes
    // equal-length operands) needs no further broadcast.
    acc = eval_logic(acc, mask, "or", kleene_or)
  }
  acc
}

///|
/// Fast `is_in` for the dtypes with no floating-point comparison subtleties: a
/// `String`, `Bool`, or `Int` column whose members are **all** of that same
/// dtype. Builds an exact membership structure over the (non-null) members once,
/// then tests every cell in a single pass — O(n + m) instead of the general
/// kernel's O(n·m) time and per-member column allocation. `Some(result)` on that
/// fast path; `None` — deferring to the exact `eval_compare` kernel — for a
/// `Float` column or any member of a different dtype, so cross-type numeric
/// equality (`Int` vs `Float`, exact across 2^53), signed-zero / NaN semantics,
/// and the `TypeMismatch` on an incomparable member all stay on that one path.
/// A null cell yields null and a null member is skipped, matching the general
/// path.
fn try_fast_is_in(operand : Series, members : Array[@types.Scalar]) -> Series? {
  let n = operand.len()
  let valid = validity_bools(operand.storage())
  let name = operand.name()
  match operand.storage().data() {
    @column.ColumnData::String(data) => {
      let set : Map[String, Unit] = Map([])
      for m in members {
        match m {
          @types.Scalar::String(s) => set[s] = ()
          @types.Scalar::Null => ()
          _ => return None
        }
      }
      Some(
        Series::from_bool_options(
          name,
          Array::makei(n, i => {
            if valid[i] {
              Some(set.contains(data[i]))
            } else {
              None
            }
          }),
        ),
      )
    }
    @column.ColumnData::Int(data) => {
      let set : Map[Int64, Unit] = Map([])
      for m in members {
        match m {
          @types.Scalar::Int(v) => set[v] = ()
          @types.Scalar::Null => ()
          _ => return None
        }
      }
      Some(
        Series::from_bool_options(
          name,
          Array::makei(n, i => {
            if valid[i] {
              Some(set.contains(data[i]))
            } else {
              None
            }
          }),
        ),
      )
    }
    @column.ColumnData::Bool(data) => {
      let mut has_true = false
      let mut has_false = false
      for m in members {
        match m {
          @types.Scalar::Bool(b) =>
            if b {
              has_true = true
            } else {
              has_false = true
            }
          @types.Scalar::Null => ()
          _ => return None
        }
      }
      Some(
        Series::from_bool_options(
          name,
          Array::makei(n, i => {
            if valid[i] {
              Some(if data[i] { has_true } else { has_false })
            } else {
              None
            }
          }),
        ),
      )
    }
    @column.ColumnData::Float(_) => None
  }
}

///|
/// `is_between`: the both-closed `lo <= x <= hi`, evaluated as
/// `x.ge(lo) & x.le(hi)` through the shared comparison and Kleene-AND kernels.
/// `x` arrives already evaluated (once) and is shared by both comparisons — the
/// whole reason `IsBetween` is a dedicated node rather than a lowering that
/// would embed the operand's subtree twice.
fn eval_is_between(
  x : Series,
  lo : Series,
  hi : Series,
  closed : @expr.ClosedInterval,
) -> Series raise @types.DataError {
  // Each end picks its verb from `closed`: an included endpoint compares with
  // `Ge` / `Le`, an excluded one with `Gt` / `Lt`. Both sides then join under
  // the same Kleene `and` the two-comparison lowering would have used.
  let (lower, upper) = match closed {
    @expr.ClosedInterval::Both => (CmpVerb::Ge, CmpVerb::Le)
    @expr.ClosedInterval::Left => (CmpVerb::Ge, CmpVerb::Lt)
    @expr.ClosedInterval::Right => (CmpVerb::Gt, CmpVerb::Le)
    @expr.ClosedInterval::None => (CmpVerb::Gt, CmpVerb::Lt)
  }
  let (xl, lol) = broadcast_pair(x, lo)
  let ge = eval_compare(xl, lol, lower)
  let (xh, hil) = broadcast_pair(x, hi)
  let le = eval_compare(xh, hil, upper)
  let (g, l) = broadcast_pair(ge, le)
  eval_logic(g, l, "and", kleene_and)
}
