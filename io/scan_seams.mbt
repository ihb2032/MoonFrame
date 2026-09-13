// The push-down contract behind the lazy scan sources — written once, in the
// place both format drivers (`scan_driver.mbt`) and the string-level
// projected cores they call (`parse_csv_str_projected` /
// `parse_ndjson_str_projected`, each living with its format) can be read
// against. What used to be four exported engine seams is now two driver
// records handed to `lazy`; the cores stay package-private to `io`.
//
// The contract both drivers honour — a pushed-down read differs from an
// eager read only in the work it skips, never in the frame it yields:
//
//   - Whole-input checks run first and see the full input: strict quote
//     validation, BOM stripping, the empty-input short-circuit, malformed
//     or non-object records, duplicate headers, the ragged-row guard. A
//     pushed-down read fails on malformed input exactly as a full one.
//   - Dtype inference always walks the whole file, so a pruned read locks
//     in the dtypes an eager `read_csv(..).filter(..)` would — the typed
//     build, not the inference, is what the push-down skips.
//   - The one observable trade is that same skipping: a `ParseError`
//     confined to a dropped column (projection) or to a row the predicate
//     drops in a column it does not read (pruning) never surfaces,
//     because those cells are never parsed.
//   - Row identity survives pruning: each kept record's original file
//     row / line threads through to the error locator, so a parse error
//     in a kept row still reports its true position.
//   - The pruned read reuses its already-built key columns rather than
//     parsing them a second time (`assemble_pruned_frame` phase 2).
//
// A new format's driver follows this contract and this file's shape: one
// read per push-down combination over the string-level core in its own
// format file.
