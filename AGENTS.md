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

- Try to keep deprecated blocks in file called `deprecated.mbt` in each <!-- doc-guard: unresolved -->
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

## One fact, one home

Every drift this repository has had came from the same shape: a fact written in
two places, changed in one. The equality contract lived in a docstring and in
the API guide; the import allowlist lived in three documents and a script; a
release number lived on six pages. Each time, the copy nobody edited became a
confident, wrong instruction.

So a fact gets one home, and everything else points at it. Where it goes:

| Fact | Home |
| --- | --- |
| A rule CI enforces (imports, seams, surfaces) | the guard script that enforces it — it cannot silently stop being true |
| The structural invariants of a `DataFrame` | `frame/invariants.mbt` (INV1–INV7) |
| What one symbol does | its docstring — the reference on mooncakes.io is generated from it |
| Cross-cutting API behaviour (errors, evaluation, the optimizer) | `docs/api.md` |
| Cost and complexity | `docs/performance.md` |
| How MoonFrame differs from Polars / pandas | `docs/comparison.md` |
| What a release changed / how to upgrade | `docs/changelog.md`, `docs/migration.md` |
| What each guard governs and how to run it | this file |

A pointer is not a copy: "the import allowlist is in `check_layering.sh`" stays
true when the allowlist changes, while "`internal/column` is imported by
`series` and `internal/kernel`" does not. Prefer describing *why* something is
where it is — that is what a second file can add without duplicating the fact —
and leave the enumerable part to its home. When you catch yourself restating a
rule for the reader's convenience, link instead.

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
sh .github/scripts/check_internal_surface.sh
sh .github/scripts/check_comment_references.sh
```

- **Version identity** — `moon.mod`, `docs/changelog.md` and
  `docs/migration.md` must name one release, and nothing else names one at all:
  the guides describe `main` and promise the facade surface, so a reader never
  has to reconcile two numbers, and prose never goes stale for saying which
  release it belongs to. Both halves are enforced — the three are compared, and
  every other tracked piece of prose (Markdown, the workflow and manifests,
  comment lines in sources) is scanned for a release-shaped version, with
  third-party versions excluded by a list in the guard and a past release opting
  out through `doc-guard: historical`. While a release is being prepared on
  `main`, the changelog's newest heading carries `(unreleased)` and `moon.mod`
  still publishes the previous version; **cutting the release means dropping that
  marker and bumping `moon.mod` together**, which is what the guard enforces.
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
  appearing, an optional parameter becoming required, a field widening to `?`.
  Three rules sit ahead of the snapshot, so regenerating cannot legalize them:
  only the four fluent-chain types may be public without being re-exported;
  every public free function must have a facade counterpart (nothing chains to
  a function, so one the facade omits is unreachable through the supported
  surface); and **no public field may hold a mutable container** (`Array` /
  `Map` / …) — reading one hands the container itself to the caller. Keep such
  a field `priv` behind an accessor that copies, as
  `CsvReadOptions::null_values` and `JoinOptions::on_keys` do. `moon info` and the downstream fixture catch
  under-exports and interface drift; this catches an *over-export* — a symbol
  that reaches callers as `@moonframe.Type::method` without any facade change,
  and becomes a breaking change once published. Any add / remove /
  reclassification / source-package change fails until the snapshot is
  regenerated (`sh .github/scripts/check_facade_surface.sh --write`).
- **Stale names** — a removed identifier must not appear in current-state prose
  or in a comment that explains something: tracked `*.md`, `*.mbt`, the CI
  workflow and the package manifests. The guard scripts are not scanned — the
  list of removed names lives in one of them. `docs/changelog.md` and
  `docs/migration.md` are exempt (history is their content); a line that must
  name one takes the marker
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
  manifests. Which package may import which is written once, in the guard that
  enforces it (`.github/scripts/check_layering.sh`) — the import allowlists,
  the packages that may reach the storage and kernel layers, the facade's exact
  dependency set, and the ban on an internal type in a public
  `pkg.generated.mbti`. Two rules hold the *direction* the snapshot cannot: each package
  declares what it may depend on, and the graph must stay acyclic — a
  reversal or a cycle is not a new edge to accept but a change of what the
  stack means. Every other production edge is pinned in
  `.github/scripts/layering.snapshot`, so a new dependency lands deliberately
  (`sh .github/scripts/check_layering.sh --write`). Test-only import blocks are
  exempt by design (`frame`'s tests name `StorageKind`). Changing the layering
  means changing the rule in the guard first, then both documents.
- **Engine seams** — every `pub` symbol in a public package carrying
  `#internal(engine, …)` / `#doc(hidden)`, with its normalised signature,
  pinned in `.github/scripts/engine_seams.snapshot`, including the variants of
  a hidden `pub(all)` enum, which the enum-surface lock cannot see either.
  `#doc(hidden)` keeps these out of the generated interface, which is exactly
  why the facade lock cannot see them; this is where adding one — or widening
  one, a seam that starts handing another package a mutable buffer — has to be
  noticed
  (`sh .github/scripts/check_engine_seams.sh --write`). The two attributes are
  a pair and either half alone is rejected outright: an alert on a symbol the
  interface still publishes, or — the quieter mistake — a symbol hidden from
  the interface, and so from every guard that reads one, with nothing stopping
  a downstream call.
