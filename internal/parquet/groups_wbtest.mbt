// Whitebox coverage for the multi-row-group shape: the writer's group
// layout (`group_rows`), the whole-file read's cross-group
// concatenation, the group reader's per-group surface, and the hostile
// footers the writer never produces — counts that disagree with the
// file's total, a group that lacks a column the first group carries,
// and counts past the bounds a frame's own height rides.

///|
/// A hand-built multi-group footer over INT64 OPTIONAL leaves: the
/// schema names `leaves`, group `i` carries one chunk naming
/// `groups[i].0` with its own row count and value count, and the file's
/// row count is whatever the caller spells — the hostile shapes the
/// writer never produces. Every chunk points past the leading magic at
/// whatever page bytes the caller supplied; the refusals these files
/// drive all land before any page decodes, so most callers pass none.
fn hostile_group_file(
  leaves : Array[String],
  num_rows : Int64,
  groups : Array[(String, Int64, Int64)],
  pages : Bytes,
  garble_rows~ : Bool = false,
) -> Bytes {
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(2, 9)
  w.list_header(leaves.length() + 1, 12)
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, leaves.length())
  w.struct_end()
  for leaf in leaves {
    w.struct_field_begin_list_elem()
    w.i32_field(1, 2)
    w.i32_field(3, 1)
    w.text_field(4, leaf)
    w.struct_end()
  }
  w.i64_field(3, num_rows)
  w.field_header(4, 9)
  w.list_header(groups.length(), 12)
  for group in groups {
    let (name, rows, values) = group
    w.struct_field_begin_list_elem()
    w.field_header(1, 9)
    w.list_header(1, 12)
    w.struct_field_begin_list_elem()
    w.i64_field(2, 4L)
    w.struct_field_begin(3)
    w.i32_field(1, 2)
    w.field_header(2, 9)
    w.list_header(2, 5)
    w.i32_list_elem(0)
    w.i32_list_elem(3)
    w.field_header(3, 9)
    w.list_header(1, 8)
    w.text_list_elem(name)
    w.i32_field(4, 0)
    w.i64_field(5, values)
    w.i64_field(6, 8L)
    w.i64_field(7, 8L)
    w.i64_field(9, 4L)
    w.struct_end()
    w.struct_end()
    w.i64_field(2, 8L)
    // The garbled spelling names the group's row count as text - the
    // footer walk refuses the field rather than reading a number that
    // is not there.
    if garble_rows {
      w.text_field(3, "not-a-count")
    } else {
      w.i64_field(3, rows)
    }
    w.struct_end()
  }
  w.text_field(6, "MoonFrame-test")
  w.struct_end()
  let footer = w.finish()
  let out : Array[Byte] = []
  for b in b"PAR1" {
    out.push(b)
  }
  for b in pages {
    out.push(b)
  }
  for b in footer {
    out.push(b)
  }
  push_le_i32(out, footer.length())
  for b in b"PAR1" {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
test "parquet writes and reads multiple row groups" {
  let columns = sample_columns()
  let names = names_of(columns)
  let bytes = write_parquet_bytes(columns, names, Uncompressed, group_rows=2L)
  // The whole-file read concatenates the groups' cells in order — the
  // frame round-trips exactly, group layout and all.
  let (picked, rows) = read_parquet_frame(bytes, None)
  assert_eq(rows, 4)
  assert_eq(picked.length(), columns.length())
  for i in 0..<columns.length() {
    assert_eq(picked[i].0, names[i])
    assert_eq(picked[i].1.dtype(), columns[i].dtype())
    assert_eq(picked[i].1.to_scalars(), columns[i].to_scalars())
  }
  // The group reader walks the same file group by group.
  let reader = ParquetGroupReader::group_reader(bytes, None)
  assert_eq(reader.group_count(), 2)
  assert_eq(reader.total_rows(), 4)
  assert_eq(reader.group_rows(0), 2)
  assert_eq(reader.group_rows(1), 2)
  let (first, first_rows) = reader.decode_group(0)
  assert_eq(first_rows, 2)
  assert_eq(first.length(), columns.length())
  for i in 0..<columns.length() {
    let whole = columns[i].to_scalars()
    let half = first[i].1.to_scalars()
    for j in 0..<2 {
      assert_eq(half[j], whole[j])
    }
  }
  // A projection narrows each group the lenient way, and a name no
  // group carries builds no column while the group's rows ride.
  let narrowed = ParquetGroupReader::group_reader(bytes, Some(["i"]))
  let (one, one_rows) = narrowed.decode_group(1)
  assert_eq(one_rows, 2)
  assert_eq(one.length(), 1)
  assert_eq(one[0].0, "i")
  let empty = ParquetGroupReader::group_reader(bytes, Some(["nope"]))
  let (none, none_rows) = empty.decode_group(0)
  assert_eq(none.length(), 0)
  assert_eq(none_rows, 2)
}

///|
test "row-group bounds degenerate and leave remainders" {
  let columns = sample_columns()
  let names = names_of(columns)
  // 0 and a bound at or past the height spell the single group.
  let zero = write_parquet_bytes(columns, names, Uncompressed)
  assert_eq(ParquetGroupReader::group_reader(zero, None).group_count(), 1)
  let past = write_parquet_bytes(columns, names, Uncompressed, group_rows=4L)
  assert_eq(ParquetGroupReader::group_reader(past, None).group_count(), 1)
  let far = write_parquet_bytes(
    columns,
    names,
    Uncompressed,
    group_rows=5_000_000_000L,
  )
  assert_eq(ParquetGroupReader::group_reader(far, None).group_count(), 1)
  // A bound inside the height leaves the remainder in the last group,
  // and the read still round-trips.
  let split = write_parquet_bytes(columns, names, Uncompressed, group_rows=3L)
  let reader = ParquetGroupReader::group_reader(split, None)
  assert_eq(reader.group_count(), 2)
  assert_eq(reader.group_rows(0), 3)
  assert_eq(reader.group_rows(1), 1)
  let (picked, rows) = read_parquet_frame(split, None)
  assert_eq(rows, 4)
  for i in 0..<columns.length() {
    assert_eq(picked[i].1.to_scalars(), columns[i].to_scalars())
  }
}

///|
test "a file whose group counts disagree with its total refuses" {
  // One group spelling 3 rows under a file that declares 5 — the sums
  // disagree, and every group boundary a batch walk derives would be
  // wrong, so the footer walk refuses before any chunk decodes.
  let file = hostile_group_file(
    ["v"],
    5L,
    [("v", 3L, 3L)],
    Bytes::from_array([]),
  )
  let result = Ok(ignore(read_parquet_frame(file, None))) catch { e => Err(e) }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("declares 5 rows but its row groups spell 3"),
  )
}

