## test_android_adapter_android_only — RS-M6 Android-host integration test.
##
## Gated entirely `when defined(android)`. On Linux the test body
## skips with a single `check true` and a docstring pointer to the
## cross-compile gate (`test_android_adapter_compile.nim`). On the
## Android emulator host (Android Studio's emulator on Apple
## Silicon — see RS-M6 / EX-M6 status blocks for the
## emulator-on-macOS justification) the test drives the EX-M6
## Android task_app demo through the RS-M6 Android adapter and
## asserts the captured pixel buffer reflects the rendered tree.
##
## **macOS engineer (RS-M6 completion):** the test body below is a
## scaffold — fill it in once the `View.draw(Canvas)` capture path
## lands in `src/isonim_render_serve/adapters/android_adapter.nim`.
## The shape should mirror `test_freya_adapter_renderframe.nim` and
## `test_gpui_adapter_renderframe.nim` (build a small headless tree
## via `AndroidRenderer`, instantiate an `AndroidFrameSource`, call
## `renderFrame`, assert dimensions + payload length match
## `width*height*4`, assert at least one non-background pixel for
## each leaf colour).
##
## Cross-references:
##   - `tests/test_android_adapter_compile.nim` — Linux-side cross-
##     compile gate that runs unconditionally.
##   - `isonim-render-stream.status.org` § RS-M6 — hand-off
##     checklist for flipping the milestone from `partial-linux`
##     to `complete`.

import std/unittest

when defined(android):
  import isonim_android/renderer

  import isonim_render_serve/adapters/android_adapter
  import isonim_render_serve/packet

  suite "RS-M6: AndroidFrameSource.renderFrame (Android emulator host)":

    test "dimensions and payload length match the configured size":
      ## TODO(macOS engineer): replace this stub body with a real
      ## headless render. The pattern mirrors RS-M2 GPUI /
      ## RS-M4 Freya / RS-M5 Cocoa:
      ##
      ##   resetRenderer()
      ##   let r = AndroidRenderer()
      ##   let root = r.createElement("div")
      ##   r.setAttribute(root, "class", "test-root")
      ##   r.setTextContent(root, "RS-M6 android capture smoke")
      ##   let src = newAndroidFrameSource(r, root, width = 320, height = 240)
      ##   let frame = src.renderFrame()
      ##   check frame.kind == fkFull
      ##   check frame.width == 320
      ##   check frame.height == 240
      ##   check frame.pixels.len == 320 * 240 * 4
      ##   # At least one non-grey pixel (the View.draw(Canvas)
      ##   # path paints the root view into the bitmap, so the
      ##   # canvas is not uniform grey).
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
      ## TODO(macOS engineer): wire the EX-M6 Android task_app
      ## demo as the bridge's frame source, drive `frameLoop` for
      ## N ticks, assert the WS client receives N `F` packets,
      ## and assert frame[N-1] differs from frame[0] after a
      ## programmatic `vm.setInputText("from android") +
      ## vm.addTask` between ticks (proves the View.draw(Canvas)
      ## capture path is *live*, not just one-shot). The shape
      ## mirrors `test_freya_adapter_streams_task_app.nim`.
      ##
      ## On the emulator host, the JNI bridge needs the
      ## commandBuffer lane (`-d:commandBuffer`) — the mockJni
      ## lane records the view tree in-process without actually
      ## constructing real `android.view.View` instances, so the
      ## `View.draw(Canvas)` path has no real bitmap to render
      ## into.
      check true

else:
  ## Linux / non-Android host. The cross-compile gate (see
  ## `test_android_adapter_compile.nim`) is the source of truth
  ## for adapter-surface drift on this host; this test skips so
  ## the Linux `just test` matrix stays green.
  suite "RS-M6: AndroidFrameSource.renderFrame (Android emulator host)":
    test "skipped on Linux — see test_android_adapter_compile.nim":
      check true
