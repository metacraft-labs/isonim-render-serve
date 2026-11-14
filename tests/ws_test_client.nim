## ws_test_client — shared helpers for the bridge integration tests.
## Spins up a server on an ephemeral port and provides a hand-rolled
## WebSocket client built on `asyncnet`.
##
## Every test reaches the bridge through `connectWs`, and reads from the
## socket through the decoder `clientStateFor(sock)` returns. The two go
## together because of how the bridge opens a connection: it writes the
## `101 Switching Protocols` response and then, at once, the `hello` M
## packet (`bridge.handleWebSocketUpgrade` → `bridgeOnce`). Both often
## arrive in the same `recv` as the response headers, and on a loaded or
## slow host they nearly always do. The bytes after the header terminator
## are therefore the start of the frame stream, not part of the response.
## `connectWs` keeps them and feeds them to the connection's decoder
## before the test reads anything else, so the `hello` packet (and any
## frame behind it) is never lost and the decoder never starts parsing in
## the middle of a frame. `tests/test_ws_test_client_keeps_early_bytes.nim`
## checks this against a server that sends the response and two frames in
## one write.
##
## The opening handshake is RFC 6455 §4.1 (client requirements) and §4.2.2
## (the server's response):
## https://www.rfc-editor.org/rfc/rfc6455#section-4

import std/[asyncdispatch, asyncnet, base64, nativesockets, net,
            random, strutils, tables]

import isonim_render_serve

proc pickPort*(): int =
  ## Best-effort ephemeral-port selection. Bind a temporary socket
  ## to port 0; read the kernel-assigned port back; close. The
  ## bind→close→listen window is short enough for the tests.
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc randMaskKey*(): array[4, byte] =
  for i in 0 ..< 4: result[i] = byte(rand(0 .. 255))

proc recvSome*(fd: AsyncFD; size: int): Future[string] {.async.} =
  var buf = newString(size)
  let n = await asyncdispatch.recvInto(fd, addr buf[0], size)
  if n <= 0: return ""
  buf.setLen(n)
  result = buf

const HeaderTerminator = "\r\n\r\n"

proc handshake*(s: AsyncSocket; host: string;
                port: int): Future[string] {.async.} =
  ## Send the upgrade request on the connected socket `s`, wait for the
  ## complete response header and require `101`. Returns every byte the
  ## server sent after the header terminator: the beginning of the frame
  ## stream, possibly empty, possibly ending inside a frame. The caller
  ## must feed it to its frame decoder before reading from the socket;
  ## `connectWs` does that.
  let key = encode("0123456789abcdef0123")
  let req = "GET / HTTP/1.1\r\n" &
            "Host: " & host & ":" & $port & "\r\n" &
            "Upgrade: websocket\r\n" &
            "Connection: Upgrade\r\n" &
            "Sec-WebSocket-Key: " & key & "\r\n" &
            "Sec-WebSocket-Version: 13\r\n\r\n"
  await s.send(req)
  let fd = AsyncFD(getFd(s))
  var resp = ""
  while not resp.contains(HeaderTerminator):
    let chunk = await recvSome(fd, 4096)
    if chunk.len == 0: break
    resp.add(chunk)
  let terminatorAt = resp.find(HeaderTerminator)
  doAssert terminatorAt >= 0 and resp.startsWith("HTTP/1.1 101"),
    "handshake failed: " & resp
  result = resp[terminatorAt + HeaderTerminator.len .. ^1]

proc sendBinaryFrame*(sock: AsyncSocket; payload: string) {.async.} =
  let mask = randMaskKey()
  let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
  await sock.send(frame)

type
  WsClientState* = ref object
    dec*: WsFrameDecoder

proc newWsClientState(): WsClientState =
  WsClientState(dec: initWsFrameDecoder())

# A recv() on the socket can return MORE bytes than the frames a single
# drain consumes (the bridge streams 256×256 F frames of ~256 KB while
# the client reads in 16 KiB chunks), and the handshake's last recv can
# carry the first frames too (see the module header). Those surplus bytes
# live in the `WsFrameDecoder.buf` of the connection's `WsClientState`. A
# decoder created anywhere else would start without them: it would miss
# the `hello` packet, or start parsing mid-frame and mis-read payload
# bytes as a frame header (whose 4-bit opcode has no `WsOpcode`
# representant → RangeDefect). So the decoder state is created by
# `connectWs`, keyed on the socket, and lives for the connection's
# lifetime; `newWsClientState` is private to keep it that way.
var perSocketState = initTable[int, WsClientState]()

proc connectWs*(port: int): Future[AsyncSocket] {.async.} =
  ## Connect to `127.0.0.1:port` and complete the opening handshake. The
  ## connection's decoder (`clientStateFor`) starts out holding the frame
  ## bytes that arrived together with the `101` response.
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  let early = await handshake(sock, "127.0.0.1", port)
  let state = newWsClientState()
  state.dec.feed(early)
  # A fresh entry REPLACES whatever an earlier, closed socket with the
  # same file descriptor left behind: the kernel reuses descriptor
  # numbers, and a stale decoder would hand that connection's leftover
  # bytes to this one.
  perSocketState[int(getFd(sock))] = state
  result = sock

proc clientStateFor*(sock: AsyncSocket): WsClientState =
  ## Return the `WsClientState` bound to `sock` by `connectWs`. Reusing it
  ## across successive `recvOneMessage` / drain calls preserves the
  ## decoder's byte buffer, so no frame is dropped or split at a drain
  ## boundary. Keyed on the socket's raw file descriptor (an
  ## `AsyncSocket` is a ref with no `hash`).
  result = perSocketState.getOrDefault(int(getFd(sock)))
  doAssert not result.isNil,
    "no decoder for this socket: open it with connectWs"

proc recvOneMessage*(sock: AsyncSocket;
                     state: WsClientState;
                     timeoutPolls: int = 200): Future[WsMessage] {.async.} =
  let fd = AsyncFD(getFd(sock))
  var msg = state.dec.popMessage()
  if msg.complete: return msg
  var attempts = 0
  while not msg.complete and attempts < timeoutPolls:
    let chunk = await recvSome(fd, 16384)
    if chunk.len == 0: break
    state.dec.feed(chunk)
    msg = state.dec.popMessage()
    inc attempts
  result = msg

proc startServer*(cfg: BridgeConfig): Server =
  ## Spawn the server task on the dispatcher; return the server
  ## handle so the caller can shut it down.
  let server = newServer(cfg)
  proc task() {.async.} =
    try: await server.serve() except CatchableError: discard
  asyncCheck task()
  # Drive the dispatcher long enough for the listen socket to bind.
  for i in 0 .. 5: poll(50)
  server

proc makeStubConfig*(port: int; backend = "stub"; fps = 20;
                     maxFrames = 0): BridgeConfig =
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: backend,
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: newBufferedInputSink().toAny(),
    frameSource: newStubFrameSource(256, 256).toAny())

proc makeStubConfigWithSink*(port: int; sink: BufferedInputSink;
                             backend = "stub"; fps = 20;
                             maxFrames = 0): BridgeConfig =
  ## Variant of `makeStubConfig` that lets the test keep a typed
  ## handle on the underlying `BufferedInputSink` so it can assert
  ## the captured event log directly (the broadened
  ## `BridgeConfig.inputSink` field hides the concrete sink behind a
  ## polymorphic wrapper).
  BridgeConfig(
    port: Port(port),
    staticDir: ".",
    backend: backend,
    frameIntervalMs: max(1, 1000 div fps),
    maxFrames: maxFrames,
    inputSink: sink.toAny(),
    frameSource: newStubFrameSource(256, 256).toAny())
