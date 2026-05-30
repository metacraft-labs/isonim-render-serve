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

import ../element_tree_attrs
import ../event_dispatch

type
  HitTester* = proc(x, y: int): CocoaElement {.closure, gcsafe.}
    ## Maps a click coordinate to the Cocoa node that should receive
    ## the synthetic event. The composition root (or the bridge
    ## tests) supplies this callback so the adapter stays
    ## demo-agnostic.

  HitChainTester* = proc(x, y: int): seq[CocoaElement]
                     {.closure, gcsafe.}
    ## EPP-M12. Resolves a click coordinate into an ordered chain of
    ## candidate fireable nodes (deepest first, then enclosing
    ## ancestors). See ``gpui_input_adapter.HitChainTester`` for the
    ## contract.

  CocoaInputSink* = ref object
    ## `InputSink` impl. Holds a hit-test callback plus a structured
    ## log mirroring `BufferedInputSink`'s `log` for assertion-driven
    ## tests. Carries the `CocoaRenderer` value (needed because the
    ## Cocoa `fireEvent` takes the renderer as its first arg, unlike
    ## GPUI/Freya whose shim free-procs don't).
    ##
    ## EPP-M7. ``focusedNode`` slot mirrors the GPUI / Freya adapters;
    ## see ``gpui_input_adapter`` for the contract.
    ##
    ## EPP-M12. ``hitChain`` mirrors the GPUI / Freya adapters; see
    ## ``gpui_input_adapter`` for the walk-up dispatch rationale.
    renderer*: CocoaRenderer
    hitTest*: HitTester
    hitChain*: HitChainTester
    log*: seq[string]
    events*: seq[InputEvent]
    focusedNode*: CocoaElement
    ## FUH-M2: hover-dispatch sink fields. Mirror of the GPUI adapter;
    ## see ``gpui_input_adapter`` for the rationale. Uses the
    ## ``ComponentPathAttr`` string as the stable identity for
    ## throttle keying (Cocoa's ``CocoaElement = Id = distinct
    ## pointer`` happens to round-trip stably through the renderer's
    ## side-tables, but the string-key idiom matches GPUI / Freya so
    ## a future renderer change can't silently break the throttle).
    ## The ``fireEvent`` calls land inside a ``when defined(macosx)``
    ## gate per the existing partial-Linux scaffold; the throttle
    ## bookkeeping still updates on Linux so unit tests can assert
    ## routing behaviour.
    lastHoveredKey*: string
    lastHoveredChain*: seq[CocoaElement]

proc newCocoaInputSink*(renderer: CocoaRenderer;
                        hitTest: HitTester;
                        hitChain: HitChainTester = nil): CocoaInputSink =
  CocoaInputSink(renderer: renderer, hitTest: hitTest,
                 hitChain: hitChain,
                 log: @[], events: @[],
                 focusedNode: default(CocoaElement),
                 lastHoveredKey: "",
                 lastHoveredChain: @[])

proc hoverKey(r: CocoaRenderer; node: CocoaElement): string =
  ## FUH-M2: stable identity for the throttle. See ``gpui_input_adapter``.
  if pointer(node) == nil: return ""
  r.getAttribute(node, ComponentPathAttr)

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

