## EPP-M7: launcher sink composition helpers.
##
## Before EPP-M7 every launcher in
## ``isonim-examples/editor/backends/{gpui,freya,cocoa,android}.nim``
## hand-stamped its own ``resizingSink`` ``AnyInputSink`` that filtered
## everything except ``iekResize`` and dropped the rest on the floor
## (see EPP-M1 audit § 4.2 / § 5). EPP-M7 closes that gap by routing
## ``iekMouse`` / ``iekKeyboard`` through the per-renderer
## ``InputSink`` adapter (``GpuiInputSink`` / ``FreyaInputSink`` /
## ``CocoaInputSink`` / ``AndroidInputSink``) while preserving
## VRS-M2's byte-exact ``iekResize`` semantics.
##
## The composition shape — ``StoryDispatchSink → DispatchingSink →
## (resize sink || renderer input sink)`` — is implemented here as a
## single ``newDispatchingLauncherSink`` factory so launchers don't
## duplicate the wiring. The factory takes a ``ResizeHandler`` closure
## (the launcher's existing resize callback) and the renderer-side
## ``AnyInputSink`` (the wrapped ``GpuiInputSink.toAny`` / etc) and
## returns the composite ``AnyInputSink`` to install at the
## ``StoryDispatchSink``'s ``inner`` slot.
##
## **No new schema** — this module only composes existing sinks. The
## ``iekKeyboard`` schema itself is locked in ``event_dispatch.nim``;
## see EPP-M7 § *Schema additions* in
## ``codetracer-specs/Front-Ends/IsoNim/Editor-Preview-Performance.milestones.org``.

import ./event_dispatch

type
  ResizeHandler* = proc(width, height: int) {.closure, gcsafe.}
    ## EPP-M7. Launcher-side resize callback. Receives the new
    ## width / height from the decoded ``iekResize`` event. The
    ## launcher's implementation typically mutates the
    ## ``AnyFrameSource``'s dynamic dimensions so the next emitted
    ## F-packet picks them up (matching VRS-M2's byte-exact
    ## contract).

proc newDispatchingLauncherSink*(onResize: ResizeHandler;
                                 inputSink: AnyInputSink = nil):
                                  AnyInputSink =
  ## EPP-M7. Compose a per-launcher input sink that routes:
  ##
  ##   * ``iekResize`` → ``onResize`` (preserves VRS-M2 semantics —
  ##     zero / negative / unchanged dimensions are filtered out by
  ##     the launcher's existing guards inside ``onResize``).
  ##   * ``iekMouse`` / ``iekKeyboard`` / ``iekScroll`` / ``iekFocus``
  ##     → ``inputSink`` (the wrapped per-renderer adapter — typically
  ##     ``GpuiInputSink.toAny`` etc.). When ``inputSink`` is nil the
  ##     events are dropped silently, matching the pre-EPP-M7 default.
  ##   * ``iekSelectStory`` / ``iekApplyMutation`` → never reach this
  ##     sink — the launcher installs this as the ``inner`` of a
  ##     ``StoryDispatchSink`` whose ``submit`` short-circuits those
  ##     kinds before delegating to inner.
  ##
  ## Returned as ``AnyInputSink`` so it drops straight into the
  ## ``StoryDispatchSink``'s ``inner`` slot.
  let capturedResize = onResize
  let capturedInput = inputSink
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}:
      case event.kind
      of iekResize:
        if capturedResize != nil:
          capturedResize(event.width, event.height)
      of iekMouse, iekKeyboard, iekScroll, iekFocus, iekKey:
        if capturedInput != nil:
          capturedInput.submit(event)
      of iekSelectStory, iekApplyMutation:
        # Defensively forward — should never reach here in practice
        # because the StoryDispatchSink wraps this sink. Forward
        # anyway so a launcher that bypasses StoryDispatchSink still
        # works.
        if capturedInput != nil:
          capturedInput.submit(event))
