# S0 spike note — `ColumnStorage` / `NumericColumn` (v0.3 Stage 2 gate)

> **Date**: 2026-06-07 · **Branch**: `feat/v0.3-storage-spike`
> **Scope**: `PLAN_v0.3.md` §3 Stage 2 / S0 — validate three uncertain points
> **before** flipping the `Series.storage` core field, else cut `NumericColumn`
> to v0.4 and ship only the `ColumnStorage` seam.

## Decision: **PROCEED to S1/S2/S3** — all three points confirmed ✅

The minimal spike (`column/numeric.mbt`, `column/storage.mbt` + blackbox
tests) compiles clean, is 100 % covered, and the full suite stays green
(693/693). `NumericColumn` earns its place — it is not an empty abstraction.

---

## Point 1 — coverage gate × closed enum ✅

`ColumnStorage { Builtin; Numeric }` and `NumericData { Int }` are closed
enums; every accessor `match`es both arms and each arm is driven by a
Builtin-backed **and** a Numeric-backed value in `storage_test.mbt`.

- `moon coverage analyze` → **"All source files are fully covered"**.
- No dead arm the type system can't eliminate. The one structural divergence
  — the `Numeric` arm of `validity()` has no stored bitmap, so it synthesises
  `Bitmap::all_valid(len)` — is reachable and tested.

**Conclusion**: the closed-enum seam holds 100 % coverage. No coverage risk
for S2's full accessor surface, provided every arm stays driven by both
backends (the test-matrix discipline `storage_test.mbt` establishes).

## Point 2 — `Series.storage` flip is mechanical ✅

Measured the real call sites (not estimated). The plan said "4 files, 8 spots";
the codebase has since grown — actual count is **13 sites across the 4 ops
files**:

| file | `.storage()` sites | shape |
|------|----:|-------|
| `drop_nulls.mbt` | 1 | `.storage().validity().to_bools()` |
| `group_by.mbt` | 7 | `.storage().validity()` ×4, `.storage().data()` ×3 |
| `join.mbt` | 4 | `.storage().validity()` ×2, `.storage().data()` ×2 |
| `sort.mbt` | 1 | bare `.storage()` → `build_sort_key(...)` arg |

- **12 / 13** are `.storage().data()` (5) or `.storage().validity()` (7)
  chains. `ColumnStorage` exposes `data(Self) -> ColumnData` and
  `validity(Self) -> Bitmap` with signatures **identical** to `BuiltinColumn`,
  so these chains compile **verbatim** when `Series::storage()` returns
  `ColumnStorage`. Proven empirically: `read_like_ops` in `storage_test.mbt`
  reproduces `build_sort_key`'s exact body (`.validity().to_bools()` + `match
  .data() { Int|Float|Bool|String }`) over a `ColumnStorage` parameter, and
  runs correctly on both backends.
- **1 / 13** (`sort.mbt:66`) passes a bare `.storage()` into
  `build_sort_key(storage : BuiltinColumn, …)`. The only edit S3 needs there is
  the **parameter type annotation** `BuiltinColumn → ColumnStorage`; the body
  is then unchanged (it already reads through `.validity()`/`.data()`).

**Conclusion**: zero *logic* changes in the ops files. One mechanical
type-annotation edit in `sort.mbt`. Note for S3: `frame/series.mbt` itself
reads its `storage` field through the **full** `BuiltinColumn` surface
(`dtype/len/null_count/get/slice/take/cast/to_*/…`) — those internal reads are
the reason S2 must port the *whole* accessor set, not just `data`/`validity`.
That is S2/S3 scope and orthogonal to the ops-file flip validated here.

## Point 3 — `NumericColumn` has a real, measurable benefit ✅

Two structural/algorithmic wins, both encoded as deterministic tests
(`numeric_test.mbt`):

1. **Construction allocates no validity buffer.** `NumericColumn` is
   `{ data : NumericData }` — no `Bitmap` field. `from_int64s` stores only the
   array; `null_count()` is the structural constant `0` (no popcount).
   `BuiltinColumn::from_ints` additionally allocates `Bitmap::all_valid(len)`
   (`⌈len/8⌉` bytes). `to_builtin()` is exactly that allocation — and equals
   `BuiltinColumn::from_ints` cell-for-cell (`derive(Eq)` proof), confirming
   the widening is lossless and the bitmap is precisely the cost the numeric
   path skips.
2. **Reductions skip the validity scan.** `NumericColumn::sum` folds the raw
   `Int64` array directly. The `BuiltinColumn` path (`Series::sum` →
   `sum_int_valid`) must first `validity().to_bools()` (an `Array[Bool]` of
   length `n`) and branch `if valid[i]` per slot. Cross-checked: numeric `sum`
   equals the valid-cell reduction of the widened column.

**Conclusion**: the no-`null`-buffer backend is a genuine `null_count == 0`
fast path (Arrow/Polars-style), not a path-map placeholder.

---

## Refinements folded into the plan for S1+

- **`sum` is total, not `raise`.** `PLAN_v0.3.md` §6 lists `sum/mean(raise)`.
  An always-numeric, all-valid column has no failure mode for `sum` (empty →
  additive identity). Per `feedback_lib_no_abort`, a propagated impossible
  `raise` would leave a dead `Err` arm and break 100 % coverage, so the spike
  ships `sum(Self) -> Scalar` total. `mean` stays `raise` (empty/all-null →
  `InvalidOperation`); `min_value`/`max_value` stay total. **Update §6 to
  `sum` total when S1 lands.**
- **`NumericData` ships `Int`-only in S0.** Keeps every match single-armed and
  trivially covered. S1 adds `Float(Array[Double])` + `from_doubles` + Float
  reductions (NaN propagates in `sum`/`mean`, skipped in `min`/`max`, per
  `project_polars_nan_semantics`) — additive, no rewrite.
- **Docs / facade sync deferred.** These spike types are not the final public
  API (S2 widens the surface; R re-exports through `moonframe.mbt` and updates
  `docs/api.md` / README / `quickstart.mbt.md`). Syncing throwaway-shape APIs
  now would be churn. The six-step quality gate's doc step belongs to S1/S2/R.

## Quality gate (this spike)

`moon check --deny-warn` 0 warnings · `moon info` (column `.mbti` diff = new
symbols only) · `moon fmt` idempotent · `moon coverage analyze` all covered ·
`moon test` 693/693.

## Artifacts (fold forward into S1/S2)

- `column/numeric.mbt` — `NumericColumn` + `NumericData` (S0 subset)
- `column/storage.mbt` — `ColumnStorage` + `StorageKind` (S0 subset)
- `column/numeric_test.mbt`, `column/storage_test.mbt`
- `column/pkg.generated.mbti` — regenerated
