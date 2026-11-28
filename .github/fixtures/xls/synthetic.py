"""The hand-built half of the reference corpus: the workbooks built record
by record for what the reference writer never spells, and the files broken
in one place each, every one with the refusal it must meet — the variant,
and the text to the byte. `gen_fixtures.py` writes what this module
describes and judges the sound files with the reference reader.

A sound workbook comes with its plan: its sheets, and for each cell what
the records wrote, spelled the way the sidecars spell them —
``["T", row, col, text]``, ``["B", row, col, boolean]``,
``["N", row, col, bits, format index, format code]`` and
``["E", row, col, text]`` — so that what the reference reader reads from
the file is compared, cell for cell, with what the encoder meant to write.

Every refusal text here is the codec's own, composed from the byte the
fault lies at; the fixtures test holds the codec to it, so the two cannot
drift apart unseen.
"""
import os
import struct
import sys

import xlrd.formatting as _formatting  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import xlsbuild as B  # noqa: E402

#: The code the reference reader names for a built-in number format no
#: FORMAT record re-spells (its table of the United States spellings).
STD_STRINGS = dict(_formatting.std_format_strings)

ERROR_TEXT = {code: text for text, code in B.ERRORS.items()}


def bits(value):
    """A double's 64 bits, as sixteen lowercase hexadecimal digits."""
    return "%016x" % struct.unpack("<Q", struct.pack("<d", value))[0]


def u(value):
    """A sector number as the file carries it: unsigned."""
    return value & 0xFFFFFFFF


def wb(at):
    return "byte %d of the workbook stream" % at


# ── a sheet being built ──────────────────────────────────────────────

class Sheet:
    """One worksheet being built: its records between the BOF and the EOF,
    and the plan of its cells."""

    def __init__(self, name, visibility=0, **kw):
        self.name = name
        self.visibility = visibility
        self.kw = kw
        self.records = []
        self.cells = {}
        self.texts = []

    def raw(self, *records):
        """Append records as they are."""
        self.records.extend(records)

    def number(self, row, col, value, style=0):
        self.raw(B.number(row, col, style, value))
        self.cells[(row, col)] = ["N", row, col, bits(value), style]

    def rk(self, row, col, value, rk, style=0):
        self.raw(B.rk_record(row, col, style, rk))
        self.cells[(row, col)] = ["N", row, col, bits(value), style]

    def mulrk(self, row, col, cells):
        """`(value, RK value, style)` triples along the row from `col`."""
        self.raw(B.mulrk(row, col, [(style, rk) for _, rk, style in cells]))
        for i, (value, _, style) in enumerate(cells):
            self.cells[(row, col + i)] = ["N", row, col + i, bits(value), style]

    def text(self, row, col, text, style=0):
        """A cell holding a shared string; its index into the table is
        settled when the workbook is built, the table being the sheets'."""
        self.records.append(B.labelsst(row, col, style, 0))
        self.texts.append((len(self.records) - 1, row, col, style, text))
        self.cells[(row, col)] = ["T", row, col, text]

    def label(self, row, col, text=None, style=0, **spell):
        """A cell holding a string of its own; `segments` spell it in
        more than one way."""
        self.raw(B.label(row, col, style, text, **spell))
        if text is None:
            text = "".join(t for t, _ in spell["segments"])
        self.cells[(row, col)] = ["T", row, col, text]

    def boolean(self, row, col, value, style=0):
        self.raw(B.boolerr(row, col, style, 1 if value else 0, 0))
        self.cells[(row, col)] = ["B", row, col, bool(value)]

    def error(self, row, col, text, style=0):
        self.raw(B.error_cell(row, col, style, text))
        self.cells[(row, col)] = ["E", row, col, text]

    def formula(self, row, col, cached, style=0, text=None, between=(), record=None):
        """A formula whose cached value is a number (`cached` a float),
        ``("bool", 0|1)``, ``("error", code)``, ``("blank",)`` or
        ``("string",)`` — then `text` is the string the STRING record after
        it holds, past the records in `between`, spelled by `record` when
        it is given."""
        self.raw(B.formula(row, col, style, cached))
        self.raw(*between)
        if isinstance(cached, float):
            self.cells[(row, col)] = ["N", row, col, bits(cached), style]
        elif cached[0] == "bool":
            self.cells[(row, col)] = ["B", row, col, cached[1] == 1]
        elif cached[0] == "error":
            self.cells[(row, col)] = ["E", row, col, ERROR_TEXT[cached[1]]]
        elif cached[0] == "blank":
            # The blank string: the codec answers no cell, the reference
            # reader an empty text.
            self.cells[(row, col)] = ["T", row, col, "", "blank"]
        else:
            self.raw(record if record is not None else B.string_record(text))
            self.cells[(row, col)] = ["T", row, col, text]

    def blank(self, row, col, style=0):
        self.raw(B.blank(row, col, style))

    def mulblank(self, row, col, styles, last=None):
        self.raw(B.mulblank(row, col, styles, last))


def build(sheets, xfs=(0,), formats=(), datemode=None, sst_limit=B.PIECE,
          sst_items=None, no_sst=False, before=(), after=(), **kw):
    """The workbook stream of `sheets`, and its plan. `xfs` is the number
    format index of each XF record, in order; `formats` the FORMAT records
    as (index, code) pairs; the shared string table holds the sheets'
    texts unless `sst_items` gives its strings as they are."""
    formats = dict(formats)
    shared = []
    for sheet in sheets:
        if isinstance(sheet, Sheet):
            for at, row, col, style, text in sheet.texts:
                if text not in shared:
                    shared.append(text)
                sheet.records[at] = B.labelsst(row, col, style, shared.index(text))
    dicts = []
    for sheet in sheets:
        if isinstance(sheet, Sheet):
            dicts.append(dict(name=sheet.name, visibility=sheet.visibility,
                              records=sheet.records, **sheet.kw))
        else:
            dicts.append(sheet)
    stream = B.simple_workbook(
        dicts, strings=shared, ifmts=xfs, formats=sorted(formats.items()),
        datemode_=datemode, sst_limit=sst_limit, sst_items=sst_items, no_sst=no_sst,
        before=before, after=after, **kw)
    plan = {"datemode": datemode or 0, "sheets": []}
    for sheet in sheets:
        if not isinstance(sheet, Sheet):
            continue
        cells = []
        for (row, col), cell in sorted(sheet.cells.items()):
            if cell[0] == "N":
                key = xfs[cell[4]]
                cell = ["N", row, col, cell[3], key,
                        formats.get(key, STD_STRINGS.get(key))]
            cells.append(cell)
        plan["sheets"].append({"sheet": sheet.name, "cells": cells})
    return stream, plan


def offset(stream, record):
    """Where a record lies in the stream, which holds it once."""
    assert stream.count(record) == 1, "the record lies in the stream %d times" % (
        stream.count(record))
    return stream.index(record)


def first_record(stream, rid):
    """Where the first record of id `rid` lies in the stream."""
    for found, _, at in B.records(stream):
        if found == rid:
            return at
    raise AssertionError("no record of id 0x%04X in the stream" % rid)


def tiny(sheet_kw=None, **kw):
    """A small sound workbook — a text and two numbers — and its plan."""
    s = Sheet("S", **(sheet_kw or {}))
    s.text(0, 0, "text")
    s.number(1, 0, 1.5)
    s.rk(1, 1, 3.0, B.rk_int(3))
    return build([s], **kw)


# ── sound hand-built workbooks ───────────────────────────────────────

