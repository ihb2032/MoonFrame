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
sh .github/scripts/check_facade_docs.sh
sh .github/scripts/check_stale_names.sh
```

- **Version identity** — `moon.mod`, `docs/api.md`, `docs/changelog.md`, and
  `docs/migration.md` must name one release. While a release is being prepared
  on `main`, the changelog's newest heading carries `(unreleased)` and
  `moon.mod` still publishes the previous version; **cutting the release means
  dropping that marker and bumping `moon.mod` together**, which is what the
  guard enforces.
- **Facade coverage** — every symbol re-exported by the root package appears in
  the facade list in `docs/api.md`, and nothing lingers there that has been
  removed.
- **Stale names** — a removed identifier must not appear in current-state prose
  or a source comment. `docs/changelog.md` and `docs/migration.md` are exempt
  (history is their content); a single line that must name one takes the marker
  `doc-guard: historical`.

A fourth pass, `review_absolute_wording.sh`, annotates absolute claims ("all",
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
