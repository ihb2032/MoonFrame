// The row sampler — Polars' `df.sample(n, with_replacement, seed)`: `n`
// rows drawn from the frame under a seeded generator, so a sample is a
// deterministic function of its seed (the library's every-other-verb
// property, kept here: same seed, same rows, on every platform). The
// generator is the fuzzer-proven splitmix64, private to this package —
// nothing else samples, so nothing else needs it. Polars' `fraction`
// parameter and `shuffle` are not carried: `n` composes with the caller's
// own row count, and shuffling is `sample(n=nrows)` away when wanted.

///|
/// splitmix64 — the deterministic generator behind the sampler (and the
/// same family the fuzzers use). Steady-state mixing per
/// <https://en.wikipedia.org/wiki/Permuted_congruential_generator#splitmix>
/// : a wrapped increment, a two-multiply mix, a rotate; the 64-bit state
/// makes the sequence reproducible across platforms.
priv struct SplitMix64 {
  mut state : UInt64
}

///|
/// The next draw, as an unsigned 64-bit value.
fn SplitMix64::next(self : SplitMix64) -> UInt64 {
  // Wrapped arithmetic: the whole point of a PRNG state is to wrap.
  self.state = self.state + 0x9E3779B97F4A7C15UL
  let mut z = self.state
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// A draw mapped into `[0, bound)` — rejection-free modulo bias is
// acceptable for row sampling (bias is ~`n / 2^64`, unobservable), kept
// simple on purpose.
fn SplitMix64::below(self : SplitMix64, bound : Int) -> Int {
  // The modulo lands in [0, 2^63) for any realistic bound, so the value
  // reinterprets safely into `Int`.
  (self.next() % bound.to_uint64()).to_int()
}

///|
/// `n` rows sampled from the frame (Polars' `df.sample`): without
/// replacement a seeded partial Fisher–Yates — the first `n` slots of a
/// full shuffle, so every row appears at most once and the output order is
/// the draw order; with replacement `n` independent draws, repeats
/// allowed. `seed~` fixes the sequence (same seed, same rows); `n`
/// saturates at the row count without replacement and raises
/// `InvalidOperation` when negative; a 0-row frame samples zero rows
/// without replacement (there is nothing to draw — the with-replacement
/// draw would divide by zero, so it raises there instead).
///
/// The schema is unchanged (a row gather), so the same-schema rebuild
/// applies and the backend follows the gathered content, as after any
/// gather.
pub fn DataFrame::sample(
  self : DataFrame,
  n : Int,
  with_replacement? : Bool = false,
  seed? : Int = 0,
) -> DataFrame raise @types.DataError {
  if n < 0 {
    raise @types.DataError::InvalidOperation("sample needs n >= 0")
  }
  let total = self.nrows()
  if !with_replacement && n > total {
    // Saturating, like `head`: asking for more rows than exist takes them
    // all.
    return self
  }
  let rng = SplitMix64::{ state: seed.to_uint64(), }
  let picked : Array[Int] = []
  if with_replacement {
    if total == 0 {
      raise @types.DataError::InvalidOperation(
        "sampling with replacement needs at least one row",
      )
    }
    for _ in 0..<n {
      picked.push(rng.below(total))
    }
  } else {
    // Partial Fisher–Yates over a row permutation: swap-and-take n slots.
    let perm = Array::makei(total, i => i)
    for i in 0..<n {
      let j = i + rng.below(total - i)
      let t = perm[i]
      perm[i] = perm[j]
      perm[j] = t
      picked.push(perm[i])
    }
  }
  let new_cols = self.columns.map(c => c.gather_series(picked))
  self.with_same_schema(new_cols, picked.length())
}
