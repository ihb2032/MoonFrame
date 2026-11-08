// The dtype mapping between MoonFrame and parquet — which physical type
// and converted type each MoonFrame dtype rides, one row per dtype,
// read by both directions. The riders carry their parquet logical
// spellings (`DATE`, `TIMESTAMP_MICROS`, `DECIMAL`), so a MoonFrame
// write is a lossless parquet citizen and a foreign file's dates read
// back as dates.

///|
/// The parquet physical types MoonFrame reads and writes — the ones its
/// dtypes map onto. `FLOAT` is deliberately absent: a 4-byte float would
/// silently lose the `Double` precision every MoonFrame `Float` carries,
/// so a foreign `FLOAT` column refuses on read rather than narrowing.
priv enum Physical {
  Boolean
  Int32P
  Int64P
  DoubleP
  ByteArrayP
  FlbaP
}

///|
/// The parquet converted-type annotations (the enum parquet-mr itself
/// spells) MoonFrame reads and writes.
priv enum Converted {
  Utf8C
  DateC
  TimestampMicrosC
  DecimalC
}

///|
/// One mapped column: the MoonFrame dtype, its physical type, and the
/// converted annotation the riders carry (`None` for `Int` / `Float` /
/// `Bool`, whose physical types say everything). The decimal scale rides
/// the row itself (`-1` outside the decimal dtype) — the schema writer
/// reads it straight off instead of re-deriving it from the dtype a
/// second time.
priv struct DtypeMap {
  dtype : @types.DataType
  mut physical : Physical
  converted : Converted?
  // The DECIMAL annotation's scale. Read side: lifted straight off the
  // footer. Write side: the writer's adaptive pass overwrites the 0 the
  // table seeds — the one scale every cell of the column honours.
  mut decimal_scale : Int32
  // The DECIMAL annotation's precision. Write side: the writer's
  // adaptive pass sets 18 over INT64 or 38 over FIXED_LEN_BYTE_ARRAY —
  // the two payloads' own ceilings. Read side: lifted off the footer.
  mut decimal_precision : Int32
  // The FIXED_LEN_BYTE_ARRAY payload's byte width (the schema element's
  // type_length). Write side: always 16 for a decimal column. Read
  // side: lifted off the footer and gated to the 4 / 8 / 16 spellings
  // foreign writers emit; -1 elsewhere.
  mut flba_width : Int32
}

