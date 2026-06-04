///|
/// The reduction an `AggSpec` applies to a column within each group.
///
/// `pub(all)` so callers can name the variants directly (e.g. in a custom
/// spec list), matching `SortOrder` / `NullOrder`. The per-kind semantics
/// (null skipping, `Float` NaN handling, dtype of the result) are
/// inherited from the matching `Series` reduction — see
/// `GroupedDataFrame::agg`.
pub(all) enum AggKind {
  Count
  Sum
  Mean
  Min
  Max
} derive(Eq, Debug)

///|
/// The lowercase verb used to build a spec's default output column name
/// (`"<column>_<suffix>"`, e.g. `quantity_sum`). Kept in lock-step with
/// the variant set so a new `AggKind` cannot ship without a name.
fn AggKind::suffix(self : AggKind) -> String {
  match self {
    Count => "count"
    Sum => "sum"
    Mean => "mean"
    Min => "min"
    Max => "max"
  }
}

///|
/// One aggregation request: which `column` to reduce, the `kind` of
/// reduction, and an optional output-column `alias`. Fields are private
/// outside the package — build a spec through the `count` / `sum` / `mean`
/// / `min` / `max` constructors and (optionally) chain `with_alias` to
/// rename its output column.
///
/// The default output column name is `"<column>_<kind>"` (e.g. a `sum`
/// over `quantity` lands in `quantity_sum`); `with_alias` overrides it.
/// `GroupedDataFrame::agg` routes the output columns through
/// `DataFrame::new`, so two specs whose names collide (with each other or
/// with a key column) surface as `DuplicateColumn`.
pub struct AggSpec {
  column : String
  kind : AggKind
  alias_name : String?
} derive(Eq, Debug)

///|
/// Count of non-null cells in `column` within each group. The result is an
/// `Int` column (matching `Series::count` and Polars' `count`) — nulls are
/// not counted, unlike a plain row count (`len`).
pub fn AggSpec::count(column : String) -> AggSpec {
  { column, kind: Count, alias_name: None }
}

///|
/// Sum of `column` within each group. The result keeps the source numeric
/// dtype (`Int → Int`, `Float → Float`); a non-numeric column raises
/// `TypeMismatch` at `agg` time. Empty / all-null groups reduce to the
/// additive identity (`0` / `0.0`); a `Float` `NaN` cell propagates to a
/// `NaN` total (matching `Series::sum` — `NaN` is a value, not missing).
pub fn AggSpec::sum(column : String) -> AggSpec {
  { column, kind: Sum, alias_name: None }
}

///|
/// Arithmetic mean of `column` within each group, as a nullable `Float`
/// column. An all-null (or empty) group yields a null mean rather than
/// failing the whole aggregation; a `Float` `NaN` cell propagates to a
/// `NaN` mean (matching `Series::mean` — `NaN` is a value, only `Null` is
/// missing). A non-numeric column raises `TypeMismatch` at `agg` time.
pub fn AggSpec::mean(column : String) -> AggSpec {
  { column, kind: Mean, alias_name: None }
}

///|
/// Minimum cell of `column` within each group, in the source dtype. Every
/// dtype has a natural order (`String` lexicographic, `Bool` `false <
/// true`), so `min` is defined for all of them; `Float` `NaN` is skipped
/// (as in Polars' regular `min` / `max`, which ignore `NaN`). An empty /
/// all-null group yields a null cell.
pub fn AggSpec::min(column : String) -> AggSpec {
  { column, kind: Min, alias_name: None }
}

///|
/// Maximum cell of `column` within each group, in the source dtype.
/// Mirrors `min` with the order reversed.
pub fn AggSpec::max(column : String) -> AggSpec {
  { column, kind: Max, alias_name: None }
}

///|
/// Return a copy of this spec whose aggregated column will be named `name`
/// instead of the default `"<column>_<kind>"`. Chainable after any
/// constructor: `AggSpec::sum("revenue").with_alias("total_revenue")`.
pub fn AggSpec::with_alias(self : AggSpec, name : String) -> AggSpec {
  { column: self.column, kind: self.kind, alias_name: Some(name) }
}

///|
/// The output column name for this spec: the explicit `alias` if set,
/// otherwise the default `"<column>_<kind>"`. Package-private — `agg`
/// uses it to name each aggregated column.
fn AggSpec::output_name(self : AggSpec) -> String {
  match self.alias_name {
    Some(name) => name
    None => self.column + "_" + self.kind.suffix()
  }
}
