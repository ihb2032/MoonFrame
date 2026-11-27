// Blackbox tests for the XML interchange at the io layer — the rows a path
// selects and the cells a row lays out, the reference implementation's
// documents cell for cell, the encodings a file comes in, the writer's
// document and its round trip, and the refusals a caller meets.
// (One-file-one-test exemption: none — this is the format's blackbox test
// file; the whitebox one sits beside it.)

///|
/// Sixteen lowercase hexadecimal digits.
fn hex64(bits : UInt64) -> String {
  let mut digits = bits.to_string(radix=16)
  while digits.length() < 16 {
    digits = "0\{digits}"
  }
  digits
}

///|
/// A scalar as a sidecar spells one.
fn spelled(value : @types.Scalar) -> String raise {
  match value {
    Null => "Null"
    Bool(b) => "Bool \{if b { "true" } else { "false" }}"
    Int(v) => "Int \{v}"
    Float(v) => "Float \{hex64(v.reinterpret_as_uint64())}"
    String(s) => "String \{s}"
    Date(_) | Duration(_) | Timestamp(_) | Decimal(_) | List(_) | Struct(_) =>
      fail("an XML column holds \{value.to_string()}")
  }
}

///|
/// A JSON value's field, which must be there.
fn field(value : Json, name : String) -> Json raise {
  if value is Object(fields) {
    match fields.get(name) {
      Some(found) => found
      None => fail("the JSON carries no field \"\{name}\"")
    }
  } else {
    fail("the JSON value is not an object")
  }
}

///|
/// A JSON value that must be an array.
fn jarray(value : Json) -> Array[Json] raise {
  if value is Array(items) {
    items
  } else {
    fail("the JSON value is not an array")
  }
}

///|
/// A JSON value that must be a string.
fn jstring(value : Json) -> String raise {
  if value is String(text) {
    text
  } else {
    fail("the JSON value is not a string")
  }
}

///|
/// A sidecar of the reference reader: the document, the path MoonFrame
/// takes, and each column's name, the reference's dtype, and its cells.
fn sidecar(
  path : String,
) -> (String, String, Array[(String, String, Array[String])]) raise {
  let text = @fs.read_file_to_string(path) catch { _ => fail("no \{path}") }
  let value = @json.parse(text) catch { _ => fail("\{path} is not JSON") }
  let columns = jarray(field(value, "columns")).map(spec => {
    let cells = jarray(field(spec, "cells")).map(jstring)
    (jstring(field(spec, "name")), jstring(field(spec, "dtype")), cells)
  })
  (jstring(field(value, "file")), jstring(field(value, "xpath")), columns)
}

///|
/// The library's dtype for a column the reference typed `dtype` — its
/// whole, float, and boolean columns read alike.
fn library_dtype(dtype : String) -> @types.DataType {
  let name = dtype.to_lower()
  if name.contains("int") {
    @types.DataType::Int
  } else if name.contains("float") {
    @types.DataType::Float
  } else if name.contains("bool") {
    @types.DataType::Bool
  } else {
    @types.DataType::String
  }
}

///|
/// The error an entry raises; a frame answered instead fails the test.
fn raised(
  read : () -> @frame.DataFrame raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[_, @types.DataError] = Ok(ignore(read())) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the document read as a frame")
    Err(e) => e
  }
}

///|
test "the reference implementation's documents read cell for cell, under its dtypes" {
  // Each sidecar holds what the reference reader itself got from the
  // document under the path; a column of nothing but missing cells is the
  // one place the library's dtype is its own.
  let dir = ".github/fixtures/xml"
  let files = [
    "records__records_row.json", "mixed__records_row.json", "entities__records_row.json",
    "data_items__item.json", "data_items__data_group_item.json", "root_row__row.json",
    "pandas_to_xml__data_row.json", "pandas_to_xml__row.json",
  ]
  let mut compared = 0
  for file in files {
    let (document, xpath, columns) = sidecar("\{dir}/\{file}")
    let text = @fs.read_file_to_string("\{dir}/\{document}") catch {
      _ => fail("no \{document}")
    }
    let df = @io.parse_xml(text, xpath~)
    if df.columns() != columns.map(column => column.0) {
      fail(
        "\{file}: the columns \{df.columns().join(", ")} against \{columns.map(column => column.0).join(", ")}",
      )
    }
    for (name, dtype, cells) in columns {
      let column = df.get_column(name)
      let expected = if cells.all(cell => cell == "Null") {
        @types.DataType::String
      } else {
        library_dtype(dtype)
      }
      if column.dtype() != expected {
        fail(
          "\{file}, column \"\{name}\": \{column.dtype()} against \{expected}",
        )
      }
      let got = column.to_scalars().map(spelled)
      if got != cells {
        fail(
          "\{file}, column \"\{name}\": \{got.join(", ")} against \{cells.join(", ")}",
        )
      }
      compared += cells.length()
    }
  }
  assert_eq(compared, 81)
}

