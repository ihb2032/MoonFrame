"""The sas7bdat page layout, walked the way the reference readers walk it.

A read-only Python model of the layout the MoonBit reader implements:
the 288-byte header start, the pages, the subheader pointers, the
metadata subheaders, and where the rows are. The fixture generator uses
it to learn each file's facts (format names, column widths, compression,
rows held) when it writes a sidecar; the probes use it to answer
questions about a file. Nothing here reads cells: the cells in a sidecar
come from the reference readers.
"""

import struct

MAGIC = bytes.fromhex(
    "000000000000000000000000c2ea8160b31411cfbd92080009c7318c181f1011"
)

ENCODINGS = {
    0: "windows-1252",
    20: "utf-8",
    28: "us-ascii",
    29: "iso-8859-1",
    30: "iso-8859-2",
    31: "iso-8859-3",
    32: "iso-8859-4",
    33: "iso-8859-5",
    34: "iso-8859-6",
    35: "iso-8859-7",
    36: "iso-8859-8",
    37: "iso-8859-9",
    38: "iso-8859-10",
    39: "cp874",
    40: "iso-8859-15",
    41: "cp437",
    42: "cp850",
    43: "cp852",
    44: "cp857",
    45: "cp858",
    46: "cp862",
    47: "cp864",
    48: "cp865",
    49: "cp866",
    50: "cp869",
    51: "cp874",
    55: "cp720",
    56: "cp737",
    57: "cp775",
    58: "cp860",
    59: "cp863",
    60: "cp1250",
    61: "cp1251",
    62: "cp1252",
    63: "cp1253",
    64: "cp1254",
    65: "cp1255",
    66: "cp1256",
    67: "cp1257",
    68: "cp1258",
    69: "mac-roman",
    70: "mac-arabic",
    72: "mac-greek",
    75: "mac-turkish",
    118: "cp950",
    123: "big5",
    125: "gb18030",
    126: "cp936",
    134: "euc-jp",
    136: "cp932",
    138: "shift-jis",
    140: "euc-kr",
    141: "cp949",
    142: "cp949",
    163: "mac-iceland",
    167: "iso-2022-jp",
    168: "iso-2022-kr",
    204: "windows-1252",
    205: "gb18030",
    227: "iso-8859-14",
    242: "iso-8859-13",
    245: "mac-croatian",
    246: "mac-cyrillic",
    247: "mac-romanian",
    248: "shift-jisx0213",
}

SIGS32 = {
    b"\xf7\xf7\xf7\xf7": "ROWSIZE",
    b"\x00\x00\x00\x00\xf7\xf7\xf7\xf7": None,
    b"\xf6\xf6\xf6\xf6": "COLSIZE",
    b"\x00\x00\x00\x00\xf6\xf6\xf6\xf6": None,
    b"\xf6\xf6\xf6\xf6\xff\xff\xfb\xfe": None,
    b"\x00\xfc\xff\xff": "COUNTS",
    b"\xff\xff\xfc\x00": "COUNTS",
    b"\xfd\xff\xff\xff": "COLTEXT",
    b"\xff\xff\xff\xfd": "COLTEXT",
    b"\xff\xff\xff\xff": "COLNAME",
    b"\xfc\xff\xff\xff": "COLATTR",
    b"\xff\xff\xff\xfc": "COLATTR",
    b"\xfe\xfb\xff\xff": "COLFMT",
    b"\xff\xff\xfb\xfe": "COLFMT",
    b"\xfe\xff\xff\xff": "COLLIST",
    b"\xff\xff\xff\xfe": "COLLIST",
}
SIGS64 = {
    b"\xf7\xf7\xf7\xf7\x00\x00\x00\x00": "ROWSIZE",
    b"\x00\x00\x00\x00\xf7\xf7\xf7\xf7": "ROWSIZE",
    b"\xf7\xf7\xf7\xf7\xff\xff\xfb\xfe": "ROWSIZE",
    b"\xf6\xf6\xf6\xf6\x00\x00\x00\x00": "COLSIZE",
    b"\x00\x00\x00\x00\xf6\xf6\xf6\xf6": "COLSIZE",
    b"\xf6\xf6\xf6\xf6\xff\xff\xfb\xfe": "COLSIZE",
    b"\x00\xfc\xff\xff\xff\xff\xff\xff": "COUNTS",
    b"\xff\xff\xff\xff\xff\xff\xfc\x00": "COUNTS",
    b"\xfd\xff\xff\xff\xff\xff\xff\xff": "COLTEXT",
    b"\xff\xff\xff\xff\xff\xff\xff\xfd": "COLTEXT",
    b"\xff\xff\xff\xff\xff\xff\xff\xff": "COLNAME",
    b"\xfc\xff\xff\xff\xff\xff\xff\xff": "COLATTR",
    b"\xff\xff\xff\xff\xff\xff\xff\xfc": "COLATTR",
    b"\xfe\xfb\xff\xff\xff\xff\xff\xff": "COLFMT",
    b"\xff\xff\xff\xff\xff\xff\xfb\xfe": "COLFMT",
    b"\xfe\xff\xff\xff\xff\xff\xff\xff": "COLLIST",
    b"\xff\xff\xff\xff\xff\xff\xff\xfe": "COLLIST",
}

