// Shared per-column dtype inference and typed-column construction for the
// CSV and JSON readers. Both readers walk an abstract "cell source" (a CSV
// row matrix indexed by column, or a JSON record array indexed by key) and
// pick the narrowest dtype that accepts every non-null probe, in the same
// priority order Int → Float → Bool → String. Factoring the skeleton here
// keeps that order — the windowed-inference rule (with `infer_schema_rows
// <= 0` meaning "scan every row", Polars' `infer_schema_length=None`) and
// the build-time parse-failure policy (`OnParseError`: raise vs. null the
// offending cell) — defined in exactly one place; each reader supplies only
// its own cell accessor, null test, per-dtype probes, and error wording.
//
// One-file-one-test exemption: this shared inference skeleton has no
// dedicated `infer_test.mbt`. It is covered through the CSV / JSON / NDJSON
// reader blackbox tests that drive it.

///|
const DEFAULT_INFER_SCHEMA_ROWS : Int = 100

///|
/// A membership set over a name list — a `Map[String, Unit]` for O(1)
/// `contains`, built once so the projection / pruned-column / key-column
/// checks in the CSV and JSON readers don't rescan (or reallocate) a name
/// array per header.
fn name_set(names : Array[String]) -> Map[String, Unit] {
  let set : Map[String, Unit] = Map([])
  for name in names {
    set[name] = ()
  }
  set
}

///|
/// The four dtypes inference can pick. `Null` is intentionally absent —
/// inference never produces it, so the builder match stays exhaustive
/// without an unreachable arm.
priv enum InferredDtype {
  InferInt
  InferFloat
  InferBool
  InferString
}

///|
/// What a reader does when a non-null cell fails to parse under the dtype
/// that inference locked in for its column — in practice a value past the
/// inference window that doesn't fit (e.g. a `String` in a column inferred
/// `Int` from its first rows).
///
/// - `Raise` (every reader's default) — surface `ParseError(Cell(...))`,
///   failing the whole read. The strict, lossless behaviour: a malformed
///   cell is never silently dropped.
/// - `Null` — downgrade the offending cell to a null cell and keep going,
///   the resilient behaviour Polars exposes as `ignore_errors=True` (pandas
///   tolerates the same). The column keeps its inferred dtype; only the
///   unparseable cells become null.
///
/// Shared by `CsvReadOptions` and `JsonReadOptions` and
/// consumed in `build_typed_column`'s parse-failure branch, so the three
/// readers agree on the policy.
pub(all) enum OnParseError {
  Raise
  Null
} derive(Eq, Debug)

///|
pub extend OnParseError with Eq::{equal, not_equal}

///|
pub extend OnParseError with Debug::{to_repr}

///|
/// Pick the narrowest dtype that accepts every non-null cell in the first
/// `limit` rows, in priority order `Int → Float → Bool → String`. A
/// `limit <= 0` lifts the cap and scans every row (Polars'
/// `infer_schema_length=None`), so a dtype that only becomes clear deep in
/// the data is inferred rather than guessed from a prefix.
///
/// `cell(i)` reads the raw cell at row `i`; `is_null(c)` reports whether it
/// is a null cell (skipped by inference); `is_int` / `is_float` / `is_bool`
/// report whether a non-null cell parses as that dtype. A probe window
/// that is entirely null falls back to `String` (no signal to
/// disambiguate). A column that eliminates Int, Float, and Bool is
/// `String` whether it is pure-string or mixed, so once all three are out
/// we stop probing early — the remaining cells cannot change the outcome.
fn[Cell] infer_dtype(
  n : Int,
  limit~ : Int,
  cell~ : (Int) -> Cell,
  is_null~ : (Cell) -> Bool,
  is_int~ : (Cell) -> Bool,
  is_float~ : (Cell) -> Bool,
  is_bool~ : (Cell) -> Bool,
) -> InferredDtype {
  let scan = if limit <= 0 || limit > n { n } else { limit }
  let mut all_int = true
  let mut all_float = true
  let mut all_bool = true
  let mut saw_any = false
  for i in 0..<scan {
    let c = cell(i)
    if is_null(c) {
      continue
    }
    saw_any = true
    if all_int && !is_int(c) {
      all_int = false
    }
    if all_float && !is_float(c) {
      all_float = false
    }
    if all_bool && !is_bool(c) {
      all_bool = false
    }
    if !all_int && !all_float && !all_bool {
      break
    }
  }
  if !saw_any {
    InferString
  } else if all_int {
    InferInt
  } else if all_float {
    InferFloat
  } else if all_bool {
    InferBool
  } else {
    InferString
  }
}

