## test_bridge_hello_static_frame_source — PSZ-M3 note 24.
##
## The hello's `capabilities.frameSource` comes from one of two places: the
## source's own label closure (`frameSourceLabelImpl`, a source that labels the
## frames it sends), or the static `cfg.frameSourceTag` for a source that
## declares a tag and has no closure. `sendHello` (bridge.nim) takes the static
## tag when the closure is nil. Removing that nil check makes the bridge call a
## nil closure, so a source without one never gets a hello. The fell-back test
## (test_bridge_renderer_fell_back.nim) always sets the closure, so nothing else
## covers this path.
##
## Mocks, and why each is here: the frame source is built from closures, as in
## test_bridge_renderer_fell_back.nim, and it has no label closure. That absence
## is the case under test. The WebSocket is the real bridge on a real socket,
## read by the shared `ws_test_client` helpers, and the hello is decoded with
## the real `decodeMeta`.
##
## Negative control: in a scratch copy, remove the `frameSourceLabelImpl != nil`
## check that guards the call in `sendHello`. The bridge then faults on the nil
## closure: the test binary crashes with SIGSEGV in sendHello, so it fails.

import std/[asyncdispatch, asyncnet, json, random, unittest]

import isonim_render_serve
import ./ws_test_client

const
  frameWidth = 8
  frameHeight = 8

proc newUnlabelledSource(): AnyFrameSource =
  ## A source with a size and a frame, and no label closure of either kind.
  let px = newSeq[byte](frameWidth * frameHeight * 4)
  result = newAnyFrameSource(frameWidth, frameHeight,
    renderFrameImpl = proc(): Frame {.closure, gcsafe.} =
      Frame(kind: fkFull,
            flags: FrameFlags(isDiff: false, isVideo: false),
            width: frameWidth, height: frameHeight, pixels: px),
    closeImpl = proc() {.closure, gcsafe.} = discard)

proc makeConfig(port: int; source: AnyFrameSource; tag: string): BridgeConfig =
  result = makeStubConfig(port, fps = 50)
  result.frameSource = source
  result.frameSourceTag = tag

proc metaJson(payload: string): string =
  ## The JSON of an M packet received as a WebSocket binary payload.
  var bytes = newSeq[byte](payload.len)
  for i, ch in payload:
    bytes[i] = byte(ch)
  result = decodeMeta(bytes).json

suite "PSZ-M3 note 24: a source with a static tag and no label closure":

  test "the hello declares the static tag, and frames follow it":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      discard startServer(makeConfig(port, newUnlabelledSource(), "synthetic"))

      proc flow(): Future[(string, int, uint16)] {.async.} =
        let sock = await connectWs(port)
        let state = clientStateFor(sock)
        var hello = ""
        var binaryCount = 0
        var closeCode: uint16 = 0
        for step in 0 ..< 50:
          let msg = await recvOneMessage(sock, state)
          if not msg.complete: break
          if msg.opcode == wsOpClose:
            closeCode = decodeCloseStatus(msg.payload)
            break
          if msg.opcode == wsOpBinary:
            if binaryCount == 0:
              hello = metaJson(msg.payload)
            inc binaryCount
          if binaryCount >= 3: break
        sock.close()
        return (hello, binaryCount, closeCode)

      let (hello, binaryCount, closeCode) = waitFor flow()
      check hello.len > 0
      if hello.len > 0:
        let caps = parseJson(hello)["capabilities"]
        check caps["frameSource"].getStr == "synthetic"
      # The hello is the first binary message; at least one frame follows it.
      check binaryCount >= 2
      check closeCode == 0
      for tick in 0 .. 5: poll(20)
