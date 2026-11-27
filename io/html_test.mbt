// Blackbox tests for the HTML table reader at the io layer — the
// reference implementation's documents table for table and cell for cell,
// the rows and columns a table lays out as, the text a cell holds, the
// document's markup around the tables, and the refusals a caller meets.
// (One-file-one-test exemption: none — this is the format's blackbox test
// file; the whitebox one sits beside it.)

///|
/// A scalar as a sidecar spells it — an integral `Float` as the `Int` it
/// equals, since the reference widens a column to floats when one of its
/// cells is missing, and the library keeps its integers.
fn spelled_whole(value : @types.Scalar) -> String raise {
  match value {
    Null => "Null"
    Bool(b) => "Bool \{if b { "true" } else { "false" }}"
    Int(v) => "Int \{v}"
    Float(v) =>
      if v == v.trunc() && v.abs() < 9007199254740992.0 {
        "Int \{v.to_int64()}"
      } else {
        "Float \{hex64(v.reinterpret_as_uint64())}"
      }
    String(s) => "String \{s}"
    Date(_) | Duration(_) | Timestamp(_) | Decimal(_) | List(_) | Struct(_) =>
      fail("an HTML column holds \{value.to_string()}")
  }
}

///|
/// A sidecar's column: the name the reference gave it — its levels, when
/// the header had more than one row — the dtype there, and the cells.
fn column_of(spec : Json) -> (Array[String], String, Array[String]) raise {
  let name = match field(spec, "name") {
    Array(levels) => levels.map(jstring)
    one => [jstring(one)]
  }
  let dtype = jstring(field(spec, "dtype"))
  let cells = jarray(field(spec, "cells")).map(jstring)
  (name, dtype, cells)
}

///|
/// A sidecar of the reference reader: its tables, each its columns.
fn html_sidecar(
  path : String,
) -> Array[Array[(Array[String], String, Array[String])]] raise {
  let text = @fs.read_file_to_string(path) catch { _ => fail("no \{path}") }
  let value = @json.parse(text) catch { _ => fail("\{path} is not JSON") }
  jarray(field(value, "tables")).map(table => {
    jarray(field(table, "columns")).map(column_of)
  })
}

///|
/// A hexadecimal integer as a sidecar spells one.
fn hexadecimal(text : String) -> UInt64 {
  let mut value = 0UL
  for c in text {
    let digit = if c >= '0' && c <= '9' {
      c.to_int() - 48
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 87
    } else {
      0
    }
    value = (value << 4) | digit.to_uint64()
  }
  value
}

///|
/// A sidecar cell's number: an `Int`'s or a `Float`'s value.
fn number(cell : String) -> Double {
  let payload = cell.split_once(" ").unwrap_or(("", "")).1.to_owned()
  if cell.has_prefix("Int ") {
    @text.parse_decimal_int_opt(payload).unwrap_or(0L).to_double()
  } else {
    let bits = hexadecimal(payload)
    bits.reinterpret_as_double()
  }
}

///|
/// The name a frame's column takes under the library's rule: a column the
/// reference numbered, or a header cell it found empty, is named by its
/// position, and a header's levels are joined by a space.
fn library_name(
  levels : Array[String],
  position : Int32,
  positional : Bool,
) -> String {
  if positional || levels == ["Unnamed: \{position}"] {
    "column\{position + 1}"
  } else {
    levels.join(" ")
  }
}

