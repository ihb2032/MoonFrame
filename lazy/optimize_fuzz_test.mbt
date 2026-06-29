///|
/// Differential fuzzer for the optimizer/executor equivalence contract over
/// the WIDENED data domain the fixed-shape example tests and the Int-only
/// `frame` properties never reach: frames carrying nulls, NaN, signed zero,
/// strings, and several columns at once. The invariant under test is the
/// optimizer's own contract — `collect()` (which runs `optimize` in front of
/// the executor) is bitwise-equal, with error parity, to the eager verb chain
/// it defers. Each case builds the SAME pipeline two ways: lazily (optimized)
/// and eagerly (the as-built reference), then asserts the two agree cell for
/// cell *and backend* (structural `DataFrame` equality observes the
/// Builtin/Numeric backend, which is exactly where an unfenced backend flip
/// would show up).
///
/// This is a deterministic loop (a small LCG seeded per case), not quickcheck:
/// the `lazy` blackbox package has no `Arbitrary` instance for `DataFrame`, and
/// a fixed seed makes any failure reproducible. The generators bias hard toward
/// the documented hazards — all-null groups, signed-zero float keys, NaN cells,
/// nullable derived columns whose nulls line up with the rows a filter drops.

///|
/// A tiny deterministic PRNG (LCG, the Numerical Recipes constants) so the
/// fuzzer reproduces identically run to run.
priv struct Rng {
  mut state : UInt64
}

///|
fn Rng::new(seed : UInt64) -> Rng {
  { state: seed * 6364136223846793005UL + 1442695040888963407UL }
}

///|
fn Rng::next_u32(self : Rng) -> UInt {
  self.state = self.state * 6364136223846793005UL + 1442695040888963407UL
  (self.state >> 33).to_uint()
}

