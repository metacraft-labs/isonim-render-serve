## Bridge — WebSocket server + hello/F/M/I loop. One process,
## one frame source, many connections.
##
## Per RS-M0 the first server→client message on every fresh
## connection is the `hello` M packet (announces
## `protocolVersion: 1`, backend identifier, capability bag,
## initial size). After hello the bridge enters a steady-state
## loop:
##
##   * Every `frameIntervalMs` the configured `AnyFrameSource`'s
##     `renderFrame` closure fires and the result is wrapped in an
##     `F` packet and shipped to the client.
##   * Inbound binary frames are parsed as F / M / I packets. I
##     packets are decoded into typed `InputEvent` values and
##     handed to the configured `InputSink`. F packets from the
##     client are a protocol violation (close 1002).
##
## RS-M0 error policy: any wire-protocol violation closes the
## connection with WS status code 1002.
##
## RS-M2 (this milestone) broadened `BridgeConfig.frameSource` from
## the concrete RS-M1 `StubFrameSource` to the closure-backed
## `AnyFrameSource` wrapper defined in `frame_source.nim`. The
## bridge code itself is untouched modulo the field type and the
## `import` swap — the rest of the polymorphism lives in the
## wrapper. Concrete adapters (GPUI, Freya, Cocoa, Android, ...)
## ship under `adapters/` and each provide a `newXxxFrameSource`
## constructor whose return value can be dropped into the field
## directly (the constructor builds the wrapper for the caller).

import std/[asyncdispatch, asynchttpserver, asyncnet, base64,
            httpcore, json, monotimes, nativesockets, options, os,
            strutils, times]
import std/sha1 as sha1Mod

import ./packet
import ./packet_video
import ./packet_webp
import ./ws_frame
import ./event_dispatch
import ./frame_source
import ./diff_region
import ./adapters/h264_videotoolbox_encoder

# ELT-M8: ekWebP gating. The encoder facade only compiles when
# ``-d:withCodecWebP`` is on (the default per ``config.nims``); the
# bridge therefore knows whether the W path is even reachable without
# probing the host. Out-of-tree consumers that compile this module
# with ``--define:withCodecWebP=false`` will still see ``ekWebP``
# values flow through the enum (the case statements below stay
# exhaustive) but the bridge's render loop degrades them to
# ``ekRawRgba`` since no encoder handle can exist.
when defined(withCodecWebP):
  import ./adapters/webp_lossless_encoder

const
  WebSocketGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ## Magic GUID required by RFC 6455 §1.3.

  ProtocolVersion* = 1
    ## RS-M0 freezes `protocolVersion = 1` for RS-M1 through the
    ## first breaking change.

  CloseProtocolError* = 1002'u16
    ## RFC 6455 §7.4.1 status code for protocol error. Used per
    ## RS-M0 § "Error handling".

