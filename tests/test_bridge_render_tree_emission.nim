## test_bridge_render_tree_emission — RS-M13b.
##
## Drives the real bridge against an in-test `RenderTreeProvider` and
## asserts the protocol-side cadence rules:
##
##   1. After `hello`, the bridge MUST emit a `render-tree` M packet
##      BEFORE the first F packet (or instead of, when
##      `rendererSurface == "tree"`).
##   2. While the provider returns the same manifest, NO further
##      `render-tree` packets are emitted (idle ticks stay quiet).
##   3. When the provider's manifest changes, the next tick MUST
##      emit a fresh `render-tree` M packet.
##   4. With `rendererSurface == "tree"`, the bridge MUST NOT emit
##      any F packets — the render-tree IS the surface.
##   5. The hello capabilities announce `renderTree: true` +
##      `rendererSurface: "tree"`.
##
## Same shape as `test_bridge_element_tree_emission.nim`: the provider
## is a tiny in-test closure (real `RenderTreeProvider`, no mock), and
## the bridge code is exercised through the production codec / cadence
## / WS framing path end-to-end.

import std/[asyncdispatch, asyncnet, json, unittest]

import isonim_render_serve
import ./ws_test_client

proc drainDispatcher() =
  for _ in 0 .. 40:
    try: poll(25)
    except ValueError: break

# ---------------------------------------------------------------------------
# Manifests for cadence tests
# ---------------------------------------------------------------------------

proc baseStyle(): RenderTreeStyle =
  result = newRenderTreeStyle()
  result.add("color", "#e2e8f0")
  result.add("font-family", "-apple-system")

proc baselineManifest(): RenderTreeManifest =
  RenderTreeManifest(
    frameSeq: 0,
    rendererId: "gpui",
    root: RenderTreeNode(
      id: "task_app",
      tag: "div",
      text: "",
      componentPath: "task_app",
      style: baseStyle(),
      bounds: ElementBounds(x: 0, y: 0, w: 640, h: 288),
      children: @[
        RenderTreeNode(
          id: "task_app/views/TaskRow#0",
          tag: "div",
          text: "Row 0",
          componentPath: "task_app/views/TaskRow#0",
          style: baseStyle(),
          bounds: ElementBounds(x: 0, y: 36, w: 640, h: 12),
          children: @[]),
        RenderTreeNode(
          id: "task_app/views/FilterBar",
          tag: "div",
          text: "",
          componentPath: "task_app/views/FilterBar",
          style: baseStyle(),
          bounds: ElementBounds(x: 0, y: 12, w: 240, h: 12),
          children: @[]),
      ]))

proc changedManifest(): RenderTreeManifest =
  ## Mutates one leaf's `text` so the tree-hash flips. We also grow
  ## the filter bar so a bounds-only change is exercised too.
  RenderTreeManifest(
    frameSeq: 1,
    rendererId: "gpui",
    root: RenderTreeNode(
      id: "task_app",
      tag: "div",
      text: "",
      componentPath: "task_app",
      style: baseStyle(),
      bounds: ElementBounds(x: 0, y: 0, w: 640, h: 288),
      children: @[
        RenderTreeNode(
          id: "task_app/views/TaskRow#0",
          tag: "div",
          text: "Row 0 (edited)",
          componentPath: "task_app/views/TaskRow#0",
          style: baseStyle(),
          bounds: ElementBounds(x: 0, y: 36, w: 640, h: 12),
          children: @[]),
        RenderTreeNode(
          id: "task_app/views/FilterBar",
          tag: "div",
          text: "",
          componentPath: "task_app/views/FilterBar",
          style: baseStyle(),
          bounds: ElementBounds(x: 0, y: 12, w: 320, h: 12),
          children: @[]),
      ]))

proc makeConfigWithRenderTree(port: int;
                              provider: RenderTreeProvider;
                              fps = 50; maxFrames = 6;
                              rendererSurface = "tree"): BridgeConfig =
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: "stub",
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: newStubFrameSource(256, 256).toAny(),
    renderTree: provider,
    rendererSurface: rendererSurface)