///|
/// A non-negative `Int` in `[0, bound)` (bound > 0).
fn Rng::below(self : Rng, bound : Int) -> Int {
  (self.next_u32() % bound.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// `true` with probability `1/n`.
fn Rng::one_in(self : Rng, n : Int) -> Bool {
  self.below(n) == 0
}

///|
/// A small grab-bag of `Int64` cell values, including the additive identity and
/// negatives (so sums can cancel and min/max straddle zero).
fn Rng::int_cell(self : Rng) -> Int64 {
  let choices : ReadOnlyArray[Int64] = [0L, 1L, -1L, 2L, 5L, 50L, 100L, -50L]
  choices[self.below(choices.length())]
}

///|
/// A small grab-bag of `Double` cell values that deliberately includes BOTH
/// signed zeros and a NaN — the values the signed-zero aggregate fence and the
/// NaN grouping rule turn on, and which the Int-only properties can never
/// produce.
fn Rng::float_cell(self : Rng) -> Double {
  let choices : ReadOnlyArray[Double] = [
    0.0, -0.0, 1.0, -1.0, 2.5, @double.not_a_number, 100.0, -100.0,
  ]
  choices[self.below(choices.length())]
}

///|
/// A small grab-bag of strings, including the empty string.
fn Rng::string_cell(self : Rng) -> String {
  let choices : ReadOnlyArray[String] = ["", "a", "b", "west", "east", "north"]
  choices[self.below(choices.length())]
}

///|
/// Build a random rich frame: `nrows` rows and a fixed schema of five columns
/// spanning every dtype, each cell independently nullable (≈1/4 null) so groups
/// go all-null, derived columns straddle the null boundary, and key columns mix
/// signed zeros / NaN / duplicate strings. Columns:
///   - `g`   : Int64  — a low-cardinality grouping key (values 0..2, nullable)
///   - `fk`  : Double — a float key carrying ±0.0 and NaN
///   - `a`   : Int64  — a nullable payload
///   - `b`   : Int64  — a nullable payload (so `a + b` is nullable)
///   - `s`   : String — a nullable string key/payload
fn Rng::rich_frame(self : Rng, nrows : Int) -> @frame.DataFrame raise {
  let g : Array[Int64?] = []
  let fk : Array[Double?] = []
  let a : Array[Int64?] = []
  let b : Array[Int64?] = []
  let s : Array[String?] = []
  for _ in 0..<nrows {
    g.push(if self.one_in(4) { None } else { Some(self.below(3).to_int64()) })
    fk.push(if self.one_in(4) { None } else { Some(self.float_cell()) })
    a.push(if self.one_in(4) { None } else { Some(self.int_cell()) })
    b.push(if self.one_in(4) { None } else { Some(self.int_cell()) })
    s.push(if self.one_in(4) { None } else { Some(self.string_cell()) })
  }
  @frame.DataFrame::new([
    @series.Series::from_int_options("g", g),
    @series.Series::from_float_options("fk", fk),
    @series.Series::from_int_options("a", a),
    @series.Series::from_int_options("b", b),
    @series.Series::from_string_options("s", s),
  ])
}

///|
/// NaN-aware structural equivalence of two frames — the oracle the differential
/// fuzzer needs over a domain that includes NaN. Plain `DataFrame::==` derives
/// `Eq` down to `Double`, where IEEE makes `NaN != NaN`, so a frame holding a
/// NaN is unequal even to *itself*; that makes `==` useless as an
/// optimizer-equivalence check on NaN-bearing data (it would flag a divergence
/// for every NaN frame regardless of what the optimizer did). This comparator
/// instead requires: identical column names and order, identical per-column
/// dtype AND storage backend (so a genuine Builtin↔Numeric flip is still
/// caught — the exact hazard under review), and cell-for-cell equality where
/// two NaN cells count as equal (matching the package's `==` contract for every
/// other value, signed zeros included). Returns `None` on equivalence, else a
/// one-line reason.
fn frames_equiv(
  opt : @frame.DataFrame,
  eag : @frame.DataFrame,
) -> String? raise @types.DataError {
  if opt.columns() != eag.columns() {
    return Some(
      "column sets differ: \{opt.columns().join(",")} vs \{eag.columns().join(",")}",
    )
  }
  if opt.nrows() != eag.nrows() {
    return Some("row counts differ: \{opt.nrows()} vs \{eag.nrows()}")
  }
  for name in opt.columns() {
    let oc = opt.get_column(name)
    let ec = eag.get_column(name)
    if oc.dtype() != ec.dtype() {
      return Some("col \{name}: dtype \{oc.dtype()} vs \{ec.dtype()}")
    }
    // Backend parity — the Builtin/Numeric flip detector. A column is `Numeric`
    // iff it differs from its `to_builtin` form (same values, Builtin backend).
    let o_numeric = oc != oc.to_builtin()
    let e_numeric = ec != ec.to_builtin()
    if o_numeric != e_numeric {
      return Some(
        "col \{name}: backend flip (opt Numeric=\{o_numeric}, eager Numeric=\{e_numeric})",
      )
    }
    let ocells = oc.to_scalars()
    let ecells = ec.to_scalars()
    for i in 0..<ocells.length() {
      if !scalars_equiv(ocells[i], ecells[i]) {
        return Some(
          "col \{name} row \{i}: \{ocells[i]} vs \{ecells[i]} (NaN-aware)",
        )
      }
    }
  }
  None
}

///|
/// Cell equality matching the package's own `==`-based equivalence contract
/// (`DataFrame::==`, what every shipped equivalence test asserts), with one
/// correction: two NaN cells count as equal, so a NaN that legitimately
/// survives BOTH chains is not reported as a divergence (plain `Double` `==`
/// gives `NaN != NaN`, which makes a NaN frame unequal even to itself). For
/// every other value — including signed zeros, which `==` treats as equal,
/// matching the contract — this defers to `==`, so the fuzzer flags exactly the
/// divergences the real contract would, no stricter.
fn scalars_equiv(a : @types.Scalar, b : @types.Scalar) -> Bool {
  match (a, b) {
    (@types.Scalar::Float(x), @types.Scalar::Float(y)) =>
      if x.is_nan() || y.is_nan() {
        x.is_nan() && y.is_nan()
      } else {
        x == y
      }
    _ => a == b
  }
}

///|
/// Run one lazy pipeline and its eager twin and require identical results,
/// with error parity. `lazy_chain` collects the optimized plan; `eager_chain`
/// runs the same verbs eagerly (the reference the optimizer must not perturb).
/// Returns `None` on agreement, or a diagnostic `String` on the first
/// divergence (value mismatch, error mismatch, or a broken-invariant result).
fn check_equiv(
  label : String,
  lazy_chain : () -> LazyFrame,
  eager_chain : () -> @frame.DataFrame raise @types.DataError,
  strict_errors? : Bool = false,
) -> String? {
  // `.collect()` (the optimizer entry point) lives here, in one fixed place, so
  // each call site only has to build the LazyFrame.
  let lazy_res = Ok(lazy_chain().collect()) catch { e => Err(e) }
  let eager_res = Ok(eager_chain()) catch { e => Err(e) }
  match (lazy_res, eager_res) {
    (Ok(lhs), Ok(rhs)) =>
      // `frames_equiv` only touches columns both frames share by construction,
      // so its `get_column` never raises here; map the impossible error to a
      // loud diagnostic rather than leave a dead arm.
      match (Ok(frames_equiv(lhs, rhs)) catch { e => Err(e) }) {
        Err(e) => Some("\{label}: frames_equiv raised unexpectedly: \{e}")
        Ok(Some(reason)) =>
          Some(
            "\{label}: \{reason}\n  optimized:\n\{lhs.to_markdown()}\n  eager:\n\{rhs.to_markdown()}",
          )
        Ok(None) =>
          if lhs.check_invariants() != Ok(()) {
            Some(
              "\{label}: optimized result breaks invariants:\n\{lhs.to_markdown()}",
            )
          } else {
            None
          }
      }
    // Both chains raise. The optimizer's documented contract is that a
    // *single-fault* plan keeps its EXACT error, while a plan with several
    // independent faults may surface a different one of them once a filter
    // sinks below another broken stage ("which one wins was an artifact of
    // stage order to begin with"). With `strict_errors` (the single-stage
    // tests, whose pipelines reference only existing columns and so are
    // single-fault by construction) the two errors must match exactly; the
    // stacked test, which deliberately builds multi-fault plans, leaves it off
    // and accepts any (DataError, DataError) pair. The soundness-critical
    // outcomes are the asymmetric ones below — one chain raises and the other
    // does not (e.g. a cast / Map value fence failing would let the optimized
    // plan succeed where eager raised) — and those are always hard failures.
    (Err(le), Err(re)) =>
      if strict_errors && le != re {
        Some(
          "\{label}: ERROR mismatch (single-fault)\n  optimized: \{le}\n  eager:     \{re}",
        )
      } else {
        None
      }
    (Ok(lhs), Err(re)) =>
      Some(
        "\{label}: optimized SUCCEEDED but eager RAISED (soundness)\n  optimized:\n\{lhs.to_markdown()}\n  eager err: \{re}",
      )
    (Err(le), Ok(rhs)) =>
      Some(
        "\{label}: optimized RAISED but eager SUCCEEDED (soundness)\n  optimized err: \{le}\n  eager:\n\{rhs.to_markdown()}",
      )
  }
}

///|
/// The hazard at the heart of the review: a key predicate sinking below an
/// `Aggregate` whose grouped cells line up with all-null groups, signed-zero /
/// NaN float keys, and string keys. For every generated frame this builds a
/// `group_by(keys).agg(aggs).filter(pred)` and compares optimized vs eager.
/// The aggregation list mixes sum/count (which sink) with mean/min/max (whose
/// all-null cell flips the stitched column's backend, so the fence must hold) —
/// the optimizer decides per-list, and either way the two chains must agree.
test "fuzz: group-by then key-filter is optimizer/eager equivalent on rich frames" {
  let mut failure : String? = None
  let mut cases = 0
  let mut rewrites = 0
  // Each (seed) draws a fresh frame and a fresh pipeline shape.
  for seed in 0U..<800U {
    if failure is Some(_) {
      break
    }
    let rng = Rng::new(seed.to_uint64())
    let nrows = rng.below(7) // 0..6 rows — includes the empty frame
    let df = rng.rich_frame(nrows)

    // Keys: a bare Int key `g`, optionally a bare Float key `fk` (signed-zero /
    // NaN folding), optionally a bare String key `s`. All bare-column keys, so
    // the key predicate is eligible to sink — the executor must keep both
    // chains equal regardless.
    let keys = [@expr.col("g")]
    if rng.one_in(2) {
      keys.push(@expr.col("fk"))
    }
    if rng.one_in(3) {
      keys.push(@expr.col("s"))
    }

    // Aggregations spanning the backend-flip boundary: sum/count never null,
    // mean/min/max go null on an all-null group. A nullable payload (`a`) feeds
    // them so all-null groups are reachable. A second draw adds a FLOAT
    // reduction over `fk` (NaN-propagating sum/mean, NaN-skipping min/max) so
    // the stitched aggregation columns carry NaN / signed zero too.
    let aggs : Array[@expr.Expr] = [
      @expr.col("a").sum().with_alias("sa"),
      @expr.col("a").count().with_alias("ca"),
    ]
    match rng.below(4) {
      0 => aggs.push(@expr.col("a").mean().with_alias("ma"))
      1 => aggs.push(@expr.col("a").min().with_alias("mn"))
      2 => aggs.push(@expr.col("a").max().with_alias("mx"))
      _ => () // sum/count only — the sink case
    }
    match rng.below(4) {
      0 => aggs.push(@expr.col("fk").sum().with_alias("fsum"))
      1 => aggs.push(@expr.col("fk").mean().with_alias("fmean"))
      2 => aggs.push(@expr.col("fk").max().with_alias("fmax"))
      _ => ()
    }

    // A key predicate on the bare Int key `g` (eligible to sink past the
    // aggregate). `is_not_null` also exercises the null-key group.
    let pred = if rng.one_in(2) {
      @expr.col("g").eq(@expr.lit_int(rng.below(3).to_int64()))
    } else {
      @expr.col("g").is_not_null()
    }
    cases = cases + 1
    let plan = lazy_frame(df).group_by(keys).agg(aggs).filter(pred)
    if plan.explain(optimized=true) != plan.explain() {
      rewrites = rewrites + 1
    }
    let lazy_chain = () => plan
    let eager_chain = () => df.group_by(keys).agg(aggs).filter(pred)
    failure = check_equiv(
      "agg-filter seed=\{seed}",
      lazy_chain,
      eager_chain,
      strict_errors=true,
    )
  }
  // Guard against a vacuous pass: the fuzzer must actually exercise the
  // pushdown (the plan must be rewritten) in a meaningful fraction of cases.
  if failure is None && rewrites < 50 {
    failure = Some("fuzzer never exercised the pushdown (rewrites=\{rewrites})")
  }
  match failure {
    Some(msg) => fail(msg)
    None => assert_true(cases > 0)
  }
}

///|
/// The select / with_columns backend-flip hazard: a derived nullable column
/// (`a + b`) whose nulls fall exactly on rows a trailing filter drops. Eager
/// computes the column over all rows (nullable ⇒ `Builtin`) then filters; the
/// optimizer sinks the filter and computes it over the survivors (which may be
/// all-valid ⇒ `Numeric` unless the gather canonicalises). Both must land on
/// the same backend, so structural equality holds. Also exercises the
/// row-count-preservation and bare-column pass-through fences with strings.
test "fuzz: select/with_columns then filter is optimizer/eager equivalent" {
  let mut failure : String? = None
  let mut cases = 0
  for seed in 1000U..<1400U {
    if failure is Some(_) {
      break
    }
    let rng = Rng::new(seed.to_uint64())
    let nrows = rng.below(7)
    let df = rng.rich_frame(nrows)

    // A trailing predicate on a bare column the stage passes through.
    let pred = match rng.below(3) {
      0 => @expr.col("a").is_not_null()
      1 => @expr.col("g").eq(@expr.lit_int(rng.below(3).to_int64()))
      _ => @expr.col("s").eq(@expr.lit_str(rng.string_cell()))
    }

    // Half the cases use `select` (with a bare pass-through of the predicate's
    // column so the filter may sink), half use `with_columns` (which keeps every
    // column, so the predicate's column is always present below).
    if rng.one_in(2) {
      // select: include the predicate's bare column plus a nullable derived one.
      let proj = [
        @expr.col("a"),
        @expr.col("g"),
        @expr.col("s"),
        (@expr.col("a") + @expr.col("b")).with_alias("sum_ab"),
      ]
      cases = cases + 1
      let lazy_chain = () => lazy_frame(df).select(proj).filter(pred)
      let eager_chain = () => df.select(proj).filter(pred)
      failure = check_equiv(
        "select-filter seed=\{seed}",
        lazy_chain,
        eager_chain,
        strict_errors=true,
      )
    } else {
      // with_columns: derive a nullable column whose nulls align with dropped rows.
      let derived = [
        (@expr.col("a") + @expr.col("b")).with_alias("sum_ab"),
        @expr.col("fk").with_alias("fk2"),
      ]
      cases = cases + 1
      let lazy_chain = () => lazy_frame(df).with_columns(derived).filter(pred)
      let eager_chain = () => df.with_columns(derived).filter(pred)
      failure = check_equiv(
        "withcols-filter seed=\{seed}",
        lazy_chain,
        eager_chain,
        strict_errors=true,
      )
    }
  }
  match failure {
    Some(msg) => fail(msg)
    None => assert_true(cases > 0)
  }
}

///|
/// Deeper, randomly-stacked pipelines: a chain of 2-4 verbs drawn from the
/// pushdown-relevant set, terminated by a filter, so both passes
/// (predicate sink + projection narrowing) fire together over rich data and a
/// scan-narrowing SELECT is inserted under a sunk filter. This is the broadest
/// net for an unfenced interaction the single-stage tests above would miss.
test "fuzz: randomly stacked pipelines stay optimizer/eager equivalent" {
  let mut failure : String? = None
  let mut cases = 0
  let mut rewrites = 0
  for seed in 2000U..<3000U {
    if failure is Some(_) {
      break
    }
    let rng = Rng::new(seed.to_uint64())
    let nrows = rng.below(8)
    let df = rng.rich_frame(nrows)
    let steps = 2 + rng.below(3) // 2..4 verbs before the terminal filter

    // Build a list of verb specs applied in the same order to a lazy and an
    // eager carrier; sharing one spec keeps the two chains provably identical
    // by construction, so any difference in the result is the optimizer's.
    let verbs : Array[VerbSpec] = []
    for _ in 0..<steps {
      verbs.push(rng.random_verb())
    }
    // Terminal filter on a bare pass-through column (eligible to sink).
    let pred = match rng.below(3) {
      0 => @expr.col("a").is_not_null()
      1 => @expr.col("g").is_not_null()
      _ => @expr.col("s").eq(@expr.lit_str(rng.string_cell()))
    }
    cases = cases + 1
    let lazy_chain = () => {
      let mut lf = lazy_frame(df)
      for v in verbs {
        lf = apply_lazy(lf, v)
      }
      lf.filter(pred)
    }
    let eager_chain = () => {
      let mut d = df
      for v in verbs {
        d = apply_eager(d, v)
      }
      d.filter(pred)
    }
    if lazy_chain().explain(optimized=true) != lazy_chain().explain() {
      rewrites = rewrites + 1
    }
    failure = check_equiv("stacked seed=\{seed}", lazy_chain, eager_chain)
  }
  if failure is None && rewrites < 50 {
    failure = Some("fuzzer never exercised the pushdown (rewrites=\{rewrites})")
  }
  match failure {
    Some(msg) => fail(msg)
    None => assert_true(cases > 0)
  }
}

///|
/// A verb specification shared by the lazy and eager appliers, so a stacked
/// pipeline is literally the same sequence of operations on both carriers.
priv enum VerbSpec {
  VFilter(@expr.Expr)
  VWithColumns(Array[@expr.Expr])
  VSelect(Array[@expr.Expr])
  VSort(Array[(@expr.Expr, @frame.SortOrder, @frame.NullOrder)])
  VHead(Int)
  // Group by the bare keys, re-emitting `a` as its per-group sum (so the
  // post-aggregate frame still carries the names `g` / `s` / `a` the terminal
  // filter and the other verbs reference; a verb that reads a column the
  // aggregate dropped raises the SAME `ColumnNotFound` on both chains, which
  // `check_equiv` verifies as error parity).
  VAggregate(Array[@expr.Expr], Array[@expr.Expr])
}

///|
fn Rng::random_verb(self : Rng) -> VerbSpec {
  match self.below(6) {
    0 =>
      VFilter(
        if self.one_in(2) {
          @expr.col("g").is_not_null()
        } else {
          @expr.col("a").gt(@expr.lit_int(0))
        },
      )
    1 =>
      VWithColumns([
        (@expr.col("a") + @expr.col("b")).with_alias("sum_ab"),
        @expr.col("a").is_null().with_alias("a_null"),
      ])
    2 =>
      VSelect([
        @expr.col("g"),
        @expr.col("a"),
        @expr.col("s"),
        @expr.col("fk"),
        @expr.col("b"),
      ])
    3 =>
      VSort([
        (@expr.col("a"), @frame.SortOrder::Asc, @frame.NullOrder::NullsLast),
      ])
    4 => {
      // Group by `g` (and sometimes the bare string key `s`), re-emitting `a`
      // as its per-group sum under the same name, so downstream `col("g")` /
      // `col("s")` / `col("a")` still resolve.
      let keys = [@expr.col("g")]
      if self.one_in(2) {
        keys.push(@expr.col("s"))
      }
      VAggregate(keys, [@expr.col("a").sum().with_alias("a")])
    }
    _ => VHead(self.below(4))
  }
}

///|
fn apply_lazy(lf : LazyFrame, v : VerbSpec) -> LazyFrame {
  match v {
    VFilter(p) => lf.filter(p)
    VWithColumns(es) => lf.with_columns(es)
    VSelect(es) => lf.select(es)
    VSort(by) => lf.sort(by)
    VHead(n) => lf.head(n)
    VAggregate(keys, exprs) => lf.group_by(keys).agg(exprs)
  }
}

///|
fn apply_eager(
  d : @frame.DataFrame,
  v : VerbSpec,
) -> @frame.DataFrame raise @types.DataError {
  match v {
    VFilter(p) => d.filter(p)
    VWithColumns(es) => d.with_columns(es)
    VSelect(es) => d.select(es)
    VSort(by) => d.sort(by)
    VHead(n) => d.head(n)
    VAggregate(keys, exprs) => d.group_by(keys).agg(exprs)
  }
}
