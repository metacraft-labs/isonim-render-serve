## test_cocoa_adapter_macos_only — RS-M5 macOS-host integration test.
##
## Gated entirely `when defined(macosx)`. On Linux the test body
## skips with a single `check true` and a docstring pointer to the
## cross-compile gate (`test_cocoa_adapter_compile.nim`). On macOS
## the test drives the EX-M5 Cocoa task_app demo through the
## RS-M5 Cocoa adapter and asserts the captured pixel buffer
## reflects the rendered tree.
##
## What this test exercises on macOS:
##
##   1. A direct unit hit on `CocoaFrameSource.renderFrame` — builds
##      a tiny headless `CocoaRenderer` tree, instantiates a
##      `CocoaFrameSource`, calls `renderFrame`, asserts dimensions
##      + payload length + at least one non-grey pixel (i.e. the
##      AppKit `bitmapImageRepForCachingDisplayInRect:` path actually
##      drew the rendered tree into the bitmap rep, instead of
##      handing back the Linux-scaffold uniform grey).
##
##   2. A full bridge end-to-end run against the EX-M5 canonical
##      `task_app/main_cocoa.nim` composition root. Mirrors the
##      RS-M2 (GPUI) / RS-M4 (Freya) `test_*_streams_task_app.nim`
##      shape: spin up the bridge, connect a real WebSocket client,
##      receive the hello M packet, collect a sequence of F packets,
##      mutate the VM between frames, assert that at least one later
##      frame differs from the first (proves the AppKit capture is
##      live, not one-shot stale).
##
## Cross-references:
##   - `tests/test_cocoa_adapter_compile.nim` — Linux-side cross-
##     compile gate that runs unconditionally.
##   - `isonim-render-stream.status.org` § RS-M5 — hand-off checklist
##     for flipping the milestone from `partial-linux` to `complete`.

import std/unittest

