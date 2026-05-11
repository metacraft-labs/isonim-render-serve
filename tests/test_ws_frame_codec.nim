## test_ws_frame_codec — RFC 6455 codec round-trip across payload
## sizes 0 / 125 / 126 / 127 / 65535 / 65536, masked and unmasked.

import std/unittest

import isonim_render_serve

suite "isonim-render-serve: WebSocket framing":

  test "client→server masked frame decode (small payload)":
    let mask: array[4, byte] = [byte 0xDE, 0xAD, 0xBE, 0xEF]
    let payload = "hello, websocket"
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.opcode == wsOpBinary
    check msg.payload == payload

  test "server→client unmasked frame round-trips":
    let payload = "binary data " & $newSeq[char](200).len
    let frame = encodeWsBinaryFrame(payload)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.opcode == wsOpBinary
    check msg.payload == payload

  test "payload length 0 (empty body)":
    let mask: array[4, byte] = [byte 1, 2, 3, 4]
    let frame = encodeWsClientFrame(wsOpBinary, "", mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 0

  test "payload length 125 (largest 7-bit field)":
    let payload = newString(125)
    let mask: array[4, byte] = [byte 0xFF, 0, 0xFF, 0]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 125

  test "payload length 126 (smallest 16-bit field)":
    let payload = newString(126)
    let mask: array[4, byte] = [byte 1, 2, 3, 4]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 126

  test "payload length 65535 (largest 16-bit field)":
    let payload = newString(65535)
    let mask: array[4, byte] = [byte 9, 8, 7, 6]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 65535

  test "payload length 65536 (smallest 64-bit field)":
    let payload = newString(65536)
    let mask: array[4, byte] = [byte 0xCA, 0xFE, 0xBA, 0xBE]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 65536

  test "F packet (large RGBA payload, ~256KB) round-trips through WS":
    # 256x256x4 = 262144 bytes. The bridge's normal frame size.
    let f = Frame(kind: fkFull,
                  flags: FrameFlags(isDiff: false, isVideo: false),
                  width: 256, height: 256,
                  pixels: newSeq[byte](256 * 256 * 4))
    let packet = encodeFrame(f)
    let payload = bytesToString(packet)
    let frame = encodeWsBinaryFrame(payload)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 256 * 256 * 4 + 14
    # The recovered packet must still decode to the original F frame.
    let decFrame = decodeFrame(stringToBytes(msg.payload))
    check decFrame.kind == fkFull
    check decFrame.width == 256
    check decFrame.height == 256

  test "fragmented stream feed (byte-at-a-time)":
    let payload = "fragmented payload that crosses many feeds"
    let mask: array[4, byte] = [byte 1, 2, 3, 4]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    for ch in frame:
      dec.feed($ch)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload == payload

  test "close frame encode + status-code decode":
    let frame = encodeWsCloseFrame(1002'u16, "protocol error")
    # Decode using the server-side decoder by feeding it as a
    # client-style masked frame (we re-mask the body).
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.opcode == wsOpClose
    check decodeCloseStatus(msg.payload) == 1002'u16

  test "compute_accept_key against RFC 6455 sample":
    check computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==") ==
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
