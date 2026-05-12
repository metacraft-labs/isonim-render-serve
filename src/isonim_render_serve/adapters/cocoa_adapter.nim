## RS-M5: Cocoa streaming adapter (real AppKit capture on macOS;
## Linux-side compiles to placeholder-pixel stubs).
##
## Wraps a `CocoaRenderer` + root `CocoaElement` into the bridge's
## `AnyFrameSource` so the WebSocket bridge can stream a headless AppKit
## tree to a browser canvas. Mirrors the shape of the GPUI (RS-M2) and
## Freya (RS-M4) adapters so the bridge consumes any of the three real
## back-ends identically.
##
## ## Status — complete (macOS); Linux compiles as placeholder
##
## On macOS the body uses real AppKit: it delegates to
## `isonim_cocoa/appkit/capture.captureViewRgba`, which drives the
## `bitmapImageRepForCachingDisplayInRect:` /
## `cacheDisplayInRect:toBitmapImageRep:` recipe documented below and
## returns a canonical RGBA8888 row-major byte buffer.
##
## The whole AppKit-touching capture call is still gated
## `when defined(macosx)` because `isonim_cocoa/renderer` transitively
## imports `isonim_cocoa/objc_runtime`, `isonim_cocoa/foundation` and
## the `isonim_cocoa/appkit/*` wrappers. Those modules use
## `{.passL: "-lobjc -framework Foundation -framework CoreGraphics".}`
## plus inline `objc_msgSend` C blocks, none of which the Linux C
## compiler can lower or link against. On Linux this module therefore
## exposes only the *types* (`CocoaFrameSource`, `CocoaCaptureMode`)
## plus a `renderFrame` entry point that returns a uniform-grey RGBA
## buffer so the rest of `isonim-render-serve` compiles cleanly on a
## Linux CI lane.
##
## ## Capture approach — AppKit headless `bitmapImageRepForCachingDisplayInRect`
##
## RS-M0's back-end capture table commits the Cocoa adapter to
## **headless bitmap via `NSView` → `NSImage` via
## `bitmapImageRepForCachingDisplayInRect`** as the primary capture
## path, with **window screencap via `CGWindowListCreateImage`** as the
## documented fallback when AppKit-headless degrades (CoreImage filter
## effects, certain blur modes, etc.).
##
## ### Primary path: NSView → NSBitmapImageRep
##
## For the macOS engineer completing RS-M5:
##
##   1. The composition root in `isonim-cocoa` (or the test driver)
##      builds the headless `CocoaRenderer` tree and produces a root
##      `NSView` instance — i.e. the `Id` handle returned by
##      `r.createElement("div")` for the app shell *is* (under the
##      hood) an `NSView` pointer (see `objc_runtime.Id = distinct
##      pointer` and `renderer.createNativeView`).
##
##   2. Call AppKit's `-[NSView bitmapImageRepForCachingDisplayInRect:]`
##      on the root view passing the view's `bounds` to obtain an
##      `NSBitmapImageRep` instance. This is the documented AppKit
##      offscreen-bitmap API; it allocates a backing bitmap large
##      enough to hold the view's full content at the view's native
##      coordinate scale.
##
##   3. Call `-[NSView cacheDisplayInRect:toBitmapImageRep:]` on the
##      root view with the bounds rect and the bitmap rep produced in
##      step 2. AppKit walks the view hierarchy and renders into the
##      bitmap rep's backing store (the "caching display" idiom).
##
##   4. Call `-[NSBitmapImageRep bitmapData]` to obtain a `unsigned
##      char *` pointing at the raw pixel buffer. Read the rep's
##      `pixelsWide`, `pixelsHigh`, `bytesPerRow`, `samplesPerPixel`,
##      `bitsPerSample`, `colorSpaceName` properties to confirm the
##      pixel format. Typical configuration when the rep is allocated
##      by `bitmapImageRepForCachingDisplayInRect:` is:
##
##        - colorSpaceName = `NSCalibratedRGBColorSpace` (or
##          `NSDeviceRGBColorSpace` on retina hosts)
##        - bitsPerSample = 8
##        - samplesPerPixel = 4 (RGBA) on most modern OS X versions
##        - bytesPerRow may exceed `width * 4` for alignment — copy
##          row-by-row, not by a single `memcpy(width*height*4)`.
##
##   5. Copy each row of the bitmap into the `Frame.pixels` buffer (a
##      Nim `seq[byte]`) as RGBA8888 row-major. If AppKit returns the
##      bytes in a different channel order (e.g. ARGB on some
##      configurations — confirm with
##      `[NSBitmapImageRep bitmapFormat]`), swizzle into RGBA byte
##      order during the row copy. The wire protocol's `F` payload
##      (see `packet.nim`) is **canonical RGBA8888 byte order**, not
##      whatever AppKit happened to allocate.
##
##   6. Return a `Frame(kind: fkFull, flags: FrameFlags(isDiff: false,
##      isVideo: false), width: w, height: h, pixels: pixels)` exactly
##      as the GPUI/Freya adapters do.
##
## ### Real-time strategy
##
## Capture on each `frameLoop` tick — `renderFrame` is called once per
## bridge tick (typically 20–60 Hz). For sufficient FPS on heavier
## views, pre-build the `NSBitmapImageRep` once at construction time
## (so AppKit doesn't re-allocate the backing store every tick) and
## refresh it on dirty signals from the VM. That optimisation is
## explicitly deferred — RS-M5's deliverable is *correct* capture, not
## fastest capture; RS-M3-style diff-region encoding on top of the
## canonical RGBA buffer already wins back most of the bandwidth.
##
## ### Documented fallback: CGWindowListCreateImage
##
## When AppKit headless mode degrades fidelity (CoreImage filters,
## certain `CALayer` blur effects, hardware-accelerated `NSView`
## subclasses that bypass `cacheDisplayInRect:`), promote the back-end
## to a real on-screen window and capture via
## `CGWindowListCreateImage(CGRectInfinite, kCGWindowListOptionIncludingWindow,
## windowID, kCGWindowImageBoundsIgnoreFraming)`. That call returns a
## `CGImageRef` whose `CGImageGetDataProvider` yields the raw RGBA bytes.
## The fidelity trade-off (real GPU compositing vs. AppKit's
## software-rasterised offscreen path) and the requirement for an
## on-screen window are why this is the fallback, not the default.
##
## ## Hand-off — what the macOS M1 engineer must do
##
## See `isonim-render-stream.status.org` § RS-M5 for the canonical
## checklist; abbreviated here for convenience:
##
##   1. Replace this module's `when defined(macosx)` body — currently
##      a `raise Defect(...)` stub — with the real
##      `bitmapImageRepForCachingDisplayInRect`-driven implementation
##      following the 6-step recipe above.
##   2. Land a real-stack `test_cocoa_adapter_macos_only.nim` (the
##      scaffold under `tests/` already wires the Linux-side skip
##      path) asserting captured pixels reflect the rendered Cocoa
##      tree. Reuse the GPUI/Freya assertion shape: drive the
##      EX-M5 task_app demo through the bridge, assert non-empty
##      `Frame.pixels` and at least one channel-distinct pixel per
##      leaf colour.
##   3. (Stretch) Wire the `CGWindowListCreateImage` fallback path,
##      gated on a `--cocoaCapture=window` runtime flag or a
##      `-d:cocoaWindowCapture` compile-time switch.
##   4. Extend the bridge integration matrix to include Cocoa as the
##      3rd-real adapter (alongside GPUI/Freya).
##   5. Flip the RS-M5 `:status:` from `partial-linux` to `complete`.

