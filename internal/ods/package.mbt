// The package: a ZIP archive read whole through the ZIP reader under its
// default limits, judged by its mimetype entry — or, with none, by the
// root of content.xml — and named by the entry when the archive is
// broken.

///|
const SPREADSHEET : String = "application/vnd.oasis.opendocument.spreadsheet"

///|
const MIMETYPE : String = "mimetype"

///|
const CONTENT : String = "content.xml"

///|
const CONTENT_TYPES : String = "[Content_Types].xml"

///|
/// The package read whole: every entry decoded and its checksum verified
/// by the ZIP reader under that reader's default limits — the package's
/// bytes, each entry's decoded bytes, all the decoded bytes together and
/// the number of entries are each bounded at 2 147 483 647.
fn open_package(bytes : Bytes) -> @zip.Archive raise @types.DataError {
  let opened : Result[@zip.Archive, @zip.ZipError] = Ok(@zip.read(bytes)) catch {
    e => Err(e)
  }
  match opened {
    Ok(archive) => archive
    Err(error) => raise broken_package(bytes, error)
  }
}

///|
/// The ZIP reader's failure over a package, as this reader's refusal: an
/// encrypted entry by name; then the entry that is broken — found by a
/// second pass that reads each entry on its own, since the reader's error
/// does not say which one it stopped at — and, when no entry is at fault,
/// the archive itself.
fn broken_package(bytes : Bytes, error : @zip.ZipError) -> @types.DataError {
  match error {
    @zip.ZipError(kind, message) => zip_refusal(bytes, kind, message)
  }
}

///|
/// The ZIP reader's kind and message turned into the refusal.
fn zip_refusal(
  bytes : Bytes,
  kind : @zip.ZipErrorKind,
  message : String,
) -> @types.DataError {
  if kind == @zip.ZipErrorKind::UnsupportedFeature {
    let name = encrypted_entry(bytes)
    if name is Some(name) {
      return nope(
        "ods: the package's entry \"\{name}\" is encrypted, which this reader does not decrypt",
      )
    }
  }
  let broken = broken_entry(bytes)
  match broken {
    Some(name) =>
      bad("ods: the package's entry \"\{name}\" is broken: \{message}")
    None => bad("ods: the package is a broken ZIP archive: \{message}")
  }
}

///|
/// Whether the package holds no mimetype entry, so that the root of
/// content.xml has to judge it instead. A mimetype that is not an
/// OpenDocument spreadsheet's refuses by name, whatever else the package
/// holds.
fn judge_mimetype(archive : @zip.Archive) -> Bool raise @types.DataError {
  let kind = archive.get(MIMETYPE)
  match kind {
    Some(kind) =>
      if is_spreadsheet_mimetype(kind) {
        false
      } else {
        raise nope(
          "ods: the package's mimetype is \"\{shown(kind)}\", not an OpenDocument spreadsheet's",
        )
      }
    None => true
  }
}

///|
/// Whether a mimetype entry's bytes are the OpenDocument spreadsheet's,
/// all 46 of them and nothing else.
fn is_spreadsheet_mimetype(kind : BytesView) -> Bool {
  kind.to_owned() == @utf8.encode(SPREADSHEET)
}

///|
/// The content.xml entry. A package that holds none is refused by what it
/// is: an Office Open XML package when it carries that format's
/// [Content_Types].xml, a package of neither kind when it carries neither
/// file, and a broken OpenDocument one when its mimetype says it should
/// hold the entry.
fn content_entry(
  archive : @zip.Archive,
  judged_by_root : Bool,
) -> BytesView raise @types.DataError {
  let content = archive.get(CONTENT)
  match content {
    Some(content) => content
    None =>
      if judged_by_root {
        if archive.get(CONTENT_TYPES) is Some(_) {
          raise nope(
            "ods: the package holds an Office Open XML [Content_Types].xml and no content.xml, so it is not an OpenDocument package",
          )
        }
        raise nope(
          "ods: the package holds neither a mimetype nor a content.xml, so it is not an OpenDocument package",
        )
      } else {
        raise bad(
          "ods: the package's mimetype is an OpenDocument spreadsheet's, but it holds no content.xml",
        )
      }
  }
}

