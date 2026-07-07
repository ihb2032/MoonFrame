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
/// Driven by quickcheck: each case draws a rich frame and a pipeline shape
/// from `@gen` combinators, and `forall_shrink` collapses a failing case to a
/// MINIMAL counterexample — row-by-row for the data (and verb-by-verb for the
/// stacked pipelines). Modelling a row as a plain tuple of `Option`s lets
/// `@shrink`'s built-in Array / tuple / Option instances do that row shrinking
/// for free, so a failure reports the smallest frame that still diverges
/// rather than an opaque seed number. Quickcheck's default seed is fixed, so
/// the generated cases — and hence coverage — are reproducible run to run. The
/// generators bias hard toward the documented hazards — all-null groups,
/// signed-zero float keys, NaN cells, nullable derived columns whose nulls line
/// up with the rows a filter drops. A per-test `rewrites` counter guards
/// against a vacuous pass: the generators must actually exercise the pushdown
/// in a meaningful fraction of cases.

// ── Generators over the rich five-column domain ──────────────────────

///|
/// One rich row — `(g, fk, a, b, s)` — with every cell independently nullable
/// (~1/4 null). A plain tuple (rather than a struct) so `@shrink` can shrink a
/// frame row-by-row and cell-by-cell out of the box.
type RichRow = (Int64?, Double?, Int64?, Int64?, String?)

///|
/// A `Bool` that is `true` with probability `1/n` — the generator counterpart
/// of the old `Rng::one_in`, kept so the pipeline-shape probabilities (and thus
/// the covered branches) match the previous hand-rolled fuzzer exactly.
fn gen_one_in(n : Int) -> @gen.Gen[Bool] {
  @gen.int_range(0, n - 1).fmap(x => x == 0)
}

///|
/// A low-cardinality grouping key `g` (values 0..2, ~1/4 null) so groups
/// actually collide and all-null groups are reachable.
fn gen_g_cell() -> @gen.Gen[Int64?] {
  @gen.frequency([
    (1, @gen.pure(None)),
    (3, @gen.int_range(0, 2).fmap(x => Some(x.to_int64()))),
  ])
}

///|
/// A small grab-bag of `Int64` payload cells, including the additive identity
/// and negatives (so sums cancel and min/max straddle zero), ~1/4 null.
fn gen_int_cell() -> @gen.Gen[Int64?] {
  @gen.frequency([
    (1, @gen.pure(None)),
    (
      3,
      @gen.one_of_array([0L, 1L, -1L, 2L, 5L, 50L, 100L, -50L]).fmap(x => {
        Some(x)
      }),
    ),
  ])
}

///|
/// A small grab-bag of `Double` cells that deliberately includes BOTH signed
/// zeros and a NaN — the values the signed-zero aggregate fence and the NaN
/// grouping rule turn on — ~1/4 null.
fn gen_float_cell() -> @gen.Gen[Double?] {
  @gen.frequency([
    (1, @gen.pure(None)),
    (
      3,
      @gen.one_of_array([
        0.0, -0.0, 1.0, -1.0, 2.5, @double.not_a_number, 100.0, -100.0,
      ]).fmap(x => Some(x)),
    ),
  ])
}

///|
/// The string grab-bag, including the empty string and repeats (so string
/// keys collide).
let string_choices : Array[String] = ["", "a", "b", "west", "east", "north"]

///|
/// A string cell drawn from `string_choices`, ~1/4 null.
fn gen_string_cell() -> @gen.Gen[String?] {
  @gen.frequency([
    (1, @gen.pure(None)),
    (3, @gen.one_of_array(string_choices).fmap(x => Some(x))),
  ])
}

///|
fn gen_rich_row() -> @gen.Gen[RichRow] {
  @gen.liftA5(
    (g, fk, a, b, s) => (g, fk, a, b, s),
    gen_g_cell(),
    gen_float_cell(),
    gen_int_cell(),
    gen_int_cell(),
    gen_string_cell(),
  )
}

