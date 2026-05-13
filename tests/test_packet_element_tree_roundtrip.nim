## test_packet_element_tree_roundtrip — RS-M11.
##
## Locks the byte layout of the `element-tree` M sub-kind so future
## codec edits can't silently shift the wire shape. The test:
##
##   * Builds a representative `ElementTreeManifest` with one entry
##     per task row + a filter-bar entry + a summary entry (the
##     EX-M23 acceptance baseline).
##   * Encodes via `encodeElementTreeJson` and asserts the bytes
##     match a hand-rolled reference encoding.
##   * Wraps the JSON in an M packet, encodes the M packet, decodes
##     it back, and confirms `decodeElementTreeJson` recovers the
##     identical manifest (deep equality).
##   * Re-encodes the decoded manifest and asserts byte-identical
##     output.
##   * Asserts the dispatcher probe `isElementTreeBody` returns true
##     for the produced body and false for other M sub-kinds.

import std/[json, unittest]

import isonim_render_serve

suite "RS-M11: element-tree codec":

  test "JSON body matches hand-rolled reference (byte-identical)":
    let manifest = ElementTreeManifest(
      frameSeq: 142,
      surfaceWidth: 640,
      surfaceHeight: 288,
      elements: @[
        ElementEntry(id: "task_app/views/TaskRow#0",
                     componentPath: "task_app/views/TaskRow#0",
                     kind: "row",
                     bounds: ElementBounds(x: 0, y: 36, w: 640, h: 12)),
        ElementEntry(id: "task_app/views/FilterBar",
                     componentPath: "task_app/views/FilterBar",
                     kind: "filter-bar",
                     bounds: ElementBounds(x: 0, y: 12, w: 240, h: 12)),
      ])
    let actual = encodeElementTreeJson(manifest)
    const expected =
      "{\"type\":\"element-tree\"" &
      ",\"frameSeq\":142" &
      ",\"surfaceWidth\":640" &
      ",\"surfaceHeight\":288" &
      ",\"elements\":[" &
      "{\"id\":\"task_app/views/TaskRow#0\"" &
      ",\"componentPath\":\"task_app/views/TaskRow#0\"" &
      ",\"kind\":\"row\"" &
      ",\"bounds\":{\"x\":0,\"y\":36,\"w\":640,\"h\":12}}" &
      "," &
      "{\"id\":\"task_app/views/FilterBar\"" &
      ",\"componentPath\":\"task_app/views/FilterBar\"" &
      ",\"kind\":\"filter-bar\"" &
      ",\"bounds\":{\"x\":0,\"y\":12,\"w\":240,\"h\":12}}" &
      "]}"
    check actual == expected

  test "JSON body parses as a valid JSON object with the expected fields":
    let manifest = ElementTreeManifest(
      frameSeq: 1, surfaceWidth: 100, surfaceHeight: 100,
      elements: @[
        ElementEntry(id: "a", componentPath: "x/A", kind: "row",
                     bounds: ElementBounds(x: 0, y: 0, w: 10, h: 10))])
    let body = encodeElementTreeJson(manifest)
    let node = parseJson(body)
    check node["type"].getStr == "element-tree"
    check node["frameSeq"].getInt == 1
    check node["surfaceWidth"].getInt == 100
    check node["surfaceHeight"].getInt == 100
    check node["elements"].kind == JArray
    check node["elements"].len == 1
    check node["elements"][0]["id"].getStr == "a"
    check node["elements"][0]["componentPath"].getStr == "x/A"
    check node["elements"][0]["bounds"]["w"].getInt == 10

  test "decode → re-encode round-trip is byte-identical":
    let manifest = ElementTreeManifest(
      frameSeq: 42, surfaceWidth: 320, surfaceHeight: 240,
      elements: @[
        ElementEntry(id: "row-0", componentPath: "x/Row#0", kind: "row",
                     bounds: ElementBounds(x: 0, y: 0, w: 320, h: 12)),
        ElementEntry(id: "row-1", componentPath: "x/Row#1", kind: "row",
                     bounds: ElementBounds(x: 0, y: 12, w: 320, h: 12)),
        ElementEntry(id: "summary", componentPath: "x/Summary",
                     kind: "summary",
                     bounds: ElementBounds(x: 0, y: 200, w: 320, h: 12))])
    let enc1 = encodeElementTreeJson(manifest)
    let dec = decodeElementTreeJson(enc1)
    check dec.frameSeq == manifest.frameSeq
    check dec.surfaceWidth == manifest.surfaceWidth
    check dec.surfaceHeight == manifest.surfaceHeight
    check dec.elements.len == manifest.elements.len
    for i in 0 ..< dec.elements.len:
      check dec.elements[i].id == manifest.elements[i].id
      check dec.elements[i].componentPath ==
        manifest.elements[i].componentPath
      check dec.elements[i].kind == manifest.elements[i].kind
      check dec.elements[i].bounds.x == manifest.elements[i].bounds.x
      check dec.elements[i].bounds.y == manifest.elements[i].bounds.y
      check dec.elements[i].bounds.w == manifest.elements[i].bounds.w
      check dec.elements[i].bounds.h == manifest.elements[i].bounds.h
    let enc2 = encodeElementTreeJson(dec)
    check enc1 == enc2

  test "wrapping in an M packet round-trips through encodeMeta / decodeMeta":
    let manifest = ElementTreeManifest(
      frameSeq: 7, surfaceWidth: 80, surfaceHeight: 24,
      elements: @[
        ElementEntry(id: "e", componentPath: "x/E", kind: "k",
                     bounds: ElementBounds(x: 1, y: 2, w: 3, h: 4))])
    let meta = encodeElementTreeMeta(manifest)
    let bytes = encodeMeta(meta)
    check bytes[0] == byte('M')
    let dec = decodeMeta(bytes)
    check dec.json == meta.json
    let decoded = decodeElementTreeJson(dec.json)
    check decoded.elements.len == 1
    check decoded.elements[0].componentPath == "x/E"

  test "isElementTreeBody discriminates from other sub-kinds":
    let manifest = ElementTreeManifest(frameSeq: 0,
      surfaceWidth: 0, surfaceHeight: 0, elements: @[])
    check isElementTreeBody(encodeElementTreeJson(manifest))
    check not isElementTreeBody("{\"type\":\"hello\",\"protocolVersion\":1}")
    check not isElementTreeBody("{\"type\":\"resize\",\"width\":640}")

  test "decodeElementTreeJson rejects wrong type":
    expect PacketProtocolError:
      discard decodeElementTreeJson("{\"type\":\"hello\"}")

  test "decodeElementTreeJson rejects missing required fields":
    expect PacketProtocolError:
      discard decodeElementTreeJson("{\"type\":\"element-tree\"}")
    expect PacketProtocolError:
      discard decodeElementTreeJson(
        "{\"type\":\"element-tree\",\"frameSeq\":1,\"surfaceWidth\":1," &
        "\"surfaceHeight\":1}")  # no elements
    expect PacketProtocolError:
      discard decodeElementTreeJson(
        "{\"type\":\"element-tree\",\"frameSeq\":1,\"surfaceWidth\":1," &
        "\"surfaceHeight\":1,\"elements\":[{\"id\":\"a\"}]}")  # incomplete entry

  test "decodeElementTreeJson rejects malformed JSON":
    expect PacketProtocolError:
      discard decodeElementTreeJson("{not json")

  test "hello packet exposes the elementTree capability":
    let withFlag = buildHelloJson("tui", 640, 288, elementTree = true)
    let withoutFlag = buildHelloJson("stub", 256, 256)
    let withNode = parseJson(withFlag)
    let withoutNode = parseJson(withoutFlag)
    check withNode["capabilities"]["elementTree"].getBool == true
    check withoutNode["capabilities"]["elementTree"].getBool == false

  test "JSON body escapes quotes / backslashes / control characters":
    let manifest = ElementTreeManifest(
      frameSeq: 0, surfaceWidth: 1, surfaceHeight: 1,
      elements: @[
        ElementEntry(id: "with\"quote\\and\nnewline",
                     componentPath: "weird\tpath",
                     kind: "ok",
                     bounds: ElementBounds(x: 0, y: 0, w: 1, h: 1))])
    let body = encodeElementTreeJson(manifest)
    # Must parse back via the standard JSON parser without errors.
    let node = parseJson(body)
    check node["elements"][0]["id"].getStr == "with\"quote\\and\nnewline"
    check node["elements"][0]["componentPath"].getStr == "weird\tpath"
