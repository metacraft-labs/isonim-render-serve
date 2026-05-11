## RS-M4 — full bridge end-to-end with the Freya task_app demo as
## the frame source. Real WebSocket client connects, receives the
## hello M packet, then a sequence of F packets. The test asserts:
##
##   * Each frame has the correct dimensions + payload length.
##   * Frame bytes change across the stream when the VM mutates.
##
## Real stack:
##   * `BridgeConfig` with a `FreyaFrameSource` wrapping the canonical
##     EX-M4 Freya task_app demo (`isonim_examples/task_app/main_freya`).
##   * Real `asyncnet` WebSocket client.
##   * Real RFC 6455 framing in both directions.
##   * Real `freya-nim-shim` cdylib (loaded via the dev shell's
##     `LD_LIBRARY_PATH` extension).

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim_freya/renderer

import task_app/main_freya as freya_app

import isonim_render_serve
import isonim_render_serve/adapters/freya_adapter
import ./ws_test_client

proc makeFreyaConfig(port: int; src: AnyFrameSource;
                     backend = "freya"; fps = 50;
                     maxFrames = 0): BridgeConfig =
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: backend,
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: src)

suite "RS-M4: bridge streams Freya task_app frames":

  test "client receives 5 F packets with correct dimensions":
    when defined(windows):
      skip()
    else:
      randomize()
      # Build the canonical EX-M4 Freya task_app demo. `runTaskApp`
      # resets the per-thread leaves table, the shim's tree, and the
      # callback registry before building the new tree.
      let vm = newTaskAppVM()
      let root = freya_app.runTaskApp(vm)
      let r = FreyaRenderer()
      let frameSource = newFreyaFrameSource(r, root,
                                            width = 320, height = 240)

      let port = pickPort()
      # Slow the bridge way down (4 fps == 250ms per frame) so the
      # test's mutations land cleanly between frames. With a 20ms
      # frame interval the receive loop may collect several frames
      # before the test's mutation thread gets scheduled.
      let cfg = makeFreyaConfig(port, frameSource.toAny(),
                                fps = 4, maxFrames = 5)
      discard startServer(cfg)

      proc flow(): Future[seq[Frame]] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        var frames: seq[Frame] = @[]
        var sawHello = false
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
            # After the first frame, mutate the VM. Subsequent
            # `renderFrame` calls will see the bigger tree.
            if frames.len == 1:
              let s = freya_app.leavesFor(vm)
              vm.setInputText("alpha")
              fireEvent(s.addBtn, "click")
            elif frames.len == 3:
              let s = freya_app.leavesFor(vm)
              vm.setInputText("beta")
              fireEvent(s.addBtn, "click")
        sock.close()
        return frames

      let frames = waitFor flow()
      check frames.len == 5
      # RS-M3: with diff streaming on, the first frame is always
      # full; later frames may arrive as diff F packets. Reconstruct
      # the latest full-frame pixel state by applying each diff in
      # turn, so the "frames evolve as the VM mutates" assertion
      # still has something to compare.
      check frames[0].kind == fkFull
      check frames[0].width == 320
      check frames[0].height == 240
      check frames[0].pixels.len == 320 * 240 * 4
      var reconstructed: seq[seq[byte]] = @[]
      reconstructed.add frames[0].pixels
      for i in 1 ..< frames.len:
        let f = frames[i]
        check f.width == 320
        check f.height == 240
        var current = reconstructed[i - 1]
        if f.kind == fkFull:
          check f.pixels.len == 320 * 240 * 4
          current = f.pixels
        else:
          for r in f.rects:
            let stride = 320 * 4
            for row in 0 ..< r.h:
              let srcOff = row * r.w * 4
              let dstOff = (r.y + row) * stride + r.x * 4
              for k in 0 ..< r.w * 4:
                current[dstOff + k] = r.pixels[srcOff + k]
        reconstructed.add current

      # The first frame was captured *before* the test mutated the
      # VM; at least one later reconstructed frame must differ.
      var someDifferent = false
      for i in 1 ..< reconstructed.len:
        var differs = false
        for j in 0 ..< reconstructed[0].len:
          if reconstructed[0][j] != reconstructed[i][j]:
            differs = true
            break
        if differs:
          someDifferent = true
          break
      check someDifferent

      for i in 0 .. 5: poll(20)
      freya_app.resetFreyaLeaves()
