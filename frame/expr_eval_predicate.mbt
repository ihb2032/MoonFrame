///|
/// The membership / range predicate kernels behind `Expr::is_in` and
/// `Expr::is_between`. Both yield a nullable `Bool` column and are built
/// entirely from the comparison (`eval_compare`) and Kleene (`eval_logic`)
/// kernels, so their semantics — exact `Int`/`Float` comparison, `String` /
/// `Bool` ordering, null propagation, and the `TypeMismatch` on an unorderable
/// pair — can never drift from `eq` / `ge` / `le` and the connectives.

///|
/// `is_in`: `true` where the cell equals one of `members`, as an OR of `eq`.
/// The accumulator seeds to `false` where the cell is present and null where it
/// is null, so an empty set is "member of nothing" for a present cell and a
/// null cell propagates; each member's `eq` mask then ORs into it under the
/// Kleene table. A `Null` member has no value to equal (and no column form), so
/// it matches nothing and is skipped; a member whose dtype cannot compare with
/// the column raises `TypeMismatch` from `eval_compare`, exactly as
/// `col.eq(lit(member))` would.
fn eval_is_in(
  operand : Series,
  members : Array[@types.Scalar],
) -> Series raise @types.DataError {
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
/// `is_between`: the both-closed `lo <= x <= hi`, evaluated as
/// `x.ge(lo) & x.le(hi)` through the shared comparison and Kleene-AND kernels.
/// `x` arrives already evaluated (once) and is shared by both comparisons — the
/// whole reason `IsBetween` is a dedicated node rather than a lowering that
/// would embed the operand's subtree twice.
fn eval_is_between(
  x : Series,
  lo : Series,
  hi : Series,
) -> Series raise @types.DataError {
  let (xl, lol) = broadcast_pair(x, lo)
  let ge = eval_compare(xl, lol, CmpVerb::Ge)
  let (xh, hil) = broadcast_pair(x, hi)
  let le = eval_compare(xh, hil, CmpVerb::Le)
  let (g, l) = broadcast_pair(ge, le)
  eval_logic(g, l, "and", kleene_and)
}
