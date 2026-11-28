// Blackbox tests for `DataFrame::to_latex` / `to_latex`.
//
// The renderer is deterministic — a given DataFrame plus options maps to
// fixed output bytes — so each aspect is pinned with an exact-string
// assertion: the shape edge cases, the null spelling, escaping (and its
// bypass), the column selection and the omitted header, the `table`
// wrapper, the `longtable`, the index column and its bold spelling, and the
// decimal separator.

///|
/// A frame of a string column with the reserved characters among its cells,
/// an integer, a float and a boolean column, a null in the float.
fn latex_frame() -> DataFrame raise @types.DataError {
  DataFrame::DataFrame([
    Series::from_strings("name", ["a_1", "b&c", ""]),
    Series::from_ints("qty", [1, 2, 3]),
    Series::from_float_options("ratio", [Some(1.5), None, Some(2.25)]),
    Series::from_bools("flag", [true, false, true]),
  ])
}

///|
test "to_latex: default is a booktabs tabular with an index column and a derived specification" {
  let df = latex_frame()
  let expected =
    #|\begin{tabular}{llrrl}
    #|\toprule
    #| & name & qty & ratio & flag \\
    #|\midrule
    #|0 & a\_1 & 1 & 1.5 & true \\
    #|1 & b\&c & 2 & NaN & false \\
    #|2 &  & 3 & 2.25 & true \\
    #|\bottomrule
    #|\end{tabular}
    #|
  assert_eq(df.to_latex(), expected)
  // The options built by default are the options applied by default.
  assert_eq(df.to_latex(options=LatexOptions::LatexOptions()), df.to_latex())
}

///|
test "to_latex: a caption, a label and a placement wrap the tabular in a table" {
  let df = latex_frame()
  let expected =
    #|\begin{table}[htbp]
    #|\caption{Sales}
    #|\label{tab:sales}
    #|\begin{tabular}{lrrr}
    #|\toprule
    #|name & qty & ratio & flag \\
    #|\midrule
    #|a\_1 & 1 & 1.5 & true \\
    #|b\&c & 2 & NaN & false \\
    #| & 3 & 2.25 & true \\
    #|\bottomrule
    #|\end{tabular}
    #|\end{table}
    #|
  let options = LatexOptions::LatexOptions(
    index=false,
    caption="Sales",
    label="tab:sales",
    position="htbp",
    column_format="lrrr",
  )
  assert_eq(df.to_latex(options~), expected)
}

///|
test "to_latex: a label alone wraps the table, without a caption line" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1])])
  let expected =
    #|\begin{table}
    #|\label{tab:one}
    #|\begin{tabular}{lr}
    #|\toprule
    #| & a \\
    #|\midrule
    #|0 & 1 \\
    #|\bottomrule
    #|\end{tabular}
    #|\end{table}
    #|
  assert_eq(
    df.to_latex(options=LatexOptions::LatexOptions(label="tab:one")),
    expected,
  )
}

///|
test "to_latex: a longtable carries its heads and feet, bold rows and its own null spelling" {
  let df = latex_frame()
  let expected =
    #|\begin{longtable}{llrrl}
    #|\caption{Sales} \label{tab:sales} \\
    #|\toprule
    #| & name & qty & ratio & flag \\
    #|\midrule
    #|\endfirsthead
    #|\caption[]{Sales} \\
    #|\toprule
    #| & name & qty & ratio & flag \\
    #|\midrule
    #|\endhead
    #|\midrule
    #|\multicolumn{5}{r}{Continued on next page} \\
    #|\midrule
    #|\endfoot
    #|\bottomrule
    #|\endlastfoot
    #|\textbf{0} & a\_1 & 1 & 1.5 & true \\
    #|\textbf{1} & b\&c & 2 & - & false \\
    #|\textbf{2} &  & 3 & 2.25 & true \\
    #|\end{longtable}
    #|
  let options = LatexOptions::LatexOptions(
    longtable=true,
    caption="Sales",
    label="tab:sales",
    bold_rows=true,
    na_rep="-",
  )
  assert_eq(df.to_latex(options~), expected)
}

