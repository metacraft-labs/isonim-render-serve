## RS-M2 — full bridge end-to-end with the GPUI task_app demo as
## the frame source. Real WebSocket client connects, receives the
## hello M packet, then a sequence of F packets. The test asserts:
##
##   * Each frame has the correct dimensions + payload length.
##   * Frame bytes change across the stream when the VM mutates.
##
## Real stack:
##   * `BridgeConfig` with a `GpuiFrameSource` wrapping the canonical
##     EX-M3 GPUI task_app demo (`isonim_examples/task_app/main_gpui`).
##   * Real `asyncnet` WebSocket client.
##   * Real RFC 6455 framing in both directions.
##   * Real `gpui-nim-shim` cdylib (loaded via the dev shell's
##     `LD_LIBRARY_PATH` extension).

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim_gpui/renderer

import task_app/main_gpui as gpui_app

import isonim_render_serve
import isonim_render_serve/adapters/gpui_adapter
import ./ws_test_client

proc makeGpuiConfig(port: int; src: AnyFrameSource;
                    backend = "gpui"; fps = 50;
                    maxFrames = 0): BridgeConfig =
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: backend,
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: src)

suite "RS-M2: bridge streams GPUI task_app frames":

  test "client receives 5 F packets with correct dimensions":
    when defined(windows):
      skip()
    else:
      randomize()
      # Build the canonical EX-M3 GPUI task_app demo. `runTaskApp`
      # resets the per-thread leaves table, the shim's tree, and the
      # callback registry before building the new tree.
      let vm = newTaskAppVM()
      let root = gpui_app.runTaskApp(vm)
      let r = GpuiRenderer()
      let frameSource = newGpuiFrameSource(r, root,
                                           width = 320, height = 240)

      let port = pickPort()
      # Slow the bridge way down (4 fps == 250ms per frame) so the
      # test's mutations land cleanly between frames. With a 20ms
      # frame interval the receive loop may collect several frames
      # before the test's mutation thread gets scheduled.
      let cfg = makeGpuiConfig(port, frameSource.toAny(),
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
              let s = gpui_app.leavesFor(vm)
              vm.setInputText("alpha")
              fireEvent(s.addBtn, "click")
            elif frames.len == 3:
              let s = gpui_app.leavesFor(vm)
              vm.setInputText("beta")
              fireEvent(s.addBtn, "click")
        sock.close()
        return frames

      let frames = waitFor flow()
      check frames.len == 5
      for f in frames:
        check f.kind == fkFull
        check f.width == 320
        check f.height == 240
        check f.pixels.len == 320 * 240 * 4

      # The first frame was captured *before* the test mutated the
      # VM; at least one later frame must differ (the rasterizer's
      # output depends on the tree's child count / per-element
      # labels, which the VM mutations grow).
      var someDifferent = false
      for i in 1 ..< frames.len:
        var differs = false
        for j in 0 ..< frames[0].pixels.len:
          if frames[0].pixels[j] != frames[i].pixels[j]:
            differs = true
            break
        if differs:
          someDifferent = true
          break
      check someDifferent

      for i in 0 .. 5: poll(20)
      gpui_app.resetGpuiLeaves()
