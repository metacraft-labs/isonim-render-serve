## ELT-M8 W-packet codec — WebP-lossless image-frame transport
## sibling of the raw RGBA F packet (``packet.nim``) and the H.264
## V packet (``packet_video.nim``).
##
## Wire format
## -----------
##
## The W packet is structurally the same shape as V — tag byte
## then a flag byte then a codec_id string then dimension headers
## then a length-prefixed payload — but its body is an *image*
## (a complete WebP RIFF container with a single VP8L chunk)
## rather than a video NALU sequence. Each W packet is fully
## self-decodable: no decoder lifecycle, no parameter sets, no
## inter-frame dependencies. Per the ELT-M7 synthesis report this
## is exactly the property that lets the browser side ship through
## ``createImageBitmap(Blob)`` with zero ``configure()`` overhead.
##
## .. code-block:: text
##
##     'W'(1)
##     | u8 flags
##     | u8 codec_id_len
##     | codec_id_len UTF-8 bytes  (e.g. "image/webp")
##     | u32 LE width
##     | u32 LE height
##     | u32 LE length
##     | WebP RIFF bytes
##
## All multi-byte ints are little-endian (matches F / M / I / V).
##
## ``codec_id`` carries the MIME type the browser side will hand to
## ``new Blob([bytes], { type: codec_id })``. Default is
## ``"image/webp"`` — the only MIME the production wiring emits at
## ELT-M8. The field stays in the wire format for forward
## compatibility (a future ``image/webp2`` profile or a non-WebP
## still-image transport could reuse the W tag with a different
## codec_id, the same way V multiplexes ``avc1.*`` / ``hvc1.*`` /
## ``av01.*`` codec strings).
##
## ``codec_id_len`` is a u8 because MIME-type strings comfortably fit
## under 255 bytes. The W header is therefore ``15 + codec_id_len``
## bytes long — identical layout cost to V.
##
## Flag byte layout
## ~~~~~~~~~~~~~~~~
##
## * bit 0 (0x01): ``isStillFrame`` — set when the WebP RIFF carries
##   a single VP8L chunk (the still-image case). ELT-M8 always emits
##   1 here; the bit reserves room for a future animated-WebP
##   transport (multiple VP8L chunks in a WEBPAnimChunk) that would
##   set the bit to 0 to signal "decode through
##   ``createImageBitmap`` with multi-frame semantics".
## * bit 1 (0x02): reserved, MUST be zero. The ELT-M9 follow-up will
##   likely use this bit for the diff-region WebP variant (W-packet
##   carrying multiple small rect-encoded VP8L blobs concatenated in
##   the payload, each preceded by a rect header).
## * bits 2..7: reserved, MUST be zero.
##
## Note: the W packet kind shares no flag bits with F / V intentionally.
## The editor's dispatcher branches on the tag byte ('W' vs 'V' vs
## 'F') first, so per-kind flag semantics can diverge without
## confusing downstream consumers.
##
## Why a new packet kind instead of bumping ``F.flags.isVideo`` or
## reusing the V kind? ELT-M7 § "Production wiring recommendation"
## locked the "each codec is its own packet kind, negotiated up
## front" discipline EPP-M5 / EPP-M6 established. W is *stateless*
## (no per-stream decoder instance), V is *stateful* (a configured
## VideoDecoder), F is *raw* (no codec). Co-locating image transport
## bytes inside V's flag byte would force a second-level dispatch
## inside the browser's V handler and lose the "stateless decoder"
## invariant that makes the WebP decode path the simplicity win it
## is.

import std/strutils

import ./packet  # PacketProtocolError + putU32LE / readU32LE helpers
                 # (re-exported from ``packet.nim`` for codec consumers)

type
  WebpFlags* = object
    isStillFrame*: bool  ## bit 0; ELT-M8 always sets this to true

  WebpFrame* = object
    flags*: WebpFlags
    codecId*: string       ## e.g. "image/webp"; max 255 UTF-8 bytes
    width*, height*: int
    riffBytes*: seq[byte]  ## raw WebP RIFF container (VP8L chunk)

# ---------------------------------------------------------------------------
# Little-endian helpers — local copies so this module compiles standalone
# even if ``packet.nim``'s helpers are made private later. Kept inline so
# the codec benchmark doesn't pay an indirect call per word.
# ---------------------------------------------------------------------------

