# XML documents

The XML documents MoonFrame's reader is checked against, with the cells
the reference reader — [pandas](https://pandas.pydata.org/)' `read_xml`
over the lxml parser — gets from each, in a JSON sidecar beside the
document. [`make_fixtures.py`](make_fixtures.py) writes the documents
(one of them through pandas' `DataFrame.to_xml`), runs the reference
reader over each document and path, and writes the sidecars; its module
docstring states the cell spelling and the three places the library's
rule and the reference's differ on purpose. `records.xml` is a plain
table of attributes and child elements, `mixed.xml` a row with its own
text and repeated and empty children, `entities.xml` entity references
and CDATA, `data_items.xml` rows at two depths under two paths,
`root_row.xml` a document element that is itself a row, and
`pandas_to_xml.xml` what the reference writer produces.

To regenerate them:

```sh
uv run --with pandas --with lxml python make_fixtures.py
```

Nothing of it runs in CI: `io/xml_test.mbt` reads the documents and the
sidecars, and names what each must read as. A file no test names is not
read, and does not belong here.
