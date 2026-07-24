// Blackbox tests for the data-cleaning helper. CSV inputs are driven
// through `parse_csv_str` so the tests are deterministic and
// file-free; `main.mbt` is the only piece that touches `read_csv` /
// `write_csv`.

///|
test "clean: drops rows with null `score` and fills remaining null `note` cells" {
  // Six rows mirroring `examples/data_cleaning/data.csv`: rows 2 and
  // 5 have null `score` (must drop), rows 3 and 6 have non-null
  // score with null note (must fill), row 4 has null name but
  // non-null score and note (must keep verbatim).
  let csv =
    #|id,name,score,note
    #|1,alice,91.5,first
    #|2,bob,,
    #|3,carol,73.0,
    #|4,,82.0,fourth
    #|5,dave,,fifth
    #|6,erin,68.5,
    #|
  let df = @moonframe.parse_csv_str(csv)
  let cleaned = clean(df)

  // 4 rows survive the `score` gate; columns stay in declaration order.
  assert_eq(cleaned.shape(), (4, 4))
  assert_eq(cleaned.columns(), ["id", "name", "score", "note"])
  assert_eq(cleaned.check_invariants(), Ok(()))

  // `score` survivors are 1 / 3 / 4 / 6, in source order.
  assert_eq(cleaned.item(0, "id"), @moonframe.Scalar::Int(1))
  assert_eq(cleaned.item(1, "id"), @moonframe.Scalar::Int(3))
  assert_eq(cleaned.item(2, "id"), @moonframe.Scalar::Int(4))
  assert_eq(cleaned.item(3, "id"), @moonframe.Scalar::Int(6))

  // The `score` column has no nulls left.
  assert_eq(cleaned.get_column("score").null_count(), 0)

  // The previously-null `note` cells (rows 3 and 6 in the source)
  // were filled with the sentinel; row 4's `note = "fourth"` was
  // untouched.
  assert_eq(cleaned.item(1, "note"), @moonframe.Scalar::String("n/a"))
  assert_eq(cleaned.item(3, "note"), @moonframe.Scalar::String("n/a"))
  assert_eq(cleaned.item(2, "note"), @moonframe.Scalar::String("fourth"))
  assert_eq(cleaned.get_column("note").null_count(), 0)

  // `name` was not part of the cleaning contract — row 4's null name
  // survives because gating is on `score` only.
  assert_eq(cleaned.item(2, "name"), @moonframe.Scalar::Null)
}

///|
test "clean: surfaces ColumnNotFound when the `score` column is missing" {
  // Pipeline assumes `score`. Without it the gating step fails up
  // front, so the caller sees a structured error instead of a
  // silently-mangled frame.
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
  ])
  assert_true(
    (Ok(clean(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("score")),
  )
}

///|
test "clean: surfaces ColumnNotFound when the `note` column is missing" {
  // `score` exists, gating succeeds → but `fill_null` then targets
  // `note`, which doesn't exist. The error must come back as
  // `ColumnNotFound("note")`, not a silent no-op.
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_int_options("score", [Some(1), None, Some(3)]),
  ])
  assert_true(
    (Ok(clean(df)) catch { e => Err(e) })
    is Err(@moonframe.DataError::ColumnNotFound("note")),
  )
}

///|
test "clean: passes through a frame that already has no nulls" {
  // No work to do — gating drops nothing, fill_null is a no-op
  // because `note` has no nulls. The frame should come back
  // structurally identical.
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("note", ["a", "b"]),
    @moonframe.Series::from_floats("score", [1.0, 2.0]),
  ])
  let cleaned = clean(df)
  assert_eq(cleaned.shape(), (2, 3))
  assert_eq(cleaned.columns(), ["id", "note", "score"])
  assert_eq(cleaned.item(0, "note"), @moonframe.Scalar::String("a"))
  assert_eq(cleaned.check_invariants(), Ok(()))
}
