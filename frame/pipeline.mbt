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
/// One stretch of the spine. `Flow` runs its verbs on each batch as it
/// passes; `Block` runs its verbs on the whole frame the stretch's input
/// drains to, and the frame re-enters the pipeline as one batch. Two
/// spans of the same kind never sit adjacent — the builder folds runs of
/// flow-safe verbs into one `Flow` and runs of blocking ones into one
/// `Block`, so a chain of blocking verbs materialises once, not once
/// per verb.
priv enum Span {
  Flow(Array[Morph])
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
/// Whether a unary verb is *flow-safe* — its per-row output depends only
/// on its per-row input, so running it per batch equals running it over
/// the whole frame. The row-local expression gates are the optimizer's
/// own predicates (`all_row_stable` excludes the aggregations, and a
/// selection that reads no column collapses its input to one row — a
/// whole-frame verb however small); the value fence the optimizer adds
/// to those gates is absent here by design — it guards error
/// faithfulness against *skipping rows* while sinking, and batching
/// skips nothing: the first row a stage refuses on is the same row, in
/// the same batch order, either way.
fn op_flows(op : FrameOp) -> Bool {
  match op {
    Filter(_) => true
    Select(exprs) => all_row_stable(exprs) && preserves_row_count(exprs)
    WithColumns(exprs) => all_row_stable(exprs)
    Rename(_) | RenameWith(_) | Drop(_) => true
    DropNulls(_) | FillNull(_) | FillNan(_) => true
    _ => false
    // The blocking rest: `Sort` / `TopK` / `Unique` / `Reverse` read
    // every row before answering; `Head` / `Tail` / `Slice` /
    // `GatherEvery` address rows by position across the whole frame;
    // `WithRowIndex` numbers rows from the frame's own start; a
    // directional fill carries its last value across row boundaries;
    // `Pivot` / `Unpivot` / `Reduce` reshape rows against the frame's
    // whole shape. One day the positional windows can flow with a
    // running row budget — until the differential battery says so, they
    // block.
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
        let morph : Morph = Morph(df => apply_frame_op(df, op))
        // A flow-safe verb joins the trailing `Flow` (or opens one); a
        // blocking verb joins the trailing `Block` (or opens one) — never
        // merging across the kinds. The in-place push grows the tail
        // span's own array; a new kind opens a new span.
        let flows = op_flows(op)
        match below.spans.get(below.spans.length() - 1) {
          Some(Flow(runs)) if flows => runs.push(morph)
          Some(Block(runs)) if !flows => runs.push(morph)
          _ =>
            if flows {
              below.spans.push(Flow([morph]))
            } else {
              below.spans.push(Block([morph]))
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
  memo_result(memo, self)
}

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
