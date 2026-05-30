## FUH-M5 — in-process WebP encoder latency budget.
##
## *Claim.* The in-process libwebp encoder lands the median 1280×800
## RGBA-to-VP8L encode at compression_level=3 under the 16 ms 60 FPS
## budget, vs. the subprocess path's ~133 ms median (FUH-M4 audit
## § 5.1). 100 frames per measurement; reports min / median / p99 for
## the FUH-M5 report.
##
## Skipped (NOT weakened) when the in-process backend isn't available
## (no libwebp dynlib at runtime) — the test enforces the budget
## ONLY against the path the test exists to measure. The umbrella
## ``isWebPEncoderAvailable`` covers the subprocess case in
## ``test_webp_encoder_lifecycle.nim``.

import std/[algorithm, monotimes, strutils, times, unittest]

import isonim_render_serve

let inProcessAvail = isInProcessWebPEncoderAvailable()

const
  BudgetMs = 16
    ## 60 FPS budget per the FUH-M4 audit § 5.2 "conservative target".
  Iterations = 100
  TestWidth = 1280
  TestHeight = 800

proc makeUiContent(w, h: int): seq[byte] =
  ## Synthetic UI-ish content — flat-ish background with a few coloured
  ## bands. Approximates the task_app editor surface (mostly flat with
  ## sparse high-contrast text / panels). The bench codec uses a
  ## similar shape for its reference measurements (FUH-M4 audit § 5.1).
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = (y * w + x) * 4
      # Three horizontal bands of slightly different gray, plus a
      # rectangle in the lower right.
      var r: byte
      var g: byte
      var b: byte
      if y < h div 3:
        r = 0xF8; g = 0xF8; b = 0xF8
      elif y < 2 * h div 3:
        r = 0xF0; g = 0xF0; b = 0xF0
      else:
        r = 0xE8; g = 0xE8; b = 0xE8
      if x > 2 * w div 3 and y > 2 * h div 3:
        r = 0x33; g = 0x66; b = 0xCC
      result[i + 0] = r
      result[i + 1] = g
      result[i + 2] = b
      result[i + 3] = 0xFF'u8

proc median(times: seq[float]): float =
  var s = times
  s.sort()
  if s.len == 0: return 0.0
  if s.len mod 2 == 0:
    (s[s.len div 2 - 1] + s[s.len div 2]) / 2.0
  else:
    s[s.len div 2]

proc percentile(times: seq[float]; p: float): float =
  var s = times
  s.sort()
  if s.len == 0: return 0.0
  let idx = int(float(s.len - 1) * p)
  s[idx]

suite "FUH-M5: in-process WebP encoder latency budget":

  test "median 1280x800 cl=3 encode lands under 16 ms":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(TestWidth, TestHeight,
                                    compressionLevel = 3)
      check h != nil
      check h.kind == wekLibwebpDirect
      let rgba = makeUiContent(TestWidth, TestHeight)
      check rgba.len == TestWidth * TestHeight * 4

      # Warm-up — first frame typically has dynlib resolution + JIT-
      # ish cache-miss overhead that's not representative.
      discard encode(h, rgba)

      var samples: seq[float] = @[]
      for i in 0 ..< Iterations:
        let t0 = getMonoTime()
        discard encode(h, rgba)
        let dt = getMonoTime() - t0
        samples.add float(inMicroseconds(dt)) / 1000.0

      let minMs = samples.min()
      let medMs = median(samples)
      let p99Ms = percentile(samples, 0.99)
      let maxMs = samples.max()

      echo ""
      echo "FUH-M5 in-process WebP encoder budget @ 1280x800 cl=3 N=", Iterations
      echo "  min    : ", minMs.formatFloat(ffDecimal, 2), " ms"
      echo "  median : ", medMs.formatFloat(ffDecimal, 2), " ms"
      echo "  p99    : ", p99Ms.formatFloat(ffDecimal, 2), " ms"
      echo "  max    : ", maxMs.formatFloat(ffDecimal, 2), " ms"
      echo "  budget : ", BudgetMs, " ms (60 FPS)"
      echo ""

      check medMs <= float(BudgetMs)
      destroy(h)

  test "median at compression_level=6 still finishes in finite time":
    # Not a budget assertion — cl=6 is the bench's worst case; we
    # only verify the encoder doesn't hang or loop. The FUH-M5
    # production tuning is cl=3 (per ELT-M7); cl=6 is a safety check
    # that the FFI doesn't break the slow path.
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(640, 480, compressionLevel = 6)
      check h != nil
      let rgba = makeUiContent(640, 480)
      let t0 = getMonoTime()
      discard encode(h, rgba)
      let dt = getMonoTime() - t0
      let ms = float(inMicroseconds(dt)) / 1000.0
      echo "FUH-M5 in-process WebP cl=6 @ 640x480 first-encode: ",
           ms.formatFloat(ffDecimal, 2), " ms"
      check ms < 2000.0   # hard upper bound; would only fail on a hang
      destroy(h)
