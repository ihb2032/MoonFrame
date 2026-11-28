// The ORC file reader: the file tail (the PostScript, the Footer and its
// type tree, the stripes' information), each stripe's footer and streams
// under the compression kinds NONE, ZLIB, SNAPPY, LZ4 and ZSTD, the run
// length encodings of the version 0.11 and 0.12 formats, and the cells'
// mapping to columns. Row indexes, statistics and bloom filters are
// stepped over: nothing of them is read.
