## test_story_dispatch_sink — RS-M12 dispatch invariants.
##
## Drives the real ``StoryDispatchSink`` against a fake renderer that
## records every (storyId, properties) tuple and every (target, key,
## value, scope) tuple. Asserts:
##
##   1. ``iekSelectStory`` → ``mountFn(storyId, properties)`` with
##      identical fields; ``currentStoryId`` updates.
##   2. ``iekApplyMutation`` → ``applyFn(target, key, value, scope)``
##      with identical fields.
##   3. Non-RS-M12 events (mouse / resize / key / scroll / focus)
##      delegate to ``inner.submit``.
##   4. The sink can be wrapped via ``toAnyInputSink`` and consumed as
##      a regular ``AnyInputSink``; the dispatch contract holds
##      through the polymorphic wrapper.
##   5. The launcher-side mountFn is responsible for warning on
##      unknown storyIds — the sink itself does not gate.
##   6. A nil ``inner`` is acceptable: non-RS-M12 events are dropped
##      silently.
##   7. Malformed JSON (truncated I packet body) surfaces as a
##      ``PacketProtocolError`` from ``decodeInputEvent`` — the sink
##      never sees the malformed event, the bridge already drops it.
##
## No mocks: the sink under test is the production code path. The
## "fake renderer" is just a recorder for the launcher-supplied
## closures.

import std/[json, unittest]

import isonim_render_serve

type
  MountRecord = tuple[storyId: string; properties: JsonNode]
  ApplyRecord = tuple[target, key: string; value: JsonNode;
                       scope: MutationScope]
  Recorder = ref object
    mounts: seq[MountRecord]
    applies: seq[ApplyRecord]
    inner: BufferedInputSink
    logs: seq[string]

proc newRecorder(): Recorder =
  Recorder(mounts: @[], applies: @[],
           inner: newBufferedInputSink(), logs: @[])

proc makeSink(rec: Recorder; mountFn = true; applyFn = true;
              withInner = true; withLogger = false): StoryDispatchSink =
  let mfn: StoryMountFn =
    if mountFn:
      proc(storyId: string; props: JsonNode) {.closure, gcsafe.} =
        {.cast(gcsafe).}: rec.mounts.add((storyId, props))
    else:
      nil
  let afn: ApplyMutationFn =
    if applyFn:
      proc(target, key: string; value: JsonNode; scope: MutationScope)
          {.closure, gcsafe.} =
        {.cast(gcsafe).}: rec.applies.add((target, key, value, scope))
    else:
      nil
  let inner: AnyInputSink =
    if withInner: rec.inner.toAny() else: nil
  let logger: StoryDispatchLogger =
    if withLogger:
      proc(msg: string) {.closure, gcsafe.} =
        {.cast(gcsafe).}: rec.logs.add(msg)
    else:
      nil
  newStoryDispatchSink(mfn, afn, inner, logger)

