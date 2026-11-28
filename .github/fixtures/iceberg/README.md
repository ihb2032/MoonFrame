# Iceberg tables

The Iceberg tables the metadata codec is checked against — every table's
whole directory as the reference wrote it, a JSON sidecar beside it
holding what the reference itself answers for it, and `index.json`
listing both. The reference is [pyiceberg](https://pyiceberg.apache.org/)
with its native core; the version the corpus was written by is the one
`index.json` names under `writer`.

The corpus is in three parts. Twenty-eight tables the reference wrote:
appends, an overwrite, a delete, a schema evolution between versions,
every carried type, names and strings outside ASCII, tables partitioned
by identity and by the other transforms, format versions 1 and 2, a
table with no snapshot, tables of no column and of no rows, a branch and
a tag, manifests under two block codecs — and seven the codec refuses by
name (a `binary` column, a `map`, a `time`, a wide decimal, a column
added with a default, a file imported without field ids, a block codec
the reader does not inflate). Five tables derived from ones the reference
wrote: a position-delete file in an unpartitioned table and one in a
partitioned table, an equality-delete file, a format version 3, and a
version 4 both the reference and the codec refuse. And 295 hand-patched files —
metadata, manifest lists and manifests broken in one place each, or built
record by record for a shape the reference never writes — under
`patched/`, each with the refusal or the answer it must meet in the index.

A sidecar holds the schema with its field ids, the partition spec, the
snapshot's manifests and files, the rows of the reference's own scan, and
`plan_rows`: the files read one by one in the plan's order with the
position deletes applied — what a reader of the files answers. One data
file is not carried, its path too long for a checkout; its sidecar names
it under `not_carried`, and a reader of its table's rows meets the
missing file as the I/O error it is.

Under [`io/`](io/) lie four Parquet files a reading of a table's rows is
checked against and the reference's writer never writes — a delete file
whose path cell is a whole number or whose position cell is a text, and a
data file lacking a column the table holds — written by
[`io/make_fixtures.py`](io/make_fixtures.py) (`uv run --with pyarrow python
io/make_fixtures.py`).

[`gen_fixtures.py`](gen_fixtures.py) writes the corpus (`make`) and its
`verify` step re-reads every table with the reference and compares what
it answers with the sidecar's record of it. The reference chooses a UUID
and a timestamp for each commit, so file names differ from one `make` to
the next while every count and answer stays the same.

To regenerate them, from the repository root, in this order:

```sh
uv run --no-project --with "pyiceberg[pyiceberg-core]" --with pyarrow --with sqlalchemy --with zstandard python -I -X utf8 .github/fixtures/iceberg/gen_fixtures.py make
moon fmt
moon test -p ihb2032/MoonFrame/internal/iceberg
uv run --no-project --with "pyiceberg[pyiceberg-core]" --with pyarrow --with sqlalchemy --with zstandard python -I -X utf8 .github/fixtures/iceberg/gen_fixtures.py verify
uv run --no-project python -I -X utf8 .github/fixtures/iceberg/check_refusal_tests.py
```

`make` clears the directory first, so it is always exactly what the last
`make` wrote; it writes its tables under a transient warehouse in
`_build/`, which nothing tracks, and refuses a corpus over its size
limit. [`check_refusal_tests.py`](check_refusal_tests.py) checks that a
test asserts every refusal the reader raises. Neither is edited by hand.

Nothing of it runs in CI. `internal/iceberg/*_test.mbt` reads the corpus
through its index and states what each file must answer; `io/iceberg_test.mbt`
reads every table through `read_iceberg` and compares its rows with
`plan_rows`.
