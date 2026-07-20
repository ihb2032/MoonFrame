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
  cond : Array[Bool],
  cond_valid : Array[Bool],
  get_then : (Int) -> T?,
  get_else : (Int) -> T?,
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
fn eval_ternary(
  cond : Series,
  then_v : Series,
  else_v : Series,
) -> Series raise @types.DataError {
  let (c1, t1) = broadcast_pair(cond, then_v)
  let (c2, e2) = broadcast_pair(c1, else_v)
  let t2 = if t1.len() == c2.len() {
    t1
  } else {
    gather_series(t1, Array::make(c2.len(), 0))
  }
  let cond_cells = match c2.storage().data() {
    @column.ColumnData::Bool(a) => a
    @column.ColumnData::Int(_)
    | @column.ColumnData::Float(_)
    | @column.ColumnData::String(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "when condition must be Bool, got \{c2.dtype()}",
        ),
      )
  }
  let cv = validity_bools(c2.storage())
  let tv = validity_bools(t2.storage())
  let ev = validity_bools(e2.storage())
  let out = match (t2.storage().data(), e2.storage().data()) {
    (@column.ColumnData::Int(a), @column.ColumnData::Int(b)) =>
      Series::from_int_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Int(a), @column.ColumnData::Float(b)) =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i].to_double()) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Int(b)) =>
      Series::from_float_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i].to_double()) } else { None },
        ),
      )
    (@column.ColumnData::Float(a), @column.ColumnData::Float(b)) =>
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
    (@column.ColumnData::String(a), @column.ColumnData::String(b)) =>
      Series::from_string_options(
        t2.name(),
        select_cells(
          cond_cells,
          cv,
          i => if tv[i] { Some(a[i]) } else { None },
          i => if ev[i] { Some(b[i]) } else { None },
        ),
      )
    (@column.ColumnData::Bool(_) | @column.ColumnData::String(_), _)
    | (_, @column.ColumnData::Bool(_) | @column.ColumnData::String(_)) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "when/then/otherwise branches do not unify: \{t2.dtype()} and \{e2.dtype()}",
        ),
      )
  }
  try_column_to_numeric(out)
}
