// The positional transforms — the expression ops whose output cell at row
// `i` reads the operand's cells at other rows: `shift` (SQL `LAG` / `LEAD`),
// the `cum_*` running aggregates, `rank`, and `arg_sort`. One kernel per
// `@ir.PositionalOp`, all reading the operand's typed buffer plus its
// validity directly (no per-cell `Scalar` boxing except where the output is
// itself heterogeneous — `shift`, whose fill value is a `Scalar`).
//
// Shared contracts, mirroring the family's documented rules:
//   - a **null** slot in the operand stays a null slot in the output for
//     every op (`shift` vacates with the fill or a null; the `cum_*`
//     aggregates skip a null without disturbing the running value;
//     `rank` leaves nulls unranked; `arg_sort` permutes the nulls' own
//     indices per `nulls_last`);
//   - `NaN` is a value: it propagates through `cum_sum` / `cum_prod` once
//     it enters, is skipped by `cum_min` / `cum_max` (the extrema rule),
//     and ranks past every other value (the total order `sort` uses);
//   - `rank` / `arg_sort` order over every dtype's natural order (`Bool`
//     `false < true`, `String` lexicographic); the `cum_*` family is
//     numeric-only (arithmetic and the numeric running extrema), one
//     contract to document rather than four;
//   - `reverse` runs a `cum_*` from the end, and ties under `rank` /
//     `arg_sort` keep input order (stability, the sort kernel's rule).

