// The morsel pipeline — the physical execution layer between the
// optimized `LogicalPlan` and the eager verbs. A plan becomes a *source*
// of batches (a scan's cursor, an in-memory frame, or a join's merged
// output) plus a spine of *spans*: a `Flow` span applies its verbs to
// each batch independently (the row-local stages — a filter keeps the
// rows its predicate keeps, wherever the batch boundaries fall), and a
// `Block` span drains what reaches it into one frame, applies its verbs
// there, and re-emits the frame as a single batch (the row-global
// stages — a sort or an aggregation reads every row before it answers
// any). The executor's contract is the interpreter's: the collected
// frame, and the first `DataError` a failing plan raises, are exactly
// what the node-by-node execution produces — batch boundaries change
// where memory is spent, never which rows collect or which error wins.
//
// The spans are shaped for the parallel executor the platform does not
// offer yet: every `Flow` verb is a total function over its batch alone
// (no state crossing a boundary), the source is a pull cursor a
// scheduler could steal from, and the row order is the batch order —
// partitioned execution plus in-order assembly equals this sequential
// walk. Nothing here schedules anything; the shapes only promise that
// something could.

///|
/// One verb's deferred execution — a `Unary` node's eager verb, or the
/// fused aggregation a `Join` / `Aggregate` node carries. A closure, not
/// the `FrameOp` itself: the aggregation nodes are not unary verbs, and
/// the pipeline never needs to render or re-optimise what it executes.
priv struct Morph((DataFrame) -> DataFrame raise @types.DataError)

///|
/// One *stateful* verb's deferred execution — a positional window that
/// rides the flow carrying its own place across batch boundaries: the
/// step transforms one batch (updating the place it holds), and once
/// the span's input has drained, the flush answers whatever tail the
/// verb was holding back. The whole-frame verb and the batch-by-batch
/// walk spell one result, cell for cell and row for row.
priv struct StateMorph {
  step : (DataFrame) -> DataFrame raise @types.DataError
  flush : () -> DataFrame? raise @types.DataError
}

///|
/// One stretch of the spine. `Flow` runs its stateless verbs on each
/// batch as it passes; `StateFlow` runs its positional verbs the same
/// way, each carrying its own place across the boundaries and flushing
/// its tail at the drain; `Block` runs its verbs on the whole frame the
/// stretch's input drains to, and the frame re-enters the pipeline as
/// one batch. Two spans of the same kind never sit adjacent — the
/// builder folds runs of same-kind verbs into one span, so a chain of
/// blocking verbs materialises once, not once per verb.
priv enum Span {
  Flow(Array[Morph])
  StateFlow(Array[StateMorph])
  Block(Array[Morph])
}

///|
/// A plan's executable shape: where its batches come from, and what
/// happens to them in order. The source is a *thunk* — opening it (the
/// file read, the join's two sides) happens at `run`, in the order the
/// interpreter would read: a join's left subtree fully before its right.
priv struct Pipeline {
  source : () -> @scan.BatchCursor raise @types.DataError
  spans : Array[Span]
}

///|
/// Which stretch a unary verb rides. `Flowing`: stateless per batch.
/// `Windowed`: stateful per batch with a flushed tail. `Blocking`: the
/// whole frame. The row-local expression gates are the optimizer's own
/// predicates (`row_stable` for a filter, `all_row_stable` for the
/// expression-list verbs, and a selection that reads no column collapses
/// its input to one row — a whole-frame verb however small); the value
/// fence the optimizer adds to those gates is absent here by design —
/// it guards error faithfulness against *skipping rows* while sinking,
/// and batching skips nothing: the first row a stage refuses on is the
/// same row, in the same batch order, either way.
priv enum VerbSpan {
  Flowing
  Windowed
  Blocking
}