suite "isonim-render-serve: RS-M12 StoryDispatchSink":

  test "select-story → mountFn with matching id + properties":
    let rec = newRecorder()
    let sink = makeSink(rec)
    let props = newJObject()
    props["dark"] = newJBool(true)
    sink.submit InputEvent(kind: iekSelectStory,
      storyGroup: "Settings App / Pages",
      storyName: "Appearance Group",
      storyKind: "skPage",
      storyId: "Settings App / Pages / Appearance Group",
      properties: props)
    check rec.mounts.len == 1
    check rec.mounts[0].storyId ==
      "Settings App / Pages / Appearance Group"
    check rec.mounts[0].properties != nil
    check rec.mounts[0].properties["dark"].getBool == true
    check sink.currentStoryId ==
      "Settings App / Pages / Appearance Group"

  test "apply-mutation → applyFn with matching target + key + value + scope":
    let rec = newRecorder()
    let sink = makeSink(rec)
    sink.submit InputEvent(kind: iekApplyMutation,
      mutationTarget: "settings_app/views/Toggle#DarkMode",
      mutationKey: "checked",
      mutationValue: newJBool(true),
      mutationScope: msShared)
    check rec.applies.len == 1
    check rec.applies[0].target == "settings_app/views/Toggle#DarkMode"
    check rec.applies[0].key == "checked"
    check rec.applies[0].value.getBool == true
    check rec.applies[0].scope == msShared

  test "mouse / resize / key / scroll / focus delegate to inner sink":
    let rec = newRecorder()
    let sink = makeSink(rec)
    sink.submit InputEvent(kind: iekMouse, mouseAction: maClick,
                            button: 0, mouseX: 100, mouseY: 50)
    sink.submit InputEvent(kind: iekResize, width: 1024, height: 768)
    sink.submit InputEvent(kind: iekKey, keyAction: kaDown, key: "Enter")
    sink.submit InputEvent(kind: iekScroll, deltaX: 0, deltaY: -10)
    sink.submit InputEvent(kind: iekFocus, focused: true)
    check rec.inner.events.len == 5
    check rec.mounts.len == 0
    check rec.applies.len == 0

  test "currentStoryId updates across consecutive selects":
    let rec = newRecorder()
    let sink = makeSink(rec)
    sink.submit InputEvent(kind: iekSelectStory, storyId: "A / X / 1",
      storyGroup: "A", storyName: "X / 1", storyKind: "skComponent")
    sink.submit InputEvent(kind: iekSelectStory, storyId: "B / Y / 2",
      storyGroup: "B", storyName: "Y / 2", storyKind: "skPage")
    check rec.mounts.len == 2
    check sink.currentStoryId == "B / Y / 2"

  test "toAnyInputSink preserves dispatch through the polymorphic wrapper":
    let rec = newRecorder()
    let sink = makeSink(rec)
    let any = sink.toAnyInputSink()
    any.submit InputEvent(kind: iekSelectStory, storyId: "P / Q / R",
      storyGroup: "P", storyName: "Q / R", storyKind: "skPage")
    any.submit InputEvent(kind: iekApplyMutation,
      mutationTarget: "x", mutationKey: "y",
      mutationValue: newJInt(7), mutationScope: msLocal)
    any.submit InputEvent(kind: iekResize, width: 800, height: 600)
    check rec.mounts.len == 1
    check rec.applies.len == 1
    check rec.inner.events.len == 1
    check rec.inner.events[0].kind == iekResize

  test "nil inner: non-RS-M12 events are dropped silently":
    let rec = newRecorder()
    let sink = makeSink(rec, withInner = false)
    # Should not raise — silent drop is the contract.
    sink.submit InputEvent(kind: iekResize, width: 100, height: 100)
    sink.submit InputEvent(kind: iekMouse, mouseAction: maClick,
                            button: 0, mouseX: 0, mouseY: 0)
    check rec.inner.events.len == 0  # we passed a separate recorder
    # The RS-M12 events still dispatch:
    sink.submit InputEvent(kind: iekSelectStory, storyId: "X / Y / Z",
      storyGroup: "X", storyName: "Y / Z", storyKind: "skPage")
    check rec.mounts.len == 1

  test "nil mountFn / applyFn: RS-M12 events become no-ops (no crash)":
    let rec = newRecorder()
    let sink = makeSink(rec, mountFn = false, applyFn = false)
    # Should not raise — the spec lets launchers opt out of either
    # path. (In practice every launcher supplies both.)
    sink.submit InputEvent(kind: iekSelectStory, storyId: "A / B / C",
      storyGroup: "A", storyName: "B / C", storyKind: "skPage")
    sink.submit InputEvent(kind: iekApplyMutation,
      mutationTarget: "t", mutationKey: "k",
      mutationValue: newJBool(false), mutationScope: msLocal)
    check rec.mounts.len == 0
    check rec.applies.len == 0
    check sink.currentStoryId == "A / B / C"  # still tracked

  test "logger fires on RS-M12 events when set":
    let rec = newRecorder()
    let sink = makeSink(rec, withLogger = true)
    sink.submit InputEvent(kind: iekSelectStory, storyId: "G / N / K",
      storyGroup: "G", storyName: "N / K", storyKind: "skPage")
    sink.submit InputEvent(kind: iekApplyMutation,
      mutationTarget: "tgt", mutationKey: "key",
      mutationValue: newJBool(true), mutationScope: msLocal)
    check rec.logs.len == 2
    check rec.logs[0] == "select-story G / N / K"
    check rec.logs[1] == "apply-mutation tgt key"

  test "malformed JSON I body raises PacketProtocolError on decode":
    expect PacketProtocolError:
      discard decodeInputEvent(InputPacket(json: "{not valid"))
    # decode-side rejection means the sink never sees the bad event.
