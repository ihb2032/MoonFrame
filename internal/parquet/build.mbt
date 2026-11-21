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
    Decimal => {
      let cells : Array[@types.Dec128?] = []
      for v in values {
        match v {
          Some(Decimal(x)) => cells.push(Some(x))
          _ => cells.push(None)
        }
      }
      @series.Series::from_decimals(name, cells)
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
/// height without a second footer parse. A multi-group file concatenates
/// each column's cells across its groups — the first group's column
/// order is the file's, a later group lacking one of those names
/// refuses, and the per-chunk cell budget holds over the concatenation —
/// and builds one series per column over the joined cells. The
/// projection is lenient like the text readers': a name the file does
/// not carry simply builds no column, and whichever expression
/// references it raises the same `ColumnNotFound` it would against a
/// full read.
pub fn read_parquet_frame(
  bytes : Bytes,
  projection : Array[String]?,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  let footer = read_footer(bytes)
  let picked : Array[(String, @series.Series)] = []
  // The first group spells the file's column order; a file with no
  // groups carries no columns (and its row count has already agreed
  // with the empty sum), so the lenient `N×0` answer is every column it
  // has.
  match footer.groups.get(0) {
    None => ()
    Some(first) =>
      for column in first.columns {
        let wanted = match projection {
          Some(names) => names.contains(column.chunk.name)
          None => true
        }
        if wanted {
          // The column's chunks across the groups, located first: the
          // missing-name refusal and the joined-cell budget both land
          // before any group's pages decode, on the footer's own counts
          // alone.
          let chunks : Array[ColumnRead] = [column]
          for gi in 1..<footer.groups.length() {
            let group = footer.groups[gi]
            match group.find(column.chunk.name) {
              Some(later) => chunks.push(later)
              None =>
                raise bad(
                  "row group \{gi + 1} lacks the column \"\{column.chunk.name}\" the first group carries",
                )
            }
          }
          let mut joined = 0L
          for c in chunks {
            refuse_impossible_count(c.chunk, bytes.length().to_int64())
            joined = joined + c.chunk.num_values
          }
          if joined > PARQUET_CELL_BUDGET {
            raise @types.DataError::InvalidOperation(
              "column \"\{column.chunk.name}\" carries \{joined} cells across its row groups, past the \{PARQUET_CELL_BUDGET}-cell budget a single column read accepts",
            )
          }
          let cells : Array[@types.Scalar?] = []
          for c in chunks {
            for cell in decode_chunk_cells(bytes, c) {
              cells.push(cell)
            }
          }
          picked.push(
            (
              column.chunk.name,
              build_series(column.chunk.name, column.map, cells),
            ),
          )
        }
      }
  }
  (picked, footer_num_rows(footer))
}

///|
/// The batch face of a parquet file: the footer parsed once, every row
/// group decodable on demand — the reader the io layer's scan driver
/// rides, one group per batch. The projection is the same lenient one
/// the whole-file entry takes (`None` = every column; a name no group's
/// first spelling carried builds no column), and each group decodes its
/// own chunks, so a group outside a pushed row window is simply never
/// asked for.
pub struct ParquetGroupReader {
  priv bytes : Bytes
  priv footer : ParquetFooter
  priv projection : Array[String]?
}

///|
/// Open a file's group reader: the one footer parse every later call
/// rides. Raises the footer walk's own refusals here — a malformed file
/// refuses at open, not per group.
pub fn ParquetGroupReader::group_reader(
  bytes : Bytes,
  projection : Array[String]?,
) -> ParquetGroupReader raise @types.DataError {
  { bytes, footer: read_footer(bytes), projection, }
}

///|
/// The file's declared row count as a frame height — the same Int32
/// check the whole-file entry applies, the height a lenient projection
/// that matches no column still reports.
pub fn ParquetGroupReader::total_rows(
  self : ParquetGroupReader,
) -> Int32 raise @types.DataError {
  footer_num_rows(self.footer)
}

///|
/// How many row groups the file declares — the batch count a scan over
/// this file walks.
pub fn ParquetGroupReader::group_count(self : ParquetGroupReader) -> Int32 {
  self.footer.groups.length()
}

///|
/// One group's own row count as a batch height. A count outside the
/// Int32 a frame's height rides (or a negative one — a hostile file
/// whose per-group counts still sum to the file's total) refuses rather
/// than truncating.
pub fn ParquetGroupReader::group_rows(
  self : ParquetGroupReader,
  i : Int32,
) -> Int32 raise @types.DataError {
  if i < 0 || i >= self.footer.groups.length() {
    raise bad(
      "row group \{i + 1} is past the file's \{self.footer.groups.length()} groups",
    )
  }
  let n = self.footer.groups[i].num_rows
  if n < 0L || n > 2147483647L {
    raise bad(
      "row group \{i + 1} declares \{n} rows, past a frame's own height",
    )
  }
  n.to_int()
}

///|
/// Decode one group's projected columns as series, under the file's own
/// column order (the first group's spelling; a later group lacking one
/// of those names refuses, the same whole-file rule). The answer carries
/// the group's own row count, so a projection matching no column keeps
/// the group's `N×0` shape.
pub fn ParquetGroupReader::decode_group(
  self : ParquetGroupReader,
  i : Int32,
) -> (Array[(String, @series.Series)], Int32) raise @types.DataError {
  if i < 0 || i >= self.footer.groups.length() {
    raise bad(
      "row group \{i + 1} is past the file's \{self.footer.groups.length()} groups",
    )
  }
  let group = self.footer.groups[i]
  let picked : Array[(String, @series.Series)] = []
  // The first group spells the file's column order; this group answers
  // each of those names from its own chunks.
  match self.footer.groups.get(0) {
    None => ()
    Some(first) =>
      for column in first.columns {
        let wanted = match self.projection {
          Some(names) => names.contains(column.chunk.name)
          None => true
        }
        if wanted {
          match group.find(column.chunk.name) {
            Some(found) =>
              picked.push((column.chunk.name, decode_column(self.bytes, found)))
            None =>
              raise bad(
                "row group \{i + 1} lacks the column \"\{column.chunk.name}\" the first group carries",
              )
          }
        }
      }
  }
  (picked, self.group_rows(i))
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
