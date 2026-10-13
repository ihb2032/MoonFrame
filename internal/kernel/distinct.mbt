// The occurrence family of the positional verbs — `unique_counts`,
// `is_first_distinct`, `is_last_distinct` — three readings of one pass
// over the column's key-normalised cells. Total over every dtype (the
// `KeyCell` normalisation `unique` / `group_by` / `join` share: `NaN` one
// bucket, `-0.0` folding into `+0.0`, a null an ordinary value), with
// nulls reporting their own bucket's statistics.

///|
/// The distinct-count and first/last-occurrence family's shared single
/// pass — occurrence counts and first / last positions per key, keyed by
/// the same `KeyCell` normalisation `unique` / `group_by` use (`NaN` one
/// bucket, `-0.0` folding into `+0.0`, a null an ordinary value). Total
/// over every dtype; nulls report their own bucket's statistics (a null
/// cell's count is the null count, and the first null is first-distinct).
fn distinct_pass(
  operand : Series,
) -> (
  Map[@series.KeyCell, Int64],
  Map[@series.KeyCell, Int32],
  Map[@series.KeyCell, Int32],
) {
  let n = operand.len()
  let cells = operand.to_scalars()
  let count : Map[@series.KeyCell, Int64] = Map([])
  let first_at : Map[@series.KeyCell, Int32] = Map([])
  let last_at : Map[@series.KeyCell, Int32] = Map([])
  for i in 0..<n {
    let k = @series.key_cell(cells[i])
    count[k] = count.get(k).unwrap_or(0L) + 1L
    if !first_at.contains(k) {
      first_at[k] = i
    }
    last_at[k] = i
  }
  (count, first_at, last_at)
}

///|
/// How many times each cell's own value occurs in the column (Polars'
/// `unique_counts`) — an `Int` per cell, in order.
fn eval_unique_counts(operand : Series) -> Series {
  let (count, _, _) = distinct_pass(operand)
  let cells = operand.to_scalars()
  let out : Array[Int64?] = cells.map(c => {
    Some(count.get(@series.key_cell(c)).unwrap_or(0L))
  })
  @series.Series::from_int_options(operand.name(), out)
}

///|
/// Whether each cell is its value's **first** occurrence (Polars'
/// `is_first_distinct`) — a `Bool` per cell.
fn eval_is_first_distinct(operand : Series) -> Series {
  let (_, first_at, _) = distinct_pass(operand)
  let cells = operand.to_scalars()
  let out : Array[Bool?] = Array::makei(cells.length(), i => {
    Some(first_at.get(@series.key_cell(cells[i])).unwrap_or(-1) == i)
  })
  @series.Series::from_bool_options(operand.name(), out)
}

///|
/// Whether each cell is its value's **last** occurrence (Polars'
/// `is_last_distinct`) — the trailing mirror of `eval_is_first_distinct`.
fn eval_is_last_distinct(operand : Series) -> Series {
  let (_, _, last_at) = distinct_pass(operand)
  let cells = operand.to_scalars()
  let out : Array[Bool?] = Array::makei(cells.length(), i => {
    Some(last_at.get(@series.key_cell(cells[i])).unwrap_or(-1) == i)
  })
  @series.Series::from_bool_options(operand.name(), out)
}
