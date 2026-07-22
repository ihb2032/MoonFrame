// Proof-carrying pure kernels. This package holds the dependency-free
// arithmetic and logic kernels whose full behaviour a machine-checked
// contract can state — every function here carries a `proof_ensure` over a
// named predicate in the sibling `.mbtp` file, discharged by `moon prove`
// (Why3 / Alt-Ergo; the prover runs where those are installed — see the
// verification note in AGENTS.md). The rest of the library cannot join it
// wholesale: the prover's current frontier excludes `Double`, `String`
// methods, closure calls, and any package defining Array-wrapping types,
// which is why this island imports nothing and grows one total function at
// a time.
//
// A proof here is stronger than the example tests it replaces — it covers
// every input, not a pinned handful — but it says nothing about backend
// codegen, so the ordinary cross-target test matrix still runs over the
// callers.

///|
/// The next bottom-up merge width, or `None` once the current run already
/// covers at least half of `n`. The guards make this total for every `Int`:
/// subtraction only happens after `0 < width < n`, and doubling only happens
/// when `width < n - width`, which proves `2 * width < n <= Int::MAX` — so
/// the doubled width can neither wrap nor re-enter the merge loop with
/// negative run bounds. `next_merge_width_spec` states exactly that
/// dichotomy, and `moon prove` checks it for **all** inputs, where the old
/// whitebox pins could only sample the `2^30` boundary.
pub fn next_merge_width(
  width : Int,
  n : Int,
) -> Int? where {
  proof_ensure: r => next_merge_width_spec(width, n, r),
} {
  // One if-chain, no early return: the prover's lowering rejects `return`
  // inside a contracted body. The guard order is load-bearing — `n - width`
  // only happens after `0 < width < n`, and `width * 2` only after
  // `width < n - width` — so the doubled width is computed only when it
  // provably cannot wrap.
  if width <= 0 || n <= 1 || width >= n {
    None
  } else if width >= n - width {
    None
  } else {
    Some(width * 2)
  }
}
