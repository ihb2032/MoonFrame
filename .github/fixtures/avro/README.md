# Avro files

The Avro container files MoonFrame's reader is checked against, each
written by [fastavro](https://fastavro.readthedocs.io/) — an
implementation other than the one MoonFrame's own entries ride — with
the table fixed in [`make_fixtures.py`](make_fixtures.py), which also
states what each fixture is for. `fastavro_types_<codec>.avro` holds one
table under each block codec, `fastavro_multiblock.avro` the same rows
over many blocks, `fastavro_logical.avro` the logical types the types
file leaves out, and `fastavro_refused_<shape>.avro` a table with one
field the mapping does not carry, beside a column it does. The
`bzip2` file is the one block codec the reference writes that the reader
refuses by name.

To regenerate them:

```sh
uv run --with fastavro --with cramjam --with backports.zstd python make_fixtures.py
```

`cramjam` and `backports.zstd` are the libraries `fastavro` reaches for
to compress and to write zstandard.

The script's `verify` mode is the other direction, and the cross-check of
MoonFrame's writer: it opens files MoonFrame wrote with `fastavro` and
compares every cell with the reference table. Nothing of it runs in CI,
so run it by hand after a change to the writer — the codec's tests leave
the files under `_build`:

```sh
moon test -p ihb2032/MoonFrame/internal/avro
uv run --with fastavro --with cramjam --with backports.zstd python make_fixtures.py verify ../../../_build/avro_written/*.avro
```

`internal/avro/avro_test.mbt` and `io/avro_test.mbt` name the files a
test reads, and state what each must read as. A file no test names is
not read, and does not belong here.
