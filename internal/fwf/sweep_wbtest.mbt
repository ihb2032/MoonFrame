// Whitebox replay of the sweep the fixture generator recorded in
// `.github/fixtures/fwf/reference/sweep.json`: the truncations, the single-character
// replacements and the random texts of the malformed-input tests, drawn by
// the same generator from the same seeds, so that each case drawn here is
// a case the sidecar holds — with the boundaries the reference reader
// inferred for it, or its refusal, and its reader's cut of every line.
// the generator beside them replayed them through that reader. No call may
// abort: a marker line precedes each case and each test ends in its
// summary, so an abort shows as the summary missing.

///|
/// What the codec answered for one case of the sweep against what the
/// reference recorded for it: the refusal or the boundaries, then every
/// line's cut. Answers how many cells were compared.
fn check_case(
  place : String,
  lines : Array[String],
  spec : Json,
  differences : Array[String],
) -> Int32 raise @types.DataError {
  let refuses = field(spec, "refuses")
  match attempt(() => fwf_infer_layout(lines, 100)) {
    Refused(error) => {
      match refuses {
        Null =>
          differences.push(
            "\{place}: the codec refuses — \{error.message()} — where the reference reads it",
          )
        refusal => {
          let difference = refusal_difference(
            place,
            error,
            jstring(field(refusal, "message")),
            lines,
            100,
          )
          if difference != "" {
            differences.push(difference)
          }
        }
      }
      0
    }
    Answered(layout) =>
      if refuses is Null {
        let mine = boundaries(layout)
        let wanted = spelled_boundaries(jarray(field(spec, "colspecs")))
        if mine != wanted {
          differences.push(
            "\{place}: the codec lays out \{mine}, the reference \{wanted}",
          )
        }
        let cut = jarray(field(spec, "cut"))
        if cut.length() != lines.length() {
          differences.push(
            "\{place}: the sidecar cuts \{cut.length()} lines, the case has \{lines.length()}",
          )
          0
        } else {
          for i, line in lines {
            let cells = fwf_cut(line, layout)
            let theirs = spelled_cells(cut[i])
            if cells.join(" | ") != theirs {
              differences.push(
                "\{place}, line \{i}: the codec cuts \"\{cells.join(" | ")}\", the reference \"\{theirs}\"",
              )
            }
          }
          layout.len() * lines.length()
        }
      } else {
        differences.push(
          "\{place}: the codec answers \{boundaries(layout)} where the reference refuses: \{jstring(field(refuses, "message"))}",
        )
        0
      }
  }
}

///|
/// Whether the lines a case splits into are the lines the reference read;
/// a difference fails the test.
fn check_split(
  place : String,
  lines : Array[String],
  spec : Json,
) -> Unit raise @types.DataError {
  let theirs = jstrings(field(spec, "lines"))
  if lines != theirs {
    raise problem(
      "\{place}: the text splits into \{lines.length()} lines here, \{theirs.length()} for the reference",
    )
  }
}

///|
test "every prefix of a valid file's lines infers what the reference inferred, or refuses as it refused, and nothing aborts" {
  let sweep = fixture_json(".github/fixtures/fwf/reference/sweep.json")
  let file = jstring(field(sweep, "prefix_file"))
  let whole = jstrings(
    field(fixture_json(".github/fixtures/fwf/reference/\{file}.json"), "lines"),
  )
  let recorded = jarray(field(sweep, "prefixes"))
  // every length from 0 to one below the full size, and the whole file
  assert_eq(recorded.length(), whole.length() + 1)
  let differences : Array[String] = []
  let mut raised = 0
  let mut answered = 0
  let mut cells = 0
  for count, spec in recorded {
    println("truncation case \{file} \{count}")
    assert_eq(jint(field(spec, "count")), count)
    let lines = split_lines(joined([..whole[0:count]]))
    check_split("\{file}, \{count} lines", lines, spec)
    match attempt(() => fwf_infer_layout(lines, 100)) {
      Refused(_) => raised += 1
      Answered(_) => answered += 1
    }
    cells += check_case("\{file}, \{count} lines", lines, spec, differences)
  }
  if !differences.is_empty() {
    fail("\{differences.length()} prefixes differ:\n\{differences.join("\n")}")
  }
  println(
    "truncations \{file}: \{recorded.length()} cases, 0 to \{whole.length()} lines, \{raised} raised DataError, \{answered} answered, \{cells} cells compared with the reference, 0 aborted; DONE",
  )
}

