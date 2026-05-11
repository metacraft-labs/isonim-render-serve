## test_packet_codec_roundtrip — F/M/I codec round-trip + reserved-
## bits-zero enforcement.
##
## *Claim.* The byte layout the codec produces matches the RS-M0
## spec exactly: tag byte, little-endian length fields, RGBA8888
## row-major payload for full frames, diff-rect layout for diff
## frames. Re-encoding a decoded packet yields byte-identical bytes.
##
## *How.* Build representative F/M/I packets, encode → decode →
## re-encode, assert byte parity. Then poison reserved flag bits and
## assert `PacketProtocolError`.

import std/[json, unittest]

import isonim_render_serve

suite "isonim-render-serve: F/M/I codec":

  test "F full-frame byte layout (header offsets)":
    let f = Frame(kind: fkFull,
                  flags: FrameFlags(isDiff: false, isVideo: false),
                  width: 2, height: 2,
                  pixels: @[byte 0xFF, 0x00, 0x00, 0xFF,   # red
                            byte 0x00, 0xFF, 0x00, 0xFF,   # green
                            byte 0x00, 0x00, 0xFF, 0xFF,   # blue
                            byte 0x80, 0x80, 0x80, 0xFF])  # gray
    let enc = encodeFrame(f)
    # 'F' + flags + 4u32 + 4u32 + 4u32 + 16 = 14 header bytes + 16
    check enc.len == 14 + 16
    check enc[0] == byte('F')
    check enc[1] == 0  # full RGBA, no reserved bits
    # width = 2 LE
    check enc[2] == 2
    check enc[3] == 0
    check enc[4] == 0
    check enc[5] == 0
    # height = 2 LE
    check enc[6] == 2
    check enc[7] == 0
    # length = 16 LE
    check enc[10] == 16
    check enc[11] == 0

  test "F full-frame encode → decode → re-encode is byte-identical":
    var pixels = newSeq[byte](64 * 32 * 4)
    for i in 0 ..< pixels.len: pixels[i] = byte(i and 0xFF)
    let f = Frame(kind: fkFull,
                  flags: FrameFlags(isDiff: false, isVideo: false),
                  width: 64, height: 32, pixels: pixels)
    let enc1 = encodeFrame(f)
    let dec = decodeFrame(enc1)
    check dec.kind == fkFull
    check dec.width == 64
    check dec.height == 32
    check dec.pixels.len == 64 * 32 * 4
    check dec.pixels == pixels
    let enc2 = encodeFrame(dec)
    check enc1 == enc2

  test "F diff-frame encode → decode → re-encode is byte-identical":
    let r1 = DirtyRect(x: 0, y: 0, w: 2, h: 2,
                       pixels: @[byte 1,2,3,4, 5,6,7,8,
                                 9,10,11,12, 13,14,15,16])
    let r2 = DirtyRect(x: 10, y: 5, w: 1, h: 1,
                       pixels: @[byte 0xAA, 0xBB, 0xCC, 0xDD])
    let f = Frame(kind: fkDiff,
                  flags: FrameFlags(isDiff: true, isVideo: false),
                  width: 256, height: 256, rects: @[r1, r2])
    let enc1 = encodeFrame(f)
    let dec = decodeFrame(enc1)
    check dec.kind == fkDiff
    check dec.width == 256
    check dec.height == 256
    check dec.rects.len == 2
    check dec.rects[0].x == 0
    check dec.rects[0].y == 0
    check dec.rects[0].w == 2
    check dec.rects[0].h == 2
    check dec.rects[1].x == 10
    check dec.rects[1].y == 5
    let enc2 = encodeFrame(dec)
    check enc1 == enc2

  test "F reserved flag bits != 0 raise PacketProtocolError":
    let f = Frame(kind: fkFull,
                  flags: FrameFlags(isDiff: false, isVideo: false),
                  width: 1, height: 1, pixels: @[byte 1, 2, 3, 4])
    var bytes = encodeFrame(f)
    # Set reserved bit 2 in the flag byte.
    bytes[1] = bytes[1] or 0x04'u8
    expect PacketProtocolError:
      discard decodeFrame(bytes)

  test "F isVideo bit is rejected at protocolVersion=1":
    let f = Frame(kind: fkFull,
                  flags: FrameFlags(isDiff: false, isVideo: false),
                  width: 1, height: 1, pixels: @[byte 1, 2, 3, 4])
    var bytes = encodeFrame(f)
    bytes[1] = bytes[1] or 0x02'u8  # isVideo
    expect PacketProtocolError:
      discard decodeFrame(bytes)

  test "F full-frame payload length mismatch raises":
    let f = Frame(kind: fkFull,
                  flags: FrameFlags(isDiff: false, isVideo: false),
                  width: 2, height: 2, pixels: newSeq[byte](16))
    var bytes = encodeFrame(f)
    # Corrupt the length field to claim 20 bytes (vs 16 actual).
    bytes[10] = 20
    expect PacketProtocolError:
      discard decodeFrame(bytes)

  test "M hello packet round-trip preserves JSON":
    let hello = buildHelloJson("stub", 256, 256)
    let m = MetaPacket(json: hello)
    let enc1 = encodeMeta(m)
    let dec = decodeMeta(enc1)
    check dec.json == hello
    let enc2 = encodeMeta(dec)
    check enc1 == enc2
    # Sanity-check the JSON structure.
    let node = parseJson(dec.json)
    check node["type"].getStr == "hello"
    check node["protocolVersion"].getInt == 1
    check node["backend"].getStr == "stub"
    check node["capabilities"]["diffRegions"].getBool == false
    check node["initialSize"]["width"].getInt == 256

  test "M packet byte layout (tag + LE length)":
    let m = MetaPacket(json: "{\"type\":\"resize\",\"width\":640,\"height\":480}")
    let enc = encodeMeta(m)
    check enc[0] == byte('M')
    # length is m.json.len, little-endian
    check enc[1] == byte(m.json.len and 0xFF)
    check enc[2] == byte((m.json.len shr 8) and 0xFF)
    check enc[3] == 0
    check enc[4] == 0

  test "I packet round-trip for every event variant":
    let events = @[
      InputEvent(kind: iekKey, keyAction: kaDown,
                 key: "a", code: "KeyA",
                 keyModifiers: Modifiers(ctrl: false, shift: true,
                                         alt: false, meta: false),
                 repeat: false),
      InputEvent(kind: iekMouse, mouseAction: maClick,
                 button: 2, mouseX: 100, mouseY: 200,
                 mouseModifiers: Modifiers()),
      InputEvent(kind: iekScroll, scrollX: 10, scrollY: 20,
                 deltaX: 0, deltaY: -120, scrollModifiers: Modifiers()),
      InputEvent(kind: iekResize, width: 1024, height: 768),
      InputEvent(kind: iekFocus, focused: true),
    ]
    for ev in events:
      let ipkt = encodeInputEvent(ev)
      let enc1 = encodeInput(ipkt)
      let dec = decodeInput(enc1)
      check dec.json == ipkt.json
      let enc2 = encodeInput(dec)
      check enc1 == enc2
      let parsed = decodeInputEvent(dec)
      check parsed.kind == ev.kind

  test "I packet decode preserves all key fields":
    let ev = InputEvent(kind: iekKey, keyAction: kaPress,
                        key: "Enter", code: "Enter",
                        keyModifiers: Modifiers(ctrl: true, shift: false,
                                                alt: false, meta: true),
                        repeat: true)
    let ipkt = encodeInputEvent(ev)
    let dec = decodeInputEvent(ipkt)
    check dec.kind == iekKey
    check dec.keyAction == kaPress
    check dec.key == "Enter"
    check dec.code == "Enter"
    check dec.keyModifiers.ctrl == true
    check dec.keyModifiers.meta == true
    check dec.keyModifiers.shift == false
    check dec.repeat == true

  test "I packet decode preserves all mouse fields":
    let ev = InputEvent(kind: iekMouse, mouseAction: maMove,
                        button: 1, mouseX: 321, mouseY: 654,
                        mouseModifiers: Modifiers(ctrl: false, shift: true,
                                                  alt: false, meta: false))
    let ipkt = encodeInputEvent(ev)
    let dec = decodeInputEvent(ipkt)
    check dec.kind == iekMouse
    check dec.mouseAction == maMove
    check dec.button == 1
    check dec.mouseX == 321
    check dec.mouseY == 654
    check dec.mouseModifiers.shift == true

  test "I packet with unknown type raises PacketProtocolError":
    let ipkt = InputPacket(json: "{\"type\":\"telepathy\"}")
    expect PacketProtocolError:
      discard decodeInputEvent(ipkt)

  test "I packet with malformed JSON raises PacketProtocolError":
    let ipkt = InputPacket(json: "{not json")
    expect PacketProtocolError:
      discard decodeInputEvent(ipkt)

  test "peekPacketKind identifies tag bytes":
    check peekPacketKind(@[byte('F'), 0, 0, 0, 0]) == pkFrame
    check peekPacketKind(@[byte('M'), 0, 0, 0, 0]) == pkMeta
    check peekPacketKind(@[byte('I'), 0, 0, 0, 0]) == pkInput
    expect PacketProtocolError:
      discard peekPacketKind(@[byte('Z')])

  test "decodeMeta rejects wrong tag byte":
    let bogus = @[byte('X'), 0, 0, 0, 0]
    expect PacketProtocolError:
      discard decodeMeta(bogus)