///|
/// One sidecar column against the frame's column.
fn check_column(
  tag : String,
  dtype : String,
  cells : Array[String],
  column : @series.Series,
) -> Unit raise {
  if column.len() != cells.length() {
    fail("\{tag}: \{column.len()} cells against \{cells.length()}")
  }
  let got = column.to_scalars()
  let mut any = false
  for cell in cells {
    if cell != "Null" {
      any = true
    }
  }
  let expected : @types.DataType = if !any {
    String
  } else if dtype.contains("int") {
    Int
  } else if dtype.contains("bool") {
    Bool
  } else if dtype.contains("float") {
    // Whole numbers the reference widened are the library's `Int`.
    let mut kind : @types.DataType = Float
    for value in got {
      match value {
        Null => ()
        Int(_) => kind = Int
        Float(_) => kind = Float
        Bool(_)
        | String(_)
        | Date(_)
        | Duration(_)
        | Timestamp(_)
        | Decimal(_)
        | List(_)
        | Struct(_) => fail("\{tag}: an HTML column holds \{value.to_string()}")
      }
    }
    kind
  } else {
    String
  }
  if column.dtype() != expected {
    fail("\{tag}: \{column.dtype()} against \{expected}")
  }
  for i, cell in cells {
    let value = got[i]
    let parts = cell.split_once(" ")
    let kind = if parts is Some((head, _)) { head.to_owned() } else { "Null" }
    let payload = if parts is Some((_, tail)) { tail.to_owned() } else { "" }
    let same = match (kind, value) {
      ("Null", Null) => true
      ("Int", Int(v)) => v.to_double() == number(cell)
      ("Float", Int(v)) => v.to_double() == number(cell)
      ("Float", Float(v)) => v == number(cell)
      ("Bool", Bool(b)) => payload == (if b { "true" } else { "false" })
      ("String", String(s)) => cell == "String \{s}"
      _ => false
    }
    if !same {
      fail("\{tag}, row \{i + 1}: \{spelled_whole(value)} against \{cell}")
    }
  }
}

///|
/// The frames a document holds, which must be exactly `count`.
fn tables_of(html : String, count : Int32) -> Array[@frame.DataFrame] raise {
  let frames = @io.parse_html(html)
  if frames.length() != count {
    fail("\{frames.length()} tables against \{count}: \{html}")
  }
  frames
}

///|
test "the reference implementation's documents read table for table, cell for cell" {
  let dir = ".github/fixtures/html"
  let mut tables = 0
  let mut compared = 0
  for file in ["plain", "spans", "several", "messy", "numbers"] {
    let expected = html_sidecar("\{dir}/\{file}.json")
    let text = @fs.read_file_to_string("\{dir}/\{file}.html") catch {
      _ => fail("no \{file}.html")
    }
    let frames = @io.parse_html(text)
    if frames.length() != expected.length() {
      fail("\{file}: \{frames.length()} tables against \{expected.length()}")
    }
    for t, columns in expected {
      let df = frames[t]
      // A table with no header has its columns numbered by the reference.
      let mut positional = columns.length() > 0
      for j, column in columns {
        if column.0 != ["\{j}"] {
          positional = false
        }
      }
      let names : Array[String] = []
      for j, column in columns {
        names.push(library_name(column.0, j, positional))
      }
      if df.columns() != names {
        fail(
          "\{file}, table \{t}: the columns \{df.columns().join(", ")} against \{names.join(", ")}",
        )
      }
      for j, column in columns {
        let tag = "\{file}, table \{t}, column \{names[j]}"
        check_column(tag, column.1, column.2, df.get_column(names[j]))
        compared += column.2.length()
      }
      tables += 1
    }
  }
  assert_eq(tables, 10)
  assert_eq(compared, 99)
}

///|
test "a table with no header names its columns by position, and a header cell left empty the same way" {
  let plain = tables_of("<table><tr><td>a</td><td>1</td></tr></table>", 1)[0]
  assert_eq(plain.columns(), ["column1", "column2"])
  assert_eq(plain.get_column("column2").to_scalars(), [@types.Scalar::Int(1L)])
  let empty = tables_of(
      "<table><tr><th></th><th>n</th></tr><tr><td>a</td><td>1</td></tr></table>",
      1,
    )[0]
  assert_eq(empty.columns(), ["column1", "n"])
  assert_eq(empty.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
  ])
  // A header that is whitespace alone is empty.
  let blank = tables_of("<table><tr><th>  </th><th>n</th></tr></table>", 1)[0]
  assert_eq(blank.columns(), ["column1", "n"])
}

