## test_protocol_violation_close — assert RS-M0 § "Error handling":
##
##   * Client F packets are illegal (the server is the sole F-packet
##     producer); receiving one MUST close the WS with code 1002.
##   * Reserved flag bits in an F packet MUST close with 1002 (this
##     test exercises the path via a synthetic violation injection,
##     i.e. the inbound-handler's PacketProtocolError surface — we
##     send a malformed I packet so the decode-error close path
##     fires).

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim_render_serve
import ./ws_test_client

proc readUntilClose(sock: AsyncSocket): Future[uint16] {.async.} =
  ## Read messages until a Close frame arrives; return its status
  ## code. Returns 0 if the connection died without one.
  let state = newWsClientState()
  for i in 0 ..< 50:
    let msg = await recvOneMessage(sock, state)
    if not msg.complete: return 0
    if msg.opcode == wsOpClose:
      return decodeCloseStatus(msg.payload)
  return 0

suite "isonim-render-serve: protocol-violation close":

  test "client F packet → WS close code 1002":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeStubConfig(port, fps = 50)
      discard startServer(cfg)

      proc flow(): Future[uint16] {.async.} =
        let sock = await connectWs(port)
        # Build a *valid* F packet — the bridge rejects it not for
        # being malformed but for coming from the client direction.
        let f = Frame(kind: fkFull,
                      flags: FrameFlags(isDiff: false, isVideo: false),
                      width: 2, height: 2,
                      pixels: newSeq[byte](16))
        let pkt = encodeFrame(f)
        await sendBinaryFrame(sock, bytesToString(pkt))
        let code = await readUntilClose(sock)
        sock.close()
        return code

      let code = waitFor flow()
      check code == 1002'u16
      for i in 0 .. 5: poll(20)

  test "malformed I packet (bad JSON) → WS close code 1002":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeStubConfig(port, fps = 50)
      discard startServer(cfg)

      proc flow(): Future[uint16] {.async.} =
        let sock = await connectWs(port)
        # Build an I packet whose JSON body is unparseable.
        let bogus = InputPacket(json: "{not json")
        let pkt = encodeInput(bogus)
        await sendBinaryFrame(sock, bytesToString(pkt))
        let code = await readUntilClose(sock)
        sock.close()
        return code

      let code = waitFor flow()
      check code == 1002'u16
      for i in 0 .. 5: poll(20)

  test "unknown packet tag → WS close code 1002":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeStubConfig(port, fps = 50)
      discard startServer(cfg)

      proc flow(): Future[uint16] {.async.} =
        let sock = await connectWs(port)
        # 'X' is not a valid packet tag.
        let bogus = @[byte('X'), 0, 0, 0, 0]
        await sendBinaryFrame(sock, bytesToString(bogus))
        let code = await readUntilClose(sock)
        sock.close()
        return code

      let code = waitFor flow()
      check code == 1002'u16
      for i in 0 .. 5: poll(20)
