// Whitebox pins for the row cap: a cursor's coarse batches answer in
// row windows of the cap, order untouched, fine batches pass through.

///|
/// A cursor over fixed batches — the whole fixture, no source behind it.
fn batches_cursor(batches : Array[ScanBatch]) -> BatchCursor {
  let at : Array[Int32] = [0]
  BatchCursor::cursor(() => {
    let i = at[0]
    at[0] = i + 1
    batches.get(i)
  })
}

///|
test "a fine batch passes through the cap whole" {
  let small = ScanBatch::batch([@series.Series::from_ints("v", [1, 2, 3])], 3)
  let walked : Array[Int32] = []
  let cursor = batches_cursor([small]).capped(5)
  while true {
    match cursor.next() {
      Some(batch) => walked.push(batch.height())
      None => break
    }
  }
  assert_eq(walked, [3])
}

///|
test "a coarse batch answers in cap-sized row windows" {
  // Seven rows under a cap of three answer 3, 3, 1 — every window a
  // prefix-slice of the source's order, the cells reading straight
  // through.
  let coarse = ScanBatch::batch(
    [@series.Series::from_ints("v", [1, 2, 3, 4, 5, 6, 7])],
    7,
  )
  let heights : Array[Int32] = []
  let cells : Array[@types.Scalar] = []
  let cursor = batches_cursor([coarse]).capped(3)
  while true {
    match cursor.next() {
      Some(batch) => {
        heights.push(batch.height())
        for c in batch.columns()[0].to_scalars() {
          cells.push(c)
        }
      }
      None => break
    }
  }
  assert_eq(heights, [3, 3, 1])
  assert_eq(cells, [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
    @types.Scalar::Int(5),
    @types.Scalar::Int(6),
    @types.Scalar::Int(7),
  ])
  // A second coarse batch flows after the first's remainder.
  let two = batches_cursor([
    ScanBatch::batch([@series.Series::from_ints("v", [1, 2, 3, 4])], 4),
    ScanBatch::batch([@series.Series::from_ints("v", [9])], 1),
  ]).capped(3)
  let heights2 : Array[Int32] = []
  while true {
    match two.next() {
      Some(batch) => heights2.push(batch.height())
      None => break
    }
  }
  assert_eq(heights2, [3, 1, 1])
}

///|
test "an empty batch answers as itself under the cap" {
  let empty : ScanBatch = ScanBatch::batch([], 5)
  let heights : Array[Int32] = []
  let cursor = batches_cursor([empty]).capped(2)
  while true {
    match cursor.next() {
      Some(batch) => heights.push(batch.height())
      None => break
    }
  }
  // The `5×0` shape keeps its row count in windows of the cap — zero
  // columns carry it whole.
  assert_eq(heights, [2, 2, 1])
}