///|
fn op_span_kind(op : FrameOp) -> VerbSpan {
  match op {
    // A filter rides the flow only when its predicate is row-stable: a
    // scope-dependent predicate (an aggregation, a window, a positional
    // shift) has to see the whole frame, so it blocks.
    Filter(predicate) =>
      if row_stable(predicate.node()) {
        Flowing
      } else {
        Blocking
      }
    Select(exprs) =>
      if all_row_stable(exprs) && preserves_row_count(exprs) {
        Flowing
      } else {
        Blocking
      }
    WithColumns(exprs) => if all_row_stable(exprs) { Flowing } else { Blocking }
    Rename(_) | RenameWith(_) | Drop(_) => Flowing
    DropNulls(_) | FillNull(_) | FillNan(_) => Flowing
    // The positional windows with a running place: a forward-count
    // `head`, a trailing window, a forward `slice`, a stride, a row
    // numbering. Each carries its place across the batches and flushes
    // its tail at the drain (`window_morph` spells the walks). The
    // shapes that read the whole frame's height *before* answering — a
    // negative bound (its eager reading drops rows from the far end), a
    // negative offset, a stride under validation — keep the whole-frame
    // path, eager error and all.
    Head(n) => if n >= 0 { Windowed } else { Blocking }
    Tail(n) => if n >= 0 { Windowed } else { Blocking }
    Slice(offset, length) =>
      if offset >= 0 && nonnegative_len(length) {
        Windowed
      } else {
        Blocking
      }
    GatherEvery(n, offset) =>
      if n >= 1 && offset >= 0 {
        Windowed
      } else {
        Blocking
      }
    WithRowIndex(_, _) => Windowed
    // The blocking rest: `Sort` / `TopK` / `Unique` / `Reverse` read
    // every row before answering; a directional fill carries its last
    // value across row boundaries into frames the verbs below it never
    // see whole; `Pivot` / `Unpivot` / `Reduce` reshape rows against
    // the frame's whole shape.
    _ => Blocking
  }
}

///|
/// A positional verb's stateful walk — the `Windowed` arms' deferred
/// execution, each carrying its place across the batches. Every walk
/// answers exactly the eager verb's rows, in the eager verb's order:
/// the state is the verb's own arithmetic (a budget, a place, a
/// kept-tail buffer), never a re-derivation.
fn window_morph(op : FrameOp) -> StateMorph {
  match op {
    Head(n) => {
      // The rows still owed: each batch pays what it can, the rest pay
      // nothing.
      let owed : Array[Int32] = [n]
      {
        step: b => {
          if owed[0] <= 0 {
            b.head(0)
          } else if b.nrows() <= owed[0] {
            owed[0] = owed[0] - b.nrows()
            b
          } else {
            let kept = b.head(owed[0])
            owed[0] = 0
            kept
          }
        },
        flush: () => None,
      }
    }
    Tail(n) => {
      // The kept tail: each batch joins a buffer never allowed past `n`
      // rows — the rows that can no longer be part of the last `n` are
      // declined on the spot (the step answers a zero-row batch, its
      // schema intact), and the tail itself flushes at the drain. A
      // zero-row whole input still answers its columns: the schema
      // batch rides the first batch's shape.
      let held : Array[DataFrame] = []
      // The buffer's logical front: batches before it are declined
      // already, their space left behind rather than shuffled down.
      let front : Array[Int32] = [0]
      let held_rows : Array[Int32] = [0]
      let schema : Array[DataFrame] = []
      let flushed : Array[Bool] = [false]
      {
        step: b => {
          if schema.length() == 0 {
            schema.push(b.head(0))
          }
          let schema_batch = b.head(0)
          held.push(b)
          held_rows[0] = held_rows[0] + b.nrows()
          // Decline from the front until the buffer holds no more than
          // the tail's `n` rows — whole batches off the front, a
          // partial cut (the front's first `room` rows) when the front
          // straddles the line.
          while held_rows[0] > n && front[0] < held.length() {
            let head = held[front[0]]
            let room = held_rows[0] - n
            if head.nrows() <= room {
              held_rows[0] = held_rows[0] - head.nrows()
              front[0] = front[0] + 1
            } else {
              held_rows[0] = held_rows[0] - room
              held[front[0]] = head.slice(room)
            }
          }
          schema_batch
        },
        flush: () => {
          if flushed[0] {
            return None
          }
          flushed[0] = true
          if front[0] < held.length() {
            let mut acc = held[front[0]]
            for i in (front[0] + 1)..<held.length() {
              acc = acc.vstack(held[i])
            }
            held.clear()
            front[0] = 0
            return Some(acc)
          }
          // Nothing was kept (`n` of zero, or a wholly empty input):
          // the columns still answer, as the eager verb's zero-row
          // frame.
          match schema.get(0) {
            Some(empty) => Some(empty)
            None => None
          }
        },
      }
    }
    Slice(offset, length) => {
      // A forward window: `skip` rows declined, then `left` rows kept
      // (forever, when no length was named).
      let skip : Array[Int32] = [offset]
      let left : Array[Int32] = [
        match length {
          Some(l) => l
          None => 2147483647
        },
      ]
      {
        step: b => {
          let mut frame = b
          if skip[0] > 0 {
            if frame.nrows() <= skip[0] {
              skip[0] = skip[0] - frame.nrows()
              frame = frame.head(0)
            } else {
              frame = frame.tail(frame.nrows() - skip[0])
              skip[0] = 0
            }
          }
          if left[0] < frame.nrows() {
            frame = frame.head(left[0])
          }
          left[0] = left[0] - frame.nrows()
          frame
        },
        flush: () => None,
      }
    }
    GatherEvery(n, offset) => {
      // A stride with a global place: the rows whose global positions
      // land on `offset + k·n`, gathered batch by batch. The builder
      // routes only `n >= 1` and `offset >= 0` here — the shapes under
      // eager validation keep the whole-frame path, its error intact.
      let place : Array[Int32] = [0]
      {
        step: b => {
          let rows = b.nrows()
          let indices : Array[Int32] = []
          // The first stride point at or after the batch's start.
          let start = place[0]
          let mut at = if offset > start {
            offset
          } else {
            start + (n - (start - offset) % n) % n
          }
          while at < start + rows {
            indices.push(at - start)
            at = at + n
          }
          place[0] = start + rows
          if indices.length() == 0 {
            b.head(0)
          } else {
            b.gather(indices)
          }
        },
        flush: () => None,
      }
    }
    WithRowIndex(name, offset) => {
      // A running row number: each batch numbered from where the last
      // one ended.
      let next : Array[Int64] = [offset]
      {
        step: b => {
          let numbered = b.with_row_index(name~, offset=next[0])
          next[0] = next[0] + b.nrows().to_int64()
          numbered
        },
        flush: () => None,
      }
    }
    // The builder never asks a non-windowed verb for a walk.
    _ => {
      let idle : (DataFrame) -> DataFrame raise @types.DataError = b => b
      { step: idle, flush: () => None, }
    }
  }
}

