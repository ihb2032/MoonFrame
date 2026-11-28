// Blackbox tests for the partitioned sinks: the files a plan's rows become
// under a key, under a row limit, and under both, for each of the four
// formats — laid out as the reference sinks lay them out, and each file
// reading back as the single-file sink's own rows for that partition.

///|
/// Every file under `root`, as its path from `root`, `/`-separated and
/// sorted — the layout a reader of the directory meets.
fn part_files(root : String) -> Array[String] raise @types.DataError {
  let out : Array[String] = []
  if @fs.path_exists(root) {
    part_walk(root, "", out)
  }
  out.sort_by((a, b) => a.lexical_compare(b))
  out
}

///|
/// The walk behind `part_files`: every entry of `dir`, a directory
/// descended into, a file named by its path from the root.
fn part_walk(
  dir : String,
  prefix : String,
  out : Array[String],
) -> Unit raise @types.DataError {
  let names = @fs.read_dir(dir) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  for name in names {
    let path = if prefix == "" { name } else { "\{prefix}/\{name}" }
    let full = "\{dir}/\{name}"
    let directory = @fs.is_dir(full) catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
    if directory {
      part_walk(full, path, out)
    } else {
      out.push(path)
    }
  }
}

///|
/// A directory's path under the build directory, emptied first — whatever a
/// earlier run left is removed — so a test sees only what it wrote.
fn part_root(name : String) -> String raise @types.DataError {
  let path = "_build/partsink_\{name}"
  part_clear(path)
  path
}

///|
/// Remove a directory tree: its files, then its directories from the
/// deepest up, then the root itself.
fn part_clear(path : String) -> Unit raise @types.DataError {
  if !@fs.path_exists(path) {
    return
  }
  let directories : Array[String] = [path]
  let files : Array[String] = []
  part_collect(path, files, directories)
  for file in files {
    @fs.remove_file(file) catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
  }
  let mut i = directories.length() - 1
  while i >= 0 {
    @fs.remove_dir(directories[i]) catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
    i -= 1
  }
}

///|
/// The walk behind `part_clear`: every file's path, and every directory's
/// in the order first met.
fn part_collect(
  dir : String,
  files : Array[String],
  directories : Array[String],
) -> Unit raise @types.DataError {
  let names = @fs.read_dir(dir) catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
  for name in names {
    let full = "\{dir}/\{name}"
    let directory = @fs.is_dir(full) catch {
      @fs.IOError(msg) => raise @types.DataError::IoError(msg)
    }
    if directory {
      directories.push(full)
      part_collect(full, files, directories)
    } else {
      files.push(full)
    }
  }
}

///|
/// The probe table: four rows, a region with a null among its values, a
/// year, and a quantity.
fn part_frame() -> @frame.DataFrame raise @types.DataError {
  @frame.DataFrame::DataFrame([
    @series.Series::from_string_options("region", [
      Some("Americas"),
      Some("Europe"),
      Some("Americas"),
      None,
    ]),
    @series.Series::from_ints("year", [2020, 2020, 2021, 2020]),
    @series.Series::from_ints("qty", [1, 2, 3, 4]),
  ])
}

///|
/// The error a call raises; nothing raised instead fails the test.
fn part_error(
  call : () -> Unit raise @types.DataError,
) -> @types.DataError raise {
  let outcome : Result[Unit, @types.DataError] = Ok(call()) catch {
    e => Err(e)
  }
  match outcome {
    Ok(_) => fail("the call raised nothing")
    Err(e) => e
  }
}

