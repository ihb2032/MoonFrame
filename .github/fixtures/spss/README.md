# SPSS system files

The `.sav` and `.zsav` files MoonFrame's reader is checked against, with
the cells the reference readers — [pandas](https://pandas.pydata.org/)'
`read_spss` and [pyreadstat](https://github.com/Roche/pyreadstat)'s
`read_sav` — get from each, in a JSON sidecar beside the file. The corpus
holds files the one reference writer produces (strings of every width in
each of the three layouts, one column a format, declared missing values of
every shape, the numbers at the edges, no row, no column, very long
strings, three hundred cases through a zlib stream) and files
[`make_fixtures.py`](make_fixtures.py) derives from one for what no writer
produces small: patched case counts, other character sets, NUL bytes, the
other byte order, no long-name record, and the encrypted wrapper's
signature. [`make_fixtures.py`](make_fixtures.py) writes the corpus and its
sidecars — a sidecar's cells come from a reference reader itself — and its
`verify` step re-reads every file with both readers.

To regenerate them, from the repository root, in this order:

```sh
uv run --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/spss/make_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/spss
uv run --with pandas --with pyreadstat python -I -X utf8 .github/fixtures/spss/make_fixtures.py verify
```

`make` writes its logs under `_build/spss_fixture_logs/`, which nothing
tracks. [`savlayout.py`](savlayout.py) is the generator's own reading of
the layout, written from the format's documentation, compared with the
reference reader on every cell at make time;
[`check_refusal_tests.py`](check_refusal_tests.py) checks that a test
asserts every refusal the reader raises. Neither is edited by hand.

Nothing of it runs in CI. `internal/spss/*_test.mbt` names the files a
test reads, and states what each must read as. A file no test names is
not read, and does not belong here.
