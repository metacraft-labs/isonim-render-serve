## EPP-M5 — V-packet codec roundtrip.
##
## *Claim.* The V wire format the codec produces matches the EPP-M5
## documented schema exactly: tag byte 'V', flag byte, codec_id_len
## byte, codec_id UTF-8 bytes, little-endian width / height / length,
## NALU payload. Re-encoding a decoded packet yields byte-identical
## bytes.

import std/unittest

import isonim_render_serve

suite "EPP-M5: V codec":

  test "V byte layout (header offsets)":
    let v = VideoFrame(
      flags: VideoFlags(isKeyframe: true, hasExtraData: true),
      codecId: "avc1.42E01E",
      width: 320, height: 240,
      naluBytes: @[byte 0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x80, 0x10])
    let enc = encodeVideoFrame(v)
    # 'V' + flags + codec_len + 11 codec bytes + 12 (w/h/len) + 8 nalu
    check enc.len == 1 + 1 + 1 + 11 + 12 + 8
    check enc[0] == byte('V')
    check enc[1] == 0x03'u8  # bit0|bit1 = keyframe + extraData
    check enc[2] == 11'u8
    check enc[3] == byte('a')
    check enc[4] == byte('v')
    check enc[5] == byte('c')
    check enc[6] == byte('1')
    check enc[7] == byte('.')
    # width 320 = 0x140 LE
    check enc[14] == 0x40'u8
    check enc[15] == 0x01'u8
    # height 240 = 0xF0 LE
    check enc[18] == 0xF0'u8
    check enc[19] == 0x00'u8
    # length = 8 LE
    check enc[22] == 0x08'u8
    check enc[23] == 0x00'u8

  test "V encode -> decode -> re-encode is byte-identical":
    var nalu = newSeq[byte](2048)
    for i in 0 ..< nalu.len: nalu[i] = byte(i and 0xFF)
    let v = VideoFrame(
      flags: VideoFlags(isKeyframe: true, hasExtraData: false),
      codecId: DefaultH264CodecId,
      width: 1024, height: 768,
      naluBytes: nalu)
    let enc1 = encodeVideoFrame(v)
    let dec = decodeVideoFrame(enc1)
    check dec.codecId == v.codecId
    check dec.width == v.width
    check dec.height == v.height
    check dec.flags.isKeyframe == v.flags.isKeyframe
    check dec.flags.hasExtraData == v.flags.hasExtraData
    check dec.naluBytes == v.naluBytes
    let enc2 = encodeVideoFrame(dec)
    check enc1 == enc2

  test "V reserved flag bits != 0 raise PacketProtocolError":
    let v = VideoFrame(
      flags: VideoFlags(isKeyframe: true, hasExtraData: false),
      codecId: "avc1.42E01E",
      width: 16, height: 16,
      naluBytes: @[byte 0x00])
    var enc = encodeVideoFrame(v)
    # Poison reserved bits.
    enc[1] = enc[1] or 0x04'u8
    expect PacketProtocolError:
      discard decodeVideoFrame(enc)

  test "V codec_id beyond 255 bytes rejected":
    var s = ""
    for _ in 0 ..< 256: s.add 'a'
    let v = VideoFrame(
      flags: VideoFlags(isKeyframe: true, hasExtraData: false),
      codecId: s,
      width: 16, height: 16,
      naluBytes: @[byte 0x00])
    expect PacketProtocolError:
      discard encodeVideoFrame(v)

  test "V truncated header raises":
    expect PacketProtocolError:
      discard decodeVideoFrame(@[byte 'V'])
    expect PacketProtocolError:
      discard decodeVideoFrame(@[byte 'V', 0x01, 0xFF])  # codec_len 255

  test "V wrong tag byte raises":
    let v = VideoFrame(
      flags: VideoFlags(isKeyframe: true, hasExtraData: false),
      codecId: "avc1.42E01E",
      width: 16, height: 16,
      naluBytes: @[byte 0x00])
    var enc = encodeVideoFrame(v)
    enc[0] = byte('F')
    expect PacketProtocolError:
      discard decodeVideoFrame(enc)

  test "V payload length mismatch raises":
    let v = VideoFrame(
      flags: VideoFlags(isKeyframe: true, hasExtraData: false),
      codecId: "avc1.42E01E",
      width: 16, height: 16,
      naluBytes: @[byte 0x00, 0x01, 0x02])
    var enc = encodeVideoFrame(v)
    enc.add 0xFF'u8  # extra trailing byte
    expect PacketProtocolError:
      discard decodeVideoFrame(enc)

  test "peekIsVideoPacket identifies the V tag":
    let v = VideoFrame(
      flags: VideoFlags(isKeyframe: true, hasExtraData: false),
      codecId: "avc1.42E01E",
      width: 16, height: 16,
      naluBytes: @[byte 0x00])
    let enc = encodeVideoFrame(v)
    check peekIsVideoPacket(enc)
    check not peekIsVideoPacket(@[byte 'F', 0x00])

  test "DefaultH264CodecId matches Baseline 3.0":
    check DefaultH264CodecId == "avc1.42E01E"
    check DefaultH264CodecId.len == 11
