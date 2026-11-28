"""Encoders for the streams of a hand-built stripe, and a file assembled
from such stripes: what the generator uses to spell runs the reference
writer never picks — a short repeat of a wide value, a patched base with a
skipped gap, a falling delta — and shapes it never writes, sound and
broken. The run length encodings are spelled here from the format's
specification and the reference reader's decoder; the reference reader then
reads every sound file back, so a misspelt run shows as a disagreement
rather than as agreement between two spellings of one mistake.

A signed value rides its zigzag code in the version 2 encoding — a
non-negative value's too — in a short repeat, a direct run and a delta's
first value and first step; the offsets above a patched base, the patches,
the gaps and a delta's later steps ride plain. A patched base rides big
endian in sign and magnitude, its top bit the sign.
"""
import struct

import orclayout as O  # noqa: E402

PRESENT, DATA, LENGTH, DICT_DATA, BLOOM_FILTER, SECONDARY, ROW_INDEX = 0, 1, 2, 3, 4, 5, 6
BLOOM_FILTER_UTF8, ENCRYPTED_INDEX, ENCRYPTED_DATA = 8, 9, 10
DIRECT, DICTIONARY, DIRECT_V2, DICTIONARY_V2 = 0, 1, 2, 3
BOOLEAN, BYTE, SHORT, INT, LONG, FLOAT, DOUBLE, STRING, BINARY, TIMESTAMP = range(10)
LIST, MAP, STRUCT, UNION, DECIMAL, DATE, VARCHAR, CHAR, TIMESTAMP_INSTANT = range(10, 19)

# the bit widths a run header's five bits name, by their code
WIDTHS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
          26, 28, 30, 32, 40, 48, 56, 64]
CODES = {w: i for i, w in enumerate(WIDTHS)}

I64_MIN, I64_MAX = -(2 ** 63), 2 ** 63 - 1
ORC_EPOCH = 1420070400


def zigzag(v):
    return (v << 1) if v >= 0 else ((-v) << 1) - 1


def unzigzag(u):
    return (u >> 1) ^ -(u & 1)


def signed_code(v):
    """The unsigned code a signed value rides in the version 2 encoding:
    its zigzag code, a non-negative value's included."""
    return zigzag(v)


def signed_bits(values):
    """How many bits the widest of the values' codes needs; none for a
    list of zeros."""
    return max(signed_code(v).bit_length() for v in values)


def plain_bits(values):
    """How many bits the widest plain value needs: an offset above a
    base, a patch, a gap, a delta's size."""
    return max(v.bit_length() for v in values)


def least_width(bits):
    """The least of the format's widths that holds so many bits."""
    return WIDTHS[0] if bits == 0 else min(w for w in WIDTHS if w >= bits)


def bits_bytes(items):
    """(value, width) pairs as one bit stream, most significant bit
    first, its end padded to a byte."""
    acc = 0
    held = 0
    out = bytearray()
    for value, width in items:
        assert width == 0 or value < (1 << width), (value, width)
        acc = (acc << width) | value
        held += width
        while held >= 8:
            held -= 8
            out.append((acc >> held) & 0xFF)
        acc &= (1 << held) - 1
    if held:
        out.append((acc << (8 - held)) & 0xFF)
    return bytes(out)


def closest_fixed(total):
    """The width a patch list's entries are packed in: the least of the
    format's widths that holds a patch's width and its gap's together."""
    return least_width(total)


# ── the byte run length encoding ─────────────────────────────────────

def byte_rle_run(byte, count):
    """A run of `count` equal bytes, 3 to 130."""
    assert 3 <= count <= 130
    return bytes([count - 3, byte])


def byte_rle_literals(data):
    """Literal bytes, 128 to a run at most."""
    out = bytearray()
    for at in range(0, len(data), 128):
        chunk = data[at:at + 128]
        out.append(256 - len(chunk))
        out.extend(chunk)
    return bytes(out)


def bits_packed(flags):
    """Bits packed most significant bit first, the last byte padded."""
    packed = bytearray()
    for at in range(0, len(flags), 8):
        chunk = flags[at:at + 8]
        byte = 0
        for flag in chunk:
            byte = (byte << 1) | (1 if flag else 0)
        packed.append(byte << (8 - len(chunk)))
    return bytes(packed)