///|
test "a path names the rows: from the document element, from its children, or at any depth" {
  let text =
    #|<data><group><item k="1"><v>a</v></item></group><item k="2"><v>b</v></item><other><item k="3"><v>c</v></item></other></data>
  // From the document element: the depth is part of the path.
  assert_eq(
    @io.parse_xml(text, xpath="/data/item").get_column("k").to_scalars(),
    [@types.Scalar::Int(2L)],
  )
  assert_eq(
    @io.parse_xml(text, xpath="/data/group/item").get_column("k").to_scalars(),
    [@types.Scalar::Int(1L)],
  )
  // From the document element's children: `./` and a bare path alike.
  assert_eq(
    @io.parse_xml(text, xpath="./group/item").get_column("k").to_scalars(),
    [@types.Scalar::Int(1L)],
  )
  assert_eq(
    @io.parse_xml(text, xpath="group/item").get_column("k").to_scalars(),
    [@types.Scalar::Int(1L)],
  )
  // At any depth below it: `//` and `.//` alike.
  assert_eq(@io.parse_xml(text, xpath="//item").shape(), (3, 2))
  assert_eq(@io.parse_xml(text, xpath=".//item").shape(), (3, 2))
  // A document element is a row when the path names it from the root, and
  // never one under a `//`.
  assert_eq(@io.parse_xml("<row id=\"1\"/>", xpath="/row").shape(), (1, 1))
  assert_eq(@io.parse_xml("<row id=\"1\"/>", xpath="//row").shape(), (0, 0))
  // `*` stands for any element: the root's three children, each with the
  // children it holds as its columns.
  assert_eq(@io.parse_xml(text, xpath="/*/*").shape(), (3, 3))
  assert_eq(@io.parse_xml(text, xpath="/*/*/item").nrows(), 2)
  // A prefixed name is a name, declaration aside.
  let prefixed =
    #|<p:data xmlns:p="urn:y" xmlns="urn:x"><p:row p:id="1" xmlns:p="urn:z"/></p:data>
  let ns = @io.parse_xml(prefixed, xpath="//p:row")
  assert_eq(ns.columns(), ["p:id"])
  assert_eq(ns.get_column("p:id").to_scalars(), [@types.Scalar::Int(1L)])
  // The default: every `row` in the document.
  assert_eq(@io.parse_xml("<a><row id=\"1\"/></a>").shape(), (1, 1))
}

///|
test "a row's cells are its attributes, its own text, and its direct children" {
  let text =
    #|<r xmlns="urn:x" xmlns:p="urn:y"><row id="1" p:k="v">loose<a>first</a><a>second</a><e>alpha<x>nested</x>gamma</e><b/><c>  </c><id>child</id></row></r>
  let df = @io.parse_xml(text, xpath="//row")
  // The attributes first, then the row's own text under the row's name,
  // then the children in document order.
  assert_eq(df.columns(), ["id", "p:k", "row", "a", "e", "b", "c"])
  // An element named like an attribute takes the attribute's column.
  assert_eq(df.get_column("id").to_scalars(), [@types.Scalar::String("child")])
  assert_eq(df.get_column("p:k").to_scalars(), [@types.Scalar::String("v")])
  // The row's own text before its first child.
  assert_eq(df.get_column("row").to_scalars(), [@types.Scalar::String("loose")])
  // A name that repeats keeps its last cell.
  assert_eq(df.get_column("a").to_scalars(), [@types.Scalar::String("second")])
  // A nested element adds nothing to the cell it sits in, and neither does
  // the text after it.
  assert_eq(df.get_column("e").to_scalars(), [@types.Scalar::String("alpha")])
  // An empty element reads missing; whitespace alone is kept as written.
  assert_eq(df.get_column("b").to_scalars(), [@types.Scalar::Null])
  assert_eq(df.get_column("b").dtype(), @types.DataType::String)
  assert_eq(df.get_column("c").to_scalars(), [@types.Scalar::String("  ")])
}

