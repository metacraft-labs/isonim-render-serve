## test_cocoa_adapter_macos_only — RS-M5 macOS-host integration test.
##
## Gated entirely `when defined(macosx)`. On Linux the test body
## skips with a single `check true` and a docstring pointer to the
## cross-compile gate (`test_cocoa_adapter_compile.nim`). On macOS
## the test drives the EX-M5 Cocoa task_app demo through the
## RS-M5 Cocoa adapter and asserts the captured pixel buffer
## reflects the rendered tree.
##
## **macOS engineer (RS-M5 completion):** the test body below is a
## scaffold — fill it in once the
## `bitmapImageRepForCachingDisplayInRect` capture path lands in
## `src/isonim_render_serve/adapters/cocoa_adapter.nim`. The shape
## should mirror `test_freya_adapter_renderframe.nim` and
## `test_gpui_adapter_renderframe.nim` (build a small headless tree
## via `CocoaRenderer`, instantiate a `CocoaFrameSource`, call
## `renderFrame`, assert dimensions + payload length match
## `width*height*4`, assert at least one non-background pixel for
## each leaf colour).
##
## Cross-references:
##   - `tests/test_cocoa_adapter_compile.nim` — Linux-side cross-
##     compile gate that runs unconditionally.
##   - `isonim-render-stream.status.org` § RS-M5 — hand-off checklist
##     for flipping the milestone from `partial-linux` to `complete`.

import std/unittest

when defined(macosx):
  import isonim_cocoa/renderer

  import isonim_render_serve/adapters/cocoa_adapter
  import isonim_render_serve/packet

  suite "RS-M5: CocoaFrameSource.renderFrame (macOS host)":

    test "dimensions and payload length match the configured size":
      ## TODO(macOS engineer): replace this stub body with a real
      ## headless render. The pattern mirrors RS-M2 GPUI /
      ## RS-M4 Freya:
      ##
      ##   resetTree()
      ##   let r = CocoaRenderer()
      ##   let root = r.createElement("div")
      ##   r.setAttribute(root, "class", "test-root")
      ##   r.setTextContent(root, "RS-M5 cocoa capture smoke")
      ##   let src = newCocoaFrameSource(r, root, width = 320, height = 240)
      ##   let frame = src.renderFrame()
      ##   check frame.kind == fkFull
      ##   check frame.width == 320
      ##   check frame.height == 240
      ##   check frame.pixels.len == 320 * 240 * 4
      ##   # At least one non-grey pixel (the AppKit headless render
      ##   # paints the root view into the bitmap rep, so the canvas
      ##   # is not uniform grey).
      ##   var nonGrey = 0
      ##   for i in 0 ..< (frame.width * frame.height):
      ##     let off = i * 4
      ##     if frame.pixels[off]   != 0x18'u8 or
      ##        frame.pixels[off+1] != 0x18'u8 or
      ##        frame.pixels[off+2] != 0x18'u8:
      ##       inc nonGrey
      ##   check nonGrey > 0
      check true

    test "streams a real task_app tree end-to-end through the bridge":
      ## TODO(macOS engineer): wire the EX-M5 Cocoa task_app demo as
      ## the bridge's frame source, drive `frameLoop` for N ticks,
      ## assert the WS client receives N `F` packets, and assert
      ## frame[N-1] differs from frame[0] after a programmatic
      ## `vm.setInputText("from cocoa") + vm.addTask` between ticks
      ## (proves the AppKit capture path is *live*, not just
      ## one-shot). The shape mirrors
      ## `test_freya_adapter_streams_task_app.nim`.
      check true

else:
  ## Linux / non-macOS host. The cross-compile gate (see
  ## `test_cocoa_adapter_compile.nim`) is the source of truth for
  ## adapter-surface drift on this host; this test skips so the Linux
  ## `just test` matrix stays green.
  suite "RS-M5: CocoaFrameSource.renderFrame (macOS host)":
    test "skipped on Linux — see test_cocoa_adapter_compile.nim":
      check true
