"""The reference reader's answers, the sidecar's cell spelling, and this
script's own reading of a content.xml — written from the format and the
task's rules, independently of the codec — for the sheets the reference
reader cannot read. Shared by the generator and its verify step.

Every cell is spelled ``[row, column, kind, payload]``: a ``Number`` by the
16 hexadecimal digits of its IEEE bits (``NaN`` for a NaN), a ``Text`` by
itself, a ``Boolean`` by ``true`` or ``false``, a ``Day``, ``Instant`` or
``Time`` by its decimal count.
"""
import datetime
import math
import re
import struct
import xml.etree.ElementTree as ET

EPOCH = datetime.datetime(1970, 1, 1)
DAY_MICROS = 86400 * 10 ** 6

OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"


def q(namespace, local):
    return "{%s}%s" % (namespace, local)


def log(text):
    print(text, flush=True)


def cut(text, most):
    return text if len(text) <= most else text[:most]


# ── the spelling ──────────────────────────────────────────────────────

def bits(value):
    return "%016x" % struct.unpack("<Q", struct.pack("<d", value))[0]


def spell(value):
    """A cell as the reference reader answered it, as this reader's value;
    None for a cell this reader does not hold (a missing value, an empty
    string)."""
    import pandas as pd
    if isinstance(value, bool):
        return ("Boolean", "true" if value else "false")
    if isinstance(value, int):
        return ("Number", bits(float(value)))
    if isinstance(value, float):
        return None if math.isnan(value) else ("Number", bits(value))
    if isinstance(value, str):
        return None if value == "" else ("Text", value)
    if isinstance(value, datetime.time):
        return ("Time", str((value.hour * 3600 + value.minute * 60 + value.second) * 10 ** 6
                            + value.microsecond))
    if isinstance(value, pd.Timestamp):
        if value.tz is not None:
            return ("Instant", str(value.value // 1000))
        micros = (value.hour * 3600 + value.minute * 60 + value.second) * 10 ** 6 + value.microsecond
        days = (value.date() - EPOCH.date()).days
        if micros == 0:
            return ("Day", str(days))
        return ("Instant", str(days * DAY_MICROS + micros))
    if value is pd.NaT:
        return None
    raise TypeError("a cell the reference reader answered that is not spelled: %r" % (value,))


def reference_cells(rows):
    """The non-empty cells of one sheet as the reader class laid it out
    (its "" marking an empty cell), each with its position."""
    cells = []
    for r, row in enumerate(rows):
        for c, value in enumerate(row):
            spelled = spell(value)
            if spelled is not None:
                cells.append([r, c, spelled[0], spelled[1]])
    return cells


# ── the reference reader ──────────────────────────────────────────────

def reference_read(path):
    """What the reference reader answers: its sheet names, and for each
    sheet the spelled cells it got — the list of lists its reader class
    laid out, emptied of its empty cells — or the exception it raised
    there; or, when it cannot open the file at all, None and the
    exception."""
    from pandas.io.excel._odfreader import ODFReader
    try:
        reader = ODFReader(path)
        names = list(reader.sheet_names)
    except Exception as e:  # noqa
        return None, "%s: %s" % (type(e).__name__, e)
    sheets = {}
    for i in range(len(names)):
        try:
            sheets[i] = reference_cells(reader.get_sheet_data(reader.get_sheet_by_index(i)))
        except Exception as e:  # noqa
            sheets[i] = "%s: %s" % (type(e).__name__, e)
    return names, sheets


def reference_view(path):
    """The reference reader's view of a file: for a sidecar, whether it
    opens, its error when it does not, and a sheet's cell count or its
    error by position; beside that the spelled cells themselves, and the
    sheet names (None where the reader lists a table with no name)."""
    names, sheets = reference_read(path)
    if names is None:
        return {"opens": False, "error": sheets, "sheets": {}}, {}, []
    view = {"opens": True, "error": None, "sheets": {}}
    for i, cells in sheets.items():
        view["sheets"][str(i)] = {"cells": len(cells)} if isinstance(cells, list) else {"error": cells}
    return view, sheets, ["" if n is None else n for n in names]


# ── this script's own reading ─────────────────────────────────────────

XSD_DOUBLE = re.compile(
    r"^[+-]?((\d+(\.\d*)?)|(\.\d+))([eE][+-]?\d+)?$|^INF$|^-INF$|^NaN$")
DATE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})"
    r"(?:[Tt ](\d{1,18}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?)?"
    r"(Z|z|[+-]\d{2}:\d{2})?$")