def scattered(stream):
    """A compound file whose mini stream lies in two regular sectors that
    are not next to each other, a free sector among them, and whose
    stream's mini sectors are not in order either: each chunk of the
    stream sits one mini sector round from where its order would put it."""
    per = 128
    m = (len(stream) + 63) // 64
    assert 8 < m <= 16, "the stream needs 9 to 16 mini sectors, it has %d" % m
    mini_stream = bytearray(1024)
    mini_fat = [B.FREE] * per
    for i in range(m):
        chunk = stream[i * 64:(i + 1) * 64].ljust(64, b"\x00")
        at = (i + 1) % m
        mini_stream[at * 64:(at + 1) * 64] = chunk
        mini_fat[at] = (i + 2) % m if i + 1 < m else B.ENDC
    fat = [B.FREE] * per
    fat[1] = 4          # the mini stream's first sector, then its second
    fat[4] = B.ENDC
    fat[2] = B.ENDC     # the mini FAT
    fat[5] = B.FATSEC   # the FAT
    fat[6] = B.ENDC     # the directory
    c = B.Cfb(
        B.header(nfat=1, dir_first=6, minifat_first=2, nminifat=1, difat=[5]),
        [b"\x00" * 512, bytes(mini_stream[:512]), B._fat_table(mini_fat, per),
         b"\xab" * 512, bytes(mini_stream[512:]), B._fat_table(fat, per),
         B._pad(B.directory(1 % m, len(stream), 1, m * 64), 512)],
        512)
    c.minifat_off = 512 + 2 * 512
    c.fat_off = 512 + 5 * 512
    c.dir_off = 512 + 6 * 512
    return c


