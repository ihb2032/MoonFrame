"""An independent reading of the ORC container's layout, written from the
format's specification and from the reference implementation's sources:
the file tail (PostScript, Footer, Metadata), the stripes and their
footers, and the location of every stream. It stops short of decoding
column values — the cells in a sidecar come from the reference reader —
and serves the generator: to describe what a file holds, and to derive a
file from another by patching a field.

The metadata is in the Protocol Buffers wire format: each field is a
base-128 varint tag (field number and wire type) followed by its value; a
length-delimited value is its length and bytes; a nested message is a
length-delimited value that is itself a sequence of fields.

Every stream's declared length is its length on disk, compression block
headers included: a stream is cut from the stripe's raw bytes and
inflated on its own, the way a reader that seeks to a stream does.
"""
import struct
import zlib

MAGIC = b"ORC"
ORC_EPOCH = 1420070400  # 2015-01-01T00:00:00Z: a timestamp's seconds count from here
COMPRESSION = {0: "NONE", 1: "ZLIB", 2: "SNAPPY", 3: "LZO", 4: "LZ4", 5: "ZSTD"}
KIND = {0: "BOOLEAN", 1: "BYTE", 2: "SHORT", 3: "INT", 4: "LONG", 5: "FLOAT", 6: "DOUBLE", 7: "STRING",
        8: "BINARY", 9: "TIMESTAMP", 10: "LIST", 11: "MAP", 12: "STRUCT", 13: "UNION", 14: "DECIMAL",
        15: "DATE", 16: "VARCHAR", 17: "CHAR", 18: "TIMESTAMP_INSTANT"}
STREAM = {0: "PRESENT", 1: "DATA", 2: "LENGTH", 3: "DICTIONARY_DATA", 4: "DICTIONARY_COUNT",
          5: "SECONDARY", 6: "ROW_INDEX", 7: "BLOOM_FILTER", 8: "BLOOM_UTF8", 9: "ENCRYPTED_INDEX",
          10: "ENCRYPTED_DATA", 100: "STRIPE_STATISTICS", 101: "FILE_STATISTICS"}
ENCODING = {0: "DIRECT", 1: "DICTIONARY", 2: "DIRECT_V2", 3: "DICTIONARY_V2"}
PRESENT, DATA, LENGTH, DICT_DATA, DICT_COUNT, SECONDARY, ROW_INDEX = 0, 1, 2, 3, 4, 5, 6
INDEX_STREAMS = (ROW_INDEX, 7, 8)


class LayoutError(Exception):
    """Bytes that do not hold together as the layout says they must."""


# ── the wire format ──────────────────────────────────────────────────

def varint(b, at):
    """The base-128 varint at `at`: (value, the offset past it). A varint
    is at most ten bytes; the tenth may carry only its lowest bit."""
    v = 0
    shift = 0
    while True:
        if at >= len(b):
            raise LayoutError("a varint that runs past the end at byte %d" % at)
        byte = b[at]
        at += 1
        if shift == 63 and byte > 1:
            raise LayoutError("a varint wider than 64 bits at byte %d" % at)
        v |= (byte & 0x7F) << shift
        if byte < 0x80:
            return v, at
        shift += 7
        if shift > 63:
            raise LayoutError("a varint longer than ten bytes at byte %d" % at)


def zigzag(u):
    return (u >> 1) ^ -(u & 1)


