"""Generate the reference corpus of OpenDocument spreadsheet packages under
``.github/fixtures/ods/reference`` with a JSON sidecar beside each, then verify both.

``make`` writes the corpus. Most files are written by the two writers —
odfpy's own elements (and the spreadsheet writer that rides it), and
ezodf — some are packages whose content.xml this script spells by hand for
a shape no writer spells (other namespace prefixes, UTF-16, a nested
table), and the ``broken_`` files are each a written package patched in
one place. Writers' entry stamps are replaced by a fixed one, so a package
written twice is the same bytes.

A sidecar holds, for every sheet, the cells the reference reader itself
got from the file; where the reference reader cannot open the file, or
raises on a sheet, the cells are this script's own reading of the
content.xml it wrote, and the sidecar says so. A file the codec refuses
carries the refusal's variant and exact text. Every cell is spelled as
``odsbuild.py``, beside it, spells it.

``verify`` re-reads every file with the reference reader and compares what
it answers with the sidecar's record of it; it exits non-zero on a
mismatch, on a file the index does not list, or on a refusal text that does
not start with ``ods: ``.

    uv run --no-project --with pandas --with odfpy --with ezodf --with lxml --with openpyxl python -I -X utf8 .github/fixtures/ods/gen_fixtures.py make
    uv run --no-project --with pandas --with odfpy --with ezodf --with lxml --with openpyxl python -I -X utf8 .github/fixtures/ods/gen_fixtures.py verify
"""
import datetime
import io
import json
import os
import re
import struct
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rawods as R  # noqa: E402
import odsbuild as B  # noqa: E402

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
FIX = os.path.join(HERE, "reference")
LOG = os.path.join(ROOT, "_build", "ods_fixture_logs")

TOP = sys.float_info.max


# ── packages written by the writers, with a fixed entry stamp ─────────

def restable(data):
    """The same package with every entry's stamp replaced by the fixed one."""
    source = zipfile.ZipFile(io.BytesIO(data))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as out:
        for info in source.infolist():
            fixed = zipfile.ZipInfo(info.filename, R.STAMP)
            fixed.compress_type = info.compress_type
            fixed.external_attr = info.external_attr
            out.writestr(fixed, source.read(info.filename))
    return buffer.getvalue()


def content_of(data):
    return zipfile.ZipFile(io.BytesIO(data)).read("content.xml")


# ── odfpy's own elements ──────────────────────────────────────────────

def odfpy_table(name):
    from odf.table import Table
    return Table(name=name)


def odfpy_row(table, *cells, repeat=None):
    from odf.table import TableRow
    row = TableRow() if repeat is None else TableRow(numberrowsrepeated=repeat)
    for cell in cells:
        row.addElement(cell)
    table.addElement(row)
    return row


def odfpy_empty(repeat=None, covered=False):
    from odf.table import TableCell, CoveredTableCell
    make = CoveredTableCell if covered else TableCell
    return make() if repeat is None else make(numbercolumnsrepeated=repeat)


def spelled_number(value):
    """A whole number below 2^53 as digits, as a spreadsheet writes it;
    every other double by its shortest round-trip spelling."""
    value = float(value)
    if value.is_integer() and abs(value) < 2 ** 53:
        return "%d" % int(value)
    return repr(value)


def odfpy_number(value, kind="float", text=None, repeat=None, currency=None):
    from odf.table import TableCell
    from odf.text import P
    cell = TableCell(valuetype=kind, value=spelled_number(value))
    if currency:
        cell.setAttrNS(B.OFFICE, "currency", currency)
    if text is not None:
        cell.addElement(P(text=text))
    if repeat is not None:
        cell.setAttrNS(B.TABLE, "number-columns-repeated", str(repeat))
    return cell


def odfpy_string(inner="paragraph", text=None, repeat=None):
    """A string cell: one paragraph of `text`, an empty one without it, or
    whatever the function `inner` puts into the cell."""
    from odf.table import TableCell
    from odf.text import P
    cell = TableCell(valuetype="string")
    if inner == "paragraph":
        cell.addElement(P() if text is None else P(text=text))
    elif inner is not None:
        inner(cell)
    if repeat is not None:
        cell.setAttrNS(B.TABLE, "number-columns-repeated", str(repeat))
    return cell


def odfpy_boolean(value, text="TRUE"):
    from odf.table import TableCell
    from odf.text import P
    cell = TableCell(valuetype="boolean", booleanvalue="true" if value else "false")
    if text is not None:
        cell.addElement(P(text=text))
    return cell


def odfpy_date(value):
    from odf.table import TableCell
    return TableCell(valuetype="date", datevalue=value)


def odfpy_time(value, text):
    from odf.table import TableCell
    from odf.text import P
    cell = TableCell(valuetype="time", timevalue=value)
    cell.addElement(P(text=text))
    return cell


def odfpy_doc(tables):
    from odf.opendocument import OpenDocumentSpreadsheet
    doc = OpenDocumentSpreadsheet()
    for table in tables:
        doc.spreadsheet.addElement(table)
    scratch = os.path.join(LOG, "_scratch.ods")
    doc.save(scratch)
    with open(scratch, "rb") as f:
        data = restable(f.read())
    os.remove(scratch)
    return data


def t_values():
    t = odfpy_table("Values")
    numbers = [1, 1.5, -2.5, 0, 1e22, 0.1, 1 / 3, 1e-5, 1e300, -1e-300, 123456789012345678,
               9007199254740993, TOP, -TOP, 5e-324, 2.2250738585072014e-308,
               2.225073858507201e-308, 4.9406564584124654e-324, 0.30000000000000004]
    odfpy_row(t, *[odfpy_number(v, text=str(float(v))) for v in numbers])
    odfpy_row(t, *[odfpy_number(v, "percentage", "15%") for v in [0.15, 1.0, -0.5, 0.0]],
              *[odfpy_number(v, "currency", "12.50", currency="USD") for v in [12.5, -3.0, 0.0]])
    odfpy_row(t, *[odfpy_string(text=s) for s in ["plain", "é", "日本語", "emoji 🎉", "<>&\"'",
                                                     "with  inner  spaces", "NA", "null"]])
    odfpy_row(t, *[odfpy_date(d) for d in ["2020-01-02", "1970-01-01", "1969-12-31", "1900-02-28",
                                           "2000-02-29", "0001-01-01", "9999-12-31", "1600-03-01"]])
    odfpy_row(t, *[odfpy_date(d) for d in ["2020-01-02T12:34:56", "2020-01-02T12:34:56.789",
                                           "2020-01-02T00:00:00", "1969-12-31T23:59:59.123456",
                                           "2020-01-02 12:00:00", "2020-01-02T12:34"]])
    odfpy_row(t, *[odfpy_time(v, text) for v, text in
                   [("PT12H34M56S", "12:34:56"), ("PT00H30M00S", "00:30:00"),
                    ("PT23H59M59S", "23:59:59"), ("PT12H34M56.789S", "12:34:56.789"),
                    ("PT00H00M00S", "00:00:00")]])
    odfpy_row(t, odfpy_boolean(True), odfpy_boolean(False, "FALSE"))
    return odfpy_doc([t, odfpy_table("Empty")])


