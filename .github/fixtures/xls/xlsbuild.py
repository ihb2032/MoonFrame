"""The encoder the hand-built fixtures are made with: BIFF8 records, record
by record, and the compound file around them, sector by sector. Nothing
here reads a file; the generator writes with it and the reference readers
judge the result. Every layout the format allows is spelled explicitly —
regular sectors, the mini stream and its table, 512- and 4096-byte
sectors, a fragmented chain, a DIFAT chain — and every fault a broken
fixture carries is a patch applied to a sound file, one fault a file.

Record ids are the format's own:

    BOF 0x0809    EOF 0x000A     FORMULA 0x0006    DATEMODE 0x0022
    FILEPASS 0x002F             CONTINUE 0x003C   BOUNDSHEET 0x0085
    MULRK 0x00BD  MULBLANK 0x00BE                  XF 0x00E0
    SST 0x00FC    LABELSST 0x00FD                  BLANK 0x0201
    NUMBER 0x0203 LABEL 0x0204   BOOLERR 0x0205    STRING 0x0207
    RK 0x027E     FORMAT 0x041E  INDEX 0x020B     DBCELL 0x00D7
"""
import struct
import zlib

BOF, EOF, FORMULA, DATEMODE, FILEPASS, CONTINUE, BOUNDSHEET = (
    0x0809, 0x000A, 0x0006, 0x0022, 0x002F, 0x003C, 0x0085)
MULRK, MULBLANK, XF, SST, LABELSST, BLANK, NUMBER, LABEL, BOOLERR, RK = (
    0x00BD, 0x00BE, 0x00E0, 0x00FC, 0x00FD, 0x0201, 0x0203, 0x0204, 0x0205, 0x027E)
STRING, FORMAT, INDEX, DBCELL, DIMENSIONS, ROWREC = (
    0x0207, 0x041E, 0x020B, 0x00D7, 0x0200, 0x0208)
ARRAY, SHRFMLA, TABLEOP, TABLEOP2 = 0x0221, 0x04BC, 0x0236, 0x0037

#: The kinds of substream a BOF record opens.
GLOBALS, WORKSHEET, CHART, MACRO, MODULE = 0x0005, 0x0010, 0x0020, 0x0040, 0x0006

#: The text a sheet shows for each error code the reference reader knows.
ERRORS = {"#NULL!": 0x00, "#DIV/0!": 0x07, "#VALUE!": 0x0F, "#REF!": 0x17,
          "#NAME?": 0x1D, "#NUM!": 0x24, "#N/A": 0x2A}

#: The eighth error code the format names, #GETTING_DATA, for which the
#: reference reader has no text.
GETTING_DATA = 0x2B

#: The most bytes a record's body holds.
PIECE = 8224


# ── records ──────────────────────────────────────────────────────────

def rec(rid, body=b""):
    return struct.pack("<HH", rid, len(body)) + body


def bof(kind=GLOBALS, vers=0x0600, rid=BOF, length=None):
    """A BOF record: the BIFF version, the kind of substream it opens, a
    build, a year, and two fields this reader never reads. `length` cuts
    the body short, for a broken file."""
    body = struct.pack("<4H2I", vers, kind, 0x0DBB, 0x07CC, 0, 0x06)
    return rec(rid, body if length is None else body[:length])


def eof():
    return rec(EOF)


def datemode(mode):
    return rec(DATEMODE, struct.pack("<H", mode))


def filepass():
    """A FILEPASS record as a writer of the weak encryption spells it:
    the kind, a key and a hash."""
    return rec(FILEPASS, struct.pack("<HHH", 0, 0x1FA0, 0x2CE6))


def xf(ifmt=0, font=0, length=None):
    """An XF record of BIFF8's twenty bytes: a font, a number format, and
    the rest the way a plain cell style spells it."""
    body = struct.pack("<HHHBBBBIIH", font, ifmt, 0xFFF5, 0x20, 0x00, 0x00, 0xF4,
                       0, 0, 0)
    return rec(XF, body if length is None else body[:length])


