// The differential test against the Arrow integration goldens: every
// vendored sample is read through the public entry, and each of its
// columns is compared cell for cell with what the sample's JSON golden
// spells — the test computing the expected cells from the golden by the
// reader's documented mapping, independently of the reader's code. A
// column whose golden values the mapping cannot hold is expected to
// refuse, naming the reason. A sample vendored in both framings is read
// through each.

///|
/// Where the vendored samples live, from the project root.
const FIXTURES : String = ".github/fixtures/arrow-ipc"

///|
/// One field of a golden's schema: the name its field carries, its Arrow
/// type as the golden spells it, and its children.
struct GoldenType {
  field : String
  name : String
  bit_width : Int32
  signed : Bool
  precision : String
  scale : Int32
  unit : String
  list_size : Int32
  dictionary_id : Int64
  children : Array[GoldenType]
}

///|
/// One column of a golden batch: its cells' validity, values, and
/// offsets, and its children's.
struct GoldenColumn {
  count : Int32
  validity : Array[Int32]
  data : Array[Json]
  offset : Array[Int64]
  children : Array[GoldenColumn]
}

///|
/// A golden: its schema, its batches, and its dictionaries — each id's
/// cells, the batches of one id joined in the order the golden lists
/// them.
struct Golden {
  types : Array[GoldenType]
  batches : Array[Array[GoldenColumn]]
  dictionary_ids : Array[Int64]
  dictionary_cells : Array[Array[@types.Scalar]]
}

///|
/// What a golden column must read as: its cells, or the reason its column
/// refuses.
type Expected = Result[Array[@types.Scalar], String]

// ── the golden's JSON ─────────────────────────────────────────────────

