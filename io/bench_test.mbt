// Micro-benchmarks for the in-memory string parsers — `parse_csv_str` and
// `parse_ndjson_str`. Run them with `moon bench`; under `moon test` every
// block executes once, so the benches stay compiled and cannot bit-rot.

///|
/// A CSV document: an `id,key,value,label` header followed by `n` data rows.
fn csv_doc(n : Int) -> String {
  let sb = StringBuilder::new()
  sb.write_string("id,key,value,label\n")
  for i in 0..<n {
    sb.write_string("\{i},\{i % 1000},\{(i * 7 + 3) % 100000},row\{i}\n")
  }
  sb.to_string()
}

///|
/// An NDJSON document of the same shape — one JSON object per line.
fn ndjson_doc(n : Int) -> String {
  let sb = StringBuilder::new()
  for i in 0..<n {
    sb.write_string(
      "{\"id\":\{i},\"key\":\{i % 1000},\"value\":\{(i * 7 + 3) % 100000},\"label\":\"row\{i}\"}\n",
    )
  }
  sb.to_string()
}

///|
test "parse_csv_str scaling" (b : @bench.T) {
  let fallback = parse_csv_str("id\n0\n", CsvReadOptions::default())
  for n in [1000, 10000, 100000] {
    let doc = csv_doc(n)
    b.bench(name="parse_csv_str/\{n}", () => {
      b.keep(
        parse_csv_str(doc, CsvReadOptions::default()) catch {
          _ => fallback
        },
      )
    })
  }
}

///|
test "parse_ndjson_str scaling" (b : @bench.T) {
  let fallback = parse_ndjson_str("{\"id\":0}\n", NdjsonReadOptions::default())
  for n in [1000, 10000, 100000] {
    let doc = ndjson_doc(n)
    b.bench(name="parse_ndjson_str/\{n}", () => {
      b.keep(
        parse_ndjson_str(doc, NdjsonReadOptions::default()) catch {
          _ => fallback
        },
      )
    })
  }
}