///|
/// Build a plan's pipeline — the tree-shaped plans `execute` hands over.
/// Iterative over the shared post-order walk with a node-keyed memo
/// (the memoised executor's own skeleton), so a deep plan builds
/// without overflowing the call stack — the never-abort shape that
/// executor was iterated for. A `Join` is the one *source switch*: both
/// sides' pipelines are captured whole, run completely at open (left
/// before right, the interpreter's own reading order), and the joined
/// frame becomes the source the stages above it flow from. The
/// aggregation nodes close a span the way a blocking verb does.
fn LogicalPlan::build_pipeline(
  self : LogicalPlan,
) -> Pipeline raise @types.DataError {
  let memo : Array[(LogicalPlan, Pipeline)] = []
  for node in self.post_order_unique() {
    let built : Pipeline = match node {
      Scan(source) => {
        let open : () -> @scan.BatchCursor raise @types.DataError = match
          source {
          InMemory(df) => single_source(df)
          File(fs) =>
            () => {
              fs.driver.batches(
                projection=fs.projection,
                predicate=fs.predicate,
                window=fs.window,
              )
            }
        }
        { source: open, spans: [], }
      }
      Unary(input, op) => {
        let below = memo_result(memo, input)
        // Same-kind verbs join the trailing span of their kind (or open
        // one); the kinds never merge. The in-place push grows the tail
        // span's own array; a new kind opens a new span.
        let kind = op_span_kind(op)
        let tail = below.spans.get(below.spans.length() - 1)
        let joined = match (kind, tail) {
          (Flowing, Some(Flow(runs))) => {
            runs.push(Morph(df => apply_frame_op(df, op)))
            true
          }
          (Windowed, Some(StateFlow(runs))) => {
            runs.push(window_morph(op))
            true
          }
          (Blocking, Some(Block(runs))) => {
            runs.push(Morph(df => apply_frame_op(df, op)))
            true
          }
          _ => false
        }
        if !joined {
          match kind {
            Flowing =>
              below.spans.push(Flow([Morph(df => apply_frame_op(df, op))]))
            Windowed => below.spans.push(StateFlow([window_morph(op)]))
            Blocking =>
              below.spans.push(Block([Morph(df => apply_frame_op(df, op))]))
          }
        }
        below
      }
      Aggregate(input, keys, exprs) => {
        let below = memo_result(memo, input)
        below.spans.push(Block([Morph(df => df.group_by(keys).agg(exprs))]))
        below
      }
      AggregateAll(input, keys, op) => {
        let below = memo_result(memo, input)
        below.spans.push(Block([Morph(df => agg_all_frame(df, keys, op))]))
        below
      }
      Join(left, right, options) => {
        // Both sides run to their frames at open — left first, the order
        // the memoised interpreter reads a join's inputs — and the joined
        // frame is the source the stages above it flow from. A nested
        // join inside a side opens the same way when *its* pipeline
        // runs, so the nesting unrolls at execution depth, not build
        // depth.
        let lp = memo_result(memo, left)
        let rp = memo_result(memo, right)
        let open : () -> @scan.BatchCursor raise @types.DataError = () => {
          let joined = lp.run().join(rp.run(), options)
          single_source(joined)()
        }
        { source: open, spans: [], }
      }
    }
    memo.push((node, built))
  }
  // Every pipeline's batches pass one row cap on their way out of the
  // source — a source whose own batches run coarser (a textual source's
  // whole-read batch, a wide row group) answers in morsels of the cap
  // instead, so the spans above see batches of a knowable size whatever
  // the source's own granularity. The cap is an internal shape, not a
  // promise: batch boundaries carry no size contract.
  let built = memo_result(memo, self)
  let raw = built.source
  { ..built, source: () => raw().capped(MORSEL_ROWS), }
}

