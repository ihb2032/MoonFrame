// Sort vocabulary shared by the per-column kernel in `series` and the
// multi-key composition in `frame`, so both layers name one direction and
// one missing-placement convention.

///|
/// Direction of a sort key. `Asc` sorts smaller values first, `Desc`
/// sorts larger values first. The convention applies to every dtype:
/// `Int` / `Float` use numeric ordering, `Bool` uses `false < true`,
/// `String` uses lexicographic comparison.
pub(all) enum SortOrder {
  Asc
  Desc
} derive(Eq, Debug)

///|
pub extend SortOrder with Eq::{equal, not_equal}

///|
pub extend SortOrder with Debug::{to_repr}

///|
/// Where missing cells go relative to non-missing ones. Missing means
/// either a `Null` slot (validity bit 0) or — for `Float` columns —
/// `NaN`. The plan specifies that NaN is treated identically to Null
/// for ordering, so callers don't need a separate knob.
pub(all) enum NullOrder {
  NullsFirst
  NullsLast
} derive(Eq, Debug)

///|
pub extend NullOrder with Eq::{equal, not_equal}

///|
pub extend NullOrder with Debug::{to_repr}
