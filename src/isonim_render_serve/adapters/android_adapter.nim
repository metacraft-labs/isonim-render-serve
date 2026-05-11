## RS-M6: Android streaming adapter (Linux-side scaffold; macOS host
## completes via emulator).
##
## Wraps an `AndroidRenderer` + root `AndroidElement` into the bridge's
## `AnyFrameSource` so the WebSocket bridge can stream a headless
## Android view tree to a browser canvas. Mirrors the shape of the
## GPUI (RS-M2), Freya (RS-M4) and Cocoa (RS-M5) adapters so the
## bridge consumes any of the four real back-ends identically.
##
## ## Status — partial-linux
##
## This is the *Linux-side scaffold*. The whole Android-runtime-
## touching body is gated `when defined(android)` because
## `isonim_android/jni_callbacks` raises a hard `{.error.}` unless
## either `-d:mockJni` (host-side test shim) or `-d:commandBuffer`
## (real Android JNI bridge) is set — and `AndroidRenderer.fireEvent`
## / the real capture path drive
## `android.view.View.draw(android.graphics.Canvas)` into an
## `android.graphics.Bitmap`, both Java classes that live inside
## the Android runtime (ART), reachable only via JNI from a
## process running on an emulator or device. On a plain Linux
## host (no `-d:android`, no `-d:mockJni`) we cannot even *import*
## `isonim_android/renderer` because the `{.error.}` fires at
## semantic-checking time. So the Linux-scaffold path keeps the
## entire renderer-touching block under `when defined(android)`,
## exposes only the surface types (`AndroidFrameSource`,
## `AndroidCaptureMode`) plus stub `renderFrame` / `toAny` /
## `newAndroidFrameSource` entry points, and substitutes an opaque
## `AndroidRenderer` / `AndroidElement` placeholder on Linux so the
## rest of `isonim-render-serve` compiles cleanly on a Linux CI
## lane.
##
## This is a structural difference from the RS-M5 Cocoa adapter
## (whose `isonim_cocoa/renderer` import compiles on Linux because
## its `{.passL.}` pragmas only kick in at link time). The
## structural difference matches the EX-M6 Android-leaves /
## composition-root scaffold pattern in `isonim-examples`.
##
## ## Capture approach — `View.draw(Canvas)` headless bitmap
##
## RS-M0's back-end capture table commits the Android adapter to
## **headless bitmap via `View.draw(Canvas)` where the `Canvas` wraps
## an `android.graphics.Bitmap`** as the primary capture path, with
## **`adb shell screencap -p` against a running emulator** as the
## documented fallback when the in-process `View.draw` route degrades
## (hardware-accelerated views — e.g. `SurfaceView`, `TextureView` —
## bypass `View.draw` and render directly to a `Surface`).
##
## ### Primary path: View.draw(Canvas) → Bitmap
##
## This is the same recipe Robolectric uses for its screenshot tests,
## so it is well-trodden territory. For the macOS engineer completing
## RS-M6:
##
##   1. The composition root in `isonim-android` (or the test driver)
##      builds the headless `AndroidRenderer` tree and produces a
##      root `android.view.View` instance — i.e. the `ViewHandle`
##      (`int64`) returned by `r.createElement("div")` for the app
##      shell *is* (under the JNI bridge) the result of a
##      `FrameLayout` constructor invocation. See
##      `isonim_android/jni_callbacks.jniCreateView` for the
##      construction path; the real Android lane lives behind
##      `-d:commandBuffer`.
##
##   2. Layout the view: call `View.measure(widthSpec, heightSpec)`
##      with `MeasureSpec.makeMeasureSpec(width, EXACTLY)` /
##      `makeMeasureSpec(height, EXACTLY)` followed by
##      `View.layout(0, 0, width, height)`. Without an explicit
##      measure+layout pass the headless view tree has no concrete
##      bounds and `draw(Canvas)` paints nothing.
##
##   3. Allocate an `android.graphics.Bitmap` via
##      `Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)`
##      (ARGB_8888 is the only format that guarantees a clean
##      mapping to RGBA8888 after a per-pixel channel swizzle — see
##      step 5).
##
##   4. Wrap the bitmap in an `android.graphics.Canvas` via the
##      `new Canvas(bitmap)` constructor, then call
##      `view.draw(canvas)` on the root view. Android walks the view
##      hierarchy and rasterises into the bitmap's backing store.
##
##   5. Extract the pixels: call `Bitmap.getPixels(intArray, offset=0,
##      stride=width, x=0, y=0, width, height)`. The returned `int[]`
##      is ARGB_8888 (Android's internal packed format —
##      `(A << 24) | (R << 16) | (G << 8) | B`). Swizzle into the
##      wire protocol's canonical RGBA8888 byte order:
##
##        for px in pixels:
##          r = (px shr 16) and 0xFF
##          g = (px shr 8) and 0xFF
##          b = px and 0xFF
##          a = (px shr 24) and 0xFF
##          out.add [r, g, b, a]
##
##      The `F` payload (see `packet.nim`) is **canonical RGBA8888
##      byte order**, not Android's native ARGB.
##
##   6. Release the bitmap (`bitmap.recycle()`) to free the native
##      backing store before returning. Return a
##      `Frame(kind: fkFull, flags: FrameFlags(isDiff: false,
##      isVideo: false), width: w, height: h, pixels: pixels)`
##      exactly as the GPUI / Freya / Cocoa adapters do.
##
## ### Real-time strategy
##
## Capture on each `frameLoop` tick — `renderFrame` is called once
## per bridge tick (typically 20–60 Hz). For sufficient FPS on
## heavier trees, pre-allocate the `Bitmap` + `Canvas` once at
## construction time (so the Android runtime doesn't allocate a new
## native bitmap every tick) and reuse them across frames; clear the
## canvas with `canvas.drawColor(0)` between frames. That
## optimisation is explicitly deferred — RS-M6's deliverable is
## *correct* capture, not fastest capture; RS-M3-style diff-region
## encoding on top of the canonical RGBA buffer already wins back
## most of the bandwidth.
##
## ### Documented fallback: adb screencap -p
##
## When the in-process `View.draw(Canvas)` route degrades fidelity
## (the most common case: the demo embeds a `SurfaceView` /
## `TextureView` / `GLSurfaceView`, all of which bypass `View.draw`
## and render directly to a `Surface` via the Hardware Composer),
## promote capture to `adb shell screencap -p /sdcard/frame.png &&
## adb pull /sdcard/frame.png` against a running emulator. That
## yields a PNG of the framebuffer (including hardware-accelerated
## surfaces). Decode the PNG with `nimPNG` / `stb_image` (per
## `feedback_image_decoders_use_libraries`) and emit the RGBA bytes
## as usual. The fidelity trade-off (real GPU compositing vs.
## headless software rasterisation) and the requirement for a
## live emulator are why this is the fallback, not the default.
##
## ## Hand-off — what the macOS M1 engineer must do
##
## See `isonim-render-stream.status.org` § RS-M6 for the canonical
## checklist; abbreviated here for convenience:
##
##   1. Replace this module's `when defined(android)` body —
##      currently a `raise Defect(...)` stub — with the real
##      `View.draw(Canvas)`-driven implementation following the
##      6-step recipe above. The capture entry point lives in
##      `isonim-android`'s JNI bridge (likely a new
##      `jniCaptureFrame(root, width, height): seq[byte]` proc in
##      `jni_callbacks.nim`'s `-d:commandBuffer` lane, mirroring
##      the GPUI / Freya shim pattern).
##   2. Land a real-stack `test_android_adapter_android_only.nim`
##      (the scaffold under `tests/` already wires the Linux-side
##      skip path) asserting captured pixels reflect the rendered
##      Android tree. Reuse the GPUI / Freya / Cocoa assertion
##      shape: drive the EX-M6 task_app demo through the bridge,
##      assert non-empty `Frame.pixels` and at least one
##      channel-distinct pixel per leaf colour. The emulator runs
##      natively on Apple Silicon (Android Studio's
##      `qemu-system-aarch64`-based emulator), so the macOS host
##      is the right place to drive this.
##   3. (Stretch) Wire the `adb screencap` fallback path, gated on
##      a `--androidCapture=screencap` runtime flag or a
##      `-d:androidScreencap` compile-time switch. The shell-out
##      can use `std/osproc.execCmdEx "adb shell screencap -p"`
##      and pipe the PNG through `nimPNG` to RGBA.
##   4. Extend the bridge integration matrix to include Android as
##      the 4th-real adapter (alongside GPUI / Freya / Cocoa).
##   5. Flip the RS-M6 `:status:` from `partial-linux` to
##      `complete`.

