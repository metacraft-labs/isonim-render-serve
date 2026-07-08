## test_bridge_emits_delta_when_negotiated — ETS-M2 Part B.
##
## End-to-end exercise of the ``element-tree-delta`` integration in
## the bridge:
##
##   1. With ``streamElementTreeDelta = true`` AND a browser
##      hello-accept M packet that pins the ``e/element-tree``
##      transport, the bridge emits the seed manifest as the legacy
##      full body, then ships every subsequent change as an
##      ``element-tree-delta`` M-subtype carrying the per-element ops.
##
##   2. With ``streamElementTreeDelta = true`` but NO hello-accept
##      from the browser, the bridge stays on the legacy
##      ``element-tree`` body — backward compatible with consumers
##      that don't recognise the new sub-kind.
##
##   3. With ``streamElementTreeDelta = false`` (the default unless
##      built with ``-d:withElementTreeDelta``), the bridge emits
##      only the legacy body regardless of what the browser
##      advertises — the wire shape is bit-for-bit identical to the
##      pre-ETS-M2 path so existing recordings / tests stay valid.
##
##   4. The hello packet's ``capabilities.transports`` array carries
##      the ``e/element-tree`` token when the gate is on, omits it
##      when the gate is off.

import std/[asyncdispatch, asyncnet, json, unittest]

import isonim_render_serve
import ./ws_test_client

proc drainDispatcher() =
  for _ in 0 .. 40:
    try: poll(25)
    except ValueError: break

# ---------------------------------------------------------------------------
# Manifests + provider
# ---------------------------------------------------------------------------

proc baselineManifest(): ElementTreeManifest =
  ElementTreeManifest(
    frameSeq: 0,
    surfaceWidth: 640, surfaceHeight: 288,
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 12, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 24, w: 640, h: 12))])

proc changedManifest(): ElementTreeManifest =
  ## Single bbox shift on row #1. The delta should carry exactly
  ## one ``eopUpdate`` op.
  ElementTreeManifest(
    frameSeq: 1,
    surfaceWidth: 640, surfaceHeight: 288,
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 12, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/TaskRow#1",
                   componentPath: "task_app/views/TaskRow#1",
                   kind: "row",
                   bounds: ElementBounds(x: 0, y: 240, w: 640, h: 12))])

proc makeConfigWithProvider(port: int;
                            provider: ElementTreeProvider;
                            streamDelta: bool;
                            fps = 8; maxFrames = 12): BridgeConfig =
  ## `fps` defaults low (≈125 ms/frame) so the server's frame loop does
  ## not buffer the whole `maxFrames` budget before the client drains the
  ## initial packets and flips the provider's manifest mid-stream. The
  ## delta/manifest re-emission this suite pins fires from inside
  ## `sendElementTreeIfChanged`; at 50 fps the flip landed after every
  ## frame was already rendered, so the changed body never appeared and
  ## the tests raced.
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: "stub",
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: newStubFrameSource(256, 256).toAny(),
    elementTree: provider,
    streamElementTreeDelta: streamDelta)

proc drainPackets(sock: AsyncSocket; count: int):
                  Future[seq[string]] {.async.} =
  result = newSeq[string]()
  # Persistent per-socket decoder: repeated drains on the same socket
  # must share one `WsFrameDecoder` so surplus recv bytes are not lost
  # at a drain boundary (see `clientStateFor` in ws_test_client).
  let state = clientStateFor(sock)
  for _ in 0 ..< count:
    let msg = await recvOneMessage(sock, state)
    if not msg.complete: break
    result.add msg.payload

proc sendHelloAccept(sock: AsyncSocket;
                     accept: seq[string]) {.async.} =
  ## Ship a client→server M packet whose body is a JSON object
  ## with an ``accept`` array. Mirrors the audit's recommended
  ## hello-accept reply shape.
  var arr = newJArray()
  for s in accept: arr.add newJString(s)
  var root = newJObject()
  root["type"] = newJString("hello-accept")
  root["accept"] = arr
  let body = $root
  let meta = MetaPacket(json: body)
  let bytes = encodeMeta(meta)
  await sendBinaryFrame(sock, bytesToString(bytes))

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

