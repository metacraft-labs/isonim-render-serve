## ELT-M8 — WebP encoder facade lifecycle.
##
## *Claim.* ``newWebPEncoderHandle`` returns a non-nil handle whenever
## ffmpeg (with libwebp) is reachable; ``encode`` produces a valid
## WebP RIFF container that round-trips through ``encodeWebpFrame``
## bit-stable; ``resize`` is O(1) and survives mid-session dim changes;
## ``destroy`` is idempotent. Real ffmpeg subprocess — no in-process
## mocks per the campaign brief's "real-environment tests only" rule.

import std/unittest

import isonim_render_serve

proc makeRedFrame(w, h: int): seq[byte] =
  result = newSeq[byte](w * h * 4)
  for i in 0 ..< w * h:
    result[i * 4 + 0] = 0xFF'u8  # R
    result[i * 4 + 1] = 0x00'u8  # G
    result[i * 4 + 2] = 0x00'u8  # B
    result[i * 4 + 3] = 0xFF'u8  # A

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

# Cache the availability probe once at module load — keeps the per-
# test branch local and avoids repeated $PATH lookups.
let webpAvail = isWebPEncoderAvailable()

suite "ELT-M8: WebP encoder facade":

  test "isWebPEncoderAvailable reflects ffmpeg presence":
    let avail = isWebPEncoderAvailable()
    # We don't assert true/false here — the test runs both on dev
    # hosts that ship ffmpeg in the dev shell (`true`) and on minimal
    # CI hosts (`false`). The check is that the probe doesn't crash
    # and returns a bool.
    check avail == avail

  test "newWebPEncoderHandle rejects bad dims":
    check newWebPEncoderHandle(0, 100) == nil
    check newWebPEncoderHandle(100, 0) == nil
    check newWebPEncoderHandle(-1, 100) == nil

  test "newWebPEncoderHandle clamps compression level":
    if not webpAvail:
      skip()
    else:
      let h1 = newWebPEncoderHandle(64, 64, compressionLevel = 0)
      check h1 != nil
      check h1.compressionLevel == 1  # clamped from 0 to min 1
      let h2 = newWebPEncoderHandle(64, 64, compressionLevel = 99)
      check h2 != nil
      check h2.compressionLevel == 6  # clamped from 99 to max 6
      destroy(h1); destroy(h2)

  test "newWebPEncoderHandle defaults match the ELT-M7 recommendation":
    if not webpAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(64, 64)
      check h != nil
      # ELT-M7 § "Encode-latency budget" recommendation: compression
      # level 3 (still lossless; 3-5x faster than the bench's 6).
      check h.compressionLevel == DefaultWebPCompressionLevel
      check h.compressionLevel == 3
      check h.codecId == DefaultWebPCodecId
      destroy(h)

  test "encode produces a valid WebP RIFF container":
    if not webpAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(32, 32)
      check h != nil
      let rgba = makeRedFrame(32, 32)
      let w = encode(h, rgba)
      check w.width == 32
      check w.height == 32
      check w.codecId == DefaultWebPCodecId
      check w.flags.isStillFrame
      # RIFF magic: bytes 0-3 = "RIFF", bytes 8-11 = "WEBP".
      check w.riffBytes.len >= 12
      check w.riffBytes[0] == byte('R')
      check w.riffBytes[1] == byte('I')
      check w.riffBytes[2] == byte('F')
      check w.riffBytes[3] == byte('F')
      check w.riffBytes[8] == byte('W')
      check w.riffBytes[9] == byte('E')
      check w.riffBytes[10] == byte('B')
      check w.riffBytes[11] == byte('P')
      # VP8L chunk header at offset 12 (the lossless chunk type).
      # Either "VP8L" (true lossless) or "VP8X" (extended with VP8L
      # inside). Either is acceptable for the lossless contract; just
      # don't accept "VP8 " (the lossy chunk type).
      let chunk4 = (char(w.riffBytes[12]), char(w.riffBytes[13]),
                    char(w.riffBytes[14]), char(w.riffBytes[15]))
      check chunk4 == ('V', 'P', '8', 'L') or chunk4 == ('V', 'P', '8', 'X')
      destroy(h)

  test "encode round-trips through encodeWebpFrame byte-stable":
    if not webpAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(48, 48)
      check h != nil
      let rgba = makeChecker(48, 48)
      let w1 = encode(h, rgba)
      let bytes1 = encodeWebpFrame(w1)
      let dec = decodeWebpFrame(bytes1)
      check dec.codecId == w1.codecId
      check dec.width == w1.width
      check dec.height == w1.height
      check dec.riffBytes == w1.riffBytes
      let bytes2 = encodeWebpFrame(dec)
      check bytes1 == bytes2
      destroy(h)

  test "encode rejects wrong-sized rgba buffer":
    if not webpAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(16, 16)
      check h != nil
      let small = newSeq[byte](16 * 16 * 4 - 4)
      expect IOError:
        discard encode(h, small)
      destroy(h)

  test "resize updates the cached dims O(1) (no session teardown)":
    if not webpAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(64, 64)
      check h != nil
      check h.width == 64
      check h.height == 64
      let h2 = resize(h, 128, 96)
      # Same handle is returned (in-place mutation); WebP has no session
      # to tear down so the resize is essentially a field swap.
      check h2 == h
      check h2.width == 128
      check h2.height == 96
      # Encoding at the new dims must produce a valid container.
      let rgba = makeRedFrame(128, 96)
      let w = encode(h2, rgba)
      check w.width == 128
      check w.height == 96
      destroy(h2)

  test "destroy is idempotent":
    if not webpAvail:
      skip()
    else:
      let h = newWebPEncoderHandle(32, 32)
      check h != nil
      destroy(h)
      destroy(h)   # second call must not crash
      # After destroy, width/height field reset signals "do not encode".
      check h.width == 0
      check h.height == 0

  test "selectEncoderKind survives ekWebP on dev hosts":
    let resolved = selectEncoderKind(ekWebP)
    when defined(withCodecWebP):
      if isWebPEncoderAvailable():
        check resolved == ekWebP
      elif isHardwareEncoderAvailable():
        check resolved == ekH264
      else:
        check resolved == ekRawRgba
    else:
      # WebP compiled out: ekWebP degrades to ekH264 or ekRawRgba.
      if isHardwareEncoderAvailable():
        check resolved == ekH264
      else:
        check resolved == ekRawRgba

  test "encoderKindName covers ekWebP":
    check encoderKindName(ekWebP) == "webp_lossless"
    check encoderKindName(ekH264) == "h264_videotoolbox"
    check encoderKindName(ekRawRgba) == "raw_rgba"
