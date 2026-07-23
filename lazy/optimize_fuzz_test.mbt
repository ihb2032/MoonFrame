///|
/// Differential fuzzer for the optimizer/executor equivalence contract over
/// the WIDENED data domain the fixed-shape example tests and the Int-only
/// `frame` properties never reach: frames carrying nulls, NaN, infinities,
/// signed zero, near-Double::MAX values, >2^53 integers, strings, and several
/// columns at once. The invariant under test is the
/// optimizer's own contract — `collect()` (which runs `optimize` in front of
/// the executor) is bitwise-equal, with error parity, to the eager verb chain
/// it defers. Each case builds the SAME pipeline two ways: lazily (optimized)
/// and eagerly (the as-built reference), then asserts the two agree cell for
/// cell (NaN-aware), with error parity. Value equality is the contract: a
/// backend flip that changes a value surfaces in the cells, while the backend
/// tag itself is an implementation detail the oracle intentionally ignores (see
/// `frames_equiv`).
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
/// signed-zero float keys, NaN/non-finite/extreme cells, dtype-changing maps
/// under grouped reductions, nullable derived columns whose nulls line up with
/// the rows a filter drops, and file projections matching no header. A per-test
/// `rewrites` counter guards
/// against a vacuous pass: the generators must actually exercise the pushdown
/// in a meaningful fraction of cases. `MOONFRAME_FUZZ_SCALE` multiplies each
/// test's fixed case count for the manual release gate; absent, invalid, and
/// non-positive values keep the ordinary CI scale of 1.

///|
fn fuzz_scale() -> Int {
  match @sys.get_env_var("MOONFRAME_FUZZ_SCALE") {
    Some(raw) =>
      match @text.parse_decimal_int_opt(raw) {
        Some(value) if value > 0L && value <= 20L => value.to_int()
        _ => 1
      }
    None => 1
  }
}

///|
fn fuzz_cases(base : Int) -> Int {
  base * fuzz_scale()
}

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
/// An `Int64` payload pool including the additive identity, negatives (so sums
/// cancel and min/max straddle zero), the exact 2^53 boundary and its first
/// inexact successor, and `Int64::MAX`, ~1/4 null.
fn gen_int_cell() -> @gen.Gen[Int64?] {
  @gen.frequency([
    (1, @gen.pure(None)),
    (
      3,
      @gen.one_of_array([
        0L, 1L, -1L, 2L, 5L, 50L, 100L, -50L, 9007199254740992L, 9007199254740993L,
        9223372036854775807L,
      ]).fmap(x => Some(x)),
    ),
  ])
}

