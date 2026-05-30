## test_element_tree_delta_codec_roundtrip — ETS-M2 Part B.
##
## Locks the on-wire JSON shape of the ``element-tree-delta``
## M-subtype across encode → decode → re-encode cycles. The
## bytes are produced by a hand-rolled stable serializer
## (`encodeElementTreeDelta`) so the round-trip can pin field
## ordering and integer formatting; future codec edits that shift
## any byte fail loudly here rather than silently desyncing the
## browser-side decoder.
##
## Covers ten op-list shapes:
##   1. Empty op list (heartbeat-style emission).
##   2. Single ``add``.
##   3. Single ``update`` with only bounds changing.
##   4. Single ``update`` with only kind changing.
##   5. Sparse ``update`` with both bounds and kind (multi-field).
##   6. Single ``remove``.
##   7. Mass ``update`` (10 simultaneous updates).
##   8. Mixed (add + update + remove in one delta).
##   9. Remove-only batch (5 removes).
##  10. JSON-escape exercise — quotes / backslashes / control
##      chars in id and kind.

import std/[json, strutils, unittest]

import isonim_render_serve

proc opsEqual(a, b: ElementOp): bool =
  if a.kind != b.kind: return false
  case a.kind
  of eopAdd:
    return a.addId == b.addId and
           a.addParent == b.addParent and
           a.addComponentPath == b.addComponentPath and
           a.addElemKind == b.addElemKind and
           a.addBounds.x == b.addBounds.x and
           a.addBounds.y == b.addBounds.y and
           a.addBounds.w == b.addBounds.w and
           a.addBounds.h == b.addBounds.h and
           a.addLabel == b.addLabel
  of eopUpdate:
    if a.updId != b.updId: return false
    if a.updBoundsSet != b.updBoundsSet: return false
    if a.updBoundsSet and (a.updBounds.x != b.updBounds.x or
                           a.updBounds.y != b.updBounds.y or
                           a.updBounds.w != b.updBounds.w or
                           a.updBounds.h != b.updBounds.h):
      return false
    if a.updElemKindSet != b.updElemKindSet: return false
    if a.updElemKindSet and a.updElemKind != b.updElemKind:
      return false
    if a.updComponentPathSet != b.updComponentPathSet: return false
    if a.updComponentPathSet and
        a.updComponentPath != b.updComponentPath:
      return false
    return true
  of eopRemove:
    return a.remId == b.remId

proc roundTrip(ops: seq[ElementOp]; seqNo: uint32):
              (string, DecodedElementTreeDelta) =
  let enc1 = encodeElementTreeDelta(ops, seqNo)
  let dec = decodeElementTreeDelta(enc1)
  (enc1, dec)

