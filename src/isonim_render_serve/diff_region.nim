## Diff-region encoder — RS-M3.
##
## Compares two same-dimensioned full RGBA frames and computes a set
## of rectangular regions that cover every changed pixel. The result
## becomes the payload of a diff F packet (per RS-M0 spec: bit 0 of
## the F flag byte set, payload = `u32 count + count × {u32 x, u32 y,
## u32 w, u32 h, u32 length, RGBA bytes}`).
##
## Algorithm (kept deliberately simple — see RS-M3 in
## `codetracer-specs/Front-Ends/IsoNim/isonim-render-stream.status.org`
## for the scope rules):
##
##   1. Per-scanline scan: walk the two frames in row-major lockstep.
##      For each scanline find the leftmost and rightmost changed
##      pixel; emit a height-1 strip covering that range (or skip if
##      the scanline is identical).
##   2. Vertical coalesce: merge adjacent rows whose strips' x ranges
##      overlap (or touch) into multi-row rectangles. This avoids
##      shipping N tiny strips when a contiguous block changed.
##   3. Full-frame fallback: if the total RGBA cost of the merged
##      regions exceeds 50% of the full-frame cost, return a single
##      rectangle that spans the whole frame. The bridge then emits
##      it as a non-diff F packet, side-stepping the per-rect header
##      overhead.
##
## The encoder is pure — it neither owns the prior frame snapshot nor
## decides whether to emit a diff or a full F packet. Those policy
## decisions live in `bridge.nim`.

import ./packet

type
  Region* = object
    ## A rectangular region with RGBA8888 pixels carved out of the
    ## current frame. Shape matches `packet.DirtyRect`; the caller
    ## promotes it to a `DirtyRect` for wire encoding.
    x*, y*, w*, h*: int
    pixels*: seq[byte]

  ScanlineStrip = object
    ## Internal: leftmost/rightmost changed column on a single row,
    ## inclusive. `present == false` means the row is identical.
    present: bool
    minX, maxX: int

proc fullFrameRegion(curr: Frame): Region =
  ## Construct a region that spans `curr` entirely — used as the
  ## fallback when diffing would not save bandwidth.
  doAssert curr.kind == fkFull,
    "diff-region encoder requires full-frame inputs"
  Region(x: 0, y: 0, w: curr.width, h: curr.height,
         pixels: curr.pixels)

proc extractRegionPixels(curr: Frame; x, y, w, h: int): seq[byte] =
  ## Pull a w×h tile of RGBA bytes out of the row-major frame buffer.
  result = newSeq[byte](w * h * 4)
  let stride = curr.width * 4
  for row in 0 ..< h:
    let srcOff = (y + row) * stride + x * 4
    let dstOff = row * w * 4
    for k in 0 ..< w * 4:
      result[dstOff + k] = curr.pixels[srcOff + k]

proc scanlineStrip(prev, curr: Frame; y: int): ScanlineStrip =
  ## Walk one row left-to-right and right-to-left; return the
  ## inclusive range of differing columns, or `present=false`.
  let w = curr.width
  let rowOff = y * w * 4
  var lo = -1
  var hi = -1
  # Find leftmost change.
  for x in 0 ..< w:
    let p = rowOff + x * 4
    if prev.pixels[p] != curr.pixels[p] or
       prev.pixels[p + 1] != curr.pixels[p + 1] or
       prev.pixels[p + 2] != curr.pixels[p + 2] or
       prev.pixels[p + 3] != curr.pixels[p + 3]:
      lo = x
      break
  if lo < 0:
    return ScanlineStrip(present: false)
  # Find rightmost change.
  for x in countdown(w - 1, lo):
    let p = rowOff + x * 4
    if prev.pixels[p] != curr.pixels[p] or
       prev.pixels[p + 1] != curr.pixels[p + 1] or
       prev.pixels[p + 2] != curr.pixels[p + 2] or
       prev.pixels[p + 3] != curr.pixels[p + 3]:
      hi = x
      break
  ScanlineStrip(present: true, minX: lo, maxX: hi)

proc rectsOverlap(aMin, aMax, bMin, bMax: int): bool =
  ## Treat strips as overlapping if their x ranges overlap *or*
  ## touch (b directly adjacent). Used to coalesce vertical neighbours.
  not (aMax < bMin or bMax < aMin)

