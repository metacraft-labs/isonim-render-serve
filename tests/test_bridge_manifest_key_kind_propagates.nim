## test_bridge_manifest_key_kind_propagates — ETS-M2 Part A.
##
## ETS-M1's audit (§ 2, file:line `bridge.nim:359-375`) flagged a
## latent bug in the legacy element-tree dedup hash: `manifestKey`
## spanned `(id, bounds)` only, with `kind` excluded. That meant any
## launcher that recategorised a node from one kind to another
## without otherwise mutating its `id` or `bounds` (e.g. the
## task-app's `row -> row-completed` flip the moment a task is
## marked done) silently failed to re-ship the manifest. The
## browser-side overlay continued to paint the old kind's
## affordance colour for the rest of the connection.
##
## This test exercises the precise mutation shape: a single
## element's `kind` field flips between two valid values; everything
## else (id, bounds, surface dimensions, neighbour entries) stays
## byte-identical. Pre-fix the second manifest is silently dropped
## and the test fails at `metas.len >= 3` because the bridge only
## ever emits hello + initial manifest. Post-fix the third meta is
## the changed manifest with the new kind value.
##
## This is the campaign's load-bearing correctness fix — even if
## the rest of ETS-M2 stalls, this single test going green delivers
## real user value (comment-mode overlays correctly track kind
## mutations).

import std/[asyncdispatch, asyncnet, json, unittest]

import isonim_render_serve
import ./ws_test_client

proc drainDispatcher() =
  for _ in 0 .. 40:
    try: poll(25)
    except ValueError: break

# ---------------------------------------------------------------------------
# Manifests — identical except for one element's `kind`.
# ---------------------------------------------------------------------------

proc kindPropagateBaseline(): ElementTreeManifest =
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

proc kindPropagateChanged(): ElementTreeManifest =
  ## Flips the first row's `kind` from "row" to "row-completed".
  ## Bounds + id + componentPath + neighbour entries unchanged.
  ElementTreeManifest(
    frameSeq: 1,
    surfaceWidth: 640, surfaceHeight: 288,
    elements: @[
      ElementEntry(id: "task_app/views/TaskRow#0",
                   componentPath: "task_app/views/TaskRow#0",
                   kind: "row-completed",
                   bounds: ElementBounds(x: 0, y: 36, w: 640, h: 12)),
      ElementEntry(id: "task_app/views/FilterBar",
                   componentPath: "task_app/views/FilterBar",
                   kind: "filter-bar",
                   bounds: ElementBounds(x: 0, y: 12, w: 240, h: 12))])

proc makeConfigWithProvider(port: int;
                            provider: ElementTreeProvider;
                            fps = 8; maxFrames = 6): BridgeConfig =
  ## `fps` defaults low (≈125 ms/frame) so the server's frame loop does
  ## not race ahead and buffer every frame before the client can drain
  ## the initial packets and flip the provider's manifest between ticks.
  ## The re-emission this test pins is triggered from inside the frame
  ## loop's `sendElementTreeIfChanged`; at 50 fps the whole `maxFrames`
  ## budget was rendered before the mid-stream flip landed, so the third
  ## (changed) manifest never appeared and the test raced.
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
  result = newSeq[string]()
  # Persistent per-socket decoder: repeated drains on the same socket
  # must share one `WsFrameDecoder` so surplus recv bytes are not lost
  # at a drain boundary (see `clientStateFor` in ws_test_client).
  let state = clientStateFor(sock)
  for _ in 0 ..< count:
    let msg = await recvOneMessage(sock, state)
    if not msg.complete: break
    result.add msg.payload

suite "ETS-M2 Part A: manifestKey spans kind":

  test "a kind-only mutation re-emits the element-tree M packet":
    when defined(windows):
      skip()
    else:
      let port = pickPort()
      var current = kindPropagateBaseline()
      let provider = ElementTreeProvider(
        buildImpl: proc(): ElementTreeManifest {.gcsafe.} =
          {.cast(gcsafe).}: current)
      let cfg = makeConfigWithProvider(port, provider, maxFrames = 8)
      discard startServer(cfg)

      proc flow(): Future[seq[string]] {.async.} =
        let sock = await connectWs(port)
        # Pull hello + initial element-tree + first F frame.
        let initial = await drainPackets(sock, 3)
        # Flip kind-only between frame ticks. ETS-M1 audit § 2:
        # pre-fix this mutation is silently dropped because
        # manifestKey hashes (id, bounds) but excludes kind.
        {.cast(gcsafe).}: current = kindPropagateChanged()
        # Drain enough packets to surface the changed manifest
        # plus at least one further F.
        let after = await drainPackets(sock, 5)
        sock.close()
        return initial & after

      let packets = waitFor flow()

      var metas: seq[string] = @[]
      for p in packets:
        if p.len > 0 and p[0] == 'M':
          metas.add p

      # Expect hello (M #0) + initial element-tree (M #1) + the
      # second element-tree emission triggered by the kind flip
      # (M #2). Pre-fix only #0 + #1 ever appear because the dedup
      # gate suppresses the second manifest.
      # Expect hello (M #0) + initial element-tree (M #1) + the
      # second element-tree emission triggered by the kind flip
      # (M #2). Pre-fix only #0 + #1 ever appear because the dedup
      # gate suppresses the second manifest. The assertion message
      # surfaces the actual count to make a regression obvious.
      if metas.len < 3:
        echo "kind-only mutation produced ", metas.len,
             " meta packets (expected >= 3)"
      check metas.len >= 3

      # The first M is hello.
      let helloBody = decodeMeta(stringToBytes(metas[0])).json
      let helloNode = parseJson(helloBody)
      check helloNode["type"].getStr == "hello"
      check helloNode["capabilities"]["elementTree"].getBool == true

      # The second M is the seed manifest carrying the original kind.
      let seedBody = decodeMeta(stringToBytes(metas[1])).json
      check isElementTreeBody(seedBody)
      let seedManifest = decodeElementTreeJson(seedBody)
      check seedManifest.elements.len == 2
      check seedManifest.elements[0].id == "task_app/views/TaskRow#0"
      check seedManifest.elements[0].kind == "row"

      # The third M is the kind-only-changed manifest. The id and
      # bounds match the baseline; only `kind` differs. Pre-fix
      # this packet would not exist.
      let changedBody = decodeMeta(stringToBytes(metas[2])).json
      check isElementTreeBody(changedBody)
      let changedManifest = decodeElementTreeJson(changedBody)
      check changedManifest.elements.len == 2
      check changedManifest.elements[0].id == "task_app/views/TaskRow#0"
      check changedManifest.elements[0].kind == "row-completed"
      # Bounds stayed identical between the two manifests — the
      # only delta is the `kind` flip. This pins the assertion
      # tightly to the bug ETS-M2 Part A fixes.
      check changedManifest.elements[0].bounds.x ==
        seedManifest.elements[0].bounds.x
      check changedManifest.elements[0].bounds.y ==
        seedManifest.elements[0].bounds.y
      check changedManifest.elements[0].bounds.w ==
        seedManifest.elements[0].bounds.w
      check changedManifest.elements[0].bounds.h ==
        seedManifest.elements[0].bounds.h

      drainDispatcher()
      drainDispatcher()
