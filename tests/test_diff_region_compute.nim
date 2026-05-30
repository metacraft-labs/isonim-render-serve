## ELT-M9 — diff-region computation under the W-diff bridge contract.
##
## *Claim.* The shared ``computeDiffRegions`` helper (originally
## landed by RS-M3 for the F-packet diff path) computes the right
## rectangle list for ELT-M9's per-frame WebP diff selector:
##
##   1. Bit-identical frames yield zero rectangles (the W-diff
##      heartbeat case).
##   2. A small contiguous text-edit-style change yields a single
##      tight rectangle (the production-target case — typing a
##      character in the editor's preview pane).
##   3. Three disjoint vertical bands yield three distinct rectangles
##      (the cursor + status-line + scrollbar-knob composition case).
##   4. A diff that would cover >50% of the frame collapses to a
##      single full-frame rectangle (the "drag the window across the
##      screen" fallback the ELT-M9 selector reads to flip to the
##      full-frame W path).
##
## The ELT-M9 bridge re-uses RS-M3's pure encoder verbatim — the wire
## difference (per-rect VP8L body vs. per-rect raw RGBA body) is
## orthogonal to the region-computation algorithm. This test fixes
## the contract from the W-diff side so a future RS-M3 refactor that
## changed the rectangle list shape can't silently break ELT-M9.

import std/[unittest]

import isonim_render_serve

proc solid(w, h: int; r, g, b, a: byte): Frame =
  var pixels = newSeq[byte](w * h * 4)
  var i = 0
  while i < pixels.len:
    pixels[i] = r
    pixels[i + 1] = g
    pixels[i + 2] = b
    pixels[i + 3] = a
    i += 4
  Frame(kind: fkFull,
        flags: FrameFlags(isDiff: false, isVideo: false),
        width: w, height: h, pixels: pixels)

proc fillRect(f: var Frame; x, y, w, h: int; r, g, b, a: byte) =
  for row in 0 ..< h:
    for col in 0 ..< w:
      let off = ((y + row) * f.width + (x + col)) * 4
      f.pixels[off] = r
      f.pixels[off + 1] = g
      f.pixels[off + 2] = b
      f.pixels[off + 3] = a

suite "ELT-M9: diff-region computation (W-diff contract)":

  test "bit-identical frames → zero rectangles (heartbeat W-diff)":
    let prev = solid(256, 128, 0x10, 0x20, 0x30, 0xFF)
    let curr = solid(256, 128, 0x10, 0x20, 0x30, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 0

  test "small text-edit-style change → one tight rectangle":
    let prev = solid(640, 480, 0xFF, 0xFF, 0xFF, 0xFF)
    var curr = solid(640, 480, 0xFF, 0xFF, 0xFF, 0xFF)
    # Simulate typing a glyph: a 12x18 ink rectangle at (110, 80).
    fillRect(curr, x = 110, y = 80, w = 12, h = 18,
             r = 0x10, g = 0x10, b = 0x10, a = 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 1
    check regions[0].x == 110
    check regions[0].y == 80
    check regions[0].w == 12
    check regions[0].h == 18
    # Per-rect pixel byte count must match w*h*4 — the bridge slices
    # this into the WebP encoder.
    check regions[0].pixels.len == 12 * 18 * 4

  test "three disjoint regions → three rectangles":
    let prev = solid(256, 256, 0xFF, 0xFF, 0xFF, 0xFF)
    var curr = solid(256, 256, 0xFF, 0xFF, 0xFF, 0xFF)
    # Cursor blink at (20, 20) → small rect.
    fillRect(curr, 20, 20, 2, 12, 0, 0, 0, 0xFF)
    # Status line painted at the bottom — but in a column that does
    # NOT overlap the cursor strip horizontally, so the per-scanline
    # coalesce keeps them separate. Use a column at x=120.
    fillRect(curr, 120, 120, 8, 8, 0xFF, 0x80, 0x00, 0xFF)
    # Scrollbar knob at far right (different x range again).
    fillRect(curr, 240, 200, 6, 14, 0xC0, 0xC0, 0xC0, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 3

  test "diff covering >50% of frame → single full-frame rectangle":
    let prev = solid(128, 128, 0xFF, 0xFF, 0xFF, 0xFF)
    var curr = solid(128, 128, 0xFF, 0xFF, 0xFF, 0xFF)
    # Repaint the entire top 80% of the frame — coarse coverage that
    # blows past the encoder's 50% fallback threshold.
    fillRect(curr, 0, 0, 128, 100, 0x00, 0x00, 0x00, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    # Fallback case is the single full-frame rectangle; the bridge's
    # ``selectTransport`` extension reads this signal and falls back
    # to the full-frame W path (or V if the H.264 encoder is up).
    check isFullFrameRegion(regions, 128, 128)

  test "ELT-M9 per-rect encode budget — rectangles stay small":
    ## Sanity guard: across the small-edit scenarios above the
    ## largest rectangle is well under the 50% threshold the
    ## fallback path triggers at. This is the load-bearing property
    ## that buys ELT-M9 its sub-16-ms-per-frame budget — the encoder
    ## runs on rectangles whose total area is a small fraction of
    ## the full frame.
    let prev = solid(640, 480, 0xFF, 0xFF, 0xFF, 0xFF)
    var curr = solid(640, 480, 0xFF, 0xFF, 0xFF, 0xFF)
    fillRect(curr, 110, 80, 12, 18, 0x10, 0x10, 0x10, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 1
    let area = regions[0].w * regions[0].h
    check area * 100 < 640 * 480 * 50  # <50% of frame area
