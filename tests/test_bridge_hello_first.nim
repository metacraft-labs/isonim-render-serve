## test_bridge_hello_first — a fresh WS connection MUST receive an
## `M` hello packet as its first message, with `protocolVersion: 1`,
## the configured backend identifier, the capability bag, and the
## frame source's initial size.

import std/[asyncdispatch, asyncnet, json, random, unittest]

import isonim_render_serve
import ./ws_test_client

suite "isonim-render-serve: hello protocol":

  test "first server message is M hello with v1 + backend + initialSize":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeStubConfig(port, backend = "stub")
      discard startServer(cfg)

      proc flow(): Future[MetaPacket] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let msg = await recvOneMessage(sock, state)
        sock.close()
        doAssert msg.complete, "no message received"
        doAssert msg.opcode == wsOpBinary,
          "first frame should be binary, got " & $msg.opcode
        let raw = stringToBytes(msg.payload)
        check peekPacketKind(raw) == pkMeta
        return decodeMeta(raw)

      let meta = waitFor flow()
      let node = parseJson(meta.json)
      check node["type"].getStr == "hello"
      check node["protocolVersion"].getInt == 1
      check node["backend"].getStr == "stub"
      check node["initialSize"]["width"].getInt == 256
      check node["initialSize"]["height"].getInt == 256
      let caps = node["capabilities"]
      check caps["diffRegions"].getBool == false
      check caps["screenshot"].getBool == false
      check caps["inputKinds"].kind == JArray
      check caps["inputKinds"].len == 5
      for i in 0 .. 5: poll(20)

  test "hello backend identifier is configurable":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let cfg = makeStubConfig(port, backend = "gpui-headless")
      discard startServer(cfg)
      proc flow(): Future[string] {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let msg = await recvOneMessage(sock, state)
        sock.close()
        doAssert msg.complete
        let m = decodeMeta(stringToBytes(msg.payload))
        let node = parseJson(m.json)
        return node["backend"].getStr
      let backend = waitFor flow()
      check backend == "gpui-headless"
      for i in 0 .. 5: poll(20)