///|
test "a key makes a directory a value, a file inside, as the single-file sink writes its rows" {
  let root = part_root("parquet_key")
  @io.sink_parquet(
    part_frame().to_lazy(),
    root,
    partition=@io.PartitionBy::PartitionBy(key=["region", "year"]),
  )
  assert_eq(part_files(root), [
    "region=Americas/year=2020/00000000.parquet", "region=Americas/year=2021/00000000.parquet",
    "region=Europe/year=2020/00000000.parquet", "region=__HIVE_DEFAULT_PARTITION__/year=2020/00000000.parquet",
  ])
  // Each file reads back as the single-file sink's own rows for that
  // partition, the key columns included.
  let americas_2020 = @io.read_parquet(
    "\{root}/region=Americas/year=2020/00000000.parquet",
  )
  assert_eq(americas_2020.columns(), ["region", "year", "qty"])
  assert_eq(americas_2020.get_column("region").to_scalars(), [
    @types.Scalar::String("Americas"),
  ])
  assert_eq(americas_2020.get_column("qty").to_scalars(), [
    @types.Scalar::Int(1),
  ])
  let americas_2021 = @io.read_parquet(
    "\{root}/region=Americas/year=2021/00000000.parquet",
  )
  assert_eq(americas_2021.get_column("qty").to_scalars(), [
    @types.Scalar::Int(3),
  ])
  let europe = @io.read_parquet(
    "\{root}/region=Europe/year=2020/00000000.parquet",
  )
  assert_eq(europe.get_column("qty").to_scalars(), [@types.Scalar::Int(2)])
  let none = @io.read_parquet(
    "\{root}/region=__HIVE_DEFAULT_PARTITION__/year=2020/00000000.parquet",
  )
  assert_eq(none.get_column("region").to_scalars(), [@types.Scalar::Null])
  assert_eq(none.get_column("year").to_scalars(), [@types.Scalar::Int(2020)])
  assert_eq(none.get_column("qty").to_scalars(), [@types.Scalar::Int(4)])
}

///|
test "a key left out of the files: include_key=false" {
  let root = part_root("parquet_nokey")
  @io.sink_parquet(
    part_frame().to_lazy(),
    root,
    partition=@io.PartitionBy::PartitionBy(key=["region"], include_key=false),
  )
  assert_eq(part_files(root), [
    "region=Americas/00000000.parquet", "region=Europe/00000000.parquet", "region=__HIVE_DEFAULT_PARTITION__/00000000.parquet",
  ])
  let americas = @io.read_parquet("\{root}/region=Americas/00000000.parquet")
  assert_eq(americas.columns(), ["year", "qty"])
  assert_eq(americas.get_column("year").to_scalars(), [
    @types.Scalar::Int(2020),
    @types.Scalar::Int(2021),
  ])
  assert_eq(americas.get_column("qty").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(3),
  ])
}

///|
test "a row limit cuts the rows into files of the base directory" {
  let root = part_root("parquet_max")
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", [1, 2, 3, 4, 5]),
  ])
  @io.sink_parquet(
    df.to_lazy(),
    root,
    partition=@io.PartitionBy::PartitionBy(max_rows_per_file=2),
  )
  assert_eq(part_files(root), [
    "00000000.parquet", "00000001.parquet", "00000002.parquet",
  ])
  let first = @io.read_parquet("\{root}/00000000.parquet")
  let second = @io.read_parquet("\{root}/00000001.parquet")
  let third = @io.read_parquet("\{root}/00000002.parquet")
  assert_eq(first.get_column("i").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(2),
  ])
  assert_eq(second.get_column("i").to_scalars(), [
    @types.Scalar::Int(3),
    @types.Scalar::Int(4),
  ])
  assert_eq(third.get_column("i").to_scalars(), [@types.Scalar::Int(5)])
}

///|
test "a key and a row limit together: a directory's rows cut at the limit" {
  let root = part_root("parquet_both")
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("k", ["a", "b", "a", "a", "b"]),
    @series.Series::from_ints("i", [1, 2, 3, 4, 5]),
  ])
  @io.sink_parquet(
    df.to_lazy(),
    root,
    partition=@io.PartitionBy::PartitionBy(key=["k"], max_rows_per_file=2),
  )
  assert_eq(part_files(root), [
    "k=a/00000000.parquet", "k=a/00000001.parquet", "k=b/00000000.parquet",
  ])
  let a0 = @io.read_parquet("\{root}/k=a/00000000.parquet")
  let a1 = @io.read_parquet("\{root}/k=a/00000001.parquet")
  let b0 = @io.read_parquet("\{root}/k=b/00000000.parquet")
  assert_eq(a0.get_column("i").to_scalars(), [
    @types.Scalar::Int(1),
    @types.Scalar::Int(3),
  ])
  assert_eq(a1.get_column("i").to_scalars(), [@types.Scalar::Int(4)])
  assert_eq(b0.get_column("i").to_scalars(), [
    @types.Scalar::Int(2),
    @types.Scalar::Int(5),
  ])
}