def boundsheet(position, name, visibility=0, kind=0, cch=None, flag=None, chars=None):
    """A BOUNDSHEET record: the sheet's place in the stream, its
    visibility, its kind, and its name as a one-byte-count string. `chars`
    gives the count, the flag and the characters as they are."""
    head = struct.pack("<iBB", position, visibility, kind)
    if chars is not None:
        return rec(BOUNDSHEET, head + chars)
    wide = (not _latin1(name)) if flag is None else bool(flag)
    text = name.encode("utf-16-le") if wide else name.encode("latin-1")
    count = len(text) // (2 if wide else 1) if cch is None else cch
    return rec(BOUNDSHEET, head + struct.pack("<BB", count, 1 if wide else 0) + text)


def number(row, col, ifx, value, length=None):
    body = struct.pack("<HHHd", row, col, ifx, value)
    return rec(NUMBER, body if length is None else body[:length])


def rk_int(i):
    """The RK value of a 30-bit signed integer."""
    assert -0x20000000 <= i < 0x20000000
    return ((i & 0x3FFFFFFF) << 2) | 2


def rk_int100(i):
    """The RK value of a 30-bit signed integer the number is a
    hundredth of."""
    assert -0x20000000 <= i < 0x20000000
    return ((i & 0x3FFFFFFF) << 2) | 3


def rk_float(d):
    """The RK value of a double whose low 34 bits are zero: its high 30
    bits, and the flags' two bits cleared."""
    bits = struct.unpack("<Q", struct.pack("<d", d))[0]
    assert bits & 0x3FFFFFFFF == 0, "not a double an RK value holds: %r" % (d,)
    return (bits >> 32) & 0xFFFFFFFC


def rk_float100(d):
    """The RK value of a double the number is a hundredth of."""
    return rk_float(d) | 1


def rk_record(row, col, ifx, value):
    return rec(RK, struct.pack("<HHHI", row, col, ifx, value & 0xFFFFFFFF))


def mulrk(row, col, cells, last=None, length=None):
    """A MULRK record: the run's cells from `col` on, each its style and
    its RK value, and the run's last column at the end. `last` spells
    another last column, `length` cuts the body, for a broken file."""
    body = struct.pack("<HH", row, col)
    body += b"".join(struct.pack("<HI", ifx, v & 0xFFFFFFFF) for ifx, v in cells)
    body += struct.pack("<H", col + len(cells) - 1 if last is None else last)
    return rec(MULRK, body if length is None else body[:length])


def blank(row, col, ifx, length=None):
    body = struct.pack("<HHH", row, col, ifx)
    return rec(BLANK, body if length is None else body[:length])


def mulblank(row, col, styles, last=None, length=None):
    """A MULBLANK record: a run of styled empty cells from `col` on, and
    the run's last column at the end."""
    body = struct.pack("<HH", row, col)
    body += b"".join(struct.pack("<H", ifx) for ifx in styles)
    body += struct.pack("<H", col + len(styles) - 1 if last is None else last)
    return rec(MULBLANK, body if length is None else body[:length])


def labelsst(row, col, ifx, index, length=None):
    body = struct.pack("<HHHi", row, col, ifx, index)
    return rec(LABELSST, body if length is None else body[:length])


def boolerr(row, col, ifx, value, is_error, length=None):
    body = struct.pack("<HHHBB", row, col, ifx, value, is_error)
    return rec(BOOLERR, body if length is None else body[:length])


def error_cell(row, col, ifx, text):
    return boolerr(row, col, ifx, ERRORS[text], 1)


def formula(row, col, ifx, cached, rgce=b"", flags=0, length=None):
    """A FORMULA record with `cached` as its value: a number (a float), or
    one of ``("bool", 0|1)``, ``("error", code)``, ``("string",)`` — the
    string follows in a STRING record — and ``("blank",)``, the blank
    string that leaves nothing to answer."""
    if isinstance(cached, float):
        val = struct.pack("<d", cached)
    else:
        kind = {"bool": 1, "error": 2, "string": 0, "blank": 3}[cached[0]]
        val = bytes([kind, 0, cached[1] if len(cached) > 1 else 0, 0, 0, 0, 0xFF, 0xFF])
    body = struct.pack("<HHH", row, col, ifx) + val
    body += struct.pack("<HIH", flags, 0, len(rgce)) + rgce
    return rec(FORMULA, body if length is None else body[:length])