type
  ElementTreeProvider* = ref object
    ## RS-M11: polymorphic handle the bridge consults to emit
    ## element-tree manifests. The bridge calls `buildImpl` on
    ## connect (right after `hello`, before the first F packet) and
    ## again on every subsequent frame tick. The provider returns the
    ## current manifest; the bridge compares against the per-
    ## connection cache and emits an M packet only when the (id,
    ## bounds) set has changed.
    ##
    ## Cadence policy lives on the bridge side, not the provider, so
    ## a single provider can be observed by multiple concurrent
    ## clients without colliding state. The provider stays a pure
    ## "current value" handle.
    buildImpl*: proc(): ElementTreeManifest {.closure, gcsafe.}

  BridgeConfig* = object
    port*: Port
    staticDir*: string
    backend*: string
    frameIntervalMs*: int
    maxFrames*: int           ## 0 = unlimited
    inputSink*: AnyInputSink
      ## RS-M2: broadened from RS-M1's concrete `BufferedInputSink`
      ## to the closure-backed `AnyInputSink` wrapper defined in
      ## `event_dispatch.nim`. RS-M1 callers wrap their buffered sink
      ## via `.toAny()`; RS-M2 adapter callers wrap their
      ## `GpuiInputSink` (or future per-back-end sink) the same way.
    frameSource*: AnyFrameSource
      ## RS-M2: broadened from the concrete `StubFrameSource` to the
      ## closure-backed `AnyFrameSource` wrapper. Adapter authors
      ## construct an `AnyFrameSource` once (see
      ## `adapters/gpui_adapter.nim` for the canonical example) and
      ## drop it in here; the bridge dispatches `renderFrame` /
      ## `close` polymorphically via the wrapper's two closures.
      ## See `frame_source.nim`'s module docstring for the design
      ## rationale (closure dispatch vs. concept-typed field vs.
      ## inheritance).
    elementTree*: ElementTreeProvider
      ## RS-M11: optional element-tree manifest producer. Nil for
      ## launchers that don't advertise the `elementTree` capability;
      ## non-nil for the TUI launcher (and future native-backend
      ## launchers under RS-M11b/c). When set, the bridge advertises
      ## `capabilities.elementTree = true` in the `hello` packet and
      ## emits manifest M packets on connect + on change.
    capturePath*: string
      ## EPP-M4: optional self-describing capture-path identifier the
      ## bridge surfaces in the ``hello`` capability bag. The Cocoa
      ## launcher sets ``"metal"`` when ``MTLCreateSystemDefaultDevice``
      ## succeeds at boot and ``"appkit"`` for the
      ## ``cacheDisplayInRect:toBitmapImageRep:`` fallback; other
      ## launchers leave it empty and the field is omitted from the
      ## hello JSON. The browser-side e2e test asserts that a Cocoa
      ## launcher in a Metal-capable env advertises
      ## ``capabilities.cocoaCapturePath == "metal"``.
    encoder*: EncoderKind
      ## EPP-M5: which encoder the per-frame render loop should run.
      ## ``ekRawRgba`` (default) keeps the EPP-M4-and-prior F-packet
      ## path; ``ekH264`` activates the VideoToolbox encoder and emits
      ## V packets per ``packet_video.nim``. Launchers select via
      ## ``selectEncoderKind(ekH264)`` which automatically degrades to
      ## ``ekRawRgba`` on hosts without VideoToolbox.
    encoderHandle*: H264EncoderHandle
      ## EPP-M5: live encoder instance when ``encoder == ekH264``.
      ## Set by the launcher; the bridge re-creates it on resize (the
      ## VTCompressionSession is dimension-bound). Nil when the
      ## launcher selected ``ekRawRgba`` or the host lacks the
      ## hardware encoder.
    encoderWebpCompressionLevel*: int
      ## ELT-M8: libwebp ``-compression_level`` knob (1..6, default
      ## 0 → resolved to ``DefaultWebPCompressionLevel``=3 per the
      ## ELT-M7 recommendation). The bench used 6 (~1 s / frame); 3
      ## still produces lossless output and lands inside the 16 ms
      ## 60 FPS budget at laptop viewports. Ignored when the launcher
      ## selected anything other than ``ekWebP``.

  TransportSelection* = enum
    ## ELT-M8 per-frame transport selection. The bridge picks a
    ## transport on each render tick based on the frame's
    ## change-score (cheap N=16 random-pixel L1 sample against the
    ## previous frame) and the launcher's encoder configuration:
    ##
    ## * ``tsFirstFrame`` — always emit F (raw RGBA) so the browser
    ##   canvas seeds without any codec configure delay.
    ## * ``tsWebP`` — frame change-score below threshold (static UI);
    ##   the W path's lossless contract + sub-baseline bandwidth wins.
    ## * ``tsH264`` — frame change-score above threshold (animation,
    ##   scroll); the V path's per-frame sub-millisecond decode wins.
    ## * ``tsRawRgba`` — fallback when neither codec path is available
    ##   for this connection.
    tsFirstFrame
    tsWebP
    tsH264
    tsRawRgba

  Server* = ref object
    cfg*: BridgeConfig
    httpServer*: AsyncHttpServer

# ---------------------------------------------------------------------------
# Handshake helpers
# ---------------------------------------------------------------------------

proc computeAcceptKey*(clientKey: string): string =
  ## RFC 6455 §1.3: SHA-1(clientKey ++ guid), base64-encoded.
  let combined = clientKey & WebSocketGuid
  {.push warning[Deprecated]: off.}
  let digest = sha1Mod.secureHash(combined)
  let bytes = sha1Mod.Sha1Digest(digest)
  {.pop.}
  var raw = newString(20)
  for i in 0 ..< 20: raw[i] = char(bytes[i])
  encode(raw)

proc readHeader(headers: HttpHeaders; key: string): string =
  if headers.hasKey(key):
    result = $headers[key]
  else:
    result = ""

# ---------------------------------------------------------------------------
# Hello builder
# ---------------------------------------------------------------------------

