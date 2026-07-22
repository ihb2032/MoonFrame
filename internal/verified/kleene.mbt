///|
/// Kleene three-valued AND over nullable booleans (the Polars / Arrow
/// `and_kleene` table): a known `false` dominates — the result is `false`
/// no matter what the other side holds, null included; two known `true`s
/// are `true`; everything else (a null meeting `true` or another null) is
/// unknown, `None`. `kleene_and_spec` states the full nine-cell table, so
/// the prover — not a sampled truth-table test — pins every cell.
pub fn kleene_and(
  a : Bool?,
  b : Bool?,
) -> Bool? where {
  proof_ensure: r => kleene_and_spec(a, b, r),
} {
  // Nested matches, not the tuple table: the prover's lowering rejects
  // tuple / or-patterns in a contracted body. Cell-for-cell the same
  // function, and the frame-level logic tests pin it end to end.
  match a {
    Some(av) =>
      match b {
        Some(bv) => Some(av && bv)
        None => if av { None } else { Some(false) }
      }
    None =>
      match b {
        Some(bv) => if bv { None } else { Some(false) }
        None => None
      }
  }
}

///|
/// Kleene three-valued OR over nullable booleans (the `or_kleene` dual):
/// a known `true` dominates regardless of the other side, null included;
/// two known `false`s are `false`; everything else is unknown, `None`.
/// `kleene_or_spec` is the full table, machine-checked.
pub fn kleene_or(
  a : Bool?,
  b : Bool?,
) -> Bool? where {
  proof_ensure: r => kleene_or_spec(a, b, r),
} {
  match a {
    Some(av) =>
      match b {
        Some(bv) => Some(av || bv)
        None => if av { Some(true) } else { None }
      }
    None =>
      match b {
        Some(bv) => if bv { Some(true) } else { None }
        None => None
      }
  }
}