///|
/// A frame of `0..=max_rows` rich rows (the empty frame is in range).
fn gen_rows(max_rows : Int) -> @gen.Gen[Array[RichRow]] {
  @gen.int_range(0, max_rows).bind(n => gen_rich_row().array_with_size(n))
}

///|
/// Build the five-column rich frame from generated rows. The fixed schema
/// spans every dtype; by construction all columns share `rows.length()`, so
/// `DataFrame::new` never actually raises here.
fn rows_to_frame(
  rows : Array[RichRow],
) -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_int_options("g", rows.map(r => r.0)),
    @series.Series::from_float_options("fk", rows.map(r => r.1)),
    @series.Series::from_int_options("a", rows.map(r => r.2)),
    @series.Series::from_int_options("b", rows.map(r => r.3)),
    @series.Series::from_string_options("s", rows.map(r => r.4)),
  ])
}

// ── Oracle (NaN-aware, backend-aware structural equivalence) ─────────

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
  lazy_chain : () -> LazyFrame raise @types.DataError,
  eager_chain : () -> @frame.DataFrame raise @types.DataError,
  strict_errors? : Bool = false,
) -> String? {
  // `.collect()` (the optimizer entry point) lives here, in one fixed place, so
  // each call site only has to build the LazyFrame. Frame construction happens
  // inside the chains too, so a build that raised would surface here as an
  // error on both sides — caught by the same `Ok(...) catch` below.
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

// ── Test 1: group-by then key-filter ─────────────────────────────────

///|
/// One generated `group_by(keys).agg(aggs).filter(pred)` case. The pipeline
/// pieces are generated as `Expr`s directly (they are `Debug`, so a failing
/// case prints them verbatim) and only `rows` shrinks — the pipeline shape is
/// held fixed, since shrinking it would change which optimizer path the case
/// exercises.
priv struct AggFilterCase {
  rows : Array[RichRow]
  keys : Array[@expr.Expr]
  aggs : Array[@expr.Expr]
  pred : @expr.Expr
} derive(Debug)

///|
/// Keys: always `g`; the ±0.0 / NaN float key `fk` with prob 1/2 and the string
/// key `s` with prob 1/3 (the mix the old fuzzer used, so key cardinality and
/// the signed-zero / NaN folding paths stay covered).
fn gen_agg_keys() -> @gen.Gen[Array[@expr.Expr]] {
  @gen.liftA2(
    (with_fk, with_s) => {
      let keys = [@expr.col("g")]
      if with_fk {
        keys.push(@expr.col("fk"))
      }
      if with_s {
        keys.push(@expr.col("s"))
      }
      keys
    },
    gen_one_in(2),
    gen_one_in(3),
  )
}

///|
/// Aggregations spanning the backend-flip boundary: sum/count never null,
/// mean/min/max go null on an all-null group. A nullable payload (`a`) feeds
/// them so all-null groups are reachable; a second draw adds a FLOAT reduction
/// over `fk` so the stitched columns carry NaN / signed zero too.
fn gen_agg_aggs() -> @gen.Gen[Array[@expr.Expr]] {
  @gen.liftA2(
    (int_choice, float_choice) => {
      let aggs = [
        @expr.col("a").sum().with_alias("sa"),
        @expr.col("a").count().with_alias("ca"),
      ]
      match int_choice {
        0 => aggs.push(@expr.col("a").mean().with_alias("ma"))
        1 => aggs.push(@expr.col("a").min().with_alias("mn"))
        2 => aggs.push(@expr.col("a").max().with_alias("mx"))
        _ => ()
      }
      match float_choice {
        0 => aggs.push(@expr.col("fk").sum().with_alias("fsum"))
        1 => aggs.push(@expr.col("fk").mean().with_alias("fmean"))
        2 => aggs.push(@expr.col("fk").max().with_alias("fmax"))
        _ => ()
      }
      aggs
    },
    @gen.int_range(0, 3),
    @gen.int_range(0, 3),
  )
}

///|
/// A key predicate on the bare Int key `g` (eligible to sink past the
/// aggregate): `g == v` for `v` in 0..2, or `g.is_not_null()` (which exercises
/// the null-key group), each with probability 1/2.
fn gen_agg_pred() -> @gen.Gen[@expr.Expr] {
  @gen.frequency([
    (
      1,
      @gen.int_range(0, 2).fmap(v => {
        @expr.col("g").eq(@expr.lit_int(v.to_int64()))
      }),
    ),
    (1, @gen.pure(@expr.col("g").is_not_null())),
  ])
}

///|
fn gen_agg_filter_case() -> @gen.Gen[AggFilterCase] {
  @gen.liftA4(
    (rows, keys, aggs, pred) => AggFilterCase::{ rows, keys, aggs, pred },
    gen_rows(6),
    gen_agg_keys(),
    gen_agg_aggs(),
    gen_agg_pred(),
  )
}

///|
/// Shrink only the frame rows; the pipeline stays fixed.
fn shrink_agg_filter_case(c : AggFilterCase) -> Iter[AggFilterCase] {
  @shrink.Shrink::shrink(c.rows).map(rows => AggFilterCase::{ ..c, rows, })
}

///|
/// The hazard at the heart of the review: a key predicate sinking below an
/// `Aggregate` whose grouped cells line up with all-null groups, signed-zero /
/// NaN float keys, and string keys. For every generated frame this builds a
/// `group_by(keys).agg(aggs).filter(pred)` and compares optimized vs eager —
/// the optimizer decides per-list whether the filter sinks, and either way the
/// two chains must agree.
test "fuzz: group-by then key-filter is optimizer/eager equivalent on rich frames" {
  let mut rewrites = 0
  let prop = (c : AggFilterCase) => {
    let lazy_chain = () => {
      lazy_frame(rows_to_frame(c.rows))
      .group_by(c.keys)
      .agg(c.aggs)
      .filter(c.pred)
    }
    let eager_chain = () => {
      rows_to_frame(c.rows).group_by(c.keys).agg(c.aggs).filter(c.pred)
    }
    // Did the optimizer actually rewrite this plan? (Guards against a vacuous
    // pass — see the assertion after the run.)
    let rewritten = try {
      let plan = lazy_chain()
      plan.explain(optimized=true) != plan.explain()
    } catch {
      _ => false
    }
    if rewritten {
      rewrites += 1
    }
    match
      check_equiv("agg-filter", lazy_chain, eager_chain, strict_errors=true) {
      None => @qc.property(true)
      Some(msg) => @qc.property(false).counterexample(msg)
    }
  }
  @qc.quick_check(
    @qc.forall_shrink(gen_agg_filter_case(), shrink_agg_filter_case, prop),
    max_success=800,
  )
  // The fuzzer must actually exercise the pushdown in a meaningful fraction of
  // cases, or it is silently testing nothing.
  if rewrites < 50 {
    fail("fuzzer never exercised the pushdown (rewrites=\{rewrites})")
  }
}

// ── Test 2: select / with_columns then filter ────────────────────────

///|
/// A `select`-or-`with_columns` stage carrying a nullable derived column,
/// terminated by a filter on a bare pass-through column.
priv struct SelectFilterCase {
  rows : Array[RichRow]
  use_select : Bool // select (with a bare pass-through) vs with_columns
  pred : @expr.Expr
} derive(Debug)

///|
/// The trailing predicate on a bare pass-through column (eligible to sink):
/// `a.is_not_null()`, `g == v`, or `s == <grab-bag string>`, uniformly.
fn gen_select_pred() -> @gen.Gen[@expr.Expr] {
  @gen.frequency([
    (1, @gen.pure(@expr.col("a").is_not_null())),
    (
      1,
      @gen.int_range(0, 2).fmap(v => {
        @expr.col("g").eq(@expr.lit_int(v.to_int64()))
      }),
    ),
    (
      1,
      @gen.one_of_array(string_choices).fmap(str => {
        @expr.col("s").eq(@expr.lit_str(str))
      }),
    ),
  ])
}

///|
fn gen_select_filter_case() -> @gen.Gen[SelectFilterCase] {
  @gen.liftA3(
    (rows, use_select, pred) => SelectFilterCase::{ rows, use_select, pred },
    gen_rows(6),
    gen_one_in(2),
    gen_select_pred(),
  )
}

///|
fn shrink_select_filter_case(c : SelectFilterCase) -> Iter[SelectFilterCase] {
  @shrink.Shrink::shrink(c.rows).map(rows => SelectFilterCase::{ ..c, rows, })
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
  let prop = (c : SelectFilterCase) => {
    // select: the predicate's bare column plus a nullable derived one.
    let proj = [
      @expr.col("a"),
      @expr.col("g"),
      @expr.col("s"),
      (@expr.col("a") + @expr.col("b")).with_alias("sum_ab"),
    ]
    // with_columns: derive a nullable column whose nulls align with dropped rows.
    let derived = [
      (@expr.col("a") + @expr.col("b")).with_alias("sum_ab"),
      @expr.col("fk").with_alias("fk2"),
    ]
    let lazy_chain = () => {
      let lf = lazy_frame(rows_to_frame(c.rows))
      if c.use_select {
        lf.select(proj).filter(c.pred)
      } else {
        lf.with_columns(derived).filter(c.pred)
      }
    }
    let eager_chain = () => {
      let df = rows_to_frame(c.rows)
      if c.use_select {
        df.select(proj).filter(c.pred)
      } else {
        df.with_columns(derived).filter(c.pred)
      }
    }
    match
      check_equiv("select-filter", lazy_chain, eager_chain, strict_errors=true) {
      None => @qc.property(true)
      Some(msg) => @qc.property(false).counterexample(msg)
    }
  }
  @qc.quick_check(
    @qc.forall_shrink(gen_select_filter_case(), shrink_select_filter_case, prop),
    max_success=500,
  )
}

// ── Test 3: randomly stacked pipelines ───────────────────────────────

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
} derive(Debug)

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

