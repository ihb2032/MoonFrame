"""Make the workbooks MoonFrame's Excel entry is checked against.

The `.xlsx` ones are written by openpyxl, a writer other than the library
MoonFrame's own entries ride, and the one that carries what openpyxl cannot
spell — a formula's cached value — is then re-saved by LibreOffice, a
third. The same table then rides the other two layouts the entry opens:
an OpenDocument spreadsheet written by odfpy and an Excel 97–2003 workbook
written by xlwt. The values are fixed here, and the tests state what each
must read as.

    uv run --with openpyxl --with odfpy --with xlwt python make_fixtures.py

LibreOffice is optional: without `soffice` on the PATH the formula
workbook keeps the file openpyxl wrote, whose formulas have no cached
value.
"""

import datetime
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import openpyxl
from openpyxl.styles.cell_style import StyleArray
from openpyxl.workbook.properties import CalcProperties

HERE = Path(__file__).resolve().parent

# The table the OpenDocument and the Excel 97–2003 fixtures carry: a text,
# a number, a boolean, a day, an instant and a time of day, a missing value
# in each of the first four, under a header row. The second sheet holds a
# header and one row.
TABLE = [
    ["name", "count", "ratio", "ok", "day", "at", "time"],
    [
        "alpha",
        42,
        1.5,
        True,
        datetime.date(2024, 1, 2),
        datetime.datetime(2024, 3, 4, 5, 6, 7),
        datetime.time(12, 30),
    ],
    ["北京", None, -0.25, False, None, None, None],
    ["gamma", 7, 3.0, None, None, None, None],
]
SECOND = [["only", "value"], [5, None]]


def builtin(cell, num_fmt_id):
    """Give a cell a builtin number format by its id, which the
    number-format text a cell carries cannot name."""
    cell.number_format = "#,##0"
    style = StyleArray(cell._style)
    style.numFmtId = num_fmt_id
    cell._style = style


def types():
    """Every cell shape a frame column reads, with nulls among them, and
    two more sheets to choose from."""
    book = openpyxl.Workbook()
    sheet = book.active
    sheet.title = "Data"
    sheet.append(["name", "count", "ratio", "ok", "day", "at", "time", "err", "spare"])
    sheet.append([
        "alpha", 42, 1.5, True,
        datetime.date(2024, 1, 2),
        datetime.datetime(2024, 3, 4, 5, 6, 7),
        datetime.time(12, 30),
        None, None,
    ])
    sheet.append(["北京", None, -0.25, False, None, None, None, "=1/0", None])
    sheet.append(["gamma", 7, 3.0, None, None, None, None, 9, None])
    second = book.create_sheet("Second")
    second["A1"] = "only"
    book.save(HERE / "openpyxl_types.xlsx")


def dates_1904():
    """The same days and instants in the 1904 date system."""
    book = openpyxl.Workbook()
    book.epoch = openpyxl.utils.datetime.CALENDAR_MAC_1904
    sheet = book.active
    sheet.title = "Data"
    sheet.append(["day", "at"])
    sheet.append([
        datetime.date(2024, 1, 2),
        datetime.datetime(2024, 3, 4, 5, 6, 7),
    ])
    sheet.append([
        datetime.date(1904, 1, 1),
        datetime.datetime(1904, 1, 1, 0, 0, 0),
    ])
    book.save(HERE / "openpyxl_1904.xlsx")


def formats():
    """A number under each kind of format: the dates, the times, the
    elapsed, and the ones that only look like them."""
    book = openpyxl.Workbook()
    sheet = book.active
    sheet.title = "Formats"
    sheet.append([
        "cjk", "quoted", "meridian", "elapsed", "accounting", "scientific",
        "day", "time", "instant", "percent", "unit", "builtin_day",
    ])
    sheet.append([None] * 12)
    # A custom date in a Chinese workbook's spelling: the month outside
    # the quotes and the rest inside them.
    sheet["A2"] = 45476.5
    sheet["A2"].number_format = 'yyyy"年"m"月"d"日"'
    # A quoted word with the date letters in it, around a plain number.
    sheet["B2"] = 45476.5
    sheet["B2"].number_format = '"day "0" m"'
    # A time with its meridian: the meridian's M is no month.
    sheet["C2"] = 45476.5
    sheet["C2"].number_format = "h:mm AM/PM"
    # An elapsed time in brackets: a day and a quarter is thirty hours.
    sheet["D2"] = 1.25
    sheet["D2"].number_format = "[h]:mm:ss"
    # A locale's builtin 27: an accounting format in one workbook and a
    # date in another's, so a plain number.
    sheet["E2"] = 1234.5
    builtin(sheet["E2"], 27)
    # A scientific format: its E is no date letter.
    sheet["F2"] = 1234.5
    sheet["F2"].number_format = "0.00E+00"
    # openpyxl's own formats for the three calendar values.
    sheet["G2"] = datetime.date(2024, 1, 2)
    sheet["H2"] = datetime.time(12, 34, 56)
    sheet["I2"] = datetime.datetime(2024, 3, 4, 5, 6, 7)
    sheet["J2"] = 0.5
    sheet["J2"].number_format = "0.0%"
    sheet["K2"] = 7
    sheet["K2"].number_format = '0.0" m"'
    # The builtin short date, by its id.
    sheet["L2"] = 45476
    builtin(sheet["L2"], 14)

    # One column with a date-formatted number and a plain one.
    mixed = book.create_sheet("Mixed")
    mixed["A1"] = "v"
    mixed["A2"] = 45476
    mixed["A2"].number_format = "yyyy-mm-dd"
    mixed["A3"] = 45476

    # A sheet that starts away from A1, with a merged cell.
    offset = book.create_sheet("Offset")
    offset["B2"] = "b"
    offset["C2"] = "c"
    offset["D2"] = "d"
    offset["B3"] = 1
    offset["C3"] = "merged"
    offset["D3"] = "hidden"
    offset.merge_cells("C3:D3")

    # Two header cells of one name.
    names = book.create_sheet("Names")
    names.append(["dup", "dup"])
    names.append([1, 2])
    book.save(HERE / "openpyxl_formats.xlsx")