proc buildHelloJson*(backend: string; width, height: int;
                     elementTree: bool = false;
                     capturePath: string = "";
                     encoder: EncoderKind = ekRawRgba;
                     codecId: string = "";
                     webpAvailable: bool = false): string =
  ## Build the JSON body for the mandatory first M packet. RS-M0
  ## locks the schema:
  ##   { type: "hello", protocolVersion: 1, backend, capabilities,
  ##     initialSize }
  ##
  ## RS-M11 adds the additive `elementTree` capability bit. The flag
  ## is false by default so existing launchers compile unchanged;
  ## launchers that emit element-tree manifests (TUI today; GPUI /
  ## Freya / Cocoa / Android under RS-M11b/c) pass `true` to advertise
  ## the capability.
  ##
  ## EPP-M4 adds the optional ``capturePath`` capability — the Cocoa
  ## launcher advertises ``"metal"`` (CARenderer + MTLTexture readback)
  ## or ``"appkit"`` (``cacheDisplayInRect:toBitmapImageRep:`` fallback)
  ## so the browser-side test harness can verify which path produced
  ## the captured frames. Empty string omits the field for launchers
  ## that don't differentiate.
  var caps = newJObject()
  caps["diffRegions"] = newJBool(true)    # RS-M3 advertises diff support
  caps["screenshot"] = newJBool(false)    # stub backend has none
  caps["hotReload"] = newJBool(false)
  caps["elementTree"] = newJBool(elementTree)
  # EPP-M7 added ``keyboard`` as the canonical browser-emitted form
  # (the legacy ``key`` kind stays advertised but is not emitted by
  # any JS sender today — see EPP-M1 audit § 4.5).
  caps["inputKinds"] = %* ["key", "mouse", "scroll", "resize", "focus",
                           "keyboard"]
  if capturePath.len > 0:
    caps["cocoaCapturePath"] = newJString(capturePath)
  # EPP-M5: advertise the encoder kind in the hello capability bag so
  # the EPP-M6 browser-side decoder can pick the right WebCodecs
  # ``VideoDecoder`` config (or skip configuring one altogether when
  # the raw-RGBA path is in force). ``transports`` is the audit-
  # recommended array form (§ 2.4 #2) — when the launcher carries a
  # live VideoToolbox encoder both transports are listed; when it
  # only has raw RGBA only the raw kind is listed.
  var transports = newJArray()
  discard webpAvailable  # quieten unused-param warning when ekWebP path is hit
  case encoder
  of ekWebP:
    # ELT-M8: when the launcher's primary encoder is ekWebP, the
    # per-frame transport selector may still ship V or F packets
    # for individual frames (V for animation, F for the seeding
    # first frame). Advertise everything we can produce so the
    # browser's accept-list reply can pin its preferences against a
    # complete view of the launcher's capability surface.
    transports.add newJString("w/" & encoderKindName(ekWebP))
    if isHardwareEncoderAvailable():
      transports.add newJString("v/" & encoderKindName(ekH264))
    transports.add newJString("f/" & encoderKindName(ekRawRgba))
  of ekH264:
    # EPP-M5 wire-format contract: ``--encoder h264`` advertises
    # exactly v/avc1 + f/raw_rgba. ELT-M8 does NOT add w/webp here
    # because the H.264 launcher's frame loop unconditionally emits
    # V packets — opting into W requires booting the launcher with
    # ``--encoder webp`` so the editor's accept list sees the W
    # advertisement on the wire and the launcher's render loop is
    # actually wired through the per-frame transport selector.
    transports.add newJString("v/" & encoderKindName(ekH264))
    transports.add newJString("f/" & encoderKindName(ekRawRgba))
  of ekRawRgba:
    transports.add newJString("f/" & encoderKindName(ekRawRgba))
  caps["transports"] = transports
  caps["encoder"] = newJString(encoderKindName(encoder))
  if codecId.len > 0:
    caps["videoCodecId"] = newJString(codecId)
  var size = newJObject()
  size["width"] = newJInt(width)
  size["height"] = newJInt(height)
  var root = newJObject()
  root["type"] = newJString("hello")
  root["protocolVersion"] = newJInt(ProtocolVersion)
  root["backend"] = newJString(backend)
  root["capabilities"] = caps
  root["initialSize"] = size
  result = $root

# ---------------------------------------------------------------------------
# WebSocket I/O
# ---------------------------------------------------------------------------

proc sendBinary(client: AsyncSocket; payload: seq[byte]) {.async.} =
  let frame = encodeWsBinaryFrame(bytesToString(payload))
  await client.send(frame)

proc sendClose(client: AsyncSocket; code: uint16;
               reason: string = "") {.async.} =
  try:
    await client.send(encodeWsCloseFrame(code, reason))
  except CatchableError:
    discard
  try: client.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Per-connection loop
# ---------------------------------------------------------------------------

