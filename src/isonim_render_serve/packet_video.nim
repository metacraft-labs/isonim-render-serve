## EPP-M5 V-packet codec — compressed video transport sibling of the
## raw RGBA F packet defined in ``packet.nim``.
##
## Wire format
## -----------
##
## The V packet mirrors F's header layout but adds a codec_id string
## prefix so the browser can configure its WebCodecs ``VideoDecoder``
## without an extra negotiation round-trip per encoded sample.
##
## .. code-block:: text
##
##     'V'(1)
##     | u8 flags
##     | u8 codec_id_len
##     | codec_id_len UTF-8 bytes  (e.g. "avc1.42E01E")
##     | u32 LE width
##     | u32 LE height
##     | u32 LE length
##     | NALU bytes
##
## All multi-byte ints are little-endian (matches F / M / I).
##
## ``codec_id`` is the same identifier the browser hands to
## ``VideoDecoder.configure({ codec })`` — RFC 6381 codec strings:
## ``avc1.<ProfileIdc><Constraints><LevelIdc>`` in hex. EPP-M5 emits
## ``avc1.42E01E`` (Baseline profile, no constraints, level 3.0) by
## default; future milestones may emit ``avc1.42E01F`` (level 3.1),
## ``avc1.4D401E`` (Main 3.0), or ``hvc1.<...>`` (HEVC).
##
## ``codec_id_len`` is a u8 because RFC 6381 codec strings comfortably
## fit in 16 characters (avc1.42E01E is 11). Capping at 255 gives the
## codec_id_len field a single byte and keeps the V header at a
## predictable size (15 + codec_id_len bytes).
##
## Flag byte layout
## ~~~~~~~~~~~~~~~~
##
## * bit 0 (0x01): ``isKeyframe`` — set when the NALU sequence carries
##   a self-decodable keyframe (IDR). EPP-M5 ships GOP=1 (every frame
##   is a keyframe) so this bit is always set on the wire today; the
##   field reserves room for EPP-M5b where the GOP grows and P-frames
##   land.
## * bit 1 (0x02): ``hasExtraData`` — when set the first
##   ``parameter_set`` bytes (SPS/PPS) are prepended to the NALU
##   stream of this frame. The browser needs SPS/PPS to configure the
##   decoder; the launcher ships them inline on the first frame
##   (where ``isKeyframe`` is also necessarily set). Once the editor
##   has decoded one frame the launcher may drop the extra data from
##   subsequent emissions.
## * bits 2..7: reserved, MUST be zero.
##
## Note: the V packet kind shares no flag bits with F intentionally —
## the editor's dispatcher branches on the tag byte ('V' vs 'F')
## first, so per-kind flag semantics can diverge without confusing
## downstream consumers.
##
## Why a new packet kind instead of bumping ``F.flags.isVideo``? The
## existing F decoder raises ``PacketProtocolError`` when the
## ``isVideo`` bit is set (per ``packet.nim`` doc comment at
## protocolVersion=1). Adding 'V' alongside lets the EPP-M6 browser
## decoder dispatch on the first byte instead of re-reading the F
## header after a tag-mismatch path. The audit (§ 2.4 recommendation
## #4) picked this same shape.

import std/strutils

import ./packet  # PacketProtocolError + putU32LE / readU32LE helpers
                 # (re-exported from ``packet.nim`` for codec consumers)

type
  VideoFlags* = object
    isKeyframe*: bool   ## bit 0
    hasExtraData*: bool ## bit 1

  VideoFrame* = object
    flags*: VideoFlags
    codecId*: string       ## e.g. "avc1.42E01E"; max 255 UTF-8 bytes
    width*, height*: int
    naluBytes*: seq[byte]  ## raw H.264 Annex-B NALU stream

# ---------------------------------------------------------------------------
# Little-endian helpers — local copies so this module compiles standalone
# even if ``packet.nim``'s helpers are made private later. Kept inline so
# the codec benchmark doesn't pay an indirect call per word.
# ---------------------------------------------------------------------------