import ../frame_source
import ../packet

when defined(android):
  ## Android-target build: pull the real Android renderer + JNI
  ## bridge. `isonim_android/jni_callbacks` raises a hard
  ## `{.error.}` unless either `-d:mockJni` (host-side test shim)
  ## or `-d:commandBuffer` (real emulator JNI bridge) is set, so a
  ## plain `nim c --os:android` invocation also has to provide one
  ## of those compile-time switches.
  import isonim_android/renderer
  export renderer  ## re-export so `AndroidRenderer` / `AndroidElement`
                   ## are visible at the adapter's call sites.

else:
  ## Linux / non-Android hosts: substitute opaque placeholders for
  ## `AndroidRenderer` / `AndroidElement` so the surface types
  ## below compile without importing `isonim_android/renderer`
  ## (which would trip `jni_callbacks`'s hard `{.error.}`). The
  ## Linux scaffold's `renderFrame` returns a uniform-grey RGBA
  ## frame and never inspects either value.

  type
    AndroidRenderer* = object
      ## Linux-scaffold placeholder. The real `AndroidRenderer`
      ## (an `object` wrapper around the JNI handle table) lives
      ## in `isonim_android/renderer`; we mirror its shape (empty
      ## object) so `newAndroidFrameSource` accepts the same call
      ## site on both platforms.
    AndroidElement* = int64
      ## Linux-scaffold placeholder. On Android,
      ## `AndroidElement = ViewHandle = int64`; this alias matches
      ## byte-for-byte so the null-check idiom (`target == 0`) used
      ## by the input adapter stays portable.

