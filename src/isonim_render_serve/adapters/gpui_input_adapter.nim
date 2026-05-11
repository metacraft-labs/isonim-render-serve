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

  GpuiInputSink* = ref object
    ## `InputSink` impl. Holds a hit-test callback plus a structured
    ## log mirroring `BufferedInputSink`'s `log` for assertion-driven
    ## tests. Real demos can subclass and override `submit` if they
    ## need richer routing.
    hitTest*: HitTester
    log*: seq[string]
    events*: seq[InputEvent]

proc newGpuiInputSink*(hitTest: HitTester): GpuiInputSink =
  GpuiInputSink(hitTest: hitTest, log: @[], events: @[])

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

proc submit*(sink: GpuiInputSink; event: InputEvent) =
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
        fireEvent(target, "click")
  of iekKey:
    sink.log.add "key " & actionToStr(event.keyAction) & " " & event.key
    # GPUI shim has no keyboard primitive yet; surface to stderr so
    # tests / dev runs see what the bridge swallowed.
    stderr.writeLine "gpui_input_adapter: key event ignored (",
      event.key, ")"
  of iekScroll:
    sink.log.add "scroll " & $event.deltaX & "," & $event.deltaY
  of iekResize:
    sink.log.add "resize " & $event.width & "x" & $event.height
  of iekFocus:
    sink.log.add "focus " & (if event.focused: "true" else: "false")

proc joinLog*(sink: GpuiInputSink; sep = "\n"): string =
  sink.log.join(sep)

proc toAny*(sink: GpuiInputSink): AnyInputSink =
  ## Wrap the GPUI input sink in the bridge's polymorphic
  ## `AnyInputSink` so it can be dropped into
  ## `BridgeConfig.inputSink`.
  let captured = sink
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
