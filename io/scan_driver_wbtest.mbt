// Whitebox battery for the file-scan drivers: the drivers are
// package-private faces the lazy engine reaches only through the
// `LazyFrame::file_scan` seam, so the driver-level contracts — the whole-input
// checks a pruned read cannot skip, the batch's shape under a partial
// projection, the batch sequence itself — are pinned here rather than
// through a reader.

///|
/// Drain a driver's read as its batches, in order — the whitebox
/// spelling of what the engine's `execute_scan` walks.
fn batches_of(
  driver : @scan.ScanDriver,
  projection~ : Array[String]? = None,
  window~ : @scan.ScanWindow? = None,
) -> Array[@scan.ScanBatch] raise @types.DataError {
  let cursor = driver.batches(projection~, window~)
  let out : Array[@scan.ScanBatch] = []
  while true {
    match cursor.next() {
      Some(batch) => out.push(batch)
      None => break
    }
  }
  out
}

///|
test "the CSV scan driver forwards strict quote validation" {
  let path = "_build/io_csv_strict_quotes_driver.csv"
  @fs.write_string_to_file(path, "a,b\n1,\"unclosed")
  let scanned = Ok(
    ignore(
      batches_of(
        csv_scan_driver(
          path,
          CsvReadOptions::CsvReadOptions(strict_quotes=true),
        ),
        projection=Some(["a"]),
      ),
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
  let none_match = batches_of(driver, projection=Some(["nope"]))
  assert_eq(none_match.length(), 1)
  assert_eq((none_match[0].columns().length(), none_match[0].height()), (0, 3))
  // Partial-match leniency is untouched: the matched column, the same height.
  let partial = batches_of(driver, projection=Some(["b", "nope"]))
  assert_eq((partial[0].columns().length(), partial[0].height()), (1, 3))
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
    ignore(
      batches_of(
        csv_scan_driver(path, CsvReadOptions::CsvReadOptions()),
        projection=Some(["a"]),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(scanned is Err(@types.DataError::ParseError(_)))
}

///|
test "a textual cursor yields its one batch and exhausts" {
  // The text formats read whole and hand back one batch; the second
  // `next` answers `None`, the cursor's whole exhaustion contract.
  let path = "_build/io_csv_single_batch.csv"
  @fs.write_string_to_file(path, "a\n1\n2\n")
  let driver = csv_scan_driver(path, CsvReadOptions::CsvReadOptions())
  let all = batches_of(driver)
  assert_eq(all.length(), 1)
  assert_eq(all[0].height(), 2)
}

///|
test "a textual cursor applies an absorbed window after the read" {
  // The window a text source receives cuts the frame the read built —
  // the eager verbs' own arithmetic, spelled through the driver's
  // defensive application (the optimizer never sinks a window into a
  // text source, so this is the only path that reaches it).
  let path = "_build/io_csv_window.csv"
  @fs.write_string_to_file(path, "a\n1\n2\n3\n4\n5\n")
  let driver = csv_scan_driver(path, CsvReadOptions::CsvReadOptions())
  let head = batches_of(driver, window=Some(@scan.ScanWindow::Head(2)))
  assert_eq(head.length(), 1)
  assert_eq(head[0].height(), 2)
  assert_eq(head[0].columns()[0].to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  let tail = batches_of(driver, window=Some(@scan.ScanWindow::Tail(2)))
  assert_eq(tail[0].columns()[0].to_scalars(), [
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
  ])
  let sliced = batches_of(
    driver,
    window=Some(@scan.ScanWindow::Slice(1, Some(2))),
  )
  assert_eq(sliced[0].columns()[0].to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
  ])
  let to_end = batches_of(driver, window=Some(@scan.ScanWindow::Slice(3, None)))
  assert_eq(to_end[0].columns()[0].to_scalars(), [
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
  ])
}

///|
test "the parquet cursor walks a multi-group file group by group" {
  // A file written in row groups hands back one batch per group, the
  // rows in the groups' declared order — and an absorbed window skips
  // the groups outside it outright, cutting a group it only partly
  // covers.
  let frame = @frame.DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4, 5, 6]),
  ])
  let path = "_build/io_parquet_groups_driver.parquet"
  write_parquet(frame, path, row_group_rows=2)
  let driver = parquet_scan_driver(path)
  let all = batches_of(driver)
  assert_eq(all.length(), 3)
  assert_eq(all[0].height(), 2)
  assert_eq(all[0].columns()[0].to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(all[2].columns()[0].to_scalars(), [
    @types.Scalar::Int(5),
    @types.Scalar::Int(6),
  ])
  // A window covering rows [2, 5): the first group is skipped whole
  // (never decoded), the second covered whole, the third cut to its
  // one overlapping row.
  let windowed = batches_of(
    driver,
    window=Some(@scan.ScanWindow::Slice(2, Some(3))),
  )
  assert_eq(windowed.length(), 2)
  assert_eq(windowed[0].columns()[0].to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
  ])
  assert_eq(windowed[1].columns()[0].to_scalars(), [@types.Scalar::Int(5)])
  // An empty window skips every group but still answers the columns —
  // one zero-row batch over the schema, the `0×N` shape an eager
  // read-then-window yields.
  let empty = batches_of(driver, window=Some(@scan.ScanWindow::Head(0)))
  assert_eq(empty.length(), 1)
  assert_eq((empty[0].columns().length(), empty[0].height()), (1, 0))
  assert_eq(empty[0].columns()[0].dtype(), @types.DataType::Int)
}
