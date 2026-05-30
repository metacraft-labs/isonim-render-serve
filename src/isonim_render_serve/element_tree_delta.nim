## element_tree_delta — ETS-M2 Part B.
##
## Per-element delta wire format for the `element-tree-delta`
## M-subtype. The ETS-M1 audit (§ 7.1) recommended this nest inside
## the existing M-packet rather than introducing a brand-new E-packet
## tag: it reuses the dispatcher, the capability handshake, and the
## back-compat fall-through path. The wire-byte verbosity penalty of
## JSON is not load-bearing given measured idle bandwidth is already
## 0 B/s (audit § 6).
##
## Body shape (wrapped in the standard M packet via `encodeMeta`):
##
##   {
##     "type": "element-tree-delta",
##     "seq": <u32>,
##     "ops": [
##       { "op": "add",
##         "id": "...", "parent": "..." (optional),
##         "x": ..., "y": ..., "w": ..., "h": ...,
##         "kind": "...", "label": "..." (optional),
##         "metadata": { ... } (optional) },
##       { "op": "update", "id": "...",
##         "x": ..., "y": ..., "w": ..., "h": ..., (sparse — only
##                                                 changed fields)
##         "kind": "...", (sparse)
##         "label": "...", (sparse)
##         "metadata": { ... } (sparse) },
##       { "op": "remove", "id": "..." }
##     ]
##   }
##
## Notes:
##   * `op` is the variant discriminator (add / update / remove).
##   * `add` carries the full element shape.
##   * `update` carries only the changed fields (sparse encoding —
##     unchanged fields are omitted).
##   * `remove` carries only the id.
##   * `seq` is monotonic per-connection so the browser can detect
##     dropped deltas and request a fresh snapshot.
##   * `parent` is only set on `add` because the tree shape is stable
##     across `update` ops.
##   * `label` and `metadata` slots are reserved for the
##     comment-mode / aria broadening planned in a follow-up (§ 5 of
##     the audit). The current `ElementEntry` shape carries neither
##     so these are emitted only when callers attach them via the
##     codec helpers below.
##
## The JSON is produced with a hand-rolled stable serializer (no
## `std/json`) so the byte ordering is deterministic across Nim
## versions and round-trip tests can lock the exact wire bytes.

import std/[json, options, strutils, tables]

import ./packet

const ElementTreeDeltaType* = "element-tree-delta"
  ## The M-subtype discriminator string. The browser-side dispatcher
  ## (and the bridge-side back-compat path) probe `"type":"<this>"`
  ## to route between the legacy full-manifest body and the delta.

type
  ElementOpKind* = enum
    eopAdd
    eopUpdate
    eopRemove

  ElementOp* = object
    ## One operation in a delta. Field semantics depend on `kind`:
    ##
    ##   * `eopAdd`: `id`, `componentPath`, `elemKind`, `bounds` are
    ##     all populated; `parent` is set when the launcher knows the
    ##     parent id (empty otherwise).
    ##   * `eopUpdate`: `id` is populated; the other fields are
    ##     present only when they changed. The `*Set` bools flag
    ##     which fields are sparse-populated.
    ##   * `eopRemove`: only `id` is populated.
    case kind*: ElementOpKind
    of eopAdd:
      addId*: string
      addParent*: string
      addComponentPath*: string
      addElemKind*: string
      addBounds*: ElementBounds
      addLabel*: string
      addMetadata*: string  ## JSON object as a raw string; "" if absent
    of eopUpdate:
      updId*: string
      updBoundsSet*: bool
      updBounds*: ElementBounds
      updComponentPathSet*: bool
      updComponentPath*: string
      updElemKindSet*: bool
      updElemKind*: string
      updLabelSet*: bool
      updLabel*: string
      updMetadataSet*: bool
      updMetadata*: string
    of eopRemove:
      remId*: string

# ---------------------------------------------------------------------------
# Diff computation
# ---------------------------------------------------------------------------

