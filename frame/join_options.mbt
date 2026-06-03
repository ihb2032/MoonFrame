///|
/// How an equi-join combines rows that share (or fail to share) a key.
///
/// `pub(all)` so callers can name the variants directly (e.g.
/// `JoinOptions::on(keys).with_how(Left)`), matching `AggKind` /
/// `SortOrder`. v0.2 ships the two most common joins:
///   * `Inner` — keep only rows whose key matches on both sides.
///   * `Left` — keep every left row; where it has no right match, the
///     right-hand columns are filled with nulls.
///
/// `Right` / `Outer` are deferred to v0.3.
pub(all) enum JoinType {
  Inner
  Left
} derive(Eq, Debug)

///|
/// The knobs for `DataFrame::join`: which columns to match on, the join
/// `how`, and the `suffix` disambiguating a right column whose name
/// collides with a left one. Fields are private outside the package —
/// build options through `JoinOptions::on` and (optionally) chain
/// `with_how` / `with_suffix`.
///
///   * `on` — the key column names, present in **both** frames; matched
///     left-to-right, so `["region", "product"]` joins on the
///     `(region, product)` tuple. An empty list is a documented cross
///     join (see `DataFrame::join`).
///   * `how` — `Inner` (the `on` default) or `Left`.
///   * `suffix` — appended to a **right** non-key column whose name also
///     occurs in the left frame (default `"_right"`); the left column
///     keeps its name. The key columns appear once and are never
///     suffixed.
pub struct JoinOptions {
  on : Array[String]
  how : JoinType
  suffix : String
} derive(Eq, Debug)

///|
/// Start a join specification on the `keys` columns, defaulting to an
/// inner join with the `"_right"` collision suffix. Chain `with_how` to
/// switch to a left join and `with_suffix` to change the suffix:
/// `JoinOptions::on(["id"]).with_how(Left).with_suffix("_r")`.
pub fn JoinOptions::on(keys : Array[String]) -> JoinOptions {
  { on: keys, how: Inner, suffix: "_right" }
}

///|
/// Return a copy of these options with the join `how` set to `how`.
/// Chainable after `on`.
pub fn JoinOptions::with_how(self : JoinOptions, how : JoinType) -> JoinOptions {
  { on: self.on, how, suffix: self.suffix }
}

///|
/// Return a copy of these options whose right-column collision suffix is
/// `suffix` instead of the default `"_right"`. Chainable after `on`.
pub fn JoinOptions::with_suffix(
  self : JoinOptions,
  suffix : String,
) -> JoinOptions {
  { on: self.on, how: self.how, suffix }
}
