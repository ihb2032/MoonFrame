///|
/// The traversal helpers every plan walker shares, kept apart from the IR
/// definition itself: `plan_children` enumerates the tree
/// shape, `post_order` / `post_order_unique` linearise it for the
/// value-stack folds, the identity-dedup family (`seen_plan`,
/// `contains_join`, `has_shared_subplan`) guards the DAG-shaped plans only a
/// `join` can build, and `memo_result` / `pop_top` / `rejoin` work a fold's
/// value stack. Their consumers are the executor, the two optimizer passes, and
/// the renderer.

///|
/// The child plans of a node, left-to-right — the `LogicalPlan` analogue of
/// `Expr::children`, and the one place the IR's recursive shape is enumerated
/// for *traversal* (the rebuild passes enumerate it again to reassemble). A
/// leaf (`Scan`) has none; `Join` has two; every
/// other node has exactly one. Drives the explicit-stack walks (`render`,
/// `post_order`) so a new node joins them the moment it declares its children
/// here.
fn LogicalPlan::plan_children(self : LogicalPlan) -> Array[LogicalPlan] {
  match self {
    Scan(_) => []
    Unary(input, _) | Aggregate(input, _, _) => [input]
    Join(left, right, _) => [left, right]
  }
}

///|
/// Plan nodes in post-order — every node's children before the node itself,
/// left subtree before right — built with an explicit stack (not the call
/// stack), so an arbitrarily deep plan linearises without overflowing and
/// aborting. The post-order/value-stack walks (`execute`, `push_predicates`)
/// fold children before parents by stepping this list front-to-back: when a
/// node is reached, its children's results are the top of the value stack.
fn LogicalPlan::post_order(self : LogicalPlan) -> Array[LogicalPlan] {
  // Root-first pre-order via a LIFO stack (children pushed left-to-right, so
  // the right subtree pops first), then reversed into post-order.
  let pre : Array[LogicalPlan] = []
  let stack : Array[LogicalPlan] = [self]
  while stack.length() > 0 {
    let node = pop_top(stack)
    pre.push(node)
    for child in node.plan_children() {
      stack.push(child)
    }
  }
  Array::makei(pre.length(), i => pre[pre.length() - 1 - i])
}

///|
/// Pop the top of an explicit walk's value stack. The post-order walks push a
/// rebuilt value for every child before its parent combines, so the stack is
/// never empty here; the top slot is read by that stack-invariant index — total,
/// like the engine's other indexed reads — and dropped, never `unwrap` (which
/// would leave a dead `None` arm and break coverage).
fn[T] pop_top(stack : Array[T]) -> T {
  let top = stack[stack.length() - 1]
  let _ = stack.pop()
  top
}

///|
/// Reassemble a `Join` from the two inputs a post-order fold leaves on its
/// value stack — the right operand on top (pushed last), the left just below —
/// the shape both optimizer passes' rebuild loops share.
fn rejoin(values : Array[LogicalPlan], options : @frame.JoinOptions) -> Unit {
  let right = pop_top(values)
  let left = pop_top(values)
  values.push(Join(left, right, options))
}

///|
/// Whether `node` is already in `seen`, by **physical identity** — the
/// object, not its value. `LazyFrame::join` stores the other frame's plan by
/// reference, so `lf.join(lf, …)` builds a DAG whose `Join` holds the same
/// node object twice; identity is what tells a genuinely shared subplan from
/// two equal-but-separate builds. Linear scan: reached only for a join-bearing
/// plan (a join-free chain skips the dedup walks entirely),
/// whose distinct-node count is small, so the callers' cost stays quadratic in
/// that small count at worst.
fn seen_plan(seen : Array[LogicalPlan], node : LogicalPlan) -> Bool {
  for p in seen {
    if physical_equal(p, node) {
      return true
    }
  }
  false
}

