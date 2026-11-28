# HTML tables

The HTML documents MoonFrame's reader is checked against, with the
tables the reference reader — [pandas](https://pandas.pydata.org/)'
`read_html` over the lxml parser — gets from each, in a JSON sidecar
beside the document. [`make_fixtures.py`](make_fixtures.py) writes the
documents, runs the reference reader over each, and writes the sidecars;
its module docstring states the cell spelling and the places the
library's rule and the reference's differ on purpose. `plain.html` is a
page around one table, `spans.html` a header and rows that reach over
several positions, `several.html` four tables — one without a header,
one with a header of two rows, one holding a nested table — `messy.html`
upper-case tags, cells and rows without ends, a comment, a script, a
foot, and tables that hold nothing, and `numbers.html` the number and
missing-value spellings.

To regenerate them:

```sh
uv run --with pandas --with lxml python make_fixtures.py
```

[`make_entities.py`](make_entities.py) writes the named character
references the reader decodes out of the HTML 4 set:

```sh
uv run python make_entities.py
```

Nothing of it runs in CI: `io/html_test.mbt` reads the documents and the
sidecars, and names what each must read as. A file no test names is not
read, and does not belong here.
