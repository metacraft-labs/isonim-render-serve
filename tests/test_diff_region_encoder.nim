## test_diff_region_encoder — pure-encoder unit tests for RS-M3's
## `computeDiffRegions`.
##
## *Claims:*
##   1. Identical frames → empty region list.
##   2. Single-pixel change → one tiny region covering exactly that
##      pixel.
##   3. Horizontal strip change → one wide single-row region.
##   4. Multiple disjoint vertical bands → multiple regions.
##   5. Pathologically large diff → encoder falls back to a single
##      full-frame-spanning region (the bridge then promotes this to
##      a non-diff F packet).
##   6. Encoded diff byte count is *strictly smaller* than the
##      full-frame byte count for the partial-change cases — the
##      whole point of diff encoding.

import std/[unittest]

import isonim_render_serve

proc makeSolidFrame(w, h: int; r, g, b, a: byte): Frame =
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

proc setPixel(f: var Frame; x, y: int; r, g, b, a: byte) =
  let off = (y * f.width + x) * 4
  f.pixels[off] = r
  f.pixels[off + 1] = g
  f.pixels[off + 2] = b
  f.pixels[off + 3] = a

proc encodedDiffSize(regions: openArray[Region]): int =
  ## Mirror of the byte-cost formula `computeDiffRegions` uses
  ## internally (see `diff_region.nim`'s pass 3): 4 bytes for the
  ## leading `u32 count` plus 20 bytes of header + RGBA payload per
  ## rect.
  result = 4
  for r in regions:
    result += 20 + r.w * r.h * 4

