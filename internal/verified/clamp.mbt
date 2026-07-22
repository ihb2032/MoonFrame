///|
/// Clamp a requested row count into `[0, len]`: a negative `n` is an empty
/// result, an oversized one is everything, anything else passes through.
/// The shared bound for `head` / `tail` / row-capped rendering on both
/// `DataFrame` and `Series`, so the two layers cannot drift.
/// `clamp_take_spec` is the exact three-way definition, machine-checked for
/// every input.
pub fn clamp_take(
  n : Int,
  len : Int,
) -> Int where {
  proof_ensure: r => clamp_take_spec(n, len, r),
} {
  if n < 0 {
    0
  } else if n > len {
    len
  } else {
    n
  }
}
