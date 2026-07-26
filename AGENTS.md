# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. Use snapshot tests to record current
  behavior. For solid, well-defined results (e.g. scientific computations),
  prefer assertion tests. You can use `moon coverage analyze > uncovered.log` to
  see which parts of your code are not covered by tests.

## Documentation guards

CI protects prose the way it protects code, for the parts of it that can be
checked mechanically. Run them the same way CI does:

```sh
sh .github/scripts/doc_guards_test.sh      # the guards' own self-test
sh .github/scripts/check_version_identity.sh
sh .github/scripts/check_stale_names.sh
sh .github/scripts/check_enum_surface.sh
sh .github/scripts/check_facade_surface.sh
sh .github/scripts/check_internal_packages.sh
sh .github/scripts/check_layering.sh
sh .github/scripts/check_engine_seams.sh
```

- **Version identity** — `moon.mod`, `docs/api.md`, `docs/changelog.md`, and
  `docs/migration.md` must name one release. While a release is being prepared
  on `main`, the changelog's newest heading carries `(unreleased)` and
  `moon.mod` still publishes the previous version; **cutting the release means
  dropping that marker and bumping `moon.mod` together**, which is what the
  guard enforces.
- **Enum surface** — the exact variant set of every public `pub(all)` enum /
  suberror is pinned in `.github/scripts/enum_surface.snapshot`. Adding,
  removing, or renaming a variant is source-breaking under exhaustive `match`,
  so it fails here until the snapshot is regenerated deliberately
  (`sh .github/scripts/check_enum_surface.sh --write`).
- **Facade surface** — the whole callable surface the facade promises is
  pinned in `.github/scripts/facade_surface.snapshot`, **with signatures**.
  Re-exporting a *type* carries everything callable on it — constructors,
  methods (including the ones `pub extend` exposes), `#alias` spellings, trait
  impls, public fields — so the snapshot covers every public package's symbols,
  tagged with its source package and with whether the facade names the type or
  leaves it a fluent-chain intermediate. Signatures matter because half of what
  breaks a caller leaves the names alone: a parameter type, a `raise`
  appearing, an optional parameter becoming required, a field widening to `?`. `moon info` and the downstream fixture catch
  under-exports and interface drift; this catches an *over-export* — a symbol
  that reaches callers as `@moonframe.Type::method` without any facade change,
  and becomes a breaking change once published. Any add / remove /
  reclassification / source-package change fails until the snapshot is
  regenerated (`sh .github/scripts/check_facade_surface.sh --write`).
- **Stale names** — a removed identifier must not appear in current-state prose
  or a source comment. `docs/changelog.md` and `docs/migration.md` are exempt
  (history is their content); a single line that must name one takes the marker
  `doc-guard: historical`. It matches distinctive spellings only — a bare word
  like `take` names live methods too — and it cannot see a *claim* that drifted
  rather than a name. **When a symbol's visibility or representation changes,
  re-read the changelog and migration sections that describe it**: those are
  current-state prose that no guard scans, and both have shipped statements
  contradicting the interface they document.
- **Internal packages** — the set of `internal/*` package *names* on disk must
  equal the set README's repository-structure block and `docs/api.md` name.
  They have no public surface, so no other guard notices one appearing or
  disappearing — and an internal package is where a whole class of work is
  supposed to live, so one the docs never mention gets bypassed. It checks
  names, not whether the descriptions are accurate.
- **Layering** — the production package graph, read off the `moon.pkg`
  manifests: `internal/column` is imported by `series` and `internal/kernel`
  and by nothing else, `internal/kernel` only by `frame`, no `internal/*`
  package imports `frame` / `io` / `lazy`, the facade imports exactly the six
  public packages, and no public `pkg.generated.mbti` names an internal
  package. Every other production edge is pinned in
  `.github/scripts/layering.snapshot`, so a new dependency lands deliberately
  (`sh .github/scripts/check_layering.sh --write`). Test-only import blocks are
  exempt by design (`frame`'s tests name `StorageKind`). Changing the layering
  means changing the rule in the guard first, then both documents.
- **Engine seams** — every `pub` symbol in a public package carrying
  `#internal(engine, …)` / `#doc(hidden)`, with its normalised signature,
  pinned in `.github/scripts/engine_seams.snapshot`. `#doc(hidden)` keeps these
  out of the generated interface, which is exactly why the facade lock cannot
  see them; this is where adding one — or widening one, a seam that starts
  handing another package a mutable buffer — has to be noticed
  (`sh .github/scripts/check_engine_seams.sh --write`). The two attributes are
  a pair and either half alone is rejected outright: an alert on a symbol the
  interface still publishes, or — the quieter mistake — a symbol hidden from
  the interface, and so from every guard that reads one, with nothing stopping
  a downstream call.

One more pass, `review_absolute_wording.sh`, annotates absolute claims ("all",
"every", "never", "total") in prose a PR adds. It never fails the build — it
asks a human to confirm the claim still holds, because that is the wording this
repository's documentation drifts on.

## Completion Requirements

- Keep test coverage at 100%. Before finishing a change, run
  `moon coverage analyze` and require it to report that all source files are
  fully covered.

- When implementing work from a design or plan document, update the
  corresponding document after the implementation is complete. Also update
  user-facing documentation whenever behavior or public APIs change.

- Each commit must contain only files changed for the current task. Stage files
  explicitly; never include unrelated or pre-existing working-tree changes.
