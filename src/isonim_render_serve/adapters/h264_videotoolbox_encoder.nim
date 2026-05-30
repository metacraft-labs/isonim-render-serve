## EPP-M5 — render-serve facade over
## ``isonim_cocoa/appkit/capture_videotoolbox``.
##
## Mirrors the EPP-M4 ``cocoa_metal_capture.nim`` shape so the
## bridge / launcher composition treats VideoToolbox as one more
## adapter under ``adapters/``: the launcher imports this module
## unconditionally, asks ``selectEncoderKind`` which encoder kind to
## use, and never has to sprinkle ``when defined(macosx)`` guards
## across the wiring.
##
## The actual VideoToolbox FFI lives in
## ``isonim-cocoa/src/isonim_cocoa/testing/capture_videotoolbox.m``
## with the Nim wrapper at
## ``isonim-cocoa/src/isonim_cocoa/appkit/capture_videotoolbox.nim``.
## This module exists so a Linux build of ``isonim-render-serve`` can
## still ``import`` the symbol and unconditionally see "unavailable".

import std/os
when not defined(js):
  import std/dynlib

import ../packet_video

when defined(macosx):
  import isonim_cocoa/appkit/capture_videotoolbox as vt
  export vt.VideoToolboxEncoder, vt.VideoToolboxEncodedFrame
else:
  type
    VideoToolboxEncoder* = ref object
      ## Linux stub — always nil at runtime.
    VideoToolboxEncodedFrame* = object
      naluBytes*: seq[byte]
      isKeyframe*: bool

type
  EncoderKind* = enum
    ## Which encoder the launcher's render loop should run per frame.
    ## ``ekRawRgba`` is the EPP-M4 (and prior) baseline — the bridge
    ## emits raw F packets with RGBA8888 payload. ``ekH264`` is the
    ## EPP-M5 path: emit V packets with hardware-encoded H.264 NALU
    ## bytes. ``ekWebP`` is the ELT-M8 path: emit W packets with
    ## libwebp-lossless RIFF bytes, decoded browser-side via
    ## ``createImageBitmap(Blob)`` (no WebCodecs). Per the campaign
    ## brief's "dormant-code-on-loss" principle, ``ekWebP`` is the
    ## SHIP tier from ELT-M7 and is compiled into the editor build
    ## by default (``-d:withCodecWebP`` is on by default; turning it
    ## off compiles ``ekWebP`` out as ``ekRawRgba``).
    ##
    ## Future entries: ``ekJpegXl`` (gated behind
    ## ``-d:withCodecJpegXl``; dormant per ELT-M7), ``ekAv1Sct``
    ## (gated behind ``-d:withCodecAv1Sct``; dormant per ELT-M7),
    ## ``ekVaapi`` / ``ekNvenc`` (Linux hardware encoders deferred
    ## to a follow-up campaign).
    ekRawRgba
    ekH264
    ekWebP

  H264EncoderHandle* = ref object
    ## Polymorphic wrapper. On macOS ``handle`` holds the live
    ## ``VideoToolboxEncoder``; on Linux this field stays nil and the
    ## launcher composition falls back to ``ekRawRgba`` at boot.
    width*, height*: int
    bitrate*: int
    codecId*: string
    when defined(macosx):
      handle*: VideoToolboxEncoder
    else:
      handle*: pointer  ## always nil on Linux

proc isHardwareEncoderAvailable*(): bool =
  ## Probe — does this host expose a hardware H.264 encoder we know
  ## how to drive? Today: VideoToolbox on macOS, nothing on Linux.
  when defined(macosx):
    vt.isVideoToolboxAvailable()
  else:
    false

proc selectEncoderKind*(prefer: EncoderKind = ekH264): EncoderKind =
  ## Resolve a per-launcher encoder preference against host
  ## capability. ``ekRawRgba`` always returns itself; ``ekH264``
  ## degrades to ``ekRawRgba`` when the host can't produce H.264;
  ## ``ekWebP`` survives whenever the editor build was compiled with
  ## ``-d:withCodecWebP`` (the default — ELT-M8 ships WebP as the
  ## SHIP tier per ELT-M7 synthesis report) AND the host has an
  ## ffmpeg binary linked against libwebp. Without either, ``ekWebP``
  ## degrades to ``ekH264`` (if available) or ``ekRawRgba``.
  ##
  ## Called once at launcher boot. The result is pinned for the
  ## lifetime of the bridge connection so transient encoder failures
  ## don't oscillate the wire format.
  case prefer
  of ekRawRgba: ekRawRgba
  of ekH264:
    if isHardwareEncoderAvailable(): ekH264 else: ekRawRgba
  of ekWebP:
    when defined(withCodecWebP) and not defined(js):
      # Avoid an import cycle (the WebP adapter imports
      # ``packet_webp``; routing through this enum's host probe via
      # an import would pull the adapter in unconditionally). The
      # WebP host probe is intentionally a duplicate of
      # ``webp_lossless_encoder.isWebPEncoderAvailable``; both check
      # for either the FUH-M5 in-process libwebp dynlib OR an ffmpeg
      # binary on the PATH (or ``$ISONIM_FFMPEG``).
      # The JS target never runs the bridge directly (the editor's
      # JS bundle is the browser-side decoder), so the probe is
      # native-only.
      var hasBackend = false
      when defined(withInProcessWebP):
        # Lazy probe — if the dynlib loads, the in-process path is
        # live and ffmpeg presence is irrelevant. Mirrors the
        # ``isLibwebpAvailable`` shape in ``webp_libwebp_ffi``;
        # we can't import that module here without dragging the
        # FFI into every encoder selector, so we re-probe via
        # ``loadLib``.
        let probeLib = dynlib.loadLib(
          when defined(macosx): "libwebp.dylib"
          elif defined(linux): "libwebp.so.7"
          else: "libwebp")
        if probeLib != nil:
          dynlib.unloadLib(probeLib)
          hasBackend = true
      if not hasBackend:
        let env = getEnv("ISONIM_FFMPEG")
        let bin = if env.len > 0: env else: findExe("ffmpeg")
        if bin.len > 0: hasBackend = true
      if hasBackend: ekWebP
      elif isHardwareEncoderAvailable(): ekH264
      else: ekRawRgba
    else:
      # WebP compiled out (or JS target — the editor's browser bundle
      # never runs ``selectEncoderKind`` at runtime; it consults the
      # launcher's hello capability bag). Either way: behave as if
      # the host had no libwebp.
      if isHardwareEncoderAvailable(): ekH264 else: ekRawRgba