///|
/// Evaluate one positional transform over an operand column, keeping the
/// operand's name (the naming verb renames through `output_name`). Raises
/// `TypeMismatch` for the numeric-only members on a non-numeric operand,
/// and for a `shift` fill whose dtype differs from the operand's.
pub fn eval_positional(
  op : @ir.PositionalOp,
  operand : Series,
) -> Series raise @types.DataError {
  let name = operand.name()
  let dtype = operand.dtype()
  let n = operand.len()
  let valid = operand.validity_bools()
  match op {
    @ir.PositionalOp::Shift(k, fill) => {
      // The fill must type like the operand it slots into; `Null` is the
      // plain-gap spelling and passes untouched.
      if !fill.is_null() && fill.dtype() != dtype {
        raise @types.DataError::TypeMismatch(
          @types.TypeMismatchDetail::Message(
            "shift fill \{fill} does not type like the \{dtype} operand",
          ),
        )
      }
      let cells = operand.to_scalars()
      // Position `i` reads `i - k`: a positive `k` is `LAG` (the value
      // lands `k` rows below), a negative one `LEAD`; `k = 0` is identity.
      // Out-of-range reads take the fill.
      let out : Array[@types.Scalar] = Array::makei(n, i => {
        let src = i - k
        if src >= 0 && src < n {
          cells[src]
        } else {
          fill
        }
      })
      @series.scalars_to_series(dtype, name, out)
    }
    @ir.PositionalOp::CumSum(reverse)
    | @ir.PositionalOp::CumProd(reverse)
    | @ir.PositionalOp::CumMin(reverse)
    | @ir.PositionalOp::CumMax(reverse) => {
      let want_sum = op is @ir.PositionalOp::CumSum(_)
      let want_prod = op is @ir.PositionalOp::CumProd(_)
      let want_min = op is @ir.PositionalOp::CumMin(_)
      // The label names the arithmetic / extremum member that raised — only
      // the four `cum_*` members reach the numeric-only raise below.
      let label = if want_sum {
        "sum"
      } else if want_prod {
        "product"
      } else if want_min {
        "min"
      } else {
        "max"
      }
      match operand.storage().data() {
        @column.ColumnData::I64(a) => {
          let out : Array[Int64?] = Array::makei(n, _ => None)
          let mut acc : Int64? = None
          visit(n, reverse, i => {
            if valid[i] {
              let v = a[i]
              acc = Some(
                match acc {
                  Some(b) =>
                    if want_sum {
                      b + v
                    } else if want_prod {
                      b * v
                    } else if want_min {
                      if v < b {
                        v
                      } else {
                        b
                      }
                    } else if v > b {
                      v
                    } else {
                      b
                    }
                  None => v
                },
              )
            }
            // A null slot keeps its null — only `cum_count` repeats the
            // running value across a gap.
            out[i] = if valid[i] { acc } else { None }
          })
          @series.Series::from_int_options(name, out)
        }
        @column.ColumnData::F64(a) => {
          let out : Array[Double?] = Array::makei(n, _ => None)
          let mut acc : Double? = None
          visit(n, reverse, i => {
            if valid[i] {
              let v = a[i]
              // `NaN` enters a running sum / product and stays (the `sum`
              // rule); the running extrema skip it (`min` / `max` — and a
              // skipped `NaN` never reaches the accumulator, so the
              // accumulator is never one).
              acc = Some(
                match acc {
                  Some(b) =>
                    if want_sum {
                      b + v
                    } else if want_prod {
                      b * v
                    } else if v.is_nan() {
                      b
                    } else if want_min {
                      if v < b {
                        v
                      } else {
                        b
                      }
                    } else if v > b {
                      v
                    } else {
                      b
                    }
                  None => v
                },
              )
            }
            // The Int arm's rule: a null slot keeps its null.
            out[i] = if valid[i] { acc } else { None }
          })
          @series.Series::from_float_options(name, out)
        }
        @column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_) =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "cumulative \{label} requires a numeric operand, got \{dtype}",
            ),
          )
      }
    }
    @ir.PositionalOp::CumCount(reverse) => {
      // Dtype-blind: the running non-null count, a null slot repeating the
      // count the prior cell reached (Polars: `[x, k, None, d]` → 1, 2, 2, 3).
      let out : Array[Int64?] = Array::makei(n, _ => None)
      let mut seen : Int64 = 0
      visit(n, reverse, i => {
        if valid[i] {
          seen = seen + 1
        }
        out[i] = Some(seen)
      })
      @series.Series::from_int_options(name, out)
    }
    @ir.PositionalOp::Rank(how, descending) => {
      // Rank the non-null cells: their positions sorted by value (input
      // order among equals), then one walk over the tie groups. The group
      // spanning sorted slots `[a, b)` carries each method's answer.
      let sorted = sorted_positions(operand, descending)
      let m = sorted.length()
      // One output slot per original position; nulls stay null.
      let int_out : Array[Int64?] = Array::makei(n, _ => None)
      let float_out : Array[Double?] = Array::makei(n, _ => None)
      let same = value_equality(operand)
      let mut dense : Int64 = 0
      let mut a = 0
      while a < m {
        let mut b = a + 1
        while b < m && same(sorted[a], sorted[b]) {
          b = b + 1
        }
        dense = dense + 1
        match how {
          Average => {
            let avg = (a + 1 + b).to_double() / 2.0
            for k in a..<b {
              float_out[sorted[k]] = Some(avg)
            }
          }
          Min =>
            for k in a..<b {
              int_out[sorted[k]] = Some((a + 1).to_int64())
            }
          Max =>
            for k in a..<b {
              int_out[sorted[k]] = Some(b.to_int64())
            }
          Dense =>
            for k in a..<b {
              int_out[sorted[k]] = Some(dense)
            }
          // Input order among equals: the sort's index tiebreak means the
          // group's positional order already is input order.
          Ordinal =>
            for k in a..<b {
              int_out[sorted[k]] = Some((k + 1).to_int64())
            }
        }
        a = b
      }
      match how {
        Average => @series.Series::from_float_options(name, float_out)
        Min | Max | Dense | Ordinal =>
          @series.Series::from_int_options(name, int_out)
      }
    }
    @ir.PositionalOp::ArgSort(descending, nulls_last) => {
      // The stable permutation: non-null positions sorted by value (input
      // order among equals), the null positions' own indices placed per
      // `nulls_last` — `false` mirroring the sort kernel's nulls-first
      // default.
      let sorted = sorted_positions(operand, descending)
      let nulls : Array[Int] = []
      for i in 0..<n {
        if !valid[i] {
          nulls.push(i)
        }
      }
      let out : Array[Int64] = []
      if !nulls_last {
        for i in nulls {
          out.push(i.to_int64())
        }
      }
      for p in sorted {
        out.push(p.to_int64())
      }
      if nulls_last {
        for i in nulls {
          out.push(i.to_int64())
        }
      }
      @series.Series::from_ints(name, out)
    }
    @ir.PositionalOp::UniqueCounts => eval_unique_counts(operand)
    @ir.PositionalOp::IsFirstDistinct => eval_is_first_distinct(operand)
    @ir.PositionalOp::IsLastDistinct => eval_is_last_distinct(operand)
    @ir.PositionalOp::ForwardFill(limit)
    | @ir.PositionalOp::BackwardFill(limit) => {
      // Directional fill, Polars' `fill_null(strategy='forward' /
      // 'backward')` core: a null slot takes the nearest present value in
      // the fill's direction, at most `limit` consecutive slots past it
      // (`None` = unlimited — a gap longer than the limit keeps its tail
      // null). Dtype-generic — the values copied are the operand's own
      // cells, whatever they are.
      let backward = op is @ir.PositionalOp::BackwardFill(_)
      match limit {
        Some(k) =>
          if k < 1 {
            raise @types.DataError::InvalidOperation(
              "fill limit must be at least 1",
            )
          }
        None => ()
      }
      let cells = operand.to_scalars()
      let out : Array[@types.Scalar] = Array::makei(n, _ => @types.Scalar::Null)
      for i in 0..<n {
        if valid[i] {
          out[i] = cells[i]
        } else {
          // Walk toward the fill's source until a present cell or the
          // limit: `steps` counts consecutive null slots crossed.
          let step = if backward { 1 } else { -1 }
          let mut j = i + step
          let mut steps = 0
          let mut filled : @types.Scalar? = None
          while j >= 0 && j < n {
            if valid[j] {
              filled = Some(cells[j])
              break
            }
            steps = steps + 1
            match limit {
              Some(k) => if steps >= k { break }
              None => ()
            }
            j = j + step
          }
          match filled {
            Some(v) => out[i] = v
            None => ()
          }
        }
      }
      @series.scalars_to_series(dtype, name, out)
    }
    @ir.PositionalOp::Rolling(stat, window, min_samples, center) => {
      // Validate once, before any window work: the trailing / centred
      // window itself is total over the remaining arguments.
      if window < 1 {
        raise @types.DataError::InvalidOperation(
          "rolling window must be at least 1",
        )
      }
      let need = match min_samples {
        Some(k) => {
          if k < 1 || k > window {
            raise @types.DataError::InvalidOperation(
              "rolling min_samples must lie in [1, window]",
            )
          }
          k
        }
        None => window
      }
      // The label sits at the window's end (`center = false`, the trailing
      // window) or at its middle — `floor(window / 2)` cells before the
      // label, the rest after (the pandas / Polars centring: a 4-wide
      // window spans [i-2, i+1]).
      let back = if center { window / 2 } else { window - 1 }
      let forward = window - 1 - back
      match operand.storage().data() {
        @column.ColumnData::I64(a) => {
          // Sum / Min / Max keep the Int dtype (the reduction family's
          // rule); the statistics widen to Double, folding the widened
          // values the Float arm shares with — an `Int` window has no `NaN`,
          // so its `saw_nan` is always false.
          let int_out : Array[Int64?] = Array::makei(n, _ => None)
          let float_out : Array[Double?] = Array::makei(n, _ => None)
          let keep_int = stat is @ir.RollStat::Sum ||
            stat is @ir.RollStat::Min ||
            stat is @ir.RollStat::Max
          for i in 0..<n {
            let lo = if i - back < 0 { 0 } else { i - back }
            let hi = if i + forward >= n { n - 1 } else { i + forward }
            let mut acc : Int64? = None
            let widened : Array[Double] = []
            let mut present_count = 0
            for j in lo..<=hi {
              if valid[j] {
                present_count = present_count + 1
                let v = a[j]
                widened.push(v.to_double())
                if keep_int {
                  acc = Some(
                    match acc {
                      Some(b) =>
                        match stat {
                          Sum => b + v
                          Min => if v < b { v } else { b }
                          _ => if v > b { v } else { b }
                        }
                      None => v
                    },
                  )
                }
              }
            }
            if present_count >= need {
              if keep_int {
                int_out[i] = acc
              } else {
                float_out[i] = float_rolling_stat(
                  stat, widened, false, present_count,
                )
              }
            }
          }
          if keep_int {
            @series.Series::from_int_options(name, int_out)
          } else {
            @series.Series::from_float_options(name, float_out)
          }
        }
        @column.ColumnData::F64(a) => {
          // A NaN is a value: it satisfies `min_samples` and propagates
          // through Sum / Mean / Std / Var / Median (the reduction family's
          // rules), while Min / Max skip it.
          let out : Array[Double?] = Array::makei(n, _ => None)
          for i in 0..<n {
            let lo = if i - back < 0 { 0 } else { i - back }
            let hi = if i + forward >= n { n - 1 } else { i + forward }
            let vals : Array[Double] = []
            let mut saw_nan = false
            for j in lo..<=hi {
              if valid[j] {
                let v = a[j]
                if v.is_nan() {
                  saw_nan = true
                } else {
                  vals.push(v)
                }
              }
            }
            // NaN counts toward `min_samples` (it is present), so the count
            // is over every present cell — the median kernel's discipline.
            let present_count = {
              let mut c = vals.length()
              if saw_nan {
                c = c + 1
              }
              c
            }
            if present_count >= need {
              out[i] = float_rolling_stat(stat, vals, saw_nan, present_count)
            }
          }
          @series.Series::from_float_options(name, out)
        }
        @column.ColumnData::Bool(_) | @column.ColumnData::Utf8(_) =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "rolling \{roll_stat_label(stat)} requires a numeric operand, got \{dtype}",
            ),
          )
      }
    }
  }
}

