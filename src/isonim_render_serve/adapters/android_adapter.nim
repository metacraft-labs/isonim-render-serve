## RS-M6: Android streaming adapter (real-device capture on Android;
## Linux-side compiles to placeholder-pixel stubs).
##
## Wraps an `AndroidRenderer` + root `AndroidElement` into the bridge's
## `AnyFrameSource` so the WebSocket bridge can stream a headless
## Android view tree to a browser canvas. Mirrors the shape of the
## GPUI (RS-M2), Freya (RS-M4) and Cocoa (RS-M5) adapters so the
## bridge consumes any of the four real back-ends identically.
##
## ## Status — complete (Android device); Linux compiles as placeholder
##
## On a real Android device the `-d:android -d:commandBuffer` build
## drives the real `View.draw(Canvas)` -> `Bitmap` -> ARGB->RGBA
## capture path: `renderFrame` delegates to
## `isonim_android/capture.captureViewToRgba`, which JNI-calls the
## Kotlin static
## `com.metacraft.isonim.examples.CaptureHelper.captureActiveRootToRgba(width,
## height)`. The Kotlin helper performs the 6-step recipe documented
## below on the UI thread, returning canonical RGBA8888 row-major
## bytes that the adapter wraps in a `Frame`.
##
## Acceptance gate. The binding RS-M6 acceptance gate is the Espresso
## instrumented test at
## `isonim-android/app/src/androidTest/kotlin/com/metacraft/isonim/
## examples/AdapterCaptureTest.kt`. It launches the live
## `nimexamples` `MainActivity`, drives the scripted task_app
## scenario, and asserts the captured bytes are well-formed (length
## = width*height*4, alpha opaque, contains the task_app's actual
## colours not just the Linux placeholder grey), and that the
## captured bytes change between scripted mutations. No mocks, no
## synthetic raster fallback.
##
## The whole Android-runtime-touching body is still gated
## `when defined(android)` because `isonim_android/jni_callbacks`
## raises a hard `{.error.}` unless either `-d:mockJni` (host-side
## test shim) or `-d:commandBuffer` (real Android JNI bridge) is
## set — both `AndroidRenderer.fireEvent` and the real capture path
## drive `android.view.View.draw(android.graphics.Canvas)` into an
## `android.graphics.Bitmap`, both Java classes that live inside
## the Android runtime (ART), reachable only via JNI from a process
## running on an emulator or device. On a plain Linux host (no
## `-d:android`, no `-d:mockJni`) we cannot even *import*
## `isonim_android/renderer` because the `{.error.}` fires at
## semantic-checking time. So the Linux-scaffold path keeps the
## entire renderer-touching block under `when defined(android)`,
## exposes only the surface types (`AndroidFrameSource`,
## `AndroidCaptureMode`) plus a placeholder `renderFrame` that
## emits uniform-grey pixels (the same byte pattern the Linux
## scaffold has always emitted), and substitutes an opaque
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
## ## Acceptance gate
##
## RS-M6 lands as `complete` once the Espresso instrumented test at
## `isonim-android/app/src/androidTest/kotlin/com/metacraft/isonim/
## examples/AdapterCaptureTest.kt` passes on a real device:
##
##   cd isonim-android
##   nix develop --command ./gradlew :app:connectedNimexamplesDebugAndroidTest
##
## That test gate exercises every link in the chain: ART boot, the
## `nimexamples` flavor APK, the EX-M6 `MainActivity` shell, the
## materialised Nim view tree, the new Kotlin `CaptureHelper`, the
## Nim adapter's JNI entry `Java_*_TaskAppBridge_captureRootViewToRgba`,
## the `currentJniEnv` threadvar hand-off, and the
## `View.draw(Canvas)` / `Bitmap` / ARGB->RGBA recipe inside ART.
##
## The matching cross-compile gate (`tests/test_android_adapter_compile.nim`)
## still drives `nim check --os:android -d:mockJni` on the host so the
## Nim type surface stays consistent on the Linux CI lane. The Nim
## Linux test scaffold `tests/test_android_adapter_android_only.nim`
## that previously lived here has been deleted; running a Nim test
## binary inside ART is non-trivial ceremony when the Kotlin
## instrumented test already drives the same Nim adapter code through
## JNI.
##
## ### Stretch (deferred)
##
##   * `adb shell screencap -p` fallback path for the `acmScreencap`
##     capture mode. Gated on a `--androidCapture=screencap` runtime
##     flag or a `-d:androidScreencap` compile-time switch. The
##     shell-out can use `std/osproc.execCmdEx` and pipe the PNG
##     through `nimPNG` to RGBA. RS-M6 ships only the primary
##     `acmHeadless` path.
##   * Extend the bridge integration matrix
##     (`tests/test_*_streams_task_app.nim`) to include Android as
##     the 4th real adapter (alongside GPUI / Freya / Cocoa). The
##     existing Espresso test already proves the adapter's
##     `renderFrame` produces live, mutation-sensitive pixels; the
##     WS-streaming variant is mechanical follow-up.

