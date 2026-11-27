"""The XML documents MoonFrame's reader is checked against, and the cells
the reference reader gets from each.

Run from the repository root:

    uv run --no-project --with pandas --with lxml \\
        python -I -X utf8 .github/fixtures/xml/make_fixtures.py

The documents are written here, beside one of them the reference
implementation wrote ([pandas] `DataFrame.to_xml`). For every document and
path the reference reader ([pandas] `read_xml`, the lxml parser) is run,
and its cells are written to a JSON sidecar: a column's name, its dtype
there, and its cells, each spelled `Null`, `Int 7`,
`Float <16 hex digits of the IEEE bits>`, `Bool true`, or
`String <text>`. A test reads each document with the codec and compares
every cell with its sidecar.

Where the library's rule and the reference's differ on purpose, the
document keeps clear of the case and MoonFrame's own tests pin it: the
library trims the whitespace around a cell's text, reads a column of
nothing but missing cells as `String`, and keeps to the CSV reader's
number rule.

[pandas]: https://pandas.pydata.org/
"""
from __future__ import annotations

import io
import json
import struct
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent

DOCUMENTS = {
    "records.xml": """<?xml version="1.0" encoding="utf-8"?>
<records>
  <row id="7" code="a">
    <qty>3</qty>
    <price>1.5</price>
    <ok>true</ok>
    <name>apple</name>
  </row>
  <row id="8" code="b">
    <qty>1200000000000</qty>
    <price>1e5</price>
    <ok>False</ok>
    <name/>
    <late>found</late>
  </row>
  <row id="9007199254740993" code="c">
    <qty>
      -1
    </qty>
    <price>-0.25</price>
    <ok>TRUE</ok>
    <name>café 日本語 😀</name>
    <late>x</late>
  </row>
</records>
""",
    "mixed.xml": """<records>
  <row id="1">loose<a>alpha</a><b>beta</b><a>second</a><b></b><c>  </c><id>child-id</id></row>
  <row id="2"><d>late</d></row>
</records>
""",
    "entities.xml": """<records>
  <row id="1"><name>Tom &amp; &quot;Jerry&quot; &lt;the 3rd&gt;<![CDATA[ raw <b>]]></name><u>café 日本語 😀</u></row>
  <row id="2"><name>plain</name><u> </u></row>
</records>
""",
    "data_items.xml": """<data>
  <group><item k="1"><v>a</v></item><item k="2"><v>b</v></item></group>
  <item k="3"><v>c</v></item>
</data>
""",
    "root_row.xml": """<row id="1"><v>a</v></row>
""",
}

# (document, the path the reference reader takes, the path MoonFrame takes)
CASES = [
    ("records.xml", "/records/row", "/records/row"),
    ("mixed.xml", "/records/row", "/records/row"),
    ("entities.xml", "/records/row", "/records/row"),
    ("data_items.xml", "//item", "//item"),
    ("data_items.xml", "/data/group/item", "/data/group/item"),
    ("root_row.xml", "/row", "/row"),
    ("pandas_to_xml.xml", "/data/row", "/data/row"),
    ("pandas_to_xml.xml", ".//row", "//row"),
]


def pandas_document() -> str:
    frame = pd.DataFrame(
        {
            "id": [1, 2, 3],
            "name": ["a", None, "café"],
            "ok": [True, False, True],
            "price": [1.5, 0.25, 19.99],
            "when": pd.to_datetime(
                ["2024-01-02 03:04:05", "2024-03-04 05:06:07", None], format="%Y-%m-%d %H:%M:%S"
            ),
        }
    )
    return frame.to_xml(index=False, parser="lxml")


def spell(value, dtype_name: str) -> str:
    dtype_name = dtype_name.lower()
    if value is None or value is pd.NA:
        return "Null"
    if "bool" in dtype_name:
        return f"Bool {'true' if bool(value) else 'false'}"
    if "int" in dtype_name:
        return f"Int {int(value)}"
    if "float" in dtype_name:
        number = float(value)
        if number != number:
            return "Null"
        return "Float {0:016x}".format(struct.unpack("<Q", struct.pack("<d", number))[0])
    if "str" in dtype_name or "object" in dtype_name:
        return f"String {value}"
    raise TypeError(f"unexpected cell {value!r} of dtype {dtype_name}")


def main() -> int:
    print(f"pandas {pd.__version__}")
    written = HERE / "pandas_to_xml.xml"
    written.write_text(pandas_document(), encoding="utf-8", newline="\n")
    print(f"wrote {written.name}")
    for name, text in DOCUMENTS.items():
        path = HERE / name
        path.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {name}")
    sidecars = 0
    for name, reference_xpath, library_xpath in CASES:
        frame = pd.read_xml(HERE / name, xpath=reference_xpath, dtype_backend="numpy_nullable")
        sidecar = {
            "file": name,
            "xpath": library_xpath,
            "reference_xpath": reference_xpath,
            "rows": int(frame.shape[0]),
            "columns": [
                {
                    "name": str(column),
                    "dtype": str(frame[column].dtype),
                    "cells": [
                        spell(value, str(frame[column].dtype)) for value in frame[column]
                    ],
                }
                for column in frame.columns
            ],
        }
        slug = library_xpath.strip("/").replace("/", "_").replace(".", "") or "root"
        out = HERE / f"{Path(name).stem}__{slug}.json"
        out.write_text(json.dumps(sidecar, indent=1, ensure_ascii=False) + "\n",
                       encoding="utf-8", newline="\n")
        sidecars += 1
        print(f"  {out.name}: {frame.shape[0]} rows, {frame.shape[1]} columns, "
              f"dtypes {[str(t) for t in frame.dtypes]}")
    print(f"sidecars: {sidecars}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
