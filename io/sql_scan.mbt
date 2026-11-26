// The lazy SQL source: the query answered through the driver's cursor and
// read batch by batch, the one source that can stop reading at a sunk
// window's end without having read the answer whole. Each batch is typed
// the way `read_sql` types a column, and the first batch's dtypes are the
// schema every later batch holds to: a stream cannot widen a column it
// has already answered, so a later cell of another shape refuses.

///|
/// The rows one batch of a SQL scan carries.
const SQL_SCAN_ROWS : Int32 = 4096

///|
/// The row position an unbounded window ends at: past any answer.
const SQL_UNBOUNDED : Int32 = 2147483647

///|
/// A SQL scan's place in one opened cursor: the rows pulled so far, the
/// row range the window keeps, the first row — which named the columns
/// and types them when the window keeps none — and, once the first batch
/// is built, each column's settled dtype.
priv struct SqlStream {
  cursor : &@moondb.Cursor
  skip : Int32
  limit : Int32
  mut before : Int32
  mut ended : Bool
  mut emitted : Bool
  mut first : @moondb.Row?
  mut pinned : Array[@types.DataType?]
}

///|
/// How a window is read: by a row range known before the first row, or
/// against the answer's row count once the answer is read whole.
priv enum SqlWindow {
  Range(Int32, Int32)
  Counted(@scan.ScanWindow)
}

///|
/// The way a window is read. No window, a `head`, and a `slice` by
/// forward bounds keep a row range known up front; a `tail`, a `head` by
/// a negative bound, and a `slice` from the answer's end are counted
/// against the answer's row count.
fn sql_window(window : @scan.ScanWindow?) -> SqlWindow {
  match window {
    None => Range(0, SQL_UNBOUNDED)
    Some(@scan.ScanWindow::Head(n)) =>
      if n >= 0 {
        Range(0, n)
      } else {
        Counted(@scan.ScanWindow::Head(n))
      }
    Some(@scan.ScanWindow::Slice(offset, length)) =>
      if offset < 0 {
        Counted(@scan.ScanWindow::Slice(offset, length))
      } else {
        match length {
          None => Range(offset, SQL_UNBOUNDED)
          Some(len) =>
            if len < 0 {
              Counted(@scan.ScanWindow::Slice(offset, length))
            } else {
              // The end saturates: a length past the answer's end is the
              // answer's end.
              let end = if len > SQL_UNBOUNDED - offset {
                SQL_UNBOUNDED
              } else {
                offset + len
              }
              Range(offset, end)
            }
        }
      }
    Some(@scan.ScanWindow::Tail(n)) => Counted(@scan.ScanWindow::Tail(n))
  }
}

///|
/// Open one read: the stream over the query's answer. A window known up
/// front streams; any other reads the answer whole to learn its row
/// count, resolves against it, and streams the rows it keeps.
fn sql_open(
  driver : &@moondb.Driver,
  sql : String,
  params : Array[@moondb.Value],
  window : @scan.ScanWindow?,
) -> SqlStream raise @types.DataError {
  let cursor = driver.query_stream(sql, params.copy()) catch {
    e => raise sql_io_error(e)
  }
  let (source, skip, limit, first) = match sql_window(window) {
    Range(skip, limit) => (cursor, skip, limit, None)
    Counted(counted) => {
      // The cursor is closed whether the answer was read or the read
      // failed partway.
      let answer : Result[Array[@moondb.Row], @moondb.DbError] = Ok(
        @moondb.drain(cursor),
      ) catch {
        e => Err(e)
      }
      cursor.close()
      let whole = match answer {
        Ok(rows) => rows
        Err(e) => raise sql_io_error(e)
      }
      let (start, length) = counted.resolve(whole.length())
      let kept = whole[start:start + length].to_owned()
      let kept_cursor : &@moondb.Cursor = @moondb.ArrayCursor::new(kept)
      // The answer's first row is kept whether or not the window keeps
      // it: an answer with rows whose window keeps none still answers
      // its columns, typed by that row.
      let head : @moondb.Row? = if whole.is_empty() {
        None
      } else {
        Some(whole[0])
      }
      (kept_cursor, 0, length, head)
    }
  }
  {
    cursor: source,
    skip,
    limit,
    before: 0,
    ended: false,
    emitted: false,
    first,
    pinned: [],
  }
}

