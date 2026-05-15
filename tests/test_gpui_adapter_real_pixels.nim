## RS-M14 Phase 2 — Nim-side adapter test for real GPUI pixels via Zed's
## `HeadlessAppContext` + `Window::render_to_image`.
##
## What this exercises:
##   * The shim binary built with `--features gpui-headless` exporting
##     `gpui_render_to_pixels` + `gpui_free_pixels`.
##   * `gpui_adapter.renderFrame` (with `-d:useGpuiHeadless`) routing
##     through the new C ABI entry instead of the synthetic vertical-
##     stack raster.
##   * The acceptance signal from RS-M14's spec: a seeded composition
##     produces a pixel histogram with strictly more than 5 unique
##     colours (the pre-RS-M14 synthetic path tops out at the small
##     fixed colour palette in `colourForTag`).
##
## Build prerequisites:
##   - The shim must be built with the `gpui-headless` feature, e.g.
##     `cargo build --features gpui-headless` inside
##     `isonim-gpui/rust/gpui-nim-shim`. The resulting
##     `libgpui_nim_shim.{dylib,so}` must be on the dynamic loader
##     search path.
##   - This test compiles with `-d:useGpuiHeadless` so the adapter's
##     headless code path is active.
##
## If the shim was built without `gpui-headless`, the dynamic linker
## will fail to find the symbol and the test will exit non-zero before
## any check runs — surfacing the missing prerequisite explicitly
## instead of silently falling back to synthetic stripes.
##
## Platform scope: the `useGpuiHeadless` test is macOS-only because the
## pinned Zed revision's `current_headless_renderer()` returns `None`
## on Linux. On Linux the headless path returns error code 2 and the
## adapter falls back to synthetic stripes; the synthetic-fallback
## test below verifies that path still works.

import std/unittest
when defined(useGpuiHeadless):
  import std/sets

import isonim_gpui/renderer
import isonim_gpui/bindings as gpui_bindings

import isonim_render_serve/adapters/gpui_adapter
import isonim_render_serve/packet

suite "RS-M14 Phase 2: GpuiFrameSource.renderFrame headless":

  test "real GPUI pixels — unique-colour histogram exceeds synthetic baseline":
    when not defined(useGpuiHeadless):
      skip()
    else:
      when not defined(macosx):
        # The pinned Zed revision's headless renderer factory returns
        # `None` on non-macOS. The headless path returns error code 2
        # (RendererUnavailable) and the adapter falls back to synthetic;
        # we don't assert the histogram check on Linux. RS-M14b owns
        # the Linux real-pixel story.
        skip()
      else:
        gpui_bindings.gpui_reset_tree()
        let r = GpuiRenderer()
        let root = r.createElement("div")
        r.setAttribute(root, "class", "test-root")
        r.setStyle(root, "background", "#28283c")
        r.setStyle(root, "width", "100%")
        r.setStyle(root, "height", "100%")
        # Stack children vertically so they each occupy a distinct strip
        # of the canvas (without flex-column the absolute-sized header /
        # body / footer overlap on top of each other).
        r.setStyle(root, "flex-direction", "column")

        # Build a small composition with several styled elements; the
        # real renderer should produce a varied raster across the tree.
        let header = r.createElement("div")
        r.setStyle(header, "background", "#dc3c50")
        r.setStyle(header, "width", "100%")
        r.setStyle(header, "height", "40px")
        # Add an antialiased text child so the captured raster has the
        # gradient of edge pixels real text produces (a flat-fill rect
        # alone yields just a handful of unique RGBA values).
        let headerLabel = r.createTextNode("Task App Demo")
        r.appendChild(header, headerLabel)
        r.appendChild(root, header)

        let body = r.createElement("div")
        r.setStyle(body, "background", "#3ca050")
        r.setStyle(body, "width", "100%")
        r.setStyle(body, "height", "60px")
        let bodyLabel = r.createTextNode("Two Active Tasks")
        r.appendChild(body, bodyLabel)
        r.appendChild(root, body)

        let footer = r.createElement("div")
        r.setStyle(footer, "background", "#2878dc")
        r.setStyle(footer, "width", "100%")
        r.setStyle(footer, "height", "20px")
        let footerLabel = r.createTextNode("RS-M14 Phase 2")
        r.appendChild(footer, footerLabel)
        r.appendChild(root, footer)

        let fs = newGpuiFrameSource(r, root, width = 200, height = 200)
        let frame = fs.renderFrame()

        check frame.kind == fkFull
        check frame.width == 200
        check frame.height == 200
        check frame.pixels.len == 200 * 200 * 4

        # Count unique RGBA tuples. The pre-RS-M14 synthetic path uses
        # the small fixed palette from `colourForTag` (typically 3-5
        # unique colours after alpha blending against the dark-grey
        # background). The real GPUI renderer produces many more colours
        # because antialiasing / corner rendering introduce gradients
        # along element edges.
        var unique = initHashSet[uint32]()
        var i = 0
        while i < frame.pixels.len:
          let rgba = uint32(frame.pixels[i]) or
                     (uint32(frame.pixels[i + 1]) shl 8) or
                     (uint32(frame.pixels[i + 2]) shl 16) or
                     (uint32(frame.pixels[i + 3]) shl 24)
          unique.incl(rgba)
          i += 4

        check unique.len > 5

  test "fallback path is exercised when useGpuiHeadless is not defined":
    when defined(useGpuiHeadless):
      skip()
    else:
      # Without -d:useGpuiHeadless, the synthetic raster path is what
      # runs. Sanity check: a seeded tree still produces a non-empty
      # RGBA buffer of the right size.
      gpui_bindings.gpui_reset_tree()
      let r = GpuiRenderer()
      let root = r.createElement("div")
      r.setStyle(root, "background", "red")
      let fs = newGpuiFrameSource(r, root, width = 32, height = 24)
      let frame = fs.renderFrame()
      check frame.pixels.len == 32 * 24 * 4
