// One index-generic reduction kernel behind every column reduction.
//
// `Series::sum` / `mean` / `min` / `max`, the grouped `agg`
// reducers, and the scoped `eval_agg` each used to carry their own
// null-skipping / `NaN`-handling fold. They now share the factories here: each
// resolves the dtype dispatch and (for the `Builtin` backend) the validity
// mask **once**, returning a total fold that reduces an index window — a count
// `n` plus an indexing function `at` mapping `0 ..< n` onto source rows — to a
// single `Scalar`. The whole-column callers fold `(len, k => k)`; the per-group
// caller hoists the factory once and folds each group `(g.length(), k => g[k])`,
// so the grouped reduction stays a single linear pass over the column rather
// than re-materialising the validity mask per group.
//
// The expression layer's aggregation family (`Expr::std` / `variance` / `median` /
// `n_unique` / `first` / `last`) reduces through the same kernel: each is a
// window reducer here, so it serves the whole-column, per-group, and per-scope
// surfaces with one fold and one set of null / `NaN` rules.
//
// The `NaN` rules live here in one place: `sum` / `mean` add `NaN` in (it is a
// value, only `Null` is missing) so it propagates — and `var` / `std`, built on
// the mean, propagate it too; the extremum fold skips it (treated as missing,
// matching Polars' regular `min` / `max` and `sort`), and `median`, an order
// statistic, skips it the same way. `n_unique` keys a `NaN` into one bucket (it
// is one value), and `first` / `last` are positional, so they skip nothing —
// a present `NaN` is returned verbatim. An all-valid `Numeric` column has no
// bitmap, so `reduce_present` hands back a constant-`true` predicate for it —
// no mask is allocated, and the `Series` reductions still dispatch to
// `NumericColumn`'s bitmap-free fast path before reaching here, so the two stay
// cell-for-cell in agreement.

///|
/// Per-row presence predicate, hoisted once per reduction. A `Builtin` column
/// materialises its validity mask; an all-valid `Numeric` column needs none
/// (every slot is present), so the predicate is constant `true` and no bitmap
/// is allocated. Read at a *source* row index, which the reducers reach through
/// their `at` mapping.
fn reduce_present(storage : @column.ColumnStorage) -> (Int) -> Bool {
  match storage.kind() {
    @column.StorageKind::Numeric => _ => true
    @column.StorageKind::Builtin => {
      let valid = storage.validity().to_bools()
      i => valid[i]
    }
  }
}

///|
/// `sum` / `mean` reducer over an index window. `sum` accumulates `Int` in
/// `Int64` (overflowing past 2^63 — the price of an exact integer sum) and
/// `Float` in `Double`; `mean`, whose output is `Double`, accumulates `Int` in
/// `Double` too, so it cannot wrap past 2^63 and flip the mean's sign (matching
/// Polars). `NaN` is summed in (so it propagates) — only a `Null`
/// cell is skipped. With `want_mean` the running total divides by the non-null
/// count and is `Scalar::Null` for an empty / all-null window (the surfaces
/// translate that: `Series::mean` to `InvalidOperation`, the grouped / scoped
/// reducers to a null cell); otherwise the result is the dtype-preserving sum,
/// the additive identity for an empty / all-null window. A non-numeric
/// (`Bool` / `String`) column `raise`s `TypeMismatch` here — at factory time,
/// before any window is folded — matching the previous per-surface reducers,
/// which rejected the dtype up front (and so reject it even for zero groups).
fn reduce_arith(
  storage : @column.ColumnStorage,
  want_mean~ : Bool,
) -> ((Int, (Int) -> Int) -> @types.Scalar) raise @types.DataError {
  let present = reduce_present(storage)
  match storage.data() {
    @column.ColumnData::Int(a) =>
      if want_mean {
        // The mean's output is `Double`, so accumulate the numerator in
        // `Double` from the start. An `Int64` accumulator would silently wrap
        // past 2^63 and flip the mean's sign — a result outside `[min, max]` —
        // even though `Double` represents the true mean (matching Polars).
        fn(n : Int, at : (Int) -> Int) {
          let mut acc = 0.0
          let mut cnt = 0
          for k in 0..<n {
            let i = at(k)
            if present(i) {
              acc = acc + a[i].to_double()
              cnt = cnt + 1
            }
          }
          if cnt == 0 {
            @types.Scalar::Null
          } else {
            @types.Scalar::Float(acc / cnt.to_double())
          }
        }
      } else {
        // `sum` keeps the `Int` dtype, so it stays an exact `Int64` fold —
        // sums past 2^63 overflow, the documented price of an integer sum.
        fn(n : Int, at : (Int) -> Int) {
          let mut acc : Int64 = 0
          for k in 0..<n {
            let i = at(k)
            if present(i) {
              acc = acc + a[i]
            }
          }
          @types.Scalar::Int(acc)
        }
      }
    @column.ColumnData::Float(a) =>
      fn(n : Int, at : (Int) -> Int) {
        let mut acc = 0.0
        let mut cnt = 0
        for k in 0..<n {
          let i = at(k)
          // `NaN` is a value, not missing: it participates and propagates to a
          // `NaN` total; only a null cell (`!present`) is skipped.
          if present(i) {
            acc = acc + a[i]
            cnt = cnt + 1
          }
        }
        if want_mean {
          if cnt == 0 {
            @types.Scalar::Null
          } else {
            @types.Scalar::Float(acc / cnt.to_double())
          }
        } else {
          @types.Scalar::Float(acc)
        }
      }
    @column.ColumnData::Bool(_) | @column.ColumnData::String(_) => {
      let verb = if want_mean { "mean" } else { "sum" }
      raise @types.DataError::TypeMismatch(
        "\{verb} undefined for \{storage.dtype()}",
      )
    }
  }
}

