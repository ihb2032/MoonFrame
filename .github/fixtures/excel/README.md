# Spreadsheets

The workbooks MoonFrame's Excel entry is checked against, with values
fixed in [`make_fixtures.py`](make_fixtures.py), which also states what
each fixture is for.

The `.xlsx` workbooks are each written by
[openpyxl](https://openpyxl.readthedocs.io/) — a writer other than the
workbook library MoonFrame's own entries ride — and
`libreoffice_formulas.xlsx` is then re-saved by LibreOffice, a third
writer: openpyxl writes a formula with no cached value, and LibreOffice
computes them. `openpyxl_macro.xlsm` is the types workbook repackaged as
a macro-enabled workbook: its workbook part declared so and a
`vbaProject.bin` part beside it, which is all that separates the two as
far as the cells go.

The other two layouts the entry opens carry the same table, written by
the library each is compared against: `odfpy_types.ods` by
[odfpy](https://github.com/tdf/odfpy) and `xlwt_types.xls` by
[xlwt](https://github.com/python-excel/xlwt), which count days from 1900,
as `xlwt_types_1904.xls` does from 1904; each holds a second sheet of a
header and one row, and a third with no value at all. An OpenDocument cell
carries its own type there — a boolean, a day, an instant and a time of
day are typed as themselves — where the two Excel layouts store a number
under a date format. `xlwt_cells.xls` holds what only an Excel 97–2003
sheet spells: an error cell, and a number under a built-in format.
`odfpy_text.odt` is an OpenDocument *text* document: the package of a
spreadsheet with another document in it.

The two codecs have a corpus of their own, under
[`../ods`](../ods/README.md) and [`../xls`](../xls/README.md): what their
cells come to, and the files they refuse.

To regenerate them:

```sh
uv run --with openpyxl --with odfpy --with xlwt python make_fixtures.py
```

LibreOffice is optional; without `soffice` on the PATH the formula
workbook keeps the file openpyxl wrote, and `libreoffice_formulas.xlsx`
stays as it is. `io/excel_test.mbt` and `io/excel_formats_test.mbt` name
the samples a test reads, and state what each must read as.