///|
/// The row cap every pipeline's batches stay within — an upper bound on
/// a morsel's height, sized so a batch frame stays a small structure
/// next to the data it carries. Sources already inside the cap pass
/// their batches through untouched.
const MORSEL_ROWS : Int32 = 65_536

///|
/// Run the pipeline: open the source, walk the spine — a `Flow` span
/// wraps the cursor so its verbs ride each batch in flight, a `Block`
/// span drains what has flowed, runs its verbs on the whole frame, and
/// re-emits the frame as the next stretch's source — and drain what
/// comes out the far end into the collected frame.
fn Pipeline::run(self : Pipeline) -> DataFrame raise @types.DataError {
  let mut cursor = (self.source)()
  for span in self.spans {
    cursor = walk_span(cursor, span)
  }
  drain_batches(cursor)
}

///|
/// Walk one span: a `Flow` wraps the cursor so its verbs ride each
/// batch in flight; a `Block` drains what has flowed, runs its verbs on
/// the whole frame, and re-emits the frame as a single batch.
fn walk_span(
  cursor : @scan.BatchCursor,
  span : Span,
) -> @scan.BatchCursor raise @types.DataError {
  match span {
    Flow(runs) => map_batches(cursor, runs)
    StateFlow(runs) => run_stateful(cursor, runs)
    Block(runs) => {
      let mut frame = drain_batches(cursor)
      for run in runs {
        let Morph(f) = run
        frame = f(frame)
      }
      single_source(frame)()
    }
  }
}

///|
/// A stateful stretch's own cursor: each source batch walks the verbs'
/// steps in order; once the source drains, the verbs flush in order —
/// each flush's tail batches walk the *later* verbs' steps (they are
/// that verb's input like any batch), and a verb flushes only after its
/// own input has drained, which the order of the cascade guarantees.
/// The state a verb holds never exceeds what its eager verb holds over
/// the whole frame's tail.
fn run_stateful(
  cursor : @scan.BatchCursor,
  runs : Array[StateMorph],
) -> @scan.BatchCursor {
  // The phase: 0 = still flowing from the source; `i + 1` = flushing
  // `runs[i]`; past the last = done. An array cell, so the step closure
  // sees its own earlier answers on every later call.
  let phase : Array[Int32] = [0]
  @scan.BatchCursor::cursor(() => {
    if phase[0] == 0 {
      match cursor.next() {
        Some(batch) => {
          let mut frame = DataFrame::from_parts(batch.columns(), batch.height())
          for run in runs {
            frame = (run.step)(frame)
          }
          return Some(
            @scan.ScanBatch::batch(frame.column_series(), frame.nrows()),
          )
        }
        None => phase[0] = 1
      }
    }
    // Flushing: each verb's tail batches walk the later verbs' steps.
    while phase[0] >= 1 && phase[0] <= runs.length() {
      let at = phase[0] - 1
      let current = runs[at]
      match (current.flush)() {
        Some(tail) => {
          let mut frame = tail
          for i in (at + 1)..<runs.length() {
            frame = (runs[i].step)(frame)
          }
          return Some(
            @scan.ScanBatch::batch(frame.column_series(), frame.nrows()),
          )
        }
        None => phase[0] = phase[0] + 1
      }
    }
    None
  })
}

///|
/// The batches of one lazy collection — the pipeline's streaming face.
/// `next` hands back each batch of the collected result in order, then
/// `None` forever, so a consumer that reads what it needs and stops
/// simply stops asking: the source's remaining batches are never read.
/// The batch boundaries are the pipeline's own (a parquet file's row
/// groups, one batch per textual source) and carry no size promise;
/// what the streaming *does* promise is that a pipeline whose verbs all
/// ride the flow answers batch by batch without ever holding the whole
/// result, the way `collect` never does.
pub struct BatchStream {
  priv step : () -> DataFrame? raise @types.DataError
}

