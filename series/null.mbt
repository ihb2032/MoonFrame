// The null-handling verbs, the two ways to deal with a missing cell:
// `fill_null` replaces every null slot with a same-dtype scalar, keeping
// the source storage backend (`preserve_backend` — a no-op fill on an
// all-valid `Numeric` column stays `Numeric`); `drop_nulls` gathers the
// valid cells in order — a null-free source is returned unchanged, so an
// all-valid `Numeric` column stays on the fast path, and a trimmed numeric
// result — now necessarily all-valid — canonicalises onto it.

///|
/// Build the fill buffer for `fill_null`: keep each valid cell, replace
/// every null slot (`valid[i] == false`) with `v`. The four per-dtype
/// arms share this closure instead of repeating the `mapi` verbatim.
fn[T] fill_buffer(data : ArrayView[T], valid : Array[Bool], v : T) -> Array[T] {
  data.mapi((i, x) => if valid[i] { x } else { v })
}

///|
/// The every-arm refusal of `fill_null`: a fill value whose scalar
/// dtype does not match the column it was handed.
fn fill_mismatch(fill : String, actual : @types.DataType) -> @types.DataError {
  @types.DataError::TypeMismatch(
    @types.TypeMismatchDetail::Message(
      "fill_null type \{fill} does not match column type \{actual}",
    ),
  )
}

///|
/// Replace every null cell with `value`. `raise TypeMismatch(...)` if
/// `value` is `Scalar::Null` (filling nulls with null is meaningless) or
/// if its dtype differs from the series'. The returned series has a
/// fully-valid bitmap and keeps the source storage backend
/// (`preserve_backend`) — a no-op fill on an all-valid `Numeric` column
/// stays `Numeric`.
///
/// Raises `InvalidOperation` past the string layout's payload bound (via
/// the underlying `from_strings`): a string fill whose rebuilt column
/// would carry more than `2^31 - 1` payload bytes refuses rather than
/// wraps.
pub fn Series::fill_null(
  self : Series,
  value : @types.Scalar,
) -> Series raise @types.DataError {
  // A column with no nulls is its own fill: the rebuild below would pay a
  // full re-materialisation (the String arm decodes every cell) to produce
  // an equal series. `drop_nulls` carries the same short-circuit. The
  // dtype equality keeps a mismatched fill value falling through to the
  // branches' own refusals — a typed fill on the wrong dtype raises with
  // its full message even when there is nothing to fill.
  if self.storage.null_count() == 0 && value.dtype() == self.dtype() {
    return self
  }
  let valid = self.validity_bools()
  let filled = match value {
    @types.Scalar::Null =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message("cannot fill nulls with Null"),
      )
    @types.Scalar::Int(v) =>
      // Gated on the column's *dtype*, not the buffer variant: a Date
      // column is also I64-typed, and an Int rebuild would silently retype
      // it to day counts.
      match self.storage.data() {
        @column.ColumnData::I64(data) if self.dtype() is @types.DataType::Int => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(self.name, @column.BuiltinColumn::from_ints(buf))
        }
        _ => raise fill_mismatch("Int", self.dtype())
      }
    @types.Scalar::Float(v) =>
      match self.storage.data() {
        @column.ColumnData::F64(data) => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(
            self.name,
            @column.BuiltinColumn::from_floats(buf),
          )
        }
        _ => raise fill_mismatch("Float", self.dtype())
      }
    @types.Scalar::Bool(v) =>
      match self.storage.data() {
        @column.ColumnData::Bool(data) => {
          let buf = fill_buffer(data, valid, v)
          Series::from_builtin(
            self.name,
            @column.BuiltinColumn::from_bools(buf),
          )
        }
        _ => raise fill_mismatch("Bool", self.dtype())
      }
    @types.Scalar::String(v) =>
      match self.storage.data() {
        @column.ColumnData::Utf8(data) => {
          let buf = fill_buffer(data.to_strings().exact_view(), valid, v)
          Series::from_builtin(
            self.name,
            @column.BuiltinColumn::from_strings(buf),
          )
        }
        _ => raise fill_mismatch("String", self.dtype())
      }
    // A Date value fills its own dtype only — gated on the column's *dtype*,
    // not the buffer variant: an Int column is also I64-typed, and filling it
    // with day-counts would silently misinterpret it.
    @types.Scalar::Date(v) =>
      match self.storage.data() {
        @column.ColumnData::I64(data) if self.dtype() is @types.DataType::Date => {
          let buf = fill_buffer(data, valid, v)
          Series::from_date_options(self.name, buf.map(x => Some(x)))
        }
        _ => raise fill_mismatch("Date", self.dtype())
      }
    // A Timestamp value fills its own dtype only — the Date rule over the
    // same buffer, with microseconds in place of day-counts.
    @types.Scalar::Timestamp(v) =>
      match self.storage.data() {
        @column.ColumnData::I64(data) if self.dtype()
          is @types.DataType::Timestamp => {
          let buf = fill_buffer(data, valid, v)
          Series::from_timestamp_options(self.name, buf.map(x => Some(x)))
        }
        _ => raise fill_mismatch("Timestamp", self.dtype())
      }
    // A Duration value fills its own dtype only — the Timestamp rule over
    // the same buffer, a span in place of an instant.
    @types.Scalar::Duration(v) =>
      match self.storage.data() {
        @column.ColumnData::I64(data) if self.dtype()
          is @types.DataType::Duration => {
          let buf = fill_buffer(data, valid, v)
          Series::from_duration_options(self.name, buf.map(x => Some(x)))
        }
        _ => raise fill_mismatch("Duration", self.dtype())
      }
    // A Decimal value fills its own dtype only — the Date rule over the
    // decimal's own buffer, the value carried whole (cohort and sign
    // included).
    @types.Scalar::Decimal(v) =>
      match self.storage.data() {
        @column.ColumnData::Dec(data) if self.dtype()
          is @types.DataType::Decimal => {
          let buf = fill_buffer(data, valid, v)
          Series::from_decimals(self.name, buf.map(x => Some(x)))
        }
        _ => raise fill_mismatch("Decimal", self.dtype())
      }
  }
  self.preserve_backend(filled)
}

///|
/// Drop every null cell. The returned series has `len = original.len -
/// original.null_count` and no null cells left. A source that already has no
/// nulls is returned unchanged — so an all-valid `Numeric` column stays on the
/// fast path (no bitmap to carry); otherwise the kept cells are gathered, and a
/// numeric result — now necessarily all-valid — canonicalises onto `Numeric`
/// (`gather_series`), so dropping nulls cannot leave a numeric column off the
/// fast path.
///
/// Raises `InvalidOperation` past the string layout's payload bound (via the
/// underlying `gather_series`): a kept-cells rebuild of a string column whose
/// payload passes `2^31 - 1` bytes refuses rather than wraps.
pub fn Series::drop_nulls(self : Series) -> Series raise @types.DataError {
  // No nulls → nothing to drop; return `self` instead of gathering every row
  // into an identical rebuild. `null_count` is O(1) for a `Numeric` column
  // (always 0, so it short-circuits here and stays on the fast path) and a
  // bitmap popcount for `Builtin`. Past this guard the column carries a null,
  // so it is necessarily `Builtin` — the mask read below sees a real bitmap.
  if self.storage.null_count() == 0 {
    return self
  }
  // Keep the indices of the valid cells, in order, then gather them —
  // `gather_series` rebuilds the series with a fully-valid bitmap.
  let valid = self.storage.validity().to_bools()
  let kept = Array::makei(valid.length(), i => i).filter(i => valid[i])
  self.gather_series(kept)
}