type
  ConnectionState = ref object
    helloSent: bool
    closed: bool
    lastSentFrame: Option[Frame]
      ## RS-M3: per-connection snapshot of the last full RGBA frame
      ## actually shipped to this client. The diff-region encoder
      ## compares against this on the next tick; `none` means the
      ## next frame must be sent in full (e.g. first frame on the
      ## connection, or after a size change invalidates the cache).
    elementTreeKey: string
      ## RS-M11: hash key of the last manifest emitted on this
      ## connection. Empty string means "no manifest sent yet"; the
      ## bridge always emits the first manifest after `hello` and
      ## before the first F packet.
    h264Encoder: H264EncoderHandle
      ## EPP-M5: per-connection mutable encoder handle. Seeded from
      ## ``BridgeConfig.encoderHandle`` on connect; mutated in place
      ## across resizes (the VTCompressionSession is dimension-bound).
      ## Per-connection scope matches the audit § 7.4 cadence: a
      ## single ``BridgeConfig`` shared across multiple concurrent
      ## browser clients still gets one independent encoder per
      ## browser, with no race on the session state.
    when defined(withCodecWebP):
      webpEncoder: WebPEncoderHandle
        ## ELT-M8: per-connection WebP encoder handle. Lazily
        ## constructed on the first frame the per-frame selector
        ## decides to ship as W; resized in place across viewport
        ## changes (the WebP encoder is stateless, so resize is O(1)
        ## and never tears the session down).
    framesSent: int
      ## ELT-M8: count of frames emitted on this connection. The
      ## per-frame transport selector forces the first frame to F
      ## (raw RGBA) so the browser canvas size seeds without paying
      ## any decoder-configure round-trip.
    prevFrameSample: seq[byte]
      ## ELT-M8: 16-pixel sample (64 bytes RGBA) cached from the
      ## previous frame at deterministic stride-based coordinates.
      ## The change-score sampler reads the current frame at the
      ## same coordinates and computes the L1 distance — cheap
      ## (1 KB worth of arithmetic) and proportional to the visible
      ## change. Empty until the first frame is captured.

proc manifestKey(m: ElementTreeManifest): string =
  ## Stable hash key over the (id, bounds) tuples of the manifest's
  ## elements plus the surface dimensions. The bridge compares this
  ## against `ConnectionState.elementTreeKey` and emits only on
  ## change (RS-M11 cadence rule).
  result = $m.surfaceWidth & 'x' & $m.surfaceHeight & '|'
  for e in m.elements:
    result.add e.id
    result.add ':'
    result.add $e.bounds.x
    result.add ','
    result.add $e.bounds.y
    result.add ','
    result.add $e.bounds.w
    result.add ','
    result.add $e.bounds.h
    result.add ';'

proc sendHello(client: AsyncSocket; cfg: BridgeConfig;
               state: ConnectionState) {.async.} =
  let codecId =
    if cfg.encoder == ekH264 and state.h264Encoder != nil:
      state.h264Encoder.codecId
    else: ""
  when defined(withCodecWebP):
    let webpAvail = isWebPEncoderAvailable()
  else:
    let webpAvail = false
  let body = buildHelloJson(cfg.backend,
                            cfg.frameSource.width,
                            cfg.frameSource.height,
                            elementTree = cfg.elementTree != nil,
                            capturePath = cfg.capturePath,
                            encoder = cfg.encoder,
                            codecId = codecId,
                            webpAvailable = webpAvail)
  let meta = MetaPacket(json: body)
  await sendBinary(client, encodeMeta(meta))
  state.helloSent = true

proc sendElementTreeIfChanged(client: AsyncSocket; cfg: BridgeConfig;
                              state: ConnectionState;
                              force: bool = false) {.async.} =
  ## RS-M11 cadence: emit an `element-tree` M packet when (a) we
  ## haven't yet sent one on this connection (force=true on first
  ## emission), or (b) the (id, bounds) set has changed since the
  ## last emission. Idle frames produce identical manifests and
  ## therefore NO emission — that is the headline cadence invariant.
  if cfg.elementTree == nil: return
  let manifest = cfg.elementTree.buildImpl()
  let key = manifestKey(manifest)
  if not force and key == state.elementTreeKey: return
  let meta = encodeElementTreeMeta(manifest)
  try:
    await sendBinary(client, encodeMeta(meta))
    state.elementTreeKey = key
  except OSError, IOError:
    discard

