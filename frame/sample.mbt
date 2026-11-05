// The row sampler and shuffler: `n` rows drawn from the frame (or a
// fraction of them), or the whole frame permuted, under a seeded
// generator, so both are deterministic functions of their seed (the
// library's every-other-verb property, kept here: same seed, same rows,
// on every platform). The generator is `core/random`'s chacha8 — pure
// MoonBit, so the sequence is reproducible across platforms and nothing
// here maintains a PRNG of its own.

///|
/// The chacha8 generator a `seed~` names: the `Int32` seed spreads across
/// the first four little-endian bytes of chacha8's 32-byte key, zero-filled
/// after, so every seed value — including negative ones, which wrap —
/// names one sequence.
fn chacha8_seeded(seed : Int32) -> @random.Rand {
  @random.Rand::chacha8(
    seed=Bytes::makei(32, i => {
      if i < 4 {
        let byte = (seed.to_uint64() >> (i * 8)) & 0xFFUL
        byte.to_int().to_byte()
      } else {
        b'\x00'
      }
    }),
  )
}

///|
/// `n` rows sampled from the frame — or, when `fraction~` is given
/// instead, `max(1, round(fraction × nrows))` of them (Polars' own
/// floor-with-a-heartbeat: a fraction of a fraction of a row still draws
/// one row, and `fraction` must sit in `(0, 1]`): without
/// replacement a seeded partial Fisher–Yates — the first `n` slots of a
/// full shuffle, so every row appears at most once and the output order is
/// the draw order; with replacement `n` independent draws, repeats
/// allowed. `seed~` fixes the sequence (same seed, same rows — and an
/// omitted seed is `seed = 0`, so independent calls share one sequence);
/// `n` raises `InvalidOperation` when negative, and — without replacement —
/// when it exceeds the row count (that many distinct rows
/// do not exist, and silently returning the whole frame unshuffled would
/// also disagree with `shuffle`, which permutes); a 0-row frame
/// samples zero rows (there is nothing to draw — the with-replacement draw
/// would divide by zero, so it raises exactly when there is a row to draw).
///
/// The schema is unchanged (a row gather), so the same-schema rebuild
/// applies and the backend follows the gathered content, as after any
/// gather.
///
/// Eager-only: a seeded draw sees a specific row set, and filter /
/// projection pushdown would reorder which one that is — so there is no
/// lazy entry; collect first.
pub fn DataFrame::sample(
  self : DataFrame,
  n? : Int32,
  with_replacement~ : Bool = false,
  seed~ : Int32 = 0,
  fraction? : Double,
) -> DataFrame raise @types.DataError {
  // Exactly one of `n` / `fraction` names the draw size; a fraction
  // converts through the rounding-with-a-floor rule above.
  let n = match (n, fraction) {
    (Some(k), None) => k
    (None, Some(f)) => {
      if !(f > 0.0 && f <= 1.0) {
        raise @types.DataError::InvalidOperation(
          "sample fraction must sit in (0, 1], got \{f}",
        )
      }
      // The floor-at-one applies only where a row exists to draw: a
      // 0-row frame samples zero rows, like an explicit `n = 0` does.
      let drawn = (f * self.nrows().to_double()).round()
      if self.nrows() == 0 {
        0
      } else if drawn < 1.0 {
        1
      } else {
        drawn.to_int()
      }
    }
    _ =>
      raise @types.DataError::InvalidOperation(
        "sample takes exactly one of n or fraction",
      )
  }
  if n < 0 {
    raise @types.DataError::InvalidOperation("sample needs n >= 0")
  }
  let total = self.nrows()
  if !with_replacement && n > total {
    raise @types.DataError::InvalidOperation(
      "sampling \{n} rows without replacement exceeds the row count (\{total})",
    )
  }
  let rng = chacha8_seeded(seed)
  let picked : Array[Int32] = []
  if with_replacement {
    if n > 0 && total == 0 {
      raise @types.DataError::InvalidOperation(
        "sampling with replacement needs at least one row",
      )
    }
    for _ in 0..<n {
      picked.push(rng.int(limit=total))
    }
  } else {
    // Partial Fisher–Yates over a row permutation: swap-and-take n slots.
    let perm = Array::makei(total, i => i)
    for i in 0..<n {
      let j = i + rng.int(limit=total - i)
      let t = perm[i]
      perm[i] = perm[j]
      perm[j] = t
      picked.push(perm[i])
    }
  }
  let new_cols = self.columns.map(c => c.gather_series(picked))
  self.with_same_schema(new_cols, picked.length())
}

///|
/// The whole frame under a seeded full permutation (a Fisher–Yates
/// shuffle): `shuffle(seed=7)` twice returns the same frame, and the row
/// *multiset* is preserved — every input row appears exactly once. An
/// omitted seed is `seed = 0`, exactly as `sample`. The schema is
/// unchanged (a row gather), so the same-schema rebuild applies and the
/// backend follows the gathered content, as after any gather. `sample`
/// without replacement is the first `n` slots of this same permutation
/// family under its own seed.
///
/// Eager-only, for the same reason `sample` is: a seeded permutation sees
/// a specific row order, and pushdown would change which one; collect
/// first. Near-total — there is no invalid argument to refuse; the one
/// raise is the string layout's payload bound the underlying row gather
/// carries (`gather_series`'s), past `2^31 - 1` bytes of string payload.
pub fn DataFrame::shuffle(
  self : DataFrame,
  seed~ : Int32 = 0,
) -> DataFrame raise @types.DataError {
  let total = self.nrows()
  let perm = Array::makei(total, i => i)
  chacha8_seeded(seed).shuffle(total, (i, j) => {
    let t = perm[i]
    perm[i] = perm[j]
    perm[j] = t
  })
  let new_cols = self.columns.map(c => c.gather_series(perm))
  self.with_same_schema(new_cols, total)
}
