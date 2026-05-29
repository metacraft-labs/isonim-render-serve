## RS-M4: Freya input adapter.
##
## Implements an `InputSink` that translates incoming `InputEvent`s
## into Freya shim `fireEvent` calls. Mirrors the RS-M2 GPUI input
## adapter shape so the bridge's polymorphic `AnyInputSink` consumes
## either back-end identically.
##
## RS-M0's `I` packet schema covers mouse / keyboard / scroll /
## resize / focus; Freya's shim today exposes a single dispatch
## primitive (`fireEvent(node, "click")`-style — see
## `isonim_freya/renderer.nim:fireEvent`). The mapping we ship at
## RS-M4 therefore covers exactly what the EX-M4 task_app demo
## uses today:
##
##   * **mouse click** → resolve to a node via the hit-test callback
##     supplied by the composition root, then `fireEvent(node,
##     "click")`. The shim dispatches through the global event
##     dispatcher (see `renderer.nim:registerCallback` /
##     `globalDispatcher`) so the Nim closure that the leaf
##     registered for that node runs in-process.
##   * **mouse move / down / up** → noted in the buffered log for
##     debugging; Freya's shim has no mousemove primitive yet.
##   * **keyboard** → logged to stderr (no Freya surface). The
##     EX-M4 leaves have an "API gap" for text input — there is
##     no `onSubmit` for input-mapped elements; the canonical path
##     is `vm.setInputText("...")` + a click on Add. The bridge
##     follows that same pattern via the hit-tester.
##   * **scroll** / **focus** / **resize** → logged; the bridge's
##     own resize plumbing is the M-packet path.
##
## The composition root supplies a `HitTester` callback that maps an
## (x, y) coordinate to the target `FreyaElement`. The bridge tests
## supply a tiny fixed hit-test that routes all clicks to the demo's
## "Add" button (proving the round-trip end-to-end without needing
## the full hit-test layout pipeline, which is RS-M5+ territory).

import std/strutils

import isonim_freya/renderer

import ../event_dispatch

type
  HitTester* = proc(x, y: int): FreyaElement {.closure, gcsafe.}
    ## Maps a click coordinate to the Freya node that should receive
    ## the synthetic event. The composition root (or the bridge
    ## tests) supplies this callback so the adapter stays
    ## demo-agnostic.

  FreyaInputSink* = ref object
    ## `InputSink` impl. Holds a hit-test callback plus a structured
    ## log mirroring `BufferedInputSink`'s `log` for assertion-driven
    ## tests. Real demos can subclass and override `submit` if they
    ## need richer routing.
    ##
    ## EPP-M7. ``focusedNode`` slot mirrors the GPUI adapter; see
    ## that module's docs.
    hitTest*: HitTester
    log*: seq[string]
    events*: seq[InputEvent]
    focusedNode*: FreyaElement

proc newFreyaInputSink*(hitTest: HitTester): FreyaInputSink =
  FreyaInputSink(hitTest: hitTest, log: @[], events: @[],
                 focusedNode: nil)

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

proc keyboardActionToStr(a: KeyboardAction): string =
  ## EPP-M7. Mirror of ``event_dispatch.actionToStr(KeyboardAction)``.
  case a
  of kbaDown: "down"
  of kbaUp: "up"
  of kbaRepeat: "repeat"

proc submit*(sink: FreyaInputSink; event: InputEvent) =
  ## Concept-satisfying entry point. Translates the typed event into
  ## either a `fireEvent` call (for clicks) or a log entry (for
  ## everything else).
  sink.events.add event
  case event.kind
  of iekMouse:
    sink.log.add "mouse " & actionToStr(event.mouseAction) & " " &
      $event.mouseX & "," & $event.mouseY
    if event.mouseAction == maClick and sink.hitTest != nil:
      let target = sink.hitTest(event.mouseX, event.mouseY)
      if target != nil:
        # EPP-M7: track click target as implicit keyboard focus.
        sink.focusedNode = target
        fireEvent(target, "click")
  of iekKey:
    sink.log.add "key " & actionToStr(event.keyAction) & " " & event.key
    # Freya shim has no keyboard primitive yet; surface to stderr so
    # tests / dev runs see what the bridge swallowed.
    stderr.writeLine "freya_input_adapter: key event ignored (",
      event.key, ")"
  of iekKeyboard:
    # EPP-M7: route through ``fireEvent`` against the implicit
    # focusedNode. Same shape as ``gpui_input_adapter``.
    sink.log.add "keyboard " & keyboardActionToStr(event.keyboardAction) &
      " " & event.keyboardCode & " " & event.keyboardKey
    if sink.focusedNode != nil:
      case event.keyboardAction
      of kbaDown, kbaRepeat:
        fireEvent(sink.focusedNode, "keydown")
        if event.keyboardText.len > 0:
          fireEvent(sink.focusedNode, "input")
      of kbaUp:
        fireEvent(sink.focusedNode, "keyup")
  of iekScroll:
    sink.log.add "scroll " & $event.deltaX & "," & $event.deltaY
  of iekResize:
    sink.log.add "resize " & $event.width & "x" & $event.height
  of iekFocus:
    sink.log.add "focus " & (if event.focused: "true" else: "false")
  of iekSelectStory, iekApplyMutation:
    # RS-M12 sub-kinds — shouldn't reach the renderer-side adapter
    # because the launcher wraps it in a ``StoryDispatchSink``. Log
    # for observability if a future refactor changes the chain.
    sink.log.add "story/mutation event reached input adapter"

proc joinLog*(sink: FreyaInputSink; sep = "\n"): string =
  sink.log.join(sep)

proc toAny*(sink: FreyaInputSink): AnyInputSink =
  ## Wrap the Freya input sink in the bridge's polymorphic
  ## `AnyInputSink` so it can be dropped into
  ## `BridgeConfig.inputSink`.
  let captured = sink
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
