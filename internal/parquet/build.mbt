// The decoded cells' typed rebuild and the whole-file entry — the tail
// of the page walk: which series constructor each mapped dtype's cells
// land in, and the footer-plus-pages orchestration the io layer rides.

///|
/// Build the typed series from the decoded cells.
fn build_series(
  name : String,
  map : DtypeMap,
  values : Array[@types.Scalar?],
) -> @series.Series raise @types.DataError {
  match map.dtype {
    Int => {
      let cells : Array[Int64?] = []
      for v in values {
        match v {
          Some(Int(x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_int_options(name, cells)
    }
    Float => {
      let cells : Array[Double?] = []
      for v in values {
        match v {
          Some(Float(x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_float_options(name, cells)
    }
    Bool => {
      let cells : Array[Bool?] = []
      for v in values {
        match v {
          Some(Bool(x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_bool_options(name, cells)
    }
    String => {
      let cells : Array[String?] = []
      for v in values {
        match v {
          Some(String(x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_string_options(name, cells)
    }
    Date => {
      let cells : Array[Int64?] = []
      for v in values {
        match v {
          Some(Date(x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_date_options(name, cells)
    }
    Timestamp => {
      let cells : Array[Int64?] = []
      for v in values {
        match v {
          Some(Timestamp(x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_timestamp_options(name, cells)
    }
    Decimal(scale) => {
      let cells : Array[Int64?] = []
      for v in values {
        match v {
          Some(Decimal(_, x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_decimal_options(scale, name, cells)
    }
    // `Null` has no buffer to decode into and `Duration` never rides the
    // read mapping (a written Duration reads back through its bare INT64
    // as an `Int`); the map produces neither, and a future dtype landing
    // here fails this match at compile time instead.
    Duration | Null =>
      raise bad("a column's dtype map names no series constructor")
  }
}

///|
/// The whole-file entry the io layer rides: the footer parsed once, the
/// named columns decoded (every column when the projection is `None`),
/// and the file's declared row count — both answers off the same walk,
/// so a lenient projection that matches no column reports its `N×0`
/// height without a second footer parse. The projection is lenient like
/// the text readers': a name the file does not carry simply builds no
/// column, and whichever expression references it raises the same
/// `ColumnNotFound` it would against a full read.
pub fn read_parquet_frame(
  bytes : Bytes,
  projection : Array[String]?,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let footer = read_footer(bytes)
  let picked : Array[(String, @series.Series)] = []
  for column in footer.columns {
    let wanted = match projection {
      Some(names) => names.contains(column.chunk.name)
      None => true
    }
    if wanted {
      picked.push((column.chunk.name, decode_column(bytes, column)))
    }
  }
  (picked, footer_num_rows(footer))
}

///|
/// The footer's row count as a frame height — the height a lenient
/// projection that matches no column still reports (the text readers'
/// projections yield the same). A count outside the Int32 a frame's
/// height rides refuses rather than truncating.
fn footer_num_rows(footer : ParquetFooter) -> Int32 raise @types.DataError {
  let n = footer.num_rows
  if n < 0L || n > 2147483647L {
    raise @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "parquet: the file declares \{n} rows, past a frame's own height",
      ),
    )
  }
  n.to_int()
}