///|
/// A `Double` pool that deliberately includes both signed zeros, NaN, both
/// infinities, and both signs of the largest finite value and a nearby value —
/// the values the signed-zero fence, grouping rules, and Welford overflow
/// guards turn on — ~1/4 null.
fn gen_float_cell() -> @gen.Gen[Double?] {
  @gen.frequency([
    (1, @gen.pure(None)),
    (
      3,
      @gen.one_of_array([
        0.0, -0.0, 1.0, -1.0, 2.5, @double.not_a_number, 100.0, -100.0, 1.7976931348623157e308,
        1.7976931348623155e308, -1.7976931348623157e308, -1.7976931348623155e308,
        @double.infinity, @double.neg_infinity,
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

// ── Oracle (NaN-aware structural equivalence) ────────────────────────

///|
/// NaN-aware structural equivalence of two frames — the oracle the differential
/// fuzzer needs over a domain that includes NaN. Plain `DataFrame::==` derives
/// `Eq` down to `Double`, where IEEE makes `NaN != NaN`, so a frame holding a
/// NaN is unequal even to *itself*; that makes `==` useless as an
/// optimizer-equivalence check on NaN-bearing data (it would flag a divergence
/// for every NaN frame regardless of what the optimizer did). This comparator
/// instead requires identical column names and order, identical per-column
/// dtype, and cell-for-cell equality where two NaN cells count as equal
/// (matching the package's `==` contract for every other value, signed zeros
/// included). Storage backend is deliberately NOT compared: `ColumnStorage`'s
/// `==` is backend-agnostic by design (a value's backend is an implementation
/// detail of its content, not part of its identity), so a backend tag is not
/// part of the value contract the optimizer must preserve — and a backend flip
/// that *does* change a value is caught by the cell comparison below. Backend
/// parity per se is guarded separately, by `series/backend_parity_test.mbt`.
/// Returns `None` on equivalence, else a one-line reason. (An earlier
/// `oc != oc.to_builtin()` "flip detector" here was inert: that `==` is exactly
/// the backend-agnostic one, so it was always `false`.)
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
struct AggFilterCase {
  rows : Array[RichRow]
  keys : Array[@expr.Expr]
  aggs : Array[@expr.Expr]
  pred : @expr.Expr
} derive(Debug)

///|
pub extend AggFilterCase with Debug::{to_repr}

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
/// Aggregations spanning the backend-flip boundary: sum/count never null;
/// mean/min/max/variance/std exercise nullable and insufficient-group paths.
/// A nullable payload (`a`) makes all-null groups reachable, while `fk`
/// carries NaN, infinities, signed zero, and near-Double::MAX values. Every
/// case also runs two dtype-changing maps under reductions: String to Int via
/// `map_elements`, and String+Int to Float via `map_many`. This exercises real
/// group scopes and the empty-scope dtype probe used for error parity.
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
        3 => aggs.push(@expr.col("fk").variance().with_alias("fvar"))
        4 => aggs.push(@expr.col("fk").std().with_alias("fstd"))
        _ => aggs.push(@expr.col("fk").min().with_alias("fmin"))
      }
      aggs.push(
        @expr.col("s")
        .map_elements(label="string-to-int", cell => {
          match cell {
            @types.Scalar::String(_) => @types.Scalar::Int(1)
            _ => @types.Scalar::Null
          }
        })
        .sum()
        .with_alias("mapped_s_sum"),
      )
      aggs.push(
        @expr.map_many(
          label="string-int-to-float",
          [@expr.col("s"), @expr.col("a")],
          cells => {
            match (cells[0], cells[1]) {
              (@types.Scalar::String(_), @types.Scalar::Int(v)) =>
                @types.Scalar::Float(v.to_double())
              _ => @types.Scalar::Null
            }
          },
        )
        .sum()
        .with_alias("mapped_sa_sum"),
      )
      aggs
    },
    @gen.int_range(0, 3),
    @gen.int_range(0, 5),
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
    max_success=fuzz_cases(800),
  )
  // The fuzzer must actually exercise the pushdown in a meaningful fraction of
  // cases, or it is silently testing nothing.
  if rewrites < fuzz_cases(50) {
    fail("fuzzer never exercised the pushdown (rewrites=\{rewrites})")
  }
}

// ── Test 2: select / with_columns then filter ────────────────────────

///|
/// A `select`-or-`with_columns` stage carrying a nullable derived column,
/// terminated by a filter on a bare pass-through column.
struct SelectFilterCase {
  rows : Array[RichRow]
  use_select : Bool // select (with a bare pass-through) vs with_columns
  pred : @expr.Expr
} derive(Debug)

///|
pub extend SelectFilterCase with Debug::{to_repr}

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
    max_success=fuzz_cases(500),
  )
}

// ── Test 3: randomly stacked pipelines ───────────────────────────────

///|
/// A verb specification shared by the lazy and eager appliers, so a stacked
/// pipeline is literally the same sequence of operations on both carriers.
enum VerbSpec {
  VFilter(@expr.Expr)
  VWithColumns(Array[@expr.Expr])
  VSelect(Array[@expr.Expr])
  VSort(Array[(@expr.Expr, @types.SortOrder, @types.NullOrder)])
  VHead(Int)
  // Group by the bare keys, re-emitting `a` as its per-group sum (so the
  // post-aggregate frame still carries the names `g` / `s` / `a` the terminal
  // filter and the other verbs reference; a verb that reads a column the
  // aggregate dropped raises the SAME `ColumnNotFound` on both chains, which
  // `check_equiv` verifies as error parity).
  VAggregate(Array[@expr.Expr], Array[@expr.Expr])
} derive(Debug)

