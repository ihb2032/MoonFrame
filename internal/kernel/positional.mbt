// The positional transforms — the expression ops whose output cell at row
// `i` reads the operand's cells at other rows: `shift` (SQL `LAG` / `LEAD`),
// the `cum_*` running aggregates, `rank`, and `arg_sort` (the windowed
// statistics and the occurrence family carry their own contracts where
// they live). One kernel per `@ir.PositionalOp`, all reading the
// operand's typed buffer plus its validity directly (no per-cell `Scalar`
// boxing except where the output is itself heterogeneous — `shift`, whose
// fill value is a `Scalar`).
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
//     contract to document rather than four — and numericity comes from
//     the dtype registry, never the buffer variant: a `Date` rides `I64`
//     and `raise`s here exactly as `reduce_arith` `raise`s, because an
//     arm that folds by variant alone swallows the rider;
//   - `Int` arithmetic wraps — a running `cum_sum` / `cum_prod` crossing
//     `Int64::MAX` goes negative silently, `fold_int64_sum`'s documented
//     price, carried by this family too;
//   - `reverse` runs a `cum_*` from the end, and ties under `rank` /
//     `arg_sort` keep input order (stability, the sort kernel's rule).

///|
/// One `cum_*` fold step over the accumulator — the arithmetic / extremum
/// member the three flags name, written once for the `I64` and `F64` arms
/// so the folding rule has one home (the `F64` arm's `NaN` gate stays at
/// its call site: it guards the seed too, before any fold runs).
fn[T : Add + Mul + Compare] cum_step(
  want_sum : Bool,
  want_prod : Bool,
  want_min : Bool,
  acc : T?,
  v : T,
) -> T {
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
  }
}

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
        // The dtype registry decides numericity, not the buffer: an `I64`
        // column without this guard is a non-numeric rider (`Date`), whose
        // day counts must not fold.
        @column.ColumnData::I64(a) if dtype.is_numeric() => {
          let out : Array[Int64?] = Array::makei(n, _ => None)
          let mut acc : Int64? = None
          visit(n, reverse, i => {
            if valid[i] {
              acc = Some(cum_step(want_sum, want_prod, want_min, acc, a[i]))
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
              // rule); the running extrema skip it — as the accumulator's
              // seed too, not only as a later candidate, so a leading `NaN`
              // leaves the running value null (an empty prefix, the extrema
              // over nothing) instead of poisoning every later comparison
              // against a `NaN` accumulator.
              if !(!want_sum && !want_prod && v.is_nan()) {
                acc = Some(cum_step(want_sum, want_prod, want_min, acc, v))
              }
            }
            // The Int arm's rule: a null slot keeps its null.
            out[i] = if valid[i] { acc } else { None }
          })
          @series.Series::from_float_options(name, out)
        }
        @column.ColumnData::I64(_)
        | @column.ColumnData::Bool(_)
        | @column.ColumnData::Utf8(_) =>
          raise @types.DataError::TypeMismatch(
            @types.TypeMismatchDetail::Message(
              "cumulative \{label} requires a numeric operand, got \{dtype}",
            ),
          )
      }
    }
    @ir.PositionalOp::CumCount(reverse) => {
      // Dtype-blind: the running non-null count, a null slot repeating the
      // count the prior cell reached (`[x, k, None, d]` → 1, 2, 2, 3).
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
      // One output slot per original position; nulls stay null. Only
      // `Average` ranks as `Float` — every other method is `Int`, so each
      // pass allocates exactly the buffer it will fill.
      let average = how is Average
      let int_out : Array[Int64?] = if average {
        []
      } else {
        Array::makei(n, _ => None)
      }
      let float_out : Array[Double?] = if average {
        Array::makei(n, _ => None)
      } else {
        []
      }
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
            // The mean of the tie-group's first and last ranks in `Int64`:
            // the last group of a 2^30-cell column reaches 2^31 in `Int32`
            // and would wrap to a negative rank.
            let avg = (a.to_int64() + 1L + b.to_int64()).to_double() / 2.0
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
      let nulls : Array[Int32] = []
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
      // Directional fill: a null slot takes the nearest present value in
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
      // One pass per direction, carrying the nearest present value and the
      // consecutive-null count since it — the walk a per-cell scan would
      // redo, done once. A gap of `g` null slots fills when `g <= limit`
      // (the nulls between the source and the target are `g`), always when
      // there is no limit.
      if backward {
        let mut next : @types.Scalar? = None
        let mut gap = 0
        for i = n - 1; i >= 0; i = i - 1 {
          if valid[i] {
            out[i] = cells[i]
            next = Some(cells[i])
            gap = 0
          } else {
            gap = gap + 1
            match (next, limit) {
              (Some(v), None) => out[i] = v
              (Some(v), Some(k)) => if gap <= k { out[i] = v }
              (None, _) => ()
            }
          }
        }
      } else {
        let mut last : @types.Scalar? = None
        let mut gap = 0
        for i in 0..<n {
          if valid[i] {
            out[i] = cells[i]
            last = Some(cells[i])
            gap = 0
          } else {
            gap = gap + 1
            match (last, limit) {
              (Some(v), None) => out[i] = v
              (Some(v), Some(k)) => if gap <= k { out[i] = v }
              (None, _) => ()
            }
          }
        }
      }
      @series.scalars_to_series(dtype, name, out)
    }
    @ir.PositionalOp::Rolling(stat, window, min_samples, center) =>
      eval_rolling(operand, valid, stat, window, min_samples, center)
  }
}

///|
/// Visit the `n` positions in running order — ascending, or from the end
/// under `reverse` — applying `step` at each. The `cum_*` kernels' one
/// shared traversal.
fn visit(n : Int32, reverse : Bool, step : (Int32) -> Unit) -> Unit {
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
fn sorted_positions(operand : Series, descending : Bool) -> Array[Int32] {
  let valid = operand.validity_bools()
  let positions : Array[Int32] = []
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
fn value_comparator(operand : Series) -> (Int32, Int32) -> Int32 {
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
fn value_equality(operand : Series) -> (Int32, Int32) -> Bool {
  let cmp = value_comparator(operand)
  (i, j) => cmp(i, j) == 0
}

///|
/// Cell-wise difference against the cell `n` rows above (`Expr::diff`
/// defaults `n` to 1): exactly the composition `self - self.shift(n)` —
/// the leading `n` slots null, a null in either
/// operand null, the subtraction under the arithmetic kernel's dtype rules
/// (`Int` stays `Int`, a `Float` operand promotes). The shift's `Numeric`
/// convergence (the evaluator's convention for a positional result feeding
/// a binary op) is kept, so the dedicated node evaluates cell-for-cell what
/// the composition always did.
pub fn eval_diff(operand : Series, n : Int32) -> Series raise @types.DataError {
  let shifted = eval_positional(
    @ir.PositionalOp::Shift(n, @types.Scalar::Null),
    operand,
  ).try_column_to_numeric()
  eval_binary(@ir.BinOp::Sub, operand, shifted)
}
