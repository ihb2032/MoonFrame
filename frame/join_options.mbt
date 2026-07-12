///|
/// How an equi-join combines rows that share (or fail to share) a key.
///
/// `pub(all)` so callers can name the variants directly (e.g.
/// `JoinOptions::on(keys).with_how(Left)`), matching `SortOrder` /
/// `NullOrder`:
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
/// read-only outside the package — build options through `JoinOptions::on` /
/// `JoinOptions::left_on` / `JoinOptions::cross` and (optionally) chain
/// `with_right_on` / `with_how` / `with_suffix` / `with_coalesce`.
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
/// Start a join specification on the `keys` expressions (applied to both
/// frames), defaulting to an inner join with the `"_right"` collision
/// suffix and automatic key coalescing (`coalesce = None`). Chain
/// `with_how` to switch the join type (`Left` / `Right` / `Outer`),
/// `with_suffix` to change the suffix, and `with_coalesce` to force key
/// coalescing on or off:
/// `JoinOptions::on([col("id")]).with_how(Left).with_coalesce(true)`.
///
/// The `keys` array is copied (as in `left_on` / `with_right_on`), so
/// mutating it after construction cannot alter the join specification.
pub fn JoinOptions::on(keys : Array[@expr.Expr]) -> JoinOptions {
  {
    on: keys.copy(),
    left_on: [],
    right_on: [],
    how: Inner,
    suffix: "_right",
    coalesce: None,
  }
}

///|
/// Start a join on differently-named (or differently-derived) keys: the
/// `keys` are evaluated on the **left** frame, paired position-by-position
/// with the `with_right_on` keys evaluated on the right. Defaults match
/// `on` (inner join, `"_right"` suffix), except that `left_on` / `right_on`
/// keys never coalesce — both key columns are kept (Polars' rule). Chain
/// `with_right_on` to supply the right-side keys:
/// `JoinOptions::left_on([col("a")]).with_right_on([col("b")])`.
pub fn JoinOptions::left_on(keys : Array[@expr.Expr]) -> JoinOptions {
  {
    on: [],
    left_on: keys.copy(),
    right_on: [],
    how: Inner,
    suffix: "_right",
    coalesce: None,
  }
}

///|
/// Start a cross-join specification — the Cartesian product of the two
/// frames, with no key columns (`how = Cross`, all key lists empty). Keeps
/// the default `"_right"` collision suffix; `coalesce` is irrelevant (there
/// are no keys to merge). `with_suffix` still applies to right columns
/// whose names clash with the left.
pub fn JoinOptions::cross() -> JoinOptions {
  {
    on: [],
    left_on: [],
    right_on: [],
    how: Cross,
    suffix: "_right",
    coalesce: None,
  }
}

///|
/// Return a copy of these options with the right-side keys for a
/// `left_on` / `right_on` join set to `keys` (evaluated on the right
/// frame). Chainable after `left_on`.
pub fn JoinOptions::with_right_on(
  self : JoinOptions,
  keys : Array[@expr.Expr],
) -> JoinOptions {
  { ..self, right_on: keys.copy() }
}

///|
/// Return a copy of these options with the left-side keys for a
/// `left_on` / `right_on` join set to `keys` (evaluated on the left
/// frame). The symmetric twin of `with_right_on`, so either side's keys
/// can be (re)supplied at any point in the chain.
pub fn JoinOptions::with_left_on(
  self : JoinOptions,
  keys : Array[@expr.Expr],
) -> JoinOptions {
  { ..self, left_on: keys.copy() }
}

///|
/// Return a copy of these options with the join `how` set to `how`.
/// Chainable after `on` / `left_on`.
pub fn JoinOptions::with_how(self : JoinOptions, how : JoinType) -> JoinOptions {
  { ..self, how, }
}

///|
/// Return a copy of these options whose right-column collision suffix is
/// `suffix` instead of the default `"_right"`. Chainable after `on` /
/// `left_on`.
pub fn JoinOptions::with_suffix(
  self : JoinOptions,
  suffix : String,
) -> JoinOptions {
  { ..self, suffix, }
}

///|
/// Return a copy of these options that forces key coalescing on
/// (`coalesce = Some(true)`, key appears once) or off
/// (`coalesce = Some(false)`, both key columns kept). Overrides the
/// `how`-derived default. Only effective for an `on` join whose keys are
/// all bare `col(...)`; `left_on` / `right_on` and derived keys never
/// coalesce regardless. Chainable after `on` / `left_on`.
pub fn JoinOptions::with_coalesce(
  self : JoinOptions,
  coalesce : Bool,
) -> JoinOptions {
  { ..self, coalesce: Some(coalesce) }
}

///|
/// Return a copy of these options with key coalescing reset to **automatic**
/// (`coalesce = None`): whether an eligible `on`-join key coalesces then follows
/// the `how`-derived default (`Inner` / `Left` / `Right` coalesce, `Outer` /
/// `Cross` do not), exactly as if `with_coalesce` had never been called. It is
/// the undo for `with_coalesce` — the only builder path back to the auto default
/// once coalescing has been forced on or off (the field is read-only outside
/// `frame`).
pub fn JoinOptions::with_coalesce_auto(self : JoinOptions) -> JoinOptions {
  { ..self, coalesce: None }
}
