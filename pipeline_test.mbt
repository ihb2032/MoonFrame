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
  let staged = DataFrame::DataFrame([
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
  assert_eq(report.item(0, "region"), Scalar::String("west"))
  assert_eq(report.item(0, "quantity"), Scalar::Int(12))
  assert_eq(report.nrows(), 3)

  // Snapshot the full markdown — the renderer is deterministic for a
  // given frame, so this pins both the schema (header / dash row) and
  // the column-width logic. String min/max use lexicographic order, so
  // the region `max` is "west" (not shortlex's longest, "north").
  let expected =
    #|| column   | dtype  | count | null_count | n_unique | mean | min  | max  |
    #|| -------- | ------ | ----- | ---------- | -------- | ---- | ---- | ---- |
    #|| region   | String | 3     | 0          | 3        |      | east | west |
    #|| quantity | Int    | 3     | 0          | 3        | 8    | 5    | 12   |
    #|| revenue  | Float  | 3     | 0          | 3        | 76   | 47.5 | 114  |
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
  let df = parse_csv_str(csv)
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
  assert_eq(sorted.item(0, "region"), Scalar::String("west"))
  assert_eq(sorted.item(0, "quantity"), Scalar::Int(12))
  assert_eq(sorted.item(2, "quantity"), Scalar::Int(5))

  // Per-column summary — fixed N×8 schema, one row per source column.
  let summary = sorted.describe()
  assert_eq(summary.shape(), (4, 8))
  assert_eq(summary.columns(), [
    "column", "dtype", "count", "null_count", "n_unique", "mean", "min", "max",
  ])
  assert_eq(summary.item(0, "column"), Scalar::String("region"))
  assert_eq(summary.item(1, "dtype"), Scalar::String("Float"))
  // `revenue` had one null in the original frame; the kept widgets
  // came from non-null rows, so the projection has full coverage.
  assert_eq(summary.item(3, "null_count"), Scalar::Int(0))

  // Snapshot the full markdown table — pins schema + width logic. String
  // min/max are lexicographic, so the region `max` is "west", not "north".
  let expected =
    #|| column   | dtype  | count | null_count | n_unique | mean | min  | max  |
    #|| -------- | ------ | ----- | ---------- | -------- | ---- | ---- | ---- |
    #|| region   | String | 3     | 0          | 3        |      | east | west |
    #|| price    | Float  | 3     | 0          | 1        | 9.5  | 9.5  | 9.5  |
    #|| quantity | Int    | 3     | 0          | 3        | 8    | 5    | 12   |
    #|| revenue  | Float  | 3     | 0          | 3        | 76   | 47.5 | 114  |
    #|
  assert_eq(summary.to_markdown(), expected)
}

// ── JSON round-trip via the facade ────────────────────────────────────

///|
test "pipeline: format_json → parse_json_str round-trip" {
  // Hand-build a frame from typed Series so we can exercise the
  // re-exported Series constructors as well as the IO ones.
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2, 3]),
    Series::from_strings("name", ["alice", "bob", "carol"]),
    Series::from_float_options("score", [Some(91.5), None, Some(73.0)]),
  ])
  assert_eq(df.check_invariants(), Ok(()))
  let json = format_json(df)
  let restored = parse_json_str(json)
  assert_eq(restored.shape(), df.shape())
  assert_eq(restored.columns(), df.columns())
  assert_eq(restored.item(0, "id"), Scalar::Int(1))
  assert_eq(restored.item(1, "score"), Scalar::Null)
  assert_eq(restored.item(2, "name"), Scalar::String("carol"))
  assert_eq(restored.check_invariants(), Ok(()))
}

// ── NDJSON round-trip via the facade ──────────────────────────────────

///|
test "pipeline: format_ndjson → parse_ndjson_str round-trip" {
  // Exercises the re-exported NDJSON surface (`format_ndjson` /
  // `parse_ndjson_str` / `JsonReadOptions`); a missing facade
  // re-export would surface as a type error in this file.
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1, 2, 3]),
    Series::from_strings("name", ["alice", "bob", "carol"]),
    Series::from_float_options("score", [Some(91.5), None, Some(73.0)]),
  ])
  assert_eq(df.check_invariants(), Ok(()))
  let ndjson = format_ndjson(df)
  let restored = parse_ndjson_str(ndjson)
  assert_eq(restored.shape(), df.shape())
  assert_eq(restored.columns(), df.columns())
  assert_eq(restored.item(0, "id"), Scalar::Int(1))
  assert_eq(restored.item(1, "score"), Scalar::Null)
  assert_eq(restored.item(2, "name"), Scalar::String("carol"))
  assert_eq(restored.check_invariants(), Ok(()))
}

// ── Null-handling pipeline ────────────────────────────────────────────