///|
test "to_latex: a longtable without a caption, a header or an index" {
  let df = latex_frame()
  let expected =
    #|\begin{longtable}[t]{lrrl}
    #|\toprule
    #|\endfirsthead
    #|\toprule
    #|\endhead
    #|\midrule
    #|\multicolumn{4}{r}{Continued on next page} \\
    #|\midrule
    #|\endfoot
    #|\bottomrule
    #|\endlastfoot
    #|a\_1 & 1 & 1.5 & true \\
    #|b\&c & 2 & NaN & false \\
    #| & 3 & 2.25 & true \\
    #|\end{longtable}
    #|
  let options = LatexOptions::LatexOptions(
    longtable=true,
    header=false,
    index=false,
    position="t",
  )
  assert_eq(df.to_latex(options~), expected)
}

///|
test "to_latex: without a header the tabular has no rule under the top rule" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1, 2])])
  let expected =
    #|\begin{tabular}{lr}
    #|\toprule
    #|0 & 1 \\
    #|1 & 2 \\
    #|\bottomrule
    #|\end{tabular}
    #|
  assert_eq(
    df.to_latex(options=LatexOptions::LatexOptions(header=false)),
    expected,
  )
}

///|
test "to_latex: escape=false passes a name and a cell through as written" {
  let df = DataFrame::DataFrame([
    Series::from_strings("a_1", ["b&c", "\\emph{x}"]),
  ])
  let expected =
    #|\begin{tabular}{ll}
    #|\toprule
    #| & a_1 \\
    #|\midrule
    #|0 & b&c \\
    #|1 & \emph{x} \\
    #|\bottomrule
    #|\end{tabular}
    #|
  assert_eq(
    df.to_latex(options=LatexOptions::LatexOptions(escape=false)),
    expected,
  )
}

///|
test "to_latex: every reserved character is escaped, and a line break becomes a space" {
  let text = "a&b%c$d#e_f{g}h~i^j\\k\nl"
  let df = DataFrame::DataFrame([Series::from_strings(text, [text])])
  let escaped = "a\\&b\\%c\\$d\\#e\\_f\\{g\\}h\\textasciitilde i\\textasciicircum j\\textbackslash k l"
  // The header names the column once and the row spells the cell once, each
  // as the escaped text.
  let expected = "\\begin{tabular}{ll}\n\\toprule\n & \{escaped} \\\\\n\\midrule\n0 & \{escaped} \\\\\n\\bottomrule\n\\end{tabular}\n"
  assert_eq(df.to_latex(), expected)
}

///|
test "to_latex: a caption, a label and a column format are written as given" {
  let df = DataFrame::DataFrame([Series::from_ints("a", [1])])
  let rendered = df.to_latex(
    options=LatexOptions::LatexOptions(
      caption="Sales_2020 & Share",
      label="tab:sales",
      column_format="|r|",
      index=false,
    ),
  )
  // The column name `a` needs no escaping; the caption keeps its underscore
  // and its ampersand, for the caller to command.
  assert_eq(
    rendered.has_prefix(
      "\\begin{table}\n\\caption{Sales_2020 & Share}\n\\label{tab:sales}\n\\begin{tabular}{|r|}\n\\toprule\n",
    ),
    true,
  )
}

///|
test "to_latex: a column subset in the order named, with the decimal separator" {
  let df = latex_frame()
  let expected =
    #|\begin{tabular}{rl}
    #|\toprule
    #|ratio & name \\
    #|\midrule
    #|1,5 & a\_1 \\
    #|NaN & b\&c \\
    #|2,25 &  \\
    #|\bottomrule
    #|\end{tabular}
    #|
  let options = LatexOptions::LatexOptions(
    columns=["ratio", "name"],
    index=false,
    decimal=",",
  )
  assert_eq(df.to_latex(options~), expected)
}

