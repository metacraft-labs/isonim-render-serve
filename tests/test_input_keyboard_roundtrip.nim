## EPP-M7 — keyboard I-frame encode / decode round-trip + bridge
## dispatch.
##
## *Claim.* The new ``iekKeyboard`` variant survives the encode →
## decode → re-encode loop byte-identically, the deterministic
## ``encodeKeyboardJson`` helper matches the std/json encoder body,
## and a real WebSocket I packet of ``type:"keyboard"`` reaches a
## ``BufferedInputSink`` via the bridge's dispatch loop.
##
## *How.* The codec tests are pure unit cases. The bridge case stands
## up a real WebSocket server (the same stub-backed
## ``BridgeConfig`` pattern as
## ``test_bridge_input_roundtrip.nim``) and asserts the sink saw the
## decoded event.
##
## Spec: EPP-M7 in
## ``codetracer-specs/Front-Ends/IsoNim/Editor-Preview-Performance.milestones.org``.

import std/[asyncdispatch, asyncnet, json, random, strutils, unittest]

import isonim_render_serve
import ./ws_test_client

proc waitForEvents(sink: BufferedInputSink; count: int;
                   maxPolls: int = 200) =
  var polls = 0
  while sink.events.len < count and polls < maxPolls:
    poll(20)
    inc polls

