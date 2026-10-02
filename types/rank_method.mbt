// The ranking vocabulary — Polars' `rank` `method` parameter, named by
// callers through `Expr::rank` and carried by the expression AST's
// positional-operator tag, so it lives with the other AST-carried parameter
// vocabularies (`ClosedInterval` for `is_between`) rather than with any one
// consumer.

///|
/// How `rank` numbers a tie — Polars' `method` parameter. Over the `m`
/// sorted non-null cells, a tie group spanning sorted positions `[a, b]`:
///
/// - `Average` (Polars' default) — every member gets the mean of `a+1 … b+1`,
///   a `Float` rank (`[3, 6, 1, 1, 6]` ranks `3.0, 4.5, 1.5, 1.5, 4.5`);
/// - `Min` — every member gets `a+1`, competition ranking (gaps follow ties);
/// - `Max` — every member gets `b+1`;
/// - `Dense` — like `Min` but the next tie group starts one past the
///   previous group's rank, no gaps;
/// - `Ordinal` — no tie sharing: cells rank `1 … m` in input order among
///   equals.
///
/// Null cells stay null under every method (only non-null cells rank).
/// Polars' sixth method `random` is not carried: its output is seeded
/// randomness, out of place in a library whose every other verb is
/// deterministic.
pub(all) enum RankMethod {
  Average
  Min
  Max
  Dense
  Ordinal
} derive(Eq, Debug)

///|
pub extend RankMethod with Eq::{equal, not_equal}

///|
pub extend RankMethod with Debug::{to_repr}
