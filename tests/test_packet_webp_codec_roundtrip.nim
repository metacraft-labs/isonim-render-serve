## ELT-M8 — W-packet codec roundtrip.
##
## *Claim.* The W wire format the codec produces matches the ELT-M8
## documented schema exactly: tag byte 'W', flag byte, codec_id_len
## byte, codec_id UTF-8 bytes, little-endian width / height / length,
## RIFF payload. Re-encoding a decoded packet yields byte-identical
## bytes. Mirrors the EPP-M5 ``test_packet_video_codec_roundtrip.nim``
## shape one-to-one so the negotiation contract stays uniform across
## packet kinds.

import std/unittest

import isonim_render_serve

proc riffStub(): seq[byte] =
  ## Minimum 12-byte fake RIFF/WEBP container that satisfies the
  ## codec's length-check sanity gate without producing a real WebP.
  result = @[
    byte('R'), byte('I'), byte('F'), byte('F'),
    0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8,
    byte('W'), byte('E'), byte('B'), byte('P')]

suite "ELT-M8: W codec":

  test "W byte layout (header offsets)":
    # ``image/webp`` is 10 UTF-8 bytes long.
    let riff = @[byte 'R', byte 'I', byte 'F', byte 'F',
                  0x10'u8, 0'u8, 0'u8, 0'u8,
                  byte 'W', byte 'E', byte 'B', byte 'P']
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 320, height: 240,
      riffBytes: riff)
    let enc = encodeWebpFrame(w)
    # 'W' + flags + codec_len + 10 codec bytes + 12 (w/h/len) + 12 riff
    check enc.len == 1 + 1 + 1 + 10 + 12 + 12
    check enc[0] == byte('W')
    check enc[1] == 0x01'u8                # bit0 = isStillFrame
    check enc[2] == 10'u8                  # codec_id_len for "image/webp"
    check enc[3] == byte('i')
    check enc[4] == byte('m')
    check enc[5] == byte('a')
    check enc[6] == byte('g')
    check enc[7] == byte('e')
    check enc[8] == byte('/')
    check enc[9] == byte('w')
    check enc[10] == byte('e')
    check enc[11] == byte('b')
    check enc[12] == byte('p')
    # width 320 = 0x140 LE at offset 13
    check enc[13] == 0x40'u8
    check enc[14] == 0x01'u8
    # height 240 = 0xF0 LE
    check enc[17] == 0xF0'u8
    check enc[18] == 0x00'u8
    # length = 12 LE
    check enc[21] == 0x0C'u8
    check enc[22] == 0x00'u8
    # RIFF magic at the payload offset
    check enc[25] == byte('R')
    check enc[26] == byte('I')
    check enc[27] == byte('F')
    check enc[28] == byte('F')

  test "W encode -> decode -> re-encode is byte-identical":
    var riff = newSeq[byte](2048)
    for i in 0 ..< riff.len: riff[i] = byte(i and 0xFF)
    # First 12 bytes must look like a RIFF header for the decode-side
    # length-check to pass; the codec doesn't parse VP8L beyond the
    # minimum container length sanity check.
    riff[0] = byte('R'); riff[1] = byte('I')
    riff[2] = byte('F'); riff[3] = byte('F')
    riff[8] = byte('W'); riff[9] = byte('E')
    riff[10] = byte('B'); riff[11] = byte('P')
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 1024, height: 768,
      riffBytes: riff)
    let enc1 = encodeWebpFrame(w)
    let dec = decodeWebpFrame(enc1)
    check dec.codecId == w.codecId
    check dec.width == w.width
    check dec.height == w.height
    check dec.flags.isStillFrame == w.flags.isStillFrame
    check dec.riffBytes == w.riffBytes
    let enc2 = encodeWebpFrame(dec)
    check enc1 == enc2

  test "W reserved flag bits != 0 raise PacketProtocolError":
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 16, height: 16,
      riffBytes: riffStub())
    var enc = encodeWebpFrame(w)
    # Poison reserved bits.
    enc[1] = enc[1] or 0x02'u8
    expect PacketProtocolError:
      discard decodeWebpFrame(enc)

  test "W codec_id beyond 255 bytes rejected":
    var s = ""
    for _ in 0 ..< 256: s.add 'a'
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: s,
      width: 16, height: 16,
      riffBytes: riffStub())
    expect PacketProtocolError:
      discard encodeWebpFrame(w)

  test "W truncated header raises":
    expect PacketProtocolError:
      discard decodeWebpFrame(@[byte 'W'])
    expect PacketProtocolError:
      discard decodeWebpFrame(@[byte 'W', 0x01, 0xFF])  # codec_len 255

  test "W wrong tag byte raises":
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 16, height: 16,
      riffBytes: riffStub())
    var enc = encodeWebpFrame(w)
    enc[0] = byte('F')
    expect PacketProtocolError:
      discard decodeWebpFrame(enc)

  test "W payload length mismatch raises":
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 16, height: 16,
      riffBytes: riffStub())
    var enc = encodeWebpFrame(w)
    enc.add 0xFF'u8  # extra trailing byte
    expect PacketProtocolError:
      discard decodeWebpFrame(enc)

  test "W RIFF payload too short rejected":
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 16, height: 16,
      riffBytes: @[byte('R'), byte('I'), byte('F'), byte('F')])  # only 4 bytes, < 12
    expect PacketProtocolError:
      discard encodeWebpFrame(w)

  test "peekIsWebpPacket identifies the W tag":
    let w = WebpFrame(
      flags: WebpFlags(isStillFrame: true),
      codecId: DefaultWebPCodecId,
      width: 16, height: 16,
      riffBytes: riffStub())
    let enc = encodeWebpFrame(w)
    check peekIsWebpPacket(enc)
    check not peekIsWebpPacket(@[byte 'F', 0x00])
    check not peekIsWebpPacket(@[byte 'V', 0x00])

  test "DefaultWebPCodecId matches MIME for createImageBitmap":
    ## The browser side hands the W payload to
    ## ``new Blob([bytes], { type: codecId })`` and then
    ## ``createImageBitmap`` decodes it. The MIME must be the canonical
    ## ``image/webp`` so the dispatch lands on the universal native
    ## WebP decoder rather than the generic
    ## ``application/octet-stream`` path which forces a MIME sniff.
    check DefaultWebPCodecId == "image/webp"
    check DefaultWebPCodecId.len == 10