type
  AndroidCaptureMode* = enum
    ## Primary vs. fallback path selector. `acmHeadless` is the RS-M0
    ## spec-blessed default (in-process `View.draw(Canvas)` into a
    ## `Bitmap`); `acmScreencap` is the documented fallback for cases
    ## where hardware-accelerated views (`SurfaceView`, `TextureView`,
    ## `GLSurfaceView`) bypass `View.draw` and render directly to a
    ## `Surface`.
    acmHeadless    ## View.draw(Canvas) into Bitmap (Robolectric path)
    acmScreencap   ## adb shell screencap -p (emulator fallback)

  AndroidFrameSource* = ref object
    ## Mirrors `GpuiFrameSource` / `FreyaFrameSource` /
    ## `CocoaFrameSource`. Carries enough context for either capture
    ## path — `deviceSerial` is only consulted when
    ## `mode == acmScreencap` (it selects the target emulator /
    ## device for `adb -s <serial> shell screencap`), otherwise the
    ## root `AndroidElement` is used as-is via `View.draw(Canvas)`.
    renderer*: AndroidRenderer
    root*: AndroidElement
    width*, height*: int
    mode*: AndroidCaptureMode
    deviceSerial*: string  ## ignored unless mode == acmScreencap

when defined(android):
  ## Android implementation — the macOS engineer fills this in per
  ## the 6-step recipe in the module docstring. Today it raises so
  ## the scaffold is honest about being incomplete; the test
  ## `test_android_adapter_android_only.nim` skips with a docstring
  ## pointer on Linux and the macOS engineer flips it on by
  ## implementing the body.

  proc renderFrame*(src: AndroidFrameSource): Frame =
    ## **Android host (emulator)**: replace this body with the
    ## `View.draw(Canvas)`-driven capture path documented in the
    ## module header. Until then, raise so the adapter signals
    ## "scaffold present, implementation pending" rather than
    ## silently returning placeholder pixels on Android.
    raise newException(Defect,
      "RS-M6 Android-host implementation pending — see " &
      "src/isonim_render_serve/adapters/android_adapter.nim module " &
      "docstring for the View.draw(Canvas) → Bitmap recipe.")

  proc close*(src: AndroidFrameSource) =
    ## No-op: the renderer + root are owned by the caller (the
    ## composition root that built the tree). The renderer's tree
    ## is reset via `resetRenderer()` by the demo when it tears
    ## down.
    discard

