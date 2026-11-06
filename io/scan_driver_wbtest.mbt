// Whitebox battery for the file-scan drivers: the drivers are
// package-private faces the lazy engine reaches only through the
// `LazyFrame::file_scan` seam, so the driver-level contracts — the whole-input
// checks a pruned read cannot skip, the batch's shape under a partial
// projection — are pinned here rather than through a reader.

///|
test "the CSV scan driver forwards strict quote validation" {
  let path = "_build/io_csv_strict_quotes_driver.csv"
  @fs.write_string_to_file(path, "a,b\n1,\"unclosed")
  let scanned = Ok(
    csv_scan_driver(path, CsvReadOptions::CsvReadOptions(strict_quotes=true)).scan(
      projection=Some(["a"]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(scanned is Err(@types.DataError::ParseError(_)))
}

///|
test "a projection matching no header reads the rows and no columns" {
  // Building zero columns used to lose the file's height, so the reader had to
  // fall back to materialising every column instead. The `N×0` frame carries
  // the row count on its own, so nothing unrelated is inferred or parsed.
  let path = "_build/io_csv_zero_match_projection.csv"
  @fs.write_string_to_file(path, "a,b\n1,x\n2,y\n3,z")
  let opts = CsvReadOptions::CsvReadOptions()
  // Through the driver face the lazy engine reads: the batch keeps the row
  // count on its own, so nothing unrelated is inferred or parsed.
  let driver = csv_scan_driver(path, opts)
  let none_match = driver.scan(projection=Some(["nope"]))
  assert_eq((none_match.columns().length(), none_match.height()), (0, 3))
  // Partial-match leniency is untouched: the matched column, the same height.
  let partial = driver.scan(projection=Some(["b", "nope"]))
  assert_eq((partial.columns().length(), partial.height()), (1, 3))
}

///|
test "the scan driver refuses a file that is not UTF-8 before any pruning" {
  // A Latin-1 byte (0xEF) is a 3-byte UTF-8 sequence lead whose followers
  // are not continuation bytes: a lenient decoder merges it with the bytes
  // after it — swallowing the delimiter and shifting every cell boundary.
  // The read refuses instead of returning confidently wrong data, and the
  // refusal happens before any projection or pruning, so the lazy path
  // cannot bypass it.
  let path = "_build/io_csv_not_utf8_driver.csv"
  @fs.write_bytes_to_file(path, b"na\xEFve,field\n1,2\n")
  let scanned = Ok(
    csv_scan_driver(path, CsvReadOptions::CsvReadOptions()).scan(
      projection=Some(["a"]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(scanned is Err(@types.DataError::ParseError(_)))
}

///|
test "the rider probes read the dtypes pins they answer for" {
  // The two probes the scan builders hand the file_scan seam answer one
  // question each — may this read carry a decimal column, may it carry a
  // temporal one — and a text read carries either family only through a
  // pin (its inference never picks a rider). `Duration` has no text
  // parser at all, so no pin can name one and the temporal probe stays
  // false beside a `Date` / `Timestamp` pin that raises it.
  let plain = CsvReadOptions::CsvReadOptions().dtypes()
  assert_false(pins_decimal(plain))
  assert_false(pins_temporal(plain))
  let decimal_pin = CsvReadOptions::CsvReadOptions(
    dtypes=Map([("d", @types.DataType::Decimal(2))]),
  ).dtypes()
  assert_true(pins_decimal(decimal_pin))
  assert_false(pins_temporal(decimal_pin))
  let temporal_pin = CsvReadOptions::CsvReadOptions(
    dtypes=Map([("t", @types.DataType::Timestamp)]),
  ).dtypes()
  assert_false(pins_decimal(temporal_pin))
  assert_true(pins_temporal(temporal_pin))
}