DURATION = re.compile(
    r"^P(?:(\d{1,18})D)?(?:T(?:(\d{1,18})H)?(?:(\d{1,18})M)?(?:(\d{0,18})(?:\.(\d+))?S)?)?$")
CLOCK = re.compile(r"^(\d{1,18}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?$")


def own_number(text):
    if not XSD_DOUBLE.match(text):
        raise ValueError("not a number: %r" % text)
    if text == "INF":
        return math.inf
    if text == "-INF":
        return -math.inf
    if text == "NaN":
        return math.nan
    value = float(text.strip())
    if math.isinf(value):
        raise ValueError("not a number: %r" % text)
    return value


def fraction_micros(digits):
    return int((digits + "000000")[:6])


def own_clock(hours, minutes, seconds, fraction):
    """A clock reading in microseconds; a clock of 24 hours or more is none."""
    if int(hours) > 23 or int(minutes) > 59 or (seconds is not None and int(seconds) > 59):
        raise ValueError("not a clock")
    return (int(hours) * 3600 + int(minutes) * 60 + int(seconds or 0)) * 10 ** 6 + \
        (fraction_micros(fraction) if fraction is not None else 0)


def own_date(text):
    match = DATE.match(text.strip())
    if not match:
        raise ValueError("not a date: %r" % text)
    year, month, day = int(match.group(1)), int(match.group(2)), int(match.group(3))
    days = (datetime.date(year, month, day) - EPOCH.date()).days
    clock = 0
    if match.group(4) is not None:
        clock = own_clock(*match.group(4, 5, 6, 7))
    zone = match.group(8)
    if zone is None and clock == 0:
        return ("Day", str(days))
    offset = 0
    if zone not in (None, "Z", "z"):
        offset = (int(zone[1:3]) * 60 + int(zone[4:6])) * 60 * 10 ** 6
        if int(zone[1:3]) > 23 or int(zone[4:6]) > 59:
            raise ValueError("not a date: %r" % text)
        if zone[0] == "-":
            offset = -offset
    return ("Instant", str(days * DAY_MICROS + clock - offset))


def own_duration(text):
    match = DURATION.match(text.strip())
    if not match:
        raise ValueError("not a time value: %r" % text)
    days, hours, minutes, seconds, fraction = match.groups()
    if not any(part for part in (days, hours, minutes, seconds, fraction)):
        raise ValueError("not a time value: %r" % text)
    total = int(days or 0) * DAY_MICROS + int(hours or 0) * 3600 * 10 ** 6 + \
        int(minutes or 0) * 60 * 10 ** 6 + int(seconds or 0) * 10 ** 6
    if fraction is not None:
        total += fraction_micros(fraction)
    return total


def raw(cell):
    """A cell's whole text: every text node inside it, nothing else."""
    return "".join(cell.itertext())


def compose(cell):
    """A string cell's value: text nodes with the line breaks at their ends
    cut, text:s as spaces, text:line-break as a line break, annotations
    skipped, every other element recursed into, a paragraph preceded by a
    line break from the second on at its level."""
    value = []

    def run(text):
        if text:
            value.append(text.strip("\n"))

    seen = False
    run(cell.text)
    for child in cell:
        if child.tag == q(TEXT, "s"):
            value.append(" " * int(child.get(q(TEXT, "c"), "1")))
        elif child.tag == q(TEXT, "line-break"):
            value.append("\n")
        elif child.tag == q(OFFICE, "annotation"):
            pass
        else:
            if child.tag == q(TEXT, "p"):
                if seen:
                    value.append("\n")
                seen = True
            value.append(compose(child))
        run(child.tail)
    return "".join(value)


