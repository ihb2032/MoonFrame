// Whitebox tests of the XML reader's and writer's private parts: the
// paths it takes, the declaration it reads, the cells' text, the names it
// writes, and the one state the event walk refuses to be left in.

///|
/// One open element of a document, as the walk pushes it.
fn opened(name : String) -> Open {
  Open::{
    name,
    is_row: false,
    attributes: [],
    cells: [],
    text: StringBuilder(),
    before_child: true,
  }
}

///|
test "a step is a name as written, or *" {
  assert_true(path_step_ok("*"))
  assert_true(path_step_ok("row"))
  assert_true(path_step_ok("_x"))
  assert_true(path_step_ok("p:row"))
  assert_true(path_step_ok("a-b.c:d"))
  assert_true(path_step_ok("x1"))
  assert_true(path_step_ok("é"))
  assert_true(path_step_ok("行"))
  assert_false(path_step_ok(""))
  assert_false(path_step_ok("1x"))
  assert_false(path_step_ok("-x"))
  assert_false(path_step_ok(".x"))
  assert_false(path_step_ok(":x"))
  assert_false(path_step_ok("a b"))
  assert_false(path_step_ok("a[b]"))
  assert_false(path_step_ok("@a"))
  assert_false(path_step_ok("a=b"))
}

///|
test "a path is read by where it starts" {
  let absolute = row_path("/records/row")
  assert_true(absolute.from_root)
  assert_eq(absolute.steps, ["records", "row"])
  for any in ["//row", ".//row"] {
    let deep = row_path(any)
    assert_false(deep.from_root)
    assert_eq(deep.steps, ["row"])
  }
  for relative in ["./group/row", "group/row"] {
    let below = row_path(relative)
    assert_true(below.from_root)
    assert_eq(below.steps, ["*", "group", "row"])
  }
}

///|
test "a path selects by depth as much as by name" {
  let stack = [opened("data"), opened("group"), opened("row")]
  assert_true(row_path("/data/group/row").selects(stack))
  assert_true(row_path("/*/*/row").selects(stack))
  assert_true(row_path("//group/row").selects(stack))
  assert_true(row_path("//row").selects(stack))
  // From the document element, the depth is part of the path.
  assert_false(row_path("/data/row").selects(stack))
  assert_false(row_path("/data/group/row/x").selects(stack))
  assert_false(row_path("/data/group/other").selects(stack))
  // At any depth, the document element is still below the steps.
  assert_false(
    row_path("//data/group/row").selects([
      opened("data"),
      opened("group"),
      opened("x"),
    ]),
  )
  assert_false(row_path("//row").selects([opened("row")]))
  assert_false(row_path("//group/row").selects([opened("group")]))
}

///|
test "a cell keeps whitespace-only text and loses the whitespace around any other" {
  assert_eq(trimmed_cell("  x  "), "x")
  assert_eq(trimmed_cell("\n  x\n"), "x")
  assert_eq(trimmed_cell(" x y "), "x y")
  assert_eq(trimmed_cell("   "), "   ")
  assert_eq(trimmed_cell(""), "")
  assert_true(blank(" \t\n"))
  assert_true(blank(""))
  assert_false(blank(" x "))
}

///|
test "an element that ends with none open refuses" {
  let outcome : Result[Unit, @types.DataError] = Ok(close_element([], [])) catch {
    e => Err(e)
  }
  assert_eq(
    outcome,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "xml: an element ends that never began",
        ),
      ),
    ),
  )
}

///|
test "a declaration's encoding is found where one is, and nowhere else" {
  assert_eq(
    declared_range("<?xml version=\"1.0\" encoding=\"UTF-8\"?><r/>"),
    Some((30, 35)),
  )
  assert_eq(
    declared_range("<?xml version='1.0' encoding='latin1'?>"),
    Some((30, 36)),
  )
  assert_eq(
    declared_range("<?xml\tversion=\"1.0\" encoding = \"utf-8\" ?>"),
    Some((32, 37)),
  )
  assert_eq(declared_range("<r/>"), None)
  assert_eq(declared_range(""), None)
  assert_eq(declared_range("<?xml"), None)
  assert_eq(declared_range("<?xml?>"), None)
  // A processing instruction opens the same way and is no declaration.
  assert_eq(
    declared_range("<?xml-stylesheet type=\"text/xsl\" encoding=\"utf-8\"?>"),
    None,
  )
  assert_eq(
    declared_range("<?xml version=\"1.0\"?><r encoding=\"utf-8\"/>"),
    None,
  )
  assert_eq(declared_range("<?xml version=\"1.0\" encoding=\"utf-8\""), None)
  assert_eq(declared_range("<?xml encoding \"utf-8\"?>"), None)
  assert_eq(declared_range("<?xml encoding=?>"), None)
  assert_eq(declared_range("<?xml encoding= ?>"), None)
  assert_eq(declared_range("<?xml encoding=utf-8?>"), None)
  assert_eq(declared_range("<?xml encoding=\"utf-8?>"), None)
}

///|
test "a transcoded document says utf-8, and one that was not is left alone" {
  assert_eq(
    redeclare("<?xml version=\"1.0\" encoding=\"UTF-16\"?><r/>"),
    "<?xml version=\"1.0\" encoding=\"utf-8\"?><r/>",
  )
  assert_eq(redeclare("<r/>"), "<r/>")
  assert_eq(
    redeclare("<?xml version=\"1.0\"?><r/>"),
    "<?xml version=\"1.0\"?><r/>",
  )
}

///|
test "the declared encoding is read out of the first hundred bytes, whatever follows" {
  assert_eq(
    declared_encoding(b"<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><r/>"),
    Some("iso-8859-1"),
  )
  assert_eq(
    declared_encoding(b"<?xml version=\"1.0\" encoding=\"latin1\"?><r>\xE9</r>"),
    Some("latin1"),
  )
  assert_eq(declared_encoding(b"<r/>"), None)
  assert_eq(declared_encoding(b""), None)
  for utf8 in ["utf-8", "utf8"] {
    assert_true(is_utf8(utf8))
  }
  assert_false(is_utf8("utf-16"))
  for
    latin in [
      "iso-8859-1", "iso8859-1", "latin-1", "latin1", "us-ascii", "ascii",
    ] {
    assert_true(is_latin1(latin))
  }
  assert_false(is_latin1("windows-1252"))
}

///|
test "UTF-16 of an odd length refuses" {
  let outcome : Result[String, @types.DataError] = Ok(
    utf16_text("odd", b"\x00", @utf16.Endian::Little),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    outcome,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "file odd is not valid UTF-16: an odd length or a lone surrogate",
        ),
      ),
    ),
  )
}

///|
test "a written name is ASCII, and opens with a letter or an underscore" {
  assert_true(xml_name_ok("a"))
  assert_true(xml_name_ok("_x"))
  assert_true(xml_name_ok("a-b.c1"))
  assert_true(xml_name_ok("A1"))
  assert_false(xml_name_ok(""))
  assert_false(xml_name_ok("1a"))
  assert_false(xml_name_ok("-a"))
  assert_false(xml_name_ok(".a"))
  assert_false(xml_name_ok("a b"))
  assert_false(xml_name_ok("a:b"))
  assert_false(xml_name_ok("é"))
}