def array_record(row=0, col=0):
    """An ARRAY record: a range of one cell, five unused bytes, and no
    formula tokens."""
    return rec(ARRAY, struct.pack("<HHBBB", row, row, col, col, 0) + b"\x00" * 5 +
               struct.pack("<H", 0))


def shrfmla_record(row=0, col=0):
    """A SHRFMLA record: a range of one cell, one formula, and no tokens."""
    return rec(SHRFMLA, struct.pack("<HHBBBBH", row, row, col, col, 0, 1, 0))


def tableop_record(row=0, col=0):
    return rec(TABLEOP, struct.pack("<HHBBBHH", row, row, col, col, 0, 1, 0))


def tableop2_record(row=0, col=0):
    return rec(TABLEOP2, struct.pack("<BB", 0, 0))


def index_record():
    """An INDEX record of no row block, as this reader steps over it."""
    return rec(INDEX, struct.pack("<IIHHH", 0, 0, 0, 0, 0) + b"\x00\x00\x00\x00")


def dbcell_record():
    return rec(DBCELL, struct.pack("<I", 0) + b"\x00\x00\x00\x00")


def dimensions(rows, cols):
    return rec(DIMENSIONS, struct.pack("<IIHH", 0, rows, 0, cols) + b"\x00\x00")


def row_record(row, cols):
    """A ROW record of BIFF8's sixteen bytes: the row, its first and last
    columns, a default height, and the flags a visible row carries."""
    return rec(ROWREC, struct.pack("<HHHHHHHH", row, 0, cols, 0xFF00, 0, 0, 0x0100, 0))


def unknown(rid, body=b"\x00\x00"):
    return rec(rid, body)


# ── strings ──────────────────────────────────────────────────────────

def _latin1(text):
    try:
        text.encode("latin-1")
        return True
    except UnicodeEncodeError:
        return False


def n_units(text):
    """A text's UTF-16 code units: two for a character past the basic
    multilingual plane."""
    return len(text.encode("utf-16-le")) // 2


def encode(text, compressed):
    """A text's characters: the low byte of each code unit when
    `compressed`, and both bytes otherwise."""
    return text.encode("latin-1") if compressed else text.encode("utf-16-le")


def auto_segments(text):
    """A text cut where its spelling changes: one-byte characters up to
    the first the Latin-1 range does not hold, two-byte ones after it, and
    so on — the way a writer saves the high bytes it can."""
    segments = []
    for ch in text:
        compressed = _latin1(ch)
        if segments and segments[-1][1] == compressed:
            segments[-1][0] += ch
        else:
            segments.append([ch, compressed])
    return [(t, c) for t, c in segments]


def string_item(text=None, *, segments=None, runs=(), phonetic=b"", cch=None,
                count_width=2, flags=None, run_count=None, phonetic_size=None):
    """One string in the parts a record cuts it into: the head that is
    never cut — the character count `count_width` bytes wide (none when 0),
    the flags, the count of rich-text runs and the size of phonetic data
    where the flags name them — the stretches of its characters as
    `(bytes, flag)` pairs, the runs, and the phonetic data. `segments` are
    `(text, compressed)` pairs the string is spelled in; one pair whole
    otherwise. `cch`, `flags`, `run_count` and `phonetic_size` spell
    another count, other flags, another number of runs and another size,
    for a broken file."""
    if segments is None:
        segments = [(text, _latin1(text))]
    if cch is None:
        count = n_units(text) if text is not None else sum(n_units(t) for t, _ in segments)
    else:
        count = cch
    if flags is None:
        flags = (0 if segments[0][1] else 1) | (0x08 if runs else 0) | (0x04 if phonetic else 0)
    head = b""
    if count_width == 1:
        head += struct.pack("<B", count)
    elif count_width == 2:
        head += struct.pack("<H", count)
    head += bytes([flags])
    if flags & 8:
        head += struct.pack("<H", len(runs) if run_count is None else run_count)
    if flags & 4:
        head += struct.pack("<i", len(phonetic) if phonetic_size is None else phonetic_size)
    return (
        head,
        [(encode(t, c), 0 if c else 1) for t, c in segments],
        b"".join(struct.pack("<HH", a, f) for a, f in runs),
        phonetic,
    )


