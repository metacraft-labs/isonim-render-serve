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
  import isonim_cocoa/appkit/autolayout as cocoa_autolayout
  import isonim_cocoa/appkit/views as cocoa_views
  import isonim_cocoa/objc_runtime as cocoa_objc

  # The macOS adapter body uses inline `{.emit:}` blocks (for the
  # NSColor → CGColor → setBackgroundColor: dance below) that
  # reference ``id``, ``SEL`` and ``objc_msgSend`` / ``sel_registerName``
  # directly. Nim doesn't auto-include the AppKit / ObjC headers in
  # the generated C file unless an emit-using proc forces it, so we
  # add the include explicitly here. Matches the analogous module-
  # level emit in ``isonim_cocoa/objc_runtime``.
  {.emit: """
#include <CoreGraphics/CGGeometry.h>
#include <objc/message.h>
""".}

import ../frame_source
import ../packet
import ../element_tree_attrs

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

  # -----------------------------------------------------------------
  # Layout pass (M-EVP-14 fix)
  # -----------------------------------------------------------------
  ##
  ## The IsoNim leaves wired through `CocoaRenderer` never call
  ## `setFrame:` on the child NSViews, and the renderer itself only
  ## emits AutoLayout constraints when the leaves set explicit
  ## `width` / `height` styles (which the task_app / settings_app
  ## leaves currently don't). The result: every NSView in the demo
  ## tree comes up at the default ``CGRectZero`` origin / size,
  ## ``cacheDisplayInRect:`` faithfully renders a 0x0 region for
  ## each child, and the captured bitmap stays mostly empty (the
  ## RGBA buffer is left as the calloc-zeroed ``(0,0,0,0)`` AppKit
  ## handed back).
  ##
  ## Until the leaves grow explicit per-platform layout — or the
  ## renderer learns to install AutoLayout constraints from the
  ## shared view template — the adapter takes the same
  ## vertical-stack heuristic ``buildLayoutRects`` already uses for
  ## the element-tree manifest and pushes those rects down onto the
  ## live NSViews via ``setFrame:``. Containers also get a layer-
  ## backed background colour keyed to depth, so the headless
  ## bitmap actually carries non-zero RGB and the editor's preview
  ## canvas reflects the rendered demo instead of a black void.

  proc setLayerBackgroundColor(view: cocoa_objc.Id;
                                r, g, b, a: cdouble) =
    ## Force ``view.wantsLayer = YES`` and stamp the layer's
    ## ``backgroundColor`` with the requested sRGBA tuple. The
    ## ``CocoaRenderer``'s ``applyStyle`` path normally does this on
    ## demand when a leaf sets ``background-color``; the layout pass
    ## below calls this directly for every container so an empty-
    ## style demo still produces opaque pixels.
    cocoa_views.setWantsLayer(view, true)
    {.emit: """
    id nsColor = ((id(*)(id, SEL, double, double, double, double))objc_msgSend)(
      (id)objc_getClass("NSColor"),
      sel_registerName("colorWithRed:green:blue:alpha:"),
      `r`, `g`, `b`, `a`);
    id layer = ((id(*)(id, SEL))objc_msgSend)(
      (id)`view`, sel_registerName("layer"));
    if (layer) {
      void* cgColor = ((void*(*)(id, SEL))objc_msgSend)(
        nsColor, sel_registerName("CGColor"));
      ((void(*)(id, SEL, void*))objc_msgSend)(
        layer, sel_registerName("setBackgroundColor:"), cgColor);
    }
    """.}

  proc depthTint(depth: int): tuple[r, g, b, a: cdouble] =
    ## Indigo-tinted palette keyed to tree depth so nested containers
    ## remain visually distinct in the captured raster even when none
    ## of the leaves set explicit colours. Matches the GPUI / Freya
    ## adapters' "every container has a fill" idiom.
    case depth mod 6
    of 0: (0.094, 0.094, 0.137, 1.0)  # #181823 — outer shell
    of 1: (0.137, 0.137, 0.196, 1.0)  # #232332
    of 2: (0.184, 0.184, 0.247, 1.0)  # #2F2F3F
    of 3: (0.486, 0.478, 0.929, 1.0)  # #7C7AED — accent
    of 4: (0.231, 0.231, 0.302, 1.0)  # #3B3B4D
    else: (0.165, 0.165, 0.220, 1.0)  # #2A2A38

  proc isNilNode(e: CocoaElement): bool {.inline.} =
    pointer(e) == nil

  proc layoutTreeForCapture(r: CocoaRenderer; node: CocoaElement;
                            x, y, w, h: int; depth = 0;
                            maxDepth = 8) =
    ## Vertical-stack layout pass that mirrors
    ## ``buildLayoutRects`` but mutates the live NSView frames via
    ## ``setFrame:`` instead of building a side-channel ``seq``.
    ## Also stamps a depth-keyed layer background on every visited
    ## node so empty containers still paint pixels.
    if isNilNode(node) or w <= 0 or h <= 0: return
    if depth > maxDepth: return
    let view = cocoa_objc.Id(node)
    cocoa_autolayout.setFrame(view, cdouble(x), cdouble(y),
                              cdouble(w), cdouble(h))
    let tint = depthTint(depth)
    setLayerBackgroundColor(view, tint.r, tint.g, tint.b, tint.a)
    let count = r.childCount(node)
    if count == 0: return
    let headerBand = min(12, max(0, h div 4))
    let bodyY = headerBand
    let bodyH = h - headerBand
    if bodyH <= 0: return
    let perChild = max(1, bodyH div count)
    var cy = bodyY
    for i in 0 ..< count:
      let child = r.nthChild(node, i)
      if isNilNode(child): continue
      let ch =
        if i == count - 1: bodyY + bodyH - cy  # last child consumes remainder
        else: perChild
      # Children are positioned in the parent's coordinate space; the
      # captured bitmap renders the root, so the (x, y) here resets
      # to the local origin (4-pixel inset to keep the parent's tint
      # visible as a "card edge").
      layoutTreeForCapture(r, child, 4, cy, w - 8, ch, depth + 1, maxDepth)
      cy += ch

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
    # M-EVP-14 fix: drive a vertical-stack layout pass over the live
    # NSView tree before AppKit caches the display. Without this, the
    # IsoNim leaves leave every child NSView at ``CGRectZero`` and the
    # captured bitmap is left as the AppKit-zeroed ``(0,0,0,0)`` —
    # i.e. a uniformly transparent / black surface. See the
    # ``layoutTreeForCapture`` docstring for the full rationale.
    layoutTreeForCapture(src.renderer, src.root, 0, 0, w, h)
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

