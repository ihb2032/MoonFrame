// MoonFrame example: null-handling round trip.
//
//   read_csv → null_count (before)
//            → drop_nulls_in (gate on `score`)
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
  let df = match @moonframe.read_csv(path) {
    Ok(d) => d
    Err(e) => {
      println("failed to read \{path}: \{e.message()}")
      return
    }
  }
  println("Source frame:")
  println(@moonframe.to_markdown(df))
  println("\nNulls per column:")
  println(@moonframe.to_markdown(@moonframe.null_count(df)))
  let cleaned = match @clean.clean(df) {
    Ok(d) => d
    Err(e) => {
      println("clean failed: \{e.message()}")
      return
    }
  }
  println("\nCleaned frame:")
  println(@moonframe.to_markdown(cleaned))

  // Round-trip the cleaned frame through `_build/` to demonstrate the
  // writer / reader staying in lock-step. The directory is created by
  // `moon test` runs as well, so it always exists.
  let out_path = "_build/data_cleaning_cleaned.csv"
  match @moonframe.write_csv(out_path, cleaned) {
    Ok(_) => println("\nWrote cleaned frame to \{out_path}")
    Err(e) => {
      println("write failed: \{e.message()}")
      return
    }
  }
  match @moonframe.read_csv(out_path) {
    Ok(restored) => {
      println(
        "Round-trip readback shape: \{restored.nrows()} rows, \{restored.ncols()} columns",
      )
      println(@moonframe.to_markdown(restored))
    }
    Err(e) => println("readback failed: \{e.message()}")
  }
}
