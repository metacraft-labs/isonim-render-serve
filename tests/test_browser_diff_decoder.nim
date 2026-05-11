## test_browser_diff_decoder — Nim-side simulation of the
## `static/index.html` diff-application path.
##
## The browser client (see `static/index.html`'s `handleF` function)
## handles two F-packet flavours:
##
##   * `flags & 0x01 == 0` (full frame): `putImageData(img, 0, 0)`
##     where `img` is an `ImageData` over the full payload.
##   * `flags & 0x01 == 1` (diff frame): parse `u32 count`, then
##     loop `count × {x, y, w, h, length, RGBA bytes}` and call
##     `putImageData(img, x, y)` for each region.
##
## Since `isonim-render-serve` doesn't ship Playwright (the
## browser-end correctness is covered by manual testing of
## `static/index.html`), this Nim-side test exercises the equivalent
## byte-level decode + apply algorithm. The encoded bytes are
## produced by the same `encodeFrame` path the bridge uses on the
## wire, so any divergence between this test and the real browser
## client would be a JS bug, not an encoder bug.

import std/[unittest]

import isonim_render_serve

const CanvasW = 16
const CanvasH = 16

proc emptyCanvas(): seq[byte] =
  result = newSeq[byte](CanvasW * CanvasH * 4)
  # Opaque-black initial state mimics the browser's pristine canvas.
  var j = 3
  while j < result.len:
    result[j] = 0xFF
    j += 4

proc applyFullFrame(canvas: var seq[byte]; f: Frame) =
  doAssert f.kind == fkFull
  doAssert canvas.len == f.pixels.len
  for i in 0 ..< canvas.len:
    canvas[i] = f.pixels[i]

proc applyDiffFrame(canvas: var seq[byte]; f: Frame) =
  ## Equivalent of `static/index.html`'s `for (let i = 0; i < count;
  ## i++) ctx.putImageData(...)` loop.
  doAssert f.kind == fkDiff
  let stride = f.width * 4
  for r in f.rects:
    for row in 0 ..< r.h:
      let srcOff = row * r.w * 4
      let dstOff = (r.y + row) * stride + r.x * 4
      for k in 0 ..< r.w * 4:
        canvas[dstOff + k] = r.pixels[srcOff + k]

suite "RS-M3: browser diff decoder simulation":

  test "decoded diff packet applied to canvas reproduces reference frame":
    # Build prev and curr frames; only one rectangle in `curr` differs.
    var prevPixels = emptyCanvas()
    var currPixels = emptyCanvas()
    # Paint a 3x3 block at (5, 5) on `curr`.
    for dy in 0 ..< 3:
      for dx in 0 ..< 3:
        let off = ((5 + dy) * CanvasW + (5 + dx)) * 4
        currPixels[off] = 0xFF
        currPixels[off + 1] = 0x80
        currPixels[off + 2] = 0x40
        currPixels[off + 3] = 0xFF
    let prev = Frame(kind: fkFull,
                     flags: FrameFlags(isDiff: false, isVideo: false),
                     width: CanvasW, height: CanvasH, pixels: prevPixels)
    let curr = Frame(kind: fkFull,
                     flags: FrameFlags(isDiff: false, isVideo: false),
                     width: CanvasW, height: CanvasH, pixels: currPixels)

    # Encoder produces the diff regions; wire-encode them as the
    # bridge does.
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 1
    check regions[0].x == 5
    check regions[0].y == 5
    check regions[0].w == 3
    check regions[0].h == 3
    let diffFrame = Frame(kind: fkDiff,
                          flags: FrameFlags(isDiff: true, isVideo: false),
                          width: CanvasW, height: CanvasH,
                          rects: toDirtyRects(regions))
    let wire = encodeFrame(diffFrame)

    # Decode the wire bytes — exactly what the browser does after
    # reading the binary WS message.
    let decoded = decodeFrame(wire)
    check decoded.kind == fkDiff
    check decoded.rects.len == 1

    # Apply the decoded frame to a canvas seeded with `prev`'s
    # pixels. Result must equal `curr`'s pixels byte-for-byte.
    var canvas = prevPixels
    applyDiffFrame(canvas, decoded)
    check canvas == currPixels

  test "multi-rect diff applied to canvas reproduces reference frame":
    var prevPixels = emptyCanvas()
    var currPixels = emptyCanvas()
    # Change pixel (1, 1).
    let off1 = (1 * CanvasW + 1) * 4
    currPixels[off1] = 0xFF; currPixels[off1 + 1] = 0x00
    currPixels[off1 + 2] = 0x00; currPixels[off1 + 3] = 0xFF
    # Change pixel (14, 12) — far enough that the encoder won't
    # coalesce them.
    let off2 = (12 * CanvasW + 14) * 4
    currPixels[off2] = 0x00; currPixels[off2 + 1] = 0xFF
    currPixels[off2 + 2] = 0x00; currPixels[off2 + 3] = 0xFF

    let prev = Frame(kind: fkFull,
                     flags: FrameFlags(isDiff: false, isVideo: false),
                     width: CanvasW, height: CanvasH, pixels: prevPixels)
    let curr = Frame(kind: fkFull,
                     flags: FrameFlags(isDiff: false, isVideo: false),
                     width: CanvasW, height: CanvasH, pixels: currPixels)
    let regions = computeDiffRegions(prev, curr)
    check regions.len == 2
    let diffFrame = Frame(kind: fkDiff,
                          flags: FrameFlags(isDiff: true, isVideo: false),
                          width: CanvasW, height: CanvasH,
                          rects: toDirtyRects(regions))
    let wire = encodeFrame(diffFrame)
    let decoded = decodeFrame(wire)
    check decoded.kind == fkDiff
    check decoded.rects.len == 2

    var canvas = prevPixels
    applyDiffFrame(canvas, decoded)
    check canvas == currPixels

  test "full-frame F packet seeds the canvas correctly":
    # The first frame on a fresh connection is always full; the
    # browser client's `if (!isDiff)` branch must produce a canvas
    # byte-identical to the frame payload.
    var pixels = newSeq[byte](CanvasW * CanvasH * 4)
    for i in 0 ..< pixels.len: pixels[i] = byte((i * 7) and 0xFF)
    let f = Frame(kind: fkFull,
                  flags: FrameFlags(isDiff: false, isVideo: false),
                  width: CanvasW, height: CanvasH, pixels: pixels)
    let wire = encodeFrame(f)
    let decoded = decodeFrame(wire)
    check decoded.kind == fkFull
    var canvas = emptyCanvas()
    applyFullFrame(canvas, decoded)
    check canvas == pixels