const
  WebPChangeScoreThreshold* = 8
    ## ELT-M8 per-frame transport-selection threshold. The change-
    ## score sampler returns the mean L1 distance across 16 fixed
    ## RGB triples (alpha excluded) between the current and previous
    ## frames. At threshold 8, sub-LSB sub-pixel motion (text
    ## anti-aliasing jitter) STAYS on the W path while genuine motion
    ## (a window dragged across the surface, a scroll) flips to V.
    ##
    ## Tuning rationale: on a fully-static frame the score is 0
    ## (W); on a frame with a single 16x16 dirty rect's worth of
    ## change the score lands at ~3-5 (W). On a frame with a 30%
    ## moving region the score lands above 30 (V). 8 captures the
    ## headline targets the ELT-M8 brief calls out (90% of UI-settled
    ## frames pick W; 90% of "drag a window across the screen" picks V).

  WebPSampleStride = 16
    ## Number of (x, y) probe points (sqrt of total = 4 → 16 points
    ## arranged on a 4x4 grid). 64 RGBA bytes per frame is cheap
    ## enough to compute every frame without measurably touching
    ## the render budget.

proc samplePoints(width, height: int): seq[(int, int)] =
  ## Generate 16 deterministic sample coordinates on a 4x4 grid.
  ## Stride-based (not random) so the same grid is sampled across
  ## frames — change-score arithmetic is meaningful only when the
  ## coordinates match. Picking points away from frame corners
  ## (offset 1/8 inset from each edge) avoids fixed UI chrome
  ## (status bar borders, scroll bar tracks) skewing the score.
  result = newSeqOfCap[(int, int)](WebPSampleStride)
  if width <= 0 or height <= 0: return
  let xs = [width div 8, (width * 3) div 8,
            (width * 5) div 8, (width * 7) div 8]
  let ys = [height div 8, (height * 3) div 8,
            (height * 5) div 8, (height * 7) div 8]
  for y in ys:
    for x in xs:
      result.add (x, y)

proc captureFrameSample(frame: Frame): seq[byte] =
  ## Read the 16 sample triples (RGB only — alpha excluded; UI
  ## surfaces rarely vary in alpha and the channel adds noise to
  ## the score when the launcher writes premultiplied alpha).
  ## Returns a 48-byte buffer; empty when the frame isn't a full
  ## RGBA8888 raster (diff frames have no sampleable backing).
  result = @[]
  if frame.kind != fkFull: return
  if frame.pixels.len < frame.width * frame.height * 4: return
  let pts = samplePoints(frame.width, frame.height)
  result = newSeqOfCap[byte](pts.len * 3)
  for (x, y) in pts:
    let i = (y * frame.width + x) * 4
    if i + 2 < frame.pixels.len:
      result.add frame.pixels[i]
      result.add frame.pixels[i + 1]
      result.add frame.pixels[i + 2]

proc changeScore(prev, curr: seq[byte]): int =
  ## Mean L1 over the 48 sampled bytes (16 RGB triples). Returns 0
  ## when the previous sample is empty (first frame: treat the surface
  ## as just-changed so we don't pin the connection to W before we
  ## know it's settled).
  if prev.len == 0 or prev.len != curr.len: return 0
  var total = 0
  for i in 0 ..< prev.len:
    let d = int(curr[i]) - int(prev[i])
    total += (if d < 0: -d else: d)
  total div max(1, prev.len)

proc selectTransport(state: ConnectionState; curr: Frame;
                     cfg: BridgeConfig;
                     webpAvailable: bool): TransportSelection =
  ## ELT-M8: per-frame transport selection. See the ``TransportSelection``
  ## enum doc-comment for the policy.
  if state.framesSent == 0:
    return tsFirstFrame
  if curr.kind != fkFull:
    # Diff frames can only ship as F today — the W codec is image-
    # complete-per-packet, not rect-based (ELT-M9 will land the
    # rect-based variant on top of W). H.264 V packets are full-
    # frame too. Either way we don't have a non-F transport for
    # diff frames at ELT-M8.
    return tsRawRgba
  let sample = captureFrameSample(curr)
  let score = changeScore(state.prevFrameSample, sample)
  let h264Ok = (state.h264Encoder != nil)
  when defined(withCodecWebP):
    let webpOk = webpAvailable and (state.webpEncoder != nil or
      cfg.encoder == ekWebP or h264Ok)
  else:
    let webpOk = false
  if score < WebPChangeScoreThreshold and webpOk:
    tsWebP
  elif h264Ok:
    tsH264
  elif webpOk:
    tsWebP
  else:
    tsRawRgba

