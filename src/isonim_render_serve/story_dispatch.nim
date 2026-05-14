## RS-M12: story-dispatch sink.
##
## Wraps a launcher-supplied ``mountFn(storyId, properties)`` and
## ``applyMutationFn(target, key, value, scope)`` behind the
## ``AnyInputSink`` shape so the bridge can submit
## ``iekSelectStory`` / ``iekApplyMutation`` events through the same
## input pipe that already carries ``iekKey`` / ``iekMouse`` /
## ``iekScroll`` / ``iekResize`` / ``iekFocus``. Events of the other
## kinds delegate to the launcher's existing wrapped sink (typically
## the renderer's resize-aware sink built in
## ``editor/backends/<renderer>.nim``).
##
## Spec: see *RS-M12* in
## ``codetracer-specs/Front-Ends/IsoNim/isonim-render-stream.status.org``.

import std/json

import ./event_dispatch

type
  StoryMountFn* = proc(storyId: string; properties: JsonNode) {.closure, gcsafe.}
  ApplyMutationFn* = proc(target, key: string; value: JsonNode;
                          scope: MutationScope) {.closure, gcsafe.}
  StoryDispatchLogger* = proc(message: string) {.closure, gcsafe.}

  StoryDispatchSink* = ref object
    ## Wraps ``inner`` so the launcher can react to RS-M12 sub-kinds.
    ## ``mountFn`` is invoked on every ``iekSelectStory``;
    ## ``applyFn`` on every ``iekApplyMutation``. All other event
    ## kinds delegate verbatim to ``inner.submit``.
    mountFn*: StoryMountFn
    applyFn*: ApplyMutationFn
    inner*: AnyInputSink
    logger*: StoryDispatchLogger
    currentStoryId*: string

proc newStoryDispatchSink*(mountFn: StoryMountFn;
                          applyFn: ApplyMutationFn;
                          inner: AnyInputSink = nil;
                          logger: StoryDispatchLogger = nil):
                           StoryDispatchSink =
  ## Construct a story-dispatch sink. ``inner`` may be nil if the
  ## launcher only cares about ``select-story`` / ``apply-mutation``
  ## events — in that case the other kinds are dropped silently. In
  ## practice every launcher supplies its existing resize sink as
  ## ``inner`` so resize / mouse / key still propagate.
  StoryDispatchSink(
    mountFn: mountFn,
    applyFn: applyFn,
    inner: inner,
    logger: logger,
    currentStoryId: "")

proc submit*(sink: StoryDispatchSink; event: InputEvent) =
  ## Dispatch one decoded event. The contract:
  ##
  ## * ``iekSelectStory`` → invoke ``mountFn`` (if set) and update
  ##   ``currentStoryId`` so the launcher can dedupe back-to-back
  ##   selects of the same story.
  ## * ``iekApplyMutation`` → invoke ``applyFn`` (if set).
  ## * anything else → delegate to ``inner.submit`` if present, drop
  ##   otherwise.
  ##
  ## Per the spec, the sink itself never warns on unknown storyIds —
  ## that diagnostic lives inside the launcher's ``mountFn``
  ## implementation, which knows the renderer-specific story table.
  case event.kind
  of iekSelectStory:
    sink.currentStoryId = event.storyId
    if sink.mountFn != nil:
      sink.mountFn(event.storyId, event.properties)
    if sink.logger != nil:
      sink.logger("select-story " & event.storyId)
  of iekApplyMutation:
    if sink.applyFn != nil:
      sink.applyFn(event.mutationTarget, event.mutationKey,
                   event.mutationValue, event.mutationScope)
    if sink.logger != nil:
      sink.logger("apply-mutation " & event.mutationTarget & " " &
                  event.mutationKey)
  else:
    if sink.inner != nil:
      sink.inner.submit(event)

proc toAnyInputSink*(s: StoryDispatchSink): AnyInputSink =
  ## Wrap the dispatch sink so it can be handed to ``runDemoBridgeWith``
  ## (or any other consumer of ``AnyInputSink``).
  let captured = s
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
