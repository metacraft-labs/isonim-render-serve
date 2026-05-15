## F / M / I packet codec — implements the wire format locked at
## RS-M0 (see `codetracer-specs/Front-Ends/IsoNim/`
## `isonim-render-stream.status.org` § *Architecture sketch — render
## streaming*).
##
## Byte layouts (all multi-byte ints little-endian):
##
##   F packet: 'F'(1) + u8 flags + u32 width + u32 height + u32 length
##             + payload
##   M packet: 'M'(1) + u32 length + UTF-8 JSON body
##   I packet: 'I'(1) + u32 length + UTF-8 JSON body
##
## F packet flag byte:
##   * bit 0 (0x01): 0 = full RGBA frame, 1 = diff-region frame.
##   * bit 1 (0x02): 0 = uncompressed RGBA8888, 1 = reserved
##     (video/h264, deferred to a later milestone).
##   * bits 2..7: reserved, MUST be zero. Non-zero reserved bits
##     trigger a `PacketProtocolError`; callers are expected to
##     close the connection with WS status 1002.
##
## F payload — full frame: exactly `width * height * 4` bytes of
## RGBA8888 row-major.
##
## F payload — diff frame: `u32 count + count × { u32 x, u32 y,
## u32 w, u32 h, u32 length, RGBA bytes }`. Each rect's `length`
## MUST equal `w * h * 4`.

import std/[json, strutils]

type
  PacketKind* = enum
    pkFrame = 'F'
    pkMeta = 'M'
    pkInput = 'I'

  FrameFlags* = object
    isDiff*: bool      ## bit 0
    isVideo*: bool     ## bit 1 — reserved at v1; always false on the wire

  DirtyRect* = object
    x*, y*, w*, h*: int
    pixels*: seq[byte]    ## RGBA8888 row-major, length == w * h * 4

  FrameKindCase* = enum
    fkFull, fkDiff

  Frame* = object
    flags*: FrameFlags
    width*, height*: int
    case kind*: FrameKindCase
    of fkFull:
      pixels*: seq[byte]    ## RGBA8888 row-major; length == width*height*4
    of fkDiff:
      rects*: seq[DirtyRect]

  MetaPacket* = object
    json*: string

  InputPacket* = object
    json*: string

  PacketProtocolError* = object of CatchableError
    ## Raised on any wire-protocol violation: unknown tag byte,
    ## truncated header / payload, reserved flag bits set, mismatched
    ## payload length. The bridge MUST close the WS connection with
    ## status code 1002 (RFC 6455 §7.4.1) when this is raised on
    ## inbound data.

# ---------------------------------------------------------------------------
# Little-endian helpers — kept inline so the codec can be benchmarked
# without pulling in `std/endians` ceremony.
# ---------------------------------------------------------------------------