def sound():
    """Every sound hand-built workbook: dicts of its name, its note, its
    bytes and its plan."""
    out = []

    def add(name, note, stream, plan, container=None, **extra):
        container = container or (B.mini if len(stream) < B.CUTOFF else B.regular)
        entry = {"name": name, "note": note, "data": container(stream).out(),
                 "plan": plan, "stream": stream}
        entry.update(extra)
        out.append(entry)

    stream, plan = tiny()
    add("syn_tiny.xls", "hand-built: one text and two numbers, in the mini stream", stream, plan)

    # the four RK spellings, the float ones the reference writer never spells
    s = Sheet("RK")
    s.rk(0, 0, 3.0, B.rk_int(3))
    s.rk(0, 1, 1.5, B.rk_int100(150))
    s.rk(0, 2, -7.0, B.rk_int(-7))
    s.rk(0, 3, -12.34, B.rk_int100(-1234))
    s.rk(1, 0, 1.5, B.rk_float(1.5))
    s.rk(1, 1, -2.5, B.rk_float(-2.5))
    s.rk(1, 2, 0.015, B.rk_float100(1.5))
    s.rk(1, 3, 1572864.0, B.rk_float(1572864.0))
    s.rk(1, 4, 100000.0, B.rk_float(100000.0))
    s.rk(1, 5, 1073741824.0, B.rk_float(1073741824.0))
    s.rk(2, 0, -536870912.0, B.rk_int(-0x20000000))
    s.rk(2, 1, 536870911.0, B.rk_int(0x1FFFFFFF))
    s.rk(2, 2, -5368709.12, B.rk_int100(-0x20000000))
    s.rk(2, 3, -0.5, B.rk_float(-0.5))
    s.rk(2, 4, -0.015, B.rk_float100(-1.5))
    s.mulrk(3, 0, [(1.0, B.rk_int(1), 0), (2.5, B.rk_int100(250), 0),
                    (-2.5, B.rk_float(-2.5), 0), (0.015, B.rk_float100(1.5), 0),
                    (3.0, B.rk_int(3), 0)])
    s.mulrk(4, 0, [(float(i), B.rk_int(i), 0) for i in range(256)])
    s.mulrk(5, 250, [(float(i), B.rk_int(i), 0) for i in range(6)])
    add("syn_rk.xls", "hand-built: the four RK spellings — a 30-bit integer and the high 30 bits of a double, each plain and divided by 100 — as RK records and in MULRK runs, one run 256 cells long, one ending at column 255", *build([s]))

    # LABEL records
    s = Sheet("labels")
    s.label(0, 0, "compressed")
    s.label(0, 1, "日本語")
    s.label(1, 0, "bold and plain", runs=[(0, 1), (4, 0)])
    s.label(1, 1, "日本語の表記", runs=[(0, 2), (1, 3)], phonetic=b"\x01\x02\x03\x04")
    s.label(2, 0, "", cch=0)
    s.label(2, 1, "line\nbreak\r\nand\ttab")
    s.label(3, 0, "é")
    s.label(3, 1, "\x00\x01\x7f\x80\xff")
    s.label(3, 2, "\U0001F600 emoji")
    add("syn_label.xls", "hand-built: LABEL records — a cell's own string, compressed and UTF-16, with rich-text runs and with phonetic data, an empty one, control characters", *build([s]))

    # a LABEL no one record holds
    s = Sheet("long")
    s.label(0, 0, segments=B.auto_segments("L" * 9000 + "日" * 100))
    s.label(0, 1, "short")
    s.formula(1, 0, ("string",), text="S" * 9000)
    s.formula(1, 1, ("string",), text="x" * 300 + "日" * 2000,
              between=[B.array_record(1, 1)],
              record=B.string_record(segments=B.auto_segments("x" * 300 + "日" * 2000)))
    add("syn_label_continued.xls", "hand-built: a LABEL record whose string outgrows one record and is continued by CONTINUE records, with a change of spelling; a formula's cached string of 9000 characters, and one continued after an ARRAY record",
        *build([s]), sidecar="generator", skip=frozenset({("long", 0, 0)}),
        deviations="the reference reader reads a LABEL record's string from its first record alone, so it truncates the continued one; the codec reads the whole string")

    # the eighth error code the format names, which the reference reader does not
    s = Sheet("S")
    s.raw(B.boolerr(0, 0, 0, B.GETTING_DATA, 1))
    s.cells[(0, 0)] = ["E", 0, 0, "#GETTING_DATA"]
    s.raw(B.formula(1, 0, 0, ("error", B.GETTING_DATA)))
    s.cells[(1, 0)] = ["E", 1, 0, "#GETTING_DATA"]
    s.text(2, 0, "beside")
    add("syn_getting_data.xls", "hand-built: the eighth error code the format names, #GETTING_DATA, in a BOOLERR record and as a formula's cached value",
        *build([s]), sidecar="generator", skip=frozenset({("S", 0, 0), ("S", 1, 0)}),
        deviations="the reference reader has no text for error code 0x2B, which the format names #GETTING_DATA; the codec answers the format's text")

    # formulas with every cached value
    s = Sheet("f")
    s.formula(0, 0, 2.5)
    s.formula(0, 1, -0.125)
    s.formula(1, 0, ("bool", 1))
    s.formula(1, 1, ("bool", 0))
    for i, text in enumerate(B.ERRORS):
        s.formula(2, i, ("error", B.ERRORS[text]))
    s.formula(3, 0, ("blank",))
    s.formula(4, 0, ("string",), text="cached")
    s.formula(4, 1, ("string",), text="after array", between=[B.array_record(4, 1)])
    s.formula(4, 2, ("string",), text="after shrfmla", between=[B.shrfmla_record(4, 2)])
    s.formula(5, 0, ("string",), text="ab日本",
              record=B.string_record(segments=B.auto_segments("ab日本")))
    s.formula(5, 1, ("string",), text="")
    s.text(6, 0, "a text beside")
    add("syn_formula.xls", "hand-built: FORMULA records with every cached value — a number, a boolean, each error, the blank string, and a string in a STRING record: plain, after ARRAY and SHRFMLA records, and spelled two ways", *build([s]))

    # a formula's string past a TABLEOP and TABLEOP2 pair
    s = Sheet("t")
    s.formula(0, 0, ("string",), text="after tableop",
              between=[B.tableop_record(0, 0), B.tableop2_record(0, 0)])
    s.formula(1, 0, 2.5)
    add("syn_formula_tableop.xls", "hand-built: a formula whose cached string follows a TABLEOP and a TABLEOP2 record, the pair a data table's formula carries",
        *build([s]), sidecar="generator",
        deviations="the reference reader allows one record between a formula and its string, and refuses the TABLEOP and TABLEOP2 pair; the codec reads past both")

    # the shared string table cut and re-spelled by CONTINUE records
    texts = ["one", "ab日本cd", "日本ab", "x" * 14 + "é" * 5 + "日" * 4,
             "日" * 6 + "z" * 9, "q" * 4 + "雨" * 3, "tail"]
    items = [B.string_item(segments=B.auto_segments(t)) for t in texts]
    items[4] = B.string_item(segments=B.auto_segments(texts[4]), runs=[(0, 1), (6, 2)])
    items[5] = B.string_item(segments=B.auto_segments(texts[5]), phonetic=b"\x11" * 9)
    s = Sheet("switch")
    for i, t in enumerate(texts):
        s.raw(B.labelsst(0, i, 0, i))
        s.cells[(0, i)] = ["T", 0, i, t]
    add("syn_switch.xls", "hand-built: shared strings whose characters CONTINUE records cut every few bytes, each piece after a cut spelled as the flags byte at its head says — compressed turning UTF-16 and back — with rich-text runs and phonetic data cut too, and a string beginning inside a CONTINUE record",
        *build([s], sst_items=items, sst_limit=13))

    # records the cells do not depend on, blanks, disorder, a cell written twice
    s = Sheet("records")
    s.raw(B.index_record(), B.dbcell_record(), B.dimensions(20, 10), B.row_record(0, 3))
    s.mulblank(0, 0, [0, 0, 0])
    s.blank(1, 5)
    s.raw(B.unknown(0x00EC, b"\x01\x02"), B.rec(B.CONTINUE, b"\xff\xff"))
    s.number(7, 0, 7.0)
    s.number(2, 9, 29.0)
    s.number(2, 1, 21.0)
    s.number(7, 0, 70.0)
    s.text(3, 0, "beside")
    s.raw(B.bof(B.CHART), B.unknown(0x1002, b"\x00\x00"), B.rec(B.CONTINUE, b"\x00"), B.eof())
    s.number(4, 0, 4.0)
    s.mulblank(5, 250, [0] * 6)
    s.blank(65535, 255)
    add("syn_records.xls", "hand-built: INDEX, DBCELL, DIMENSIONS and ROW records, an unknown record with a CONTINUE after it, MULBLANK records (one to column 255) and BLANK records, an embedded chart substream with records of its own, cells out of row and column order, and a cell written twice",
        *build([s]))

    # number formats
    formats = [(164, "yyyy-mm-dd"), (165, "[$-409]d-mmm-yyyy"), (166, "[h]:mm:ss"),
               (167, "0.000"), (168, "#,##0.00"), (169, "0.00E+00"), (170, "@"),
               (171, ""), (172, 'yyyy"年"mm"月"dd"日"'), (173, "[<=9999999]###-####;(###) ###-####"),
               (14, "yyyy-mm-dd")]
    xfs = [0, 1, 2, 9, 14, 15, 18, 20, 22, 45, 46, 47, 49, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173]
    s = Sheet("formats")
    values = [0.0, 1.0, 59.0, 60.0, 61.0, 25569.0, 43831.0, 43831.52425925926, 2958465.9999884,
              0.5, -3.5, 1e-7]
    for i, value in enumerate(values):
        for style, _ in enumerate(xfs):
            s.number(i, style, value, style)
    add("syn_formats.xls", "hand-built: twelve numbers from 0 to the last second of 9999, a fraction, a negative and a tiny one, each under every kind of number format — General, decimals, the built-in date and time ids 14 to 22 and 45 to 47, text, and custom codes, a built-in id re-spelled by a FORMAT record among them",
        *build([s], xfs=xfs, formats=formats))

    # dates in the 1904 date system, spelled by hand
    s = Sheet("d1904")
    s.number(0, 0, 42429.52425925926, 1)
    s.number(0, 1, 0.0, 1)
    s.number(1, 0, 43831.0, 2)
    add("syn_dates_1904.xls", "hand-built: a DATEMODE record counting dates from 1904-01-01, with date-formatted numbers", *build([s], xfs=[0, 14, 165], formats=[(165, "yyyy-mm-dd")], datemode=1))

    # containers
    stream, plan = tiny()
    out.append({"name": "syn_book_stream.xls", "note": "hand-built: the workbook in a stream named Book, the older spelling",
                "data": B.mini(stream, name="Book").out(), "plan": plan, "stream": stream})
    out.append({"name": "syn_uppercase_stream.xls", "note": "hand-built: the workbook in a stream named WORKBOOK, matched without regard to case",
                "data": B.mini(stream, name="WORKBOOK").out(), "plan": plan, "stream": stream})
    c = B.mini(stream)
    c.entry_set(1, B.SIZE_AT, "<Q", (0x1234 << 32) | len(stream))
    out.append({"name": "syn_size_high_bytes.xls", "note": "hand-built: a version 3 compound file whose stream size carries other bytes than zero in its high four, which a version 3 file does not read",
                "data": c.out(), "plan": plan, "stream": stream})
    s = Sheet("S")
    for i in range(56):
        s.rk(i, 0, float(i), B.rk_int(i))
    stream, plan = build([s])
    out.append({"name": "syn_mini_stream.xls", "note": "hand-built: a workbook of 56 numbers in the mini stream, nine mini sectors long",
                "data": B.mini(stream).out(), "plan": plan, "stream": stream})
    s = Sheet("S")
    for i in range(50):
        s.rk(i, 0, float(i), B.rk_int(i))
    stream, plan = build([s])
    out.append({"name": "syn_mini_scattered.xls", "note": "hand-built: a workbook of 50 numbers in a mini stream that lies in two regular sectors apart from each other, its mini sectors out of order",
                "data": scattered(stream).out(), "plan": plan, "stream": stream})
    stream, plan = tiny()
    out.append({"name": "syn_sector_4096.xls", "note": "hand-built: a version 4 compound file with 4096-byte sectors",
                "data": B.regular(stream, 4096).out(), "plan": plan, "stream": stream})
    out.append({"name": "syn_difat_chain.xls", "note": "hand-built: a compound file with 110 file allocation table sectors, more than the header has entries for, so a DIFAT sector chains after them",
                "data": B.difat_chain(stream).out(), "plan": plan, "stream": stream})
    out.append({"name": "syn_fragmented.xls", "note": "hand-built: a compound file whose stream's sectors are not next to each other in the file, a free sector among them, the FAT sector after the data",
                "data": B.fragmented(stream, tuple(range(11, 3, -1))).out(), "plan": plan, "stream": stream})

    # no sheet at all
    stream = B.workbook([], before=[B.xf()])
    out.append({"name": "syn_zero_sheets.xls", "note": "hand-built: a workbook of no sheet, which the reference writer cannot save",
                "data": B.mini(stream).out(), "plan": {"datemode": 0, "sheets": []}, "stream": stream,
                "sheets": []})

    # sheets of the other kinds, passed over
    chart = B.sheet([B.unknown(0x1002, b"\x00\x00")], kind=B.CHART)
    ws1 = Sheet("Ws")
    ws1.text(0, 0, "first")
    ws2 = Sheet("Hidden", visibility=1)
    ws2.number(0, 0, 2.0)
    ws3 = Sheet("日本語のシート", visibility=2)
    ws3.text(0, 0, "very hidden")
    # A dialog sheet is a worksheet's substream whose SHEETPR record says
    # so; it holds no cells and is listed like any worksheet.
    dialog = Sheet("Dialog")
    dialog.raw(B.rec(0x0081, b"\x0c\x01"))
    stream, plan = build([
        {"name": "Chart1", "kind": 2, "data": chart},
        ws1,
        {"name": "Macro1", "kind": 1, "data": B.sheet([], kind=B.MACRO)},
        ws2,
        {"name": "Module1", "kind": 6, "data": B.sheet([], kind=B.MODULE)},
        ws3,
        dialog,
    ])
    out.append({"name": "syn_sheet_kinds.xls", "note": "hand-built: BOUNDSHEET records of a chart, a macro sheet and a module between three worksheets — one hidden, one very hidden, one named in Japanese — and a dialog sheet, which holds no cells; the first three are passed over, as the format's readers do",
                "data": B.mini(stream).out(), "plan": plan, "stream": stream})

    # numbers only, no shared string table
    s = Sheet("S")
    s.number(0, 0, 2.5)
    s.rk(0, 1, 3.0, B.rk_int(3))
    add("syn_no_sst.xls", "hand-built: numbers only, no shared string table", *build([s], no_sst=True))
    for entry in out:
        entry.setdefault("sidecar", "reference")
    return out


