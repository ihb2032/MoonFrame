///|
test "README moon.pkg import exposes the MoonFrame facade" {
  let (series, len) = readme_import_probe()
  assert_eq(series.name(), "value")
  assert_eq(len, 2)
}
