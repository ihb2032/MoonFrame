// Blackbox tests for the expression / lazy helpers. The CSV input is
// driven through `parse_csv_str` so the tests are deterministic and
// file-free; `main.mbt` is the only piece that touches `read_csv` / the
// filesystem. Revenue / cost / quantity are chosen so every derived value
// (profit, unit_price, the scaled revenue, the per-region means) is exact
// on every backend.

///|
let sample_csv : String =
  #|region,product,revenue,cost,quantity
  #|west,widget,100,60,10
  #|east,gadget,80,30,5
  #|west,gadget,72,40,6
  #|east,widget,30,45,3
  #|north,widget,40,20,4
  #|north,gadget,90,55,6
  #|

///|
fn read_sample() -> @moonframe.DataFrame raise @moonframe.DataError {
  @moonframe.parse_csv_str(sample_csv)
}

///|
test "enrich: appends profit and unit_price, keeping every source column" {
  let out = enrich(read_sample())
  // Five source columns plus the two derived ones, in expression order.
  assert_eq(out.shape(), (6, 7))
  assert_eq(out.columns(), [
    "region", "product", "revenue", "cost", "quantity", "profit", "unit_price",
  ])
  // profit = revenue - cost (Int); unit_price = revenue / quantity (Float).
  assert_eq(out.item(0, "profit"), @moonframe.Scalar::Int(40))
  assert_eq(out.item(0, "unit_price"), @moonframe.Scalar::Float(10.0))
  assert_eq(out.item(1, "profit"), @moonframe.Scalar::Int(50))
  assert_eq(out.item(1, "unit_price"), @moonframe.Scalar::Float(16.0))
  assert_eq(out.item(3, "profit"), @moonframe.Scalar::Int(-15))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "top_west: keeps only the profitable western rows" {
  let out = top_west(read_sample())
  // Rows 0 (west widget, profit 40) and 2 (west gadget, profit 32) pass;
  // eastern rows and the loss-making row are dropped.
  assert_eq(out.shape(), (2, 7))
  assert_eq(out.item(0, "product"), @moonframe.Scalar::String("widget"))
  assert_eq(out.item(0, "profit"), @moonframe.Scalar::Int(40))
  assert_eq(out.item(1, "product"), @moonframe.Scalar::String("gadget"))
  assert_eq(out.item(1, "profit"), @moonframe.Scalar::Int(32))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "margins: composite aggregation per region, first-appearance order" {
  let out = margins(read_sample())
  assert_eq(out.shape(), (3, 4))
  assert_eq(out.columns(), ["region", "total_profit", "avg_revenue", "n"])
  // west: profit 40 + 32 = 72, mean revenue (100 + 72) / 2 = 86, 2 rows.
  assert_eq(out.item(0, "region"), @moonframe.Scalar::String("west"))
  assert_eq(out.item(0, "total_profit"), @moonframe.Scalar::Int(72))
  assert_eq(out.item(0, "avg_revenue"), @moonframe.Scalar::Float(86.0))
  assert_eq(out.item(0, "n"), @moonframe.Scalar::Int(2))
  // east: profit 50 + (-15) = 35, mean (80 + 30) / 2 = 55.
  assert_eq(out.item(1, "region"), @moonframe.Scalar::String("east"))
  assert_eq(out.item(1, "total_profit"), @moonframe.Scalar::Int(35))
  assert_eq(out.item(1, "avg_revenue"), @moonframe.Scalar::Float(55.0))
  // north: profit 20 + 35 = 55, mean (40 + 90) / 2 = 65.
  assert_eq(out.item(2, "region"), @moonframe.Scalar::String("north"))
  assert_eq(out.item(2, "total_profit"), @moonframe.Scalar::Int(55))
  assert_eq(out.item(2, "avg_revenue"), @moonframe.Scalar::Float(65.0))
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "margins: renders as a Markdown summary" {
  inspect(
    margins(read_sample()).to_markdown(),
    content=(
      #|| region | total_profit | avg_revenue | n   |
      #|| ------ | ------------ | ----------- | --- |
      #|| west   | 72           | 86          | 2   |
      #|| east   | 35           | 55          | 2   |
      #|| north  | 55           | 65          | 2   |
      #|
    ),
  )
}

///|
test "graded: tags each row high/low with when/then/otherwise" {
  let out = graded(read_sample())
  // One extra column on top of the five source columns.
  assert_eq(out.shape(), (6, 6))
  assert_eq(out.item(0, "tier"), @moonframe.Scalar::String("high")) // 100 >= 60
  assert_eq(out.item(3, "tier"), @moonframe.Scalar::String("low")) // 30 < 60
  assert_eq(out.item(4, "tier"), @moonframe.Scalar::String("low")) // 40 < 60
  assert_eq(out.item(5, "tier"), @moonframe.Scalar::String("high")) // 90 >= 60
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "report_plan: explains as built, then shows the optimized plan" {
  let plan = report_plan(read_sample())
  // As built — a faithful mirror of the chained verbs.
  inspect(
    plan.explain(),
    content=(
      #|SELECT [col(region), col(revenue_adj)]
      #|  FILTER (col(region) == "west")
      #|    WITH_COLUMNS [(col(revenue) * 1.5) as revenue_adj]
      #|      SCAN [6×5]
    ),
  )
  // Optimized — the filter sinks below the projection it commutes with,
  // and a narrowing SELECT prunes the scan to the two columns the query
  // actually reads (region, revenue).
  inspect(
    plan.explain(optimized=true),
    content=(
      #|SELECT [col(region), col(revenue_adj)]
      #|  WITH_COLUMNS [(col(revenue) * 1.5) as revenue_adj]
      #|    FILTER (col(region) == "west")
      #|      SELECT [col(region), col(revenue)]
      #|        SCAN [6×5]
    ),
  )
}

///|
test "report_plan: collect runs the plan and equals the eager pipeline" {
  let plan = report_plan(read_sample())
  let out = plan.collect()
  // west rows only, revenue scaled by 1.5, projected to two columns.
  assert_eq(out.shape(), (2, 2))
  assert_eq(out.columns(), ["region", "revenue_adj"])
  assert_eq(out.item(0, "revenue_adj"), @moonframe.Scalar::Float(150.0))
  assert_eq(out.item(1, "revenue_adj"), @moonframe.Scalar::Float(108.0))
  // The optimizer's contract: collecting equals the eager equivalent.
  let eager = read_sample()
    .with_columns([
      (@moonframe.col("revenue") * @moonframe.lit_float(1.5)).with_alias(
        "revenue_adj",
      ),
    ])
    .filter(@moonframe.col("region").eq(@moonframe.lit_str("west")))
    .select([@moonframe.col("region"), @moonframe.col("revenue_adj")])
  assert_eq(out, eager)
  assert_eq(out.check_invariants(), Ok(()))
}

///|
test "enrich: a missing source column surfaces as ColumnNotFound" {
  // No `cost` column, so `revenue - cost` can't be evaluated.
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("revenue", [1, 2]),
    @moonframe.Series::from_ints("quantity", [1, 2]),
  ])
  assert_true(
    (Ok(enrich(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("cost")),
  )
}
