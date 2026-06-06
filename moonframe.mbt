// MoonFrame — facade package. Re-exports the public API from the
// four sub-packages so callers can `import "ihb2032/MoonFrame"` and
// access every symbol in one place. Sub-packages remain directly
// importable for callers who only need a slice of the surface (e.g.
// just `@types` for the value types).
//
// Note: the operator verbs (`select` / `drop` / `rename` /
// `with_column` / `replace_column` / `filter` / `sort_by` /
// `drop_nulls` / `drop_nulls_in` / `fill_null` / `null_count` /
// `count` / `sum` / `mean` / `min` / `max` / `describe` / `group_by` /
// `join` / `inner_join` / `left_join` / `cross_join`) and the
// `to_markdown` / `to_html` renderers
// are now methods on `DataFrame`, so re-exporting `type DataFrame`
// makes them automatically reachable through the facade — there is
// nothing to list for them here. Likewise `GroupedDataFrame::agg`, the
// `AggSpec` constructors, the `JoinOptions` builders, the `HtmlOptions`
// builders, and the `ChartSpec` constructors come for free once their
// types are re-exported. Only the value types (including the GroupBy
// `AggKind` / `AggSpec` / `GroupedDataFrame`, the Join `JoinType` /
// `JoinOptions`, the HTML `HtmlOptions`, and the Chart `ChartKind` /
// `ChartSpec`) and the `io` free functions need explicit re-export.
// The `@ops` package no longer exists (it was folded into `@frame`).

///|
pub using @types {
  type DataError,
  type DataType,
  type Scalar,
  type Field,
  type Schema,
}

///|
pub using @column {type Bitmap, type BuiltinColumn, type ColumnData}

///|
pub using @frame {
  type Series,
  type DataFrame,
  type RowView,
  type SortOrder,
  type NullOrder,
  type AggKind,
  type AggSpec,
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
