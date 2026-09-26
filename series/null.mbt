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
/// Replace every null cell with `value`. `raise TypeMismatch(...)` if
/// `value` is `Scalar::Null` (filling nulls with null is meaningless) or
/// if its dtype differs from the series'. The returned series has a
/// fully-valid bitmap and keeps the source storage backend
/// (`preserve_backend`) — a no-op fill on an all-valid `Numeric` column
/// stays `Numeric`.
pub fn Series::fill_null(
  self : Series,
  value : @types.Scalar,
) -> Series raise @types.DataError {
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
        _ =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "fill_null type Int does not match column type \{self.dtype()}",
            ),
          )
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
        _ =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "fill_null type Float does not match column type \{self.dtype()}",
            ),
          )
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
        _ =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "fill_null type Bool does not match column type \{self.dtype()}",
            ),
          )
      }
    @types.Scalar::String(v) =>
      match self.storage.data() {
        @column.ColumnData::Utf8(data) => {
          let buf = data
            .to_strings()
            .mapi((i, x) => if valid[i] { x } else { v })
          Series::from_builtin(
            self.name,
            @column.BuiltinColumn::from_strings(buf),
          )
        }
        _ =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "fill_null type String does not match column type \{self.dtype()}",
            ),
          )
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
        _ =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "fill_null type Date does not match column type \{self.dtype()}",
            ),
          )
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
pub fn Series::drop_nulls(self : Series) -> Series {
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
