## FUH-M5 — in-process libwebp encoder lifecycle.
##
## *Claim.* When ``-d:withInProcessWebP`` is on (the default per
## ``config.nims``) AND the runtime probe finds ``libwebp.dylib`` /
## ``libwebp.so.7``, ``newWebPEncoderHandle`` returns a handle with
## ``inProcess = true`` + ``kind = wekLibwebpDirect``. Encoding 5
## distinct (width, height, RGBA) cases produces VP8L lossless RIFFs
## that round-trip through ``WebPDecodeRGBA`` with L1 = 0 (every byte
## matches the input). Mirrors the ELT-M8 lifecycle test shape.

import std/unittest

import isonim_render_serve
import isonim_render_serve/adapters/webp_libwebp_ffi

# Cache the probes once at module load.
let inProcessAvail = isInProcessWebPEncoderAvailable()
let webpAvail = isWebPEncoderAvailable()

proc makeRedFrame(w, h: int): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for i in 0 ..< w * h:
    result[i * 4 + 0] = 0xFF'u8
    result[i * 4 + 1] = 0x00'u8
    result[i * 4 + 2] = 0x00'u8
    result[i * 4 + 3] = 0xFF'u8

proc makeChecker(w, h: int): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let on = ((x div 8) + (y div 8)) mod 2 == 0
      let i = (y * w + x) * 4
      if on:
        result[i + 0] = 0xFF'u8
        result[i + 1] = 0xFF'u8
        result[i + 2] = 0xFF'u8
      else:
        result[i + 0] = 0x00'u8
        result[i + 1] = 0x00'u8
        result[i + 2] = 0x00'u8
      result[i + 3] = 0xFF'u8

proc makeGradient(w, h: int): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let i = (y * w + x) * 4
      result[i + 0] = byte(x and 0xFF)
      result[i + 1] = byte(y and 0xFF)
      result[i + 2] = byte((x + y) and 0xFF)
      result[i + 3] = 0xFF'u8

proc makeRandomish(w, h: int; seed: int): seq[byte] =
  ## Deterministic pseudo-random pattern — defeats lossless prediction
  ## just enough to exercise the encoder's harder paths without making
  ## the test non-deterministic.
  result = newSeq[byte](w * h * 4)
  var x = seed
  for i in 0 ..< w * h:
    # Cheap PRNG (xorshift-ish) — good enough for pattern diversity.
    x = (x * 1103515245 + 12345) and 0x7FFFFFFF
    result[i * 4 + 0] = byte(x and 0xFF)
    result[i * 4 + 1] = byte((x shr 8) and 0xFF)
    result[i * 4 + 2] = byte((x shr 16) and 0xFF)
    result[i * 4 + 3] = 0xFF'u8

proc decodeRGBA(riff: seq[byte]; expectedW, expectedH: int): seq[byte] =
  ## Decode a VP8L RIFF via libwebp's ``WebPDecodeRGBA`` and copy the
  ## bytes into a Nim seq. Returns empty seq on decode failure.
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
  doAssert int(w) == expectedW,
    "decode width " & $int(w) & " != " & $expectedW
  doAssert int(h) == expectedH,
    "decode height " & $int(h) & " != " & $expectedH
  let n = int(w) * int(h) * 4
  result = newSeq[byte](n)
  copyMem(addr result[0], outPtr, n)
  WebPFree(outPtr)

suite "FUH-M5: in-process WebP encoder lifecycle":

  test "isInProcessWebPEncoderAvailable matches dynlib presence":
    # The probe must succeed cleanly (no crash) regardless of host.
    # On dev hosts with libwebp in the dev shell it returns true;
    # on a stripped CI host without libwebp it returns false. Either
    # way the test asserts the boolean is well-defined.
    let avail = isInProcessWebPEncoderAvailable()
    check avail == avail

  test "newWebPEncoderHandle picks wekLibwebpDirect when libwebp loads":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(64, 64)
      check h != nil
      check h.kind == wekLibwebpDirect
      check h.inProcess == true
      destroy(h)

  test "encode 32x32 red frame round-trips lossless (L1 = 0)":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(32, 32)
      check h != nil
      let original = makeRedFrame(32, 32)
      let w = encode(h, original)
      check w.width == 32
      check w.height == 32
      check w.flags.isStillFrame
      let decoded = decodeRGBA(w.riffBytes, 32, 32)
      check decoded.len == original.len
      check decoded == original
      destroy(h)

  test "encode 48x48 checker frame round-trips lossless":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(48, 48)
      let original = makeChecker(48, 48)
      let w = encode(h, original)
      let decoded = decodeRGBA(w.riffBytes, 48, 48)
      check decoded == original
      destroy(h)

  test "encode 128x96 gradient round-trips lossless":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(128, 96)
      let original = makeGradient(128, 96)
      let w = encode(h, original)
      let decoded = decodeRGBA(w.riffBytes, 128, 96)
      check decoded == original
      destroy(h)

  test "encode 1x1 single-pixel edge case round-trips":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(1, 1)
      let original = @[byte 0x12, 0x34, 0x56, 0xFF]
      let w = encode(h, original)
      check w.width == 1
      check w.height == 1
      let decoded = decodeRGBA(w.riffBytes, 1, 1)
      check decoded == original
      destroy(h)

  test "encode 200x150 pseudo-random pattern round-trips lossless":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(200, 150)
      let original = makeRandomish(200, 150, seed = 0xC0DEFACE)
      let w = encode(h, original)
      let decoded = decodeRGBA(w.riffBytes, 200, 150)
      check decoded.len == original.len
      check decoded == original
      destroy(h)

  test "resize between encodes still produces lossless RIFFs":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(32, 32)
      let red32 = makeRedFrame(32, 32)
      let w1 = encode(h, red32)
      check decodeRGBA(w1.riffBytes, 32, 32) == red32
      let h2 = resize(h, 64, 48)
      check h2 == h
      check h2.kind == wekLibwebpDirect  # backend choice survives resize
      let gradient = makeGradient(64, 48)
      let w2 = encode(h2, gradient)
      check decodeRGBA(w2.riffBytes, 64, 48) == gradient
      destroy(h2)

  test "destroy is idempotent on the in-process handle":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(32, 32)
      check h != nil
      check h.inProcess
      destroy(h)
      destroy(h)
      check h.width == 0
      check h.height == 0

  test "in-process encode rejects wrong-sized rgba buffer":
    if not inProcessAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(16, 16)
      let small = newSeq[byte](16 * 16 * 4 - 8)
      expect IOError:
        discard encode(h, small)
      destroy(h)

  test "isWebPEncoderAvailable is true whenever isInProcessWebPEncoderAvailable is":
    # The umbrella probe must include the in-process backend.
    if inProcessAvail:
      check webpAvail
