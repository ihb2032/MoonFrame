///|
/// Bring the `@test` versions of `assert_eq` / `assert_not_eq` into scope
/// for every `*_test.mbt` in this package. The prelude versions are
/// deprecated in favor of these Debug-based assertions.
using @test {assert_eq, assert_not_eq}

///|
/// `Series` moved to the `series` package; bind it unqualified for the
/// blackbox tests in this package (which build fixtures via `Series::from_*`),
/// mirroring the same `using` in the package's main scope.
using @series {type Series}
