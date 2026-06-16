///|
/// Bring the `@test` versions of `assert_eq` / `assert_not_eq` into scope
/// for every `*_test.mbt` in this package. The prelude versions are
/// deprecated in favor of these Debug-based assertions.
using @test {assert_eq, assert_not_eq}

///|
/// `lit_series` embeds a `@series.Series`; bind the type unqualified for the
/// blackbox tests that build literal-series fixtures via `Series::from_*`.
using @series {type Series}
