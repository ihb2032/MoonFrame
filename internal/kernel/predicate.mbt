///|
/// The membership / range predicate kernels behind `Expr::is_in` and
/// `Expr::is_between`. Both yield a nullable `Bool` column, and both reach
/// their semantics — exact `Int`/`Float` comparison, `String` / `Bool`
/// ordering, null propagation, and the `TypeMismatch` on an unorderable pair —
/// from the comparison (`eval_compare`) and Kleene (`eval_logic`) kernels, so
/// they cannot drift from `eq` / `ge` / `le` and the connectives. `is_in` has
/// one exception, `try_fast_is_in`: a hash-set pass for the dtypes where
/// membership is plain equality, kept deliberately narrow — only `String`,
/// `Bool`, and `Int` columns whose members share that dtype — so nothing with a
/// floating-point subtlety leaves the shared path.

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
pub fn eval_is_in(
  operand : Series,
  members : ArrayView[@types.Scalar],
) -> Series raise @types.DataError {
  match try_fast_is_in(operand, members) {
    Some(result) => return result
    None => ()
  }
  let mut acc = Series::from_bool_options(
    operand.name(),
    map_present(operand.len(), operand.validity_bools(), _ => false),
  )
  for m in members {
    if m.is_null() {
      continue
    }
    let (lhs, rhs) = broadcast_pair(operand, singleton_series(m))
    let mask = eval_compare(lhs, rhs, CmpVerb::Eq)
    // `acc` and `mask` are both `operand`-tall, so `eval_logic` (which assumes
    // equal-length operands) needs no further broadcast.
    acc = eval_logic(acc, mask, LogicOp::Or)
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
fn try_fast_is_in(
  operand : Series,
  members : ArrayView[@types.Scalar],
) -> Series? {
  let valid = operand.validity_bools()
  let name = operand.name()
  match operand.storage().data() {
    // Decoded once per side: cell membership reads materialised Strings.
    @column.ColumnData::Utf8(buf) =>
      hash_set_is_in(name, buf.to_strings(), valid, members, m => {
        if m is @types.Scalar::String(v) {
          Some(v)
        } else {
          None
        }
      })
    // Dtype-gated: a Date column is I64-typed, but its cells must not match
    // Int members through the fast path — the general path compares Scalars,
    // which keep the dtypes distinct.
    @column.ColumnData::I64(data) if operand.dtype() is @types.DataType::Int =>
      hash_set_is_in(name, data, valid, members, m => {
        if m is @types.Scalar::Int(v) {
          Some(v)
        } else {
          None
        }
      })
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
          Array::makei(operand.len(), i => {
            if valid[i] {
              Some(if data[i] { has_true } else { has_false })
            } else {
              None
            }
          }),
        ),
      )
    }
    @column.ColumnData::F64(_) | @column.ColumnData::I64(_) => None
  }
}

///|
/// The hash-set membership both dtype-keyed arms of `try_fast_is_in` run:
/// build the set over the members — a null member is skipped, a member whose
/// dtype is not the column's own abandons the fast path (`None`, deferring to
/// the exact kernel where cross-type semantics live) — then answer every
/// valid cell with one set lookup, a null cell with null.
fn[T : Eq + Hash] hash_set_is_in(
  name : String,
  data : ArrayView[T],
  valid : Array[Bool],
  members : ArrayView[@types.Scalar],
  key_of : (@types.Scalar) -> T?,
) -> Series? {
  let set : Map[T, Unit] = Map([])
  for m in members {
    match m {
      @types.Scalar::Null => ()
      _ =>
        match key_of(m) {
          Some(k) => set[k] = ()
          None => return None
        }
    }
  }
  Some(
    Series::from_bool_options(
      name,
      Array::makei(data.length(), i => {
        if valid[i] {
          Some(set.contains(data[i]))
        } else {
          None
        }
      }),
    ),
  )
}

///|
/// `is_between`: the range test `lo <= x <= hi`, with each endpoint included or
/// excluded per `closed` — `Both` evaluates as `x.ge(lo) & x.le(hi)`, and
/// `Left` / `Right` / `None` swap the corresponding side to a strict `gt` / `lt`
/// — through the shared comparison and Kleene-AND kernels.
/// `x` arrives already evaluated (once) and is shared by both comparisons — the
/// whole reason `IsBetween` is a dedicated node rather than a lowering that
/// would embed the operand's subtree twice.
pub fn eval_is_between(
  x : Series,
  lo : Series,
  hi : Series,
  closed : @types.ClosedInterval,
) -> Series raise @types.DataError {
  // Each end picks its verb from `closed`: an included endpoint compares with
  // `Ge` / `Le`, an excluded one with `Gt` / `Lt`. Both sides then join under
  // the same Kleene `and` the two-comparison lowering would have used.
  let (lower, upper) = match closed {
    @types.ClosedInterval::Both => (CmpVerb::Ge, CmpVerb::Le)
    @types.ClosedInterval::Left => (CmpVerb::Ge, CmpVerb::Lt)
    @types.ClosedInterval::Right => (CmpVerb::Gt, CmpVerb::Le)
    @types.ClosedInterval::None => (CmpVerb::Gt, CmpVerb::Lt)
  }
  let (xl, lol) = broadcast_pair(x, lo)
  let ge = eval_compare(xl, lol, lower)
  let (xh, hil) = broadcast_pair(x, hi)
  let le = eval_compare(xh, hil, upper)
  let (g, l) = broadcast_pair(ge, le)
  eval_logic(g, l, LogicOp::And)
}
