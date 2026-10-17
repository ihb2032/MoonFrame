// The rolling half of the positional family — the seven windowed
// statistics (`rolling_sum` / `mean` / `min` / `max` / `std` /
// `variance` / `median`) over a trailing or centred window. The rules are
// the reduction family's verbatim, and so are the folds: every statistic
// below runs through the shared accumulations of `@numeric` (the extremum
// fold, the `Double` sum, Welford's variance), so a rule change there is a
// rule change here by construction, not a second implementation to keep
// in step. The NaN split, the fewer-than-two precedence, and the
// numeric-only dtype gate (the registry's word, never the buffer
// variant's — a `Date` riding `I64` raises) are pinned in the rolling
// tests beside the positional ones.

///|
/// Evaluate the rolling statistic over an operand column, keeping the
/// operand's name — the window bounds are this function's own; `valid` is
/// the caller's materialised validity (shared with the other positional
/// kernels' prologue). Raises `InvalidOperation` for a window below 1 or a
/// `min_samples` outside `[1, window]`, and `TypeMismatch` for a
/// non-numeric operand.
fn eval_rolling(
  operand : Series,
  valid : Array[Bool],
  stat : @ir.RollStat,
  window : Int32,
  min_samples : Int32?,
  center : Bool,
) -> Series raise @types.DataError {
  let name = operand.name()
  let dtype = operand.dtype()
  let n = operand.len()
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
    // The dtype registry decides numericity, not the buffer — a
    // non-numeric `I64` rider (`Date`) raises, like every numeric
    // kernel.
    @column.ColumnData::I64(a) if dtype.is_numeric() => {
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
        // Decide on a comparison that cannot overflow (`forward` near
        // `Int::MAX` and a large `i` would wrap `i + forward` negative) —
        // the `gather_every` idiom.
        let hi = if forward >= n - i { n - 1 } else { i + forward }
        let mut acc : Int64? = None
        let widened : Array[Double] = []
        let mut present_count = 0
        for j in lo..<=hi {
          if valid[j] {
            present_count = present_count + 1
            let v = a[j]
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
            } else {
              // Only the widening statistics read the widened cells —
              // Sum / Min / Max fold the Ints directly.
              widened.push(v.to_double())
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
        // Decide on a comparison that cannot overflow (`forward` near
        // `Int::MAX` and a large `i` would wrap `i + forward` negative) —
        // the `gather_every` idiom.
        let hi = if forward >= n - i { n - 1 } else { i + forward }
        let vals : Array[Double] = []
        let mut saw_nan = false
        let mut present_count = 0
        for j in lo..<=hi {
          if valid[j] {
            // Each present cell counts once, `NaN` included — the
            // count is over every present cell, the median kernel's
            // discipline.
            present_count = present_count + 1
            let v = a[j]
            if v.is_nan() {
              saw_nan = true
            } else {
              vals.push(v)
            }
          }
        }
        if present_count >= need {
          out[i] = float_rolling_stat(stat, vals, saw_nan, present_count)
        }
      }
      @series.Series::from_float_options(name, out)
    }
    @column.ColumnData::I64(_)
    | @column.ColumnData::Bool(_)
    | @column.ColumnData::Utf8(_) =>
      raise @types.DataError::TypeMismatch(
        @types.TypeMismatchDetail::Message(
          "rolling \{roll_stat_label(stat)} requires a numeric operand, got \{dtype}",
        ),
      )
  }
}

///|
/// The statistic over one window's present values — `vals` holds the
/// non-`NaN` cells, `saw_nan` whether a `NaN` was among the present, the
/// count every present cell (`NaN` included, the median kernel's
/// discipline). Returns `None` where the statistic has no value at all
/// (an all-`NaN` window under the extrema — nothing to skip to; a window
/// with fewer than two present cells under `std` / `variance` — no sample
/// denominator, so a lone `NaN` cell is `Null`, the reduction family's
/// precedence), `Some(NaN)` where a present `NaN` propagates (sum / mean /
/// std / variance / median — after the fewer-than-two rule), and the
/// computed value otherwise. The sums, extrema, and variance all fold
/// through `@numeric`'s shared primitives.
fn float_rolling_stat(
  stat : @ir.RollStat,
  vals : Array[Double],
  saw_nan : Bool,
  present_count : Int32,
) -> Double? {
  match stat {
    Sum | Mean => {
      let (s, _) = @numeric.fold_double_sum(vals.length(), k => vals[k], _ => {
        true
      })
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
      @numeric.fold_extremum(vals.length(), k => vals[k], _ => false, (v, b) => {
        if want_min {
          v < b
        } else {
          v > b
        }
      })
    }
    Std | Var =>
      // The fewer-than-two rule takes precedence over `NaN` propagation —
      // a lone present `NaN` cell is `Null`, not `NaN` (the reduction
      // family's order). Over two-plus cells the statistic is Welford's —
      // the same `fold_welford_m2` the reduce family folds, saturation
      // rescue included, so a window of near-`Double`-max values whose
      // two-pass mean would overflow still yields its finite variance.
      if present_count < 2 {
        None
      } else if saw_nan {
        Some(@double.not_a_number)
      } else {
        let (m2, cnt, _) = @numeric.fold_welford_m2(
          vals.length(),
          k => vals[k],
          _ => true,
        )
        let variance = m2 / (cnt - 1).to_double()
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
