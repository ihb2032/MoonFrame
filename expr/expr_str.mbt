///|
/// The `.str_*` string namespace (Polars' `str` accessors), one method per
/// `StrOp` tag. Every `str_*` method builds a `Str` node over its tag,
/// evaluated cell by cell in `internal/kernel/str.mbt` and rendered by the
/// `Str` arm in `explain.mbt`; the family's expression-layer tests live in
/// `expr_str_test.mbt`, the per-cell evaluation semantics in
/// `frame/str_ops_test.mbt`.

///|
/// Uppercase the **ASCII** letters of a String column — the shape of
/// Polars' `str.to_uppercase`, but case mapping is currently ASCII-only
/// (like `str_strip_chars`' ASCII whitespace set): a non-ASCII letter
/// (`é`, `ß`, Cyrillic, …) passes through unchanged rather than mapping.
/// Null cells stay null, the result keeps the operand's column name, and a
/// non-String operand is a `TypeMismatch` at evaluation. The leading method
/// of the string namespace.
pub fn Expr::str_to_uppercase(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::ToUppercase, self.node))
}

///|
/// Lowercase the **ASCII** letters of a String column (the shape of Polars'
/// `str.to_lowercase`, with `str_to_uppercase`'s ASCII-only case-mapping
/// caveat), the case mirror of `str_to_uppercase`.
pub fn Expr::str_to_lowercase(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::ToLowercase, self.node))
}

///|
/// Strip leading and trailing characters from every cell of a String column —
/// Polars' `str.strip_chars`. With `chars` omitted, the default set is ASCII
/// whitespace (tab, newline, carriage-return, space); with `chars` given, every
/// character in that string is a strip target (order and repeats do not
/// matter). Null cells stay null.
pub fn Expr::str_strip_chars(self : Expr, chars? : String) -> Expr {
  match chars {
    None => Expr::of(@ir.ExprNode::Str(@ir.StrOp::StripChars, self.node))
    Some(set) =>
      Expr::of(@ir.ExprNode::Str(@ir.StrOp::StripCharsCustom(set), self.node))
  }
}

///|
/// The number of Unicode characters in each cell of a String column, as an
/// `Int` (Polars `str.len_chars`): a supplementary-plane character counts
/// once, not as its two UTF-16 code units. Null cells stay null; an all-valid
/// result rides the `Numeric` fast path like every computed numeric column.
pub fn Expr::str_len_chars(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::LenChars, self.node))
}

///|
/// The number of **UTF-8 bytes** in each cell of a String column, as an `Int`
/// (Polars `str.len_bytes`) — the encoded byte length, so an ASCII character is
/// 1, a `é` is 2, and a supplementary-plane emoji is 4 (vs `str_len_chars`,
/// which counts every character as 1). Null cells stay null; an all-valid
/// result rides the `Numeric` fast path.
pub fn Expr::str_len_bytes(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::LenBytes, self.node))
}

///|
/// The `index`-th field of each cell split on the literal separator `sep`, as a
/// nullable `String` (a scalar slice of Polars' `str.split`, which returns a
/// list this repo has no dtype for). `index` is 0-based; a cell with fewer than
/// `index + 1` fields (or a negative `index`) yields **null**. `"a,b,c"` split
/// on `","` at index 1 is `"b"`. Null cells stay null.
pub fn Expr::str_split_get(self : Expr, sep : String, index : Int) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::SplitGet(sep, index), self.node))
}

///|
/// A `Bool` column that is `true` where the cell contains `pattern` — Polars'
/// `str.contains`. `literal` defaults to `true`, matching `pattern` as a plain
/// substring; `literal=false` reads it as a **POSIX** regular expression (the
/// core engine's dialect, so character classes are `[[:digit:]]` /
/// `[[:alpha:]]`, not the PCRE `\d` / `\w`, which raise). The default is the
/// opposite of Polars', which is regex-first. A regex is compiled once per
/// evaluation, so an invalid pattern raises `InvalidOperation` then. Null cells
/// stay null.
pub fn Expr::str_contains(
  self : Expr,
  pattern : String,
  literal? : Bool = true,
) -> Expr {
  if literal {
    Expr::of(@ir.ExprNode::Str(@ir.StrOp::Contains(pattern), self.node))
  } else {
    Expr::of(@ir.ExprNode::Str(@ir.StrOp::ContainsRegex(pattern), self.node))
  }
}

///|
/// A `Bool` column that is `true` where the cell starts with `prefix`
/// (Polars `str.starts_with`). Null cells stay null.
pub fn Expr::str_starts_with(self : Expr, prefix : String) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::StartsWith(prefix), self.node))
}

///|
/// A `Bool` column that is `true` where the cell ends with `suffix`
/// (Polars `str.ends_with`). Null cells stay null.
pub fn Expr::str_ends_with(self : Expr, suffix : String) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::EndsWith(suffix), self.node))
}

