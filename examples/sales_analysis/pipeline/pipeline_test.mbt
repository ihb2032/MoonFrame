// Blackbox tests for the sales-analysis pipeline helpers. The CSV
// inputs are driven through `parse_csv_str` so the tests are
// deterministic and file-free; `main.mbt` is the only piece that
// touches `read_csv`.

///|
test "widget_report: keeps widget rows, projects 4 cols, sorts by quantity desc" {
  let csv =
    #|region,product,price,quantity,revenue,active
    #|west,widget,9.5,12,114.0,true
    #|east,gadget,12.0,8,96.0,true
    #|north,widget,9.5,5,47.5,false
    #|south,gadget,12.0,10,120.0,true
    #|east,widget,9.5,7,66.5,false
    #|
  let df = @moonframe.parse_csv_str(csv, @moonframe.CsvReadOptions::default())
  let (sorted, summary) = widget_report(df)

  // The filter kept the three widget rows; select pinned the 4
  // columns in declaration order; sort put quantity = 12 first.
  assert_eq(sorted.shape(), (3, 4))
  assert_eq(sorted.columns(), ["region", "price", "quantity", "revenue"])
  assert_eq(sorted.item(0, "region"), @moonframe.Scalar::String("west"))
  assert_eq(sorted.item(0, "quantity"), @moonframe.Scalar::Int(12))
  assert_eq(sorted.item(2, "quantity"), @moonframe.Scalar::Int(5))
  assert_eq(sorted.check_invariants(), Ok(()))

  // `describe` returns the fixed 8-column summary, one row per
  // projected source column.
  assert_eq(summary.shape(), (4, 8))
  assert_eq(summary.item(0, "column"), @moonframe.Scalar::String("region"))
  assert_eq(summary.check_invariants(), Ok(()))
}

///|
test "widget_report: empty product set collapses to a 0-row widget frame" {
  let csv =
    #|region,product,price,quantity,revenue,active
    #|west,gadget,12.0,8,96.0,true
    #|south,gizmo,15.0,3,45.0,true
    #|
  let df = @moonframe.parse_csv_str(csv, @moonframe.CsvReadOptions::default())
  let (sorted, summary) = widget_report(df)
  // No widgets in the source → kept row count is zero, but the
  // projection keeps the schema verbatim.
  assert_eq(sorted.shape(), (0, 4))
  assert_eq(sorted.columns(), ["region", "price", "quantity", "revenue"])
  // `describe` still produces an N×8 row-per-column summary.
  assert_eq(summary.shape(), (4, 8))
}

///|
test "widget_report: missing `product` column surfaces as ColumnNotFound" {
  // The pipeline reads `product` to decide row inclusion; if the
  // source frame is missing it, the `is_widget_row` predicate bubbles
  // `ColumnNotFound` up through `filter` rather than silently excluding
  // every row.
  let df = @moonframe.DataFrame::new([
    @moonframe.Series::from_ints("id", [1, 2, 3]),
  ])
  assert_true(
    (Ok(widget_report(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("product")),
  )
}

///|
test "widget_report: select error surfaces when a required column is missing" {
  // `product` exists (so the filter succeeds) but `region` does not
  // — the next step (`select`) must propagate the ColumnNotFound.
  let df = @moonframe.DataFrame::new([
    @moonframe.Series::from_strings("product", ["widget", "gadget"]),
  ])
  assert_true(
    (Ok(widget_report(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("region")),
  )
}

///|
test "widget_report: sort error surfaces when `quantity` is missing post-filter" {
  // Hand-build a frame that has `product` + `region` + `price` +
  // `revenue` but no `quantity`. `select` fails when it asks for
  // `quantity` — so this also exercises the `select` error path,
  // but with a different missing column from the previous case.
  let df = @moonframe.DataFrame::new([
    @moonframe.Series::from_strings("product", ["widget"]),
    @moonframe.Series::from_strings("region", ["west"]),
    @moonframe.Series::from_floats("price", [9.5]),
    @moonframe.Series::from_floats("revenue", [114.0]),
  ])
  assert_true(
    (Ok(widget_report(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("quantity")),
  )
}

///|
test "is_widget_row: keeps matching rows and drops the rest" {
  // Apply the reified predicate through `filter`, exercising both branches
  // of the closure: a "widget" cell is kept, a "gadget" cell dropped.
  let df = @moonframe.DataFrame::new([
    @moonframe.Series::from_strings("product", ["widget", "gadget"]),
  ])
  let kept = df.filter(is_widget_row())
  assert_eq(kept.nrows(), 1)
  assert_eq(kept.item(0, "product"), @moonframe.Scalar::String("widget"))
}

///|
test "is_widget_row: surfaces accessor error when `product` column is absent" {
  let df = @moonframe.DataFrame::new([@moonframe.Series::from_ints("id", [1])])
  assert_true(
    (Ok(df.filter(is_widget_row())) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("product")),
  )
}

///|
test "is_widget_row: a non-String product column surfaces TypeMismatch" {
  // The predicate reads each `product` cell as a String; a non-String column
  // (here Int) makes `Scalar::as_string` raise `TypeMismatch` — the typed-cell
  // error path the doc promises, distinct from the missing-column case above.
  let df = @moonframe.DataFrame::new([
    @moonframe.Series::from_ints("product", [1, 2]),
  ])
  assert_true(
    (Ok(df.filter(is_widget_row())) catch { e => Err(e) })
    is Err(@moonframe.DataError::TypeMismatch(_)),
  )
}
