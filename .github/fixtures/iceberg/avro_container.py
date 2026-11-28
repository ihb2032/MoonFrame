"""A minimal reader and writer of Avro object container files — enough to
take a manifest or a manifest list the reference wrote apart and to build a
hand-patched one from its header and records.

    container = Container(bytes)            # parse
    container.metadata                       # {key: value}
    container.payload(0)                     # a block's bytes, inflated
    Container.build(metadata, payload)       # one uncompressed block

The encoders write the binary values a record holds: zigzag whole numbers
and length-prefixed strings and byte runs.
"""
from __future__ import annotations

import zlib

MAGIC = b"Obj\x01"


def read_varint(data: bytes, at: int) -> tuple[int, int]:
    shift = value = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, at
        shift += 7


def read_zigzag(data: bytes, at: int) -> tuple[int, int]:
    value, at = read_varint(data, at)
    return (value >> 1) ^ -(value & 1), at


def varint(value: int) -> bytes:
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def zigzag(value: int) -> bytes:
    return varint((value << 1) ^ (value >> 63))


def avro_int(value: int) -> bytes:
    """An int or a long: the same zigzag encoding."""
    return zigzag(value)


def avro_string(text: str) -> bytes:
    data = text.encode("utf-8")
    return zigzag(len(data)) + data


def avro_bytes(data: bytes) -> bytes:
    return zigzag(len(data)) + data


def inflate(codec: str, payload: bytes) -> bytes:
    if codec in (None, "", "null"):
        return payload
    if codec == "deflate":
        return zlib.decompress(payload, -15)
    raise ValueError(f"cannot inflate codec {codec!r} in this helper")


class Container:
    """A parsed container: its metadata with the offsets of its values, its
    sync marker, and its blocks."""

    def __init__(self, data: bytes) -> None:
        self.data = data
        if data[:4] != MAGIC:
            raise ValueError("not an Avro container")
        at = 4
        self.metadata: dict[str, str] = {}
        self.value_at: dict[str, int] = {}
        while True:
            count, at = read_zigzag(data, at)
            if count == 0:
                break
            if count < 0:
                size, at = read_zigzag(data, at)
                count = -count
            for _ in range(count):
                n, at = read_zigzag(data, at)
                key = data[at:at + n].decode("utf-8")
                at += n
                value_at = at
                n, at = read_zigzag(data, at)
                self.metadata[key] = data[at:at + n].decode("utf-8")
                self.value_at[key] = value_at
                at += n
        self.sync_at = at
        self.sync = data[at:at + 16]
        at += 16
        self.blocks: list[dict] = []
        while at < len(data):
            count_at = at
            count, at = read_zigzag(data, at)
            size_at = at
            size, at = read_zigzag(data, at)
            payload_at = at
            at += size
            marker_at = at
            marker = data[at:at + 16]
            at += 16
            self.blocks.append(
                {"count": count, "size": size, "count_at": count_at, "size_at": size_at, "payload_at": payload_at, "marker_at": marker_at, "marker": marker}
            )

    def payload(self, block: int) -> bytes:
        return inflate(self.metadata.get("avro.codec"), self.data[self.blocks[block]["payload_at"]:self.blocks[block]["payload_at"] + self.blocks[block]["size"]])

    @staticmethod
    def build(metadata: dict[str, str], count: int, payload: bytes, codec: str = "null", sync: bytes = bytes(range(16))) -> bytes:
        """One container: the magic, the metadata map, the sync marker, and one
        block of `count` records in `payload` under `codec` (none or deflate)."""
        out = bytearray(MAGIC)
        pairs = list(metadata.items()) + [("avro.codec", codec)]
        out += zigzag(len(pairs))
        for key, value in pairs:
            out += avro_string(key)
            out += avro_string(value)
        out += zigzag(0)
        out += sync
        encoded = zlib.compress(payload)[2:-1] if codec == "deflate" else payload
        out += zigzag(count)
        out += zigzag(len(encoded))
        out += encoded
        out += sync
        return bytes(out)

    @staticmethod
    def build_raw(metadata: dict[str, str], count: int, payload: bytes, sync: bytes = bytes(range(16))) -> bytes:
        """One container whose header is exactly `metadata` — no codec added
        — and whose one block holds `payload` as it is."""
        out = bytearray(MAGIC)
        out += zigzag(len(metadata))
        for key, value in metadata.items():
            out += avro_string(key)
            out += avro_string(value)
        out += zigzag(0)
        out += sync
        out += zigzag(count)
        out += zigzag(len(payload))
        out += payload
        out += sync
        return bytes(out)


def replace_at(data: bytes, at: int, length: int, replacement: bytes) -> bytes:
    """`data` with the `length` bytes at `at` replaced — by something as long."""
    if len(replacement) != length:
        raise ValueError("the replacement must be as long as what it replaces")
    return data[:at] + replacement + data[at + length:]
