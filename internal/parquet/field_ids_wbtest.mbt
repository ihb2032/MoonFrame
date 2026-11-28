// Whitebox tests of the field-id reading: what a table format laid over
// Parquet files identifies a column by, spelled on each schema element.

///|
test "a file's columns answer the field ids its schema elements name, and -1 where none is named" {
  let bytes = @fs.read_file_to_bytes(
    ".github/fixtures/parquet/field_ids.parquet",
  )
  assert_eq(parquet_field_ids(bytes), [("i", 1L), ("s", 2L), ("plain", -1L)])
}

///|
test "a file the library's own writer wrote names no field id" {
  let columns = [
    @series.Series::from_int_options("i", [Some(1), Some(2)]),
    @series.Series::from_string_options("s", [Some("a"), None]),
  ]
  let bytes = write_parquet_bytes(columns, ["i", "s"], Uncompressed)
  assert_eq(parquet_field_ids(bytes), [("i", -1L), ("s", -1L)])
}

///|
test "a file that is no parquet file refuses as a read of it does" {
  let junk = b"no parquet file at all"
  assert_true(
    (Ok(ignore(parquet_field_ids(junk))) catch { e => Err(e) })
    is Err(@types.DataError::ParseError(_)),
  )
}
