## test_bridge_input_roundtrip — client sends an I packet over a
## real WebSocket; the bridge decodes it and submits a matching
## `InputEvent` to the configured `BufferedInputSink`. The sink is
## inspected from the test to assert byte parity at the semantic
## level.

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim_render_serve
import ./ws_test_client

proc waitForEvents(sink: BufferedInputSink; count: int;
                   maxPolls: int = 200) =
  var polls = 0
  while sink.events.len < count and polls < maxPolls:
    poll(20)
    inc polls

suite "isonim-render-serve: I packet round-trip":

  test "client mouse click reaches the InputSink":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      var cfg = makeStubConfig(port, fps = 50, maxFrames = 0)
      let sink = cfg.inputSink
      discard startServer(cfg)

      proc flow() {.async.} =
        let sock = await connectWs(port)
        # Wait for hello so we know the bridge is alive.
        let state = newWsClientState()
        let hello = await recvOneMessage(sock, state)
        doAssert hello.complete
        # Construct a mouse click I packet via the encoder.
        let ev = InputEvent(kind: iekMouse, mouseAction: maClick,
                            button: 0, mouseX: 42, mouseY: 84,
                            mouseModifiers: Modifiers(shift: true))
        let ipkt = encodeInputEvent(ev)
        let pkt = encodeInput(ipkt)
        await sendBinaryFrame(sock, bytesToString(pkt))
        # Yield long enough for the bridge to read + dispatch.
        sock.close()

      waitFor flow()
      waitForEvents(sink, 1)
      check sink.events.len >= 1
      let got = sink.events[0]
      check got.kind == iekMouse
      check got.mouseAction == maClick
      check got.button == 0
      check got.mouseX == 42
      check got.mouseY == 84
      check got.mouseModifiers.shift == true
      for i in 0 .. 5: poll(20)

  test "multiple I packets arrive in order":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      var cfg = makeStubConfig(port, fps = 50)
      let sink = cfg.inputSink
      discard startServer(cfg)

      let events = @[
        InputEvent(kind: iekKey, keyAction: kaDown, key: "a",
                   code: "KeyA", keyModifiers: Modifiers(),
                   repeat: false),
        InputEvent(kind: iekKey, keyAction: kaUp, key: "a",
                   code: "KeyA", keyModifiers: Modifiers(),
                   repeat: false),
        InputEvent(kind: iekScroll, scrollX: 5, scrollY: 5,
                   deltaX: 0, deltaY: 120,
                   scrollModifiers: Modifiers()),
        InputEvent(kind: iekResize, width: 1920, height: 1080),
        InputEvent(kind: iekFocus, focused: false),
      ]

      proc flow() {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let hello = await recvOneMessage(sock, state)
        doAssert hello.complete
        for ev in events:
          let pkt = encodeInput(encodeInputEvent(ev))
          await sendBinaryFrame(sock, bytesToString(pkt))
        # Give the bridge a beat to drain.
        for i in 0 .. 10: await sleepAsync(20)
        sock.close()

      waitFor flow()
      waitForEvents(sink, events.len)
      check sink.events.len >= events.len
      check sink.events[0].kind == iekKey
      check sink.events[0].keyAction == kaDown
      check sink.events[1].keyAction == kaUp
      check sink.events[2].kind == iekScroll
      check sink.events[2].deltaY == 120
      check sink.events[3].kind == iekResize
      check sink.events[3].width == 1920
      check sink.events[3].height == 1080
      check sink.events[4].kind == iekFocus
      check sink.events[4].focused == false
      for i in 0 .. 5: poll(20)
