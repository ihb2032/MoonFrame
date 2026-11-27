"""Lay out a small sas7bdat file from scratch, in any of the format's layouts.

A fixture builder for what no reference writer produces, or produces only in
large files: numeric columns narrower than eight bytes in big-endian and in
64-bit files, display formats named one by one, a second text block on an AMD
page, a data set of no column, any character-set code, rows compressed in a
layout the writer's compressed files do not come in. It writes a header,
then a page holding the row-size, column-count, text, column-name,
column-attribute and format subheaders — a MIX page, which then holds the
rows too, or a page of another kind with the rows on DATA pages after it, or
as compressed subheaders of its own — and, when asked, an AMD page holding a
second text block. Both reference readers open what it writes — the second
only while every numeric column is at least three bytes wide — so they serve
as the oracles for the cells; nothing here reads a file.

The layouts follow what the corpus holds: the alignment bytes at 32 and
35 say whether offsets are 8 bytes wide and whether four bytes of padding
follow the header's fixed part; byte 37 says the byte order.
"""

import struct

MAGIC = bytes.fromhex(
    "000000000000000000000000c2ea8160b31411cfbd92080009c7318c181f1011"
)
# Seconds after 1960-01-01: 2007-07-14, a date every runtime accepts.
STAMP = 1500000000.0
ROW_SIZE = 0xF7F7F7F7
COLUMN_SIZE = 0xF6F6F6F6
COLUMN_TEXT = 0xFFFFFFFD
COLUMN_NAME = 0xFFFFFFFF
COLUMN_ATTRIBUTES = 0xFFFFFFFC
COLUMN_FORMAT = 0xFFFFFBFE
META = 0x0000
DATA = 0x0100
MIX = 0x0200
AMD = 0x0400
# The bytes a text block opens with, behind its size field: a compression
# name goes here.
PREAMBLE = 16
# The format's two row compressions, by the name a file's text block carries.
COMPRESSIONS = {"CHAR": b"SASYZCRL", "BINARY": b"SASYZCR2"}
# The bytes a fill command of either method repeats by a code of its own:
# an at-sign, a blank and a NUL in the CHAR method; in the BINARY method
# every fill names its byte, so anything can end a row.
FILL_MINIMUM = 18


def trailing_run(spelled):
    """Where the row's last run of one byte begins, and the byte: it must be long enough to fill.

    A stream has to be shorter than the row it spells — a reader takes a
    longer one for a plain row — so the row's end is written as one fill
    command, and a fill is at least 18 bytes.
    """
    filler = spelled[-1]
    start = len(spelled)
    while start > 0 and spelled[start - 1] == filler:
        start -= 1
    if len(spelled) - start < FILL_MINIMUM:
        raise ValueError("a compressed row must end in a run of one byte at least 18 long")
    return spelled[:start], filler, len(spelled) - start


