// Integration tests for the facade package. Every symbol used here is
// reached through `ihb2032/MoonFrame` (no `@types` / `@frame` / `@io`
// qualifications), so these tests double as the practical completeness
// check for the `pub using` re-exports in `moonframe.mbt`. A missing
// re-export here surfaces as a type error rather than a silent gap in
// the public surface. The operator verbs and `to_markdown` are methods
// on `DataFrame`, reached automatically through the `type DataFrame`
// re-export.

// ── End-to-end file-backed pipeline (matches PLAN §6.4) ──────────────

///|
test "pipeline: read_csv → filter → select → sort → describe → to_markdown" {
  // Stage a fixture in `_build/` via the public `write_csv` API so the
  // test stays self-contained — no checked-in fixture file required.
  // The pipeline then runs against `read_csv`, which is the exact path
  // the plan's §6 acceptance criterion calls out.
  let path = "_build/pipeline_facade_fixture.csv"
  let staged = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west", "north"]),
    Series::from_strings("product", ["widget", "widget", "gadget", "widget"]),
    Series::from_ints("quantity", [12, 7, 4, 5]),
    Series::from_floats("revenue", [114.0, 66.5, 48.0, 47.5]),
  ])
  write_csv(path, staged)
  let df = read_csv(path)
  assert_eq(df.check_invariants(), Ok(()))

  // filter (widgets only) → select → sort → describe → to_markdown.
  // The predicate is an `Expr` the evaluator runs vectorized; an unknown
  // column surfaces as `ColumnNotFound`.
  let report = df
    .filter(col("product").eq(lit_str("widget")))
    .select(cols(["region", "quantity", "revenue"]))
    .sort([(col("quantity"), SortOrder::Desc, NullOrder::NullsLast)])
  let summary = report.describe()

  // Quantity desc puts west first; describe should surface that.
  assert_eq(report.get(0, "region"), Scalar::String("west"))
  assert_eq(report.get(0, "quantity"), Scalar::Int(12))
  assert_eq(report.nrows(), 3)

  // Snapshot the full markdown — the renderer is deterministic for a
  // given frame, so this pins both the schema (header / dash row) and
  // the column-width logic. String min/max use lexicographic order, so
  // the region `max` is "west" (not shortlex's longest, "north").
  let expected =
    #|| column   | dtype  | count | null_count | unique_count | mean | min  | max  |
    #|| -------- | ------ | ----- | ---------- | ------------ | ---- | ---- | ---- |
    #|| region   | String | 3     | 0          | 3            |      | east | west |
    #|| quantity | Int    | 3     | 0          | 3            | 8    | 5    | 12   |
    #|| revenue  | Float  | 3     | 0          | 3            | 76   | 47.5 | 114  |
    #|
  assert_eq(summary.to_markdown(), expected)
}

// ── End-to-end string-in CSV pipeline ─────────────────────────────────