///|
/// The JSON value at a key of an object, JSON null when the key is
/// absent.
fn golden_at(j : Json, key : String) -> Json {
  match j {
    Object(fields) =>
      match fields.get(key) {
        Some(v) => v
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
fn golden_text(j : Json) -> String {
  match j {
    String(text) => text
    _ => ""
  }
}

///|
fn golden_array(j : Json) -> Array[Json] {
  match j {
    Array(items) => items
    _ => []
  }
}

///|
fn golden_small_int(j : Json) -> Int32 {
  match j {
    Number(n, ..) => n.to_int()
    _ => 0
  }
}

///|
/// An integer's value — a golden spells a large one as its digits.
fn golden_int(j : Json) -> Int64? {
  let text = match j {
    Number(_, repr=Some(digits)) => digits
    String(text) => text
    Number(n, repr=None) =>
      if n == n.trunc() && n < 9.2e18 && n > -9.2e18 {
        return Some(n.to_int64())
      } else {
        return None
      }
    _ => return None
  }
  let negative = text.has_prefix("-")
  let digits = if negative { text[1:].to_owned() } else { text }
  if digits.length() == 0 {
    return None
  }
  let mut value = 0L
  for i in 0..<digits.length() {
    let digit = digits[i].to_int() - 48
    if digit < 0 || digit > 9 || value > 922337203685477580L {
      return None
    }
    value = value * 10L + digit.to_int64()
  }
  if negative {
    Some(-value)
  } else {
    Some(value)
  }
}

///|
/// A golden float: a number, or the text of a value JSON has no literal
/// for.
fn golden_float(j : Json) -> Double {
  match j {
    Number(n, ..) => n
    String("NaN") => 0.0 / 0.0
    String("Infinity") => 1.0 / 0.0
    String("-Infinity") => -1.0 / 0.0
    _ => 0.0
  }
}

///|
/// The bytes a golden's hexadecimal cell spells, or `None` when the text
/// is not an even number of hexadecimal digits.
fn golden_bytes(text : String) -> Bytes? {
  if text.length() % 2 != 0 {
    return None
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < text.length() {
    let byte = match
      (hex_digit(text[i].to_int()), hex_digit(text[i + 1].to_int())) {
      (Some(high), Some(low)) => high * 16 + low
      _ => return None
    }
    out.push(byte.to_byte())
    i += 2
  }
  Some(Bytes::from_array(out))
}

///|
fn hex_digit(unit : Int32) -> Int32? {
  if unit >= 48 && unit <= 57 {
    Some(unit - 48)
  } else if unit >= 65 && unit <= 70 {
    Some(unit - 55)
  } else if unit >= 97 && unit <= 102 {
    Some(unit - 87)
  } else {
    None
  }
}

///|
fn golden_type(field : String, j : Json) -> GoldenType {
  let type_json = golden_at(j, "type")
  let children : Array[GoldenType] = []
  for child in golden_array(golden_at(j, "children")) {
    children.push(golden_type(golden_text(golden_at(child, "name")), child))
  }
  {
    field,
    name: golden_text(golden_at(type_json, "name")),
    bit_width: golden_small_int(golden_at(type_json, "bitWidth")),
    signed: golden_at(type_json, "isSigned") is True,
    precision: golden_text(golden_at(type_json, "precision")),
    scale: golden_small_int(golden_at(type_json, "scale")),
    unit: golden_text(golden_at(type_json, "unit")),
    list_size: golden_small_int(golden_at(type_json, "listSize")),
    dictionary_id: match
      golden_int(golden_at(golden_at(j, "dictionary"), "id")) {
      Some(v) => v
      None => -1L
    },
    children,
  }
}

///|
fn golden_column(j : Json) -> GoldenColumn {
  let validity : Array[Int32] = []
  for v in golden_array(golden_at(j, "VALIDITY")) {
    validity.push(golden_small_int(v))
  }
  let offset : Array[Int64] = []
  for v in golden_array(golden_at(j, "OFFSET")) {
    match golden_int(v) {
      Some(n) => offset.push(n)
      None => ()
    }
  }
  let children : Array[GoldenColumn] = []
  for child in golden_array(golden_at(j, "children")) {
    children.push(golden_column(child))
  }
  {
    count: golden_small_int(golden_at(j, "count")),
    validity,
    data: golden_array(golden_at(j, "DATA")),
    offset,
    children,
  }
}

///|
/// The first field encoded against dictionary `id`, at any depth.
fn golden_encoded(types : Array[GoldenType], id : Int64) -> GoldenType? {
  for t in types {
    if t.dictionary_id == id {
      return Some(t)
    }
    match golden_encoded(t.children, id) {
      Some(found) => return Some(found)
      None => ()
    }
  }
  None
}

// ── the expected cells ────────────────────────────────────────────────

///|
/// Whether row `i` of a golden column is present: a golden leaves the
/// validity out when every cell is.
fn present(col : GoldenColumn, i : Int32) -> Bool {
  col.validity.is_empty() || (i < col.validity.length() && col.validity[i] == 1)
}

///|
/// The cells a golden column must read as, by the reader's mapping, or
/// the reason its column refuses.
fn golden_cells(
  t : GoldenType,
  col : GoldenColumn,
  golden : Golden,
) -> Expected {
  // An encoded field's cells are its dictionary's values, indexed.
  if t.dictionary_id >= 0L {
    let values : Array[@types.Scalar] = []
    let mut known = false
    for d, id in golden.dictionary_ids {
      if id == t.dictionary_id {
        known = true
        for value in golden.dictionary_cells[d] {
          values.push(value)
        }
      }
    }
    if !known {
      return Err("dictionary \{t.dictionary_id}")
    }
    let cells : Array[@types.Scalar] = []
    for i in 0..<col.count {
      if !present(col, i) {
        cells.push(@types.Scalar::Null)
        continue
      }
      match golden_int(col.data[i]) {
        Some(index) =>
          if index < 0L || index >= values.length().to_int64() {
            return Err("past its dictionary")
          } else {
            cells.push(values[index.to_int()])
          }
        None => return Err("unreadable")
      }
    }
    return Ok(cells)
  }
  // A union spells its cells by type ids and children, which no leaf
  // reads: the column refuses by its name.
  if t.name == "union" {
    return Err("union")
  }
  if t.name == "list" ||
    t.name == "largelist" ||
    t.name == "fixedsizelist" ||
    t.name == "map" {
    if t.children.is_empty() || col.children.is_empty() {
      return Err("unreadable")
    }
    let element = match golden_cells(t.children[0], col.children[0], golden) {
      Ok(cells) => cells
      Err(reason) => return Err(reason)
    }
    let cells : Array[@types.Scalar] = []
    for i in 0..<col.count {
      if present(col, i) {
        let (from, to) = if t.name == "fixedsizelist" {
          (i * t.list_size, (i + 1) * t.list_size)
        } else if i + 1 < col.offset.length() {
          (col.offset[i].to_int(), col.offset[i + 1].to_int())
        } else {
          return Err("unreadable")
        }
        if from < 0 || to < from || to > element.length() {
          return Err("unreadable")
        }
        cells.push(
          @types.Scalar::List(
            @types.ListValue::ListValue(element[from:to].to_owned()),
          ),
        )
      } else {
        cells.push(@types.Scalar::Null)
      }
    }
    return Ok(cells)
  }
  if t.name == "struct" {
    // Two fields of one name spell no struct dtype.
    let names : Array[String] = []
    for child in t.children {
      if names.contains(child.field) {
        return Err("field names repeat")
      }
      names.push(child.field)
    }
    let children : Array[Array[@types.Scalar]] = []
    for c, child in t.children {
      if c >= col.children.length() {
        return Err("unreadable")
      }
      match golden_cells(child, col.children[c], golden) {
        Ok(cells) => children.push(cells)
        Err(reason) => return Err(reason)
      }
    }
    let cells : Array[@types.Scalar] = []
    for i in 0..<col.count {
      if present(col, i) {
        let fields : Array[@types.FieldValue] = []
        for c, child in t.children {
          fields.push(
            @types.FieldValue::FieldValue(child.field, children[c][i]),
          )
        }
        cells.push(
          @types.Scalar::Struct(@types.StructValue::StructValue(fields)),
        )
      } else {
        cells.push(@types.Scalar::Null)
      }
    }
    return Ok(cells)
  }
  let cells : Array[@types.Scalar] = []
  for i in 0..<col.count {
    // A null column spells no values at all: every cell is null.
    if !present(col, i) || t.name == "null" {
      cells.push(@types.Scalar::Null)
      continue
    }
    if i >= col.data.length() {
      return Err("unreadable")
    }
    match leaf_cell(t, col.data[i]) {
      Ok(cell) => cells.push(cell)
      Err(reason) => return Err(reason)
    }
  }
  Ok(cells)
}

///|
/// One present cell of a leaf column, by the reader's mapping.
fn leaf_cell(t : GoldenType, value : Json) -> Result[@types.Scalar, String] {
  if t.name == "null" {
    return Ok(@types.Scalar::Null)
  }
  if t.name == "int" {
    let v = match golden_int(value) {
      Some(v) => v
      None => return Err("unreadable")
    }
    if !t.signed && v < 0L {
      return Err("past Int64's range")
    }
    return Ok(@types.Scalar::Int(v))
  }
  if t.name == "floatingpoint" {
    if t.precision == "HALF" {
      return Err("Float16")
    }
    return Ok(@types.Scalar::Float(golden_float(value)))
  }
  if t.name == "bool" {
    return Ok(@types.Scalar::Bool(value is True))
  }
  if t.name == "utf8" || t.name == "largeutf8" {
    return Ok(@types.Scalar::String(golden_text(value)))
  }
  if t.name == "binary" ||
    t.name == "largebinary" ||
    t.name == "fixedsizebinary" {
    let bytes = match golden_bytes(golden_text(value)) {
      Some(b) => b
      None => return Err("unreadable")
    }
    let text = @utf8.decode(bytes) catch { _ => return Err("utf8:not UTF-8") }
    return Ok(@types.Scalar::String(text))
  }
  if t.name == "decimal" {
    if t.bit_width == 256 {
      return Err("Decimal256")
    }
    return golden_decimal(golden_text(value), t.scale)
  }
  if t.name == "date" {
    let v = match golden_int(value) {
      Some(v) => v
      None => return Err("unreadable")
    }
    if t.unit == "DAY" {
      return Ok(@types.Scalar::Date(v))
    }
    if v > 9223372036854775L || v < -9223372036854775L {
      return Err("microsecond count reaches")
    }
    return Ok(@types.Scalar::Timestamp(v * 1000L))
  }
  if t.name == "time" {
    return Err("time")
  }
  if t.name == "timestamp" || t.name == "duration" {
    let v = match golden_int(value) {
      Some(v) => v
      None => return Err("unreadable")
    }
    let micros = if t.unit == "SECOND" {
      if v > 9223372036854L || v < -9223372036854L {
        return Err("microsecond count reaches")
      }
      v * 1000000L
    } else if t.unit == "MILLISECOND" {
      if v > 9223372036854775L || v < -9223372036854775L {
        return Err("microsecond count reaches")
      }
      v * 1000L
    } else if t.unit == "MICROSECOND" {
      v
    } else if v % 1000L == 0L {
      v / 1000L
    } else {
      return Err("nanosecond")
    }
    if t.name == "timestamp" {
      return Ok(@types.Scalar::Timestamp(micros))
    }
    return Ok(@types.Scalar::Duration(micros))
  }
  if t.name == "interval" {
    return Err("interval")
  }
  Err(t.name)
}

///|
/// The decimal a golden's unscaled digits spell at a scale: the digits
/// without their leading and trailing zeros as the coefficient, the
/// trailing zeros folded into the exponent.
fn golden_decimal(
  digits : String,
  scale : Int32,
) -> Result[@types.Scalar, String] {
  let negative = digits.has_prefix("-")
  let magnitude = if negative { digits[1:].to_owned() } else { digits }
  let mut start = 0
  while start < magnitude.length() - 1 && magnitude[start] == '0' {
    start += 1
  }
  let trimmed = magnitude[start:].to_owned()
  let mut end = trimmed.length()
  while end > 1 && trimmed[end - 1] == '0' {
    end -= 1
  }
  let coefficient = trimmed[:end].to_owned()
  if coefficient.length() > 34 {
    return Err("significant digits")
  }
  let exponent = trimmed.length() - end - scale
  let sign = if negative && coefficient != "0" { "-" } else { "" }
  match @types.Dec128::parse_opt("\{sign}\{coefficient}E\{exponent}") {
    Some(v) => Ok(@types.Scalar::Decimal(v))
    None => Err("scale")
  }
}

// ── the comparison ────────────────────────────────────────────────────

///|
/// The refusal a mismatching comparison raises: a golden's column did not
/// read as the golden spells it.
fn mismatch(what : String) -> @types.DataError {
  @types.DataError::InvalidOperation("the golden disagrees: \{what}")
}

///|
/// Whether two cells read the same: a float's golden carries its value to
/// the digits the golden prints, so a float compares within that
/// rounding; everything else compares exactly.
fn cells_match(
  want : @types.Scalar,
  got : @types.Scalar,
) -> Bool raise @types.DataError {
  match (want, got) {
    (@types.Scalar::Float(a), @types.Scalar::Float(b)) =>
      (a.is_nan() && b.is_nan()) ||
      (
        !a.is_nan() &&
        !b.is_nan() &&
        (a == b || (a - b).abs() <= 0.000000001 + b.abs() * 0.00001)
      )
    (@types.Scalar::List(a), @types.Scalar::List(b)) => lists_match(a, b)
    (@types.Scalar::Struct(a), @types.Scalar::Struct(b)) => structs_match(a, b)
    (@types.Scalar::Null, @types.Scalar::Null) => true
    (x, y) => x == y
  }
}

///|
fn lists_match(
  want : @types.ListValue,
  got : @types.ListValue,
) -> Bool raise @types.DataError {
  if want.len() != got.len() {
    return false
  }
  for i in 0..<want.len() {
    if !cells_match(want.get(i), got.get(i)) {
      return false
    }
  }
  true
}

///|
fn structs_match(
  want : @types.StructValue,
  got : @types.StructValue,
) -> Bool raise @types.DataError {
  if want.len() != got.len() {
    return false
  }
  let wanted = want.fields()
  let gotten = got.fields()
  for i in 0..<wanted.length() {
    if wanted[i].name() != gotten[i].name() ||
      !cells_match(wanted[i].value(), gotten[i].value()) {
      return false
    }
  }
  true
}

///|
/// Whether every cell of a column reads as the golden spells it; the
/// first that does not is named.
fn column_matches(
  label : String,
  want : Array[@types.Scalar],
  got : Array[@types.Scalar],
) -> Unit raise @types.DataError {
  if want.length() != got.length() {
    raise mismatch(
      "\{label}: \{got.length()} cells where the golden spells \{want.length()}",
    )
  }
  for i in 0..<want.length() {
    if !cells_match(want[i], got[i]) {
      raise mismatch(
        "\{label}: cell \{i + 1} reads \{got[i]} where the golden spells \{want[i]}",
      )
    }
  }
}

// ── the driver ────────────────────────────────────────────────────────

///|
/// A sample's JSON golden, read and decompressed; its dictionaries are
/// the cells their batches carried, each id's joined in the order the
/// golden lists them.
fn load_golden(path : String) -> Golden raise @types.DataError {
  let compressed = @fs.read_file_to_bytes(path) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  let text = @utf8.decode(@gzip.decompress(compressed)) catch {
    _ =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message("the golden \{path} is not text"),
      )
  }
  let doc = @json.parse(text) catch {
    _ =>
      raise @types.DataError::ParseError(
        @types.ParseErrorDetail::Message("the golden \{path} is not JSON"),
      )
  }
  let types : Array[GoldenType] = []
  for field in golden_array(golden_at(golden_at(doc, "schema"), "fields")) {
    types.push(golden_type(golden_text(golden_at(field, "name")), field))
  }
  let batches : Array[Array[GoldenColumn]] = []
  for batch in golden_array(golden_at(doc, "batches")) {
    let columns : Array[GoldenColumn] = []
    for column in golden_array(golden_at(batch, "columns")) {
      columns.push(golden_column(column))
    }
    batches.push(columns)
  }
  let dictionary_ids : Array[Int64] = []
  let dictionary_cells : Array[Array[@types.Scalar]] = []
  let golden = Golden::{ types, batches, dictionary_ids, dictionary_cells, }
  for dictionary in golden_array(golden_at(doc, "dictionaries")) {
    let id = match golden_int(golden_at(dictionary, "id")) {
      Some(v) => v
      None => 0L
    }
    let columns = golden_array(
      golden_at(golden_at(dictionary, "data"), "columns"),
    )
    // A dictionary's values are its field's values, read as the field's
    // type spells them without the encoding.
    let value_type = match golden_encoded(types, id) {
      Some(t) => GoldenType::{ ..t, dictionary_id: -1L, }
      None =>
        raise @types.DataError::ParseError(
          @types.ParseErrorDetail::Message(
            "the golden \{path} names a dictionary no field is encoded against",
          ),
        )
    }
    if columns.is_empty() {
      continue
    }
    match golden_cells(value_type, golden_column(columns[0]), golden) {
      Ok(cells) => {
        dictionary_ids.push(id)
        dictionary_cells.push(cells)
      }
      Err(reason) =>
        raise mismatch(
          "the golden \{path} spells dictionary \{id} as cells the mapping refuses: \{reason}",
        )
    }
  }
  golden
}

///|
/// Whether an error is the refusal a reason asks for: a reason under
/// `utf8:` is a malformed payload's `ParseError`, and every other is an
/// `Unsupported` — each naming the reason in its message.
fn refusal_names(reason : String, e : @types.DataError) -> Bool {
  if reason.has_prefix("utf8:") {
    e is ParseError(Message(message)) && message.contains(reason[5:].to_owned())
  } else {
    e is Unsupported(message) && message.contains(reason)
  }
}

///|
/// A cell with every struct field renamed to its position. A payload
/// spells a map entry's fields by Arrow's own names (`key` and `value`)
/// where the golden keeps the names the sample was written with, so a
/// map column compares without them.
fn unnamed(cell : @types.Scalar) -> @types.Scalar raise @types.DataError {
  if cell is Struct(value) {
    let fields : Array[@types.FieldValue] = []
    for i, field in value.fields() {
      fields.push(
        @types.FieldValue::FieldValue(i.to_string(), unnamed(field.value())),
      )
    }
    return @types.Scalar::Struct(@types.StructValue::StructValue(fields))
  }
  if cell is List(value) {
    let cells : Array[@types.Scalar] = []
    for item in value.cells() {
      cells.push(unnamed(item))
    }
    return @types.Scalar::List(@types.ListValue::ListValue(cells))
  }
  cell
}

///|
/// What one column of a payload must read as over every batch: the
/// golden's cells joined, or the reason the column refuses.
fn expected_cells(golden : Golden, index : Int32) -> Expected {
  let cells : Array[@types.Scalar] = []
  for batch in golden.batches {
    if index >= batch.length() {
      return Err("unreadable")
    }
    match golden_cells(golden.types[index], batch[index], golden) {
      Ok(more) =>
        for cell in more {
          cells.push(cell)
        }
      Err(reason) => return Err(reason)
    }
  }
  Ok(cells)
}

///|
/// One payload against its golden, column for column: a column the golden
/// spells as cells the mapping holds reads as them, and one it spells as
/// cells it cannot hold refuses, naming the reason.
fn check_payload(
  golden : Golden,
  bytes : Bytes,
  label : String,
) -> Unit raise @types.DataError {
  for index, t in golden.types {
    let column = "\{label}, column \{index + 1} (\"\{t.field}\")"
    // Two fields of one name: a read by that name chooses both, and the
    // frame refuses the second.
    let mut repeats = 0
    for other in golden.types {
      if other.field == t.field {
        repeats += 1
      }
    }
    if repeats > 1 {
      let both : Result[@frame.DataFrame, @types.DataError] = Ok(
        @io.parse_ipc(bytes, projection=[t.field]),
      ) catch {
        e => Err(e)
      }
      // A repeated name refuses at the schema — or a type with no dtype
      // refuses first, as it is also met at the schema.
      let by_name = both is Err(@types.DataError::DuplicateColumn(name)) &&
        name == t.field
      let by_type = match (expected_cells(golden, index), both) {
        (Err(reason), Err(e)) => refusal_names(reason, e)
        _ => false
      }
      if by_name || by_type {
        continue
      }
      raise mismatch(
        "\{column}: expected a DuplicateColumn for a name the payload repeats",
      )
    }
    let read : Result[@series.Series, @types.DataError] = Ok(
      @io.parse_ipc(bytes, projection=[t.field]).get_column(t.field),
    ) catch {
      e => Err(e)
    }
    match (expected_cells(golden, index), read) {
      (Err(reason), Err(e)) =>
        if refusal_names(reason, e) {
          ()
        } else {
          raise mismatch(
            "\{column}: expected an Unsupported naming \{reason}, got \{e}",
          )
        }
      (Ok(cells), Ok(series)) =>
        if t.name == "map" {
          let want : Array[@types.Scalar] = []
          for cell in cells {
            want.push(unnamed(cell))
          }
          let got : Array[@types.Scalar] = []
          for cell in series.to_scalars() {
            got.push(unnamed(cell))
          }
          column_matches(column, want, got)
        } else {
          column_matches(column, cells, series.to_scalars())
        }
      (Err(reason), Ok(series)) =>
        raise mismatch(
          "\{column}: reads \{series.len()} cells where the golden's values refuse (\{reason})",
        )
      (Ok(cells), Err(e)) =>
        raise mismatch(
          "\{column}: refuses (\{e}) where the golden spells \{cells.length()} cells",
        )
    }
  }
}

///|
/// One sample, read through every framing it is vendored in.
fn check_sample(
  version : String,
  sample : String,
) -> Unit raise @types.DataError {
  let base = "\{FIXTURES}/\{version}/generated_\{sample}"
  let golden = load_golden("\{base}.json.gz")
  let stream : Result[Bytes, @types.DataError] = Ok(
    @fs.read_file_to_bytes("\{base}.stream"),
  ) catch {
    @fs.IOError(msg) => Err(@types.DataError::IoError(msg))
  }
  match stream {
    Ok(bytes) =>
      check_payload(golden, bytes, "\{version}/generated_\{sample}.stream")
    Err(_) => ()
  }
  let file : Result[Bytes, @types.DataError] = Ok(
    @fs.read_file_to_bytes("\{base}.arrow_file"),
  ) catch {
    @fs.IOError(msg) => Err(@types.DataError::IoError(msg))
  }
  match file {
    Ok(bytes) =>
      check_payload(golden, bytes, "\{version}/generated_\{sample}.arrow_file")
    Err(_) => ()
  }
}

// ── the samples ───────────────────────────────────────────────────────

///|
test "IPC reads the little-endian goldens column for column" {
  for
    sample in [
      "primitive", "primitive_no_batches", "primitive_zerolength", "primitive_large_offsets",
      "null", "null_trivial", "nested", "nested_large_offsets", "nested_dictionary",
      "dictionary", "dictionary_unsigned", "datetime", "interval", "decimal", "map",
      "map_non_canonical", "extension", "duplicate_fieldnames", "custom_metadata",
      "union",
    ] {
    check_sample("1.0.0-littleendian", sample)
  }
}

///|
test "IPC reads the big-endian goldens column for column" {
  for
    sample in [
      "primitive", "null", "nested", "dictionary", "datetime", "decimal",
    ] {
    check_sample("1.0.0-bigendian", sample)
  }
}

///|
test "IPC reads the goldens of the earlier metadata versions" {
  for
    sample in [
      "primitive", "primitive_no_batches", "primitive_zerolength", "nested", "dictionary",
      "datetime",
    ] {
    check_sample("0.14.1", sample)
  }
  check_sample("0.17.1", "union")
}

///|
test "IPC reads the compressed goldens column for column" {
  for sample in ["lz4", "zstd", "uncompressible_lz4", "uncompressible_zstd"] {
    check_sample("2.0.0-compression", sample)
  }
}

///|
test "IPC reads the shared-dictionary golden column for column" {
  check_sample("4.0.0-shareddict", "shared_dict")
}
