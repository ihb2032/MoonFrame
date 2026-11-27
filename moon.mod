name = "ihb2032/MoonFrame"

version = "0.9.0"

supported_targets = [ "wasm", "wasm-gc", "js", "native" ]

warnings = "+a-unnecessary_annotation-test_unqualified_package-unqualified_local_using-missing_invariant-missing_reasoning"

import {
  "moonbitlang/x@0.5.6",
  "moonbit-community/NyaCSV@0.3.4",
  "moonbit-community/flate@0.10.0",
  "moonbitstack/moondb@0.3.1",
  "moonbitlang/mbtexcel@0.3.2",
  "gaato/lz4@0.1.1",
  "gaato/zstd@0.6.1",
  "gaato/snappy@0.1.1",
  "gaato/crc@0.1.1",
}

readme = "README.mbt.md"

repository = "https://github.com/ihb2032/MoonFrame"

license = "Apache-2.0"

keywords = [ "dataframe", "data-analysis", "csv", "tabular" ]

description = "A lightweight DataFrame and tabular-data library for MoonBit"
