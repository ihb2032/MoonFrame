///|
/// The string-namespace kernel: apply a `@expr.StrOp` to each cell of a String
/// operand — case, `strip_chars` (default or custom charset), `len_chars` /
/// `len_bytes`, `reverse`, `pad`, `slice`, `split_get`, the literal `contains` /
/// `starts_with` / `ends_with` predicates and `replace` / `replace_all`, and the
/// POSIX-regex `contains_regex` / `replace_regex` / `replace_all_regex` /
/// `extract` / `count_matches`. A non-String operand raises `TypeMismatch`, null
/// cells stay null. Literal / positional ops are per-value total; the regex ops
/// compile their pattern once (an invalid pattern raises `InvalidOperation`).

///|
/// Elementwise string-namespace kernel: apply `op` to each cell of a String
/// operand. The operand must be `String` — any other dtype is a
/// `TypeMismatch`, decided once for the whole column (scope-independent, so
/// the optimizer treats a `Str` node as row-stable). A null cell maps to a
/// null result; a present cell maps through the underlying total `String`
/// method, so no *value* can raise. `ToUppercase` / `ToLowercase` /
/// `StripChars` / `Replace` / `ReplaceAll` / `Reverse` / `PadStart` / `PadEnd` /
/// `ReplaceRegex` / `ReplaceAllRegex` produce a String column, `LenChars` an Int
/// (the Unicode character count — an all-valid result converges onto the
/// `Numeric` fast path like every computed numeric), and the `Contains` /
/// `StartsWith` / `EndsWith` / `ContainsRegex` predicates a Bool. The `*Regex`
/// ops compile their POSIX pattern **once** (hoisted out of the per-cell map),
/// so an invalid pattern raises `InvalidOperation` once per evaluation — the
/// only non-total path — while literal matching stays per-value total.
fn eval_str(
  op : @expr.StrOp,
  operand : Series,
) -> Series raise @types.DataError {
  let data = match operand.storage().data() {
    @column.ColumnData::String(a) => a
    @column.ColumnData::Int(_)
    | @column.ColumnData::Float(_)
    | @column.ColumnData::Bool(_) =>
      raise @types.DataError::TypeMismatch(
        "string operation requires a String operand, got \{operand.dtype()}",
      )
  }
  let valid = validity_bools(operand.storage())
  let name = operand.name()
  let n = data.length()
  let out = match op {
    @expr.StrOp::ToUppercase =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].to_upper()),
      )
    @expr.StrOp::ToLowercase =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].to_lower()),
      )
    @expr.StrOp::StripChars =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].trim().to_owned()),
      )
    @expr.StrOp::LenChars =>
      Series::from_int_options(
        name,
        map_present(n, valid, i => data[i].char_length().to_int64()),
      )
    @expr.StrOp::Contains(pattern) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].contains(pattern)),
      )
    @expr.StrOp::StartsWith(prefix) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].has_prefix(prefix)),
      )
    @expr.StrOp::EndsWith(suffix) =>
      Series::from_bool_options(
        name,
        map_present(n, valid, i => data[i].has_suffix(suffix)),
      )
    @expr.StrOp::Replace(pattern, value) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].replace(old=pattern, new=value)),
      )
    @expr.StrOp::ReplaceAll(pattern, value) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].replace_all(old=pattern, new=value)),
      )
    @expr.StrOp::Reverse =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].rev()),
      )
    @expr.StrOp::PadStart(width, fill) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => pad_start_chars(data[i], width, fill)),
      )
    @expr.StrOp::PadEnd(width, fill) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => pad_end_chars(data[i], width, fill)),
      )
    // The `*Regex` ops compile the pattern once here — outside `map_present`, so
    // an invalid pattern raises once per evaluation, never per cell — then run
    // it over each present cell (`String` cells auto-coerce to `StringView`).
    @expr.StrOp::ContainsRegex(pattern) => {
      let re = compile_regex(pattern)
      Series::from_bool_options(
        name,
        map_present(n, valid, i => re.execute(data[i]) is Some(_)),
      )
    }
    @expr.StrOp::ReplaceRegex(pattern, value) => {
      let re = compile_regex(pattern)
      Series::from_string_options(
        name,
        map_present(n, valid, i => {
          re.replace_by(data[i], _ => value, limit=1).to_owned()
        }),
      )
    }
    @expr.StrOp::ReplaceAllRegex(pattern, value) => {
      let re = compile_regex(pattern)
      Series::from_string_options(
        name,
        map_present(n, valid, i => re.replace_by(data[i], _ => value).to_owned()),
      )
    }
    // `Extract` nulls a present cell that does not match (or whose group is
    // absent), so it builds `Array[String?]` directly rather than through
    // `map_present`, whose `f` cannot itself produce a null.
    @expr.StrOp::Extract(pattern, group) => {
      let re = compile_regex(pattern)
      Series::from_string_options(
        name,
        Array::makei(n, i => {
          if valid[i] {
            extract_match(re, data[i], group)
          } else {
            None
          }
        }),
      )
    }
    @expr.StrOp::CountMatches(pattern) => {
      let re = compile_regex(pattern)
      Series::from_int_options(
        name,
        map_present(n, valid, i => re.find(data[i]).count().to_int64()),
      )
    }
    @expr.StrOp::Slice(offset, length) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => slice_chars(data[i], offset, length)),
      )
    @expr.StrOp::LenBytes =>
      Series::from_int_options(
        name,
        map_present(n, valid, i => @utf8.encode(data[i]).length().to_int64()),
      )
    @expr.StrOp::StripCharsCustom(chars) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => data[i].trim(chars~).to_owned()),
      )
    // `SplitGet` nulls a present cell that has no `index`-th field, so it builds
    // `Array[String?]` directly rather than through `map_present`.
    @expr.StrOp::SplitGet(sep, index) =>
      Series::from_string_options(
        name,
        Array::makei(n, i => {
          if valid[i] {
            split_get(data[i], sep, index)
          } else {
            None
          }
        }),
      )
    @expr.StrOp::ZFill(width) =>
      Series::from_string_options(
        name,
        map_present(n, valid, i => zfill_chars(data[i], width)),
      )
  }
  try_column_to_numeric(out)
}

