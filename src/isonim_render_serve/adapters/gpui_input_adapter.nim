## RS-M2: GPUI input adapter.
##
## Implements an `InputSink` that translates incoming
## `InputEvent`s into GPUI shim `fireEvent` calls.
##
## RS-M0's `I` packet schema covers mouse / keyboard / scroll /
## resize / focus; GPUI's shim today exposes a single dispatch
## primitive (`fireEvent(node, "click")`-style — see
## `isonim_gpui/renderer.nim:fireEvent`). The mapping we ship at
## RS-M2 therefore covers exactly what the demo uses today:
##
##   * **mouse click** → resolve to a node via the hit-test callback
##     supplied by the composition root, then `fireEvent(node,
##     "click")`.
##   * **mouse move / down / up** → noted in the buffered log for
##     debugging; the GPUI shim has no mousemove primitive yet.
##   * **keyboard** → logged to stderr (no GPUI surface).
##   * **scroll** / **focus** / **resize** → logged; the bridge's
##     own resize plumbing is the M-packet path at RS-M3+.
##
## The composition root supplies a `hitTest` callback that maps an
## (x, y) coordinate to the target `GpuiElement`. The bridge tests
## supply a tiny fixed hit-test that routes all clicks to the demo's
## "Add" button (proving the round-trip end-to-end without needing
## the full hit-test layout pipeline, which is RS-M3+).

import std/strutils

import isonim_gpui/renderer

import ../event_dispatch

type
  HitTester* = proc(x, y: int): GpuiElement {.closure, gcsafe.}
    ## Maps a click coordinate to the GPUI node that should receive
    ## the synthetic event. The composition root (or the bridge
    ## tests) supplies this callback so the adapter stays
    ## demo-agnostic.

  HitChainTester* = proc(x, y: int): seq[GpuiElement]
                     {.closure, gcsafe.}
    ## EPP-M12. Resolves a click coordinate into an ordered chain of
    ## candidate fireable nodes (deepest first, then enclosing
    ## ancestors). The launcher composition root supplies this so the
    ## adapter can fire ``"click"`` on every node in the chain — that
    ## way whichever ancestor has the registered Nim closure handles
    ## the click. ``fireEvent`` is a no-op on nodes with no listener
    ## for the dispatched event, so the walk is safe to apply
    ## unconditionally. See ``gpui_adapter.hitTestPath`` for the
    ## canonical layout-based implementation.

  GpuiInputSink* = ref object
    ## `InputSink` impl. Holds a hit-test callback plus a structured
    ## log mirroring `BufferedInputSink`'s `log` for assertion-driven
    ## tests. Real demos can subclass and override `submit` if they
    ## need richer routing.
    ##
    ## EPP-M7 adds ``focusedNode``: the launcher's last hit-tested
    ## click target is remembered as the implicit keyboard-focus
    ## sink, mirroring how a DOM ``<input>`` element receives all
    ## subsequent keystrokes after the user clicks into it. The
    ## browser-side shim sends keystrokes only while the canvas has
    ## focus, so the launcher does not need a separate focus
    ## handshake — every click into the canvas updates this slot.
    ##
    ## EPP-M12 adds ``hitChain``: when non-nil, the input adapter
    ## fires ``"click"`` on every node in the returned chain (deepest
    ## first) rather than the single legacy ``hitTest`` target. The
    ## launcher composition root wires this to ``hitTestPath`` so the
    ## click reaches a fireable shadow-tree leaf even when the
    ## composition root itself has no click handler.
    hitTest*: HitTester
    hitChain*: HitChainTester
    log*: seq[string]
    events*: seq[InputEvent]
    focusedNode*: GpuiElement

