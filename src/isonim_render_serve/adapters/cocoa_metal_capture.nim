## EPP-M4: render-serve facade over ``isonim_cocoa/appkit/capture_metal``.
##
## Keeping the import surface on the render-serve side under
## ``adapters/`` lets ``cocoa_adapter.nim`` ask "do we have a Metal
## capture path on this host?" and "give me a pixel buffer through the
## Metal path" without sprinkling ``when defined(macosx)`` guards
## across the adapter body. The actual ObjC + Metal work lives in
## ``isonim-cocoa/src/isonim_cocoa/testing/capture_metal.m`` plus the
## thin Nim wrapper at ``isonim_cocoa/appkit/capture_metal.nim``;
## this module exists so a Linux build of ``isonim-render-serve`` can
## still ``import`` the symbol and unconditionally see the
## "unavailable" reply.
##
## ## Capture-path selection
##
## EPP-M4's contract is: try Metal first, fall back to AppKit when
## Metal is unavailable. ``selectCocoaCapturePath`` codifies the
## decision once on launcher boot and returns a value that
## ``cocoa_adapter.renderFrame`` consults per frame. The adapter
## carries the selection in its ``CocoaFrameSource`` instance so a
## live capture loop never re-probes the device.
##
## When Metal returns a zero-length buffer at runtime (rare — usually
## a transient GPU loss event), ``renderFrame`` re-falls-back to the
## AppKit path for that frame and then re-probes on the next tick. The
## selection knob is therefore a *hint*, not a hard ceiling.

import isonim_cocoa/objc_runtime

when defined(macosx):
  import isonim_cocoa/appkit/capture_metal as cocoa_metal_capture

type
  CocoaCapturePath* = enum
    ## Which low-level capture helper the adapter should invoke this
    ## frame. ``ccpAppKit`` is the EPP-M1 baseline
    ## ``cacheDisplayInRect:toBitmapImageRep:`` path; ``ccpMetal`` is
    ## EPP-M4's CARenderer + MTLTexture path.
    ccpAppKit
    ccpMetal

proc isMetalCaptureAvailable*(): bool =
  ## Cheap one-shot probe: does this host have a default Metal device?
  ##
  ## On macOS the call delegates to
  ## ``isonim_cocoa/appkit/capture_metal.isMetalCaptureAvailable``,
  ## which in turn asks ``MTLCreateSystemDefaultDevice`` (Apple caches
  ## the answer internally after the first hit, so calling this on
  ## every launcher boot is fine).
  ##
  ## On Linux / non-macOS the body short-circuits to ``false`` so the
  ## render-serve test suite compiles on a Linux CI lane without
  ## dragging Metal headers in. The EPP-M4 milestone is macOS-only by
  ## design.
  when defined(macosx):
    cocoa_metal_capture.isMetalCaptureAvailable()
  else:
    false

proc selectCocoaCapturePath*(prefer: CocoaCapturePath = ccpMetal):
                              CocoaCapturePath =
  ## Pick the per-launcher capture path. The default preference is
  ## ``ccpMetal`` (EPP-M4 makes Metal the default on macOS). If the
  ## caller prefers Metal but the host can't provide a Metal device,
  ## fall back to AppKit. ``ccpAppKit`` always returns itself —
  ## callers that want to force the legacy path (testing the fallback,
  ## bisecting a render-bug) can do so.
  case prefer
  of ccpAppKit: ccpAppKit
  of ccpMetal:
    if isMetalCaptureAvailable(): ccpMetal else: ccpAppKit

proc captureViewMetal*(view: Id; width, height: int): seq[byte] =
  ## Render ``view`` through the Metal capture helper and return
  ## RGBA8888 row-major bytes. Empty seq on failure (callers fall
  ## back to AppKit). On non-macOS hosts always returns an empty seq.
  when defined(macosx):
    cocoa_metal_capture.captureViewMetal(view, width, height)
  else:
    @[]

proc capturePathName*(p: CocoaCapturePath): string =
  ## Stable identifier for the wire-format hello packet. The editor
  ## browser-side e2e test asserts the launcher's hello carries
  ## ``capabilities.cocoaCapturePath`` equal to ``"metal"`` when Metal
  ## was selected; the launcher emits ``"appkit"`` for the fallback.
  case p
  of ccpAppKit: "appkit"
  of ccpMetal:  "metal"
