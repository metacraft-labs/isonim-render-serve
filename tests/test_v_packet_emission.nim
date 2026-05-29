## EPP-M5 — bridge V vs F selection.
##
## *Claim.* A ``BridgeConfig`` configured with ``encoder = ekH264``
## and a non-nil ``encoderHandle`` emits V packets; the same config
## with ``encoder = ekRawRgba`` emits F packets. The hello
## capability bag advertises both transports when V is enabled and
## only the F transport when not.
##
## Real stack: real ``BridgeConfig``, real stub frame source, real
## ``asyncnet`` client, real RFC 6455 framing both directions. On
## macOS the encoder is the real VideoToolbox session. On Linux the
## V branch is skipped (no hardware H.264 encoder).

import std/[asyncdispatch, asyncnet, json, random, unittest]

import isonim_render_serve
import ./ws_test_client

proc makeStubCfgVideo(port: int; encoder: EncoderKind;
                      encoderHandle: H264EncoderHandle;
                      fps = 30; maxFrames = 0): BridgeConfig =
  ## Like ``makeStubConfig`` but pins the encoder kind + handle for
  ## the EPP-M5 emission test. Uses a small 320x240 stub source so
  ## the test doesn't pay the cost of a huge gradient compute per
  ## tick.
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: "stub",
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: newStubFrameSource(320, 240).toAny(),
    encoder: encoder,
    encoderHandle: encoderHandle)

proc collectFirstPackets(port: int; minF, minV: int):
    Future[tuple[hello: JsonNode, fCount: int, vCount: int,
                  firstV: VideoFrame]] {.async.} =
  let sock = await connectWs(port)
  let state = newWsClientState()
  var hello = newJNull()
  var fCount = 0
  var vCount = 0
  var firstV: VideoFrame
  var firstVCaptured = false
  while (fCount < minF or vCount < minV):
    let msg = await recvOneMessage(sock, state)
    if not msg.complete: break
    if msg.opcode != wsOpBinary: continue
    let raw = stringToBytes(msg.payload)
    if raw.len == 0: continue
    case char(raw[0])
    of 'M':
      if hello.kind == JNull:
        let m = decodeMeta(raw)
        try:
          hello = parseJson(m.json)
        except CatchableError:
          hello = newJNull()
    of 'F':
      inc fCount
    of 'V':
      let v = decodeVideoFrame(raw)
      if not firstVCaptured:
        firstV = v
        firstVCaptured = true
      inc vCount
    else:
      discard
  sock.close()
  return (hello, fCount, vCount, firstV)

suite "EPP-M5: bridge V vs F selection":

  test "ekRawRgba bridge emits F packets and advertises only f/raw_rgba":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeStubCfgVideo(port, ekRawRgba, nil,
                                  fps = 50, maxFrames = 3)
      discard startServer(cfg)
      let res = waitFor collectFirstPackets(port, minF = 3, minV = 0)
      check res.fCount >= 3
      check res.vCount == 0
      check res.hello.kind == JObject
      check res.hello["type"].getStr == "hello"
      let caps = res.hello["capabilities"]
      check caps["encoder"].getStr == "raw_rgba"
      let transports = caps["transports"]
      check transports.kind == JArray
      check transports.len == 1
      check transports[0].getStr == "f/raw_rgba"
      check not caps.hasKey("videoCodecId")
      for i in 0 .. 5: poll(20)

  when defined(macosx):
    test "ekH264 bridge emits V packets and advertises both transports":
      randomize()
      let port = pickPort()
      let handle = newH264EncoderHandle(320, 240, bitrate = 1_500_000)
      check handle != nil
      let cfg = makeStubCfgVideo(port, ekH264, handle,
                                  fps = 50, maxFrames = 3)
      discard startServer(cfg)
      let res = waitFor collectFirstPackets(port, minF = 0, minV = 3)
      check res.vCount >= 3
      check res.fCount == 0
      check res.hello.kind == JObject
      let caps = res.hello["capabilities"]
      check caps["encoder"].getStr == "h264_videotoolbox"
      let transports = caps["transports"]
      check transports.kind == JArray
      check transports.len == 2
      check transports[0].getStr == "v/h264_videotoolbox"
      check transports[1].getStr == "f/raw_rgba"
      # EPP-M9: codec_id is now derived from the encoder's actually-
      # chosen H.264 profile/level (per ``profileLevelToCodecId``).
      # The picker enforces a Baseline 4.0 floor so the codec_id stays
      # stable at ``avc1.420028`` across the editor's pinned viewport
      # ladder (Desktop / Laptop / Tablet / Phone). Constraint byte
      # ``0x00`` mirrors what VideoToolbox actually emits in the SPS
      # ``constraint_set_flags`` — a previous draft used ``0xE0`` and
      # tripped Chrome's WebCodecs configure rejection. The floor
      # applies for the stub source's 320x240 dims here too.
      check caps["videoCodecId"].getStr == "avc1.420028"
      # First V packet must carry SPS/PPS (every frame is keyframe at
      # GOP=1) and valid Annex-B framing.
      check res.firstV.flags.isKeyframe
      check res.firstV.flags.hasExtraData
      check res.firstV.width == 320
      check res.firstV.height == 240
      check res.firstV.codecId == "avc1.420028"  # EPP-M9 Baseline 4.0
                                                  # floor — see hello-bag
                                                  # assertion above for why.
      check res.firstV.naluBytes.len > 0
      # Annex-B start code: NALU stream must begin with 0x00000001.
      check res.firstV.naluBytes[0] == 0x00'u8
      check res.firstV.naluBytes[1] == 0x00'u8
      check res.firstV.naluBytes[2] == 0x00'u8
      check res.firstV.naluBytes[3] == 0x01'u8
      destroy(handle)
      for i in 0 .. 5: poll(20)
  else:
    test "ekH264 bridge path skipped on non-macOS hosts":
      check true

  test "selectEncoderKind degrades ekH264 to ekRawRgba on hosts without VT":
    ## Document the audit-mandated fallback shape: ``selectEncoderKind``
    ## probes the host once and pins the answer. On macOS we expect
    ## ``ekH264`` to survive; elsewhere we expect ``ekRawRgba``.
    let resolved = selectEncoderKind(ekH264)
    when defined(macosx):
      check resolved == ekH264
    else:
      check resolved == ekRawRgba
    # ekRawRgba always returns itself regardless of host capability.
    check selectEncoderKind(ekRawRgba) == ekRawRgba