///|
test "a key value is spelled as its cell renders, percent-encoded" {
  let root = part_root("parquet_spelling")
  let df = @frame.DataFrame::DataFrame([
    @series.Series::from_strings("s", [
      "a b/c=d", "ünï 日本", "plain-._~", "100%", "back\\slash:tick?",
    ]),
    @series.Series::from_ints("i", [1, 2, 3, 4, 5]),
  ])
  @io.sink_parquet(
    df.to_lazy(),
    root,
    partition=@io.PartitionBy::PartitionBy(key=["s"]),
  )
  assert_eq(part_files(root), [
    "s=%C3%BCn%C3%AF%20%E6%97%A5%E6%9C%AC/00000000.parquet", "s=100%25/00000000.parquet",
    "s=a%20b%2Fc%3Dd/00000000.parquet", "s=back%5Cslash%3Atick%3F/00000000.parquet",
    "s=plain-._~/00000000.parquet",
  ])
  // Every other dtype spells as its cell renders.
  let typed_root = part_root("parquet_spelling_typed")
  let typed = @frame.DataFrame::DataFrame([
    @series.Series::from_floats("f", [1.5, 0.25]),
    @series.Series::from_bools("b", [true, false]),
    @series.Series::from_date_options("d", [Some(0L), Some(-1L)]),
  ])
  for key in ["f", "b", "d"] {
    @io.sink_parquet(
      typed.to_lazy(),
      "\{typed_root}/\{key}",
      partition=@io.PartitionBy::PartitionBy(key=[key]),
    ) catch {
      e => fail("the key \{key} refused: \{e}")
    }
  }
  assert_eq(part_files("\{typed_root}/f"), [
    "f=0.25/00000000.parquet", "f=1.5/00000000.parquet",
  ])
  assert_eq(part_files("\{typed_root}/b"), [
    "b=false/00000000.parquet", "b=true/00000000.parquet",
  ])
  assert_eq(part_files("\{typed_root}/d"), [
    "d=1969-12-31/00000000.parquet", "d=1970-01-01/00000000.parquet",
  ])
}

///|
test "a CSV partition carries the header in every file, and the rows read back" {
  let root = part_root("csv_key")
  @io.sink_csv(
    part_frame().to_lazy(),
    root,
    partition=@io.PartitionBy::PartitionBy(key=["region"]),
  )
  assert_eq(part_files(root), [
    "region=Americas/00000000.csv", "region=Europe/00000000.csv", "region=__HIVE_DEFAULT_PARTITION__/00000000.csv",
  ])
  let text = @fs.read_file_to_string("\{root}/region=Americas/00000000.csv") catch {
    _ => ""
  }
  assert_eq(text, "region,year,qty\nAmericas,2020,1\nAmericas,2021,3\n")
  // The other options ride every file as they ride the single one.
  let options = CsvWriteOptions::CsvWriteOptions(
    header=false,
    delimiter=';',
    null_value="NA",
  )
  let other = part_root("csv_options")
  @io.sink_csv(
    part_frame().to_lazy(),
    other,
    options~,
    partition=@io.PartitionBy::PartitionBy(key=["year"]),
  )
  let semicolons = @fs.read_file_to_string("\{other}/year=2020/00000000.csv") catch {
    _ => ""
  }
  assert_eq(semicolons, "Americas;2020;1\nEurope;2020;2\nNA;2020;4\n")
}

