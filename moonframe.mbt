// MoonFrame — facade package. Re-exports the public API from the
// sub-packages so callers can `import "ihb2032/MoonFrame"` and access every
// symbol in one place. The public sub-packages remain directly importable for
// callers who only need a slice of the surface (e.g. just `@types` for the
// value types); the `column` storage layer is internal (`internal/column`)
// and is not part of the public API.
//
// Note: the operator verbs (`select` / `drop` / `rename` /
// `filter` / `with_columns` /
// `sort` / `drop_nulls` /
// `fill_null` / `null_count` / `count` / `sum` /
// `mean` / `min` / `max` / `describe` / `group_by` / `join`) and the
// `to_markdown` / `to_html` renderers
// are now methods on `DataFrame`, so re-exporting `type DataFrame`
// makes them automatically reachable through the facade — there is
// nothing to list for them here. Likewise `GroupedDataFrame::agg` and the
// `JoinOptions` / `HtmlOptions` / `ChartSpec` constructors — one per type since
// v0.6 replaced the setter chains — come for free once their types are
// re-exported. Only the
// value types (including the GroupBy `GroupedDataFrame`, the Join
// `JoinType` / `JoinOptions`, the HTML `HtmlOptions`, and the Chart
// `ChartKind` / `ChartSpec`) and the `io` free functions need explicit
// re-export. (The text / literal helpers that once lived in `@types` —
// `compare_string_lex`, `is_decimal_int_literal`, `format_scalar` — are now in
// the internal `@text` / `@literal` packages and are not part of the public
// surface.) The `@ops` package no longer exists (it was folded into `@frame`).
//
// The expression / lazy layers follow the same rule for inherent methods:
// `Expr::{with_alias,cast,eq,sum,...}` and the `LazyFrame` methods remain
// available with their re-exported types. Trait-backed dot methods are
// different: `expr_ops.mbt` exposes them through explicit
// `pub extend Expr with Trait::{method}` declarations, while operator syntax is
// provided by the corresponding trait impls (`Add` / `Sub` / `Mul` / `Div` /
// `BitAnd` / `BitOr` / `Neg`). Keep the explicit extensions; an impl alone no
// longer exposes its method through dot syntax.
//
// A type is re-exported only when a downstream caller must *name* it — to
// construct it (`Scalar::Int`, `HtmlOptions::HtmlOptions`), annotate it
// (`Array[Expr]`, `let df : DataFrame`), or match its variants. The
// fluent-chain intermediates are deliberately NOT re-exported: `WhenThen` /
// `WhenThenElse` (threaded through `when(c).then(a).otherwise(b)`) and
// `GroupedDataFrame` / `LazyGroupBy` (through `group_by(k).agg(e)`). A caller
// never names one — it only chains a method off the previous step's return
// value, and dot-method resolution follows that value's own type, so the chain
// compiles cross-module without the name in scope (verified against a real
// downstream module). They stay `pub` in their home packages, since the verb
// that returns one must be; the facade simply does not proxy the name.
//
// So `@expr` needs explicit re-export only for the free constructors (`col` /
// `cols` / `lit` / `lit_int` / `lit_float` / `lit_str` / `lit_bool` /
// `lit_series` / `when` / `map_many` — `map_elements` is a method, riding
// along with `type Expr`).
// The `ClosedInterval` enum that names `is_between`'s `closed?` argument now
// lives in `@types` (the expression AST carries it, and the AST is below
// `expr`), so it is re-exported from there. The expression AST itself —
// `ExprNode` and its `BinOp` / `UnOp` / `AggOp` / `StrOp` tags — lives in the
// module-internal `internal/ir` package, unreachable downstream and named by
// no public API, so there is nothing to re-export for it. `@lazy` needs the
// `scan_csv` / `scan_ndjson` file sources, whose optional options parameters
// ride along with `@io`; its own entry point rides along with
// `type LazyFrame` as that type's constructor.

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
  type SortOrder,
  type NullOrder,
  type ClosedInterval,
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
/// `Series` lives in its own `@series` package (extracted in v0.5 so the
/// expression layer can build on the per-column unit); re-exporting the type
/// carries its constructors (`from_ints` / …) and methods along, so the facade
/// name `@moonframe.Series` is unchanged for callers.
pub using @series {type Series}

///|
pub using @frame {
  type DataFrame,
  type KeepStrategy,
  type JoinType,
  type JoinOptions,
  type HtmlOptions,
  numeric_cols,
  cols_of_dtype,
  cols_matching,
  cols_starts_with,
  cols_ends_with,
  cols_contains,
}

///|
pub using @io {
  type CsvReadOptions,
  type CsvWriteOptions,
  type JsonReadOptions,
  type OnParseError,
  type ChartKind,
  type ChartSpec,
  type VegaType,
  format_csv,
  format_json,
  format_ndjson,
  format_vega_lite,
  parse_csv_str,
  parse_json_str,
  parse_ndjson_str,
  read_csv,
  read_json,
  read_ndjson,
  write_csv,
  write_json,
  write_ndjson,
  write_vega_lite,
}

///|
pub using @lazy {type LazyFrame, scan_csv, scan_ndjson}