///|
/// Materialise one typed column from an abstract cell source. `cell(i)`
/// reads the raw cell, `is_null(c)` maps a null cell to `None`, `parse(c)`
/// converts a non-null cell to `Some(value)` (or `None` when it doesn't fit
/// the locked-in dtype), and `build` wraps the option array into a
/// `Series`. Used for the parseable dtypes (`Int` / `Float` / `Bool`); the
/// `String` fallback goes through the total `build_string_column` below (its
/// `render` never fails, so it needs no `parse` / `err` / `on_parse_error`).
///
/// A non-null cell that `parse` rejects is handled per `on_parse_error`:
/// `Raise` surfaces `err(i, c)` (the strict default, failing the read),
/// `Null` downgrades it to a null cell so the read continues with the
/// column's inferred dtype intact (Polars' `ignore_errors`).
fn[Cell, T] build_typed_column(
  name : String,
  n : Int,
  cell~ : (Int) -> Cell,
  is_null~ : (Cell) -> Bool,
  parse~ : (Cell) -> T?,
  err~ : (Int, Cell) -> @types.DataError,
  on_parse_error~ : OnParseError,
  build~ : (String, Array[T?]) -> @series.Series,
) -> @series.Series raise @types.DataError {
  let values : Array[T?] = Array::makei(n, i => {
    let c = cell(i)
    if is_null(c) {
      None
    } else {
      match parse(c) {
        Some(x) => Some(x)
        None =>
          match on_parse_error {
            Raise => raise err(i, c)
            Null => None
          }
      }
    }
  })
  build(name, values)
}

///|
/// Materialise a `String` column from an abstract cell source — the total
/// counterpart of `build_typed_column` for the `String` fallback dtype.
/// `cell(i)` reads the raw cell, `is_null(c)` maps a null cell to `None`, and
/// `render(c)` stringifies a non-null cell (it never fails, so there is no
/// `parse` / `err` / `on_parse_error`). The CSV reader renders with the
/// identity; the JSON reader with its value-to-string fallback.
fn[Cell] build_string_column(
  name : String,
  n : Int,
  cell : (Int) -> Cell,
  is_null : (Cell) -> Bool,
  render : (Cell) -> String,
) -> @series.Series {
  @series.Series::from_string_options(
    name,
    Array::makei(n, i => {
      let c = cell(i)
      if is_null(c) {
        None
      } else {
        Some(render(c))
      }
    }),
  )
}

///|
/// The four-arm `InferredDtype` dispatch shared by the CSV and JSON readers:
/// route the three parseable dtypes through `build_typed_column` (each with its
/// own parser and a `locate`d error) and the `String` fallback through the
/// total `build_string_column`. Each reader supplies only its cell accessor,
/// null test, per-dtype parsers, string render, and error locator —
/// `locate(dt, i, c)` builds the `ParseError` for the cell at index `i` that
/// failed to fit dtype `dt`, letting each format place the coordinate (a CSV
/// data row, an NDJSON line, a JSON record) and stringify the offending value
/// its own way. The match, and the `Int → Float → Bool → String` order it
/// mirrors from `infer_dtype`, live here once.
fn[Cell] build_inferred_column(
  name : String,
  dtype : InferredDtype,
  n : Int,
  cell~ : (Int) -> Cell,
  is_null~ : (Cell) -> Bool,
  parse_int~ : (Cell) -> Int64?,
  parse_float~ : (Cell) -> Double?,
  parse_bool~ : (Cell) -> Bool?,
  render~ : (Cell) -> String,
  locate~ : (@types.DataType, Int, Cell) -> @types.DataError,
  on_parse_error~ : OnParseError,
) -> @series.Series raise @types.DataError {
  match dtype {
    InferInt =>
      build_typed_column(
        name,
        n,
        cell~,
        is_null~,
        parse=parse_int,
        err=(i, c) => locate(@types.DataType::Int, i, c),
        on_parse_error~,
        build=@series.Series::from_int_options,
      )
    InferFloat =>
      build_typed_column(
        name,
        n,
        cell~,
        is_null~,
        parse=parse_float,
        err=(i, c) => locate(@types.DataType::Float, i, c),
        on_parse_error~,
        build=@series.Series::from_float_options,
      )
    InferBool =>
      build_typed_column(
        name,
        n,
        cell~,
        is_null~,
        parse=parse_bool,
        err=(i, c) => locate(@types.DataType::Bool, i, c),
        on_parse_error~,
        build=@series.Series::from_bool_options,
      )
    InferString => build_string_column(name, n, cell, is_null, render)
  }
}

