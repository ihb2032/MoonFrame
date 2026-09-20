// Reading a column's buffers, for tests that assert what is *in* them —
// placeholders at null slots, a cast preserving validity, a constructor's
// buffer and mask agreeing in length. The column itself offers `data()`, an
// untyped enum, because its production consumers (`series` and the kernel
// layer) match every dtype in one pass; unwrapping a dtype a test already
// knows is test work, so the typed readers live here, inside the package
// the whitebox suite compiles into.

///|
/// The `Int` buffer and validity mask of a column the caller knows is `Int`;
/// an empty buffer for any other dtype, which fails the assertion that
/// follows rather than the test.
fn int_cells(col : BuiltinColumn) -> (ArrayView[Int64], @buffer.Bitmap) {
  match col.data() {
    ColumnData::I64(a) => (a, col.validity())
    ColumnData::F64(_) | ColumnData::Bool(_) | ColumnData::Utf8(_) =>
      ([], col.validity())
  }
}

///|
/// The `Float` buffer and validity mask, mirroring `int_cells`.
fn float_cells(col : BuiltinColumn) -> (ArrayView[Double], @buffer.Bitmap) {
  match col.data() {
    ColumnData::F64(a) => (a, col.validity())
    ColumnData::I64(_) | ColumnData::Bool(_) | ColumnData::Utf8(_) =>
      ([], col.validity())
  }
}

///|
/// The `Bool` buffer and validity mask, mirroring `int_cells`.
fn bool_cells(col : BuiltinColumn) -> (ArrayView[Bool], @buffer.Bitmap) {
  match col.data() {
    ColumnData::Bool(a) => (a, col.validity())
    ColumnData::I64(_) | ColumnData::F64(_) | ColumnData::Utf8(_) =>
      ([], col.validity())
  }
}

///|
/// The `String` buffer and validity mask, mirroring `int_cells`.
fn string_cells(col : BuiltinColumn) -> (Array[String], @buffer.Bitmap) {
  match col.data() {
    ColumnData::Utf8(a) => (a.to_strings(), col.validity())
    ColumnData::I64(_) | ColumnData::F64(_) | ColumnData::Bool(_) =>
      ([], col.validity())
  }
}

///|
/// Whether every null slot's `data` holds this dtype's canonical placeholder
/// (`Int = 0`, `Float = 0.0`, `Bool = false`, `String = ""`). The constructors,
/// casts and row transforms all write these, so a null slot's value never
/// leaks out of a `Scalar`-returning read — and, since this package's own `Eq`
/// for `BuiltinColumn` compares the raw `data` array,
/// null slots included, two logically equal columns differing only in a null
/// slot's placeholder would otherwise compare unequal.
///
/// It lives with the tests because asserting it is all it was ever for: as a
/// production function it had no caller, which made it a `pub` the packages
/// above could reach for no reason any of them needed. The `data` match is
/// wildcard-free, so a future dtype has to supply its placeholder here.
fn placeholders_normalized(col : BuiltinColumn) -> Bool {
  let valid = col.validity.to_bools()
  match col.data {
    ColumnData::I64(a) => null_slots_hold(a, valid, 0L)
    ColumnData::F64(a) => null_slots_hold(a, valid, 0.0)
    ColumnData::Bool(a) => null_slots_hold(a, valid, false)
    ColumnData::Utf8(a) => null_slots_hold(a.to_strings(), valid, "")
  }
}

///|
/// `true` when every null slot (`valid[i] == false`) of `data` holds `ph`.
fn[T : Eq] null_slots_hold(
  data : ArrayView[T],
  valid : Array[Bool],
  ph : T,
) -> Bool {
  for i in 0..<data.length() {
    if !valid[i] && data[i] != ph {
      return false
    }
  }
  true
}
