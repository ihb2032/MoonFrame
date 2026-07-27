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
fn int_cells(col : BuiltinColumn) -> (Array[Int64], Bitmap) {
  match col.data() {
    ColumnData::Int(a) => (a, col.validity())
    ColumnData::Float(_) | ColumnData::Bool(_) | ColumnData::String(_) =>
      ([], col.validity())
  }
}

///|
/// The `Float` buffer and validity mask; see `int_cells`.
fn float_cells(col : BuiltinColumn) -> (Array[Double], Bitmap) {
  match col.data() {
    ColumnData::Float(a) => (a, col.validity())
    ColumnData::Int(_) | ColumnData::Bool(_) | ColumnData::String(_) =>
      ([], col.validity())
  }
}

///|
/// The `Bool` buffer and validity mask; see `int_cells`.
fn bool_cells(col : BuiltinColumn) -> (Array[Bool], Bitmap) {
  match col.data() {
    ColumnData::Bool(a) => (a, col.validity())
    ColumnData::Int(_) | ColumnData::Float(_) | ColumnData::String(_) =>
      ([], col.validity())
  }
}

///|
/// The `String` buffer and validity mask; see `int_cells`.
fn string_cells(col : BuiltinColumn) -> (Array[String], Bitmap) {
  match col.data() {
    ColumnData::String(a) => (a, col.validity())
    ColumnData::Int(_) | ColumnData::Float(_) | ColumnData::Bool(_) =>
      ([], col.validity())
  }
}

///|
/// A validity mask from a plain `Bool` vector, `true` ↦ valid. What
/// `Bitmap::from_bools` did before it was deleted: production never builds a
/// mask that way — it builds one from the option vector a constructor was
/// given, or all-valid — so spelling a mask out bit by bit is a test's need
/// and lives with the tests.
fn mask(bits : Array[Bool]) -> Bitmap {
  Bitmap::from_options(bits.map(b => if b { Some(0) } else { None }))
}