///|
/// `min` / `max` reducer over an index window (`want_min` picks which),
/// keeping the source dtype. Total over every dtype — `Bool` orders
/// `false < true`, `String` by `compare_string_lex` — returning the dtype's
/// `Scalar` variant or `Scalar::Null` for an empty / all-null / all-`NaN`
/// (`Float`) window. `NaN` is treated as missing (skipped), matching
/// `Series::min` / `max` and `sort`; only a null slot is
/// otherwise skipped. Shares the single `fold_extremum` accumulation.
fn reduce_extremum(
  storage : @column.ColumnStorage,
  want_min~ : Bool,
) -> (Int, (Int) -> Int) -> @types.Scalar {
  let present = reduce_present(storage)
  match storage.data() {
    @column.ColumnData::Int(a) =>
      fn(n : Int, at : (Int) -> Int) {
        match
          @types.fold_extremum(n, k => a[at(k)], k => !present(at(k)), (x, y) => {
            if want_min {
              x < y
            } else {
              x > y
            }
          }) {
          Some(b) => @types.Scalar::Int(b)
          None => @types.Scalar::Null
        }
      }
    @column.ColumnData::Float(a) =>
      fn(n : Int, at : (Int) -> Int) {
        match
          @types.fold_extremum(
            n,
            k => a[at(k)],
            // `NaN` is treated as missing (skipped), as in `Series::min`.
            k => !present(at(k)) || a[at(k)].is_nan(),
            (x, y) => if want_min { x < y } else { x > y },
          ) {
          Some(b) => @types.Scalar::Float(b)
          None => @types.Scalar::Null
        }
      }
    @column.ColumnData::Bool(a) =>
      fn(n : Int, at : (Int) -> Int) {
        match
          @types.fold_extremum(
            n,
            k => a[at(k)],
            k => !present(at(k)),
            // `false < true`: under min `false` beats `true`, under max reverse.
            (x, y) => if want_min { !x && y } else { x && !y },
          ) {
          Some(b) => @types.Scalar::Bool(b)
          None => @types.Scalar::Null
        }
      }
    @column.ColumnData::String(a) =>
      fn(n : Int, at : (Int) -> Int) {
        match
          @types.fold_extremum(n, k => a[at(k)], k => !present(at(k)), (x, y) => {
            if want_min {
              @types.compare_string_lex(x, y) < 0
            } else {
              @types.compare_string_lex(x, y) > 0
            }
          }) {
          Some(b) => @types.Scalar::String(b)
          None => @types.Scalar::Null
        }
      }
  }
}

