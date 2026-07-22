///|
/// How an equi-join combines rows that share (or fail to share) a key.
///
/// `pub(all)` so callers can name the variants directly (e.g.
/// `JoinOptions::on(keys, how=Left)`), matching `@types.SortOrder` / `@types.NullOrder`:
///   * `Inner` — keep only rows whose key matches on both sides.
///   * `Left` — keep every left row; where it has no right match, the
///     right-hand columns are filled with nulls.
///   * `Right` — the mirror of `Left`: keep every right row; where it has
///     no left match, the left-hand columns are filled with nulls. The
///     output still leads with the left columns (only the row set changes
///     to "all right rows").
///   * `Outer` — the full outer join: keep matched pairs plus every
///     unmatched row from **both** sides (the missing side's columns null).
///     Left rows (matched and unmatched) come first in left order, then the
///     unmatched right rows in right order.
///   * `Cross` — the Cartesian product (every left row paired with every
///     right row); takes **no** key columns.
pub(all) enum JoinType {
  Inner
  Left
  Right
  Outer
  Cross
} derive(Eq, Debug)

///|
pub extend JoinType with Eq::{equal, not_equal}

///|
pub extend JoinType with Debug::{to_repr}

///|
/// The knobs for `DataFrame::join`: which columns to match on, the join
/// `how`, the `suffix` disambiguating a right column whose name collides
/// with a left one, and whether to `coalesce` the key columns. Fields are
/// read-only outside the package — build options through `JoinOptions::on` /
/// `JoinOptions::left_on` / `JoinOptions::cross`, naming only the knobs that
/// differ from their defaults. The three entry points are the legal shapes: an
/// `on` join, a paired `left_on` / `right_on` join, and a keyless cross join —
/// no combination of them can be spelled.
///
///   * `on` — the key **expressions**, evaluated over **both** frames
///     (Polars' `IntoExpr`). A bare `col("id")` matches on an existing
///     column; a derived key such as `col("ts") / lit_int(86400)` matches
///     on the computed value. `["region", "product"]`-style multi-key joins
///     become `[col("region"), col("product")]`, matched on the tuple. An
///     empty list is a documented cross join (see `DataFrame::join`).
///   * `left_on` / `right_on` — paired key expressions evaluated on the
///     left and right frame respectively, for joining on differently-named
///     or differently-derived keys (`left_on([col("a")])` against
///     `right_on([col("b")])`). Mutually exclusive with `on`, and the two
///     lists must name the same number of keys; key `i` on the left is
///     matched against key `i` on the right.
///   * `how` — `Inner` (the `on` / `left_on` default), `Left`, `Right`,
///     `Outer`, or `Cross`.
///   * `suffix` — appended to a **right** column whose name also occurs in
///     the left frame (default `"_right"`); the left column keeps its name.
///   * `coalesce` — whether each key column is merged into a single output
///     column. `None` (the default) auto-selects by `how`, matching Polars:
///     an inner / left / right join **coalesces** (the key appears once),
///     while `Outer` does **not** (the right key is kept as
///     `<key><suffix>`, null wherever its row had no match, so matched and
///     unmatched rows are distinguishable). `Some(true)` always coalesces;
///     `Some(false)` never does. Coalescing only applies when keying by
///     `on` whose every key is a bare `col(...)` (the precondition for the
///     key to name a single column on both sides); `left_on` / `right_on`
///     and any derived key turn it off, keeping both key columns (Polars'
///     "join on a non-column expression turns off coalescing"). When
///     coalesced the single key takes its value from whichever side is
///     present on that row (the two are equal on a matched pair) — the left
///     on `Inner` / `Left`, the right on `Right`, and the present side per
///     row on `Outer`.
pub struct JoinOptions {
  on : Array[@expr.Expr]
  left_on : Array[@expr.Expr]
  right_on : Array[@expr.Expr]
  how : JoinType
  suffix : String
  coalesce : Bool?
} derive(Eq, Debug)

///|
pub extend JoinOptions with Eq::{equal, not_equal}

///|
pub extend JoinOptions with Debug::{to_repr}

///|
/// Start a join on shared key columns — each key expression is evaluated on
/// **both** frames (`JoinOptions::on([col("id")])`). `how` defaults to an
/// inner join, `suffix` to `"_right"` for a right column whose name collides
/// with a left one, and an omitted `coalesce` leaves key coalescing on
/// automatic (by `how`, matching Polars); pass `coalesce=true` / `false` to
/// force it.
///
/// The `keys` array is copied (as in `left_on`), so mutating it after
/// construction cannot alter the join specification.
pub fn JoinOptions::on(
  keys : Array[@expr.Expr],
  how? : JoinType = Inner,
  suffix? : String = "_right",
  coalesce? : Bool,
) -> JoinOptions {
  { on: keys.copy(), left_on: [], right_on: [], how, suffix, coalesce }
}

///|
/// Start a join on differently-named (or differently-derived) keys: `keys` is
/// evaluated on the **left** frame, paired position-by-position with
/// `right_on` on the right
/// (`JoinOptions::left_on([col("a")], right_on=[col("b")])`). Taking both
/// sides at once makes an unpaired specification unspellable. Defaults match
/// `on`, except that `left_on` / `right_on` keys never coalesce — both key
/// columns are kept (Polars' rule).
///
/// Both arrays are copied, so mutating them after construction cannot alter
/// the join specification.
pub fn JoinOptions::left_on(
  keys : Array[@expr.Expr],
  right_on~ : Array[@expr.Expr],
  how? : JoinType = Inner,
  suffix? : String = "_right",
  coalesce? : Bool,
) -> JoinOptions {
  {
    on: [],
    left_on: keys.copy(),
    right_on: right_on.copy(),
    how,
    suffix,
    coalesce,
  }
}

///|
/// Start a cross-join specification — the Cartesian product of the two
/// frames, with no key columns (`how = Cross`, all key lists empty).
/// `suffix` still applies to a right column whose name clashes with a left
/// one; `coalesce` is irrelevant (there are no keys to merge).
pub fn JoinOptions::cross(suffix? : String = "_right") -> JoinOptions {
  { on: [], left_on: [], right_on: [], how: Cross, suffix, coalesce: None }
}
