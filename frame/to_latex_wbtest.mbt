// Whitebox pins for the LaTeX renderer's pieces the public entry cannot
// reach alone: the null dtype's alignment (no column is built with that
// dtype) and each scalar kind's cell spelling, one value at a time.

///|
test "a column of the null dtype aligns like every other non-number" {
  assert_eq(latex_alignment(@types.DataType::Null), 'l')
}

///|
test "a date, a timestamp, a duration, a list and a struct keep their scalar spellings" {
  let options = LatexOptions::LatexOptions()
  for
    cell in [
      @types.Scalar::Date(0L),
      @types.Scalar::Timestamp(61500000L),
      @types.Scalar::Duration(86400000000L),
      @types.Scalar::List(
        @types.ListValue::ListValue([@types.Scalar::Int(1), @types.Scalar::Null]),
      ),
      @types.Scalar::Struct(
        @types.StructValue::StructValue([
          @types.FieldValue::FieldValue("x", @types.Scalar::Int(1)),
        ]),
      ),
    ] {
    // The decimal separator touches a float and a decimal alone.
    assert_eq(latex_cell(cell, options), cell.to_string())
    assert_eq(
      latex_cell(cell, LatexOptions::LatexOptions(decimal=",")),
      cell.to_string(),
    )
  }
}

///|
test "the longtable's first head carries a caption and a label as given" {
  let buf = StringBuilder()
  latex_title(buf, LatexOptions::LatexOptions(caption="Sales", label="tab:s"))
  assert_eq(buf.to_string(), "\\caption{Sales} \\label{tab:s}")
  // Either alone; neither, an empty line's worth of nothing.
  let caption_only = StringBuilder()
  latex_title(caption_only, LatexOptions::LatexOptions(caption="Sales"))
  assert_eq(caption_only.to_string(), "\\caption{Sales}")
  let label_only = StringBuilder()
  latex_title(label_only, LatexOptions::LatexOptions(label="tab:s"))
  assert_eq(label_only.to_string(), "\\label{tab:s}")
}