suite "EPP-M7: keyboard event schema + bridge dispatch":

  test "encodeInputEvent / decodeInputEvent round-trip preserves fields":
    let ev = InputEvent(kind: iekKeyboard,
      keyboardAction: kbaDown,
      keyboardKey: "a", keyboardCode: "KeyA", keyboardText: "a",
      keyboardModifiers: Modifiers(ctrl: false, shift: true,
                                   alt: false, meta: false))
    let ipkt = encodeInputEvent(ev)
    let dec = decodeInputEvent(ipkt)
    check dec.kind == iekKeyboard
    check dec.keyboardAction == kbaDown
    check dec.keyboardKey == "a"
    check dec.keyboardCode == "KeyA"
    check dec.keyboardText == "a"
    check dec.keyboardModifiers.shift == true
    check dec.keyboardModifiers.ctrl == false

  test "I packet wire-level round-trip is byte-identical":
    let ev = InputEvent(kind: iekKeyboard,
      keyboardAction: kbaUp,
      keyboardKey: "Enter", keyboardCode: "Enter", keyboardText: "",
      keyboardModifiers: Modifiers(ctrl: true, meta: true))
    let ipkt = encodeInputEvent(ev)
    let enc1 = encodeInput(ipkt)
    let dec = decodeInput(enc1)
    check dec.json == ipkt.json
    let enc2 = encodeInput(dec)
    check enc1 == enc2
    let parsed = decodeInputEvent(dec)
    check parsed.kind == iekKeyboard
    check parsed.keyboardAction == kbaUp
    check parsed.keyboardKey == "Enter"
    check parsed.keyboardCode == "Enter"
    check parsed.keyboardModifiers.ctrl == true
    check parsed.keyboardModifiers.meta == true

  test "kbaRepeat round-trips through the action enum":
    let ev = InputEvent(kind: iekKeyboard,
      keyboardAction: kbaRepeat,
      keyboardKey: "ArrowLeft", keyboardCode: "ArrowLeft",
      keyboardText: "",
      keyboardModifiers: Modifiers())
    let ipkt = encodeInputEvent(ev)
    let dec = decodeInputEvent(ipkt)
    check dec.keyboardAction == kbaRepeat
    # And surface in the JSON as the string "repeat".
    let node = parseJson(ipkt.json)
    check node["action"].getStr == "repeat"

  test "encodeKeyboardJson is byte-stable and matches std/json shape":
    let body = encodeKeyboardJson(kbaDown, "h", "KeyH", "h",
                                  Modifiers(shift: false))
    # Field order locked: type, action, key, code, text, modifiers.
    let expected = "{\"type\":\"keyboard\",\"action\":\"down\"," &
                   "\"key\":\"h\",\"code\":\"KeyH\",\"text\":\"h\"," &
                   "\"modifiers\":{\"ctrl\":false,\"shift\":false," &
                   "\"alt\":false,\"meta\":false}}"
    check body == expected
    # And parses to the same InputEvent shape as encodeInputEvent.
    let ipkt = InputPacket(json: body)
    let dec = decodeInputEvent(ipkt)
    check dec.kind == iekKeyboard
    check dec.keyboardAction == kbaDown
    check dec.keyboardKey == "h"
    check dec.keyboardCode == "KeyH"
    check dec.keyboardText == "h"

  test "unknown keyboard action raises PacketProtocolError":
    let bogus = InputPacket(
      json: "{\"type\":\"keyboard\",\"action\":\"sneeze\"}")
    expect PacketProtocolError:
      discard decodeInputEvent(bogus)

  test "missing action raises PacketProtocolError":
    let bogus = InputPacket(
      json: "{\"type\":\"keyboard\",\"key\":\"a\"}")
    expect PacketProtocolError:
      discard decodeInputEvent(bogus)

  test "BufferedInputSink.submit logs a keyboard entry":
    let sink = newBufferedInputSink()
    sink.submit(InputEvent(kind: iekKeyboard,
      keyboardAction: kbaDown,
      keyboardKey: "z", keyboardCode: "KeyZ", keyboardText: "z",
      keyboardModifiers: Modifiers()))
    check sink.events.len == 1
    check sink.events[0].kind == iekKeyboard
    check sink.joinLog().contains "keyboard down KeyZ z"

  test "bridge dispatches client keyboard I packet to InputSink":
    when defined(windows):
      skip()
    else:
      randomize()
      let port = pickPort()
      let sink = newBufferedInputSink()
      var cfg = makeStubConfigWithSink(port, sink, fps = 50,
                                       maxFrames = 0)
      discard startServer(cfg)

      proc flow() {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let hello = await recvOneMessage(sock, state)
        doAssert hello.complete
        # Build a keyboard I packet via the canonical encoder so the
        # wire bytes are identical to what the editor's JS shim
        # emits.
        let ev = InputEvent(kind: iekKeyboard,
          keyboardAction: kbaDown,
          keyboardKey: "h", keyboardCode: "KeyH", keyboardText: "h",
          keyboardModifiers: Modifiers())
        let pkt = encodeInput(encodeInputEvent(ev))
        await sendBinaryFrame(sock, bytesToString(pkt))
        sock.close()

      waitFor flow()
      waitForEvents(sink, 1)
      check sink.events.len >= 1
      let got = sink.events[0]
      check got.kind == iekKeyboard
      check got.keyboardAction == kbaDown
      check got.keyboardKey == "h"
      check got.keyboardCode == "KeyH"
      check got.keyboardText == "h"
      for i in 0 .. 5: poll(20)

  test "bridge hello capabilities advertise the keyboard inputKind":
    let hello = buildHelloJson("stub", 320, 240)
    let node = parseJson(hello)
    let kinds = node["capabilities"]["inputKinds"]
    var found = false
    for k in kinds:
      if k.getStr == "keyboard":
        found = true
    check found

  test "newDispatchingLauncherSink routes by event kind":
    # Resize calls go to the resize handler; mouse / keyboard go to
    # the renderer-side input sink.
    var resizes: seq[(int, int)] = @[]
    let onResize = proc(w, h: int) {.gcsafe.} =
      {.cast(gcsafe).}:
        resizes.add (w, h)
    let inner = newBufferedInputSink()
    let composite = newDispatchingLauncherSink(onResize, inner.toAny())

    composite.submit(InputEvent(kind: iekResize, width: 320, height: 240))
    composite.submit(InputEvent(kind: iekMouse, mouseAction: maClick,
                                button: 0, mouseX: 10, mouseY: 20,
                                mouseModifiers: Modifiers()))
    composite.submit(InputEvent(kind: iekKeyboard,
      keyboardAction: kbaDown,
      keyboardKey: "a", keyboardCode: "KeyA", keyboardText: "a",
      keyboardModifiers: Modifiers()))

    check resizes == @[(320, 240)]
    check inner.events.len == 2
    check inner.events[0].kind == iekMouse
    check inner.events[1].kind == iekKeyboard