- **Internal surface** — the same question, asked inside the module. A `pub`
  function or type in an `internal/` package must be used by another package;
  otherwise it is package-private (its tests move in with it, as `_wbtest.mbt`)
  or deleted, and the few that cannot be either — an invariant predicate exists
  to be asserted and so has no caller — are listed with their reason in
  `.github/scripts/internal_surface.allowlist`. The symbols come from the
  package's generated interface rather than its source, which is what makes the
  count complete: a `derive`'s methods and every `pub impl` are in it. A source
  `pub fn` the interface does *not* carry fails outright — inside an internal
  package `#doc(hidden)` buys nothing the module boundary has not already
  bought, and it hides the symbol from every reader of the interface, this
  audit included. Fields never appear in one either: a field publishes the
  layout where the methods beside it publish what a consumer needs. Callers are
  matched by spelling, and where a spelling cannot say *which* symbol was meant
  (`.len(`, or a bare free-function token), the compiler is asked instead — the
  symbol is made private, the module is type-checked, and a diagnostic in
  another package proves the call. Probes run one batch per package, with a
  second pass alone for whatever the batch left unproven, since the first
  package to fail blocks the ones above it. Where no toolchain is available the
  unsettled set is pinned in `.github/scripts/internal_surface.ambiguous`
  instead (`sh .github/scripts/check_internal_surface.sh --write`). The methods
  a `derive` generates and the `pub impl` / `pub extend` lines stay outside the
  audit — a derived `equal` is reached through `==` and through the `derive` of
  any type embedding this one, neither of which writes its name — so they are
  **pinned** in `.github/scripts/internal_generated.snapshot` rather than
  audited. A count going up says something grew without saying what; the
  snapshot makes the next one a question to answer — but the question is about
  the *impl*, not the method beside it. MoonBit promotes a trait impl's methods
  to regular methods ([0079]), and neither half of that can be declined: leaving
  the `pub extend` out is a deprecation error, and writing a non-`pub` one makes
  `equal` an unused function. So an impl a package must keep visible publishes
  `equal` / `not_equal` / `to_repr` with it, and every such line in the snapshot
  is forced by an impl above it: `ColumnStorage`'s content equality (which
  `Series` and `DataFrame` compare through), the `Debug` chain their `derive`
  needs down to the buffers, `StorageKind`'s reader for `frame`'s
  backend assertions, and the AST tags whose `Eq` the node comparison in
  `internal/ir/equality_wbtest.mbt` consumes. The answer to "does this need to be
  here" is therefore whether *production* needs that impl at all: if only a test
  wants the operator, the impl belongs in a `_wbtest.mbt`, which compiles inside
  its package and publishes nothing — that is where the column and AST
  equalities live, after a review found thirteen of them in the interfaces, and
  where `Bitmap`'s went once it turned out that only a test ever compared two
  validity buffers. If nothing needs it, the impl goes: `PhysicalType` carries no
  trait at all, because a caller matches on the tag. **A clean run means nothing
  is provably unused, not that everything left is needed.**

- **Comment references** — a comment that names something is making a claim,
  and two of those a machine can check: `@pkg.Name` must be a name that package
  declares, `Type::method` must be a pair that exists, and a `path/file.mbt` <!-- doc-guard: unresolved -->
  must be a file — resolved as a sibling first, then from the root, so a
  cross-package reference has to say which package. Evidence comes from code
  only: two comments naming the same dead symbol are the drift, not proof of
  each other. A qualifier this module does not define (`@debug`, `@string`) is
  external and skipped, as is a `Type::method` whose type the module does not
  declare — the standard library is not read here, so a miss there would say
  nothing. Two markers skip a line, and choosing between them is choosing what
  you are claiming: `doc-guard: historical` says the name *was* real, and
  `doc-guard: unresolved` says it was never meant to resolve — a convention
  (`deprecated.mbt`), a deliberate absence ("no dedicated `foo_test.mbt`"), a <!-- doc-guard: unresolved -->
  basename several packages share. In Markdown the marker goes in an HTML
  comment so a reader of the rendered page never sees it. **What no guard can
  check is the sentence around the name**: every comment corrected in this
  repository so far named only living symbols and still described something
  that had changed.

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