///|
test "a later row group lacking a column refuses" {
  // The first group carries "v" and "w" in the schema; the second group
  // spells only "w" — the concatenation for "v" has no knowable cells
  // in that group, and both the whole-file read and the group reader
  // refuse naming the group, before any page decodes.
  let file = hostile_group_file(
    ["v", "w"],
    2L,
    [("v", 1L, 1L), ("w", 1L, 1L)],
    Bytes::from_array([]),
  )
  let whole = Ok(ignore(read_parquet_frame(file, None))) catch { e => Err(e) }
  assert_true(
    whole
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("row group 2 lacks the column \"v\""),
  )
  let grouped = Ok(
    ignore(ParquetGroupReader::group_reader(file, None).decode_group(1)),
  ) catch {
    e => Err(e)
  }
  assert_true(
    grouped
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(gmsg))) &&
    gmsg.contains("row group 2 lacks the column \"v\""),
  )
}

///|
test "the joined-cell budget across row groups refuses" {
  // Two groups each inside the per-chunk budget (2^26 + 1 values, held
  // plausible by a fill that carries them at eight one-bit cells to a
  // byte) whose sum leaves it — the refusal lands on the footer's own
  // counts, before either group's pages decode.
  let file = hostile_group_file(
    ["v"],
    134_217_730L,
    [("v", 67_108_865L, 67_108_865L), ("v", 67_108_865L, 67_108_865L)],
    Bytes::makei(8_388_610, _ => 0),
  )
  let result = Ok(ignore(read_parquet_frame(file, None))) catch { e => Err(e) }
  assert_true(
    result is Err(@types.DataError::InvalidOperation(msg)) &&
    msg.contains("134217730 cells across its row groups"),
  )
}

