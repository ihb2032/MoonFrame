"""Make the Excel workbooks MoonFrame's reader is checked against.

Each is written by openpyxl, a writer other than the library MoonFrame's
own entries ride, and the one that carries what openpyxl cannot spell — a
formula's cached value — is then re-saved by LibreOffice, a third. The
values are fixed here, and the tests state what each must read as.

    uv run --with openpyxl python make_fixtures.py

LibreOffice is optional: without `soffice` on the PATH the formula
workbook keeps the file openpyxl wrote, whose formulas have no cached
value.
"""

import datetime
import shutil
import subprocess
import sys
from pathlib import Path

import openpyxl
from openpyxl.styles.cell_style import StyleArray
from openpyxl.workbook.properties import CalcProperties

HERE = Path(__file__).resolve().parent


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


def main():
    types()
    dates_1904()
    formats()
    formulas()
    print("openpyxl", openpyxl.__version__)


if __name__ == "__main__":
    sys.exit(main())