proc putU32LEw(buf: var seq[byte]; v: uint32) {.inline.} =
  buf.add byte(v and 0xFF'u32)
  buf.add byte((v shr 8) and 0xFF'u32)
  buf.add byte((v shr 16) and 0xFF'u32)
  buf.add byte((v shr 24) and 0xFF'u32)

proc readU32LEw(buf: openArray[byte]; off: int): uint32 {.inline.} =
  uint32(buf[off]) or
    (uint32(buf[off + 1]) shl 8) or
    (uint32(buf[off + 2]) shl 16) or
    (uint32(buf[off + 3]) shl 24)

# ---------------------------------------------------------------------------
# Encode / decode
# ---------------------------------------------------------------------------

proc encodeWebpFlags*(flags: WebpFlags): uint8 =
  result = 0
  if flags.isStillFrame: result = result or 0x01'u8

proc decodeWebpFlags*(b: uint8): WebpFlags =
  if (b and 0xFE'u8) != 0:
    raise newException(PacketProtocolError,
      "W flag byte has non-zero reserved bits: " & $b)
  result.isStillFrame = (b and 0x01'u8) != 0

proc encodeWebpFrame*(w: WebpFrame): seq[byte] =
  ## Encode a W packet per the wire format documented in the module
  ## header. Raises ``PacketProtocolError`` on shape violations
  ## (codec_id longer than 255 bytes; non-positive dims; empty
  ## RIFF bytes — every W packet MUST carry a complete RIFF blob,
  ## which is at minimum the 12-byte RIFF/WEBP header).
  if w.codecId.len > 255:
    raise newException(PacketProtocolError,
      "W codec_id length " & $w.codecId.len & " exceeds u8 max (255)")
  if w.width <= 0 or w.height <= 0:
    raise newException(PacketProtocolError,
      "W dimensions must be positive; got " & $w.width & "x" & $w.height)
  if w.riffBytes.len < 12:
    raise newException(PacketProtocolError,
      "W riffBytes too short to be a WebP RIFF container " &
      "(min 12 bytes for the RIFF/WEBP header); got " & $w.riffBytes.len)
  let headerBase = 15 + w.codecId.len
  result = newSeqOfCap[byte](headerBase + w.riffBytes.len)
  result.add byte('W')
  result.add encodeWebpFlags(w.flags)
  result.add byte(w.codecId.len)
  for ch in w.codecId: result.add byte(ch)
  putU32LEw(result, uint32(w.width))
  putU32LEw(result, uint32(w.height))
  putU32LEw(result, uint32(w.riffBytes.len))
  for b in w.riffBytes: result.add b

proc decodeWebpFrame*(bytes: openArray[byte]): WebpFrame =
  ## Decode a W packet. Raises ``PacketProtocolError`` on any wire
  ## violation (wrong tag, truncated header, reserved flag bits set,
  ## codec_id length runs past end of buffer, payload length mismatch).
  if bytes.len < 3:
    raise newException(PacketProtocolError,
      "W packet truncated; need >= 3 bytes for tag+flags+codec_len, got " &
      $bytes.len)
  if bytes[0] != byte('W'):
    raise newException(PacketProtocolError,
      "expected tag 'W' (0x57), got 0x" & toHex(int(bytes[0]), 2))
  let flags = decodeWebpFlags(bytes[1])
  let codecLen = int(bytes[2])
  let headerEnd = 3 + codecLen + 12  # +12 = w(4)+h(4)+len(4)
  if bytes.len < headerEnd:
    raise newException(PacketProtocolError,
      "W packet truncated; need >= " & $headerEnd & " bytes for header, got " &
      $bytes.len)
  var codecId = newString(codecLen)
  for i in 0 ..< codecLen: codecId[i] = char(bytes[3 + i])
  let widthOff = 3 + codecLen
  let width = int(readU32LEw(bytes, widthOff))
  let height = int(readU32LEw(bytes, widthOff + 4))
  let length = int(readU32LEw(bytes, widthOff + 8))
  if bytes.len - headerEnd != length:
    raise newException(PacketProtocolError,
      "W payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - headerEnd))
  var riff = newSeq[byte](length)
  for i in 0 ..< length: riff[i] = bytes[headerEnd + i]
  result = WebpFrame(flags: flags, codecId: codecId,
                     width: width, height: height,
                     riffBytes: riff)

proc peekIsWebpPacket*(bytes: openArray[byte]): bool {.inline.} =
  ## Cheap dispatcher probe: returns true if the buffer's first byte
  ## is the W tag. Mirrors ``packet_video.peekIsVideoPacket``.
  bytes.len >= 1 and bytes[0] == byte('W')

# ---------------------------------------------------------------------------
# Default codec identifier — convenience for launcher / test wiring.
# ---------------------------------------------------------------------------

const
  DefaultWebPCodecId* = "image/webp"
    ## MIME type the browser-side ``createImageBitmap(Blob)`` decoder
    ## expects. ELT-M8 always emits this value; future profiles (e.g.
    ## ``image/webp2``) would supply their own codec_id while reusing
    ## the W packet tag.