PAGE_KINDS = {0x0000: "META", 0x0100: "DATA", 0x0200: "MIX", 0x0400: "AMD", 0x4000: "META2"}
SIZES = {"I": 4, "Q": 8, "H": 2, "II": 8, "QQ": 16, "HHH": 6, "6H": 12}


class LayoutError(Exception):
    """Bytes that contradict the layout: the Python model's parse refusal."""


def field(data, bo, fmt, at):
    """One little- or big-endian field at ``at``; a read past the end refuses."""
    size = SIZES[fmt]
    if at < 0 or at + size > len(data):
        raise LayoutError(f"byte {at}: the file ends at byte {len(data)} inside a {size}-byte field")
    return struct.unpack_from(bo + fmt, data, at)


def walk(data):
    """Walk a whole sas7bdat file.

    Returns a dict with the header facts, the pages, the metadata subheaders
    in file order, the resolved columns and the row sources. Raises
    ``LayoutError`` for bytes that contradict the layout.
    """
    if len(data) < 288:
        raise LayoutError(f"the file is {len(data)} bytes, shorter than the 288-byte header start")
    if data[:32] != MAGIC:
        raise LayoutError("byte 0: the magic is not the SAS Version 7/8/9 data-set magic")
    wide = data[32] == 0x33
    pad = 4 if data[35] == 0x33 else 0
    if data[37] == 1:
        little = True
    elif data[37] == 0:
        little = False
    else:
        raise LayoutError(f"byte 37: {data[37]} names neither byte order")
    bo = "<" if little else ">"
    word = 8 if wide else 4
    pointer = 24 if wide else 12
    bit = 32 if wide else 16
    WF = "Q" if wide else "I"
    enc = data[70]
    header_length = field(data, bo, "I", 196 + pad)[0]
    page_length = field(data, bo, "I", 200 + pad)[0]
    if header_length < 288:
        raise LayoutError(f"byte {196 + pad}: the header length is {header_length}, under 288")
    if header_length > len(data):
        raise LayoutError(
            f"byte {196 + pad}: the header length is {header_length} and the file ends at byte {len(data)}"
        )
    if page_length < bit + 8:
        raise LayoutError(
            f"byte {200 + pad}: the page length is {page_length}, under the {bit + 8} a page header takes"
        )
    rest = len(data) - header_length
    if rest == 0:
        raise LayoutError(f"the file ends at byte {len(data)} right after its header: no page")
    if rest % page_length:
        raise LayoutError(
            f"byte {200 + pad}: the page length is {page_length} and {rest} bytes follow the header, "
            f"which is {rest // page_length} pages and {rest % page_length} bytes"
        )
    pages_count = rest // page_length
    out = {
        "wide": wide,
        "pad": pad,
        "little": little,
        "word": word,
        "pointer": pointer,
        "bit": bit,
        "encoding_code": enc,
        "encoding": ENCODINGS.get(enc, f"code {enc}"),
        "header_length": header_length,
        "page_length": page_length,
        "pages_count": pages_count,
        "pages": [],
        "texts": [],
        "names": [],
        "attrs": [],
        "formats": [],
        "rowsize": None,
        "colsize": None,
        "raw_runs": [],
    }
    for index in range(pages_count):
        page_at = header_length + index * page_length
        raw = field(data, bo, "H", page_at + bit)[0]
        blocks = field(data, bo, "H", page_at + bit + 2)[0]
        subs = field(data, bo, "H", page_at + bit + 4)[0]
        kind = raw & 0xFF00
        page = {"index": index, "at": page_at, "raw": raw, "kind": kind, "blocks": blocks, "subheaders": subs, "pointers": []}
        out["pages"].append(page)
        if kind == 0x0100:
            out["raw_runs"].append({"at": page_at + bit + 8, "count": blocks, "compressed": False, "page": index, "raw": False})
            continue
        if raw & 0x9000:
            continue
        if kind not in (0x0000, 0x0200, 0x0400, 0x4000):
            continue
        pointers_at = page_at + bit + 8
        if pointers_at + subs * pointer > page_at + page_length:
            raise LayoutError(
                f"byte {page_at + bit + 4}: {subs} subheader pointers of {pointer} bytes do not fit in a {page_length}-byte page"
            )
        for s in range(subs):
            p = pointers_at + s * pointer
            off, ln = field(data, bo, "QQ" if wide else "II", p)
            comp = data[p + 2 * word]
            typ = data[p + 2 * word + 1]
            info = {"at": p, "offset": off, "length": ln, "compression": comp, "type": typ}
            page["pointers"].append(info)
            if ln == 0 or comp == 1:
                continue
            if off > page_length or ln > page_length or off + ln > page_length:
                raise LayoutError(
                    f"byte {p}: a subheader at byte {off} of {ln} bytes does not fit in a {page_length}-byte page"
                )
            if off < bit + 8 + subs * pointer:
                raise LayoutError(f"byte {p}: a subheader at byte {off} lies inside the page's {subs} subheader pointers")
            sub_at = page_at + off
            if comp == 4:
                out["raw_runs"].append({"at": sub_at, "length": ln, "count": 1, "compressed": True, "page": index, "raw": False})
                info["kind"] = "ROW"
                continue
            if comp != 0:
                raise LayoutError(f"byte {p + 2 * word}: a subheader names compression code {comp}")
            if ln < word:
                raise LayoutError(f"byte {p}: a subheader of {ln} bytes is shorter than its signature")
            sig = bytes(data[sub_at : sub_at + word])
            which = (SIGS64 if wide else SIGS32).get(sig)
            if which is None and wide and not little:
                which = SIGS64.get(sig[4:] + sig[:4])
            if which is None and sig[0] >= 0xF8 and all(b == 0xFF for b in sig[1:]):
                which = "VOID"
            info["kind"] = which
            if which is None:
                if typ == 1:
                    out["raw_runs"].append({"at": sub_at, "length": ln, "count": 1, "compressed": False, "page": index, "raw": True})
                    info["kind"] = "ROW(raw)"
                    continue
                raise LayoutError(f"byte {sub_at}: the signature {sig.hex()} is not a subheader's")
            if which in ("COUNTS", "COLLIST", "VOID"):
                continue
            if which == "ROWSIZE":
                if out["rowsize"] is not None:
                    raise LayoutError(f"byte {sub_at}: a second row-size subheader")
                if ln < 16 * word:
                    raise LayoutError(f"byte {sub_at}: a row-size subheader of {ln} bytes")
                out["rowsize"] = {
                    "at": sub_at,
                    "row_length": field(data, bo, WF, sub_at + 5 * word)[0],
                    "row_count": field(data, bo, WF, sub_at + 6 * word)[0],
                    "col1": field(data, bo, WF, sub_at + 9 * word)[0],
                    "col2": field(data, bo, WF, sub_at + 10 * word)[0],
                    "mix_rows": field(data, bo, WF, sub_at + 15 * word)[0],
                }
            elif which == "COLSIZE":
                if out["colsize"] is not None:
                    raise LayoutError(f"byte {sub_at}: a second column-count subheader")
                if ln < 2 * word:
                    raise LayoutError(f"byte {sub_at}: a column-count subheader of {ln} bytes")
                out["colsize"] = {"at": sub_at, "count": field(data, bo, WF, sub_at + word)[0]}
            elif which == "COLTEXT":
                size = field(data, bo, "H", sub_at + word)[0]
                if size != ln - 2 * word - 4:
                    raise LayoutError(f"byte {sub_at + word}: a text block of {size} bytes in a subheader of {ln} bytes")
                # The block runs from its size field to the subheader's end:
                # real files park text past the size the field names (the
                # reference reader that reads such files uses this extent).
                out["texts"].append({"at": sub_at + word, "size": ln - word, "declared": size, "page": index})
            else:
                out[{"COLNAME": "names", "COLATTR": "attrs", "COLFMT": "formats"}[which]].append(
                    {"at": sub_at, "length": ln, "which": which, "page": index}
                )
        if kind == 0x0200:
            start = bit + 8 + subs * pointer
            start += start % 8
            out["raw_runs"].append({"at": page_at + start, "count": "mix", "compressed": False, "page": index, "raw": False})
    rs = out["rowsize"]
    if rs is None:
        raise LayoutError("no row-size subheader anywhere in the file")
    if out["colsize"] is None:
        raise LayoutError("no column-count subheader anywhere in the file")
    row_length = rs["row_length"]
    if row_length == 0:
        raise LayoutError(f"byte {rs['at'] + 5 * word}: the row length is 0")
    if row_length > page_length:
        raise LayoutError(f"byte {rs['at'] + 5 * word}: the row length {row_length} exceeds the page length {page_length}")
    names = []
    for sub in out["names"]:
        ln = sub["length"]
        if ln < 2 * word + 12 or (ln - 2 * word - 12) % 8:
            raise LayoutError(f"byte {sub['at']}: a column-name subheader of {ln} bytes")
        base = sub["at"] + word + 8
        for k in range((ln - 2 * word - 12) // 8):
            e = base + 8 * k
            idx, off, length = field(data, bo, "HHH", e)
            names.append({"index": idx, "offset": off, "length": length, "at": e})
    out["name_refs"] = names
    attrs = []
    for sub in out["attrs"]:
        ln = sub["length"]
        if ln < 2 * word + 12 or (ln - 2 * word - 12) % (word + 8):
            raise LayoutError(f"byte {sub['at']}: a column-attribute subheader of {ln} bytes")
        base = sub["at"] + word + 8
        for k in range((ln - 2 * word - 12) // (word + 8)):
            e = base + (word + 8) * k
            attrs.append(
                {"offset": field(data, bo, WF, e)[0], "width": field(data, bo, "I", e + word)[0], "type": data[e + word + 6], "at": e}
            )
    out["attr_refs"] = attrs
    formats = []
    for sub in out["formats"]:
        ln = sub["length"]
        if ln < 3 * word + 34:
            raise LayoutError(f"byte {sub['at']}: a format subheader of {ln} bytes")
        base = sub["at"] + 3 * word
        f_idx, f_off, f_len, l_idx, l_off, l_len = field(data, bo, "6H", base + 22)
        formats.append({"index": f_idx, "offset": f_off, "length": f_len, "at": base + 22, "page": sub["page"]})
    out["format_refs"] = formats
    column_count = out["colsize"]["count"]
    if column_count == 0:
        raise LayoutError(
            f"byte {out['colsize']['at'] + word}: the file declares no column but rows of {row_length} bytes"
        )
    if len(names) < column_count:
        raise LayoutError(f"the file declares {column_count} columns but names {len(names)}")
    if len(attrs) < column_count:
        raise LayoutError(f"the file declares {column_count} columns but describes {len(attrs)}")

    def text(ref, what):
        if ref["index"] >= len(out["texts"]):
            raise LayoutError(
                f"byte {ref['at']}: {what} names text block {ref['index']} and the file holds {len(out['texts'])}"
            )
        block = out["texts"][ref["index"]]
        if ref["offset"] + ref["length"] > block["size"]:
            raise LayoutError(
                f"byte {ref['at']}: {what} names bytes {ref['offset']}..{ref['offset'] + ref['length']} "
                f"of a text block of {block['size']} bytes"
            )
        return bytes(data[block["at"] + ref["offset"] : block["at"] + ref["offset"] + ref["length"]])

    columns = []
    for i in range(column_count):
        a = attrs[i]
        if a["offset"] + a["width"] > row_length:
            raise LayoutError(
                f"byte {a['at']}: column {i + 1} spans bytes {a['offset']}..{a['offset'] + a['width']} of a {row_length}-byte row"
            )
        fmt = None
        if i < len(formats):
            fmt = text(formats[i], f"the format of column {i + 1}")
        columns.append(
            {
                "index": i,
                "name_raw": text(names[i], f"the name of column {i + 1}"),
                "format_raw": fmt,
                "offset": a["offset"],
                "width": a["width"],
                "type": a["type"],
                "attr_at": a["at"],
                "name_at": names[i]["at"],
            }
        )
    out["columns"] = columns
    comp = None
    for block in out["texts"]:
        blob = bytes(data[block["at"] : block["at"] + block["size"]])
        at = blob.find(b"SASYZCR")
        if at >= 0:
            comp = blob[at : at + 8]
            break
    out["compression"] = comp
    runs = []
    rows_available = 0
    for run in out["raw_runs"]:
        if run["compressed"]:
            runs.append({"at": run["at"], "length": run["length"], "count": 1, "compressed": True, "page": run["page"]})
            rows_available += 1
            continue
        if run.get("raw") and run["length"] != row_length:
            raise LayoutError(f"byte {run['at']}: a row subheader of {run['length']} bytes, and rows are {row_length}")
        count = rs["mix_rows"] if run["count"] == "mix" else run["count"]
        runs.append({"at": run["at"], "length": row_length, "count": count, "compressed": False, "page": run["page"]})
        page_end = out["pages"][run["page"]]["at"] + page_length
        capacity = max(0, (page_end - run["at"]) // row_length)
        rows_available += min(count, capacity)
    out["runs"] = runs
    out["rows_available"] = rows_available
    out["row_count"] = rs["row_count"]
    if comp is None and any(r["compressed"] for r in runs):
        raise LayoutError("a row is marked compressed and the file names no compression")
    if rows_available < rs["row_count"]:
        raise LayoutError(f"the file declares {rs['row_count']} rows and holds {rows_available}")
    return out


def page_name(page):
    """A page's kind as a word."""
    if page["raw"] & 0x9000:
        return "COMP"
    if page["kind"] == 0 and page["raw"] & 0x4000:
        return "META2"
    return PAGE_KINDS.get(page["kind"], hex(page["kind"]))


def describe(out):
    """One sentence naming a file's layout variants."""
    order = "little-endian" if out["little"] else "big-endian"
    width = "64-bit" if out["wide"] else "32-bit"
    aligned = ", 4-byte aligned" if out["pad"] else ""
    kinds = []
    for page in out["pages"]:
        name = page_name(page)
        if not kinds or kinds[-1] != name:
            kinds.append(name)
    where = []
    for run in out["runs"]:
        tag = f"{page_name(out['pages'][run['page']])} subheaders" if run["compressed"] else f"{page_name(out['pages'][run['page']])} rows"
        if not where or where[-1] != tag:
            where.append(tag)
    comp = out["compression"]
    comp = "none" if comp is None else {"SASYZCRL": "RLE", "SASYZCR2": "RDC"}.get(comp, comp.decode())
    return (
        f"{width} {order}{aligned}; header {out['header_length']}, page {out['page_length']}, "
        f"{out['pages_count']} page(s) [{', '.join(kinds)}]; charset {out['encoding']} (code {out['encoding_code']}); "
        f"compression {comp}; rows {out['row_count']} declared, {out['rows_available']} held, "
        f"row {out['rowsize']['row_length']} bytes; {out['colsize']['count']} columns; rows from {', '.join(where)}"
    )