///|
test "the header is the rows read in a thead, or the leading rows of header cells" {
  // A cell a td opened is a header cell inside a thead.
  let thead = tables_of(
      "<table><thead><tr><td>h</td></tr></thead><tr><td>1</td></tr></table>", 1,
    )[0]
  assert_eq(thead.columns(), ["h"])
  assert_eq(thead.get_column("h").to_scalars(), [@types.Scalar::Int(1L)])
  // A row that mixes header and data cells is data.
  let mixed = tables_of("<table><tr><th>a</th><td>b</td></tr></table>", 1)[0]
  assert_eq(mixed.columns(), ["column1", "column2"])
  assert_eq(mixed.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
  ])
  // Leading header rows name the columns, their levels joined by a space.
  let levels = tables_of(
      "<table><tr><th>x</th><th>y</th></tr><tr><th>p</th><th>q</th></tr><tr><td>1</td><td>2</td></tr></table>",
      1,
    )[0]
  assert_eq(levels.columns(), ["x p", "y q"])
  // A header alone is a table of no row.
  assert_eq(
    tables_of("<table><thead><tr><th>x</th></tr></thead></table>", 1)[0].shape(),
    (0, 1),
  )
  // A header cell after the data is data.
  let later = tables_of(
      "<table><tr><td>1</td></tr><tr><th>2</th></tr></table>", 1,
    )[0]
  assert_eq(later.shape(), (2, 1))
  assert_eq(later.get_column("column1").to_scalars(), [
    @types.Scalar::Int(1L),
    @types.Scalar::Int(2L),
  ])
  // A header cell reaching past the header names its column alone, and
  // the position it leaves beside it takes its own name.
  let reaching = tables_of(
      "<table><tr><th rowspan=\"2\">a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>",
      1,
    )[0]
  assert_eq(reaching.columns(), ["a a", "b"])
  // A header under a thead, and the data after it.
  let both = tables_of(
      "<table><thead><tr><th>a</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>",
      1,
    )[0]
  assert_eq(both.shape(), (1, 1))
}

///|
test "a cell's spans fill the grid; a span that is no number or zero is one, and a span is clamped" {
  let spans = tables_of(
      "<table><tr><td rowspan=\"2\">r</td><td>c1</td></tr><tr><td>c2</td></tr><tr><td colspan=\"2\">wide</td></tr></table>",
      1,
    )[0]
  assert_eq(spans.shape(), (3, 2))
  assert_eq(spans.get_column("column1").to_scalars(), [
    @types.Scalar::String("r"),
    @types.Scalar::String("r"),
    @types.Scalar::String("wide"),
  ])
  assert_eq(spans.get_column("column2").to_scalars(), [
    @types.Scalar::String("c1"),
    @types.Scalar::String("c2"),
    @types.Scalar::String("wide"),
  ])
  // A position a cell above still covers pushes the row's cells past it.
  let pushed = tables_of(
      "<table><tr><td rowspan=\"2\" colspan=\"2\">top</td></tr><tr><td>next</td></tr></table>",
      1,
    )[0]
  assert_eq(pushed.shape(), (2, 3))
  assert_eq(pushed.get_column("column3").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::String("next"),
  ])
  // A span reaching into a row it alone fills leaves the positions before
  // it in that row missing.
  let gap = tables_of(
      "<table><tr><td>a</td></tr><tr><td></td><td rowspan=\"2\">b</td></tr></table>",
      1,
    )[0]
  assert_eq(gap.shape(), (3, 2))
  assert_eq(gap.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::Null,
    @types.Scalar::Null,
  ])
  assert_eq(gap.get_column("column2").to_scalars(), [
    @types.Scalar::Null,
    @types.Scalar::String("b"),
    @types.Scalar::String("b"),
  ])
  // Quoted or not, a span is read; one that is no number, or zero, is one.
  let odd = tables_of(
      "<table><tr><td rowspan=abc>a</td><td rowspan='0'>b</td><td colspan=\"-2\">c</td></tr><tr><td>d</td><td>e</td></tr></table>",
      1,
    )[0]
  assert_eq(odd.shape(), (2, 3))
  assert_eq(odd.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("d"),
  ])
  // A span is clamped to what a browser clamps it to.
  let wide = tables_of("<table><tr><td colspan=\"9999\">x</td></tr></table>", 1)[0]
  assert_eq(wide.shape(), (1, 1000))
  let tall = tables_of(
      "<table><tr><td rowspan=\"70000\">x</td></tr></table>", 1,
    )[0]
  assert_eq(tall.shape(), (65534, 1))
}