///|
test "an IPC partition writes a payload a file, an NDJSON partition a file of lines" {
  let root = part_root("ipc_key")
  @io.sink_ipc(
    part_frame().to_lazy(),
    root,
    compression=IpcCompression::Lz4,
    partition=@io.PartitionBy::PartitionBy(key=["region"], include_key=false),
  )
  assert_eq(part_files(root), [
    "region=Americas/00000000.ipc", "region=Europe/00000000.ipc", "region=__HIVE_DEFAULT_PARTITION__/00000000.ipc",
  ])
  let americas = @io.read_ipc("\{root}/region=Americas/00000000.ipc")
  assert_eq(americas.columns(), ["year", "qty"])
  assert_eq(americas.shape(), (2, 2))
  let lines = part_root("ndjson_max")
  @io.sink_ndjson(
    part_frame().to_lazy(),
    lines,
    partition=@io.PartitionBy::PartitionBy(max_rows_per_file=3),
  )
  assert_eq(part_files(lines), ["00000000.jsonl", "00000001.jsonl"])
  let first = @fs.read_file_to_string("\{lines}/00000000.jsonl") catch {
    _ => ""
  }
  assert_eq(
    first, "{\"region\":\"Americas\",\"year\":2020,\"qty\":1}\n{\"region\":\"Europe\",\"year\":2020,\"qty\":2}\n{\"region\":\"Americas\",\"year\":2021,\"qty\":3}\n",
  )
  let second = @io.read_ndjson("\{lines}/00000001.jsonl")
  assert_eq(second.shape(), (1, 3))
}

///|
test "a plan that answers no row: no directory under a key, one empty file without one" {
  let df = part_frame()
  let empty = df.filter(@expr.lit_bool(false)).to_lazy()
  let keyed = part_root("empty_key")
  @io.sink_parquet(
    empty,
    keyed,
    partition=@io.PartitionBy::PartitionBy(key=["region"]),
  )
  assert_false(@fs.path_exists(keyed))
  let plain = part_root("empty_plain")
  @io.sink_parquet(empty, plain, partition=@io.PartitionBy::PartitionBy())
  assert_eq(part_files(plain), ["00000000.parquet"])
  assert_eq(@io.read_parquet("\{plain}/00000000.parquet").shape(), (0, 3))
  // The other formats answer their empty file too, a CSV one its header.
  let csv = part_root("empty_csv")
  @io.sink_csv(
    empty,
    csv,
    partition=@io.PartitionBy::PartitionBy(max_rows_per_file=2),
  )
  assert_eq(part_files(csv), ["00000000.csv"])
  let text = @fs.read_file_to_string("\{csv}/00000000.csv") catch { _ => "" }
  assert_eq(text, "region,year,qty\n")
}

///|
test "a plan of no column: its rows go to one file, and a key names nothing" {
  let rows = @frame.DataFrame::from_parts([], 3)
  let root = part_root("nocolumn")
  @io.sink_parquet(
    rows.to_lazy(),
    root,
    partition=@io.PartitionBy::PartitionBy(max_rows_per_file=2),
  )
  assert_eq(part_files(root), ["00000000.parquet", "00000001.parquet"])
  assert_eq(@io.read_parquet("\{root}/00000000.parquet").shape(), (2, 0))
  assert_eq(@io.read_parquet("\{root}/00000001.parquet").shape(), (1, 0))
  let keyed = part_root("nocolumn_key")
  assert_eq(
    part_error(() => {
      @io.sink_parquet(
        rows.to_lazy(),
        keyed,
        partition=@io.PartitionBy::PartitionBy(key=["k"]),
      )
    }),
    @types.DataError::ColumnNotFound("k"),
  )
}

///|
test "a key the plan does not carry is the frame's own refusal; so are a limit that holds no row and a key naming no column" {
  let df = part_frame()
  assert_eq(
    part_error(() => {
      @io.sink_parquet(
        df.to_lazy(),
        "_build/partsink_missing",
        partition=@io.PartitionBy::PartitionBy(key=["region", "nope"]),
      )
    }),
    @types.DataError::ColumnNotFound("nope"),
  )
  assert_eq(
    part_error(() => {
      @io.sink_csv(
        df.to_lazy(),
        "_build/partsink_limit",
        partition=@io.PartitionBy::PartitionBy(max_rows_per_file=0),
      )
    }),
    @types.DataError::InvalidOperation(
      "sink: max_rows_per_file is 0, where a file holds at least one row",
    ),
  )
  assert_eq(
    part_error(() => {
      @io.sink_ndjson(
        df.to_lazy(),
        "_build/partsink_nokey",
        partition=@io.PartitionBy::PartitionBy(key=[]),
      )
    }),
    @types.DataError::InvalidOperation(
      "sink: the partition key names no column",
    ),
  )
  // A base path that cannot be a directory is the write's IoError.
  let blocked = "_build/partsink_blocked_file"
  @fs.write_string_to_file(blocked, "a file where a directory should go") catch {
    _ => ()
  }
  let refused = part_error(() => {
    @io.sink_parquet(
      df.to_lazy(),
      "\{blocked}/sub",
      partition=@io.PartitionBy::PartitionBy(),
    )
  })
  assert_true(refused is @types.DataError::IoError(_))
}

