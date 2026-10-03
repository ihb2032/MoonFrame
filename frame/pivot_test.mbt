// Blackbox tests for the reshape pair — `pivot` (long → wide) and
// `unpivot` (wide → long). Pinned: the first-appearance axes, the naming
// rule (on-value alone for one values column, value_on for several), the
// omission defaults, every `PivotAgg`'s cell rule, the strict default on
// multi-cell slots, the dtype rules (kept / Float / Int per aggregation,
// unpivot's unification), and the lazy mirrors' collect parity.

///|
/// Long fixture: two regions × two quarters of sales, one duplicate cell
/// (region "east" / quarter "q1" holds two rows).
fn sales_long() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("region", ["west", "west", "east", "east"]),
    Series::from_strings("quarter", ["q1", "q2", "q1", "q1"]),
    Series::from_ints("sales", [10, 20, 30, 40]),
  ])
}

///|
test "pivot reshapes long to wide, first-appearance on both axes" {
  // Drop the duplicate first: the strict default must hold for the rest.
  let df = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "west", "east"]),
    Series::from_strings("quarter", ["q1", "q2", "q1"]),
    Series::from_ints("sales", [10, 20, 30]),
  ])
  let r = df.pivot(on=[@expr.col("quarter")], index=[@expr.col("region")])
  // Rows: west first (first appearance); columns: q1 then q2.
  assert_eq(r.columns(), ["region", "q1", "q2"])
  assert_eq(r.get_column("region").to_scalars(), [
    @types.Scalar::String("west"),
    @types.Scalar::String("east"),
  ])
  assert_eq(r.get_column("q1").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(30),
  ])
  assert_eq(r.get_column("q2").to_scalars(), [
    @types.Scalar::Int(20),
    @types.Scalar::Null,
  ])
}