suite "ETS-M2 Part B: bridge emits delta when negotiated":

  test "1. hello transports list includes e/element-tree when gated on":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider,
        streamDelta = true, maxFrames = 3)
      discard startServer(cfg)

      proc flow(): Future[string] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let msg = await recvOneMessage(sock, state)
        sock.close()
        return msg.payload

      let helloPayload = waitFor flow()
      let helloBody = decodeMeta(stringToBytes(helloPayload)).json
      let helloJson = parseJson(helloBody)
      let transports = helloJson["capabilities"]["transports"]
      var found = false
      for entry in transports:
        if entry.getStr == "e/element-tree":
          found = true
          break
      check found
      drainDispatcher()
      drainDispatcher()

  test "2. hello transports list omits e/element-tree when gate is off":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider,
        streamDelta = false, maxFrames = 3)
      discard startServer(cfg)

      proc flow(): Future[string] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let msg = await recvOneMessage(sock, state)
        sock.close()
        return msg.payload

      let helloPayload = waitFor flow()
      let helloBody = decodeMeta(stringToBytes(helloPayload)).json
      let helloJson = parseJson(helloBody)
      let transports = helloJson["capabilities"]["transports"]
      for entry in transports:
        check entry.getStr != "e/element-tree"
      drainDispatcher()
      drainDispatcher()

  test "3. with gate ON + hello-accept advertising e/element-tree, " &
       "subsequent manifest changes ship as element-tree-delta":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider,
        streamDelta = true, maxFrames = 12)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        # 1. Pull hello + seed manifest + first F frame.
        let initial = await drainPackets(sock, 3)
        # 2. Send hello-accept advertising the element-tree
        #    transport. The bridge flips
        #    elementTreeDeltaAccepted on this M packet.
        await sendHelloAccept(sock, @["w/webp", "f/raw_rgba",
                                       "e/element-tree"])
        # 3. Let the dispatcher settle so the inbound M is read
        #    before we mutate the manifest.
        for _ in 0 .. 6:
          try: poll(10) except ValueError: break
        # 4. Flip the manifest. Next tick the bridge should ship
        #    the change as a delta (not the legacy full body).
        {.cast(gcsafe).}: current = changedManifest()
        # 5. Drain enough packets to capture the next M + further F.
        let after = await drainPackets(sock, 6)
        sock.close()
        return initial & after

      let packets = waitFor flow()
      var metas: seq[string] = @[]
      for p in packets:
        if p.len > 0 and p[0] == 'M':
          metas.add p
      check metas.len >= 3

      # First meta: hello.
      let helloBody = decodeMeta(stringToBytes(metas[0])).json
      check parseJson(helloBody)["type"].getStr == "hello"

      # Second meta: seed element-tree (legacy full body).
      let seedBody = decodeMeta(stringToBytes(metas[1])).json
      check isElementTreeBody(seedBody)
      check not isElementTreeDeltaBody(seedBody)

      # Third meta: element-tree-delta carrying the bounds shift.
      let deltaBody = decodeMeta(stringToBytes(metas[2])).json
      check isElementTreeDeltaBody(deltaBody)
      check not isElementTreeBody(deltaBody)
      let decoded = decodeElementTreeDelta(deltaBody)
      check decoded.seqNo == 1'u32
      check decoded.ops.len == 1
      check decoded.ops[0].kind == eopUpdate
      check decoded.ops[0].updId == "task_app/views/TaskRow#1"
      check decoded.ops[0].updBoundsSet
      check decoded.ops[0].updBounds.y == 240
      # Sparse: kind didn't change, so the op shouldn't carry it.
      check not decoded.ops[0].updElemKindSet

      drainDispatcher()
      drainDispatcher()

  test "4. with gate ON but NO hello-accept, the bridge stays on " &
       "the legacy element-tree body":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider,
        streamDelta = true, maxFrames = 12)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        let initial = await drainPackets(sock, 3)
        # NB: NO hello-accept sent — the browser never opts in.
        {.cast(gcsafe).}: current = changedManifest()
        let after = await drainPackets(sock, 6)
        sock.close()
        return initial & after

      let packets = waitFor flow()
      var metas: seq[string] = @[]
      for p in packets:
        if p.len > 0 and p[0] == 'M':
          metas.add p
      check metas.len >= 3
      # The third M MUST be a legacy element-tree body, not a delta.
      let changedBody = decodeMeta(stringToBytes(metas[2])).json
      check isElementTreeBody(changedBody)
      check not isElementTreeDeltaBody(changedBody)
      # Decodes as a full manifest with 2 elements (proves
      # backward-compat — the wire shape is what RS-M11 consumers
      # see).
      let manifest = decodeElementTreeJson(changedBody)
      check manifest.elements.len == 2
      drainDispatcher()
      drainDispatcher()

  test "5. with gate OFF, hello-accept advertising e/element-tree " &
       "is ignored — legacy body only":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = baselineManifest()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider,
        streamDelta = false, maxFrames = 12)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        let initial = await drainPackets(sock, 3)
        # Browser tries to opt in, but the bridge wasn't compiled /
        # configured with the gate on — the hello-accept is silently
        # ignored. Backward-compat for old consumer code paths.
        await sendHelloAccept(sock, @["e/element-tree"])
        for _ in 0 .. 6:
          try: poll(10) except ValueError: break
        {.cast(gcsafe).}: current = changedManifest()
        let after = await drainPackets(sock, 6)
        sock.close()
        return initial & after

      let packets = waitFor flow()
      var metas: seq[string] = @[]
      for p in packets:
        if p.len > 0 and p[0] == 'M':
          metas.add p
      check metas.len >= 3
      let changedBody = decodeMeta(stringToBytes(metas[2])).json
      check isElementTreeBody(changedBody)
      check not isElementTreeDeltaBody(changedBody)
      drainDispatcher()
      drainDispatcher()