///|
test "a key's rows across batches land in one directory, in order" {
  // A scanned file's rows arrive in several batches; a key cycling through
  // three values meets each batch.
  let rows : Array[Int64] = []
  let keys : Array[String] = []
  for i in 0..<12000 {
    rows.push(i.to_int64())
    keys.push(["a", "b", "c"][i % 3])
  }
  let source = @frame.DataFrame::DataFrame([
    @series.Series::from_ints("i", rows),
    @series.Series::from_strings("k", keys),
  ])
  let path = "_build/partsink_many.csv"
  @io.write_csv(path, source)
  let root = part_root("many")
  @io.sink_parquet(
    @io.scan_csv(path),
    root,
    partition=@io.PartitionBy::PartitionBy(key=["k"]),
  )
  assert_eq(part_files(root), [
    "k=a/00000000.parquet", "k=b/00000000.parquet", "k=c/00000000.parquet",
  ])
  let a = @io.read_parquet("\{root}/k=a/00000000.parquet")
  assert_eq(a.shape(), (4000, 2))
  assert_eq(a.get_column("i").to_scalars()[0], @types.Scalar::Int(0))
  assert_eq(a.get_column("i").to_scalars()[3999], @types.Scalar::Int(11997))
}

///|
test "PartitionBy answers its fields as copies, and defaults to one file with the key kept" {
  let names = ["region", "year"]
  let parts = @io.PartitionBy::PartitionBy(key=names, max_rows_per_file=10)
  names[0] = "changed"
  names.clear()
  assert_eq(parts.key(), Some(["region", "year"]))
  let back = parts.key().unwrap()
  back[1] = "changed"
  assert_eq(parts.key(), Some(["region", "year"]))
  assert_eq(parts.include_key(), true)
  assert_eq(parts.max_rows_per_file(), Some(10))
  let defaults = @io.PartitionBy::PartitionBy()
  assert_eq(defaults.key(), None)
  assert_eq(defaults.include_key(), true)
  assert_eq(defaults.max_rows_per_file(), None)
  assert_eq(defaults, @io.PartitionBy::PartitionBy(include_key=true))
}

///|
/// A directory where a file was going to go: the base directory the sink
/// writes into, and inside it one named as the file — so the file cannot be
/// written.
fn part_block(base : String, name : String) -> Unit raise @types.DataError {
  @fs.create_dir(base) catch {
    _ => ()
  }
  @fs.create_dir("\{base}/\{name}") catch {
    @fs.IOError(msg) => raise @types.DataError::IoError(msg)
  }
}

///|
test "a file's write that fails is the IoError of each format" {
  // A directory sitting where the file should go: the directory is made,
  // the file is not.
  let df = part_frame()
  let parquet = part_root("blocked_parquet")
  part_block(parquet, "00000000.parquet")
  assert_true(
    part_error(() => {
      @io.sink_parquet(
        df.to_lazy(),
        parquet,
        partition=@io.PartitionBy::PartitionBy(),
      )
    })
    is @types.DataError::IoError(_),
  )
  let ipc = part_root("blocked_ipc")
  part_block(ipc, "00000000.ipc")
  assert_true(
    part_error(() => {
      @io.sink_ipc(df.to_lazy(), ipc, partition=@io.PartitionBy::PartitionBy())
    })
    is @types.DataError::IoError(_),
  )
}

///|
test "a base path with doubled separators names the directory its letters spell" {
  let root = part_root("doubled")
  let df = part_frame()
  @io.sink_parquet(
    df.to_lazy(),
    "\{root}//inner/",
    partition=@io.PartitionBy::PartitionBy(key=["region"]),
  )
  assert_eq(part_files("\{root}/inner"), [
    "region=Americas/00000000.parquet", "region=Europe/00000000.parquet", "region=__HIVE_DEFAULT_PARTITION__/00000000.parquet",
  ])
}
