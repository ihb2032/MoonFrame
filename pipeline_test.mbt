// Integration tests for the facade package. Every symbol used here is
// reached through `ihb2032/MoonFrame` (no `@types` / `@frame` / `@ops`
// / `@io` qualifications), so these tests double as the practical
// completeness check for the `pub using` re-exports in
// `moonframe.mbt`. A missing re-export here surfaces as a type error
// rather than a silent gap in the public surface.

// ── End-to-end file-backed pipeline (matches PLAN §6.4) ──────────────

///|
test "pipeline: read_csv → filter → select → sort_by → describe → to_markdown" {
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
  ]).unwrap()
  assert_eq(write_csv(path, staged), Ok(()))
  let df = read_csv(path).unwrap()
  assert_eq(df.check_invariants(), Ok(()))

  // filter (widgets only) → select → sort_by → describe → to_markdown.
  let widgets = filter_try(df, row => {
    row.get_string("product").map(name => name == "widget")
  }).unwrap()
  let projected = select(widgets, ["region", "quantity", "revenue"]).unwrap()
  let sorted = sort_by(projected, SortSpec::desc("quantity")).unwrap()
  let summary = describe(sorted).unwrap()

  // Quantity desc puts west first; describe should surface that.
  assert_eq(sorted.get(0, "region"), Ok(Scalar::String("west")))
  assert_eq(sorted.get(0, "quantity"), Ok(Scalar::Int(12)))
  assert_eq(sorted.nrows(), 3)

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
  assert_eq(to_markdown(summary), expected)
}

// ── End-to-end string-in CSV pipeline ─────────────────────────────────

///|
test "pipeline: parse_csv_str → filter → select → sort_by → describe → to_markdown" {
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
  let df = parse_csv_str(csv, CsvReadOptions::default()).unwrap()
  assert_eq(df.shape(), (6, 6))
  assert_eq(df.check_invariants(), Ok(()))

  // Keep rows whose product is "widget"; predicate must surface
  // accessor errors (column not found, dtype mismatch), so use
  // `filter_try` with `RowView::get_string`.
  let widgets = filter_try(df, row => {
    row.get_string("product").map(name => name == "widget")
  }).unwrap()
  assert_eq(widgets.nrows(), 3)
  assert_eq(widgets.check_invariants(), Ok(()))

  // Project a subset of columns to demonstrate `select` keeps the
  // requested column order.
  let projected = select(widgets, ["region", "price", "quantity", "revenue"]).unwrap()
  assert_eq(projected.columns(), ["region", "price", "quantity", "revenue"])
  assert_eq(projected.check_invariants(), Ok(()))

  // Sort by quantity descending — stable mergesort + NullsLast.
  let sorted = sort_by(projected, SortSpec::desc("quantity")).unwrap()
  assert_eq(sorted.check_invariants(), Ok(()))
  assert_eq(sorted.get(0, "region"), Ok(Scalar::String("west")))
  assert_eq(sorted.get(0, "quantity"), Ok(Scalar::Int(12)))
  assert_eq(sorted.get(2, "quantity"), Ok(Scalar::Int(5)))

  // Per-column summary — fixed N×8 schema, one row per source column.
  let summary = describe(sorted).unwrap()
  assert_eq(summary.shape(), (4, 8))
  assert_eq(summary.columns(), [
    "column", "dtype", "count", "null_count", "unique_count", "mean", "min", "max",
  ])
  assert_eq(summary.get(0, "column"), Ok(Scalar::String("region")))
  assert_eq(summary.get(1, "dtype"), Ok(Scalar::String("Float")))
  // `revenue` had one null in the original frame; the kept widgets
  // came from non-null rows, so the projection has full coverage.
  assert_eq(summary.get(3, "null_count"), Ok(Scalar::Int(0)))

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
  assert_eq(to_markdown(summary), expected)
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
  ]).unwrap()
  assert_eq(df.check_invariants(), Ok(()))
  let json = format_json_records(df)
  let restored = parse_json_records_str(json, JsonReadOptions::default()).unwrap()
  assert_eq(restored.shape(), df.shape())
  assert_eq(restored.columns(), df.columns())
  assert_eq(restored.get(0, "id"), Ok(Scalar::Int(1)))
  assert_eq(restored.get(1, "score"), Ok(Scalar::Null))
  assert_eq(restored.get(2, "name"), Ok(Scalar::String("carol")))
  assert_eq(restored.check_invariants(), Ok(()))
}

// ── Null-handling pipeline ────────────────────────────────────────────

