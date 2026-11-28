// The BIFF8 workbook reader: the compound file that holds the workbook
// stream (its file allocation table, its directory, and the mini stream
// with its own table), the stream's records (the workbook globals with the
// shared string table, the number formats and the sheets' names and
// places; then one sheet's cells), and the cells' mapping to raw values —
// a text, a boolean, a number with its style's number format, or an
// error. Nothing is written and no formula is evaluated: a formula
// answers its cached value.