///|
test "pivot's omission defaults and the both-omitted error" {
  let df = sales_long().head(3)
  // index omitted → every column on / values do not name.
  let by_values = df.pivot(on=[@expr.col("quarter")], values=[
    @expr.col("sales"),
  ])
  assert_eq(by_values.columns(), ["region", "q1", "q2"])
  // values omitted → every column on / index do not name — here "sales".
  let by_index = df.pivot(on=[@expr.col("quarter")], index=[@expr.col("region")])
  assert_eq(by_index.columns(), by_values.columns())
  // Both omitted has no reading.
  assert_true(
    (Ok(df.pivot(on=[@expr.col("quarter")])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // Neither an empty on list.
  assert_true(
    (Ok(df.pivot(on=[], index=[@expr.col("region")])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "the strict default raises on a multi-cell slot; each aggregation collapses" {
  let df = sales_long()
  // The east/q1 slot holds [30, 40].
  assert_true(
    (Ok(df.pivot(on=[@expr.col("quarter")], index=[@expr.col("region")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  fn p(agg : PivotAgg) -> DataFrame raise @types.DataError {
    df.pivot(
      on=[@expr.col("quarter")],
      index=[@expr.col("region")],
      aggregate_function=agg,
    )
  }
  assert_eq(p(First).get_column("q1").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(30),
  ])
  assert_eq(p(Last).get_column("q1").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(40),
  ])
  assert_eq(p(Sum).get_column("q1").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(70),
  ])
  assert_eq(p(Min).get_column("q1").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(30),
  ])
  assert_eq(p(Max).get_column("q1").to_scalars(), [
    @types.Scalar::Int(10),
    @types.Scalar::Int(40),
  ])
  // Mean is Float; Len counts rows (nulls included).
  assert_eq(p(Mean).get_column("q1").to_scalars(), [
    @types.Scalar::Float(10.0),
    @types.Scalar::Float(35.0),
  ])
  assert_eq(p(Median).get_column("q1").to_scalars(), [
    @types.Scalar::Float(10.0),
    @types.Scalar::Float(35.0),
  ])
  assert_eq(p(Len).get_column("q1").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
}

///|
test "multiple values columns name value_on; an empty index is the grand total" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a", "b"]),
    Series::from_strings("q", ["x", "y", "x"]),
    Series::from_ints("v1", [1, 2, 3]),
    Series::from_ints("v2", [4, 5, 6]),
  ])
  let r = df.pivot(on=[@expr.col("q")], index=[@expr.col("k")], values=[
    @expr.col("v1"),
    @expr.col("v2"),
  ])
  assert_eq(r.columns(), ["k", "v1_x", "v1_y", "v2_x", "v2_y"])
  assert_eq(r.get_column("v1_x").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(3),
  ])
  // An empty index list is the grand total: one row, every value column
  // still reshaping under it.
  let total = df.pivot(
    on=[@expr.col("q")],
    index=[],
    values=[@expr.col("v1"), @expr.col("v2")],
    aggregate_function=First,
  )
  assert_eq(total.shape(), (1, 4))
  assert_eq(total.columns(), ["v1_x", "v1_y", "v2_x", "v2_y"])
  assert_eq(total.get_column("v1_x").to_scalars(), [@types.Scalar::Int(1)])
  // values omitted with an explicit index takes the remaining columns.
  let by_index = df.pivot(
    on=[@expr.col("q")],
    index=[@expr.col("k")],
    aggregate_function=First,
  )
  assert_eq(by_index.columns(), ["k", "v1_x", "v1_y", "v2_x", "v2_y"])
}

///|
test "a null on-cell names its column; a derived key groups by its value" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "b"]),
    Series::from_string_options("q", [None, Some("x")]),
    Series::from_ints("v", [1, 2]),
  ])
  let r = df.pivot(on=[@expr.col("q")], index=[@expr.col("k")])
  assert_eq(r.nrows(), 2)
  // The null on value renders its own display as the column name.
  assert_eq(r.columns(), ["k", "null", "x"])
  // A derived on key evaluates: parity classes computed from the raw
  // value, one card per distinct computed value.
  let d = DataFrame::DataFrame([
    Series::from_ints("v", [1, 2, 3, 4]),
    Series::from_strings("t", ["a", "b", "c", "d"]),
  ])
  let keyed = d.pivot(
    on=[@expr.col("v").modulo(@expr.lit_int(2)).eq(@expr.lit_int(0))],
    values=[@expr.col("t")],
    aggregate_function=First,
  )
  assert_eq(keyed.shape(), (1, 2))
  assert_eq(keyed.columns(), ["false", "true"])
  assert_eq(keyed.get_column("false").to_scalars(), [@types.Scalar::String("a")])
  assert_eq(keyed.get_column("true").to_scalars(), [@types.Scalar::String("b")])
}

///|
test "unpivot folds columns into variable/value under the index" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "b"]),
    Series::from_ints("x", [1, 2]),
    Series::from_ints("y", [3, 4]),
  ])
  let r = df.unpivot(index=[@expr.col("k")])
  // Rows walk source rows outermost, then the on columns in order.
  assert_eq(r.shape(), (4, 3))
  assert_eq(r.columns(), ["k", "variable", "value"])
  assert_eq(r.get_column("k").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("b"),
    @types.Scalar::String("a"),
    @types.Scalar::String("b"),
  ])
  assert_eq(r.get_column("variable").to_scalars(), [
    @types.Scalar::String("x"),
    @types.Scalar::String("x"),
    @types.Scalar::String("y"),
    @types.Scalar::String("y"),
  ])
  assert_eq(r.get_column("value").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
  ])
  // The names are parameters.
  let named = df.unpivot(
    index=[@expr.col("k")],
    variable_name="col",
    value_name="amt",
  )
  assert_eq(named.columns(), ["k", "col", "amt"])
}

