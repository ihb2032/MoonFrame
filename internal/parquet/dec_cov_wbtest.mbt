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
    Some(@types.Dec128::parse_opt("1E-39").unwrap()),
  ])
  assert_true(
    (Ok(ignore(write_parquet_bytes([deep], ["d"], Uncompressed))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // A magnitude past even the 16-byte payload's 38 digits refuses too —
  // the lifted run leaves the wide interchange's own window.
  let wide = @series.Series::from_decimals("d", [
    Some(@types.Dec128::parse_opt("1E+39").unwrap()),
  ])
  assert_true(
    (Ok(ignore(write_parquet_bytes([wide], ["d"], Uncompressed))) catch {
      e => Err(e)
    })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // The per-cell encoder's own INT64 bound — the completeness fence
  // under the payload the adaptive pass would never hand it: a cell
  // past `Int64` handed a map that still names the INT64 interchange.
  let int64_map : DtypeMap = DtypeMap::{
    dtype: @types.DataType::Decimal,
    physical: Int64P,
    converted: Some(DecimalC),
    decimal_scale: 0,
    decimal_precision: 18,
    flba_width: -1,
  }
  let huge = @types.Dec128::parse_opt("1E+30").unwrap()
  let cell : Array[Byte] = []
  let fence = Ok(
    ignore(encode_plain_value(cell, @types.Scalar::Decimal(huge), int64_map)),
  ) catch {
    e => Err(e)
  }
  assert_true(fence is Err(@types.DataError::InvalidOperation(_)))
}