proc computeElementTreeDelta*(prev: ElementTreeManifest;
                              curr: ElementTreeManifest): seq[ElementOp] =
  ## Compute the per-element delta from `prev` to `curr`. Strategy:
  ## index both manifests by `id`, then iterate the union of ids:
  ##
  ##   * present in `curr` only -> emit `eopAdd` with the full
  ##     element shape.
  ##   * present in both with different (bounds, componentPath, or
  ##     elemKind) -> emit `eopUpdate` with the changed fields only.
  ##   * present in `prev` only -> emit `eopRemove` with the id.
  ##
  ## The op order is: removes first (so the consumer can free the
  ## slot before re-binding ids), then adds (so newly-added children
  ## of a moved parent land after their parent), then updates. The
  ## browser-side cache applies them in that order.
  result = @[]
  var prevById = initTable[string, ElementEntry]()
  for e in prev.elements:
    prevById[e.id] = e
  var currById = initTable[string, ElementEntry]()
  for e in curr.elements:
    currById[e.id] = e

  # Removes: in prev, missing in curr.
  for id, _ in prevById:
    if id notin currById:
      result.add ElementOp(kind: eopRemove, remId: id)

  # Adds: in curr, missing in prev. Preserve curr-order so the
  # browser-side cache iterates parents-before-children when the
  # launcher emits them DFS.
  for e in curr.elements:
    if e.id notin prevById:
      result.add ElementOp(
        kind: eopAdd,
        addId: e.id,
        addParent: "",  # ElementEntry has no parent_id today (audit § 5)
        addComponentPath: e.componentPath,
        addElemKind: e.kind,
        addBounds: e.bounds,
        addLabel: "",
        addMetadata: "")

  # Updates: in both, sparse over the changed fields. Order follows
  # curr-order for stability across re-emissions of the same diff.
  for e in curr.elements:
    if e.id in prevById:
      let p = prevById[e.id]
      let boundsChanged = (p.bounds.x != e.bounds.x or
                           p.bounds.y != e.bounds.y or
                           p.bounds.w != e.bounds.w or
                           p.bounds.h != e.bounds.h)
      let kindChanged = (p.kind != e.kind)
      let pathChanged = (p.componentPath != e.componentPath)
      if boundsChanged or kindChanged or pathChanged:
        var op = ElementOp(kind: eopUpdate, updId: e.id)
        if boundsChanged:
          op.updBoundsSet = true
          op.updBounds = e.bounds
        if kindChanged:
          op.updElemKindSet = true
          op.updElemKind = e.kind
        if pathChanged:
          op.updComponentPathSet = true
          op.updComponentPath = e.componentPath
        result.add op

# ---------------------------------------------------------------------------
# JSON encoder (hand-rolled, byte-stable field ordering)
# ---------------------------------------------------------------------------

