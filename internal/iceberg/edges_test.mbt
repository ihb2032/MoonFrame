// Blackbox tests of the edges: a table with no snapshot, a table of no
// column, a snapshot with no file, columns of nothing but missing values,
// and names and strings at the format's limits. The tables are the
// generator's, under `.github/fixtures/iceberg/reference/`.

///|
/// A table of the corpus, read from its current metadata file.
fn corpus_table(name : String) -> IcebergTable raise @types.DataError {
  iceberg_metadata(
    fixture(current_metadata(".github/fixtures/iceberg/reference/\{name}")),
  )
}

///|
test "a table with no snapshot answers its columns and no manifest list" {
  let empty = corpus_table("empty")
  assert_eq(empty.schema().len(), 1)
  assert_eq(empty.schema().field_names(), ["i"])
  assert_eq(empty.field_ids(), [1L])
  assert_eq(empty.manifest_list(), None)
}

///|
test "a table of no column reads as an empty schema" {
  let bare = corpus_table("no_columns")
  assert_eq(bare.schema().len(), 0)
  assert_true(bare.schema().is_empty())
  assert_eq(bare.field_ids(), [])
  assert_eq(bare.manifest_list(), None)
}

///|
test "a snapshot whose manifest list names no manifest reads as no file" {
  let table = corpus_table("no_rows")
  let list = table.manifest_list().unwrap_or("")
  assert_eq(list.has_prefix("metadata/"), true)
  let manifests = iceberg_manifests(
    fixture(".github/fixtures/iceberg/reference/no_rows/\{list}"),
    location=table.location(),
  )
  assert_eq(manifests.length(), 0)
}

///|
test "columns of nothing but missing values keep their dtypes" {
  let table = corpus_table("all_null")
  assert_eq(table.schema().field_names(), ["i", "s", "d"])
  let dtypes = table.schema().fields().map(fn(one) { one.dtype().to_string() })
  assert_eq(dtypes, ["Int", "String", "Date"])
  let list = table.manifest_list().unwrap_or("")
  let manifests = iceberg_manifests(
    fixture(".github/fixtures/iceberg/reference/all_null/\{list}"),
    location=table.location(),
  )
  assert_eq(manifests.length(), 1)
  let files = iceberg_files(
    fixture(
      ".github/fixtures/iceberg/reference/all_null/\{manifests[0].path()}",
    ),
    manifest=manifests[0],
  )
  assert_eq(files.length(), 1)
  assert_eq(files[0].record_count(), 3L)
  assert_eq(files[0].kind(), Data)
}

///|
test "a column name of 255 characters and a string of 2,000 come back as spelled" {
  let table = corpus_table("limits")
  let names = table.schema().field_names()
  assert_eq(names.length(), 3)
  assert_eq(names[0], "k")
  assert_eq(names[2], "with space")
  assert_eq(names[1].length(), 255)
  assert_eq(names[1], "n".repeat(255))
}

///|
test "a name and a value outside ASCII come back as spelled" {
  let table = corpus_table("unicode")
  let names = table.schema().field_names()
  assert_eq(names, ["col naïf", "a.b", "with space"])
  let list = table.manifest_list().unwrap_or("")
  let manifests = iceberg_manifests(
    fixture(".github/fixtures/iceberg/reference/unicode/\{list}"),
    location=table.location(),
  )
  assert_eq(manifests.length(), 1)
  let files = iceberg_files(
    fixture(".github/fixtures/iceberg/reference/unicode/\{manifests[0].path()}"),
    manifest=manifests[0],
  )
  assert_eq(files.length(), 1)
  assert_eq(files[0].record_count(), 3L)
}

///|
test "a manifest read on its own answers its paths as it spells them" {
  let table = corpus_table("append_one")
  let list = table.manifest_list().unwrap_or("")
  let listed = iceberg_manifests(
    fixture(".github/fixtures/iceberg/reference/append_one/\{list}"),
    location=table.location(),
  )
  assert_eq(listed.length(), 1)
  // Without the table's location the path is the list's own spelling.
  let alone = iceberg_manifests(
    fixture(".github/fixtures/iceberg/reference/append_one/\{list}"),
  )
  assert_eq(alone.length(), 1)
  assert_eq(alone[0].path().has_prefix(table.location()), true)
  let files = iceberg_files(
    fixture(".github/fixtures/iceberg/reference/append_one/\{listed[0].path()}"),
  )
  assert_eq(files.length(), 1)
  assert_eq(files[0].path().has_prefix(table.location()), true)
  // An added entry read alone has no manifest to inherit from.
  assert_eq(files[0].sequence_number(), 0L)
  assert_eq(files[0].equality_ids().length(), 0)
  // Read under the list's entry, the same entry inherits the sequence
  // number of the manifest, which is its only commit's; and its path is
  // answered relative to the table's location.
  let inherited = iceberg_files(
    fixture(".github/fixtures/iceberg/reference/append_one/\{listed[0].path()}"),
    manifest=listed[0],
  )
  assert_eq(inherited.length(), 1)
  assert_eq(inherited[0].sequence_number(), 1L)
  assert_eq(inherited[0].path().has_prefix("data/"), true)
  assert_eq(inherited[0].field_ids(), [1L, 2L])
}

///|
test "the three readings refuse what is not theirs, by variant and text" {
  // Bytes that are no container at all.
  let outcome : Result[Array[IcebergManifest], @types.DataError] = Ok(
    iceberg_manifests(b"not an Avro container at all, just text"),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("text read as a manifest list")
    Err(error) => {
      assert_eq(variant(error), "ParseError")
      assert_eq(
        error.message(),
        "Parse error: iceberg: byte 0: a file that does not open with the Avro magic",
      )
    }
  }
  // A manifest list's bytes handed to the manifest reading: a list's schema
  // names no status.
  let table = corpus_table("append_one")
  let list = table.manifest_list().unwrap_or("")
  let bytes = fixture(".github/fixtures/iceberg/reference/append_one/\{list}")
  let outcome : Result[Array[IcebergFile], @types.DataError] = Ok(
    iceberg_files(bytes),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("a manifest list read as a manifest")
    Err(error) =>
      assert_eq(
        error.message(),
        "Parse error: iceberg: the manifest: a schema that names no field with the id 0",
      )
  }
  // The metadata's bytes handed to the list reading.
  let outcome : Result[Array[IcebergManifest], @types.DataError] = Ok(
    iceberg_manifests(
      fixture(current_metadata(".github/fixtures/iceberg/reference/append_one")),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => fail("a metadata file read as a manifest list")
    Err(error) =>
      assert_eq(
        error.message(),
        "Parse error: iceberg: byte 0: a file that does not open with the Avro magic",
      )
  }
}
