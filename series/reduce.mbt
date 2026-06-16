// One index-generic reduction kernel behind every column reduction.
//
// `Series::sum` / `mean` / `min_value` / `max_value`, the grouped `agg`
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
// The `NaN` rules live here in one place: `sum` / `mean` add `NaN` in (it is a
// value, only `Null` is missing) so it propagates; the extremum fold skips it
// (treated as missing, matching Polars' regular `min` / `max` and `sort_by`).
// An all-valid `Numeric` column has no bitmap, so `reduce_present` hands back a
// constant-`true` predicate for it — no mask is allocated, and the `Series`
// reductions still dispatch to `NumericColumn`'s bitmap-free fast path before
// reaching here, so the two stay cell-for-cell in agreement.

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
/// Fold the non-missing cells of an `n`-wide index window to an extremum.
/// `get(k)` reads window position `k`, `missing(k)` is `true` when it is
/// skipped (a null slot, plus `NaN` for `Float`), and `better(candidate, best)`
/// is `true` when `candidate` should replace the running best. Returns `None`
/// when every cell is missing — the single extremum accumulation behind
/// `reduce_extremum` (whole-column, per-group, and per-scope `min` / `max`),
/// so each dtype arm there supplies only its reader, skip test, and comparator
/// instead of repeating the `best : T?` loop.
fn[T] fold_extremum(
  n : Int,
  get : (Int) -> T,
  missing : (Int) -> Bool,
  better : (T, T) -> Bool,
) -> T? {
  let mut best : T? = None
  for k in 0..<n {
    if !missing(k) {
      // Bind the cell once: the `Some` arm would otherwise evaluate `get(k)`
      // up to twice per non-missing element.
      let v = get(k)
      best = match best {
        None => Some(v)
        Some(b) => if better(v, b) { Some(v) } else { Some(b) }
      }
    }
  }
  best
}

///|
/// `sum` / `mean` reducer over an index window. `Int` accumulates in `Int64`,
/// `Float` in `Double` with `NaN` summed in (so it propagates) — only a `Null`
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
      fn(n : Int, at : (Int) -> Int) {
        let mut acc : Int64 = 0
        let mut cnt = 0
        for k in 0..<n {
          let i = at(k)
          if present(i) {
            acc = acc + a[i]
            cnt = cnt + 1
          }
        }
        if want_mean {
          if cnt == 0 {
            @types.Scalar::Null
          } else {
            @types.Scalar::Float(acc.to_double() / cnt.to_double())
          }
        } else {
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
    _ =>
      raise @types.DataError::TypeMismatch(
        (if want_mean { "mean" } else { "sum" }) +
        " undefined for " +
        storage.dtype().to_string(),
      )
  }
}

///|
/// `min` / `max` reducer over an index window (`want_min` picks which),
/// keeping the source dtype. Total over every dtype — `Bool` orders
/// `false < true`, `String` by `compare_string_lex` — returning the dtype's
/// `Scalar` variant or `Scalar::Null` for an empty / all-null / all-`NaN`
/// (`Float`) window. `NaN` is treated as missing (skipped), matching
/// `Series::min_value` / `max_value` and `sort_by`; only a null slot is
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
          fold_extremum(n, k => a[at(k)], k => !present(at(k)), (x, y) => {
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
          fold_extremum(
            n,
            k => a[at(k)],
            // `NaN` is treated as missing (skipped), as in `Series::min_value`.
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
          fold_extremum(
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
          fold_extremum(n, k => a[at(k)], k => !present(at(k)), (x, y) => {
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
/// The five reductions the shared kernel resolves. Lives here in `series` and
/// is `pub(all)` so the `frame`-side aggregations can construct it — they can't
/// reuse their own op tags: `@expr.AggOp` is a read-only enum (matchable but
/// not constructible outside `expr`), and `AggKind` is tied to the `AggSpec`
/// surface. The grouped (`agg`, from `AggKind`) and scoped (`eval_agg`, from
/// `@expr.AggOp`) reductions both map their own op into this one vocabulary.
pub(all) enum ReduceOp {
  Sum
  Mean
  Min
  Max
  Count
}

///|
/// Resolve a `ReduceOp` to its window reducer plus the `ColumnData` probe that
/// fixes the output dtype (`Count` is always `Int`, `Mean` always `Float`,
/// `Sum` / `Min` / `Max` keep the source dtype). Shared by the grouped (`agg`)
/// and scoped (`eval_agg`) reductions so the op → reducer mapping lives in one
/// place. `Sum` / `Mean` `raise` `TypeMismatch` here for a non-numeric column,
/// before any window work.
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
/// (`eval_agg`) reductions and the expression aggregator (`agg_exprs`), so all
/// three agree on backend as well as on every cell value: the catch-all `None`
/// arm is reached by the nullable reductions (`mean` / `min` / `max` over an
/// empty / all-null window), so no arm is dead.
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