///|
/// `count` reducer over an index window: the number of non-null cells, as a
/// `Scalar::Int`. Dtype-independent (it reads only the presence predicate), so
/// it needs no per-dtype dispatch and is total over every column.
fn reduce_count(
  storage : @column.ColumnStorage,
) -> (Int, (Int) -> Int) -> @types.Scalar {
  let present = reduce_present(storage)
  fn(n : Int, at : (Int) -> Int) {
    let mut c : Int64 = 0
    for k in 0..<n {
      if present(at(k)) {
        c = c + 1
      }
    }
    @types.Scalar::Int(c)
  }
}

///|
/// Resolve a numeric column's dtype dispatch once into a `(Int) -> Double` cell
/// reader: an `Int` cell widens through `to_double`, a `Float` cell reads
/// directly. Shared by the numeric-only reductions `variance` / `std` and
/// `median`, which otherwise repeat this same three-arm match. A non-numeric
/// (`Bool` / `String`) column has no such reading, so it `raise`s `TypeMismatch`
/// here — naming the operation (`op`) that asked — at factory time, before any
/// window is folded, exactly as `reduce_arith` rejects a non-numeric column.
fn numeric_double_reader(
  storage : @column.ColumnStorage,
  op : String,
) -> ((Int) -> Double) raise @types.DataError {
  match storage.data() {
    @column.ColumnData::Int(a) => i => a[i].to_double()
    @column.ColumnData::Float(a) => i => a[i]
    @column.ColumnData::Bool(_) | @column.ColumnData::String(_) =>
      raise @types.DataError::TypeMismatch(
        "\{op} undefined for \{storage.dtype()}",
      )
  }
}

///|
/// `var` / `std` reducer over an index window (`want_std` square-roots the
/// result): the **sample** statistics with `ddof = 1` (Polars' default). The
/// variance is `Σ(xᵢ − mean)² / (cnt − 1)` over the `cnt` non-null cells and
/// the standard deviation its square root, both `Scalar::Float` — `Int` widens
/// to `Double`, so the output always types `Float`. Computed by Welford's
/// online algorithm (a single pass that never forms the raw sum), so a
/// finite-variance window of near-`Double`-max values — whose sum would
/// overflow to `±inf` and poison a two-pass mean, reporting `+inf` for a true
/// variance of 0 — still yields its finite variance. When the true variance
/// itself exceeds `Double`'s range (finite cells more than `Double::MAX`
/// apart, e.g. opposite signs near `±1.8e308`), the result saturates to
/// `+inf` — never a negative variance or a `NaN` std from the internal
/// overflow — matching numpy / Polars. Numeric only: a
/// non-numeric (`Bool` / `String`) column `raise`s `TypeMismatch` here at
/// factory time, before any window is folded, exactly as `reduce_arith` does.
/// A `NaN` is a present value: when at least two non-null cells are present it
/// counts toward `cnt` and **propagates** — the mean is `NaN`, hence every
/// deviation and the result — matching `sum` / `mean`. The fewer-than-two rule
/// takes precedence, though: a window with fewer than two non-null cells has no
/// sample variance (the `cnt − 1` denominator is zero or negative), so it
/// reduces to `Scalar::Null` (the empty / single-value / all-null cases — so a
/// lone `NaN` cell is `Null`, not `NaN`), which the surfaces translate the way
/// they do `mean`'s null cell.
fn reduce_variance(
  storage : @column.ColumnStorage,
  want_std~ : Bool,
) -> ((Int, (Int) -> Int) -> @types.Scalar) raise @types.DataError {
  let present = reduce_present(storage)
  let read = numeric_double_reader(
    storage,
    if want_std {
      "std"
    } else {
      "variance"
    },
  )
  fn(n : Int, at : (Int) -> Int) {
    // Welford's online algorithm: one pass that never forms the raw sum, so a
    // finite-variance window of near-`Double`-max values (whose sum would
    // overflow to `±inf` and poison a two-pass mean, turning a true variance of
    // 0 into `+inf`) still yields its finite variance. `mean` is the running
    // mean, `m2` the running sum of squared deviations from it.
    let mut cnt = 0
    let mut mean = 0.0
    let mut m2 = 0.0
    let mut saw_nonfinite = false
    for k in 0..<n {
      let i = at(k)
      if present(i) {
        // A `NaN` cell makes `mean` `NaN`, so `m2` — and the result — is `NaN`
        // (propagation), matching `sum` / `mean`.
        let x = read(i)
        cnt = cnt + 1
        saw_nonfinite = saw_nonfinite || x.is_nan() || x.is_inf()
        let delta = x - mean
        mean = mean + delta / cnt.to_double()
        m2 = m2 + delta * (x - mean)
      }
    }
    // The sample denominator `cnt - 1` is zero or negative for an empty,
    // single-value, or all-null window — no sample variance, a null cell (so a
    // lone `NaN` cell is `Null`, not `NaN`); the fewer-than-two rule precedes
    // NaN propagation.
    if cnt < 2 {
      @types.Scalar::Null
    } else {
      // Welford keeps `m2 >= 0` under finite in-range arithmetic, but `delta`
      // itself overflows to `±inf` when two finite cells sit more than
      // `Double::MAX` apart (opposite signs near `±1.8e308`), and the
      // artefact poisons `m2` to `-inf` or `NaN` — reporting a mathematically
      // impossible negative variance and a `NaN` std. With every *input*
      // finite, a negative/`NaN` `m2` can only be that artefact, so saturate
      // to `+inf`: the true variance exceeds `Double`'s range (numpy/Polars
      // report `+inf` here too), and `sqrt(+inf) = +inf` keeps std
      // consistent. Genuine `NaN` / `±inf` inputs skip the rescue and keep
      // IEEE propagation, matching `sum` / `mean`.
      let m2 = if !saw_nonfinite && !(m2 >= 0.0) {
        @double.infinity
      } else {
        m2
      }
      let variance = m2 / (cnt - 1).to_double()
      @types.Scalar::Float(if want_std { variance.sqrt() } else { variance })
    }
  }
}