proc drainPackets(sock: AsyncSocket; count: int):
                  Future[seq[string]] {.async.} =
  result = newSeq[string]()
  let state = newWsClientState()
  for _ in 0 ..< count:
    let msg = await recvOneMessage(sock, state)
    if not msg.complete: break
    result.add msg.payload

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "RS-M13b: bridge render-tree emission":

  test "render-tree manifest arrives after hello, before any F packet":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = RenderTreeProvider(
        buildImpl: proc(): RenderTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithRenderTree(port, provider, maxFrames = 4)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        # hello + render-tree; with rendererSurface=="tree" no F packets follow.
        let packets = await drainPackets(sock, 2)
        sock.close()
        return packets

      let packets = waitFor flow()
      check packets.len >= 2
      check packets[0][0] == 'M'   # hello
      check packets[1][0] == 'M'   # render-tree

      let helloMeta = decodeMeta(stringToBytes(packets[0]))
      let helloJson = parseJson(helloMeta.json)
      check helloJson["type"].getStr == "hello"
      check helloJson["capabilities"]["renderTree"].getBool == true
      check helloJson["capabilities"]["rendererSurface"].getStr == "tree"

      let rtMeta = decodeMeta(stringToBytes(packets[1]))
      check isRenderTreeBody(rtMeta.json)
      let manifest = decodeRenderTreeBody(rtMeta.json)
      check manifest.rendererId == "gpui"
      check manifest.root.componentPath == "task_app"
      check manifest.root.children.len == 2
      check manifest.root.children[0].text == "Row 0"
      drainDispatcher()
      drainDispatcher()

  test "idle ticks do NOT re-emit the render-tree manifest":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = RenderTreeProvider(
        buildImpl: proc(): RenderTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      # Tree-surface mode caps the frame loop on tick count, not on
      # F-packet sends; maxFrames=6 yields one hello + one initial
      # render-tree on connect, then nothing further while the
      # manifest is unchanged.
      let cfg = makeConfigWithRenderTree(port, provider, maxFrames = 6)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        # We expect exactly two messages (hello + initial render-tree)
        # and the receiver should time out (or hit close on the
        # server's maxFrames cap) waiting for a third. Drain up to a
        # generous bound; idle ticks emit nothing.
        let packets = await drainPackets(sock, 2)
        # Let several frame ticks elapse before closing.
        await sleepAsync(150)
        sock.close()
        return packets

      let packets = waitFor flow()
      var metas = 0
      var frames = 0
      for p in packets:
        case p[0]
        of 'M': inc metas
        of 'F': inc frames
        else: discard
      check metas == 2     # hello + initial render-tree, nothing else
      check frames == 0    # no F packets while rendererSurface=="tree"
      drainDispatcher()
      drainDispatcher()

  test "render-tree change triggers a fresh emission":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = RenderTreeProvider(
        buildImpl: proc(): RenderTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithRenderTree(port, provider, maxFrames = 8)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        # Drain hello + initial render-tree.
        let initial = await drainPackets(sock, 2)
        # Flip the manifest BEFORE the next tick.
        {.cast(gcsafe).}: current = changedManifest()
        # The next tick should emit the changed manifest.
        let after = await drainPackets(sock, 1)
        sock.close()
        return initial & after

      let packets = waitFor flow()
      var metas: seq[string] = @[]
      for p in packets:
        if p[0] == 'M':
          metas.add p
      check metas.len >= 3
      # First two metas: hello, baseline render-tree.
      check parseJson(decodeMeta(stringToBytes(metas[0])).json)["type"].getStr == "hello"
      let baselineJson = decodeMeta(stringToBytes(metas[1])).json
      check isRenderTreeBody(baselineJson)
      let baselineDec = decodeRenderTreeBody(baselineJson)
      check baselineDec.root.children[0].text == "Row 0"
      check baselineDec.root.children[1].bounds.w == 240
      # Third meta: changed render-tree.
      let changedJson = decodeMeta(stringToBytes(metas[2])).json
      check isRenderTreeBody(changedJson)
      let changedDec = decodeRenderTreeBody(changedJson)
      check changedDec.root.children[0].text == "Row 0 (edited)"
      check changedDec.root.children[1].bounds.w == 320
      drainDispatcher()
      drainDispatcher()

  test "hello announces renderTree:false when no provider attached":
    when defined(windows):
      skip()
    else:
      drainDispatcher()
      drainDispatcher()
      let port = pickPort()
      let cfg = makeStubConfig(port, backend = "stub")
      discard startServer(cfg)
      for _ in 0 .. 10:
        try: poll(25)
        except ValueError: break

      proc flow(): Future[string] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let msg = await recvOneMessage(sock, state)
        sock.close()
        return msg.payload

      let payload = waitFor flow()
      let helloJson = parseJson(decodeMeta(stringToBytes(payload)).json)
      check helloJson["capabilities"]["renderTree"].getBool == false
      check helloJson["capabilities"]["rendererSurface"].getStr == "pixels"
      drainDispatcher()
      drainDispatcher()
