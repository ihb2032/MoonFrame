// A cell between the start and the end of its element. Its whole text says
// two things whatever its type: whether it is "#N/A", an error value, and
// whether it is "TRUE". A string cell's value is the string its
// paragraphs, spaces, line breaks and nested elements compose.

///|
/// What an element opening inside a string cell does to the value.
priv enum Level {
  // text:s: as many spaces as its text:c names.
  Space
  // text:line-break: a line break.
  Break
  // text:p: the second paragraph under one element follows a line break.
  Paragraph
  // office:annotation: nothing inside it is part of the value.
  Annotation
  // Any other element: what is inside it is part of the value.
  Other
}

///|
/// One element level of a string cell's value: what the level has
/// composed, and whether a paragraph has already closed into it.
priv struct Frame {
  annotation : Bool
  mut paragraph : Bool
  out : StringBuilder
}

///|
/// A cell between its element's start and end.
priv struct OpenCell {
  // The depth of the element among the open ones: its parent is the row
  // when the row's is one less.
  depth : Int32
  // Where the element starts, for a message.
  byte : Int32
  // A covered cell with no office:value is empty whatever else it holds.
  covered : Bool
  element : @xml.NamespaceElement
  // How many columns the cell takes.
  repeat : Int64
  // Whether the string is composed as the text arrives: a string cell's
  // is, and no other cell's.
  composes : Bool
  frames : Array[Frame]
  // The text since the last element boundary: one text node.
  run : StringBuilder
  // The whole text, kept only where a time cell has to read it.
  raw : StringBuilder
  keep_raw : Bool
  // How much of "#N/A", and of "TRUE", the text has spelled so far: -1
  // once the text cannot be the whole of that word.
  mut na : Int32
  mut yes : Int32
}

///|
/// A cell just opened: it composes its string when its type is `string`,
/// and keeps its whole text only when it is a time cell with no value.
fn open_cell(
  element : @xml.NamespaceElement,
  depth : Int32,
  byte : Int32,
  covered : Bool,
  repeat : Int64,
  kind : String,
  has_time_value : Bool,
) -> OpenCell {
  let root = Frame::{
    annotation: false,
    paragraph: false,
    out: StringBuilder(),
  }
  let composes = kind == "string"
  OpenCell::{
    depth,
    byte,
    covered,
    element,
    repeat,
    composes,
    frames: [root],
    run: StringBuilder(),
    raw: StringBuilder(),
    keep_raw: kind == "time" && !has_time_value,
    na: 0,
    yes: 0,
  }
}

///|
/// A run of the cell's text.
fn OpenCell::text(self : OpenCell, text : String) -> Unit {
  let na = "#N/A".code_units()
  let yes = "TRUE".code_units()
  let units = text.code_units()
  for i in 0..<units.length() {
    let unit = units[i].to_int()
    if self.na >= 0 {
      if self.na < 4 && unit == na[self.na].to_int() {
        self.na += 1
      } else {
        self.na = -1
      }
    }
    if self.yes >= 0 {
      if self.yes < 4 && unit == yes[self.yes].to_int() {
        self.yes += 1
      } else {
        self.yes = -1
      }
    }
  }
  if self.keep_raw {
    self.raw.write_string(text)
  }
  if self.composes {
    self.run.write_string(text)
  }
}

///|
/// Whether the cell's whole text is "#N/A".
fn OpenCell::is_na(self : OpenCell) -> Bool {
  self.na == 4
}

///|
/// Whether the cell's whole text is "TRUE".
fn OpenCell::is_true(self : OpenCell) -> Bool {
  self.yes == 4
}

///|
/// The text node since the last element boundary goes into the string,
/// the line breaks at its two ends cut.
fn OpenCell::flush(self : OpenCell) -> Unit {
  if self.run.is_empty() {
    return
  }
  let text = self.run.to_string()
  self.run.reset()
  self.frames[self.frames.length() - 1].out.write_string(end_breaks_cut(text))
}

///|
/// An element opens inside the cell: `spaces` is what a text:s spells.
fn OpenCell::open(self : OpenCell, level : Level, spaces : Int32) -> Unit {
  if !self.composes {
    return
  }
  self.flush()
  let top = self.frames[self.frames.length() - 1]
  let frame = Frame::{
    annotation: level is Annotation,
    paragraph: false,
    out: StringBuilder(),
  }
  match level {
    Space =>
      for _ in 0..<spaces {
        top.out.write_char(' ')
      }
    Break => top.out.write_char('\n')
    Paragraph => {
      if top.paragraph {
        top.out.write_char('\n')
      }
      top.paragraph = true
    }
    Annotation | Other => ()
  }
  self.frames.push(frame)
}

///|
/// An element closes inside the cell: what it composed goes into the
/// string of the element around it, unless it is an annotation.
fn OpenCell::close(self : OpenCell) -> Unit {
  if !self.composes {
    return
  }
  self.flush()
  if self.frames.length() < 2 {
    return
  }
  let frame = self.frames.pop()
  if frame is Some(frame) {
    if !frame.annotation {
      let top = self.frames[self.frames.length() - 1]
      top.out.write_string(frame.out.to_string())
    }
  }
}

///|
/// The string the cell composed.
fn OpenCell::composed(self : OpenCell) -> String {
  self.frames[0].out.to_string()
}

///|
/// A text node with the line breaks at its two ends cut, and nothing
/// else: a space is text, and a line break inside stays.
fn end_breaks_cut(text : String) -> String {
  let units = text.code_units()
  let mut from = 0
  let mut to = units.length()
  while from < to && units[from].to_int() == 10 {
    from += 1
  }
  while to > from && units[to - 1].to_int() == 10 {
    to -= 1
  }
  text[from:to].to_owned()
}