///|
/// The statistic over one window's present values — `vals` holds the
/// non-`NaN` cells, `saw_nan` whether a `NaN` was among the present, the
/// count every present cell (`NaN` included, the median kernel's
/// discipline). Returns `None` where the statistic has no value at all
/// (an all-`NaN` window under the extrema — nothing to skip to; a
/// single-value window under `std` / `variance` — no sample denominator,
/// the reduction family's Null rule), `Some(NaN)` where a present `NaN`
/// propagates (sum / mean / std / variance / median), and the computed
/// value otherwise.
fn float_rolling_stat(
  stat : @ir.RollStat,
  vals : Array[Double],
  saw_nan : Bool,
  present_count : Int,
) -> Double? {
  match stat {
    Sum | Mean => {
      let mut s = 0.0
      for v in vals {
        s = s + v
      }
      if saw_nan {
        Some(@double.not_a_number)
      } else if stat is Mean {
        Some(s / present_count.to_double())
      } else {
        Some(s)
      }
    }
    // The extrema skip `NaN`, so `vals` alone is the candidate set; an
    // empty one is the no-value window.
    Min | Max => {
      let want_min = stat is Min
      let mut best : Double? = None
      for v in vals {
        best = Some(
          match best {
            Some(b) =>
              if want_min {
                if v < b {
                  v
                } else {
                  b
                }
              } else if v > b {
                v
              } else {
                b
              }
            None => v
          },
        )
      }
      best
    }
    Std | Var =>
      if saw_nan {
        Some(@double.not_a_number)
      } else if vals.length() < 2 {
        None
      } else {
        let m = {
          let mut s = 0.0
          for v in vals {
            s = s + v
          }
          s / vals.length().to_double()
        }
        let mut m2 = 0.0
        for v in vals {
          m2 = m2 + (v - m) * (v - m)
        }
        let variance = m2 / (vals.length() - 1).to_double()
        Some(if stat is Std { variance.sqrt() } else { variance })
      }
    Median =>
      if saw_nan {
        Some(@double.not_a_number)
      } else {
        vals.sort()
        let m = vals.length()
        Some(
          if m % 2 == 1 {
            vals[m / 2]
          } else {
            let lo = vals[m / 2 - 1]
            let hi = vals[m / 2]
            // The median kernel's overflow rule: two near-`Double`-max
            // middles overflow their sum before the halving, so halve first.
            let sum = lo + hi
            if sum.is_inf() {
              lo / 2.0 + hi / 2.0
            } else {
              sum / 2.0
            }
          },
        )
      }
  }
}

