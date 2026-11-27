// Blackbox test tables: what the codec carries, written once here and
// read by the round-trip test (in code) and by the export test (into
// `_build/stata_written/`, for the reference readers — see
// `make_fixtures.py verify` beside the fixtures). A table is a list of
// columns, and a height for the table that has none.

///|
/// One table: its columns, and the height written when there is no
/// column to derive it from.
struct Table {
  name : String
  columns : Array[@series.Series]
  height : Int32
}

///|
/// A text 2200 bytes long, past the 2045 a fixed-width string holds.
fn long_text() -> String {
  String::make(2200, 'x')
}

///|
/// The tables the codec carries. `all_types` holds every dtype beside a
/// missing cell; `extremes` the extreme values of each numeric type;
/// `strl_keys` long strings that repeat, share a record, or are empty;
/// `names` names at the format's limits; and the last three have no row,
/// no column, or neither.
fn tables() -> Array[Table] raise @types.DataError {
  let n = 7
  let vacant = @series.Series::from_i64_options(
    "vacant",
    @types.DataType::Null,
    [None, None, None, None, None, None, None],
  )
  let limit = 1.7976931348623157e308 / 2.0
  let far = 4503599627370496000L
  [
    Table::{
      name: "all_types",
      height: n,
      columns: [
        @series.Series::from_scalars(
          "flag",
          [
            @types.Scalar::Bool(true),
            @types.Scalar::Bool(false),
            @types.Scalar::Null,
            @types.Scalar::Bool(true),
            @types.Scalar::Null,
            @types.Scalar::Bool(false),
            @types.Scalar::Bool(true),
          ],
          dtype=@types.DataType::Bool,
        ),
        @series.Series::from_scalars(
          "num",
          [
            @types.Scalar::Int(1L),
            @types.Scalar::Int(-2L),
            @types.Scalar::Null,
            @types.Scalar::Int(2147483620L),
            @types.Scalar::Int(-2147483647L),
            @types.Scalar::Int(0L),
            @types.Scalar::Int(7L),
          ],
          dtype=@types.DataType::Int,
        ),
        @series.Series::from_scalars(
          "wide",
          [
            @types.Scalar::Null,
            @types.Scalar::Int(1099511627776L),
            @types.Scalar::Int(-9007199254740992L),
            @types.Scalar::Int(9007199254740992L),
            @types.Scalar::Int(4611686018427387904L),
            @types.Scalar::Int(-9223372036854775808L),
            @types.Scalar::Int(2147483621L),
          ],
          dtype=@types.DataType::Int,
        ),
        @series.Series::from_scalars(
          "ratio",
          [
            @types.Scalar::Float(1.5),
            @types.Scalar::Float(-0.25),
            @types.Scalar::Null,
            // A NaN: the format has none, so it writes as the code for `.`.
            @types.Scalar::Float(0.0 / 0.0),
            @types.Scalar::Float(1.0e300),
            @types.Scalar::Float(5.0e-324),
            @types.Scalar::Float(-0.0),
          ],
          dtype=@types.DataType::Float,
        ),
        @series.Series::from_scalars(
          "label",
          [
            @types.Scalar::String("héllo"),
            @types.Scalar::String(""),
            @types.Scalar::Null,
            @types.Scalar::String("日本語 😀"),
            @types.Scalar::String("x"),
            @types.Scalar::String(""),
            @types.Scalar::String("plain"),
          ],
          dtype=@types.DataType::String,
        ),
        @series.Series::from_scalars(
          "notes",
          [
            @types.Scalar::String(""),
            @types.Scalar::String("repeat"),
            @types.Scalar::String(long_text()),
            @types.Scalar::String("repeat"),
            @types.Scalar::Null,
            @types.Scalar::String(long_text()),
            @types.Scalar::String("日本語"),
          ],
          dtype=@types.DataType::String,
        ),
        @series.Series::from_scalars(
          "day",
          [
            @types.Scalar::Date(0L),
            @types.Scalar::Date(-1L),
            @types.Scalar::Null,
            @types.Scalar::Date(20000L),
            @types.Scalar::Date(-719528L),
            @types.Scalar::Date(2932896L),
            @types.Scalar::Date(365L),
          ],
          dtype=@types.DataType::Date,
        ),
        @series.Series::from_scalars(
          "stamp",
          [
            @types.Scalar::Timestamp(0L),
            @types.Scalar::Timestamp(-1000000L),
            @types.Scalar::Null,
            @types.Scalar::Timestamp(1700000000123000L),
            @types.Scalar::Timestamp(253402300799999000L),
            @types.Scalar::Timestamp(-62135596800000000L),
            @types.Scalar::Timestamp(86400000000L),
          ],
          dtype=@types.DataType::Timestamp,
        ),
        vacant,
      ],
    },
    Table::{
      name: "extremes",
      height: n,
      columns: [
        @series.Series::from_ints("i_long", [
          -2147483647L, 2147483620L, 0L, -1L, 1L, 2147483619L, -2147483646L,
        ]),
        @series.Series::from_ints("i_wide", [
          -9223372036854775808L, -4611686018427387904L, 3458764513820540928L, 9007199254740992L,
          -9007199254740992L, 2147483648L, 4294967296L,
        ]),
        @series.Series::from_floats("f_small", [
          5.0e-324, -5.0e-324, 2.2250738585072014e-308, -2.2250738585072014e-308,
          1.0, 0.0, -0.0,
        ]),
        @series.Series::from_floats("f_big", [
          limit,
          -limit,
          1.0e300,
          -1.0e300,
          1.0,
          limit / 2.0,
          2.0,
        ]),
        @series.Series::from_floats("f_bits", [
          0.1,
          -0.1,
          1.0 / 3.0,
          3.141592653589793,
          2.718281828459045,
          -1.0e-10,
          123456789.123456789,
        ]),
        @series.Series::from_scalars(
          "d_edge",
          [
            @types.Scalar::Date(-2147487300L),
            @types.Scalar::Date(2147479967L),
            @types.Scalar::Date(0L),
            @types.Scalar::Date(-719528L),
            @types.Scalar::Date(2932896L),
            @types.Scalar::Date(365L),
            @types.Scalar::Date(-365L),
          ],
          dtype=@types.DataType::Date,
        ),
        @series.Series::from_scalars(
          "t_far",
          [
            @types.Scalar::Timestamp(0L),
            @types.Scalar::Timestamp(-1000000L),
            @types.Scalar::Timestamp(far),
            @types.Scalar::Timestamp(-far),
            @types.Scalar::Timestamp(253402300799999000L),
            @types.Scalar::Timestamp(-62135596800000000L),
            @types.Scalar::Timestamp(86400000000L),
          ],
          dtype=@types.DataType::Timestamp,
        ),
      ],
    },
    Table::{
      name: "strl_keys",
      height: 9,
      columns: [
        @series.Series::from_scalars(
          "notes",
          [
            @types.Scalar::String(""),
            @types.Scalar::String("a"),
            @types.Scalar::String("a"),
            @types.Scalar::String(""),
            @types.Scalar::Null,
            @types.Scalar::String(long_text()),
            @types.Scalar::String("a"),
            @types.Scalar::String(long_text()),
            @types.Scalar::String(""),
          ],
          dtype=@types.DataType::String,
        ),
        @series.Series::from_scalars(
          "brief",
          [
            @types.Scalar::String("x"),
            @types.Scalar::String(""),
            @types.Scalar::Null,
            @types.Scalar::String("y"),
            @types.Scalar::String("x"),
            @types.Scalar::String(""),
            @types.Scalar::String(""),
            @types.Scalar::Null,
            @types.Scalar::String("z"),
          ],
          dtype=@types.DataType::String,
        ),
      ],
    },
    Table::{
      name: "names",
      height: 2,
      columns: [
        @series.Series::from_ints("abcdefghijklmnopqrstuvwxyz123456", [1L, 2L]),
        @series.Series::from_ints("_x1", [3L, 4L]),
        @series.Series::from_floats("A9", [1.5, 2.5]),
        @series.Series::from_strings("z_9", ["a", "b"]),
      ],
    },
    Table::{
      name: "no_rows",
      height: 0,
      columns: [
        @series.Series::from_bools("flag", []),
        @series.Series::from_ints("num", []),
        @series.Series::from_floats("ratio", []),
        @series.Series::from_strings("label", []),
        @series.Series::from_scalars("day", [], dtype=@types.DataType::Date),
        @series.Series::from_scalars(
          "stamp",
          [],
          dtype=@types.DataType::Timestamp,
        ),
      ],
    },
    Table::{ name: "height_only", height: 3, columns: [], },
    Table::{ name: "empty", height: 0, columns: [], },
  ]
}

