// Defensive-copy contracts for the public boundaries that *retain* a
// caller-owned `Array`. The CI guard
// (`.github/scripts/check_array_copy_boundaries.py`) is lexical: it only sees
// a `.copy()` spelled at the boundary itself, so a boundary that copies inside
// a helper — or one whose parameter shape the guard cannot parse — needs its
// behaviour pinned here instead. Every test mutates the caller's array after
// the call and asserts the constructed value never observes the mutation.
// `Expr::is_in` keeps the same pin beside its own package, in
// `expr/expr_test.mbt`.

///|
test "DataFrame::DataFrame copies the caller's column vector" {
  let columns = [Series::from_ints("a", [1, 2]), Series::from_ints("b", [3, 4])]
  let df = DataFrame::DataFrame(columns)
  columns.push(Series::from_ints("c", [5, 6]))
  columns[0] = Series::from_ints("z", [9, 9])
  assert_eq(df.columns(), ["a", "b"])
  assert_eq(df.item(0, "a"), Scalar::Int(1))
}

///|
test "Schema::Schema copies the caller's field array" {
  let fields : Array[Field] = [Field::Field("a", DataType::Int)]
  let schema = Schema::Schema(fields)
  fields.push(Field::Field("b", DataType::String))
  assert_eq(schema.len(), 1)
  assert_eq(schema.field_at(0).name(), "a")
}

///|
test "Series constructors copy their value arrays" {
  let ints : Array[Int64] = [1, 2]
  let floats = [1.5, 2.5]
  let bools = [true, false]
  let strings = ["a", "b"]
  let int_options : Array[Int64?] = [Some(1), None]
  let float_options : Array[Double?] = [Some(1.5), None]
  let bool_options : Array[Bool?] = [Some(true), None]
  let string_options : Array[String?] = [Some("a"), None]
  let series : ReadOnlyArray[Series] = [
    Series::from_ints("i", ints),
    Series::from_floats("f", floats),
    Series::from_bools("b", bools),
    Series::from_strings("s", strings),
    Series::from_int_options("io", int_options),
    Series::from_float_options("fo", float_options),
    Series::from_bool_options("bo", bool_options),
    Series::from_string_options("so", string_options),
  ]
  ints[0] = 99
  floats[0] = 99.5
  bools[0] = false
  strings[0] = "z"
  int_options[0] = None
  float_options[0] = None
  bool_options[0] = None
  string_options[0] = None
  assert_eq(series[0].get(0), Scalar::Int(1))
  assert_eq(series[1].get(0), Scalar::Float(1.5))
  assert_eq(series[2].get(0), Scalar::Bool(true))
  assert_eq(series[3].get(0), Scalar::String("a"))
  assert_eq(series[4].get(0), Scalar::Int(1))
  assert_eq(series[5].get(0), Scalar::Float(1.5))
  assert_eq(series[6].get(0), Scalar::Bool(true))
  assert_eq(series[7].get(0), Scalar::String("a"))
}

///|
test "JoinOptions key builders copy their key arrays" {
  let keys = [col("id")]
  let on = JoinOptions::on(keys)
  let sided = JoinOptions::left_on(keys, right_on=keys)
  keys.push(col("other"))
  assert_eq(on, JoinOptions::on([col("id")]))
  assert_eq(sided, JoinOptions::left_on([col("id")], right_on=[col("id")]))
}

///|
/// Copying on the way in is only half of it: while the key lists were public
/// fields, reading one handed back the array itself, so a caller could push a
/// key into options a `LazyFrame::join` had already captured and change what
/// the built plan collected. The accessors copy on the way out, and this pins
/// both ends of that — the options value and a plan holding it.
test "JoinOptions key accessors copy on the way out" {
  let left = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2]),
    Series::from_ints("t", [7, 8]),
  ])
  let right = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2]),
    Series::from_ints("t", [7, 9]),
  ])
  let options = JoinOptions::on([col("id")])
  let plan = LazyFrame::LazyFrame(left).join(
    LazyFrame::LazyFrame(right),
    options,
  )
  let rows = plan.collect().nrows()
  // Mutating what an accessor returned reaches neither the options nor the
  // captured plan: joining on `id` alone keeps both rows, and a second key on
  // `t` would drop one.
  options.on_keys().push(col("t"))
  options.left_keys().push(col("t"))
  options.right_keys().push(col("t"))
  assert_eq(options, JoinOptions::on([col("id")]))
  assert_eq(plan.collect().nrows(), rows)
  assert_eq(rows, 2)
}

///|
/// The lazy builders keep their arrays alive inside the logical plan until
/// `collect` runs, so they are the widest retention surface in the library.
/// `drop_nulls` additionally carries its keys behind an optional parameter.
/// These are runtime contracts, independent of the lexical guard in
/// `.github/scripts/` rather than a substitute for what it misses: the guard
/// reads syntax and can only see a copy written at the boundary, while these
/// mutate a caller's array afterwards and check the frame did not change.
test "lazy builders copy their expression arrays" {
  let df = DataFrame::DataFrame([
    Series::from_ints("a", [2, 1]),
    Series::from_int_options("b", [Some(3), None]),
  ])
  let selected = [col("a")]
  let derived = [col("a").add(lit_int(1)).with_alias("c")]
  let ordering = [(col("a"), SortOrder::Asc, NullOrder::NullsLast)]
  let dropped = [col("b")]
  let renames = [("a", "x")]
  let keys = [col("a")]
  let aggregates = [col("a").sum().with_alias("total")]
  let gates = [col("b")]
  let select_plan = LazyFrame::LazyFrame(df).select(selected)
  let with_columns_plan = LazyFrame::LazyFrame(df).with_columns(derived)
  let sort_plan = LazyFrame::LazyFrame(df).sort(ordering)
  let drop_plan = LazyFrame::LazyFrame(df).drop(dropped)
  let rename_plan = LazyFrame::LazyFrame(df).rename(renames)
  let group_plan = LazyFrame::LazyFrame(df).group_by(keys).agg(aggregates)
  let drop_nulls_plan = LazyFrame::LazyFrame(df).drop_nulls(subset=gates)
  selected.push(col("b"))
  derived.push(col("a").with_alias("d"))
  ordering.push((col("b"), SortOrder::Desc, NullOrder::NullsLast))
  dropped.push(col("a"))
  renames.push(("b", "y"))
  keys.push(col("b"))
  aggregates.push(col("b").sum().with_alias("other"))
  gates.push(col("a"))
  assert_eq(select_plan.collect().columns(), ["a"])
  assert_eq(with_columns_plan.collect().columns(), ["a", "b", "c"])
  assert_eq(sort_plan.collect().item(0, "a"), Scalar::Int(1))
  assert_eq(drop_plan.collect().columns(), ["a"])
  assert_eq(rename_plan.collect().columns(), ["x", "b"])
  assert_eq(group_plan.collect().columns(), ["a", "total"])
  assert_eq(drop_nulls_plan.collect().nrows(), 1)
}