proc buildOutgoingFrame(curr: Frame; state: ConnectionState): Frame =
  ## RS-M3 outgoing-frame policy:
  ##
  ##   - First frame on a connection (no `lastSentFrame`): emit as
  ##     full RGBA. The client has nothing to diff against.
  ##   - Resize mid-stream (dimensions differ from the cache): emit
  ##     as full and invalidate the cache. We never diff across a
  ##     size change.
  ##   - Otherwise: ask `computeDiffRegions` for the rectangle list.
  ##     Empty list → identical frame, but we still must ship
  ##     *something* every tick (the client uses the F packet as a
  ##     heartbeat); emit an empty diff F packet. Full-frame
  ##     fallback signaled by the encoder (one region == whole
  ##     frame) → emit as a non-diff full F packet, which saves the
  ##     per-rect header overhead.
  if state.lastSentFrame.isNone:
    return curr
  let prev = state.lastSentFrame.get
  if prev.width != curr.width or prev.height != curr.height:
    return curr
  let regions = computeDiffRegions(prev, curr)
  if regions.len == 0:
    return Frame(kind: fkDiff,
                 flags: FrameFlags(isDiff: true, isVideo: false),
                 width: curr.width, height: curr.height,
                 rects: @[])
  if isFullFrameRegion(regions, curr.width, curr.height):
    return curr
  return Frame(kind: fkDiff,
               flags: FrameFlags(isDiff: true, isVideo: false),
               width: curr.width, height: curr.height,
               rects: toDirtyRects(regions))