import isonim_cocoa/renderer

when defined(macosx):
  import isonim_cocoa/appkit/capture as cocoa_capture

import ../frame_source
import ../packet

type
  CocoaCaptureMode* = enum
    ## Primary vs. fallback path selector. `ccmHeadless` is the RS-M0
    ## spec-blessed default; `ccmWindowScreencap` is the documented
    ## fallback for cases where AppKit headless degrades fidelity.
    ccmHeadless          ## bitmapImageRepForCachingDisplayInRect
    ccmWindowScreencap   ## CGWindowListCreateImage (on-screen fallback)

  CocoaFrameSource* = ref object
    ## Mirrors `GpuiFrameSource` / `FreyaFrameSource`. Carries enough
    ## context for either capture path — `windowId` is only consulted
    ## when `mode == ccmWindowScreencap`, otherwise the root NSView is
    ## used as-is.
    renderer*: CocoaRenderer
    root*: CocoaElement
    width*, height*: int
    mode*: CocoaCaptureMode
    windowId*: uint32  ## ignored unless mode == ccmWindowScreencap

when defined(macosx):
  ## macOS implementation — real `bitmapImageRepForCachingDisplayInRect`
  ## capture path. Delegates to `isonim_cocoa/appkit/capture`, which
  ## wraps the 6-step recipe documented in the module header
  ## (set frame, lay out subtree, allocate `NSBitmapImageRep`, drive
  ## `cacheDisplayInRect:toBitmapImageRep:`, inspect `bitmapFormat`,
  ## row-by-row swizzle into canonical RGBA8888) in an ObjC `.m`
  ## helper (`isonim_cocoa/testing/capture_rgba.m`).

  proc renderFrame*(src: CocoaFrameSource): Frame =
    ## Capture the rendered Cocoa tree rooted at `src.root` into an
    ## RGBA8888 row-major frame of `src.width × src.height` pixels.
    ##
    ## The capture is done entirely offscreen via AppKit's
    ## `NSView bitmapImageRepForCachingDisplayInRect:` API — no
    ## NSWindow / event loop required. The view's frame is forced to
    ## `(0, 0, width, height)` before the bitmap is drawn so the
    ## requested wire dimensions match the captured raster regardless
    ## of the view's natural size; on retina hosts the helper
    ## nearest-neighbor downscales the (point ≠ pixel) rep so the
    ## payload length still equals `width * height * 4`.
    ##
    ## The `ccmWindowScreencap` capture mode is documented in the
    ## module header as a fallback for AppKit headless degradation;
    ## RS-M5 ships only the primary `ccmHeadless` path. A future
    ## promotion will branch here on `src.mode` once a real demo hits
    ## the AppKit-headless fidelity gap.
    let w = src.width
    let h = src.height
    var pixels = cocoa_capture.captureViewRgba(Id(src.root), w, h)
    if pixels.len != w * h * 4:
      # The capture helper returns an empty seq on AppKit error
      # (nil view / unsupported pixel format). Treat that as a
      # hard failure — the bridge expects a wire-valid F packet.
      raise newException(Defect,
        "RS-M5 Cocoa capture failed: bitmapImageRepForCachingDisplayInRect " &
        "returned a buffer of " & $pixels.len & " bytes; expected " &
        $(w * h * 4) & ". Check that src.root is a live NSView and that " &
        "AppKit produced an 8-bit bitmap rep.")
    result = Frame(kind: fkFull,
                   flags: FrameFlags(isDiff: false, isVideo: false),
                   width: w, height: h, pixels: pixels)

  proc close*(src: CocoaFrameSource) =
    ## No-op: the renderer + root are owned by the caller (the
    ## composition root that built the tree). The renderer's tree is
    ## reset via `resetTree()` by the demo when it tears down.
    discard