///|
test "group rows past the count and hostile counts refuse" {
  // The writer-produced shape: an index past the group count (either
  // end) refuses naming the count, on both the row-count and the
  // decode entries.
  let columns = sample_columns()
  let names = names_of(columns)
  let bytes = write_parquet_bytes(columns, names, Uncompressed, group_rows=2L)
  let reader = ParquetGroupReader::group_reader(bytes, None)
  for past in [2, -1] {
    let rows = Ok(ignore(reader.group_rows(past))) catch { e => Err(e) }
    assert_true(
      rows
      is Err(
        @types.DataError::ParseError(@types.ParseErrorDetail::Message(msg)),
      ) &&
      msg.contains("past the file's 2 groups"),
    )
    let decode = Ok(ignore(reader.decode_group(past))) catch { e => Err(e) }
    assert_true(
      decode
      is Err(
        @types.DataError::ParseError(@types.ParseErrorDetail::Message(dmsg)),
      ) &&
      dmsg.contains("past the file's 2 groups"),
    )
  }
  // A hostile spelling whose per-group counts sum to the file's total
  // only through a negative group — the group's own count refuses.
  let negative = hostile_group_file(
    ["v"],
    0L,
    [("v", -5L, -5L), ("v", 5L, 5L)],
    Bytes::from_array([]),
  )
  let neg_reader = ParquetGroupReader::group_reader(negative, None)
  assert_eq(neg_reader.total_rows(), 0)
  let neg = Ok(ignore(neg_reader.group_rows(0))) catch { e => Err(e) }
  assert_true(
    neg
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("declares -5 rows, past a frame's own height"),
  )
  // A count inside a negative-free spelling but past the Int32 a
  // frame's height rides refuses the same way.
  let huge = hostile_group_file(
    ["v"],
    3_000_000_000L,
    [("v", 3_000_000_000L, 3_000_000_000L)],
    Bytes::from_array([]),
  )
  let huge_reader = ParquetGroupReader::group_reader(huge, None)
  let over = Ok(ignore(huge_reader.group_rows(0))) catch { e => Err(e) }
  assert_true(
    over
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("3000000000 rows, past a frame's own height"),
  )
}

///|
test "a garbled group row count refuses the footer walk" {
  // The group's own field 3 spelled as text: the walk refuses the field
  // rather than reading a number that is not there.
  let file = hostile_group_file(
    ["v"],
    1L,
    [("v", 1L, 1L)],
    Bytes::from_array([]),
    garble_rows=true,
  )
  let result = Ok(ignore(read_parquet_frame(file, None))) catch { e => Err(e) }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("the row group list is malformed"),
  )
}

///|
test "the schema batch answers columns without decoding cells" {
  // A file with no groups has no columns to answer — 0×0. A real file's
  // schema batch carries the projected columns as zero-row series with
  // their dtypes, never decoding a page.
  let bare = hostile_group_file(["v"], 0L, [], Bytes::from_array([]))
  let bare_reader = ParquetGroupReader::group_reader(bare, None)
  let (empty, empty_rows) = bare_reader.schema_group()
  assert_eq(empty.length(), 0)
  assert_eq(empty_rows, 0)
  let columns = sample_columns()
  let names = names_of(columns)
  let bytes = write_parquet_bytes(columns, names, Uncompressed, group_rows=2L)
  let reader = ParquetGroupReader::group_reader(bytes, Some(["i", "s"]))
  let (schema, rows) = reader.schema_group()
  assert_eq(rows, 0)
  assert_eq(schema.length(), 2)
  assert_eq(schema[0].0, "i")
  assert_eq(schema[0].1.dtype(), @types.DataType::Int)
  assert_eq(schema[0].1.len(), 0)
  assert_eq(schema[1].1.dtype(), @types.DataType::String)
}

///|
test "a group's own chunk past the cell budget refuses at its decode" {
  // The whole-file entry refuses a joined count at the footer; the group
  // reader walks one group at a time, so its refusal is the chunk's own
  // — the same budget, reached through the per-group path.
  let file = hostile_group_file(
    ["v"],
    134_217_729L,
    [("v", 134_217_729L, 134_217_729L)],
    Bytes::makei(16_777_220, _ => 0),
  )
  let reader = ParquetGroupReader::group_reader(file, None)
  let result = Ok(ignore(reader.decode_group(0))) catch { e => Err(e) }
  assert_true(
    result is Err(@types.DataError::InvalidOperation(msg)) &&
    msg.contains("past the 134217728-cell budget"),
  )
}