def fields(b, base=0):
    """Every field of one message, in the order it is spelled: (number,
    wire type, value, offset of the tag). A varint field's value is an
    int, a fixed one its bytes, a length-delimited one its bytes."""
    at = 0
    out = []
    while at < len(b):
        tag_at = at
        tag, at = varint(b, at)
        num, wire = tag >> 3, tag & 7
        if num == 0:
            raise LayoutError("field number 0 at byte %d" % (base + tag_at))
        if wire == 0:
            v, at = varint(b, at)
        elif wire == 1:
            if at + 8 > len(b):
                raise LayoutError("a 64-bit field that runs past the end at byte %d" % (base + at))
            v = b[at:at + 8]
            at += 8
        elif wire == 2:
            n, at = varint(b, at)
            if n > len(b) - at:
                raise LayoutError("a %d-byte field that runs past the end at byte %d" % (n, base + at))
            v = b[at:at + n]
            at += n
        elif wire == 5:
            if at + 4 > len(b):
                raise LayoutError("a 32-bit field that runs past the end at byte %d" % (base + at))
            v = b[at:at + 4]
            at += 4
        else:
            raise LayoutError("wire type %d at byte %d" % (wire, base + tag_at))
        out.append((num, wire, v, base + tag_at))
    return out


def get(b, num, default=None):
    """The value of the last field `num` of message `b`, or `default`."""
    found = default
    for n, w, v, _ in fields(b):
        if n == num:
            found = v
    return found


def all_of(b, num):
    """Every field `num` of message `b`, in order."""
    return [v for n, w, v, _ in fields(b) if n == num]


def packed(b, num):
    """A repeated integer field, packed or not: a packed field arrives as
    one length-delimited run of varints, an unpacked one as a varint each."""
    out = []
    for n, w, v, _ in fields(b):
        if n == num:
            if w == 2:
                at = 0
                while at < len(v):
                    x, at = varint(v, at)
                    out.append(x)
            elif w == 0:
                out.append(v)
            else:
                raise LayoutError("field %d in wire type %d" % (num, w))
    return out


def uints(b, num):
    """A repeated uint32 field read as varints (the unpacked spelling)."""
    return [v for n, w, v, _ in fields(b) if n == num and w == 0]


# ── an encoder, for derived files ────────────────────────────────────

def put_varint(v):
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def tag(num, wire):
    return put_varint((num << 3) | wire)


def f_varint(num, v):
    return tag(num, 0) + put_varint(v)


def f_bytes(num, v):
    return tag(num, 2) + put_varint(len(v)) + v


def f_packed(num, values):
    return f_bytes(num, b"".join(put_varint(v) for v in values))


def refield(message, num, encode):
    """The message with every field `num` replaced by `encode(old) -> bytes`
    (a whole field, tag included), in place; other fields as they were."""
    return rebuild(message, lambda n, w, v: encode(v, w) if n == num else keep(n, w, v))


def keep(num, wire, value):
    """One field as it was spelled: its tag and its value."""
    if wire == 0:
        return f_varint(num, value)
    if wire == 2:
        return f_bytes(num, value)
    return tag(num, wire) + value


def rebuild(message, encode):
    """The message with every field handed to `encode(number, wire type,
    value) -> bytes`, a whole field each; an empty answer drops the field,
    so the field order is the caller's to keep."""
    out = b""
    for n, w, v, _ in fields(message):
        out += encode(n, w, v)
    return out


def set_varints(message, changes):
    """The message with its integer fields set: `changes` maps a field
    number to a value, or to None to drop the field. A field the message
    does not carry is inserted where its number falls, so the fields stay
    in ascending order — the PostScript keeps its magic last."""
    present = {n for n, _, _, _ in fields(message)}
    pending = sorted(n for n in changes if n not in present and changes[n] is not None)
    out = b""
    for n, w, v, _ in fields(message):
        while pending and pending[0] < n:
            out += f_varint(pending[0], changes[pending[0]])
            pending.pop(0)
        if n in changes:
            if changes[n] is not None:
                out += f_varint(n, changes[n])
        else:
            out += keep(n, w, v)
    for n in pending:
        out += f_varint(n, changes[n])
    return out


def drop_field(message, num):
    return refield(message, num, lambda v, w: b"")


# ── compression blocks ───────────────────────────────────────────────