///|
test "a cell's text is everything in it, decoded, its runs of whitespace folded, its ends cut" {
  let df = tables_of(
      "<table><tr>" +
      "<td>  spaced  </td>" +
      "<td>a<br>b</td>" +
      "<td><b>bold</b> <i>it</i></td>" +
      "<td>a<b>b</b>c</td>" +
      "<td>a  b</td>" +
      "<td>a\tb</td>" +
      "<td>\n    spread\n    over\n  </td>" +
      "<td>a<br>\n b</td>" +
      "<td><br>a</td>" +
      "<td>&nbsp;x&nbsp;</td>" +
      "</tr></table>",
      1,
    )[0]
  let cells : Array[@types.Scalar] = []
  for j in 1..<=10 {
    cells.push(df.get_column("column\{j}").to_scalars()[0])
  }
  assert_eq(cells, [
    @types.Scalar::String("spaced"),
    @types.Scalar::String("a b"),
    @types.Scalar::String("bold it"),
    @types.Scalar::String("abc"),
    @types.Scalar::String("a b"),
    @types.Scalar::String("a\tb"),
    @types.Scalar::String("spread  over"),
    @types.Scalar::String("a  b"),
    @types.Scalar::String("a"),
    @types.Scalar::String("x"),
  ])
}

///|
test "character references decode, and what names none stays as written" {
  let df = tables_of(
      "<table><tr>" +
      "<td>&amp;&lt;&gt;&quot;&apos;</td>" +
      "<td>&eacute;&Eacute;&ntilde;&copy;&euro;</td>" +
      "<td>&#233;&#xE9;&#XE9;&#xe9;&#65;</td>" +
      "<td>&#x1F600;&#128512;</td>" +
      "<td>&#0;&#xD800;&#x110000;&#99999999999999999999;</td>" +
      "<td>&nope;&amp;&eacute;&unknown;</td>" +
      "<td>&#;&#x;&#65 &;x</td>" +
      "<td>&aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; &Auml;</td>" +
      "</tr></table>",
      1,
    )[0]
  let cells : Array[@types.Scalar] = []
  for j in 1..<=8 {
    cells.push(df.get_column("column\{j}").to_scalars()[0])
  }
  assert_eq(cells, [
    @types.Scalar::String("&<>\"'"),
    @types.Scalar::String("éÉñ©€"),
    @types.Scalar::String("ééééA"),
    @types.Scalar::String("😀😀"),
    // A code point that is none reads as the replacement character.
    @types.Scalar::String("\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}"),
    @types.Scalar::String("&nope;&é&unknown;"),
    @types.Scalar::String("&#;&#x;&#65 &;x"),
    @types.Scalar::String("&aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; Ä"),
  ])
}

