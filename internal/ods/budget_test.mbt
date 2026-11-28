// Blackbox tests of the budget a sheet is held to: the rectangle a file
// asks for is checked against a budget tied to the package's size before a
// cell of it is stored, and the sheet holds as many cells as the budget,
// and not one more.

///|
/// A row of one value, repeated `count` times, as a package.
fn repeated_rows(count : String) -> Bytes {
  let content = swapped(
    document(
      "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"00000\"><table:table-cell office:value-type=\"float\" office:value=\"1\"/></table:table-row></table:table>",
    ),
    "00000",
    count,
  )
  spreadsheet(content)
}

///|
/// A row of one value repeated `count` times along it, as a package.
fn repeated_columns(count : String) -> Bytes {
  let content = swapped(
    document(
      "<table:table table:name=\"S\"><table:table-row><table:table-cell office:value-type=\"float\" office:value=\"1\" table:number-columns-repeated=\"00000\"/></table:table-row></table:table>",
    ),
    "00000",
    count,
  )
  spreadsheet(content)
}

///|
test "the rectangle a file asks for is held to a budget tied to the package's size" {
  // A thousand empty rows, then a thousand empty cells: a rectangle of a
  // million and one cells. A package of a few hundred bytes cannot ask
  // for it — the count read last before the sheet is measured is named —
  // and one of 200 KB can: the budget grows with the package.
  let far = "<table:table table:name=\"S\"><table:table-row table:number-rows-repeated=\"1000\"/><table:table-row><table:table-cell table:number-columns-repeated=\"1000\"/><table:table-cell office:value-type=\"float\" office:value=\"1\"/></table:table-row></table:table>"
  let small = body_package(far)
  let at = at_of(
    @utf8.encode(document(far)),
    "table:number-columns-repeated=\"1000\"/>",
  )
  refusal_is(
    small,
    "ParseError",
    "ods: content.xml byte \{at}: the table:number-columns-repeated attribute \"1000\" would make sheet \"S\" hold more cells than this reader grants a package of \{small.length()} bytes (\{budget_of(small.length())})",
  )
  let archive = @zip.Archive::Archive()
  archive.add("mimetype", @utf8.encode(MIMETYPE), compression=Store)
  archive.add("pad.bin", Bytes::makei(200000, _ => b'p'), compression=Store)
  archive.add("content.xml", @utf8.encode(document(far)))
  let padded = @zip.write(archive) catch { _ => b"" }
  if budget_of(padded.length()) <= 1002000L {
    fail(
      "the padded package's budget is \{budget_of(padded.length())}, too small for the test",
    )
  }
  cells_are(padded, ["1000,1000 Number 3ff0000000000000"])
}

///|
test "a sheet holds as many cells as the budget, and not one more" {
  // A count is sought that is its own package's budget: the budget moves
  // the package by a byte or two as its digits change, so the count is
  // followed until it settles.
  let mut count = budget_of(repeated_rows("69000").length())
  let mut settled = false
  for _ in 0..<20 {
    let bytes = repeated_rows(count.to_string())
    let again = budget_of(bytes.length())
    if again == count {
      let cells = sheet_grid(bytes).cells()
      assert_eq(cells.length().to_int64(), count)
      assert_eq(cells[0].row(), 0)
      assert_eq(cells[cells.length() - 1].row(), (count - 1L).to_int())
      settled = true
      break
    }
    count = again
  }
  if !settled {
    fail("no count settled as its own budget")
  }
  // Well past it — past the bytes a changed count moves the package by.
  let over = (count + 64L).to_string()
  let over_bytes = repeated_rows(over)
  let at = at_of(
    content_entry(over_bytes),
    "table:number-rows-repeated=\"\{over}\"",
  )
  refusal_is(
    over_bytes,
    "ParseError",
    "ods: content.xml byte \{at}: the table:number-rows-repeated attribute \"\{over}\" would make sheet \"S\" hold more cells than this reader grants a package of \{over_bytes.length()} bytes (\{budget_of(over_bytes.length())})",
  )
  // Cells along a row are held to the same budget.
  let mut count = budget_of(repeated_columns("69000").length())
  let mut settled = false
  for _ in 0..<20 {
    let bytes = repeated_columns(count.to_string())
    let again = budget_of(bytes.length())
    if again == count {
      let cells = sheet_grid(bytes).cells()
      assert_eq(cells.length().to_int64(), count)
      assert_eq(cells[0].col(), 0)
      assert_eq(cells[cells.length() - 1].col(), (count - 1L).to_int())
      settled = true
      break
    }
    count = again
  }
  if !settled {
    fail("no count settled as its own budget, along a row")
  }
}

///|
/// The content.xml of a package the test built, as bytes.
fn content_entry(bytes : Bytes) -> Bytes {
  let opened : Result[_, @zip.ZipError] = Ok(@zip.read(bytes)) catch {
    e => Err(e)
  }
  match opened {
    Ok(archive) =>
      match archive.get("content.xml") {
        Some(view) => view.to_owned()
        None => b""
      }
    Err(_) => b""
  }
}