def inflate(codec, payload, limit=None):
    """One compressed block's payload inflated. zlib is the standard
    library's; the other codecs ride the cramjam wheels. An lz4 block
    names no size of its own, so `limit` — the file's block size — bounds
    what it may inflate to."""
    if codec == 1:
        return zlib.decompressobj(-15).decompress(payload)
    import cramjam  # noqa: E402
    if codec == 2:
        return bytes(cramjam.snappy.decompress_raw(payload))
    if codec == 4:
        # the block names no size: it inflates into a buffer of the block
        # size, and the wheel answers how many bytes it wrote
        output = bytearray(limit or 256 * 1024)
        return bytes(output[:cramjam.lz4.decompress_block_into(payload, output)])
    if codec == 5:
        return bytes(cramjam.zstd.decompress(payload))
    raise LayoutError("compression kind %d" % codec)


def inflate_stream(raw, codec, at, block_size=None):
    """The logical bytes of one stream: its blocks, each three header
    bytes and a payload, inflated in turn; `at` is the stream's offset in
    the file, for the errors."""
    if codec == 0:
        return raw
    out = b""
    pos = 0
    while pos < len(raw):
        if pos + 3 > len(raw):
            raise LayoutError("a block header cut short at byte %d" % (at + pos))
        h = raw[pos] | raw[pos + 1] << 8 | raw[pos + 2] << 16
        n = h >> 1
        if n == 0:
            raise LayoutError("a block that declares no bytes at byte %d" % (at + pos))
        if pos + 3 + n > len(raw):
            raise LayoutError("a block of %d bytes that runs past its stream at byte %d" % (n, at + pos))
        payload = raw[pos + 3:pos + 3 + n]
        out += payload if h & 1 else inflate(codec, payload, block_size)
        pos += 3 + n
    return out


def block_header(length, original):
    h = (length << 1) | (1 if original else 0)
    return bytes((h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF))


# ── the file ─────────────────────────────────────────────────────────

class Type:
    def __init__(self, raw, at):
        self.raw = raw
        self.at = at  # offset of the message's bytes within the file's footer region
        self.kind = get(raw, 1, 0)
        self.subtypes = packed(raw, 2)
        try:
            self.names = [v.decode("utf-8") for v in all_of(raw, 3)]
        except UnicodeDecodeError:
            raise LayoutError("a field name not well-formed as UTF-8 in the type at byte %d" % at)
        self.max_length = get(raw, 4, 0)
        self.precision = get(raw, 5, 0)
        self.scale = get(raw, 6, 0)

    def __repr__(self):
        return KIND.get(self.kind, "KIND%d" % self.kind)


class Stream:
    def __init__(self, kind, column, length, at):
        self.kind = kind
        self.column = column
        self.length = length
        self.at = at  # offset of the stream's first byte in the file

    def __repr__(self):
        return "%s(%d)@%d" % (STREAM.get(self.kind, "KIND%d" % self.kind), self.column, self.at)


class Stripe:
    def __init__(self, info, index):
        self.index = index
        self.offset = get(info, 1, 0)
        self.index_length = get(info, 2, 0)
        self.data_length = get(info, 3, 0)
        self.footer_length = get(info, 4, 0)
        self.rows = get(info, 5, 0)
        self.raw_streams = []
        self.streams = {}  # (kind, column) -> logical bytes
        self.encodings = []
        self.timezone = ""