def boolean_bits(flags):
    """The bits of a present stream or a boolean column as byte run length
    literals."""
    return byte_rle_literals(bits_packed(flags))


def present(flags):
    return boolean_bits(flags)


# ── the integer run length encoding of the 0.11 format ───────────────

def rle1_run(count, delta, first):
    """A run of `count` values a fixed `delta` apart, 3 to 130, the first
    value a zigzag varint."""
    assert 3 <= count <= 130 and -128 <= delta <= 127
    return bytes([count - 3, delta & 0xFF]) + O.put_varint(zigzag(first))


def rle1_literals(values):
    """Literal values, zigzag varints, 128 to a run at most."""
    out = bytearray()
    for at in range(0, len(values), 128):
        chunk = values[at:at + 128]
        out.append(256 - len(chunk))
        for v in chunk:
            out.extend(O.put_varint(zigzag(v)))
    return bytes(out)


def rle1_unsigned_literals(values):
    """Literal values of an unsigned stream, plain varints, 128 to a run
    at most."""
    out = bytearray()
    for at in range(0, len(values), 128):
        chunk = values[at:at + 128]
        out.append(256 - len(chunk))
        for v in chunk:
            out.extend(O.put_varint(v))
    return bytes(out)


# ── the integer run length encoding of the 0.12 format ───────────────

def pack_signed(values, width):
    """Signed values of one width, packed in their zigzag codes."""
    return bits_bytes([(signed_code(v), width) for v in values])


def pack_plain(values, width):
    """Plain values of one width, packed."""
    return bits_bytes([(v, width) for v in values])


