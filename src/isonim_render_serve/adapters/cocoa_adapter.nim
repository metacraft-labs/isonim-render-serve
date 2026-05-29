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

import std/strutils

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
import ./cocoa_metal_capture

export cocoa_metal_capture.CocoaCapturePath,
       cocoa_metal_capture.isMetalCaptureAvailable,
       cocoa_metal_capture.selectCocoaCapturePath,
       cocoa_metal_capture.capturePathName

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
    ##
    ## EPP-M4: ``capturePath`` selects between the Metal-backed
    ## CARenderer offscreen render (``ccpMetal``, default on hosts
    ## where ``MTLCreateSystemDefaultDevice`` succeeds) and the
    ## legacy AppKit ``cacheDisplayInRect:toBitmapImageRep:`` path
    ## (``ccpAppKit``, the EPP-M1 baseline). The legacy path remains
    ## the runtime fallback when the Metal helper returns an empty
    ## buffer for a given frame (transient GPU loss, sandboxing).
    renderer*: CocoaRenderer
    root*: CocoaElement
    width*, height*: int
    mode*: CocoaCaptureMode
    windowId*: uint32  ## ignored unless mode == ccmWindowScreencap
    capturePath*: CocoaCapturePath

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
  ## live NSViews via ``setFrame:``. Containers that don't have an
  ## explicit ``background-color`` style also get a neutral, dark-
  ## grey layer fill keyed to depth so the headless bitmap carries
  ## non-zero RGB and the editor's preview canvas reflects the
  ## rendered demo instead of a black void. (M-EVP-14 round-3:
  ## the earlier ``depthTint`` palette painted a saturated indigo
  ## at depth 3, which clobbered the task_app's row layer and
  ## inverted the visual hierarchy. Accent placement is now
  ## delegated entirely to leaves' explicit styles.)

  proc walkApplyDarkAppearance(view: cocoa_objc.Id;
                               darkAppearance: cocoa_objc.Id) =
    ## Apply the dark NSAppearance to ``view`` (when the view responds
    ## to ``setAppearance:``) and recurse into its subviews. Iterative
    ## via a manual queue would be cleaner but every settings_app
    ## subtree we hit is < 200 nodes so plain recursion is fine.
    if pointer(view) == nil: return
    let v = view
    let app = darkAppearance
    {.emit: """
    if (((BOOL(*)(id, SEL, id))objc_msgSend)(
          (id)`v`, sel_registerName("respondsToSelector:"),
          sel_registerName("setAppearance:"))) {
      ((void(*)(id, SEL, id))objc_msgSend)(
        (id)`v`, sel_registerName("setAppearance:"), (id)`app`);
    }
    """.}
    # Also bind the popup's cell (NSPopUpButtonCell) — the cell is what
    # actually paints the bezel + selected title and consults its own
    # appearance, which is independent of the control's
    # ``setAppearance:``.
    {.emit: """
    if (((BOOL(*)(id, SEL, id))objc_msgSend)(
          (id)`v`, sel_registerName("respondsToSelector:"),
          sel_registerName("cell"))) {
      id cell = ((id(*)(id, SEL))objc_msgSend)(
        (id)`v`, sel_registerName("cell"));
      if (cell && ((BOOL(*)(id, SEL, id))objc_msgSend)(
            cell, sel_registerName("respondsToSelector:"),
            sel_registerName("setAppearance:"))) {
        ((void(*)(id, SEL, id))objc_msgSend)(
          cell, sel_registerName("setAppearance:"), (id)`app`);
      }
    }
    """.}
    # Now recurse into subviews. We pull the subview count + each
    # child handle into Nim-side variables so the recursion stays
    # purely Nim (no ObjC blocks).
    var childCount: clong = 0
    {.emit: """
    if (((BOOL(*)(id, SEL, id))objc_msgSend)(
          (id)`v`, sel_registerName("respondsToSelector:"),
          sel_registerName("subviews"))) {
      id subs = ((id(*)(id, SEL))objc_msgSend)(
        (id)`v`, sel_registerName("subviews"));
      if (subs) {
        `childCount` = (long)((long(*)(id, SEL))objc_msgSend)(
          subs, sel_registerName("count"));
      }
    }
    """.}
    for i in 0 ..< childCount:
      var child: cocoa_objc.Id
      let idx = i
      {.emit: """
      id subs = ((id(*)(id, SEL))objc_msgSend)(
        (id)`v`, sel_registerName("subviews"));
      `child` = ((id(*)(id, SEL, long))objc_msgSend)(
        subs, sel_registerName("objectAtIndex:"), (long)`idx`);
      """.}
      walkApplyDarkAppearance(child, app)

  proc forceDarkAquaAppearance(view: cocoa_objc.Id) =
    ## M-EVP-14 Wave Y (Y-1 fix): the per-control ``setAppearance:`` call
    ## inside ``isonim_cocoa/renderer.nim`` (ekSelect branch) lands on
    ## the NSPopUpButton instance, but the appearance does NOT
    ## propagate down to the popup's NSPopUpButtonCell / NSMenu (the
    ## cell paints with its own ``effectiveAppearance`` snapshot taken
    ## at draw time, which falls back to NSApp.effectiveAppearance when
    ## no NSWindow is in play). Round-17 reviewer confirmed the popup
    ## still renders light-on-light despite the Wave X-6 fix. The fix:
    ## (1) push the dark appearance onto the NSApplication singleton so
    ## every drawing operation that consults ``+[NSApp
    ## effectiveAppearance]`` sees dark; AND (2) recursively walk the
    ## subview tree applying ``setAppearance:`` to every view AND its
    ## cell (NSPopUpButtonCell is the one that paints the bezel/title).
    ## Belt and suspenders.
    var darkAppearance: cocoa_objc.Id
    {.emit: """
    id darkName = ((id(*)(id, SEL, const char*))objc_msgSend)(
      (id)objc_getClass("NSString"),
      sel_registerName("stringWithUTF8String:"),
      "NSAppearanceNameDarkAqua");
    `darkAppearance` = ((id(*)(id, SEL, id))objc_msgSend)(
      (id)objc_getClass("NSAppearance"),
      sel_registerName("appearanceNamed:"), darkName);
    if (`darkAppearance`) {
      // (1) Pin the global NSApp appearance. NSPopUpButtonCell and
      // NSMenu both consult NSApp.effectiveAppearance during draw
      // when no NSWindow is in the inheritance chain.
      id app = ((id(*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSApplication"),
        sel_registerName("sharedApplication"));
      if (app && ((BOOL(*)(id, SEL, id))objc_msgSend)(
            app, sel_registerName("respondsToSelector:"),
            sel_registerName("setAppearance:"))) {
        ((void(*)(id, SEL, id))objc_msgSend)(
          app, sel_registerName("setAppearance:"), `darkAppearance`);
      }
      // Also push the dark appearance onto the global +[NSAppearance
      // currentAppearance] (legacy fallback path on older macOS).
      if (((BOOL(*)(id, SEL, id))objc_msgSend)(
            (id)objc_getClass("NSAppearance"),
            sel_registerName("respondsToSelector:"),
            sel_registerName("setCurrentAppearance:"))) {
        ((void(*)(id, SEL, id))objc_msgSend)(
          (id)objc_getClass("NSAppearance"),
          sel_registerName("setCurrentAppearance:"), `darkAppearance`);
      }
    }
    """.}
    if pointer(darkAppearance) == nil: return
    walkApplyDarkAppearance(view, darkAppearance)

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

  proc neutralTint(depth: int): tuple[r, g, b, a: cdouble] =
    ## Neutral dark-grey palette keyed to tree depth. Every level
    ## gets a slightly different shade so nested containers remain
    ## visually distinct in the captured raster, but no level carries
    ## an "accent" colour — accent / brand placement is delegated to
    ## leaves' explicit ``background-color`` styles (M-EVP-14 round-3
    ## fix: previously a depth-keyed indigo at depth 3 painted task
    ## rows as primary CTAs, inverting the visual hierarchy).
    case depth mod 6
    of 0: (0.094, 0.094, 0.110, 1.0)  # #18181C — outer shell
    of 1: (0.125, 0.125, 0.149, 1.0)  # #202025 — cards
    of 2: (0.157, 0.157, 0.180, 1.0)  # #28282E — rows / sections
    of 3: (0.196, 0.196, 0.220, 1.0)  # #323238 — row interior
    of 4: (0.227, 0.227, 0.251, 1.0)  # #3A3A40 — labels band
    else: (0.169, 0.169, 0.192, 1.0)  # #2B2B31 — fallback

  proc isNilNode(e: CocoaElement): bool {.inline.} =
    pointer(e) == nil

  proc parsePxAttr(s: string): int =
    ## Parse an integer pixel attribute like "44" or "44px". Returns 0
    ## when the value is empty or unparseable; the layout caller treats
    ## 0 as "no fixed size, distribute flexibly".
    if s.len == 0: return 0
    var t = s
    if t.endsWith("px"): t = t[0 ..< t.len - 2]
    try: parseInt(t.strip()) except CatchableError: 0

  proc pxAttr(r: CocoaRenderer; node: CocoaElement; name: string): int =
    max(0, parsePxAttr(r.getAttribute(node, name)))

  proc layoutTreeForCapture(r: CocoaRenderer; node: CocoaElement;
                            parentH: int;
                            x, y, w, h: int; depth = 0;
                            maxDepth = 12;
                            parentHasExplicitBg = false) =
    ## Layout pass that mirrors ``buildLayoutRects`` but mutates the
    ## live NSView frames via ``setFrame:`` instead of building a
    ## side-channel ``seq``. Also stamps a neutral layer background on
    ## every visited node so empty containers still paint pixels.
    ##
    ## Coordinate system note (M-EVP-14 round-3 fix). NSView's
    ## default ``isFlipped`` is ``NO`` — y grows upward from the
    ## bottom-left origin. ``setFrame:`` interprets the rect's
    ## ``origin.y`` in that bottom-up space. The layout walker here
    ## thinks top-down (``y`` increases as we descend the DOM),
    ## which means without a flip the captured bitmap shows the
    ## children stacked in reverse: the last DOM child paints at the
    ## visual top, the first child at the bottom. Round 2 of the
    ## M-EVP-14 review caught this on task_app/cocoa ("summary on
    ## top, input at bottom"). The fix: convert our top-down y into
    ## NSView's bottom-up frame y by reflecting through the parent's
    ## height: ``nsY = parentH - (layoutY + h)``. ``parentH`` is
    ## threaded through the recursion so each child sees the right
    ## parent height. The root is laid out against itself
    ## (``parentH = h``).
    ##
    ## Layout direction (M-EVP-14 round-4 fix). The default is
    ## vertical stacking — children flow top-to-bottom, each filling
    ## the parent's width. A node tagged ``data-layout="horizontal"``
    ## flows children left-to-right, each filling the parent's height.
    ## This is how the task_app row gets the toggle / title / remove
    ## glyphs side-by-side instead of stacked vertically.
    ##
    ## Fixed-size children (M-EVP-14 round-4 fix). When a child sets
    ## ``data-fixed-height`` (vertical layout) or ``data-fixed-width``
    ## (horizontal layout), the parent reserves that exact size and
    ## distributes the remainder among the flexible siblings. This
    ## lets the settings_app shell pin the disclosure triangle to a
    ## thin band, the group header to ~44 px, and each item row to
    ## ~44 px — leaving the previously-collapsed item rows with real
    ## bitmap area instead of the prior equal-split which compounded
    ## down to single-digit pixels per item.
    ##
    ## Tint precedence. The renderer marks
    ## ``hasExplicitBackground`` inside ``applyStyle`` when a leaf
    ## picks a brand / accent / status colour via ``setStyle``.
    ## We skip the neutral fallback in two cases:
    ##   1. The node itself has an explicit background.
    ##   2. The node's parent has an explicit background — otherwise
    ##      the children's neutral tint would obscure the parent's
    ##      chosen colour. The macOS unit test
    ##      (``test_cocoa_adapter_macos_only.nim``) raspberry root
    ##      with two unstyled children exercises this propagation.
    if isNilNode(node) or w <= 0 or h <= 0: return
    if depth > maxDepth: return
    let view = cocoa_objc.Id(node)
    # Convert our top-down y to NSView's bottom-up frame y.
    let nsY = parentH - (y + h)
    cocoa_autolayout.setFrame(view, cdouble(x), cdouble(nsY),
                              cdouble(w), cdouble(h))
    let selfHasExplicitBg = r.hasExplicitBackground(node)
    if not selfHasExplicitBg and not parentHasExplicitBg:
      let tint = neutralTint(depth)
      setLayerBackgroundColor(view, tint.r, tint.g, tint.b, tint.a)
    let count = r.childCount(node)
    if count == 0: return
    let isHorizontal = r.getAttribute(node, "data-layout") == "horizontal"
    let padding = pxAttr(r, node, "data-layout-padding")
    let gap = pxAttr(r, node, "data-layout-gap")
    # Only reserve a small header band at the outer layers so the
    # parent's card-edge tint stays visible; deeper containers get
    # 0 header band so the settings_app's nested label tree doesn't
    # collapse to invisible. Header band is along the cross axis
    # (top for vertical layout, left for horizontal).
    let headerBand =
      if depth <= 1 and not isHorizontal: min(12, max(0, h div 8))
      else: 0
    # Pre-pass: compute per-child fixed and flexible sizes along the
    # layout axis. ``data-fixed-height`` is honoured under vertical
    # layout, ``data-fixed-width`` under horizontal. Anything else is
    # flexible and shares the leftover slice equally.
    var fixedSizes = newSeq[int](count)
    var fixedTotal = 0
    var flexCount = 0
    for i in 0 ..< count:
      let child = r.nthChild(node, i)
      if isNilNode(child):
        fixedSizes[i] = 0
        continue
      let attr =
        if isHorizontal: r.getAttribute(child, "data-fixed-width")
        else: r.getAttribute(child, "data-fixed-height")
      let s = parsePxAttr(attr)
      fixedSizes[i] = s
      if s > 0: fixedTotal += s
      else: inc flexCount
    let propagateBg = selfHasExplicitBg or parentHasExplicitBg
    if isHorizontal:
      # Horizontal layout: stack children left-to-right; each child
      # fills the parent's height (minus 2 px vertical inset for a
      # subtle parent-edge tint band). The 4 px horizontal inset is
      # subsumed into the parent's start/end gutters by giving each
      # child the parent's full width slice.
      let bodyX = padding
      let bodyW = w - (padding * 2)
      let childTotalW = bodyW - (gap * max(0, count - 1))
      if bodyW <= 0 or childTotalW <= 0: return
      let flexTotal = max(0, childTotalW - fixedTotal)
      let perFlex = if flexCount > 0: max(1, flexTotal div flexCount) else: 0
      var cx = bodyX
      let defaultChildY = padding
      let defaultChildH = max(1, h - (padding * 2))
      for i in 0 ..< count:
        let child = r.nthChild(node, i)
        if isNilNode(child): continue
        let remaining = (bodyX + bodyW) - cx
        if remaining <= 0: break
        let cw =
          if fixedSizes[i] > 0:
            min(fixedSizes[i], remaining)
          elif i == count - 1:
            remaining
          elif perFlex > remaining:
            remaining
          else:
            perFlex
        if cw <= 0: break
        var childY = defaultChildY
        var childH = defaultChildH
        let crossAttr = r.getAttribute(child, "data-fixed-height")
        let crossFixed = parsePxAttr(crossAttr)
        if crossFixed > 0 and crossFixed < defaultChildH:
          childH = crossFixed
          childY = defaultChildY + max(0, (defaultChildH - childH) div 2)
        layoutTreeForCapture(r, child, h, cx, childY, cw, childH,
                             depth + 1, maxDepth, propagateBg)
        cx += cw + gap
    else:
      let bodyY = headerBand + padding
      let bodyH = h - headerBand - (padding * 2)
      let childTotalH = bodyH - (gap * max(0, count - 1))
      if bodyH <= 0 or childTotalH <= 0: return
      let flexTotal = max(0, childTotalH - fixedTotal)
      let perFlex = if flexCount > 0: max(1, flexTotal div flexCount) else: 0
      var cy = bodyY
      # M-EVP-14 Wave W (W-1 fix): in vertical layout the main axis is
      # height, so ``data-fixed-height`` is the size-along-axis hint
      # honoured by the pre-pass above. ``data-fixed-width`` is the
      # cross-axis hint and was previously ignored — every child
      # stretched to the parent's full body width regardless of its
      # natural size. That made the settings_app toggle pills
      # (``<switch>`` with ``data-fixed-width="44"``) render as
      # full-row indigo bars instead of compact pills hugged to the
      # right edge. We now read each child's ``data-fixed-width`` and,
      # when present and smaller than the parent's body width, render
      # the child at that exact cross-axis size right-aligned to the
      # body's right edge. Children without ``data-fixed-width`` keep
      # the previous behaviour (fill body width, 4 px inset).
      let bodyX = 4 + padding
      let bodyW = w - 8 - (padding * 2)
      for i in 0 ..< count:
        let child = r.nthChild(node, i)
        if isNilNode(child): continue
        let remaining = bodyY + bodyH - cy
        if remaining <= 0: break
        let ch =
          if fixedSizes[i] > 0:
            min(fixedSizes[i], remaining)
          elif i == count - 1:
            remaining
          elif perFlex > remaining:
            remaining
          else:
            perFlex
        if ch <= 0: break
        # Cross-axis: if the child declares ``data-fixed-width`` and
        # the requested width fits inside the body band, render at
        # that exact width right-aligned. Otherwise fill the body band.
        let crossAttr = r.getAttribute(child, "data-fixed-width")
        let crossFixed = parsePxAttr(crossAttr)
        var childX = bodyX
        var childW = bodyW
        if crossFixed > 0 and crossFixed < bodyW:
          childW = crossFixed
          let crossAlign = r.getAttribute(child, "data-cross-align")
          if crossAlign == "start" or crossAlign == "left":
            childX = bodyX
          elif crossAlign == "center":
            childX = bodyX + max(0, (bodyW - childW) div 2)
          else:
            childX = bodyX + (bodyW - childW)  # right-align
        # Children are positioned in the parent's local coordinate
        # space (NSView's frame origin is relative to the immediate
        # superview's bounds). The 4-pixel horizontal inset keeps the
        # parent's tint visible as a card edge.
        layoutTreeForCapture(r, child, h, childX, cy, childW, ch,
                             depth + 1, maxDepth, propagateBg)
        cy += ch + gap

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
    #
    # ``parentH`` for the root is the root's own height — the layout
    # pass uses ``parentH`` to flip our top-down ``y`` into NSView's
    # bottom-up frame y. With ``parentH = h`` the root's NS-y is 0,
    # which is what we want for the capture target.
    layoutTreeForCapture(src.renderer, src.root, h, 0, 0, w, h)
    # M-EVP-14 Wave Y (Y-1): pin the global + per-view appearance to
    # NSAppearanceNameDarkAqua so NSPopUpButtonCell / NSMenu / NSSwitch
    # paint with the dark trait collection. See ``forceDarkAquaAppearance``
    # for the full rationale; this must run AFTER ``layoutTreeForCapture``
    # but BEFORE ``captureViewRgba`` so every view in the live tree
    # exists, has its frame set, and receives the appearance push before
    # AppKit's ``cacheDisplayInRect:`` draw pass.
    forceDarkAquaAppearance(cocoa_objc.Id(src.root))
    # EPP-M4: capture path selection.
    #
    # Per the EPP-M1 audit § 1.3 the AppKit ``cacheDisplayInRect:`` path
    # is software-rasterised and lands at 10-40 ms / frame on M1; the
    # Metal-backed CARenderer path is predicted at 5-15 ms. ``src.capturePath``
    # encodes the launcher's preference (Metal default; AppKit fallback
    # when ``MTLCreateSystemDefaultDevice`` returns nil at boot). We try
    # the preferred path first and fall back to AppKit if the Metal
    # helper returns a zero-length buffer for this frame (rare — usually
    # a transient GPU loss, sandboxing edge case, or unexpectedly nil
    # CALayer on a non-layer-backed view).
    var pixels: seq[byte]
    var actualPath = src.capturePath
    if src.capturePath == ccpMetal:
      pixels = captureViewMetal(Id(src.root), w, h)
      if pixels.len != w * h * 4:
        # Transient failure: degrade to AppKit for this frame. We do
        # NOT mutate ``src.capturePath`` — the next tick re-probes Metal.
        pixels = cocoa_capture.captureViewRgba(Id(src.root), w, h)
        actualPath = ccpAppKit
    else:
      pixels = cocoa_capture.captureViewRgba(Id(src.root), w, h)
    discard actualPath  # retained for future "which path actually ran this tick" telemetry
    if pixels.len != w * h * 4:
      # Both paths failed. Treat as a hard error — the bridge expects
      # a wire-valid F packet.
      raise newException(Defect,
        "EPP-M4 Cocoa capture failed: both Metal and AppKit capture " &
        "helpers returned " & $pixels.len & " bytes; expected " &
        $(w * h * 4) & ". Check that src.root is a live NSView, that " &
        "AppKit produced an 8-bit bitmap rep, and that Metal returned " &
        "a renderable CARenderer texture.")
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
                          windowId: uint32 = 0;
                          capturePath = ccpMetal): CocoaFrameSource =
  ## Build a `CocoaFrameSource`. The default 800×600 matches the
  ## canonical window size used by the EX-M5 Cocoa task_app demo
  ## (`task_app/main_cocoa.nim`). `mode` defaults to the RS-M0
  ## primary path; pass `ccmWindowScreencap` plus a valid
  ## `windowId` to drive the documented `CGWindowListCreateImage`
  ## fallback (macOS host only — Linux scaffold ignores the mode
  ## and returns placeholder pixels either way).
  ##
  ## EPP-M4. ``capturePath`` selects the per-frame helper. The
  ## ``ccpMetal`` default is degraded to ``ccpAppKit`` via
  ## ``selectCocoaCapturePath`` when the host has no Metal device —
  ## so callers that pass the default always get a valid path
  ## without an extra probe at the call site.
  let resolved = selectCocoaCapturePath(capturePath)
  CocoaFrameSource(renderer: renderer, root: root,
                   width: width, height: height,
                   mode: mode, windowId: windowId,
                   capturePath: resolved)

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

