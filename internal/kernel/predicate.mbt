///|
/// The membership / range predicate kernels behind `Expr::is_in` and
/// `Expr::is_between`. Both yield a nullable `Bool` column, and both reach
/// their semantics — exact `Int`/`Float` comparison, `String` / `Bool`
/// ordering, null propagation, and the `TypeMismatch` on an unorderable pair —
/// from the comparison (`eval_compare`) and Kleene (`eval_logic`) kernels, so
/// they cannot drift from `eq` / `ge` / `le` and the connectives. `is_in` has
/// one exception, `try_fast_is_in`: a hash-set pass for the dtypes where
/// membership is plain equality — `String`, `Bool`, `Int`, `Float`, and the
/// same-dtype I64 riders (`Date` / `Timestamp` / same-scale `Decimal`) whose
/// members share the column's dtype. On `Float` the set spells IEEE `==`
/// exactly (a NaN member matches nothing, a NaN cell answers false, the two
/// zeros fold), so nothing with a cross-type or cross-scale subtlety leaves
/// the shared path — the mixed `Int` vs `Float` exactness and the
/// `TypeMismatch` on an incomparable member stay on the general kernel.

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
/// A `String` / `Bool` / `Int` / `Float` column — or an I64-rider column
/// (`Date` / `Timestamp` / `Decimal`) whose members all carry the column's
/// own rider dtype and scale — takes the O(n + m) `try_fast_is_in` fast
/// path instead; a cross-type comparison (`Int` vs `Float` members) and any
/// cross-scale rider mismatch stay on the exact general path.
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
/// Fast `is_in` for the dtypes where membership is plain equality:
/// a `String`, `Bool`, `Int`, or `Float` column whose members are **all**
/// of that same dtype, or an I64-rider column whose members all carry its
/// rider dtype. Builds an exact membership structure over the (non-null)
/// members once, then tests every cell in a single pass — O(n + m) instead
/// of the general kernel's O(n·m) time and per-member column allocation.
/// `Some(result)` on that fast path; `None` — deferring to the exact
/// `eval_compare` kernel — for any member of a different dtype, so
/// cross-type numeric equality (`Int` vs `Float`, exact across 2^53) and
/// the `TypeMismatch` on an incomparable member stay on that one path. The
/// `Float` set hashes to IEEE `==` semantics: a NaN member is dropped
/// (it could equal nothing), a NaN cell answers false, and `-0.0` folds
/// onto `0.0` — each the same verdict the general path's `eq` gives. A
/// null cell yields null and a null member is skipped, matching the
/// general path.
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
    // A `Float` column with all-`Float` members: the same hash-set reading
    // under the exact kernel's IEEE semantics — `-0.0` folds into `+0.0`
    // (they compare equal; the folded key makes the set agree), a `NaN`
    // member is dropped (nothing equals a `NaN`), and a `NaN` cell answers
    // `false` outright rather than probing the set. A cross-type member
    // (an `Int`, exact across 2^53) abandons the fast path as everywhere
    // else.
    @column.ColumnData::F64(data) => {
      let set : @set.Set[Double] = @set.Set([])
      for m in members {
        match m {
          @types.Scalar::Float(v) =>
            if !v.is_nan() {
              set.add(if v == 0.0 { 0.0 } else { v })
            }
          @types.Scalar::Null => ()
          _ => return None
        }
      }
      Some(
        Series::from_bool_options(
          name,
          Array::makei(operand.len(), i => {
            if !valid[i] {
              None
            } else if data[i].is_nan() {
              Some(false)
            } else {
              Some(set.contains(if data[i] == 0.0 { 0.0 } else { data[i] }))
            }
          }),
        ),
      )
    }
    // A `Date` / `Timestamp` / `Decimal` column (the I64 riders): the cells
    // hash on their raw counts when every member carries the column's own
    // rider dtype — for `Decimal`, at the column's own scale, whose
    // cross-scale equality only the general path's exact rescaling arm
    // serves. A member of any other dtype (an `Int` against a `Date`
    // column, a cross-scale decimal) abandons the fast path, which keeps
    // the dtypes distinct exactly as the general path's Scalar comparison
    // does.
    @column.ColumnData::I64(data) => {
      let dtype = operand.dtype()
      hash_set_is_in(name, data, valid, members, m => {
        match (dtype, m) {
          (@types.DataType::Date, @types.Scalar::Date(v)) => Some(v)
          (@types.DataType::Timestamp, @types.Scalar::Timestamp(v)) => Some(v)
          (_, _) => None
        }
      })
    }
    // A Decimal column: the cells and the members both key on the
    // canonical cohort spelling (the `key_cells` fold's own rule), so
    // cohorts match (`1.0` against a set holding `1.00`), ±0 folds, and
    // a NaN member is dropped — nothing equals a NaN — while a NaN cell
    // answers false outright, the Float arm's stance.
    @column.ColumnData::Dec(data) => {
      let set : Map[String, Unit] = Map([])
      for m in members {
        match m {
          @types.Scalar::Decimal(v) =>
            if !v.is_nan() {
              set[v.canonical().to_string()] = ()
            }
          @types.Scalar::Null => ()
          _ => return None
        }
      }
      Some(
        Series::from_bool_options(
          name,
          Array::makei(operand.len(), i => {
            if !valid[i] {
              None
            } else if data[i].is_nan() {
              Some(false)
            } else {
              Some(set.contains(data[i].canonical().to_string()))
            }
          }),
        ),
      )
    }
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