# ── the refusal texts, as the codec composes them ────────────────────

def m_chain_names(declared_at, what, kind, sid, home, count):
    return "xls: byte %d: the %s names %s %d, and %s holds %d" % (
        declared_at, what, kind, u(sid), home, count)


def m_chain_table(declared_at, what, sid, entries):
    return "xls: byte %d: the %s names sector %d, and its allocation table holds %d entries" % (
        declared_at, what, sid, entries)


def m_chain_loops(declared_at, what, kind, sid):
    return "xls: byte %d: the %s enters %s %d a second time, so its chain loops" % (
        declared_at, what, kind, sid)


def m_chain_ends(declared_at, what, kind, needed, got):
    return "xls: byte %d: the %s needs %d %ss and its chain ends after %d" % (
        declared_at, what, needed, kind, got)


def m_size(at, what, size, held):
    return "xls: byte %d: %s declares %d bytes, and the file holds %d past its header" % (
        at, what, size, held)


def m_need(name, at, length, need):
    return "xls: %s: the %s record is %d bytes long, and its kind needs %d" % (
        wb(at), name, length, need)


# ── broken files, one fault each ─────────────────────────────────────

def broken():
    """Every broken file: dicts of its name, its note, its bytes, the
    variant the codec refuses with, and the text."""
    out = []

    def add(name, note, data, refusal, message):
        assert message.startswith("xls: "), message
        out.append({"name": name, "note": note, "data": data,
                    "refusal": refusal, "message": message})

    NOT_XLS = "xls: not an .xls workbook: the bytes do not open with a compound file's signature"
    NO_STREAM = "xls: not an .xls workbook: the compound file holds no stream named Workbook or Book"
    P, U = "ParseError", "Unsupported"

    # ── not a compound file, or a compound file that is not a workbook ──
    add("broken_zip_container.xls", "a ZIP archive, as an .xlsx workbook is one, under an .xls name", B.zip_container(), U, NOT_XLS)
    add("broken_text_bytes.xls", "plain text", b"This is not a workbook.\n" * 8, U, NOT_XLS)
    add("broken_empty.xls", "no byte at all", b"", U, NOT_XLS)
    add("broken_seven_bytes.xls", "seven bytes: shorter than the signature", b"\xd0\xcf\x11\xe0\xa1\xb1\x1a", U, NOT_XLS)
    sig = B.SIGNATURE + b"\x00" * 100
    add("broken_header_cut.xls", "the signature, then a header cut short at 108 bytes", sig, P,
        "xls: byte 108: the file ends inside the compound file's 512-byte header")

    stream, plan = tiny()
    c = B.mini(stream)
    c.set(B.ORDER_AT, "H", 0xFEFF)
    add("broken_byte_order.xls", "a compound file declaring the big-endian byte order", c.out(), U,
        "xls: byte 28: the compound file declares byte order 0xFEFF, and this reader reads the little-endian one, 0xFFFE")
    c = B.mini(stream)
    c.set(B.VERSION_AT, "H", 5)
    add("broken_version_5.xls", "a compound file declaring version 5", c.out(), U,
        "xls: byte 26: the compound file declares version 5 with 2^9-byte sectors, and this reader reads version 3 with 512-byte sectors and version 4 with 4096-byte ones")
    c = B.mini(stream)
    c.set(B.SHIFT_AT, "H", 12)
    add("broken_sector_shift.xls", "a version 3 compound file declaring 4096-byte sectors", c.out(), U,
        "xls: byte 26: the compound file declares version 3 with 2^12-byte sectors, and this reader reads version 3 with 512-byte sectors and version 4 with 4096-byte ones")
    c = B.mini(stream)
    c.set(B.MINI_SHIFT_AT, "H", 7)
    add("broken_mini_shift.xls", "a compound file declaring 128-byte mini sectors", c.out(), U,
        "xls: byte 32: the compound file declares 2^7-byte mini sectors, and this reader reads 64-byte ones")
    add("broken_no_workbook.xls", "a compound file holding one stream, named Data", B.mini(stream, name="Data").out(), U, NO_STREAM)
    for name, note, length in [
        ("broken_entry_name_odd.xls", "a directory entry spelling its name in 7 bytes", 7),
        ("broken_entry_name_long.xls", "a directory entry spelling its name in 66 bytes, past the 64 an entry holds", 66)]:
        c = B.mini(stream)
        c.entry_set(2, 0, "128s", B.entry("Odd", 2, start=0, size=10, name_length=length))
        add(name, note + ", beside the workbook's", c.out(), P,
            "xls: byte %d: directory entry 2 spells its name in %d bytes, neither an even count from 2 to 64 nor none"
            % (c.dir_off + 128 * 2 + B.NAME_LENGTH_AT, length))

    # ── the file allocation table ──
    c = B.mini(stream)
    c.set(B.DIFAT_AT, "I", 99)
    add("broken_fat_sector_out.xls", "the header naming sector 99 as its file allocation table's, in a file of 4 sectors", c.out(), P,
        "xls: byte 76: the header names sector 99 as one of the file allocation table's, and the file holds 4")
    c = B.mini(stream)
    c.set(B.DIFAT_AT, "I", B.ENDC)
    add("broken_fat_sector_marker.xls", "the header naming no file allocation table sector at all, where the file has one", c.out(), P,
        m_chain_table(48, "directory", 3, 0))
    c = B.difat_chain(stream)
    c.set(B.DIFAT_AT + 4, "I", c.get(B.DIFAT_AT, "I"))
    add("broken_fat_named_twice.xls", "the header naming the same file allocation table sector twice", c.out(), P,
        "xls: byte 80: the header names sector %d as one of the file allocation table's a second time" % c.get(B.DIFAT_AT, "I"))
    c = B.difat_chain(stream)
    c.set(B.DIFAT_FIRST_AT, "I", 9999)
    add("broken_difat_out.xls", "the DIFAT chain naming a sector the file does not hold", c.out(), P,
        "xls: byte 68: the file allocation table's chain names sector 9999, and the file holds %d" % ((len(c.data) - 512) // 512))
    c = B.difat_chain(stream)
    difat_sector = 8 + 110
    link_at = 512 + difat_sector * 512 + 127 * 4
    c.set(link_at, "I", difat_sector)
    add("broken_difat_loop.xls", "a DIFAT sector chaining to itself", c.out(), P,
        "xls: byte %d: the file allocation table's chain enters sector %d a second time, so it loops" % (link_at, difat_sector))

    # ── the directory ──
    c = B.mini(stream)
    c.set(B.DIR_FIRST_AT, "I", 99)
    add("broken_directory_out.xls", "the header placing the directory at sector 99, in a file of 4 sectors", c.out(), P,
        "xls: byte 48: the header places the directory at sector 99, and the file holds 4")
    c = B.mini(stream)
    c.set(B.DIR_FIRST_AT, "I", B.ENDC)
    add("broken_directory_end.xls", "the header placing the directory at an end-of-chain marker", c.out(), P,
        "xls: byte 48: the header places the directory at sector 4294967294, and the file holds 4")
    c = B.mini(stream)
    c.fat(3, 3)
    add("broken_directory_loop.xls", "the directory's sector chained to itself", c.out(), P,
        m_chain_loops(c.fat_off + 4 * 3, "directory", "sector", 3))
    c = B.mini(stream)
    c.cut(2000)
    add("broken_file_truncated.xls", "a sound file cut at 2000 bytes, inside its file allocation table's sector", c.out(), P,
        "xls: byte 76: the header names sector 2 as one of the file allocation table's, and the file holds 2")

    # ── the workbook stream's entry and chain ──
    def entry_at(c, index, field):
        return c.dir_off + 128 * index + field

    c = B.mini(stream)
    c.entry_set(1, B.SIZE_AT, "<Q", 999999)
    add("broken_stream_size_past.xls", "the Workbook stream declaring 999999 bytes", c.out(), P,
        m_size(entry_at(c, 1, B.SIZE_AT), "the Workbook stream", 999999, len(c.data) - 512))
    c = B.regular(stream, 4096)
    c.entry_set(1, B.SIZE_AT, "<Q", 1 << 63)
    add("broken_stream_size_negative.xls", "a version 4 compound file whose Workbook stream declares a size past 63 bits", c.out(), P,
        m_size(entry_at(c, 1, B.SIZE_AT), "the Workbook stream", 1 << 63, len(c.data) - 512))
    c = B.regular(stream)
    c.entry_set(1, B.START_AT, "<I", 99)
    add("broken_stream_start_out.xls", "the Workbook stream starting at sector 99, in a file of 10 sectors", c.out(), P,
        m_chain_names(entry_at(c, 1, B.START_AT), "Workbook stream", "sector", 99, "the file", c.data_count + 2))
    c = B.regular(stream)
    c.entry_set(1, B.START_AT, "<I", B.ENDC)
    add("broken_stream_start_end.xls", "the Workbook stream starting at an end-of-chain marker", c.out(), P,
        m_chain_names(entry_at(c, 1, B.START_AT), "Workbook stream", "sector", B.ENDC, "the file", c.data_count + 2))
    c = B.regular(stream)
    c.fat(c.data_count - 2, B.ENDC)
    add("broken_stream_chain_ends.xls", "the Workbook stream's chain ending one sector early", c.out(), P,
        m_chain_ends(c.fat_off + 4 * (c.data_count - 2), "Workbook stream", "sector", c.data_count, c.data_count - 1))
    c = B.regular(stream)
    c.fat(3, 500)
    add("broken_stream_chain_out.xls", "the Workbook stream's chain naming sector 500, in a file of 10 sectors", c.out(), P,
        m_chain_names(c.fat_off + 4 * 3, "Workbook stream", "sector", 500, "the file", c.data_count + 2))
    c = B.regular(stream)
    c.fat(3, B.FATSEC)
    add("broken_stream_chain_marker.xls", "the Workbook stream's chain naming a FAT sector marker", c.out(), P,
        m_chain_names(c.fat_off + 4 * 3, "Workbook stream", "sector", B.FATSEC, "the file", c.data_count + 2))
    c = B.regular(stream)
    c.fat(4, 2)
    add("broken_stream_chain_loop.xls", "the Workbook stream's chain coming back to a sector it entered", c.out(), P,
        m_chain_loops(c.fat_off + 4 * 4, "Workbook stream", "sector", 2))

    # ── the mini stream ──
    c = B.mini(stream)
    c.entry_set(0, B.START_AT, "<I", B.ENDC)
    c.entry_set(0, B.SIZE_AT, "<Q", 0)
    add("broken_mini_no_root.xls", "a short Workbook stream in a compound file whose root entry holds no mini stream", c.out(), P,
        m_chain_names(entry_at(c, 1, B.START_AT), "Workbook stream", "mini sector", 0, "the mini stream", 0))
    c = B.mini(stream)
    c.entry_set(1, B.START_AT, "<I", 60)
    add("broken_mini_sector_out.xls", "the Workbook stream naming mini sector 60, where the mini stream holds %d" % c.mini_count, c.out(), P,
        m_chain_names(entry_at(c, 1, B.START_AT), "Workbook stream", "mini sector", 60, "the mini stream", c.mini_count))
    c = B.mini(stream)
    c.mini_fat(0, B.ENDC)
    add("broken_mini_chain_ends.xls", "the Workbook stream's mini chain ending after its first mini sector", c.out(), P,
        m_chain_ends(c.minifat_off, "Workbook stream", "mini sector", c.mini_count, 1))
    c = B.mini(stream)
    c.mini_fat(1, 0)
    add("broken_mini_chain_loop.xls", "the Workbook stream's mini chain coming back to its first mini sector", c.out(), P,
        m_chain_loops(c.minifat_off + 4, "Workbook stream", "mini sector", 0))
    c = B.mini(stream)
    c.set(B.MINIFAT_FIRST_AT, "I", 99)
    add("broken_mini_table_out.xls", "the header placing the mini stream's table at sector 99, in a file of 4 sectors", c.out(), P,
        "xls: byte 60: the header places the mini stream's table at sector 99, and the file holds 4")
    c = B.mini(stream)
    c.set(B.NMINIFAT_AT, "I", 2)
    add("broken_mini_table_ends.xls", "the header counting two mini table sectors, where the chain holds one", c.out(), P,
        m_chain_ends(c.fat_off + 4 * 1, "mini stream's table", "sector", 2, 1))
    c = B.mini(stream)
    c.set(B.MINIFAT_FIRST_AT, "I", B.ENDC)
    c.set(B.NMINIFAT_AT, "I", 0)
    add("broken_mini_table_missing.xls", "a short Workbook stream in a compound file whose header counts no mini table sector at all", c.out(), P,
        "xls: byte %d: the Workbook stream names mini sector 0, and its allocation table holds 0 entries"
        % entry_at(c, 1, B.START_AT))
    c = B.mini(stream)
    c.entry_set(0, B.SIZE_AT, "<Q", 999999)
    add("broken_root_size_past.xls", "the root entry's stream declaring 999999 bytes", c.out(), P,
        m_size(entry_at(c, 0, B.SIZE_AT), "the root entry's stream", 999999, len(c.data) - 512))
    c = B.mini(stream)
    c.entry_set(0, B.START_AT, "<I", 77)
    c.entry_set(0, B.SIZE_AT, "<Q", 900)
    add("broken_root_start_out.xls", "the root entry's stream starting at sector 77, in a file of 4 sectors", c.out(), P,
        m_chain_names(entry_at(c, 0, B.START_AT), "root entry's stream", "sector", 77, "the file", 4))
    c = B.mini(stream)
    c.entry_set(0, B.SIZE_AT, "<Q", 900)
    c.fat(0, 0)
    add("broken_root_chain_loop.xls", "the root entry's stream chained back to its own first sector", c.out(), P,
        m_chain_loops(c.fat_off, "root entry's stream", "sector", 0))

    # ── the workbook stream's records ──
    add("broken_stream_empty.xls", "a Workbook stream of no byte", B.mini(b"").out(), P,
        "xls: byte 0 of the workbook stream: the stream ends inside a record header, which needs 4 bytes")
    add("broken_stream_header_cut.xls", "a Workbook stream of two bytes: cut inside its first record's header", B.mini(b"\x09\x08").out(), P,
        "xls: byte 0 of the workbook stream: the stream ends inside a record header, which needs 4 bytes")
    add("broken_stream_record_cut.xls", "a Workbook stream of 30 bytes: cut inside a record's body", B.mini(stream[:30]).out(), P,
        "xls: byte 20 of the workbook stream: the record claims 20 bytes and the stream holds 6 after its header")

    first = B.bof()
    add("broken_no_bof.xls", "a stream opening with an EOF record", B.mini(B.eof() + stream).out(), P,
        "xls: byte 0 of the workbook stream: record EOF stands where a BOF record should")
    add("broken_unknown_bof.xls", "a stream opening with a record of an id the format does not give the workbook globals", B.mini(B.unknown(0x1234) + stream).out(), P,
        "xls: byte 0 of the workbook stream: record 0x1234 stands where a BOF record should")
    add("broken_biff5.xls", "a BOF record declaring BIFF version 0x0500, as a BIFF5 file does", B.mini(B.bof(vers=0x0500) + stream[len(first):]).out(), U,
        "xls: byte 4 of the workbook stream: the BOF record at byte 0 declares BIFF version 0x0500, and this reader reads BIFF8's 0x0600")
    add("broken_biff4.xls", "a stream opening with the BOF record id of BIFF4", B.mini(B.rec(0x0409, struct.pack("<HHH", 0x0DBB, 0x07CC, 0x0005)) + stream[len(first):]).out(), U,
        "xls: byte 0 of the workbook stream: the BOF record's id 0x0409 is BIFF4's, and this reader reads BIFF8's 0x0809")
    add("broken_biff3.xls", "a stream opening with the BOF record id of BIFF3", B.mini(B.rec(0x0209, struct.pack("<HHH", 0x0DBB, 0x07CC, 0x0005)) + stream[len(first):]).out(), U,
        "xls: byte 0 of the workbook stream: the BOF record's id 0x0209 is BIFF3's, and this reader reads BIFF8's 0x0809")
    add("broken_biff2.xls", "a stream opening with the BOF record id of BIFF2", B.mini(B.rec(0x0009, struct.pack("<H", 0x0005)) + stream[len(first):]).out(), U,
        "xls: byte 0 of the workbook stream: the BOF record's id 0x0009 is BIFF2's, and this reader reads BIFF8's 0x0809")
    add("broken_bof_short.xls", "a BOF record of two bytes", B.mini(B.bof(length=2) + stream[len(first):]).out(), P,
        m_need("BOF", 0, 2, 4))
    add("broken_bof_type.xls", "a stream opening with a worksheet's BOF record", B.mini(B.bof(B.WORKSHEET) + stream[len(first):]).out(), P,
        "xls: byte 6 of the workbook stream: the BOF record at byte 0 declares substream type 0x0010, not the workbook globals' 0x0005")
    pass_record = B.filepass()
    stream2, _ = tiny(before=[pass_record])
    add("broken_filepass.xls", "a FILEPASS record after the BOF record: an encrypted workbook", B.mini(stream2).out(), U,
        "xls: %s: the workbook is encrypted (a FILEPASS record), and this reader decrypts nothing" % wb(offset(stream2, pass_record)))
    mode = B.datemode(2)
    stream2, _ = tiny(before=[mode])
    add("broken_datemode.xls", "a DATEMODE record holding 2", B.mini(stream2).out(), P,
        "xls: %s: the DATEMODE record at byte %d holds 2, neither 0 nor 1" % (wb(offset(stream2, mode) + 4), offset(stream2, mode)))
    stream2 = B.bof() + B.xf()
    add("broken_globals_no_eof.xls", "a workbook globals that ends before its EOF record", B.mini(stream2).out(), P,
        "xls: %s: the workbook globals end before their EOF record" % wb(len(stream2)))
    stream2 = B.bof() + B.xf() + B.sheet([])
    add("broken_bof_in_globals.xls", "a sheet's BOF record where the workbook globals' EOF record should be", B.mini(stream2).out(), P,
        "xls: %s: a BOF record stands where the workbook globals' EOF record should end them" % wb(offset(stream2, B.bof(B.WORKSHEET))))
    short_xf = B.xf(length=10)
    stream2, _ = tiny(before=[short_xf])
    add("broken_xf_short.xls", "an XF record of ten bytes", B.mini(stream2).out(), P,
        m_need("XF", offset(stream2, short_xf), 10, 20))
    for name, note, body, message, delta in [
        ("broken_format_short.xls", "a FORMAT record holding its index and no code", struct.pack("<H", 164),
         "the FORMAT record at byte %d ends inside its character count", 6),
        ("broken_format_flags.xls", "a FORMAT record holding its index, a count of no characters, and no flags",
         struct.pack("<HH", 164, 0), "the FORMAT record at byte %d ends inside its flags", 8),
        ("broken_format_cut.xls", "a FORMAT record whose UTF-16 code counts two characters and holds three bytes",
         struct.pack("<HH", 164, 2) + b"\x01\x00\x30\x00",
         "the characters of the FORMAT record at byte %d are cut inside a character at the record's end", 11),
        ("broken_format_count.xls", "a FORMAT record whose code counts three characters and holds two",
         struct.pack("<HH", 164, 3) + b"\x00ab", "the FORMAT record at byte %d ends inside its data", 11)]:
        rec_ = B.rec(B.FORMAT, body)
        stream2, _ = tiny(before=[rec_])
        at = offset(stream2, rec_)
        add(name, note, B.mini(stream2).out(), P, "xls: %s: %s" % (wb(at + delta), message % at))

    # ── the shared string table ──
    def sst_stream(pieces, cells=None, **kw):
        s = Sheet("S")
        s.raw(*(cells or [B.labelsst(0, 0, 0, 0)]))
        return build([s], no_sst=True, after=[B.sst_raw(pieces)], **kw)[0]

    counts = struct.pack("<ii", 1, 1)
    body = counts + struct.pack("<HB", 10, 0) + b"abc"
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_cut.xls", "a shared string of ten characters, three of which the record holds", B.mini(stream2).out(), P,
        "xls: %s: the 1st string of the shared string table ends inside its data" % wb(at + 4 + len(body)))
    first_piece = counts + struct.pack("<HB", 2, 1) + b"\x30"
    second_piece = b"\x01\x00\x30"
    stream2 = sst_stream([first_piece, second_piece])
    at = offset(stream2, B.rec(B.SST, first_piece))
    add("broken_sst_odd_cut.xls", "a UTF-16 shared string cut by a CONTINUE record inside a character", B.mini(stream2).out(), P,
        "xls: %s: the characters of the 1st string of the shared string table are cut inside a character at the record's end" % wb(at + 4 + len(first_piece) - 1))
    body = counts + struct.pack("<HB", 1, 1) + b"\x00\xd8"
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_utf16.xls", "a shared string holding a lone high surrogate", B.mini(stream2).out(), P,
        "xls: %s: the characters of the 1st string of the shared string table are not well-formed UTF-16" % wb(at + 4 + 11))
    body = counts + struct.pack("<HBi", 1, 5, -4)
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_phonetic_negative.xls", "a shared string claiming -4 bytes of phonetic data", B.mini(stream2).out(), P,
        "xls: %s: the 1st string of the shared string table claims -4 bytes of phonetic data" % wb(at + 4 + 11))
    body = counts + struct.pack("<HBH", 2, 8, 2) + b"ab" + b"\x00\x00\x00\x00" + b"\x01\x00"
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_runs_cut.xls", "a shared string claiming two rich-text runs, the second cut by two bytes", B.mini(stream2).out(), P,
        "xls: %s: the 1st string of the shared string table ends inside its rich-text runs" % wb(at + 4 + len(body) - 2))
    body = counts + struct.pack("<HBH", 2, 8, 2) + b"ab" + b"\x00\x00\x00\x00"
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_runs_missing.xls", "a shared string claiming two rich-text runs and holding one", B.mini(stream2).out(), P,
        "xls: %s: the 1st string of the shared string table ends inside its data" % wb(at + 4 + len(body)))
    body = counts + struct.pack("<HBi", 1, 4, 10) + b"a"
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_phonetic_missing.xls", "a shared string claiming ten bytes of phonetic data and holding none", B.mini(stream2).out(), P,
        "xls: %s: the 1st string of the shared string table ends inside its data" % wb(at + 4 + len(body)))
    body = struct.pack("<ii", 1, -1)
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_negative.xls", "a shared string table counting -1 strings", B.mini(stream2).out(), P,
        "xls: %s: the shared string table declares a string count of -1" % wb(at + 8))
    one = B.string_item("one")
    two = B.string_item("two")
    body = struct.pack("<ii", 2, 3) + one[0] + one[1][0][0] + two[0] + two[1][0][0]
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_fewer.xls", "a shared string table counting three strings and holding two", B.mini(stream2).out(), P,
        "xls: %s: the 3rd string of the shared string table ends inside its character count" % wb(at + 4 + len(body)))
    body = struct.pack("<ii", 2, 1) + one[0] + one[1][0][0] + two[0] + two[1][0][0]
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_more.xls", "a shared string table counting one string and holding two", B.mini(stream2).out(), P,
        "xls: %s: the shared string table declares a string count of 1 and holds more" % wb(at + 4 + 14))
    body = struct.pack("<i", 1)
    stream2 = sst_stream([body])
    at = offset(stream2, B.rec(B.SST, body))
    add("broken_sst_short.xls", "an SST record holding one of its two counts", B.mini(stream2).out(), P,
        "xls: %s: the shared string table ends inside its counts" % wb(at + 4))
    table = B.sst_records([B.string_item("text")])
    stream2, _ = tiny()
    at = offset(stream2, table)
    cut = stream2[:at + len(table)] + B.rec(B.CONTINUE, b"\x00" * 20)[:2] + struct.pack("<H", 9999) + stream2[at + len(table):]
    add("broken_continue_cut.xls", "a CONTINUE record after the shared string table, claiming more than the stream holds", B.mini(cut).out(), P,
        "xls: %s: the record claims 9999 bytes and the stream holds %d after its header" % (wb(at + len(table)), len(cut) - (at + len(table)) - 4))

    # ── a sheet's cells ──
    for name, note, index, spelled in [
        ("broken_labelsst_index.xls", "a LABELSST record naming shared string 5, where the table holds one", 5, "5"),
        ("broken_labelsst_negative.xls", "a LABELSST record naming shared string -1", -1, "-1")]:
        bad = B.labelsst(0, 0, 0, index)
        s = Sheet("S")
        s.raw(bad)
        s.text(1, 0, "one")
        stream2, _ = build([s])
        at = offset(stream2, bad)
        add(name, note, B.mini(stream2).out(), P,
            "xls: %s: the LABELSST record at byte %d names shared string %s, and the table holds 1" % (wb(at + 10), at, spelled))
    bad = B.number(1, 0, 3, 1.5)
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_xf_index.xls", "a cell naming XF 3, where the workbook holds one XF record", B.mini(stream2).out(), P,
        "xls: %s: the NUMBER record at byte %d names XF 3, and the workbook holds 1" % (wb(at + 8), at))
    bad = B.rk_record(1, 0, 0, B.rk_int(3))
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s], xfs=[200])
    at = offset(stream2, bad)
    add("broken_format_undefined.xls", "an XF record naming number format 200, which no FORMAT record defines", B.mini(stream2).out(), P,
        "xls: %s: the RK record at byte %d names number format 200, which no FORMAT record defines" % (wb(at + 8), at))
    bad = B.number(0, 256, 0, 1.0)
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_col_256.xls", "a NUMBER record placing a cell in column 256", B.mini(stream2).out(), P,
        "xls: %s: the NUMBER record at byte %d places a cell in column 256, and a sheet holds 256" % (wb(at + 6), at))
    bad = B.mulrk(0, 254, [(0, B.rk_int(1)), (0, B.rk_int(2)), (0, B.rk_int(3))])
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_mulrk_col_256.xls", "a MULRK run of three cells from column 254", B.mini(stream2).out(), P,
        "xls: %s: the MULRK record at byte %d places a cell in column 256, and a sheet holds 256" % (wb(at + 6), at))
    for name, rec_, need, what in [
            ("broken_number_short.xls", B.number(1, 0, 0, 1.5, length=10), 14, "NUMBER"),
            ("broken_rk_short.xls", B.rec(B.RK, struct.pack("<HHH", 1, 0, 0)), 10, "RK"),
            ("broken_blank_short.xls", B.blank(1, 0, 0, length=4), 6, "BLANK"),
            ("broken_labelsst_short.xls", B.labelsst(1, 0, 0, 0, length=6), 10, "LABELSST"),
            ("broken_boolerr_short.xls", B.boolerr(1, 0, 0, 1, 0, length=7), 8, "BOOLERR"),
            ("broken_formula_short.xls", B.formula(1, 0, 0, 2.5, length=10), 14, "FORMULA"),
            ("broken_mulrk_short.xls", B.rec(B.MULRK, struct.pack("<HHH", 1, 0, 0xFFFF)), 12, "MULRK"),
            ("broken_mulblank_short.xls", B.mulblank(1, 0, [0], length=7), 8, "MULBLANK")]:
        s = Sheet("S")
        s.raw(rec_)
        stream2, _ = build([s])
        add(name, "a %s record of %d bytes" % (what, len(rec_) - 4), B.mini(stream2).out(), P,
            m_need(what, offset(stream2, rec_), len(rec_) - 4, need))
    bad = B.mulrk(1, 0, [(0, B.rk_int(1)), (0, B.rk_int(2))], length=17)
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    add("broken_mulrk_length.xls", "a MULRK record of 17 bytes: five past its two cells", B.mini(stream2).out(), P,
        "xls: %s: the MULRK record is 17 bytes long, and its kind needs 6 bytes and 6 more for every cell" % wb(offset(stream2, bad)))
    bad = B.mulrk(1, 0, [(0, B.rk_int(1)), (0, B.rk_int(2))], last=5)
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_mulrk_last.xls", "a MULRK record holding two cells from column 0 and naming column 5 as its last", B.mini(stream2).out(), P,
        "xls: %s: the MULRK record at byte %d holds 2 cells from column 0, and names column 5 as its last" % (wb(at + 4 + len(bad) - 4 - 2), at))
    bad = B.mulblank(1, 0, [0, 0], length=9)
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    add("broken_mulblank_length.xls", "a MULBLANK record of 9 bytes: one past its row, its first column and its two styles", B.mini(stream2).out(), P,
        "xls: %s: the MULBLANK record is 9 bytes long, and its kind needs 6 bytes and 2 more for every cell" % wb(offset(stream2, bad)))
    bad = B.mulblank(1, 0, [0, 0], last=4)
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_mulblank_last.xls", "a MULBLANK record holding two cells from column 0 and naming column 4 as its last", B.mini(stream2).out(), P,
        "xls: %s: the MULBLANK record at byte %d holds 2 cells from column 0, and names column 4 as its last" % (wb(at + 4 + len(bad) - 4 - 2), at))
    for name, note, rec_, message, delta in [
        ("broken_boolerr_flag.xls", "a BOOLERR record whose last byte is 2", B.boolerr(0, 0, 0, 1, 2),
         "the BOOLERR record at byte %d holds 2, neither a boolean's 0 nor an error's 1", 7),
        ("broken_boolerr_value.xls", "a BOOLERR record holding 2 as a boolean", B.boolerr(0, 0, 0, 2, 0),
         "the BOOLERR record at byte %d holds 2 as a boolean, neither 0 nor 1", 6),
        ("broken_error_code.xls", "a BOOLERR record carrying error code 0x0001", B.boolerr(0, 0, 0, 1, 1),
         "the BOOLERR record at byte %d carries error code 0x0001, which the format does not name", 6)]:
        s = Sheet("S")
        s.raw(rec_)
        stream2, _ = build([s])
        at = offset(stream2, rec_)
        add(name, note, B.mini(stream2).out(), P, "xls: %s: %s" % (wb(at + 4 + delta), message % at))
    for name, note, kind_byte, tail, message, delta in [
        ("broken_formula_kind.xls", "a formula caching a value of kind 7", 7, b"\x00",
         "the FORMULA record at byte %d caches a value of kind 7, which the format does not name", 0),
        ("broken_formula_bool.xls", "a formula caching a boolean of 2", 1, b"\x02",
         "the FORMULA record at byte %d caches a boolean of 2, neither 0 nor 1", 2),
        ("broken_formula_error.xls", "a formula caching error code 0x0005", 2, b"\x05",
         "the FORMULA record at byte %d carries error code 0x0005, which the format does not name", 2)]:
        rec_ = B.rec(B.FORMULA, struct.pack("<HHH", 0, 0, 0) + bytes([kind_byte, 0, tail[0], 0, 0, 0, 0xFF, 0xFF]) + struct.pack("<HIH", 0, 0, 0))
        s = Sheet("S")
        s.raw(rec_)
        stream2, _ = build([s])
        at = offset(stream2, rec_)
        add(name, note, B.mini(stream2).out(), P, "xls: %s: %s" % (wb(at + 4 + 6 + delta), message % at))
    s = Sheet("S")
    s.raw(B.formula(0, 0, 0, ("string",)), B.number(1, 0, 0, 1.5))
    stream2, _ = build([s])
    at = offset(stream2, B.formula(0, 0, 0, ("string",)))
    add("broken_formula_no_string.xls", "a formula whose cached value is a string, followed by a NUMBER record", B.mini(stream2).out(), P,
        "xls: %s: record NUMBER follows the FORMULA record at byte %d, whose cached value is a string, where a STRING record should" % (wb(at + 26), at))
    bad = B.label(0, 0, 0, "abc", cch=10)
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_label_cut.xls", "a LABEL record counting ten characters and holding three", B.mini(stream2).out(), P,
        "xls: %s: the LABEL record at byte %d ends inside its data" % (wb(at + 4 + len(bad) - 4), at))
    bad = B.rec(B.LABEL, struct.pack("<HHHH", 0, 0, 0, 2) + b"\x09")
    s = Sheet("S")
    s.raw(bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_label_flags_cut.xls", "a LABEL record naming rich-text runs and holding no count of them", B.mini(stream2).out(), P,
        "xls: %s: the LABEL record at byte %d ends inside its rich-text run count" % (wb(at + 13), at))
    pieces = [struct.pack("<HB", 5, 0) + b"ab"]
    bad = B.rec(B.STRING, pieces[0])
    s = Sheet("S")
    s.raw(B.formula(0, 0, 0, ("string",)), bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_string_cut.xls", "a STRING record counting five characters and holding two", B.mini(stream2).out(), P,
        "xls: %s: the STRING record at byte %d ends inside its data" % (wb(at + 4 + 5), at))
    pieces = [struct.pack("<HB", 2, 1) + b"\x30", b"\x01\x00\x30"]
    bad = B.raw_continued(B.STRING, pieces)
    s = Sheet("S")
    s.raw(B.formula(0, 0, 0, ("string",)), bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_string_odd_cut.xls", "a UTF-16 STRING record cut by a CONTINUE record inside a character", B.mini(stream2).out(), P,
        "xls: %s: the characters of the STRING record at byte %d are cut inside a character at the record's end" % (wb(at + 7), at))
    bad = B.rec(B.STRING, struct.pack("<HB", 1, 1) + b"\x00\xd8")
    s = Sheet("S")
    s.raw(B.formula(0, 0, 0, ("string",)), bad)
    stream2, _ = build([s])
    at = offset(stream2, bad)
    add("broken_string_utf16.xls", "a STRING record holding a lone high surrogate", B.mini(stream2).out(), P,
        "xls: %s: the characters of the STRING record at byte %d are not well-formed UTF-16" % (wb(at + 4 + 3), at))

    # ── the sheets' places and substreams ──
    stream2, _ = tiny(sheet_kw={"position": 99999})
    bounds = B.boundsheet(99999, "S")
    at = offset(stream2, bounds)
    add("broken_sheet_position.xls", "a BOUNDSHEET record placing its sheet at byte 99999", B.mini(stream2).out(), P,
        'xls: %s: the BOUNDSHEET record at byte %d places the sheet "S" at byte 99999, and the stream holds %d bytes' % (wb(at + 4), at, len(stream2)))
    xf_record = B.xf()
    stream2, _ = tiny(sheet_kw={"position": 20})
    add("broken_sheet_bof.xls", "a BOUNDSHEET record placing its sheet at an XF record", B.mini(stream2).out(), P,
        "xls: %s: record XF stands where a BOF record should" % wb(20))
    stream2, _ = tiny(sheet_kw={"bof_kind": B.CHART})
    add("broken_sheet_type.xls", "a sheet's BOF record opening a chart's substream", B.mini(stream2).out(), P,
        "xls: %s: the BOF record at byte %d declares substream type 0x0020, not a worksheet's 0x0010" % (wb(offset(stream2, B.bof(B.CHART)) + 6), offset(stream2, B.bof(B.CHART))))
    stream2, _ = tiny(sheet_kw={"bof_vers": 0x0500})
    add("broken_sheet_biff5.xls", "a sheet's BOF record declaring BIFF version 0x0500", B.mini(stream2).out(), U,
        "xls: %s: the BOF record at byte %d declares BIFF version 0x0500, and this reader reads BIFF8's 0x0600" % (wb(offset(stream2, B.bof(B.WORKSHEET, 0x0500)) + 4), offset(stream2, B.bof(B.WORKSHEET, 0x0500))))
    stream2, _ = tiny(sheet_kw={"with_eof": False})
    add("broken_sheet_no_eof.xls", "a sheet that ends with the stream, before its EOF record", B.mini(stream2).out(), P,
        "xls: %s: sheet 0 ends before its EOF record" % wb(len(stream2)))
    embedded = B.bof(B.CHART)
    s = Sheet("S", with_eof=False)
    s.raw(embedded, B.unknown(0x1002, b"\x00\x00"))
    stream2, _ = build([s])
    add("broken_embedded_no_eof.xls", "a chart's substream embedded in a sheet, with no EOF record to end it", B.mini(stream2).out(), P,
        "xls: %s: the substream embedded at byte %d ends before its EOF record" % (wb(len(stream2)), offset(stream2, embedded)))
    stream2, _ = tiny(sheet_kw={"spell": {"cch": 20}})
    at = first_record(stream2, B.BOUNDSHEET)
    add("broken_boundsheet_name_cut.xls", "a BOUNDSHEET record counting twenty characters of name and holding one", B.mini(stream2).out(), P,
        "xls: %s: the BOUNDSHEET record at byte %d ends inside its data" % (wb(at + 13), at))
    stream2, _ = tiny(sheet_kw={"spell": {"chars": b"\x01\x01\x00\xd8"}})
    at = first_record(stream2, B.BOUNDSHEET)
    add("broken_boundsheet_name_utf16.xls", "a BOUNDSHEET record naming its sheet by a lone high surrogate", B.mini(stream2).out(), P,
        "xls: %s: the characters of the BOUNDSHEET record at byte %d are not well-formed UTF-16" % (wb(at + 12), at))
    return out
