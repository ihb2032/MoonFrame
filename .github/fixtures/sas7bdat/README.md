# SAS data sets

The `sas7bdat` files MoonFrame's reader is checked against, with the cells
the reference readers — [pandas](https://pandas.pydata.org/)' `read_sas`
and [pyreadstat](https://github.com/Roche/pyreadstat)'s `read_sas7bdat` —
get from each, in a JSON sidecar beside the file. The corpus holds files
SAS itself wrote (seven of the pandas test corpus, among them one that
opens with no character set recorded and one in windows-1251), files the
one reference writer produces (the 32-bit layout, and rows compressed with
each method), and files [`sas7bdat_build.py`](sas7bdat_build.py) lays out
for what no writer produces small: every display-format family, the
character sets, the page kinds, numeric columns 1 to 8 bytes wide in four
layouts, and the files the reader refuses by name.
[`make_fixtures.py`](make_fixtures.py) writes the corpus and its
sidecars — a sidecar's cells come from a reference reader itself, and say
per column whether each reader's own converted result agrees — and its
`verify` step re-reads every file with both readers.

To regenerate them, from the repository root, in this order:

```sh
uv run --with pandas python .github/scripts/gen_sas7bdat_charsets.py
uv run --with pandas --with pyreadstat python .github/fixtures/sas7bdat/make_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/sas7bdat
uv run --with pandas --with pyreadstat python .github/fixtures/sas7bdat/make_fixtures.py verify
```

`gen_sas7bdat_charsets.py` writes `internal/sas7bdat/charsets.mbt` (the
49 single-byte code pages, taken from Python's codecs by way of the
reference reader's table of codes) and the whitebox vectors beside it;
neither is edited by hand. `make` fetches the pandas corpus files it
needs into `_build/sas7bdat_corpus/`.
[`sidecar_notes.py`](sidecar_notes.py) prints the cell-level
disagreements with the reference readers.

Nothing of it runs in CI. `internal/sas7bdat/*_test.mbt` names the files
a test reads, and states what each must read as. A file no test names is
not read, and does not belong here.
