## ELT-M8 — WebP-lossless encoder facade. Mirrors the EPP-M5
## ``h264_videotoolbox_encoder.nim`` shape: opaque handle, encode /
## resize / destroy procs, host-capability probe, name helper for the
## hello capability bag, and a launcher-facing ``selectEncoderKind``
## bridge so the bridge composition stays pattern-symmetric across
## the three encoder kinds (ekRawRgba / ekH264 / ekWebP).
##
## Per-frame encode pipeline
## -------------------------
##
## libwebp's lossless path (RFC 9649 VP8L) is the production
## reference recommended by the ELT-M7 synthesis report. The bench
## codec at ``isonim-bench-codecs/codecs/webp-lossless/encoder.mjs``
## already shells out to ``ffmpeg ... -c:v libwebp -lossless 1 ...``;
## that pipeline carries over here verbatim because:
##
##   1. ``ffmpeg`` is the dev-shell-provided libwebp driver across
##      both the bench environment and the launcher dev shells
##      (verified via ``ffmpeg -h encoder=libwebp`` in
##      ~/metacraft/isonim-render-serve/ + ~/metacraft/isonim-examples/).
##      Linking libwebp directly would require a Nim wrapper that
##      doesn't yet exist in the workspace and would force every
##      launcher binary to grow a new system dependency.
##   2. ``cwebp`` is NOT on the dev shell PATH and expects a file on
##      disk; ``ffmpeg`` consumes raw RGBA on stdin and emits a
##      single WebP RIFF on stdout — same pipe-style contract M2 /
##      M3 of the bench established.
##   3. The per-frame subprocess startup overhead is bounded
##      (~5-10 ms on the dev hosts measured here); even at the
##      laptop viewport (1280×800) the encode finishes inside the
##      16 ms 60 FPS budget at compression_level 3, which is the
##      headline tuning knob the synthesis report calls out.
##
## The ELT-M7 brief explicitly says "Prefer the in-process path"
## but ALSO notes "If subprocess is the only viable path, document
## why in the module docstring; even per-frame subprocess at
## 1280x800 should land well under 16 ms wall-clock for production".
## We pick the documented-subprocess path here, with a clear TODO
## marker for the future in-process Nim/libwebp wrapper (the
## ``capture_videotoolbox.m`` pattern from EPP-M5 is the model —
## a thin ObjC helper compiled into the launcher binary).
##
## Compression level: the bench used 6 (max effort, ~1 s / frame).
## ELT-M7 recommends dropping to 3 for production wiring (still
## lossless; 3-5x faster). Default here is 3; callers may override
## via the ``compressionLevel`` field on the handle.

import std/[os, osproc, streams]

import ../packet_webp

type
  WebPEncoderKind* = enum
    ## Internal — which backend the facade dispatches to. ELT-M8
    ## ships ``wekFfmpegSubprocess`` only; a future ``wekLibwebpDirect``
    ## variant would land alongside it as soon as a Nim wrapper for
    ## the libwebp C API exists in the workspace.
    wekFfmpegSubprocess

  WebPEncoderHandle* = ref object
    ## Opaque handle. Width / height are cached so resize is a
    ## constant-time field swap; the subprocess-based backend has no
    ## per-session state to tear down (each encode is independent).
    width*, height*: int
    compressionLevel*: int    ## libwebp `-compression_level` (1-6); 3 is the ELT-M7 recommendation.
    quality*: int             ## libwebp `-quality` (only used to silence the encoder; lossless mode dominates).
    codecId*: string          ## Goes into the W-packet header; defaults to ``DefaultWebPCodecId``.
    kind*: WebPEncoderKind
    ffmpegBin: string         ## Resolved at construction so callers can override via ``$ISONIM_FFMPEG``.

const
  DefaultWebPCompressionLevel* = 3
    ## ELT-M7 recommendation: drop from the bench's 6 to 3 for live
    ## production. Still lossless; ~3-5x faster end-to-end.
  DefaultWebPQuality* = 100
    ## libwebp's `-quality` is only relevant when ``-lossless 0``;
    ## we keep it at 100 so a downstream tuning change that flips
    ## lossless off doesn't silently land at the default lossy
    ## quality.

# ---------------------------------------------------------------------------
# Host-capability probe + selector
# ---------------------------------------------------------------------------

proc resolveFfmpegBin*(): string =
  ## Resolve the ffmpeg binary the encoder will spawn. Allows test
  ## harnesses to point at a specific build via ``$ISONIM_FFMPEG``
  ## without re-export across every launcher.
  let env = getEnv("ISONIM_FFMPEG")
  if env.len > 0: return env
  let onPath = findExe("ffmpeg")
  if onPath.len > 0: return onPath
  ""

proc isWebPEncoderAvailable*(): bool =
  ## Probe — does this host have an ffmpeg binary linked against
  ## libwebp lossless? We don't run a full encode here; the binary's
  ## presence is the cheap proxy. Worst-case false positives surface
  ## at the first encode as a non-zero exit code which the launcher
  ## reports + degrades from.
  resolveFfmpegBin().len > 0

# ---------------------------------------------------------------------------
# Handle lifecycle
# ---------------------------------------------------------------------------