///|
/// The `index`-th field of `s` split on the literal `sep`, as a `String?`:
/// `None` for a negative `index` or one past the last field (`str_split_get`).
fn split_get(s : String, sep : String, index : Int) -> String? {
  if index < 0 {
    None
  } else {
    s.split(sep).nth(index).map(v => v.to_owned())
  }
}

///|
/// Substring of `s` by **character** position (`str_slice`). `offset` is
/// 0-based; a negative `offset` counts from the end. `length` is a character
/// count (`None` = to the end, `<= 0` = empty). Both are clamped to `s`, so it
/// is total. Character-based — `iter` walks codepoints, so a surrogate pair is
/// never split — consistent with `char_length`.
fn slice_chars(s : String, offset : Int, length : Int?) -> String {
  let len = s.char_length()
  let start = if offset < 0 {
    let from_end = len + offset
    if from_end < 0 {
      0
    } else {
      from_end
    }
  } else if offset > len {
    len
  } else {
    offset
  }
  let count = match length {
    None => len - start
    Some(n) =>
      if n <= 0 {
        0
      } else if start + n > len {
        len - start
      } else {
        n
      }
  }
  String::from_iter(s.iter().drop(start).take(count))
}

///|
/// Extract the `group`-th capture (`0` = the whole match) of the first match of
/// `re` in `cell`, as a `String?`: `None` when the cell does not match or the
/// chosen group did not participate. Behind `Extract`; `re` is compiled once by
/// the caller.
fn extract_match(re : @string.Regex, cell : String, group : Int) -> String? {
  match re.execute(cell) {
    None => None
    Some(m) =>
      if group == 0 {
        Some(m.content().to_owned())
      } else {
        m.group(group).map(v => v.to_owned())
      }
  }
}

///|
/// Compile a regex `pattern` once, mapping the core engine's parse error to an
/// `InvalidOperation` — the `*Regex` string ops' one raising path, taken once
/// per evaluation, never per cell. The engine's dialect is POSIX, so a PCRE
/// class like `\d` is itself a parse error, surfaced here with the engine's own
/// message.
fn compile_regex(pattern : String) -> @string.Regex raise @types.DataError {
  @string.Regex::Regex(pattern) catch {
    e =>
      raise @types.DataError::InvalidOperation(
        "invalid regex pattern \"\{pattern}\": \{e}",
      )
  }
}

///|
/// Left-pad `s` with `fill` until it is `width` **characters** long, else
/// return it unchanged. Codepoint-based (`char_length` + `String::make`, both
/// counting characters), so the width is consistent with `str_len_chars` and
/// with Polars — unlike `String::pad_start`, whose width counts UTF-16 units.
fn pad_start_chars(s : String, width : Int, fill : Char) -> String {
  let len = s.char_length()
  if len >= width {
    s
  } else {
    "\{String::make(width - len, fill)}\{s}"
  }
}

///|
/// Right-pad `s` with `fill` until it is `width` characters long — the mirror
/// of `pad_start_chars`.
fn pad_end_chars(s : String, width : Int, fill : Char) -> String {
  let len = s.char_length()
  if len >= width {
    s
  } else {
    "\{s}\{String::make(width - len, fill)}"
  }
}

///|
/// Left-pad `s` with `'0'` to `width` **characters**, keeping a leading sign
/// ahead of the zeros — Polars' `str.zfill`. `"-5"` to width 4 is `"-005"`.
/// The width counts characters (sign included) and a cell already that wide is
/// returned unchanged. Delegates the zero-padding to `pad_start_chars`: with a
/// leading sign, the digits after it pad to a one-narrower field (the sign is a
/// single ASCII character, so `s[1:]` drops exactly it).
fn zfill_chars(s : String, width : Int) -> String {
  if s.has_prefix("-") {
    "-\{pad_start_chars(s[1:].to_owned(), width - 1, '0')}"
  } else if s.has_prefix("+") {
    "+\{pad_start_chars(s[1:].to_owned(), width - 1, '0')}"
  } else {
    pad_start_chars(s, width, '0')
  }
}
