///|
/// Whitebox coverage for the multi-input `MapBatches` render. `Expr::map_batches`
/// only ever builds a single-input node (`[self]`), but the variant is
/// multi-input-capable in storage — the shape a future `map_batches_many` would
/// use, mirroring `map_many` for `Map`. Construct a two-input node directly
/// (possible only in-package) so the `", "` input separator in the `explain`
/// render is exercised, matching how the public `map_many` covers `Map`'s.
test "map_batches renders multiple inputs comma-separated" {
  let node : Expr = MapBatches(
    "combine",
    [Expr::col("a"), Expr::col("b")],
    false,
    vs => vs[0],
  )
  inspect(node.explain(), content="map_batches(\"combine\", [col(a), col(b)])")
  // The reducing flag still appends its marker with several inputs.
  let reducing : Expr = MapBatches(
    "combine",
    [Expr::col("a"), Expr::col("b")],
    true,
    vs => vs[0],
  )
  inspect(
    reducing.explain(),
    content="map_batches(\"combine\", [col(a), col(b)], returns_scalar=true)",
  )
}