///|
/// Whether the plan contains a `Join`. `Join` is the one binary node (every
/// other node is unary), and `LazyFrame::join`, capturing
/// the other frame's plan by reference, is the only builder that can make a
/// subplan reachable twice. So a join-free plan is a *linear chain* with nothing
/// shared: the identity dedup the DAG walks perform is pure overhead on it, and
/// `has_shared_subplan` / `post_order_unique` take an O(nodes) fast path when
/// this is `false`. Short-circuits on the first `Join`, and every node visited
/// before then is itself non-`Join` — hence part of that unary chain — so this
/// never re-expands a shared subplan and is itself O(nodes).
fn LogicalPlan::contains_join(self : LogicalPlan) -> Bool {
  let stack : Array[LogicalPlan] = [self]
  while stack.length() > 0 {
    let node = pop_top(stack)
    if node is Join(_, _, _) {
      return true
    }
    for child in node.plan_children() {
      stack.push(child)
    }
  }
  false
}

///|
/// Whether the plan is DAG-shaped: some node object reachable twice (nested
/// self-joins built from a shared `LazyFrame`). Sharing can enter only through
/// a `Join`, so a join-free plan is answered `false` in O(nodes) without the
/// identity walk. Otherwise the walk marks every node by identity and stops at
/// the first repeat, so it never re-expands a shared subplan — it avoids the
/// 2^depth blow-up of a naive walk, at a cost quadratic in the (small)
/// distinct-node count from the identity `seen` scan.
fn LogicalPlan::has_shared_subplan(self : LogicalPlan) -> Bool {
  if !self.contains_join() {
    return false
  }
  let seen : Array[LogicalPlan] = []
  let stack : Array[LogicalPlan] = [self]
  while stack.length() > 0 {
    let node = pop_top(stack)
    if seen_plan(seen, node) {
      return true
    }
    seen.push(node)
    for child in node.plan_children() {
      stack.push(child)
    }
  }
  false
}

///|
/// Plan nodes in post-order with each *distinct* node exactly once — the
/// identity-deduplicated walk `execute` folds over. A join-free plan is a unary
/// chain with nothing shared, so the plain `post_order` already lists each node
/// once: taking it directly is the deep-plan fast path, folding a long `head` /
/// `select` chain in O(nodes) rather than the O(nodes²) an identity `seen` scan
/// would cost. Otherwise, on a tree it yields exactly `post_order`'s sequence
/// (left subtree, right subtree, node); on a DAG-shaped plan (only a `Join` can
/// share a subplan) each shared subplan is listed once, before its first
/// consumer (children always precede parents), so a fold that reads child
/// results out of a memo does each subplan's work once instead of once per
/// occurrence — which is 2^depth for nested self-joins.
fn LogicalPlan::post_order_unique(self : LogicalPlan) -> Array[LogicalPlan] {
  if !self.contains_join() {
    return self.post_order()
  }
  let out : Array[LogicalPlan] = []
  let seen : Array[LogicalPlan] = []
  // (node, expanded): expanded=false schedules the node (skipping it if a
  // previous path already claimed it), expanded=true emits it — by then all
  // its children have been emitted.
  let stack : Array[(LogicalPlan, Bool)] = [(self, false)]
  while stack.length() > 0 {
    let (node, expanded) = pop_top(stack)
    if expanded {
      out.push(node)
      continue
    }
    if seen_plan(seen, node) {
      continue
    }
    seen.push(node)
    stack.push((node, true))
    let kids = node.plan_children()
    for i in 0..<kids.length() {
      stack.push((kids[kids.length() - 1 - i], false))
    }
  }
  out
}

///|
/// The memoised result of `node`, scanned newest-first so the common case —
/// a linear pipeline reading the frame computed immediately before — hits on
/// the first probe. `post_order_unique` emits every child before its parent,
/// so the scan always finds its node; that contract has no type-level
/// spelling (the key is physical identity, which nothing hashes), so a miss
/// is refused with `InvalidOperation` instead of answered with some other
/// node's frame — a wrong-entry answer would turn a broken walk into
/// silently wrong data.
fn memo_result(
  memo : Array[(LogicalPlan, @frame.DataFrame)],
  node : LogicalPlan,
) -> @frame.DataFrame raise @types.DataError {
  for i = memo.length() - 1; i >= 0; i = i - 1 {
    if physical_equal(memo[i].0, node) {
      return memo[i].1
    }
  }
  raise @types.DataError::InvalidOperation(
    "plan memo miss: the fold read a node the post-order walk never emitted",
  )
}
