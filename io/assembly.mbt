// The reader-shared frame assembly: the survivor compaction, the name-set
// helper, and the two-phase pruned-frame orchestration the CSV and JSON
// readers drive. This is the `io → frame` edge's remaining job — the
// string-level parse cores stay with their format files, and the typed
// column build stays with the inference skeleton; what lives
// here is only what every reader must do *around* its core once a predicate
// or projection narrows the read.
//
// One-file-one-test exemption: this shared assembly has no dedicated test
// file of its own. (doc-guard: unresolved) It is covered
// through the CSV / JSON / NDJSON reader blackbox tests that drive it.

///|
/// A membership set over a name list — a `Map[String, Unit]` for O(1)
/// `contains`, built once so the projection / pruned-column / key-column
/// checks in the readers don't rescan (or reallocate) a name array per
/// header.
fn name_set(names : Array[String]) -> Map[String, Unit] {
  let set : Map[String, Unit] = Map([])
  for name in names {
    set[name] = ()
  }
  set
}

///|
/// Compact one record-parallel structure by a prune's survivor list:
/// identity when no pruner ran (`None` = every record), else each kept
/// record's entry. The "survivor → original position" compaction both
/// readers thread, so a parse error in a kept row reports its true source
/// row / line rather than its compacted index.
fn[T] kept_records(keep : Array[Int]?, all : Array[T]) -> Array[T] {
  match keep {
    None => all
    Some(k) => Array::makei(k.length(), i => all[k[i]])
  }
}

///|
/// The pruner a pushed-down read carries: the key columns to build in
/// phase 1, and the callback (built by the lazy layer from the absorbed
/// predicate) that decides which rows survive into phase 2. Named once so
/// every signature that threads it — the string-level projected cores, the
/// JSON records core, and the frame assembler — spells the same contract.
type RowPruner = (
  Array[String],
  (@frame.DataFrame) -> Array[Int] raise @types.DataError,
)

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
  pruner : RowPruner?,
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
