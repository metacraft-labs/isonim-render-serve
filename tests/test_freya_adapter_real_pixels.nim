## RS-M14 Phase 1 — Nim-side adapter test for real Freya pixels via
## `freya-testing`'s Skia raster path.
##
## What this exercises:
##   * The shim binary built with `--features freya-headless` exporting
##     `freya_render_to_pixels` + `freya_free_pixels`.
##   * `freya_adapter.renderFrame` (with `-d:useFreyaHeadless`)
##     routing through the new C ABI entry instead of the synthetic
##     vertical-stack raster.
##   * The acceptance signal from RS-M14's spec: a seeded composition
##     produces a pixel histogram with strictly more than 5 unique
##     colours (the pre-RS-M14 synthetic path tops out at the small
##     fixed colour palette in `colourForTag`).
##
## Build prerequisites:
##   - The shim must be built with the `freya-headless` feature, e.g.
##     `cargo build --features freya-headless` inside
##     `isonim-freya/rust/freya-nim-shim`. The resulting
##     `libfreya_nim_shim.{dylib,so}` must be on the dynamic loader
##     search path (the shim's flake shellHook handles this).
##   - This test compiles with `-d:useFreyaHeadless` so the adapter's
##     headless code path is active.
##
## If the shim was built without `freya-headless`, the dynamic linker
## will fail to find the symbol and the test will exit non-zero before
## any check runs — surfacing the missing prerequisite explicitly
## instead of silently falling back to synthetic stripes.

import std/unittest
when defined(useFreyaHeadless):
  import std/sets

import isonim_freya/renderer
import isonim_freya/bindings as freya_bindings

import isonim_render_serve/adapters/freya_adapter
import isonim_render_serve/packet

suite "RS-M14 Phase 1: FreyaFrameSource.renderFrame headless":

  test "real Freya pixels — unique-colour histogram exceeds synthetic baseline":
    when not defined(useFreyaHeadless):
      skip()
    else:
      freya_bindings.freya_reset_tree()
      let r = FreyaRenderer()
      let root = r.createElement("div")
      r.setAttribute(root, "class", "test-root")
      r.setStyle(root, "background", "rgb(40, 40, 60)")
      r.setStyle(root, "width", "100%")
      r.setStyle(root, "height", "100%")

      # Build a small composition with several styled elements; the
      # real renderer should produce a varied raster across the tree.
      let header = r.createElement("rect")
      r.setStyle(header, "background", "rgb(220, 60, 80)")
      r.setStyle(header, "width", "100%")
      r.setStyle(header, "height", "40")
      r.appendChild(root, header)

      let body = r.createElement("rect")
      r.setStyle(body, "background", "rgb(60, 160, 80)")
      r.setStyle(body, "width", "100%")
      r.setStyle(body, "height", "60")
      r.appendChild(root, body)

      let footer = r.createElement("rect")
      r.setStyle(footer, "background", "rgb(40, 120, 220)")
      r.setStyle(footer, "width", "100%")
      r.setStyle(footer, "height", "20")
      r.appendChild(root, footer)

      let fs = newFreyaFrameSource(r, root, width = 100, height = 100)
      let frame = fs.renderFrame()

      check frame.kind == fkFull
      check frame.width == 100
      check frame.height == 100
      check frame.pixels.len == 100 * 100 * 4

      # Count unique RGBA tuples. The pre-RS-M14 synthetic path uses
      # the small fixed palette from `colourForTag` (typically 3-5
      # unique colours after alpha blending against the dark-grey
      # background). The real Skia raster path produces many more
      # colours because antialiasing and corner rendering introduce
      # gradients along element edges.
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

  test "fallback path is exercised when useFreyaHeadless is not defined":
    when defined(useFreyaHeadless):
      skip()
    else:
      # Without -d:useFreyaHeadless, the synthetic raster path is
      # what runs. Sanity check: a seeded tree still produces a
      # non-empty RGBA buffer of the right size.
      freya_bindings.freya_reset_tree()
      let r = FreyaRenderer()
      let root = r.createElement("div")
      r.setStyle(root, "background", "red")
      let fs = newFreyaFrameSource(r, root, width = 32, height = 24)
      let frame = fs.renderFrame()
      check frame.pixels.len == 32 * 24 * 4
