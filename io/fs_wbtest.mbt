// The gzip choke point's own refusal: the per-format suites cover the
// happy path end to end (a `.gz` written by `write_text` read back by
// `read_csv` / `read_json` / `read_ndjson`), but the output cap fires only
// past a production-sized expansion, which no end-to-end test should pay
// for — so the cap is parameterised and these tests drive the same core
// `gunzip_bytes` delegates to with a small one.

///|
test "a gzip expansion past the output cap refuses" {
  // 100 KB of one byte compresses to a few hundred; the 1 KB cap refuses
  // once the inflater has produced past it — the same refusal the
  // production 1 GiB cap takes on a real bomb, at a test-sized price.
  let bomb = @gzip.compress(Bytes::makei(100_000, _ => b'a'))
  let result = Ok(ignore(gunzip_bytes_capped("bomb.csv.gz", bomb, 1000))) catch {
    e => Err(e)
  }
  assert_true(result is Err(@types.DataError::ParseError(_)))
}

///|
test "a gzip expansion under the output cap decompresses" {
  let plain = @gzip.compress(b"a,b\n1,2\n")
  let out = gunzip_bytes_capped("small.csv.gz", plain, 0x4000_0000)
  assert_eq(out, b"a,b\n1,2\n")
}

///|
test "a plain file passes through the capped gunzip untouched" {
  // The magic sniff runs before the cap: content that does not claim gzip
  // is returned as-is whatever the cap is.
  let out = gunzip_bytes_capped("plain.csv", b"a,b\n1,2\n", 1)
  assert_eq(out, b"a,b\n1,2\n")
}