class File:
    """A file's tail and stripes, read once."""

    def __init__(self, data):
        self.data = data
        n = len(data)
        if n < 4:
            raise LayoutError("a file of %d bytes, too short for a PostScript" % n)
        self.ps_len = data[-1]
        if self.ps_len < 3:
            raise LayoutError("a PostScript of %d bytes" % self.ps_len)
        if data[n - 4:n - 1] != MAGIC and data[:3] != MAGIC:
            raise LayoutError("neither the tail nor the head spells the magic")
        self.ps_at = n - 1 - self.ps_len
        self.ps = data[self.ps_at:n - 1]
        self.footer_length = get(self.ps, 1, 0)
        self.compression = get(self.ps, 2, None)
        self.block_size = get(self.ps, 3, 256 * 1024)
        self.version = packed(self.ps, 4)
        self.metadata_length = get(self.ps, 5, 0)
        self.writer_version = get(self.ps, 6, 0)
        self.magic = get(self.ps, 8000, b"")
        tail = 1 + self.ps_len + self.footer_length
        if tail >= n:
            raise LayoutError("the tail of %d bytes in a file of %d" % (tail, n))
        self.footer_at = n - tail
        if self.footer_at - self.metadata_length < 3:
            raise LayoutError("the metadata of %d bytes runs past the header" % self.metadata_length)
        self.metadata_at = self.footer_at - self.metadata_length
        self.footer = inflate_stream(data[self.footer_at:self.footer_at + self.footer_length], self.compression, self.footer_at, self.block_size)
        self.header_length = get(self.footer, 1, 0)
        self.content_length = get(self.footer, 2, 0)
        self.rows = get(self.footer, 6, 0)
        self.stride = get(self.footer, 8, 0)
        self.writer = get(self.footer, 9, 0)
        self.software = get(self.footer, 12, b"")
        self.encrypted = len(all_of(self.footer, 10)) > 0
        # types, with each message's offset inside the footer: a patch to a
        # type rewrites the footer, and the stripes move with it. The
        # message's bytes start after its tag and length.
        self.types = []
        for num, wire, v, tag_at in fields(self.footer):
            if num == 4:
                if wire != 2:
                    raise LayoutError("a type of the footer arrives in wire type %d, not a message" % wire)
                body_at = tag_at + len(tag(4, 2)) + len(put_varint(len(v)))
                self.types.append(Type(v, body_at))
        self.stripes = []
        pos = 0
        for i, info in enumerate(all_of(self.footer, 3)):
            s = Stripe(info, i)
            cursor = s.offset
            s.footer_at = s.offset + s.index_length + s.data_length
            self.stripes.append(s)

    def stripe(self, i):
        """Stripe `i` with its footer parsed and its streams located."""
        s = self.stripes[i]
        if s.encodings:
            return s
        d = self.data
        raw_footer = d[s.footer_at:s.footer_at + s.footer_length]
        sf = inflate_stream(raw_footer, self.compression, s.footer_at, self.block_size)
        s.footer_raw = raw_footer
        s.footer = sf
        s.timezone = get(sf, 3, b"").decode("utf-8")
        s.encodings = [(get(v, 1, 0), get(v, 2, 0)) for v in all_of(sf, 2)]
        cursor = s.offset
        for v in all_of(sf, 1):
            st = Stream(get(v, 1, 0), get(v, 2, 0), get(v, 3, 0), cursor)
            s.raw_streams.append(st)
            cursor += st.length
        s.end = cursor
        for st in s.raw_streams:
            raw = d[st.at:st.at + st.length]
            s.streams[(st.kind, st.column)] = inflate_stream(raw, self.compression, st.at, self.block_size)
        return s

    def describe(self):
        """A few lines saying what the file holds."""
        out = ["%d bytes; version %s; compression %s, block %s; writerVersion %s; writer %s; software %r; %d rows, stride %s, %d stripes"
               % (len(self.data), self.version, COMPRESSION.get(self.compression, self.compression), self.block_size,
                  self.writer_version, self.writer, self.software, self.rows, self.stride, len(self.stripes))]
        for i, t in enumerate(self.types):
            out.append("  type %d: %s subtypes=%s names=%s maxlen=%s prec=%s scale=%s"
                       % (i, t, t.subtypes, t.names, t.max_length, t.precision, t.scale))
        for i in range(len(self.stripes)):
            s = self.stripe(i)
            out.append("  stripe %d @%d: index %d, data %d, footer %d, rows %d, timezone %r"
                       % (i, s.offset, s.index_length, s.data_length, s.footer_length, s.rows, s.timezone))
            out.append("    streams: " + " ".join(repr(st) for st in s.raw_streams))
            out.append("    encodings: " + " ".join("%d=%s(%s)" % (j, ENCODING.get(k, k), dsz) for j, (k, dsz) in enumerate(s.encodings)))
        return "\n".join(out)