///|
test "pipeline: parse_csv_str → filter → select → sort → describe → to_markdown" {
  // Synthetic sales rows: 4 numeric / 1 boolean / 1 string column,
  // mixed nulls in `revenue` so the downstream describe has something
  // to summarise.
  let csv =
    #|region,product,price,quantity,revenue,active
    #|west,widget,9.5,12,114.0,true
    #|east,gadget,12.0,8,96.0,true
    #|north,widget,9.5,5,47.5,false
    #|west,gizmo,15.0,3,45.0,true
    #|south,gadget,12.0,10,,true
    #|east,widget,9.5,7,66.5,false
    #|
  let df = parse_csv_str(csv, CsvReadOptions::default())
  assert_eq(df.shape(), (6, 6))
  assert_eq(df.check_invariants(), Ok(()))

  // Keep rows whose product is "widget" with an `Expr` predicate; an
  // unknown column raises `ColumnNotFound` straight through `filter`.
  let widgets = df.filter(col("product").eq(lit_str("widget")))
  assert_eq(widgets.nrows(), 3)
  assert_eq(widgets.check_invariants(), Ok(()))

  // Project a subset of columns to demonstrate `select` keeps the
  // requested column order.
  let projected = widgets.select(
    cols(["region", "price", "quantity", "revenue"]),
  )
  assert_eq(projected.columns(), ["region", "price", "quantity", "revenue"])
  assert_eq(projected.check_invariants(), Ok(()))

  // Sort by quantity descending — stable mergesort + NullsLast.
  let sorted = projected.sort([
    (col("quantity"), SortOrder::Desc, NullOrder::NullsLast),
  ])
  assert_eq(sorted.check_invariants(), Ok(()))
  assert_eq(sorted.get(0, "region"), Scalar::String("west"))
  assert_eq(sorted.get(0, "quantity"), Scalar::Int(12))
  assert_eq(sorted.get(2, "quantity"), Scalar::Int(5))

  // Per-column summary — fixed N×8 schema, one row per source column.
  let summary = sorted.describe()
  assert_eq(summary.shape(), (4, 8))
  assert_eq(summary.columns(), [
    "column", "dtype", "count", "null_count", "unique_count", "mean", "min", "max",
  ])
  assert_eq(summary.get(0, "column"), Scalar::String("region"))
  assert_eq(summary.get(1, "dtype"), Scalar::String("Float"))
  // `revenue` had one null in the original frame; the kept widgets
  // came from non-null rows, so the projection has full coverage.
  assert_eq(summary.get(3, "null_count"), Scalar::Int(0))

  // Snapshot the full markdown table — pins schema + width logic. String
  // min/max are lexicographic, so the region `max` is "west", not "north".
  let expected =
    #|| column   | dtype  | count | null_count | unique_count | mean | min  | max  |
    #|| -------- | ------ | ----- | ---------- | ------------ | ---- | ---- | ---- |
    #|| region   | String | 3     | 0          | 3            |      | east | west |
    #|| price    | Float  | 3     | 0          | 1            | 9.5  | 9.5  | 9.5  |
    #|| quantity | Int    | 3     | 0          | 3            | 8    | 5    | 12   |
    #|| revenue  | Float  | 3     | 0          | 3            | 76   | 47.5 | 114  |
    #|
  assert_eq(summary.to_markdown(), expected)
}

// ── JSON round-trip via the facade ────────────────────────────────────

///|
test "pipeline: format_json_records → parse_json_records_str round-trip" {
  // Hand-build a frame from typed Series so we can exercise the
  // re-exported Series constructors as well as the IO ones.
  let df = DataFrame::new([
    Series::from_ints("id", [1, 2, 3]),
    Series::from_strings("name", ["alice", "bob", "carol"]),
    Series::from_float_options("score", [Some(91.5), None, Some(73.0)]),
  ])
  assert_eq(df.check_invariants(), Ok(()))
  let json = format_json_records(df)
  let restored = parse_json_records_str(json, JsonReadOptions::default())
  assert_eq(restored.shape(), df.shape())
  assert_eq(restored.columns(), df.columns())
  assert_eq(restored.get(0, "id"), Scalar::Int(1))
  assert_eq(restored.get(1, "score"), Scalar::Null)
  assert_eq(restored.get(2, "name"), Scalar::String("carol"))
  assert_eq(restored.check_invariants(), Ok(()))
}

// ── NDJSON round-trip via the facade ──────────────────────────────────

///|
test "pipeline: format_ndjson → parse_ndjson_str round-trip" {
  // Exercises the re-exported NDJSON surface (`format_ndjson` /
  // `parse_ndjson_str` / `NdjsonReadOptions`); a missing facade
  // re-export would surface as a type error in this file.
  let df = DataFrame::new([
    Series::from_ints("id", [1, 2, 3]),
    Series::from_strings("name", ["alice", "bob", "carol"]),
    Series::from_float_options("score", [Some(91.5), None, Some(73.0)]),
  ])
  assert_eq(df.check_invariants(), Ok(()))
  let ndjson = format_ndjson(df)
  let restored = parse_ndjson_str(ndjson, NdjsonReadOptions::default())
  assert_eq(restored.shape(), df.shape())
  assert_eq(restored.columns(), df.columns())
  assert_eq(restored.get(0, "id"), Scalar::Int(1))
  assert_eq(restored.get(1, "score"), Scalar::Null)
  assert_eq(restored.get(2, "name"), Scalar::String("carol"))
  assert_eq(restored.check_invariants(), Ok(()))
}

