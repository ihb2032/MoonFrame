# Fixed-width files

The fixed-width text files the column logic is checked against, with the
boundaries and the cells the reference reader — [pandas](https://pandas.pydata.org/)'s
`read_fwf` — gets from each, in a JSON sidecar beside the file. The corpus
holds a classic rigid grid, columns of ragged widths, a header wider than
its cells and a cell wider than the header, indentation, trailing spaces,
blank lines, tabs inside and between fields, empty fields, short lines,
headers and cells outside ASCII, the reference reader's own test shape, a
line holding nothing but a space the reference's table drops, a preamble
meant to be skipped, comment lines, and the two line-ending conventions
beside the Unix one; two files hold nothing to infer a layout from, which the
sidecars name as refusals. Every file is read under two or more readings —
the reference's own inference, and a width a field — and some under a
smaller window, skipped lines or a comment marker. `sweep.json` records the
reference reader's answer on every case of the malformed-input sweeps.
[`gen_fixtures.py`](gen_fixtures.py) writes the corpus, its sidecars and the
sweep from one named seed — a sidecar's boundaries and cells come from the
reference reader itself — and its `verify` step regenerates the corpus into
a temporary directory, compares byte for byte, and re-reads every file with
the reference.

To regenerate them, from the repository root, in this order:

```sh
uv run --with pandas python -I -X utf8 .github/fixtures/fwf/gen_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/fwf
uv run --with pandas python -I -X utf8 .github/fixtures/fwf/gen_fixtures.py verify
uv run --no-project python -I -X utf8 .github/fixtures/fwf/check_refusal_tests.py
```

`make` clears the directory first, so it is always exactly what the last
`make` wrote; the fixtures test fails on a data file its index does not
list. It writes its logs under `_build/fwf_fixture_logs/`, which nothing
tracks. [`check_refusal_tests.py`](check_refusal_tests.py) checks that a test
asserts every refusal the reader raises. Neither is edited by hand.

Nothing of it runs in CI. `internal/fwf/*_wbtest.mbt` reads the corpus through
its index and states what each reading must answer.
