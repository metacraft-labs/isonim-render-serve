## F / M / I packet codec — implements the wire format locked at
## RS-M0 (see `codetracer-specs/Front-Ends/IsoNim/`
## `isonim-render-stream.status.org` § *Architecture sketch — render
## streaming*).
##
## Byte layouts (all multi-byte ints little-endian):
##
##   F packet: 'F'(1) + u8 flags + u32 width + u32 height + u32 length
##             + payload
##   M packet: 'M'(1) + u32 length + UTF-8 JSON body
##   I packet: 'I'(1) + u32 length + UTF-8 JSON body
##
## F packet flag byte:
##   * bit 0 (0x01): 0 = full RGBA frame, 1 = diff-region frame.
##   * bit 1 (0x02): 0 = uncompressed RGBA8888, 1 = reserved
##     (video/h264, deferred to a later milestone).
##   * bits 2..7: reserved, MUST be zero. Non-zero reserved bits
##     trigger a `PacketProtocolError`; callers are expected to
##     close the connection with WS status 1002.
##
## F payload — full frame: exactly `width * height * 4` bytes of
## RGBA8888 row-major.
##
## F payload — diff frame: `u32 count + count × { u32 x, u32 y,
## u32 w, u32 h, u32 length, RGBA bytes }`. Each rect's `length`
## MUST equal `w * h * 4`.

type
  PacketKind* = enum
    pkFrame = 'F'
    pkMeta = 'M'
    pkInput = 'I'

  FrameFlags* = object
    isDiff*: bool      ## bit 0
    isVideo*: bool     ## bit 1 — reserved at v1; always false on the wire

  DirtyRect* = object
    x*, y*, w*, h*: int
    pixels*: seq[byte]    ## RGBA8888 row-major, length == w * h * 4

  FrameKindCase* = enum
    fkFull, fkDiff

  Frame* = object
    flags*: FrameFlags
    width*, height*: int
    case kind*: FrameKindCase
    of fkFull:
      pixels*: seq[byte]    ## RGBA8888 row-major; length == width*height*4
    of fkDiff:
      rects*: seq[DirtyRect]

  MetaPacket* = object
    json*: string

  InputPacket* = object
    json*: string

  PacketProtocolError* = object of CatchableError
    ## Raised on any wire-protocol violation: unknown tag byte,
    ## truncated header / payload, reserved flag bits set, mismatched
    ## payload length. The bridge MUST close the WS connection with
    ## status code 1002 (RFC 6455 §7.4.1) when this is raised on
    ## inbound data.

# ---------------------------------------------------------------------------
# Little-endian helpers — kept inline so the codec can be benchmarked
# without pulling in `std/endians` ceremony.
# ---------------------------------------------------------------------------

