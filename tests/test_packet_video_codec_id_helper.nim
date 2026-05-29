## EPP-M9 — V-packet codec_id helper.
##
## *Claim.* ``profileLevelToCodecId(profileIdc, levelIdc)`` produces
## the RFC 6381 ``avc1.<ProfileIDC><Constraints><LevelIDC>`` codec
## string with each byte hex-encoded in upper-case ASCII. The helper
## is the single source of truth for the codec_id the V-packet
## advertises — the launcher's encoder picks a profile/level at
## VTCompressionSession-create time and the helper turns that pair
## into the exact string the browser's WebCodecs ``VideoDecoder.configure``
## consumes.
##
## *Methodology.* Walk a matrix of (profile, level, expected) triples
## locking down the contract for Baseline / Main / High at every level
## the EPP-M9 selector picks from. Then assert
## ``DefaultH264CodecId`` equals ``profileLevelToCodecId(Baseline, 4.0)``
## so the campaign-locked default is itself derived from the helper
## (no second source of truth to drift).

import std/[strutils, unittest]

import isonim_render_serve

suite "EPP-M9: codec_id helper":

  test "Baseline / Main / High at the EPP-M9 levels":
    type Triple = tuple[profile, level: int; expected: string]
    const cases: array[15, Triple] = [
      # Baseline ladder — what the EPP-M9 selector picks first. The
      # constraint byte is ``0x00`` because the VideoToolbox encoder
      # emits SPS NALUs with ``constraint_set_flags = 0x00`` for the
      # Baseline 4.0 floor (verified by dumping the SPS bytes from a
      # live session at 800×600 — see packet_video.nim const doc).
      (H264ProfileBaseline, 0x1E, "avc1.42001E"),  # 3.0
      (H264ProfileBaseline, 0x1F, "avc1.42001F"),  # 3.1
      (H264ProfileBaseline, 0x20, "avc1.420020"),  # 3.2
      (H264ProfileBaseline, 0x28, "avc1.420028"),  # 4.0 (EPP-M9 default)
      (H264ProfileBaseline, 0x29, "avc1.420029"),  # 4.1
      (H264ProfileBaseline, 0x2A, "avc1.42002A"),  # 4.2
      (H264ProfileBaseline, 0x32, "avc1.420032"),  # 5.0
      (H264ProfileBaseline, 0x33, "avc1.420033"),  # 5.1
      (H264ProfileBaseline, 0x34, "avc1.420034"),  # 5.2
      # Main fallback (constraint byte still 0x00 — the helper mirrors
      # what the encoder produces, not the marketing-name profile
      # number from the brief).
      (H264ProfileMain, 0x28, "avc1.4D0028"),
      (H264ProfileMain, 0x29, "avc1.4D0029"),
      # High fallback at 4.0/4.1/4.2.
      (H264ProfileHigh, 0x28, "avc1.640028"),
      (H264ProfileHigh, 0x29, "avc1.640029"),
      (H264ProfileHigh, 0x2A, "avc1.64002A"),
      # Level 0xFF — boundary of the u8 range, helper must not truncate.
      (H264ProfileBaseline, 0xFF, "avc1.4200FF"),
    ]
    for c in cases:
      check profileLevelToCodecId(c.profile, c.level) == c.expected

  test "DefaultH264CodecId is derived from the helper":
    ## EPP-M9 campaign-locked default: Baseline 4.0. The helper is the
    ## canonical builder so the const must NOT drift from it.
    check DefaultH264CodecId ==
      profileLevelToCodecId(H264ProfileBaseline, 0x28)
    check DefaultH264CodecId == "avc1.420028"

  test "codec_id is always 11 ASCII characters":
    ## Wire-format contract: the V-packet header's ``codec_id_len`` is a
    ## single byte so any helper output longer than 255 chars is invalid.
    ## Standard AVC strings land at 11; the helper must not pad.
    for p in [H264ProfileBaseline, H264ProfileMain, H264ProfileHigh]:
      for l in [0x1E, 0x28, 0x34, 0xFF]:
        let s = profileLevelToCodecId(p, l)
        check s.len == 11
        check s.startsWith("avc1.")

  test "out-of-range bytes raise PacketProtocolError":
    expect PacketProtocolError:
      discard profileLevelToCodecId(-1, 0x28)
    expect PacketProtocolError:
      discard profileLevelToCodecId(0x100, 0x28)
    expect PacketProtocolError:
      discard profileLevelToCodecId(H264ProfileBaseline, -5)
    expect PacketProtocolError:
      discard profileLevelToCodecId(H264ProfileBaseline, 0x1_00)

  test "hex digits are upper-case":
    ## Browsers accept either case but the spec recommends upper. We
    ## standardise on upper to match Apple's bundled ffprobe output
    ## and the EPP-M5 doc strings.
    let s = profileLevelToCodecId(H264ProfileBaseline, 0x2A)
    check s == "avc1.42002A"
    for ch in s[5 .. ^1]:
      if ch in {'a'..'z'}:
        check false  # any lower-case hex is a regression

  test "constraint byte is fixed at 0x00":
    ## EPP-M9 holds the constraints field constant at ``0x00`` to
    ## mirror the VideoToolbox encoder's SPS — see the const's
    ## doc-comment in packet_video.nim for why a mismatch trips
    ## Chrome's WebCodecs configure rejection.
    check H264ConstraintSetByte == 0x00
    let s = profileLevelToCodecId(H264ProfileBaseline, 0x28)
    check s[7..8] == "00"