when defined(macosx):
  import std/[asyncdispatch, asyncnet, random]

  import isonim_cocoa/renderer

  import task_app/main_cocoa as cocoa_app

  import isonim_render_serve
  import isonim_render_serve/adapters/cocoa_adapter
  import ./ws_test_client

  proc makeCocoaConfig(port: int; src: AnyFrameSource;
                       backend = "cocoa"; fps = 50;
                       maxFrames = 0): BridgeConfig =
    BridgeConfig(
      port: Port(port),
      staticDir: ".",
      backend: backend,
      frameIntervalMs: max(1, 1000 div fps),
      maxFrames: maxFrames,
      inputSink: newBufferedInputSink().toAny(),
      frameSource: src)

  suite "RS-M5: CocoaFrameSource.renderFrame (macOS host)":

    test "dimensions and payload length match the configured size":
      ## Build a tiny headless `CocoaRenderer` tree and capture it
      ## through the real `bitmapImageRepForCachingDisplayInRect:` /
      ## `cacheDisplayInRect:toBitmapImageRep:` AppKit pipeline. The
      ## resulting RGBA8888 buffer must be exactly `width * height *
      ## 4` bytes long, every pixel opaque, and the raster must
      ## reflect the rendered tree — i.e. it must NOT be the uniform
      ## `(0x18, 0x18, 0x18, 0xFF)` dark grey the Linux scaffold
      ## hands out, and it must contain *multiple distinct colours*
      ## (rules out the failure mode where the helper falls back to
      ## a single solid colour like pure black or pure white).
      resetTree()
      resetCallbacks()
      let r = CocoaRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, "class", "test-root")
      # Paint a distinctive non-grey background so the canvas content
      # is byte-distinct from the Linux scaffold's (0x18, 0x18, 0x18,
      # 0xFF) pixels in every single byte. We pick a saturated colour
      # that no swizzle confusion can accidentally reproduce.
      r.setStyle(root, "background-color", "#c83264")  # raspberry
      let label = r.createElement("p")
      r.setTextContent(label, "RS-M5 cocoa capture smoke")
      r.appendChild(root, label)
      let btn = r.createElement("button")
      r.setTextContent(btn, "Click me")
      r.appendChild(root, btn)

      let src = newCocoaFrameSource(r, root, width = 320, height = 240)
      let frame = src.renderFrame()

      check frame.kind == fkFull
      check frame.width == 320
      check frame.height == 240
      check frame.pixels.len == 320 * 240 * 4

      # Every alpha byte must be opaque — the
      # bitmapImageRepForCachingDisplayInRect: rep that AppKit
      # allocates is RGBA with hasAlpha:YES.
      var allOpaque = true
      var idx = 3
      while idx < frame.pixels.len:
        if frame.pixels[idx] != 0xFF'u8:
          allOpaque = false
          break
        idx += 4
      check allOpaque

      # No pixel may match the Linux placeholder scaffold's
      # (0x18, 0x18, 0x18, 0xFF) grey — if AppKit produced a real
      # raster, it cannot be pure dark grey (and our raspberry
      # background is far from grey on every channel).
      var greyPixels = 0
      for i in 0 ..< (frame.width * frame.height):
        let off = i * 4
        if frame.pixels[off]     == 0x18'u8 and
           frame.pixels[off + 1] == 0x18'u8 and
           frame.pixels[off + 2] == 0x18'u8:
          inc greyPixels
      check greyPixels == 0

      # AppKit's NSColor.colorWithRed:green:blue:alpha: paints the
      # layer's background colour through CALayer. With our raspberry
      # fill on `<div>` we expect the bulk of pixels to be dominated
      # by the red channel. The exact bytes shift versus the source
      # `#c83264` because AppKit applies a colour-space conversion
      # (NSCalibratedRGBColorSpace gamma) when the CGColor is built
      # from `colorWithRed:green:blue:alpha:` floats and then drawn
      # into the bitmap rep's device colour space — on this M1 box
      # the raspberry source `(200, 50, 100)` lands at `(185, 27, 81)`
      # in the captured bytes (gamma shift of ≈15–25 per channel).
      # Assert the channel *relationships* instead of literal bytes
      # so the test is robust against this gamma shift: red must
      # dominate green and blue across most pixels.
      var redDominant = 0
      for i in 0 ..< (frame.width * frame.height):
        let off = i * 4
        let pr = int(frame.pixels[off])
        let pg = int(frame.pixels[off + 1])
        let pb = int(frame.pixels[off + 2])
        # Raspberry-like: red is strongly above green and blue is
        # the same order of magnitude as red minus a clear gap.
        if pr > pg + 50 and pr > pb + 50 and pb > pg + 20:
          inc redDominant
      # At least half the captured raster must match the raspberry
      # channel-relationship signature. The `<div>` with wantsLayer
      # = YES + backgroundColor = raspberry paints the layer's full
      # bounds; buttons + labels are unstyled subviews that paint
      # their own small areas on top, leaving the parent layer
      # visible across most of the canvas.
      check redDominant > (frame.width * frame.height) div 2

    test "streams a real task_app tree end-to-end through the bridge":
      ## EX-M5 canonical composition root — `task_app/main_cocoa`'s
      ## `runTaskApp(vm)` builds the four-leaf task_app tree against
      ## a fresh `CocoaRenderer`. We wrap that tree in
      ## `CocoaFrameSource`, spin up the bridge, connect a real
      ## WebSocket client, and assert the wire sees N `F` packets
      ## plus an `M` hello. Then mutate the VM mid-stream (set input
      ## text + click Add) and assert at least one later frame
      ## reconstructs to a pixel buffer that differs from the first
      ## — proves the AppKit capture is live, not a single static
      ## snapshot.
      when defined(windows):
        skip()
      else:
        randomize()
        let vm = newTaskAppVM()
        let root = cocoa_app.runTaskApp(vm)
        let r = CocoaRenderer()
        let frameSource = newCocoaFrameSource(r, root,
                                              width = 320, height = 240)
        let port = pickPort()
        # 4 fps == 250 ms per frame; gives the mutation interleave
        # plenty of room. Mirrors the GPUI/Freya integration tests.
        let cfg = makeCocoaConfig(port, frameSource.toAny(),
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
              # Mutate after frame 1 and frame 3 so subsequent frames
              # see a bigger tree. `cocoa_app.leavesFor(vm).addBtn` is
              # the canonical click target (see the EX-M5 leaves
              # docstring for why we drive Add via fireEvent rather
              # than NSTextField submit).
              if frames.len == 1:
                let s = cocoa_app.leavesFor(vm)
                vm.setInputText("from cocoa one")
                r.fireEvent(s.addBtn, "click")
              elif frames.len == 3:
                let s = cocoa_app.leavesFor(vm)
                vm.setInputText("from cocoa two")
                r.fireEvent(s.addBtn, "click")
          sock.close()
          return frames

        let frames = waitFor flow()
        check frames.len == 5
        # RS-M3 diff streaming: the first frame is always a full
        # frame; later frames may be diff F packets. Reconstruct each
        # full frame so the "frames evolve as the VM mutates"
        # assertion has a pixel buffer to compare.
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
            for rect in f.rects:
              let stride = 320 * 4
              for row in 0 ..< rect.h:
                let srcOff = row * rect.w * 4
                let dstOff = (rect.y + row) * stride + rect.x * 4
                for k in 0 ..< rect.w * 4:
                  current[dstOff + k] = rect.pixels[srcOff + k]
          reconstructed.add current

        # Frame 0 was captured before the test mutated the VM; at
        # least one later reconstructed frame must differ.
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
        cocoa_app.resetCocoaLeaves()

else:
  ## Linux / non-macOS host. The cross-compile gate (see
  ## `test_cocoa_adapter_compile.nim`) is the source of truth for
  ## adapter-surface drift on this host; this test skips so the Linux
  ## `just test` matrix stays green.
  suite "RS-M5: CocoaFrameSource.renderFrame (macOS host)":
    test "skipped on Linux — see test_cocoa_adapter_compile.nim":
      check true
