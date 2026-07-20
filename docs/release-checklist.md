# Release checklist

Use this checklist for every MoonFrame release candidate. Pull requests still
run the ordinary cross-platform CI matrix; a release candidate additionally
runs the manually dispatched, expanded gates below.

## Automated release run

Dispatch the `CI` workflow from the release commit with `fuzz_scale=10`. The
manual run performs the normal three-OS checks and, on Linux, additionally:

- reruns `lazy/optimize_fuzz_test.mbt` with ten times its normal deterministic
  QuickCheck case counts;
- runs `series/backend_parity_test.mbt` explicitly to pin Builtin/Numeric value
  and error parity;
- runs `io/roundtrip_corpus_test.mbt` explicitly across the adversarial CSV,
  JSON-record, and NDJSON corpus;
- checks every public MoonBit boundary for direct retention of a caller-owned
  `Array` without `.copy()`.

Equivalent local commands are:

```sh
MOONFRAME_FUZZ_SCALE=10 moon test lazy/optimize_fuzz_test.mbt
moon test series/backend_parity_test.mbt
moon test io/roundtrip_corpus_test.mbt
python .github/scripts/check_array_copy_boundaries.py
```

`MOONFRAME_FUZZ_SCALE` accepts positive integers up to 20. Missing, invalid,
non-positive, or larger values fall back to the normal deterministic scale of
1 so an accidental environment value cannot make routine CI unbounded.

## Release review

- Confirm the manual `CI` workflow is green on Linux, macOS, and Windows.
- Confirm `moon check --deny-warn`, `moon fmt --check`, `moon info`,
  `moon test --target all`, `moon coverage analyze`, and `moon bench` are green.
- Review every changed public behavior statement in `docs/api.md`: each must
  point to, or be introduced with, a pinned contract test that would fail if
  the documented behavior drifted.
- Review the generated `pkg.generated.mbti` diff and confirm every public API
  change is intentional.
- Confirm `git status --porcelain` is empty before tagging.