proc putU32LE(buf: var seq[byte]; v: uint32) =
  buf.add byte(v and 0xFF'u32)
  buf.add byte((v shr 8) and 0xFF'u32)
  buf.add byte((v shr 16) and 0xFF'u32)
  buf.add byte((v shr 24) and 0xFF'u32)

proc readU32LE(buf: openArray[byte]; off: int): uint32 =
  uint32(buf[off]) or
    (uint32(buf[off + 1]) shl 8) or
    (uint32(buf[off + 2]) shl 16) or
    (uint32(buf[off + 3]) shl 24)

# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

proc encodeFrameFlags*(flags: FrameFlags): uint8 =
  ## Pack the flag-byte. Reserved bits are always emitted as zero.
  result = 0
  if flags.isDiff: result = result or 0x01'u8
  if flags.isVideo: result = result or 0x02'u8

proc decodeFrameFlags*(b: uint8): FrameFlags =
  ## Decode the flag byte. Reserved bits 2..7 MUST be zero; raise
  ## `PacketProtocolError` otherwise.
  if (b and 0xFC'u8) != 0:
    raise newException(PacketProtocolError,
      "F flag byte has non-zero reserved bits: " & $b)
  result.isDiff = (b and 0x01'u8) != 0
  result.isVideo = (b and 0x02'u8) != 0

proc encodeFrame*(frame: Frame): seq[byte] =
  ## Encode an F packet exactly as specified at RS-M0.
  var payload = newSeq[byte]()
  case frame.kind
  of fkFull:
    let expected = frame.width * frame.height * 4
    if frame.pixels.len != expected:
      raise newException(PacketProtocolError,
        "full frame pixel buffer length " & $frame.pixels.len &
        " does not match width*height*4 = " & $expected)
    payload = frame.pixels
  of fkDiff:
    putU32LE(payload, uint32(frame.rects.len))
    for r in frame.rects:
      let expected = r.w * r.h * 4
      if r.pixels.len != expected:
        raise newException(PacketProtocolError,
          "diff rect pixel buffer length " & $r.pixels.len &
          " does not match w*h*4 = " & $expected)
      putU32LE(payload, uint32(r.x))
      putU32LE(payload, uint32(r.y))
      putU32LE(payload, uint32(r.w))
      putU32LE(payload, uint32(r.h))
      putU32LE(payload, uint32(r.pixels.len))
      for b in r.pixels: payload.add b
  var flags = frame.flags
  flags.isDiff = (frame.kind == fkDiff)
  result = newSeqOfCap[byte](14 + payload.len)
  result.add byte('F')
  result.add encodeFrameFlags(flags)
  putU32LE(result, uint32(frame.width))
  putU32LE(result, uint32(frame.height))
  putU32LE(result, uint32(payload.len))
  for b in payload: result.add b

proc decodeFrame*(bytes: openArray[byte]): Frame =
  ## Decode an F packet. Raises `PacketProtocolError` on any wire
  ## violation (wrong tag, truncated header, reserved flag bits set,
  ## mismatched payload length).
  if bytes.len < 14:
    raise newException(PacketProtocolError,
      "F packet truncated; need >= 14 bytes, got " & $bytes.len)
  if bytes[0] != byte('F'):
    raise newException(PacketProtocolError,
      "expected tag 'F' (0x46), got 0x" & $bytes[0])
  let flags = decodeFrameFlags(bytes[1])
  if flags.isVideo:
    raise newException(PacketProtocolError,
      "F encoding bit 1 (video/h264) is reserved at protocolVersion=1")
  let width = int(readU32LE(bytes, 2))
  let height = int(readU32LE(bytes, 6))
  let length = int(readU32LE(bytes, 10))
  if bytes.len - 14 != length:
    raise newException(PacketProtocolError,
      "F payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - 14))
  if flags.isDiff:
    if length < 4:
      raise newException(PacketProtocolError,
        "F diff payload truncated; need u32 count")
    let count = int(readU32LE(bytes, 14))
    var rects = newSeqOfCap[DirtyRect](count)
    var off = 18
    for i in 0 ..< count:
      if off + 20 > bytes.len:
        raise newException(PacketProtocolError,
          "F diff rect header truncated at rect " & $i)
      let rx = int(readU32LE(bytes, off))
      let ry = int(readU32LE(bytes, off + 4))
      let rw = int(readU32LE(bytes, off + 8))
      let rh = int(readU32LE(bytes, off + 12))
      let rl = int(readU32LE(bytes, off + 16))
      off += 20
      if rl != rw * rh * 4:
        raise newException(PacketProtocolError,
          "F diff rect " & $i & " length " & $rl &
          " != w*h*4 (" & $(rw * rh * 4) & ")")
      if off + rl > bytes.len:
        raise newException(PacketProtocolError,
          "F diff rect " & $i & " payload truncated")
      var pixels = newSeq[byte](rl)
      for j in 0 ..< rl: pixels[j] = bytes[off + j]
      off += rl
      rects.add DirtyRect(x: rx, y: ry, w: rw, h: rh, pixels: pixels)
    if off != bytes.len:
      raise newException(PacketProtocolError,
        "F diff payload trailing bytes: " & $(bytes.len - off))
    result = Frame(kind: fkDiff, flags: flags, width: width, height: height,
                   rects: rects)
  else:
    let expected = width * height * 4
    if length != expected:
      raise newException(PacketProtocolError,
        "F full payload length " & $length &
        " != width*height*4 (" & $expected & ")")
    var pixels = newSeq[byte](length)
    for i in 0 ..< length: pixels[i] = bytes[14 + i]
    result = Frame(kind: fkFull, flags: flags, width: width, height: height,
                   pixels: pixels)

proc encodeMeta*(meta: MetaPacket): seq[byte] =
  ## Encode an M packet: 'M' + u32 LE length + UTF-8 JSON.
  let n = meta.json.len
  result = newSeqOfCap[byte](5 + n)
  result.add byte('M')
  putU32LE(result, uint32(n))
  for ch in meta.json: result.add byte(ch)

proc decodeMeta*(bytes: openArray[byte]): MetaPacket =
  if bytes.len < 5:
    raise newException(PacketProtocolError,
      "M packet truncated; need >= 5 bytes")
  if bytes[0] != byte('M'):
    raise newException(PacketProtocolError,
      "expected tag 'M' (0x4D), got 0x" & $bytes[0])
  let length = int(readU32LE(bytes, 1))
  if bytes.len - 5 != length:
    raise newException(PacketProtocolError,
      "M payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - 5))
  var s = newString(length)
  for i in 0 ..< length: s[i] = char(bytes[5 + i])
  result = MetaPacket(json: s)

proc encodeInput*(inp: InputPacket): seq[byte] =
  ## Encode an I packet: 'I' + u32 LE length + UTF-8 JSON.
  let n = inp.json.len
  result = newSeqOfCap[byte](5 + n)
  result.add byte('I')
  putU32LE(result, uint32(n))
  for ch in inp.json: result.add byte(ch)

proc decodeInput*(bytes: openArray[byte]): InputPacket =
  if bytes.len < 5:
    raise newException(PacketProtocolError,
      "I packet truncated; need >= 5 bytes")
  if bytes[0] != byte('I'):
    raise newException(PacketProtocolError,
      "expected tag 'I' (0x49), got 0x" & $bytes[0])
  let length = int(readU32LE(bytes, 1))
  if bytes.len - 5 != length:
    raise newException(PacketProtocolError,
      "I payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - 5))
  var s = newString(length)
  for i in 0 ..< length: s[i] = char(bytes[5 + i])
  result = InputPacket(json: s)

proc bytesToString*(bytes: openArray[byte]): string =
  ## Helper for handing byte buffers to the asyncnet `send`/`recv`
  ## APIs (which speak `string`).
  result = newString(bytes.len)
  for i in 0 ..< bytes.len: result[i] = char(bytes[i])

proc stringToBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len: result[i] = byte(s[i])

proc peekPacketKind*(bytes: openArray[byte]): PacketKind =
  ## Inspect a buffer's first byte and return the matching
  ## `PacketKind`, or raise `PacketProtocolError` for unknown tags.
  if bytes.len == 0:
    raise newException(PacketProtocolError, "empty packet")
  case char(bytes[0])
  of 'F': pkFrame
  of 'M': pkMeta
  of 'I': pkInput
  else:
    raise newException(PacketProtocolError,
      "unknown packet tag 0x" & $bytes[0])