// ── Null-handling pipeline ────────────────────────────────────────────

///|
test "pipeline: drop_nulls / fill_null / null_count compose via the facade" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3), Some(4)]),
    Series::from_string_options("b", [Some("x"), Some("y"), None, Some("z")]),
    Series::from_float_options("c", [Some(1.0), Some(2.0), Some(3.0), None]),
  ])

  // Per-column null counts up-front: 1 / 1 / 1.
  let counts = df.null_count()
  assert_eq(counts.shape(), (1, 3))
  assert_eq(counts.get(0, "a"), Scalar::Int(1))
  assert_eq(counts.get(0, "b"), Scalar::Int(1))
  assert_eq(counts.get(0, "c"), Scalar::Int(1))

  // Gate only on `a` — rows 0/2/3 survive (row 1 has a null `a`); the
  // null `b` on row 2 and the null `c` on row 3 are tolerated because
  // those columns are unlisted.
  let gated = df.drop_nulls(subset=[col("a")])
  assert_eq(gated.nrows(), 3)
  assert_eq(gated.check_invariants(), Ok(()))
  assert_eq(gated.get(1, "b"), Scalar::Null)
  assert_eq(gated.get(2, "c"), Scalar::Null)

  // Fill the surviving null cells with dtype-matched scalars.
  let filled = gated
    .fill_null("b", Scalar::String("-"))
    .fill_null("c", Scalar::Float(0.0))
  assert_eq(filled.get(1, "b"), Scalar::String("-"))
  assert_eq(filled.get(2, "c"), Scalar::Float(0.0))
  assert_eq(filled.check_invariants(), Ok(()))

  // After filling, every column reports zero nulls.
  let after = filled.null_count()
  assert_eq(after.get(0, "a"), Scalar::Int(0))
  assert_eq(after.get(0, "b"), Scalar::Int(0))
  assert_eq(after.get(0, "c"), Scalar::Int(0))
}

// ── Stats + describe via the facade ───────────────────────────────────

///|
test "pipeline: per-column scalars and whole-frame reductions via the facade" {
  let df = DataFrame::new([
    Series::from_int_options("n", [Some(1), Some(2), None, Some(4)]),
    Series::from_strings("tag", ["a", "b", "c", "d"]),
  ])
  // A single column's scalar reduction reads through its Series (the v0.4
  // `df.sum("n")` migration target).
  assert_eq(df.get_column("n").count(), 3)
  assert_eq(df.get_column("n").sum(), Scalar::Int(7))
  // 1 + 2 + 4 == 7, n_non_null == 3 → mean == 7 / 3.
  let m = df.get_column("n").mean()
  assert_true((m - 7.0 / 3.0).abs() < 1.0e-6)
  assert_eq(df.get_column("n").min_value(), Scalar::Int(1))
  assert_eq(df.get_column("n").max_value(), Scalar::Int(4))

  // The whole-frame reductions return a 1-row frame: the numeric column
  // reduces, the non-numeric column becomes a Null cell, count counts both.
  let summed = df.sum()
  assert_eq(summed.shape(), (1, 2))
  assert_eq(summed.get(0, "n"), Scalar::Int(7))
  assert_eq(summed.get(0, "tag"), Scalar::Null)
  assert_eq(df.count().get(0, "tag"), Scalar::Int(4))

  // The explicit per-column sum still rejects a non-numeric column, while the
  // whole-frame sum above tolerates it by nulling.
  assert_true((try? df.get_column("tag").sum()) is Err(_))
}