def t_bool_spelled():
    from odf.text import P
    t = odfpy_table("Booleans")
    cells = [odfpy_boolean(True, text)
             for text in ["TRUE", "true", "True", "FALSE", "0", "1", None, " TRUE", "TRUE ", "yes"]]
    cells.append(odfpy_boolean(True, "FALSE"))
    both = odfpy_boolean(True, "TRUE")
    both.addElement(P(text="FALSE"))
    cells.append(both)
    odfpy_row(t, *cells)
    return odfpy_doc([t])


def t_strings():
    from odf.text import P, S, LineBreak, Span, List, ListItem
    from odf.office import Annotation

    t = odfpy_table("Strings")

    def ends(cell):
        p = P()
        p.addText(" ")
        p.addElement(S())
        p.addText("leading and trailing")
        p.addText(" ")
        p.addElement(S())
        cell.addElement(p)

    def run(cell):
        p = P(text="a")
        p.addElement(S(c=5))
        p.addText("b")
        cell.addElement(p)

    def broken(cell):
        p = P(text="line one")
        p.addElement(LineBreak())
        p.addText("line two")
        cell.addElement(p)

    def paragraphs(cell):
        for text in ["first", "second", "third"]:
            cell.addElement(P(text=text))

    def noted(cell):
        cell.addElement(P(text="visible"))
        note = Annotation()
        note.addElement(P(text="a note"))
        cell.addElement(note)

    def styled(cell):
        p = P(text="plain ")
        p.addElement(Span(stylename="T1", text="styled"))
        p.addText(" plain again")
        cell.addElement(p)

    def nested(cell):
        p = P(text="x")
        outer = Span(stylename="T1", text="a")
        inner = Span(stylename="T2", text="b")
        inner.addElement(S(c=2))
        inner.addText("c")
        outer.addElement(inner)
        outer.addText("d")
        p.addElement(outer)
        p.addText("y")
        cell.addElement(p)

    def listed(cell):
        items = List()
        for text in ["one", "two"]:
            item = ListItem()
            item.addElement(P(text=text))
            items.addElement(item)
        cell.addElement(items)

    def spaces_only(cell):
        # The schema puts text:s under a paragraph; a cell is taken too.
        cell.addElement(S(c=3), check_grammar=False)

    def break_only(cell):
        cell.addElement(LineBreak(), check_grammar=False)

    cells = [odfpy_string(inner) for inner in
             [ends, run, broken, paragraphs, noted, styled, nested, listed, spaces_only, break_only]]
    cells += [odfpy_string(text=s) for s in ["日本語のテキスト", "emoji 🎉🚀 done", "a\tb", "a & b < c",
                                             " x ", "  ", "\n", "alpha\nbeta"]]
    bare = odfpy_string(None)
    bare.addText("bare text, no paragraph", check_grammar=False)
    cells.append(bare)
    cdata = odfpy_string(None)
    cdata.addCDATA("<raw & cdata>", check_grammar=False)
    cells.append(cdata)
    odfpy_row(t, *cells)
    return odfpy_doc([t])


def t_sheets():
    first = odfpy_table("First")
    odfpy_row(first, odfpy_number(1), odfpy_string(text="one"))
    third = odfpy_table("É 日本 & <x>")
    odfpy_row(third, odfpy_number(3))
    odfpy_row(third, odfpy_number(4))
    return odfpy_doc([first, odfpy_table("An empty one"), third])


def t_structure():
    from odf.table import TableColumn, TableHeaderRows, TableRowGroup, TableRows
    t = odfpy_table("Layout")
    for _ in range(3):
        t.addElement(TableColumn())
    headers = TableHeaderRows()
    odfpy_row(headers, odfpy_string(text="name"), odfpy_string(text="amount"), odfpy_string(text="day"))
    t.addElement(headers)
    group = TableRowGroup()
    odfpy_row(group, odfpy_string(text="a"), odfpy_number(1.5), odfpy_date("2020-01-02"))
    inner = TableRowGroup()
    odfpy_row(inner, odfpy_string(text="b"), odfpy_number(-2), odfpy_date("2020-01-03"))
    group.addElement(inner)
    t.addElement(group)
    plain = TableRows()
    odfpy_row(plain, odfpy_empty(), odfpy_empty(), odfpy_number(9))
    t.addElement(plain)
    odfpy_row(t)
    odfpy_row(t)
    odfpy_row(t, odfpy_empty(repeat=2), odfpy_string(text="far right"))
    return odfpy_doc([t])


def t_repeats():
    t = odfpy_table("Repeats")
    odfpy_row(t, odfpy_empty(), repeat=3)
    odfpy_row(t, odfpy_empty(repeat=2), odfpy_string(text="after gaps"), odfpy_empty(), odfpy_number(7))
    odfpy_row(t, odfpy_number(5, text="5", repeat=3))
    odfpy_row(t, odfpy_string(text="twice"), odfpy_number(2), repeat=2)
    odfpy_row(t, odfpy_number(1), odfpy_empty(repeat=1023))
    odfpy_row(t, odfpy_empty(repeat=1024), repeat=1048560)
    return odfpy_doc([t])


def t_merged():
    from odf.table import TableCell
    from odf.text import P
    t = odfpy_table("Merged")
    corner = TableCell(valuetype="string", numbercolumnsspanned=2, numberrowsspanned=2)
    corner.addElement(P(text="M"))
    odfpy_row(t, corner, odfpy_empty(covered=True), odfpy_number(3))
    odfpy_row(t, odfpy_empty(covered=True), odfpy_empty(covered=True), odfpy_number(4))
    odfpy_row(t, odfpy_empty(covered=True, repeat=2), odfpy_number(5))
    with_value = odfpy_empty(covered=True)
    with_value.setAttrNS(B.OFFICE, "value-type", "float")
    with_value.setAttrNS(B.OFFICE, "value", "6")
    dated = odfpy_empty(covered=True)
    dated.setAttrNS(B.OFFICE, "value-type", "date")
    dated.setAttrNS(B.OFFICE, "date-value", "2020-01-02")
    odfpy_row(t, with_value, dated, odfpy_number(8))
    return odfpy_doc([t])


def t_formula():
    from odf.table import TableCell
    from odf.text import P
    t = odfpy_table("Formulas")
    summed = TableCell(formula="of:=1+2", valuetype="float", value="3")
    summed.addElement(P(text="3"))
    joined = TableCell(formula='of:=CONCATENATE("a";"b")', valuetype="string")
    joined.setAttrNS(B.OFFICE, "string-value", "ab")
    joined.addElement(P(text="ab"))
    uncached = TableCell(formula="of:=1/0")
    odfpy_row(t, summed, joined, uncached, odfpy_number(1))
    return odfpy_doc([t])