///|
test "200 single-character replacements of a valid file infer and cut as the reference does, and nothing aborts" {
  let sweep = fixture_json(".github/fixtures/fwf/reference/sweep.json")
  let file = jstring(field(sweep, "replacement_file"))
  let whole = jstrings(
    field(fixture_json(".github/fixtures/fwf/reference/\{file}.json"), "lines"),
  )
  let alphabet = jstrings(field(sweep, "alphabet"))
  let recorded = jarray(field(sweep, "replacements"))
  assert_eq(recorded.length(), 200)
  assert_eq(
    jstring(field(field(sweep, "seeds"), "replacements")),
    spelled_seed(SEED_REPLACEMENTS),
  )
  let rng = SplitMix::{ state: SEED_REPLACEMENTS, }
  let differences : Array[String] = []
  let distinct : Array[String] = []
  let mut raised = 0
  let mut answered = 0
  let mut cells = 0
  for case, spec in recorded {
    println("replacement case \{file} \{case}")
    let line = (rng.next() % whole.length().to_uint64()).to_int()
    let characters = whole[line].iter().count()
    let at = (rng.next() % characters.to_uint64()).to_int()
    let picked = (rng.next() % alphabet.length().to_uint64()).to_int()
    // The generator's replay of the sweep draws the same replacement.
    if line != jint(field(spec, "line")) ||
      at != jint(field(spec, "at")) ||
      picked != jint(field(spec, "with")) {
      fail(
        "\{file}, case \{case}: the sweep replaces line \{line} character \{at} with \{alphabet[picked]}; the generator's replay line \{jint(field(spec, "line"))} character \{jint(field(spec, "at"))} with \{alphabet[jint(field(spec, "with"))]}",
      )
    }
    let mutated = whole.copy()
    mutated[line] = replace_char(whole[line], at, alphabet[picked])
    let lines = split_lines(joined(mutated))
    check_split("\{file}, case \{case}", lines, spec)
    match attempt(() => fwf_infer_layout(lines, 100)) {
      Refused(_) => raised += 1
      Answered(layout) => {
        answered += 1
        let spelled = boundaries(layout)
        if !distinct.contains(spelled) {
          distinct.push(spelled)
        }
      }
    }
    cells += check_case("\{file}, case \{case}", lines, spec, differences)
  }
  if answered == 0 {
    fail("no replacement answered a layout")
  }
  if !differences.is_empty() {
    fail(
      "\{differences.length()} replacements differ:\n\{differences.join("\n")}",
    )
  }
  println(
    "replacements \{file}: 200 cases, \{raised} raised DataError, \{answered} answered, \{distinct.length()} distinct layouts, \{cells} cells compared with the reference, 0 aborted; DONE",
  )
}

///|
test "200 random texts infer and cut as the reference does, and nothing aborts" {
  let sweep = fixture_json(".github/fixtures/fwf/reference/sweep.json")
  let recorded = jarray(field(sweep, "random"))
  assert_eq(recorded.length(), 200)
  assert_eq(
    jstring(field(field(sweep, "seeds"), "random")),
    spelled_seed(SEED_RANDOM),
  )
  let rng = SplitMix::{ state: SEED_RANDOM, }
  let differences : Array[String] = []
  let distinct : Array[String] = []
  let mut raised = 0
  let mut answered = 0
  let mut cells = 0
  let mut lines_drawn = 0
  for case, spec in recorded {
    println("random-text case \{case}")
    let count = 1 + (rng.next() % 4UL).to_int()
    let drawn : Array[String] = []
    for _ in 0..<count {
      let length = (rng.next() % 24UL).to_int()
      drawn.push(drawn_text(rng, length))
    }
    let lines = split_lines(joined(drawn))
    lines_drawn += lines.length()
    check_split("random text \{case}", lines, spec)
    match attempt(() => fwf_infer_layout(lines, 100)) {
      Refused(_) => raised += 1
      Answered(layout) => {
        answered += 1
        let spelled = boundaries(layout)
        if !distinct.contains(spelled) {
          distinct.push(spelled)
        }
      }
    }
    cells += check_case("random text \{case}", lines, spec, differences)
  }
  if raised == 0 || answered == 0 {
    fail("of 200 random texts \{raised} raised and \{answered} answered")
  }
  if !differences.is_empty() {
    fail(
      "\{differences.length()} random texts differ:\n\{differences.join("\n")}",
    )
  }
  println(
    "random texts: 200 cases, \{lines_drawn} lines, \{raised} raised DataError, \{answered} answered, \{distinct.length()} distinct layouts, \{cells} cells compared with the reference, 0 aborted; DONE",
  )
}
