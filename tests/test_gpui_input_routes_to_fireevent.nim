## RS-M2 — mouse-click I packet sent over a real WebSocket reaches
## the GPUI input adapter, which dispatches a real `fireEvent` call
## to the task_app demo's "Add" button. The button's click handler
## reads `vm.inputText.val` and pushes a task via the canonical VM.
## The assertion checks the VM state, not the rendered tree, so it
## stays sharp regardless of rasterizer changes.
##
## Real stack:
##   * Bridge with a `GpuiFrameSource` over the task_app demo.
##   * Bridge with a `GpuiInputSink` whose `HitTester` always returns
##     the demo's add button.
##   * Real `fireEvent` -> real shim event dispatcher -> real Nim
##     closure that mutates the canonical `TaskAppVM`.

import std/[asyncdispatch, asyncnet, random, unittest]

import isonim/core/signals
import isonim_gpui/renderer
import isonim_gpui/bindings

import task_app/main_gpui as gpui_app

import isonim_render_serve
import isonim_render_serve/adapters/gpui_adapter
import isonim_render_serve/adapters/gpui_input_adapter
import ./ws_test_client

suite "RS-M2: GPUI input adapter routes WS clicks to fireEvent":

  test "WS mouse-click I packet adds a task via the demo's Add button":
    when defined(windows):
      skip()
    else:
      randomize()

      # Build the canonical EX-M3 GPUI task_app demo. The leaves
      # table holds the `addBtn` handle the input adapter will route
      # clicks to.
      let vm = newTaskAppVM()
      let root = gpui_app.runTaskApp(vm)
      let s = gpui_app.leavesFor(vm)
      doAssert s.addBtn != nil

      # Seed the VM's input text the way the EX-M3 e2e test does
      # (the GPUI shim has no real input-text primitive). The
      # add-button's click handler reads `vm.inputText.val`.
      vm.setInputText("via-ws")

      # The hit-test always returns the addBtn — every click lands
      # on the same target, which is enough to prove routing.
      let target = s.addBtn
      let hitTest = proc(x, y: int): GpuiElement {.gcsafe.} =
                      {.cast(gcsafe).}: target
      let inputSink = newGpuiInputSink(hitTest)

      let r = GpuiRenderer()
      let frameSource = newGpuiFrameSource(r, root,
                                           width = 100, height = 100)

      let port = pickPort()
      let cfg = BridgeConfig(
        port: Port(port),
        staticDir: ".",
        backend: "gpui",
        frameIntervalMs: 50,
        maxFrames: 0,
        inputSink: inputSink.toAny(),
        frameSource: frameSource.toAny())
      discard startServer(cfg)

      proc flow() {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        # Wait for hello so we know the bridge is alive.
        let hello = await recvOneMessage(sock, state)
        doAssert hello.complete
        # Build a synthetic mouse-click I packet and send it.
        let ev = InputEvent(kind: iekMouse, mouseAction: maClick,
                            button: 0, mouseX: 10, mouseY: 10,
                            mouseModifiers: Modifiers())
        let pkt = encodeInput(encodeInputEvent(ev))
        await sendBinaryFrame(sock, bytesToString(pkt))
        # Drain a few frames so the bridge has time to process the
        # inbound packet.
        for _ in 0 .. 10: await sleepAsync(20)
        sock.close()

      waitFor flow()

      # The click hit-tested to the addBtn, whose handler reads
      # `vm.inputText.val` ("via-ws") and pushed a task.
      check vm.tasks.val.len == 1
      check vm.tasks.val[0].name == "via-ws"
      # The sink also logged the event.
      check inputSink.events.len >= 1
      check inputSink.events[0].kind == iekMouse
      check inputSink.events[0].mouseAction == maClick

      for i in 0 .. 5: poll(20)
      gpui_app.resetGpuiLeaves()

  test "keyboard event is logged but does not crash the bridge":
    when defined(windows):
      skip()
    else:
      randomize()

      let vm = newTaskAppVM()
      let root = gpui_app.runTaskApp(vm)
      let r = GpuiRenderer()
      let frameSource = newGpuiFrameSource(r, root,
                                           width = 80, height = 60)
      let hitTest = proc(x, y: int): GpuiElement {.gcsafe.} =
                      {.cast(gcsafe).}: nil
      let inputSink = newGpuiInputSink(hitTest)

      let port = pickPort()
      let cfg = BridgeConfig(
        port: Port(port),
        staticDir: ".",
        backend: "gpui",
        frameIntervalMs: 50,
        maxFrames: 0,
        inputSink: inputSink.toAny(),
        frameSource: frameSource.toAny())
      discard startServer(cfg)

      proc flow() {.async.} =
        let sock = await connectWs(port)
        let state = newWsClientState()
        let hello = await recvOneMessage(sock, state)
        doAssert hello.complete
        let ev = InputEvent(kind: iekKey, keyAction: kaDown,
                            key: "a", code: "KeyA",
                            keyModifiers: Modifiers(), repeat: false)
        let pkt = encodeInput(encodeInputEvent(ev))
        await sendBinaryFrame(sock, bytesToString(pkt))
        for _ in 0 .. 10: await sleepAsync(20)
        sock.close()

      waitFor flow()
      check inputSink.events.len >= 1
      check inputSink.events[0].kind == iekKey
      # VM remained untouched (no add-task triggered).
      check vm.tasks.val.len == 0
      for i in 0 .. 5: poll(20)
      gpui_app.resetGpuiLeaves()
