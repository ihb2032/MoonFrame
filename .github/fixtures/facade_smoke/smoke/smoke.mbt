// Downstream facade smoke test.
//
// This module lives outside `ihb2032/MoonFrame` and imports the root
// facade (`@moonframe`), exactly as a real user would. It compiles a spread of
// typical pipelines; `moon check` here fails if the facade ever stops
// re-exporting a symbol a downstream program needs to *name*.
//
// The two deliberate extra imports are `@io` for the string-level serialisers
// (`format_csv` / `parse_csv_str`): the facade intentionally does not
// re-export that family — building a frame from in-memory text is reached
// through the `io` package directly — so this fixture mirrors the qualified
// spelling a facade caller is expected to use for them; and `@fs`, to hand
// a written file's bytes to the byte-level parser the way a caller would.
//
// It deliberately chains through the fluent intermediates — `when().then()
// .otherwise()`, `group_by().agg()`, and their lazy twins — without ever
// naming `WhenThen` / `WhenThenElse` / `GroupedDataFrame` / `LazyGroupBy`.
// Those types are `pub` in their home packages but are NOT re-exported by the
// facade; that this module compiles proves a caller never has to name one — dot
// resolution follows each step's return value. If a future change made one of
// them necessary to name, this fixture would stop compiling and force the
// question back into view.
//
// It is a compile fixture: `moon check` typechecks every chain. The assertions
// let it double as a runnable `moon test` if wired that way.

///|
/// Value types the facade must re-export, each named directly.
test "value types are reachable by name" {
  let dtype : @moonframe.DataType = @moonframe.DataType::Int
  let field : @moonframe.Field = @moonframe.Field::Field("a", dtype)
  let schema : @moonframe.Schema = @moonframe.Schema::Schema([field])
  let scalar : @moonframe.Scalar = @moonframe.Scalar::Int(1)
  assert_eq(schema.len(), 1)
  assert_eq(scalar.to_string(), "1")
  // `Field` is opaque: built through its constructor, read through its
  // accessors. A downstream module never names its representation, so a field
  // added to it stays additive — which is the point of keeping them private.
  assert_eq(field.name(), "a")
  assert_eq(field.dtype(), @moonframe.DataType::Int)
  assert_true(field.nullable())
}

///|
/// Eager construction, expressions, operators, and the `when` conditional —
/// the ternary chain threads `WhenThen` / `WhenThenElse` without naming them.
test "eager expression pipeline" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("qty", [10, 3, 7]),
    @moonframe.Series::from_strings("region", ["west", "east", "west"]),
  ])
  let tagged = df.with_columns([
    @moonframe.when(@moonframe.col("qty").gt(@moonframe.lit_int(5)))
    .then(@moonframe.lit_str("big"))
    .otherwise(@moonframe.lit_str("small"))
    .with_alias("size"),
    (@moonframe.col("qty") + @moonframe.lit_int(1)).with_alias("qty1"),
  ])
  let big = tagged.filter(
    @moonframe.col("size")
    .eq(@moonframe.lit_str("big"))
    .land(@moonframe.col("qty").gt(@moonframe.lit_int(0))),
  )
  assert_eq(big.nrows(), 2)
  let _ = big.select(@moonframe.cols(["region", "qty"]))
  let _ = big.to_markdown()

}

///|
/// Group-by / aggregate — `group_by(...).agg(...)` chains `GroupedDataFrame`
/// without naming it — plus sort, unique, drop, and rename.
test "group-by, sort, and reshaping" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_strings("region", ["west", "east", "west"]),
    @moonframe.Series::from_ints("rev", [100, 50, 70]),
  ])
  let grouped = df
    .group_by([@moonframe.col("region")])
    .agg([
      @moonframe.col("rev").sum().with_alias("rev"),
      @moonframe.col("rev").count().with_alias("n"),
    ])
    .sort([
      (
        @moonframe.col("rev"),
        true,
        true,
      ),
    ])
  assert_eq(grouped.nrows(), 2)
  let _ = df.unique(subset=[@moonframe.col("region")])
  let _ = df.drop([@moonframe.col("rev")]).rename([("region", "r")])

}

///|
/// Join through `JoinOptions`.
test "join" {
  let left = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("name", ["a", "b"]),
  ])
  let right = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_ints("score", [9, 8]),
  ])
  let joined = left.join(
    right,
    @moonframe.JoinOptions::on([@moonframe.col("id")]),
  )
  assert_eq(joined.ncols(), 3)
}

///|
/// Lazy layer — `LazyFrame::group_by(...).agg(...)` chains `LazyGroupBy`
/// without naming it — with `collect` / `explain`.
test "lazy pipeline" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_strings("k", ["x", "y", "x"]),
    @moonframe.Series::from_ints("v", [1, 2, 3]),
  ])
  let lf = @moonframe.LazyFrame::LazyFrame(df)
    .filter(@moonframe.col("v").gt(@moonframe.lit_int(0)))
    .group_by([@moonframe.col("k")])
    .agg([@moonframe.col("v").sum().with_alias("v")])
  let out = lf.collect()
  assert_eq(out.nrows(), 2)
  let _ = lf.explain()

}

