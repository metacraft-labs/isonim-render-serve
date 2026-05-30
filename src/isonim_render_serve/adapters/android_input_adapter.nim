## RS-M6: Android input adapter (Linux-side scaffold; macOS host
## completes via emulator).
##
## Implements an `InputSink` that translates incoming `InputEvent`s
## into `AndroidRenderer.fireEvent` calls (which dispatch through
## the JNI callback registry that `addEventListener` populated). The
## adapter mirrors the RS-M2 (GPUI), RS-M4 (Freya) and RS-M5 (Cocoa)
## input-adapter shape so the bridge's polymorphic `AnyInputSink`
## consumes any of the four back-ends identically.
##
## ## Status — partial-linux
##
## On Linux the type machinery (`HitTester`, `AndroidInputSink`,
## `submit`, `toAny`) compiles, but the `fireEvent` call on the
## hit-tested target view is gated `when defined(android)` because
## `AndroidRenderer.fireEvent` walks the JNI `callLog` (mockJni
## lane) or dispatches through the real JNI bridge (commandBuffer
## lane), neither of which the plain Linux host build wants to run.
## In fact `isonim_android/jni_callbacks` raises a hard `{.error.}`
## on a plain Linux build unless one of `-d:mockJni` /
## `-d:commandBuffer` is set, so the `isonim_android/renderer`
## import itself has to live inside the `when defined(android)`
## block — matching the EX-M6 pattern in
## `isonim-examples/task_app/main_android.nim`. On Linux the click
## path falls through to the buffered log so unit tests can still
## assert routing behaviour, and the surface types
## (`AndroidRenderer`, `AndroidElement`) come from the adapter's
## Linux-scaffold placeholders re-exported via `android_adapter`.
##
## ## Mapping
##
## RS-M0's `I` packet schema covers mouse / keyboard / scroll /
## resize / focus; the Android renderer exposes the same
## `fireEvent` dispatch primitive as the GPUI / Freya / Cocoa
## shims:
##
##   * **mouse click** → resolve to a node via the hit-test callback
##     supplied by the composition root, then `r.fireEvent(node,
##     "click")`. The renderer dispatches through the registered
##     JNI callback (see `renderer.fireEvent` →
##     `jniSetEventListener` → `registerCallback`) so the Nim
##     closure that the leaf attached for that node runs in-process
##     (mockJni lane) or via the real JNI bridge (commandBuffer
##     lane on an emulator). On a real Android host the click maps
##     to a synthesised `MotionEvent` of action `ACTION_UP` for
##     low-level event injection (`dispatchTouchEvent`), but
##     Robolectric / the in-process JNI shim short-circuits to the
##     registered listener callback — matching the
##     GPUI/Freya/Cocoa idiom.
##   * **mouse move / down / up** → buffered to the structured log.
##     `AndroidRenderer` has no mousemove dispatch primitive yet
##     (same gap as GPUI / Freya / Cocoa).
##   * **keyboard** → logged to stderr (no Android keyboard surface
##     beyond `EditText`'s `setText`, which is wired via JNI
##     attribute updates, not the `fireEvent` C API). The EX-M6
##     task_app demo follows the GPUI / Freya / Cocoa pattern:
##     `vm.setInputText` + click on Add, both routed through this
##     sink.
##   * **scroll** / **focus** / **resize** → logged; the bridge's
##     own resize plumbing remains the M-packet path.
##
## ## Hand-off — what the macOS M1 engineer must do (emulator host)
##
## See `isonim-render-stream.status.org` § RS-M6 for the canonical
## checklist. For this module specifically:
##
##   1. Verify the `r.fireEvent(target, "click")` call dispatches
##      through to the leaf-registered Nim callback on a real
##      Android emulator host (commandBuffer JNI lane).
##      `AndroidRenderer.fireEvent` is currently `discard` on the
##      commandBuffer lane (the implementation gates the callLog
##      walk on `when defined(mockJni)`); the engineer must either
##      extend the commandBuffer lane to issue a JNI
##      `View.performClick()` call on the target view, or add a
##      parallel in-process callback registry on the JNI bridge
##      side. Confirm the callback runs synchronously inside
##      `fireEvent` (as it does on GPUI / Freya / Cocoa). If
##      `fireEvent` ends up asynchronous on Android, surface a
##      synchronous mode for tests.
##   2. The hit-tester callback is composition-root-supplied (same
##      as GPUI / Freya / Cocoa). For the task_app integration
##      test, point all clicks at the demo's Add-button leaf — the
##      test asserts `vm.tasks.value.len` increments per click.

