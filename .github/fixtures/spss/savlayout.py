"""An independent reading of the SPSS system-file layout in Python: the
dictionary's records, the data record under its three compressions, and
the cells under the codec's stated rules. The fixture generator uses it
to spell the cells of files the reference reader refuses, to check its
own reading against the reference reader's where that one reads, and to
derive the synthetic fixtures from files the reference writer wrote.

The byte order of a file is taken from its layout code, the floating
point byte order from its compression bias, as the layout document
gives both.
"""
import math
import struct
import zlib

# The family a print format's type code names, as the format defines it.
FAMILY = {}
for _code in (20, 23, 38, 24, 39, 29, 28, 30):
    FAMILY[_code] = "Date"
for _code in (22, 41):
    FAMILY[_code] = "DateTime"
for _code in (21, 25, 40):
    FAMILY[_code] = "TimeOfDay"

SYSMIS = 0xFFEFFFFFFFFFFFFF
HIGHEST = 0x7FEFFFFFFFFFFFFF
LOWEST = 0xFFEFFFFFFFFFFFFE
EPOCH_DAYS = 141428
EPOCH_MICROS = 12219379200000000

# windows-1252's printable range; the five unassigned bytes spell the
# control character of their own number.
CP1252 = {0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
          0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
          0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
          0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
          0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
          0x9E: 0x017E, 0x9F: 0x0178}
CP1252_INVERSE = {v: k for k, v in CP1252.items()}


def decode_cp1252(raw):
    return "".join(chr(CP1252.get(b, b)) for b in raw)


def encode_cp1252(text):
    return bytes(CP1252_INVERSE[ord(c)] if ord(c) in CP1252_INVERSE else (ord(c) if ord(c) < 256 and not (0x80 <= ord(c) <= 0x9F) else -1) for c in text)


def encoding_name(code):
    return {-1: "UTF-8", 65001: "UTF-8", 28591: "ISO-8859-1", 2: "WINDOWS-1252", 3: "WINDOWS-1252", 1252: "WINDOWS-1252"}.get(code)


def decode_text(raw, encoding):
    """A string cell's bytes as text under the codec's rules: NUL bytes
    dropped, trailing blanks cut, UTF-8 with a truncated character at the
    end cut."""
    raw = bytes(b for b in raw if b != 0).rstrip(b" ")
    if encoding == "UTF-8":
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError as e:
            rest = raw[e.start:]
            if e.start + _len(rest[0]) > len(raw) and all(0x80 <= b <= 0xBF for b in rest[1:]):
                return raw[:e.start].decode("utf-8")
            raise
    if encoding == "ISO-8859-1":
        return raw.decode("latin-1")
    return decode_cp1252(raw)


def _len(lead):
    if lead < 0x80:
        return 1
    if 0xC2 <= lead <= 0xDF:
        return 2
    if 0xE0 <= lead <= 0xEF:
        return 3
    if 0xF0 <= lead <= 0xF4:
        return 4
    return 99


class Reader:
    def __init__(self, b, big, big_float):
        self.b = b
        self.e = ">" if big else "<"
        self.f = ">" if big_float else "<"
        self.pos = 0

    def u8(self):
        v = self.b[self.pos]
        self.pos += 1
        return v

    def i32(self):
        v = struct.unpack_from(self.e + "i", self.b, self.pos)[0]
        self.pos += 4
        return v

    def u32(self):
        v = struct.unpack_from(self.e + "I", self.b, self.pos)[0]
        self.pos += 4
        return v

    def i64(self):
        v = struct.unpack_from(self.e + "q", self.b, self.pos)[0]
        self.pos += 8
        return v

    def f64(self):
        v = struct.unpack_from(self.f + "d", self.b, self.pos)[0]
        self.pos += 8
        return v

    def take(self, n):
        v = self.b[self.pos:self.pos + n]
        self.pos += n
        return v


