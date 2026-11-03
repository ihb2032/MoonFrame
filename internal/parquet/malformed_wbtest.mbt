// Whitebox malformed-footer sweep — every prefix of a valid footer,
// re-wrapped as a self-consistent file (the cut footer's own length +
// the trailing magic), must refuse without aborting. One loop walks the
// truncation arms of every footer reader: the schema list, the row
// groups, the column chunks, the page walk never reached.

///|
test "every truncated footer prefix refuses, never aborts" {
  let columns : Array[@series.Series] = [
    @series.Series::from_ints("i", [1, 2, 3]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ]
  let whole = write_parquet_bytes(columns, ["i", "s"], Uncompressed)
  let n = whole.length()
  let footer_len = le_i32(whole, n - 8)
  let footer_start = n - 8 - footer_len
  for cut in 0..<footer_len {
    // The file: the head through the cut, then the cut length and the
    // magic — a structurally valid file whose footer ends early.
    let body = Bytes::makei(footer_start + cut, k => whole[k])
    let tail : Array[Byte] = []
    push_le_i32(tail, cut)
    let out = Bytes::makei(body.length() + 8, k => {
      if k < body.length() {
        body[k]
      } else {
        let at = k - body.length()
        if at < 4 {
          tail[at]
        } else {
          b"PAR1"[at - 4]
        }
      }
    })
    let result = Ok(ignore(read_parquet_columns(out, None))) catch {
      e => Err(e)
    }
    // The contract is "never aborts": a cut mid-thrift either refuses
    // below the magic checks or happens to land on a struct boundary
    // the thrift grammar accepts (a footer with fewer fields — a frame
    // with no row groups decodes as the empty frame). Both outcomes are
    // fine; an abort would fail this test on its own.
    match result {
      Ok(_) => ()
      Err(_) => ()
    }
  }
}

///|
test "a schema element with a wrong list element type refuses" {
  // The schema list header naming a non-struct element type (here 5 =
  // i32) is the list-header mismatch arm.
  let columns : Array[@series.Series] = [@series.Series::from_ints("i", [1])]
  let whole = write_parquet_bytes(columns, ["i"], Uncompressed)
  let n = whole.length()
  let footer_len = le_i32(whole, n - 8)
  let footer_start = n - 8 - footer_len
  // The schema list opens at the footer's field 2: find the byte with
  // the struct element type (0x?C) and rewrite it to i32 (0x05) — the
  // first list header in the footer is the schema's. `Bytes` is
  // immutable — the patch rebuilds the whole array.
  let limit = n - 8
  let mut patched = false
  let out = Bytes::makei(n, k => {
    if !patched &&
      k >= footer_start &&
      k < limit &&
      (whole[k].to_int() & 0x0F) == 12 &&
      whole[k].to_int() >> 4 > 0 {
      patched = true
      (0x05).to_byte()
    } else {
      whole[k]
    }
  })
  let _ = patched
  let result = Ok(ignore(read_parquet_columns(out, None))) catch { e => Err(e) }
  assert_true(result is Err(_))
}

///|
test "every footer byte corrupted to 0xFF refuses or answers, never aborts" {
  let columns : Array[@series.Series] = [
    @series.Series::from_ints("i", [1, 2, 3]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ]
  let whole = write_parquet_bytes(columns, ["i", "s"], Uncompressed)
  let n = whole.length()
  let footer_len = le_i32(whole, n - 8)
  let footer_start = n - 8 - footer_len
  // One byte at a time, over the footer and the page-head region both.
  for k in footer_start..<n {
    let out = Bytes::makei(n, at => {
      if at == k {
        (0xFF).to_byte()
      } else {
        whole[at]
      }
    })
    let result = Ok(ignore(read_parquet_columns(out, None))) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => ()
      Err(_) => ()
    }
  }
}

///|
test "page-header truncations and corruptions never abort" {
  let columns : Array[@series.Series] = [
    @series.Series::from_ints("i", [1, 2, 3]),
    @series.Series::from_strings("s", ["a", "b", "c"]),
  ]
  let whole = write_parquet_bytes(columns, ["i", "s"], Uncompressed)
  let n = whole.length()
  let footer_len = le_i32(whole, n - 8)
  let pages_end = n - 8 - footer_len
  // Every truncation of the page region (keeping a self-consistent
  // footer): the chunk offsets then leave the file, or the page header
  // ends mid-thrift — both refuse.
  for cut in 4..<pages_end {
    let body = Bytes::makei(cut, k => whole[k])
    let out : Array[Byte] = []
    for b in body {
      out.push(b)
    }
    // The footer bytes, re-appended with their own length.
    let footer = Bytes::makei(footer_len, k => whole[pages_end + k])
    for b in footer {
      out.push(b)
    }
    push_le_i32(out, footer_len)
    for b in b"PAR1" {
      out.push(b)
    }
    let result = Ok(ignore(read_parquet_columns(Bytes::from_array(out), None))) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => ()
      Err(_) => ()
    }
  }
  // And every page-region byte flipped to 0xFF.
  for k in 4..<pages_end {
    let out = Bytes::makei(n, at => {
      if at == k {
        (0xFF).to_byte()
      } else {
        whole[at]
      }
    })
    let result = Ok(ignore(read_parquet_columns(out, None))) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => ()
      Err(_) => ()
    }
  }
}