import std/strutils

import ./android_adapter  ## re-exports `AndroidRenderer` /
                          ## `AndroidElement` from
                          ## `isonim_android/renderer` on
                          ## `-d:android` builds, or the Linux-side
                          ## opaque placeholders otherwise.

import ../element_tree_attrs
import ../event_dispatch

type
  HitTester* = proc(x, y: int): AndroidElement {.closure, gcsafe.}
    ## Maps a click coordinate to the Android node that should
    ## receive the synthetic event. The composition root (or the
    ## bridge tests) supplies this callback so the adapter stays
    ## demo-agnostic.

  HitChainTester* = proc(x, y: int): seq[AndroidElement]
                     {.closure, gcsafe.}
    ## FUH-M2. Resolves a coordinate into an ordered chain of
    ## candidate fireable nodes (deepest first, then enclosing
    ## ancestors). See ``gpui_input_adapter.HitChainTester`` for the
    ## contract. The launcher composition root supplies this so the
    ## adapter can fire ``"click"`` (on ``maClick``) or
    ## ``"mouseenter"`` / ``"mouseleave"`` (on ``maMove``) on every
    ## node in the chain. ``fireEvent`` is a no-op on nodes without a
    ## registered listener, so the walk-up is safe to apply
    ## unconditionally. See ``android_adapter.hitTestPath`` for the
    ## canonical layout-based implementation.

  AndroidInputSink* = ref object
    ## `InputSink` impl. Holds a hit-test callback plus a structured
    ## log mirroring `BufferedInputSink`'s `log` for assertion-driven
    ## tests. Carries the `AndroidRenderer` value (needed because
    ## the Android `fireEvent` takes the renderer as its first arg,
    ## like Cocoa — and unlike the GPUI / Freya shim free-procs).
    ## Note that `AndroidElement = ViewHandle = int64` (not
    ## `distinct pointer` like GPUI / Freya / Cocoa), so null
    ## checks use `target == 0` instead of `pointer(target) != nil`.
    ##
    ## EPP-M7. ``focusedNode`` slot mirrors GPUI / Freya / Cocoa.
    ##
    ## FUH-M2. ``hitChain`` mirrors the GPUI / Freya / Cocoa adapters
    ## (FUH-M1 audit § 1 flagged Android as the only adapter without
    ## this field at the EPP-M12 baseline). ``lastHoveredKey`` /
    ## ``lastHoveredChain`` carry the throttle state for the hover
    ## dispatch on ``maMove``; see ``gpui_input_adapter`` for the
    ## stable-identity rationale.
    renderer*: AndroidRenderer
    hitTest*: HitTester
    hitChain*: HitChainTester
    log*: seq[string]
    events*: seq[InputEvent]
    focusedNode*: AndroidElement
    lastHoveredKey*: string
    lastHoveredChain*: seq[AndroidElement]

proc newAndroidInputSink*(renderer: AndroidRenderer;
                          hitTest: HitTester;
                          hitChain: HitChainTester = nil): AndroidInputSink =
  AndroidInputSink(renderer: renderer, hitTest: hitTest,
                   hitChain: hitChain,
                   log: @[], events: @[],
                   focusedNode: AndroidElement(0),
                   lastHoveredKey: "",
                   lastHoveredChain: @[])

when defined(android) or defined(mockJni):
  proc hoverKey(r: AndroidRenderer; node: AndroidElement): string =
    ## FUH-M2: stable identity for the throttle. See
    ## ``gpui_input_adapter``. Only meaningful when the renderer is
    ## the real ``isonim_android/renderer`` (i.e. ``-d:android`` or
    ## ``-d:mockJni``); on the plain Linux scaffold the renderer is
    ## an empty placeholder with no ``getAttribute`` and the
    ## throttle falls back to comparing the raw integer handle below.
    if node == 0: return ""
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
  ## EPP-M7.
  case a
  of kbaDown: "down"
  of kbaUp: "up"
  of kbaRepeat: "repeat"