///|
test "the markup around the tables is stepped over" {
  let html =
    #|<!DOCTYPE html>
    #|<html><head><title>&lt;t&gt;</title><style>table { x: "</table>" }</style></head>
    #|<body>
    #|<!-- a table in a comment:
    #|<table><tr><td>hidden</td></tr></table>
    #|-->
    #|<?php echo "<table><tr><td>no</td></tr></table>"; ?>
    #|<p>a &lt; b, 3<4 and 5 > 2, a &notanentity; and a stray </td></tr> here</p>
    #|<script>
    #|  var t = "</td></tr></table><table><tr><td>no</td></tr></table>";
    #|</script>
    #|<div><span>text</span> <table id="t"><caption>C</caption><colgroup><col></colgroup>
    #|<tr><td>a</td><td>1</td></tr></table> after</div>
    #|<!-- never closed
    #|<table><tr><td>no</td></tr></table>
  assert_eq(tables_of(html, 1)[0].shape(), (1, 2))
  // A comment ends where the document does.
  assert_eq(
    tables_of("<table><tr><td>a</td></tr></table><!-- <table>", 1)[0].shape(),
    (1, 1),
  )
  // A tag the document ends inside is dropped; the cell keeps what came before.
  let cut = tables_of("<table><tr><td>a<td colspan=\"2", 1)[0]
  assert_eq(cut.shape(), (1, 1))
  assert_eq(cut.get_column("column1").to_scalars(), [@types.Scalar::String("a")])
  // A `<` that opens no markup is a character.
  let bare = tables_of(
      "<table><tr><td>a < b</td><td>a <3 b</td><td></td>x</tr></table>", 1,
    )[0]
  assert_eq(bare.get_column("column1").to_scalars(), [
    @types.Scalar::String("a < b"),
  ])
  assert_eq(bare.get_column("column2").to_scalars(), [
    @types.Scalar::String("a <3 b"),
  ])
  // A script's text runs to its end tag; with none, to the end of the
  // document.
  let script = tables_of(
      "<table><tr><td>a<script>var x = 1;</script>b</td></tr></table>", 1,
    )[0]
  assert_eq(script.get_column("column1").to_scalars(), [
    @types.Scalar::String("ab"),
  ])
  let swallowed = tables_of(
    "<table><tr><td>a</td></tr></table><script>var t = 1;", 1,
  )
  assert_eq(swallowed[0].shape(), (1, 1))
  let upper = tables_of(
      "<table><tr><td>a</td><SCRIPT>x</SCRIPT><STYLE>y</STYLE></tr></table>", 1,
    )[0]
  assert_eq(upper.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
  ])
  // A construct the document ends inside is stepped over to the end; an end
  // tag with no name is a character.
  assert_eq(
    tables_of("<table><tr><td>a</td></tr></table><!DOCTYPE html", 1)[0].shape(),
    (1, 1),
  )
  assert_eq(
    tables_of("<table><tr><td>a</td></tr></table></tr", 1)[0].shape(),
    (1, 1),
  )
  let nameless = tables_of("<table><tr><td>a</td></tr></table></><td>x</td>", 1)[0]
  assert_eq(nameless.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
  ])
  // Attributes are stepped over whatever quotes they carry, a nameless one
  // too, and a self-closing slash.
  let attrs = tables_of(
      "<table data-x=\"a>b\" data-y='c' data-z=d \"q\" =v><tr><td colspan = \"2\" >a</td><td/><td/></tr></table>",
      1,
    )[0]
  assert_eq(attrs.shape(), (1, 4))
  // A space before a tag closes, and a value with no quotes that a `>`
  // or another attribute ends.
  let spaced = tables_of(
      "<table ><tr><td  colspan = 2 >a</td><td data-x = y data-w>z</td></tr></table>",
      1,
    )[0]
  assert_eq(spaced.shape(), (1, 3))
}

///|
test "every table is a frame in document order, a nested one after the one holding it" {
  let frames = tables_of(
    "<div><table><tr><th>outer</th></tr><tr><td>before <table><tr><td>mid <table><tr><td>deep</td></tr></table> after</td></tr></table> end</td></tr></table><p>x</p><table><tr><td>last</td></tr></table></div>",
    4,
  )
  assert_eq(frames[0].columns(), ["outer"])
  assert_eq(frames[0].get_column("outer").to_scalars(), [
    @types.Scalar::String("before mid deep after end"),
  ])
  assert_eq(frames[1].get_column("column1").to_scalars(), [
    @types.Scalar::String("mid deep after"),
  ])
  assert_eq(frames[2].get_column("column1").to_scalars(), [
    @types.Scalar::String("deep"),
  ])
  assert_eq(frames[3].get_column("column1").to_scalars(), [
    @types.Scalar::String("last"),
  ])
  // Text around a table is nobody's cell.
  let around = tables_of("a<table><tr><td>b</td></tr></table>c", 1)[0]
  assert_eq(around.get_column("column1").to_scalars(), [
    @types.Scalar::String("b"),
  ])
}

