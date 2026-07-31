///|
/// Bring the `@test` version of `assert_eq` into scope for every `*_test.mbt`
/// in this package. The prelude version is deprecated in favor of this
/// Debug-based assertion.
using @test {assert_eq}
