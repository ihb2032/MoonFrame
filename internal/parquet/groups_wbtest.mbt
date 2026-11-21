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
    w.i64_field(3, rows)
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
    [("v", -5L, 0L), ("v", 5L, 0L)],
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
    [("v", 3_000_000_000L, 0L)],
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