def own_cell(cell, covered):
    """A cell's value by the rules this reader codes, or None for an empty
    one. Raises ValueError for what the reader refuses."""
    if raw(cell) == "#N/A":
        return None
    kind = cell.get(q(OFFICE, "value-type"))
    if kind is None:
        return None
    if covered and cell.get(q(OFFICE, "value")) is None:
        return None
    if kind in ("float", "percentage", "currency"):
        value = cell.get(q(OFFICE, "value"))
        if value is None:
            raise ValueError("a %s cell carries no office:value" % kind)
        return ("Number", "NaN" if math.isnan(own_number(value)) else bits(own_number(value)))
    if kind == "boolean":
        return ("Boolean", "true" if raw(cell) == "TRUE" else "false")
    if kind == "string":
        text = compose(cell)
        return None if text == "" else ("Text", text)
    if kind == "date":
        value = cell.get(q(OFFICE, "date-value"))
        return None if not value else own_date(value)
    if kind == "time":
        value = cell.get(q(OFFICE, "time-value"))
        if value is not None:
            return ("Time", str(own_duration(value)))
        text = raw(cell).strip()
        if text == "":
            return None
        match = CLOCK.match(text)
        if not match:
            raise ValueError("not a clock: %r" % raw(cell))
        return ("Time", str(own_clock(*match.group(1, 2, 3, 4))))
    if kind == "void":
        return None
    raise LookupError(kind)


def count(attribute, name):
    """A repeat count as the reader takes it: 1 where absent."""
    if attribute is None:
        return 1
    if not re.match(r"^\d{1,10}$", attribute) or int(attribute) > 2147483647:
        raise ValueError("not a count: %r" % (attribute,))
    return int(attribute)


def own_sheets(content):
    """The sheets of a content.xml by the rules this reader codes: a list
    of (name, cells)."""
    root = ET.fromstring(content)
    parents = {child: parent for parent in root.iter() for child in parent}

    def table_of(element):
        while element in parents:
            element = parents[element]
            if element.tag == q(TABLE, "table"):
                return element
        return None

    sheets = []
    body = root.find(q(OFFICE, "body"))
    for table in ([] if body is None else body.iter(q(TABLE, "table"))):
        cells = []
        next_row = 0
        empty_rows = 0
        for row in table.iter(q(TABLE, "table-row")):
            if table_of(row) is not table:
                continue
            repeat = count(row.get(q(TABLE, "number-rows-repeated")), "rows")
            placed = []
            waiting = 0
            col = 0
            for cell in row:
                if cell.tag not in (q(TABLE, "table-cell"), q(TABLE, "covered-table-cell")):
                    continue
                span = count(cell.get(q(TABLE, "number-columns-repeated")), "columns")
                value = own_cell(cell, cell.tag == q(TABLE, "covered-table-cell"))
                if value is None:
                    waiting += span
                else:
                    if span > 0:
                        placed.append((col + waiting, span, value))
                    col += waiting + span
                    waiting = 0
            if not placed:
                empty_rows += repeat
                continue
            first = next_row + empty_rows
            empty_rows = 0
            for k in range(repeat):
                for at, span, value in placed:
                    for j in range(span):
                        cells.append([first + k, at + j, value[0], value[1]])
            next_row = first + repeat
        sheets.append((table.get(q(TABLE, "name"), ""), cells))
    return sheets


# ── the reader's refusals, as its messages spell them ─────────────────

def budget(size):
    return min(65536 + 8 * size, 33554432)


def refuse_attribute(byte, name, value, wrong):
    return "ods: content.xml byte %d: the %s attribute \"%s\" %s" % (byte, name, cut(value, 32), wrong)


def refuse_budget(byte, name, value, sheet, size):
    return refuse_attribute(byte, name, value,
                            "would make sheet \"%s\" hold more cells than this reader grants a "
                            "package of %d bytes (%d)" % (cut(sheet, 64), size, budget(size)))