def t_empty_cells():
    from odf.text import P, S
    t = odfpy_table("Kinds of empty")
    void = odfpy_empty()
    void.setAttrNS(B.OFFICE, "value-type", "void")
    untyped = odfpy_empty()
    untyped.addElement(P(text="just text"))
    only_spaces = odfpy_string(None)
    p = P()
    p.addElement(S(c=0))
    only_spaces.addElement(p)
    attributed = odfpy_empty()
    attributed.setAttrNS(B.OFFICE, "value-type", "string")
    attributed.setAttrNS(B.OFFICE, "string-value", "only an attribute")
    undated = odfpy_empty()
    undated.setAttrNS(B.OFFICE, "value-type", "date")
    odfpy_row(t, odfpy_string(text="#N/A"), void, untyped, odfpy_string(), only_spaces,
              odfpy_string(text="kept"), attributed, undated)
    return odfpy_doc([t])


def t_pandas():
    frame = pd.DataFrame({
        "n": [1, 2.5, None, -7],
        "s": ["x", "y\nz", "w", ""],
        "b": [True, False, True, False],
        "stamp": [datetime.datetime(2020, 1, 2, 12, 34, 56), datetime.datetime(2020, 1, 3),
                  pd.NaT, datetime.datetime(1969, 12, 31, 23, 59, 59, 500000)],
        "day": [datetime.date(2020, 1, 4), datetime.date(1999, 12, 31), None,
                datetime.date(2000, 2, 29)],
        "f": [0.15, -1e300, 5e-324, TOP],
    })
    scratch = os.path.join(LOG, "_scratch.ods")
    frame.to_excel(scratch, engine="odf", index=False, header=False)
    with open(scratch, "rb") as f:
        data = restable(f.read())
    os.remove(scratch)
    return data


def t_offsets():
    t = odfpy_table("Offsets and fractions")
    odfpy_row(t, *[odfpy_date(d) for d in [
        "2020-01-02T12:34:56Z", "2020-01-02T12:34:56+02:00", "2020-01-02T12:34:56-05:30",
        "2020-01-02t12:34:56z", "2020-01-02T00:00:00+02:00", "2020-01-02T00:00:00.5+02:00"]])
    odfpy_row(t, *[odfpy_date(d) for d in [
        "2020-01-02T12:34:56.123", "2020-01-02T12:34:56.123456", "2020-01-02T12:34:56.123456789",
        "2020-01-02T12:34:56.0000005", "2020-01-02T12:34:56.9999995", "2020-01-02T00:00:00.0000004",
        "1969-12-31T23:59:59.123456789", "1969-12-31T23:59:59.9999995", "1970-01-01T00:00:00.000001"]])
    return odfpy_doc([t])


def t_small():
    t = odfpy_table("Small")
    odfpy_row(t, odfpy_number(1), odfpy_string(text="one"), odfpy_date("2020-01-02"))
    odfpy_row(t, odfpy_number(2.5), odfpy_string(text="two"), odfpy_boolean(False, "FALSE"))
    odfpy_row(t, odfpy_number(-3), odfpy_string(text="three"), odfpy_time("PT01H02M03S", "01:02:03"))
    odfpy_row(t, odfpy_number(1e22), odfpy_empty(), odfpy_date("1969-12-31T23:59:59"))
    return odfpy_doc([t, odfpy_table("Nothing here")])


# ── ezodf ─────────────────────────────────────────────────────────────

def ezodf_doc(sheets):
    """`sheets`: (name, size or None for the writer's default, a function
    filling the sheet or None)."""
    import ezodf
    scratch = os.path.join(LOG, "_scratch.ods")
    doc = ezodf.newdoc("ods", scratch)
    for name, size, fill in sheets:
        sheet = ezodf.Sheet(name) if size is None else ezodf.Sheet(name, size=size)
        doc.sheets += sheet
        if fill:
            fill(sheet)
    doc.save()
    with open(scratch, "rb") as f:
        data = restable(f.read())
    os.remove(scratch)
    return pinned(data, "meta.xml")


def t_ezodf_values():
    import ezodf

    def fill(sheet):
        sheet[0, 0].set_value(1.5)
        sheet[0, 1].set_value(True)
        sheet[0, 2].set_value("hello")
        sheet[0, 3].set_value(datetime.date(2020, 1, 2), "date")
        sheet[0, 4].set_value(datetime.datetime(2020, 1, 2, 12, 34, 56), "date")
        sheet[0, 5].set_value(3, "percentage")
        sheet[1, 0].set_value(4, "currency", currency="USD")
        sheet[1, 1].set_value(-2.25)
        sheet[1, 2].set_value("PT12H34M56S", "time")
        sheet[1, 2].display_form = "12:34:56"
        sheet[1, 3].set_value(False)
        sheet[1, 4].set_value("日本 🎉")
        sheet[1, 5].append(ezodf.Paragraph("untyped text"))

    def silent(sheet):
        sheet[0, 0].set_value("PT00H30M00S", "time")

    return ezodf_doc([("S", (2, 6), fill), ("Silent time", (1, 1), silent)])


def t_ezodf_grid():
    import ezodf

    def fill(sheet):
        for col, value in enumerate([1, "two", 3.5, True]):
            sheet[0, col].set_value(value)
        sheet[1, 1].set_value("x")
        sheet[1, 3].set_value(False)
        sheet[1, 0].set_value("with spaces")
        sheet[1, 0].append(ezodf.Spaces(5))
        sheet[1, 0].append(ezodf.Paragraph("second line"))

    return ezodf_doc([("A", (2, 4), fill), ("Default", None, None)])


# ── content.xml spelled by hand ───────────────────────────────────────

MANIFEST = ("META-INF/manifest.xml", R.MANIFEST.encode("utf-8"))


def prefixed(body):
    text = R.content(body).decode("utf-8")
    text = text.replace(' xmlns:office="', ' xmlns:off="').replace(' xmlns:table="', ' xmlns:tbl="') \
        .replace(' xmlns:text="', ' xmlns:txt="')
    for was, now in (("office", "off"), ("table", "tbl"), ("text", "txt")):
        text = text.replace("<%s:" % was, "<%s:" % now).replace("</%s:" % was, "</%s:" % now) \
            .replace(" %s:" % was, " %s:" % now)
    return R.pack([("content.xml", text.encode("utf-8")), MANIFEST])


def utf16(body, big):
    text = R.content(body).decode("utf-8").replace(
        '<?xml version="1.0" encoding="UTF-8"?>\n', '<?xml version="1.0" encoding="UTF-16"?>\n')
    raw = text.encode("utf-16-be" if big else "utf-16-le")
    return R.pack([("content.xml", (b"\xfe\xff" if big else b"\xff\xfe") + raw), MANIFEST])