def rle2_short_repeat(value, count, width=None):
    """A short repeat run: 3 to 10 equal values, in 1 to 8 bytes, big
    endian; `width` the byte width, the narrowest that holds the code
    unless given."""
    assert 3 <= count <= 10
    code = signed_code(value)
    width = width or max(1, (code.bit_length() + 7) // 8)
    assert code < (1 << (8 * width)) and 1 <= width <= 8, (value, width)
    return bytes([((width - 1) << 3) | (count - 3)]) + code.to_bytes(width, "big")


def rle2_direct(values, width=None):
    """A direct run of a signed stream: 1 to 512 values of one width, the
    narrowest that holds them all unless given."""
    assert 1 <= len(values) <= 512
    width = width or least_width(signed_bits(values))
    assert width in CODES
    header = 0x40 | (CODES[width] << 1) | ((len(values) - 1) >> 8)
    return bytes([header, (len(values) - 1) & 0xFF]) + pack_signed(values, width)


def rle2_direct_unsigned(values, width=None):
    """A direct run of an unsigned stream: the values ride plain."""
    assert 1 <= len(values) <= 512
    width = width or least_width(plain_bits(values))
    header = 0x40 | (CODES[width] << 1) | ((len(values) - 1) >> 8)
    return bytes([header, (len(values) - 1) & 0xFF]) + pack_plain(values, width)


def rle2_patched(values, base=None, width=None, patch_width=None, gap_width=None):
    """A patched base run: every value its base plus an offset of `width`
    bits, the offsets that do not fit patched from a list — an entry a gap
    and the value's missing high bits, packed side by side. The first gap
    counts from the run's head, each later one from the last patched value;
    a gap of 255 with a patch of zero passes over 255 values. The widths
    are the narrowest that hold their bits unless given."""
    assert 1 <= len(values) <= 512
    base = min(values) if base is None else base
    assert base <= min(values)
    offsets = [v - base for v in values]
    width = width or least_width(plain_bits(offsets))
    assert width in CODES
    over = [i for i, o in enumerate(offsets) if o >= (1 << width)]
    highs = [offsets[i] >> width for i in over]
    gaps = [over[0]] + [over[i] - over[i - 1] for i in range(1, len(over))]
    patch_width = patch_width or least_width(plain_bits(highs))
    gap_width = gap_width or least_width(plain_bits(gaps))
    assert all(0 < h < (1 << patch_width) for h in highs), (patch_width, highs)
    assert all(g < (1 << gap_width) for g in gaps), (gap_width, gaps)
    assert patch_width + gap_width <= 64, (patch_width, gap_width)
    entries = []
    for g, h in zip(gaps, highs):
        while g >= 255:
            entries.append((255, 0))
            g -= 255
        entries.append((g, h))
    assert 0 < len(entries) <= 31, len(entries)
    # the base in sign and magnitude, in the least whole bytes that hold
    # its magnitude with the top bit to spare
    base_width = max(1, abs(base).bit_length() // 8 + 1)
    assert base_width <= 8
    base_code = ((1 << (8 * base_width - 1)) | -base) if base < 0 else base
    header = bytes([0x80 | (CODES[width] << 1) | ((len(values) - 1) >> 8), (len(values) - 1) & 0xFF,
                    ((base_width - 1) << 5) | CODES[patch_width], ((gap_width - 1) << 5) | len(entries)])
    low = [o & ((1 << width) - 1) for o in offsets]
    # each entry its gap above its patch, in the fixed width that holds
    # both: the least of the format's widths past their sum
    slot = closest_fixed(patch_width + gap_width)
    patch_list = bits_bytes([((g << patch_width) | p, slot) for g, p in entries])
    return header + base_code.to_bytes(base_width, "big") + pack_plain(low, width) + patch_list


def rle2_delta(values, width=None):
    """A delta run: 2 to 512 values whose steps after the first all lie
    one side of zero, the steps packed plain and added or subtracted as the
    first step's sign says; a width of zero names steps all equal to the
    first."""
    assert 2 <= len(values) <= 512
    steps = [values[i] - values[i - 1] for i in range(1, len(values))]
    if steps[0] > 0:
        assert all(s >= 0 for s in steps), steps
    elif steps[0] < 0:
        assert all(s <= 0 for s in steps), steps
    if width is None:
        width = 0 if all(s == steps[0] for s in steps) else least_width(plain_bits([abs(s) for s in steps[1:]]))
    assert width == 0 or width in CODES
    header = bytes([0xC0 | (CODES.get(width, 0) << 1) | ((len(values) - 1) >> 8), (len(values) - 1) & 0xFF])
    rest = b"" if width == 0 else pack_plain([abs(s) for s in steps[1:]], width)
    return header + O.put_varint(zigzag(values[0])) + O.put_varint(zigzag(steps[0])) + rest


def rle2(values, speller=rle2_direct):
    """A signed stream of any length as runs of at most 512 values."""
    return b"".join(speller(values[at:at + 512]) for at in range(0, len(values), 512))


def rle2_unsigned(values):
    """An unsigned stream of any length as direct runs."""
    return b"".join(rle2_direct_unsigned(values[at:at + 512]) for at in range(0, len(values), 512))


def rle1(values):
    """A version 1 signed stream of any length as literal runs."""
    return b"".join(rle1_literals(values[at:at + 128]) for at in range(0, len(values), 128))


def rle1_unsigned(values):
    """A version 1 unsigned stream of any length as literal runs."""
    return b"".join(rle1_unsigned_literals(values[at:at + 128]) for at in range(0, len(values), 128))


def unsigned(values, encoding=DIRECT_V2):
    """An unsigned stream — a string's or a list's lengths, a dictionary's
    ids — spelled in the column's encoding: plain, never zigzag coded."""
    return rle1_unsigned(values) if encoding in (DIRECT, DICTIONARY) else rle2_unsigned(values)


def signed(values, encoding=DIRECT_V2):
    """A signed stream spelled in the column's encoding."""
    return rle1(values) if encoding in (DIRECT, DICTIONARY) else rle2(values)


# ── the other streams ────────────────────────────────────────────────

def doubles(values):
    """A double column's data stream: little endian IEEE values."""
    return b"".join(struct.pack("<d", v) for v in values)


def floats(values):
    """A float column's data stream: little endian IEEE values."""
    return b"".join(struct.pack("<f", v) for v in values)


def strip_nanos(nanos):
    """A timestamp's nanoseconds as the writers spell them: a count not
    ending in two zeros rides whole with no trailing-zero count; one that
    does loses two digits, and more while they are zeros, the count in the
    low three bits from one — so a reader scales the mantissa by ten to the
    count plus one. Thus 1000 nanoseconds is 0x0a and 100000 is 0x0c."""
    if nanos == 0:
        return 0
    if nanos % 100 != 0:
        return nanos << 3
    nanos //= 100
    zeros = 1
    while nanos % 10 == 0 and zeros < 7:
        nanos //= 10
        zeros += 1
    return (nanos << 3) | zeros


def legacy_nanos(nanos):
    """A negative nanosecond remainder as the first writers spelled one:
    the same formula, on the negative count — so the packed value is
    negative too, in two's complement as an unsigned stream carries it.
    Today's writers keep the remainder positive and the seconds below it."""
    assert nanos < 0
    return strip_nanos(nanos) % (2 ** 64)


def unbounded_zigzag(v):
    """A decimal's unscaled value as the format spells it: a zigzag
    varint of any width."""
    return O.put_varint(zigzag(v))


# ── the messages ─────────────────────────────────────────────────────

def type_msg(kind, subtypes=(), names=(), precision=None, scale=None, maximum_length=None, unpacked=False):
    """A type of the footer's tree. The subtypes ride in one packed field
    unless `unpacked` spells each one a field of its own."""
    out = O.f_varint(1, kind)
    if subtypes and unpacked:
        for s in subtypes:
            out += O.f_varint(2, s)
    elif subtypes:
        out += O.f_packed(2, list(subtypes))
    for name in names:
        out += O.f_bytes(3, name.encode("utf-8"))
    if maximum_length is not None:
        out += O.f_varint(4, maximum_length)
    if precision is not None:
        out += O.f_varint(5, precision)
    if scale is not None:
        out += O.f_varint(6, scale)
    return out


def stream_msg(kind, column, length):
    return O.f_varint(1, kind) + O.f_varint(2, column) + O.f_varint(3, length)


def encoding_msg(kind, dictionary_size=None):
    out = O.f_varint(1, kind)
    if dictionary_size is not None:
        out += O.f_varint(2, dictionary_size)
    return out


class Column:
    """A column of a hand-built file: its type's kind and fields, the
    message that names its encoding, its streams as `(kind, bytes)`, and
    its children — a list's element, a struct's fields, each with its own
    streams."""

    def __init__(self, kind, encoding=DIRECT_V2, streams=(), children=(), names=(),
                 precision=None, scale=None, maximum_length=None, dictionary_size=None, unpacked=False):
        self.kind = kind
        self.encoding = encoding if isinstance(encoding, bytes) else encoding_msg(encoding, dictionary_size)
        self.streams = list(streams)
        self.children = list(children)
        self.names = list(names)
        self.precision, self.scale, self.maximum_length = precision, scale, maximum_length
        self.unpacked = unpacked

    def message(self, child_ids):
        return type_msg(self.kind, child_ids, self.names, self.precision, self.scale, self.maximum_length,
                        self.unpacked)


def listed(values):
    """The present values of a column: None spells an absent one."""
    return [v for v in values if v is not None]


def flags_of(values):
    """The present bits of a column."""
    return [v is not None for v in values]


def int_col(kind, data, encoding=DIRECT_V2, flags=None, extra=()):
    """An integer column of the type kind `kind` whose DATA stream is
    `data` as spelled: an optional PRESENT stream before it."""
    streams = []
    if flags is not None:
        streams.append((PRESENT, present(flags)))
    streams.append((DATA, data))
    streams.extend(extra)
    return Column(kind, encoding, streams)


def int_values(kind, values, encoding=DIRECT_V2, spelling=None):
    """An integer column spelled from `values`, None an absent one: a
    PRESENT stream when a value is absent, and the present values as
    direct runs, literal ones under the 0.11 format."""
    spelling = spelling or (rle1 if encoding in (DIRECT, DICTIONARY) else rle2)
    streams = []
    if None in values:
        streams.append((PRESENT, present(flags_of(values))))
    streams.append((DATA, spelling(listed(values))))
    return Column(kind, encoding, streams)


def bool_col(values, encoding=DIRECT_V2):
    """A boolean column: its bits as a byte run length stream."""
    streams = []
    if None in values:
        streams.append((PRESENT, present(flags_of(values))))
    streams.append((DATA, boolean_bits([bool(v) for v in listed(values)])))
    return Column(BOOLEAN, encoding, streams)


def float_col(values, kind=DOUBLE):
    """A float or double column: little endian IEEE values."""
    streams = []
    if None in values:
        streams.append((PRESENT, present(flags_of(values))))
    pack = floats if kind == FLOAT else doubles
    streams.append((DATA, pack(listed(values))))
    return Column(kind, DIRECT_V2, streams)


def string_col(values, encoding=DIRECT_V2, lengths=None, data=None, with_present=None, kind=STRING, **fields):
    """A direct string column of `values`, strings or None: a PRESENT
    stream when a value is absent, the byte lengths of the present values
    as one direct run unless `lengths` spells them, and the bytes unless
    `data` gives them."""
    flags = [v is not None for v in values]
    codes = [len(v.encode("utf-8")) for v in values if v is not None]
    lengths = unsigned(codes, encoding) if lengths is None else lengths
    data = b"".join(v.encode("utf-8") for v in values if v is not None) if data is None else data
    streams = []
    if with_present or (with_present is None and not all(flags)):
        streams.append((PRESENT, present(flags)))
    streams += [(LENGTH, lengths), (DATA, data)]
    return Column(kind, encoding, streams, **fields)


def dictionary_col(entries, ids, encoding=DICTIONARY_V2, present_rows=None, dictionary_size=None):
    """A dictionary string column: `entries` the dictionary's strings,
    `ids` the entry of each present value. The entries' lengths, the ids
    and the entries' bytes ride three streams; a PRESENT stream when
    `present_rows` gives the bits."""
    lengths = [len(e.encode("utf-8")) for e in entries]
    streams = []
    if present_rows is not None:
        streams.append((PRESENT, present(present_rows)))
    streams += [
        (LENGTH, unsigned(lengths, encoding)),
        (DATA, unsigned(ids, encoding)),
        (DICT_DATA, b"".join(e.encode("utf-8") for e in entries)),
    ]
    size = len(entries) if dictionary_size is None else dictionary_size
    return Column(STRING, encoding_msg(encoding, size), streams)


def timestamp_col(seconds, nanos, encoding=DIRECT_V2, kind=TIMESTAMP):
    """A timestamp column: the seconds after the 2015 epoch as a signed
    stream and the nanoseconds in their stripped spelling as an unsigned
    one — a negative remainder in the first writers' spelling; a row
    whose seconds are None is absent."""
    pairs = [(s, n) for s, n in zip(seconds, nanos) if s is not None]
    streams = []
    if len(pairs) != len(seconds):
        streams.append((PRESENT, present(flags_of(seconds))))
    stripped = [strip_nanos(n) if n >= 0 else legacy_nanos(n) for _, n in pairs]
    streams += [(DATA, signed([s for s, _ in pairs], encoding)), (SECONDARY, unsigned(stripped, encoding))]
    return Column(kind, encoding, streams)


def decimal_col(unscaled, scale, encoding=DIRECT_V2, precision=38, scales=None):
    """A decimal column: each present value an unbounded zigzag varint,
    then the scales as a signed stream — one scale for all, or `scales`
    one a present value."""
    per_value = scales if scales is not None else [scale] * len(unscaled)
    pairs = [(u, s) for u, s in zip(unscaled, per_value) if u is not None]
    streams = []
    if len(pairs) != len(unscaled):
        streams.append((PRESENT, present(flags_of(unscaled))))
    streams += [(DATA, b"".join(unbounded_zigzag(u) for u, _ in pairs)),
                (SECONDARY, signed([s for _, s in pairs], encoding))]
    return Column(DECIMAL, encoding, streams, precision=precision, scale=scale)


def list_col(lengths, child, encoding=DIRECT_V2):
    """A list column of the given lengths — None an absent list — over
    `child`, a Column whose streams spell its elements. An absent list has
    no length in the stream: only the present ones do."""
    streams = []
    if None in lengths:
        streams.append((PRESENT, present(flags_of(lengths))))
    streams.append((LENGTH, unsigned(listed(lengths), encoding)))
    return Column(LIST, encoding, streams, children=[child])


def struct_col(fields, names, encoding=DIRECT, present_rows=None):
    """A struct column over `fields`, each a Column, with their names; a
    PRESENT stream when `present_rows` gives a struct's bits."""
    streams = []
    if present_rows is not None:
        streams.append((PRESENT, present(present_rows)))
    return Column(STRUCT, encoding, streams, children=fields, names=names)


# ── a file ───────────────────────────────────────────────────────────

def pre_order(columns):
    """The columns and their descendants, parents before children."""
    order = []

    def walk(c):
        order.append(c)
        for ch in c.children:
            walk(ch)

    for c in columns:
        walk(c)
    return order


def build_file(columns, rows, compression=0, version=(0, 12), root_present=None, extra_streams=(),
               stripe_footer_extra=b"", footer_extra=b"", footer_rows=None, index_entries=0,
               names=None, metadata=b"", writer_version=None, block_size=None, ps_extra=b"",
               footer_prefix=b"", types=None, encodings=None, streams=None, root=None):
    """A one-stripe file of `columns` — each a Column, its type in the
    footer's tree in pre-order under the root struct — with the row count
    `rows`, or `footer_rows` in the footer when a test wants the two to
    disagree. The root struct's PRESENT stream is written when
    `root_present` gives its bits; `extra_streams` are more streams,
    `(kind, column, bytes)`, listed last; the first `index_entries` streams
    are the stripe's index. `types`, `encodings`, `streams` and `root`
    replace what the columns would spell, for a footer that does not hold
    together. `footer_prefix` goes between the footer's stripes and its
    types and `footer_extra` after its row count; `metadata` is the file's
    metadata section and `ps_extra` the PostScript's bytes before its
    magic. The PostScript always names the compression kind."""
    order = pre_order(columns)
    ids = {id(c): i + 1 for i, c in enumerate(order)}
    if root is None:
        root = type_msg(STRUCT, [ids[id(c)] for c in columns],
                        names if names is not None else ["c%d" % i for i in range(len(columns))])
    spelled = [(k, ids[id(c)], payload) for c in order for k, payload in c.streams]
    if root_present is not None:
        spelled.insert(0, (PRESENT, 0, present(root_present)))
    spelled.extend(extra_streams)
    if streams is not None:
        spelled = list(streams)
    body = b"".join(s[2] for s in spelled)
    index_length = sum(len(s[2]) for s in spelled[:index_entries])
    stripe_footer = b"".join(O.f_bytes(1, stream_msg(k, c, len(p))) for k, c, p in spelled)
    encs = encodings if encodings is not None else [encoding_msg(DIRECT)] + [c.encoding for c in order]
    stripe_footer += b"".join(O.f_bytes(2, e) for e in encs) + stripe_footer_extra
    # the stripe's fields as a writer of today spells them: a zero is not
    # written
    stripe = b""
    for num, value in ((1, 3), (2, index_length), (3, len(body) - index_length),
                       (4, len(stripe_footer)), (5, rows)):
        if value:
            stripe += O.f_varint(num, value)
    footer = O.f_varint(1, 3) + O.f_varint(2, len(body) + len(stripe_footer)) + O.f_bytes(3, stripe)
    footer += footer_prefix
    for t in ([root] if types is None else []) + ([c.message([ids[id(ch)] for ch in c.children]) for c in order]
                                                  if types is None else types):
        footer += O.f_bytes(4, t)
    footer += O.f_varint(6, rows if footer_rows is None else footer_rows)
    footer += footer_extra
    ps = O.f_varint(1, len(footer)) + O.f_varint(2, compression)
    if block_size is not None:
        ps += O.f_varint(3, block_size)
    if version is not None:
        ps += O.f_packed(4, list(version))
    if metadata:
        ps += O.f_varint(5, len(metadata))
    if writer_version is not None:
        ps += O.f_varint(6, writer_version)
    ps += ps_extra + O.f_bytes(8000, b"ORC")
    return b"ORC" + body + stripe_footer + metadata + footer + ps + bytes([len(ps)])