import ../frame_source
import ../packet

when defined(android) or defined(mockJni):
  import ../element_tree_attrs

when defined(android) or defined(mockJni):
  ## Android-target build OR host-side `-d:mockJni` lane: pull the real
  ## Android renderer + JNI bridge. `isonim_android/jni_callbacks`
  ## raises a hard `{.error.}` unless either `-d:mockJni` (host-side
  ## test shim) or `-d:commandBuffer` (real emulator JNI bridge) is
  ## set, so a plain `nim c --os:android` invocation also has to
  ## provide one of those compile-time switches.
  ##
  ## RS-M11c expanded the gate from `defined(android)` to
  ## `defined(android) or defined(mockJni)` so the host-side launcher
  ## (`editor/backends/android.nim`) can build an in-process
  ## `AndroidRenderer` tree under `-d:mockJni` and feed it to the
  ## element-tree manifest builder while keeping the F-packet stream
  ## driven by `adb exec-out screencap` against a real device.
  import isonim_android/renderer
  export renderer  ## re-export so `AndroidRenderer` / `AndroidElement`
                   ## are visible at the adapter's call sites.

  when defined(commandBuffer):
    ## On the real Android device the `-d:commandBuffer` lane is
    ## active and the capture path JNI-calls back into Kotlin's
    ## `com.metacraft.isonim.examples.CaptureHelper`. See
    ## `isonim_android/capture` for the full design and the
    ## `currentJniEnv` threadvar contract.
    import isonim_android/capture as android_capture
    export android_capture

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