def no_mimetype(body, root="document-content", mimetype=None):
    text = R.content(body).decode("utf-8")
    if root != "document-content":
        text = text.replace("office:document-content", "office:" + root)
    if mimetype:
        text = text.replace(' office:version="1.2">',
                            ' office:version="1.2" office:mimetype="%s">' % mimetype)
    return R.pack([MANIFEST, ("content.xml", text.encode("utf-8"))], mimetype=False)


# ── patches on written packages ───────────────────────────────────────

def payload_offset(data, name):
    archive = zipfile.ZipFile(io.BytesIO(data))
    info = archive.getinfo(name)
    extra = struct.unpack_from("<H", data, info.header_offset + 28)[0]
    return info.header_offset + 30 + len(info.filename.encode("utf-8")) + extra


def with_content(data, content, name="content.xml", store=True):
    """The package with one entry's bytes replaced — stored when `store`
    is true, as the content.xml of a broken package is, deflated as it
    was otherwise."""
    archive = zipfile.ZipFile(io.BytesIO(data))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as out:
        for info in archive.infolist():
            fixed = zipfile.ZipInfo(info.filename, R.STAMP)
            fixed.compress_type = zipfile.ZIP_STORED if (info.filename == name and store) \
                else info.compress_type
            out.writestr(fixed, content if info.filename == name else archive.read(info.filename))
    return buffer.getvalue()


STAMPED = re.compile(rb"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?")


def pinned(data, name):
    """The package with the timestamps one of its entries carries — the
    moment of writing — replaced by a fixed one."""
    content = zipfile.ZipFile(io.BytesIO(data)).read(name)
    return with_content(data, STAMPED.sub(b"2020-01-01T00:00:00", content), name, store=False)


def without_entry(data, name):
    archive = zipfile.ZipFile(io.BytesIO(data))
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as out:
        for info in archive.infolist():
            if info.filename == name:
                continue
            fixed = zipfile.ZipInfo(info.filename, R.STAMP)
            fixed.compress_type = info.compress_type
            out.writestr(fixed, archive.read(info.filename))
    return buffer.getvalue()


def encrypted(data, name):
    """The package with one entry's general-purpose flag — bit 0, in its
    local header and in its directory record — declaring it encrypted."""
    archive = zipfile.ZipFile(io.BytesIO(data))
    out = bytearray(data)
    out[archive.getinfo(name).header_offset + 6] |= 0x01
    central = data.find(b"PK\x01\x02")
    while central >= 0:
        if data[central + 46:central + 46 + len(name)] == name.encode("utf-8"):
            out[central + 8] |= 0x01
        central = data.find(b"PK\x01\x02", central + 4)
    return bytes(out)


def xlsx_package():
    scratch = os.path.join(LOG, "_scratch.xlsx")
    pd.DataFrame({"a": [1, 2], "b": ["x", "y"]}).to_excel(scratch, index=False, header=False)
    with open(scratch, "rb") as f:
        data = restable(f.read())
    os.remove(scratch)
    return pinned(data, "docProps/core.xml")


def at_of(data, attribute):
    """The byte an attribute starts at in the package's content.xml."""
    return content_of(data).index(attribute.encode("utf-8"))


# ── the sidecar ───────────────────────────────────────────────────────

def dumps(entry):
    """A sidecar as JSON, a sheet's cells to a line, so a person can scan it."""
    lines = ["{"]
    items = list(entry.items())
    for k, (key, value) in enumerate(items):
        comma = "," if k < len(items) - 1 else ""
        if key != "sheets":
            lines.append(" " + json.dumps(key) + ": " + json.dumps(value, ensure_ascii=False) + comma)
            continue
        lines.append(' "sheets": [')
        for i, sheet in enumerate(value):
            cells = ",".join(json.dumps(c, ensure_ascii=False) for c in sheet["cells"])
            head = {c: v for c, v in sheet.items() if c != "cells"}
            last = i == len(value) - 1
            lines.append("  " + json.dumps(head, ensure_ascii=False)[:-1] + ', "cells": [' + cells + "]}"
                         + ("" if last else ","))
        lines.append(" ]" + comma)
    lines.append("}")
    return "\n".join(lines)