///|
pub extend VerbSpec with Debug::{to_repr}

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
          (@expr.col("a"), @types.SortOrder::Asc, @types.NullOrder::NullsLast),
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
struct StackedCase {
  rows : Array[RichRow]
  verbs : Array[VerbSpec]
  pred : @expr.Expr
} derive(Debug)

///|
pub extend StackedCase with Debug::{to_repr}

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
    max_success=fuzz_cases(1000),
  )
  if rewrites < fuzz_cases(50) {
    fail("fuzzer never exercised the pushdown (rewrites=\{rewrites})")
  }
}

// ── Test 4: file-source projections with no matching header ─────────────

///|
/// A generated zero-match file projection. `missing` is guaranteed not to
/// occur in either fixture's schema, and `head` varies the row-count-sensitive
/// stage between scan and select. Every generated case runs against both lazy
/// file sources rather than relying on random source selection.
struct FileProjectionCase {
  missing : String
  head : Int
} derive(Debug)

///|
pub extend FileProjectionCase with Debug::{to_repr}

///|
fn gen_file_projection_case() -> @gen.Gen[FileProjectionCase] {
  @gen.liftA2(
    (missing, head) => FileProjectionCase::{ missing, head },
    @gen.one_of_array(["missing", "ghost", "G", "a ", ""]),
    @gen.int_range(0, 7),
  )
}

///|
/// Shrink only the row limit; the invalid header stays fixed so a
/// counterexample keeps exercising the same projection-pushdown branch.
fn shrink_file_projection_case(
  c : FileProjectionCase,
) -> Iter[FileProjectionCase] {
  @shrink.Shrink::shrink(c.head).map(head => FileProjectionCase::{ ..c, head, })
}

///|
/// Write equivalent CSV and NDJSON fixtures for the file-source differential
/// property. The schema intentionally matches `RichRow`, while none of the
/// generated projection names do.
fn write_projection_fuzz_fixtures(
  csv_path : String,
  ndjson_path : String,
) -> Unit raise @types.DataError {
  let df = rows_to_frame([
    (Some(0L), Some(0.0), Some(1L), Some(2L), Some("west")),
    (Some(1L), Some(-0.0), Some(3L), None, Some("east")),
    (None, Some(@double.infinity), Some(9007199254740993L), Some(4L), None),
    (Some(2L), None, Some(9223372036854775807L), Some(-1L), Some("north")),
  ])
  @io.write_csv(csv_path, df)
  @io.write_ndjson(ndjson_path, df)
}

///|
/// Projection pushdown writes requested names into a file scan before the
/// header is known. When no name matches, the optimized reader must preserve
/// the as-built plan's exact `ColumnNotFound` variant rather than collapsing
/// the source to a zero-row frame and letting `head` expose a different error.
/// This turns the fixed CSV regression into a differential property over both
/// file sources, several invalid names, and row limits around the fixture size.
test "fuzz: zero-match file projections preserve exact eager errors" {
  let csv_path = "_build/lazy_optimize_fuzz_zero_match.csv"
  let ndjson_path = "_build/lazy_optimize_fuzz_zero_match.ndjson"
  write_projection_fuzz_fixtures(csv_path, ndjson_path)
  let prop = (c : FileProjectionCase) => {
    let check_source = (use_ndjson : Bool) => {
      let lazy_chain : () -> LazyFrame raise @types.DataError = () => {
        let source = if use_ndjson {
          scan_ndjson(ndjson_path)
        } else {
          scan_csv(csv_path)
        }
        source.head(c.head).select([@expr.col(c.missing)])
      }
      let eager_chain = () => {
        let source = if use_ndjson {
          @io.read_ndjson(ndjson_path)
        } else {
          @io.read_csv(csv_path)
        }
        source.head(c.head).select([@expr.col(c.missing)])
      }
      check_equiv(
        "zero-match-file-projection",
        lazy_chain,
        eager_chain,
        strict_errors=true,
      )
    }
    match check_source(false) {
      Some(msg) => @qc.property(false).counterexample("CSV: \{msg}")
      None =>
        match check_source(true) {
          Some(msg) => @qc.property(false).counterexample("NDJSON: \{msg}")
          None => @qc.property(true)
        }
    }
  }
  @qc.quick_check(
    @qc.forall_shrink(
      gen_file_projection_case(),
      shrink_file_projection_case,
      prop,
    ),
    max_success=fuzz_cases(200),
  )
}

