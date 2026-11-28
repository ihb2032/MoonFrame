// Whitebox pins for the ORC scan driver: the batches its cursor answers
// under a window and a projection, which the public lazy pipeline composes
// with the optimizer and so never shows one at a time.

///|
/// The heights of every batch a cursor answers.
fn orc_batch_heights(
  cursor : @scan.BatchCursor,
) -> Array[Int32] raise @types.DataError {
  let heights : Array[Int32] = []
  let mut going = true
  while going {
    match cursor.next() {
      Some(batch) => heights.push(batch.height())
      None => going = false
    }
  }
  heights
}

///|
test "the ORC scan driver answers one batch a stripe" {
  let path = ".github/fixtures/orc/reference/pyorc_stripes.orc"
  let cursor = orc_scan_driver(path).batches()
  assert_eq(orc_batch_heights(cursor), [10, 10, 10, 10, 10, 10])
  assert_eq(orc_scan_driver(path).label(), "ORC \"\{path}\"")
}

///|
test "the ORC scan driver skips the stripes outside a window and cuts the ones it reaches" {
  let path = ".github/fixtures/orc/reference/pyorc_stripes.orc"
  let driver = orc_scan_driver(path)
  // Rows 23 to 41: the third stripe keeps its last seven rows, the fourth
  // is whole, the fifth keeps its first.
  let cut = driver.batches(window=Some(@scan.ScanWindow::Slice(23, Some(18))))
  assert_eq(orc_batch_heights(cut), [7, 10, 1])
  // A head or a tail is a window too.
  let head = driver.batches(window=Some(@scan.ScanWindow::Head(23)))
  assert_eq(orc_batch_heights(head), [10, 10, 3])
  let tail = driver.batches(window=Some(@scan.ScanWindow::Tail(17)))
  assert_eq(orc_batch_heights(tail), [7, 10])
  // A window that names no row: one batch over the fields, of no row.
  let none = driver.batches(window=Some(@scan.ScanWindow::Head(0)))
  assert_eq(orc_batch_heights(none), [0])
  let past = driver.batches(window=Some(@scan.ScanWindow::Slice(60, Some(5))))
  assert_eq(orc_batch_heights(past), [0])
}

///|
test "the ORC scan driver keeps the rows under a projection naming no column" {
  let path = ".github/fixtures/orc/reference/pyorc_stripes.orc"
  let driver = orc_scan_driver(path)
  let cursor = driver.batches(projection=Some(["no_such_field"]))
  // A stripe's rows still answer — the `N×0` shape the text readers'
  // projections yield — and every stripe answers one.
  let heights : Array[Int32] = []
  let mut going = true
  while going {
    match cursor.next() {
      Some(batch) => {
        assert_eq(batch.columns().length(), 0)
        heights.push(batch.height())
      }
      None => going = false
    }
  }
  assert_eq(heights, [10, 10, 10, 10, 10, 10])
  // The empty window's one batch carries the fields: none here.
  let empty = driver.batches(
    projection=Some(["no_such_field"]),
    window=Some(@scan.ScanWindow::Head(0)),
  )
  match empty.next() {
    Some(batch) => {
      assert_eq(batch.columns().length(), 0)
      assert_eq(batch.height(), 0)
    }
    None => fail("the empty window answered no batch")
  }
  assert_true(empty.next() is None)
}

///|
test "the ORC scan driver's empty batch carries the projected fields" {
  let path = ".github/fixtures/orc/reference/pyorc_stripes.orc"
  let driver = orc_scan_driver(path)
  let cursor = driver.batches(
    projection=Some(["f", "b"]),
    window=Some(@scan.ScanWindow::Head(0)),
  )
  match cursor.next() {
    Some(batch) => {
      assert_eq(batch.columns().map(column => column.name()), ["f", "b"])
      assert_eq(batch.height(), 0)
    }
    None => fail("the empty window answered no batch")
  }
  // Past the end the same: the fields, no row.
  let past = driver.batches(window=Some(@scan.ScanWindow::Slice(60, None)))
  match past.next() {
    Some(batch) => {
      assert_eq(batch.columns().length(), 4)
      assert_eq(batch.height(), 0)
    }
    None => fail("a window past the end answered no batch")
  }
  assert_true(past.next() is None)
}
