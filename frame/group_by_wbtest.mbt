// Whitebox tests for `GroupedDataFrame`. Its fields are `priv`, so a
// corrupted-`groups` handle can only be planted from inside the package —
// exactly the internal-bug case `agg`'s re-validation guards against, raising
// `InvalidOperation` rather than letting a fold abort on a bad row index.

///|
test "agg rejects an in-package-corrupted groups handle" {
  let base = DataFrame::new([
    @series.Series::from_strings("region", ["east", "west", "east"]),
    @series.Series::from_ints("quantity", [10, 5, 2]),
  ])
  // Emptied group.
  let emptied = base.group_by([@expr.col("region")])
  emptied.groups[0].clear()
  assert_true(
    (Ok(emptied.agg([@expr.col("quantity").sum()])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // Stray (out-of-range) row index.
  let stray = base.group_by([@expr.col("region")])
  stray.groups[0][0] = 1_000_000
  assert_true(
    (Ok(stray.agg([@expr.col("quantity").sum()])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
  // Negative row index.
  let negative = base.group_by([@expr.col("region")])
  negative.groups[0][0] = -1
  assert_true(
    (Ok(negative.agg([@expr.col("quantity").sum()])) catch { e => Err(e) })
    is Err(@types.DataError::InvalidOperation(_)),
  )
}
