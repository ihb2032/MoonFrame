// MoonFrame example: null-handling round trip.
//
//   read_csv → null_count (before)
//            → drop_nulls (gate on `score`)
//            → fill_null (default `note` to "n/a")
//            → write_csv (round-trip back to disk)
//            → read_csv (verify the file matches expectations)
//
// Pipeline logic lives in the sibling `clean/` package so it is
// covered by `clean_test.mbt`. `main` is a thin orchestrator around
// `read_csv` / `write_csv` / `println` and is therefore marked
// `#coverage.skip` — every meaningful branch is in the helper.
//
// Run from the project root:
//     moon run examples/data_cleaning

///|
#coverage.skip
fn main {
  let path = "examples/data_cleaning/data.csv"
  let out_path = "_build/data_cleaning_cleaned.csv"
  // The whole round trip raises `DataError`; a single `try`/`catch` at
  // the top of `main` keeps the happy path a flat method chain and
  // prints a diagnostic on any failure.
  try {
    let df = @moonframe.read_csv(path)
    println("Source frame:")
    println(df.to_markdown())
    println("\nNulls per column:")
    println(df.null_count().to_markdown())
    let cleaned = @clean.clean(df)
    println("\nCleaned frame:")
    println(cleaned.to_markdown())
    // Round-trip the cleaned frame through `_build/` to demonstrate the
    // writer / reader staying in lock-step. The directory is created by
    // `moon test` runs as well, so it always exists.
    @moonframe.write_csv(out_path, cleaned)
    println("\nWrote cleaned frame to \{out_path}")
    let restored = @moonframe.read_csv(out_path)
    println(
      "Round-trip readback shape: \{restored.nrows()} rows, \{restored.ncols()} columns",
    )
    println(restored.to_markdown())
  } catch {
    e => println("data_cleaning failed: \{e.message()}")
  }
}
