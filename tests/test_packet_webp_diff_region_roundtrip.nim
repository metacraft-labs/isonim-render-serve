## ELT-M9 — W-diff packet codec roundtrip.
##
## *Claim.* The W-diff variant (``isDiffRegion = 1``) packs a length-
## prefixed list of N rectangles into the W body. Each rectangle
## carries its own ``(x, y, w, h)`` plus a complete WebP RIFF blob.
## Encoding then decoding then re-encoding yields byte-identical
## bytes for N=0, 1, 3, 10. The browser-side ``handleW`` walks the
## rect list and paints each at its anchor; the static-UI heartbeat
## case (N=0) is the lowest-bandwidth point on the wire (just the W
## header + a 4-byte rect_count u32).
##
## Mirrors the ELT-M8 ``test_packet_webp_codec_roundtrip`` shape so
## the codec test fleet stays uniform across W variants.

import std/unittest

import isonim_render_serve

proc riffStub(seed: byte): seq[byte] =
  ## 12-byte fake RIFF/WEBP container with a seed byte stamped into
  ## the size field so the round-trip test can verify per-rect byte
  ## identity (we don't decode the VP8L body here — the rect codec
  ## treats it as an opaque blob).
  result = @[
    byte('R'), byte('I'), byte('F'), byte('F'),
    seed, seed, seed, seed,
    byte('W'), byte('E'), byte('B'), byte('P')]

proc makeRegion(x, y, w, h: int; seed: byte): WebpDiffRegion =
  WebpDiffRegion(x: x, y: y, w: w, h: h, riffBytes: riffStub(seed))

