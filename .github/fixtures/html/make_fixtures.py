"""The HTML documents MoonFrame's reader is checked against, with the
tables the reference reader gets from each.

Run from the repository root:

    uv run --no-project --with pandas --with lxml \\
        python -I -X utf8 .github/fixtures/html/make_fixtures.py

Every document is written here. For each, the reference reader —
[pandas](https://pandas.pydata.org/)' `read_html` over the lxml parser —
is run, and each table it answers is written to a JSON sidecar: the
columns' names (a name a list when the header has more than one row), the
dtype there, and the cells, each spelled `Null`, `Int 7`,
`Float <16 hex digits of the IEEE bits>`, `Bool true`, or
`String <text>`. A test reads each document and compares every table and
cell with its sidecar.

Where the library's rule and the reference's differ on purpose, the
document keeps clear of the case and MoonFrame's own tests pin it: a table
with no header names its columns `column1`, `column2`, … where the
reference numbers them; a header cell left empty names its column the same
way where the reference writes `Unnamed: N`; a multi-row header's names are
joined by a space where the reference keeps a tuple; a misspelt boolean is
text; and the CSV reader's number rule holds.
"""
from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent

DOCUMENTS = {
    "plain.html": """<!DOCTYPE html>
<html>
<head><title>Sales</title><style>td { color: black }</style></head>
<body>
<h1>Quarterly sales</h1>
<p>Figures are <b>unaudited</b>.</p>
<table id="sales">
  <caption>Q1</caption>
  <thead>
    <tr><th>Item</th><th>Qty</th><th>Price</th><th>Note</th><th>Ok</th></tr>
  </thead>
  <tbody>
    <tr><td>apple</td><td>3</td><td>1.5</td><td>fresh &amp; crisp</td><td>yes</td></tr>
    <tr><td>caf&eacute; au lait</td><td>1,234</td><td>0.25</td><td>hot<br>large</td><td>no</td></tr>
    <tr><td><i>pear</i></td><td></td><td>-7</td><td>
      spread over
      three lines
    </td><td>NA</td></tr>
    <tr><td>&lt;unit&gt; &#8364;4 &#x1F34E;</td><td>9007199254740993</td><td>1e3</td><td>  padded  </td><td>N/A</td></tr>
  </tbody>
</table>
<p>After.</p>
</body>
</html>
""",
    "spans.html": """<table border="1">
  <thead>
    <tr><th rowspan="2">Region</th><th colspan="2">Q1</th><th>Q2</th></tr>
    <tr><th>a</th><th>b</th><th>c</th></tr>
  </thead>
  <tbody>
    <tr><td rowspan="3">north</td><td>1</td><td>2</td><td>3</td></tr>
    <tr><td>4</td><td>5</td><td>6</td></tr>
    <tr><td colspan="3">wide cell</td></tr>
    <tr><td>south</td><td>7</td><td>8</td><td>9</td></tr>
  </tbody>
</table>
""",
    "several.html": """<div>
<table>
  <tr><td>x</td><td>1</td></tr>
  <tr><td>y</td><td>2</td></tr>
</table>
<p>between</p>
<table class="second">
  <tr><th>first</th><th>second</th></tr>
  <tr><th>upper</th><th>lower</th></tr>
  <tr><td>1</td><td>2.5</td></tr>
</table>
<table>
  <tr><th>outer</th><th>holder</th></tr>
  <tr><td>o1</td><td>before
    <table><tr><th>inner</th></tr><tr><td>i1</td></tr><tr><td>i2</td></tr></table>
    after</td></tr>
</table>
</div>
""",
    "messy.html": """<TABLE BORDER=1>
<TR><TH NOWRAP>name<TH>value
<TR><TD>a<TD>1
<TR><TD>b<TD>
</TABLE>
<!-- <table><tr><td>in a comment</td></tr></table> -->
<script>var t = "<table><tr><td>in a script</td></tr></table>";</script>
<table>
  <thead><tr><th></th><th>n</th></tr></thead>
  <tbody><tr><td>a</td><td>1</td><td>extra</td></tr><tr><td>b</td></tr></tbody>
  <tfoot><tr><td>total</td><td>3</td></tr></tfoot>
</table>
<table></table>
<table><tbody><tr><td>only body</td></tr></tbody></table>
<p>a < b and a <b>bold</b> word and 3<4 and &copy; 2024 &amp; more</p>
""",
    "numbers.html": """<table>
  <tr><th>thousands</th><th>float</th><th>neg</th><th>whole</th><th>blank</th>
      <th>dash</th><th>truth</th><th>padded</th><th>signed</th><th>exp</th>
      <th>text</th><th>missing</th><th>nullish</th></tr>
  <tr><td>1,234,567</td><td>1.5</td><td>-7</td><td>3.0</td><td></td>
      <td>-</td><td>True</td><td> 12 </td><td>+12</td><td>5e3</td>
      <td>$5</td><td>N/A</td><td>NULL</td></tr>
  <tr><td>12,34</td><td>-0.25</td><td>2</td><td>4</td><td>x</td>
      <td>+</td><td>FALSE</td><td>3</td><td>-4</td><td>1e-3</td>
      <td>50%</td><td>nan</td><td>None</td></tr>
  <tr><td>123,</td><td>.5</td><td>0</td><td>5</td><td>y</td>
      <td>n/a</td><td>true</td><td>5</td><td>6</td><td>2E2</td>
      <td>(4)</td><td>#N/A</td><td>null</td></tr>
</table>
""",
}


def spell(value, dtype_name: str) -> str:
    dtype_name = dtype_name.lower()
    if value is None or value is pd.NA:
        return "Null"
    if isinstance(value, float) and value != value:
        return "Null"
    if "bool" in dtype_name:
        return f"Bool {'true' if bool(value) else 'false'}"
    if "int" in dtype_name:
        return f"Int {int(value)}"
    if "float" in dtype_name:
        return "Float {0:016x}".format(struct.unpack("<Q", struct.pack("<d", float(value)))[0])
    if isinstance(value, str):
        return f"String {value}"
    raise TypeError(f"unexpected cell {value!r} of dtype {dtype_name}")


def name_of(column) -> list[str] | str:
    if isinstance(column, tuple):
        return [str(level) for level in column]
    return str(column)


def main() -> int:
    print(f"pandas {pd.__version__}")
    tables = 0
    for name, text in DOCUMENTS.items():
        path = HERE / name
        path.write_text(text, encoding="utf-8", newline="\n")
        frames = pd.read_html(path, flavor="lxml")
        sidecar = {
            "file": name,
            "tables": [
                {
                    "columns": [
                        {
                            "name": name_of(column),
                            "dtype": str(frame[column].dtype),
                            "cells": [
                                spell(value, str(frame[column].dtype))
                                for value in frame[column]
                            ],
                        }
                        for column in frame.columns
                    ],
                    "rows": int(frame.shape[0]),
                }
                for frame in frames
            ],
        }
        out = HERE / f"{path.stem}.json"
        out.write_text(json.dumps(sidecar, indent=1, ensure_ascii=False) + "\n",
                       encoding="utf-8", newline="\n")
        tables += len(frames)
        shapes = [frame.shape for frame in frames]
        print(f"  {out.name}: {len(frames)} tables {shapes}")
    print(f"tables: {tables}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
