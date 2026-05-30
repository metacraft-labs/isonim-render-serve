## test_compute_element_tree_delta — ETS-M2 Part B.
##
## Pins `computeElementTreeDelta(prev, curr)`'s op-list output for
## known before / after manifest pairs. The diff strategy under
## test:
##
##   * Index both manifests by ``id``.
##   * Walk the union of ids:
##     - present in curr only -> ``eopAdd``  (full element shape)
##     - present in prev only -> ``eopRemove`` (id only)
##     - present in both with any of (bounds, kind, componentPath)
##       differing -> ``eopUpdate`` sparse over the changed fields
##     - present in both with no differences -> NO op emitted.
##
## Op-emission order matters because the browser-side cache applies
## removes-first / adds-next / updates-last so children of moved
## parents land after the parents themselves. The tests below pin
## that order.

import std/[unittest]

import isonim_render_serve

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc mkEntry(id: string; xx, yy, ww, hh: int; kind = "row";
             path = ""): ElementEntry =
  ElementEntry(id: id,
               componentPath: (if path.len > 0: path else: id),
               kind: kind,
               bounds: ElementBounds(x: xx, y: yy, w: ww, h: hh))

proc mkManifest(elements: seq[ElementEntry]; w = 640;
                h = 288): ElementTreeManifest =
  ElementTreeManifest(
    frameSeq: 0, surfaceWidth: w, surfaceHeight: h,
    elements: elements)

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "ETS-M2 Part B: computeElementTreeDelta":

  test "identical manifests produce zero ops":
    let prev = mkManifest(@[mkEntry("a", 0, 0, 10, 10),
                             mkEntry("b", 10, 0, 10, 10)])
    let curr = mkManifest(@[mkEntry("a", 0, 0, 10, 10),
                             mkEntry("b", 10, 0, 10, 10)])
    check computeElementTreeDelta(prev, curr).len == 0

  test "pure add — one new id":
    let prev = mkManifest(@[mkEntry("a", 0, 0, 10, 10)])
    let curr = mkManifest(@[mkEntry("a", 0, 0, 10, 10),
                             mkEntry("b", 10, 0, 10, 10, kind = "filter")])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 1
    check ops[0].kind == eopAdd
    check ops[0].addId == "b"
    check ops[0].addElemKind == "filter"
    check ops[0].addBounds.x == 10
    check ops[0].addBounds.w == 10

  test "pure remove — one disappearing id":
    let prev = mkManifest(@[mkEntry("a", 0, 0, 10, 10),
                             mkEntry("dropped", 20, 0, 10, 10)])
    let curr = mkManifest(@[mkEntry("a", 0, 0, 10, 10)])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 1
    check ops[0].kind == eopRemove
    check ops[0].remId == "dropped"

  test "pure bounds update — sparse over changed fields":
    let prev = mkManifest(@[mkEntry("a", 0, 0, 10, 10)])
    let curr = mkManifest(@[mkEntry("a", 5, 5, 20, 20)])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 1
    check ops[0].kind == eopUpdate
    check ops[0].updId == "a"
    check ops[0].updBoundsSet
    check ops[0].updBounds.x == 5
    check ops[0].updBounds.w == 20
    check not ops[0].updElemKindSet
    check not ops[0].updComponentPathSet

  test "pure kind update — closes the manifestKey-kind bug at delta level":
    # ETS-M2 Part A fixed the dedup hash to span `kind`; the diff
    # helper must agree — a kind-only change must produce a
    # kind-only update op, not a no-op.
    let prev = mkManifest(@[mkEntry("row-0", 0, 0, 10, 10, kind = "row")])
    let curr = mkManifest(@[
      mkEntry("row-0", 0, 0, 10, 10, kind = "row-completed")])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 1
    check ops[0].kind == eopUpdate
    check ops[0].updId == "row-0"
    check not ops[0].updBoundsSet
    check ops[0].updElemKindSet
    check ops[0].updElemKind == "row-completed"

  test "combined bounds + kind update — both flagged sparse":
    let prev = mkManifest(@[
      mkEntry("row-0", 0, 0, 10, 10, kind = "row")])
    let curr = mkManifest(@[
      mkEntry("row-0", 0, 12, 10, 10, kind = "row-completed")])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 1
    check ops[0].kind == eopUpdate
    check ops[0].updBoundsSet
    check ops[0].updBounds.y == 12
    check ops[0].updElemKindSet
    check ops[0].updElemKind == "row-completed"

  test "componentPath-only update":
    let prev = mkManifest(@[mkEntry("a", 0, 0, 10, 10, path = "p/A")])
    let curr = mkManifest(@[mkEntry("a", 0, 0, 10, 10, path = "p/A/renamed")])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 1
    check ops[0].kind == eopUpdate
    check not ops[0].updBoundsSet
    check not ops[0].updElemKindSet
    check ops[0].updComponentPathSet
    check ops[0].updComponentPath == "p/A/renamed"

  test "mixed delta — remove + add + update in one diff":
    let prev = mkManifest(@[
      mkEntry("keep", 0, 0, 10, 10),
      mkEntry("move", 10, 0, 10, 10),
      mkEntry("drop", 20, 0, 10, 10)])
    let curr = mkManifest(@[
      mkEntry("keep", 0, 0, 10, 10),
      mkEntry("move", 10, 12, 10, 10),  # bounds shift
      mkEntry("new",  30, 0, 10, 10)])  # added
    let ops = computeElementTreeDelta(prev, curr)
    # Ordering invariant: removes first, then adds, then updates.
    check ops.len == 3
    check ops[0].kind == eopRemove
    check ops[0].remId == "drop"
    check ops[1].kind == eopAdd
    check ops[1].addId == "new"
    check ops[2].kind == eopUpdate
    check ops[2].updId == "move"
    check ops[2].updBoundsSet
    check ops[2].updBounds.y == 12

  test "task-app insert-row scenario — measures bbox-shift cascade":
    # Insert a row at the top of the list: every row below the
    # insertion point gets a y-shift but keeps the same id. The
    # diff should produce exactly one add and N updates.
    var prevElements: seq[ElementEntry] = @[
      mkEntry("filter-bar", 0, 0, 640, 12, kind = "filter-bar")]
    for i in 0 ..< 5:
      prevElements.add mkEntry("row-" & $i, 0, 12 + i * 12, 640, 12)
    let prev = mkManifest(prevElements)

    var currElements: seq[ElementEntry] = @[
      mkEntry("filter-bar", 0, 0, 640, 12, kind = "filter-bar"),
      mkEntry("row-new", 0, 12, 640, 12)]
    for i in 0 ..< 5:
      currElements.add mkEntry("row-" & $i, 0, 24 + i * 12, 640, 12)
    let curr = mkManifest(currElements)

    let ops = computeElementTreeDelta(prev, curr)
    # 1 add + 5 updates = 6 ops.
    var adds = 0
    var updates = 0
    var removes = 0
    for op in ops:
      case op.kind
      of eopAdd: inc adds
      of eopUpdate: inc updates
      of eopRemove: inc removes
    check adds == 1
    check updates == 5
    check removes == 0
    # The added op should carry the full new row's shape.
    for op in ops:
      if op.kind == eopAdd:
        check op.addId == "row-new"
        check op.addBounds.y == 12
        check op.addElemKind == "row"

  test "empty curr produces removes for every prev entry":
    let prev = mkManifest(@[
      mkEntry("a", 0, 0, 10, 10),
      mkEntry("b", 0, 12, 10, 10),
      mkEntry("c", 0, 24, 10, 10)])
    let curr = mkManifest(@[])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 3
    var removed: seq[string] = @[]
    for op in ops:
      check op.kind == eopRemove
      removed.add op.remId
    check "a" in removed
    check "b" in removed
    check "c" in removed

  test "empty prev produces adds for every curr entry":
    let prev = mkManifest(@[])
    let curr = mkManifest(@[
      mkEntry("a", 0, 0, 10, 10),
      mkEntry("b", 0, 12, 10, 10)])
    let ops = computeElementTreeDelta(prev, curr)
    check ops.len == 2
    check ops[0].kind == eopAdd
    check ops[0].addId == "a"
    check ops[1].kind == eopAdd
    check ops[1].addId == "b"
