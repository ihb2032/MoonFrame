# Excel workbooks

The workbooks MoonFrame's Excel reader is checked against, each written by
[openpyxl](https://openpyxl.readthedocs.io/) — a writer other than the
workbook library MoonFrame's own entries ride — with values fixed in
[`make_fixtures.py`](make_fixtures.py), which also states what each
fixture is for. `libreoffice_formulas.xlsx` is then re-saved by
LibreOffice, a third writer: openpyxl writes a formula with no cached
value, and LibreOffice computes them.

To regenerate them:

```sh
uv run --with openpyxl python make_fixtures.py
```

LibreOffice is optional; without `soffice` on the `PATH` the formula
workbook keeps the file openpyxl wrote, and `libreoffice_formulas.xlsx`
stays as it is. `io/excel_test.mbt` names the samples a test reads, and
states what each must read as.
