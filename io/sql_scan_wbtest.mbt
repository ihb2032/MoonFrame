// Whitebox tests of the SQL scan's window: how each shape is read, and
// that every shape answers the rows its eager verb answers — the shapes
// the optimizer never sinks among them, since the driver takes any
// window the seam spells.

///|
/// moondb's own mock, answering the integers from `0` up to `count` in
/// one `c0` column.
fn mock_ints(count : Int32) -> @moondb.MockDriver raise @moondb.DbError {
  let db = @moondb.MockDriver::new()
  for k in 0..<count {
    ignore(db.execute("insert", [Int64(k.to_int64())]))
  }
  db
}

///|
/// Every batch the driver answers under `window`, stacked into the one
/// frame the batches make.
fn stacked(
  driver : @scan.ScanDriver,
  window : @scan.ScanWindow?,
) -> @frame.DataFrame raise @types.DataError {
  let cursor = driver.batches(window~)
  let mut answer : @frame.DataFrame? = None
  let mut done = false
  while !done {
    match cursor.next() {
      None => done = true
      Some(batch) => {
        let part = @frame.DataFrame::from_parts(batch.columns(), batch.height())
        answer = match answer {
          None => Some(part)
          Some(so_far) => Some(so_far.vstack(part))
        }
      }
    }
  }
  match answer {
    Some(frame) => frame
    None => @frame.DataFrame::from_parts([], 0)
  }
}

///|
/// A frame's rows under a window, by the eager verb of that shape.
fn windowed(
  frame : @frame.DataFrame,
  window : @scan.ScanWindow,
) -> @frame.DataFrame {
  match window {
    @scan.ScanWindow::Head(n) => frame.head(n)
    @scan.ScanWindow::Tail(n) => frame.tail(n)
    @scan.ScanWindow::Slice(offset, length) =>
      match length {
        Some(len) => frame.slice(offset, length=len)
        None => frame.slice(offset)
      }
  }
}

///|
test "a window is read by its row range up front, or against the answer's count" {
  assert_true(sql_window(None) is Range(0, 2147483647))
  assert_true(sql_window(Some(@scan.ScanWindow::Head(3))) is Range(0, 3))
  assert_true(sql_window(Some(@scan.ScanWindow::Head(-1))) is Counted(_))
  assert_true(
    sql_window(Some(@scan.ScanWindow::Slice(2, None))) is Range(2, 2147483647),
  )
  assert_true(
    sql_window(Some(@scan.ScanWindow::Slice(2, Some(3)))) is Range(2, 5),
  )
  // A length that would run past the last row ends there.
  assert_true(
    sql_window(Some(@scan.ScanWindow::Slice(10, Some(2147483647))))
    is Range(10, 2147483647),
  )
  assert_true(
    sql_window(Some(@scan.ScanWindow::Slice(2, Some(-1)))) is Counted(_),
  )
  assert_true(sql_window(Some(@scan.ScanWindow::Slice(-3, None))) is Counted(_))
  assert_true(sql_window(Some(@scan.ScanWindow::Tail(2))) is Counted(_))
}

///|
test "every window shape answers its eager verb's rows" {
  let windows : Array[@scan.ScanWindow] = [
    Head(3),
    Head(0),
    Head(-3),
    Head(100),
    Tail(2),
    Tail(0),
    Tail(-3),
    Tail(100),
    Slice(2, None),
    Slice(2, Some(3)),
    Slice(2, Some(0)),
    Slice(2, Some(-1)),
    Slice(-3, None),
    Slice(-3, Some(2)),
    Slice(-3, Some(-1)),
    Slice(20, Some(2)),
    Slice(0, Some(2147483647)),
  ]
  for window in windows {
    let db = mock_ints(10)
    let got = stacked(sql_scan_driver(db, "select", []), Some(window))
    assert_eq(got, windowed(read_sql(db, "select"), window))
  }
  // An answer of no row under any window is the empty frame.
  for window in windows {
    let db = mock_ints(0)
    let got = stacked(sql_scan_driver(db, "select", []), Some(window))
    assert_eq(got.shape(), (0, 0))
  }
}
