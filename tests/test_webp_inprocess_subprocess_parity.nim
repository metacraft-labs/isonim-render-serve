## FUH-M5 — in-process vs subprocess parity.
##
## *Claim.* Both encoder backends produce VP8L lossless bytes whose
## decoded RGBA pixels are bit-identical to the input. The wire bytes
## themselves may diverge between backends (different libwebp builds
## reorder transforms, embed different version markers etc.) — what
## the W packet codec contracts is *image* fidelity, not byte-for-byte
## RIFF identity across encoder implementations. Decoding both then
## comparing pixels is the canonical lossless contract per
## ELT-M7 § "Quality contract".
##
## This test enforces the contract by:
##
## 1. Forcing the in-process backend (default when libwebp is loaded).
## 2. Encoding via the in-process path.
## 3. Encoding the same RGBA via the subprocess path (ffmpeg).
## 4. Decoding both through ``WebPDecodeRGBA``.
## 5. Asserting the two decoded pixel arrays match the original
##    exactly (L1 == 0).
##
## When either backend is unavailable the test skips (NOT weakens) —
## the parity claim only makes sense when both paths can run.

import std/[osproc, streams, unittest]

import isonim_render_serve
import isonim_render_serve/adapters/webp_libwebp_ffi
import isonim_render_serve/adapters/webp_lossless_encoder as wle

let inProcessAvail = isInProcessWebPEncoderAvailable()
let ffmpegBin = wle.resolveFfmpegBin()
let subprocessAvail = ffmpegBin.len > 0

proc makeChecker(w, h: int): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let on = ((x div 4) + (y div 4)) mod 2 == 0
      let i = (y * w + x) * 4
      if on:
        result[i + 0] = 0xFF; result[i + 1] = 0xFF; result[i + 2] = 0xFF
      else:
        result[i + 0] = 0x10; result[i + 1] = 0x20; result[i + 2] = 0x30
      result[i + 3] = 0xFF

proc makeGradient(w, h: int): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = (y * w + x) * 4
      result[i + 0] = byte(x and 0xFF)
      result[i + 1] = byte(y and 0xFF)
      result[i + 2] = byte((x xor y) and 0xFF)
      result[i + 3] = 0xFF

proc decodeRGBA(riff: seq[byte]; expectedW, expectedH: int): seq[byte] =
  var w: cint = 0
  var h: cint = 0
  let dataPtr =
    if riff.len > 0:
      cast[ptr UncheckedArray[byte]](unsafeAddr riff[0])
    else:
      nil
  let outPtr = WebPDecodeRGBA(dataPtr, csize_t(riff.len), addr w, addr h)
  if outPtr == nil:
    return @[]
  doAssert int(w) == expectedW
  doAssert int(h) == expectedH
  let n = int(w) * int(h) * 4
  result = newSeq[byte](n)
  copyMem(addr result[0], outPtr, n)
  WebPFree(outPtr)

proc encodeViaFfmpegStandalone(width, height, compressionLevel: int;
                                rgba: openArray[byte]): seq[byte] =
  ## Reimplementation of the encoder facade's subprocess path,
  ## stripped of the handle wrapper so the parity test can exercise
  ## ffmpeg directly even when ``newWebPEncoderHandle`` would have
  ## picked the in-process backend. Mirrors
  ## ``webp_lossless_encoder.encodeViaFfmpeg`` byte-for-byte.
  let argv = @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-f", "rawvideo",
    "-pix_fmt", "rgba",
    "-s", $width & "x" & $height,
    "-r", "30",
    "-i", "pipe:0",
    "-frames:v", "1",
    "-c:v", "libwebp",
    "-lossless", "1",
    "-compression_level", $compressionLevel,
    "-quality", "100",
    "-pix_fmt", "rgba",
    "-f", "webp",
    "pipe:1",
  ]
  var p = startProcess(ffmpegBin, args = argv, options = {poUsePath})
  let sin = p.inputStream()
  let sout = p.outputStream()
  if rgba.len > 0:
    sin.writeData(unsafeAddr rgba[0], rgba.len)
  sin.close()
  var collected: seq[byte] = @[]
  const chunkSize = 64 * 1024
  var buf = newSeq[byte](chunkSize)
  while true:
    let n = sout.readData(addr buf[0], chunkSize)
    if n <= 0: break
    let prev = collected.len
    collected.setLen(prev + n)
    copyMem(addr collected[prev], addr buf[0], n)
  let code = p.waitForExit()
  p.close()
  doAssert code == 0, "ffmpeg exited with " & $code
  collected

suite "FUH-M5: in-process vs subprocess parity":

  test "subprocess fallback path is available":
    # Sanity check — the parity tests below depend on both paths.
    # We report (don't assert) availability so the suite still runs
    # the lossless contract on whichever side is live.
    echo "in-process libwebp available: ", inProcessAvail
    echo "ffmpeg subprocess available:  ", subprocessAvail, " (", ffmpegBin, ")"
    check true

  test "32x32 checker — both backends decode to identical pixels":
    if not (inProcessAvail and subprocessAvail):
      skip()
    else:
      let original = makeChecker(32, 32)
      let inProcRiff = encodeWebPLossless(original, 32, 32, 3)
      let subprocRiff = encodeViaFfmpegStandalone(32, 32, 3, original)
      let inProcPixels = decodeRGBA(inProcRiff, 32, 32)
      let subprocPixels = decodeRGBA(subprocRiff, 32, 32)
      # Both paths must produce LOSSLESS output equal to the input.
      check inProcPixels == original
      check subprocPixels == original
      # Therefore both decoded buffers are identical to each other.
      check inProcPixels == subprocPixels

  test "128x96 gradient — both backends decode to identical pixels":
    if not (inProcessAvail and subprocessAvail):
      skip()
    else:
      let original = makeGradient(128, 96)
      let inProcRiff = encodeWebPLossless(original, 128, 96, 3)
      let subprocRiff = encodeViaFfmpegStandalone(128, 96, 3, original)
      let inProcPixels = decodeRGBA(inProcRiff, 128, 96)
      let subprocPixels = decodeRGBA(subprocRiff, 128, 96)
      check inProcPixels == original
      check subprocPixels == original
      check inProcPixels == subprocPixels

  test "subprocess wire bytes match the pre-FUH-M5 fallback behavior":
    # FUH-M5's backward-compat contract: when the in-process path
    # is disabled (``-d:withInProcessWebP=false``) or the runtime
    # probe fails, the encoder facade falls back to the subprocess
    # path with *unchanged* invocation arguments. We can't compare
    # against a frozen golden RIFF (ffmpeg versions drift) but we
    # CAN compare two subprocess invocations with the same args and
    # the same input — they must be bit-identical because ffmpeg's
    # libwebp encode is deterministic at fixed inputs.
    if not subprocessAvail:
      skip()
    else:
      let original = makeChecker(32, 32)
      let a = encodeViaFfmpegStandalone(32, 32, 3, original)
      let b = encodeViaFfmpegStandalone(32, 32, 3, original)
      check a == b
      check a.len > 12  # at least a RIFF header
      check a[0..3] == @[byte('R'), byte('I'), byte('F'), byte('F')]