class Pieces:
    """A record's body split into pieces of at most `limit` bytes. An atom
    is never cut; a stretch of characters is cut where its piece ends, and
    the piece after a cut in the characters opens with the flag saying how
    its own stretch is spelled; any other data is cut wherever the piece
    ends."""

    def __init__(self, limit=PIECE):
        self.limit = limit
        self.pieces = [bytearray()]

    def cut(self):
        self.pieces.append(bytearray())

    def atom(self, data):
        if self.pieces[-1] and len(self.pieces[-1]) + len(data) > self.limit:
            self.cut()
        self.pieces[-1] += data

    def chars(self, data, flag):
        while data:
            room = self.limit - len(self.pieces[-1])
            if room <= 0:
                self.cut()
                self.pieces[-1].append(flag)
                room = self.limit - 1
            take = min(room, len(data))
            if (flag & 1) and (take & 1):
                # A two-byte character is never cut.
                take -= 1
                if take == 0:
                    self.cut()
                    self.pieces[-1].append(flag)
                    take = min(self.limit - 1, len(data)) & ~1
            self.pieces[-1] += data[:take]
            data = data[take:]

    def stream(self, data):
        while data:
            room = self.limit - len(self.pieces[-1])
            if room <= 0:
                self.cut()
                room = self.limit
            take = min(room, len(data))
            self.pieces[-1] += data[:take]
            data = data[take:]

    def lay(self, item):
        """Lay one string out: its head and its first character together,
        a change of spelling always at a cut, each run whole, the phonetic
        data anywhere."""
        head, segments, runs, phonetic = item
        if not segments:
            segments = [(b"", 0)]
        first, flag = segments[0]
        width = 2 if flag & 1 else 1
        self.atom(head + first[:width])
        self.chars(first[width:], flag)
        for data, flag in segments[1:]:
            if self.pieces[-1]:
                self.cut()
            self.pieces[-1].append(flag)
            self.chars(data, flag)
        for i in range(0, len(runs), 4):
            self.atom(runs[i:i + 4])
        self.stream(phonetic)

    def records(self, rid):
        """The record `rid` with the first piece, and a CONTINUE record
        with every piece after it."""
        out = rec(rid, bytes(self.pieces[0]))
        return out + b"".join(rec(CONTINUE, bytes(p)) for p in self.pieces[1:])


def raw_continued(rid, pieces):
    """A record and the CONTINUE records after it, their bodies given as
    they are."""
    return rec(rid, pieces[0]) + b"".join(rec(CONTINUE, p) for p in pieces[1:])


def sst_records(items, total=None, unique=None, limit=PIECE):
    """The shared string table: its two counts — of every reference to its
    strings, and of the strings — then the strings."""
    count = len(items)
    pieces = Pieces(limit)
    pieces.atom(struct.pack("<ii", count if total is None else total,
                            count if unique is None else unique))
    for item in items:
        pieces.lay(item)
    return pieces.records(SST)


def sst_raw(pieces):
    """A shared string table whose pieces are given as they are."""
    return raw_continued(SST, pieces)


def continued(rid, prefix, item, limit=PIECE):
    """The records carrying one string: the record `rid` with `prefix`
    before the string, and a CONTINUE record for every piece after the
    first."""
    pieces = Pieces(limit)
    pieces.atom(prefix)
    pieces.lay(item)
    return pieces.records(rid)


def label(row, col, ifx, text=None, *, item=None, cch=None, limit=PIECE, **spell):
    """A LABEL record — a cell holding a string of its own — and the
    CONTINUE records after it. The record spells the character count
    before the string; the string spells none."""
    if item is None:
        if cch is not None:
            spell["cch"] = cch
        item = string_item(text, count_width=0, **spell)
    if cch is not None:
        count = cch
    elif text is not None:
        count = n_units(text)
    else:
        count = sum(n_units(t) for t, _ in spell["segments"])
    prefix = struct.pack("<HHHH", row, col, ifx, count)
    return continued(LABEL, prefix, item, limit)


def string_record(text=None, *, item=None, limit=PIECE, **spell):
    """A STRING record — a formula's cached string — and the CONTINUE
    records after it. The string spells its own character count."""
    if item is None:
        item = string_item(text, **spell)
    return continued(STRING, b"", item, limit)


