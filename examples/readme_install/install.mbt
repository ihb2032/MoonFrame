// Compile-time consumer fixture for the package import shown in README.md.
// Keeping this in a separate package makes CI resolve the public facade through
// the documented `@moonframe` alias rather than through an internal package.

///|
fn readme_import_probe() -> (@moonframe.Series, Int) {
  let series : @moonframe.Series = @moonframe.Series::from_ints("value", [1, 2])
  (series, series.len())
}

///|
#coverage.skip
fn main {
  ignore(readme_import_probe())
}
