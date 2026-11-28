///|
/// Bring the test package's versions of `assert_eq` and `assert_true`
/// into scope for every blackbox test file in this package. The prelude
/// versions are deprecated in favor of these Debug-based assertions.
using @test {assert_eq}

///|
/// The names of the sheets the workbook `bytes` spell, in workbook order.
fn sheet_names(bytes : Bytes) -> Array[String] raise @types.DataError {
  xls_open(bytes).sheets()
}

///|
/// The grid of the sheet at `sheet` — the first when none is given.
fn sheet_grid(
  bytes : Bytes,
  sheet~ : Int32 = 0,
) -> XlsGrid raise @types.DataError {
  xls_open(bytes).grid(sheet~)
}
