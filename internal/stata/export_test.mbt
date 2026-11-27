// Blackbox export: the shared test tables, as the codec writes
// them, for the reference readers. `make_fixtures.py verify` reads
// each `.dta` under `_build/stata_written/` back with both reference
// readers and compares the cells with the `.json` written beside it,
// which spells the table the codec was handed.

///|
/// A table as the reference readers' check reads it: the height, whether
/// a reference reader opens such a file at all, and every column's name,
/// dtype and cells.
fn table_json(table : Table) -> String {
  let columns = table.columns.map(column => {
    Json::object({
      "name": Json::string(column.name()),
      "dtype": Json::string(column.dtype().to_string()),
      "cells": Json::array(
        column.to_scalars().map(value => Json::string(spelled(value))),
      ),
    })
  })
  Json::object({
    "name": Json::string(table.name),
    "height": Json::number(table.height.to_double()),
    // The reference reader's cell read raises on a file of observations
    // and no variable; the generator does not ask it to.
    "reference_opens": Json::boolean(
      table.columns.length() > 0 || table.height == 0,
    ),
    "columns": Json::array(columns),
  }).stringify(indent=1)
}

///|
/// The `.dta` and `.json` files left under `dir` by an earlier run.
fn stale_files(dir : String) -> Array[String] {
  let stale : Array[String] = []
  let listed : Result[ArrayView[String], Unit] = Ok(@fs.read_dir(dir)) catch {
    _ => Err(())
  }
  match listed {
    Ok(names) =>
      for name in names {
        if name.has_suffix(".dta") || name.has_suffix(".json") {
          stale.push(name)
        }
      }
    Err(_) => ()
  }
  stale
}

///|
test "the codec's tables are written out for the reference readers" {
  let dir = "_build/stata_written"
  if !@fs.path_exists(dir) {
    @fs.create_dir(dir) catch {
      _ => fail("cannot create \{dir}")
    }
  }
  for name in stale_files(dir) {
    @fs.remove_file("\{dir}/\{name}") catch {
      _ => fail("cannot remove the stale \{dir}/\{name}")
    }
  }
  let mut written = 0
  for table in tables() {
    let bytes = write_table(table)
    @fs.write_bytes_to_file("\{dir}/\{table.name}.dta", bytes) catch {
      _ => fail("cannot write \{dir}/\{table.name}.dta")
    }
    @fs.write_string_to_file("\{dir}/\{table.name}.json", table_json(table)) catch {
      _ => fail("cannot write \{dir}/\{table.name}.json")
    }
    written += 1
  }
  if written != 7 {
    fail("\{written} tables were written out, not the seven defined")
  }
  println("tables written for the reference readers: \{written}")
}
