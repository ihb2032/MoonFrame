// Whitebox pins for the nested column's engine-side paths — the ones no
// public verb reaches on its own: the total order's every branch, the
// key cell a nested value normalises to, the coalesced join key, the
// gathers' stray-index hardening, and the cell-wise rebuild's refusal.

///|
fn lv(cells : Array[@types.Scalar]) -> @types.Scalar {
  @types.Scalar::List(@types.ListValue::ListValue(cells))
}

///|
fn fv(name : String, value : @types.Scalar) -> @types.FieldValue {
  @types.FieldValue::FieldValue(name, value)
}

///|
fn sv(a : @types.Scalar, b : @types.Scalar) -> @types.Scalar {
  @types.Scalar::Struct(
    @types.StructValue::StructValue([fv("a", a), fv("b", b)]),
  )
}

///|
fn ints(cells : Array[Int64]) -> @types.Scalar {
  lv(cells.map(i => @types.Scalar::Int(i)))
}

///|
fn lists_of_ints() -> @types.DataType {
  @types.DataType::List(@types.DataType::Int)
}

///|
fn lists_series() -> Series raise @types.DataError {
  Series::from_scalars(
    "l",
    [ints([1, 2]), @types.Scalar::Null, ints([3]), lv([])],
    dtype=lists_of_ints(),
  )
}

///|
test "the total order's every branch" {
  let c = cmp_scalar_total
  let nan = 0.0 / 0.0
  // Nulls first, and equal.
  assert_eq(c(@types.Scalar::Null, @types.Scalar::Int(1)), -1)
  assert_eq(c(@types.Scalar::Int(1), @types.Scalar::Null), 1)
  assert_eq(c(@types.Scalar::Null, @types.Scalar::Null), 0)
  // Ints and the I64 riders by count.
  assert_eq(c(@types.Scalar::Int(-2), @types.Scalar::Int(1)), -1)
  assert_eq(c(@types.Scalar::Int(1), @types.Scalar::Int(-2)), 1)
  assert_eq(c(@types.Scalar::Int(5), @types.Scalar::Int(5)), 0)
  assert_eq(c(@types.Scalar::Date(1), @types.Scalar::Date(2)), -1)
  assert_eq(c(@types.Scalar::Timestamp(2), @types.Scalar::Timestamp(1)), 1)
  assert_eq(c(@types.Scalar::Duration(1), @types.Scalar::Duration(1)), 0)
  // Floats by the IEEE total order: NaN one bucket past everything.
  assert_eq(c(@types.Scalar::Float(-1.5), @types.Scalar::Float(2.0)), -1)
  assert_eq(c(@types.Scalar::Float(2.0), @types.Scalar::Float(-1.5)), 1)
  assert_eq(c(@types.Scalar::Float(0.0), @types.Scalar::Float(-0.0)), 0)
  assert_eq(c(@types.Scalar::Float(1.0), @types.Scalar::Float(nan)), -1)
  assert_eq(c(@types.Scalar::Float(nan), @types.Scalar::Float(1.0)), 1)
  assert_eq(c(@types.Scalar::Float(nan), @types.Scalar::Float(nan)), 0)
  // Bool: false before true.
  assert_eq(c(@types.Scalar::Bool(false), @types.Scalar::Bool(true)), -1)
  assert_eq(c(@types.Scalar::Bool(true), @types.Scalar::Bool(false)), 1)
  assert_eq(c(@types.Scalar::Bool(true), @types.Scalar::Bool(true)), 0)
  // String lexicographically.
  assert_eq(c(@types.Scalar::String("a"), @types.Scalar::String("b")), -1)
  assert_eq(c(@types.Scalar::String("b"), @types.Scalar::String("a")), 1)
  assert_eq(c(@types.Scalar::String("a"), @types.Scalar::String("a")), 0)
  // Decimal by its own total order.
  let one = @types.Dec128::of_int64_scale(100, scale=2)
  let two = @types.Dec128::of_int64_scale(200, scale=2)
  assert_eq(c(@types.Scalar::Decimal(one), @types.Scalar::Decimal(two)), -1)
  assert_eq(c(@types.Scalar::Decimal(two), @types.Scalar::Decimal(one)), 1)
  assert_eq(c(@types.Scalar::Decimal(one), @types.Scalar::Decimal(one)), 0)
  // Lists: the first unequal element decides, a prefix sorts first, and
  // a longer one after an equal prefix.
  assert_eq(c(ints([1, 2]), ints([1, 3])), -1)
  assert_eq(c(ints([1, 3]), ints([1, 2])), 1)
  assert_eq(c(ints([1]), ints([1, 2])), -1)
  assert_eq(c(ints([1, 2]), ints([1])), 1)
  assert_eq(c(ints([1, 2]), ints([1, 2])), 0)
  assert_eq(c(lv([]), ints([1])), -1)
  assert_eq(c(lv([]), lv([])), 0)
  // Structs: field by field.
  assert_eq(
    c(
      sv(@types.Scalar::Int(1), @types.Scalar::Int(9)),
      sv(@types.Scalar::Int(2), @types.Scalar::Int(0)),
    ),
    -1,
  )
  assert_eq(
    c(
      sv(@types.Scalar::Int(1), @types.Scalar::Int(9)),
      sv(@types.Scalar::Int(1), @types.Scalar::Int(10)),
    ),
    -1,
  )
  assert_eq(
    c(
      sv(@types.Scalar::Int(1), @types.Scalar::Int(9)),
      sv(@types.Scalar::Int(1), @types.Scalar::Int(9)),
    ),
    0,
  )
  // A pair of different shapes cannot come out of one column; it still
  // answers, by the two dtypes' names, so the order is total.
  let cross = c(@types.Scalar::Int(1), @types.Scalar::Bool(true))
  let by_name = "Int".compare("Bool")
  assert_eq(cross, by_name)
  assert_eq(cross, -1)
}

