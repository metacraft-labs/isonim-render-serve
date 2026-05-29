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
            httpcore, json, nativesockets, options, os, strutils]
import std/sha1 as sha1Mod

import ./packet
import ./packet_video
import ./ws_frame
import ./event_dispatch
import ./frame_source
import ./diff_region
import ./adapters/h264_videotoolbox_encoder

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
                     codecId: string = ""): string =
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
  case encoder
  of ekH264:
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
  let body = buildHelloJson(cfg.backend,
                            cfg.frameSource.width,
                            cfg.frameSource.height,
                            elementTree = cfg.elementTree != nil,
                            capturePath = cfg.capturePath,
                            encoder = cfg.encoder,
                            codecId = codecId)
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
  var sent = 0
  while not state.closed and not client.isClosed:
    if not state.helloSent:
      await sleepAsync(5)
      continue
    # RS-M11: re-check the element-tree manifest each tick BEFORE
    # rendering the frame. If the (id, bounds) set has changed we
    # emit a fresh manifest; otherwise the cadence rule skips the
    # M packet so idle frame streams do not churn manifests.
    if cfg.elementTree != nil:
      await sendElementTreeIfChanged(client, cfg, state)
    let curr = cfg.frameSource.renderFrame()

    case cfg.encoder
    of ekRawRgba:
      let outFrame = buildOutgoingFrame(curr, state)
      try:
        await sendBinary(client, encodeFrame(outFrame))
      except OSError, IOError:
        return
      # Cache the *current full frame* for the next tick's diff, not
      # the encoded outgoing frame (which may be a diff). Caching the
      # full frame keeps the diff path correct across multiple ticks.
      state.lastSentFrame = some(curr)
    of ekH264:
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

    inc sent
    if cfg.maxFrames > 0 and sent >= cfg.maxFrames:
      return
    await sleepAsync(cfg.frameIntervalMs)

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
                              h264Encoder: cfg.encoderHandle)
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