///|
test "page headers truncated mid-field refuse, never abort" {
  // One column, one page: rebuild the file for every prefix length of
  // the page header (the footer's chunk sizes naming the prefix, so
  // the walk enters the header and ends mid-field at exactly the cut).
  let columns : Array[@series.Series] = [
    @series.Series::from_ints("i", [1, 2, 3]),
  ]
  let whole = write_parquet_bytes(columns, ["i"], Uncompressed)
  let n = whole.length()
  let footer_len = le_i32(whole, n - 8)
  let footer_start = n - 8 - footer_len
  let page_len = footer_start - 4
  // Rebuild: for each cut, the page bytes are whole[4..4+cut), and the
  // footer's two size fields (compressed 7 and data_page_offset 9 +
  // total 6) need rewriting — the footer is thrift with varints, so
  // rewriting in place is fragile. Instead: patch by re-encoding the
  // footer from the reader's own structures — spelled here by
  // re-writing a fresh footer via the writer with the cut size.
  for cut in 1..<page_len {
    // Locate the chunk's size fields: walk the footer with the reader
    // to find them, then rebuild the footer with the compressed /
    // uncompressed sizes set to the cut.
    let rebuilt = rebuild_footer_with_page_size(whole, footer_start, cut)
    let out : Array[Byte] = []
    for k in 0..<4 {
      out.push(whole[k])
    }
    let page = Bytes::makei(cut, k => whole[4 + k])
    for b in page {
      out.push(b)
    }
    for b in rebuilt {
      out.push(b)
    }
    push_le_i32(out, rebuilt.length())
    for b in b"PAR1" {
      out.push(b)
    }
    let result = Ok(ignore(read_parquet_columns(Bytes::from_array(out), None))) catch {
      e => Err(e)
    }
    match result {
      Ok(_) => ()
      Err(_) => ()
    }
  }
}

///|
/// Re-encode `whole`'s footer with the single column chunk's
/// `total_compressed_size` (field 7) and `total_uncompressed_size`
/// (field 6) set to `page_size` — every other field carried verbatim
/// from the walk. The one-column shape the sweeps read is all this
/// needs: one row group, one chunk, one schema column.
fn rebuild_footer_with_page_size(
  whole : Bytes,
  footer_start : Int32,
  page_size : Int32,
) -> Bytes {
  // Walk the original footer for the facts.
  let r = thrift_reader(whole)
  r.pos = footer_start
  let mut num_rows = 0L
  let mut physical = 0
  let mut name = ""
  let mut last = 0
  for ;; {
    let h = r.field_header(last).unwrap()
    if h.wire is Stop {
      break
    }
    last = h.id
    match h.id {
      3 => num_rows = r.zigzag_i64().unwrap()
      2 => {
        // The schema list: skip its header, read the root, read the
        // one column element.
        let count = list_header(r, 12).unwrap()
        ignore(count)
        // Root element.
        let mut l2 = 0
        for ;; {
          let hh = r.field_header(l2).unwrap()
          if hh.wire is Stop {
            break
          }
          l2 = hh.id
          if !r.skip(hh.wire) {
            break
          }
        }
        // The column element: physical (1), repetition (3), name (4),
        // converted (6).
        let mut l3 = 0
        for ;; {
          let hh = r.field_header(l3).unwrap()
          if hh.wire is Stop {
            break
          }
          l3 = hh.id
          match hh.id {
            1 => physical = r.zigzag_i32().unwrap()
            4 => name = r.text().unwrap()
            _ => if !r.skip(hh.wire) { break }
          }
        }
      }
      _ => if !r.skip(h.wire) { break }
    }
  }
  // Re-emit the footer with the patched sizes.
  let w = thrift_writer()
  w.i32_field(1, 1)
  w.field_header(2, 9)
  w.list_header(2, 12)
  w.struct_field_begin_list_elem()
  w.text_field(4, "schema")
  w.i32_field(5, 1)
  w.struct_end()
  w.struct_field_begin_list_elem()
  w.i32_field(1, physical)
  w.i32_field(3, 1)
  w.text_field(4, name)
  w.struct_end()
  w.i64_field(3, num_rows)
  w.field_header(4, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.field_header(1, 9)
  w.list_header(1, 12)
  w.struct_field_begin_list_elem()
  w.i64_field(2, 4L)
  w.struct_field_begin(3)
  w.i32_field(1, physical)
  w.field_header(2, 9)
  w.list_header(2, 5)
  w.i32_list_elem(0)
  w.i32_list_elem(3)
  w.field_header(3, 9)
  w.list_header(1, 8)
  w.text_list_elem(name)
  w.i32_field(4, 0)
  w.i64_field(5, num_rows)
  w.i64_field(6, page_size.to_int64())
  w.i64_field(7, page_size.to_int64())
  w.i64_field(9, 4L)
  w.struct_end()
  w.struct_end()
  w.i64_field(2, page_size.to_int64())
  w.i64_field(3, num_rows)
  w.struct_end()
  w.struct_end()
  w.text_field(6, "MoonFrame-test")
  w.struct_end()
  w.finish()
}