suite "ELT-M9: W-diff codec":

  test "W-diff N=0 heartbeat encodes to header + 4-byte rect_count":
    let pkt = encodeWDiffPacket(@[], fullW = 800, fullH = 600)
    # Header: 'W'(1) + flags(1) + codec_len(1) + 10 codec bytes
    #         + width(4) + height(4) + length(4)
    # Body:   u32 LE rect_count == 0 → 4 bytes
    check pkt.len == 1 + 1 + 1 + DefaultWebPCodecId.len + 12 + 4
    check pkt[0] == byte('W')
    # bit 0 (isStillFrame) + bit 1 (isDiffRegion) = 0x03
    check pkt[1] == 0x03'u8
    check pkt[2] == byte(DefaultWebPCodecId.len)
    check peekIsWebpPacket(pkt)
    check peekIsWebpDiffPacket(pkt)
    let dec = decodeWDiffPacket(pkt)
    check dec.width == 800
    check dec.height == 600
    check dec.codecId == DefaultWebPCodecId
    check dec.regions.len == 0
    let reEnc = encodeWDiffPacket(dec.regions, dec.width, dec.height,
                                   dec.codecId)
    check reEnc == pkt

  test "W-diff N=1 round-trips byte-identically":
    let region = makeRegion(x = 100, y = 50, w = 64, h = 64, seed = 0xAB'u8)
    let pkt = encodeWDiffPacket(@[region], fullW = 1280, fullH = 800)
    check peekIsWebpDiffPacket(pkt)
    let dec = decodeWDiffPacket(pkt)
    check dec.width == 1280
    check dec.height == 800
    check dec.regions.len == 1
    check dec.regions[0].x == 100
    check dec.regions[0].y == 50
    check dec.regions[0].w == 64
    check dec.regions[0].h == 64
    check dec.regions[0].riffBytes == region.riffBytes
    let reEnc = encodeWDiffPacket(dec.regions, dec.width, dec.height,
                                   dec.codecId)
    check reEnc == pkt

  test "W-diff N=3 round-trips byte-identically":
    let regs = @[
      makeRegion(0, 0, 32, 32, 0x11'u8),
      makeRegion(64, 64, 16, 24, 0x22'u8),
      makeRegion(200, 100, 100, 50, 0x33'u8),
    ]
    let pkt = encodeWDiffPacket(regs, fullW = 1024, fullH = 768)
    let dec = decodeWDiffPacket(pkt)
    check dec.regions.len == 3
    for i in 0 ..< 3:
      check dec.regions[i].x == regs[i].x
      check dec.regions[i].y == regs[i].y
      check dec.regions[i].w == regs[i].w
      check dec.regions[i].h == regs[i].h
      check dec.regions[i].riffBytes == regs[i].riffBytes
    let reEnc = encodeWDiffPacket(dec.regions, dec.width, dec.height,
                                   dec.codecId)
    check reEnc == pkt

  test "W-diff N=10 round-trips byte-identically":
    var regs: seq[WebpDiffRegion] = @[]
    for i in 0 ..< 10:
      regs.add makeRegion(x = i * 20, y = i * 10,
                          w = 16, h = 16,
                          seed = byte(0x40 + i))
    let pkt = encodeWDiffPacket(regs, fullW = 800, fullH = 600)
    let dec = decodeWDiffPacket(pkt)
    check dec.regions.len == 10
    for i in 0 ..< 10:
      check dec.regions[i].x == regs[i].x
      check dec.regions[i].y == regs[i].y
      check dec.regions[i].riffBytes == regs[i].riffBytes
    let reEnc = encodeWDiffPacket(dec.regions, dec.width, dec.height,
                                   dec.codecId)
    check reEnc == pkt

  test "W-diff rejects rectangle running outside the full-frame box":
    let r = makeRegion(x = 700, y = 0, w = 200, h = 100, seed = 0x55'u8)
    # rectangle right edge is 900 > full-frame width 800 → reject.
    expect PacketProtocolError:
      discard encodeWDiffPacket(@[r], fullW = 800, fullH = 600)

  test "W-diff rejects rectangle with non-positive dimensions":
    let r = WebpDiffRegion(x: 0, y: 0, w: 0, h: 32,
                           riffBytes: riffStub(0x66'u8))
    expect PacketProtocolError:
      discard encodeWDiffPacket(@[r], fullW = 800, fullH = 600)

  test "W-diff rejects rectangle with sub-12-byte riff blob":
    let r = WebpDiffRegion(x: 0, y: 0, w: 16, h: 16,
                           riffBytes: @[byte 'R', byte 'I', byte 'F'])
    expect PacketProtocolError:
      discard encodeWDiffPacket(@[r], fullW = 800, fullH = 600)

  test "W-diff rejects truncated body during decode":
    let region = makeRegion(0, 0, 16, 16, 0x77'u8)
    var pkt = encodeWDiffPacket(@[region], fullW = 800, fullH = 600)
    # Lop off the last 4 bytes of the body — the header length field
    # still claims the original size, so the decoder MUST raise.
    pkt.setLen(pkt.len - 4)
    expect PacketProtocolError:
      discard decodeWDiffPacket(pkt)

  test "W-diff decoder rejects single-RIFF (non-diff) W packets":
    # A plain ELT-M8 W packet has ``isDiffRegion = 0``; the W-diff
    # decoder must refuse to parse it (the dispatcher branches on the
    # bit before picking the decoder).
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 16, height: 16,
      riffBytes: riffStub(0x88'u8))
    let pkt = encodeWebpFrame(w)
    check not peekIsWebpDiffPacket(pkt)
    expect PacketProtocolError:
      discard decodeWDiffPacket(pkt)

  test "ELT-M8 single-RIFF W packets still round-trip after ELT-M9":
    # Regression guard: the bit-0 (``isStillFrame``) ELT-M8 path must
    # stay byte-identical after the flag-decoder learned bit 1.
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 320, height: 240,
      riffBytes: riffStub(0x99'u8))
    let enc1 = encodeWebpFrame(w)
    let dec = decodeWebpFrame(enc1)
    check dec.flags.isStillFrame
    check not dec.flags.isDiffRegion
    let enc2 = encodeWebpFrame(dec)
    check enc1 == enc2