///|
/// Assemble a stream from its next step — the pipeline's own factory;
/// the public entry is `LazyFrame::collect_batches`.
fn BatchStream::stream(
  step : () -> DataFrame? raise @types.DataError,
) -> BatchStream {
  { step, }
}

///|
/// The next batch of the collection, or `None` once it has answered
/// everything. Raises the read's own `DataError` — the same error, on
/// the same first offending batch, `collect` would raise.
pub fn BatchStream::next(
  self : BatchStream,
) -> DataFrame? raise @types.DataError {
  (self.step)()
}

///|
/// A pipeline as its batches: every span walks as `run` walks it — a
/// blocking stretch materialises when the first batch is pulled, not
/// before — except a *trailing* flow, whose batches answer as they
/// arrive, verbs applied in flight, never stacked into one frame.
fn Pipeline::into_stream(self : Pipeline) -> BatchStream {
  // The walk's place: the current batch source (opened at the first
  // pull — construction reads nothing, like every `LazyFrame` builder)
  // and the next span to walk. A trailing flow stays unwalked: each
  // pull wraps the same cursor in the same span, and wrapping is
  // stateless — the underlying cursor's own position is the only state.
  let cursor : Array[@scan.BatchCursor?] = [None]
  let at : Array[Int32] = [0]
  BatchStream::stream(() => {
    let mut cur = match cursor[0] {
      Some(c) => c
      None => {
        let opened = (self.source)()
        cursor[0] = Some(opened)
        opened
      }
    }
    let last = self.spans.length() - 1
    // Walk every span except a trailing flow — a trailing *block* walks
    // like any other (its materialised frame is the one batch it
    // answers), so only the trailing flow stays unwalked.
    let trailing_flow = last >= 0 && self.spans[last] is Flow(_)
    while at[0] < self.spans.length() && !(trailing_flow && at[0] == last) {
      cur = walk_span(cur, self.spans[at[0]])
      cursor[0] = Some(cur)
      at[0] = at[0] + 1
    }
    match self.spans.get(at[0]) {
      // The trailing flow: its verbs ride the batches as they answer.
      Some(Flow(runs)) => batch_frame(map_batches(cur, runs).next())
      // Everything else has walked (a trailing block re-emitted its one
      // batch), so the batches that answer are the walked cursor's own.
      _ => batch_frame(cur.next())
    }
  })
}

///|
/// One batch as the frame a consumer reads.
fn batch_frame(batch : @scan.ScanBatch?) -> DataFrame? raise @types.DataError {
  match batch {
    None => None
    Some(b) => Some(DataFrame::from_parts(b.columns(), b.height()))
  }
}

///|
/// One frame as a one-batch source — the in-memory scan leaf's shape,
/// and the shape a blocking span's output re-enters the pipeline as.
fn single_source(
  df : DataFrame,
) -> () -> @scan.BatchCursor raise @types.DataError {
  () => {
    let spent : Array[Bool] = [false]
    @scan.BatchCursor::cursor(() => {
      if spent[0] {
        return None
      }
      spent[0] = true
      Some(@scan.ScanBatch::batch(df.column_series(), df.nrows()))
    })
  }
}

///|
/// The flowing half of a `Flow` span: a cursor whose batches are the
/// underlying cursor's, each run through the span's verbs on its way
/// out. The verbs are total per batch by `op_flows`'s own gates, so the
/// first error surfaces on the first batch that carries it — the
/// interpreter's first error, in the interpreter's order.
fn map_batches(
  cursor : @scan.BatchCursor,
  runs : Array[Morph],
) -> @scan.BatchCursor {
  @scan.BatchCursor::cursor(() => {
    match cursor.next() {
      None => None
      Some(batch) => {
        let mut frame = DataFrame::from_parts(batch.columns(), batch.height())
        for run in runs {
          let Morph(f) = run
          frame = f(frame)
        }
        Some(@scan.ScanBatch::batch(frame.column_series(), frame.nrows()))
      }
    }
  })
}

///|
/// Drain a cursor into one frame — the pipeline's one assembly point
/// (a `Block` span's input, and the collect at the far end): every batch
/// becomes a frame, and the frames stack in batch order, each row copied
/// once. A cursor that yields nothing assembles to the 0×0 frame.
fn drain_batches(
  cursor : @scan.BatchCursor,
) -> DataFrame raise @types.DataError {
  let frames : Array[DataFrame] = []
  while true {
    match cursor.next() {
      Some(batch) =>
        frames.push(DataFrame::from_parts(batch.columns(), batch.height()))
      None => break
    }
  }
  stack_frames("scan assembly", frames)
}