def format_record(index, text, *, item=None, limit=PIECE):
    """A FORMAT record: the index of a number format and its code, a
    whole string that spells its own character count."""
    if item is None:
        item = string_item(text)
    return continued(FORMAT, struct.pack("<H", index), item, limit)


# ── the workbook stream ──────────────────────────────────────────────

def sheet(records, kind=WORKSHEET, vers=0x0600, rid=BOF, with_eof=True, length=None):
    """A sheet's substream: its BOF record, its records, its EOF record."""
    return bof(kind, vers, rid, length) + b"".join(records) + (eof() if with_eof else b"")


def _sheet_bytes(s):
    """A sheet's whole substream, as its dict spells it."""
    if "data" in s:
        return s["data"]
    return sheet(
        s.get("records", ()), s.get("bof_kind", WORKSHEET), s.get("bof_vers", 0x0600),
        s.get("bof_id", BOF), s.get("with_eof", True), s.get("bof_length"),
    )


def _boundsheet(s, position):
    if "boundsheet" in s:
        return s["boundsheet"]
    return boundsheet(position, s["name"], s.get("visibility", 0), s.get("kind", 0),
                      **s.get("spell", {}))


def workbook(sheets, before=(), after=(), globals_bof=None):
    """The workbook stream: the globals' BOF record, the records `before`,
    a BOUNDSHEET record for each sheet — naming the byte of its substream —
    the records `after`, an EOF record, then each sheet's substream in
    order. A sheet is a dict with its ``name`` and either ``records``
    (between its BOF and its EOF) or ``data`` (its whole substream);
    ``visibility`` and ``kind`` go into its BOUNDSHEET record, ``position``
    names another byte in it, ``boundsheet`` is that record as it is, and
    ``bof_kind``, ``bof_vers``, ``bof_id``, ``with_eof`` and ``bof_length``
    spell its BOF record. `globals_bof` replaces the globals' BOF record."""
    bodies = [_sheet_bytes(s) for s in sheets]
    head = (bof(GLOBALS) if globals_bof is None else globals_bof) + b"".join(before)
    tail = b"".join(after) + eof()
    start = len(head) + sum(len(_boundsheet(s, 0)) for s in sheets) + len(tail)
    out = head
    pos = start
    for s, body in zip(sheets, bodies):
        out += _boundsheet(s, s.get("position", pos))
        pos += len(body)
    return out + tail + b"".join(bodies)


def simple_workbook(sheets, *, strings=(), ifmts=(0,), formats=(), datemode_=None,
                    sst_limit=PIECE, sst_total=None, sst_unique=None, sst_items=None,
                    no_sst=False, before=(), after=(), **kw):
    """A workbook of worksheets from their records: the DATEMODE record
    when `datemode_` is given, the FORMAT records in `formats` (index,
    code), one XF record a number format in `ifmts`, the shared string
    table of `strings`, and then the sheets. `sheets` are dicts as
    `workbook` takes them, with ``records`` their cells."""
    head = list(before)
    if datemode_ is not None:
        head.append(datemode(datemode_))
    head.extend(format_record(i, c) for i, c in formats)
    head.extend(xf(i) for i in ifmts)
    tail = list(after)
    if not no_sst:
        items = list(sst_items) if sst_items is not None else [string_item(s) for s in strings]
        tail.append(sst_records(items, sst_total, sst_unique, sst_limit))
    return workbook(sheets, before=head, after=tail, **kw)


# ── the compound file ────────────────────────────────────────────────

FREE, ENDC, FATSEC, DIFSEC = 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD, 0xFFFFFFFC
SIGNATURE = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"

#: The size a stream must reach to live in the file's own sectors.
CUTOFF = 0x1000

#: Where the header's fields lie.
VERSION_AT, ORDER_AT, SHIFT_AT, MINI_SHIFT_AT = 26, 28, 30, 32
NFAT_AT, DIR_FIRST_AT, CUTOFF_AT, MINIFAT_FIRST_AT, NMINIFAT_AT = 44, 48, 56, 60, 64
DIFAT_FIRST_AT, NDIFAT_AT, DIFAT_AT = 68, 72, 76

