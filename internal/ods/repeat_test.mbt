// Blackbox tests of a row's own repeat count: a row with values stands
// for as many rows as it says, a repeat of zero for none, and what
// follows lands after them.

///|
test "a repeated row with values stands for as many rows, and a repeat of zero for none" {
  let twice = "<table:table-row table:number-rows-repeated=\"2\">" +
    xnumber("1") +
    xnumber("2") +
    "</table:table-row>"
  cells_are(body_package(xtable("S", twice + xrow(xnumber("3")))), [
    "0,0 Number 3ff0000000000000", "0,1 Number 4000000000000000", "1,0 Number 3ff0000000000000",
    "1,1 Number 4000000000000000", "2,0 Number 4008000000000000",
  ])
  // A repeat of zero: no row, no cell — and the five empty rows before it
  // still become rows of the sheet, since a row with a value follows them.
  cells_are(
    body_package(
      xtable(
        "S",
        "<table:table-row table:number-rows-repeated=\"5\"/>" +
        "<table:table-row table:number-rows-repeated=\"0\">" +
        xnumber("9") +
        "</table:table-row>" +
        xrow(xnumber("1")) +
        xrow(xnumber("4")),
      ),
    ),
    ["5,0 Number 3ff0000000000000", "6,0 Number 4010000000000000"],
  )
  // A cell of zero columns inside a row: nothing, and the cells after it
  // take their places.
  cells_are(
    body_package(
      xtable(
        "S",
        xrow(
          xnumber("1") +
          "<table:table-cell office:value-type=\"float\" office:value=\"8\" table:number-columns-repeated=\"0\"/>" +
          xnumber("2"),
        ),
      ),
    ),
    ["0,0 Number 3ff0000000000000", "0,1 Number 4000000000000000"],
  )
  // The count is read once, at the row's start: cells after the first row
  // it stands for are that row's.
  let thrice = "<table:table-row table:number-rows-repeated=\"3\">" +
    xnumber("1") +
    "<table:table-cell table:number-columns-repeated=\"2\"/>" +
    xnumber("5") +
    "</table:table-row>"
  cells_are(body_package(xtable("S", thrice)), [
    "0,0 Number 3ff0000000000000", "0,3 Number 4014000000000000", "1,0 Number 3ff0000000000000",
    "1,3 Number 4014000000000000", "2,0 Number 3ff0000000000000", "2,3 Number 4014000000000000",
  ])
}