def compress_row(spelled, method):
    """A row's bytes as a compressed stream: the row's head copied as it is, its tail filled.

    The head — everything before the row's last run of one byte — goes out
    in pieces of sixteen, each copied as it is: the CHAR method's copy
    command (8), a control byte and a piece; the BINARY method's literals
    under control words of zeros. The tail is one fill command in the CHAR
    method (at-sign, blank or NUL by a code of their own, any other byte
    named), and runs of up to eighteen in the BINARY method, which has no
    longer fill of one byte to give.
    """
    head, filler, run = trailing_run(spelled)
    out = bytearray()
    if method == "CHAR":
        for k in range(0, len(head), 16):
            piece = head[k : k + 16]
            out.append(0x80 | (len(piece) - 1))
            out += piece
        if filler in (0x40, 0x20, 0x00):
            command = {0x40: 0x50, 0x20: 0x60, 0x00: 0x70}[filler]
            count = run - 17
        else:
            command = 0x40
            count = run - 18
        out.append(command | (count // 256))
        out.append(count % 256)
        if command == 0x40:
            out.append(filler)
        return bytes(out)
    commands = [(0, bytes([byte])) for byte in head]
    left = run
    while left:
        count = min(left, 18)
        commands.append((1, bytes([count - 3, filler])))
        left -= count
    for k in range(0, len(commands), 16):
        group = commands[k : k + 16]
        word = 0
        for j, (bit, _payload) in enumerate(group):
            word |= bit << (15 - j)
        out += bytes([word >> 8, word & 0xFF])
        for _bit, payload in group:
            out += payload
    return bytes(out)


def build(
    columns,
    rows,
    wide,
    little,
    pad,
    charset=29,
    page_size=4096,
    header_size=1024,
    format_count=None,
    formats=None,
    second_text=(),
    preamble=b"",
    meta_type=MIX,
    row_pages=1,
    compress=None,
):
    """The bytes of a data set.

    ``columns`` is a list of ``(name, kind, width)`` with ``kind`` ``"n"``
    (numeric) or ``"s"`` (character); ``rows`` a list of lists of values,
    a float for a numeric column and a text for a character one — a ``str``,
    spelled Latin-1, or the ``bytes`` themselves. Either may be empty.
    ``wide`` lays the file out in 64-bit fields, ``pad`` puts four bytes
    of padding behind the header's fixed part, ``little`` chooses the byte
    order and ``charset`` is the header's character-set code (byte 70).
    ``formats`` maps a column's name to the text of its display format; a
    column left out has none. ``format_count`` limits the format subheaders
    to the first so many columns (all by default). The names of the columns
    in ``second_text`` lie in a second text block, on an AMD page of its
    own. ``preamble`` is text laid in the first text block behind its size
    field, before the names: a compression name, up to 14 bytes.
    ``meta_type`` is the kind of the page holding the subheaders: a MIX
    page holds the rows too; with any other kind they go to ``row_pages``
    DATA pages after it — unless ``compress`` names a method, ``"CHAR"`` or
    ``"BINARY"``, when each row is a compressed stream stored as a
    subheader on that page, and the method's name is the preamble.
    """
    word = 8 if wide else 4
    bo = "<" if little else ">"
    WF = "Q" if wide else "I"
    lead = 32 if wide else 16
    pointer = 24 if wide else 12
    if formats is None:
        formats = {}
    if format_count is None:
        format_count = len(columns)
    if row_pages != 1 and meta_type == MIX:
        raise ValueError("a MIX page holds its own rows: row_pages is 1")
    if compress is not None:
        if meta_type == MIX:
            raise ValueError("compressed rows are subheaders: give a page of another kind than MIX")
        if compress not in COMPRESSIONS:
            raise ValueError(f"unknown row compression {compress!r}: one of {sorted(COMPRESSIONS)}")
        if preamble:
            raise ValueError("the preamble is the compression's name when the rows are compressed")
        preamble = COMPRESSIONS[compress]
    row_length = sum(width for _name, _kind, width in columns)
    if (columns or rows) and row_length == 0:
        raise ValueError("a row must hold at least one byte")
    for name in list(formats) + list(second_text):
        if name not in [n for n, _k, _w in columns]:
            raise ValueError(f"{name!r} is not a column")
    if len(preamble) > PREAMBLE - 2:
        raise ValueError("the preamble is longer than the 14 bytes free before the names")

    def signature(value):
        # A 32-bit file spells the signature's four bytes in its byte order.
        # A 64-bit one widens them to eight: a little-endian file zero-extends
        # the row-size and column-count signatures and sign-extends the others
        # (whose top byte is FF); a big-endian one puts the four bytes first
        # and follows them with FF FF FB FE. That is what the corpus holds.
        if not wide:
            return struct.pack(bo + "I", value)
        if value >= 0xFF000000:
            return struct.pack(bo + "q", value - (1 << 32))
        if little:
            return struct.pack("<Q", value)
        return struct.pack(">I", value) + bytes([0xFF, 0xFF, 0xFB, 0xFE])

    def pack(buffer, fmt, at, value):
        struct.pack_into(bo + fmt, buffer, at, value)

    # ---- the header
    header = bytearray(header_size)
    header[0:32] = MAGIC
    header[32] = 0x33 if wide else 0x22
    header[35] = 0x33 if pad else 0x22
    header[37] = 1 if little else 0
    header[39] = ord("1")
    header[70] = charset
    header[84:92] = b"DATA    "
    at = 164 + (4 if pad else 0)
    pack(header, "d", at, STAMP)
    at += 8
    pack(header, "d", at, STAMP)
    at += 8 + 16
    pack(header, "I", at, header_size)
    at += 4
    pack(header, "I", at, page_size)
    at += 4
    pages_count = 1 + (1 if second_text else 0) + (0 if meta_type == MIX or compress is not None else row_pages)
    pack(header, WF, at, pages_count)
    at += word + 8
    header[at : at + 8] = b"9.0401M1"
    at += 16
    header[at : at + 5] = b"Linux"
    if at + 16 + 64 > header_size:
        raise ValueError("the header is too short for its tail")

    # ---- the subheaders
    on_page = len(rows) if meta_type == MIX else 0
    row_size = bytearray(808 if wide else 480)
    row_size[0:word] = signature(ROW_SIZE)
    pack(row_size, WF, 5 * word, row_length)
    pack(row_size, WF, 6 * word, len(rows))
    pack(row_size, WF, 9 * word, len(columns))
    pack(row_size, WF, 15 * word, on_page)

    column_size = bytearray(2 * word)
    column_size[0:word] = signature(COLUMN_SIZE)
    pack(column_size, WF, word, len(columns))

    # The names, each closed by a NUL and each in the text block its
    # reference names (the first by default, the second for the columns in
    # ``second_text``), from the block's 16th byte on — the preamble first,
    # behind the two bytes the block's size field takes. A reference names a
    # name by offset and length inside the block, which starts at the
    # subheader's size field and is as long as that field says. Behind the
    # block the subheader carries a word and four bytes more, which the
    # first reference reader does not read.
    blocks = {0: bytearray(2) + preamble + bytearray(PREAMBLE - 2 - len(preamble)), 1: bytearray(PREAMBLE)}
    names_at = {}
    for name, _kind, _width in columns:
        block = 1 if name in second_text else 0
        spelled = (name if isinstance(name, bytes) else name.encode("latin-1")) + b"\x00"
        names_at[name] = (block, len(blocks[block]), len(spelled) - 1)
        blocks[block] += spelled
    formats_at = {}
    for name, text in formats.items():
        formats_at[name] = (len(blocks[0]), len(text))
        blocks[0] += text.encode("latin-1")

    def text_subheader(block):
        blob = blocks[block]
        text = bytearray(word) + blob + bytearray(word + 4)
        text[0:word] = signature(COLUMN_TEXT)
        pack(text, "H", word, len(blob))
        return text

    name_refs = bytearray(2 * word + 12 + 8 * len(columns))
    name_refs[0:word] = signature(COLUMN_NAME)
    pack(name_refs, "H", word, len(name_refs) - 4 - 2 * word)
    attributes = bytearray(2 * word + 12 + (word + 8) * len(columns))
    attributes[0:word] = signature(COLUMN_ATTRIBUTES)
    pack(attributes, "H", word, len(attributes) - 4 - 2 * word)
    offset = 0
    for k, (name, kind, width) in enumerate(columns):
        at = word + 8 + 8 * k
        block, name_offset, name_length = names_at[name]
        pack(name_refs, "H", at, block)
        pack(name_refs, "H", at + 2, name_offset)
        pack(name_refs, "H", at + 4, name_length)
        at = word + 8 + (word + 8) * k
        pack(attributes, WF, at, offset)
        pack(attributes, "I", at + word, width)
        attributes[at + word + 6] = 1 if kind == "n" else 2
        offset += width

    # One format subheader per column, in column order, each naming its
    # column's format in the first text block, or none: the reference
    # readers pair the k-th with column k.
    subformats = []
    for name, _kind, _width in columns:
        fmt = bytearray(64 if wide else 52)
        fmt[0:word] = signature(COLUMN_FORMAT)
        at = 3 * word + 22
        f_offset, f_length = formats_at.get(name, (0, 0))
        for k, value in enumerate((0, f_offset, f_length, 0, 0, 0)):
            pack(fmt, "H", at + 2 * k, value)
        subformats.append(fmt)

    # ---- the rows
    spelled_rows = []
    for k, row in enumerate(rows):
        if len(row) != len(columns):
            raise ValueError(f"row {k} spells {len(row)} cells for {len(columns)} columns")
        spelled = bytearray()
        for (name, kind, width), value in zip(columns, row):
            if kind == "n":
                number = struct.pack(">d", float(value))
                if number[width:] != b"\x00" * (8 - width):
                    raise ValueError(f"{name}: {value!r} does not fit {width} bytes")
                # The number's leading bytes: most significant first in a
                # big-endian file, least significant first in a little-endian one.
                spelled += number[:width] if not little else number[:width][::-1]
            else:
                if value is None:
                    text = b""
                else:
                    text = value if isinstance(value, bytes) else value.encode("latin-1")
                if len(text) > width:
                    raise ValueError(f"{name}: {value!r} is wider than {width} bytes")
                spelled += text + b" " * (width - len(text))
        spelled_rows.append(spelled)

    def place(page, subheaders, sub_start):
        """Pointers to ``subheaders`` — ``(bytes, compression byte)`` — laid at ``sub_start`` of ``page``, from its lead on.

        Every pointer types its subheader as a row (the type byte the format
        gives rows and metadata alike); a compressed row's carries the
        compression byte 4.
        """
        if sub_start + sum(len(s) for s, _c in subheaders) > page_size:
            raise ValueError("the page is too small for the rows and the subheaders")
        for k, (sub, compression) in enumerate(subheaders):
            page[sub_start : sub_start + len(sub)] = sub
            at = lead + 8 + pointer * k
            pack(page, WF, at, sub_start)
            pack(page, WF, at + word, len(sub))
            page[at + 2 * word] = compression
            page[at + 2 * word + 1] = 1
            sub_start += len(sub)

    def page_of(kind, subheaders):
        page = bytearray(page_size)
        pack(page, "H", lead, kind)
        pack(page, "H", lead + 4, len(subheaders))
        return page

    subheaders = [(s, 0) for s in [row_size, column_size, text_subheader(0), name_refs, attributes]]
    subheaders += [(s, 0) for s in subformats[:format_count]]
    if compress is not None:
        # Each row a compressed stream of its own, behind the metadata.
        subheaders += [(compress_row(spelled, compress), 4) for spelled in spelled_rows]
    pages = []
    page = page_of(meta_type, subheaders)
    if meta_type == MIX:
        rows_start = lead + 8 + pointer * len(subheaders)
        rows_start += rows_start % 8
        for k, spelled in enumerate(spelled_rows):
            page[rows_start + row_length * k : rows_start + row_length * (k + 1)] = spelled
        place(page, subheaders, rows_start + row_length * len(spelled_rows))
    else:
        place(page, subheaders, lead + 8 + pointer * len(subheaders))
    pages.append(page)
    if second_text:
        page = page_of(AMD, [text_subheader(1)])
        place(page, [(text_subheader(1), 0)], lead + 8 + pointer)
        pages.append(page)
    if meta_type != MIX and compress is None:
        # The rows over ``row_pages`` DATA pages, as evenly as they go; a
        # page's block count, two bytes behind its type, says how many it
        # holds, from eight bytes after its lead on.
        per = (len(spelled_rows) + row_pages - 1) // row_pages
        for k in range(row_pages):
            part = spelled_rows[k * per : (k + 1) * per]
            page = page_of(DATA, [])
            pack(page, "H", lead + 2, len(part))
            if lead + 8 + row_length * len(part) > page_size:
                raise ValueError(f"the page is too small for {len(part)} rows")
            for j, spelled in enumerate(part):
                page[lead + 8 + row_length * j : lead + 8 + row_length * (j + 1)] = spelled
            pages.append(page)
    return bytes(header) + b"".join(bytes(page) for page in pages)


def compact_values(width):
    """Three numbers a double spells in exactly its leading ``width`` bytes.

    Each has a nonzero byte in position ``width`` and zero bytes after it,
    so narrowing the column to fewer bytes would change it. One byte spells
    no mantissa at all; that column is three zeros.
    """
    if width == 1:
        return [0.0, 0.0, 0.0]
    found = []
    for sign_exponent, marker in ((0x3FF, 0x01), (0x405, 0x80), (0xC00, 0xFF)):
        bits = (sign_exponent << 52) | (marker << (8 * (8 - width)))
        found.append(struct.unpack(">d", struct.pack(">Q", bits))[0])
    return found


def from_bits(bits):
    """The double whose big-endian spelling is ``bits``: a missing value's, or a NaN's."""
    return struct.unpack(">d", struct.pack(">Q", bits))[0]