///|
test "pipeline: drop_nulls / fill_null / null_count compose via the facade" {
  let df = DataFrame::DataFrame([
    Series::from_int_options("a", [Some(1), None, Some(3), Some(4)]),
    Series::from_string_options("b", [Some("x"), Some("y"), None, Some("z")]),
    Series::from_float_options("c", [Some(1.0), Some(2.0), Some(3.0), None]),
  ])

  // Per-column null counts up-front: 1 / 1 / 1.
  let counts = df.null_count()
  assert_eq(counts.shape(), (1, 3))
  assert_eq(counts.item(0, "a"), Scalar::Int(1))
  assert_eq(counts.item(0, "b"), Scalar::Int(1))
  assert_eq(counts.item(0, "c"), Scalar::Int(1))

  // Gate only on `a` — rows 0/2/3 survive (row 1 has a null `a`); the
  // null `b` on row 2 and the null `c` on row 3 are tolerated because
  // those columns are unlisted.
  let gated = df.drop_nulls(subset=[col("a")])
  assert_eq(gated.nrows(), 3)
  assert_eq(gated.check_invariants(), Ok(()))
  assert_eq(gated.item(1, "b"), Scalar::Null)
  assert_eq(gated.item(2, "c"), Scalar::Null)

  // Fill the surviving null cells with the per-column `Expr::fill_null`
  // through `with_columns` — each replaces its own column in place.
  let filled = gated.with_columns([
    col("b").fill_null(lit_str("-")),
    col("c").fill_null(lit_float(0.0)),
  ])
  assert_eq(filled.item(1, "b"), Scalar::String("-"))
  assert_eq(filled.item(2, "c"), Scalar::Float(0.0))
  assert_eq(filled.check_invariants(), Ok(()))

  // After filling, every column reports zero nulls.
  let after = filled.null_count()
  assert_eq(after.item(0, "a"), Scalar::Int(0))
  assert_eq(after.item(0, "b"), Scalar::Int(0))
  assert_eq(after.item(0, "c"), Scalar::Int(0))

  // The frame-wide `fill_null(value)` fills only the dtype-compatible
  // columns: a String value fills `b`, leaving the Int `a` and Float `c`
  // columns untouched.
  let bonly = gated.fill_null(Scalar::String("?"))
  assert_eq(bonly.item(1, "b"), Scalar::String("?"))
  assert_eq(bonly.item(2, "c"), Scalar::Null)
  assert_eq(bonly.check_invariants(), Ok(()))
}

// ── Stats + describe via the facade ───────────────────────────────────