when defined(android) or defined(mockJni):
  ## Android implementation — drives the real `View.draw(Canvas)` ->
  ## `Bitmap` -> ARGB->RGBA capture path from inside the Android
  ## Runtime. Delegates to `isonim_android/capture.captureViewToRgba`
  ## under the `-d:commandBuffer` lane; that helper JNI-calls the
  ## Kotlin static `com.metacraft.isonim.examples.CaptureHelper`
  ## .captureActiveRootToRgba(width, height)` which performs the
  ## 6-step recipe documented in the module header on the UI thread.
  ##
  ## Under `-d:mockJni` (host-side test shim, also used by the RS-M11c
  ## launcher to build the in-process tree for the manifest builder)
  ## the `View.draw(Canvas)` path has no runtime to drive, so the body
  ## falls back to the same placeholder pixels the Linux stub returns.
  ## The launcher does not invoke this `renderFrame` anyway — pixels
  ## come from `adb exec-out screencap`.
  ##
  ## The `currentJniEnv` threadvar in `isonim_android/capture` must
  ## be set by the JNI entry that drives this `renderFrame` call
  ## (typically `Java_*_TaskAppBridge_captureRootViewToRgba` in
  ## `isonim-examples/task_app/main_android.nim`'s
  ## `-d:androidGui` block). The bridge integration on a live device
  ## arranges this by routing every capture through that JNI
  ## namespace; the acceptance test exercises the same path.
  ##
  ## The `-d:mockJni` host-test lane has no Android runtime to drive
  ## `View.draw(Canvas)` against, so it falls back to a single-pixel
  ## placeholder consistent with the Linux-host stub. Real-device
  ## capture is the binding RS-M6 acceptance gate and is exercised
  ## by `isonim-android/app/src/androidTest/kotlin/com/metacraft/
  ## isonim/examples/AdapterCaptureTest.kt`.

  proc renderFrame*(src: AndroidFrameSource): Frame =
    ## Capture the rendered Android view tree rooted at `src.root`
    ## into an RGBA8888 row-major frame of `src.width × src.height`
    ## pixels via the 6-step `View.draw(Canvas)` recipe.
    ##
    ## The recipe runs entirely inside the Android Runtime: the
    ## Kotlin helper allocates `Bitmap.createBitmap(width, height,
    ## ARGB_8888)`, wraps it with `Canvas(bitmap)`, invokes
    ## `view.draw(canvas)` against the active root, reads pixels
    ## via `bitmap.getPixels`, swizzles ARGB_8888 -> RGBA8888 byte
    ## order, recycles the bitmap, and returns the bytes through
    ## JNI to this proc.
    ##
    ## The `acmScreencap` capture mode is documented in the module
    ## header as a fallback for cases where hardware-accelerated
    ## views bypass `View.draw`. RS-M6 ships only the primary
    ## `acmHeadless` path. A future promotion will branch here on
    ## `src.mode` once a real demo hits the
    ## `View.draw(Canvas)` fidelity gap.
    let w = src.width
    let h = src.height
    when defined(commandBuffer):
      var pixels = android_capture.captureViewToRgba(w, h)
      if pixels.len != w * h * 4:
        # The capture helper returns an empty seq on JNI error
        # (no active root, exception inside CaptureHelper, dim
        # mismatch). Treat that as a hard failure — the bridge
        # expects a wire-valid F packet.
        raise newException(Defect,
          "RS-M6 Android capture failed: CaptureHelper.captureActiveRootToRgba " &
          "returned a buffer of " & $pixels.len & " bytes; expected " &
          $(w * h * 4) & ". Check that CaptureHelper.activeRootView is non-null " &
          "(MainActivity.rebuildTree should publish it) and that no JNI " &
          "exception was thrown during the View.draw(Canvas) pass.")
      result = Frame(kind: fkFull,
                     flags: FrameFlags(isDiff: false, isVideo: false),
                     width: w, height: h, pixels: pixels)
    else:
      # `-d:mockJni` lane (host-side tests): no Android Runtime to
      # drive `View.draw(Canvas)` against. Ship a placeholder frame
      # matching the Linux-scaffold pixel pattern so the codec
      # invariants still hold.
      var pixels = newSeq[byte](w * h * 4)
      for i in 0 ..< (w * h):
        let off = i * 4
        pixels[off]     = 0x18'u8
        pixels[off + 1] = 0x18'u8
        pixels[off + 2] = 0x18'u8
        pixels[off + 3] = 0xFF'u8
      result = Frame(kind: fkFull,
                     flags: FrameFlags(isDiff: false, isVideo: false),
                     width: w, height: h, pixels: pixels)

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

# ---------------------------------------------------------------------------
# RS-M11c: element-tree manifest builder
# ---------------------------------------------------------------------------
##
## ``buildAndroidElementTreeManifest`` walks the headless
## ``AndroidElement`` tree via the renderer's own DFS helpers
## (``r.childCount`` / ``r.nthChild`` / ``r.getAttribute``),
## synthesises a vertical-stack layout — the same heuristic GPUI /
## Freya / Cocoa use in their adapters — and emits one ``ElementEntry``
## per node carrying a non-empty ``ComponentPathAttr`` annotation.
##
## Gating: the builder is only available when the renderer can be
## imported (``-d:android`` for a real-device build, or ``-d:mockJni``
## for host-side test / RS-M11c launcher use). On a plain Linux host
## without either flag, `isonim_android/renderer` cannot compile (the
## `{.error.}` in `jni_callbacks` fires), so we cannot expose a
## meaningful manifest builder there. The launcher
## (`editor/backends/android.nim`) provides `-d:mockJni` at build
## time; tests `nim c --define:mockJni`.