proc submit*(sink: AndroidInputSink; event: InputEvent) =
  ## Concept-satisfying entry point. Translates the typed event
  ## into either a `fireEvent` call (for clicks, on Android) or a
  ## log entry (for everything else, on every host).
  sink.events.add event
  case event.kind
  of iekMouse:
    sink.log.add "mouse " & actionToStr(event.mouseAction) & " " &
      $event.mouseX & "," & $event.mouseY
    if event.mouseAction == maClick:
      # FUH-M2: prefer the chain hit-tester so the click reaches a
      # fireable shadow-tree leaf even when the composition root
      # itself has no click handler. Mirrors the EPP-M12 walk-up
      # dispatch contract in the GPUI / Freya / Cocoa adapters.
      if sink.hitChain != nil:
        let chain = sink.hitChain(event.mouseX, event.mouseY)
        if chain.len > 0:
          sink.focusedNode = chain[0]
          sink.log.add "hit-chain " & $chain.len
          when defined(android) or defined(mockJni):
            for node in chain:
              if node != 0:
                sink.renderer.fireEvent(node, "click")
          else:
            sink.log.add "hit-chain (linux scaffold; fireEvent deferred)"
      elif sink.hitTest != nil:
        let target = sink.hitTest(event.mouseX, event.mouseY)
        if target != 0:
          # EPP-M7: track click target as implicit keyboard focus.
          sink.focusedNode = target
          when defined(android) or defined(mockJni):
            sink.renderer.fireEvent(target, "click")
          else:
            ## RS-M6 partial-linux: Android-runtime dispatch isn't
            ## available on the Linux host. Record the hit-test
            ## resolution so unit tests can still assert the
            ## routing decision; the actual `fireEvent` call lands
            ## when the macOS engineer takes the milestone on an
            ## emulator host.
            sink.log.add "hit (linux scaffold; fireEvent deferred)"
    elif event.mouseAction == maMove and sink.hitChain != nil:
      # FUH-M2 Phase A: hover dispatch. See the GPUI adapter for the
      # rationale; the throttle and walk contract are identical. The
      # ``fireEvent`` calls are gated on the Android runtime; the
      # throttle bookkeeping still updates on the plain Linux host
      # so unit tests (and the mockJni lane) can assert routing.
      let chain = sink.hitChain(event.mouseX, event.mouseY)
      let newKey =
        when defined(android) or defined(mockJni):
          if chain.len > 0: hoverKey(sink.renderer, chain[0])
          else: ""
        else:
          # Linux scaffold: no real renderer; fall back to the
          # raw integer handle as a stable identity. The scaffold
          # adapter only ever receives stub `AndroidElement` values
          # so this is safe for the unit-test compile gate.
          if chain.len > 0: $int64(chain[0])
          else: ""
      if newKey != sink.lastHoveredKey:
        if sink.lastHoveredChain.len > 0:
          sink.log.add "hover-leave " & $sink.lastHoveredChain.len
          when defined(android) or defined(mockJni):
            for node in sink.lastHoveredChain:
              if node != 0:
                sink.renderer.fireEvent(node, "mouseleave")
          else:
            sink.log.add "hover-leave (linux scaffold; fireEvent deferred)"
        if chain.len > 0:
          sink.log.add "hover-enter " & $chain.len
          when defined(android) or defined(mockJni):
            for node in chain:
              if node != 0:
                sink.renderer.fireEvent(node, "mouseenter")
          else:
            sink.log.add "hover-enter (linux scaffold; fireEvent deferred)"
        sink.lastHoveredKey = newKey
        sink.lastHoveredChain = chain
  of iekKey:
    sink.log.add "key " & actionToStr(event.keyAction) & " " & event.key
    # Android renderer has no synthetic keyboard primitive in
    # `fireEvent` today; surface to stderr so tests / dev runs see
    # what the bridge swallowed.
    stderr.writeLine "android_input_adapter: key event ignored (",
      event.key, ")"
  of iekKeyboard:
    # EPP-M7: route through ``r.fireEvent`` against the implicit
    # focusedNode. Same shape as the GPUI / Freya / Cocoa adapters.
    sink.log.add "keyboard " & keyboardActionToStr(event.keyboardAction) &
      " " & event.keyboardCode & " " & event.keyboardKey
    if sink.focusedNode != 0:
      when defined(android):
        case event.keyboardAction
        of kbaDown, kbaRepeat:
          sink.renderer.fireEvent(sink.focusedNode, "keydown")
          if event.keyboardText.len > 0:
            sink.renderer.fireEvent(sink.focusedNode, "input")
        of kbaUp:
          sink.renderer.fireEvent(sink.focusedNode, "keyup")
      else:
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

proc joinLog*(sink: AndroidInputSink; sep = "\n"): string =
  sink.log.join(sep)

proc toAny*(sink: AndroidInputSink): AnyInputSink =
  ## Wrap the Android input sink in the bridge's polymorphic
  ## `AnyInputSink` so it can be dropped into
  ## `BridgeConfig.inputSink`.
  let captured = sink
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