else:
  ## Linux / non-Android hosts: ship placeholder bodies so the rest
  ## of `isonim-render-serve` compiles. Calling `renderFrame` returns
  ## a uniform-grey frame matching `Frame` invariants from RS-M0;
  ## this keeps unit tests that import the adapter module
  ## compilable and the bridge's frame-loop invariants intact, while
  ## making it obvious in any visual inspection that no Android
  ## work happened.

  const placeholderPixel = [0x18'u8, 0x18'u8, 0x18'u8, 0xFF'u8]

  proc renderFrame*(src: AndroidFrameSource): Frame =
    ## Build a uniform dark-grey RGBA8888 frame with the configured
    ## dimensions. The placeholder lets unit tests that import the
    ## adapter on a non-Android host receive a well-formed `Frame`
    ## (so they exercise packet-codec invariants) without claiming
    ## any Android-runtime work happened.
    let w = src.width
    let h = src.height
    var pixels = newSeq[byte](w * h * 4)
    for i in 0 ..< (w * h):
      let off = i * 4
      pixels[off]     = placeholderPixel[0]
      pixels[off + 1] = placeholderPixel[1]
      pixels[off + 2] = placeholderPixel[2]
      pixels[off + 3] = placeholderPixel[3]
    result = Frame(kind: fkFull,
                   flags: FrameFlags(isDiff: false, isVideo: false),
                   width: w, height: h, pixels: pixels)

  proc close*(src: AndroidFrameSource) =
    discard

# ---------------------------------------------------------------------------
# Constructors — compile on both platforms so the bridge / tests can
# instantiate an AndroidFrameSource value even on Linux.
# ---------------------------------------------------------------------------

proc newAndroidFrameSource*(renderer: AndroidRenderer; root: AndroidElement;
                            width = 800; height = 600;
                            mode: AndroidCaptureMode = acmHeadless;
                            deviceSerial = ""): AndroidFrameSource =
  ## Build an `AndroidFrameSource`. The default 800×600 matches the
  ## canonical window size used by the EX-M6 Android task_app demo
  ## (`task_app/main_android.nim`). `mode` defaults to the RS-M0
  ## primary path; pass `acmScreencap` plus a valid `deviceSerial`
  ## to drive the documented `adb screencap` fallback (Android host
  ## only — Linux scaffold ignores the mode and returns placeholder
  ## pixels either way).
  AndroidFrameSource(renderer: renderer, root: root,
                     width: width, height: height,
                     mode: mode, deviceSerial: deviceSerial)

proc toAny*(src: AndroidFrameSource): AnyFrameSource =
  ## Wrap the Android source in the bridge's polymorphic
  ## `AnyFrameSource` so it can be dropped into
  ## `BridgeConfig.frameSource` alongside the stub, GPUI, Freya and
  ## Cocoa adapters.
  let captured = src
  newAnyFrameSource(src.width, src.height,
    renderFrameImpl = proc(): Frame {.gcsafe.} =
      {.cast(gcsafe).}: captured.renderFrame(),
    closeImpl = proc() {.gcsafe.} =
      {.cast(gcsafe).}: captured.close())
