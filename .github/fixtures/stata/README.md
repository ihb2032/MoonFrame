# Stata datasets

The Stata dataset files MoonFrame's reader is checked against, each
written by one of two implementations other than MoonFrame's own
entries — pandas' `DataFrame.to_stata` and pyreadstat's `write_dta` —
with the table fixed in [`make_fixtures.py`](make_fixtures.py), which
also states what each fixture is for. Beside every `.dta` file sits a
JSON sidecar holding the cells the reference *reader* itself got from
that file, so no expectation in a test comes from the codec, and
`reference/index.json` lists the corpus with each file's digest.
`pandas_v*.dta` and `pyreadstat_v*.dta` hold one table of every storage
under each release and byte order the writer produces, `codes_*` all 27
missing codes, `limits_*`, `names_*` and `reserved_*` the edges of a
cell and of a name, `empty_*` and `norows_*` the empty shapes, and
`synthetic_*` the releases and byte orders no reference writer produces
(each sidecar says what was changed and which reader confirmed the
result).

To regenerate them:

```sh
uv run --with pandas --with pyreadstat python make_fixtures.py make
```

The script's `verify` step is the other direction, and the cross-check
of MoonFrame's writer: it opens files MoonFrame wrote with both
reference readers and compares every cell with the table the codec was
handed. Nothing of it runs in CI, so run it by hand after a change to
the writer — the codec's export test leaves the files under `_build`:

```sh
moon test -p ihb2032/MoonFrame/internal/stata
uv run --with pandas --with pyreadstat python make_fixtures.py verify
```

[`probe_writers.py`](probe_writers.py) prints which releases and byte
orders each reference writer can produce, the evidence behind the
synthetic files. `internal/stata/*_test.mbt` names the files a test
reads, and states what each must read as. A file no test names is not
read, and does not belong here.