///|
test "a column takes the narrowest dtype holding its values, over text with its edges cut" {
  let text =
    #|<r><row><a>
    #|    7
    #|  </a><b>1.5</b><c>TRUE</c><d>  padded  </d><e>007</e><f>inf</f><g>   </g><h/><i>9223372036854775808</i><j>1_000</j><k>0x10</k></row></r>
  let df = @io.parse_xml(text, xpath="//row")
  assert_eq(df.columns(), [
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k",
  ])
  assert_eq(df.get_column("a").dtype(), @types.DataType::Int)
  assert_eq(df.get_column("a").to_scalars(), [@types.Scalar::Int(7L)])
  assert_eq(df.get_column("b").to_scalars(), [@types.Scalar::Float(1.5)])
  assert_eq(df.get_column("c").to_scalars(), [@types.Scalar::Bool(true)])
  assert_eq(df.get_column("d").to_scalars(), [@types.Scalar::String("padded")])
  assert_eq(df.get_column("g").to_scalars(), [@types.Scalar::String("   ")])
  assert_eq(df.get_column("h").to_scalars(), [@types.Scalar::Null])
  // An integer past what an `Int` holds is a `Float`, exactly as far as
  // the double holds it; a non-finite spelling is a `Float`, as in CSV.
  assert_eq(df.get_column("i").dtype(), @types.DataType::Float)
  assert_eq(df.get_column("i").to_scalars(), [
    @types.Scalar::Float(9223372036854775808.0),
  ])
  assert_eq(df.get_column("f").to_scalars(), [
    @types.Scalar::Float(@double.infinity),
  ])
  // A grouped, or a prefixed, number is text.
  assert_eq(df.get_column("j").to_scalars(), [@types.Scalar::String("1_000")])
  assert_eq(df.get_column("k").to_scalars(), [@types.Scalar::String("0x10")])
  // A mixed column is text, every cell of it.
  let mixed = @io.parse_xml(
    "<r><row><v>1</v></row><row><v>x</v></row><row><v>2.5</v></row></r>",
    xpath="//row",
  )
  assert_eq(mixed.get_column("v").dtype(), @types.DataType::String)
  assert_eq(mixed.get_column("v").to_scalars(), [
    @types.Scalar::String("1"),
    @types.Scalar::String("x"),
    @types.Scalar::String("2.5"),
  ])
}

///|
test "events outside the cells change nothing: a declaration, a document type, comments, and processing instructions" {
  let text =
    #|<?xml version="1.0" encoding="UTF-8"?>
    #|<!DOCTYPE r [<!ELEMENT r ANY>]>
    #|<!-- a comment --><?php echo "hi"; ?>
    #|<r><!-- in the root --><row id="1"><?pi data?><v>x<!-- in a cell -->y</v></row></r>
    #|
  let df = @io.parse_xml(text, xpath="//row")
  assert_eq(df.get_column("id").to_scalars(), [@types.Scalar::Int(1L)])
  assert_eq(df.get_column("v").to_scalars(), [@types.Scalar::String("xy")])
}

