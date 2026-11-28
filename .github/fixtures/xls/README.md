# Excel 97–2003 workbooks

The `.xls` workbooks the Excel 97–2003 codec is checked against, with
what the reference reader — [xlrd](https://github.com/xlrd/xlrd) —
gets from each, in a JSON sidecar beside the file. The corpus is in three
parts. The workbooks the reference writer,
[xlwt](https://github.com/python-excel/xlwt), wrote (`xlwt_*.xls`);
the workbooks built record by record with `xlsbuild.py` for what that
writer never spells (`syn_*.xls` — the two `RK` spellings it leaves out,
`LABEL`, `INDEX` and `DBCELL` records, a formula's other cached values, a
mini stream, a sector size of 4096, a workbook of no sheet); and the
files broken in one place each (`broken_*.xls`), with the refusal each
must meet. Two files are no `.xls` at all — a ZIP, and an `.xlsx` — for
the refusals they must meet.

A sidecar holds what the reference reader itself got from its file: its
sheets in workbook order, the date mode, and every cell that is not empty.
Two cells are the generator's word against the reader's and are marked so:
a formula whose cached value is the blank string, which the reader answers
as an empty text and the codec as no cell, and a continued `LABEL`
record, which the reader truncates. `index.json` lists the corpus, and
`sweep.json` records the reference reader's answer on every case of the
malformed-input test's replacement sweep.

[`gen_fixtures.py`](gen_fixtures.py) writes the corpus and its sidecars
(`make`), and its `verify` step re-reads every file with two readers —
xlrd, and the dataframe library riding it — and compares every cell with
the sidecar. A hand-built workbook's plan is compared with what the
reader read, cell for cell, at make time.

To regenerate them, from the repository root, in this order:

```sh
uv run --no-project --with xlwt --with xlrd --with pandas --with olefile python -I -X utf8 .github/fixtures/xls/gen_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/xls
uv run --no-project --with xlwt --with xlrd --with pandas --with olefile python -I -X utf8 .github/fixtures/xls/gen_fixtures.py verify
uv run --no-project python -I -X utf8 .github/fixtures/xls/check_refusal_tests.py
```

`make` clears the directory first, so it is always exactly what the last
`make` wrote; a second `make` writes the same bytes. It writes its logs
under `_build/xls_fixture_logs/`, which nothing tracks.
[`check_refusal_tests.py`](check_refusal_tests.py) checks that a test
asserts every refusal the reader raises. Neither is edited by hand.

Nothing of it runs in CI. `internal/xls/*_test.mbt` reads the corpus
through its index and states what each file must answer.