///|
/// `median` reducer over an index window: the middle of the sorted non-null
/// cells, or the mean of the two middles for an even count, as a
/// `Scalar::Float` — `Int` widens to `Double`, so a median always types
/// `Float` (Polars). Numeric only: a non-numeric column `raise`s
/// `TypeMismatch` at factory time, as `reduce_arith` does. A `NaN` is
/// **skipped** (treated as missing), the `min` / `max` and `sort` rule rather
/// than `sum` / `mean` propagation — MoonFrame orders `NaN` as missing
/// throughout (see `sort`), so this order statistic drops it too. An empty /
/// all-null / all-`NaN` window reduces to `Scalar::Null`.
fn reduce_median(
  storage : @column.ColumnStorage,
) -> ((Int, (Int) -> Int) -> @types.Scalar) raise @types.DataError {
  let present = reduce_present(storage)
  let read = numeric_double_reader(storage, "median")
  fn(n : Int, at : (Int) -> Int) {
    // Collect the present, non-`NaN` values, then sort: the median is the
    // middle by order, and `NaN` (ordered as missing here) takes no part.
    let vals : Array[Double] = []
    for k in 0..<n {
      let i = at(k)
      if present(i) {
        let v = read(i)
        if !v.is_nan() {
          vals.push(v)
        }
      }
    }
    let m = vals.length()
    if m == 0 {
      @types.Scalar::Null
    } else {
      vals.sort()
      if m % 2 == 1 {
        @types.Scalar::Float(vals[m / 2])
      } else {
        let lo = vals[m / 2 - 1]
        let hi = vals[m / 2]
        // Average the two middle values. The precise `(lo + hi) / 2` is kept for
        // the common case, but two near-`Double`-max middles overflow their sum
        // to ±Inf before the halving — even though the median lies between them
        // and is always finite. Halve first in that case (each half stays in
        // range). A genuinely infinite middle keeps `(lo + hi) / 2`'s result.
        let sum = lo + hi
        @types.Scalar::Float(
          if sum.is_inf() {
            lo / 2.0 + hi / 2.0
          } else {
            sum / 2.0
          },
        )
      }
    }
  }
}

