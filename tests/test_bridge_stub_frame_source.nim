## test_bridge_stub_frame_source — bridge serves the stub gradient
## source over a real WebSocket; client receives a sequence of F
## packets whose payload bytes form the expected animated gradient.
##
## Real stack: real `BridgeConfig`, real `StubFrameSource`, real
## `asyncnet` client, real RFC 6455 framing both directions.

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim_render_serve
import ./ws_test_client

suite "isonim-render-serve: stub frame source over real WS":

  test "client receives N full RGBA frames with correct dimensions":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeStubConfig(port, fps = 50, maxFrames = 5)
      discard startServer(cfg)

      proc flow(): Future[seq[Frame]] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        var frames: seq[Frame] = @[]
        var sawHello = false
        # Drain until we've collected 5 F packets (or the server
        # closed). Hello arrives first; everything after that is F.
        while frames.len < 5:
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
      check frames.len == 5
      # RS-M3: the stub gradient changes *every* pixel between
      # ticks, so the diff-region encoder always trips the
      # 50%-of-full-frame threshold and falls back to a non-diff
      # full F packet. Bridge therefore still ships fkFull for
      # every tick on this source.
      for f in frames:
        check f.kind == fkFull
        check f.width == 256
        check f.height == 256
        check f.pixels.len == 256 * 256 * 4
        # Alpha channel must be 0xFF on every pixel.
        var allOpaque = true
        var idx = 3
        while idx < f.pixels.len:
          if f.pixels[idx] != 0xFF'u8:
            allOpaque = false; break
          idx += 4
        check allOpaque

      # Gradient sanity: first vs last pixel differ in at least one
      # channel; pixels along the top row form a smooth progression
      # in the red channel (which is `(x + tick) mod 256` per the
      # stub spec).
      let f0 = frames[0]
      check f0.pixels[0] != f0.pixels[f0.pixels.len - 4]
      # Walk first row: red channel should increment by 1 each pixel
      # for the first frame (tick=0).
      var monotonic = true
      for x in 1 ..< 256:
        let prev = int(f0.pixels[(x - 1) * 4])
        let cur = int(f0.pixels[x * 4])
        if ((prev + 1) and 0xFF) != cur:
          monotonic = false; break
      check monotonic

      # Frame-to-frame animation: tick advances; the first pixel's
      # red channel must change between successive frames.
      for i in 1 ..< frames.len:
        check frames[i].pixels[0] != frames[i - 1].pixels[0]

      for i in 0 .. 5: poll(20)

  test "stub source renders deterministically (per-tick gradient)":
    # Sanity check the in-process generator independently — its
    # output is what the bridge ships, so test it directly too.
    let src = newStubFrameSource(4, 4)
    let f0 = src.renderFrame()
    let f1 = src.renderFrame()
    check f0.width == 4
    check f0.height == 4
    check f0.pixels.len == 64
    # Pixel (0,0) in frame 0: R = (0+0) = 0, G = (0+0) = 0,
    # B = (0+0+0) = 0, A = 0xFF.
    check f0.pixels[0] == 0'u8
    check f0.pixels[1] == 0'u8
    check f0.pixels[2] == 0'u8
    check f0.pixels[3] == 0xFF'u8
    # Pixel (0,0) in frame 1: tick=1 → R=1, G=1, B=2.
    check f1.pixels[0] == 1'u8
    check f1.pixels[1] == 1'u8
    check f1.pixels[2] == 2'u8