///|
test "read_xml decodes UTF-8, UTF-16, and ISO-8859-1 documents, and a compressed file" {
  let body = "<r><row><n>café 日本語</n></row></r>"
  let declared = "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + body
  // UTF-8 with a byte-order mark.
  @fs.write_bytes_to_file(
    "_build/io_xml_bom.xml",
    b"\xEF\xBB\xBF" + @utf8.encode(declared),
  )
  assert_eq(
    @io.read_xml("_build/io_xml_bom.xml").get_column("n").to_scalars(),
    [@types.Scalar::String("café 日本語")],
  )
  // UTF-16 under its mark, either byte order, declared as UTF-16 — a short
  // document, where the declaration is checked against the text.
  let as16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + body
  for k, order in [@utf16.Endian::Little, @utf16.Endian::Big] {
    let path = "_build/io_xml_utf16_\{k}.xml"
    @fs.write_bytes_to_file(
      path,
      @utf16.encode(as16, bom=true, endianness=order),
    )
    assert_eq(@io.read_xml(path).get_column("n").to_scalars(), [
      @types.Scalar::String("café 日本語"),
    ])
    // And without the mark: a zero byte beside the `<` says which order.
    let bare = "_build/io_xml_utf16_bare_\{k}.xml"
    @fs.write_bytes_to_file(bare, @utf16.encode(as16, endianness=order))
    assert_eq(@io.read_xml(bare).shape(), (1, 1))
  }
  // ISO-8859-1, declared: one byte one character.
  let latin = @utf8.encode(
    "<?xml version='1.0' encoding='ISO-8859-1'?><r><row><n>caf",
  )
  @fs.write_bytes_to_file(
    "_build/io_xml_latin1.xml",
    latin + b"\xE9</n></row></r>",
  )
  assert_eq(
    @io.read_xml("_build/io_xml_latin1.xml").get_column("n").to_scalars(),
    [@types.Scalar::String("café")],
  )
  // A gzip file reads like its plain twin.
  let df = @io.parse_xml(declared)
  @io.write_xml(df, "_build/io_xml_roundtrip.xml.gz")
  assert_eq(@io.read_xml("_build/io_xml_roundtrip.xml.gz").shape(), (1, 1))
}

///|
test "format_xml lays a frame out as a document, and write_xml writes one that reads back" {
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_int_options("id", [Some(1), None]),
    @series.Series::from_string_options("name", [
      Some("Tom & \"Jerry\" <3>"),
      Some(""),
    ]),
    @series.Series::from_floats("price", [1.5, -0.25]),
    @series.Series::from_bools("ok", [true, false]),
  ])
  assert_eq(
    @io.format_xml(df),
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<data>\n  <row>\n    <id>1</id>\n    <name>Tom &amp; &quot;Jerry&quot; &lt;3&gt;</name>\n    <price>1.5</price>\n    <ok>true</ok>\n  </row>\n  <row>\n    <id/>\n    <name></name>\n    <price>-0.25</price>\n    <ok>false</ok>\n  </row>\n</data>\n",
  )
  // Other names for the root and the row; a date and an instant in their
  // text forms.
  let dated = @frame.DataFrame::DataFrame([
    @series.Series::from_date_options("day", [Some(0L)]),
    @series.Series::from_timestamp_options("at", [Some(61500000000L)]),
  ])
  assert_eq(
    @io.format_xml(dated, root_name="records", row_name="entry"),
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<records>\n  <entry>\n    <day>1970-01-01</day>\n    <at>1970-01-01T17:05:00.000000</at>\n  </entry>\n</records>\n",
  )
  // The file reads back as what was written, a string that was empty
  // being the one cell that changes: an empty element reads missing.
  @io.write_xml(df, "_build/io_xml_written.xml")
  let back = @io.read_xml("_build/io_xml_written.xml")
  assert_eq(back.shape(), (2, 4))
  assert_eq(back.columns(), ["id", "name", "price", "ok"])
  assert_eq(back.get_column("id").to_scalars(), [
    @types.Scalar::Int(1L),
    @types.Scalar::Null,
  ])
  assert_eq(back.get_column("name").to_scalars(), [
    @types.Scalar::String("Tom & \"Jerry\" <3>"),
    @types.Scalar::Null,
  ])
  assert_eq(back.get_column("price").to_scalars(), [
    @types.Scalar::Float(1.5),
    @types.Scalar::Float(-0.25),
  ])
  assert_eq(back.get_column("ok").to_scalars(), [
    @types.Scalar::Bool(true),
    @types.Scalar::Bool(false),
  ])
  // The same frame writes the same document.
  let again = @fs.read_file_to_string("_build/io_xml_written.xml") catch {
    _ => ""
  }
  assert_eq(again, @io.format_xml(df))
  // A frame of no row is the root alone.
  assert_eq(
    @io.format_xml(@frame.DataFrame::DataFrame([])),
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<data>\n</data>\n",
  )
}