#: Where a directory entry's fields lie, inside its 128 bytes.
NAME_LENGTH_AT, TYPE_AT, CHILD_AT, START_AT, SIZE_AT = 64, 66, 76, 116, 120


def header(*, version=3, shift=None, mini_shift=6, order=0xFFFE, nfat=0,
           dir_first=0, cutoff=CUTOFF, minifat_first=ENDC, nminifat=0,
           difat_first=ENDC, ndifat=0, difat=(), ndir=0, minor=0x3E,
           signature=SIGNATURE, length=512):
    """The compound file's header: the signature, the version, the byte
    order, the two sector sizes, the table's and the directory's places,
    the cutoff, the mini table's place, the DIFAT chain, and the 109 DIFAT
    entries. `length` cuts it short, for a broken file."""
    if shift is None:
        shift = 9 if version == 3 else 12
    h = bytearray(512)
    h[0:len(signature)] = signature
    struct.pack_into("<HHHHH", h, 24, minor, version, order, shift, mini_shift)
    struct.pack_into("<IIIIIIIII", h, 40, ndir, nfat, dir_first, 0, cutoff,
                     minifat_first, nminifat, difat_first, ndifat)
    entries = list(difat)[:109]
    for i, sid in enumerate(entries + [FREE] * (109 - len(entries))):
        struct.pack_into("<I", h, DIFAT_AT + 4 * i, sid)
    return bytes(h[:length])


def entry(name, kind, *, child=0xFFFFFFFF, left=0xFFFFFFFF, right=0xFFFFFFFF,
          start=ENDC, size=0, colour=1, name_length=None):
    """A directory entry: a UTF-16 name with its length counting the final
    U+0000, the object's kind (5 the root, 2 a stream), the tree's links,
    and the stream's first sector and size. `name_length` spells another
    length, for a broken file."""
    e = bytearray(128)
    n = name.encode("utf-16-le") + b"\x00\x00"
    e[0:min(len(n), 64)] = n[:64]
    struct.pack_into("<H", e, NAME_LENGTH_AT, len(n) if name_length is None else name_length)
    e[TYPE_AT] = kind
    e[67] = colour
    struct.pack_into("<III", e, 68, left, right, child)
    struct.pack_into("<I", e, START_AT, start)
    struct.pack_into("<Q", e, SIZE_AT, size)
    return bytes(e)


def directory(stream_start, stream_size, root_start=ENDC, root_size=0, name="Workbook",
              kind=2, **spell):
    """A directory of four entries: the root, whose stream is the mini
    stream, the workbook stream, and two unused."""
    return (entry("", 5, child=1, start=root_start, size=root_size) +
            entry(name, kind, start=stream_start, size=stream_size, **spell) +
            entry("", 0) + entry("", 0))


class Cfb:
    """A compound file assembled once and then patched: a sound file to
    start with, and the places its header's fields, its FAT's entries, its
    mini FAT's entries and its directory entries' fields lie at, for the
    one fault a broken fixture carries."""

    def __init__(self, head, sectors, sector=512):
        self.sector = sector
        self.data = bytearray(head)
        for s in sectors:
            assert len(s) == sector, "a sector is %d bytes, not %d" % (len(s), sector)
            self.data += s
        self.fat_off = None
        self.minifat_off = None
        self.dir_off = None

    def out(self):
        return bytes(self.data)

    def cut(self, length):
        """Keep the file's first `length` bytes."""
        self.data = self.data[:length]

    def fat(self, i, value):
        """The FAT's entry for sector `i`."""
        struct.pack_into("<I", self.data, self.fat_off + 4 * i, value)

    def mini_fat(self, i, value):
        """The mini FAT's entry for mini sector `i`."""
        struct.pack_into("<I", self.data, self.minifat_off + 4 * i, value)

    def entry_set(self, index, offset, fmt, *values):
        """A field of directory entry `index`."""
        struct.pack_into(fmt, self.data, self.dir_off + 128 * index + offset, *values)

    def set(self, offset, fmt, *values):
        """A field of the file at `offset`."""
        struct.pack_into(fmt, self.data, offset, *values)

    def get(self, offset, fmt):
        return struct.unpack_from(fmt, self.data, offset)[0]