///|
/// IO round-trips — the text pair, and the lazy sinks to JSON and NDJSON —
/// and the error type, named on the recovery path.
test "io and error handling" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("a", [1, 2]),
  ])
  let csv = @io.format_csv(df)
  let back = @io.parse_csv_str(csv)
  assert_eq(back.nrows(), 2)
  // A plan's batches turned to a file, each read back by its reader.
  let lf = @moonframe.LazyFrame::LazyFrame(df)
  @moonframe.sink_json(lf, "_build/smoke.json")
  assert_eq(@moonframe.read_json("_build/smoke.json").nrows(), 2)
  @moonframe.sink_ndjson(lf, "_build/smoke.ndjson")
  assert_eq(@moonframe.read_ndjson("_build/smoke.ndjson").nrows(), 2)
  // The error type is nameable on a recovery boundary — a missing column
  // raises `DataError`, re-wrapped here into a `Result`.
  let r : Result[@moonframe.DataFrame, @moonframe.DataError] = Ok(
    df.select([@moonframe.col("missing")]),
  ) catch {
    e => Err(e)
  }
  assert_true(r is Err(_))
}

///|
/// The nested value types and the Arrow IPC interchange, each named through
/// the facade: a list and a struct built from their parts, written to a
/// file, read back, scanned with a sunk window, and sunk again.
test "nested values and arrow ipc" {
  let list : @moonframe.ListValue = @moonframe.ListValue::ListValue([
    @moonframe.Scalar::Int(1),
    @moonframe.Scalar::Null,
  ])
  let field : @moonframe.FieldValue = @moonframe.FieldValue::FieldValue(
    "a",
    @moonframe.Scalar::String("x"),
  )
  let record : @moonframe.StructValue = @moonframe.StructValue::StructValue([
    field,
  ])
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_scalars(
      "l",
      [@moonframe.Scalar::List(list)],
      dtype=@moonframe.DataType::List(@moonframe.DataType::Int),
    ),
    @moonframe.Series::from_scalars(
      "s",
      [@moonframe.Scalar::Struct(record)],
      dtype=@moonframe.DataType::Struct(
        @moonframe.Schema::Schema([
          @moonframe.Field::Field("a", @moonframe.DataType::String),
        ]),
      ),
    ),
    @moonframe.Series::from_ints("i", [1]),
  ])
  let compression : @moonframe.IpcCompression = @moonframe.IpcCompression::Lz4
  let format : @moonframe.IpcFormat = @moonframe.IpcFormat::Stream
  @moonframe.write_ipc(df, "_build/smoke.arrow", compression~, format~)
  assert_eq(@moonframe.read_ipc("_build/smoke.arrow").nrows(), 1)
  // The binary counterpart of read_ipc takes the bytes themselves; on
  // bytes that open no payload it raises the reader's own refusal.
  let refused : Result[@moonframe.DataFrame, @moonframe.DataError] = Ok(
    @moonframe.parse_ipc(b""),
  ) catch {
    e => Err(e)
  }
  assert_true(refused is Err(_))
  let scanned = @moonframe.scan_ipc("_build/smoke.arrow").head(1).collect()
  assert_eq(scanned.nrows(), 1)
  @moonframe.sink_ipc(
    @moonframe.scan_ipc("_build/smoke.arrow").tail(1),
    "_build/smoke_sunk.arrow",
    compression=@moonframe.IpcCompression::Zstd,
    format=@moonframe.IpcFormat::File,
  )
  assert_eq(@moonframe.read_ipc("_build/smoke_sunk.arrow").nrows(), 1)
}

///|
/// The SQL entries over moondb's own in-memory driver, each named through
/// the facade: a frame written into a table, the table read whole, and the
/// query scanned with a sunk window.
test "sql write, table read, and scan" {
  let mock = @moondb.MockDriver::new()
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("name", ["a", "b"]),
  ])
  let if_exists : @moonframe.SqlIfExists = @moonframe.SqlIfExists::Append
  @moonframe.write_sql(df, mock, "items", if_exists~)
  // The mock keeps a statement's values as one row, whatever the query,
  // so the table holds the one statement the write bound its rows by.
  let table = @moonframe.read_sql_table(mock, "items")
  assert_eq(table.shape(), (1, 4))
  let scanned = @moonframe.scan_sql(mock, "select").head(1).collect()
  assert_eq(scanned.shape(), (1, 4))
}

