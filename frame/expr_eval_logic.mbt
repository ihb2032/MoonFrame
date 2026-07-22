///|
/// The boolean-logic kernels: Kleene three-valued `&` / `|` (`eval_logic` over
/// the proof-carrying `@verified.kleene_and` / `@verified.kleene_or` cell tables) and
/// logical negation (`eval_not`). `Bool` operands only — any other dtype raises `TypeMismatch` —
/// and the output is nullable, on the `Builtin` backend.

///|
/// Kleene logic kernel over two equal-length `Bool` operands
/// (post-`broadcast_pair`); `&` and `|` differ only in the nullable cell
/// combiner (`@verified.kleene_and` / `@verified.kleene_or`) and the verb their `TypeMismatch`
/// message names. Non-`Bool` operands raise. The output is nullable by
/// nature and lands on the `Builtin` backend.
fn eval_logic(
  left : Series,
  right : Series,
  verb : String,
  combine : (Bool?, Bool?) -> Bool?,
) -> Series raise @types.DataError {
  let lv = validity_bools(left.storage())
  let rv = validity_bools(right.storage())
  match (left.storage().data(), right.storage().data()) {
    (@column.ColumnData::Bool(a), @column.ColumnData::Bool(b)) =>
      Series::from_bool_options(
        left.name(),
        Array::makei(a.length(), i => {
          combine(
            if lv[i] {
              Some(a[i])
            } else {
              None
            },
            if rv[i] {
              Some(b[i])
            } else {
              None
            },
          )
        }),
      )
    (
      @column.ColumnData::Int(_)
      | @column.ColumnData::Float(_)
      | @column.ColumnData::String(_),
      _,
    )
    | (
      _,
      @column.ColumnData::Int(_)
      | @column.ColumnData::Float(_)
      | @column.ColumnData::String(_),
    ) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "logical '\{verb}' requires Bool operands, got \{left.dtype()} and \{right.dtype()}",
        ),
      )
  }
}

///|
/// Kleene logical negation kernel: `not(true) = false`, `not(false) =
/// true`, `not(null) = null`. Non-`Bool` operands raise.
fn eval_not(operand : Series) -> Series raise @types.DataError {
  let valid = validity_bools(operand.storage())
  match operand.storage().data() {
    @column.ColumnData::Bool(a) =>
      Series::from_bool_options(
        operand.name(),
        map_present(a.length(), valid, i => !a[i]),
      )
    @column.ColumnData::Int(_)
    | @column.ColumnData::Float(_)
    | @column.ColumnData::String(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "logical 'not' requires a Bool operand, got \{operand.dtype()}",
        ),
      )
  }
}
