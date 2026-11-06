// MoonFrame — facade package. Re-exports the public API from the
// sub-packages so callers can `import "ihb2032/MoonFrame"` and reach the
// supported stable surface — every symbol a normal caller must name — in one
// place. The public sub-packages remain directly importable for
// callers who only need a slice of the surface (e.g. just the
// value types). Everything under `internal/` is unimportable downstream and is
// not part of the public API. Naming more of the packages here than the facade
// re-exports is how a package map goes stale, so the lists below name only what
// bears on what the facade re-exports.
//
// Note: the operator verbs are methods on `DataFrame` — `select` / `filter` /
// `with_columns` / `group_by` / `join` / `sort` and the rest — as are the
// `to_markdown` / `to_html` renderers, so re-exporting `type DataFrame` makes
// every one of them reachable through the facade and there is nothing to list
// for them here. They are deliberately not enumerated: a hand-written list of
// methods is stale the first time one is added, and the facade surface is
// enumerated mechanically instead, generated from
// the interfaces. Likewise the
// `JoinOptions` / `HtmlOptions` / `ChartSpec` constructors — the named
// constructors that replaced the setter chains
// (`JoinOptions::on` / `left_on` / `cross`, the `ChartSpec` mark-named
// family (`bar` / `line` / `point` / `area` / … / `arc` / `text` /
// `boxplot`) and `VegaChannel::count`, and `HtmlOptions::HtmlOptions`) —
// come for free once their
// types are re-exported. The rule is that simple: **methods and constructors ride along
// with a re-exported type; type names and free functions still need an
// explicit line here.** So the lists below are the value types (the Join
// `JoinType` / `JoinOptions`, the HTML `HtmlOptions`, the Chart `ChartKind` /
// `ChartSpec` / `VegaChannel` and its `VegaType` / `VegaAggregate` /
// `VegaSort`, …) plus every free function a caller reaches by name — the
// expression constructors, the frame's column selectors, the io layer's
// file-level readers and writers, the chart's channel builder, its
// spec / HTML export, and the plot entry. (The chart package keeps a second, deliberate
// surface off this facade: the deep Vega mirror family — the
// spec-object trees behind `@chart.VegaSides` and its kin — is reached
// through `@chart` qualification alone, the way io's string-level
// serialisers are; the facade-surface guard pins that line both ways.)
// The string-level
// serialisers (`parse_csv_str` / `parse_json_str` / `parse_ndjson_str` /
// `format_csv` / `format_json` / `format_ndjson`) are deliberately NOT
// re-exported: building a frame from in-memory text is a slice of the
// surface, reached through the io layer directly, not part of the first-contact
// face. (`GroupedDataFrame::agg` is reached the other way —
// by chaining off `group_by`'s return, not by naming the type.)
// (The text / literal helpers that once lived in the value-type package —
// `compare_string_lex`, `is_decimal_int_literal`, `format_scalar` — are now
// internal and are not part of the public
// surface.) The former ops package no longer exists (it was folded into the
// frame layer).
//
// The expression layer and the lazy plan follow the same rule for inherent
// methods: `Expr::{with_alias,cast,eq,sum,...}` and the `LazyFrame` methods
// remain available with their re-exported types. Trait-backed dot methods are
// different: the expression package exposes them through explicit
// `pub extend Expr with Trait::{method}` declarations, while operator syntax is
// provided by the corresponding trait impls (`Add` / `Sub` / `Mul` / `Div` /
// `BitAnd` / `BitOr` / `Neg`). Keep the explicit extensions; an impl alone no
// longer exposes its method through dot syntax.
//
// A type is re-exported only when a downstream caller must *name* it — to
// construct it (`Scalar::Int`, `HtmlOptions::HtmlOptions`), annotate it
// (`Array[Expr]`, `let df : DataFrame`), or match its variants. The
// fluent-chain intermediates are deliberately NOT re-exported: `WhenThen` /
// `WhenThenElse` (threaded through `when(c).then(a).otherwise(b)`),
// `GroupedDataFrame` / `LazyGroupBy` (through `group_by(k).agg(e)`), and the
// chart's `FramePlot` / `Plot` (through `plot(df).bar(x=, y=)` and the
// refinement chain off the mark). Reaching
// the library through this facade never requires naming one — a caller chains
// a method off the previous step's return value, and dot-method resolution
// follows that value's own type, so the chain compiles cross-module without
// the name in scope (verified against a real downstream module). They stay `pub` in their home packages, since the verb
// that returns one must be; the facade simply does not proxy the name.
//
// So the expression package needs explicit re-export only for the free
// constructors (`col` / `cols` / `lit` / `lit_int` / `lit_float` / `lit_str` /
// `lit_bool` / `lit_series` / `when` / `map_many` — `map_elements` is a
// method, riding along with `type Expr`).
// The `ClosedInterval` enum that names `is_between`'s `closed?` argument
// belongs to the value-type layer (the expression AST carries it, and the AST
// sits below the expression layer), so it is re-exported from there. The
// expression AST itself — `ExprNode` and its `BinOp` / `UnOp` / `StrOp` tags —
// is module-internal, unreachable downstream and named by no public API, so
// there is nothing to re-export for it. The lazy layer rides along with
// `type LazyFrame` (and its constructor) from the frame block above — the
// deferred plan is executed by the same engine that owns the eager verbs;
// its `scan_csv` / `scan_ndjson` / `scan_json` / `scan_parquet` file sources
// live in the io layer, listed there, beside the readers and drivers they
// defer.