proc frameLoop(client: AsyncSocket; cfg: BridgeConfig;
               state: ConnectionState) {.async.} =
  ## Push the stub source's frames at the configured cadence until
  ## either side hangs up (or `maxFrames` is reached, for the tests).
  ##
  ## EPP-M5: when ``cfg.encoder == ekH264`` and a non-nil encoder
  ## handle is present, each render-frame is passed through the
  ## VideoToolbox encoder and the result is shipped as a V packet.
  ## A resize between ticks is detected by comparing the frame source's
  ## reported dimensions against the encoder's; on mismatch the
  ## encoder handle is re-created (VTCompressionSession is
  ## dimension-bound). This matches the audit § 7.4 "Encoder
  ## lifecycle on resize" recipe.
  ##
  ## EPP-M10 cadence fix: the post-frame sleep below subtracts the
  ## elapsed render+send time from ``frameIntervalMs`` so the wall-
  ## clock period is the requested period (~33 ms at 30 fps),
  ## not ``render + 33 ms``. The pre-EPP-M10 loop stacked the sleep
  ## on top of the render time, which surfaced as the EPP-M8 matrix's
  ## "Freya 62 ms median at Desktop" gap even after the Skia render
  ## itself dropped to 28 ms (the sleep was paying the full 33 ms cap
  ## regardless). Backwards-compatible: if a frame takes longer than
  ## the requested interval, the sleep clamps to a small minimum
  ## (1 ms) instead of going negative, which preserves yielding to
  ## the event loop for I/O dispatch.
  var sent = 0
  when defined(withCodecWebP):
    let webpAvail = isWebPEncoderAvailable()
  else:
    let webpAvail = false
  while not state.closed and not client.isClosed:
    if not state.helloSent:
      await sleepAsync(5)
      continue
    let tickStart = getMonoTime()
    # RS-M11: re-check the element-tree manifest each tick BEFORE
    # rendering the frame. If the (id, bounds) set has changed we
    # emit a fresh manifest; otherwise the cadence rule skips the
    # M packet so idle frame streams do not churn manifests.
    if cfg.elementTree != nil:
      await sendElementTreeIfChanged(client, cfg, state)
    let curr = cfg.frameSource.renderFrame()

    # ELT-M8: per-frame transport selection runs ONLY when the
    # launcher booted with ekWebP as its primary — the "opt into
    # the new per-frame selector" signal. The ekRawRgba launcher
    # stays on the F path unconditionally (EPP-M4 behaviour) and
    # the ekH264 launcher stays on the V path unconditionally
    # (EPP-M5 behaviour) so existing tests + connections that
    # explicitly negotiated those transports keep their wire shape
    # bit-for-bit. When a static-UI launcher running on ekWebP
    # detects motion the selector still hands off to V (when an
    # H.264 encoder is available) or F as the fallback.
    let selection =
      case cfg.encoder
      of ekRawRgba: tsRawRgba
      of ekH264:    tsH264
      of ekWebP:
        selectTransport(state, curr, cfg, webpAvail)

    case selection
    of tsRawRgba, tsFirstFrame:
      let outFrame = buildOutgoingFrame(curr, state)
      try:
        await sendBinary(client, encodeFrame(outFrame))
      except OSError, IOError:
        return
      # Cache the *current full frame* for the next tick's diff, not
      # the encoded outgoing frame (which may be a diff). Caching the
      # full frame keeps the diff path correct across multiple ticks.
      state.lastSentFrame = some(curr)
    of tsH264:
      # Resize-driven encoder re-init: VTCompressionSession is
      # dimension-bound, so a size change requires a fresh session.
      # The launcher's resizingSink already mutates the frame source's
      # reported (width, height); we detect that delta here and rebuild
      # the encoder before pushing the new-size frame through it.
      if state.h264Encoder != nil and
         (state.h264Encoder.width != curr.width or
          state.h264Encoder.height != curr.height):
        state.h264Encoder = resize(state.h264Encoder,
                                   curr.width, curr.height)
      var emitted = false
      if state.h264Encoder != nil and curr.kind == fkFull:
        try:
          let v = encode(state.h264Encoder, curr.pixels)
          await sendBinary(client, encodeVideoFrame(v))
          emitted = true
        except Defect:
          # Encoder failed (rare — e.g. session lost). Degrade to the
          # raw F-packet path for this frame so the client doesn't see
          # a wire stall, and try the encoder again next tick.
          discard
      if not emitted:
        try:
          await sendBinary(client, encodeFrame(curr))
        except OSError, IOError:
          return
      # No diff cache for the V path — every V packet is self-decodable
      # (GOP=1 keyframes).
      state.lastSentFrame = none(Frame)
    of tsWebP:
      when defined(withCodecWebP):
        # Lazy encoder construction on first W emission. WebP is
        # stateless so the handle is essentially a tiny config bag;
        # the cost of constructing one is bounded (a few hundred ns
        # for the field init + a $PATH lookup the first time).
        if state.webpEncoder == nil:
          let cl =
            if cfg.encoderWebpCompressionLevel > 0:
              cfg.encoderWebpCompressionLevel
            else: DefaultWebPCompressionLevel
          state.webpEncoder = newWebPEncoderHandle(
            curr.width, curr.height, compressionLevel = cl)
        # Resize is O(1) for WebP (no session lifecycle).
        if state.webpEncoder != nil and
           (state.webpEncoder.width != curr.width or
            state.webpEncoder.height != curr.height):
          state.webpEncoder = resize(state.webpEncoder,
                                      curr.width, curr.height)
        var emitted = false
        if state.webpEncoder != nil and curr.kind == fkFull:
          try:
            let w = encode(state.webpEncoder, curr.pixels)
            await sendBinary(client, encodeWebpFrame(w))
            emitted = true
          except IOError, Defect:
            # ffmpeg failure (binary disappeared mid-session, OOM,
            # etc.). Degrade to the F path for this frame so the
            # client doesn't see a wire stall and try W again next
            # tick. The synthesis report's "no frame is ever dropped
            # due to the codec choice" guarantee.
            discard
        if not emitted:
          try:
            await sendBinary(client, encodeFrame(curr))
          except OSError, IOError:
            return
        state.lastSentFrame = none(Frame)
      else:
        # WebP compiled out. Selector should never produce this
        # branch, but be defensive: fall through to F.
        try:
          await sendBinary(client, encodeFrame(curr))
        except OSError, IOError:
          return
        state.lastSentFrame = some(curr)

    # ELT-M8: refresh the per-connection change-score baseline.
    state.prevFrameSample = captureFrameSample(curr)
    inc state.framesSent

    inc sent
    if cfg.maxFrames > 0 and sent >= cfg.maxFrames:
      return
    # EPP-M10 cadence: budget = requested frame interval. Sleep only
    # the residue so the wall-clock period matches the user's --fps
    # request even when the render itself takes most of the cap.
    let elapsedMs = int(inMilliseconds(getMonoTime() - tickStart))
    let residueMs = cfg.frameIntervalMs - elapsedMs
    await sleepAsync(max(1, residueMs))

