## test_bridge_element_tree_emission — RS-M11.
##
## Drives the real bridge against an in-test `ElementTreeProvider`
## and asserts the protocol-side cadence rules:
##
##   1. After `hello`, the bridge MUST emit an `element-tree` M
##      packet BEFORE the first F packet.
##   2. While the provider returns the same manifest, NO further
##      `element-tree` packets are emitted (idle frames stay quiet).
##   3. When the provider's manifest changes, the next tick MUST
##      emit a fresh `element-tree` M packet.
##
## The provider is a tiny in-test closure — not a mock of the
## producer surface, but a real `ElementTreeProvider` configured
## with a `Signal[ElementTreeManifest]`-style mutable cell. The
## bridge code is exercised exactly as production launchers exercise
## it (the launcher just captures a `harness` closure here; the
## codec path, cadence path, and WS framing are real).

import std/[asyncdispatch, asyncnet, json, unittest]

import isonim_render_serve
import ./ws_test_client

proc drainDispatcher() =
  ## Pump the async dispatcher long enough for any prior test's
  ## frame loop to exhaust its `maxFrames` budget and close the
  ## connection. Without this, tests that pickPort() right after
  ## a previous test sometimes race against the kernel's TIME_WAIT
  ## reuse and reconnect to the previous test's server.
  for _ in 0 .. 40:
    try: poll(25)
    except ValueError: break

# ---------------------------------------------------------------------------
# Manifests used by the cadence tests
# ---------------------------------------------------------------------------

proc baselineManifest(): ElementTreeManifest =
  ElementTreeManifest(
    frameSeq: 0,
    surfaceWidth: 640, surfaceHeight: 288,
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 36, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/FilterBar",
                   componentPath: "task_app/views/FilterBar",
                   kind: "filter-bar",
                   bounds: ElementBounds(x: 0, y: 12, w: 240, h: 12))])

proc changedManifest(): ElementTreeManifest =
  ## Adds a new row + grows the filter bar so the (id, bounds) set
  ## differs from `baselineManifest`. Both delta kinds (new id +
  ## changed bounds) trigger re-emission per the RS-M11 cadence rule.
  ElementTreeManifest(
    frameSeq: 1,
    surfaceWidth: 640, surfaceHeight: 288,
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 36, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 48, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/FilterBar",
                   componentPath: "task_app/views/FilterBar",
                   kind: "filter-bar",
                   bounds: ElementBounds(x: 0, y: 12, w: 320, h: 12))])

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeConfigWithProvider(port: int;
                            provider: ElementTreeProvider;
                            fps = 8; maxFrames = 6): BridgeConfig =
  ## Mirror of `makeStubConfig` that plugs in an element-tree
  ## provider so the bridge runs through the manifest-emission code
  ## path. Stub frame source keeps the F packets cheap. `fps` defaults
  ## low (≈125 ms/frame) so the server's frame loop does not race ahead
  ## and buffer every frame before the client drains the initial packets
  ## and flips the provider's manifest between ticks. The re-emission the
  ## "manifest change triggers a fresh element-tree packet" test pins
  ## fires from inside `sendElementTreeIfChanged`; at 50 fps the whole
  ## `maxFrames` budget was rendered before the flip landed, so the
  ## changed manifest never appeared and the test raced.
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: "stub",
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: newStubFrameSource(256, 256).toAny(),
    elementTree: provider)