///|
/// The two-phase assembly shared by the pruned CSV and JSON readers. `headers`
/// gives the column order; `build_over(name, i, keep)` builds the column named
/// `name` (at header index `i`) over the records `keep` selects (`None` = every
/// record), threading each surviving record's original position for the
/// reader's error locator. With a `pruner`, phase 1 builds only the key columns
/// over every record, asks `keep` which rows survive, and gathers the key
/// frame; phase 2 then builds each projected column over the survivors —
/// reusing an already-built key column rather than parsing it a second time.
/// Without a pruner, phase 2 builds each projected column over every record.
///
/// Factoring the orchestration here keeps the row-pruning contract — inference
/// over the whole file, original-position threading for error locators, and the
/// key-column reuse — defined once for both formats, rather than mirrored
/// (which is how the CSV reader once shipped without the position threading the
/// NDJSON reader had).
///
/// `nrows` is the record count the file itself carries, and it — not the built
/// column vector — sets the result's height. The two are the same whenever a
/// column survives, and differ exactly when none does: a projection that
/// matches no header, or a record shape with no fields at all (`[{}, {}]`),
/// reads as the `N×0` frame rather than losing the file's rows. The same count
/// anchors the phase-1 key frame, so a predicate that reads no column still
/// sees the file's real height.
fn assemble_pruned_frame(
  headers : Array[String],
  nrows : Int,
  projection : Array[String]?,
  pruner : (
    Array[String],
    (@frame.DataFrame) -> Array[Int] raise @types.DataError,
  )?,
  build_over : (String, Int, Array[Int]?) -> @series.Series raise @types.DataError,
) -> @frame.DataFrame raise @types.DataError {
  // Phase 1: build only the key columns over every record, gather the survivors.
  let pruned : (@frame.DataFrame, Array[Int])? = match pruner {
    None => None
    Some((key_columns, keep)) => {
      let key_set = name_set(key_columns)
      let keys : Array[@series.Series] = []
      for col, name in headers {
        if key_set.contains(name) {
          keys.push(build_over(name, col, None))
        }
      }
      let key_frame = @frame.DataFrame::from_parts(keys, nrows)
      let kept = keep(key_frame)
      Some((key_frame.gather(kept), kept))
    }
  }
  let kept : Array[Int]? = match pruned {
    None => None
    Some((_, k)) => Some(k)
  }
  let projection_set = projection.map(name_set)
  let pruned_cols : Map[String, Unit] = match pruned {
    Some((frame, _)) => name_set(frame.columns())
    None => Map([])
  }
  // Phase 2: build each projected column over the survivors (or every record).
  let series : Array[@series.Series] = []
  for col, name in headers {
    let included = match projection_set {
      None => true
      Some(names) => names.contains(name)
    }
    if included {
      // A predicate key column is already built and pruned — take it rather than
      // parsing those cells a second time.
      match pruned {
        Some((frame, _)) if pruned_cols.contains(name) =>
          series.push(frame.get_column(name))
        _ => series.push(build_over(name, col, kept))
      }
    }
  }
  // The surviving height: the rows a pruner kept, else every record. With at
  // least one column built these agree with `series[0].len()`; with none, this
  // is the only thing that carries it.
  let height = match kept {
    None => nrows
    Some(k) => k.length()
  }
  @frame.DataFrame::from_parts(series, height)
}
