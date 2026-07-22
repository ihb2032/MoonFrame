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

## Formal verification

- `internal/verified` holds proof-carrying pure kernels: each function carries
  a `proof_ensure` contract over the named predicates in `specs.mbtp`, and
  `moon prove internal/verified` must report every goal proved.

- The prover needs Why3 + Alt-Ergo, which are not installed on Windows; on
  this machine they live in WSL (`wsl -u root`, moon pinned to the same
  version as CI). Proofs do not run in CI — treat a green `moon prove` as part
  of the local gate whenever that package changes.

- The prover's frontier is narrower than the language: contracted bodies
  reject tuple / or-patterns and early `return`, `.mbtp` predicates take
  `Option[T]` spelled out and no `else if`, and packages defining
  Array-wrapping types (or using Double / String methods / closures in
  contracted code) cannot be proved at all — which is why the island imports
  nothing and the columnar core stays test-covered instead.

## Completion Requirements

- Keep test coverage at 100%. Before finishing a change, run
  `moon coverage analyze` and require it to report that all source files are
  fully covered.

- When implementing work from a design or plan document, update the
  corresponding document after the implementation is complete. Also update
  user-facing documentation whenever behavior or public APIs change.

- Each commit must contain only files changed for the current task. Stage files
  explicitly; never include unrelated or pre-existing working-tree changes.