///|
test "pipeline: drop_nulls_in / fill_null / null_count compose via the facade" {
  let df = DataFrame::new([
    Series::from_int_options("a", [Some(1), None, Some(3), Some(4)]),
    Series::from_string_options("b", [Some("x"), Some("y"), None, Some("z")]),
    Series::from_float_options("c", [Some(1.0), Some(2.0), Some(3.0), None]),
  ]).unwrap()

  // Per-column null counts up-front: 1 / 1 / 1.
  let counts = null_count(df).unwrap()
  assert_eq(counts.shape(), (1, 3))
  assert_eq(counts.get(0, "a"), Ok(Scalar::Int(1)))
  assert_eq(counts.get(0, "b"), Ok(Scalar::Int(1)))
  assert_eq(counts.get(0, "c"), Ok(Scalar::Int(1)))

  // Gate only on `a` — rows 0/2/3 survive (row 1 has a null `a`); the
  // null `b` on row 2 and the null `c` on row 3 are tolerated because
  // those columns are unlisted.
  let gated = drop_nulls_in(df, ["a"]).unwrap()
  assert_eq(gated.nrows(), 3)
  assert_eq(gated.check_invariants(), Ok(()))
  assert_eq(gated.get(1, "b"), Ok(Scalar::Null))
  assert_eq(gated.get(2, "c"), Ok(Scalar::Null))

  // Fill the surviving null cells with dtype-matched scalars.
  let filled_b = fill_null(gated, "b", Scalar::String("-")).unwrap()
  let filled = fill_null(filled_b, "c", Scalar::Float(0.0)).unwrap()
  assert_eq(filled.get(1, "b"), Ok(Scalar::String("-")))
  assert_eq(filled.get(2, "c"), Ok(Scalar::Float(0.0)))
  assert_eq(filled.check_invariants(), Ok(()))

  // After filling, every column reports zero nulls.
  let after = null_count(filled).unwrap()
  assert_eq(after.get(0, "a"), Ok(Scalar::Int(0)))
  assert_eq(after.get(0, "b"), Ok(Scalar::Int(0)))
  assert_eq(after.get(0, "c"), Ok(Scalar::Int(0)))
}

// ── Stats + describe via the facade ───────────────────────────────────

///|
test "pipeline: count / sum / mean / min / max all reach Series-equivalent results" {
  let df = DataFrame::new([
    Series::from_int_options("n", [Some(1), Some(2), None, Some(4)]),
    Series::from_strings("tag", ["a", "b", "c", "d"]),
  ]).unwrap()
  assert_eq(count(df, "n"), Ok(3))
  assert_eq(sum(df, "n"), Ok(Scalar::Int(7)))
  // 1 + 2 + 4 == 7, n_non_null == 3 → mean == 7 / 3.
  let m = mean(df, "n").unwrap()
  assert_true((m - 7.0 / 3.0).abs() < 1.0e-6)
  assert_eq(min(df, "n"), Ok(Scalar::Int(1)))
  assert_eq(max(df, "n"), Ok(Scalar::Int(4)))

  // Non-numeric column rejects the numeric reductions.
  assert_true(sum(df, "tag") is Err(_))
  assert_true(mean(df, "tag") is Err(_))
}

// ── Column ops + with_column / replace_column via the facade ──────────

///|
test "pipeline: rename / drop / with_column / replace_column compose cleanly" {
  let df = DataFrame::new([
    Series::from_ints("x", [1, 2, 3]),
    Series::from_ints("y", [10, 20, 30]),
  ]).unwrap()

  // Append a derived column then rename it.
  let with_sum = with_column(df, Series::from_ints("sum", [11, 22, 33])).unwrap()
  let renamed = rename(with_sum, [("sum", "total")]).unwrap()
  assert_eq(renamed.columns(), ["x", "y", "total"])

  // Drop the original "y" and verify the remaining schema.
  let dropped = drop(renamed, ["y"]).unwrap()
  assert_eq(dropped.columns(), ["x", "total"])
  assert_eq(dropped.check_invariants(), Ok(()))

  // Replace "x" with a new dtype (cross-dtype swap is allowed).
  let swapped = replace_column(
    dropped,
    "x",
    Series::from_strings("x", ["a", "b", "c"]),
  ).unwrap()
  assert_eq(swapped.get_column("x").unwrap().dtype(), DataType::String)
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
  let (data, validity) = col.int_values().unwrap()
  assert_eq(data.length(), 3)
  assert_eq(validity.is_valid(1), Ok(false))
  assert_true(col.data is ColumnData::Int(_))
}

// ── filter_try error propagation ──────────────────────────────────────

///|
test "pipeline: filter_try surfaces RowView accessor errors instead of swallowing them" {
  let df = DataFrame::new([Series::from_ints("n", [1, 2, 3])]).unwrap()
  // Predicate misspells the column name; the first `Err` returned by
  // `RowView::get_int` must propagate verbatim, *not* collapse to
  // "row excluded".
  let result = filter_try(df, row => row.get_int("nope").map(v => v > 0))
  assert_true(result is Err(DataError::ColumnNotFound("nope")))
}

// ── Schema / Field reachable through the facade ───────────────────────

///|
test "pipeline: Schema and Field surface for callers building empty frames" {
  let schema = Schema::new([
    Field::new("id", DataType::Int),
    Field::with_nullable("note", DataType::String, false),
  ]).unwrap()
  assert_eq(schema.len(), 2)
  assert_eq(schema.field_names(), ["id", "note"])
  let empty = DataFrame::empty(schema).unwrap()
  assert_eq(empty.shape(), (0, 2))
  assert_eq(empty.check_invariants(), Ok(()))
}