///|
/// The lowercase statistic name for a `TypeMismatch` message.
fn roll_stat_label(stat : @ir.RollStat) -> String {
  match stat {
    Sum => "sum"
    Mean => "mean"
    Min => "min"
    Max => "max"
    Std => "std"
    Var => "variance"
    Median => "median"
  }
}

///|
/// Visit the `n` positions in running order — ascending, or from the end
/// under `reverse` — applying `step` at each. The `cum_*` kernels' one
/// shared traversal.
fn visit(n : Int, reverse : Bool, step : (Int) -> Unit) -> Unit {
  if reverse {
    for i = n - 1; i >= 0; i = i - 1 {
      step(i)
    }
  } else {
    for i in 0..<n {
      step(i)
    }
  }
}

///|
/// The non-null positions of the operand sorted by their values under the
/// operand's own backend order (the total order for `Float` — `NaN` past
/// every value — `Bool` `false < true`, `String` lexicographic),
/// `descending` flipping it, ties broken by input index so equals keep
/// input order and the permutation is deterministic.
fn sorted_positions(operand : Series, descending : Bool) -> Array[Int] {
  let valid = operand.validity_bools()
  let positions : Array[Int] = []
  for i in 0..<operand.len() {
    if valid[i] {
      positions.push(i)
    }
  }
  let cmp = value_comparator(operand)
  positions.sort_by((x, y) => {
    let c = if descending { -cmp(x, y) } else { cmp(x, y) }
    // Ties keep input order under both directions: the index tiebreak is
    // never flipped.
    if c != 0 {
      c
    } else {
      x - y
    }
  })
  positions
}