///|
/// Count the distinct non-null values in an index window — the total core
/// behind both the `n_unique` reduction and `Series::n_unique`, so the two
/// agree on what "distinct" means cell-for-cell. Cells are keyed by the same
/// `key_cell` normalisation `group_by` / `join` use, so "distinct value" means
/// exactly "distinct group": every `NaN` collapses into one bucket and `-0.0`
/// folds into `+0.0`. Nulls are excluded, the presence predicate skipping them.
/// The dtype dispatch resolves once into a per-row key reader; only `Float`
/// needs normalisation (which `key_cell` centralises), the others key on the
/// native value directly.
fn count_distinct(
  storage : @column.ColumnStorage,
) -> (Int, (Int) -> Int) -> Int {
  let present = reduce_present(storage)
  let key_of : (Int) -> KeyCell = match storage.data() {
    @column.ColumnData::Int(a) => i => KInt(a[i])
    // The `Float` arm shares `float_key_cell` with `key_cell` (NaN → KNaN,
    // -0.0 → +0.0) so it keys on the native `Double` without boxing a `Scalar`
    // per cell, like the other three arms — n_unique / group_by / join stay in
    // agreement on "distinct" by construction, not by hand-synced copies.
    @column.ColumnData::Float(a) => i => float_key_cell(a[i])
    @column.ColumnData::Bool(a) => i => KBool(a[i])
    @column.ColumnData::String(a) => i => KStr(a[i])
  }
  fn(n : Int, at : (Int) -> Int) {
    let seen : Map[KeyCell, Unit] = {}
    for k in 0..<n {
      let i = at(k)
      if present(i) {
        seen[key_of(i)] = ()
      }
    }
    seen.length()
  }
}

///|
/// `n_unique` reducer over an index window: the number of distinct non-null
/// values, as a `Scalar::Int`. Total over every dtype (it raises nothing) and
/// never null — an empty / all-null window counts zero. Wraps the shared
/// `count_distinct` core that `Series::n_unique` also uses.
fn reduce_nunique(
  storage : @column.ColumnStorage,
) -> (Int, (Int) -> Int) -> @types.Scalar {
  let counter = count_distinct(storage)
  fn(n : Int, at : (Int) -> Int) {
    @types.Scalar::Int(counter(n, at).to_int64())
  }
}

///|
/// `first` / `last` reducer over an index window (`want_first` picks which):
/// the cell at the window's first / last position, in the window's row order,
/// keeping the source dtype. Total over every dtype, and — unlike the other
/// reductions — it skips nothing: a present cell yields its value verbatim
/// (`NaN` included), and a *null* first / last cell yields `Scalar::Null`, as
/// does an empty window. (Polars' `first` / `last` are likewise positional.)
fn reduce_first_last(
  storage : @column.ColumnStorage,
  want_first~ : Bool,
) -> (Int, (Int) -> Int) -> @types.Scalar {
  let present = reduce_present(storage)
  // Resolve the dtype dispatch once: a reader that builds the source-dtype
  // `Scalar` at a source row. Only ever called on a present row (the null /
  // empty cases short-circuit to `Null` first), so it never reads a null slot.
  let read : (Int) -> @types.Scalar = match storage.data() {
    @column.ColumnData::Int(a) => i => @types.Scalar::Int(a[i])
    @column.ColumnData::Float(a) => i => @types.Scalar::Float(a[i])
    @column.ColumnData::Bool(a) => i => @types.Scalar::Bool(a[i])
    @column.ColumnData::String(a) => i => @types.Scalar::String(a[i])
  }
  fn(n : Int, at : (Int) -> Int) {
    if n == 0 {
      @types.Scalar::Null
    } else {
      let i = at(if want_first { 0 } else { n - 1 })
      if present(i) {
        read(i)
      } else {
        @types.Scalar::Null
      }
    }
  }
}

