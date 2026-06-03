// MoonFrame — facade package. Re-exports the v0.2 public API from the
// four sub-packages so callers can `import "ihb2032/MoonFrame"` and
// access every symbol in one place. Sub-packages remain directly
// importable for callers who only need a slice of the surface (e.g.
// just `@types` for the value types).
//
// v0.2 note: the operator verbs (`select` / `drop` / `rename` /
// `with_column` / `replace_column` / `filter` / `sort_by` /
// `drop_nulls` / `drop_nulls_in` / `fill_null` / `null_count` /
// `count` / `sum` / `mean` / `min` / `max` / `describe`) and the
// `to_markdown` renderers are now methods on `DataFrame`, so
// re-exporting `type DataFrame` makes them automatically reachable
// through the facade — there is nothing to list for them here. Only
// the value types and the `io` free functions need explicit
// re-export. The `@ops` package no longer exists (it was folded into
// `@frame`).

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
}

///|
pub using @io {
  type CsvReadOptions,
  type CsvWriteOptions,
  type JsonReadOptions,
  format_csv_str,
  format_json_records,
  parse_csv_str,
  parse_json_records_str,
  read_csv,
  read_csv_with_options,
  read_json,
  read_json_with_options,
  write_csv,
  write_csv_with_options,
  write_json_records,
}