proc submit*(sink: CocoaInputSink; event: InputEvent) =
  ## Concept-satisfying entry point. Translates the typed event into
  ## either a `fireEvent` call (for clicks, on macOS) or a log entry
  ## (for everything else, on every host).
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
          when defined(macosx):
            for node in chain:
              if pointer(node) != nil:
                sink.renderer.fireEvent(node, "click")
          else:
            sink.log.add "hit-chain (linux scaffold; fireEvent deferred)"
      elif sink.hitTest != nil:
        let target = sink.hitTest(event.mouseX, event.mouseY)
        if pointer(target) != nil:
          # EPP-M7: track click target as implicit keyboard focus
          # (same pattern as GPUI / Freya adapters).
          sink.focusedNode = target
          when defined(macosx):
            sink.renderer.fireEvent(target, "click")
          else:
            ## RS-M5 partial-linux: AppKit dispatch isn't available on
            ## the Linux host. Record the hit-test resolution so unit
            ## tests can still assert the routing decision; the actual
            ## `fireEvent` call lands when the macOS engineer takes
            ## the milestone.
            sink.log.add "hit (linux scaffold; fireEvent deferred)"
    elif event.mouseAction == maMove and sink.hitChain != nil:
      # FUH-M2 Phase A: hover dispatch. See the GPUI adapter for the
      # rationale; the throttle and walk contract are identical. The
      # ``fireEvent`` calls are gated ``when defined(macosx)`` per
      # the existing partial-Linux scaffold (the audit § 3.3
      # documents the gate). The throttle bookkeeping still updates
      # on Linux so unit tests can assert routing.
      let chain = sink.hitChain(event.mouseX, event.mouseY)
      let newKey =
        if chain.len > 0: hoverKey(sink.renderer, chain[0])
        else: ""
      if newKey != sink.lastHoveredKey:
        if sink.lastHoveredChain.len > 0:
          sink.log.add "hover-leave " & $sink.lastHoveredChain.len
          when defined(macosx):
            for node in sink.lastHoveredChain:
              if pointer(node) != nil:
                sink.renderer.fireEvent(node, "mouseleave")
          else:
            sink.log.add "hover-leave (linux scaffold; fireEvent deferred)"
        if chain.len > 0:
          sink.log.add "hover-enter " & $chain.len
          when defined(macosx):
            for node in chain:
              if pointer(node) != nil:
                sink.renderer.fireEvent(node, "mouseenter")
          else:
            sink.log.add "hover-enter (linux scaffold; fireEvent deferred)"
        sink.lastHoveredKey = newKey
        sink.lastHoveredChain = chain
  of iekKey:
    sink.log.add "key " & actionToStr(event.keyAction) & " " & event.key
    # Cocoa renderer has no synthetic keyboard primitive in `fireEvent`
    # today; surface to stderr so tests / dev runs see what the bridge
    # swallowed.
    stderr.writeLine "cocoa_input_adapter: key event ignored (",
      event.key, ")"
  of iekKeyboard:
    # EPP-M7: route through ``r.fireEvent`` against the implicit
    # focusedNode. Gated `when defined(macosx)` to match the
    # mouse-click path's RS-M5 partial-Linux scaffold.
    sink.log.add "keyboard " & keyboardActionToStr(event.keyboardAction) &
      " " & event.keyboardCode & " " & event.keyboardKey
    if pointer(sink.focusedNode) != nil:
      when defined(macosx):
        case event.keyboardAction
        of kbaDown, kbaRepeat:
          sink.renderer.fireEvent(sink.focusedNode, "keydown")
          if event.keyboardText.len > 0:
            sink.renderer.fireEvent(sink.focusedNode, "input")
        of kbaUp:
          sink.renderer.fireEvent(sink.focusedNode, "keyup")
      else:
        ## Linux scaffold: record the routing decision; the actual
        ## fireEvent call lands on macOS.
        sink.log.add "keyboard-target (linux scaffold; fireEvent deferred)"
  of iekScroll:
    sink.log.add "scroll " & $event.deltaX & "," & $event.deltaY
  of iekResize:
    sink.log.add "resize " & $event.width & "x" & $event.height
  of iekFocus:
    sink.log.add "focus " & (if event.focused: "true" else: "false")
  of iekSelectStory, iekApplyMutation:
    # RS-M12 sub-kinds — shouldn't reach the renderer-side adapter.
    sink.log.add "story/mutation event reached input adapter"

proc joinLog*(sink: CocoaInputSink; sep = "\n"): string =
  sink.log.join(sep)

proc toAny*(sink: CocoaInputSink): AnyInputSink =
  ## Wrap the Cocoa input sink in the bridge's polymorphic
  ## `AnyInputSink` so it can be dropped into
  ## `BridgeConfig.inputSink`.
  let captured = sink
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
