// Reading a column's buffers, for tests that assert what is *in* them —
// placeholders at null slots, a cast preserving validity, a constructor's
// buffer and mask agreeing in length. The column itself offers `data()`, an
// untyped enum, because the one production consumer (`internal/kernel`)
// matches every dtype in one pass; the typed readers it used to carry existed
// for these assertions alone and are gone. Unwrapping the dtype a test already
// knows is a test's business, so it lives here, inside the package the
// whitebox suite compiles into.

///|
/// The `Int` buffer and validity mask of a column the caller knows is `Int`;
/// an empty buffer for any other dtype, which fails the assertion that
/// follows rather than the test.
fn int_cells(col : BuiltinColumn) -> (ArrayView[Int64], Bitmap) {
  match col.data() {
    ColumnData::Int(a) => (a, col.validity())
    ColumnData::Float(_) | ColumnData::Bool(_) | ColumnData::String(_) =>
      ([], col.validity())
  }
}

///|
/// The `Float` buffer and validity mask; see `int_cells`.
fn float_cells(col : BuiltinColumn) -> (ArrayView[Double], Bitmap) {
  match col.data() {
    ColumnData::Float(a) => (a, col.validity())
    ColumnData::Int(_) | ColumnData::Bool(_) | ColumnData::String(_) =>
      ([], col.validity())
  }
}

///|
/// The `Bool` buffer and validity mask; see `int_cells`.
fn bool_cells(col : BuiltinColumn) -> (ArrayView[Bool], Bitmap) {
  match col.data() {
    ColumnData::Bool(a) => (a, col.validity())
    ColumnData::Int(_) | ColumnData::Float(_) | ColumnData::String(_) =>
      ([], col.validity())
  }
}

///|
/// The `String` buffer and validity mask; see `int_cells`.
fn string_cells(col : BuiltinColumn) -> (ArrayView[String], Bitmap) {
  match col.data() {
    ColumnData::String(a) => (a, col.validity())
    ColumnData::Int(_) | ColumnData::Float(_) | ColumnData::Bool(_) =>
      ([], col.validity())
  }
}

///|
/// A validity mask from a plain `Bool` vector, `true` ↦ valid. What
/// `Bitmap::from_bools` did before it was deleted (doc-guard: historical):
/// production never builds a mask that way — it builds one from the option
/// vector a constructor was given, or all-valid — so spelling a mask out bit
/// by bit is a test's need and lives with the tests.
fn mask(bits : Array[Bool]) -> Bitmap {
  Bitmap::from_options(bits.map(b => if b { Some(0) } else { None }))
}

///|
/// Whether every null slot's `data` holds this dtype's canonical placeholder
/// (`Int = 0`, `Float = 0.0`, `Bool = false`, `String = ""`). The constructors,
/// casts and row transforms all write these, so a null slot's value never
/// leaks out of a `Scalar`-returning read — and, since `BuiltinColumn` derives
/// `Eq` over the raw `data` array, null slots included, two logically equal
/// columns differing only in a null slot's placeholder would otherwise compare
/// unequal.
///
/// It lives with the tests because asserting it is all it was ever for: as a
/// production function it had no caller, which made it a `pub` the packages
/// above could reach for no reason any of them needed. The `data` match is
/// wildcard-free, so a future dtype has to supply its placeholder here.
fn placeholders_normalized(col : BuiltinColumn) -> Bool {
  let valid = col.validity.to_bools()
  match col.data {
    ColumnData::Int(a) => null_slots_hold(a, valid, 0L)
    ColumnData::Float(a) => null_slots_hold(a, valid, 0.0)
    ColumnData::Bool(a) => null_slots_hold(a, valid, false)
    ColumnData::String(a) => null_slots_hold(a, valid, "")
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