suite "RS-M3: diff-region encoder":

  test "identical frames → empty region list":
    let prev = makeSolidFrame(32, 32, 0x10, 0x20, 0x30, 0xFF)
    let curr = makeSolidFrame(32, 32, 0x10, 0x20, 0x30, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 0

  test "single-pixel change → one 1x1 region at that exact coord":
    let prev = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    var curr = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    setPixel(curr, 17, 33, 0xFF, 0x80, 0x40, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 1
    check regions[0].x == 17
    check regions[0].y == 33
    check regions[0].w == 1
    check regions[0].h == 1
    # Pixel matches the modified RGBA.
    check regions[0].pixels.len == 4
    check regions[0].pixels[0] == 0xFF'u8
    check regions[0].pixels[1] == 0x80'u8
    check regions[0].pixels[2] == 0x40'u8
    check regions[0].pixels[3] == 0xFF'u8
    # Encoded size must beat full-frame for this trivially small
    # diff: 4 + 20 + 4 == 28 bytes, vs 64*64*4 == 16384.
    let fullCost = 64 * 64 * 4
    check encodedDiffSize(regions) < fullCost

  test "horizontal-strip change → one wide single-row region":
    let prev = makeSolidFrame(128, 16, 0x40, 0x40, 0x40, 0xFF)
    var curr = makeSolidFrame(128, 16, 0x40, 0x40, 0x40, 0xFF)
    # Paint a strip on row 5 from x=10 to x=99 inclusive.
    for x in 10 .. 99:
      setPixel(curr, x, 5, 0xFF, 0x00, 0x00, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 1
    check regions[0].x == 10
    check regions[0].y == 5
    check regions[0].w == 90  # 99 - 10 + 1
    check regions[0].h == 1
    let fullCost = 128 * 16 * 4
    check encodedDiffSize(regions) < fullCost

  test "two disjoint changes (well-separated rows) → two regions":
    let prev = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    var curr = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    setPixel(curr, 5, 10, 0xFF, 0x00, 0x00, 0xFF)
    setPixel(curr, 50, 40, 0x00, 0xFF, 0x00, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    # The vertical-coalesce pass leaves the rows non-adjacent
    # (rows 10 and 40 — many identical rows between), so they
    # remain two separate rectangles.
    check regions.len == 2
    var found1 = false
    var found2 = false
    for r in regions:
      if r.x == 5 and r.y == 10 and r.w == 1 and r.h == 1: found1 = true
      if r.x == 50 and r.y == 40 and r.w == 1 and r.h == 1: found2 = true
    check found1
    check found2
    let fullCost = 64 * 64 * 4
    check encodedDiffSize(regions) < fullCost

  test "vertical coalesce: contiguous rows with overlapping x ranges " &
       "merge into one tall region":
    let prev = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    var curr = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    # Paint a 10x10 block at (20, 30).
    for dy in 0 ..< 10:
      for dx in 0 ..< 10:
        setPixel(curr, 20 + dx, 30 + dy, 0xFF, 0xFF, 0x00, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 1
    check regions[0].x == 20
    check regions[0].y == 30
    check regions[0].w == 10
    check regions[0].h == 10
    check regions[0].pixels.len == 10 * 10 * 4
    # Every pixel in the extracted block must be the painted yellow.
    var allYellow = true
    var i = 0
    while i < regions[0].pixels.len:
      if regions[0].pixels[i] != 0xFF'u8 or
         regions[0].pixels[i + 1] != 0xFF'u8 or
         regions[0].pixels[i + 2] != 0x00'u8 or
         regions[0].pixels[i + 3] != 0xFF'u8:
        allYellow = false
        break
      i += 4
    check allYellow
    let fullCost = 64 * 64 * 4
    check encodedDiffSize(regions) < fullCost

  test "full-frame change → fallback to single full-frame region":
    # Two frames where *every* pixel differs. The encoder's 50%
    # cost threshold must trip and emit a single region covering the
    # entire frame (the bridge then promotes this to a non-diff F
    # packet).
    let prev = makeSolidFrame(32, 32, 0x00, 0x00, 0x00, 0xFF)
    let curr = makeSolidFrame(32, 32, 0xFF, 0xFF, 0xFF, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 1
    check regions[0].x == 0
    check regions[0].y == 0
    check regions[0].w == 32
    check regions[0].h == 32
    check isFullFrameRegion(regions, 32, 32)

  test "alternating-row full-width changes trip full-frame fallback":
    # Paint every other row across its full width. Each painted row
    # cannot vertically coalesce with its (unpainted) neighbours, so
    # the encoder emits 32 strips of (64*1*4 + 20-byte header) ==
    # 276 bytes each → 32*276+4 == 8836 bytes. Full-frame cost is
    # 64*64*4 == 16384 bytes; 2 × 8836 == 17672 > 16384 trips the
    # 50%-threshold fallback to a single full-frame region.
    let prev = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    var curr = makeSolidFrame(64, 64, 0x00, 0x00, 0x00, 0xFF)
    var y = 0
    while y < 64:
      for x in 0 ..< 64:
        setPixel(curr, x, y, 0xFF, 0x00, 0xFF, 0xFF)
      y += 2
    let regions = computeDiffRegions(prev, curr)
    check isFullFrameRegion(regions, 64, 64)

  test "toDirtyRects lifts Region → DirtyRect with byte-identical " &
       "pixel buffer":
    let prev = makeSolidFrame(8, 8, 0x00, 0x00, 0x00, 0xFF)
    var curr = makeSolidFrame(8, 8, 0x00, 0x00, 0x00, 0xFF)
    setPixel(curr, 3, 3, 0xAA, 0xBB, 0xCC, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    let rects = toDirtyRects(regions)
    check rects.len == regions.len
    for i in 0 ..< rects.len:
      check rects[i].x == regions[i].x
      check rects[i].y == regions[i].y
      check rects[i].w == regions[i].w
      check rects[i].h == regions[i].h
      check rects[i].pixels == regions[i].pixels

  test "encode/decode round-trip through packet.nim for a diff frame":
    # The encoder produces Regions; the bridge promotes them to
    # DirtyRects and hands the frame to `encodeFrame`. The codec must
    # accept the output without raising.
    let prev = makeSolidFrame(16, 16, 0x00, 0x00, 0x00, 0xFF)
    var curr = makeSolidFrame(16, 16, 0x00, 0x00, 0x00, 0xFF)
    setPixel(curr, 4, 4, 0xFF, 0x00, 0x00, 0xFF)
    setPixel(curr, 12, 12, 0x00, 0xFF, 0x00, 0xFF)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 2
    let frame = Frame(kind: fkDiff,
                      flags: FrameFlags(isDiff: true, isVideo: false),
                      width: 16, height: 16,
                      rects: toDirtyRects(regions))
    let enc = encodeFrame(frame)
    let dec = decodeFrame(enc)
    check dec.kind == fkDiff
    check dec.rects.len == 2
    # The encoded byte count must beat the full frame.
    let fullFrameBytes = 14 + 16 * 16 * 4
    check enc.len < fullFrameBytes