///|
/// The Excel entries, each named through the facade: a frame written as a
/// workbook under a chosen sheet, the workbook's sheets listed, and the
/// sheet read back by name and by its options.
test "excel write and read" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("name", ["a", "b"]),
  ])
  let options : @moonframe.ExcelWriteOptions = @moonframe.ExcelWriteOptions::ExcelWriteOptions(
    sheet="Records",
  )
  @moonframe.write_excel(df, "_build/smoke.xlsx", options~)
  assert_eq(@moonframe.excel_sheets("_build/smoke.xlsx"), ["Records"])
  let read : @moonframe.ExcelReadOptions = @moonframe.ExcelReadOptions::ExcelReadOptions(
    sheet="Records",
  )
  assert_eq(@moonframe.read_excel("_build/smoke.xlsx", options=read).nrows(), 2)
  // The default options read the first sheet, which this is.
  assert_eq(@moonframe.read_excel("_build/smoke.xlsx").shape(), (2, 2))
  let flat : @moonframe.ExcelReadOptions = @moonframe.ExcelReadOptions::ExcelReadOptions(
    has_header=false,
  )
  assert_eq(
    @moonframe.read_excel("_build/smoke.xlsx", options=flat).shape(),
    (3, 2),
  )
}

///|
/// The Avro entries, each named through the facade: a frame written as a
/// file under a chosen codec, the codec enum named by its variants, and
/// the file read back from a path and from bytes with a projection.
test "avro write and read" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("name", ["a", "b"]),
  ])
  let codec : @moonframe.AvroCodec = @moonframe.AvroCodec::Deflate
  @moonframe.write_avro(df, "_build/smoke.avro", codec=codec)
  assert_eq(@moonframe.read_avro("_build/smoke.avro").shape(), (2, 2))
  // The default codec stores the blocks as encoded; the bytes already in
  // memory parse with a projection, which keeps the named column and the
  // rows.
  @moonframe.write_avro(df, "_build/smoke_plain.avro")
  let bytes = @fs.read_file_to_bytes("_build/smoke_plain.avro") catch {
    _ => b""
  }
  assert_eq(
    @moonframe.parse_avro(bytes, projection=["name"]).shape(),
    (2, 1),
  )
}

///|
/// The Stata entries, each named through the facade: a frame written as
/// a dataset file, and the file read back from a path and from bytes
/// with a projection.
test "stata write and read" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("name", ["a", "b"]),
  ])
  @moonframe.write_stata(df, "_build/smoke.dta")
  assert_eq(@moonframe.read_stata("_build/smoke.dta").shape(), (2, 2))
  let bytes = @fs.read_file_to_bytes("_build/smoke.dta") catch {
    _ => b""
  }
  assert_eq(
    @moonframe.parse_stata(bytes, projection=["name"]).shape(),
    (2, 1),
  )
}

///|
/// The XML entries, each named through the facade: a frame written as a
/// document, the document read back from a path, and its text parsed
/// under a path of the caller's.
test "xml write and read" {
  let df = @moonframe.DataFrame::DataFrame([
    @moonframe.Series::from_ints("id", [1, 2]),
    @moonframe.Series::from_strings("name", ["a", "b"]),
  ])
  @moonframe.write_xml(df, "_build/smoke.xml")
  assert_eq(@moonframe.read_xml("_build/smoke.xml").shape(), (2, 2))
  let text : String = @moonframe.format_xml(df)
  assert_eq(@moonframe.parse_xml(text, xpath="/data/row").shape(), (2, 2))
}

///|
/// The HTML entries, each named through the facade: a page's two tables
/// read from its text, a frame a table.
test "html read" {
  let page : String =
    #|<html><body><p>a page</p>
    #|<table><tr><th>id</th><th>name</th></tr><tr><td>1</td><td>a</td></tr></table>
    #|<table><tr><td>x</td></tr><tr><td>y</td></tr></table>
    #|</body></html>
  let tables = @moonframe.parse_html(page)
  assert_eq(tables.length(), 2)
  assert_eq(tables[0].columns(), ["id", "name"])
  assert_eq(tables[1].shape(), (2, 1))
  let read : @moonframe.DataFrame = @moonframe.parse_html(page)[0]
  assert_eq(read.shape(), (1, 2))
}

///|
/// The error-detail enums are `#non_exhaustive`: a downstream match carries a
/// `..` arm for the diagnostic shapes it does not know, so a shape arriving in
/// a later release is a recompile, not a break. This match is the migration
/// sample — delete the last arm and it stops compiling, which is the compiler
/// enforcing exactly that contract.
test "error details match with a forward-compat arm" {
  fn shape(d : @moonframe.TypeMismatchDetail) -> String {
    match d {
      Message(m) => "message: \{m}"
      Expected(_, _, _) => "expected"
      Operation(_, _, _) => "operation"
      @moonframe.TypeMismatchDetail::.. => "unknown shape"
    }
  }
  assert_eq(
    shape(
      @moonframe.TypeMismatchDetail::Expected(
        @moonframe.DataType::Int,
        @moonframe.DataType::String,
        "",
      ),
    ),
    "expected",
  )
  assert_eq(
    shape(@moonframe.TypeMismatchDetail::Message("boom")),
    "message: boom",
  )
}
