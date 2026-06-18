// Blackbox tests for the reporting helpers. The CSV input is driven
// through `parse_csv_str` so the tests are deterministic and file-free;
// `main.mbt` is the only piece that touches `read_csv` / the filesystem.
// Revenue / quantity are integers so the sums (and the rendered HTML /
// Vega-Lite output) are byte-identical on every backend.

///|
let sample_csv : String =
  #|region,product,revenue,quantity
  #|west,widget,100,10
  #|east,gadget,50,5
  #|west,gadget,70,7
  #|east,widget,30,3
  #|north,widget,40,4
  #|

///|
test "revenue_by_region: sums per region and orders by revenue desc" {
  let df = @moonframe.parse_csv_str(
    sample_csv,
    @moonframe.CsvReadOptions::default(),
  )
  let summary = revenue_by_region(df)
  // One row per region; columns are the group key then the two aliased
  // sums, in spec order.
  assert_eq(summary.shape(), (3, 3))
  assert_eq(summary.columns(), ["region", "revenue", "quantity"])
  // west leads (100 + 70 = 170), then east (50 + 30 = 80), then north (40).
  assert_eq(summary.item(0, "region"), @moonframe.Scalar::String("west"))
  assert_eq(summary.item(0, "revenue"), @moonframe.Scalar::Int(170))
  assert_eq(summary.item(0, "quantity"), @moonframe.Scalar::Int(17))
  assert_eq(summary.item(1, "region"), @moonframe.Scalar::String("east"))
  assert_eq(summary.item(1, "revenue"), @moonframe.Scalar::Int(80))
  assert_eq(summary.item(2, "region"), @moonframe.Scalar::String("north"))
  assert_eq(summary.item(2, "revenue"), @moonframe.Scalar::Int(40))
  assert_eq(summary.check_invariants(), Ok(()))
}

///|
test "revenue_table: renders the summary as a captioned HTML table" {
  let df = @moonframe.parse_csv_str(
    sample_csv,
    @moonframe.CsvReadOptions::default(),
  )
  let html = revenue_table(revenue_by_region(df))
  inspect(
    html,
    content=(
      #|<table class="dataframe">
      #|<caption>Revenue by region</caption>
      #|<thead>
      #|<tr><th>region</th><th>revenue</th><th>quantity</th></tr>
      #|</thead>
      #|<tbody>
      #|<tr><td>west</td><td>170</td><td>17</td></tr>
      #|<tr><td>east</td><td>80</td><td>8</td></tr>
      #|<tr><td>north</td><td>40</td><td>4</td></tr>
      #|</tbody>
      #|</table>
      #|
    ),
  )
}

///|
test "revenue_chart: emits a Vega-Lite v5 bar spec" {
  let df = @moonframe.parse_csv_str(
    sample_csv,
    @moonframe.CsvReadOptions::default(),
  )
  let chart = revenue_chart(revenue_by_region(df))
  inspect(
    chart,
    content=(
      #|{"$schema":"https://vega.github.io/schema/vega-lite/v5.json","title":"Revenue by region","mark":"bar","encoding":{"x":{"field":"region","type":"nominal"},"y":{"field":"revenue","type":"quantitative"}},"data":{"values":[{"region":"west","revenue":170,"quantity":17},{"region":"east","revenue":80,"quantity":8},{"region":"north","revenue":40,"quantity":4}]}}
    ),
  )
}

///|
test "revenue_by_region: missing `region` column surfaces as ColumnNotFound" {
  let df = @moonframe.DataFrame::new([
    @moonframe.Series::from_ints("revenue", [1, 2]),
  ])
  assert_true(
    (Ok(revenue_by_region(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("region")),
  )
}

///|
test "revenue_chart: missing charted column surfaces as ColumnNotFound" {
  // A frame with `region` but no `revenue` can't be charted on y=revenue;
  // x is validated before y, so the missing column reported is `revenue`.
  let df = @moonframe.DataFrame::new([
    @moonframe.Series::from_strings("region", ["west", "east"]),
  ])
  assert_true(
    (Ok(revenue_chart(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("revenue")),
  )
}