///|
/// One verb drawn uniformly from the pushdown-relevant set. Most variants carry
/// a fixed payload; the ones with a choice draw it from a nested generator.
fn gen_verb() -> @gen.Gen[VerbSpec] {
  @gen.frequency([
    (
      1,
      @gen.one_of_array([
        @expr.col("g").is_not_null(),
        @expr.col("a").gt(@expr.lit_int(0)),
      ]).fmap(p => VFilter(p)),
    ),
    (
      1,
      @gen.pure(
        VWithColumns([
          (@expr.col("a") + @expr.col("b")).with_alias("sum_ab"),
          @expr.col("a").is_null().with_alias("a_null"),
        ]),
      ),
    ),
    (
      1,
      @gen.pure(
        VSelect([
          @expr.col("g"),
          @expr.col("a"),
          @expr.col("s"),
          @expr.col("fk"),
          @expr.col("b"),
        ]),
      ),
    ),
    (
      1,
      @gen.pure(
        VSort([
          (@expr.col("a"), @frame.SortOrder::Asc, @frame.NullOrder::NullsLast),
        ]),
      ),
    ),
    (
      1,
      // Group by `g` (and, with prob 1/2, the bare string key `s`), re-emitting
      // `a` as its per-group sum under the same name so downstream `col("g")` /
      // `col("s")` / `col("a")` still resolve.
      gen_one_in(2).fmap(add_s => {
        let keys = [@expr.col("g")]
        if add_s {
          keys.push(@expr.col("s"))
        }
        VAggregate(keys, [@expr.col("a").sum().with_alias("a")])
      }),
    ),
    (1, @gen.int_range(0, 3).fmap(n => VHead(n))),
  ])
}

