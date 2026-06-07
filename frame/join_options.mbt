///|
/// How an equi-join combines rows that share (or fail to share) a key.
///
/// `pub(all)` so callers can name the variants directly (e.g.
/// `JoinOptions::on(keys).with_how(Left)`), matching `AggKind` /
/// `SortOrder`:
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
/// The knobs for `DataFrame::join`: which columns to match on, the join
/// `how`, the `suffix` disambiguating a right column whose name collides
/// with a left one, and whether to `coalesce` the key columns. Fields are
/// private outside the package — build options through `JoinOptions::on`
/// and (optionally) chain `with_how` / `with_suffix` / `with_coalesce`.
///
///   * `on` — the key column names, present in **both** frames; matched
///     left-to-right, so `["region", "product"]` joins on the
///     `(region, product)` tuple. An empty list is a documented cross
///     join (see `DataFrame::join`).
///   * `how` — `Inner` (the `on` default), `Left`, `Right`, `Outer`, or
///     `Cross`.
///   * `suffix` — appended to a **right** column whose name also occurs in
///     the left frame (default `"_right"`); the left column keeps its name.
///   * `coalesce` — whether each key column is merged into a single output
///     column. `None` (the `on` default) auto-selects by `how`, matching
///     Polars: an inner join **coalesces** (the key appears once), while
///     `Left` / `Right` / `Outer` do **not** (the right key is kept as
///     `<key><suffix>`, null wherever its row had no match, so matched and
///     unmatched rows are distinguishable). `Some(true)` always coalesces;
///     `Some(false)` never does. When coalesced the single key takes its
///     value from whichever side is present on that row (the two are equal
///     on a matched pair) — the left on `Inner` / `Left`, the right on
///     `Right`, and the present side per row on `Outer`.
pub struct JoinOptions {
  on : Array[String]
  how : JoinType
  suffix : String
  coalesce : Bool?
} derive(Eq, Debug)

///|
/// Start a join specification on the `keys` columns, defaulting to an
/// inner join with the `"_right"` collision suffix and automatic key
/// coalescing (`coalesce = None`). Chain `with_how` to switch the join type
/// (`Left` / `Right` / `Outer`), `with_suffix` to change the suffix, and
/// `with_coalesce` to force key coalescing on or off:
/// `JoinOptions::on(["id"]).with_how(Left).with_coalesce(true)`.
pub fn JoinOptions::on(keys : Array[String]) -> JoinOptions {
  { on: keys, how: Inner, suffix: "_right", coalesce: None }
}

///|
/// Start a cross-join specification — the Cartesian product of the two
/// frames, with no key columns (`how = Cross`, `on = []`). Keeps the
/// default `"_right"` collision suffix; `coalesce` is irrelevant (there
/// are no keys to merge). `with_suffix` still applies to right columns
/// whose names clash with the left. The convenience `DataFrame::cross_join`
/// wraps this.
pub fn JoinOptions::cross() -> JoinOptions {
  { on: [], how: Cross, suffix: "_right", coalesce: None }
}

///|
/// Return a copy of these options with the join `how` set to `how`.
/// Chainable after `on`.
pub fn JoinOptions::with_how(self : JoinOptions, how : JoinType) -> JoinOptions {
  { on: self.on, how, suffix: self.suffix, coalesce: self.coalesce }
}

///|
/// Return a copy of these options whose right-column collision suffix is
/// `suffix` instead of the default `"_right"`. Chainable after `on`.
pub fn JoinOptions::with_suffix(
  self : JoinOptions,
  suffix : String,
) -> JoinOptions {
  { on: self.on, how: self.how, suffix, coalesce: self.coalesce }
}

///|
/// Return a copy of these options that forces key coalescing on
/// (`coalesce = Some(true)`, key appears once) or off
/// (`coalesce = Some(false)`, both key columns kept). Overrides the
/// `how`-derived default from `on`. Chainable after `on`.
pub fn JoinOptions::with_coalesce(
  self : JoinOptions,
  coalesce : Bool,
) -> JoinOptions {
  { on: self.on, how: self.how, suffix: self.suffix, coalesce: Some(coalesce) }
}
