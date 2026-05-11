## RS-M5: Cocoa input adapter (Linux-side scaffold; macOS host completes).
##
## Implements an `InputSink` that translates incoming `InputEvent`s into
## `CocoaRenderer.fireEvent` calls. Mirrors the RS-M2 (GPUI) and RS-M4
## (Freya) input-adapter shape so the bridge's polymorphic
## `AnyInputSink` consumes any of the three back-ends identically.
##
## ## Status — partial-linux
##
## On Linux the type machinery (`HitTester`, `CocoaInputSink`,
## `submit`, `toAny`) compiles, but the `fireEvent` call on the hit-
## tested target view is gated `when defined(macosx)` because
## `CocoaRenderer.fireEvent` dispatches through the AppKit target/
## action runtime which the Linux host can't link against. On Linux the
## click path falls through to the buffered log so unit tests can still
## assert routing behaviour.
##
## ## Mapping
##
## RS-M0's `I` packet schema covers mouse / keyboard / scroll / resize /
## focus; the Cocoa renderer exposes the same `fireEvent` dispatch
## primitive as the GPUI/Freya shims:
##
##   * **mouse click** → resolve to a node via the hit-test callback
##     supplied by the composition root, then `r.fireEvent(node,
##     "click")`. The renderer dispatches through the registered
##     target/action callback (see `renderer.fireEvent` /
##     `registerCallback` / `newCallbackTarget`) so the Nim closure
##     that the leaf attached for that node runs in-process.
##   * **mouse move / down / up** → buffered to the structured log.
##     `CocoaRenderer` has no mousemove dispatch primitive yet (same
##     gap as GPUI/Freya).
##   * **keyboard** → logged to stderr (no Cocoa keyboard surface
##     beyond NSTextField's editing actions, which are wired via
##     AppKit notifications, not the `fireEvent` C API). The EX-M5
##     task_app demo follows the GPUI/Freya pattern: `vm.setInputText`
##     + click on Add, both routed through this sink.
##   * **scroll** / **focus** / **resize** → logged; the bridge's own
##     resize plumbing remains the M-packet path.
##
## ## Hand-off — what the macOS M1 engineer must do
##
## See `isonim-render-stream.status.org` § RS-M5 for the canonical
## checklist. For this module specifically:
##
##   1. Verify the `r.fireEvent(target, "click")` call dispatches
##      through to the leaf-registered Nim callback on a real AppKit
##      host. Cocoa's button target/action wiring is sometimes
##      sensitive to the `NSButton.target` retain cycle — confirm the
##      callback runs synchronously inside `fireEvent` (as it does on
##      GPUI/Freya). If `fireEvent` is asynchronous on Cocoa, surface
##      a synchronous mode for tests.
##   2. The hit-tester callback is composition-root-supplied (same as
##      GPUI/Freya). For the task_app integration test, point all
##      clicks at the demo's Add-button leaf — the test asserts
##      `vm.tasks.value.len` increments per click.

import std/strutils

import isonim_cocoa/renderer

import ../event_dispatch

type
  HitTester* = proc(x, y: int): CocoaElement {.closure, gcsafe.}
    ## Maps a click coordinate to the Cocoa node that should receive
    ## the synthetic event. The composition root (or the bridge
    ## tests) supplies this callback so the adapter stays
    ## demo-agnostic.

  CocoaInputSink* = ref object
    ## `InputSink` impl. Holds a hit-test callback plus a structured
    ## log mirroring `BufferedInputSink`'s `log` for assertion-driven
    ## tests. Carries the `CocoaRenderer` value (needed because the
    ## Cocoa `fireEvent` takes the renderer as its first arg, unlike
    ## GPUI/Freya whose shim free-procs don't).
    renderer*: CocoaRenderer
    hitTest*: HitTester
    log*: seq[string]
    events*: seq[InputEvent]

proc newCocoaInputSink*(renderer: CocoaRenderer;
                        hitTest: HitTester): CocoaInputSink =
  CocoaInputSink(renderer: renderer, hitTest: hitTest,
                 log: @[], events: @[])

proc actionToStr(a: MouseAction): string =
  case a
  of maDown: "down"
  of maUp: "up"
  of maMove: "move"
  of maClick: "click"

proc actionToStr(a: KeyAction): string =
  case a
  of kaDown: "down"
  of kaUp: "up"
  of kaPress: "press"

proc submit*(sink: CocoaInputSink; event: InputEvent) =
  ## Concept-satisfying entry point. Translates the typed event into
  ## either a `fireEvent` call (for clicks, on macOS) or a log entry
  ## (for everything else, on every host).
  sink.events.add event
  case event.kind
  of iekMouse:
    sink.log.add "mouse " & actionToStr(event.mouseAction) & " " &
      $event.mouseX & "," & $event.mouseY
    if event.mouseAction == maClick and sink.hitTest != nil:
      let target = sink.hitTest(event.mouseX, event.mouseY)
      if pointer(target) != nil:
        when defined(macosx):
          sink.renderer.fireEvent(target, "click")
        else:
          ## RS-M5 partial-linux: AppKit dispatch isn't available on
          ## the Linux host. Record the hit-test resolution so unit
          ## tests can still assert the routing decision; the actual
          ## `fireEvent` call lands when the macOS engineer takes
          ## the milestone.
          sink.log.add "hit (linux scaffold; fireEvent deferred)"
  of iekKey:
    sink.log.add "key " & actionToStr(event.keyAction) & " " & event.key
    # Cocoa renderer has no synthetic keyboard primitive in `fireEvent`
    # today; surface to stderr so tests / dev runs see what the bridge
    # swallowed.
    stderr.writeLine "cocoa_input_adapter: key event ignored (",
      event.key, ")"
  of iekScroll:
    sink.log.add "scroll " & $event.deltaX & "," & $event.deltaY
  of iekResize:
    sink.log.add "resize " & $event.width & "x" & $event.height
  of iekFocus:
    sink.log.add "focus " & (if event.focused: "true" else: "false")

proc joinLog*(sink: CocoaInputSink; sep = "\n"): string =
  sink.log.join(sep)

proc toAny*(sink: CocoaInputSink): AnyInputSink =
  ## Wrap the Cocoa input sink in the bridge's polymorphic
  ## `AnyInputSink` so it can be dropped into
  ## `BridgeConfig.inputSink`.
  let captured = sink
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