def formulas():
    """Formulas, which openpyxl writes with no cached value: LibreOffice
    computes them and stores the values."""
    book = openpyxl.Workbook()
    sheet = book.active
    sheet.title = "Calc"
    sheet["A1"] = 10
    sheet["A2"] = 20
    sheet["A3"] = "=A1+A2"
    sheet["A4"] = '=A1&" units"'
    sheet["A5"] = "=1/0"
    sheet["A6"] = "=A1+A2"
    sheet["B1"] = datetime.date(2024, 1, 2)
    sheet["B2"] = True
    book.calculation = CalcProperties(fullCalcOnLoad=True)
    source = HERE / "openpyxl_formulas.xlsx"
    book.save(source)
    soffice = shutil.which("soffice")
    if soffice is None:
        return
    out = HERE / "_libreoffice"
    out.mkdir(exist_ok=True)
    subprocess.run(
        [soffice, "--headless", "--convert-to", "xlsx", "--outdir", str(out), str(source)],
        check=True,
        capture_output=True,
    )
    (out / "openpyxl_formulas.xlsx").replace(HERE / "libreoffice_formulas.xlsx")
    out.rmdir()


def macro():
    """The types workbook as a macro-enabled workbook, `.xlsm`: the same
    package with its workbook part declared macro-enabled and a
    `vbaProject.bin` part beside it, which is all that separates the two
    as far as the cells go. openpyxl saves one only by keeping the VBA
    project of a template, so the package is rewritten here instead; the
    project part holds opaque bytes no reader of cells opens."""
    source = HERE / "openpyxl_types.xlsx"
    target = HERE / "openpyxl_macro.xlsm"
    sheet_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
    macro_type = "application/vnd.ms-excel.sheet.macroEnabled.main+xml"
    with zipfile.ZipFile(source) as book, zipfile.ZipFile(
        target, "w", zipfile.ZIP_DEFLATED
    ) as out:
        for info in book.infolist():
            data = book.read(info.filename)
            if info.filename == "[Content_Types].xml":
                text = data.decode("utf-8")
                assert text.count(sheet_type) == 1, text
                text = text.replace(sheet_type, macro_type)
                text = text.replace(
                    "<Default",
                    '<Default Extension="bin" '
                    'ContentType="application/vnd.ms-office.vbaProject"/><Default',
                    1,
                )
                data = text.encode("utf-8")
            elif info.filename == "xl/_rels/workbook.xml.rels":
                text = data.decode("utf-8")
                assert text.count("</Relationships>") == 1, text
                text = text.replace(
                    "</Relationships>",
                    '<Relationship Id="rIdVba" '
                    'Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" '
                    'Target="vbaProject.bin"/></Relationships>',
                )
                data = text.encode("utf-8")
            out.writestr(info, data)
        out.writestr(
            "xl/vbaProject.bin",
            b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 504,
        )


