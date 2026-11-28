"""The hand-patched files of the corpus: one file for every malformed shape
the codec refuses, and a few it must accept, each with the variant and the
exact text of its refusal as the index records it.

Three sources:
  - the metadata of the `append_one` table, edited as JSON (or its bytes
    cut, or replaced);
  - manifest lists and manifests built record by record with the encoder
    below, from a header and a schema written here;
  - the manifest list `append_one` really holds, with bytes patched in
    place at offsets its own layout gives.

Nothing here comes from the codec: the texts are what its tests compare
the codec's refusals with, so a text that drifts fails a test.
"""
from __future__ import annotations

import copy
import json
import os
import struct

from avro_container import Container, varint

METADATA = "metadata"
LIST = "list"
MANIFEST = "manifest"

# The table schema a hand-built manifest's header carries: a column of every
# type the plan meets, plus a few it does not carry.
TABLE_SCHEMA = {
    "type": "struct",
    "fields": [
        {"id": 1, "name": "i", "type": "long", "required": False},
        {"id": 2, "name": "s", "type": "string", "required": False},
        {"id": 3, "name": "d", "type": "date", "required": False},
        {"id": 4, "name": "b", "type": "binary", "required": False},
        {"id": 5, "name": "m", "type": "decimal(10, 2)", "required": False},
        {"id": 6, "name": "t", "type": "timestamp", "required": False},
        {"id": 7, "name": "f", "type": "float", "required": False},
        {"id": 8, "name": "dd", "type": "double", "required": False},
        {"id": 9, "name": "bb", "type": "boolean", "required": False},
        {"id": 10, "name": "big", "type": "decimal(38, 2)", "required": False},
        {"id": 11, "name": "pad", "type": "decimal(34, 2)", "required": False},
    ],
    "schema-id": 0,
    "identifier-field-ids": [],
}

DATE = {"type": "int", "logicalType": "date"}
DECIMAL_FIXED_5_2 = {"type": "fixed", "size": 5, "name": "decimal_10_2", "logicalType": "decimal", "precision": 10, "scale": 2}