///|
test "a file-wide row count past a frame's height refuses the total" {
  // The group's own count stayed inside Int32; the file's declaration
  // did not — the whole-file height answer refuses it.
  let file = hostile_group_file(
    ["v"],
    3_000_000_000L,
    [("v", 3_000_000_000L, 3_000_000_000L)],
    Bytes::from_array([]),
  )
  let reader = ParquetGroupReader::group_reader(file, None)
  let result = Ok(ignore(reader.total_rows())) catch { e => Err(e) }
  assert_true(
    result
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("the file declares 3000000000 rows, past a frame's own height"),
  )
}

///|
test "a group row count cut off mid-varint refuses the walk" {
  // The reader's row-count field ends the buffer inside its varint: the
  // continuation bit promises a byte that is not there, and the walk
  // refuses the group list rather than reading a number that is not
  // there. Built directly — the writer never truncates its own varints,
  // so no whole-file spelling reaches this arm.
  let w = thrift_writer()
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.field_header(3, 6)
  let bytes : Array[Byte] = []
  for b in w.finish() {
    bytes.push(b)
  }
  // The varint's lone byte: continuation set, nothing after it.
  bytes.push((0x80).to_byte())
  let r = thrift_reader(Bytes::from_array(bytes))
  r.pos = 0
  let groups : Array[GroupRaw] = []
  assert_false(row_groups_read(r, groups))
  assert_eq(groups.length(), 0)
}

///|
test "a chunk count disagreeing with its group refuses at the footer" {
  // The whole-file read decodes by the chunk count; the batch read takes
  // its height from the group count. A file where the two disagree would
  // answer two different heights, so the footer walk refuses it before
  // either engine decodes a page.
  let file = hostile_group_file(
    ["v"],
    5L,
    [("v", 5L, 3L)],
    Bytes::from_array([]),
  )
  let whole = Ok(ignore(read_parquet_frame(file, None))) catch { e => Err(e) }
  assert_true(
    whole
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(msg))) &&
    msg.contains("declares 3 values but the group declares 5 rows"),
  )
  let opened = Ok(ignore(ParquetGroupReader::group_reader(file, None))) catch {
    e => Err(e)
  }
  assert_true(
    opened
    is Err(@types.DataError::ParseError(@types.ParseErrorDetail::Message(gmsg))) &&
    gmsg.contains("declares 3 values but the group declares 5 rows"),
  )
}

