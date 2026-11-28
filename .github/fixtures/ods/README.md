# OpenDocument spreadsheets

The `.ods` packages the OpenDocument spreadsheet codec is checked against,
with what the reference reader — [pandas](https://pandas.pydata.org/)'s
`read_excel`, over [odfpy](https://github.com/tdf/odfpy) — gets from each,
in a JSON sidecar beside the file. Most packages were written by two
writers, odfpy's own elements and [ezodf](https://github.com/yrro/ezodf);
some have a `content.xml` the generator spells by hand for a shape no
writer spells — other namespace prefixes, UTF-16, a nested table, no
`mimetype` entry, a pretty-printed or a stored one; and the `broken_`
files are each a written package patched in one place, with the refusal it
must meet. A sidecar holds, for every sheet, the cells the reference
reader itself got from the file; where that reader cannot open the file,
or raises on a sheet, the cells are the generator's own reading of the
`content.xml` it wrote, and the sidecar says so. Two files are no
spreadsheet package at all — a ZIP that is not one, and an `.xlsx` — for
the refusals they must meet. `index.json` lists the corpus.

[`gen_fixtures.py`](gen_fixtures.py) writes the corpus and its sidecars
(`make`), and its `verify` step re-reads every file with the reference
reader — its reader class, and the named call — and compares what it
answers with the sidecar's record of it. A writer's entry stamps are
replaced by a fixed one, so a package written twice is the same bytes.

To regenerate them, from the repository root, in this order:

```sh
uv run --no-project --with pandas --with odfpy --with ezodf --with lxml --with openpyxl python -I -X utf8 .github/fixtures/ods/gen_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/ods
uv run --no-project --with pandas --with odfpy --with ezodf --with lxml --with openpyxl python -I -X utf8 .github/fixtures/ods/gen_fixtures.py verify
uv run --no-project python -I -X utf8 .github/fixtures/ods/check_refusal_tests.py
```

`make` clears the directory first, so it is always exactly what the last
`make` wrote. It writes its logs under `_build/ods_fixture_logs/`, which
nothing tracks. [`check_refusal_tests.py`](check_refusal_tests.py) checks
that a test or a sidecar asserts every refusal the reader raises. Neither
is edited by hand.

Nothing of it runs in CI. `internal/ods/*_test.mbt` reads the corpus
through its index and states what each file must answer.
