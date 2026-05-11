## ws_test_client — shared helpers for the bridge integration tests.
## Spins up a server on an ephemeral port and provides a hand-rolled
## WebSocket client built on `asyncnet`.

import std/[asyncdispatch, asyncnet, base64, nativesockets, net,
            random, strutils]

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

proc handshake*(s: AsyncSocket; host: string; port: int) {.async.} =
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
  while not resp.contains("\r\n\r\n"):
    let chunk = await recvSome(fd, 4096)
    if chunk.len == 0: break
    resp.add(chunk)
  doAssert resp.startsWith("HTTP/1.1 101"),
    "handshake failed: " & resp

proc connectWs*(port: int): Future[AsyncSocket] {.async.} =
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  await handshake(sock, "127.0.0.1", port)
  result = sock

proc sendBinaryFrame*(sock: AsyncSocket; payload: string) {.async.} =
  let mask = randMaskKey()
  let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
  await sock.send(frame)

type
  WsClientState* = ref object
    dec*: WsFrameDecoder

proc newWsClientState*(): WsClientState =
  WsClientState(dec: initWsFrameDecoder())

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
    inputSink: newBufferedInputSink(),
    frameSource: newStubFrameSource(256, 256))