proc handleInbound(client: AsyncSocket; cfg: BridgeConfig;
                   state: ConnectionState) {.async.} =
  ## Read WS frames from the client; dispatch I packets to the sink,
  ## treat any F packet from the client as a protocol violation.
  var dec = initWsFrameDecoder()
  let fd = AsyncFD(getFd(client))
  while not client.isClosed:
    var buf = newString(4096)
    var n = 0
    try:
      n = await asyncdispatch.recvInto(fd, addr buf[0], buf.len)
    except CatchableError:
      break
    if n <= 0: break
    dec.feed(buf[0 ..< n])
    while true:
      let msg = dec.popMessage()
      if not msg.complete: break
      if msg.opcode == wsOpClose:
        state.closed = true
        try: client.close() except CatchableError: discard
        return
      if msg.opcode == wsOpPing:
        try:
          await client.send(encodeWsFrame(wsOpPong, msg.payload))
        except CatchableError:
          discard
        continue
      if msg.opcode != wsOpBinary and msg.opcode != wsOpText:
        continue
      if msg.payload.len == 0:
        state.closed = true
        await sendClose(client, CloseProtocolError, "empty packet")
        return
      let kind = char(msg.payload[0])
      let raw = stringToBytes(msg.payload)
      case kind
      of 'F':
        # Clients MUST NOT push F packets; RS-M0 § "Error handling".
        state.closed = true
        await sendClose(client, CloseProtocolError, "client F packet")
        return
      of 'I':
        var ipkt: InputPacket
        try:
          ipkt = decodeInput(raw)
        except PacketProtocolError as e:
          state.closed = true
          await sendClose(client, CloseProtocolError, e.msg)
          return
        var ev: InputEvent
        try:
          ev = decodeInputEvent(ipkt)
        except PacketProtocolError as e:
          state.closed = true
          await sendClose(client, CloseProtocolError, e.msg)
          return
        if cfg.inputSink != nil:
          cfg.inputSink.submit(ev)
      of 'M':
        # Meta packets from client are accepted but unused at RS-M1.
        try:
          discard decodeMeta(raw)
        except PacketProtocolError as e:
          state.closed = true
          await sendClose(client, CloseProtocolError, e.msg)
          return
      else:
        state.closed = true
        await sendClose(client, CloseProtocolError,
                        "unknown tag 0x" & toHex(uint8(kind), 2))
        return

proc bridgeOnce(client: AsyncSocket; cfg: BridgeConfig) {.async.} =
  let state = ConnectionState(helloSent: false, closed: false,
                              lastSentFrame: none(Frame),
                              elementTreeKey: "",
                              h264Encoder: cfg.encoderHandle,
                              framesSent: 0,
                              prevFrameSample: @[])
  await sendHello(client, cfg, state)
  # RS-M11: the manifest MUST land before the first F packet so the
  # editor's canvas can hit-test the very first pixel-rendered frame.
  if cfg.elementTree != nil:
    await sendElementTreeIfChanged(client, cfg, state, force = true)
  let outFut = frameLoop(client, cfg, state)
  let inFut = handleInbound(client, cfg, state)
  await outFut or inFut
  state.closed = true
  try: client.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# HTTP entry point
# ---------------------------------------------------------------------------

proc serveStatic(req: Request; staticDir: string) {.async.} =
  var path = req.url.path
  if path == "/" or path == "":
    path = "/index.html"
  if "/.." in path or path.startsWith(".."):
    await req.respond(Http400, "bad path")
    return
  let full = staticDir / path[1 ..^ 1]
  if not fileExists(full):
    await req.respond(Http404, "not found: " & path)
    return
  let body = readFile(full)
  let mime =
    if path.endsWith(".html"): "text/html; charset=utf-8"
    elif path.endsWith(".js"): "application/javascript"
    elif path.endsWith(".css"): "text/css"
    else: "application/octet-stream"
  var headers = newHttpHeaders([("Content-Type", mime)])
  await req.respond(Http200, body, headers)

proc handleWebSocketUpgrade(req: Request; cfg: BridgeConfig) {.async.} =
  let key = readHeader(req.headers, "Sec-WebSocket-Key")
  if key.len == 0:
    await req.respond(Http400, "missing Sec-WebSocket-Key")
    return
  let accept = computeAcceptKey(key.strip())
  let resp = "HTTP/1.1 101 Switching Protocols\r\n" &
             "Upgrade: websocket\r\n" &
             "Connection: Upgrade\r\n" &
             "Sec-WebSocket-Accept: " & accept & "\r\n\r\n"
  await req.client.send(resp)
  await bridgeOnce(req.client, cfg)

proc handler(req: Request; cfg: BridgeConfig) {.async.} =
  let upgrade = readHeader(req.headers, "Upgrade")
  if upgrade.toLowerAscii == "websocket":
    await handleWebSocketUpgrade(req, cfg)
  else:
    await serveStatic(req, cfg.staticDir)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc newServer*(cfg: BridgeConfig): Server =
  Server(cfg: cfg, httpServer: newAsyncHttpServer())

proc serve*(s: Server) {.async.} =
  proc cb(req: Request) {.async.} =
    await handler(req, s.cfg)
  await s.httpServer.serve(s.cfg.port, cb)

proc port*(s: Server): Port = s.cfg.port