proc computeDiffRegions*(prev, curr: Frame;
                        minRegionPixels: int = 64): seq[Region] =
  ## Compare two same-dimensioned full RGBA frames and return the
  ## rectangular regions covering every changed pixel.
  ##
  ## *Invariants:*
  ##   - `prev.kind == fkFull` and `curr.kind == fkFull`.
  ##   - `prev.width == curr.width` and `prev.height == curr.height`.
  ##
  ## *Returns:*
  ##   - Empty seq when the frames are bit-identical.
  ##   - A single full-frame region when the merged diff would cost
  ##     more than 50% of the full-frame payload. The bridge detects
  ##     this case (one region equal to the whole frame) and emits a
  ##     non-diff F packet, which is cheaper because it skips the
  ##     per-rect header overhead.
  ##   - Otherwise: one or more sub-frame rectangles, each carrying
  ##     its own RGBA8888 row-major pixel buffer.
  ##
  ## `minRegionPixels` is the floor for a standalone region — strips
  ## smaller than that are still emitted (correctness > pathological
  ## micro-optimisation) but the coalesce pass tends to fold them
  ## into larger neighbours regardless.
  doAssert prev.kind == fkFull and curr.kind == fkFull,
    "diff-region encoder requires full-frame inputs"
  doAssert prev.width == curr.width and prev.height == curr.height,
    "diff-region encoder requires same-dimensioned frames"
  let w = curr.width
  let h = curr.height
  if w == 0 or h == 0:
    return @[]

  # Pass 1: per-scanline strip extraction.
  var strips = newSeq[ScanlineStrip](h)
  for y in 0 ..< h:
    strips[y] = scanlineStrip(prev, curr, y)

  # Pass 2: vertical coalesce. Walk strips top-to-bottom; merge a
  # running rectangle while consecutive rows have overlapping or
  # touching x-ranges; emit the rectangle when the run breaks.
  var rects: seq[tuple[x, y, w, h: int]] = @[]
  var inRun = false
  var runMinX, runMaxX, runStartY, runEndY: int
  for y in 0 ..< h:
    let s = strips[y]
    if not s.present:
      if inRun:
        rects.add (x: runMinX, y: runStartY,
                   w: runMaxX - runMinX + 1,
                   h: runEndY - runStartY + 1)
        inRun = false
      continue
    if not inRun:
      inRun = true
      runMinX = s.minX
      runMaxX = s.maxX
      runStartY = y
      runEndY = y
    else:
      if rectsOverlap(runMinX, runMaxX, s.minX, s.maxX):
        runMinX = min(runMinX, s.minX)
        runMaxX = max(runMaxX, s.maxX)
        runEndY = y
      else:
        rects.add (x: runMinX, y: runStartY,
                   w: runMaxX - runMinX + 1,
                   h: runEndY - runStartY + 1)
        runMinX = s.minX
        runMaxX = s.maxX
        runStartY = y
        runEndY = y
  if inRun:
    rects.add (x: runMinX, y: runStartY,
               w: runMaxX - runMinX + 1,
               h: runEndY - runStartY + 1)

  if rects.len == 0:
    return @[]

  # Pass 3: cost check vs. full-frame. Each rect adds 20 bytes of
  # header (`x, y, w, h, length` × 4) plus its RGBA payload. Plus 4
  # bytes for the leading `count` u32. Compare against the full-frame
  # cost (`w * h * 4`).
  var diffCost = 4
  for r in rects:
    diffCost += 20 + r.w * r.h * 4
  let fullCost = w * h * 4
  if diffCost * 2 > fullCost:
    return @[fullFrameRegion(curr)]

  # Materialize the regions: pull each rect's pixels out of curr.
  result = newSeqOfCap[Region](rects.len)
  for r in rects:
    let _ = minRegionPixels  # threshold informs callers; current impl
                             # keeps every coalesced rect (folding tiny
                             # strips happens during vertical merge).
    result.add Region(x: r.x, y: r.y, w: r.w, h: r.h,
                      pixels: extractRegionPixels(curr,
                                                  r.x, r.y, r.w, r.h))

proc toDirtyRects*(regions: openArray[Region]): seq[DirtyRect] =
  ## Lift the pure `Region` shape into the wire `DirtyRect` shape.
  ## Cheap helper that keeps the encoder decoupled from packet.nim's
  ## exact field names (they happen to match today, but the wire
  ## struct could grow extra fields later — e.g. a per-rect codec
  ## flag once video lands).
  result = newSeqOfCap[DirtyRect](regions.len)
  for r in regions:
    result.add DirtyRect(x: r.x, y: r.y, w: r.w, h: r.h,
                         pixels: r.pixels)

proc isFullFrameRegion*(regions: openArray[Region];
                       width, height: int): bool =
  ## Detect the fallback case `computeDiffRegions` returns when
  ## diffing wouldn't save bandwidth. Bridge code uses this to choose
  ## between emitting an F-diff and an F-full packet.
  regions.len == 1 and regions[0].x == 0 and regions[0].y == 0 and
    regions[0].w == width and regions[0].h == height
