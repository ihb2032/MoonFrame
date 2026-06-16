// MoonFrame — facade package. Re-exports the public API from the
// four sub-packages so callers can `import "ihb2032/MoonFrame"` and
// access every symbol in one place. Sub-packages remain directly
// importable for callers who only need a slice of the surface (e.g.
// just `@types` for the value types).
//
// Note: the operator verbs (`select` / `drop` / `rename` /
// `with_column` / `replace_column` / `filter` / `with_columns` /
// `filter_where` / `sort_by` / `drop_nulls` /
// `drop_nulls_in` / `fill_null` / `null_count` / `count` / `sum` /
// `mean` / `min` / `max` / `describe` / `group_by` / `join` /
// `inner_join` / `left_join` / `right_join` / `outer_join` /
// `cross_join`) and the `to_markdown` / `to_html` renderers
// are now methods on `DataFrame`, so re-exporting `type DataFrame`
// makes them automatically reachable through the facade — there is
// nothing to list for them here. Likewise `GroupedDataFrame::agg`, the
// `JoinOptions` builders, the `HtmlOptions` builders, and the `ChartSpec`
// constructors come for free once their types are re-exported. Only the
// value types (including the GroupBy `GroupedDataFrame`, the Join
// `JoinType` / `JoinOptions`, the HTML `HtmlOptions`, and the Chart
// `ChartKind` / `ChartSpec`), the `@types` free functions
// (`compare_string_lex` / `is_decimal_int_literal`), and the `io` free
// functions need explicit re-export. The `@ops` package no longer exists
// (it was folded into `@frame`).
//
// The v0.4 expression / lazy layers follow the same rule. The `Expr`
// methods (`with_alias` / `cast` / `eq` / `sum` / …) and operator impls
// (`Add` / `Sub` / `Mul` / `Div` / `BitAnd` / `BitOr` / `Neg`) ride along
// with `type Expr`; the `LazyFrame` / `LazyGroupBy` methods (including the
// `LazyFrame::from` constructor) ride along with their types. So `@expr`
// needs explicit re-export only for the free constructors (`col` /
// `cols` / `lit` / `lit_int` / `lit_float` / `lit_str` / `lit_bool` /
// `when`) and the two builder types `WhenThen` / `WhenThenElse`; the
// `BinOp` / `UnOp` / `AggOp` tag enums are inert (no public API names
// them), so they are deliberately *not* re-exported. `@lazy` needs only
// `lazy_frame` (the
// free-function alias for `LazyFrame::from` — the bare identifier `lazy`
// is a reserved word, so the alias is spelled `lazy_frame`).

///|
pub using @types {
  type DataError,
  type DataType,
  type Scalar,
  type Field,
  type Schema,
  compare_string_lex,
  is_decimal_int_literal,
}

///|
pub using @column {
  type Bitmap,
  type BuiltinColumn,
  type ColumnData,
  type NumericColumn,
  type NumericData,
  type ColumnStorage,
  type StorageKind,
}

///|
pub using @expr {
  type Expr,
  type WhenThen,
  type WhenThenElse,
  col,
  cols,
  lit,
  lit_int,
  lit_float,
  lit_str,
  lit_bool,
  when,
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
  type RowView,
  type SortOrder,
  type NullOrder,
  type GroupedDataFrame,
  type JoinType,
  type JoinOptions,
  type HtmlOptions,
}

///|
pub using @io {
  type CsvReadOptions,
  type CsvWriteOptions,
  type JsonReadOptions,
  type NdjsonReadOptions,
  type OnParseError,
  type ChartKind,
  type ChartSpec,
  format_csv_str,
  format_json_records,
  format_ndjson,
  format_vega_lite,
  parse_csv_str,
  parse_json_records_str,
  parse_ndjson_str,
  read_csv,
  read_csv_with_options,
  read_json,
  read_json_with_options,
  read_ndjson,
  read_ndjson_with_options,
  write_csv,
  write_csv_with_options,
  write_json_records,
  write_ndjson,
  write_vega_lite,
}

///|
pub using @lazy {type LazyFrame, type LazyGroupBy, lazy_frame}