else:
  ## Linux / non-macOS hosts: ship placeholder bodies so the rest of
  ## `isonim-render-serve` compiles. Calling `renderFrame` returns a
  ## uniform-grey frame matching `Frame` invariants from RS-M0; this
  ## keeps unit tests that import the adapter module compilable and
  ## the bridge's frame-loop invariants intact, while making it
  ## obvious in any visual inspection that no AppKit work happened.

  const placeholderPixel = [0x18'u8, 0x18'u8, 0x18'u8, 0xFF'u8]

  proc renderFrame*(src: CocoaFrameSource): Frame =
    ## Build a uniform dark-grey RGBA8888 frame with the configured
    ## dimensions. The placeholder lets unit tests that import the
    ## adapter on a non-macOS host receive a well-formed `Frame` (so
    ## they exercise packet-codec invariants) without claiming any
    ## AppKit work happened.
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

  proc close*(src: CocoaFrameSource) =
    discard

# ---------------------------------------------------------------------------
# Constructors — compile on both platforms so the bridge / tests can
# instantiate a CocoaFrameSource value even on Linux.
# ---------------------------------------------------------------------------

proc newCocoaFrameSource*(renderer: CocoaRenderer; root: CocoaElement;
                          width = 800; height = 600;
                          mode: CocoaCaptureMode = ccmHeadless;
                          windowId: uint32 = 0): CocoaFrameSource =
  ## Build a `CocoaFrameSource`. The default 800×600 matches the
  ## canonical window size used by the EX-M5 Cocoa task_app demo
  ## (`task_app/main_cocoa.nim`). `mode` defaults to the RS-M0
  ## primary path; pass `ccmWindowScreencap` plus a valid
  ## `windowId` to drive the documented `CGWindowListCreateImage`
  ## fallback (macOS host only — Linux scaffold ignores the mode
  ## and returns placeholder pixels either way).
  CocoaFrameSource(renderer: renderer, root: root,
                   width: width, height: height,
                   mode: mode, windowId: windowId)

proc toAny*(src: CocoaFrameSource): AnyFrameSource =
  ## Wrap the Cocoa source in the bridge's polymorphic `AnyFrameSource`
  ## so it can be dropped into `BridgeConfig.frameSource` alongside the
  ## stub, GPUI and Freya adapters.
  let captured = src
  newAnyFrameSource(src.width, src.height,
    renderFrameImpl = proc(): Frame {.gcsafe.} =
      {.cast(gcsafe).}: captured.renderFrame(),
    closeImpl = proc() {.gcsafe.} =
      {.cast(gcsafe).}: captured.close())