proc encoderKindName*(k: EncoderKind): string =
  ## Wire-format identifier surfaced in the hello capability bag.
  ## Mirrors EPP-M4's ``capturePathName`` shape so the editor's
  ## browser-side e2e harness can grep the hello JSON for the
  ## negotiated encoder without parsing more than the top-level
  ## string.
  case k
  of ekRawRgba: "raw_rgba"
  of ekH264:    "h264_videotoolbox"
  of ekWebP:    "webp_lossless"

proc newH264EncoderHandle*(width, height: int;
                           bitrate = 2_000_000;
                           codecId = ""): H264EncoderHandle =
  ## Build a live encoder. Returns nil if the host has no
  ## hardware encoder; the caller MUST treat nil as "fall back to
  ## ``ekRawRgba``" and not attempt to encode.
  ##
  ## ``bitrate`` is the per-second average target in bits. The
  ## EPP-M5 brief targets ~2 Mbps at 1024x768; for smaller surfaces
  ## the encoder honours the cap but typically lands below it.
  ##
  ## EPP-M9 ``codecId`` policy: if the caller passes the empty string
  ## (the new default), the codec_id is derived from the encoder's
  ## actually-chosen H.264 profile / level via
  ## ``profileLevelToCodecId``. This guarantees the wire-advertised
  ## codec string can never drift from the bytes the encoder produces
  ## — which was the EPP-M5 → EPP-M9 regression that broke Cocoa's
  ## V-decoder on Laptop / Desktop viewports. Callers MAY still pin
  ## an explicit codec_id string (e.g. for tests that need a known
  ## value); whatever they pass is shipped verbatim.
  when defined(macosx):
    if not vt.isVideoToolboxAvailable(): return nil
    let raw = vt.newVideoToolboxEncoder(width, height, bitrate)
    if raw == nil: return nil
    let resolvedCodecId =
      if codecId.len > 0: codecId
      elif raw.profileIdc != 0 and raw.levelIdc != 0:
        profileLevelToCodecId(raw.profileIdc, raw.levelIdc)
      else:
        DefaultH264CodecId
    H264EncoderHandle(width: width, height: height,
                      bitrate: bitrate, codecId: resolvedCodecId,
                      handle: raw)
  else:
    discard width; discard height; discard bitrate; discard codecId
    nil

proc destroy*(enc: H264EncoderHandle) =
  if enc == nil: return
  when defined(macosx):
    if enc.handle != nil:
      vt.destroy(enc.handle)
      enc.handle = nil
  else:
    discard

proc resize*(enc: H264EncoderHandle; newW, newH: int): H264EncoderHandle =
  ## VTCompressionSession is dimension-bound, so a resize means a
  ## destroy + re-create. Returns the new handle; the caller is
  ## responsible for swapping the field in its source struct.
  ## Pattern lifted from the EPP-M5 brief § "Encoder lifecycle hooks
  ## for resize".
  ##
  ## EPP-M9 codec_id policy: a resize re-derives the codec_id from the
  ## new encoder's profile/level selection. The previous EPP-M5
  ## behaviour propagated the old codec_id verbatim, which broke the
  ## browser's WebCodecs decoder when the new dims fell outside the
  ## old level's coded-dim cap (the audit § 2.1 root cause of EPP-M9).
  ## With the dynamic selector active a resize picks whatever level
  ## the new dims need; the codec_id derived from that level reflects
  ## the wire bytes the encoder actually produces, so the browser
  ## reconfigures its decoder correctly across the resize boundary.
  if enc == nil:
    return newH264EncoderHandle(newW, newH)
  let bitrate = enc.bitrate
  destroy(enc)
  newH264EncoderHandle(newW, newH, bitrate, codecId = "")

proc encode*(enc: H264EncoderHandle;
             rgba: openArray[byte]): VideoFrame =
  ## Encode one RGBA frame into a ``VideoFrame`` ready for the V
  ## packet codec. The launcher's render loop hands the result to
  ## ``encodeVideoFrame`` in ``packet_video.nim``.
  ##
  ## Raises ``Defect`` if the encoder is nil or the encoder backend
  ## fails (per ``capture_videotoolbox.encodeFrame``).
  if enc == nil:
    raise newException(Defect,
      "H264EncoderHandle is nil; launcher should have fallen back " &
      "to ekRawRgba")
  when defined(macosx):
    let raw = vt.encodeFrame(enc.handle, rgba)
    result = VideoFrame(
      flags: VideoFlags(isKeyframe: raw.isKeyframe,
                        hasExtraData: raw.isKeyframe),
      codecId: enc.codecId,
      width: enc.width, height: enc.height,
      naluBytes: raw.naluBytes)
  else:
    discard rgba
    raise newException(Defect,
      "H264 encoder is not available on this platform")
