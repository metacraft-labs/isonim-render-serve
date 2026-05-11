## RS-M2 — direct unit test of the GPUI adapter's `renderFrame`
## entry point against a real `GpuiRenderer` + a tiny tree built
## through the actual shim cdylib (no mocks).
##
## What this exercises:
##   * `GpuiRenderer.createElement` / `setAttribute` /
##     `appendChild` — the real shim FFI loaded via
##     `LD_LIBRARY_PATH`.
##   * `gpui_adapter.newGpuiFrameSource`.
##   * `gpui_adapter.renderFrame` — tree-derived synthetic
##     raster path (the RS-M2 capture approach, see the adapter's
##     module docstring for the rationale).
##   * `Frame` invariants from RS-M0 (dimensions, payload length,
##     non-empty pixel data).

import std/unittest

import isonim_gpui/renderer
import isonim_gpui/bindings

import isonim_render_serve/adapters/gpui_adapter
import isonim_render_serve/packet

suite "RS-M2: GpuiFrameSource.renderFrame (direct)":

  test "dimensions and payload length match the configured size":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, "class", "test-root")
    let label = r.createElement("p")
    r.setTextContent(label, "hello")
    r.appendChild(root, label)

    let fs = newGpuiFrameSource(r, root, width = 64, height = 48)
    let frame = fs.renderFrame()

    check frame.kind == fkFull
    check frame.width == 64
    check frame.height == 48
    check frame.pixels.len == 64 * 48 * 4
    # Alpha channel: every pixel opaque (the adapter writes 0xFF to
    # every alpha byte).
    var allOpaque = true
    var idx = 3
    while idx < frame.pixels.len:
      if frame.pixels[idx] != 0xFF'u8:
        allOpaque = false
        break
      idx += 4
    check allOpaque

  test "non-empty tree produces at least one non-background pixel":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    let header = r.createElement("button")
    r.setTextContent(header, "Click me")
    r.appendChild(root, header)
    let body = r.createElement("ul")
    for i in 0 ..< 3:
      let li = r.createElement("li")
      r.setTextContent(li, "item " & $i)
      r.appendChild(body, li)
    r.appendChild(root, body)

    let fs = newGpuiFrameSource(r, root, width = 80, height = 60)
    let frame = fs.renderFrame()
    check frame.pixels.len == 80 * 60 * 4

    # The empty-canvas background is RGB (0x18, 0x18, 0x18). At least
    # one pixel must differ — i.e. the rasterizer filled in a
    # rectangle for at least one element.
    var sawColoured = false
    var i = 0
    while i < frame.pixels.len:
      if frame.pixels[i] != 0x18'u8 or
         frame.pixels[i + 1] != 0x18'u8 or
         frame.pixels[i + 2] != 0x18'u8:
        sawColoured = true
        break
      i += 4
    check sawColoured

  test "empty tree (nil root) still yields valid frame":
    let r = GpuiRenderer()
    let fs = newGpuiFrameSource(r, nil, width = 16, height = 16)
    let frame = fs.renderFrame()
    check frame.pixels.len == 16 * 16 * 4
    # Background-only: every RGB triplet == (0x18, 0x18, 0x18).
    var bgOnly = true
    var i = 0
    while i < frame.pixels.len:
      if frame.pixels[i] != 0x18'u8 or
         frame.pixels[i + 1] != 0x18'u8 or
         frame.pixels[i + 2] != 0x18'u8:
        bgOnly = false
        break
      i += 4
    check bgOnly

  test "mutating the tree changes the rendered pixels":
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    let label = r.createElement("p")
    r.setTextContent(label, "before")
    r.appendChild(root, label)
    let fs = newGpuiFrameSource(r, root, width = 32, height = 32)
    let pixA = fs.renderFrame().pixels

    # Mutate: append a button child, which changes the tree's
    # child-count + colour mix.
    let btn = r.createElement("button")
    r.setTextContent(btn, "go")
    r.appendChild(root, btn)
    let pixB = fs.renderFrame().pixels

    check pixA.len == pixB.len
    # At least one byte must differ.
    var changed = false
    for i in 0 ..< pixA.len:
      if pixA[i] != pixB[i]:
        changed = true
        break
    check changed