///|
test "a nested value normalises to a key cell by its shape" {
  // The same folds a bare float gets, at every depth: NaN one bucket,
  // -0.0 onto 0.0.
  let nan = 0.0 / 0.0
  assert_true(
    key_cell(lv([@types.Scalar::Float(nan), @types.Scalar::Float(-0.0)])) ==
    KList([KNaN, KFloat(0.0)]),
  )
  assert_true(
    key_cell(sv(@types.Scalar::Int(1), @types.Scalar::Null)) ==
    KStruct([("a", KInt(1)), ("b", KNull)]),
  )
  assert_true(key_cell(lv([])) == KList([]))
  assert_true(
    key_cell(lv([lv([@types.Scalar::Bool(true)])])) ==
    KList([KList([KBool(true)])]),
  )
  // Two separately built keys of one shape are one map entry.
  let m : Map[KeyCell, Int32] = Map([])
  m[key_cell(ints([1, 2]))] = 1
  m[key_cell(ints([1, 2]))] = 2
  m[key_cell(ints([2, 1]))] = 3
  assert_eq(m.length(), 2)
}

///|
test "key_cells keys a nested column and skips its null cells" {
  let keys = lists_series().key_cells()
  assert_eq(keys.length(), 4)
  assert_true(keys[0] == KList([KInt(1), KInt(2)]))
  assert_true(keys[1] == KNull)
  assert_true(keys[2] == KList([KInt(3)]))
  assert_true(keys[3] == KList([]))
}

///|
test "the coalesced join key takes one side's whole nested cell" {
  let base = Series::from_scalars(
    "k",
    [ints([1]), @types.Scalar::Null, @types.Scalar::Null, ints([4])],
    dtype=lists_of_ints(),
  )
  let fill = Series::from_scalars(
    "k",
    [ints([9]), ints([2]), @types.Scalar::Null, ints([8])],
    dtype=lists_of_ints(),
  )
  let merged = base.coalesce_columns(fill, "k")
  assert_eq(merged.dtype(), lists_of_ints())
  assert_eq(merged.to_scalars().copy(), [
    ints([1]),
    ints([2]),
    @types.Scalar::Null,
    ints([4]),
  ])
  // A fill of another dtype refuses.
  let other = Series::from_scalars(
    "k",
    [lv([@types.Scalar::String("x")])],
    dtype=@types.DataType::List(@types.DataType::String),
  )
  let refused = Ok(ignore(base.coalesce_columns(other, "k"))) catch {
    e => Err(e)
  }
  assert_true(
    refused
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(m)),
    ) &&
    m.contains("coalesce fill carries"),
  )
}

