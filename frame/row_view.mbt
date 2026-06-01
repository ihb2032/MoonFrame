///|
/// Borrowed view of a single row in a `DataFrame`. `RowView` is the
/// per-row unit handed to `filter` predicates and the ergonomic way to
/// pluck typed cell values without materialising a per-row record.
///
/// The view stores the underlying `DataFrame` by value (cheap — the
/// frame's internals are shared) plus the row index, so accessors stay
/// `O(1)` and there is no per-row allocation.
pub struct RowView {
  df : DataFrame
  row_index : Int
} derive(Eq, Debug)

// ── Inspection ────────────────────────────────────────────────────────

///|
/// Row index this view points at.
pub fn RowView::index(self : RowView) -> Int {
  self.row_index
}

// ── Cell access ───────────────────────────────────────────────────────

///|
/// Read the cell as a `Scalar`. `raise ColumnNotFound(name)` for unknown
/// columns; null cells return `Scalar::Null`.
pub fn RowView::get(
  self : RowView,
  name : String,
) -> @types.Scalar raise @types.DataError {
  // `Series::get` re-validates `row_index`, so a view built by the
  // unchecked `DataFrame::row_view` surfaces an out-of-range index as
  // `IndexOutOfBounds` here rather than aborting.
  self.df.get_column(name).get(self.row_index)
}

///|
/// `true` when the cell at `(row_index, name)` is null.
/// `raise ColumnNotFound(name)` for unknown columns.
pub fn RowView::is_null(
  self : RowView,
  name : String,
) -> Bool raise @types.DataError {
  self.df.get_column(name).is_null(self.row_index)
}

///|
/// Read the cell as an `Int64`. Raises:
/// - `ColumnNotFound(name)` for unknown columns;
/// - `TypeMismatch(...)` when the column's dtype isn't `Int` or the cell
///   is null (mirrors `Scalar::as_int`).
pub fn RowView::get_int(
  self : RowView,
  name : String,
) -> Int64 raise @types.DataError {
  self.get(name).as_int()
}

///|
/// Read the cell as a `Double`. `Int` cells are promoted via
/// `Scalar::as_float`. Null cells and non-numeric dtypes
/// `raise TypeMismatch(...)`.
pub fn RowView::get_float(
  self : RowView,
  name : String,
) -> Double raise @types.DataError {
  self.get(name).as_float()
}

///|
/// Read the cell as a `Bool`. Non-bool dtypes and null cells
/// `raise TypeMismatch(...)`.
pub fn RowView::get_bool(
  self : RowView,
  name : String,
) -> Bool raise @types.DataError {
  self.get(name).as_bool()
}

///|
/// Read the cell as a `String`. Non-string dtypes and null cells
/// `raise TypeMismatch(...)`. For value-form rendering across all
/// dtypes, use `get(name).to_string()` instead.
pub fn RowView::get_string(
  self : RowView,
  name : String,
) -> String raise @types.DataError {
  self.get(name).as_string()
}
