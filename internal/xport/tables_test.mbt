// Blackbox tables: the tables the export test writes out for the
// reference readers, and the columns the round-trip test reads back.

///|
/// One table the codec carries, with what a reference reader can do with
/// its file.
struct Table {
  name : String
  height : Int32
  // pandas' reader raises on a file of no observation; pyreadstat's opens
  // one that has variables and refuses one that has none.
  pandas_opens : Bool
  pyreadstat_opens : Bool
  columns : Array[@series.Series]
}

///|
/// `text` repeated `count` times.
fn repeated(text : String, count : Int32) -> String {
  let out = StringBuilder()
  for _ in 0..<count {
    out.write_string(text)
  }
  out.to_string()
}

///|
/// Every dtype the codec carries, a missing cell of each, and a
/// non-ASCII string: three observations.
fn all_types() -> Array[@series.Series] raise @types.DataError {
  [
    @series.Series::from_scalars(
      "flag",
      [
        @types.Scalar::Bool(true),
        @types.Scalar::Null,
        @types.Scalar::Bool(false),
      ],
      dtype=@types.DataType::Bool,
    ),
    @series.Series::from_ints("num", [1L, -2L, 9007199254740992L]),
    @series.Series::from_float_options("ratio", [Some(1.5), None, Some(-0.25)]),
    @series.Series::from_string_options("label", [
      Some("a"),
      None,
      Some("héllo wörld"),
    ]),
    @series.Series::from_date_options("day", [Some(0L), None, Some(19782L)]),
    @series.Series::from_timestamp_options("stamp", [
      Some(0L),
      Some(-315619200000000L),
      Some(1709201696781250L),
    ]),
    @series.Series::from_i64_options("nothing", @types.DataType::Null, [
      None,
      None,
      None,
    ]),
  ]
}

///|
/// The extreme values of each numeric type, and text at the format's
/// limit: five observations.
fn extremes() -> Array[@series.Series] raise @types.DataError {
  [
    @series.Series::from_ints("num", [
      0L, 9007199254740992L, -9007199254740992L, 1L, -1L,
    ]),
    @series.Series::from_floats("ratio", [
      5.397605346934028e-79, -5.397605346934028e-79, 0.1, 1.0e75, -0.0,
    ]),
    @series.Series::from_string_options("text", [
      Some(repeated("é", 100)),
      Some(repeated("日", 66)),
      Some(""),
      None,
      Some("z"),
    ]),
    @series.Series::from_date_options("day", [
      Some(-719162L),
      Some(2932896L),
      Some(0L),
      Some(1L),
      Some(-1L),
    ]),
    @series.Series::from_timestamp_options("stamp", [
      Some(-62135596800000000L),
      Some(253370764800000000L),
      Some(1709201696781250L),
      Some(0L),
      Some(-315619200000000L),
    ]),
  ]
}

///|
/// Names at the format's limits, as spelled: two observations.
fn named() -> Array[@series.Series] {
  let names = [
    "abcdefgh", "_x", "a_1", "Mixed", "UPPER9ch", "x1234567", "_1234567", "Z9",
  ]
  names.map(name => @series.Series::from_ints(name, [1L, 2L]))
}

///|
/// The tables the codec carries. `all_types` holds every dtype beside a
/// missing cell; `extremes` the extreme values of each numeric type and
/// text at the format's limit; `names` names at the format's limits; and
/// the last two have no row, or no row and no column.
fn tables() -> Array[Table] raise @types.DataError {
  [
    Table::{
      name: "all_types",
      height: 3,
      pandas_opens: true,
      pyreadstat_opens: true,
      columns: all_types(),
    },
    Table::{
      name: "extremes",
      height: 5,
      pandas_opens: true,
      pyreadstat_opens: true,
      columns: extremes(),
    },
    Table::{
      name: "names",
      height: 2,
      pandas_opens: true,
      pyreadstat_opens: true,
      columns: named(),
    },
    Table::{
      name: "no_rows",
      height: 0,
      pandas_opens: false,
      pyreadstat_opens: true,
      columns: [
        @series.Series::from_bool_options("flag", []),
        @series.Series::from_ints("num", []),
        @series.Series::from_floats("ratio", []),
        @series.Series::from_strings("label", []),
        @series.Series::from_date_options("day", []),
        @series.Series::from_timestamp_options("stamp", []),
      ],
    },
    Table::{
      name: "empty",
      height: 0,
      pandas_opens: false,
      pyreadstat_opens: false,
      columns: [],
    },
  ]
}

///|
/// A table as the codec writes it.
fn write_table(table : Table) -> Bytes raise @types.DataError {
  write_xport_bytes(table.columns, height=table.height)
}
