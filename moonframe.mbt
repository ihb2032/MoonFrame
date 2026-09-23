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
// (`JoinOptions::on` / `left_on` / `cross`, `ChartSpec::bar` / `line` /
// `point` / `area`, and `HtmlOptions::HtmlOptions`) — come for free once their
// types are re-exported. The rule is that simple: **methods and constructors ride along
// with a re-exported type; type names and free functions still need an
// explicit line here.** So the lists below are the value types (the Join
// `JoinType` / `JoinOptions`, the HTML `HtmlOptions`, the Chart `ChartKind` /
// `ChartSpec`, …) plus every free function a caller reaches by name — the
// expression constructors, the frame's column selectors, the io layer's
// file-level readers and writers, the chart's spec export, and the lazy
// layer's file sources. The string-level
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
// The expression / lazy layers follow the same rule for inherent methods:
// `Expr::{with_alias,cast,eq,sum,...}` and the `LazyFrame` methods remain
// available with their re-exported types. Trait-backed dot methods are
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
// `WhenThenElse` (threaded through `when(c).then(a).otherwise(b)`) and
// `GroupedDataFrame` / `LazyGroupBy` (through `group_by(k).agg(e)`). Reaching
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
// there is nothing to re-export for it. The lazy layer needs
// the `scan_csv` / `scan_ndjson` file sources, whose optional options
// parameters ride along with the io layer; its own entry point rides along with
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
/// `Series` has its own package (extracted so the
/// expression layer can build on the per-column unit); re-exporting the type
/// carries its constructors (`from_ints` / …) and methods along, so the
/// facade name for `Series` is unchanged for callers.
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
  read_csv,
  read_json,
  read_ndjson,
  write_csv,
  write_json,
  write_ndjson,
}

///|
pub using @chart {
  type ChartKind,
  type ChartSpec,
  type VegaType,
  format_vega_lite,
  write_vega_lite,
}

///|
pub using @lazy {type LazyFrame, scan_csv, scan_ndjson}