def _pad(data, width):
    """`data` completed with nothing to a multiple of `width`, and a whole
    `width` of nothing when there is no data at all: a stream of no byte
    still has a sector."""
    extra = width if len(data) == 0 else (-len(data)) % width
    return bytes(data) + b"\x00" * extra


def _sectors(data, sector):
    """A stream as the sectors holding it: padded to whole ones and cut
    into them."""
    data = _pad(data, sector)
    return [data[i * sector:(i + 1) * sector] for i in range(len(data) // sector)]


def _fat_table(entries, count):
    """FAT entries as bytes, padded with free sectors to `count`."""
    entries = list(entries) + [FREE] * (count - len(entries))
    return b"".join(struct.pack("<I", e & 0xFFFFFFFF) for e in entries)


def regular(stream, sector=512, name="Workbook"):
    """A compound file whose one stream lies in the file's own sectors: the
    stream's sectors, then the FAT sector, then the directory sector. A
    version 3 file when a sector is 512 bytes, a version 4 one when it is
    4096. The stream is padded to the cutoff, 4096 bytes, as a writer pads
    it — a shorter stream would belong in the mini stream — and its entry
    names the padded length."""
    version = {512: 3, 4096: 4}[sector]
    per = sector // 4
    data = _sectors(_pad(stream, CUTOFF), sector)
    count = len(data)
    assert count + 2 <= per, "one FAT sector covers %d sectors, the stream needs %d" % (per, count + 2)
    fat = list(range(1, count)) + [ENDC, FATSEC, ENDC]
    c = Cfb(
        header(version=version, nfat=1, dir_first=count + 1, difat=[count]),
        data + [_fat_table(fat, per), _pad(directory(0, count * sector, name=name), sector)],
        sector,
    )
    c.fat_off = 512 + count * sector
    c.dir_off = 512 + (count + 1) * sector
    c.data_first = 0
    c.data_count = count
    c.size = count * sector
    return c


def mini(stream, sector=512, name="Workbook"):
    """A compound file whose one stream is shorter than the cutoff and lies
    in the mini stream: the root entry's stream in a sector of its own,
    the mini FAT sector, the FAT sector and the directory sector."""
    per = sector // 4
    m = max(1, (len(stream) + 63) // 64)
    count = max(1, (m * 64 + sector - 1) // sector)
    assert m <= per, "one mini FAT sector covers %d mini sectors, the stream needs %d" % (per, m)
    fat = list(range(1, count)) + [ENDC, ENDC, FATSEC, ENDC]
    c = Cfb(
        header(nfat=1, dir_first=count + 2, minifat_first=count, nminifat=1,
               difat=[count + 1]),
        _sectors(_pad(stream, m * 64), sector) +
        [_fat_table(list(range(1, m)) + [ENDC], per), _fat_table(fat, per),
         _pad(directory(0 if len(stream) else ENDC, len(stream), 0, m * 64, name=name), sector)],
        sector,
    )
    c.minifat_off = 512 + count * sector
    c.fat_off = 512 + (count + 1) * sector
    c.dir_off = 512 + (count + 2) * sector
    c.data_first = 0
    c.data_count = count
    c.mini_count = m
    return c


def fragmented(stream, order=(3, 1, 5, 0, 4, 2), name="Workbook"):
    """A compound file whose stream's sectors are not next to each other in
    the file — a free sector among them — and whose FAT sector comes after
    the data. `order` maps each sector of the stream to its sector of the
    file."""
    sector = 512
    per = sector // 4
    data = _sectors(_pad(stream, CUTOFF), sector)
    count = len(data)
    assert count <= len(order) and max(order) + 2 <= per
    chain = list(order[:count])
    fat_sector = max(order) + 1
    dir_sector = fat_sector + 1
    sectors = [b"\x00" * sector] * (dir_sector + 1)
    for k, sid in enumerate(chain):
        sectors[sid] = data[k]
    fat = [FREE] * per
    for k, sid in enumerate(chain):
        fat[sid] = chain[k + 1] if k + 1 < count else ENDC
    fat[fat_sector] = FATSEC
    fat[dir_sector] = ENDC
    sectors[fat_sector] = _fat_table(fat, per)
    sectors[dir_sector] = _pad(directory(chain[0], count * sector, name=name), sector)
    c = Cfb(header(nfat=1, dir_first=dir_sector, difat=[fat_sector]), sectors)
    c.fat_off = 512 + fat_sector * sector
    c.dir_off = 512 + dir_sector * sector
    c.data_first = chain[0]
    c.data_count = count
    c.size = count * sector
    c.chain = chain
    return c


def difat_chain(stream, name="Workbook"):
    """A compound file with more FAT sectors than the header has entries
    for — 110 — so a DIFAT sector chains after the header: the stream's
    sectors, the 110 FAT sectors, the DIFAT sector, the directory sector."""
    sector = 512
    per = sector // 4
    data = _sectors(_pad(stream, CUTOFF), sector)
    count = len(data)
    nfat = 110
    fat_first = count
    difat_sector = count + nfat
    dir_sector = difat_sector + 1
    fat = [FREE] * (nfat * per)
    for k in range(count):
        fat[k] = k + 1 if k + 1 < count else ENDC
    for i in range(nfat):
        fat[fat_first + i] = FATSEC
    fat[difat_sector] = DIFSEC
    fat[dir_sector] = ENDC
    fat_bytes = _fat_table(fat, nfat * per)
    # The DIFAT sector: the last FAT sector's number, free entries, and
    # the end of the DIFAT chain.
    difat = [fat_first + nfat - 1] + [FREE] * (per - 2) + [ENDC]
    c = Cfb(
        header(nfat=nfat, dir_first=dir_sector, difat=list(range(fat_first, fat_first + 109)),
               difat_first=difat_sector, ndifat=1),
        data + [fat_bytes[i * sector:(i + 1) * sector] for i in range(nfat)] +
        [_fat_table(difat, per), _pad(directory(0, count * sector, name=name), sector)],
    )
    c.fat_off = 512 + fat_first * sector
    c.fat_at = [fat_first + i for i in range(nfat)]
    c.dir_off = 512 + dir_sector * sector
    c.data_first = 0
    c.data_count = count
    c.size = count * sector
    return c


def zip_container():
    """A ZIP archive holding two entries, as an .xlsx workbook is a ZIP
    archive: not a compound file."""
    entries = [("[Content_Types].xml", b'<?xml version="1.0"?><Types xmlns="u"/>'),
               ("_rels/.rels", b'<?xml version="1.0"?><Relationships/>')]
    out = bytearray()
    central = bytearray()
    offsets = []
    for name, body in entries:
        crc = zlib.crc32(body) & 0xFFFFFFFF
        offsets.append(len(out))
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0, crc, len(body),
                           len(body), len(name), 0) + name.encode() + body
    for (name, body), at in zip(entries, offsets):
        crc = zlib.crc32(body) & 0xFFFFFFFF
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 0, 0, 0,
                               crc, len(body), len(body), len(name), 0, 0, 0, 0, 0, at)
        central += name.encode()
    out += central
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries),
                       len(central), offsets and len(out) - len(central), 0)
    return bytes(out)