///|
/// A mimetype entry's bytes for a message: its first 64 characters as
/// UTF-8, or — when they are not UTF-8 — its first 16 bytes in
/// hexadecimal; `...` where the entry goes on.
fn shown(kind : BytesView) -> String {
  let head = if kind.length() < 256 { kind } else { kind[0:256] }
  let decoded : Result[String, _] = Ok(@utf8.decode(head)) catch {
    _ => Err(())
  }
  let out = StringBuilder()
  match decoded {
    Ok(text) => {
      let kept = cut(text, 64)
      out.write_string(kept)
      if kept.length() < text.length() || kind.length() > 256 {
        out.write_string("...")
      }
    }
    Err(_) => {
      let few = if head.length() < 16 { head } else { head[0:16] }
      out.write_string(hexadecimal(few))
      if head.length() > 16 {
        out.write_string("...")
      }
    }
  }
  out.to_string()
}

///|
/// A byte view in hexadecimal: `\x`, then two digits, a byte.
fn hexadecimal(bytes : BytesView) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
  ]
  let out = StringBuilder()
  for b in bytes {
    let value = b.to_int()
    out.write_string("\\x")
    out.write_char(digits[value >> 4])
    out.write_char(digits[value & 15])
  }
  out.to_string()
}

///|
/// The first entry whose flags declare it encrypted, or nothing — and
/// nothing too when the archive's directory cannot be listed.
fn encrypted_entry(bytes : Bytes) -> String? {
  let listing = match directory(bytes) {
    Some(listing) => listing
    None => return None
  }
  let entries = listing.entries()
  let found = entries.search_by(entry => entry.is_encrypted())
  match found {
    Some(index) => Some(entries[index].name())
    None => None
  }
}

///|
/// The first entry of the archive that cannot be read on its own, or
/// nothing: when every entry reads, when the directory itself cannot be
/// listed, or when an entry fails for a reason other than being broken —
/// a compression method or a flag the ZIP reader does not take.
fn broken_entry(bytes : Bytes) -> String? {
  let listing = match directory(bytes) {
    Some(listing) => listing
    None => return None
  }
  let entries = listing.entries()
  // The scratch buffer every entry's decoded bytes pass through and are
  // dropped into; its size is this reader's, not the file's.
  let output = FixedArray::make(65536, b'\x00')
  for index in 0..<entries.length() {
    let reader = match open_entry(listing, index) {
      Some(reader) => reader
      None => continue
    }
    if entry_broken(bytes, reader, output) {
      return Some(entries[index].name())
    }
  }
  None
}

///|
/// The archive's directory, or nothing when it cannot be listed.
fn directory(bytes : Bytes) -> @zip.Directory? {
  let reader = @zip.DirectoryReader(
    bytes.length().to_uint64(),
    limits=@zip.DirectoryLimits(),
  )
  let mut input : Bytes = b""
  let listing = for ;; {
    let advanced : Result[@zip.DirectoryStep, _] = Ok(reader.advance(input)) catch {
      _ => Err(())
    }
    match advanced {
      Err(_) => break None
      Ok(NeedRead(range)) => input = range_bytes(bytes, range)
      Ok(Done(listing)) => break Some(listing)
    }
  }
  listing
}

///|
/// One entry opened for reading, or nothing when the ZIP reader refuses to
/// open it.
fn open_entry(listing : @zip.Directory, index : Int32) -> @zip.EntryReader? {
  let opened : Result[@zip.EntryReader, _] = Ok(listing.open_entry(index)) catch {
    _ => Err(())
  }
  match opened {
    Ok(reader) => Some(reader)
    Err(_) => None
  }
}

///|
/// Whether an entry, read on its own, fails: its local header disagrees
/// with the directory, its bytes do not inflate, its size or its checksum
/// is wrong, or it asks for a range outside the archive.
fn entry_broken(
  bytes : Bytes,
  reader : @zip.EntryReader,
  output : FixedArray[Byte],
) -> Bool {
  let mut input : Bytes = b""
  let verdict = for ;; {
    let stepped : Result[@zip.EntryStep, _] = Ok(reader.step(input, output)) catch {
      _ => Err(())
    }
    match stepped {
      Err(_) => break true
      Ok(NeedRead(range)) => input = range_bytes(bytes, range)
      Ok(NeedMoreOutput) => input = b""
      Ok(Done) => break false
    }
  }
  verdict
}

///|
/// The bytes a range reader asks for: the archive's bytes over that range,
/// checked against the archive's length before anything is sliced — and
/// none at all when the range lies outside it, which every reader refuses
/// as a short response.
fn range_bytes(bytes : Bytes, range : @zip.ReadRange) -> Bytes {
  let total = bytes.length().to_uint64()
  let offset = range.offset()
  let length = range.length().to_uint64()
  if offset > total || length > total - offset {
    b""
  } else {
    let from = offset.to_int()
    bytes[from:from + length.to_int()].to_owned()
  }
}
