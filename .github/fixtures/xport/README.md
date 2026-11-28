# SAS transport files

The Version 5 transport files MoonFrame's reader is checked against,
with the cells the readers get from each, in a JSON sidecar beside the
file. [`make_fixtures.py`](make_fixtures.py) writes twelve with the one
reference writer ([pyreadstat](https://github.com/Roche/pyreadstat)'s
`write_xport`), lays thirteen out itself for what no reference writer
produces — the 28 missing spellings and their lookalikes, numeric
variables 2 to 7 bytes wide, IBM spellings chosen by hand, the row-count
shapes, formats the reference writer will not attach, descriptors of 135
bytes, character variables of 200, 201 and 255 bytes — and four more as
files the reader refuses by name; a sidecar's cells come from the
generator's own exact arithmetic over the bytes, and say per column
whether each reference reader — [pandas](https://pandas.pydata.org/)'
`read_sas` and pyreadstat's `read_xport` — returned the same cells. It
also writes the whitebox vectors (`internal/xport/vectors_wbtest.mbt`,
generated: do not edit it). The script's `verify` step reads what the
codec's export test left under `_build` back with both reference readers.

To regenerate everything, from the repository root, in this order:

```sh
uv run --with pandas --with pyreadstat python .github/fixtures/xport/make_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/xport
uv run --with pandas --with pyreadstat python .github/fixtures/xport/make_fixtures.py verify
python .github/fixtures/xport/sidecar_report.py
```

Nothing of it runs in CI. `internal/xport/*_test.mbt` names the files a
test reads, and states what each must read as. A file no test names is
not read, and does not belong here.