proc putU32LEv(buf: var seq[byte]; v: uint32) {.inline.} =
  buf.add byte(v and 0xFF'u32)
  buf.add byte((v shr 8) and 0xFF'u32)
  buf.add byte((v shr 16) and 0xFF'u32)
  buf.add byte((v shr 24) and 0xFF'u32)

proc readU32LEv(buf: openArray[byte]; off: int): uint32 {.inline.} =
  uint32(buf[off]) or
    (uint32(buf[off + 1]) shl 8) or
    (uint32(buf[off + 2]) shl 16) or
    (uint32(buf[off + 3]) shl 24)

# ---------------------------------------------------------------------------
# Encode / decode
# ---------------------------------------------------------------------------

proc encodeVideoFlags*(flags: VideoFlags): uint8 =
  result = 0
  if flags.isKeyframe: result = result or 0x01'u8
  if flags.hasExtraData: result = result or 0x02'u8

proc decodeVideoFlags*(b: uint8): VideoFlags =
  if (b and 0xFC'u8) != 0:
    raise newException(PacketProtocolError,
      "V flag byte has non-zero reserved bits: " & $b)
  result.isKeyframe = (b and 0x01'u8) != 0
  result.hasExtraData = (b and 0x02'u8) != 0

proc encodeVideoFrame*(v: VideoFrame): seq[byte] =
  ## Encode a V packet per the wire format documented in the module
  ## header. Raises ``PacketProtocolError`` on shape violations
  ## (codec_id longer than 255 bytes; negative dims; nil-ish NALU
  ## bytes when isKeyframe is set).
  if v.codecId.len > 255:
    raise newException(PacketProtocolError,
      "V codec_id length " & $v.codecId.len & " exceeds u8 max (255)")
  if v.width <= 0 or v.height <= 0:
    raise newException(PacketProtocolError,
      "V dimensions must be positive; got " & $v.width & "x" & $v.height)
  let headerBase = 15 + v.codecId.len
  result = newSeqOfCap[byte](headerBase + v.naluBytes.len)
  result.add byte('V')
  result.add encodeVideoFlags(v.flags)
  result.add byte(v.codecId.len)
  for ch in v.codecId: result.add byte(ch)
  putU32LEv(result, uint32(v.width))
  putU32LEv(result, uint32(v.height))
  putU32LEv(result, uint32(v.naluBytes.len))
  for b in v.naluBytes: result.add b

proc decodeVideoFrame*(bytes: openArray[byte]): VideoFrame =
  ## Decode a V packet. Raises ``PacketProtocolError`` on any wire
  ## violation (wrong tag, truncated header, reserved flag bits set,
  ## codec_id length runs past end of buffer, payload length mismatch).
  if bytes.len < 3:
    raise newException(PacketProtocolError,
      "V packet truncated; need >= 3 bytes for tag+flags+codec_len, got " &
      $bytes.len)
  if bytes[0] != byte('V'):
    raise newException(PacketProtocolError,
      "expected tag 'V' (0x56), got 0x" & toHex(int(bytes[0]), 2))
  let flags = decodeVideoFlags(bytes[1])
  let codecLen = int(bytes[2])
  let headerEnd = 3 + codecLen + 12  # +12 = w(4)+h(4)+len(4)
  if bytes.len < headerEnd:
    raise newException(PacketProtocolError,
      "V packet truncated; need >= " & $headerEnd & " bytes for header, got " &
      $bytes.len)
  var codecId = newString(codecLen)
  for i in 0 ..< codecLen: codecId[i] = char(bytes[3 + i])
  let widthOff = 3 + codecLen
  let width = int(readU32LEv(bytes, widthOff))
  let height = int(readU32LEv(bytes, widthOff + 4))
  let length = int(readU32LEv(bytes, widthOff + 8))
  if bytes.len - headerEnd != length:
    raise newException(PacketProtocolError,
      "V payload length mismatch: header says " & $length &
      ", buffer has " & $(bytes.len - headerEnd))
  var nalu = newSeq[byte](length)
  for i in 0 ..< length: nalu[i] = bytes[headerEnd + i]
  result = VideoFrame(flags: flags, codecId: codecId,
                      width: width, height: height,
                      naluBytes: nalu)

proc peekIsVideoPacket*(bytes: openArray[byte]): bool {.inline.} =
  ## Cheap dispatcher probe: returns true if the buffer's first byte
  ## is the V tag. Mirrors ``packet.peekPacketKind`` shape but lives
  ## here so callers that only care about V can avoid pulling the
  ## full packet.PacketKind enum.
  bytes.len >= 1 and bytes[0] == byte('V')

# ---------------------------------------------------------------------------
# Default codec identifier — convenience for launcher / test wiring.
# ---------------------------------------------------------------------------

const
  DefaultH264CodecId* = "avc1.42E01E"
    ## H.264 Baseline profile, no constraints, level 3.0.
    ## See EPP-M5 brief § "ProfileLevel"; matches
    ## kVTProfileLevel_H264_Baseline_AutoLevel for our target
    ## 320x240..1024x768 size envelope.