///|
test "the sink's schema and batch refusals" {
  let ints = @series.Series::from_ints("v", [1, 2])
  // The one-shot writer pins its names to the columns' own.
  let mismatched = Ok(ignore(write_parquet_bytes([ints], ["w"], Uncompressed))) catch {
    e => Err(e)
  }
  assert_true(
    mismatched is Err(@types.DataError::InvalidOperation(m)) &&
    m.contains("disagrees with its column's own"),
  )
  let wrong_count = Ok(ignore(write_parquet_bytes([ints], [], Uncompressed))) catch {
    e => Err(e)
  }
  assert_true(
    (
      wrong_count is Err(@types.DataError::InvalidOperation(c)) &&
      c.contains("1 names for 0 columns")
    ) ||
    (
      wrong_count is Err(@types.DataError::InvalidOperation(c2)) &&
      c2.contains("0 names for 1 columns")
    ),
  )
  // A batch with no columns carries no height.
  let sink = ParquetSink::sink(Uncompressed)
  let bare = Ok(ignore(sink.push([]))) catch { e => Err(e) }
  assert_true(
    bare is Err(@types.DataError::InvalidOperation(b)) &&
    b.contains("no columns"),
  )
  // A first batch with disagreeing column lengths refuses.
  let ragged = ParquetSink::sink(Uncompressed)
  let ragged_push = Ok(
    ignore(ragged.push([ints, @series.Series::from_ints("w", [1])])),
  ) catch {
    e => Err(e)
  }
  assert_true(ragged_push is Err(@types.DataError::LengthMismatch(2, 1)))
  // A frameless push cannot follow a schema'd one.
  let mixed = ParquetSink::sink(Uncompressed)
  mixed.push([ints])
  let after = Ok(ignore(mixed.push_frameless(3))) catch { e => Err(e) }
  assert_true(
    after is Err(@types.DataError::InvalidOperation(a)) &&
    a.contains("frameless push cannot follow"),
  )
  // Later batches must agree with the schema: count, name, dtype.
  let schema = ParquetSink::sink(Uncompressed)
  schema.push([ints])
  let count = Ok(
    ignore(schema.push([ints, @series.Series::from_ints("w", [1, 2])])),
  ) catch {
    e => Err(e)
  }
  assert_true(
    count
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(c)),
    ) &&
    c.contains("2 columns but the sink's schema has 1"),
  )
  let renamed = ParquetSink::sink(Uncompressed)
  renamed.push([ints])
  let name = Ok(ignore(renamed.push([@series.Series::from_ints("w", [1])]))) catch {
    e => Err(e)
  }
  assert_true(
    name
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(n)),
    ) &&
    n.contains("column 0 is w but the sink's schema spells v"),
  )
  let retyped = ParquetSink::sink(Uncompressed)
  retyped.push([ints])
  let dtype = Ok(
    ignore(retyped.push([@series.Series::from_floats("v", [1.0])])),
  ) catch {
    e => Err(e)
  }
  assert_true(
    dtype
    is Err(
      @types.DataError::TypeMismatch(@types.TypeMismatchDetail::Message(d)),
    ) &&
    d.contains("Float but the sink's schema spells Int"),
  )
}

///|
test "a later batch's decimal cells answer to the first batch's window" {
  // The schema's window is the first batch's own; a later batch needing
  // a wider scale or magnitude refuses rather than silently narrowing.
  let first = @series.Series::from_decimals("d", [
    Some(@types.Dec128::of_int64_scale(15L, scale=2)),
  ])
  let sink = ParquetSink::sink(Uncompressed)
  sink.push([first])
  let wider = Ok(
    ignore(
      sink.push([
        @series.Series::from_decimals("d", [
          Some(@types.Dec128::of_int64_scale(15L, scale=5)),
        ]),
      ]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    wider is Err(@types.DataError::InvalidOperation(w)) &&
    w.contains("fraction digits, past the 2-digit scale"),
  )
  let big = Ok(
    ignore(
      sink.push([
        @series.Series::from_decimals("d", [
          Some(
            @types.Dec128::of_int64_scale(9_000_000_000_000_000_000L, scale=0),
          ),
        ]),
      ]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    big is Err(@types.DataError::InvalidOperation(g)) &&
    g.contains("past the precision-18 window"),
  )
  // A NaN cell in a later batch refuses the same way the first's would.
  let nan = @series.Series::from_decimals("d", [
    Some(@types.Dec128::of_int64_scale(15L, scale=2)),
    Some(@types.Dec128::nan()),
  ])
  let sink2 = ParquetSink::sink(Uncompressed)
  let refused = Ok(ignore(sink2.push([nan]))) catch { e => Err(e) }
  assert_true(
    refused is Err(@types.DataError::InvalidOperation(r)) &&
    r.contains("NaN or infinite decimal cell"),
  )
}

///|
test "a sink nothing was pushed to finishes as the empty file" {
  let bytes = ParquetSink::sink(Uncompressed).finish()
  let (picked, rows) = read_parquet_frame(bytes, None)
  assert_eq(picked.length(), 0)
  assert_eq(rows, 0)
}

///|
test "a later batch's NaN cell refuses under the schema's window" {
  let first = @series.Series::from_decimals("d", [
    Some(@types.Dec128::of_int64_scale(15L, scale=2)),
  ])
  let sink = ParquetSink::sink(Uncompressed)
  sink.push([first])
  let later = Ok(
    ignore(
      sink.push([
        @series.Series::from_decimals("d", [Some(@types.Dec128::nan())]),
      ]),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(
    later is Err(@types.DataError::InvalidOperation(r)) &&
    r.contains("NaN or infinite decimal cell"),
  )
}