///|
/// Replace the first occurrence of `pattern` with `value` in each cell of a
/// String column — Polars' `str.replace`. `literal` defaults to `true` (plain
/// substring); `literal=false` reads `pattern` as a POSIX regular expression
/// (see `str_contains` for the dialect and the invalid-pattern error), with
/// `value` inserted literally — no capture-group references yet. A cell without
/// a match is unchanged; null cells stay null.
pub fn Expr::str_replace(
  self : Expr,
  pattern : String,
  value : String,
  literal? : Bool = true,
) -> Expr {
  if literal {
    Expr::of(@ir.ExprNode::Str(@ir.StrOp::Replace(pattern, value), self.node))
  } else {
    Expr::of(
      @ir.ExprNode::Str(@ir.StrOp::ReplaceRegex(pattern, value), self.node),
    )
  }
}

///|
/// Replace every occurrence of `pattern` with `value` in each cell (Polars
/// `str.replace_all`), the all-occurrences mirror of `str_replace` — including
/// its `literal` parameter and default.
pub fn Expr::str_replace_all(
  self : Expr,
  pattern : String,
  value : String,
  literal? : Bool = true,
) -> Expr {
  if literal {
    Expr::of(
      @ir.ExprNode::Str(@ir.StrOp::ReplaceAll(pattern, value), self.node),
    )
  } else {
    Expr::of(
      @ir.ExprNode::Str(@ir.StrOp::ReplaceAllRegex(pattern, value), self.node),
    )
  }
}

///|
/// Reverse the Unicode characters of each cell of a String column — Polars'
/// `str.reverse()`. Surrogate pairs are respected (reversal is by codepoint,
/// not UTF-16 unit); null cells stay null.
pub fn Expr::str_reverse(self : Expr) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::Reverse, self.node))
}

///|
/// Left-pad each cell of a String column with `fill` until it is `width`
/// **characters** long — Polars' `str.pad_start`. A cell already at least
/// `width` characters is unchanged (never truncated); null cells stay null.
/// The width counts characters, consistent with `str_len_chars`.
pub fn Expr::str_pad_start(
  self : Expr,
  width : Int,
  fill? : Char = ' ',
) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::PadStart(width, fill), self.node))
}

///|
/// Right-pad each cell of a String column with `fill` until it is `width`
/// **characters** long — Polars' `str.pad_end`, the mirror of `str_pad_start`.
pub fn Expr::str_pad_end(self : Expr, width : Int, fill? : Char = ' ') -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::PadEnd(width, fill), self.node))
}

///|
/// Left-pad each cell of a String column with `'0'` until it is `width`
/// **characters** long — Polars' `str.zfill`. Like `str_pad_start('0')` but
/// **sign-aware**: a leading `'+'` / `'-'` keeps its place and the zeros are
/// inserted *after* it (`"-5"` to width 4 is `"-005"`, not `"00-5"`). A cell
/// already at least `width` characters is unchanged (never truncated); null
/// cells stay null. The width counts characters, consistent with
/// `str_len_chars`.
pub fn Expr::str_zfill(self : Expr, width : Int) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::ZFill(width), self.node))
}

///|
/// Extract a substring matched by the POSIX regular expression `pattern` — a
/// nullable `String` column (Polars' `str.extract`). `group` (default `0`, the
/// **whole match** — Polars defaults to the first capture group `1` instead)
/// selects a capture group; a cell that does not match, or whose chosen group
/// did not participate, yields **null**. See `str_contains` for the regex
/// dialect and the invalid-pattern error; a null cell stays null and a
/// non-String operand raises `TypeMismatch`.
pub fn Expr::str_extract(
  self : Expr,
  pattern : String,
  group? : Int = 0,
) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::Extract(pattern, group), self.node))
}

///|
/// Count the non-overlapping matches of the POSIX regular expression `pattern`
/// in each cell — an `Int` column (Polars' `str.count_matches`), `0` where the
/// pattern does not match. An all-valid result rides the `Numeric` fast path,
/// like `str_len_chars`. See `str_contains` for the regex dialect and the
/// invalid-pattern error; a null cell stays null and a non-String operand
/// raises `TypeMismatch`.
pub fn Expr::str_count_matches(self : Expr, pattern : String) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::CountMatches(pattern), self.node))
}

///|
/// Substring of each cell by **character** position — Polars' `str.slice`.
/// `offset` is a 0-based character index; a negative `offset` counts from the
/// end (`-2` starts two characters before the end). `length` is the number of
/// characters (omitted → to the end); a `length` of zero or less yields the
/// empty string. Both are clamped to the cell — an `offset` past the end gives
/// `""`, and a `length` past the end stops at the end — so it never raises on a
/// value. Character-based (surrogate pairs are never split), consistent with
/// `str_len_chars`; a null cell stays null and a non-String operand raises
/// `TypeMismatch`.
pub fn Expr::str_slice(self : Expr, offset : Int, length? : Int) -> Expr {
  Expr::of(@ir.ExprNode::Str(@ir.StrOp::Slice(offset, length), self.node))
}
