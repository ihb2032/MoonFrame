# Arrow IPC integration samples

The samples MoonFrame's Arrow IPC reader is checked against, vendored from
[apache/arrow-testing](https://github.com/apache/arrow-testing) at commit
`5a26d35785ff8761e56d79eebff971f6f737e18c` (Apache-2.0): its
`data/arrow-ipc-stream/integration` directory. Each subdirectory is named
for the Arrow release its samples were written under. Inside one,
`generated_<name>.stream` is a sample in the stream framing,
`generated_<name>.arrow_file` a sample also vendored in the file framing,
and `generated_<name>.json.gz` the JSON golden both are compared with.

`io/ipc_golden_test.mbt` names the samples a test reads, and computes each
column's expected cells from the golden by the mapping `read_ipc`'s
docstring states — apart from the reader's own code, so a sample's cells
are checked against the format and not against the reader. A sample no
test names is not read, and does not belong here.
