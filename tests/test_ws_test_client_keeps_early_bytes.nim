## test_ws_test_client_keeps_early_bytes — the shared test WebSocket
## client (`ws_test_client.connectWs`) must keep the frame bytes that
## arrive in the same read as the `101 Switching Protocols` response.
##
## The bridge writes its `hello` M packet right after the `101` response,
## so the two regularly share a TCP segment. A client that read "until
## `\r\n\r\n`" and then dropped the whole buffer lost the `hello` (the
## `sawHello` assertion of `test_bridge_diff_streaming` failed on a macOS
## runner this way), or cut a frame in half so that its decoder parsed
## payload bytes as a frame header.
##
## WHY A SCRIPTED SERVER INSTEAD OF THE BRIDGE. Whether the bridge's
## `hello` shares a read with the response depends on scheduling, which
## is exactly why the defect was intermittent: a test against the real
## bridge passes or fails by timing. This test needs the byte layout that
## triggers the defect on every run, so a minimal server sends the
## response and the frames in one `send` (and, in the second case, cuts a
## frame across two sends). It replaces only the server's timing; the
## client code under test is the real helper every bridge test uses, and
## the frames are built with the product's own `encodeWsBinaryFrame` and
## `encodeMeta`. The bridge's real behaviour stays covered by the bridge
## tests themselves, which all go through `connectWs`.

import std/[asyncdispatch, asyncnet, net, strutils, unittest]

import isonim_render_serve
import ./ws_test_client

const SwitchingProtocols = "HTTP/1.1 101 Switching Protocols\r\n" &
                           "Upgrade: websocket\r\n" &
                           "Connection: Upgrade\r\n" &
                           "Sec-WebSocket-Accept: unchecked-by-the-client\r\n" &
                           "\r\n"

proc metaFrame(json: string): string =
  ## One server→client binary WebSocket frame carrying an M packet.
  encodeWsBinaryFrame(bytesToString(encodeMeta(MetaPacket(json: json))))

proc serveScripted(listener: AsyncSocket;
                   writes: seq[string]) {.async.} =
  ## Accept one connection, read the upgrade request, then perform
  ## `writes` as separate `send` calls (with a dispatcher turn between
  ## them so they are not merged on the sender side).
  let client = await listener.accept()
  # `recvLine` returns "\r\n" for the empty line that ends the request
  # header, and "" when the peer closed.
  while true:
    let line = await client.recvLine()
    if line.len == 0 or line == "\r\n": break
  for i, w in writes:
    if i > 0: await sleepAsync(20)
    await client.send(w)
  # Hold the connection open until the client has read everything.
  await sleepAsync(200)
  client.close()

proc readTwoPackets(writes: seq[string]): Future[seq[string]] {.async.} =
  ## Start the scripted server, connect with `connectWs` and return the
  ## JSON of the first two M packets the client decodes.
  let port = pickPort()
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port), "127.0.0.1")
  listener.listen()
  let serverFut = serveScripted(listener, writes)
  let sock = await connectWs(port)
  # The server's first write is a single loopback `send` of the response
  # together with the frames, so the handshake's read receives them in
  # one buffer on every run.
  let state = clientStateFor(sock)
  result = @[]
  for i in 0 ..< 2:
    let msg = await recvOneMessage(sock, state, timeoutPolls = 20)
    if not msg.complete: break
    check msg.opcode == wsOpBinary
    let raw = stringToBytes(msg.payload)
    check peekPacketKind(raw) == pkMeta
    result.add decodeMeta(raw).json
  sock.close()
  await serverFut
  listener.close()

# Skipped on Windows like every bridge test that uses this client: the
# client reads through `asyncdispatch.recvInto` on the socket's raw handle,
# a path those tests have never exercised on Windows.
suite "ws_test_client: frame bytes that arrive with the 101 response":

  test "response and two whole frames in one write: both frames decoded":
    when defined(windows):
      skip()
    else:
      let hello = """{"type":"hello"}"""
      let second = """{"type":"second"}"""
      let packets = waitFor readTwoPackets(@[
        SwitchingProtocols & metaFrame(hello) & metaFrame(second)])
      check packets == @[hello, second]

  test "early bytes end inside a frame: the decoder resumes it intact":
    when defined(windows):
      skip()
    else:
      let hello = """{"type":"hello"}"""
      # Long enough that the cut below lands in the payload.
      let second = """{"type":"second","pad":"""" & repeat('x', 300) & "\"}"
      let secondFrame = metaFrame(second)
      let cut = secondFrame.len div 2
      let packets = waitFor readTwoPackets(@[
        SwitchingProtocols & metaFrame(hello) & secondFrame[0 ..< cut],
        secondFrame[cut .. ^1]])
      check packets == @[hello, second]