///|
pub using @types {
  type DataError,
  type TypeMismatchDetail,
  type CellParseLocation,
  type ParseErrorDetail,
  type DataType,
  type Scalar,
  type Field,
  type Schema,
  type ClosedInterval,
  type RankMethod,
}

///|
pub using @expr {
  type Expr,
  col,
  cols,
  lit,
  lit_int,
  lit_float,
  lit_str,
  lit_bool,
  lit_series,
  when,
  map_many,
}

///|
/// `Series` has its own package (extracted so the
/// expression layer can build on the per-column unit); re-exporting the type
/// carries its constructors (`from_ints` / …) and methods along, so the
/// facade name for `Series` is unchanged for callers. `QuantileInterpolation`
/// is named by callers to pick a non-default interpolation — the only
/// enum-argument vocabulary on the reduction family.
pub using @series {type Series, type QuantileInterpolation}

///|
/// The lazy layer's deferred query plan lives in the frame package — the
/// engine that executes its verbs — re-exported beside the eager face it
/// defers.
pub using @frame {
  type DataFrame,
  type KeepStrategy,
  type JoinType,
  type JoinOptions,
  type HtmlOptions,
  type PivotAgg,
  type LazyFrame,
  type Optimizations,
}

///|
pub using @io {
  type CsvReadOptions,
  type CsvWriteOptions,
  type JsonReadOptions,
  type OnParseError,
  type ParquetCodec,
  parse_parquet,
  read_csv,
  read_json,
  read_ndjson,
  read_parquet,
  scan_csv,
  scan_json,
  scan_ndjson,
  scan_parquet,
  write_csv,
  write_json,
  write_ndjson,
  write_parquet,
}

///|
pub using @chart {
  type Chart,
  type ChartKind,
  type ChartSpec,
  type VegaAggregate,
  type VegaAutoSize,
  type VegaBin,
  type VegaBinParams,
  type VegaChannel,
  type VegaChannelSort,
  type VegaExtent,
  type VegaPadding,
  type VegaSort,
  type VegaSortChannel,
  type VegaStack,
  type VegaTimeUnit,
  type VegaType,
  constant,
  datum,
  field,
  format_vega_html,
  format_vega_lite,
  plot,
  write_vega_html,
  write_vega_lite,
}