def sidecar(file, origin, note, data, writer, refuse=None, deviating=()):
    """One file's sidecar: what the reference reader answered, what this
    script's own reading says, and which of the two the cells come from."""
    path = os.path.join(FIX, file)
    with open(path, "wb") as f:
        f.write(data)
    view, theirs_by_sheet, names = B.reference_view(path)
    entry = {"file": file, "origin": origin, "note": note, "writer": writer, "bytes": len(data),
             "reference": view}
    compared = 0
    if refuse is not None:
        variant, message = refuse(data)
        if not message.startswith("ods: "):
            raise SystemExit("%s: the refusal does not start with \"ods: \": %s" % (file, message))
        entry["codec"] = "refuses"
        entry["refusal"] = variant
        entry["message"] = message
    else:
        own = B.own_sheets(content_of(data))
        entry["codec"] = "reads"
        sheets = []
        for index, (name, cells) in enumerate(own):
            theirs = theirs_by_sheet.get(index) if view["opens"] else None
            source = "generator"
            if isinstance(theirs, list) and name not in deviating:
                source = "reference"
                if theirs != cells:
                    raise SystemExit(
                        "%s, sheet %r: this script's reading and the reference reader's differ:\n"
                        "  own: %r\n  ref: %r" % (file, name, cells, theirs))
                compared += len(cells)
            sheet = {"name": name, "source": source, "cells": cells}
            if isinstance(theirs, str):
                sheet["reference_error"] = theirs
            sheets.append(sheet)
        if view["opens"] and names != [sheet["name"] for sheet in sheets]:
            raise SystemExit("%s: the reference names the sheets %r, this script %r"
                             % (file, names, [sheet["name"] for sheet in sheets]))
        entry["sheets"] = sheets
    with open(path + ".json", "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(entry) + "\n")
    index = {"file": file, "origin": origin, "codec": entry["codec"]}
    if refuse is not None:
        index["refusal"] = entry["refusal"]
    else:
        index["sheets"] = [sheet["name"] for sheet in entry["sheets"]]
        index["cells"] = sum(len(sheet["cells"]) for sheet in entry["sheets"])
    return index, compared


def refuse_attribute(attribute, name, value, wrong):
    return lambda data: ("ParseError", B.refuse_attribute(at_of(data, attribute), name, value, wrong))


# ── make ──────────────────────────────────────────────────────────────

def main_make():
    os.makedirs(FIX, exist_ok=True)
    os.makedirs(LOG, exist_ok=True)
    for name in os.listdir(FIX):
        os.remove(os.path.join(FIX, name))
    import importlib.metadata as m
    B.log("python %s; pandas %s, numpy %s, odfpy %s, ezodf %s, openpyxl %s" % (
        sys.version.split()[0], pd.__version__, np.__version__, m.version("odfpy"),
        m.version("ezodf"), m.version("openpyxl")))
    index = []
    tally = {"compared": 0}

    def add(file, origin, note, data, writer, refuse=None, deviating=()):
        item, compared = sidecar(file, origin, note, data, writer, refuse, deviating)
        index.append(item)
        tally["compared"] += compared
        if refuse:
            B.log("  %-30s the codec refuses it (%s); the reference reader %s" % (
                file, item["refusal"], "opens it" if item_opens(item) else "cannot open it"))
        else:
            B.log("  %-30s %d sheets, %d cells%s" % (
                file, len(item["sheets"]), item["cells"],
                "" if compared == item["cells"] else
                " (%d of them from this script's own reading)" % (item["cells"] - compared)))

    def item_opens(item):
        with open(os.path.join(FIX, item["file"] + ".json"), encoding="utf-8") as f:
            return json.load(f)["reference"]["opens"]

    body = R.table("S", R.row(R.fcell("1")))
    B.log("files odfpy wrote:")
    add("odfpy_values.ods", "odfpy", "every value type; whole numbers, fractions, negatives, the largest doubles; dates, datetimes, times; an empty sheet", t_values(), "odfpy")
    add("odfpy_bool_spelled.ods", "odfpy", "boolean cells whose text spells the value twelve ways; only TRUE reads true", t_bool_spelled(), "odfpy")
    add("odfpy_strings.ods", "odfpy", "strings: spaces at the ends, a run of spaces, a line break, paragraphs, an annotation, spans, a list, Japanese, emoji, CDATA, a tab", t_strings(), "odfpy")
    add("odfpy_sheets.ods", "odfpy", "three sheets, the middle one empty; a name with non-ASCII text, spaces and an ampersand", t_sheets(), "odfpy")
    add("odfpy_structure.ods", "odfpy", "a header-rows block, row groups, a table-rows block, column declarations, empty rows and cells between data", t_structure(), "odfpy")
    add("odfpy_repeats.ods", "odfpy", "repeats: empty rows before data, empty cells mid-row, a value repeated along a row, a row with values repeated, trailing empties with large counts", t_repeats(), "odfpy")
    add("odfpy_merged.ods", "odfpy", "covered cells around a merged cell; a covered cell with a value; one with a date and no office:value", t_merged(), "odfpy")
    add("odfpy_formula.ods", "odfpy", "formula cells: a cached number, a cached string, no cached value", t_formula(), "odfpy")
    add("odfpy_empty_cells.ods", "odfpy", "cells that hold nothing: #N/A, void, no value type, an empty string, text:s with c=0, a date with no value, string-value alone", t_empty_cells(), "odfpy")
    add("odfpy_pandas.ods", "odfpy", "a frame written by the spreadsheet writer that rides odfpy: numbers, strings, booleans, datetimes, dates, missing values", t_pandas(), "odfpy")
    add("odfpy_offsets.ods", "odfpy", "datetimes with UTC offsets and with fractions of 3, 6 and 9 digits; before 1970", t_offsets(), "odfpy")
    add("odfpy_small.ods", "odfpy", "four rows: numbers, strings, a boolean, a date, a time; a second sheet with nothing", t_small(), "odfpy")

    B.log("files ezodf wrote:")
    add("ezodf_values.ods", "ezodf", "a sized sheet set cell by cell: a boolean with no text, dates with no text, a datetime spelled with a space, a percentage, a currency, a time with its display text; a time with no text", t_ezodf_values(), "ezodf")
    add("ezodf_grid.ods", "ezodf", "the way its README spells a sheet, with empty cells and spaces; a default-sized empty sheet", t_ezodf_grid(), "ezodf")

    B.log("files whose content.xml this script spells:")
    add("synthetic_prefixed.ods", "synthetic", "the three namespaces under the prefixes off:, tbl: and txt:", prefixed(body), "hand-built")
    cells = R.row(R.scell(R.text("café 日本 🎉")) + R.fcell("1.5")
                  + R.cell(' office:value-type="date" office:date-value="2020-01-02T12:34:56"'))
    add("synthetic_utf16le.ods", "synthetic", "content.xml in UTF-16, little-endian, with its byte-order mark; the reference reader decodes UTF-8 only", utf16(R.table("S", cells), False), "hand-built")
    add("synthetic_utf16be.ods", "synthetic", "content.xml in UTF-16, big-endian, with its byte-order mark", utf16(R.table("S", cells), True), "hand-built")
    marked = b"\xef\xbb\xbf" + R.content(R.table("S", cells))
    add("synthetic_utf8_bom.ods", "synthetic", "content.xml in UTF-8 with a byte-order mark", R.pack([("content.xml", marked), MANIFEST]), "hand-built")
    add("synthetic_no_mimetype.ods", "synthetic", "no mimetype entry: content.xml's root judges the package", no_mimetype(body), "hand-built")
    pretty = ('<table:table table:name="P">\n  <table:table-row>\n    <table:table-cell office:value-type="string">\n'
              '      <text:p>indented</text:p>\n    </table:table-cell>\n    <table:table-cell office:value-type="float" office:value="1">\n'
              '      <text:p>1</text:p>\n    </table:table-cell>\n  </table:table-row>\n</table:table>')
    add("synthetic_pretty.ods", "synthetic", "a content.xml indented with line breaks and spaces: the indentation inside a string cell is part of the string", R.package(pretty), "hand-built")
    nested = R.table("Outer", R.row(R.fcell("1") + R.cell("", R.table("Inner", R.row(R.fcell("2")))) + R.fcell("3")))
    add("synthetic_nested_table.ods", "synthetic", "a table inside a cell of another table: the reference also counts the inner rows as the outer sheet's; this reader does not", R.package(nested), "hand-built", deviating=("Outer",))
    nonfinite = R.table("nonfinite", R.row(R.fcell("NaN") + R.fcell("INF") + R.fcell("-INF") + R.fcell("-0.0")))
    longtimes = R.table("longtimes", R.row(
        R.cell(' office:value-type="time" office:time-value="PT26H00M00S"', R.text("26:00:00"))
        + R.cell(' office:value-type="time" office:time-value="P1DT02H00M00S"')
        + R.cell(' office:value-type="time" office:time-value="PT12H34M56.789123456S"')))
    dateoffset = R.table("dateoffset", R.row(
        R.cell(' office:value-type="date" office:date-value="2020-01-02+02:00"')
        + R.cell(' office:value-type="date" office:date-value="2020-01-02Z"')
        + R.cell(' office:value-type="date" office:date-value="2020-01-02T12:34:56.123456789+02:00"')))
    clocktext = R.table("clocktext", R.row(
        R.cell(' office:value-type="time"', R.text("12:34:56"))
        + R.cell(' office:value-type="time"', R.text("1:05"))
        + R.cell(' office:value-type="time"', R.text("12:34:56.789"))
        + R.cell(' office:value-type="time"', R.text(" 23:59 "))
        + R.cell(' office:value-type="time"')))
    add("synthetic_beyond_reference.ods", "synthetic", "what the reference reader cannot answer: NaN, INF and -INF; -0.0; times of 26 hours; a bare date with a UTC offset; time cells read from their text", R.package(nonfinite + longtimes + dateoffset + clocktext), "hand-built")
    add("synthetic_no_sheets.ods", "synthetic", "a spreadsheet whose content.xml holds no table", R.package(""), "hand-built")
    plain = R.row(R.fcell("1") + R.cell("") + R.cell("") + R.fcell("2")) \
        + R.row(R.scell(R.text("x")) + R.cell("") + R.fcell("3"))
    repeated = R.row(R.fcell("1") + R.cell(' table:number-columns-repeated="2"') + R.fcell("2")) \
        + R.row(R.scell(R.text("x")) + R.cell("") + R.fcell("3"))
    add("synthetic_repeats_equal.ods", "synthetic", "one table spelled twice: with empty cells written out, and with a repeat count", R.package(R.table("Plain", plain) + R.table("Repeated", repeated)), "hand-built")
    add("synthetic_stored.ods", "synthetic", "every entry stored, none deflated", R.package(R.table("S", cells), compress_content=False), "hand-built")

    B.log("files broken in one place each:")
    base = t_small()
    content = content_of(base)
    add("broken_truncated.ods", "broken", "the archive cut in half", base[:len(base) // 2], "patched",
        refuse=lambda data: ("ParseError", "ods: the package is a broken ZIP archive: zip: end of central directory not found"))
    def flipped_payload(data, name, at):
        """The package with one byte of a stored entry's payload flipped:
        its CRC-32 no longer matches."""
        out = bytearray(data)
        out[payload_offset(data, name) + at] ^= 0x01
        return bytes(out)

    stored = with_content(base, content)
    add("broken_checksum.ods", "broken", "a byte of a stored content.xml flipped after the archive was built: its CRC-32 no longer matches", flipped_payload(stored, "content.xml", len(content) // 2), "patched",
        refuse=lambda data: ("ParseError", "ods: the package's entry \"content.xml\" is broken: zip: CRC-32 mismatch"))
    defiant = bytearray(base)
    at = payload_offset(base, "content.xml")
    defiant[at] = (defiant[at] & 0xF8) | 0x07
    add("broken_wont_inflate.ods", "broken", "the first byte of the deflated content.xml made to name a reserved block type", bytes(defiant), "patched",
        refuse=lambda data: ("ParseError", "ods: the package's entry \"content.xml\" is broken: corrupt: reserved block type"))
    styles = zipfile.ZipFile(io.BytesIO(base)).read("styles.xml")
    with_styles = with_content(base, styles, "styles.xml")
    add("broken_other_entry.ods", "broken", "a stored styles.xml with its last byte flipped: the entry named is the broken one", flipped_payload(with_styles, "styles.xml", len(styles) - 1), "patched",
        refuse=lambda data: ("ParseError", "ods: the package's entry \"styles.xml\" is broken: zip: CRC-32 mismatch"))

    first_cell = b'<table:table-cell office:value-type="float" office:value="1"/>'
    opened = b'<table:table-cell office:value-type="string">'
    cut = content[:content.index(b"<text:p>one</text:p>")]

    def unclosed_message(data):
        text = content_of(data)
        at = text.rindex(opened)
        lines_before = text.count(b"\n", 0, at)
        column = at - (text.rfind(b"\n", 0, at) + 1) + 1
        return ("ParseError", "ods: content.xml byte %d is not well-formed: InvalidSyntax(unclosed element: <table:table-cell>) at %d:%d-%d:%d"
                % (at, lines_before + 1, column, lines_before + 1, column + len(opened)))

    add("broken_content_cut.ods", "broken", "content.xml cut short after a cell's start tag; the reference reader answers the cells before the cut", with_content(base, cut), "patched",
        refuse=unclosed_message)
    add("broken_xml_junk.ods", "broken", "content.xml that is not XML; the reference reader answers no sheet", with_content(base, b"not xml at all"), "patched",
        refuse=lambda data: ("ParseError", "ods: content.xml byte 0 is not well-formed: InvalidSyntax(content before root element) at 1:1-1:1"))
    typed = content.replace(b'office:value-type="float" office:value="1"/>', b'office:value-type="html" office:value="1"/>')
    add("broken_value_type.ods", "broken", "a cell of a value type no spreadsheet carries; the reference reader raises on it", with_content(base, typed), "patched",
        refuse=lambda data: ("Unsupported", "ods: content.xml byte %d: the office:value-type \"html\" is not a value type this reader carries" % at_of(data, 'office:value-type="html"')))
    for file, note, attribute, wrong in (
            ("broken_repeat_negative.ods", "a column repeat of -2 on an empty cell", 'table:number-columns-repeated="-2"', "is not a whole number"),
            ("broken_repeat_text.ods", "a column repeat that spells no number", 'table:number-columns-repeated="abc"', "is not a whole number"),
            ("broken_repeat_count.ods", "a column repeat past the largest count the reader takes", 'table:number-columns-repeated="2147483648"', "is past the largest count this reader takes"),
            ("broken_repeat_enormous.ods", "a column repeat of two thousand million on a cell with a value", 'table:number-columns-repeated="2000000000"', None),
    ):
        if wrong is None:
            new = content.replace(first_cell, first_cell[:-2] + b" " + attribute.encode() + b"/>")
        else:
            new = content.replace(b"<table:table-cell/>", b"<table:table-cell " + attribute.encode() + b"/>", 1)
        name, value = attribute.split("=")
        add(file, "broken", note, with_content(base, new), "patched",
            refuse=lambda data, name=name, value=value.strip('"'), wrong=wrong, attribute=attribute:
            ("ParseError", B.refuse_attribute(at_of(data, attribute), name, value, wrong)
             if wrong else B.refuse_budget(at_of(data, attribute), name, value, "Small", len(data))))
    # A hundred thousand rows: the reference reader lays them out, a count
    # past the budget of a package this size.
    rows = content.replace(b"<table:table-row>", b'<table:table-row table:number-rows-repeated="100000">', 1)
    add("broken_repeat_rows.ods", "broken", "a row with a value, repeated a hundred thousand times; the reference reader lays every one of them out", with_content(base, rows), "patched",
        refuse=lambda data: ("ParseError", B.refuse_budget(at_of(data, 'table:number-rows-repeated="100000"'), "table:number-rows-repeated", "100000", "Small", len(data))))
    add("broken_date.ods", "broken", "a date-value that is not a date: February 30th", with_content(base, content.replace(b'office:date-value="2020-01-02"', b'office:date-value="2020-02-30"')), "patched",
        refuse=refuse_attribute('office:date-value="2020-02-30"', "office:date-value", "2020-02-30", "is not a date"))
    add("broken_number.ods", "broken", "an office:value that spells no number", with_content(base, content.replace(b'office:value="2.5"', b'office:value="abc"')), "patched",
        refuse=refuse_attribute('office:value="abc"', "office:value", "abc", "is not a number"))
    add("broken_number_missing.ods", "broken", "a float cell with no office:value", with_content(base, content.replace(b' office:value="2.5"', b"", 1)), "patched",
        refuse=lambda data: ("ParseError", "ods: content.xml byte %d: a float cell carries no office:value" % at_of(data, '<table:table-cell office:value-type="float"/>')))
    add("broken_time_value.ods", "broken", "a time-value with a year in it: not a time of day", with_content(base, content.replace(b'office:time-value="PT01H02M03S"', b'office:time-value="P1Y"')), "patched",
        refuse=refuse_attribute('office:time-value="P1Y"', "office:time-value", "P1Y", "is not a time value"))
    clocked = '<table:table-cell office:value-type="time"><text:p>25:02:03'
    add("broken_clock.ods", "broken", "a time cell whose text is a clock reading of 25 hours", with_content(base, content.replace(b'office:value-type="time" office:time-value="PT01H02M03S"><text:p>01:02:03', b'office:value-type="time"><text:p>25:02:03')), "patched",
        refuse=lambda data: ("ParseError", "ods: content.xml byte %d: the text of a time cell, \"25:02:03\", is not a clock reading" % at_of(data, clocked)))
    spaced = ('<table:table-cell office:value-type="string"><text:p><text:s text:c="2000000000"/></text:p>'
              '</table:table-cell>').encode()
    add("broken_spaces.ods", "broken", "a text:s made to spell two thousand million spaces", with_content(base, content.replace(b"<table:table-cell/>", spaced, 1)), "patched",
        refuse=lambda data: ("ParseError", B.refuse_attribute(at_of(data, 'text:c="2000000000"'), "text:c", "2000000000",
                                                                "would spell more spaces than this reader grants a package of %d bytes (%d)" % (len(data), B.budget(len(data))))))
    counted = ('<table:table-cell office:value-type="string"><text:p><text:s text:c="x"/></text:p>'
               '</table:table-cell>').encode()
    add("broken_text_c.ods", "broken", "a text:c that spells no number; the reference reader raises on it", with_content(base, content.replace(b"<table:table-cell/>", counted, 1)), "patched",
        refuse=refuse_attribute('text:c="x"', "text:c", "x", "is not a whole number"))
    add("broken_mimetype_text.ods", "broken", "a package whose mimetype names a text document; the reference reader reads its tables all the same", with_content(base, b"application/vnd.oasis.opendocument.text", "mimetype"), "patched",
        refuse=lambda data: ("Unsupported", "ods: the package's mimetype is \"application/vnd.oasis.opendocument.text\", not an OpenDocument spreadsheet's"))
    add("broken_mimetype_bytes.ods", "broken", "a mimetype entry of two bytes that are not UTF-8", with_content(base, b"\xff\xfe", "mimetype"), "patched",
        refuse=lambda data: ("Unsupported", "ods: the package's mimetype is \"\\xFF\\xFE\", not an OpenDocument spreadsheet's"))
    add("broken_no_content.ods", "broken", "the mimetype of a spreadsheet and no content.xml; the reference reader answers no sheet", without_entry(base, "content.xml"), "patched",
        refuse=lambda data: ("ParseError", "ods: the package's mimetype is an OpenDocument spreadsheet's, but it holds no content.xml"))
    add("broken_ooxml.xlsx", "broken", "an Office Open XML package", xlsx_package(), "openpyxl",
        refuse=lambda data: ("Unsupported", "ods: the package holds an Office Open XML [Content_Types].xml and no content.xml, so it is not an OpenDocument package"))
    add("broken_not_package.zip", "broken", "a ZIP archive of neither format", R.pack([("hello.txt", b"hello")], mimetype=False), "hand-built",
        refuse=lambda data: ("Unsupported", "ods: the package holds neither a mimetype nor a content.xml, so it is not an OpenDocument package"))
    latin = R.content(R.table("S", R.row(R.scell(R.text("café")))))
    latin = latin.replace(b'encoding="UTF-8"', b'encoding="ISO-8859-1"').replace("café".encode(), "café".encode("latin-1"))
    add("broken_encoding_latin1.ods", "broken", "content.xml declaring ISO-8859-1; the reference reader decodes UTF-8 only", R.pack([("content.xml", latin), MANIFEST]), "hand-built",
        refuse=lambda data: ("Unsupported", "ods: content.xml declares the iso-8859-1 encoding, which this reader does not decode"))
    invalid = R.content(R.table("S", R.row(R.scell(R.text("cafX"))))).replace(b"cafX", b"caf" + bytes([0xE9]))
    add("broken_encoding_bytes.ods", "broken", "a content.xml in UTF-8 with one byte that is not UTF-8", R.pack([("content.xml", invalid), MANIFEST]), "hand-built",
        refuse=lambda data: ("ParseError", "ods: content.xml byte %d is not valid UTF-8" % (content_of(data).index(b"caf" + bytes([0xE9])) + 3)))
    add("broken_root_other.ods", "broken", "no mimetype entry and a root that is the document-styles element", no_mimetype(body, root="document-styles"), "hand-built",
        refuse=lambda data: ("Unsupported", "ods: content.xml's root element is \"office:document-styles\", not an OpenDocument document-content element"))
    add("broken_root_mimetype.ods", "broken", "no mimetype entry; the root's office:mimetype names a text document", no_mimetype(body, mimetype="application/vnd.oasis.opendocument.text"), "hand-built",
        refuse=lambda data: ("Unsupported", "ods: content.xml's office:mimetype is \"application/vnd.oasis.opendocument.text\", not an OpenDocument spreadsheet's"))
    add("broken_encrypted.ods", "broken", "content.xml's flags declare it encrypted; the reference reader raises on the package", encrypted(base, "content.xml"), "patched",
        refuse=lambda data: ("Unsupported", "ods: the package's entry \"content.xml\" is encrypted, which this reader does not decrypt"))

    with open(os.path.join(FIX, "index.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=1)
    refused = sum(1 for e in index if e["codec"] == "refuses")
    B.log("the corpus: wrote %d files (%d of them the codec refuses by name) and %d cells under %s"
        % (len(index), refused, sum(e.get("cells", 0) for e in index), FIX))
    B.log("cells this script's reading and the reference reader both hold, compared at make time: %d" % tally["compared"])
    B.log("bytes on disk: %d" % sum(os.path.getsize(os.path.join(FIX, n)) for n in os.listdir(FIX)))
    return 0


# ── verify ────────────────────────────────────────────────────────────

def main_verify():
    with open(os.path.join(FIX, "index.json"), encoding="utf-8") as f:
        index = json.load(f)
    listed = set(e["file"] for e in index)
    problems = 0
    for name in os.listdir(FIX):
        if name != "index.json" and not name.endswith(".json") and name not in listed:
            B.log("MISMATCH fixtures/reference/%s is not in the index" % name)
            problems += 1
    stats = {"files": 0, "refused": 0, "opens": 0, "cannot_open": 0, "cells": 0, "agreed": 0,
             "generator": 0, "sheets_raising": 0, "deviating": 0, "excel_sheets": 0, "excel_raising": 0, "excel_nulled": 0}
    for entry in index:
        path = os.path.join(FIX, entry["file"])
        with open(path + ".json", encoding="utf-8") as f:
            car = json.load(f)
        stats["files"] += 1
        if car["codec"] == "refuses":
            stats["refused"] += 1
            if not car["message"].startswith("ods: "):
                B.log("MISMATCH %s: the refusal does not start with \"ods: \"" % entry["file"])
                problems += 1
        view, theirs_by_sheet, names = B.reference_view(path)
        if view["opens"] != car["reference"]["opens"]:
            B.log("MISMATCH %s: the reference reader opens it: %s now, %s in the sidecar"
                % (entry["file"], view["opens"], car["reference"]["opens"]))
            problems += 1
            continue
        if not view["opens"]:
            stats["cannot_open"] += 1
            if car["codec"] == "reads":
                stats["generator"] += sum(len(sheet["cells"]) for sheet in car["sheets"])
            continue
        stats["opens"] += 1
        if view["sheets"] != car["reference"]["sheets"]:
            B.log("MISMATCH %s: the reference reader's cell counts or errors differ from the sidecar's record"
                % entry["file"])
            problems += 1
        if car["codec"] == "refuses":
            continue
        if names != [sheet["name"] for sheet in car["sheets"]]:
            B.log("MISMATCH %s: the sheet names differ" % entry["file"])
            problems += 1
        for i, sheet in enumerate(car["sheets"]):
            theirs = theirs_by_sheet.get(i)
            if sheet["source"] != "reference":
                # The reference reader raises on this sheet, or answers it
                # differently: its cells are this script's own reading.
                stats["generator"] += len(sheet["cells"])
                if isinstance(theirs, str):
                    stats["sheets_raising"] += 1
                else:
                    stats["deviating"] += 1
                continue
            stats["cells"] += len(theirs)
            if theirs == sheet["cells"]:
                stats["agreed"] += len(theirs)
            else:
                B.log("MISMATCH %s, sheet %r: the reference reader's cells differ from the sidecar"
                    % (entry["file"], sheet["name"]))
                problems += 1
            # The call the task names gives the same cells as the reader
            # class the sidecar came from.
            verdict, nulled = excel_agrees(path, i, sheet["cells"])
            stats["excel_nulled"] += len(nulled)
            for text in nulled:
                stats.setdefault("nulled_strings", []).append(text)
            if verdict is not True:
                B.log("MISMATCH %s, sheet %r: read_excel gives other cells than the reader class: %s"
                    % (entry["file"], sheet["name"], verdict))
                problems += 1
            else:
                stats["excel_sheets"] += 1
        for i, sheet in enumerate(car["sheets"]):
            if sheet["source"] == "reference" or not isinstance(theirs_by_sheet.get(i), str):
                continue
            # Where the reader class raises on a sheet, the named call raises too.
            if excel_raises(path, i):
                stats["excel_raising"] += 1
            else:
                B.log("MISMATCH %s, sheet %r: the reader class raises, read_excel does not"
                    % (entry["file"], sheet["name"]))
                problems += 1
    B.log("reference files: %(files)d; the codec refuses %(refused)d by name; the reference reader opens %(opens)d "
        "and cannot open %(cannot_open)d" % stats)
    B.log("cells the reference reader returned, compared with the sidecars: %(cells)d; agreed: %(agreed)d; "
        "sheets it raises on: %(sheets_raising)d; sheets it answers differently: %(deviating)d; "
        "cells from this script's own reading: %(generator)d" % stats)
    B.log("read_excel(path, engine=\"odf\", header=None, dtype=object), its text NA filter off: the same cells as "
        "the reader class on %(excel_sheets)d sheets; raising on %(excel_raising)d of the sheets the reader "
        "class raises on; with the filter on, as the call is named, it nulls %(excel_nulled)d cells the reader "
        "class gives as strings: %(nulled_strings)s"
        % dict(stats, nulled_strings=stats.get("nulled_strings", [])))
    B.log("mismatches: %d" % problems)
    return 1 if problems else 0


def excel_cells(path, index, keep_default_na):
    """The cells `read_excel(path, engine="odf", header=None, dtype=object)`
    answers for sheet `index`, spelled as the sidecars spell them, by
    position — with pandas' own text NA filter on or off."""
    frame = pd.read_excel(path, engine="odf", header=None, dtype=object, sheet_name=index,
                          keep_default_na=keep_default_na)
    spelled = {}
    for r in range(frame.shape[0]):
        for c in range(frame.shape[1]):
            got = B.spell(frame.iat[r, c])
            if got is not None:
                spelled[(r, c)] = [r, c, got[0], got[1]]
    return spelled


def excel_agrees(path, index, cells):
    """Whether the named call, asked not to apply its text NA filter,
    answers the cells of sheet `index` the reader class gave — `True`, or
    what differs — and which of those cells the call as named in the task
    nulls by that filter: the strings it takes for missing values ("NA",
    "null", …) are a pandas parser convention, not the odf reader's."""
    spelled = excel_cells(path, index, False)
    wanted = {(cell[0], cell[1]): cell for cell in cells}
    verdict = True
    if spelled != wanted:
        verdict = "the same cells in another order"
        for key in sorted(set(spelled) | set(wanted)):
            if spelled.get(key) != wanted.get(key):
                verdict = "at %s: read_excel %r, the reader class %r" % (
                    key, spelled.get(key), wanted.get(key))
                break
    plain = excel_cells(path, index, True)
    nulled = [wanted[key][3] for key in sorted(wanted) if key not in plain]
    return verdict, nulled


def excel_raises(path, index):
    """Whether the named call raises on sheet `index`."""
    try:
        pd.read_excel(path, engine="odf", header=None, dtype=object, sheet_name=index)
    except Exception:  # noqa
        return True
    return False


if __name__ == "__main__":
    steps = [a for a in sys.argv[1:] if not a.startswith("--")]
    step = steps[0] if steps else "make"
    sys.exit(main_make() if step == "make" else main_verify())