// ── GroupBy via the facade ────────────────────────────────────────────

///|
test "pipeline: group_by → agg → sort produces a grouped summary via the facade" {
  let df = DataFrame::new([
    Series::from_strings("region", ["west", "east", "west", "east", "west"]),
    Series::from_ints("quantity", [12, 7, 4, 5, 8]),
    Series::from_floats("revenue", [120.0, 66.5, 30.0, 47.5, 90.0]),
  ])
  // `group_by` returns a `GroupedDataFrame` (re-exported type) and `agg`
  // takes reduction expressions built from the re-exported `col` — all
  // through the facade. A missing re-export would surface as a type error
  // in this file.
  let grouped : GroupedDataFrame = df.group_by([col("region")])
  let summary = grouped
    .agg([
      col("quantity").count().with_alias("quantity_count"),
      col("quantity").sum().with_alias("total_q"),
      col("revenue").mean().with_alias("avg_rev"),
    ])
    .sort([(col("total_q"), SortOrder::Desc, NullOrder::NullsLast)])
  assert_eq(summary.check_invariants(), Ok(()))
  assert_eq(summary.columns(), [
    "region", "quantity_count", "total_q", "avg_rev",
  ])
  assert_eq(summary.shape(), (2, 4))
  // total_q descending puts west (24) before east (12).
  assert_eq(summary.get(0, "region"), Scalar::String("west"))
  assert_eq(summary.get(0, "quantity_count"), Scalar::Int(3))
  assert_eq(summary.get(0, "total_q"), Scalar::Int(24))
  assert_eq(summary.get(0, "avg_rev"), Scalar::Float(80.0)) // (120+30+90)/3
  assert_eq(summary.get(1, "region"), Scalar::String("east"))
  assert_eq(summary.get(1, "total_q"), Scalar::Int(12))
  assert_eq(summary.get(1, "avg_rev"), Scalar::Float(57.0)) // (66.5+47.5)/2
}

// ── Join via the facade ───────────────────────────────────────────────

///|
test "pipeline: join enriches a frame then sorts via the facade" {
  // Orders (left) reference a customer by id; customers (right) carry the
  // region. `JoinType` / `JoinOptions` are named explicitly so a missing
  // facade re-export surfaces as a type error in this file.
  let _ : JoinType = JoinType::Inner
  let orders = DataFrame::new([
    Series::from_ints("order_id", [1, 2, 3, 4]),
    Series::from_ints("customer_id", [10, 20, 10, 99]),
    Series::from_ints("amount", [100, 50, 70, 30]),
  ])
  let customers = DataFrame::new([
    Series::from_ints("customer_id", [10, 20, 30]),
    Series::from_strings("region", ["west", "east", "north"]),
  ])

  // Inner join via the explicit options form, then sort by amount desc.
  let opts : JoinOptions = JoinOptions::on([col("customer_id")])
  let enriched = orders
    .join(customers, opts)
    .sort([(col("amount"), SortOrder::Desc, NullOrder::NullsLast)])
  assert_eq(enriched.check_invariants(), Ok(()))
  // Order 4 (customer 99) has no matching customer → dropped by inner join;
  // the key column appears once, then the right's non-key "region".
  assert_eq(enriched.columns(), ["order_id", "customer_id", "amount", "region"])
  assert_eq(enriched.shape(), (3, 4))
  // amount desc: 100 (west) → 70 (west) → 50 (east).
  assert_eq(enriched.get(0, "amount"), Scalar::Int(100))
  assert_eq(enriched.get(0, "region"), Scalar::String("west"))
  assert_eq(enriched.get(2, "region"), Scalar::String("east"))

  // The left join keeps the unmatched order; per the Polars auto-coalesce
  // default it also keeps the right key as customer_id_right, null on the
  // unmatched row (order 4, customer 99).
  let all_orders = orders.join(
    customers,
    JoinOptions::on([col("customer_id")]).with_how(JoinType::Left),
  )
  assert_eq(all_orders.columns(), [
    "order_id", "customer_id", "amount", "customer_id_right", "region",
  ])
  assert_eq(all_orders.shape(), (4, 5))
  assert_eq(all_orders.get(3, "order_id"), Scalar::Int(4))
  assert_eq(all_orders.get(3, "customer_id_right"), Scalar::Null)
  assert_eq(all_orders.get(3, "region"), Scalar::Null)

  // Cross join reachable through the facade (JoinType::Cross + JoinOptions).
  let _ : JoinType = JoinType::Cross
  assert_eq(orders.join(customers, JoinOptions::cross()).shape(), (12, 5)) // 4 x 3
}

