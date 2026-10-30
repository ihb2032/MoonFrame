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
///
/// The selection half of the three dtype-pair gates — see
/// `DataType::comparable_with` for the comparison gate and the review rule
/// that ties the three together.
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
/// Clamp each cell into `[lower?, upper?]`: a null bound cell means "no
/// bound on that side" — the operand cell passes through untouched, present
/// or not, the bound's null never propagating into the clipped value —
/// while a present operand cell
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
  // The same-dtype numeric shapes take one pass over the buffers — no
  // per-bound chain of probe / compare / logic / selection columns, each
  // of which allocates a full intermediate. Every other shape (an `Int`
  // column against a `Float` bound, a rider, a string, a length that is
  // neither the operand's own nor 1) falls through to the composed
  // kernels below, where the general comparison semantics live.
  match try_clip_buffers(operand, lower, upper) {
    Some(out) => return out
    None => ()
  }
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

///|
/// One clip bound's extracted reading: the typed buffer, the validity the
/// null-bound rule reads, and whether the bound is a length-1 literal
/// (every row reads cell 0) or a column of the operand's own height.
priv struct ClipBound[T] {
  buf : ArrayView[T]
  valid : Array[Bool]
  literal : Bool
}

///|
/// The single-pass clip over same-dtype numeric buffers, `None` for every
/// shape it does not own. One cell decision per row: a null operand stays
/// null, a null bound cell means no bound on that side (the operand passes
/// through), a `NaN` operand fails both comparisons and keeps its cell,
/// and a bound that holds lifts / presses the cell to it — the same
/// cell-for-cell semantics the composed kernels spell, one buffer read
/// instead of eight intermediate columns.
fn try_clip_buffers(
  operand : Series,
  lower : Series?,
  upper : Series?,
) -> Series? {
  let n = operand.len()
  let op_valid = operand.validity_bools()
  // Guard-arm style, like `try_fast_is_in`: the dtype the buffer must
  // carry rides the arm guard, and every other shape — a rider on the I64
  // buffer, a mixed pair, a non-numeric bound — falls to an explicit
  // `None` arm the composed kernels then serve, so no reachable shape is
  // silently clamped on raw day-counts or magnitudes.
  fn i64_bound(b : Series) -> ClipBound[Int64]? {
    match b.storage().data() {
      @column.ColumnData::I64(buf) if b.dtype() == @types.DataType::Int &&
        (b.len() == n || b.len() == 1) =>
        Some({ buf, valid: b.validity_bools(), literal: b.len() == 1, })
      @column.ColumnData::I64(_)
      | @column.ColumnData::F64(_)
      | @column.ColumnData::Bool(_)
      | @column.ColumnData::Utf8(_) => None
    }
  }
  fn f64_bound(b : Series) -> ClipBound[Double]? {
    match b.storage().data() {
      @column.ColumnData::F64(buf) if b.dtype() == @types.DataType::Float &&
        (b.len() == n || b.len() == 1) =>
        Some({ buf, valid: b.validity_bools(), literal: b.len() == 1, })
      @column.ColumnData::I64(_)
      | @column.ColumnData::F64(_)
      | @column.ColumnData::Bool(_)
      | @column.ColumnData::Utf8(_) => None
    }
  }
  match operand.storage().data() {
    @column.ColumnData::I64(a) if operand.dtype() == @types.DataType::Int => {
      let lo : ClipBound[Int64]? = match lower.map(b => i64_bound(b)) {
        Some(Some(b)) => Some(b)
        Some(None) => return None
        None => None
      }
      let hi : ClipBound[Int64]? = match upper.map(b => i64_bound(b)) {
        Some(Some(b)) => Some(b)
        Some(None) => return None
        None => None
      }
      fn at(bound : ClipBound[Int64]?, i : Int32) -> Int64? {
        match bound {
          None => None
          Some(b) => {
            let idx = if b.literal { 0 } else { i }
            if b.valid[idx] {
              Some(b.buf[idx])
            } else {
              None
            }
          }
        }
      }
      let out : Array[Int64?] = Array::makei(n, i => {
        if !op_valid[i] {
          None
        } else {
          let mut v = a[i]
          match at(lo, i) {
            Some(lo_v) => if v < lo_v { v = lo_v }
            None => ()
          }
          match at(hi, i) {
            Some(hi_v) => if v > hi_v { v = hi_v }
            None => ()
          }
          Some(v)
        }
      })
      Some(
        Series::from_int_options(operand.name(), out).try_column_to_numeric(),
      )
    }
    @column.ColumnData::F64(a) => {
      let lo : ClipBound[Double]? = match lower.map(b => f64_bound(b)) {
        Some(Some(b)) => Some(b)
        Some(None) => return None
        None => None
      }
      let hi : ClipBound[Double]? = match upper.map(b => f64_bound(b)) {
        Some(Some(b)) => Some(b)
        Some(None) => return None
        None => None
      }
      fn at(bound : ClipBound[Double]?, i : Int32) -> Double? {
        match bound {
          None => None
          Some(b) => {
            let idx = if b.literal { 0 } else { i }
            if b.valid[idx] {
              Some(b.buf[idx])
            } else {
              None
            }
          }
        }
      }
      let out : Array[Double?] = Array::makei(n, i => {
        if !op_valid[i] {
          None
        } else {
          let mut v = a[i]
          match at(lo, i) {
            Some(lo_v) => if v < lo_v { v = lo_v }
            None => ()
          }
          match at(hi, i) {
            Some(hi_v) => if v > hi_v { v = hi_v }
            None => ()
          }
          Some(v)
        }
      })
      Some(
        Series::from_float_options(operand.name(), out).try_column_to_numeric(),
      )
    }
    // A rider on the I64 buffer (a `Date` clipping against an `Int` bound
    // would clamp raw day-counts) and every non-numeric operand decline
    // the fast pass; the composed kernels raise on those pairs exactly as
    // they did before this pass existed.
    @column.ColumnData::I64(_)
    | @column.ColumnData::Bool(_)
    | @column.ColumnData::Utf8(_) => None
  }
}