///|
/// `-1 / 0 / 1` over the values at two positions, under the operand's
/// backend order, `descending` flipping the sign. Total — every backend
/// carries an order.
fn value_comparator(operand : Series) -> (Int, Int) -> Int {
  match operand.storage().data() {
    @column.ColumnData::I64(a) =>
      (i, j) => if a[i] < a[j] { -1 } else if a[i] > a[j] { 1 } else { 0 }
    @column.ColumnData::F64(a) =>
      (i, j) => @numeric.cmp_double_total(a[i], a[j])
    @column.ColumnData::Bool(a) =>
      (i, j) => if !a[i] && a[j] { -1 } else if a[i] && !a[j] { 1 } else { 0 }
    @column.ColumnData::Utf8(a) =>
      (i, j) => @text.compare_string_lex(a.get(i), a.get(j))
  }
}

///|
/// Whether the values at two positions are equal under the backend order —
/// the tie test `rank`'s group walk runs.
fn value_equality(operand : Series) -> (Int, Int) -> Bool {
  let cmp = value_comparator(operand)
  (i, j) => cmp(i, j) == 0
}

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
  Map[@series.KeyCell, Int],
  Map[@series.KeyCell, Int],
) {
  let n = operand.len()
  let cells = operand.to_scalars()
  let count : Map[@series.KeyCell, Int64] = Map([])
  let first_at : Map[@series.KeyCell, Int] = Map([])
  let last_at : Map[@series.KeyCell, Int] = Map([])
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
