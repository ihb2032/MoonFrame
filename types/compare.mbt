// Comparison primitives the expression evaluator's kernels share that are not
// tied to a single `Scalar` or numeric type. The exact `Int64`/`Double`
// comparisons live in `double.mbt`; this is the text side.

///|
/// Dictionary-order comparison of two `String` cells (`< 0` / `0` / `> 0`) — the
/// raw primitive the expression evaluator's `String` comparison kernel reduces
/// to, beside the exact-numeric `int64_*` primitives it already shares. By
/// Unicode code point, not MoonBit's built-in shortlex.
#doc(hidden)
#internal(engine, "MoonFrame execution engine API")
pub fn compare_strings_lex(a : String, b : String) -> Int {
  @text.compare_string_lex(a, b)
}
