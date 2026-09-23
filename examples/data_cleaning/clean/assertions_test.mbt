///|
/// Bring the `@test` versions of `assert_eq` / `assert_not_eq` into scope
/// for every blackbox test in this package. The prelude versions are
/// deprecated in favor of these Debug-based assertions.
using @test {assert_eq}