suite "ETS-M2 Part B: element-tree-delta codec round-trip":

  test "1. empty op list encodes / decodes / re-encodes byte-identically":
    let (enc1, dec) = roundTrip(@[], 0)
    check dec.seqNo == 0'u32
    check dec.ops.len == 0
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2
    check enc1 == "{\"type\":\"element-tree-delta\",\"seq\":0,\"ops\":[]}"

  test "2. single add round-trips with all fields preserved":
    let ops = @[
      ElementOp(kind: eopAdd,
                addId: "task_app/views/TaskRow#7",
                addParent: "task_app/views/TaskList",
                addComponentPath: "task_app/views/TaskRow#7",
                addElemKind: "row",
                addBounds: ElementBounds(x: 0, y: 84, w: 640, h: 12))]
    let (enc1, dec) = roundTrip(ops, 17'u32)
    check dec.seqNo == 17'u32
    check dec.ops.len == 1
    check opsEqual(dec.ops[0], ops[0])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2

  test "3. single update — bounds only":
    let ops = @[
      ElementOp(kind: eopUpdate, updId: "task_app/views/TaskRow#0",
                updBoundsSet: true,
                updBounds: ElementBounds(x: 0, y: 240, w: 640, h: 12))]
    let (enc1, dec) = roundTrip(ops, 1)
    check dec.ops.len == 1
    check opsEqual(dec.ops[0], ops[0])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2
    # Confirm the sparse encoding really is sparse — the body must
    # NOT carry a kind / componentPath field when those weren't set.
    check not enc1.contains("\"kind\"")
    check not enc1.contains("\"componentPath\"")

  test "4. single update — kind only":
    let ops = @[
      ElementOp(kind: eopUpdate, updId: "row-3",
                updElemKindSet: true, updElemKind: "row-completed")]
    let (enc1, dec) = roundTrip(ops, 4)
    check dec.ops.len == 1
    check opsEqual(dec.ops[0], ops[0])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2
    # Sparse: no bounds in the body.
    check not enc1.contains("\"x\":")

  test "5. sparse update — bounds AND kind AND componentPath":
    let ops = @[
      ElementOp(kind: eopUpdate, updId: "filter-bar",
                updBoundsSet: true,
                updBounds: ElementBounds(x: 0, y: 12, w: 320, h: 12),
                updElemKindSet: true,
                updElemKind: "filter-bar-active",
                updComponentPathSet: true,
                updComponentPath: "task_app/views/FilterBar/Active")]
    let (enc1, dec) = roundTrip(ops, 9)
    check dec.ops.len == 1
    check opsEqual(dec.ops[0], ops[0])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2

  test "6. single remove":
    let ops = @[ElementOp(kind: eopRemove, remId: "task_app/views/TaskRow#99")]
    let (enc1, dec) = roundTrip(ops, 42)
    check dec.ops.len == 1
    check opsEqual(dec.ops[0], ops[0])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2

  test "7. mass update — 10 simultaneous bounds shifts":
    var ops: seq[ElementOp] = @[]
    for i in 0 ..< 10:
      ops.add ElementOp(
        kind: eopUpdate, updId: "row-" & $i,
        updBoundsSet: true,
        updBounds: ElementBounds(x: 0, y: i * 12, w: 640, h: 12))
    let (enc1, dec) = roundTrip(ops, 100)
    check dec.ops.len == 10
    for i in 0 ..< 10:
      check opsEqual(dec.ops[i], ops[i])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2

  test "8. mixed batch — add + update + remove":
    let ops = @[
      ElementOp(kind: eopRemove, remId: "old-row"),
      ElementOp(kind: eopAdd,
                addId: "new-row",
                addParent: "",
                addComponentPath: "x/NewRow",
                addElemKind: "row",
                addBounds: ElementBounds(x: 0, y: 0, w: 100, h: 12)),
      ElementOp(kind: eopUpdate, updId: "existing-row",
                updBoundsSet: true,
                updBounds: ElementBounds(x: 0, y: 12, w: 100, h: 12))]
    let (enc1, dec) = roundTrip(ops, 7)
    check dec.ops.len == 3
    for i in 0 ..< 3:
      check opsEqual(dec.ops[i], ops[i])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2

  test "9. remove-only batch — 5 removes":
    var ops: seq[ElementOp] = @[]
    for i in 0 ..< 5:
      ops.add ElementOp(kind: eopRemove, remId: "dropped-" & $i)
    let (enc1, dec) = roundTrip(ops, 50)
    check dec.ops.len == 5
    for i in 0 ..< 5:
      check opsEqual(dec.ops[i], ops[i])
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2

  test "10. JSON-escape exercise — quote, backslash, newline, tab":
    let ops = @[
      ElementOp(kind: eopAdd,
                addId: "id\"with\\escape\nand\ttab",
                addParent: "",
                addComponentPath: "weird/Path",
                addElemKind: "kind-with\"quote",
                addBounds: ElementBounds(x: 0, y: 0, w: 1, h: 1))]
    let (enc1, dec) = roundTrip(ops, 1)
    check dec.ops.len == 1
    check dec.ops[0].addId == "id\"with\\escape\nand\ttab"
    check dec.ops[0].addElemKind == "kind-with\"quote"
    let enc2 = encodeElementTreeDelta(dec.ops, dec.seqNo)
    check enc1 == enc2
    # Belt-and-suspenders: the body must parse as JSON via std/json
    # too, so it's interoperable with non-Nim consumers.
    let node = parseJson(enc1)
    check node["type"].getStr == "element-tree-delta"
    check node["ops"].len == 1

  test "isElementTreeDeltaBody discriminates from other sub-kinds":
    check isElementTreeDeltaBody(encodeElementTreeDelta(@[], 0))
    check not isElementTreeDeltaBody("{\"type\":\"hello\"}")
    check not isElementTreeDeltaBody(
      "{\"type\":\"element-tree\",\"frameSeq\":0}")

  test "decoder rejects wrong type":
    expect PacketProtocolError:
      discard decodeElementTreeDelta("{\"type\":\"hello\"}")

  test "decoder rejects missing seq":
    expect PacketProtocolError:
      discard decodeElementTreeDelta(
        "{\"type\":\"element-tree-delta\",\"ops\":[]}")

  test "decoder rejects unknown op discriminator":
    expect PacketProtocolError:
      discard decodeElementTreeDelta(
        "{\"type\":\"element-tree-delta\",\"seq\":0,\"ops\":" &
        "[{\"op\":\"frobulate\",\"id\":\"x\"}]}")