proc escapeJsonStr(s: string): string =
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ch.uint8 < 0x20'u8:
        const hexChars = "0123456789abcdef"
        result.add "\\u00"
        result.add hexChars[int(ch.uint8 shr 4)]
        result.add hexChars[int(ch.uint8 and 0x0F'u8)]
      else:
        result.add ch
  result.add '"'

proc encodeElementTreeDelta*(ops: seq[ElementOp]; seq: uint32): string =
  ## Encode an op list to the `element-tree-delta` JSON body. Stable
  ## field ordering — `type`, `seq`, then `ops` in caller order; per
  ## op, fields are emitted in a fixed order (op, id, parent,
  ## bounds-as-flat-xywh, kind, componentPath, label, metadata).
  ##
  ## Bounds are inlined as flat `x/y/w/h` fields on the op (not nested
  ## inside a `bounds` object) so the consumer can read them in one
  ## sweep — matches the brief's example wire shape.
  result = newStringOfCap(64 + 96 * ops.len)
  result.add "{\"type\":\""
  result.add ElementTreeDeltaType
  result.add "\",\"seq\":"
  result.add $seq
  result.add ",\"ops\":["
  for i, op in ops:
    if i > 0: result.add ','
    result.add '{'
    case op.kind
    of eopAdd:
      result.add "\"op\":\"add\""
      result.add ",\"id\":"
      result.add escapeJsonStr(op.addId)
      if op.addParent.len > 0:
        result.add ",\"parent\":"
        result.add escapeJsonStr(op.addParent)
      result.add ",\"x\":"
      result.add $op.addBounds.x
      result.add ",\"y\":"
      result.add $op.addBounds.y
      result.add ",\"w\":"
      result.add $op.addBounds.w
      result.add ",\"h\":"
      result.add $op.addBounds.h
      result.add ",\"kind\":"
      result.add escapeJsonStr(op.addElemKind)
      result.add ",\"componentPath\":"
      result.add escapeJsonStr(op.addComponentPath)
      if op.addLabel.len > 0:
        result.add ",\"label\":"
        result.add escapeJsonStr(op.addLabel)
      if op.addMetadata.len > 0:
        result.add ",\"metadata\":"
        result.add op.addMetadata
    of eopUpdate:
      result.add "\"op\":\"update\""
      result.add ",\"id\":"
      result.add escapeJsonStr(op.updId)
      if op.updBoundsSet:
        result.add ",\"x\":"
        result.add $op.updBounds.x
        result.add ",\"y\":"
        result.add $op.updBounds.y
        result.add ",\"w\":"
        result.add $op.updBounds.w
        result.add ",\"h\":"
        result.add $op.updBounds.h
      if op.updElemKindSet:
        result.add ",\"kind\":"
        result.add escapeJsonStr(op.updElemKind)
      if op.updComponentPathSet:
        result.add ",\"componentPath\":"
        result.add escapeJsonStr(op.updComponentPath)
      if op.updLabelSet:
        result.add ",\"label\":"
        result.add escapeJsonStr(op.updLabel)
      if op.updMetadataSet:
        result.add ",\"metadata\":"
        result.add op.updMetadata
    of eopRemove:
      result.add "\"op\":\"remove\""
      result.add ",\"id\":"
      result.add escapeJsonStr(op.remId)
    result.add '}'
  result.add "]}"

proc encodeElementTreeDeltaMeta*(ops: seq[ElementOp];
                                 seq: uint32): MetaPacket =
  ## Helper: wrap the delta body in a `MetaPacket` (the bridge's
  ## `sendBinary` consumes that directly via `encodeMeta`).
  MetaPacket(json: encodeElementTreeDelta(ops, seq))

# ---------------------------------------------------------------------------
# JSON decoder
# ---------------------------------------------------------------------------

type DecodedElementTreeDelta* = object
  ## Output shape of `decodeElementTreeDelta`. The bridge tests round-
  ## trip via this; the browser-side handler under ETS-M4 will
  ## consume the same shape.
  seqNo*: uint32
  ops*: seq[ElementOp]

proc decodeElementTreeDelta*(body: string): DecodedElementTreeDelta =
  ## Decode an `element-tree-delta` JSON body. Raises
  ## `PacketProtocolError` on shape violations.
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError, ValueError:
    raise newException(PacketProtocolError,
      "element-tree-delta body is not valid JSON")
  if node.kind != JObject:
    raise newException(PacketProtocolError,
      "element-tree-delta body is not a JSON object")
  if not node.hasKey("type") or node["type"].kind != JString or
      node["type"].getStr != ElementTreeDeltaType:
    raise newException(PacketProtocolError,
      "element-tree-delta body has wrong type")
  if not node.hasKey("seq") or node["seq"].kind != JInt:
    raise newException(PacketProtocolError,
      "element-tree-delta body missing seq")
  result.seqNo = uint32(node["seq"].getInt)
  if not node.hasKey("ops") or node["ops"].kind != JArray:
    raise newException(PacketProtocolError,
      "element-tree-delta body missing ops array")
  for raw in node["ops"]:
    if raw.kind != JObject:
      raise newException(PacketProtocolError,
        "element-tree-delta op is not an object")
    if not raw.hasKey("op") or raw["op"].kind != JString:
      raise newException(PacketProtocolError,
        "element-tree-delta op missing discriminator")
    let opStr = raw["op"].getStr
    if not raw.hasKey("id") or raw["id"].kind != JString:
      raise newException(PacketProtocolError,
        "element-tree-delta op missing id")
    let id = raw["id"].getStr
    template optStr(name: string): string =
      if raw.hasKey(name) and raw[name].kind == JString:
        raw[name].getStr
      else: ""
    template hasInt(name: string): bool =
      raw.hasKey(name) and raw[name].kind == JInt
    template getInt(name: string): int =
      raw[name].getInt
    case opStr
    of "add":
      var op = ElementOp(kind: eopAdd, addId: id)
      op.addParent = optStr("parent")
      op.addComponentPath = optStr("componentPath")
      op.addElemKind = optStr("kind")
      if not (hasInt("x") and hasInt("y") and hasInt("w") and hasInt("h")):
        raise newException(PacketProtocolError,
          "element-tree-delta add op missing bounds fields")
      op.addBounds = ElementBounds(
        x: getInt("x"), y: getInt("y"),
        w: getInt("w"), h: getInt("h"))
      op.addLabel = optStr("label")
      if raw.hasKey("metadata") and raw["metadata"].kind == JObject:
        op.addMetadata = $raw["metadata"]
      result.ops.add op
    of "update":
      var op = ElementOp(kind: eopUpdate, updId: id)
      if hasInt("x") and hasInt("y") and hasInt("w") and hasInt("h"):
        op.updBoundsSet = true
        op.updBounds = ElementBounds(
          x: getInt("x"), y: getInt("y"),
          w: getInt("w"), h: getInt("h"))
      if raw.hasKey("kind") and raw["kind"].kind == JString:
        op.updElemKindSet = true
        op.updElemKind = raw["kind"].getStr
      if raw.hasKey("componentPath") and raw["componentPath"].kind == JString:
        op.updComponentPathSet = true
        op.updComponentPath = raw["componentPath"].getStr
      if raw.hasKey("label") and raw["label"].kind == JString:
        op.updLabelSet = true
        op.updLabel = raw["label"].getStr
      if raw.hasKey("metadata") and raw["metadata"].kind == JObject:
        op.updMetadataSet = true
        op.updMetadata = $raw["metadata"]
      result.ops.add op
    of "remove":
      result.ops.add ElementOp(kind: eopRemove, remId: id)
    else:
      raise newException(PacketProtocolError,
        "element-tree-delta unknown op discriminator: " & opStr)

proc isElementTreeDeltaBody*(body: string): bool =
  ## Cheap probe — substring scan for the type discriminator. Used by
  ## the bridge / editor dispatcher hot path to route between the
  ## legacy full-manifest body and the delta variant.
  body.contains("\"type\":\"element-tree-delta\"")

# ---------------------------------------------------------------------------
# Hello-accept transport tokens
# ---------------------------------------------------------------------------

const ElementTreeTransportToken* = "e/element-tree"
  ## Transport identifier the launcher advertises in the hello
  ## packet's capabilities.transports list when
  ## `-d:withElementTreeDelta` is on, and the browser echoes back in
  ## its hello-accept M packet. When the bridge sees this token in the
  ## accept list it switches the per-connection element-tree emission
  ## from the legacy full-manifest body to `element-tree-delta`.

proc helloAcceptAcceptsElementTreeDelta*(body: string): bool =
  ## Inspect a browser-emitted hello-accept M body (or any M body
  ## carrying an `accept` array of transport identifiers) and return
  ## true if `e/element-tree` is in the list. Returns false on any
  ## shape mismatch — that maps the safe (legacy) path on failure.
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError, ValueError:
    return false
  if node.kind != JObject: return false
  if not node.hasKey("accept"): return false
  if node["accept"].kind != JArray: return false
  for entry in node["accept"]:
    if entry.kind == JString and entry.getStr == ElementTreeTransportToken:
      return true
  false