///|
test "a row or cell still open ends where the next one starts, and a table still open ends with the document" {
  let implicit = tables_of("<table><tr><td>a<td>b<tr><td>c</table>", 1)[0]
  assert_eq(implicit.shape(), (2, 2))
  assert_eq(implicit.get_column("column2").to_scalars(), [
    @types.Scalar::String("b"),
    @types.Scalar::Null,
  ])
  // Upper-case tags, header cells without ends, a row without an end.
  let upper = tables_of("<TABLE><TR><TH>a<TH>b</TR><TR><TD>1", 1)[0]
  assert_eq(upper.columns(), ["a", "b"])
  assert_eq(upper.get_column("a").to_scalars(), [@types.Scalar::Int(1L)])
  assert_eq(upper.get_column("b").to_scalars(), [@types.Scalar::Null])
  // End tags with nothing to end, a cell outside every table, a table of
  // no row, and a table closed twice.
  assert_eq(@io.parse_html("</table></tr></td><td>x</td></table>").length(), 0)
  assert_eq(
    @io.parse_html("<table></table><table><tbody></tbody></table>").length(),
    0,
  )
  assert_eq(
    tables_of("<table><tr><td>a</td></tr></table></table>", 1)[0].shape(),
    (1, 1),
  )
  // A nested table closed by the outer one's end tag.
  let nested = tables_of("<table><tr><td>a<table><tr><td>b", 2)
  assert_eq(nested[0].get_column("column1").to_scalars(), [
    @types.Scalar::String("ab"),
  ])
  assert_eq(nested[1].get_column("column1").to_scalars(), [
    @types.Scalar::String("b"),
  ])
  // Row groups end where the next begins.
  let groups = tables_of(
      "<table><thead><tr><th>h</th></tr><tbody><tr><td>1</td></tr><tfoot><tr><td>2</td></tr></table>",
      1,
    )[0]
  assert_eq(groups.shape(), (2, 1))
  assert_eq(groups.get_column("h").to_scalars(), [
    @types.Scalar::Int(1L),
    @types.Scalar::Int(2L),
  ])
}

///|
test "a cell outside any row opens one, a short row reads missing past its cells, and a foot is data" {
  assert_eq(
    tables_of("<table><td>a</td><td>b</td><td>c</td></table>", 1)[0].shape(),
    (1, 3),
  )
  let ragged = tables_of(
      "<table><tr><td>a</td><td>b</td><td>c</td></tr><tr><td>1</td></tr></table>",
      1,
    )[0]
  assert_eq(ragged.shape(), (2, 3))
  assert_eq(ragged.get_column("column3").to_scalars(), [
    @types.Scalar::String("c"),
    @types.Scalar::Null,
  ])
  let foot = tables_of(
      "<table><tr><td>a</td></tr><tfoot><tr><td>f</td></tr></tfoot></table>", 1,
    )[0]
  assert_eq(foot.get_column("column1").to_scalars(), [
    @types.Scalar::String("a"),
    @types.Scalar::String("f"),
  ])
  // A row of no cell is a row of nothing.
  assert_eq(tables_of("<table><tr></tr></table>", 1)[0].shape(), (1, 0))
}

///|
test "a cell spelling a missing value reads missing, a number with commas reads as that number" {
  let missing = tables_of(
      "<table><tr><td>NA</td><td>N/A</td><td>n/a</td><td>NULL</td><td>null</td><td>None</td><td>NaN</td><td>nan</td><td>-NaN</td><td>-nan</td><td>&lt;NA&gt;</td><td>#NA</td><td>#N/A</td><td>#N/A N/A</td><td>1.#IND</td><td>-1.#IND</td><td>1.#QNAN</td><td>-1.#QNAN</td><td></td><td>na</td><td>-</td></tr></table>",
      1,
    )[0]
  for j in 1..<=19 {
    assert_eq(missing.get_column("column\{j}").to_scalars(), [
      @types.Scalar::Null,
    ])
  }
  assert_eq(missing.get_column("column20").to_scalars(), [
    @types.Scalar::String("na"),
  ])
  assert_eq(missing.get_column("column21").to_scalars(), [
    @types.Scalar::String("-"),
  ])
  let numbers = tables_of(
      "<table>" +
      "<tr><td>1,234,567</td><td>12,34</td><td>1,2345</td><td>-1,234</td><td>+1,234.5</td><td>123,</td></tr>" +
      "<tr><td>1,,234</td><td>,123</td><td>1e1,5</td><td>(1,234)</td><td>1,234%</td><td>a,1</td></tr>" +
      "</table>",
      1,
    )[0]
  assert_eq(numbers.get_column("column1").to_scalars(), [
    @types.Scalar::String("1,234,567"),
    @types.Scalar::String("1,,234"),
  ])
  assert_eq(numbers.get_column("column2").to_scalars(), [
    @types.Scalar::String("12,34"),
    @types.Scalar::String(",123"),
  ])
  assert_eq(numbers.get_column("column3").to_scalars(), [
    @types.Scalar::String("1,2345"),
    @types.Scalar::String("1e1,5"),
  ])
  assert_eq(numbers.get_column("column4").to_scalars(), [
    @types.Scalar::String("-1,234"),
    @types.Scalar::String("(1,234)"),
  ])
  assert_eq(numbers.get_column("column5").to_scalars(), [
    @types.Scalar::String("+1,234.5"),
    @types.Scalar::String("1,234%"),
  ])
  assert_eq(numbers.get_column("column6").to_scalars(), [
    @types.Scalar::String("123,"),
    @types.Scalar::String("a,1"),
  ])
}

