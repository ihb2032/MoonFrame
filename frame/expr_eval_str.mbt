///|
/// The string-namespace kernel: apply a `@expr.StrOp` to each cell of a String
/// operand — case, `strip_chars`, `len_chars`, the literal `contains` /
/// `starts_with` / `ends_with` predicates, and literal `replace` /
/// `replace_all`. A non-String operand raises `TypeMismatch`, null cells stay
/// null, and matching is always literal (no regex engine yet).

///|
/// Elementwise string-namespace kernel: apply `op` to each cell of a String
/// operand. The operand must be `String` — any other dtype is a
/// `TypeMismatch`, decided once for the whole column (scope-independent, so
/// the optimizer treats a `Str` node as row-stable). A null cell maps to a
/// null result; a present cell maps through the underlying total `String`
/// method, so no value can raise. `ToUppercase` / `ToLowercase` /
/// `StripChars` / `Replace` / `ReplaceAll` produce a String column,
/// `LenChars` an Int (the Unicode character count — an all-valid result
/// converges onto the `Numeric` fast path like every computed numeric), and
/// the `Contains` / `StartsWith` / `EndsWith` predicates a Bool. Matching is
/// always literal (no regex engine yet).
fn eval_str(
  op : @expr.StrOp,
  operand : Series,
) -> Series raise @types.DataError {
  let data = match operand.storage().data() {
    @column.ColumnData::String(a) => a
    @column.ColumnData::Int(_)
    | @column.ColumnData::Float(_)
    | @column.ColumnData::Bool(_) =>
      raise @types.DataError::TypeMismatch(
        "string operation requires a String operand, got \{operand.dtype()}",
      )
  }
  let valid = validity_bools(operand.storage())
  let name = operand.name()
  let n = data.length()
  let out = match op {
    @expr.StrOp::ToUppercase =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].to_upper()),
      )
    @expr.StrOp::ToLowercase =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].to_lower()),
      )
    @expr.StrOp::StripChars =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].trim().to_owned()),
      )
    @expr.StrOp::LenChars =>
      Series::from_int_options(
        name,
        map_present(n, valid, i => data[i].char_length().to_int64()),
      )
    @expr.StrOp::Contains(pattern) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].contains(pattern)),
      )
    @expr.StrOp::StartsWith(prefix) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].has_prefix(prefix)),
      )
    @expr.StrOp::EndsWith(suffix) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].has_suffix(suffix)),
      )
    @expr.StrOp::Replace(pattern, value) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].replace(old=pattern, new=value)),
      )
    @expr.StrOp::ReplaceAll(pattern, value) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].replace_all(old=pattern, new=value)),
      )
  }
  try_column_to_numeric(out)
}
