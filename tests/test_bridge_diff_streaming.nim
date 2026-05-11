## test_bridge_diff_streaming — real bridge end-to-end with a custom
## `AnyFrameSource` that emits a deterministic two-frame sequence
## with one known per-frame change. Asserts:
##
##   * First F packet is a *full* frame (no prior frame to diff
##     against).
##   * Second F packet is a *diff* frame with exactly the one
##     rectangle covering the changed pixel.
##   * Region coordinates match where we changed the pixel.
##   * Encoded second-frame packet is *smaller* than the equivalent
##     full F frame would be — the entire point of RS-M3.
##
## Real stack:
##   * Real `BridgeConfig` with a custom `AnyFrameSource` closure.
##   * Real `asyncnet` WebSocket client over RFC 6455 framing.
##   * Real packet codec on both sides.

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim_render_serve
import ./ws_test_client

const FrameW = 32
const FrameH = 32

proc makeSolid(r, g, b, a: byte): seq[byte] =
  result = newSeq[byte](FrameW * FrameH * 4)
  var i = 0
  while i < result.len:
    result[i] = r
    result[i + 1] = g
    result[i + 2] = b
    result[i + 3] = a
    i += 4

proc deterministicTwoFrameSource(): AnyFrameSource =
  ## Yields frame #0 as solid black, frame #1 as solid black with
  ## one red pixel at (5, 7). All later calls repeat frame #1.
  var tick = 0
  let renderImpl = proc(): Frame {.gcsafe.} =
    var pixels = makeSolid(0x00, 0x00, 0x00, 0xFF)
    if tick >= 1:
      let off = (7 * FrameW + 5) * 4
      pixels[off] = 0xFF
      pixels[off + 1] = 0x00
      pixels[off + 2] = 0x00
      pixels[off + 3] = 0xFF
    tick += 1
    Frame(kind: fkFull,
          flags: FrameFlags(isDiff: false, isVideo: false),
          width: FrameW, height: FrameH, pixels: pixels)
  let closeImpl = proc() {.gcsafe.} = discard
  newAnyFrameSource(FrameW, FrameH, renderImpl, closeImpl)

proc makeDiffStreamingConfig(port: int; src: AnyFrameSource;
                             fps = 50; maxFrames = 2): BridgeConfig =
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: "diff-stream-test",
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: src)

suite "RS-M3: bridge diff streaming":

  test "first frame is full RGBA, second frame is a single-rect diff":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeDiffStreamingConfig(
        port, deterministicTwoFrameSource(),
        fps = 50, maxFrames = 2)
      discard startServer(cfg)

      proc flow(): Future[seq[Frame]] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        var frames: seq[Frame] = @[]
        var sawHello = false
        while frames.len < 2:
          let msg = await recvOneMessage(sock, state)
          if not msg.complete: break
          if msg.opcode != wsOpBinary: continue
          let raw = stringToBytes(msg.payload)
          let kind = peekPacketKind(raw)
          if kind == pkMeta:
            sawHello = true
            continue
          if kind == pkFrame:
            doAssert sawHello, "F packet arrived before hello"
            frames.add decodeFrame(raw)
        sock.close()
        return frames

      let frames = waitFor flow()
      check frames.len == 2

      # Frame 0: full RGBA (no prior frame to diff against).
      check frames[0].kind == fkFull
      check frames[0].width == FrameW
      check frames[0].height == FrameH
      check frames[0].pixels.len == FrameW * FrameH * 4

      # Frame 1: diff with exactly one rect at (5, 7) of size 1x1.
      check frames[1].kind == fkDiff
      check frames[1].width == FrameW
      check frames[1].height == FrameH
      check frames[1].rects.len == 1
      let r = frames[1].rects[0]
      check r.x == 5
      check r.y == 7
      check r.w == 1
      check r.h == 1
      check r.pixels.len == 4
      check r.pixels[0] == 0xFF'u8
      check r.pixels[1] == 0x00'u8
      check r.pixels[2] == 0x00'u8
      check r.pixels[3] == 0xFF'u8

      # Bandwidth assertion: encoded diff packet is much smaller
      # than a fresh full-frame F packet would have been.
      let encDiff = encodeFrame(frames[1])
      let encFull = encodeFrame(Frame(
        kind: fkFull,
        flags: FrameFlags(isDiff: false, isVideo: false),
        width: FrameW, height: FrameH,
        pixels: newSeq[byte](FrameW * FrameH * 4)))
      check encDiff.len < encFull.len

      for i in 0 .. 5: poll(20)

  test "applying the diff to frame 0 reconstructs frame 1 exactly":
    # The browser-side path is `putImageData(rect, x, y)` over the
    # standing canvas. This test simulates that step in Nim so the
    # apply-diff algorithm is covered by the test suite even though
    # the browser runtime is out of scope.
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeDiffStreamingConfig(
        port, deterministicTwoFrameSource(),
        fps = 50, maxFrames = 2)
      discard startServer(cfg)

      proc flow(): Future[seq[Frame]] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        var frames: seq[Frame] = @[]
        var sawHello = false
        while frames.len < 2:
          let msg = await recvOneMessage(sock, state)
          if not msg.complete: break
          if msg.opcode != wsOpBinary: continue
          let raw = stringToBytes(msg.payload)
          let kind = peekPacketKind(raw)
          if kind == pkMeta:
            sawHello = true
            continue
          if kind == pkFrame:
            doAssert sawHello
            frames.add decodeFrame(raw)
        sock.close()
        return frames

      let frames = waitFor flow()
      check frames.len == 2

      # Reconstruct: start from frame 0's full bitmap and apply
      # each rect of frame 1 in turn.
      var canvas = frames[0].pixels
      check frames[1].kind == fkDiff
      let stride = FrameW * 4
      for rect in frames[1].rects:
        for row in 0 ..< rect.h:
          let srcOff = row * rect.w * 4
          let dstOff = (rect.y + row) * stride + rect.x * 4
          for k in 0 ..< rect.w * 4:
            canvas[dstOff + k] = rect.pixels[srcOff + k]

      # Build the expected reference: same as the source's frame 1.
      var expected = newSeq[byte](FrameW * FrameH * 4)
      for j in countup(3, expected.len - 1, 4):
        expected[j] = 0xFF  # alpha
      let off = (7 * FrameW + 5) * 4
      expected[off] = 0xFF
      expected[off + 1] = 0x00
      expected[off + 2] = 0x00
      expected[off + 3] = 0xFF

      check canvas == expected
      for i in 0 .. 5: poll(20)