def ods():
    """The table as an OpenDocument spreadsheet, written by odfpy — the
    library the reader its cells are compared against rides. A cell's type
    is the file's own: a boolean, a day, an instant and a time of day are
    typed as themselves, where the other two layouts store a number and
    let its format say what it is."""
    from odf.opendocument import OpenDocumentSpreadsheet
    from odf.table import Table, TableCell, TableRow
    from odf.text import P

    def cell(value):
        if value is None:
            return TableCell()
        if isinstance(value, bool):
            out = TableCell(
                valuetype="boolean", booleanvalue="true" if value else "false"
            )
            out.addElement(P(text="TRUE" if value else "FALSE"))
        elif isinstance(value, (int, float)):
            out = TableCell(valuetype="float", value=str(float(value)))
            out.addElement(P(text=str(value)))
        elif isinstance(value, (datetime.datetime, datetime.date)):
            out = TableCell(valuetype="date", datevalue=value.isoformat())
            out.addElement(P(text=value.isoformat()))
        elif isinstance(value, datetime.time):
            out = TableCell(
                valuetype="time",
                timevalue="PT%02dH%02dM%02dS"
                % (value.hour, value.minute, value.second),
            )
            out.addElement(P(text=value.isoformat()))
        else:
            out = TableCell(valuetype="string")
            out.addElement(P(text=value))
        return out

    book = OpenDocumentSpreadsheet()
    for name, rows in (("Data", TABLE), ("Second", SECOND), ("Third", [])):
        sheet = Table(name=name)
        for row in rows:
            line = TableRow()
            for value in row:
                line.addElement(cell(value))
            sheet.addElement(line)
        book.spreadsheet.addElement(sheet)
    book.save(str(HERE / "odfpy_types.ods"))


def xls():
    """The table as an Excel 97–2003 workbook, written by xlwt — the writer
    the reader its cells are compared against rides. A day, an instant and
    a time of day are numbers under a date format, as the format spells
    them; a boolean is a boolean record. It is written twice, counting days
    from 1900 and from 1904."""
    import xlwt

    day = xlwt.easyxf(num_format_str="YYYY-MM-DD")
    at = xlwt.easyxf(num_format_str="YYYY-MM-DD HH:MM:SS")
    time = xlwt.easyxf(num_format_str="HH:MM:SS")
    for name, from_1904 in (
        ("xlwt_types.xls", False),
        ("xlwt_types_1904.xls", True),
    ):
        book = xlwt.Workbook()
        book.set_dates_1904(from_1904)
        # a time alone is the fraction of a day, on the day the system
        # counts from
        first_day = (
            datetime.datetime(1904, 1, 1) if from_1904 else datetime.datetime(1899, 12, 31)
        )
        for sheet_name, rows in (
            ("Data", TABLE),
            ("Second", SECOND),
            ("Third", []),
        ):
            sheet = book.add_sheet(sheet_name)
            for r, row in enumerate(rows):
                for c, value in enumerate(row):
                    if value is None:
                        continue
                    if isinstance(value, datetime.datetime):
                        sheet.write(r, c, value, at)
                    elif isinstance(value, datetime.date):
                        sheet.write(
                            r, c, datetime.datetime(value.year, value.month, value.day), day
                        )
                    elif isinstance(value, datetime.time):
                        sheet.write(
                            r,
                            c,
                            first_day.replace(hour=value.hour, minute=value.minute),
                            time,
                        )
                    else:
                        sheet.write(r, c, value)
        book.save(str(HERE / name))


def xls_cells():
    """What only an Excel 97–2003 sheet spells, written by xlwt: an error
    cell, which holds no value; and a number under a built-in format,
    which the writer maps to the format's id when it is given the format's
    own spelling."""
    import xlwt

    book = xlwt.Workbook()
    errors = book.add_sheet("Errors")
    for c, name in enumerate(["n", "err", "text"]):
        errors.write(0, c, name)
    errors.write(1, 0, 1)
    errors.row(1).set_cell_error(1, "#DIV/0!")
    errors.write(1, 2, "a")
    errors.write(2, 0, 2)
    errors.row(2).set_cell_error(1, 0x2A)  # #N/A, by its code
    errors.write(3, 0, 3)
    errors.write(3, 1, "kept")
    errors.write(3, 2, "c")
    builtin = book.add_sheet("Builtin")
    for c, name in enumerate(["day", "time", "num"]):
        builtin.write(0, c, name)
    builtin.write(
        1, 0, datetime.datetime(2024, 1, 2), xlwt.easyxf(num_format_str="M/D/YY")
    )
    builtin.write(
        1,
        1,
        datetime.datetime(1899, 12, 31, 12, 30),
        xlwt.easyxf(num_format_str="h:mm"),
    )
    builtin.write(1, 2, 3.0, xlwt.easyxf(num_format_str="0.00"))
    book.save(str(HERE / "xlwt_cells.xls"))


def odt():
    """An OpenDocument text document: the package of a spreadsheet with
    another document in it, for the entry to leave to the workbook
    library's refusal."""
    from odf.opendocument import OpenDocumentText
    from odf.text import P

    book = OpenDocumentText()
    book.text.addElement(P(text="A text document, not a spreadsheet."))
    book.save(str(HERE / "odfpy_text.odt"))


def main():
    types()
    dates_1904()
    formats()
    formulas()
    macro()
    ods()
    xls()
    xls_cells()
    odt()
    print("openpyxl", openpyxl.__version__)


if __name__ == "__main__":
    sys.exit(main())