def parse(b):
    """The dictionary as the layout gives it: the header fields, every
    record with its offset, the variable slots, the first record of each
    extension subtype, and where the data record starts."""
    if b[:4] not in (b"$FL2", b"$FL3"):
        raise ValueError("not a system file")
    if b[64:68] in (b"\x02\x00\x00\x00", b"\x03\x00\x00\x00"):
        big = False
    elif b[64:68] in (b"\x00\x00\x00\x02", b"\x00\x00\x00\x03"):
        big = True
    else:
        raise ValueError("layout code")
    if b[84:92] == b"\x00\x00\x00\x00\x00\x00\x59\x40":
        big_float = False
    elif b[84:92] == b"\x40\x59\x00\x00\x00\x00\x00\x00":
        big_float = True
    else:
        raise ValueError("bias")
    r = Reader(b, big, big_float)
    r.pos = 64
    layout = r.i32()
    d = {"big": big, "big_float": big_float, "magic": b[:4], "product": b[4:64].rstrip(b" "),
         "layout": layout, "nominal": r.i32(), "compression": r.i32(), "weight": r.i32(), "ncases": r.i32()}
    d["bias"] = struct.unpack_from(r.f + "d", b, 84)[0]
    r.pos = 176
    records = []
    while True:
        at = r.pos
        kind = r.i32()
        rec = {"kind": kind, "at": at}
        if kind == 999:
            rec["filler"] = r.i32()
            rec["end"] = r.pos
            records.append(rec)
            break
        if kind == 2:
            rec.update(type=r.i32(), has_label=r.i32(), n_missing=r.i32(), print=r.i32(),
                       write=r.i32(), name=r.take(8))
            rec["label_at"] = r.pos
            if rec["has_label"] == 1:
                n = r.u32()
                rec["label_len"] = n
                rec["label"] = r.take((n + 3) // 4 * 4)
            if rec["n_missing"]:
                rec["missing_at"] = r.pos
                rec["missing"] = r.take(8 * abs(rec["n_missing"]))
        elif kind == 3:
            rec["count"] = r.u32()
            items = []
            rec["values_at"] = []
            for _ in range(rec["count"]):
                rec["values_at"].append(r.pos)
                value = r.take(8)
                n = r.u8()
                items.append((value, r.take((n + 8) // 8 * 8 - 1)))
            rec["items"] = items
        elif kind == 4:
            rec["count"] = r.u32()
            rec["vars_at"] = r.pos
            rec["vars"] = [r.i32() for _ in range(rec["count"])]
        elif kind == 6:
            rec["count"] = r.u32()
            rec["lines"] = r.take(80 * rec["count"])
        elif kind == 7:
            rec["subtype"] = r.u32()
            size = r.u32()
            count = r.u32()
            rec["size"], rec["count"] = size, count
            rec["data_at"] = r.pos
            rec["data"] = r.take(size * count)
        else:
            raise ValueError("record type %d at byte %d" % (kind, at))
        rec["end"] = r.pos
        records.append(rec)
    d["records"] = records
    d["data_at"] = r.pos
    # the variable slots
    slots = []
    pending = 0
    for rec in records:
        if rec["kind"] != 2:
            if pending:
                raise ValueError("continuation records missing at byte %d" % rec["at"])
            continue
        if rec["type"] < 0:
            pending -= 1
            continue
        width = rec["type"]
        octets = 1 if width == 0 else (width + 7) // 8
        pending = octets - 1
        raw = rec["name"].split(b" ", 1)[0].split(b"\x00", 1)[0]
        slots.append({"at": rec["at"], "raw_name": raw, "width": width, "octets": octets,
                      "format": (rec["print"] >> 16) & 0xFF, "name": None, "length": 0,
                      "owner": -1, "rec": rec})
    d["slots"] = slots
    ext = {}
    for rec in records:
        if rec["kind"] == 7 and rec["subtype"] not in ext:
            ext[rec["subtype"]] = rec
    d["ext"] = ext
    _resolve(d)
    return d


def _bits(raw, big):
    return struct.unpack(">Q" if big else "<Q", raw)[0]


def _resolve(d):
    """What the extension records make of the variables: the encoding, the
    long names, the very long strings and the missing values."""
    b = d.get("_bytes")
    code = -1
    if 3 in d["ext"] and len(d["ext"][3]["data"]) == 32:
        data = d["ext"][3]["data"]
        code = struct.unpack_from((">" if d["big"] else "<") + "i", data, 28)[0]
    name = None
    if 20 in d["ext"]:
        name = d["ext"][20]["data"].rstrip(b" \x00")
    encoding = None
    if name:
        key = name.decode("ascii", "replace").upper().replace("-", "").replace("_", "").replace(".", "")
        encoding = {"UTF8": "UTF-8", "ISO88591": "ISO-8859-1", "LATIN1": "ISO-8859-1", "L1": "ISO-8859-1",
                    "WINDOWS1252": "WINDOWS-1252", "CP1252": "WINDOWS-1252", "MSANSI": "WINDOWS-1252"}.get(key)
    else:
        encoding = encoding_name(code)
    d["encoding"] = encoding
    d["character_code"] = code
    if encoding is None:
        return
    for slot in d["slots"]:
        slot["name"] = decode_text(slot["raw_name"], encoding)
    if 13 in d["ext"]:
        for piece in d["ext"][13]["data"].split(b"\x09"):
            if b"=" not in piece:
                continue
            key, value = piece.split(b"=", 1)
            for slot in d["slots"]:
                if slot["raw_name"].upper() == key.upper():
                    slot["name"] = decode_text(value, encoding)
    if 14 in d["ext"]:
        pieces = d["ext"][14]["data"].replace(b"\x00", b"\x09").split(b"\x09")
        for piece in pieces:
            if not piece:
                continue
            key, digits = piece.split(b"=", 1)
            width = int(digits)
            count = (width + 251) // 252
            found = None
            for i, slot in enumerate(d["slots"]):
                if slot["raw_name"].upper() == key.upper():
                    found = i
            if found is None:
                raise ValueError("very long string names no variable")
            d["slots"][found]["length"] = width
            for k in range(1, count):
                d["slots"][found + k]["owner"] = found
    d["sysmis"] = SYSMIS
    if 4 in d["ext"] and len(d["ext"][4]["data"]) == 24:
        d["sysmis"] = _bits(d["ext"][4]["data"][:8], d["big_float"])
    for slot in d["slots"]:
        slot["ranges"] = []
        slot["missing_text"] = []
        rec = slot["rec"]
        if rec["n_missing"]:
            if slot["width"] == 0:
                values = [_bits(rec["missing"][i:i + 8], d["big_float"]) for i in range(0, len(rec["missing"]), 8)]
                if rec["n_missing"] < 0:
                    lo = -math_inf() if values[0] in (LOWEST, SYSMIS) else _double(values[0])
                    hi = math_inf() if values[1] == HIGHEST else _double(values[1])
                    slot["ranges"] += [lo, hi]
                    if rec["n_missing"] == -3:
                        slot["ranges"] += [_double(values[2])] * 2
                else:
                    for v in values:
                        slot["ranges"] += [_double(v)] * 2
            else:
                for i in range(0, len(rec["missing"]), 8):
                    slot["missing_text"].append(decode_text(rec["missing"][i:i + 8], encoding))
        if 22 in d["ext"] and slot["owner"] < 0:
            data = d["ext"][22]["data"]
            i = 0
            while i < len(data):
                n = struct.unpack_from((">" if d["big"] else "<") + "I", data, i)[0]
                raw = data[i + 4:i + 4 + n]
                i += 4 + n
                count = data[i]
                i += 1
                vlen = struct.unpack_from((">" if d["big"] else "<") + "I", data, i)[0]
                i += 4
                if decode_text(raw, encoding) == slot["name"] or raw.upper() == slot["raw_name"].upper():
                    for _ in range(count):
                        slot["missing_text"].append(decode_text(data[i:i + vlen], encoding))
                        i += vlen
                else:
                    i += count * vlen


def _double(bits):
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


def math_inf():
    return float("inf")


def inflated(b, d):
    """The joined blocks of a zlib-compressed data record."""
    at = d["data_at"]
    e = ">" if d["big"] else "<"
    self_at, trailer_at, trailer_len = struct.unpack_from(e + "qqq", b, at)
    bias, zero, block_size, blocks = struct.unpack_from(e + "qqII", b, trailer_at)
    out = b""
    for i in range(blocks):
        uo, co, us, cs = struct.unpack_from(e + "qqII", b, trailer_at + 24 + 24 * i)
        plain = zlib.decompress(b[co:co + cs])
        assert len(plain) == us
        out += plain
    return out


def units(b, d):
    """Every case's eight-byte units, in file order: the plain data, or
    the bytecode decoded, or the zlib blocks inflated and decoded."""
    if d["compression"] == 0:
        return b[d["data_at"]:]
    raw = inflated(b, d) if d["compression"] == 2 else b[d["data_at"]:]
    out = bytearray()
    pos = 0
    literal = 0
    index = 8
    group = 0
    sysmis = struct.pack((">" if d["big_float"] else "<") + "Q", d["sysmis"])
    while True:
        if index == 8:
            if len(raw) - literal < 8:
                break
            group = literal
            literal += 8
            index = 0
        code = raw[group + index]
        index += 1
        if code == 0:
            continue
        if code == 252:
            break
        if code == 253:
            out += raw[literal:literal + 8]
            literal += 8
        elif code == 254:
            out += b" " * 8
        elif code == 255:
            out += sysmis
        else:
            out += struct.pack((">" if d["big_float"] else "<") + "d", code - 100.0)
    return bytes(out)


def whole_days(seconds):
    if seconds % 86400.0 != 0.0:
        return None
    days = seconds / 86400.0
    if not -9e18 <= days <= 9e18:
        return None
    return int(days) - EPOCH_DAYS


def whole_micros(seconds):
    micros = seconds * 1e6
    if micros != math.floor(micros) or micros / 1e6 != seconds or not -9e18 <= micros <= 9e18:
        return None
    return int(micros)


def read(b):
    """The file's columns under the codec's stated rules: each column's
    name, dtype and cells spelled `<kind> <payload>`; and the case count."""
    d = parse(b)
    if d["encoding"] is None:
        raise ValueError("encoding %r not decoded" % (d.get("character_code"),))
    data = units(b, d)
    slots = d["slots"]
    row_units = sum(s["octets"] for s in slots)
    if d["ncases"] >= 0:
        rows = d["ncases"]
        if d["compression"] == 0 and rows * row_units * 8 > len(data):
            raise ValueError("cases not held")
    else:
        if d["compression"] == 0 and len(data) % (row_units * 8):
            raise ValueError("partial case")
        rows = len(data) // (row_units * 8) if row_units else 0
    if rows * row_units * 8 > len(data):
        raise ValueError("cases not held")
    columns = []
    offset = 0
    f = ">" if d["big_float"] else "<"
    for i, slot in enumerate(slots):
        if slot["owner"] >= 0:
            offset += slot["octets"]
            continue
        cells = []
        if slot["width"] == 0:
            values = []
            for r in range(rows):
                at = (r * row_units + offset) * 8
                v = struct.unpack_from(f + "d", data, at)[0]
                if struct.unpack_from(f + "Q", data, at)[0] == d["sysmis"]:
                    values.append(None)
                elif any(lo <= v <= hi for lo, hi in zip(slot["ranges"][0::2], slot["ranges"][1::2])):
                    values.append(None)
                else:
                    values.append(v)
            kind = FAMILY.get(slot["format"], "Plain")
            converted = []
            for v in values:
                if v is None:
                    converted.append(None)
                elif kind == "Date":
                    converted.append(whole_days(v))
                elif kind in ("DateTime", "TimeOfDay"):
                    converted.append(whole_micros(v))
            if kind != "Plain" and all(c is not None or v is None for c, v in zip(converted, values)):
                dtype = "Date" if kind == "Date" else "Timestamp"
                for c in converted:
                    if c is None:
                        cells.append("Null")
                    else:
                        cells.append("%s %d" % (dtype, c - EPOCH_MICROS if kind == "DateTime" else c))
            else:
                dtype = "Float"
                for r, v in enumerate(values):
                    if v is None:
                        cells.append("Null")
                    else:
                        cells.append("Float %016x" % struct.unpack_from(f + "Q", data, (r * row_units + offset) * 8)[0])
        else:
            dtype = "String"
            for r in range(rows):
                base = (r * row_units + offset) * 8
                if slot["length"]:
                    count = (slot["length"] + 251) // 252
                    raw = b""
                    at = base
                    for k in range(count):
                        used = max(0, min(slot["length"] - 255 * k, 255))
                        raw += data[at:at + used]
                        at += slots[i + k]["octets"] * 8
                else:
                    raw = data[base:base + slot["width"]]
                text = decode_text(raw, d["encoding"])
                cells.append("Null" if text in slot["missing_text"] else "String " + text)
        columns.append({"name": slot["name"], "dtype": dtype, "cells": cells,
                        "format": slot["format"]})
        offset += slot["octets"]
    return {"rows": rows, "columns": columns, "dictionary": d}
