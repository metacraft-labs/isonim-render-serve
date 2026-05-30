## EMC2-M2 — per-backend rasteriser ``ElementKindAttr`` -> paint binding.
##
## The Editor-Matrix-Closer-2 campaign's milestone EMC2-M2 wires each of
## the four backend rasterisers (GPUI / Freya / Cocoa / Android) to read
## ``ElementKindAttr`` on every visited node and paint a distinguishable
## fill colour for the interactive-state kinds ``"row-hovered"``,
## ``"row-pressed"`` (closing the 11 click-null cells the FUH-M8 matrix
## flagged) and ``"row-completed"`` (mirror of the existing settings_app
## convention).
##
## This test builds a four-row tree where each row carries a different
## ``ElementKindAttr`` value, rasterises the tree through each backend's
## ``renderFrame`` (or its host-side stand-in), and asserts the centre
## pixel of each row has an RGB triplet that is distinguishable from
## every other row's centre pixel. A per-channel difference of at least
## 16 is required — well above any sensible noise floor and below the
## smallest expected delta from the chosen palette (which uses shifts
## of >=32 per channel, see ``gpui_adapter.colourForKind``).
##
## Per-backend gating mirrors the existing element-tree tests:
##   - GPUI / Freya: always available (synthetic raster path lives in
##     pure Nim and runs on Linux and macOS alike).
##   - Cocoa: ``when defined(macosx)`` — the real AppKit capture path
##     needs an NSApplication; on Linux the adapter ships a placeholder
##     ``renderFrame`` and this test is a no-op.
##   - Android: ``when defined(mockJni) or defined(android)`` — the
##     ``isonim_android/renderer`` import hard-errors otherwise. The
##     EMC2-M2 mockJni branch paints kind tints over the legacy
##     uniform-grey placeholder so host-side tests can exercise the
##     same fingerprint-ROI contract the matrix uses.

import std/unittest

import isonim_render_serve/element_tree_attrs
import isonim_render_serve/packet

const
  CanvasW = 200
  CanvasH = 240  ## 4 rows x 60 px each
  RowCount = 4
  RowHeight = CanvasH div RowCount  ## 60
  Kinds = ["row", "row-completed", "row-hovered", "row-pressed"]

proc rowCentre(rowIdx: int): tuple[x, y: int] =
  ## Centre coordinate of the ``rowIdx``-th row's pixel band.
  (CanvasW div 2, rowIdx * RowHeight + RowHeight div 2)

proc pixelAt(frame: Frame; x, y: int): tuple[r, g, b: int] =
  let off = (y * frame.width + x) * 4
  (int(frame.pixels[off]),
   int(frame.pixels[off + 1]),
   int(frame.pixels[off + 2]))

proc channelDelta(a, b: tuple[r, g, b: int]): int =
  ## Largest per-channel absolute difference between two RGB triplets.
  max(max(abs(a.r - b.r), abs(a.g - b.g)), abs(a.b - b.b))

proc assertDistinguishablePalette(samples: array[RowCount,
                                                 tuple[r, g, b: int]];
                                  backend: string) =
  ## Every pair of (row_i, row_j) for i != j must differ on at least one
  ## RGB channel by 16 or more. ``backend`` shows up in the failure
  ## diagnostic so the per-rasteriser regression is easy to spot.
  for i in 0 ..< RowCount:
    for j in i + 1 ..< RowCount:
      let d = channelDelta(samples[i], samples[j])
      if d < 16:
        let msg = backend & ": rows " & $i & " (kind=" & Kinds[i] &
                  " rgb=" & $samples[i] & ") and " & $j &
                  " (kind=" & Kinds[j] & " rgb=" & $samples[j] &
                  ") differ by only " & $d &
                  " on the largest channel; threshold 16."
        checkpoint(msg)
        check d >= 16

# ---------------------------------------------------------------------------
# GPUI synthetic raster — always available.
# ---------------------------------------------------------------------------

import isonim_gpui/renderer as gpui_renderer
import isonim_gpui/bindings as gpui_bindings
import isonim_render_serve/adapters/gpui_adapter

suite "EMC2-M2: GpuiFrameSource.renderFrame paints per-kind tints":

  test "each row's centre pixel is distinguishable from the others":
    gpui_bindings.gpui_reset_tree()
    let r = gpui_renderer.GpuiRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "test/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")
    for i in 0 ..< RowCount:
      let row = r.createElement("li")
      r.setAttribute(row, ComponentPathAttr, "test/Row#" & $i)
      r.setAttribute(row, ElementKindAttr, Kinds[i])
      r.appendChild(root, row)
    let src = newGpuiFrameSource(r, root,
                                 width = CanvasW, height = CanvasH)
    let frame = src.renderFrame()
    check frame.kind == fkFull
    check frame.width == CanvasW
    check frame.height == CanvasH
    check frame.pixels.len == CanvasW * CanvasH * 4
    var samples: array[RowCount, tuple[r, g, b: int]]
    for i in 0 ..< RowCount:
      let (cx, cy) = rowCentre(i)
      samples[i] = pixelAt(frame, cx, cy)
    assertDistinguishablePalette(samples, "gpui")