proc parseLayoutPxAttr(s: string): int =
  if s.len == 0: return 0
  var t = s
  if t.endsWith("px"): t = t[0 ..< t.len - 2]
  try: parseInt(t.strip()) except CatchableError: 0

proc layoutPxAttr(r: CocoaRenderer; node: CocoaElement; name: string): int =
  max(0, parseLayoutPxAttr(r.getAttribute(node, name)))

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
  let isHorizontal = r.getAttribute(node, "data-layout") == "horizontal"
  let padding = layoutPxAttr(r, node, "data-layout-padding")
  let gap = layoutPxAttr(r, node, "data-layout-gap")
  var fixedSizes = newSeq[int](count)
  var fixedTotal = 0
  var flexCount = 0
  for i in 0 ..< count:
    let child = r.nthChild(node, i)
    if isNilElement(child):
      fixedSizes[i] = 0
      continue
    let attr =
      if isHorizontal: r.getAttribute(child, "data-fixed-width")
      else: r.getAttribute(child, "data-fixed-height")
    let s = parseLayoutPxAttr(attr)
    fixedSizes[i] = s
    if s > 0: fixedTotal += s else: inc flexCount
  if isHorizontal:
    let bodyX = x + padding
    let bodySpanW = w - (padding * 2)
    let childTotalW = bodySpanW - (gap * max(0, count - 1))
    if bodySpanW <= 0 or childTotalW <= 0: return
    let flexTotal = max(0, childTotalW - fixedTotal)
    let perFlex = if flexCount > 0: max(1, flexTotal div flexCount) else: 0
    var cx = bodyX
    let childY = y + padding
    let childH = max(1, h - (padding * 2))
    for i in 0 ..< count:
      let child = r.nthChild(node, i)
      if isNilElement(child): continue
      let remaining = (bodyX + bodySpanW) - cx
      if remaining <= 0: break
      let cw =
        if fixedSizes[i] > 0:
          min(fixedSizes[i], remaining)
        elif i == count - 1:
          remaining
        elif perFlex > remaining:
          remaining
        else:
          perFlex
      if cw <= 0: break
      walkLayout(r, child, cx, childY, cw, childH, rects,
                 depth + 1, maxDepth)
      cx += cw + gap
  else:
    # Reserve a small header band at the outer layers so parent
    # surfaces still show as cards; explicit padding/gap then handles
    # the visible spacing inside the body.
    let headerBand = if depth <= 1: min(12, max(0, h div 8)) else: 0
    let bodyX = x + 4 + padding
    let bodyW = w - 8 - (padding * 2)
    let bodyY = y + headerBand + padding
    let bodySpanH = h - headerBand - (padding * 2)
    let childTotalH = bodySpanH - (gap * max(0, count - 1))
    if bodyW <= 0 or bodySpanH <= 0 or childTotalH <= 0: return
    let flexTotal = max(0, childTotalH - fixedTotal)
    let perFlex = if flexCount > 0: max(1, flexTotal div flexCount) else: 0
    var cy = bodyY
    for i in 0 ..< count:
      let child = r.nthChild(node, i)
      if isNilElement(child): continue
      let remaining = (bodyY + bodySpanH) - cy
      if remaining <= 0: break
      let ch =
        if fixedSizes[i] > 0:
          min(fixedSizes[i], remaining)
        elif i == count - 1:
          remaining
        elif perFlex > remaining:
          remaining
        else:
          perFlex
      if ch <= 0: break
      let crossFixed = layoutPxAttr(r, child, "data-fixed-width")
      var childX = bodyX
      var childW = bodyW
      if crossFixed > 0 and crossFixed < bodyW:
        childW = crossFixed
        let crossAlign = r.getAttribute(child, "data-cross-align")
        if crossAlign == "center":
          childX = bodyX + max(0, (bodyW - childW) div 2)
        elif crossAlign == "start" or crossAlign == "left":
          childX = bodyX
        else:
          childX = bodyX + (bodyW - childW)
      walkLayout(r, child, childX, cy, childW, ch, rects,
                 depth + 1, maxDepth)
      cy += ch + gap