# ------------------------------------------------------------- the encoder
def encode(ty, value) -> bytes:
    """A datum under an Avro type spelled as the schema JSON spells it. Every
    count and length is a zigzag long, as the binary encoding writes them."""
    if ty == "null":
        return b""
    if ty in ("int", "long"):
        return varint((value << 1) ^ (value >> 63))
    if isinstance(ty, dict) and ty.get("logicalType") == "date":
        return encode("int", value)
    if isinstance(ty, dict) and ty.get("logicalType", "").startswith("timestamp"):
        return encode("long", value)
    if ty == "string":
        if isinstance(value, (bytes, bytearray)):
            # A string by its raw bytes, well formed or not.
            return varint(len(value) << 1) + bytes(value)
        data = value.encode("utf-8")
        return varint(len(data) << 1) + data
    if ty == "boolean":
        return b"\x01" if value else b"\x00"
    if ty == "float":
        # A float by its value, or by its 32 bits as `("bits", n)`.
        return struct.pack("<I", value[1]) if isinstance(value, tuple) else struct.pack("<f", value)
    if ty == "double":
        return struct.pack("<Q", value[1]) if isinstance(value, tuple) else struct.pack("<d", value)
    if ty == "bytes":
        return varint(len(value) << 1) + value
    if isinstance(ty, list):  # a union: a null and one type, by a zigzag index
        if value is None:
            return b"\x00"
        if isinstance(value, Raw):
            return varint(value.index << 1) + encode(ty[1], value.value)
        return b"\x02" + encode(ty[1], value)
    if isinstance(ty, dict):
        kind = ty["type"]
        if isinstance(kind, (dict, list)):
            # A nested definition under outer attributes, which carry
            # nothing the binary encoding spells.
            return encode(kind, value)
        if kind in ("int", "long", "string", "boolean", "float", "double"):
            # A primitive under attributes, such as a logical type.
            return encode(kind, value)
        if kind == "record":
            out = b""
            for field in ty["fields"]:
                out += encode(field["type"], value.get(field["name"]) if isinstance(value, dict) else None)
            return out
        if kind == "enum":
            return encode("int", value)
        if kind == "array":
            if not value:
                return varint(0)
            out = varint(len(value) << 1)
            for item in value:
                out += encode(ty["items"], item)
            return out + varint(0)
        if kind == "map":
            if not value:
                return varint(0)
            out = varint(len(value) << 1)
            for key, item in value:
                out += encode("long", key) + encode(ty["values"], item)
            return out + varint(0)
        if kind == "fixed":
            if isinstance(value, (bytes, bytearray)):
                return bytes(value)
            if ty.get("logicalType") == "decimal":
                return int(value).to_bytes(ty["size"], "big", signed=True)
            return value
        if kind == "bytes":
            # A run of bytes is length-prefixed, a decimal's included.
            if isinstance(value, (bytes, bytearray)):
                return varint(len(value) << 1) + bytes(value)
            if ty.get("logicalType") == "decimal":
                raw = int(value).to_bytes(max(1, (int(value).bit_length() + 8) // 8), "big", signed=True)
                return varint(len(raw) << 1) + raw
            return varint(len(value) << 1) + value
    raise ValueError(f"cannot encode {ty!r}")


class Raw:
    """A union datum spelled by its index, for an index outside the two."""

    def __init__(self, index: int, value) -> None:
        self.index = index
        self.value = value


def resolve(ty, names: dict):
    """A schema with every reference by name replaced by the definition it
    names, as the encoder has no registry of its own."""
    if isinstance(ty, str):
        return names.get(ty, ty)
    if isinstance(ty, list):
        return [resolve(branch, names) for branch in ty]
    if isinstance(ty, dict):
        if ty.get("name") and ty.get("type") in ("fixed", "enum", "record"):
            names[ty["name"]] = ty
            if ty.get("namespace"):
                names[f"{ty['namespace']}.{ty['name']}"] = ty
        out = dict(ty)
        for key in ("items", "values"):
            if key in out:
                out[key] = resolve(out[key], names)
        if "fields" in out:
            out["fields"] = [dict(field, type=resolve(field["type"], names)) for field in out["fields"]]
        return out
    return ty


def record_bytes(schema: dict, values: dict) -> bytes:
    return encode(resolve(schema, {}), values)


def optional(fields: list, field_id: int) -> list:
    """The fields with one of them made nullable: a file that spells a null
    where the format wants a value can only do it in a nullable field."""
    out = copy.deepcopy(fields)
    for field in out:
        if field["field-id"] == field_id and not isinstance(field["type"], list):
            field["type"] = ["null", field["type"]]
    return out


def data_file_fields(partition_type: dict | None = None, replacements: dict | None = None, drop: tuple = ()) -> list:
    """The fields of a manifest's `data_file` record, each by field id."""
    fields = [
        {"name": "content", "type": "int", "field-id": 134},
        {"name": "file_path", "type": "string", "field-id": 100},
        {"name": "file_format", "type": "string", "field-id": 101},
        {"name": "partition", "type": partition_type or empty_record(), "field-id": 102},
        {"name": "record_count", "type": "long", "field-id": 103},
        {"name": "column_sizes", "type": {"type": "map", "values": ["null", "long"]}, "field-id": 108},
        {"name": "key_metadata", "type": ["null", "bytes"], "field-id": 131},
        {"name": "equality_ids", "type": {"type": "array", "element-id": 136, "items": "long"}, "field-id": 135},
    ]
    if replacements:
        fields = [replacements.get(f["field-id"], f) for f in fields]
    return [f for f in fields if f["field-id"] not in drop]


def empty_record() -> dict:
    return {"type": "record", "name": "r102", "fields": []}


def entry_schema(data_fields: list | None = None) -> dict:
    fields = [
        {"name": "status", "type": "int", "field-id": 0},
        {"name": "sequence_number", "type": ["null", "long"], "field-id": 3},
        {"name": "data_file", "type": {"type": "record", "name": "r2", "fields": data_fields or data_file_fields()}, "field-id": 2},
    ]
    return {"type": "record", "name": "manifest_entry", "fields": fields}


def entry(status=1, sequence_number=None, **data_file) -> dict:
    base = {
        "content": 0,
        "file_path": None,
        "file_format": "PARQUET",
        "partition": {},
        "record_count": 3,
        "column_sizes": [(1, 10), (2, 20)],
        "key_metadata": None,
        "equality_ids": [],
    }
    base.update(data_file)
    return {"status": status, "sequence_number": sequence_number, "data_file": base}


LIST_FIELDS = [
    {"name": "manifest_path", "type": "string", "field-id": 500},
    {"name": "manifest_length", "type": "long", "field-id": 501},
    {"name": "partition_spec_id", "type": "int", "field-id": 502},
    {"name": "added_snapshot_id", "type": "long", "field-id": 503},
    {"name": "sequence_number", "type": "long", "field-id": 515},
    {"name": "content", "type": "int", "field-id": 517},
    {"name": "key_metadata", "type": ["null", "bytes"], "field-id": 519},
]


def list_record(path, length=100, spec_id=0, snapshot=5, sequence=0, content=0, key_metadata=None) -> dict:
    return {
        "manifest_path": path,
        "manifest_length": length,
        "partition_spec_id": spec_id,
        "added_snapshot_id": snapshot,
        "sequence_number": sequence,
        "content": content,
        "key_metadata": key_metadata,
    }


def container(avro_schema, records: list, metadata: dict, codec: str = "null", suffix: bytes = b"") -> bytes:
    """A container of `records` under `avro_schema`; `suffix` is appended to
    the block's bytes past the last record."""
    payload = b"".join(record_bytes(avro_schema, record) for record in records)
    return Container.build({**metadata, "avro.schema": json.dumps(avro_schema, separators=(",", ":"))}, len(records), payload + suffix, codec=codec)


def block_offset(data: bytes) -> int:
    """Where a container's one block begins: the byte its record count
    starts at, which is what the codec's refusals name."""
    return Container(data).blocks[0]["count_at"]


# ------------------------------------------------------------ the metadata
def metadata_shapes(base: dict, location: str) -> list:
    """Every malformed shape of the metadata JSON, each one edit of the
    `append_one` table's metadata, and the shapes it must accept."""
    snapshot = base["snapshots"][0]["snapshot-id"]
    list_rel = base["snapshots"][0]["manifest-list"][len(location) + 1:]

    def edited(change) -> bytes:
        metadata = copy.deepcopy(base)
        change(metadata)
        return json.dumps(metadata, indent=1, ensure_ascii=False).encode("utf-8")

    def first_field(metadata):
        return metadata["schemas"][0]["fields"][0]

    def refuses(variant, text):
        return {"codec": "refuses", "refusal": {"variant": variant, "text": "iceberg: " + text}}

    def answers(**what):
        return {"codec": "reads", "answers": what}

    plain_answers = dict(field_ids=[1, 2], manifest_list=list_rel, partition_fields=[])

    def type_shape(name, spelling, refusal):
        def change(metadata):
            first_field(metadata)["type"] = spelling
        return (name, lambda: edited(change), refusal)

    uncarried = lambda column, spelling: refuses("Unsupported", f'column "{column}": the type {spelling}, which this reader does not carry')
    shapes = [
        ("metadata_truncated", lambda: json.dumps(base, indent=1).encode("utf-8")[: len(json.dumps(base, indent=1)) // 2], refuses("ParseError", "the metadata is not JSON: Unexpected end of file")),
        ("metadata_bad_char", lambda: b"?", refuses("ParseError", "the metadata is not JSON: Invalid character '?' at line 1, column 0")),
        ("metadata_not_utf8", lambda: b"\xff\xfe\x00", refuses("ParseError", "the metadata is not UTF-8 text")),
        ("metadata_not_object", lambda: b"[]", refuses("ParseError", "the metadata is not an object")),
        ("metadata_no_version", lambda: edited(lambda m: m.pop("format-version")), refuses("ParseError", 'the metadata names no "format-version"')),
        ("metadata_version_four", lambda: edited(lambda m: m.__setitem__("format-version", 4)), refuses("Unsupported", "format version 4, where this reader reads 1 to 3")),
        ("metadata_version_zero", lambda: edited(lambda m: m.__setitem__("format-version", 0)), refuses("Unsupported", "format version 0, where this reader reads 1 to 3")),
        ("metadata_version_text", lambda: edited(lambda m: m.__setitem__("format-version", "2")), refuses("ParseError", "format-version is not a 64-bit whole number")),
        ("metadata_version_fraction", lambda: edited(lambda m: m.__setitem__("format-version", 2.5)), refuses("ParseError", "format-version is 2.5, not a 64-bit whole number")),
        ("metadata_version_huge", lambda: edited(lambda m: m.__setitem__("format-version", 9223372036854775808)), refuses("ParseError", "format-version is 9223372036854775808, not a 64-bit whole number")),
        ("metadata_no_location", lambda: edited(lambda m: m.pop("location")), refuses("ParseError", 'the metadata names no "location"')),
        ("metadata_location_empty", lambda: edited(lambda m: m.__setitem__("location", "")), refuses("ParseError", "location is empty")),
        ("metadata_location_number", lambda: edited(lambda m: m.__setitem__("location", 5)), refuses("ParseError", "location is not a string")),
        # A field the plan does not need is read past, whatever its shape.
        ("metadata_uuid_number", lambda: edited(lambda m: m.__setitem__("table-uuid", 5)), answers(**plain_answers)),
        ("metadata_source_ids_single", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-ids": [2], "name": "s", "transform": "identity"}])), answers(field_ids=[1, 2], manifest_list=list_rel, partition_fields=[["s", 2, "identity"]])),
        ("metadata_spec_no_id", lambda: edited(lambda m: m["partition-specs"][0].pop("spec-id")), answers(**plain_answers)),
        ("metadata_schema_id_unknown", lambda: edited(lambda m: m.__setitem__("current-schema-id", 7)), refuses("ParseError", "current-schema-id 7 names none of the table's 1 schemas")),
        ("metadata_schemas_not_array", lambda: edited(lambda m: m.__setitem__("schemas", {})), refuses("ParseError", "schemas is not an array")),
        ("metadata_schema_not_object", lambda: edited(lambda m: m.__setitem__("schemas", [5])), refuses("ParseError", "a schema is not an object")),
        ("metadata_schema_id_text", lambda: edited(lambda m: m["schemas"][0].__setitem__("schema-id", "0")), refuses("ParseError", "a schema's schema-id is not a 64-bit whole number")),
        ("metadata_no_schema", lambda: edited(lambda m: m.pop("schemas")), refuses("ParseError", "the metadata names no schema")),
        ("metadata_schema_type", lambda: edited(lambda m: m["schemas"][0].__setitem__("type", "record")), refuses("ParseError", "a schema whose type is record, not struct")),
        ("metadata_schema_no_type", lambda: edited(lambda m: m["schemas"][0].pop("type")), refuses("ParseError", 'the schema names no "type"')),
        ("metadata_schema_type_number", lambda: edited(lambda m: m["schemas"][0].__setitem__("type", 5)), refuses("ParseError", "the schema's type is not a string")),
        ("metadata_fields_not_array", lambda: edited(lambda m: m["schemas"][0].__setitem__("fields", {})), refuses("ParseError", "the schema's fields is not an array")),
        ("metadata_no_fields", lambda: edited(lambda m: m["schemas"][0].pop("fields")), refuses("ParseError", 'the schema names no "fields"')),
        ("metadata_field_not_object", lambda: edited(lambda m: m["schemas"][0].__setitem__("fields", [5])), refuses("ParseError", "a field of the schema is not an object")),
        ("metadata_field_no_id", lambda: edited(lambda m: first_field(m).pop("id")), refuses("ParseError", 'a field of the schema names no "id"')),
        ("metadata_field_no_name", lambda: edited(lambda m: first_field(m).pop("name")), refuses("ParseError", 'a field of the schema names no "name"')),
        ("metadata_field_no_type", lambda: edited(lambda m: first_field(m).pop("type")), refuses("ParseError", 'a field of the schema names no "type"')),
        ("metadata_type_number", lambda: edited(lambda m: first_field(m).__setitem__("type", 5)), refuses("ParseError", 'the type of column "i" is neither a name nor a definition')),
        type_shape("metadata_type_binary", "binary", uncarried("i", "binary")),
        type_shape("metadata_type_map", {"type": "map", "key-id": 9, "key": "string", "value-id": 10, "value": "long"}, uncarried("i", "map")),
        type_shape("metadata_type_variant", "variant", uncarried("i", "variant")),
        type_shape("metadata_type_time", "time", uncarried("i", "time")),
        type_shape("metadata_type_timestamp_ns", "timestamp_ns", uncarried("i", "timestamp_ns")),
        type_shape("metadata_type_timestamptz_ns", "timestamptz_ns", uncarried("i", "timestamptz_ns")),
        type_shape("metadata_type_uuid", "uuid", uncarried("i", "uuid")),
        type_shape("metadata_type_fixed", "fixed[16]", uncarried("i", "fixed[16]")),
        type_shape("metadata_type_unknown", "unknown", uncarried("i", "unknown")),
        type_shape("metadata_type_geometry", "geometry", uncarried("i", "geometry")),
        type_shape("metadata_type_geography", "geography", uncarried("i", "geography")),
        type_shape("metadata_type_file", "file", uncarried("i", "file")),
        ("metadata_list_no_element", lambda: edited(lambda m: first_field(m).__setitem__("type", {"type": "list", "element-id": 9})), refuses("ParseError", 'the list "i" names no "element"')),
        ("metadata_list_element_binary", lambda: edited(lambda m: first_field(m).__setitem__("type", {"type": "list", "element-id": 9, "element": "binary"})), uncarried("i[]", "binary")),
        ("metadata_struct_no_fields", lambda: edited(lambda m: first_field(m).__setitem__("type", {"type": "struct"})), refuses("ParseError", 'the struct "i" names no "fields"')),
        ("metadata_struct_duplicate", lambda: edited(lambda m: first_field(m).__setitem__("type", {"type": "struct", "fields": [{"id": 9, "name": "x", "type": "long"}, {"id": 10, "name": "x", "type": "long"}]})), refuses("Unsupported", 'the struct "i" holds two fields named "x"')),
        ("metadata_duplicate_columns", lambda: edited(lambda m: m["schemas"][0]["fields"].append({"id": 9, "name": "i", "type": "long"})), refuses("Unsupported", 'the schema holds two fields named "i"')),
        ("metadata_initial_default", lambda: edited(lambda m: first_field(m).__setitem__("initial-default", 5)), refuses("Unsupported", 'column "i": the initial default 5, which the files written before the column was added do not hold and this reader does not materialise')),
        # A null default is no default: the rows written before the column
        # was added read null either way.
        ("metadata_initial_default_null", lambda: edited(lambda m: first_field(m).__setitem__("initial-default", None)), answers(**plain_answers)),
        ("metadata_decimal_shape", lambda: edited(lambda m: first_field(m).__setitem__("type", "decimal(9)")), refuses("ParseError", 'decimal(9), the type of column "i", spells no precision and scale')),
        ("metadata_decimal_negative_scale", lambda: edited(lambda m: first_field(m).__setitem__("type", "decimal(9, -1)")), refuses("ParseError", 'decimal(9, -1), the type of column "i", spells no precision and scale')),
        ("metadata_decimal_range", lambda: edited(lambda m: first_field(m).__setitem__("type", "decimal(0, 0)")), refuses("ParseError", 'decimal(0, 0), the type of column "i", is not a decimal\'s precision and scale')),
        ("metadata_decimal_scale_over_precision", lambda: edited(lambda m: first_field(m).__setitem__("type", "decimal(9, 10)")), refuses("ParseError", 'decimal(9, 10), the type of column "i", is not a decimal\'s precision and scale')),
        ("metadata_decimal_wide", lambda: edited(lambda m: first_field(m).__setitem__("type", "decimal(35, 2)")), refuses("Unsupported", 'column "i": decimal(35, 2) holds up to 35 digits, where a Decimal here holds 34')),
        ("metadata_specs_not_array", lambda: edited(lambda m: m.__setitem__("partition-specs", {})), refuses("ParseError", "partition-specs is not an array")),
        ("metadata_spec_not_object", lambda: edited(lambda m: m.__setitem__("partition-specs", [5])), refuses("ParseError", "a partition spec is not an object")),
        ("metadata_spec_no_fields", lambda: edited(lambda m: m["partition-specs"][0].pop("fields")), refuses("ParseError", 'a partition spec names no "fields"')),
        ("metadata_spec_fields_not_array", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", {})), refuses("ParseError", "a partition spec's fields is not an array")),
        ("metadata_spec_field_not_object", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [5])), refuses("ParseError", "a partition field is not an object")),
        ("metadata_spec_field_no_source", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"field-id": 1000, "name": "x", "transform": "identity"}])), refuses("ParseError", "a partition field names no source column")),
        ("metadata_spec_field_source_ids_empty", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-ids": [], "name": "x", "transform": "identity"}])), refuses("ParseError", "a partition field names no source column")),
        ("metadata_spec_field_multi_source", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-ids": [1, 2], "name": "x", "transform": "identity"}])), refuses("Unsupported", "a partition field drawing on several source columns, which this reader does not carry")),
        ("metadata_spec_field_no_name", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-id": 1, "transform": "identity"}])), refuses("ParseError", 'a partition field names no "name"')),
        ("metadata_spec_field_no_transform", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-id": 1, "name": "x"}])), refuses("ParseError", 'a partition field names no "transform"')),
        ("metadata_spec_transform_number", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-id": 1, "name": "x", "transform": 5}])), refuses("ParseError", "a partition field's transform is not a string")),
        ("metadata_spec_bucket_zero", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-id": 1, "name": "x", "transform": "bucket[0]"}])), refuses("ParseError", "bucket[0], which spells no positive whole number in brackets")),
        ("metadata_spec_bucket_text", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-id": 1, "name": "x", "transform": "truncate[w]"}])), refuses("ParseError", "truncate[w], which spells no positive whole number in brackets")),
        ("metadata_spec_bucket_unclosed", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("fields", [{"source-id": 1, "name": "x", "transform": "bucket[4"}])), refuses("ParseError", "bucket[4, which spells no positive whole number in brackets")),
        ("metadata_spec_id_unknown", lambda: edited(lambda m: m.__setitem__("default-spec-id", 3)), refuses("ParseError", "default-spec-id 3 names none of the table's 1 partition specs")),
        ("metadata_spec_id_text", lambda: edited(lambda m: m.__setitem__("default-spec-id", "0")), refuses("ParseError", "default-spec-id is not a 64-bit whole number")),
        ("metadata_spec_id_field_text", lambda: edited(lambda m: m["partition-specs"][0].__setitem__("spec-id", "0")), refuses("ParseError", "a partition spec's spec-id is not a 64-bit whole number")),
        ("metadata_name_mapping", lambda: edited(lambda m: m.__setitem__("properties", {"schema.name-mapping.default": '[{"names":["i"],"field-id":1}]'})), refuses("Unsupported", "the property schema.name-mapping.default maps field ids to the columns of data files that carry none, and this reader does not apply it")),
        ("metadata_name_mapping_empty", lambda: edited(lambda m: m.__setitem__("properties", {"schema.name-mapping.default": ""})), answers(**plain_answers)),
        ("metadata_encryption_keys", lambda: edited(lambda m: m.__setitem__("encryption-keys", [{"key-id": "k"}])), refuses("Unsupported", "the table holds encryption keys, and this reader decrypts nothing")),
        ("metadata_encryption_keys_empty", lambda: edited(lambda m: m.__setitem__("encryption-keys", [])), answers(**plain_answers)),
        ("metadata_properties_not_object", lambda: edited(lambda m: m.__setitem__("properties", 5)), refuses("ParseError", "properties is not an object")),
        ("metadata_refs_not_object", lambda: edited(lambda m: m.__setitem__("refs", 5)), refuses("ParseError", "refs is not an object")),
        ("metadata_main_not_object", lambda: edited(lambda m: m.__setitem__("refs", {"main": 5})), refuses("ParseError", "the main reference is not an object")),
        ("metadata_main_no_snapshot", lambda: edited(lambda m: m.__setitem__("refs", {"main": {"type": "branch"}})), refuses("ParseError", 'the main reference names no "snapshot-id"')),
        ("metadata_refs_disagree", lambda: edited(lambda m: m["refs"]["main"].__setitem__("snapshot-id", 123)), refuses("ParseError", f"refs names the snapshot 123 for main, current-snapshot-id the snapshot {snapshot}")),
        ("metadata_refs_without_current", lambda: edited(lambda m: m.pop("current-snapshot-id")), refuses("ParseError", f"refs names the snapshot {snapshot} for main, current-snapshot-id none")),
        ("metadata_current_minus_one_with_refs", lambda: edited(lambda m: m.__setitem__("current-snapshot-id", -1)), refuses("ParseError", f"refs names the snapshot {snapshot} for main, current-snapshot-id none")),
        ("metadata_snapshot_unknown", lambda: edited(lambda m: (m["refs"]["main"].__setitem__("snapshot-id", 123), m.__setitem__("current-snapshot-id", 123))), refuses("ParseError", "the snapshot 123 is named as current, but the metadata's snapshots do not hold it")),
        ("metadata_snapshots_not_array", lambda: edited(lambda m: m.__setitem__("snapshots", {})), refuses("ParseError", "snapshots is not an array")),
        ("metadata_snapshot_not_object", lambda: edited(lambda m: m.__setitem__("snapshots", [5])), refuses("ParseError", "a snapshot is not an object")),
        ("metadata_snapshot_no_id", lambda: edited(lambda m: m["snapshots"][0].pop("snapshot-id")), refuses("ParseError", 'a snapshot names no "snapshot-id"')),
        ("metadata_snapshot_no_list", lambda: edited(lambda m: m["snapshots"][0].pop("manifest-list")), refuses("ParseError", f'the snapshot {snapshot} names no "manifest-list"')),
        ("metadata_snapshot_list_number", lambda: edited(lambda m: m["snapshots"][0].__setitem__("manifest-list", 5)), refuses("ParseError", f"the snapshot {snapshot}'s manifest-list is not a string")),
        ("metadata_snapshot_sequence_negative", lambda: edited(lambda m: m["snapshots"][0].__setitem__("sequence-number", -1)), refuses("ParseError", f"the snapshot {snapshot} carries the sequence number -1")),
        ("metadata_snapshot_sequence_text", lambda: edited(lambda m: m["snapshots"][0].__setitem__("sequence-number", "1")), refuses("ParseError", f"the snapshot {snapshot}'s sequence-number is not a 64-bit whole number")),
        ("metadata_snapshot_no_sequence", lambda: edited(lambda m: m["snapshots"][0].pop("sequence-number")), answers(**plain_answers)),
        ("metadata_snapshot_key_id", lambda: edited(lambda m: m["snapshots"][0].__setitem__("key-id", "k")), refuses("Unsupported", f"the snapshot {snapshot} names an encryption key, and this reader decrypts nothing")),
        ("metadata_list_outside", lambda: edited(lambda m: m["snapshots"][0].__setitem__("manifest-list", "C:/elsewhere/snap.avro")), refuses("Unsupported", f"the manifest list of the snapshot {snapshot} C:/elsewhere/snap.avro lies outside the table location {location}")),
        ("metadata_list_other_scheme", lambda: edited(lambda m: m["snapshots"][0].__setitem__("manifest-list", "s3://bucket/snap.avro")), refuses("Unsupported", f"the manifest list of the snapshot {snapshot} s3://bucket/snap.avro lies under the scheme s3, not under the table location {location}, which lies under no scheme")),
        ("metadata_list_empty", lambda: edited(lambda m: m["snapshots"][0].__setitem__("manifest-list", "")), refuses("ParseError", f"the snapshot {snapshot}'s manifest-list is an empty path")),
        ("metadata_location_slashes", lambda: edited(lambda m: m.__setitem__("location", "///")), refuses("ParseError", "the table's location is empty")),
        ("metadata_location_uri", lambda: edited(lambda m: (m.__setitem__("location", "file:///wh/ns/t"), m["snapshots"][0].__setitem__("manifest-list", "file:///wh/ns/t/metadata/snap.avro"))), answers(field_ids=[1, 2], manifest_list="metadata/snap.avro", partition_fields=[])),
        ("metadata_legacy_schema", lambda: edited(lambda m: (m.__setitem__("schema", m.pop("schemas")[0]))), answers(**plain_answers)),
        ("metadata_no_partition_specs", lambda: edited(lambda m: (m.pop("partition-specs"), m.pop("default-spec-id"))), answers(**plain_answers)),
        ("metadata_legacy_partition_spec", lambda: edited(lambda m: (m.__setitem__("partition-specs", []), m.__setitem__("partition-spec", [{"source-id": 2, "name": "s", "transform": "identity"}]))), answers(field_ids=[1, 2], manifest_list=list_rel, partition_fields=[["s", 2, "identity"]])),
        ("metadata_minus_one_no_snapshot", lambda: edited(lambda m: (m.__setitem__("snapshots", []), m.__setitem__("current-snapshot-id", -1), m.__setitem__("refs", {}))), answers(field_ids=[1, 2], manifest_list=None, partition_fields=[])),
        ("metadata_no_refs", lambda: edited(lambda m: m.pop("refs")), answers(**plain_answers)),
        ("metadata_write_default", lambda: edited(lambda m: first_field(m).__setitem__("write-default", 5)), answers(**plain_answers)),
        ("metadata_decimals", lambda: edited(lambda m: (first_field(m).__setitem__("type", "decimal(9,2)"), m["schemas"][0]["fields"][1].__setitem__("type", "decimal(10,   5)"))), answers(dtypes=["Decimal", "Decimal"], **plain_answers)),
        ("metadata_every_type", lambda: edited(lambda m: m["schemas"][0].__setitem__("fields", [
            {"id": k, "name": n, "type": t, "required": True}
            for k, (n, t) in enumerate([
                ("b", "boolean"), ("i", "int"), ("l", "long"), ("f", "float"), ("d", "double"), ("s", "string"),
                ("dt", "date"), ("ts", "timestamp"), ("tz", "timestamptz"), ("dec", "decimal(20, 4)"),
                ("lst", {"type": "list", "element-id": 30, "element": "int", "element-required": False}),
                ("st", {"type": "struct", "fields": [{"id": 31, "name": "x", "type": "long", "required": False}, {"id": 32, "name": "y", "type": "date", "required": True}]}),
            ], 1)
        ])), answers(dtypes=["Bool", "Int", "Int", "Float", "Float", "String", "Date", "Timestamp", "Timestamp", "Decimal", "List[Int]", "Struct{x: Int, y: Date}"], field_ids=[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], manifest_list=list_rel, partition_fields=[])),
        ("metadata_no_current_schema_id", lambda: edited(lambda m: m.pop("current-schema-id")), answers(**plain_answers)),
        ("metadata_schema_no_id", lambda: edited(lambda m: m["schemas"][0].pop("schema-id")), answers(**plain_answers)),
        ("metadata_no_snapshots", lambda: edited(lambda m: (m.pop("snapshots"), m.pop("refs"), m.pop("current-snapshot-id"))), answers(field_ids=[1, 2], manifest_list=None, partition_fields=[])),
        ("metadata_no_properties", lambda: edited(lambda m: m.pop("properties")), answers(**plain_answers)),
        # A member spelled null is one the object does not carry.
        ("metadata_null_schema_id", lambda: edited(lambda m: m["schemas"][0].__setitem__("schema-id", None)), answers(**plain_answers)),
        ("metadata_type_member_number", lambda: edited(lambda m: first_field(m).__setitem__("type", {"type": 5})), refuses("ParseError", 'the type of column "i" is not a string')),
        # Bytes that are not JSON: the parser's own account, as it renders
        # it — a bad character with its place, the end of the text, a key
        # twice, a document nested too deep.
        ("metadata_bad_number", lambda: b'{"format-version": 01}', refuses("ParseError", "the metadata is not JSON: Invalid character '1' at line 1, column 20")),
        ("metadata_bad_ident", lambda: b'{"format-version": tru}', refuses("ParseError", "the metadata is not JSON: Invalid character '}' at line 1, column 22")),
        ("metadata_bad_escape", lambda: b'{"format-version": 2, "a": f\\x61lse}', refuses("ParseError", "the metadata is not JSON: Invalid character '\\\\' at line 1, column 28")),
        ("metadata_number_cut", lambda: b'{"format-version": 1.}', refuses("ParseError", "the metadata is not JSON: Invalid character '}' at line 1, column 21")),
        ("metadata_leading_dot", lambda: b'{"format-version": .5}', refuses("ParseError", "the metadata is not JSON: Invalid character '.' at line 1, column 19")),
        ("metadata_ident_tail", lambda: b'{"a": nulll}', refuses("ParseError", "the metadata is not JSON: Invalid character 'l' at line 1, column 10")),
        ("metadata_duplicate_key", lambda: b'{"format-version": 2, "format-version": 3}', refuses("ParseError", 'the metadata is not JSON: Duplicate key "format-version" at line 1, column 22')),
        ("metadata_too_deep", lambda: b'{"format-version": 2, "x": ' + b"[" * 129 + b"]" * 129 + b"}", refuses("ParseError", "the metadata is not JSON: Depth limit exceeded, please increase the max_nesting_depth parameter")),
    ]
    return shapes


# ------------------------------------------------------------------ lists
def list_shapes(location: str, real_list_path: str) -> list:
    """Manifest lists: the real one of `append_one` with bytes patched in
    place, and ones built record by record."""
    real = open(real_list_path, "rb").read()
    parsed = Container(real)
    block = parsed.blocks[0]
    codec_at = parsed.value_at["avro.codec"]
    inflated = len(parsed.payload(0))

    def patched(data: bytes, at: int, length: int, replacement: bytes) -> bytes:
        assert len(replacement) == length
        return data[:at] + replacement + data[at + length:]

    size_at = block["size_at"]
    size_length = block["payload_at"] - size_at
    shapes = []
    def add(name, data, variant, text, **extra):
        shapes.append((name, data, {"codec": "refuses", "refusal": {"variant": variant, "text": "iceberg: " + text, "step": "manifest_list"}, **extra}))

    def plain(name, data, manifests):
        shapes.append((name, data, {"codec": "reads", "manifests": [{"path": p} for p in manifests], "location": location}))

    add("list_bad_magic", b"\x00" + real[1:], "ParseError", "byte 0: a file that does not open with the Avro magic")
    add("list_too_short", real[:3], "ParseError", "a file of 3 bytes, too short for the magic")
    add("list_empty", b"", "ParseError", "a file of 0 bytes, too short for the magic")
    # The codec's value begins after its one-byte length; the refusal names
    # the length's byte.
    add("list_codec_unknown", patched(real, codec_at + 1, 7, b"unknown"), "ParseError", f'byte {codec_at}: the header names the block codec "unknown", which this reader does not inflate')
    add("list_codec_deflate_corrupt", patched(real, block["payload_at"], block["size"], b"\xff" * block["size"]), "ParseError", f"byte {block['count_at']}: a deflate block that does not decompress within 16777216 bytes")
    add("list_sync_truncated", real[: parsed.sync_at + 5], "ParseError", f"byte {parsed.sync_at} of the manifest list as a file: a file that ends inside its sync marker")
    schema_at = parsed.value_at["avro.schema"]
    add("list_header_truncated", real[: schema_at + 10], "ParseError", f"byte {schema_at} of the manifest list as a file: a length of {len(parsed.metadata['avro.schema'])} bytes that the bytes cannot hold")
    count_zero = patched(real, block["count_at"], 1, b"\x00")
    add("list_block_count_zero_then_bytes", count_zero + b"\x00", "ParseError", f"byte {len(count_zero)}: 1 bytes past a block of no records")
    # 127 zigzag-decodes to -64.
    add("list_block_count_negative", patched(real, block["count_at"], 1, bytes([127])), "ParseError", f"byte {block['count_at']}: a block of -64 records")
    # A count no single byte can spell: more records than the block has bytes.
    too_many = Container.build({"avro.schema": parsed.metadata["avro.schema"]}, 200, parsed.payload(0))
    add("list_block_count_too_many", too_many, "ParseError", f"byte {block_offset(too_many)}: a block of 200 records in {inflated} bytes")
    add("list_block_size_past", patched(real, size_at, size_length, b"\xfe\x7f" + b"\x00" * (size_length - 2)), "ParseError", f"byte {block['count_at']}: a block of 8191 bytes, past what the file holds")
    short_size = block["size"] - 1
    short_encoded = varint(short_size << 1)
    assert len(short_encoded) == size_length
    add("list_block_size_short", patched(real, size_at, size_length, short_encoded), "ParseError", f"byte {block['payload_at'] + short_size}: a block whose sync marker differs from the file's")
    add("list_sync_mismatch", patched(real, block["marker_at"], 1, bytes([real[block["marker_at"]] ^ 0xFF])), "ParseError", f"byte {block['marker_at']}: a block whose sync marker differs from the file's")
    add("list_block_truncated", real[: block["payload_at"] + 10], "ParseError", f"byte {block['count_at']}: a block of {block['size']} bytes, past what the file holds")
    plain("list_no_blocks", real[: block["count_at"]], [])
    plain("list_count_zero_closes", count_zero[: block["marker_at"] + 16], [])

    path = f"{location}/metadata/x.avro"
    full = location + "/metadata/x.avro"

    def built(records, fields=LIST_FIELDS, metadata=None):
        """A list whose schema is `fields`, or — when `fields` is None —
        whatever `avro.schema` the metadata spells."""
        meta = dict(metadata or {})
        if isinstance(fields, dict) and "fields" in fields:
            # A whole record schema in place of its fields.
            fields = fields["fields"]
        if fields is not None:
            meta["avro.schema"] = json.dumps({"type": "record", "fields": fields}, separators=(",", ":"))
        return Container.build(meta, len(records), b"".join(record_bytes({"type": "record", "fields": fields or []}, record) for record in records))

    def hand(name, records, variant, text, fields=LIST_FIELDS, metadata=None, **extra):
        add(name, built(records, fields, metadata), variant, text, **extra)

    # --- its schema: named types, logical types, and the shapes it cannot be
    one_field = lambda ty, field_id=500: {"type": "record", "fields": [{"name": "a", "type": ty, "field-id": field_id}]}
    listed = [{"path": "metadata/x.avro"}]

    def with_extra(ty, field_id=900):
        """The list's own schema with one more field, of the type in
        question, past the ids a list's schema has to name."""
        return LIST_FIELDS + [{"name": "a", "type": ty, "field-id": field_id}]

    plain("list_named_reference", built(
        [dict(list_record(full), a=b"\x00\x00\x00\x01", b=b"\x00\x00\x00\x02")],
        with_extra({"type": "fixed", "name": "f4", "size": 4, "logicalType": "decimal", "precision": 9, "scale": 2}) + [{"name": "b", "type": "f4", "field-id": 901}],
    ), ["metadata/x.avro"])
    plain("list_named_namespace", built(
        [dict(list_record(full), a=b"\x01\x02", b=b"\x03\x04")],
        with_extra({"type": "fixed", "name": "n", "namespace": "a.b", "size": 2}) + [{"name": "b", "type": "a.b.n", "field-id": 901}],
    ), ["metadata/x.avro"])
    plain("list_decimal_no_scale", built([dict(list_record(full), a=b"\x01")], with_extra({"type": "bytes", "logicalType": "decimal", "precision": 9})), ["metadata/x.avro"])
    hand("list_decimal_out_of_range", [], "ParseError", "a decimal with precision 0 and scale 0", fields=one_field({"type": "fixed", "name": "f", "size": 4, "logicalType": "decimal", "precision": 0, "scale": 0})["fields"])
    plain("list_decimal_on_int", built([dict(list_record(full), a=5)], with_extra({"type": "int", "logicalType": "decimal", "precision": 9, "scale": 2})), ["metadata/x.avro"])
    plain("list_logical_map_three_fields", built([dict(list_record(full), a=[{"x": 1, "y": 2, "z": 3}])], with_extra({"type": "array", "logicalType": "map", "items": {"type": "record", "name": "r", "fields": [
        {"name": "x", "type": "int", "field-id": 1}, {"name": "y", "type": "int", "field-id": 2}, {"name": "z", "type": "int", "field-id": 3}]}})), ["metadata/x.avro"])
    plain("list_logical_map_on_string", built([dict(list_record(full), a="x")], with_extra({"type": "string", "logicalType": "map"})), ["metadata/x.avro"])
    hand("list_enum_no_symbol", [], "ParseError", "an enum with no symbol", fields=one_field({"type": "enum", "name": "e", "symbols": []})["fields"])
    hand("list_fixed_size_zero", [], "ParseError", "a fixed type of size 0", fields=one_field({"type": "fixed", "name": "f", "size": 0})["fields"])
    hand("list_dangling_keyword", [], "ParseError", 'a schema that refers to the type "nothing", which it never defines', fields=one_field({"type": "nothing", "name": "x"})["fields"])
    plain("list_nested_definition", built([dict(list_record(full), a="x")], with_extra({"type": {"type": "string"}, "doc": "d"})), ["metadata/x.avro"])
    deep = "string"
    for _ in range(66):
        deep = {"type": deep}
    hand("list_depth", [], "ParseError", "a schema nested deeper than 64 types", fields=one_field(deep)["fields"])
    hand("list_union_of_union", [], "ParseError", "a union that is not a null and one type", fields=one_field(["null", ["null", "int"]])["fields"])
    hand("list_union_null_null", [], "ParseError", "a union that is not a null and one type", fields=one_field(["null", "null"])["fields"])
    v1_schema = {"type": "record", "fields": [f for f in LIST_FIELDS if f["field-id"] not in (515, 517, 519)]}
    v1_fields = v1_schema["fields"]
    plain("list_no_codec", Container.build_raw({"avro.schema": json.dumps(v1_schema, separators=(",", ":"))}, 1, record_bytes(v1_schema, list_record(full, length=7, spec_id=0, snapshot=1))), ["metadata/x.avro"])
    many = {f"k{i}": "v" for i in range(1025)}
    many["avro.schema"] = json.dumps(v1_schema, separators=(",", ":"))
    add("list_metadata_limit", Container.build_raw(many, 0, b""), "ParseError", "byte 4: a header with more than 1024 metadata entries")
    hand("list_schema_top_union", [], "ParseError", "the manifest list: a top-level Avro schema that is a union, not a record", fields=None, metadata={"avro.schema": '["null", ' + json.dumps({"type": "record", "fields": LIST_FIELDS}, separators=(",", ":")) + "]"})
    data = built([dict(list_record(full), manifest_path=b"\xff")])
    add("list_string_not_utf8", data, "ParseError", f"byte 0 of the block at byte {block_offset(data)}: a string that is not valid UTF-8")

    hand("list_content_out_of_set", [list_record(path, content=7)], "ParseError", "manifest entry 0 of the list: the content 7, not 0 for data or 1 for deletes")
    hand("list_length_negative", [list_record(path, length=-1)], "ParseError", "manifest entry 0 of the list: the manifest length -1")
    hand("list_no_length", [dict(list_record(path), manifest_length=None)], "ParseError", "manifest entry 0 of the list names no length", fields=optional(LIST_FIELDS, 501))
    hand("list_no_path", [dict(list_record(path), manifest_path=None)], "ParseError", "manifest entry 0 of the list names no path", fields=optional(LIST_FIELDS, 500))
    hand("list_no_spec_id", [dict(list_record(path), partition_spec_id=None)], "ParseError", "manifest entry 0 of the list names no partition spec id", fields=optional(LIST_FIELDS, 502))
    hand("list_no_snapshot_id", [dict(list_record(path), added_snapshot_id=None)], "ParseError", "manifest entry 0 of the list names no added snapshot id", fields=optional(LIST_FIELDS, 503))
    hand("list_sequence_negative", [list_record(path, sequence=-1)], "ParseError", "manifest entry 0 of the list: the sequence number -1")
    hand("list_key_metadata", [list_record(full, key_metadata=b"k")], "Unsupported", "the manifest metadata/x.avro: it carries key metadata, which marks it as encrypted, and this reader decrypts nothing")
    hand("list_path_outside", [list_record("C:/other/x.avro")], "Unsupported", f"the manifest C:/other/x.avro lies outside the table location {location}")
    hand("list_path_other_scheme", [list_record("s3://bucket/x.avro")], "Unsupported", f"the manifest s3://bucket/x.avro lies under the scheme s3, not under the table location {location}, which lies under no scheme")
    hand("list_path_empty", [list_record("")], "ParseError", "the manifest is an empty path")
    hand("list_second_entry", [list_record(full), list_record(full, content=9)], "ParseError", "manifest entry 1 of the list: the content 9, not 0 for data or 1 for deletes")
    no_path = {"type": "record", "fields": [f for f in LIST_FIELDS if f["field-id"] != 500]}
    hand("list_schema_no_path", [list_record(path, length=7, spec_id=0, snapshot=1, sequence=0, content=0)], "ParseError", "the manifest list: a schema that names no field with the id 500", fields=no_path["fields"])
    hand("list_schema_top_not_record", [], "ParseError", "the manifest list: a top-level Avro schema that is an int, not a record", fields=None, metadata={"avro.schema": '"int"'})
    add("list_schema_no_avro", Container.build({}, 0, b""), "ParseError", 'the manifest list: the header names no "avro.schema"', step="manifest_list")
    hand("list_schema_not_json", [], "ParseError", "the manifest list's Avro schema is not JSON: Unexpected end of file", fields=None, metadata={"avro.schema": "{"})
    hand("list_schema_number", [], "ParseError", "a schema entry that is neither a name, a union, or a type definition", fields=None, metadata={"avro.schema": "5"})
    dangling = {"type": "record", "fields": [{"name": "a", "type": "nothing", "field-id": 500}]}
    hand("list_schema_dangling", [], "ParseError", 'a schema that refers to the type "nothing", which it never defines', fields=dangling["fields"])
    union = {"type": "record", "fields": [{"name": "a", "type": ["null", "int", "long"], "field-id": 500}]}
    hand("list_schema_union", [], "ParseError", "a union that is not a null and one type", fields=union["fields"])
    v1 = [f for f in LIST_FIELDS if f["field-id"] not in (515, 517, 519)]
    plain("list_v1_defaults", built([list_record(full, length=7, spec_id=0, snapshot=1)], v1), ["metadata/x.avro"])
    payload = record_bytes({"type": "record", "fields": v1}, list_record(full))
    with_extra = Container.build({"avro.schema": json.dumps({"type": "record", "fields": v1}, separators=(",", ":"))}, 1, payload + b"\x00")
    add("list_bytes_past_record", with_extra, "ParseError", f"the block at byte {block_offset(with_extra)}: 1 bytes past the last record")
    return shapes


# -------------------------------------------------------------- manifests
def manifest_shapes(location: str) -> list:
    """Manifests built record by record: one file for every malformed shape
    of a manifest, and the shapes it must accept. Where a shape needs the
    manifest list's entry — the length, the content, the spec, the location
    — a list naming it is built beside it."""
    path = f"{location}/data/x.parquet"
    rel = "data/x.parquet"
    shapes = []

    def header(**extra):
        base = {"schema": json.dumps(TABLE_SCHEMA, separators=(",", ":")), "partition-spec": "[]", "format-version": "2", "content": "data", "partition-spec-id": "0"}
        base.update(extra)
        for key in [k for k, v in base.items() if v is None]:
            del base[key]
        return base

    def build(entries, schema=None, spec=None, metadata=None, codec="null", suffix=b""):
        """A manifest from its header, its Avro schema and its records; a
        schema of `"__none__"` leaves the header without one. The header's
        partition spec is `spec` when one is given, and otherwise whatever
        the metadata spells."""
        meta = header() if metadata is None else metadata
        if spec is not None:
            meta["partition-spec"] = spec
        if schema == "__none__":
            return Container.build({}, len(entries), b"")
        return container(schema or entry_schema(), entries, meta, codec=codec, suffix=suffix)

    def named_list(data: bytes, spec_id=0, content=0, sequence=7, length=None):
        return container({"type": "record", "fields": LIST_FIELDS}, [list_record(f"{location}/metadata/x.avro", length=len(data) if length is None else length, spec_id=spec_id, content=content, sequence=sequence)], {})

    def refuses(name, data, variant, text, with_list=None, **extra):
        item = {"shape": name, "file": f"patched/{name}.avro", "kind": MANIFEST, "codec": "refuses", "refusal": {"variant": variant, "text": "iceberg: " + text, "step": "manifest"}, "location": location, **extra}
        if with_list is not None:
            item["list"] = f"patched/{name}.list.avro"
            shapes.append((f"{name}.list", with_list, None))
        shapes.append((name, data, item))

    def reads(name, data, files, with_list=None, **extra):
        if with_list is None:
            # Without the list's entry the manifest is not told where the
            # table lies, so it answers each path as the manifest spells it.
            files = [dict(f, path=path) if f["path"] == rel else f for f in files]
        item = {"shape": name, "file": f"patched/{name}.avro", "kind": MANIFEST, "codec": "reads", "location": location, "files": files, **extra}
        if with_list is not None:
            item["list"] = f"patched/{name}.list.avro"
            shapes.append((f"{name}.list", with_list, None))
        shapes.append((name, data, item))

    def file_entry(**what):
        out = {"path": rel, "kind": 0, "record_count": 3, "sequence_number": 0, "field_ids": [1, 2], "partition": [], "equality_ids": []}
        out.update(what)
        return out

    # --- what a manifest must answer
    reads("manifest_data_file", build([entry(file_path=path)]), [file_entry(sequence_number=7)], with_list=named_list(build([entry(file_path=path)])))
    for name, content, kind, ids in (("manifest_position_delete", 1, 1, []), ("manifest_equality_delete", 2, 2, [1])):
        data = build([entry(file_path=path, content=content, equality_ids=ids)])
        reads(name, data, [file_entry(kind=kind, equality_ids=ids, sequence_number=7)], with_list=named_list(data))
    data = build([entry(status=2, file_path=path), entry(status=0, file_path=path, record_count=9)])
    reads("manifest_deleted_and_existing", data, [file_entry(record_count=9, sequence_number=0)], with_list=named_list(data))
    data = build([entry(status=2, file_path=path, file_format="AVRO", content=9)])
    reads("manifest_deleted_entry", data, [])
    data = build([entry(file_path=path, file_format="parquet")])
    reads("manifest_format_lower_case", data, [file_entry()])
    data = build([entry(file_path=path, file_format="ParQuet")])
    reads("manifest_format_mixed_case", data, [file_entry()])
    reads("manifest_no_blocks", build([]), [])
    # A manifest of format version 1: no content, no sequence numbers, and
    # the fields that version alone wrote.
    v1 = {"type": "record", "name": "manifest_entry", "fields": [
        {"name": "status", "type": "int", "field-id": 0},
        {"name": "snapshot_id", "type": "long", "field-id": 1},
        {"name": "data_file", "type": {"type": "record", "name": "r2", "fields": [
            {"name": "file_path", "type": "string", "field-id": 100},
            {"name": "file_ordinal", "type": ["null", "int"], "field-id": 106},
            {"name": "file_format", "type": "string", "field-id": 101},
            {"name": "partition", "type": empty_record(), "field-id": 102},
            {"name": "record_count", "type": "long", "field-id": 103},
            {"name": "block_size_in_bytes", "type": "long", "field-id": 105},
            {"name": "distinct_counts", "type": {"type": "map", "values": ["null", "long"]}, "field-id": 111},
            {"name": "split_offsets", "type": {"type": "array", "element-id": 133, "items": "long"}, "field-id": 132},
            {"name": "sort_order_id", "type": ["null", "int"], "field-id": 140},
        ]}, "field-id": 2},
    ]}
    data = container(v1, [{"status": 1, "snapshot_id": 77, "data_file": {"file_path": path, "file_ordinal": None, "file_format": "PARQUET", "partition": {}, "record_count": 4, "block_size_in_bytes": 67108864, "distinct_counts": [(1, 3)], "split_offsets": [4], "sort_order_id": None}}], {"schema": json.dumps(TABLE_SCHEMA, separators=(",", ":")), "partition-spec": "[]"})
    reads("manifest_v1_schema", data, [file_entry(record_count=4, field_ids=[])])
    spec_d = json.dumps([{"source-id": 3, "field-id": 1000, "transform": "identity", "name": "d"}])
    partition_d = {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", DATE], "field-id": 1000}]}
    fields = data_file_fields(partition_type=partition_d)
    data = build([entry(file_path=path, partition={"d": 19000}), entry(file_path=path, partition={"d": None})], entry_schema(fields), spec=spec_d)
    reads("manifest_partition_values", data, [file_entry(partition=[["d", 3, "identity", {"kind": "date", "value": 19000}]]), file_entry(partition=[["d", 3, "identity", {"kind": "null"}]])])
    spec_scalars = json.dumps([
        {"source-id": 1, "field-id": 1000, "transform": "identity", "name": "i"},
        {"source-id": 2, "field-id": 1001, "transform": "truncate[2]", "name": "s_trunc"},
        {"source-id": 3, "field-id": 1002, "transform": "year", "name": "d_year"},
        {"source-id": 4, "field-id": 1003, "transform": "void", "name": "b_void"},
        {"source-id": 5, "field-id": 1004, "transform": "identity", "name": "m"},
        {"source-id": 6, "field-id": 1005, "transform": "identity", "name": "t"},
        {"source-id": 6, "field-id": 1006, "transform": "bucket[8]", "name": "t_bucket"},
        {"source-id": 6, "field-id": 1007, "transform": "hour", "name": "t_hour"},
        {"source-id": 3, "field-id": 1008, "transform": "day", "name": "d_day"},
        {"source-id": 3, "field-id": 1009, "transform": "month", "name": "d_month"},
        {"source-id": 1, "field-id": 1010, "transform": "temporal[1, 2]", "name": "i_copy"},
    ])
    partition_scalars = {"type": "record", "name": "r102", "fields": [
        {"name": "i", "type": ["null", "long"], "field-id": 1000},
        {"name": "s_trunc", "type": ["null", "string"], "field-id": 1001},
        {"name": "d_year", "type": ["null", "int"], "field-id": 1002},
        {"name": "b_void", "type": ["null", "int"], "field-id": 1003},
        {"name": "m", "type": ["null", DECIMAL_FIXED_5_2], "field-id": 1004},
        {"name": "t", "type": ["null", {"type": "long", "logicalType": "timestamp-micros", "adjust-to-utc": False}], "field-id": 1005},
        {"name": "t_bucket", "type": ["null", "int"], "field-id": 1006},
        {"name": "t_hour", "type": ["null", "long"], "field-id": 1007},
        {"name": "d_day", "type": ["null", DATE], "field-id": 1008},
        {"name": "d_month", "type": ["null", "int"], "field-id": 1009},
        {"name": "i_copy", "type": ["null", "long"], "field-id": 1010},
    ]}
    stamp = 1_583_164_496_789_012
    values = {"i": -5, "s_trunc": "ab", "d_year": 52, "b_void": None, "m": 12345, "t": stamp, "t_bucket": 3, "t_hour": 439768, "d_day": 19000, "d_month": 625, "i_copy": 9}
    spelled = [
        ["i", 1, "identity", {"kind": "int", "value": -5}],
        ["s_trunc", 2, "truncate[2]", {"kind": "string", "value": "ab"}],
        ["d_year", 3, "year", {"kind": "int", "value": 52}],
        ["b_void", 4, "void", {"kind": "null"}],
        ["m", 5, "identity", {"kind": "decimal", "value": "123.45"}],
        ["t", 6, "identity", {"kind": "timestamp", "value": str(stamp)}],
        ["t_bucket", 6, "bucket[8]", {"kind": "int", "value": 3}],
        ["t_hour", 6, "hour", {"kind": "int", "value": 439768}],
        ["d_day", 3, "day", {"kind": "date", "value": 19000}],
        ["d_month", 3, "month", {"kind": "int", "value": 625}],
        ["i_copy", 1, "temporal[1, 2]", {"kind": "int", "value": 9}],
    ]
    data = build([entry(file_path=path, partition=values)], entry_schema(data_file_fields(partition_type=partition_scalars)), spec=spec_scalars)
    reads("manifest_partition_scalars", data, [file_entry(partition=spelled)])
    unknown_types = [
        {"name": "nothing", "type": "null", "field-id": 900},
        {"name": "flag", "type": "boolean", "field-id": 901},
        {"name": "ratio", "type": "float", "field-id": 902},
        {"name": "ratio2", "type": "double", "field-id": 903},
        {"name": "blob", "type": "bytes", "field-id": 904},
        {"name": "choice", "type": {"type": "enum", "name": "choice", "symbols": ["a", "b"]}, "field-id": 905},
        {"name": "tag", "type": {"type": "fixed", "name": "tag", "size": 3}, "field-id": 906},
        {"name": "numbers", "type": {"type": "array", "items": "int"}, "field-id": 907},
        {"name": "counts", "type": {"type": "map", "values": ["null", "long"]}, "field-id": 908},
        {"name": "run", "type": {"type": "bytes", "logicalType": "decimal", "precision": 10, "scale": 2}, "field-id": 909},
        {"name": "inner", "type": {"type": "record", "name": "r910", "fields": [{"name": "x", "type": "long", "field-id": 911}, {"name": "y", "type": ["null", "string"], "field-id": 912}]}, "field-id": 910},
        {"name": "maybe", "type": ["null", "int"], "field-id": 913},
    ]
    schema_unknown = copy.deepcopy(entry_schema())
    schema_unknown["fields"] = schema_unknown["fields"][:2] + unknown_types + schema_unknown["fields"][2:]
    unknown_values = {"nothing": None, "flag": True, "ratio": 0.5, "ratio2": -2.25, "blob": b"\x01\x02", "choice": 1, "tag": b"abc", "numbers": [1, -2, 3], "counts": [(7, 1), (8, None)], "run": -1500, "inner": {"x": 4, "y": "q"}, "maybe": None}
    data = build([dict(entry(file_path=path, record_count=5), **unknown_values)], schema_unknown)
    reads("manifest_skips_unknown_fields", data, [file_entry(record_count=5)])
    metric_fields = data_file_fields()
    values = entry(file_path=path, column_sizes=[(3, 5), (1, 9)], value_counts=[(1, 3)], null_value_counts=[(2, 1), (3, 0)], nan_value_counts=[], lower_bounds=[(6, b"\x01")], upper_bounds=[(2, b"s")])
    extra_metrics = [
        {"name": "value_counts", "type": {"type": "map", "values": ["null", "long"]}, "field-id": 109},
        {"name": "null_value_counts", "type": {"type": "map", "values": ["null", "long"]}, "field-id": 110},
        {"name": "nan_value_counts", "type": {"type": "map", "values": ["null", "long"]}, "field-id": 137},
        {"name": "lower_bounds", "type": {"type": "map", "values": ["null", "bytes"]}, "field-id": 125},
        {"name": "upper_bounds", "type": {"type": "map", "values": ["null", "bytes"]}, "field-id": 128},
    ]
    schema_metrics = entry_schema(metric_fields[:5] + extra_metrics + metric_fields[5:])
    data = build([values], schema_metrics)
    reads("manifest_metric_ids", data, [file_entry(field_ids=[1, 2, 3, 6])])

    # --- what a manifest must refuse: its entries
    refuses("manifest_status_out_of_set", build([entry(status=3, file_path=path)]), "ParseError", "entry 0 of the manifest: the status 3, not 0, 1 or 2")
    optional_status = copy.deepcopy(entry_schema())
    optional_status["fields"][0]["type"] = ["null", "int"]
    refuses("manifest_status_null", build([dict(entry(file_path=path), status=None)], optional_status), "ParseError", "entry 0 of the manifest names no status")
    refuses("manifest_no_path", build([entry()], entry_schema(optional(data_file_fields(), 100))), "ParseError", "entry 0 of the manifest names no path")
    refuses("manifest_path_empty", build([entry(file_path="")]), "ParseError", "the file is an empty path")
    refuses("manifest_format_avro", build([entry(file_path=path, file_format="AVRO")]), "Unsupported", f"the file {path}: the format AVRO, where this reader reads parquet files only")
    refuses("manifest_no_format", build([entry(file_path=path, file_format=None)], entry_schema(optional(data_file_fields(), 101))), "ParseError", "entry 0 of the manifest names no format")
    refuses("manifest_record_count_negative", build([entry(file_path=path, record_count=-1)]), "ParseError", "entry 0 of the manifest: the record count -1")
    refuses("manifest_no_record_count", build([entry(file_path=path, record_count=None)], entry_schema(optional(data_file_fields(), 103))), "ParseError", "entry 0 of the manifest names no record count")
    refuses("manifest_content_out_of_set", build([entry(file_path=path, content=5)]), "ParseError", "entry 0 of the manifest: the content 5, not 0, 1 or 2")
    refuses("manifest_key_metadata", build([entry(file_path=path, key_metadata=b"k")]), "Unsupported", f"the file {path}: it carries key metadata, which marks it as encrypted, and this reader decrypts nothing")
    required_key = data_file_fields(replacements={131: {"name": "key_metadata", "type": "bytes", "field-id": 131}})
    refuses("manifest_key_metadata_required", build([entry(file_path=path, key_metadata=b"k")], entry_schema(required_key)), "Unsupported", f"the file {path}: it carries key metadata, which marks it as encrypted, and this reader decrypts nothing")
    refuses("manifest_equality_no_column", build([entry(file_path=path, content=2)]), "ParseError", f"the equality-delete file {path} names no column")
    refuses("manifest_equality_null_ids", build([entry(file_path=path, content=2, equality_ids=None)]), "ParseError", f"the equality-delete file {path} names no column")
    refuses("manifest_sequence_negative", build([entry(file_path=path, sequence_number=-5)]), "ParseError", "entry 0 of the manifest: the sequence number -5")
    data = build([entry(file_path="C:/other/x.parquet")])
    refuses("manifest_path_outside", data, "Unsupported", f"the file C:/other/x.parquet lies outside the table location {location}", with_list=named_list(data))
    data = build([entry(file_path="s3://bucket/x.parquet")])
    refuses("manifest_path_other_scheme", data, "Unsupported", f"the file s3://bucket/x.parquet lies under the scheme s3, not under the table location {location}, which lies under no scheme", with_list=named_list(data))
    data = build([entry(status=0, file_path=path), entry(status=3, file_path=path)])
    refuses("manifest_second_entry_bad", data, "ParseError", "entry 1 of the manifest: the status 3, not 0, 1 or 2")
    index5 = build([entry(file_path=path, sequence_number=Raw(5, 1))])
    offset = block_offset(index5)
    refuses("manifest_union_index_outside", index5, "ParseError", f"byte 1 of the block at byte {offset}: the union index 5, outside its two branches")
    data = build([entry(file_path=path, sequence_number=Raw(2, 1))])
    refuses("manifest_union_index_two", data, "ParseError", f"byte 1 of the block at byte {offset}: the union index 2, outside its two branches")

    # --- its partition
    def at_field(schema, values, name):
        data_file = schema["fields"][2]["type"]["fields"]
        prefix = encode(schema["fields"][0]["type"], values["status"]) + encode(schema["fields"][1]["type"], values["sequence_number"])
        inner = b""
        for field in data_file:
            if field["name"] == name:
                break
            inner += encode(field["type"], values["data_file"].get(field["name"]))
        return len(prefix + inner)

    def partition_shape(name, spec, partition_type, partition, variant, text):
        schema = entry_schema(data_file_fields(partition_type=partition_type))
        values = entry(file_path=path, partition=partition)
        data = build([values], schema, spec=json.dumps(spec))
        at = block_offset(data)
        if "{n}" in text:
            text = text.replace("{n}", str(at_field(schema, values, "partition"))).replace("{at}", str(at))
        if "{path}" in text:
            text = text.replace("{path}", path)
        refuses(name, data, variant, text)

    spec_d = [{"source-id": 3, "field-id": 1000, "transform": "identity", "name": "d"}]
    partition_shape("manifest_partition_null", spec_d, ["null", partition_d], None, "ParseError", "byte {n} of the block at byte {at}: a file whose partition is null where the manifest's spec names 1 fields")
    two = {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", DATE], "field-id": 1000}, {"name": "extra", "type": ["null", "int"], "field-id": 1001}]}
    partition_shape("manifest_partition_count", spec_d, two, {"d": 1, "extra": 2}, "ParseError", "byte {n} of the block at byte {at}: a partition of 2 fields where the manifest's spec names 1")
    partition_shape("manifest_partition_no_fields", spec_d, empty_record(), {}, "ParseError", "byte {n} of the block at byte {at}: a partition of 0 fields where the manifest's spec names 1")
    partition_shape("manifest_partition_string", spec_d, "string", "x", "ParseError", "byte {n} of the block at byte {at}: a string where a partition is expected")
    partition_shape("manifest_partition_array", spec_d, {"type": "array", "items": "int"}, [1], "ParseError", "byte {n} of the block at byte {at}: an array where a partition is expected")
    as_string = {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", "string"], "field-id": 1000}]}
    partition_shape("manifest_partition_value_string", spec_d, as_string, {"d": "x"}, "ParseError", 'the partition field "d" holds a string, not the shape its transform and column give it')
    partition_shape("manifest_partition_value_double", spec_d, {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", "double"], "field-id": 1000}]}, {"d": 1.5}, "ParseError", 'the partition field "d" holds a float, not the shape its transform and column give it')
    partition_shape("manifest_partition_value_bool", spec_d, {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", "boolean"], "field-id": 1000}]}, {"d": True}, "ParseError", 'the partition field "d" holds a boolean, not the shape its transform and column give it')
    partition_shape("manifest_partition_value_record", spec_d, {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", {"type": "record", "name": "r9", "fields": [{"name": "z", "type": "int", "field-id": 9}]}], "field-id": 1000}]}, {"d": {"z": 1}}, "ParseError", "byte {n} of the block at byte {at}: a record where the partition field \"d\" holding a primitive is expected")
    partition_shape("manifest_partition_source_missing", [{"source-id": 99, "field-id": 1000, "transform": "identity", "name": "x"}], {"type": "record", "name": "r102", "fields": [{"name": "x", "type": ["null", "long"], "field-id": 1000}]}, {"x": 1}, "ParseError", 'the partition field "x": the manifest\'s schema holds no column with the id 99')
    partition_shape("manifest_partition_source_binary", [{"source-id": 4, "field-id": 1000, "transform": "identity", "name": "b"}], {"type": "record", "name": "r102", "fields": [{"name": "b", "type": ["null", "bytes"], "field-id": 1000}]}, {"b": b"\x01"}, "Unsupported", 'the partition field "b": the source column\'s type binary, which this reader does not carry')
    partition_shape("manifest_partition_truncate_binary", [{"source-id": 4, "field-id": 1000, "transform": "truncate[2]", "name": "b"}], {"type": "record", "name": "r102", "fields": [{"name": "b", "type": ["null", "bytes"], "field-id": 1000}]}, {"b": b"\x01"}, "Unsupported", 'the partition field "b": the source column\'s type binary, which this reader does not carry')
    spec_m = [{"source-id": 5, "field-id": 1000, "transform": "identity", "name": "m"}]
    scale3 = {"type": "fixed", "size": 5, "name": "decimal_10_3", "logicalType": "decimal", "precision": 10, "scale": 3}
    partition_shape("manifest_partition_decimal_scale", spec_m, {"type": "record", "name": "r102", "fields": [{"name": "m", "type": ["null", scale3], "field-id": 1000}]}, {"m": 12345}, "ParseError", 'the partition field "m" holds a decimal of scale 3, where the column\'s scale is 2')
    wide = {"type": "fixed", "size": 17, "name": "decimal_38", "logicalType": "decimal", "precision": 38, "scale": 2}
    partition_shape("manifest_partition_decimal_wide", spec_m, {"type": "record", "name": "r102", "fields": [{"name": "m", "type": ["null", wide], "field-id": 1000}]}, {"m": 1}, "Unsupported", 'the partition field "m": a decimal 17 bytes wide, past the 16 a 128-bit integer holds')
    sixteen = {"type": "fixed", "size": 16, "name": "decimal_38", "logicalType": "decimal", "precision": 38, "scale": 2}
    partition_shape("manifest_partition_decimal_digits", spec_m, {"type": "record", "name": "r102", "fields": [{"name": "m", "type": ["null", sixteen], "field-id": 1000}]}, {"m": 2**127 - 1}, "Unsupported", 'the partition field "m": a decimal with more than 34 significant digits')
    spec_void = [{"source-id": 4, "field-id": 1000, "transform": "void", "name": "b"}]
    partition_shape("manifest_partition_void_bytes", spec_void, {"type": "record", "name": "r102", "fields": [{"name": "b", "type": ["null", "bytes"], "field-id": 1000}]}, {"b": b"\x01\x02"}, "Unsupported", 'the partition field "b": bytes, which this reader does not carry as a value')
    spec_unknown = [{"source-id": 4, "field-id": 1000, "transform": "temporal[1, 2]", "name": "b"}]
    partition_shape("manifest_partition_unknown_fixed", spec_unknown, {"type": "record", "name": "r102", "fields": [{"name": "b", "type": ["null", {"type": "fixed", "name": "f", "size": 2}], "field-id": 1000}]}, {"b": b"\x01\x02"}, "Unsupported", 'the partition field "b": bytes, which this reader does not carry as a value')
    spec_i = [{"source-id": 1, "field-id": 1000, "transform": "identity", "name": "i"}]
    partition_shape("manifest_partition_field_array", spec_i, {"type": "record", "name": "r102", "fields": [{"name": "i", "type": {"type": "array", "items": "int"}, "field-id": 1000}]}, {"i": [1]}, "ParseError", 'byte {n} of the block at byte {at}: an array where the partition field "i" holding a primitive is expected')
    partition_shape("manifest_partition_long_for_string", [{"source-id": 2, "field-id": 1000, "transform": "identity", "name": "s"}], {"type": "record", "name": "r102", "fields": [{"name": "s", "type": ["null", "long"], "field-id": 1000}]}, {"s": 7}, "ParseError", 'the partition field "s" holds a whole number, not the shape its transform and column give it')
    partition_shape("manifest_partition_decimal_for_date", spec_d, {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", DECIMAL_FIXED_5_2], "field-id": 1000}]}, {"d": 19000}, "ParseError", 'the partition field "d" holds a decimal of scale 2, not the shape its transform and column give it')
    partition_shape("manifest_partition_source_decimal_wide", [{"source-id": 10, "field-id": 1000, "transform": "identity", "name": "big"}], {"type": "record", "name": "r102", "fields": [{"name": "big", "type": ["null", {"type": "fixed", "size": 16, "name": "decimal_38_2", "logicalType": "decimal", "precision": 38, "scale": 2}], "field-id": 1000}]}, {"big": 1}, "Unsupported", 'the partition field "big": the source column\'s decimal(38, 2) holds up to 38 digits, where a Decimal here holds 34')
    # what it must answer: no partition, where the spec names no field
    values = entry(file_path=path)
    values["data_file"]["partition"] = None
    reads("manifest_partition_null_no_spec", build([values], entry_schema(data_file_fields(partition_type=["null", empty_record()]))), [file_entry()])

    # A 32-bit float widened exactly: a negative, a zero, an infinity, a
    # quiet NaN and the least subnormal — the double's bits by the format's
    # own arithmetic, with a double's -0.0 and least subnormal beside them.
    def float32_double(bits: int) -> str:
        sign, exponent, fraction = (bits >> 31) & 1, (bits >> 23) & 0xFF, bits & 0x7FFFFF
        if exponent == 255:
            out = 0x7FF0000000000000 | fraction << 29
        elif exponent == 0:
            out = struct.unpack(">Q", struct.pack(">d", fraction * 2.0**-149))[0]
        else:
            out = struct.unpack(">Q", struct.pack(">d", struct.unpack("<f", struct.pack("<I", bits))[0]))[0]
        return "%016x" % (out | sign << 63)

    spec_fd = [{"source-id": 7, "field-id": 1000, "transform": "identity", "name": "f"}, {"source-id": 8, "field-id": 1001, "transform": "identity", "name": "dd"}]
    partition_fd = {"type": "record", "name": "r102", "fields": [{"name": "f", "type": ["null", "float"], "field-id": 1000}, {"name": "dd", "type": ["null", "double"], "field-id": 1001}]}
    floats = [(-1.5, 0xBFC00000, 2.5, 0x4004000000000000), (0.0, 0, ("bits", 0x8000000000000000), 0x8000000000000000), (("bits", 0x7F800000), 0x7F800000, None, None), (("bits", 0x7FC00000), 0x7FC00000, 1.5, 0x3FF8000000000000), (("bits", 1), 1, ("bits", 1), 1)]
    data = build([entry(file_path=path, partition={"f": f, "dd": d}) for f, _, d, _ in floats], entry_schema(data_file_fields(partition_type=partition_fd)), spec=json.dumps(spec_fd))
    reads("manifest_partition_float_values", data, [
        file_entry(partition=[["f", 7, "identity", {"kind": "float", "value": float32_double(fb)}], ["dd", 8, "identity", {"kind": "null"} if db is None else {"kind": "float", "value": "%016x" % db}]])
        for _, fb, _, db in floats
    ])
    spec_void2 = [{"source-id": 9, "field-id": 1000, "transform": "void", "name": "bb"}, {"source-id": 8, "field-id": 1001, "transform": "void", "name": "dd"}]
    partition_v = {"type": "record", "name": "r102", "fields": [{"name": "bb", "type": ["null", "boolean"], "field-id": 1000}, {"name": "dd", "type": ["null", "double"], "field-id": 1001}]}
    data = build([entry(file_path=path, partition={"bb": True, "dd": 2.5})], entry_schema(data_file_fields(partition_type=partition_v)), spec=json.dumps(spec_void2))
    reads("manifest_partition_void_bool_double", data, [file_entry(partition=[["bb", 9, "void", {"kind": "bool", "value": True}], ["dd", 8, "void", {"kind": "float", "value": "4004000000000000"}]])])
    # A decimal whose magnitude spans three groups of digits, one of them
    # padded: 123 × 10^9 + 12.
    spec_pad = [{"source-id": 11, "field-id": 1000, "transform": "identity", "name": "pad"}]
    fixed15 = {"type": "fixed", "size": 15, "name": "decimal_34_2", "logicalType": "decimal", "precision": 34, "scale": 2}
    partition_p = {"type": "record", "name": "r102", "fields": [{"name": "pad", "type": ["null", fixed15], "field-id": 1000}]}
    data = build([entry(file_path=path, partition={"pad": 123000000012}), entry(file_path=path, partition={"pad": -(10**14 + 7)}), entry(file_path=path, partition={"pad": None})], entry_schema(data_file_fields(partition_type=partition_p)), spec=json.dumps(spec_pad))
    reads("manifest_partition_decimal_padding", data, [
        file_entry(partition=[["pad", 11, "identity", {"kind": "decimal", "value": "1230000000.12"}]]),
        file_entry(partition=[["pad", 11, "identity", {"kind": "decimal", "value": "-1000000000000.07"}]]),
        file_entry(partition=[["pad", 11, "identity", {"kind": "null"}]]),
    ])
    # --- unknown fields of every remaining shape are stepped over
    schema_fixed = copy.deepcopy(entry_schema())
    schema_fixed["fields"] = schema_fixed["fields"][:2] + [{"name": "w", "type": {"type": "fixed", "name": "d4", "size": 4, "logicalType": "decimal", "precision": 9, "scale": 2}, "field-id": 900}] + schema_fixed["fields"][2:]
    data = build([dict(entry(file_path=path), w=1234)], schema_fixed)
    reads("manifest_skips_fixed_decimal", data, [file_entry()])

    # --- a known field of a type other than the one it is read as
    null_status = copy.deepcopy(entry_schema())
    null_status["fields"][0]["type"] = "null"
    data = build([dict(entry(file_path=path), status=None)], null_status)
    refuses("manifest_status_null_type", data, "ParseError", f"byte 0 of the block at byte {block_offset(data)}: a null where the status of a manifest entry is expected")
    names = {100: "file_path", 103: "record_count", 108: "column_sizes"}
    whats = {100: "the path of a file", 103: "the record count of a file", 108: "the column metrics of a file"}

    def wrong_type_shape(name, field_id, ty, value, spelled):
        schema = entry_schema(data_file_fields(replacements={field_id: {"name": names[field_id], "type": ty, "field-id": field_id}}))
        values = entry(file_path=path)
        values["data_file"][names[field_id]] = value
        data = build([values], schema)
        at = block_offset(data)
        refuses(name, data, "ParseError", f"byte {at_field(schema, values, names[field_id])} of the block at byte {at}: {spelled} where {whats[field_id]} is expected")

    wrong_type_shape("manifest_path_long", 100, "long", 7, "a long")
    wrong_type_shape("manifest_record_count_string", 103, "string", "x", "a string")
    wrong_type_shape("manifest_record_count_map", 103, {"type": "map", "values": ["null", "long"]}, [(1, 2)], "a map")
    wrong_type_shape("manifest_column_sizes_string", 108, "string", "x", "a string")
    nullable_map = ["null", {"type": "map", "values": ["null", "long"]}]
    reads("manifest_null_metrics", build([entry(file_path=path, column_sizes=None, equality_ids=None)], entry_schema(data_file_fields(replacements={108: {"name": "column_sizes", "type": nullable_map, "field-id": 108}, 135: {"name": "equality_ids", "type": ["null", {"type": "array", "element-id": 136, "items": "long"}], "field-id": 135}}))), [file_entry(field_ids=[])])
    names[135] = "equality_ids"
    whats[135] = "the equality ids of a file"
    wrong_type_shape("manifest_equality_ids_string", 135, "string", "x", "a string")
    wrong_type_shape("manifest_equality_ids_long", 135, "long", 7, "a long")
    # A required map left null would be a datum of another type; a nullable one is simply absent.
    reads("manifest_no_column_sizes", build([entry(file_path=path, column_sizes=None)]), [file_entry(field_ids=[])])
    nullable_ids = entry_schema(data_file_fields(replacements={135: {"name": "equality_ids", "type": {"type": "array", "element-id": 136, "items": ["null", "long"]}, "field-id": 135}}))
    data = build([entry(file_path=path, content=2, equality_ids=[1, None])], nullable_ids)
    reads("manifest_equality_null_element", data, [file_entry(kind=2, equality_ids=[1])])
    refuses("manifest_format_orc", build([entry(file_path=path, file_format="ORC")]), "Unsupported", f"the file {path}: the format ORC, where this reader reads parquet files only")
    refuses("manifest_format_seven_letters", build([entry(file_path=path, file_format="PARQUTX")]), "Unsupported", f"the file {path}: the format PARQUTX, where this reader reads parquet files only")
    reads("manifest_schema_no_partition_no_spec", build([entry(file_path=path)], entry_schema(data_file_fields(drop=(102,)))), [file_entry()])
    partition_shape("manifest_partition_bytes_for_date", spec_d, {"type": "record", "name": "r102", "fields": [{"name": "d", "type": ["null", "bytes"], "field-id": 1000}]}, {"d": b"\x01"}, "ParseError", 'the partition field "d" holds bytes, not the shape its transform and column give it')
    spec_void_s = [{"source-id": 2, "field-id": 1000, "transform": "void", "name": "s"}]
    partition_shape_void_string = {"type": "record", "name": "r102", "fields": [{"name": "s", "type": ["null", "string"], "field-id": 1000}]}
    data = build([entry(file_path=path, partition={"s": "x"})], entry_schema(data_file_fields(partition_type=partition_shape_void_string)), spec=json.dumps(spec_void_s))
    reads("manifest_partition_void_string", data, [file_entry(partition=[["s", 2, "void", {"kind": "string", "value": "x"}]])])
    boolean_status = copy.deepcopy(entry_schema())
    boolean_status["fields"][0]["type"] = "boolean"
    data = build([dict(entry(file_path=path), status=True)], boolean_status)
    refuses("manifest_status_boolean", data, "ParseError", f"byte 0 of the block at byte {block_offset(data)}: a boolean where the status of a manifest entry is expected")
    wrong_type_shape("manifest_record_count_float", 103, "float", 1.5, "a float")
    wrong_type_shape("manifest_record_count_double", 103, "double", 1.5, "a double")
    wrong_type_shape("manifest_record_count_bytes", 103, "bytes", b"", "bytes")
    wrong_type_shape("manifest_record_count_decimal", 103, DECIMAL_FIXED_5_2, 12345, "a decimal")
    wrong_type_shape("manifest_record_count_enum", 103, {"type": "enum", "name": "e", "symbols": ["a", "b"]}, 1, "an enum")
    wrong_type_shape("manifest_path_fixed", 100, {"type": "fixed", "name": "f3", "size": 3}, b"abc", "a fixed")
    spec_void_m = [{"source-id": 5, "field-id": 1000, "transform": "void", "name": "m"}]
    partition_void_m = {"type": "record", "name": "r102", "fields": [{"name": "m", "type": ["null", DECIMAL_FIXED_5_2], "field-id": 1000}]}
    data = build([entry(file_path=path, partition={"m": 12345})], entry_schema(data_file_fields(partition_type=partition_void_m)), spec=json.dumps(spec_void_m))
    reads("manifest_partition_void_decimal", data, [file_entry(partition=[["m", 5, "void", {"kind": "decimal", "value": "123.45"}]])])
    data = build([entry(file_path=path)], entry_schema(data_file_fields(drop=(102,))), spec=json.dumps(spec_d))
    refuses("manifest_schema_no_partition_field", data, "ParseError", "entry 0 of the manifest: the manifest's schema names no partition where its spec names 1 fields")
    nullable_data_file = copy.deepcopy(entry_schema())
    nullable_data_file["fields"][2]["type"] = ["null", nullable_data_file["fields"][2]["type"]]
    refuses("manifest_data_file_null", build([{"status": 1, "sequence_number": None, "data_file": None}], nullable_data_file), "ParseError", "entry 0 of the manifest names no path")
    no_spec_id = header()
    del no_spec_id["partition-spec-id"]
    data = build([entry(file_path=path)], metadata=no_spec_id)
    reads("manifest_header_no_spec_id", data, [file_entry(sequence_number=7)], with_list=named_list(data))
    # what it must answer: a zero decimal from no bytes, a decimal from a run of bytes, negatives
    spec_m = json.dumps(spec_m)
    bytes_decimal = {"type": "bytes", "logicalType": "decimal", "precision": 10, "scale": 2}
    schema = entry_schema(data_file_fields(partition_type={"type": "record", "name": "r102", "fields": [{"name": "m", "type": ["null", bytes_decimal], "field-id": 1000}]}))
    data = build([entry(file_path=path, partition={"m": b""}), entry(file_path=path, partition={"m": -1500}), entry(file_path=path, partition={"m": 1234567890123})], schema, spec=spec_m)
    reads("manifest_partition_decimal_bytes", data, [
        file_entry(partition=[["m", 5, "identity", {"kind": "decimal", "value": "0"}]]),
        file_entry(partition=[["m", 5, "identity", {"kind": "decimal", "value": "-15"}]]),
        file_entry(partition=[["m", 5, "identity", {"kind": "decimal", "value": "12345678901.23"}]]),
    ])
    schema = entry_schema(data_file_fields(partition_type={"type": "record", "name": "r102", "fields": [{"name": "m", "type": ["null", DECIMAL_FIXED_5_2], "field-id": 1000}]}))
    data = build([entry(file_path=path, partition={"m": -1}), entry(file_path=path, partition={"m": 0}), entry(file_path=path, partition={"m": -(2**39 - 1)})], schema, spec=spec_m)
    # No bytes spell a decimal of exponent zero; five zero bytes spell the
    # column's scale.
    reads("manifest_partition_decimal_fixed", data, [
        file_entry(partition=[["m", 5, "identity", {"kind": "decimal", "value": "-0.01"}]]),
        file_entry(partition=[["m", 5, "identity", {"kind": "decimal", "value": "0.00"}]]),
        file_entry(partition=[["m", 5, "identity", {"kind": "decimal", "value": "-5497558138.87"}]]),
    ])

    # --- its header
    def header_shape(name, metadata, variant, text, schema=None, entries=None, with_list=None):
        data = build(entries or [], schema, metadata=metadata)
        refuses(name, data, variant, text, with_list=with_list)

    no_schema = header()
    del no_schema["schema"]
    header_shape("manifest_no_schema", no_schema, "ParseError", 'the manifest: the header names no "schema"')
    # Versions 2 and 3 let a header leave the partition spec to the table's
    # own specs, named by the header's id; a reader given the manifest's
    # bytes alone refuses such a manifest by name. At version 1 the header
    # must carry the spec.
    no_spec = header()
    del no_spec["partition-spec"]
    header_shape("manifest_no_spec", no_spec, "Unsupported", "the manifest's header names no partition spec, which format versions 2 and 3 allow a reader to take from the table's own specs; given the manifest's bytes alone, this reader has none")
    header_shape("manifest_no_spec_v1", header(**{"format-version": "1", "partition-spec": None}), "ParseError", 'the manifest: the header names no "partition-spec"')
    header_shape("manifest_schema_not_json", header(schema="{"), "ParseError", "the manifest's schema is not JSON: Unexpected end of file")
    header_shape("manifest_schema_not_struct", header(schema="[]"), "ParseError", "the schema is not an object")
    header_shape("manifest_schema_type", header(schema='{"type":"int","fields":[]}'), "ParseError", "a schema whose type is int, not struct")
    header_shape("manifest_spec_not_json", header(**{"partition-spec": "["}), "ParseError", "the manifest's partition spec is not JSON: Unexpected end of file")
    header_shape("manifest_spec_not_array", header(**{"partition-spec": "{}"}), "ParseError", "a partition spec's fields is not an array")
    header_shape("manifest_spec_field_no_source", header(**{"partition-spec": '[{"name":"x","transform":"identity"}]'}), "ParseError", "a partition field names no source column")
    header_shape("manifest_format_four", header(**{"format-version": "4"}), "Unsupported", "the manifest's format version 4, where this reader reads 1 to 3")
    header_shape("manifest_format_text", header(**{"format-version": "two"}), "ParseError", 'the manifest\'s header names the format version "two", which spells no whole number')
    header_shape("manifest_content_other", header(content="other"), "ParseError", 'the manifest\'s header names the content "other", not data or deletes')
    header_shape("manifest_spec_id_text", header(**{"partition-spec-id": "x"}), "ParseError", 'the manifest\'s header names the partition spec id "x", which spells no whole number')
    data = build([entry(file_path=path)], metadata=header(content="deletes"))
    refuses("manifest_content_disagrees", data, "ParseError", "the manifest metadata/x.avro: its header names the content deletes, the list data", with_list=named_list(data, content=0))
    data = build([entry(file_path=path)], metadata=header(**{"partition-spec-id": "1"}))
    refuses("manifest_spec_disagrees", data, "ParseError", "the manifest metadata/x.avro: its header names the partition spec 1, the list 0", with_list=named_list(data, spec_id=0))
    data = build([entry(file_path=path)])
    refuses("manifest_length_mismatch", data, "ParseError", f"the manifest metadata/x.avro: the list names {len(data) + 1} bytes, the file holds {len(data)}", with_list=named_list(data, length=len(data) + 1))
    data = build([entry(file_path=path)], metadata=header(**{"format-version": "3"}))
    reads("manifest_format_three", data, [file_entry(sequence_number=7)], with_list=named_list(data))
    data = build([entry(file_path=path)], metadata=header(content=None, **{"format-version": None}))
    reads("manifest_v1_header", data, [file_entry(sequence_number=7)], with_list=named_list(data))
    data = build([entry(file_path=path)], metadata=header(content="deletes"))
    reads("manifest_deletes_agree", data, [file_entry(sequence_number=7)], with_list=named_list(data, content=1))

    # --- its schema
    header_shape("manifest_schema_top_not_record", header(), "ParseError", "the manifest: a top-level Avro schema that is an int, not a record", schema="int")
    header_shape("manifest_schema_no_avro", {}, "ParseError", 'the manifest: the header names no "avro.schema"', schema="__none__")
    no_status = copy.deepcopy(entry_schema())
    no_status["fields"] = no_status["fields"][1:]
    header_shape("manifest_schema_no_status", header(), "ParseError", "the manifest: a schema that names no field with the id 0", schema=no_status)
    no_data = copy.deepcopy(entry_schema())
    no_data["fields"] = no_data["fields"][:2]
    header_shape("manifest_schema_no_data_file", header(), "ParseError", "the manifest: a schema that names no field with the id 2", schema=no_data)
    data_string = copy.deepcopy(entry_schema())
    data_string["fields"][2]["type"] = "string"
    header_shape("manifest_schema_data_file_string", header(), "ParseError", "the manifest: a field with the id 2 that is a string, not a record", schema=data_string)
    no_path_field = copy.deepcopy(entry_schema())
    no_path_field["fields"][2]["type"]["fields"] = [f for f in no_path_field["fields"][2]["type"]["fields"] if f["field-id"] != 100]
    header_shape("manifest_schema_no_path_field", header(), "ParseError", "the manifest's data file: a schema that names no field with the id 100", schema=no_path_field)
    idless = copy.deepcopy(entry_schema())
    for field in idless["fields"]:
        field.pop("field-id")
    header_shape("manifest_schema_idless", header(), "ParseError", "the manifest: a schema that names no field with the id 0", schema=idless)

    # --- its bytes
    good = build([entry(file_path=path)])
    with_extra = build([entry(file_path=path)], suffix=b"\x00")
    refuses("manifest_bytes_past_record", with_extra, "ParseError", f"the block at byte {block_offset(with_extra)}: 1 bytes past the last record")
    refuses("manifest_bad_magic", b"\x00" + good[1:], "ParseError", "byte 0: a file that does not open with the Avro magic")
    refuses("manifest_too_short", good[:3], "ParseError", "a file of 3 bytes, too short for the magic")
    refuses("manifest_empty", b"", "ParseError", "a file of 0 bytes, too short for the magic")
    bzip2 = build([entry(file_path=path)], codec="bzip2")
    codec_at = Container(bzip2).value_at["avro.codec"]
    refuses("manifest_codec_bzip2", bzip2, "ParseError", f'byte {codec_at}: the header names the block codec "bzip2", which this reader does not inflate')
    deflate = build([entry(file_path=path)], codec="deflate")
    block = Container(deflate).blocks[0]
    corrupt = deflate[: block["payload_at"]] + b"\xff" * block["size"] + deflate[block["payload_at"] + block["size"]:]
    refuses("manifest_deflate_corrupt", corrupt, "ParseError", f"byte {block['count_at']}: a deflate block that does not decompress within 16777216 bytes")
    sync_at = Container(good).sync_at
    refuses("manifest_sync_truncated", good[: sync_at + 7], "ParseError", f"byte {sync_at} of the manifest as a file: a file that ends inside its sync marker")
    refuses("manifest_sync_mismatch", deflate[: block["marker_at"]] + bytes([deflate[block["marker_at"]] ^ 0x55]) + deflate[block["marker_at"] + 1:], "ParseError", f"byte {block['marker_at']}: a block whose sync marker differs from the file's")
    return shapes


# ------------------------------------------------------------------- all
def write_all(ref: str, location_of) -> list:
    """Write every patched file under `ref/patched` and answer the index
    entries the codec's tests read."""
    location = location_of("append_one")
    metadata_path = _newest(os.path.join(ref, "append_one"))
    base = json.load(open(metadata_path, encoding="utf-8"))
    out = os.path.join(ref, "patched")
    os.makedirs(out, exist_ok=True)
    index = []
    for name, data, expected in metadata_shapes(base, location):
        with open(os.path.join(out, f"{name}.metadata.json"), "wb") as handle:
            handle.write(data() if callable(data) else data)
        index.append({"shape": name, "file": f"patched/{name}.metadata.json", "kind": METADATA, "step": "metadata", **expected})
    real_list = os.path.join(ref, "append_one", base["snapshots"][0]["manifest-list"][len(location) + 1:].replace("\\", "/"))
    for name, data, expected in list_shapes(location, real_list):
        with open(os.path.join(out, f"{name}.avro"), "wb") as handle:
            handle.write(data)
        if expected is not None:
            index.append({"shape": name, "file": f"patched/{name}.avro", "kind": LIST, "step": "manifest_list", "location": location, **expected})
    for name, data, expected in manifest_shapes(location):
        with open(os.path.join(out, f"{name}.avro"), "wb") as handle:
            handle.write(data)
        if expected is not None:
            index.append(expected)
    return index


def _newest(table_dir: str) -> str:
    mdir = os.path.join(table_dir, "metadata")
    return os.path.join(mdir, max((n for n in os.listdir(mdir) if n.endswith(".metadata.json")), key=lambda n: int(n.split("-", 1)[0])))