///|
/// Pull the next batch's rows: up to `SQL_SCAN_ROWS` inside the window,
/// the read stopping at the window's end and the cursor closing there.
/// The first row names the columns, and every row is held to that width.
fn SqlStream::pull(
  self : SqlStream,
) -> Array[@moondb.Row] raise @types.DataError {
  let rows : Array[@moondb.Row] = []
  while !self.ended && rows.length() < SQL_SCAN_ROWS {
    let next = self.cursor.next() catch { e => raise sql_io_error(e) }
    match next {
      None => {
        self.ended = true
        self.cursor.close()
      }
      Some(row) => {
        match self.first {
          // The first row names the columns; every later one is held to
          // that width.
          None => self.first = Some(row)
          Some(head) =>
            if row.columns.length() != head.columns.length() {
              raise @types.DataError::ParseError(
                @types.ParseErrorDetail::Message(
                  "sql: a row carries \{row.columns.length()} columns but the first carried \{head.columns.length()}",
                ),
              )
            }
        }
        let at = self.before
        self.before += 1
        if at >= self.skip && at < self.limit {
          rows.push(row)
        }
        if at + 1 >= self.limit {
          self.ended = true
          self.cursor.close()
        }
      }
    }
  }
  rows
}

///|
/// The columns one read builds: those the projection names, with the
/// absorbed predicate's own beside them — the predicate filters each
/// batch, so its columns are built even when the projection omits them.
fn sql_wanted(
  name : String,
  projection : Array[String]?,
  keys : Array[String],
) -> Bool {
  match projection {
    None => true
    Some(cols) => cols.contains(name) || keys.contains(name)
  }
}

///|
/// One column of a later batch, under the dtype its first batch settled:
/// a cell of that dtype lands as it is, an integer cell in a `Float`
/// column lifts, and a cell of any other shape refuses naming the column.
fn sql_pinned_column(
  name : String,
  rows : Array[@moondb.Row],
  c : Int32,
  dtype : @types.DataType,
) -> @series.Series raise @types.DataError {
  let cells : Array[@types.Scalar] = []
  for row in rows {
    let cell = sql_cell(name, row.values[c])
    if cell is @types.Scalar::Null {
      cells.push(cell)
    } else if dtype is @types.DataType::Float && cell is @types.Scalar::Int(v) {
      cells.push(@types.Scalar::Float(v.to_double()))
    } else if cell.dtype() == dtype {
      cells.push(cell)
    } else {
      raise @types.DataError::InvalidOperation(
        "scan_sql: column \"\{name}\" holds a \{cell.dtype()} cell where its first batch held \{dtype} ones, and a stream cannot widen a column it has answered; cast the column in the query",
      )
    }
  }
  @series.Series::from_scalars(name, cells, dtype~)
}

///|
/// The next batch, or `None` once the read is done. An answer with rows
/// whose window keeps none still answers its columns once, as zero-row
/// columns typed by the answer's first row — the `0×N` shape an eager
/// read-then-window yields.
fn SqlStream::next(
  self : SqlStream,
  projection : Array[String]?,
  keys : Array[String],
  to_batch : (@frame.DataFrame) -> @scan.ScanBatch raise @types.DataError,
) -> @scan.ScanBatch? raise @types.DataError {
  if self.ended && (self.emitted || self.first is None) {
    return None
  }
  let rows = self.pull()
  let frame = if rows.is_empty() {
    // The window keeps no row of an answer that has some: its columns
    // answer once, each typed by the first row — the row a read with no
    // window would have typed its first batch by.
    let columns : Array[@series.Series] = []
    match self.first {
      None => ()
      Some(head) =>
        for c, name in head.columns {
          if sql_wanted(name, projection, keys) {
            let typed = sql_column(name, [head], c)
            columns.push(
              @series.Series::from_scalars(name, [], dtype=typed.dtype()),
            )
          }
        }
    }
    @frame.DataFrame::from_parts(columns, 0)
  } else {
    // The first batch settles the dtypes; every later one is held to them.
    let names = rows[0].columns
    if self.pinned.is_empty() {
      self.pinned = Array::make(names.length(), None)
    }
    let columns : Array[@series.Series] = []
    for c, name in names {
      if sql_wanted(name, projection, keys) {
        let series = match self.pinned[c] {
          None => sql_column(name, rows, c)
          Some(dtype) => sql_pinned_column(name, rows, c, dtype)
        }
        self.pinned[c] = Some(series.dtype())
        columns.push(series)
      }
    }
    @frame.DataFrame::from_parts(columns, rows.length())
  }
  self.emitted = true
  Some(to_batch(frame))
}