///|
/// The mapping table, one row per writable dtype. `String` rides
/// `BYTE_ARRAY` + `UTF8`; `Date` `INT32` + `DATE`; `Timestamp` `INT64` +
/// `TIMESTAMP_MICROS`; `Decimal` `INT64` + `DECIMAL` — each cell lifted
/// to the column's one adaptive scale exactly (the writer computes it
/// from the cells and names it in the annotation; a NaN / ±∞ cell or a
/// value the 18-digit INT64 interchange cannot hold refuses the write);
/// `Duration` rides bare `INT64` (no standard converted type names a
/// microsecond span; the round trip keeps the raw count).
fn dtype_map(dtype : @types.DataType) -> DtypeMap? {
  match dtype {
    Int =>
      Some(DtypeMap::{
        dtype,
        physical: Int64P,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    Float =>
      Some(DtypeMap::{
        dtype,
        physical: DoubleP,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    Bool =>
      Some(DtypeMap::{
        dtype,
        physical: Boolean,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    String =>
      Some(DtypeMap::{
        dtype,
        physical: ByteArrayP,
        converted: Some(Utf8C),
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    Date =>
      Some(DtypeMap::{
        dtype,
        physical: Int32P,
        converted: Some(DateC),
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    Timestamp =>
      Some(DtypeMap::{
        dtype,
        physical: Int64P,
        converted: Some(TimestampMicrosC),
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    Decimal =>
      Some(DtypeMap::{
        dtype,
        physical: Int64P,
        converted: Some(DecimalC),
        decimal_scale: 0,
        // The seeds the writer's adaptive pass overwrites — INT64(18)
        // when every lifted cell fits, FIXED_LEN_BYTE_ARRAY(38) when
        // only the 16-byte payload holds them.
        decimal_precision: 18,
        flba_width: -1,
      })
    Duration =>
      Some(DtypeMap::{
        dtype,
        physical: Int64P,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    Null => None
  }
}

///|
/// The physical-type enum value the thrift schema carries.
fn physical_tag(p : Physical) -> Int32 {
  match p {
    Boolean => 0
    Int32P => 1
    Int64P => 2
    DoubleP => 5
    ByteArrayP => 6
    FlbaP => 7
  }
}

///|
/// The converted-type enum value the thrift schema carries.
fn converted_tag(c : Converted) -> Int32 {
  match c {
    Utf8C => 0
    DateC => 6
    TimestampMicrosC => 10
    DecimalC => 5
  }
}

///|
/// The converted annotation a thrift schema row's value names, when it is
/// one MoonFrame carries — the reading twin of `converted_tag`, so the
/// tag values have one home the way `physical_tag` / `physical_from_tag`
/// already do.
fn converted_from_tag(tag : Int32) -> Converted? {
  match tag {
    0 => Some(Utf8C)
    6 => Some(DateC)
    10 => Some(TimestampMicrosC)
    5 => Some(DecimalC)
    _ => None
  }
}

///|
/// The `INT32` physical value from a thrift schema row, when it is one.
fn physical_from_tag(tag : Int32) -> Physical? {
  match tag {
    0 => Some(Boolean)
    1 => Some(Int32P)
    2 => Some(Int64P)
    5 => Some(DoubleP)
    6 => Some(ByteArrayP)
    7 => Some(FlbaP)
    _ => None
  }
}

///|
/// The mapping a thrift schema row names, when MoonFrame carries it. A
/// bare `INT32` reads as `Int` (signed — the UINT annotations refuse
/// instead of re-reading the bits unsigned); a bare `INT64` the same.
/// A `FLOAT` (4), `INT96` (3), or `FIXED_LEN_BYTE_ARRAY` (7) physical
/// type refuses — the first would narrow, the latter two carry dtypes
/// (`TIMESTAMP` pre-converted, `DECIMAL` over bytes) MoonFrame does not
/// spell. A `BYTE_ARRAY` without `UTF8` also refuses (a raw binary
/// column is not a `String`). A `DECIMAL` annotation carries the
/// format's own envelope: the precision required, one to eighteen
/// digits over the `INT64` payload, the scale never past it.
fn map_from_schema(
  physical_tag_value : Int32,
  converted_value : Int32?,
  decimal_scale : Int32?,
  decimal_precision : Int32?,
  type_length : Int32?,
) -> DtypeMap? {
  let physical = match physical_from_tag(physical_tag_value) {
    Some(p) => p
    None => return None
  }
  // An annotation the reader does not spell refuses the column outright —
  // it must not fall back to the bare mapping, which would silently
  // misread the annotated column as its physical dtype.
  let converted = match converted_value {
    None => None
    Some(tag) =>
      match converted_from_tag(tag) {
        Some(c) => Some(c)
        None => return None
      }
  }
  match (physical, converted) {
    (Int32P, None) =>
      Some({
        dtype: Int,
        physical: Int32P,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    (Int64P, None) =>
      Some({
        dtype: Int,
        physical: Int64P,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    (DoubleP, None) =>
      Some({
        dtype: Float,
        physical: DoubleP,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    (Boolean, None) =>
      Some({
        dtype: Bool,
        physical: Boolean,
        converted: None,
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    (ByteArrayP, Some(Utf8C)) =>
      Some({
        dtype: String,
        physical: ByteArrayP,
        converted: Some(Utf8C),
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    (Int32P, Some(DateC)) =>
      Some({
        dtype: Date,
        physical: Int32P,
        converted: Some(DateC),
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    (Int64P, Some(TimestampMicrosC)) =>
      Some({
        dtype: Timestamp,
        physical: Int64P,
        converted: Some(TimestampMicrosC),
        decimal_scale: -1,
        decimal_precision: -1,
        flba_width: -1,
      })
    (Int64P, Some(DecimalC)) =>
      // A DECIMAL over INT64: the scale names the dtype, and the
      // annotation's own envelope bounds both — the format's decimal
      // rules make the precision required and, over an INT64 payload,
      // one to eighteen digits (the type's own ceiling: an Int64 spells
      // no more), with the scale never past the precision it names
      // fraction digits inside. A file declaring past that envelope is
      // not a decimal the INT64 payload can honour, so it refuses
      // naming the column rather than misreading the cells.
      match (decimal_scale, decimal_precision) {
        (Some(scale), Some(p)) =>
          if scale >= 0 && scale <= p && p >= 1 && p <= 18 {
            Some({
              dtype: Decimal,
              physical: Int64P,
              converted: Some(DecimalC),
              decimal_scale: scale,
              decimal_precision: p,
              flba_width: -1,
            })
          } else {
            None
          }
        _ => None
      }
    (FlbaP, Some(DecimalC)) =>
      // A DECIMAL over FIXED_LEN_BYTE_ARRAY — the wide payload foreign
      // writers spell when the unscaled magnitudes leave INT64. The
      // bytes are big-endian two's complement at the element's own
      // type_length; the interchange's decimal ceiling is precision 38,
      // the scale never past the precision, and the payload's own digit
      // ceiling bounds the precision a width can honour (9 over 4
      // bytes, 18 over 8, 38 over 16 — the widths the foreign writers
      // emit). A FLBA column without the DECIMAL annotation carries no
      // dtype MoonFrame spells and refuses as before.
      match (decimal_scale, decimal_precision, type_length) {
        (Some(scale), Some(p), Some(width)) => {
          let width_ceiling = match width {
            4 => 9
            8 => 18
            16 => 38
            _ => -1
          }
          if width_ceiling >= 0 &&
            scale >= 0 &&
            scale <= p &&
            p >= 1 &&
            p <= 38 &&
            p <= width_ceiling {
            Some({
              dtype: Decimal,
              physical: FlbaP,
              converted: Some(DecimalC),
              decimal_scale: scale,
              decimal_precision: p,
              flba_width: width,
            })
          } else {
            None
          }
        }
        _ => None
      }
    _ => None
  }
}
