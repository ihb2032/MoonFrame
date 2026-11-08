// Coverage pins for the writer's decimal refusal family — exercised
// through the package's own entry (`write_parquet_bytes`), because the
// coverage gate counts a line only inside its owning package.

///|
test "the writer's decimal refusals name the exceptional cells" {
  let nan_col = @series.Series::from_decimals("d", [Some(@types.Dec128::nan())])
  assert_true(
    (Ok(ignore(write_parquet_bytes([nan_col], ["d"], Uncompressed))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  let inf_col = @series.Series::from_decimals("d", [
    Some(@types.Dec128::infinity(neg=true)),
  ])
  assert_true(
    (Ok(ignore(write_parquet_bytes([inf_col], ["d"], Uncompressed))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  let deep = @series.Series::from_decimals("d", [
    Some(@types.Dec128::parse_opt("1E-19").unwrap()),
  ])
  assert_true(
    (Ok(ignore(write_parquet_bytes([deep], ["d"], Uncompressed))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // A magnitude past the INT64 interchange at the adaptive scale
  // refuses too — the unscaled lift leaves Int64.
  let wide = @series.Series::from_decimals("d", [
    Some(@types.Dec128::parse_opt("1E+30").unwrap()),
  ])
  assert_true(
    (Ok(ignore(write_parquet_bytes([wide], ["d"], Uncompressed))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}