///|
/// A table written by the codec.
fn write_table(table : Table) -> Bytes raise @types.DataError {
  write_stata_bytes(table.columns, height=table.height)
}

///|
/// Whether an `Int` column's every cell lies inside the `long` storage's
/// valid range, which is what writes it as `long`; one cell outside puts
/// the whole column under `double`. A column of another dtype is narrow
/// by default.
fn writes_narrow(column : @series.Series) -> Bool {
  let mut narrow = true
  if column.dtype() is @types.DataType::Int {
    for cell in column.to_scalars() {
      if cell is @types.Scalar::Int(v) {
        if v < -2147483647L || v > 2147483620L {
          narrow = false
        }
      }
    }
  }
  narrow
}

///|
/// What a cell comes back as from a file: the format has no boolean
/// storage, so a `Bool` cell reads as `Int` 1 or 0; no missing string, so
/// a missing `String` cell reads as the empty string; a NaN `Float` cell
/// reads as missing, the code for `.` it was written as; and an `Int`
/// cell too wide for `long` reads as the `Float` it was written as.
/// Every other cell reads as itself.
fn as_read(column : @series.Series, value : @types.Scalar) -> @types.Scalar {
  let dtype = column.dtype()
  if value is Null {
    if dtype is @types.DataType::String {
      @types.Scalar::String("")
    } else {
      @types.Scalar::Null
    }
  } else if dtype is @types.DataType::Bool {
    if value is Bool(true) {
      @types.Scalar::Int(1L)
    } else {
      @types.Scalar::Int(0L)
    }
  } else if value is Float(v) && v.is_nan() {
    @types.Scalar::Null
  } else if dtype is @types.DataType::Int && !writes_narrow(column) {
    if value is Int(v) {
      @types.Scalar::Float(v.to_double())
    } else {
      value
    }
  } else {
    value
  }
}

///|
/// The dtype a column comes back as from a file: `Bool` reads as `Int`,
/// the all-missing `Null` and a too-wide `Int` as `Float`, and every
/// other dtype as itself.
fn dtype_as_read(column : @series.Series) -> @types.DataType {
  let dtype = column.dtype()
  if dtype is @types.DataType::Bool {
    @types.DataType::Int
  } else if dtype is @types.DataType::Null {
    @types.DataType::Float
  } else if dtype is @types.DataType::Int && !writes_narrow(column) {
    @types.DataType::Float
  } else {
    dtype
  }
}