///|
test "to_latex: a decimal takes the separator too, and the other values keep their spellings" {
  let df = DataFrame::DataFrame([
    Series::from_decimals("dec", [
      Some(@types.Dec128::of_int64_scale(125L, scale=2)),
      Some(@types.Dec128::of_int64_scale(-50L, scale=2)),
    ]),
    Series::from_date_options("day", [Some(0L), None]),
    Series::from_timestamp_options("at", [Some(61500000L), Some(-1000L)]),
    Series::from_duration_options("span", [Some(86400000000L), None]),
  ])
  let expected =
    #|\begin{tabular}{lrlll}
    #|\toprule
    #| & dec & day & at & span \\
    #|\midrule
    #|0 & 1,25 & 1970-01-01 & 1970-01-01T00:01:01.500000 & P1DT0.000000S \\
    #|1 & -0,50 & NaN & 1969-12-31T23:59:59.999000 & NaN \\
    #|\bottomrule
    #|\end{tabular}
    #|
  assert_eq(
    df.to_latex(options=LatexOptions::LatexOptions(decimal=",")),
    expected,
  )
}

///|
test "to_latex: a derived specification gives numbers r and every other dtype l" {
  let schema = @types.Schema::Schema([
    @types.Field::Field("i", @types.DataType::Int),
    @types.Field::Field("f", @types.DataType::Float),
    @types.Field::Field("b", @types.DataType::Bool),
    @types.Field::Field("s", @types.DataType::String),
    @types.Field::Field("d", @types.DataType::Date),
    @types.Field::Field("t", @types.DataType::Timestamp),
    @types.Field::Field("m", @types.DataType::Decimal),
    @types.Field::Field("u", @types.DataType::Duration),
    @types.Field::Field("l", @types.DataType::List(@types.DataType::Int)),
    @types.Field::Field(
      "r",
      @types.DataType::Struct(
        @types.Schema::Schema([@types.Field::Field("x", @types.DataType::Int)]),
      ),
    ),
  ])
  let df = DataFrame::empty(schema)
  let expected =
    #|\begin{tabular}{rrllllrlll}
    #|\toprule
    #|i & f & b & s & d & t & m & u & l & r \\
    #|\midrule
    #|\bottomrule
    #|\end{tabular}
    #|
  assert_eq(
    df.to_latex(options=LatexOptions::LatexOptions(index=false)),
    expected,
  )
}

///|
test "to_latex: a frame with nothing to tabulate is the empty string" {
  // A column-less frame has no cells to draw, at any height.
  let empty = DataFrame::empty(@types.Schema::Schema([]))
  assert_eq(empty.to_latex(), "")
  // A selection naming no column draws none, at any height.
  let df = latex_frame()
  assert_eq(df.to_latex(options=LatexOptions::LatexOptions(columns=[])), "")
}

///|
test "to_latex: columns with no row render as the header and the rules" {
  let schema = @types.Schema::Schema([
    @types.Field::Field("a", @types.DataType::Int),
    @types.Field::Field("b", @types.DataType::String),
  ])
  let df = DataFrame::empty(schema)
  let expected =
    #|\begin{tabular}{lrl}
    #|\toprule
    #| & a & b \\
    #|\midrule
    #|\bottomrule
    #|\end{tabular}
    #|
  assert_eq(df.to_latex(), expected)
}

///|
test "to_latex: a column the frame does not carry is the frame's own refusal" {
  let df = latex_frame()
  let outcome : Result[_, @types.DataError] = Ok(
    ignore(
      df.to_latex(options=LatexOptions::LatexOptions(columns=["qty", "nope"])),
    ),
  ) catch {
    e => Err(e)
  }
  assert_eq(outcome, Err(@types.DataError::ColumnNotFound("nope")))
}

///|
test "LatexOptions: the columns are a copy at both ends" {
  let named = ["qty", "name"]
  let options = LatexOptions::LatexOptions(columns=named)
  // Mutating the array the constructor was handed cannot alter the options.
  named[0] = "changed"
  named.clear()
  assert_eq(options.columns(), Some(["qty", "name"]))
  // The accessor answers a copy: mutating it cannot alter the options either.
  let back = options.columns().unwrap()
  back[1] = "changed"
  assert_eq(options.columns(), Some(["qty", "name"]))
  // Omitted, the options carry no selection.
  assert_eq(LatexOptions::LatexOptions().columns(), None)
}