proc newGpuiInputSink*(hitTest: HitTester;
                       hitChain: HitChainTester = nil): GpuiInputSink =
  GpuiInputSink(hitTest: hitTest, hitChain: hitChain,
                log: @[], events: @[],
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
  ## EPP-M7. Local mirror of ``event_dispatch.actionToStr(KeyboardAction)``
  ## so the adapter's log lines stay self-contained.
  case a
  of kbaDown: "down"
  of kbaUp: "up"
  of kbaRepeat: "repeat"

proc submit*(sink: GpuiInputSink; event: InputEvent) =
  ## Concept-satisfying entry point. Translates the typed event into
  ## either a `fireEvent` call (for clicks) or a log entry (for
  ## everything else).
  sink.events.add event
  case event.kind
  of iekMouse:
    sink.log.add "mouse " & actionToStr(event.mouseAction) & " " &
      $event.mouseX & "," & $event.mouseY
    if event.mouseAction == maClick:
      # EPP-M12: prefer the chain hit-tester when present so the
      # adapter fires ``"click"`` on every shadow-tree node that
      # contains the click coordinate (deepest first, then enclosing
      # ancestors). ``fireEvent`` is a no-op on nodes without a
      # registered ``"click"`` listener, so the walk-up safely
      # delivers the click to whichever ancestor actually owns the
      # handler.
      if sink.hitChain != nil:
        let chain = sink.hitChain(event.mouseX, event.mouseY)
        if chain.len > 0:
          # EPP-M7: implicit keyboard focus tracks the deepest hit.
          sink.focusedNode = chain[0]
          sink.log.add "hit-chain " & $chain.len
          for node in chain:
            if node != nil:
              fireEvent(node, "click")
      elif sink.hitTest != nil:
        let target = sink.hitTest(event.mouseX, event.mouseY)
        if target != nil:
          # EPP-M7: remember the click target as the implicit
          # keyboard-focus sink so subsequent ``iekKeyboard`` events
          # land on the same leaf.
          sink.focusedNode = target
          fireEvent(target, "click")
  of iekKey:
    sink.log.add "key " & actionToStr(event.keyAction) & " " & event.key
    # GPUI shim has no keyboard primitive yet; surface to stderr so
    # tests / dev runs see what the bridge swallowed.
    stderr.writeLine "gpui_input_adapter: key event ignored (",
      event.key, ")"
  of iekKeyboard:
    # EPP-M7: route keyboard events through the same shadow-tree
    # ``fireEvent`` dispatch the audit § 4.4 documents. The launcher
    # leaves register ``"keydown"`` / ``"keyup"`` / ``"input"`` Nim
    # closures via the standard ``addEventListener`` path; this
    # adapter just translates the wire kind into the matching
    # fireEvent name. ``kbaRepeat`` is projected onto ``"keydown"``
    # (matching the DOM-side ``event.repeat`` convention) so launcher
    # handlers only have to handle two events, not three.
    sink.log.add "keyboard " & keyboardActionToStr(event.keyboardAction) &
      " " & event.keyboardCode & " " & event.keyboardKey
    if sink.focusedNode != nil:
      case event.keyboardAction
      of kbaDown, kbaRepeat:
        fireEvent(sink.focusedNode, "keydown")
        if event.keyboardText.len > 0:
          # Text input contribution — most ``<input>`` leaves listen
          # on ``"input"`` for typed characters; the leaf can read
          # the captured text via the renderer's own focus-text
          # surface (out of scope for this milestone — the existing
          # ``vm.setInputText`` / Add-button pattern still works).
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
    # RS-M12 sub-kinds. The launcher wraps this adapter inside a
    # ``StoryDispatchSink`` whose ``submit`` short-circuits these
    # kinds before delegating to ``inner``, so they shouldn't reach
    # us in practice. Log them so a future refactor that bypasses
    # the StoryDispatchSink wrapper is visible in the test trace.
    sink.log.add "story/mutation event reached input adapter"

proc joinLog*(sink: GpuiInputSink; sep = "\n"): string =
  sink.log.join(sep)

proc toAny*(sink: GpuiInputSink): AnyInputSink =
  ## Wrap the GPUI input sink in the bridge's polymorphic
  ## `AnyInputSink` so it can be dropped into
  ## `BridgeConfig.inputSink`.
  let captured = sink
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