// ── Column ops + with_column / replace_column via the facade ──────────

///|
test "pipeline: rename / drop / with_column / replace_column compose cleanly" {
  let df = DataFrame::new([
    Series::from_ints("x", [1, 2, 3]),
    Series::from_ints("y", [10, 20, 30]),
  ])

  // Append a derived column then rename it.
  let renamed = df
    .with_column(Series::from_ints("sum", [11, 22, 33]))
    .rename([("sum", "total")])
  assert_eq(renamed.columns(), ["x", "y", "total"])

  // Drop the original "y" and verify the remaining schema.
  let dropped = renamed.drop([col("y")])
  assert_eq(dropped.columns(), ["x", "total"])
  assert_eq(dropped.check_invariants(), Ok(()))

  // Replace "x" with a new dtype (cross-dtype swap is allowed).
  let swapped = dropped.replace_column(
    "x",
    Series::from_strings("x", ["a", "b", "c"]),
  )
  assert_eq(swapped.get_column("x").dtype(), DataType::String)
  assert_eq(swapped.check_invariants(), Ok(()))
}

// ── Bitmap / BuiltinColumn reachable for low-level callers ────────────

///|
test "pipeline: facade exposes column-layer primitives (Bitmap, BuiltinColumn, ColumnData)" {
  // `Bitmap::from_bools` and `BuiltinColumn::from_int_options` both
  // travel through the facade; the assertion is structural — if the
  // re-exports were missing, the file would fail to compile.
  let bm = Bitmap::from_bools([true, false, true, true])
  assert_eq(bm.len(), 4)
  assert_eq(bm.null_count(), 1)
  let col = BuiltinColumn::from_int_options([Some(10), None, Some(30)])
  assert_eq(col.len(), 3)
  assert_eq(col.null_count(), 1)
  // Reach into the typed accessor (zero-boxing fast path) — this also
  // structurally confirms `ColumnData::Int` is re-exported via the
  // facade (the constructor alias kicks in automatically through
  // `pub using @column { type ColumnData }`).
  let (data, validity) = col.int_values()
  assert_eq(data.length(), 3)
  assert_eq(validity.is_valid(1), false)
  assert_true(col.data is ColumnData::Int(_))
}

// ── filter error propagation ──────────────────────────────────────────

///|
test "pipeline: filter surfaces predicate evaluation errors instead of swallowing them" {
  let df = DataFrame::new([Series::from_ints("n", [1, 2, 3])])
  // The predicate references a misspelled column; the evaluator's
  // `ColumnNotFound` must propagate verbatim, *not* collapse to
  // "row excluded".
  let result = try? df.filter(col("nope").gt(lit_int(0)))
  assert_true(result is Err(DataError::ColumnNotFound("nope")))
}

// ── Schema / Field reachable through the facade ───────────────────────

///|
test "pipeline: Schema and Field surface for callers building empty frames" {
  let schema = Schema::new([
    Field::new("id", DataType::Int),
    Field::with_nullable("note", DataType::String, false),
  ])
  assert_eq(schema.len(), 2)
  assert_eq(schema.field_names(), ["id", "note"])
  let empty = DataFrame::empty(schema)
  assert_eq(empty.shape(), (0, 2))
  assert_eq(empty.check_invariants(), Ok(()))
}
