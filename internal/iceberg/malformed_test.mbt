// Blackbox malformed-input sweep. The three readings take bytes from a
// file: the table's metadata JSON, a snapshot's manifest list, a manifest.
// Each is truncated at every length; each has one byte replaced in 200
// copies; then 200 random byte strings go through each reading. No call
// may abort, and no call may raise anything but `DataError`: a truncation
// that is still a whole file reads back and is counted, since a container
// cut exactly where its header ends is a container of no block. An abort
// would end the test process before its summary, so a marker line precedes
// each case and the summary is each test's last line. The seeds are named
// below, and the generator is written out, so the inputs are the same on
// every run and every target.

///|
/// A deterministic 64-bit generator (splitmix64).
struct SplitMix {
  mut state : UInt64
}

///|
/// The next number of the generator.
fn SplitMix::next(self : SplitMix) -> UInt64 {
  self.state += 0x9E3779B97F4A7C15UL
  let mut z = self.state
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// The replacement sweep's seed.
const SEED_REPLACEMENT : UInt64 = 0x4943453230323636UL

///|
/// The random-string sweep's seed.
const SEED_RANDOM : UInt64 = 0x4943453230323637UL

///|
/// One small valid input of each kind: the table's metadata, its
/// snapshot's manifest list, and the manifest that list names.
struct Small {
  location : String
  metadata : Bytes
  list : Bytes
  manifest : Bytes
  entry : IcebergManifest
}

///|
/// The small inputs, read from the corpus.
fn small() -> Small raise @types.DataError {
  let dir = ".github/fixtures/iceberg/reference/append_one"
  let metadata_bytes = fixture(current_metadata(dir))
  let table = iceberg_metadata(metadata_bytes)
  let list_bytes = fixture("\{dir}/\{table.manifest_list().unwrap_or("")}")
  let manifests = iceberg_manifests(list_bytes, location=table.location())
  let entry = manifests[0]
  let manifest_bytes = fixture("\{dir}/\{entry.path()}")
  Small::{
    location: table.location(),
    metadata: metadata_bytes,
    list: list_bytes,
    manifest: manifest_bytes,
    entry,
  }
}

///|
/// Whether reading the metadata in `bytes` raised `DataError`.
fn metadata_raises(bytes : Bytes) -> Bool {
  let outcome : Result[IcebergTable, @types.DataError] = Ok(
    iceberg_metadata(bytes),
  ) catch {
    error => Err(error)
  }
  outcome is Err(_)
}

///|
/// Whether reading the manifest list in `bytes` raised `DataError`.
fn list_raises(bytes : Bytes, location : String) -> Bool {
  let outcome : Result[Array[IcebergManifest], @types.DataError] = Ok(
    iceberg_manifests(bytes, location~),
  ) catch {
    error => Err(error)
  }
  outcome is Err(_)
}

///|
/// Whether reading the manifest in `bytes` raised `DataError`, read with
/// the list's entry when `with_entry` is set and on its own otherwise.
fn manifest_raises(
  bytes : Bytes,
  entry : IcebergManifest,
  with_entry : Bool,
) -> Bool {
  let outcome : Result[Array[IcebergFile], @types.DataError] = Ok(
    if with_entry {
      iceberg_files(bytes, manifest=entry)
    } else {
      iceberg_files(bytes)
    },
  ) catch {
    error => Err(error)
  }
  outcome is Err(_)
}

///|
/// `whole` cut to its first `length` bytes.
fn cut(whole : Bytes, length : Int32) -> Bytes {
  Bytes::makei(length, i => whole[i])
}

///|
/// `whole` with the byte at `at` replaced by `value`.
fn replaced(whole : Bytes, at : Int32, value : Byte) -> Bytes {
  Bytes::makei(whole.length(), i => if i == at { value } else { whole[i] })
}

///|
/// The sweep's next replacement of `whole`: the offset and the value, as
/// `rng` draws them.
fn draw(rng : SplitMix, whole : Bytes) -> (Int32, Byte) {
  let at = (rng.next() % whole.length().to_uint64()).to_int()
  let mut value = ((rng.next() >> 8) & 0xFFUL).to_byte()
  if value == whole[at] {
    value = (value.to_int() ^ 0xFF).to_byte()
  }
  (at, value)
}

///|
test "every truncation of a metadata file raises DataError, and nothing aborts" {
  // A metadata file is one JSON document: cut anywhere, it is no document.
  let whole = small().metadata
  for length in 0..<whole.length() {
    println("truncation case metadata \{length}")
    if !metadata_raises(cut(whole, length)) {
      fail("the metadata truncated to \{length} bytes read back")
    }
  }
  println(
    "truncations metadata: \{whole.length()} cases, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "every truncation of a manifest list raises, or is the header alone, and nothing aborts" {
  // A container cut exactly where its header ends has no block: a list of
  // no manifest. Any other cut falls inside the header or the block.
  let files = small()
  let whole = files.list
  let mut whole_files = 0
  for length in 0..<whole.length() {
    println("truncation case list \{length}")
    if !list_raises(cut(whole, length), files.location) {
      whole_files += 1
      println(
        "the list truncated to \{length} bytes reads as a list of no manifest",
      )
    }
  }
  if whole_files > 1 {
    fail(
      "\{whole_files} truncations of the manifest list read back; only the cut at its header's end can",
    )
  }
  println(
    "truncations list: \{whole.length()} cases, \{whole.length() - whole_files} raised DataError, \{whole_files} read back as a list of no manifest, 0 aborted; DONE",
  )
}

///|
test "every truncation of a manifest raises while the list names its length, and nothing aborts" {
  // The list's entry states how long the manifest is; a cut anywhere makes
  // the file shorter than its entry says.
  let files = small()
  let whole = files.manifest
  for length in 0..<whole.length() {
    println("truncation case manifest \{length}")
    if !manifest_raises(cut(whole, length), files.entry, true) {
      fail(
        "the manifest truncated to \{length} bytes read back under its entry",
      )
    }
  }
  println(
    "truncations manifest under its entry: \{whole.length()} cases, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "truncations of a manifest read on its own raise inside its bytes, or are a whole shorter manifest, and nothing aborts" {
  // Without the list's entry a cut at a record's end leaves a manifest of
  // fewer records; inside a record it is refused. Both are counted.
  let files = small()
  let whole = files.manifest
  let mut raised = 0
  let mut read_back = 0
  for length in 0..<whole.length() {
    println("truncation case manifest alone \{length}")
    if manifest_raises(cut(whole, length), files.entry, false) {
      raised += 1
    } else {
      read_back += 1
    }
  }
  if raised == 0 {
    fail("no truncation of the manifest read on its own raised")
  }
  println(
    "truncations manifest alone: \{whole.length()} cases, \{raised} raised DataError, \{read_back} read back, 0 aborted; DONE",
  )
}

///|
test "200 single-byte replacements of each file never abort" {
  // Most bytes of a manifest are metrics the plan steps over, and a
  // metadata file carries a UUID and a location no cell depends on: a
  // replacement there reads back. That some raised shows the sweep is not
  // vacuous.
  let files = small()
  let inputs : Array[(String, Bytes)] = [
    ("metadata", files.metadata),
    ("list", files.list),
    ("manifest under its entry", files.manifest),
    ("manifest alone", files.manifest),
  ]
  let mut raised_all = 0
  let mut read_all = 0
  for (label, whole) in inputs {
    let rng = SplitMix::{ state: SEED_REPLACEMENT, }
    let mut raised = 0
    for case in 0..<200 {
      println("replacement case \{label} \{case}")
      let (at, value) = draw(rng, whole)
      let bytes = replaced(whole, at, value)
      let refused = if label == "metadata" {
        metadata_raises(bytes)
      } else if label == "list" {
        list_raises(bytes, files.location)
      } else {
        manifest_raises(bytes, files.entry, label != "manifest alone")
      }
      if refused {
        raised += 1
      }
    }
    if raised == 0 {
      fail("no replacement in \{label} raised")
    }
    println(
      "replacements \{label}: 200 cases, \{raised} raised DataError, \{200 - raised} read back, 0 aborted; DONE",
    )
    raised_all += raised
    read_all += 200 - raised
  }
  println(
    "replacements total: 800 cases, \{raised_all} raised DataError, \{read_all} read back, 0 aborted; DONE",
  )
}

///|
test "200 random byte strings raise DataError in each reading, and nothing aborts" {
  // Random bytes do not open with the JSON a metadata file needs or with
  // the Avro magic a container does.
  let files = small()
  let rng = SplitMix::{ state: SEED_RANDOM, }
  let mut shortest = 3000
  let mut longest = 0
  for case in 0..<200 {
    println("random case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    if length < shortest {
      shortest = length
    }
    if length > longest {
      longest = length
    }
    let bytes = Bytes::makei(length, _ => (rng.next() & 0xFFUL).to_byte())
    if !metadata_raises(bytes) {
      fail("random byte string \{case} (\{length} bytes) read back as a table")
    }
    if !list_raises(bytes, files.location) {
      fail(
        "random byte string \{case} (\{length} bytes) read back as a manifest list",
      )
    }
    if !manifest_raises(bytes, files.entry, true) {
      fail(
        "random byte string \{case} (\{length} bytes) read back under its entry",
      )
    }
    if !manifest_raises(bytes, files.entry, false) {
      fail(
        "random byte string \{case} (\{length} bytes) read back as a manifest",
      )
    }
  }
  println(
    "random strings: 200 cases, lengths \{shortest} to \{longest}, through four readings, all raised DataError, 0 aborted; DONE",
  )
}

///|
test "200 random byte strings after the magic raise DataError, and nothing aborts" {
  // The head spells the Avro magic, so the header, the schema and the
  // block are what refuse them.
  let files = small()
  let rng = SplitMix::{ state: SEED_RANDOM + 1UL, }
  let mut lists = 0
  let mut manifests = 0
  for case in 0..<200 {
    println("random-after-magic case \{case}")
    let length = (rng.next() % 3001UL).to_int()
    let bytes = Bytes::makei(length + 4, i => {
      if i < 4 {
        b"Obj\x01"[i]
      } else {
        (rng.next() & 0xFFUL).to_byte()
      }
    })
    if !list_raises(bytes, files.location) {
      fail("random bytes after the magic \{case} read back as a manifest list")
    }
    lists += 1
    if !manifest_raises(bytes, files.entry, false) {
      fail("random bytes after the magic \{case} read back as a manifest")
    }
    manifests += 1
  }
  println(
    "random strings after the magic: 200 cases, through the list reading \{lists} times and the manifest reading \{manifests} times, all raised DataError, 0 aborted; DONE",
  )
}