///|
test "a column takes the narrowest dtype holding its values, the CSV reader's rule" {
  let df = tables_of(
      "<table>" +
      "<tr><td>1</td><td>1.0</td><td>TRUE</td><td>tRue</td><td>inf</td><td>007</td><td>0x1F</td><td>1_000</td><td>yes</td><td>2024-01-02</td></tr>" +
      "<tr><td>2.5</td><td>2</td><td>false</td><td>FALSE</td><td>1</td><td>008</td><td>2</td><td>2</td><td>no</td><td>2024-03-04</td></tr>" +
      "</table>",
      1,
    )[0]
  let dtypes = df.column_series().map(column => column.dtype())
  assert_eq(dtypes, [
    @types.DataType::Float,
    @types.DataType::Float,
    @types.DataType::Bool,
    @types.DataType::Bool,
    @types.DataType::Float,
    @types.DataType::Int,
    @types.DataType::String,
    @types.DataType::String,
    @types.DataType::String,
    @types.DataType::String,
  ])
  assert_eq(df.get_column("column5").to_scalars(), [
    @types.Scalar::Float(@double.infinity),
    @types.Scalar::Float(1.0),
  ])
  assert_eq(df.get_column("column6").to_scalars(), [
    @types.Scalar::Int(7L),
    @types.Scalar::Int(8L),
  ])
}

///|
test "a table's grid is bounded: a span past the positions it may hold refuses" {
  let outcome : Result[Array[@frame.DataFrame], @types.DataError] = Ok(
    @io.parse_html(
      "<table><tr><td rowspan=\"65534\" colspan=\"1000\">x</td></tr></table>",
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    outcome,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "html: a table's cell spans past the 33554432 positions a table's grid may hold",
        ),
      ),
    ),
  )
}

///|
test "read_html reads a file and a compressed one, and the entries raise the errors a caller meets" {
  let html = "<table><tr><th>a</th></tr><tr><td>1</td></tr></table>"
  @fs.write_bytes_to_file("_build/io_html_plain.html", @utf8.encode(html))
  assert_eq(@io.read_html("_build/io_html_plain.html")[0].shape(), (1, 1))
  @fs.write_bytes_to_file(
    "_build/io_html_plain.html.gz",
    @gzip.compress(@utf8.encode(html)),
  )
  assert_eq(@io.read_html("_build/io_html_plain.html.gz")[0].shape(), (1, 1))
  // A document with no table is no frame; so is no document.
  assert_eq(@io.parse_html("<p>nothing</p>").length(), 0)
  assert_eq(@io.parse_html("").length(), 0)
  // A path that cannot be read.
  let missing : Result[Array[@frame.DataFrame], @types.DataError] = Ok(
    @io.read_html("_build/no_such_html.html"),
  ) catch {
    e => Err(e)
  }
  assert_true(missing is Err(@types.DataError::IoError(_)))
  // Bytes that are not UTF-8.
  @fs.write_bytes_to_file(
    "_build/io_html_bad.html", b"<table><tr><td>\xFF</td>",
  )
  let bad : Result[Array[@frame.DataFrame], @types.DataError] = Ok(
    @io.read_html("_build/io_html_bad.html"),
  ) catch {
    e => Err(e)
  }
  assert_eq(
    bad,
    Err(
      @types.DataError::ParseError(
        @types.ParseErrorDetail::Message(
          "file _build/io_html_bad.html is not valid UTF-8: first malformed byte at offset 15",
        ),
      ),
    ),
  )
  // A header naming one column twice.
  let twice : Result[Array[@frame.DataFrame], @types.DataError] = Ok(
    @io.parse_html("<table><tr><th>a</th><th>a</th></tr></table>"),
  ) catch {
    e => Err(e)
  }
  assert_eq(twice, Err(@types.DataError::DuplicateColumn("a")))
}