# ---------------------------------------------------------------------------
# RS-M11c: element-tree manifest builder
# ---------------------------------------------------------------------------
##
## ``buildCocoaElementTreeManifest`` walks the headless ``CocoaElement``
## tree via the renderer's own DFS helpers (``r.childCount`` /
## ``r.nthChild`` / ``r.getAttribute``), synthesises a vertical-stack
## layout — the same heuristic GPUI / Freya use in their adapters —
## and emits one ``ElementEntry`` per node carrying a non-empty
## ``ComponentPathAttr`` annotation.
##
## The walk is platform-portable: it touches only the renderer-side
## Nim tables holding parent/child relationships and attribute strings,
## never invokes AppKit, and therefore compiles on Linux as well as
## macOS. The Linux scaffold's ``renderFrame`` returns a placeholder
## but the manifest builder still produces a real, structurally
## correct manifest from any tree the renderer has built up.
##
## Note (call-site discipline): the Cocoa renderer's tree-inspection
## helpers (``childCount``, ``nthChild``, ``getAttribute``) are methods
## that take the renderer as their first argument — unlike GPUI /
## Freya where these are bare procs on the element handle. The walk
## here therefore threads a ``CocoaRenderer`` value through the
## recursion. Construct one via ``CocoaRenderer()`` (zero-sized type)
## when the caller doesn't already have one in scope; the renderer
## value carries no state, only dispatch.

type
  LayoutRect* = object
    ## Per-node layout entry. Pure geometry + identity; mirror of the
    ## GPUI / Freya adapter's ``LayoutRect`` shape.
    node*: CocoaElement
    x*, y*, w*, h*: int
    depth*: int
    tag*, label*: string

proc isNilElement(e: CocoaElement): bool {.inline.} =
  pointer(e) == nil

proc walkLayout(r: CocoaRenderer; node: CocoaElement; x, y, w, h: int;
                rects: var seq[LayoutRect]; depth = 0; maxDepth = 8) =
  ## DFS that produces one ``LayoutRect`` per visited element. The
  ## traversal order matches the GPUI / Freya rasterisers' drawing
  ## order so the manifest's per-node bounds stay byte-stable across
  ## re-emits and across renderers.
  if isNilElement(node) or w <= 0 or h <= 0: return
  if depth > maxDepth: return
  # Tag derived from the renderer's `getAttribute(node, "class")` (no
  # public `getTag` on the Cocoa renderer); the rasteriser key here is
  # `(tag, label)` purely for stable colouring in cross-adapter
  # comparison plots — the manifest builder filters on
  # ComponentPathAttr below and ignores tag entirely.
  let cls = r.getAttribute(node, "class")
  let txt = r.textContent(node)
  rects.add LayoutRect(node: node, x: x, y: y, w: w, h: h,
                       depth: depth, tag: cls, label: txt & "|" & cls)
  let count = r.childCount(node)
  if count == 0: return
  # Reserve a small "header band" at the top so the parent's fill
  # remains visible (children stack below). 12px or 1/4 of h.
  let headerBand = min(12, max(0, h div 4))
  let bodyY = y + headerBand
  let bodyH = h - headerBand
  if bodyH <= 0: return
  let perChild = max(1, bodyH div count)
  var cy = bodyY
  for i in 0 ..< count:
    let child = r.nthChild(node, i)
    if isNilElement(child): continue
    let ch =
      if i == count - 1: bodyY + bodyH - cy  # last child consumes remainder
      else: perChild
    walkLayout(r, child, x + 4, cy, w - 8, ch, rects, depth + 1, maxDepth)
    cy += ch

proc buildLayoutRects*(r: CocoaRenderer; root: CocoaElement;
                       width, height: int): seq[LayoutRect] =
  ## Public layout pass. The Cocoa renderer's helpers take the renderer
  ## as an argument, hence the extra parameter (mirror of GPUI / Freya
  ## semantics modulo that calling convention).
  result = @[]
  if isNilElement(root) or width <= 0 or height <= 0: return
  walkLayout(r, root, 0, 0, width, height, result)

proc buildCocoaElementTreeManifest*(root: CocoaElement;
                                    width, height: int;
                                    frameSeq: int = 0):
                                   ElementTreeManifest =
  ## Build a fresh manifest from the current state of the Cocoa tree
  ## rooted at ``root``. Idempotent: same tree → same manifest, so the
  ## bridge can hash the result and skip emission when unchanged.
  ##
  ## Walks the renderer's headless side-tables; portable to Linux.
  result = ElementTreeManifest(
    frameSeq: frameSeq,
    surfaceWidth: width,
    surfaceHeight: height,
    elements: @[])
  if isNilElement(root) or width <= 0 or height <= 0: return
  let r = CocoaRenderer()
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