proc buildLayoutRects*(r: CocoaRenderer; root: CocoaElement;
                       width, height: int): seq[LayoutRect] =
  ## Public layout pass. The Cocoa renderer's helpers take the renderer
  ## as an argument, hence the extra parameter (mirror of GPUI / Freya
  ## semantics modulo that calling convention).
  result = @[]
  if isNilElement(root) or width <= 0 or height <= 0: return
  walkLayout(r, root, 0, 0, width, height, result)

proc hitTestPath*(r: CocoaRenderer; root: CocoaElement;
                  width, height: int;
                  x, y: int): seq[CocoaElement] =
  ## EPP-M12. Mirror of the GPUI ``hitTestPath`` — resolves a click
  ## coordinate to an ordered chain of shadow-tree nodes that contain
  ## the point ``(x, y)`` (deepest first). See ``gpui_adapter.hitTestPath``
  ## for the rationale and the walk-up dispatch contract.
  result = @[]
  if isNilElement(root) or width <= 0 or height <= 0: return
  let rects = buildLayoutRects(r, root, width, height)
  for i in countdown(rects.len - 1, 0):
    let lr = rects[i]
    if x >= lr.x and x < lr.x + lr.w and y >= lr.y and y < lr.y + lr.h:
      result.add lr.node

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
