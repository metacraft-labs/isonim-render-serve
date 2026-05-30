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

import ../element_tree_attrs
import ../event_dispatch

type
  HitTester* = proc(x, y: int): FreyaElement {.closure, gcsafe.}
    ## Maps a click coordinate to the Freya node that should receive
    ## the synthetic event. The composition root (or the bridge
    ## tests) supplies this callback so the adapter stays
    ## demo-agnostic.

  HitChainTester* = proc(x, y: int): seq[FreyaElement]
                     {.closure, gcsafe.}
    ## EPP-M12. Resolves a click coordinate into an ordered chain of
    ## candidate fireable nodes (deepest first, then enclosing
    ## ancestors). See ``gpui_input_adapter.HitChainTester`` for the
    ## contract.

  FreyaInputSink* = ref object
    ## `InputSink` impl. Holds a hit-test callback plus a structured
    ## log mirroring `BufferedInputSink`'s `log` for assertion-driven
    ## tests. Real demos can subclass and override `submit` if they
    ## need richer routing.
    ##
    ## EPP-M7. ``focusedNode`` slot mirrors the GPUI adapter; see
    ## that module's docs.
    ##
    ## EPP-M12. ``hitChain`` mirrors the GPUI adapter; see
    ## ``gpui_input_adapter`` for the walk-up dispatch rationale.
    hitTest*: HitTester
    hitChain*: HitChainTester
    log*: seq[string]
    events*: seq[InputEvent]
    focusedNode*: FreyaElement
    ## FUH-M2: hover-dispatch sink fields. Mirror of the GPUI adapter;
    ## see ``gpui_input_adapter`` for the rationale (including the
    ## ``ComponentPathAttr``-based stable identity, since the Freya
    ## shim has the same fresh-handle-per-call shape as GPUI).
    lastHoveredKey*: string
    lastHoveredChain*: seq[FreyaElement]

proc newFreyaInputSink*(hitTest: HitTester;
                        hitChain: HitChainTester = nil): FreyaInputSink =
  FreyaInputSink(hitTest: hitTest, hitChain: hitChain,
                 log: @[], events: @[],
                 focusedNode: nil,
                 lastHoveredKey: "",
                 lastHoveredChain: @[])

proc hoverKey(node: FreyaElement): string =
  ## FUH-M2: stable identity for the throttle. See ``gpui_input_adapter``.
  if node == nil: return ""
  getAttribute(node, ComponentPathAttr)

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
    if event.mouseAction == maClick:
      # EPP-M12: prefer the chain hit-tester so the click reaches a
      # fireable shadow-tree leaf even when the composition root
      # itself has no click handler. See the GPUI input adapter for
      # the rationale; the walk-up dispatch contract is identical.
      if sink.hitChain != nil:
        let chain = sink.hitChain(event.mouseX, event.mouseY)
        if chain.len > 0:
          sink.focusedNode = chain[0]
          sink.log.add "hit-chain " & $chain.len
          for node in chain:
            if node != nil:
              fireEvent(node, "click")
      elif sink.hitTest != nil:
        let target = sink.hitTest(event.mouseX, event.mouseY)
        if target != nil:
          # EPP-M7: track click target as implicit keyboard focus.
          sink.focusedNode = target
          fireEvent(target, "click")
    elif event.mouseAction == maMove and sink.hitChain != nil:
      # FUH-M2 Phase A: hover dispatch. See the GPUI adapter for the
      # rationale; the throttle and walk contract are identical.
      let chain = sink.hitChain(event.mouseX, event.mouseY)
      let newKey =
        if chain.len > 0: hoverKey(chain[0])
        else: ""
      if newKey != sink.lastHoveredKey:
        if sink.lastHoveredChain.len > 0:
          sink.log.add "hover-leave " & $sink.lastHoveredChain.len
          for node in sink.lastHoveredChain:
            if node != nil:
              fireEvent(node, "mouseleave")
        if chain.len > 0:
          sink.log.add "hover-enter " & $chain.len
          for node in chain:
            if node != nil:
              fireEvent(node, "mouseenter")
        sink.lastHoveredKey = newKey
        sink.lastHoveredChain = chain
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
