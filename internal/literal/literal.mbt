// Display-syntax rendering for literal scalars, shared by the expression
// explain renderer and the lazy plan printer so the two spellings can never
// drift apart. Internal: it is a renderer detail, not a value-formatting API
// users should depend on (`Scalar::to_string` is the user-facing form).

///|
/// Display-syntax rendering of a literal `Scalar` — the one spelling shared
/// by the `expr` explain renderer and the `lazy` plan printer, so the two
/// can never drift apart (each used to carry a hand-synced private copy).
/// `Int` / `Bool` render bare, a `String` is quoted and
/// `@text.escape_debug`-escaped so it stays distinguishable and on one line, and
/// the (unevaluatable) null literal renders as `null`. A `Float` stays
/// distinct from an `Int`: `Double::to_string` prints a finite whole value
/// without a decimal point (`1.0` -> `"1"`), so a `.0` suffix is re-added,
/// and it drops the sign of negative zero (`-0.0` -> `"0"`) even though the
/// two zeros evaluate observably differently under division
/// (`1.0 / -0.0 = -inf`), so the sign is re-added from the sign bit;
/// `NaN` / `Infinity` / `-Infinity` are non-finite and keep their own
/// spelling. Display syntax, not the debug form `Scalar`'s own `Show`
/// produces.
pub fn format_scalar(value : @types.Scalar) -> String {
  match value {
    Int(v) => v.to_string()
    Float(v) =>
      if v == 0.0 && v.reinterpret_as_int64() != 0L {
        "-0.0"
      } else {
        let s = v.to_string()
        let finite = v - v == 0.0
        let has_point = s.iter().any(c => c == '.' || c == 'e' || c == 'E')
        if finite && !has_point {
          s + ".0"
        } else {
          s
        }
      }
    Bool(v) => v.to_string()
    String(v) => "\"\{@text.escape_debug(v)}\""
    Null => "null"
  }
}