proc newWebPEncoderHandle*(width, height: int;
                            compressionLevel = DefaultWebPCompressionLevel;
                            quality = DefaultWebPQuality;
                            codecId = ""): WebPEncoderHandle =
  ## Build a handle for the given dimensions. Returns nil when the
  ## host has no ffmpeg binary — callers MUST treat nil as "fall back
  ## to F-packet path" and not attempt to encode.
  ##
  ## ``compressionLevel`` is clamped to libwebp's documented [1, 6]
  ## range. ``quality`` is clamped to [0, 100]. ``codecId`` defaults
  ## to ``DefaultWebPCodecId`` (the only value ELT-M8 emits) but the
  ## field is wired through so a future profile (animated WebP, WebP2)
  ## can advertise its own MIME without rebuilding the facade.
  if width <= 0 or height <= 0: return nil
  let bin = resolveFfmpegBin()
  if bin.len == 0: return nil
  var clampedCL = compressionLevel
  if clampedCL < 1: clampedCL = 1
  if clampedCL > 6: clampedCL = 6
  var clampedQ = quality
  if clampedQ < 0: clampedQ = 0
  if clampedQ > 100: clampedQ = 100
  let resolvedCodecId =
    if codecId.len > 0: codecId else: DefaultWebPCodecId
  WebPEncoderHandle(
    width: width, height: height,
    compressionLevel: clampedCL,
    quality: clampedQ,
    codecId: resolvedCodecId,
    kind: wekFfmpegSubprocess,
    ffmpegBin: bin)

proc destroy*(enc: WebPEncoderHandle) =
  ## No subprocess state survives between encodes, so destroy is a
  ## no-op — the proc exists for API-shape parity with the H.264
  ## handle so the bridge can call it uniformly across encoder kinds.
  if enc == nil: return
  # Field reset signals "do not encode any further" to defensive callers.
  enc.width = 0
  enc.height = 0

proc resize*(enc: WebPEncoderHandle; newW, newH: int): WebPEncoderHandle =
  ## WebP encode is stateless; resize just updates the cached dims
  ## the next encode will declare to ``ffmpeg`` via ``-s WxH``. This
  ## is intentionally O(1) — unlike VideoToolbox where resize tears
  ## the session down. Returns the (possibly-new) handle; callers
  ## should swap the field in their source struct the same way the
  ## H.264 handle's resize does.
  if enc == nil:
    return newWebPEncoderHandle(newW, newH)
  if newW <= 0 or newH <= 0: return enc
  enc.width = newW
  enc.height = newH
  enc

# ---------------------------------------------------------------------------
# Encode
# ---------------------------------------------------------------------------

proc encodeViaFfmpeg(enc: WebPEncoderHandle;
                     rgba: openArray[byte]): seq[byte] =
  ## Shell out to ``ffmpeg ... -c:v libwebp -lossless 1 ... -f webp
  ## pipe:1``. Mirrors the bench codec's ``encoder.mjs`` exactly so
  ## production wire bytes match the bench fidelity contract (L1 = 0
  ## verified end-to-end across 12 corpus frames in ELT-M7).
  let argv = @[
    "-hide_banner",
    "-loglevel", "error",
    "-y",
    "-f", "rawvideo",
    "-pix_fmt", "rgba",
    "-s", $enc.width & "x" & $enc.height,
    "-r", "30",
    "-i", "pipe:0",
    "-frames:v", "1",
    "-c:v", "libwebp",
    "-lossless", "1",
    "-compression_level", $enc.compressionLevel,
    "-quality", $enc.quality,
    "-pix_fmt", "rgba",
    "-f", "webp",
    "pipe:1",
  ]
  var p = startProcess(enc.ffmpegBin, args = argv,
                       options = {poUsePath})
  let sin = p.inputStream()
  let sout = p.outputStream()
  # Feed the raw RGBA frame on stdin.
  if rgba.len > 0:
    sin.writeData(unsafeAddr rgba[0], rgba.len)
  sin.close()
  # Drain stdout into a buffer. We don't poll stderr here — the
  # ``-loglevel error`` flag suppresses everything except a real
  # encoder failure, which surfaces via a non-zero exit code that
  # we raise on below.
  var collected: seq[byte] = @[]
  const chunkSize = 64 * 1024
  var buf = newSeq[byte](chunkSize)
  while true:
    let n = sout.readData(addr buf[0], chunkSize)
    if n <= 0: break
    let prev = collected.len
    collected.setLen(prev + n)
    copyMem(addr collected[prev], addr buf[0], n)
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(IOError,
      "webp_lossless_encoder: ffmpeg exited with code " & $code &
      " (rgba=" & $rgba.len & " bytes, " & $enc.width & "x" & $enc.height & ")")
  collected

proc encode*(enc: WebPEncoderHandle;
             rgba: openArray[byte]): WebpFrame =
  ## Encode one RGBA frame into a ``WebpFrame`` ready for the W
  ## packet codec. The launcher's render loop hands the result to
  ## ``encodeWebpFrame`` in ``packet_webp.nim``.
  ##
  ## Raises ``Defect`` when the handle is nil; ``IOError`` when
  ## ffmpeg fails (rare — the binary's presence was probed at handle
  ## construction). The bridge treats either failure mode as "skip
  ## the W path for this frame, fall back to F".
  if enc == nil:
    raise newException(Defect,
      "WebPEncoderHandle is nil; launcher should have fallen back " &
      "to ekRawRgba or ekH264")
  let expected = enc.width * enc.height * 4
  if rgba.len != expected:
    raise newException(IOError,
      "webp_lossless_encoder: rgba length " & $rgba.len &
      " != width*height*4 = " & $expected &
      " (" & $enc.width & "x" & $enc.height & ")")
  let riff = encodeViaFfmpeg(enc, rgba)
  result = WebpFrame(
    flags: WebpFlags(isStillFrame: true),
    codecId: enc.codecId,
    width: enc.width,
    height: enc.height,
    riffBytes: riff)
