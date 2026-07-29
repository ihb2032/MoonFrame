// The structural equality over `ExprNode`, defined where the only code that
// needs it lives. No production code in this module compares two nodes: the
// engine matches on them, walks them, and renders them. What did need this
// relation was a public `Eq` on `@expr.Expr`, and removing that was the point
// — an equality over the tree *as built* would have made how an operator
// lowers part of the API.
//
// So it sits in a whitebox file: compiled inside the package, available to
// every `_wbtest.mbt` here, and absent from the generated interface that the
// internal-surface audit reads. The same goes for the four operator tags,
// whose equality this one consumes.
//
// The four operator tags keep their `derive(Eq)` in production, and that is a
// deliberate line rather than an oversight: this comparison consumes it one
// file over, and hand-copying a fifteen-variant payload comparison into a test
// file to unpublish four symbols would trade a real risk of drift for a
// cosmetic win.
//
// The wildcard-free matches are load-bearing and stay that way: a variant
// added to `ExprNode` fails to compile here until its case is written, which
// is what keeps the coverage guard beside it honest.

///|
/// Structural equality, handwritten because the `Map` / `MapBatches` closures
/// have no `Eq`, so the enum cannot `derive` one. Two `Map` nodes are equal on
/// `(label, inputs)` with the function opaque; `MapBatches` also compares its
/// `returns_scalar` flag. Every other variant compares recursively.
///
/// Nothing outside this package reaches it: the `@expr.Expr` handle used to
/// forward an `Eq` here, and that is exactly what was removed — an equality
/// over the tree *as built* leaks how an operator lowers, so a caller could
/// depend on a lowering being one shape rather than another. What is left is
/// an internal relation this package's own tests pin — including the coverage
/// guard beside it, whose exhaustive match on the variants is what makes
/// adding one a compile error there.
impl Eq for ExprNode with fn equal(self, other) {
  nodes_structurally_equal(self, other)
}

///|

///|
/// Structural equality over an explicit work-stack of node pairs rather than
/// the call stack: a deeply nested tree (`col("a") + col("a") + …` tens of
/// thousands deep) would otherwise overflow the native stack and abort. Each
/// iteration matches the first operand wildcard-free and then the second, so a
/// differing variant short-circuits to `false` and a newly added `ExprNode`
/// variant fails to compile here until its case is written.
fn nodes_structurally_equal(first : ExprNode, second : ExprNode) -> Bool {
  let stack : Array[(ExprNode, ExprNode)] = [(first, second)]
  for ;; {
    match stack.pop() {
      None => break
      Some((a, b)) =>
        match a {
          Col(x) =>
            match b {
              Col(y) => if x != y { return false }
              _ => return false
            }
          Lit(x) =>
            match b {
              Lit(y) => if x != y { return false }
              _ => return false
            }
          LitSeries(x) =>
            match b {
              LitSeries(y) => if x != y { return false }
              _ => return false
            }
          Binary(o1, l1, r1) =>
            match b {
              Binary(o2, l2, r2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((l1, l2))
                stack.push((r1, r2))
              }
              _ => return false
            }
          Unary(o1, e1) =>
            match b {
              Unary(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Agg(o1, e1) =>
            match b {
              Agg(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Str(o1, e1) =>
            match b {
              Str(o2, e2) => {
                if o1 != o2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Cast(e1, t1) =>
            match b {
              Cast(e2, t2) => {
                if t1 != t2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Alias(e1, n1) =>
            match b {
              Alias(e2, n2) => {
                if n1 != n2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          Ternary(c1, t1, f1) =>
            match b {
              Ternary(c2, t2, f2) => {
                stack.push((c1, c2))
                stack.push((t1, t2))
                stack.push((f1, f2))
              }
              _ => return false
            }
          FillNull(o1, v1) =>
            match b {
              FillNull(o2, v2) => {
                stack.push((o1, o2))
                stack.push((v1, v2))
              }
              _ => return false
            }
          FillNan(o1, v1) =>
            match b {
              FillNan(o2, v2) => {
                stack.push((o1, o2))
                stack.push((v1, v2))
              }
              _ => return false
            }
          IsIn(e1, m1) =>
            match b {
              IsIn(e2, m2) => {
                if m1 != m2 {
                  return false
                }
                stack.push((e1, e2))
              }
              _ => return false
            }
          IsBetween(x1, l1, h1, c1) =>
            match b {
              IsBetween(x2, l2, h2, c2) => {
                if c1 != c2 {
                  return false
                }
                stack.push((x1, x2))
                stack.push((l1, l2))
                stack.push((h1, h2))
              }
              _ => return false
            }
          Map(l1, i1, _) =>
            match b {
              Map(l2, i2, _) => {
                if l1 != l2 || i1.length() != i2.length() {
                  return false
                }
                for k in 0..<i1.length() {
                  stack.push((i1[k], i2[k]))
                }
              }
              _ => return false
            }
          MapBatches(l1, i1, rs1, _) =>
            match b {
              MapBatches(l2, i2, rs2, _) => {
                if l1 != l2 || rs1 != rs2 || i1.length() != i2.length() {
                  return false
                }
                for k in 0..<i1.length() {
                  stack.push((i1[k], i2[k]))
                }
              }
              _ => return false
            }
        }
    }
  }
  true
}
