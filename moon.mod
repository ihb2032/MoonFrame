name = "ihb2032/MoonFrame"

version = "0.5.5"

supported_targets = [ "wasm", "wasm-gc", "js", "native" ]

warnings = "+a-unnecessary_annotation-test_unqualified_package-unqualified_local_using-missing_invariant-missing_reasoning"

import {
  "moonbitlang/x@0.4.43",
  "moonbit-community/NyaCSV@0.3.3",
  "moonbitlang/quickcheck@0.14.0",
}

readme = "README.md"

repository = "https://github.com/ihb2032/MoonFrame"

license = "Apache-2.0"

keywords = [ "dataframe", "data-analysis", "csv", "tabular" ]

description = "A lightweight DataFrame and tabular-data library for MoonBit"