# ── a reading of the stream, for the generator's own bookkeeping ─────

def records(stream):
    """The records of a workbook stream: (id, body, offset)."""
    at = 0
    while at + 4 <= len(stream):
        rid, length = struct.unpack_from("<HH", stream, at)
        yield rid, stream[at + 4:at + 4 + length], at
        at += 4 + length


def sheet_positions(stream):
    """Where the workbook globals' BOUNDSHEET records place their sheets."""
    out = []
    for rid, body, _ in records(stream):
        if rid == BOUNDSHEET:
            out.append(struct.unpack_from("<i", body)[0])
        if rid == EOF:
            break
    return out


def blank_formulas(stream):
    """The cells whose formula caches a blank string: `(sheet place, row,
    column)` for each. The reference reader answers a text cell holding
    the empty string for them; the codec answers no cell."""
    found = set()
    for position in sheet_positions(stream):
        at = position + 4 + 16
        while at + 4 <= len(stream):
            rid, length = struct.unpack_from("<HH", stream, at)
            if rid == EOF:
                break
            if rid == FORMULA:
                row, col = struct.unpack_from("<HH", stream, at + 4)
                if stream[at + 10:at + 18] == b"\x03\x00\x00\x00\x00\x00\xff\xff":
                    found.add((position, row, col))
            at += 4 + length
    return found