///|
test "unpivot unifies Int / Float to Float and refuses other mixes" {
  let mixed = DataFrame::DataFrame([
    Series::from_ints("i", [1, 2]),
    Series::from_floats("f", [0.5, 1.5]),
  ])
  let r = mixed.unpivot()
  assert_eq(r.get_column("value").dtype(), @types.DataType::Float)
  assert_eq(r.get_column("value").to_scalars(), [
    @types.Scalar::Float(1.0),
    @types.Scalar::Float(2.0),
    @types.Scalar::Float(0.5),
    @types.Scalar::Float(1.5),
  ])
  let bad = DataFrame::DataFrame([
    Series::from_ints("i", [1]),
    Series::from_strings("s", ["x"]),
  ])
  assert_true(
    (Ok(bad.unpivot()) catch { e => Err(e) })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  // An empty on resolution — index names every column — raises.
  assert_true(
    (Ok(mixed.unpivot(index=[@expr.col("i"), @expr.col("f")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a duplicate on-name is rejected before any reshape work" {
  // The str op's output name is its leftmost column — "q" again — so the
  // second key collides with the first.
  let df = DataFrame::DataFrame([
    Series::from_strings("q", ["x", "y"]),
    Series::from_ints("v", [1, 2]),
  ])
  assert_true(
    (Ok(
      df.pivot(on=[@expr.col("q"), @expr.col("q").str_to_uppercase()], index=[]),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::DuplicateColumn(_)),
  )
}

///|
test "an all-null slot is a Null cell under mean and median" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "a"]),
    Series::from_strings("q", ["x", "x"]),
    Series::from_int_options("v", [None, None]),
  ])
  let mean = df.pivot(
    on=[@expr.col("q")],
    index=[@expr.col("k")],
    aggregate_function=Mean,
  )
  assert_eq(mean.get_column("x").to_scalars(), [@types.Scalar::Null])
  let median = df.pivot(
    on=[@expr.col("q")],
    index=[@expr.col("k")],
    aggregate_function=Median,
  )
  assert_eq(median.get_column("x").to_scalars(), [@types.Scalar::Null])
  // And sum over the all-null slot is the additive identity, min / max the
  // Null cell — the reduction family's split, verbatim.
  let sum = df.pivot(
    on=[@expr.col("q")],
    index=[@expr.col("k")],
    aggregate_function=Sum,
  )
  assert_eq(sum.get_column("x").to_scalars(), [@types.Scalar::Int(0)])
  let min = df.pivot(
    on=[@expr.col("q")],
    index=[@expr.col("k")],
    aggregate_function=Min,
  )
  assert_eq(min.get_column("x").to_scalars(), [@types.Scalar::Null])
}

///|
test "pivot's Mean / Median refuse a non-numeric values column" {
  // The default values~ resolution collects every unnamed column — the
  // note column included — and Mean / Median reduce through a Float probe
  // that would silently null every String cell; the gate raises instead,
  // the reduction family's rule.
  let df = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "west", "east"]),
    Series::from_strings("quarter", ["q1", "q2", "q1"]),
    Series::from_ints("sales", [10, 20, 30]),
    Series::from_strings("note", ["a", "b", "c"]),
  ])
  assert_true(
    (Ok(
      df.pivot(
        on=[@expr.col("quarter")],
        index=[@expr.col("region")],
        aggregate_function=Mean,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  assert_true(
    (Ok(
      df.pivot(
        on=[@expr.col("quarter")],
        index=[@expr.col("region")],
        aggregate_function=Median,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  // An explicit String values column raises the same way; an explicit
  // numeric one is untouched by the gate.
  assert_true(
    (Ok(
      df.pivot(
        on=[@expr.col("quarter")],
        index=[@expr.col("region")],
        values=[@expr.col("note")],
        aggregate_function=Mean,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(TypeMismatch(@types.TypeMismatchDetail::Message(_))),
  )
  let ok = df.pivot(
    on=[@expr.col("quarter")],
    index=[@expr.col("region")],
    values=[@expr.col("sales")],
    aggregate_function=Mean,
  )
  assert_eq(ok.get_column("q1").to_scalars(), [
    @types.Scalar::Float(10.0),
    @types.Scalar::Float(30.0),
  ])
}

///|
test "a pivot with no values column to reshape raises" {
  // on and index name every column between them, so the default values
  // resolution is empty — nothing to reshape, and the twin verb's guard is
  // the family's rule.
  let df = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "east"]),
    Series::from_strings("quarter", ["q1", "q2"]),
  ])
  assert_true(
    (Ok(df.pivot(on=[@expr.col("quarter")], index=[@expr.col("region")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // An explicit empty list is the same nothing.
  assert_true(
    (Ok(
      df.pivot(on=[@expr.col("quarter")], index=[@expr.col("region")], values=[]),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}

///|
test "a card's rendered name collides at the card, not after the reshape" {
  // The String "null" and a real null are different keys (two cards) that
  // render the same column name.
  let dup = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "east"]),
    Series::from_string_options("q", [Some("null"), None]),
    Series::from_ints("sales", [10, 30]),
  ])
  assert_true(
    (Ok(dup.pivot(on=[@expr.col("q")], index=[@expr.col("region")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::DuplicateColumn("null")),
  )
  // A card colliding with an index column's name — the final-name check,
  // so the multi-value prefix shape stays honest: "sales" prefixed by the
  // "sales" card does not collide with the bare index name.
  let clash = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "east"]),
    Series::from_strings("q", ["region", "x"]),
    Series::from_ints("sales", [10, 30]),
  ])
  assert_true(
    (Ok(clash.pivot(on=[@expr.col("q")], index=[@expr.col("region")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::DuplicateColumn("region")),
  )
  // With two values columns the names carry the value-column prefix, so
  // the card "region" names "sales_region" instead — no collision with the
  // bare index name, and the reshape goes through.
  let two = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "east"]),
    Series::from_strings("q", ["region", "x"]),
    Series::from_ints("sales", [10, 30]),
    Series::from_ints("stock", [1, 2]),
  ])
  let r = two.pivot(
    on=[@expr.col("q")],
    index=[@expr.col("region")],
    aggregate_function=Sum,
  )
  assert_eq(r.columns(), [
    "region", "sales_region", "sales_x", "stock_region", "stock_x",
  ])
  // A prefixed collision, the other way round: value column "sales" with
  // card "b_c" against value column "sales_b" with card "c".
  let cross = DataFrame::DataFrame([
    Series::from_strings("region", ["west", "east", "north"]),
    Series::from_strings("q", ["b_c", "c", "other"]),
    Series::from_ints("sales", [10, 30, 50]),
    Series::from_ints("sales_b", [1, 2, 3]),
  ])
  assert_true(
    (Ok(
      cross.pivot(
        on=[@expr.col("q")],
        index=[@expr.col("region")],
        aggregate_function=Sum,
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::DuplicateColumn("sales_b_c")),
  )
}

///|
test "unpivot's roles stay disjoint and its names stay fresh" {
  let df = DataFrame::DataFrame([
    Series::from_strings("k", ["a", "b"]),
    Series::from_ints("x", [1, 2]),
    Series::from_ints("y", [3, 4]),
  ])
  // A column both folding into value and standing as index appears twice.
  assert_true(
    (Ok(df.unpivot(on=[@expr.col("x")], index=[@expr.col("x")])) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // The generated value name landing on an index column.
  let with_value = DataFrame::DataFrame([
    Series::from_ints("value", [9, 8]),
    Series::from_ints("x", [1, 2]),
    Series::from_ints("y", [3, 4]),
  ])
  assert_true(
    (Ok(
      with_value.unpivot(on=[@expr.col("x"), @expr.col("y")], index=[
        @expr.col("value"),
      ]),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::DuplicateColumn("value")),
  )
  // The two generated names colliding with each other.
  assert_true(
    (Ok(
      df.unpivot(
        on=[@expr.col("x"), @expr.col("y")],
        variable_name="same",
        value_name="same",
      ),
    ) catch {
      e => Err(e)
    })
    is Err(@types.DataError::DuplicateColumn("same")),
  )
}