# ---------------------------------------------------------------------------
# Freya synthetic raster — always available.
# ---------------------------------------------------------------------------

import isonim_freya/renderer as freya_renderer
import isonim_freya/bindings as freya_bindings
import isonim_render_serve/adapters/freya_adapter

suite "EMC2-M2: FreyaFrameSource.renderFrame paints per-kind tints":

  test "each row's centre pixel is distinguishable from the others":
    freya_bindings.freya_reset_tree()
    let r = freya_renderer.FreyaRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, ComponentPathAttr, "test/Root")
    r.setAttribute(root, ElementKindAttr, "app-shell")
    for i in 0 ..< RowCount:
      let row = r.createElement("rect")
      r.setAttribute(row, ComponentPathAttr, "test/Row#" & $i)
      r.setAttribute(row, ElementKindAttr, Kinds[i])
      r.appendChild(root, row)
    let src = newFreyaFrameSource(r, root,
                                  width = CanvasW, height = CanvasH)
    let frame = src.renderFrame()
    check frame.kind == fkFull
    check frame.width == CanvasW
    check frame.height == CanvasH
    check frame.pixels.len == CanvasW * CanvasH * 4
    var samples: array[RowCount, tuple[r, g, b: int]]
    for i in 0 ..< RowCount:
      let (cx, cy) = rowCentre(i)
      samples[i] = pixelAt(frame, cx, cy)
    assertDistinguishablePalette(samples, "freya")

# ---------------------------------------------------------------------------
# Cocoa real AppKit raster — macOS-host only.
# ---------------------------------------------------------------------------

when defined(macosx):
  import isonim_cocoa/renderer as cocoa_renderer
  import isonim_render_serve/adapters/cocoa_adapter

  suite "EMC2-M2: CocoaFrameSource.renderFrame paints per-kind tints":

    test "each row's centre pixel is distinguishable from the others":
      cocoa_renderer.resetTree()
      cocoa_renderer.resetCallbacks()
      let r = cocoa_renderer.CocoaRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, ComponentPathAttr, "test/Root")
      r.setAttribute(root, ElementKindAttr, "app-shell")
      for i in 0 ..< RowCount:
        let row = r.createElement("div")
        r.setAttribute(row, ComponentPathAttr, "test/Row#" & $i)
        r.setAttribute(row, ElementKindAttr, Kinds[i])
        r.appendChild(root, row)
      let src = newCocoaFrameSource(r, root,
                                    width = CanvasW, height = CanvasH)
      let frame = src.renderFrame()
      check frame.kind == fkFull
      check frame.width == CanvasW
      check frame.height == CanvasH
      check frame.pixels.len == CanvasW * CanvasH * 4
      var samples: array[RowCount, tuple[r, g, b: int]]
      for i in 0 ..< RowCount:
        let (cx, cy) = rowCentre(i)
        samples[i] = pixelAt(frame, cx, cy)
      assertDistinguishablePalette(samples, "cocoa")
else:
  suite "EMC2-M2: cocoa adapter (skipped on non-macOS hosts)":
    test "compile-only — macOS run gated by `when defined(macosx)`":
      check true

# ---------------------------------------------------------------------------
# Android host-side raster — -d:mockJni only.
# ---------------------------------------------------------------------------

when defined(mockJni):
  import isonim_android/renderer as android_renderer
  import isonim_render_serve/adapters/android_adapter

  suite "EMC2-M2: AndroidFrameSource.renderFrame paints per-kind tints":

    test "each row's centre pixel is distinguishable from the others":
      android_renderer.resetRenderer()
      let r = android_renderer.AndroidRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, ComponentPathAttr, "test/Root")
      r.setAttribute(root, ElementKindAttr, "app-shell")
      for i in 0 ..< RowCount:
        let row = r.createElement("li")
        r.setAttribute(row, ComponentPathAttr, "test/Row#" & $i)
        r.setAttribute(row, ElementKindAttr, Kinds[i])
        r.appendChild(root, row)
      let src = newAndroidFrameSource(r, root,
                                      width = CanvasW, height = CanvasH)
      let frame = src.renderFrame()
      check frame.kind == fkFull
      check frame.width == CanvasW
      check frame.height == CanvasH
      check frame.pixels.len == CanvasW * CanvasH * 4
      var samples: array[RowCount, tuple[r, g, b: int]]
      for i in 0 ..< RowCount:
        let (cx, cy) = rowCentre(i)
        samples[i] = pixelAt(frame, cx, cy)
      assertDistinguishablePalette(samples, "android")
else:
  suite "EMC2-M2: android adapter (build with -d:mockJni to run)":
    test "compile-only — Android test gated by `defined(mockJni)`":
      check true
