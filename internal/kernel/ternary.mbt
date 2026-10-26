///|
/// The conditional kernel (`when(cond).then(a).otherwise(b)`): align the three
/// operands, then build the output through `select_cells` — a null condition
/// cell nulls the output (Kleene), and the branches must share a dtype except
/// that `Int` meets `Float` by promotion. An all-valid numeric result converges
/// onto the `Numeric` backend.

///|
/// Build the cells of a conditional: where the condition is null the
/// output is null (Kleene: the branch is unknown), where it is `true` /
/// `false` the cell comes from the matching branch reader — which itself
/// yields `None` for a null branch cell.
fn[T] select_cells(
  cond : ArrayView[Bool],
  cond_valid : Array[Bool],
  get_then : (Int32) -> T?,
  get_else : (Int32) -> T?,
) -> Array[T?] {
  Array::makei(cond.length(), i => {
    if !cond_valid[i] {
      None
    } else if cond[i] {
      get_then(i)
    } else {
      get_else(i)
    }
  })
}

///|
/// `when(cond).then(a).otherwise(b)` kernel. The three operands evaluate
/// under one scope, so lengths are drawn from `{1, |scope|}`; two
/// `broadcast_pair` passes plus one stretch of the `then` branch align
/// them (the stretch only fires when the condition and `then` are both
/// length-1 literals against a column-length `otherwise`). The condition
/// must be `Bool`; a null condition cell nulls the output. The branches
/// must share a dtype, except that `Int` meets `Float` by promoting to
/// `Float` — the arithmetic promotion rule applied to selection. An
/// all-valid numeric result converges onto the `Numeric` backend.
pub fn eval_ternary(
  cond : Series,
  then_v : Series,
  else_v : Series,
) -> Series raise @types.DataError {
  let (c1, t1) = broadcast_pair(cond, then_v)
  let (c2, e2) = broadcast_pair(c1, else_v)
  let t2 = if t1.len() == c2.len() {
    t1
  } else {
    t1.gather_series(Array::make(c2.len(), 0))
  }
  let cond_cells = match c2.storage().data() {
    @column.ColumnData::Bool(a) => a
    @column.ColumnData::I64(_)
    | @column.ColumnData::F64(_)
    | @column.ColumnData::Utf8(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "when condition must be Bool, got \{c2.dtype()}",
        ),
      )
  }
  let cv = c2.validity_bools()
  let tv = t2.validity_bools()
  let ev = e2.validity_bools()
  let out = match (t2.storage().data(), e2.storage().data()) {
    (@column.ColumnData::I64(a), @column.ColumnData::I64(b)) if t2.dtype() ==
      e2.dtype() =>
      // Rebuilt through the dtype, not the variant: the branches may hold
      // the same dtype on an I64 rider other than Int (a Date), and an Int
      // rebuild would silently retype every selected cell.
      Series::from_i64_options(
        t2.name(),
        t2.dtype(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::I64(a), @column.ColumnData::F64(b)) if t2
      .dtype()
      .is_numeric() =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i].to_double()) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::F64(a), @column.ColumnData::I64(b)) if e2
      .dtype()
      .is_numeric() =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i].to_double()) } else { None },
        ),
      )
    (@column.ColumnData::F64(a), @column.ColumnData::F64(b)) =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      Series::from_bool_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Utf8(a), @column.ColumnData::Utf8(b)) => {
      // Decoded once per branch: selection copies materialised Strings.
      let sa = a.to_strings()
      let sb = b.to_strings()
      Series::from_string_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(sa[i]) } else { None },
          i => if ev[i] { Some(sb[i]) } else { None },
        ),
      )
    }
    (@column.ColumnData::I64(_), @column.ColumnData::I64(_))
    | (@column.ColumnData::I64(_), @column.ColumnData::F64(_))
    | (@column.ColumnData::F64(_), @column.ColumnData::I64(_))
    | (@column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_)) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "when/then/otherwise branches do not unify: \{t2.dtype()} and \{e2.dtype()}",
        ),
      )
  }
  out.try_column_to_numeric()
}

///|
/// Clamp each cell into `[lower?, upper?]` (Polars' `clip`): a null bound
/// cell means "no bound on that side" — the operand cell passes through
/// untouched, present or not (Polars' post-1.0 reading, where a null bound
/// stops propagating into the clipped value) — while a present operand cell
/// below `lower?` lifts to it and one above `upper?` presses down to it, a
/// null operand cell stays null, and a `NaN` stays put (no comparison holds
/// against it). Both bounds may be omitted (the identity) or given, in which
/// case the lower clamp runs first — a degenerate pair clamps every cell to
/// `upper?`. A bound is evaluated once, as a whole column or a length-1
/// literal, and the length contract is each composed kernel's own. Built by
/// composing the probe / compare / logic / selection kernels cell-for-cell:
/// `not_null(bound) & (x < bound)` selects the bound, and the Kleene reading
/// of that chain is the null rule above.
pub fn eval_clip(
  operand : Series,
  lower? : Series,
  upper? : Series,
) -> Series raise @types.DataError {
  fn bound_select(
    x : Series,
    bound : Series,
    crossed : @ir.BinOp,
  ) -> Series raise @types.DataError {
    // `false & null = false`: a null bound cell makes the whole condition
    // false (not null), so the selection keeps `x` — the null-bound rule.
    // Each step rides the dispatch entry (not the raw kernels) so a
    // length-1 literal bound broadcasts exactly as a hand-written
    // comparison tree's would.
    let present = eval_unary(@ir.UnOp::IsNotNull, bound)
    eval_ternary(
      eval_binary(@ir.BinOp::And, present, eval_binary(crossed, x, bound)),
      bound,
      x,
    )
  }
  let mut out = operand
  if lower is Some(lo) {
    out = bound_select(out, lo, @ir.BinOp::Lt)
  }
  if upper is Some(hi) {
    out = bound_select(out, hi, @ir.BinOp::Gt)
  }
  out
}