///|
/// The SQL scan driver: one cursor over the query per read, its rows
/// handed out batch by batch — the pushed-down predicate filtering each
/// batch once it is built, the projection keeping its columns in the
/// answer's own order, and a sunk window read no further than its end.
fn sql_scan_driver(
  driver : &@moondb.Driver,
  sql : String,
  params : Array[@moondb.Value],
) -> @scan.ScanDriver {
  @scan.ScanDriver::driver(
    () => "SQL \"\{@text.escape_debug(sql)}\"",
    (projection, predicate, window) => {
      // The predicate's own columns ride the build.
      let keys : Array[String] = []
      match predicate {
        Some(pred) =>
          for name in pred.referenced_columns() {
            keys.push(name)
          }
        None => ()
      }
      let stream = sql_open(driver, sql, params, window)
      @scan.BatchCursor::cursor(() => {
        stream.next(projection, keys, fn(
          frame : @frame.DataFrame,
        ) -> @scan.ScanBatch raise @types.DataError {
          // One batch's frame to the batch the engine reads: the
          // absorbed predicate filters the batch, then the projection
          // keeps its columns in the answer's own schema order (a name
          // the answer does not carry builds no column, and the
          // separately carried height keeps the rows — the `N×0`
          // shape).
          let kept = match predicate {
            Some(pred) => frame.filter(pred)
            None => frame
          }
          let out : Array[@series.Series] = match projection {
            Some(cols) =>
              kept.column_series().filter(s => cols.contains(s.name()))
            None => kept.column_series()
          }
          @scan.ScanBatch::batch(out, kept.nrows())
        })
      })
    },
    absorbs_window=true,
  )
}

///|
/// The lazy SQL source: `scan_sql(driver, sql, params~)` builds a
/// `LazyFrame` whose leaf is a deferred run of the query — the
/// push-down-aware, streaming counterpart of eager `read_sql`, over the
/// same moondb driver and the same cell mapping. Nothing is sent until
/// `collect` (the builder is total), and the answer is then read through
/// the driver's cursor in batches, so a plan that stops pulling stops the
/// read.
///
/// The **projection** names the columns each batch builds, with the
/// **predicate**'s own beside them; the predicate filters each batch once
/// it is built. A sunk **window** rides into the read: a `head`, and a
/// `slice` by forward bounds, stop the read at the window's end, so the
/// rows after it are never pulled; a `tail`, and a window counted from
/// the answer's end, read the answer whole first to learn its row count.
/// The surviving rows are exactly the eager read's.
///
/// Each column's dtype is settled by the first batch, by `read_sql`'s
/// rule, and every later batch is held to it: an integer cell in a `Float`
/// column lifts, and a cell of any other shape refuses naming the column
/// — a stream cannot widen a column it has already answered, where
/// `read_sql` would. A column whose first batch holds no cell to type it
/// is `String`, as an all-null column reads. An answer of no row is the
/// `0×0` frame; an answer whose window keeps no row answers its columns
/// once, as zero-row columns typed by the answer's first row. The dtypes follow the cells, so the schema
/// can name temporal columns no plan-time fact can rule out, and this
/// source takes the temporal value-fence's conservative arm: a predicate
/// or stage expression carrying a temporal-checked operation stays above
/// the scan.
pub fn scan_sql(
  driver : &@moondb.Driver,
  sql : String,
  params~ : Array[@moondb.Value] = [],
) -> @frame.LazyFrame {
  // The caller's array is copied at the boundary: the plan keeps the
  // values until the read opens, and the copy leaves the caller's array
  // the caller's own.
  let params = params.copy()
  @frame.LazyFrame::file_scan(
    sql_scan_driver(driver, sql, params),
    may_carry_temporal=true,
  )
}