// ── Test 5: predicate push-down into file sources ──────────────────────

///|
/// A generated file + predicate: random rows written to disk, then a filter
/// that references a real column (so the optimizer absorbs it into the scan and
/// exercises `read_csv_pruned`, the row-pruning reader Test 4's projection-only
/// pipeline never reaches; the NDJSON twin shares the pruning path and is
/// covered by `scan_ndjson_test.mbt`).
struct PrunedFileCase {
  rows : Array[RichRow]
  pred : @expr.Expr
} derive(Debug)

///|
pub extend PrunedFileCase with Debug::{to_repr}

///|
fn gen_pruned_file_case() -> @gen.Gen[PrunedFileCase] {
  @gen.liftA2(
    (rows, pred) => PrunedFileCase::{ rows, pred },
    gen_rows(7),
    gen_stacked_pred(),
  )
}

///|
fn shrink_pruned_file_case(c : PrunedFileCase) -> Iter[PrunedFileCase] {
  @shrink.Shrink::shrink(c.rows).map(rows => PrunedFileCase::{ ..c, rows, })
}

///|
/// The round-trip-clean subset of the rich schema: the `Int` and `String`
/// columns (`g` / `a` / `b` / `s`), dropping the `Float` `fk`. `NaN` /
/// `±inf` / `-0.0` do not survive a default CSV write→read, and this
/// differential compares two reads of the same file, so isolating the pruned
/// reader's logic means keeping the fixture lossless rather than testing float
/// round-tripping (which `io`'s own tests own). `gen_stacked_pred` only
/// references `a` / `g` / `s`, all present here.
fn rows_to_clean_frame(
  rows : Array[RichRow],
) -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::new([
    @series.Series::from_int_options("g", rows.map(r => r.0)),
    @series.Series::from_int_options("a", rows.map(r => r.2)),
    @series.Series::from_int_options("b", rows.map(r => r.3)),
    @series.Series::from_string_options("s", rows.map(r => r.4)),
  ])
}

///|
/// A filter on a `scan_csv` leaf is absorbed into the scan, which builds the
/// predicate's columns, prunes the rows, and parses the rest for survivors alone
/// (`read_csv_pruned`). That row-pruning path — distinct from the projection-only
/// narrowing Test 4 covers — must collect bitwise-equal to an eager
/// read-then-filter of the same file. Fuzz it: write generated rows, then
/// compare the pruned scan against the eager read+filter. Clean Int/String data
/// round-trips losslessly through the CSV header, so both sides read identical
/// data and any divergence is the pruned reader's own.
test "fuzz: predicate push-down into a CSV source stays eager-equivalent" {
  let csv_path = "_build/lazy_optimize_fuzz_pruned.csv"
  let prop = (c : PrunedFileCase) => {
    // Write the fixture up front (the property itself must not raise; the chains
    // defer their reads to `check_equiv`). Clean Int/String data never actually
    // raises here, so a raise would be a real fault.
    let setup = Ok(@io.write_csv(csv_path, rows_to_clean_frame(c.rows))) catch {
      e => Err(e)
    }
    match setup {
      Err(_) => @qc.property(false).counterexample("fixture write raised")
      Ok(_) => {
        // The absorbed filter drives `read_csv_pruned`; the eager read+filter of
        // the same file is the reference. A CSV header always carries the
        // schema, so even an empty or all-null frame round-trips faithfully —
        // both sides read identical data and any divergence is the reader's own.
        let lazy_chain : () -> LazyFrame raise @types.DataError = () => {
          scan_csv(csv_path).filter(c.pred)
        }
        let eager_chain = () => @io.read_csv(csv_path).filter(c.pred)
        // A single filter over clean data is a single-fault plan, so any error
        // must match exactly.
        match
          check_equiv("pruned-csv", lazy_chain, eager_chain, strict_errors=true) {
          Some(msg) => @qc.property(false).counterexample(msg)
          None => @qc.property(true)
        }
      }
    }
  }
  @qc.quick_check(
    @qc.forall_shrink(gen_pruned_file_case(), shrink_pruned_file_case, prop),
    max_success=fuzz_cases(150),
  )
}
