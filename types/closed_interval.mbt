// Interval-endpoint vocabulary for `Expr::is_between`. This is value-type
// material rather than an expression-layer construct because the expression
// AST (`ExprNode`) carries it on the `IsBetween` node, and the AST layer sits
// below the expression layer — the same
// reason `SortOrder` / `NullOrder` live here too. Constructible by callers
// (unlike the AST tags), so it stays a public, facade-re-exported type.

///|
/// Which endpoints an `is_between` range includes — Polars' `closed`.
/// `Both` (the default) is `lo <= x <= hi`; `Left` / `Right` open the other
/// end; `None` excludes both (`lo < x < hi`).
pub(all) enum ClosedInterval {
  Both
  Left
  Right
  None
} derive(Eq, Debug)

///|
pub extend ClosedInterval with Eq::{equal, not_equal}

///|
pub extend ClosedInterval with Debug::{to_repr}