///|
/// A chain of 2..4 verbs.
fn gen_verbs() -> @gen.Gen[Array[VerbSpec]] {
  @gen.int_range(2, 4).bind(n => gen_verb().array_with_size(n))
}

///|
/// A deeper, randomly-stacked pipeline: a chain of 2..4 verbs terminated by a
/// filter on a bare pass-through column.
priv struct StackedCase {
  rows : Array[RichRow]
  verbs : Array[VerbSpec]
  pred : @expr.Expr
} derive(Debug)

///|
/// The terminal predicate on a bare pass-through column: `a.is_not_null()`,
/// `g.is_not_null()`, or `s == <grab-bag string>`, uniformly.
fn gen_stacked_pred() -> @gen.Gen[@expr.Expr] {
  @gen.frequency([
    (1, @gen.pure(@expr.col("a").is_not_null())),
    (1, @gen.pure(@expr.col("g").is_not_null())),
    (
      1,
      @gen.one_of_array(string_choices).fmap(str => {
        @expr.col("s").eq(@expr.lit_str(str))
      }),
    ),
  ])
}

///|
fn gen_stacked_case() -> @gen.Gen[StackedCase] {
  @gen.liftA3(
    (rows, verbs, pred) => StackedCase::{ rows, verbs, pred },
    gen_rows(7),
    gen_verbs(),
    gen_stacked_pred(),
  )
}