type
  LayoutRect* = object
    ## Per-node layout entry. Mirror of the GPUI / Freya / Cocoa
    ## adapter's ``LayoutRect`` shape.
    node*: AndroidElement
    x*, y*, w*, h*: int
    depth*: int
    tag*, label*: string

when defined(android) or defined(mockJni):

  proc walkLayout(r: AndroidRenderer; node: AndroidElement;
                  x, y, w, h: int;
                  rects: var seq[LayoutRect]; depth = 0;
                  maxDepth = 8) =
    ## DFS that produces one ``LayoutRect`` per visited element.
    if node == 0 or w <= 0 or h <= 0: return
    if depth > maxDepth: return
    let cls = r.getAttribute(node, "class")
    let txt = r.textContent(node)
    rects.add LayoutRect(node: node, x: x, y: y, w: w, h: h,
                         depth: depth, tag: cls, label: txt & "|" & cls)
    let count = r.childCount(node)
    if count == 0: return
    let headerBand = min(12, max(0, h div 4))
    let bodyY = y + headerBand
    let bodyH = h - headerBand
    if bodyH <= 0: return
    let perChild = max(1, bodyH div count)
    var cy = bodyY
    for i in 0 ..< count:
      let child = r.nthChild(node, i)
      if child == 0: continue
      let ch =
        if i == count - 1: bodyY + bodyH - cy
        else: perChild
      walkLayout(r, child, x + 4, cy, w - 8, ch, rects, depth + 1, maxDepth)
      cy += ch

  proc buildLayoutRects*(r: AndroidRenderer; root: AndroidElement;
                         width, height: int): seq[LayoutRect] =
    ## Public layout pass.
    result = @[]
    if root == 0 or width <= 0 or height <= 0: return
    walkLayout(r, root, 0, 0, width, height, result)

  proc hitTestPath*(r: AndroidRenderer; root: AndroidElement;
                    width, height: int;
                    x, y: int): seq[AndroidElement] =
    ## FUH-M2. Mirror of the GPUI / Freya / Cocoa ``hitTestPath`` —
    ## resolves a coordinate to an ordered chain of shadow-tree nodes
    ## that contain the point ``(x, y)`` (deepest first). See
    ## ``gpui_adapter.hitTestPath`` for the rationale; the walk-up
    ## dispatch contract is identical.
    result = @[]
    if root == 0 or width <= 0 or height <= 0: return
    let rects = buildLayoutRects(r, root, width, height)
    for i in countdown(rects.len - 1, 0):
      let lr = rects[i]
      if x >= lr.x and x < lr.x + lr.w and y >= lr.y and y < lr.y + lr.h:
        result.add lr.node

  proc buildAndroidElementTreeManifest*(root: AndroidElement;
                                        width, height: int;
                                        frameSeq: int = 0):
                                       ElementTreeManifest =
    ## Build a fresh manifest from the current state of the Android
    ## tree rooted at ``root``. Idempotent: same tree → same manifest.
    ##
    ## Under ``-d:mockJni`` the renderer's ``viewTree`` table holds the
    ## walkable tree; under ``-d:commandBuffer`` (real device) the tree
    ## lives in ART and ``childCount`` / ``nthChild`` return 0 — that's
    ## the documented host-side trade-off. The RS-M11c launcher pairs
    ## ``-d:mockJni`` (for the manifest tree) with the
    ## ``AdbScreencapFrameSource`` (for real-device pixels).
    result = ElementTreeManifest(
      frameSeq: frameSeq,
      surfaceWidth: width,
      surfaceHeight: height,
      elements: @[])
    if root == 0 or width <= 0 or height <= 0: return
    let r = AndroidRenderer()
    let layoutRects = buildLayoutRects(r, root, width, height)
    for lr in layoutRects:
      let path = r.getAttribute(lr.node, ComponentPathAttr)
      if path.len == 0: continue
      let kind = r.getAttribute(lr.node, ElementKindAttr)
      result.elements.add ElementEntry(
        id: path,
        componentPath: path,
        kind: kind,
        bounds: ElementBounds(x: lr.x, y: lr.y, w: lr.w, h: lr.h))
