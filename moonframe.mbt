// MoonFrame — facade package. Re-exports the v0.1 public API from the
// five sub-packages so callers can `import "ihb2032/MoonFrame"` and
// access every symbol in one place. Sub-packages remain directly
// importable for callers who only need a slice of the surface (e.g.
// just `@types` for the value types).

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
pub using @frame {type Series, type DataFrame, type RowView}

///|
pub using @ops {
  type SortOrder,
  type NullOrder,
  type SortSpec,
  count,
  describe,
  drop,
  drop_nulls,
  drop_nulls_in,
  fill_null,
  filter,
  filter_try,
  max,
  mean,
  min,
  null_count,
  rename,
  replace_column,
  select,
  sort_by,
  sort_by_many,
  sum,
  with_column,
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
  to_markdown,
  to_markdown_with_limit,
  write_csv,
  write_csv_with_options,
  write_json_records,
}
