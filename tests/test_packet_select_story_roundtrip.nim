## test_packet_select_story_roundtrip — RS-M12 wire-protocol check.
##
## Encodes and decodes the two new I-packet sub-kinds (``select-story``
## and ``apply-mutation``) and asserts:
##
##   1. ``decodeInputEvent(InputPacket(json: <reference>))`` yields the
##      expected typed ``InputEvent`` variant + fields.
##   2. ``encodeSelectStoryJson`` / ``encodeApplyMutationJson`` produce
##      byte-identical JSON against a hand-rolled reference encoding.
##   3. encode → decode → re-encode round-trip is byte-identical.
##   4. Malformed packets surface ``PacketProtocolError`` so the bridge
##      can close the WS with status 1002 (RFC 6455 §7.4.1).
##
## No mocks; the codec under test is the launcher's real production
## path. Spec: RS-M12 § *Wire protocol changes* in
## ``codetracer-specs/Front-Ends/IsoNim/isonim-render-stream.status.org``.

import std/[json, unittest]

import isonim_render_serve

suite "isonim-render-serve: RS-M12 I-packet sub-kinds":

  test "select-story decode populates storyId/group/name/kind/properties":
    let body = """{"type":"select-story",""" &
               """"group":"Settings App / Pages",""" &
               """"name":"Appearance Group",""" &
               """"kind":"skPage",""" &
               """"storyId":"Settings App / Pages / Appearance Group",""" &
               """"properties":{"theme":"dark","fontSize":14}}"""
    let ev = decodeInputEvent(InputPacket(json: body))
    check ev.kind == iekSelectStory
    check ev.storyGroup == "Settings App / Pages"
    check ev.storyName == "Appearance Group"
    check ev.storyKind == "skPage"
    check ev.storyId == "Settings App / Pages / Appearance Group"
    check ev.properties != nil
    check ev.properties.kind == JObject
    check ev.properties["theme"].getStr == "dark"
    check ev.properties["fontSize"].getInt == 14

  test "select-story decode tolerates missing properties":
    let body = """{"type":"select-story","group":"Task App / TaskList",""" &
               """"name":"Two Active","kind":"skComponent",""" &
               """"storyId":"Task App / TaskList / Two Active"}"""
    let ev = decodeInputEvent(InputPacket(json: body))
    check ev.kind == iekSelectStory
    check ev.properties == nil

  test "select-story hand-rolled encoder matches a fixed reference":
    let ref0 = """{"type":"select-story","group":"Task App / Pages",""" &
               """"name":"Inbox","kind":"skPage",""" &
               """"storyId":"Task App / Pages / Inbox"}"""
    let actual = encodeSelectStoryJson(
      storyGroup = "Task App / Pages",
      storyName = "Inbox",
      storyKind = "skPage",
      storyId = "Task App / Pages / Inbox")
    check actual == ref0

  test "select-story hand-rolled encoder embeds properties verbatim":
    let props = newJObject()
    props["dark"] = newJBool(true)
    let ref0 = """{"type":"select-story","group":"Settings App / Group",""" &
               """"name":"Appearance","kind":"skComponent",""" &
               """"storyId":"Settings App / Group / Appearance",""" &
               """"properties":{"dark":true}}"""
    let actual = encodeSelectStoryJson(
      storyGroup = "Settings App / Group",
      storyName = "Appearance",
      storyKind = "skComponent",
      storyId = "Settings App / Group / Appearance",
      properties = props)
    check actual == ref0

  test "apply-mutation decode populates target/key/value/scope":
    let body = """{"type":"apply-mutation",""" &
               """"target":"settings_app/views/Toggle#DarkMode",""" &
               """"key":"checked","value":true,"scope":"local"}"""
    let ev = decodeInputEvent(InputPacket(json: body))
    check ev.kind == iekApplyMutation
    check ev.mutationTarget == "settings_app/views/Toggle#DarkMode"
    check ev.mutationKey == "checked"
    check ev.mutationValue != nil
    check ev.mutationValue.kind == JBool
    check ev.mutationValue.getBool == true
    check ev.mutationScope == msLocal

  test "apply-mutation decode accepts shared scope and string value":
    let body = """{"type":"apply-mutation",""" &
               """"target":"settings_app/views/Choice#Theme",""" &
               """"key":"selected","value":"solarized","scope":"shared"}"""
    let ev = decodeInputEvent(InputPacket(json: body))
    check ev.kind == iekApplyMutation
    check ev.mutationScope == msShared
    check ev.mutationValue.getStr == "solarized"

  test "apply-mutation hand-rolled encoder matches a fixed reference":
    let ref0 = """{"type":"apply-mutation",""" &
               """"target":"task_app/views/TaskRow#7",""" &
               """"key":"completed","value":true,"scope":"local"}"""
    let actual = encodeApplyMutationJson(
      target = "task_app/views/TaskRow#7",
      key = "completed",
      value = newJBool(true),
      scope = msLocal)
    check actual == ref0

  test "apply-mutation hand-rolled encoder accepts number value":
    let ref0 = """{"type":"apply-mutation",""" &
               """"target":"settings_app/views/Number#FontSize",""" &
               """"key":"value","value":14,"scope":"shared"}"""
    let actual = encodeApplyMutationJson(
      target = "settings_app/views/Number#FontSize",
      key = "value",
      value = newJInt(14),
      scope = msShared)
    check actual == ref0

  test "select-story decode → encode round-trip preserves fields":
    let body = encodeSelectStoryJson(
      storyGroup = "Task App / FilterBar",
      storyName = "Active Selected",
      storyKind = "skComponent",
      storyId = "Task App / FilterBar / Active Selected")
    let ev = decodeInputEvent(InputPacket(json: body))
    let reencoded = encodeSelectStoryJson(
      storyGroup = ev.storyGroup,
      storyName = ev.storyName,
      storyKind = ev.storyKind,
      storyId = ev.storyId,
      properties = ev.properties)
    check reencoded == body

  test "apply-mutation decode → encode round-trip preserves fields":
    let value = newJObject()
    value["min"] = newJInt(8)
    value["max"] = newJInt(96)
    let body = encodeApplyMutationJson(
      target = "settings_app/views/Number#FontSize",
      key = "constraints",
      value = value,
      scope = msShared)
    let ev = decodeInputEvent(InputPacket(json: body))
    let reencoded = encodeApplyMutationJson(
      target = ev.mutationTarget,
      key = ev.mutationKey,
      value = ev.mutationValue,
      scope = ev.mutationScope)
    check reencoded == body

  test "select-story missing required field raises PacketProtocolError":
    let body = """{"type":"select-story","group":"Task App / Pages",""" &
               """"name":"Inbox"}"""  # missing kind + storyId
    expect PacketProtocolError:
      discard decodeInputEvent(InputPacket(json: body))

  test "apply-mutation unknown scope raises PacketProtocolError":
    let body = """{"type":"apply-mutation","target":"x","key":"y",""" &
               """"value":1,"scope":"chaotic"}"""
    expect PacketProtocolError:
      discard decodeInputEvent(InputPacket(json: body))

  test "apply-mutation missing 'value' raises PacketProtocolError":
    let body = """{"type":"apply-mutation","target":"x","key":"y",""" &
               """"scope":"local"}"""
    expect PacketProtocolError:
      discard decodeInputEvent(InputPacket(json: body))

  test "BufferedInputSink logs select-story and apply-mutation":
    let sink = newBufferedInputSink()
    sink.submit InputEvent(kind: iekSelectStory,
      storyGroup: "Task App / Pages",
      storyName: "Inbox",
      storyKind: "skPage",
      storyId: "Task App / Pages / Inbox")
    sink.submit InputEvent(kind: iekApplyMutation,
      mutationTarget: "task_app/views/TaskRow#1",
      mutationKey: "completed",
      mutationValue: newJBool(true),
      mutationScope: msLocal)
    check sink.events.len == 2
    check sink.log[0] == "select-story Task App / Pages / Inbox"
    check sink.log[1] ==
      "apply-mutation task_app/views/TaskRow#1 completed scope=local"
