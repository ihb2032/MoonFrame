// AST metadata analysis over `ExprNode` — the column-reference set a tree reads
// and the output-column name it produces. These are pure walks of the AST
// shape, so they live beside it in `internal/ir` rather than on the public
// `@expr.Expr` handle; the engine reaches them through `Expr::node()`. Both are
// total — they only inspect shape, and the walks are iterative (explicit heap
// stack, not the call stack) so an arbitrarily deep tree cannot overflow and
// abort.

///|
/// Every column name the tree references, as a set — membership only; iteration
/// order is neither significant nor guaranteed. A `Ternary`'s condition counts
/// (the optimizer must keep a column alive even if only the condition reads it),
/// unlike output *naming*, which draws from the value branches only. Duplicates
/// collapse: `col("a") + col("a")` references `{"a"}`.
pub fn ExprNode::referenced_columns(self : ExprNode) -> @set.Set[String] {
  let acc : @set.Set[String] = @set.Set([])
  // Explicit heap stack (not the call stack): a deeply nested tree would
  // otherwise overflow and abort. Children pushed right-to-left so the leftmost
  // pops first; for a `Set` the visit order is not observable anyway.
  let stack : Array[ExprNode] = [self]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) => {
        match e {
          Col(name) => acc.add(name)
          _ => ()
        }
        let children = e.children()
        for i = children.length() - 1; i >= 0; i = i - 1 {
          stack.push(children[i])
        }
      }
    }
  }
  acc
}

///|
/// The output-column name this expression produces — Polars' naming rule: an
/// alias wins, otherwise the leftmost column reference's name, otherwise
/// `"literal"` for a column-less tree. One rule, two consumers that must never
/// drift apart: the eager materialisers in `frame` (`with_columns` / `select` /
/// `agg`) name their output columns with it, and the lazy optimizer's projection
/// pushdown uses it to know which names a deferred `with_columns` stage
/// *defines* — a defined name need not exist in the stage's input, so pruning
/// must not require it there.
pub fn ExprNode::output_name(self : ExprNode) -> String {
  leftmost_name(self).unwrap_or("literal")
}

///|
/// Depth-first, left-to-right search for the first *naming* node behind
/// `output_name`. An `Alias` names its whole subtree, so an alias anywhere on
/// the leftmost path wins over the `Col` beneath it; the wrappers
/// (`Unary` / `Agg` / `Cast`) and the binary / map operands are name-transparent,
/// so the search rides `children` for them, taking the first child to yield a
/// name (a `Map` is thus named after its leftmost input, like Polars'
/// `map_elements`). A `LitSeries` names itself after the series it carries — like
/// a `Col`. A `Ternary` draws its name from the value branches — `then` first,
/// `otherwise` as fallback — never from the condition (the condition gates rows,
/// it does not produce output values), so it is matched explicitly rather than
/// walking all of its children. (`referenced_columns`, by contrast, includes
/// condition columns — pushdown must keep them alive.)
fn leftmost_name(node : ExprNode) -> String? {
  let stack : Array[ExprNode] = [node]
  for ;; {
    match stack.pop() {
      None => break
      Some(e) =>
        match e {
          Col(name) => return Some(name)
          LitSeries(s) => return Some(s.name())
          Alias(_, name) => return Some(name)
          Ternary(_, t, f) => {
            stack.push(f)
            stack.push(t)
          }
          _ => {
            let children = e.children()
            for i = children.length() - 1; i >= 0; i = i - 1 {
              stack.push(children[i])
            }
          }
        }
    }
  }
  None
}