///|
test "pipeline: per-column scalars and whole-frame reductions via the facade" {
  let df = DataFrame::DataFrame([
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
  assert_eq(df.get_column("n").min(), Scalar::Int(1))
  assert_eq(df.get_column("n").max(), Scalar::Int(4))

  // The whole-frame reductions return a 1-row frame: the numeric column
  // reduces, the non-numeric column becomes a Null cell, count counts both.
  let summed = df.sum()
  assert_eq(summed.shape(), (1, 2))
  assert_eq(summed.item(0, "n"), Scalar::Int(7))
  assert_eq(summed.item(0, "tag"), Scalar::Null)
  assert_eq(df.count().item(0, "tag"), Scalar::Int(4))

  // The explicit per-column sum still rejects a non-numeric column, while the
  // whole-frame sum above tolerates it by nulling.
  assert_true((Ok(df.get_column("tag").sum()) catch { e => Err(e) }) is Err(_))
}

// ── GroupBy via the facade ────────────────────────────────────────────

///|
test "pipeline: group_by → agg → sort produces a grouped summary via the facade" {
  let df = DataFrame::DataFrame([
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
  assert_eq(summary.item(0, "region"), Scalar::String("west"))
  assert_eq(summary.item(0, "quantity_count"), Scalar::Int(3))
  assert_eq(summary.item(0, "total_q"), Scalar::Int(24))
  assert_eq(summary.item(0, "avg_rev"), Scalar::Float(80.0)) // (120+30+90)/3
  assert_eq(summary.item(1, "region"), Scalar::String("east"))
  assert_eq(summary.item(1, "total_q"), Scalar::Int(12))
  assert_eq(summary.item(1, "avg_rev"), Scalar::Float(57.0)) // (66.5+47.5)/2
}

// ── Join via the facade ───────────────────────────────────────────────

///|
test "pipeline: join enriches a frame then sorts via the facade" {
  // Orders (left) reference a customer by id; customers (right) carry the
  // region. `JoinType` / `JoinOptions` are named explicitly so a missing
  // facade re-export surfaces as a type error in this file.
  let _ : JoinType = JoinType::Inner
  let orders = DataFrame::DataFrame([
    Series::from_ints("order_id", [1, 2, 3, 4]),
    Series::from_ints("customer_id", [10, 20, 10, 99]),
    Series::from_ints("amount", [100, 50, 70, 30]),
  ])
  let customers = DataFrame::DataFrame([
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
  assert_eq(enriched.item(0, "amount"), Scalar::Int(100))
  assert_eq(enriched.item(0, "region"), Scalar::String("west"))
  assert_eq(enriched.item(2, "region"), Scalar::String("east"))

  // The left join keeps the unmatched order; per the Polars auto-coalesce
  // default a left join coalesces the key, so customer_id appears once and
  // carries the left value (99) on the unmatched row (order 4), where region
  // is null.
  let all_orders = orders.join(
    customers,
    JoinOptions::on([col("customer_id")], how=JoinType::Left),
  )
  assert_eq(all_orders.columns(), [
    "order_id", "customer_id", "amount", "region",
  ])
  assert_eq(all_orders.shape(), (4, 4))
  assert_eq(all_orders.item(3, "order_id"), Scalar::Int(4))
  assert_eq(all_orders.item(3, "customer_id"), Scalar::Int(99))
  assert_eq(all_orders.item(3, "region"), Scalar::Null)

  // Cross join reachable through the facade (JoinType::Cross + JoinOptions).
  let _ : JoinType = JoinType::Cross
  assert_eq(orders.join(customers, JoinOptions::cross()).shape(), (12, 5)) // 4 x 3
}

// ── Column ops + with_columns via the facade ─────────

///|
test "pipeline: rename / drop / with_columns compose cleanly" {
  let df = DataFrame::DataFrame([
    Series::from_ints("x", [1, 2, 3]),
    Series::from_ints("y", [10, 20, 30]),
  ])

  // Append a derived column then rename it.
  let renamed = df
    .with_columns([lit_series(Series::from_ints("sum", [11, 22, 33]))])
    .rename([("sum", "total")])
  assert_eq(renamed.columns(), ["x", "y", "total"])

  // Drop the original "y" and verify the remaining schema.
  let dropped = renamed.drop([col("y")])
  assert_eq(dropped.columns(), ["x", "total"])
  assert_eq(dropped.check_invariants(), Ok(()))

  // Replace "x" with a new dtype: a same-named `lit_series` swaps in place
  // (cross-dtype swap is allowed).
  let swapped = dropped.with_columns([
    lit_series(Series::from_strings("x", ["a", "b", "c"])),
  ])
  assert_eq(swapped.get_column("x").dtype(), DataType::String)
  assert_eq(swapped.check_invariants(), Ok(()))
}

// ── filter error propagation ──────────────────────────────────────────

///|
test "pipeline: filter surfaces predicate evaluation errors instead of swallowing them" {
  let df = DataFrame::DataFrame([Series::from_ints("n", [1, 2, 3])])
  // The predicate references a misspelled column; the evaluator's
  // `ColumnNotFound` must propagate verbatim, *not* collapse to
  // "row excluded".
  let result = Ok(df.filter(col("nope").gt(lit_int(0)))) catch { e => Err(e) }
  assert_true(result is Err(DataError::ColumnNotFound("nope")))
}

// ── Schema / Field reachable through the facade ───────────────────────

///|
test "pipeline: Schema and Field surface for callers building empty frames" {
  let schema = Schema::Schema([
    Field("id", DataType::Int),
    Field("note", DataType::String, nullable=false),
  ])
  assert_eq(schema.len(), 2)
  assert_eq(schema.field_names(), ["id", "note"])
  let empty = DataFrame::empty(schema)
  assert_eq(empty.shape(), (0, 2))
  assert_eq(empty.check_invariants(), Ok(()))
}

// ── expression vocabulary reachable through the facade ────────────────

///|
test "pipeline: ClosedInterval is reachable unqualified" {
  // The `closed` endpoint enum must ride the facade like SortOrder /
  // KeepStrategy do — a missing re-export would fail to compile here.
  let df = DataFrame::DataFrame([Series::from_ints("n", [1, 2, 3])])
  let kept = df.filter(
    col("n").is_between(lit_int(1), lit_int(3), closed=ClosedInterval::Left),
  )
  assert_eq(kept.nrows(), 2)
}

// ── column selectors reachable through the facade ─────────────────────

///|
test "pipeline: the column selectors are reachable unqualified" {
  // `numeric_cols` / `cols_of_dtype` / `cols_matching` are `@frame` free
  // functions; a missing `pub using` would make these fail to compile.
  let df = DataFrame::DataFrame([
    Series::from_ints("id", [1]),
    Series::from_floats("price", [2.0]),
    Series::from_strings("label", ["x"]),
  ])
  assert_eq(df.select(numeric_cols(df)).columns(), ["id", "price"])
  assert_eq(cols_of_dtype(df, DataType::String).length(), 1)
  assert_eq(df.select(cols_matching(df, "^p")).columns(), ["price"])
}