///|
/// Shrink the rows (via `@shrink`) and, independently, drop one verb at a time
/// — collapsing a failing stack to the shortest verb chain that still diverges.
fn shrink_stacked_case(c : StackedCase) -> Iter[StackedCase] {
  let out : Array[StackedCase] = []
  for rows in @shrink.Shrink::shrink(c.rows) {
    out.push(StackedCase::{ ..c, rows, })
  }
  for i in 0..<c.verbs.length() {
    let verbs : Array[VerbSpec] = []
    for j in 0..<c.verbs.length() {
      if j != i {
        verbs.push(c.verbs[j])
      }
    }
    out.push(StackedCase::{ ..c, verbs, })
  }
  out.iter()
}

///|
/// The broadest net for an unfenced interaction the single-stage tests miss:
/// both optimizer passes (predicate sink + projection narrowing) fire together
/// over rich data, and a scan-narrowing SELECT is inserted under a sunk filter.
/// `strict_errors` is off — a stack can build a multi-fault plan whose winning
/// error legitimately changes once a filter sinks past a broken stage.
test "fuzz: randomly stacked pipelines stay optimizer/eager equivalent" {
  let mut rewrites = 0
  let prop = (c : StackedCase) => {
    let lazy_chain = () => {
      let mut lf = lazy_frame(rows_to_frame(c.rows))
      for v in c.verbs {
        lf = apply_lazy(lf, v)
      }
      lf.filter(c.pred)
    }
    let eager_chain = () => {
      let mut d = rows_to_frame(c.rows)
      for v in c.verbs {
        d = apply_eager(d, v)
      }
      d.filter(c.pred)
    }
    let rewritten = try {
      let plan = lazy_chain()
      plan.explain(optimized=true) != plan.explain()
    } catch {
      _ => false
    }
    if rewritten {
      rewrites += 1
    }
    match check_equiv("stacked", lazy_chain, eager_chain) {
      None => @qc.property(true)
      Some(msg) => @qc.property(false).counterexample(msg)
    }
  }
  @qc.quick_check(
    @qc.forall_shrink(gen_stacked_case(), shrink_stacked_case, prop),
    max_success=1000,
  )
  if rewrites < 50 {
    fail("fuzzer never exercised the pushdown (rewrites=\{rewrites})")
  }
}
