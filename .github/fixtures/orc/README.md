# ORC files

The ORC files MoonFrame's reader is checked against, with the cells the
reference reader — [pyarrow](https://arrow.apache.org/docs/python/)'s
`orc.read_table`, the format's own C++ implementation — gets from each, in a
JSON sidecar beside the file. The corpus holds files pyarrow's writer produces
(one column a carried type, lists and structs at every depth, the dictionary
encoding, every compression kind, both format versions, the numbers at their
edges), files [`make_fixtures.py`](make_fixtures.py) builds stream by stream
for the shapes no writer spells (the short repeat, patched base and delta
runs at their widths, every nanosecond spelling, decimals of every precision),
files it derives from one of those by breaking a single field — each pinning
one refusal of the reader, with the refusal's text in its sidecar — and the
small example files of the format's own repository, written by its Java
implementation (Apache-2.0). [`make_fixtures.py`](make_fixtures.py) writes the
corpus and its sidecars — a sidecar's cells come from the reference reader
itself, and name the few views where it cannot hold what the file carries —
and its `verify` step re-reads every view with the reference reader, and
every file of the replacement sweep it opens.

To regenerate them, from the repository root, in this order:

```sh
uv run --with pyarrow --with tzdata --with cramjam python -I -X utf8 .github/fixtures/orc/make_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/orc
uv run --with pyarrow --with tzdata --with cramjam python -I -X utf8 .github/fixtures/orc/make_fixtures.py verify
```

The scripts beside the generator are its own: [`orclayout.py`](orclayout.py)
reads a file's layout without decoding a cell, [`orcenc.py`](orcenc.py) spells
the streams of a hand-built stripe, and [`reference_summary.py`](reference_summary.py)
and [`reference_sweep.py`](reference_sweep.py) run the reference reader on one
file in a process of its own, since a malformed file may crash its C++ core.
[`check_refusal_tests.py`](check_refusal_tests.py) checks that a test asserts
every refusal the reader raises. None is edited by hand.

`make` fetches the example files it needs into `_build/orc_examples/` and
writes its logs under `_build/orc_fixture_logs/`, which nothing tracks.

Nothing of it runs in CI. `internal/orc/*_test.mbt` names the corpus through
its index, and states what each file must read as. A file the index does not
list fails the fixtures test.