proc drainPackets(sock: AsyncSocket; count: int):
                  Future[seq[string]] {.async.} =
  ## Pull `count` complete WS binary messages from the socket and
  ## return their payloads (each is a single F / M / I packet).
  result = newSeq[string]()
  # Persistent per-socket decoder: repeated drains on the same socket
  # must share one `WsFrameDecoder` so surplus recv bytes are not lost
  # at a drain boundary (see `clientStateFor` in ws_test_client).
  let state = clientStateFor(sock)
  for _ in 0 ..< count:
    let msg = await recvOneMessage(sock, state)
    if not msg.complete: break
    result.add msg.payload

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "RS-M11: bridge element-tree emission":

  test "manifest arrives after hello and before the first F packet":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider, maxFrames = 3)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        # Pull at least 3 messages: hello (M), element-tree (M),
        # first F frame. The bridge's `maxFrames=3` cap stops the
        # frame loop afterwards.
        let packets = await drainPackets(sock, 3)
        sock.close()
        return packets

      let packets = waitFor flow()
      check packets.len >= 3
      # Tag classes: M, M, F.
      check packets[0][0] == 'M'
      check packets[1][0] == 'M'
      check packets[2][0] == 'F'

      # First M MUST be `hello`; second M MUST be `element-tree`.
      let helloMeta = decodeMeta(stringToBytes(packets[0]))
      let helloJson = parseJson(helloMeta.json)
      check helloJson["type"].getStr == "hello"
      check helloJson["capabilities"]["elementTree"].getBool == true

      let manifestMeta = decodeMeta(stringToBytes(packets[1]))
      check isElementTreeBody(manifestMeta.json)
      let manifest = decodeElementTreeJson(manifestMeta.json)
      check manifest.surfaceWidth == 640
      check manifest.surfaceHeight == 288
      check manifest.elements.len == 2
      check manifest.elements[0].componentPath == "task_app/views/TaskRow#0"
      check manifest.elements[1].kind == "filter-bar"
      drainDispatcher()
      drainDispatcher()

  test "idle frames do NOT re-emit the manifest":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      # Burn through several frames without changing the manifest.
      let cfg = makeConfigWithProvider(port, provider, maxFrames = 6)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        let packets = await drainPackets(sock, 1 + 1 + 6) # hello+manifest+6 frames
        sock.close()
        return packets

      let packets = waitFor flow()
      check packets.len >= 8
      # Tag map: M, M, then six F's. The two M packets are
      # `hello` and the first `element-tree`; no further M packets
      # may appear while the manifest is unchanged.
      var meta = 0
      var frames = 0
      for p in packets[0 ..< packets.len]:
        case p[0]
        of 'M': inc meta
        of 'F': inc frames
        else: discard
      check meta == 2     # hello + first element-tree, nothing else
      check frames >= 6
      drainDispatcher()
      drainDispatcher()

  test "manifest change triggers a fresh element-tree packet":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider, maxFrames = 6)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        # Pull hello + first manifest + first frame: 3 packets.
        let initial = await drainPackets(sock, 3)
        # Flip the manifest BEFORE the next frame tick.
        {.cast(gcsafe).}: current = changedManifest()
        # Drain enough packets to surface the next M (the changed
        # manifest) + at least one further F.
        let after = await drainPackets(sock, 4)
        sock.close()
        return initial & after

      let packets = waitFor flow()
      var metas: seq[string] = @[]
      for p in packets:
        if p[0] == 'M':
          metas.add p
      check metas.len >= 3  # hello + initial element-tree + changed element-tree
      # First two metas: hello, baseline element-tree.
      check parseJson(decodeMeta(stringToBytes(metas[0])).json)["type"].getStr == "hello"
      let baselineJson = decodeMeta(stringToBytes(metas[1])).json
      check isElementTreeBody(baselineJson)
      let baselineManifestDec = decodeElementTreeJson(baselineJson)
      check baselineManifestDec.elements.len == 2
      # Third (or later) meta: changed element-tree.
      let changedJson = decodeMeta(stringToBytes(metas[2])).json
      check isElementTreeBody(changedJson)
      let changedManifestDec = decodeElementTreeJson(changedJson)
      check changedManifestDec.elements.len == 3
      check changedManifestDec.elements[1].componentPath ==
        "task_app/views/TaskRow#1"
      drainDispatcher()
      drainDispatcher()

  test "hello with no provider keeps elementTree=false":
    when defined(windows):
      skip()
    else:
      drainDispatcher()
      drainDispatcher()
      let port = pickPort()
      # No `elementTree` provider — the legacy launcher shape.
      let cfg = makeStubConfig(port, backend = "stub")
      discard startServer(cfg)
      # Extra settle time so the listening socket is fully ready.
      for _ in 0 .. 10:
        try: poll(25)
        except ValueError: break

      proc flow(): Future[string] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let msg = await recvOneMessage(sock, state)
        sock.close()
        return msg.payload

      let helloPayload = waitFor flow()
      let helloJson = parseJson(decodeMeta(
        stringToBytes(helloPayload)).json)
      check helloJson["capabilities"]["elementTree"].getBool == false
      drainDispatcher()
      drainDispatcher()