///|
/// The eleven reductions the shared kernel resolves. Lives here in `series` and
/// is `pub(all)` so the `frame`-side aggregations can construct it — they can't
/// reuse `@expr.AggOp`, a read-only enum (matchable but not constructible
/// outside `expr`). The grouped (`agg`) and scoped (`eval_agg`) reductions both
/// map `@expr.AggOp` into this one vocabulary.
///
/// This variant list mirrors `@expr.AggOp` one-to-one; `frame`'s
/// `reduce_op_of_agg` translates between them. Keep the two in lockstep — a
/// reduction added here must also be added to `@expr.AggOp` and to that map.
pub(all) enum ReduceOp {
  Sum
  Mean
  Min
  Max
  Count
  Std
  Var
  Median
  NUnique
  First
  Last
}

///|
/// Resolve a `ReduceOp` to its window reducer plus the `ColumnData` probe that
/// fixes the output dtype: `Count` / `NUnique` are always `Int`, `Mean` / `Std`
/// / `Var` / `Median` always `Float`, and `Sum` / `Min` / `Max` / `First` /
/// `Last` keep the source dtype. Shared by the grouped (`agg`) and scoped
/// (`eval_agg`) reductions so the op → reducer mapping lives in one place.
/// `Sum` / `Mean` / `Std` / `Var` / `Median` `raise` `TypeMismatch` here for a
/// non-numeric column, before any window work.
pub fn reducer_for(
  storage : @column.ColumnStorage,
  op : ReduceOp,
) -> ((Int, (Int) -> Int) -> @types.Scalar, @column.ColumnData) raise @types.DataError {
  match op {
    Count => (reduce_count(storage), @column.ColumnData::Int([]))
    Sum => (reduce_arith(storage, want_mean=false), storage.data())
    Mean =>
      (reduce_arith(storage, want_mean=true), @column.ColumnData::Float([]))
    Min => (reduce_extremum(storage, want_min=true), storage.data())
    Max => (reduce_extremum(storage, want_min=false), storage.data())
    Std =>
      (reduce_variance(storage, want_std=true), @column.ColumnData::Float([]))
    Var =>
      (reduce_variance(storage, want_std=false), @column.ColumnData::Float([]))
    Median => (reduce_median(storage), @column.ColumnData::Float([]))
    NUnique => (reduce_nunique(storage), @column.ColumnData::Int([]))
    First => (reduce_first_last(storage, want_first=true), storage.data())
    Last => (reduce_first_last(storage, want_first=false), storage.data())
  }
}

///|
/// Project per-window reduction `Scalar`s into a typed output column. `probe`
/// fixes the output dtype, so an all-null result (every cell `Null`) still
/// types correctly; each cell is projected "matching variant → `Some`,
/// anything else (including `Null`) → `None`"; and an all-valid numeric result
/// then converges onto the `Numeric` fast path (`try_column_to_numeric`, a
/// no-op for a nullable, `Bool`, or `String` column, which keeps `Builtin`).
/// This is the single column builder behind the grouped (`agg`) and scoped
/// (`eval_agg`) reductions, so both agree on backend as well as on every cell
/// value: the catch-all `None` arm is reached by the nullable reductions
/// (`mean` / `min` / `max` / `std` / `var` / `median` over an empty / all-null
/// window, and `first` / `last` over a null cell), so no arm is dead.
pub fn scalars_to_series(
  probe : @column.ColumnData,
  name : String,
  cells : Array[@types.Scalar],
) -> Series {
  let built = match probe {
    @column.ColumnData::Int(_) =>
      Series::from_int_options(
        name,
        cells.map(c => {
          match c {
            @types.Scalar::Int(v) => Some(v)
            _ => None
          }
        }),
      )
    @column.ColumnData::Float(_) =>
      Series::from_float_options(
        name,
        cells.map(c => {
          match c {
            @types.Scalar::Float(v) => Some(v)
            _ => None
          }
        }),
      )
    @column.ColumnData::Bool(_) =>
      Series::from_bool_options(
        name,
        cells.map(c => {
          match c {
            @types.Scalar::Bool(v) => Some(v)
            _ => None
          }
        }),
      )
    @column.ColumnData::String(_) =>
      Series::from_string_options(
        name,
        cells.map(c => {
          match c {
            @types.Scalar::String(v) => Some(v)
            _ => None
          }
        }),
      )
  }
  try_column_to_numeric(built)
}
