## test_packet_render_tree_roundtrip — RS-M13b.
##
## Locks the byte layout of the `render-tree` M sub-kind so future
## codec edits can't silently shift the wire shape. The test:
##
##   * Builds a representative `RenderTreeManifest` exercising the
##     nested style / children / componentPath / bounds payload.
##   * Encodes via `encodeRenderTreeBody` and asserts the bytes
##     match a hand-rolled reference encoding (byte equality).
##   * Decodes the body and confirms `decodeRenderTreeBody` recovers
##     the identical manifest (deep equality).
##   * Re-encodes the decoded manifest and asserts byte-identical
##     output.
##   * Asserts the dispatcher probe `isRenderTreeBody` returns true
##     for the produced body and false for other M sub-kinds.

import std/[json, unittest]

import isonim_render_serve

proc styleOf(pairs: openArray[(string, string)]): RenderTreeStyle =
  result = newRenderTreeStyle()
  for (k, v) in pairs:
    result.add(k, v)

suite "RS-M13b: render-tree codec":

  test "JSON body matches hand-rolled reference (byte-identical)":
    let manifest = RenderTreeManifest(
      frameSeq: 7,
      rendererId: "gpui",
      root: RenderTreeNode(
        id: "task_app",
        tag: "div",
        text: "",
        componentPath: "task_app",
        style: styleOf({
          "background-color": "#0a0a0a",
          "font-family": "-apple-system",
        }),
        bounds: ElementBounds(x: 0, y: 0, w: 800, h: 600),
        children: @[
          RenderTreeNode(
            id: "task_app/views/TaskRow#0",
            tag: "div",
            text: "Pick up groceries",
            componentPath: "task_app/views/TaskRow#0",
            style: styleOf({"color": "#e2e8f0"}),
            bounds: ElementBounds(x: 0, y: 36, w: 800, h: 28),
            children: @[]),
        ]))
    let actual = encodeRenderTreeBody(manifest)
    const expected =
      "{\"type\":\"render-tree\"" &
      ",\"frameSeq\":7" &
      ",\"rendererId\":\"gpui\"" &
      ",\"root\":{" &
      "\"id\":\"task_app\"" &
      ",\"tag\":\"div\"" &
      ",\"text\":\"\"" &
      ",\"componentPath\":\"task_app\"" &
      ",\"style\":{\"background-color\":\"#0a0a0a\"" &
      ",\"font-family\":\"-apple-system\"}" &
      ",\"bounds\":{\"x\":0,\"y\":0,\"w\":800,\"h\":600}" &
      ",\"children\":[" &
      "{\"id\":\"task_app/views/TaskRow#0\"" &
      ",\"tag\":\"div\"" &
      ",\"text\":\"Pick up groceries\"" &
      ",\"componentPath\":\"task_app/views/TaskRow#0\"" &
      ",\"style\":{\"color\":\"#e2e8f0\"}" &
      ",\"bounds\":{\"x\":0,\"y\":36,\"w\":800,\"h\":28}" &
      ",\"children\":[]}]}}"
    check actual == expected

  test "isRenderTreeBody probe":
    let manifest = RenderTreeManifest(
      frameSeq: 0, rendererId: "gpui",
      root: RenderTreeNode(id: "x", tag: "div", text: "",
                           componentPath: "", style: newRenderTreeStyle(),
                           bounds: ElementBounds(),
                           children: @[]))
    let body = encodeRenderTreeBody(manifest)
    check isRenderTreeBody(body) == true
    check isRenderTreeBody("{\"type\":\"hello\"}") == false
    check isElementTreeBody(body) == false

  test "empty tree round-trips byte-identically":
    let manifest = RenderTreeManifest(
      frameSeq: 0, rendererId: "freya",
      root: RenderTreeNode(id: "root", tag: "div", text: "",
                           componentPath: "root",
                           style: newRenderTreeStyle(),
                           bounds: ElementBounds(x: 0, y: 0, w: 1, h: 1),
                           children: @[]))
    let enc1 = encodeRenderTreeBody(manifest)
    let dec = decodeRenderTreeBody(enc1)
    let enc2 = encodeRenderTreeBody(dec)
    check enc1 == enc2

  test "deeply nested tree round-trips":
    proc make(depth: int): RenderTreeNode =
      result = RenderTreeNode(
        id: "n" & $depth,
        tag: "div",
        text: "",
        componentPath: "x/N#" & $depth,
        style: styleOf({"data-depth": $depth}),
        bounds: ElementBounds(x: depth, y: depth, w: 100, h: 20),
        children: @[])
      if depth < 5:
        result.children.add make(depth + 1)
    let manifest = RenderTreeManifest(
      frameSeq: 1, rendererId: "gpui", root: make(0))
    let enc1 = encodeRenderTreeBody(manifest)
    let dec = decodeRenderTreeBody(enc1)
    let enc2 = encodeRenderTreeBody(dec)
    check enc1 == enc2
    # Depth chain preserved
    var n = dec.root
    var d = 0
    while n.children.len > 0:
      check n.id == "n" & $d
      n = n.children[0]
      inc d
    check d == 5

  test "decoder rejects body with wrong type":
    expect PacketProtocolError:
      discard decodeRenderTreeBody("{\"type\":\"element-tree\",\"x\":1}")

  test "decoder rejects body missing root":
    expect PacketProtocolError:
      discard decodeRenderTreeBody(
        "{\"type\":\"render-tree\",\"frameSeq\":1,\"rendererId\":\"gpui\"}")

  test "decoder rejects non-string style values":
    let bad =
      "{\"type\":\"render-tree\",\"frameSeq\":0,\"rendererId\":\"gpui\"," &
      "\"root\":{\"id\":\"r\",\"tag\":\"div\",\"text\":\"\"," &
      "\"componentPath\":\"r\",\"style\":{\"k\":42}," &
      "\"bounds\":{\"x\":0,\"y\":0,\"w\":1,\"h\":1}," &
      "\"children\":[]}}"
    expect PacketProtocolError:
      discard decodeRenderTreeBody(bad)

  test "escapes preserve special characters":
    let manifest = RenderTreeManifest(
      frameSeq: 9, rendererId: "gpui",
      root: RenderTreeNode(
        id: "r", tag: "div", text: "a\"b\\c\nd",
        componentPath: "r",
        style: styleOf({"content": "\"q\""}),
        bounds: ElementBounds(), children: @[]))
    let enc = encodeRenderTreeBody(manifest)
    let dec = decodeRenderTreeBody(enc)
    check dec.root.text == "a\"b\\c\nd"
    check dec.root.style.values[0] == "\"q\""

  test "style key order survives round-trip":
    let s = styleOf({
      "padding": "8px",
      "color": "#fff",
      "background-color": "#222",
      "font-family": "system-ui",
      "border-radius": "12px",
    })
    let manifest = RenderTreeManifest(
      frameSeq: 0, rendererId: "freya",
      root: RenderTreeNode(id: "r", tag: "div", text: "",
                           componentPath: "r", style: s,
                           bounds: ElementBounds(), children: @[]))
    let enc1 = encodeRenderTreeBody(manifest)
    let dec = decodeRenderTreeBody(enc1)
    check dec.root.style.keys == s.keys
    check dec.root.style.values == s.values
    check encodeRenderTreeBody(dec) == enc1

  test "meta wrap encodes byte-identical to encodeRenderTreeBody":
    let manifest = RenderTreeManifest(
      frameSeq: 3, rendererId: "freya",
      root: RenderTreeNode(id: "r", tag: "div", text: "hi",
                           componentPath: "r",
                           style: styleOf({"k": "v"}),
                           bounds: ElementBounds(x: 1, y: 2, w: 3, h: 4),
                           children: @[]))
    let body = encodeRenderTreeBody(manifest)
    let meta = encodeRenderTreeMeta(manifest)
    check meta.json == body
    let bytes = encodeMeta(meta)
    let decoded = decodeMeta(bytes)
    check decoded.json == body
    check isRenderTreeBody(decoded.json)

  test "JSON parses cleanly":
    let manifest = RenderTreeManifest(
      frameSeq: 42, rendererId: "gpui",
      root: RenderTreeNode(id: "r", tag: "div", text: "x",
                           componentPath: "p",
                           style: styleOf({"a": "1"}),
                           bounds: ElementBounds(x: 0, y: 0, w: 10, h: 10),
                           children: @[]))
    let body = encodeRenderTreeBody(manifest)
    let node = parseJson(body)
    check node["type"].getStr == "render-tree"
    check node["frameSeq"].getInt == 42
    check node["rendererId"].getStr == "gpui"
    check node["root"]["id"].getStr == "r"
    check node["root"]["style"]["a"].getStr == "1"
    check node["root"]["bounds"]["w"].getInt == 10