///|
test "the XML entries raise the errors a caller meets" {
  // A document that is not well-formed names where it fails.
  let mismatch = raised(() => @io.parse_xml("<r><row><v>x</v></r>"))
  assert_eq(
    mismatch,
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "xml: InvalidSyntax(end tag mismatch: expected </row>, found </r>) at 1:17-1:20",
      ),
    ),
  )
  let unclosed = raised(() => @io.parse_xml("<r><row>"))
  assert_true(
    unclosed
    is @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "xml: InvalidSyntax(unclosed element: <row>) at 1:4-1:9",
      ),
    ),
  )
  // A path this reader does not take.
  for bad in ["", "/", "a//b", "a/", "@id", "..", ".", "a[@id='1']", "a b", "-"] {
    assert_eq(
      raised(() => @io.parse_xml("<r><row id=\"1\"/></r>", xpath=bad)),
      @types.DataError::InvalidOperation(
        "xml: the path \"\{bad}\" is not one this reader takes: element names or * separated by /, from the document element (/a/b), from the element below it (a/b), or at any depth below it (//b)",
      ),
    )
  }
  // A path that selects nothing reads as a frame of no row and no column.
  assert_eq(
    @io.parse_xml("<r><row id=\"1\"/></r>", xpath="/r/other").shape(),
    (0, 0),
  )
  assert_eq(@io.parse_xml("<r/>").shape(), (0, 0))
  // A document with nothing in it is not a document.
  assert_eq(
    raised(() => @io.parse_xml("")),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "xml: InvalidSyntax(empty document - no root element) at 1:1-1:1",
      ),
    ),
  )
  // A path that cannot be read is the read's IoError.
  let missing = raised(() => @io.read_xml("_build/no_such_xml.xml"))
  assert_true(missing is @types.DataError::IoError(_))
  // Bytes that are not UTF-8, under no other declaration.
  @fs.write_bytes_to_file(
    "_build/io_xml_bad_utf8.xml", b"<r><row>\xFF</row></r>",
  )
  assert_eq(
    raised(() => @io.read_xml("_build/io_xml_bad_utf8.xml")),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "file _build/io_xml_bad_utf8.xml is not valid UTF-8: first malformed byte at offset 8",
      ),
    ),
  )
  // UTF-16 bytes of an odd length.
  @fs.write_bytes_to_file("_build/io_xml_bad_utf16.xml", b"\xFF\xFE<")
  assert_eq(
    raised(() => @io.read_xml("_build/io_xml_bad_utf16.xml")),
    @types.DataError::ParseError(
      @types.ParseErrorDetail::Message(
        "file _build/io_xml_bad_utf16.xml is not valid UTF-16: an odd length or a lone surrogate",
      ),
    ),
  )
  // An encoding this reader does not decode, by name.
  @fs.write_bytes_to_file(
    "_build/io_xml_cp1252.xml", b"<?xml version=\"1.0\" encoding=\"windows-1252\"?><r/>",
  )
  assert_eq(
    raised(() => @io.read_xml("_build/io_xml_cp1252.xml")),
    @types.DataError::Unsupported(
      "xml: the document declares the windows-1252 encoding, which this reader does not decode",
    ),
  )
  // A name a written element cannot carry.
  let named = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("1st", [1]),
    @series.Series::from_ints("a b", [2]),
  ])
  assert_eq(
    raised(() => {
      @io.parse_xml(@io.format_xml(named, root_name="", row_name="2row"))
    }),
    @types.DataError::InvalidOperation(
      "xml: the root name \"\" is not an element name this writer carries (a letter or _, then letters, digits, _, - and .)",
    ),
  )
  let one = @frame.DataFrame::DataFrame([@series.Series::from_ints("v", [1])])
  assert_eq(
    raised(() => @io.parse_xml(@io.format_xml(one, row_name="2row"))),
    @types.DataError::InvalidOperation(
      "xml: the row name \"2row\" is not an element name this writer carries (a letter or _, then letters, digits, _, - and .)",
    ),
  )
  let unwritable = Ok(
    ignore(@io.write_xml(one, "_build/no_such_dir_z/out.xml")),
  ) catch {
    e => Err(e)
  }
  assert_true(unwritable is Err(@types.DataError::IoError(_)))
  // Columns of dtypes a document would not read back as itself.
  let nested = @frame.DataFrame::DataFrame([
    @series.Series::from_duration_options("span", [Some(5L)]),
  ])
  assert_eq(
    raised(() => @io.parse_xml(@io.format_xml(nested))),
    @types.DataError::Unsupported(
      "xml cannot carry column \"span\" of dtype Duration",
    ),
  )
}
