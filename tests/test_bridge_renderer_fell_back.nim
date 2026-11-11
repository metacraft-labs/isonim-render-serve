## test_bridge_renderer_fell_back — PSZ-M3 note 22: a frame source whose label
## changes after the hello fails the connection.
##
## The editor is told by the hello which frame source the frames are of. When
## the renderer falls back to another source mid-connection (a headless error on
## macOS, or any later change), the bridge must not keep sending frames as if
## they were the declared source. It closes the WebSocket with
## `rendererFellBackCloseCode` (4001) and sends no frame of the new source.
##
## Mocks, and why each is here: the frame source is a fabricated
## `AnyFrameSource` built from closures, not a GPUI renderer. The label flip is
## the only behaviour under test, and a real fallback needs a headless renderer
## this Linux test host does not have (test_hello_frame_source.nim covers the
## real source's label). The WebSocket is the real bridge on a real socket, read
## by the shared `ws_test_client` helpers.
##
## Negative control: with the `trackFrameSource` check removed from `frameLoop`
## (in a scratch copy) the connection never closes with 4001 and this test
## fails: the bridge keeps streaming the fallback frames.

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim_render_serve
import ./ws_test_client

type
  FlipState = ref object
    ## Frames rendered so far; the label is "real" until the frame count
    ## passes `flipAfter`, then "synthetic" (the fallback).
    rendered: int
    flipAfter: int

const
  frameWidth = 8
  frameHeight = 8

proc newFlippingSource(flipAfter: int): AnyFrameSource =
  let st = FlipState(rendered: 0, flipAfter: flipAfter)
  let px = newSeq[byte](frameWidth * frameHeight * 4)
  result = newAnyFrameSource(frameWidth, frameHeight,
    renderFrameImpl = proc(): Frame {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        inc st.rendered
        Frame(kind: fkFull,
              flags: FrameFlags(isDiff: false, isVideo: false),
              width: frameWidth, height: frameHeight, pixels: px),
    closeImpl = proc() {.closure, gcsafe.} = discard)
  # The hello declares the source's label before any frame: "real".
  result.frameSourceLabelImpl = proc(): string {.closure, gcsafe.} = "real"
  # The label of the frame last rendered: it changes after `flipAfter` frames.
  result.currentFrameSourceLabelImpl = proc(): string {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if st.rendered > st.flipAfter: "synthetic" else: "real"

proc makeConfig(port: int; source: AnyFrameSource): BridgeConfig =
  result = makeStubConfig(port, fps = 50)
  result.frameSource = source

suite "PSZ-M3 note 22: a mid-connection fallback fails the connection":

  test "a label change after the hello closes with 4001 and sends no fallback frame":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      # Two real frames, then the source falls back: the third rendered frame
      # is synthetic and must not be sent.
      discard startServer(makeConfig(port, newFlippingSource(flipAfter = 2)))

      proc flow(): Future[(uint16, string, int)] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        var binaryAfterHello = 0
        var closeCode: uint16 = 0
        var closeReason = ""
        for i in 0 ..< 50:
          let msg = await recvOneMessage(sock, state)
          if not msg.complete: break
          if msg.opcode == wsOpClose:
            closeCode = decodeCloseStatus(msg.payload)
            if msg.payload.len > 2:
              closeReason = msg.payload[2 .. ^1]
            break
          if msg.opcode == wsOpBinary:
            inc binaryAfterHello
        sock.close()
        # The hello is the first binary message; the rest are frames.
        return (closeCode, closeReason, binaryAfterHello - 1)

      let (code, reason, frames) = waitFor flow()
      check code == rendererFellBackCloseCode
      check reason == rendererFellBackReason
      check frames == 2
      for i in 0 .. 5: poll(20)