proc putU32LE(buf: var seq[byte]; v: uint32) =
  buf.add byte(v and 0xFF'u32)
  buf.add byte((v shr 8) and 0xFF'u32)
  buf.add byte((v shr 16) and 0xFF'u32)
  buf.add byte((v shr 24) and 0xFF'u32)

proc readU32LE(buf: openArray[byte]; off: int): uint32 =
  uint32(buf[off]) or
    (uint32(buf[off + 1]) shl 8) or
    (uint32(buf[off + 2]) shl 16) or
    (uint32(buf[off + 3]) shl 24)

# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

proc encodeFrameFlags*(flags: FrameFlags): uint8 =
  ## Pack the flag-byte. Reserved bits are always emitted as zero.
  result = 0
  if flags.isDiff: result = result or 0x01'u8
  if flags.isVideo: result = result or 0x02'u8

proc decodeFrameFlags*(b: uint8): FrameFlags =
  ## Decode the flag byte. Reserved bits 2..7 MUST be zero; raise
  ## `PacketProtocolError` otherwise.
  if (b and 0xFC'u8) != 0:
    raise newException(PacketProtocolError,
      "F flag byte has non-zero reserved bits: " & $b)
  result.isDiff = (b and 0x01'u8) != 0
  result.isVideo = (b and 0x02'u8) != 0

proc encodeFrame*(frame: Frame): seq[byte] =
  ## Encode an F packet exactly as specified at RS-M0.
  var payload = newSeq[byte]()
  case frame.kind
  of fkFull:
    let expected = frame.width * frame.height * 4
    if frame.pixels.len != expected:
      raise newException(PacketProtocolError,
        "full frame pixel buffer length " & $frame.pixels.len &
        " does not match width*height*4 = " & $expected)
    payload = frame.pixels
  of fkDiff:
    putU32LE(payload, uint32(frame.rects.len))
    for r in frame.rects:
      let expected = r.w * r.h * 4
      if r.pixels.len != expected:
        raise newException(PacketProtocolError,
          "diff rect pixel buffer length " & $r.pixels.len &
          " does not match w*h*4 = " & $expected)
      putU32LE(payload, uint32(r.x))
      putU32LE(payload, uint32(r.y))
      putU32LE(payload, uint32(r.w))
      putU32LE(payload, uint32(r.h))
      putU32LE(payload, uint32(r.pixels.len))
      for b in r.pixels: payload.add b
  var flags = frame.flags
  flags.isDiff = (frame.kind == fkDiff)
  result = newSeqOfCap[byte](14 + payload.len)
  result.add byte('F')
  result.add encodeFrameFlags(flags)
  putU32LE(result, uint32(frame.width))
  putU32LE(result, uint32(frame.height))
  putU32LE(result, uint32(payload.len))
  for b in payload: result.add b

proc decodeFrame*(bytes: openArray[byte]): Frame =
  ## Decode an F packet. Raises `PacketProtocolError` on any wire
  ## violation (wrong tag, truncated header, reserved flag bits set,
  ## mismatched payload length).
  if bytes.len < 14:
    raise newException(PacketProtocolError,
      "F packet truncated; need >= 14 bytes, got " & $bytes.len)
  if bytes[0] != byte('F'):
    raise newException(PacketProtocolError,
      "expected tag 'F' (0x46), got 0x" & $bytes[0])
  let flags = decodeFrameFlags(bytes[1])
  if flags.isVideo:
    raise newException(PacketProtocolError,
      "F encoding bit 1 (video/h264) is reserved at protocolVersion=1")
  let width = int(readU32LE(bytes, 2))
  let height = int(readU32LE(bytes, 6))
  let length = int(readU32LE(bytes, 10))
  if bytes.len - 14 != length:
    raise newException(PacketProtocolError,
      "F payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - 14))
  if flags.isDiff:
    if length < 4:
      raise newException(PacketProtocolError,
        "F diff payload truncated; need u32 count")
    let count = int(readU32LE(bytes, 14))
    var rects = newSeqOfCap[DirtyRect](count)
    var off = 18
    for i in 0 ..< count:
      if off + 20 > bytes.len:
        raise newException(PacketProtocolError,
          "F diff rect header truncated at rect " & $i)
      let rx = int(readU32LE(bytes, off))
      let ry = int(readU32LE(bytes, off + 4))
      let rw = int(readU32LE(bytes, off + 8))
      let rh = int(readU32LE(bytes, off + 12))
      let rl = int(readU32LE(bytes, off + 16))
      off += 20
      if rl != rw * rh * 4:
        raise newException(PacketProtocolError,
          "F diff rect " & $i & " length " & $rl &
          " != w*h*4 (" & $(rw * rh * 4) & ")")
      if off + rl > bytes.len:
        raise newException(PacketProtocolError,
          "F diff rect " & $i & " payload truncated")
      var pixels = newSeq[byte](rl)
      for j in 0 ..< rl: pixels[j] = bytes[off + j]
      off += rl
      rects.add DirtyRect(x: rx, y: ry, w: rw, h: rh, pixels: pixels)
    if off != bytes.len:
      raise newException(PacketProtocolError,
        "F diff payload trailing bytes: " & $(bytes.len - off))
    result = Frame(kind: fkDiff, flags: flags, width: width, height: height,
                   rects: rects)
  else:
    let expected = width * height * 4
    if length != expected:
      raise newException(PacketProtocolError,
        "F full payload length " & $length &
        " != width*height*4 (" & $expected & ")")
    var pixels = newSeq[byte](length)
    for i in 0 ..< length: pixels[i] = bytes[14 + i]
    result = Frame(kind: fkFull, flags: flags, width: width, height: height,
                   pixels: pixels)

proc encodeMeta*(meta: MetaPacket): seq[byte] =
  ## Encode an M packet: 'M' + u32 LE length + UTF-8 JSON.
  let n = meta.json.len
  result = newSeqOfCap[byte](5 + n)
  result.add byte('M')
  putU32LE(result, uint32(n))
  for ch in meta.json: result.add byte(ch)

proc decodeMeta*(bytes: openArray[byte]): MetaPacket =
  if bytes.len < 5:
    raise newException(PacketProtocolError,
      "M packet truncated; need >= 5 bytes")
  if bytes[0] != byte('M'):
    raise newException(PacketProtocolError,
      "expected tag 'M' (0x4D), got 0x" & $bytes[0])
  let length = int(readU32LE(bytes, 1))
  if bytes.len - 5 != length:
    raise newException(PacketProtocolError,
      "M payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - 5))
  var s = newString(length)
  for i in 0 ..< length: s[i] = char(bytes[5 + i])
  result = MetaPacket(json: s)

proc encodeInput*(inp: InputPacket): seq[byte] =
  ## Encode an I packet: 'I' + u32 LE length + UTF-8 JSON.
  let n = inp.json.len
  result = newSeqOfCap[byte](5 + n)
  result.add byte('I')
  putU32LE(result, uint32(n))
  for ch in inp.json: result.add byte(ch)

proc decodeInput*(bytes: openArray[byte]): InputPacket =
  if bytes.len < 5:
    raise newException(PacketProtocolError,
      "I packet truncated; need >= 5 bytes")
  if bytes[0] != byte('I'):
    raise newException(PacketProtocolError,
      "expected tag 'I' (0x49), got 0x" & $bytes[0])
  let length = int(readU32LE(bytes, 1))
  if bytes.len - 5 != length:
    raise newException(PacketProtocolError,
      "I payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - 5))
  var s = newString(length)
  for i in 0 ..< length: s[i] = char(bytes[5 + i])
  result = InputPacket(json: s)

proc bytesToString*(bytes: openArray[byte]): string =
  ## Helper for handing byte buffers to the asyncnet `send`/`recv`
  ## APIs (which speak `string`).
  result = newString(bytes.len)
  for i in 0 ..< bytes.len: result[i] = char(bytes[i])

proc stringToBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc peekPacketKind*(bytes: openArray[byte]): PacketKind =
  ## Inspect a buffer's first byte and return the matching
  ## `PacketKind`, or raise `PacketProtocolError` for unknown tags.
  if bytes.len == 0:
    raise newException(PacketProtocolError, "empty packet")
  case char(bytes[0])
  of 'F': pkFrame
  of 'M': pkMeta
  of 'I': pkInput
  else:
    raise newException(PacketProtocolError,
      "unknown packet tag 0x" & $bytes[0])

# ---------------------------------------------------------------------------
# RS-M11: element-tree manifest sub-kind
# ---------------------------------------------------------------------------
##
## The element-tree M sub-kind announces the layout-bound, hit-testable
## element list for the current surface. The wire shape (with the
## containing M packet stripped) is:
##
##   {
##     "type": "element-tree",
##     "frameSeq": <u32>,
##     "surfaceWidth": <u32>,
##     "surfaceHeight": <u32>,
##     "elements": [
##       { "id": <string>,
##         "componentPath": <string>,
##         "kind": <string>,
##         "bounds": { "x": <u32>, "y": <u32>,
##                     "w": <u32>, "h": <u32> } },
##       ...
##     ]
##   }
##
## The JSON is wrapped in a standard M packet via `encodeMeta`; the
## helpers below produce / decode the body shape only.

type
  ElementBounds* = object
    ## Pixel-space bounding rectangle of a manifest entry. The
    ## launcher converts cell coordinates to surface pixels before
    ## emission so the editor never needs to know the renderer's
    ## native unit.
    x*, y*, w*, h*: int

  ElementEntry* = object
    ## One row in the element-tree manifest. `id` is launcher-stable
    ## (the editor uses it for selection identity); `componentPath`
    ## is the path the editor's selection signal should report; `kind`
    ## is a free-form launcher hint used for tie-breaking and
    ## diagnostics; `bounds` is the on-surface rectangle that the
    ## editor's `elementAt(x, y)` helper hit-tests.
    id*: string
    componentPath*: string
    kind*: string
    bounds*: ElementBounds

  ElementTreeManifest* = object
    ## Top-level container for one `element-tree` emission. Pairs
    ## with the F packet sequence number `frameSeq` so the editor can
    ## drop manifests that arrive late after a resize.
    ##
    ## ``boundsUnit`` records the coordinate unit each ``ElementEntry``
    ## bounds are expressed in: empty / "pixels" (default for the
    ## F/M/I transport) or "cells" (RS-M13 D/M/P TUI transport). The
    ## editor's overlay-positioning effect branches on this field so
    ## the hover label, selection outline, breadcrumb and edit-mode
    ## handles paint correctly over either the pixel canvas or the
    ## xterm.js terminal host.
    frameSeq*: int
    surfaceWidth*, surfaceHeight*: int
    boundsUnit*: string
    elements*: seq[ElementEntry]

proc encodeElementTreeJson*(m: ElementTreeManifest): string =
  ## Build the JSON body for an element-tree M packet using a
  ## hand-rolled stable serializer. We avoid `std/json` here so the
  ## byte layout is fully deterministic across compiler / Nim
  ## versions (object-key order, integer formatting, no whitespace) —
  ## the round-trip test pins this exact shape so future codec edits
  ## can't silently shift the wire bytes.
  proc escape(s: string): string =
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

  result = newStringOfCap(64 + 96 * m.elements.len)
  result.add "{\"type\":\"element-tree\""
  result.add ",\"frameSeq\":"
  result.add $m.frameSeq
  result.add ",\"surfaceWidth\":"
  result.add $m.surfaceWidth
  result.add ",\"surfaceHeight\":"
  result.add $m.surfaceHeight
  result.add ",\"elements\":["
  for i, e in m.elements:
    if i > 0: result.add ','
    result.add "{\"id\":"
    result.add escape(e.id)
    result.add ",\"componentPath\":"
    result.add escape(e.componentPath)
    result.add ",\"kind\":"
    result.add escape(e.kind)
    result.add ",\"bounds\":{\"x\":"
    result.add $e.bounds.x
    result.add ",\"y\":"
    result.add $e.bounds.y
    result.add ",\"w\":"
    result.add $e.bounds.w
    result.add ",\"h\":"
    result.add $e.bounds.h
    result.add "}}"
  result.add "]}"

proc encodeElementTreeMeta*(m: ElementTreeManifest): MetaPacket =
  ## Helper: wrap the manifest in a `MetaPacket` (the bridge's
  ## `sendBinary` consumes that directly). The byte-on-wire shape is
  ## the standard M packet plus the JSON body produced by
  ## `encodeElementTreeJson`.
  MetaPacket(json: encodeElementTreeJson(m))

proc decodeElementTreeJson*(body: string): ElementTreeManifest =
  ## Decode the JSON body of an element-tree M packet. Raises
  ## `PacketProtocolError` on shape violations (missing required
  ## fields, wrong `type`).
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError, ValueError:
    raise newException(PacketProtocolError,
      "element-tree body is not valid JSON")
  if node.kind != JObject:
    raise newException(PacketProtocolError,
      "element-tree body is not a JSON object")
  if not node.hasKey("type") or node["type"].kind != JString or
      node["type"].getStr != "element-tree":
    raise newException(PacketProtocolError,
      "element-tree body has wrong type")
  template intField(name: string): int =
    if not node.hasKey(name) or node[name].kind != JInt:
      raise newException(PacketProtocolError,
        "element-tree body missing int field: " & name)
    node[name].getInt
  result.frameSeq = intField("frameSeq")
  result.surfaceWidth = intField("surfaceWidth")
  result.surfaceHeight = intField("surfaceHeight")
  if not node.hasKey("elements") or node["elements"].kind != JArray:
    raise newException(PacketProtocolError,
      "element-tree body missing elements array")
  for raw in node["elements"]:
    if raw.kind != JObject:
      raise newException(PacketProtocolError,
        "element-tree entry is not an object")
    template strField(host: JsonNode; name: string): string =
      if not host.hasKey(name) or host[name].kind != JString:
        raise newException(PacketProtocolError,
          "element-tree entry missing string field: " & name)
      host[name].getStr
    var entry: ElementEntry
    entry.id = strField(raw, "id")
    entry.componentPath = strField(raw, "componentPath")
    entry.kind = strField(raw, "kind")
    if not raw.hasKey("bounds") or raw["bounds"].kind != JObject:
      raise newException(PacketProtocolError,
        "element-tree entry missing bounds object")
    let b = raw["bounds"]
    template intB(name: string): int =
      if not b.hasKey(name) or b[name].kind != JInt:
        raise newException(PacketProtocolError,
          "element-tree bounds missing int field: " & name)
      b[name].getInt
    entry.bounds = ElementBounds(
      x: intB("x"), y: intB("y"), w: intB("w"), h: intB("h"))
    result.elements.add entry

proc isElementTreeBody*(body: string): bool =
  ## Cheap probe for the dispatcher in the bridge / editor: returns
  ## true if the JSON body's `type` field is `"element-tree"`. Used
  ## by code paths that decode the M body once and route by sub-kind.
  # We avoid a full parse — a substring scan is sufficient for the
  # dispatcher hot path. Editor / test callers can defer to
  # `decodeElementTreeJson` for full validation.
  body.contains("\"type\":\"element-tree\"")

# ---------------------------------------------------------------------------
# RS-M13b: render-tree manifest sub-kind
# ---------------------------------------------------------------------------
##
## The render-tree M sub-kind carries a hierarchical presentation tree
## (tag, text, style map, children, componentPath, bounds) that the
## editor's DOM-rendering path turns into a `<div>` subtree under the
## render-tree host. Renderer-specific CSS (GPUI = macOS-native,
## Freya = Material) decorates the subtree. The element-tree manifest
## stays authoritative for hit-test bounds; render-tree's bounds is a
## presentation hint only.
##
## Wire shape (M packet body):
##
##   {
##     "type": "render-tree",
##     "frameSeq": <u32>,
##     "rendererId": "gpui" | "freya" | ...,
##     "root": <RenderTreeNode>
##   }
##
##   RenderTreeNode:
##     {
##       "id": <string>,
##       "tag": <string>,
##       "text": <string>,
##       "componentPath": <string>,
##       "style": { <key>: <value>, ... },
##       "bounds": { "x": <u32>, "y": <u32>,
##                   "w": <u32>, "h": <u32> },
##       "children": [ <RenderTreeNode>, ... ]
##     }
##
## Field order is locked so byte-equality round-trip tests can pin the
## wire shape. ``style`` keys are emitted in insertion order — the
## adapter owns that ordering by inserting keys via
## ``RenderTreeStyle.add(key, value)``.

type
  RenderTreeStyle* = object
    ## Ordered (key, value) pairs that map onto inline CSS on the
    ## materialised DOM node. We use a parallel-seq pair (rather than
    ## a `Table`) so iteration order is stable across encoders and the
    ## byte-equality test can pin a deterministic JSON key order.
    keys*: seq[string]
    values*: seq[string]

  RenderTreeNode* = object
    ## One node in the render-tree manifest. Mirrors the GPUI / Freya
    ## headless tree's `(tag, text, attributes)` triple plus a derived
    ## per-node `style` map populated by the tree adapter.
    id*: string
    tag*: string
    text*: string
    componentPath*: string
    style*: RenderTreeStyle
    bounds*: ElementBounds
    children*: seq[RenderTreeNode]

  RenderTreeManifest* = object
    ## Top-level container for one `render-tree` emission.
    ##
    ## ``rendererId`` carries the launcher's backend identifier (the
    ## same string the hello packet's ``backend`` field carries) so
    ## the editor's DOM-rendering path can pick the matching CSS
    ## bundle without consulting the parent VM.
    frameSeq*: int
    rendererId*: string
    root*: RenderTreeNode

proc add*(s: var RenderTreeStyle; key, value: string) =
  ## Append a (key, value) pair to the style map. Preserves insertion
  ## order — the encoder iterates the parallel seqs left-to-right.
  s.keys.add key
  s.values.add value

proc newRenderTreeStyle*(): RenderTreeStyle =
  RenderTreeStyle(keys: @[], values: @[])

proc renderTreeJsonEscape(s: string): string =
  ## RFC 8259 string-literal escaper for render-tree bodies. Same
  ## shape as ``encodeElementTreeJson``'s local helper.
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

proc encodeRenderTreeNodeBody(node: RenderTreeNode; buf: var string) =
  ## Serialise a single node into ``buf``. Field order locked to
  ## ``id, tag, text, componentPath, style, bounds, children``.
  buf.add "{\"id\":"
  buf.add renderTreeJsonEscape(node.id)
  buf.add ",\"tag\":"
  buf.add renderTreeJsonEscape(node.tag)
  buf.add ",\"text\":"
  buf.add renderTreeJsonEscape(node.text)
  buf.add ",\"componentPath\":"
  buf.add renderTreeJsonEscape(node.componentPath)
  buf.add ",\"style\":{"
  for i in 0 ..< node.style.keys.len:
    if i > 0: buf.add ','
    buf.add renderTreeJsonEscape(node.style.keys[i])
    buf.add ':'
    buf.add renderTreeJsonEscape(node.style.values[i])
  buf.add "},\"bounds\":{\"x\":"
  buf.add $node.bounds.x
  buf.add ",\"y\":"
  buf.add $node.bounds.y
  buf.add ",\"w\":"
  buf.add $node.bounds.w
  buf.add ",\"h\":"
  buf.add $node.bounds.h
  buf.add "},\"children\":["
  for i, c in node.children:
    if i > 0: buf.add ','
    encodeRenderTreeNodeBody(c, buf)
  buf.add "]}"

proc encodeRenderTreeBody*(m: RenderTreeManifest): string =
  ## Encode the M-packet body for a render-tree manifest. Hand-rolled
  ## emitter — deterministic key order, no whitespace — so the
  ## round-trip test can byte-equality-check the wire shape against a
  ## hand-rolled reference.
  result = newStringOfCap(96)
  result.add "{\"type\":\"render-tree\""
  result.add ",\"frameSeq\":"
  result.add $m.frameSeq
  result.add ",\"rendererId\":"
  result.add renderTreeJsonEscape(m.rendererId)
  result.add ",\"root\":"
  encodeRenderTreeNodeBody(m.root, result)
  result.add "}"

proc encodeRenderTreeMeta*(m: RenderTreeManifest): MetaPacket =
  ## Helper: wrap the manifest in a `MetaPacket` so the bridge's
  ## ``sendBinary`` path can consume it directly.
  MetaPacket(json: encodeRenderTreeBody(m))

proc decodeRenderTreeNode(node: JsonNode): RenderTreeNode =
  if node.kind != JObject:
    raise newException(PacketProtocolError,
      "render-tree node is not a JSON object")
  template strField(host: JsonNode; name: string): string =
    if not host.hasKey(name) or host[name].kind != JString:
      raise newException(PacketProtocolError,
        "render-tree node missing string field: " & name)
    host[name].getStr
  result.id = strField(node, "id")
  result.tag = strField(node, "tag")
  result.text = strField(node, "text")
  result.componentPath = strField(node, "componentPath")
  if not node.hasKey("style") or node["style"].kind != JObject:
    raise newException(PacketProtocolError,
      "render-tree node missing style object")
  result.style = newRenderTreeStyle()
  let styleNode = node["style"]
  for k in styleNode.keys:
    let v = styleNode[k]
    if v.kind != JString:
      raise newException(PacketProtocolError,
        "render-tree style value for '" & k & "' is not a string")
    result.style.add(k, v.getStr)
  if not node.hasKey("bounds") or node["bounds"].kind != JObject:
    raise newException(PacketProtocolError,
      "render-tree node missing bounds object")
  let b = node["bounds"]
  template intB(name: string): int =
    if not b.hasKey(name) or b[name].kind != JInt:
      raise newException(PacketProtocolError,
        "render-tree bounds missing int field: " & name)
    b[name].getInt
  result.bounds = ElementBounds(
    x: intB("x"), y: intB("y"), w: intB("w"), h: intB("h"))
  if not node.hasKey("children") or node["children"].kind != JArray:
    raise newException(PacketProtocolError,
      "render-tree node missing children array")
  result.children = @[]
  for raw in node["children"]:
    result.children.add decodeRenderTreeNode(raw)

proc decodeRenderTreeBody*(body: string): RenderTreeManifest =
  ## Decode the JSON body of a render-tree M packet. Raises
  ## `PacketProtocolError` on shape violations.
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError, ValueError:
    raise newException(PacketProtocolError,
      "render-tree body is not valid JSON")
  if node.kind != JObject:
    raise newException(PacketProtocolError,
      "render-tree body is not a JSON object")
  if not node.hasKey("type") or node["type"].kind != JString or
      node["type"].getStr != "render-tree":
    raise newException(PacketProtocolError,
      "render-tree body has wrong type")
  if not node.hasKey("frameSeq") or node["frameSeq"].kind != JInt:
    raise newException(PacketProtocolError,
      "render-tree body missing frameSeq")
  if not node.hasKey("rendererId") or node["rendererId"].kind != JString:
    raise newException(PacketProtocolError,
      "render-tree body missing rendererId")
  if not node.hasKey("root") or node["root"].kind != JObject:
    raise newException(PacketProtocolError,
      "render-tree body missing root object")
  result.frameSeq = node["frameSeq"].getInt
  result.rendererId = node["rendererId"].getStr
  result.root = decodeRenderTreeNode(node["root"])

proc isRenderTreeBody*(body: string): bool =
  ## Cheap probe used by the bridge / editor dispatcher to route M
  ## packets by sub-kind without a full parse.
  body.contains("\"type\":\"render-tree\"")