///|
test "the engine gathers harden a stray index into a null nested cell" {
  let s = lists_series()
  // gather_series: an out-of-range index is a null cell, never a panic.
  let gathered = s.gather_series([2, 99, 0, -1])
  assert_eq(gathered.to_scalars().copy(), [
    ints([3]),
    @types.Scalar::Null,
    ints([1, 2]),
    @types.Scalar::Null,
  ])
  // gather_series_opt: a `None` slot is a null cell.
  let opt = s.gather_series_opt([Some(3), None, Some(1)], "out")
  assert_eq(opt.name(), "out")
  assert_eq(opt.dtype(), lists_of_ints())
  assert_eq(opt.to_scalars().copy(), [
    lv([]),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  // The public gather raises on a stray index, as for every column.
  let raised = Ok(ignore(s.gather([0, 9]))) catch { e => Err(e) }
  assert_true(raised is Err(@types.DataError::IndexOutOfBounds(9)))
}

///|
test "a nested column stays on its backend and is canonical" {
  let s = lists_series()
  assert_true(s.is_canonical())
  // No all-valid nested column converges onto the numeric backend.
  let all_valid = Series::from_scalars(
    "l",
    [ints([1]), ints([2])],
    dtype=lists_of_ints(),
  )
  assert_true(all_valid.is_canonical())
  assert_eq(all_valid.storage_kind(), @column.StorageKind::Builtin)
  // A Boolean mask is not a nested column: the reader declines.
  assert_true(s.mask_true_indices() is None)
}

///|
test "the cell-wise rebuild refuses a nested column it is handed" {
  // Every caller routes a nested source to `rebuild_nested` first; the
  // skeleton's refusal is the guard that keeps a future caller honest.
  let refused = Ok(
    ignore(
      lists_series().rebuild_options(
        "l",
        1,
        (a, k) => Some(a[k]),
        (a, k) => Some(a[k]),
        (a, k) => Some(a[k]),
        (a, k) => Some(a.get(k)),
        (a, k) => Some(a[k]),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    refused is Err(@types.DataError::InvalidOperation(m)) &&
    m.contains("cell-wise rebuild does not take a nested column"),
  )
}

///|
test "the extremum reducers name the sorted ends, windowed" {
  let s = Series::from_scalars(
    "l",
    [ints([3]), ints([1, 9]), @types.Scalar::Null, lv([]), ints([1, 2])],
    dtype=lists_of_ints(),
  )
  let (min_reducer, dtype) = Series::reducer_for(s, ReduceOp::Min)
  assert_eq(dtype, lists_of_ints())
  // The window is the four present-or-not rows 1..4.
  assert_eq(min_reducer(4, k => k + 1), lv([]))
  assert_eq(min_reducer(0, k => k), @types.Scalar::Null)
  assert_eq(min_reducer(1, _ => 2), @types.Scalar::Null)
  let (max_reducer, _) = Series::reducer_for(s, ReduceOp::Max)
  assert_eq(max_reducer(5, k => k), ints([3]))
  // The positional twins name the window-local row.
  let (arg_min, arg_dtype) = Series::reducer_for(s, ReduceOp::ArgMin)
  assert_eq(arg_dtype, @types.DataType::Int)
  assert_eq(arg_min(5, k => k), @types.Scalar::Int(3))
  let (arg_max, _) = Series::reducer_for(s, ReduceOp::ArgMax)
  assert_eq(arg_max(5, k => k), @types.Scalar::Int(0))
  assert_eq(arg_min(1, _ => 2), @types.Scalar::Null)
  // First / last / count / mode read nested cells like any other.
  let (first, _) = Series::reducer_for(s, ReduceOp::First)
  assert_eq(first(5, k => k), ints([3]))
  let (mode, _) = Series::reducer_for(s, ReduceOp::Mode)
  let twice = Series::from_scalars(
    "l",
    [ints([7]), ints([7]), ints([8])],
    dtype=lists_of_ints(),
  )
  let (mode2, _) = Series::reducer_for(twice, ReduceOp::Mode)
  assert_eq(mode2(3, k => k), ints([7]))
  ignore(mode)
  let (n_unique, _) = Series::reducer_for(s, ReduceOp::NUnique)
  assert_eq(n_unique(5, k => k), @types.Scalar::Int(5))
}

///|
test "the aggregate reducers refuse a nested column" {
  let s = lists_series()
  let ops : Array[(ReduceOp, String)] = [
    (ReduceOp::Sum, "sum"),
    (ReduceOp::Mean, "mean"),
    (ReduceOp::Std, "std"),
    (ReduceOp::Var, "var"),
    (ReduceOp::Median, "median"),
  ]
  for pair in ops {
    let (op, name) = pair
    let refused : Result[_, @types.DataError] = Ok(
      ignore(Series::reducer_for(s, op)),
    ) catch {
      e => Err(e)
    }
    match refused {
      Err(@types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(m))) =>
        assert_true(m.contains(name))
      _ => fail("\{name} was expected to refuse a nested column")
    }
  }
  // The quantile refuses when its reducer is asked for — before any
  // window is folded.
  let quantile = Ok(
    ignore(
      Series::reducer_for(
        s,
        ReduceOp::Quantile(0.5, QuantileInterpolation::Linear),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    quantile
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(m)),
    ) &&
    m.contains("quantile undefined for List"),
  )
}

///|
test "the positional comparator reads the nested order" {
  // `value_comparator` feeds the order-based positional kernels; on a
  // nested column it answers the total order the sort key reads.
  let s = Series::from_scalars(
    "l",
    [ints([2]), lv([]), ints([1])],
    dtype=lists_of_ints(),
  )
  let sorted = s.sort()
  assert_eq(sorted.to_scalars().copy(), [lv([]), ints([1]), ints([2])])
}

///|
test "the total order places a shorter struct before a longer one" {
  // Structs of one column always share a width; the comparator still
  // answers for two that do not — the shared prefix compares equal and
  // the shorter sorts first.
  let short = @types.Scalar::Struct(
    @types.StructValue::StructValue([fv("a", @types.Scalar::Int(1))]),
  )
  let long = @types.Scalar::Struct(
    @types.StructValue::StructValue([
      fv("a", @types.Scalar::Int(1)),
      fv("b", @types.Scalar::Int(2)),
    ]),
  )
  assert_eq(cmp_scalar_total(short, long), -1)
  assert_eq(cmp_scalar_total(long, short), 1)
}
