## Event dispatch — `InputEvent` variant 1:1 with the `I` packet
## JSON schema locked at RS-M0, plus a JSON → `InputEvent` decoder
## and an `InputSink` concept that bridge consumers implement.
##
## See `codetracer-specs/Front-Ends/IsoNim/`
## `isonim-render-stream.status.org` § *Architecture sketch — render
## streaming* for the canonical schema.

import std/[json, strutils]

import ./packet

type
  InputEventKind* = enum
    iekKey, iekMouse, iekScroll, iekResize, iekFocus,
    iekSelectStory, iekApplyMutation

  Modifiers* = object
    ctrl*, shift*, alt*, meta*: bool

  KeyAction* = enum kaDown, kaUp, kaPress
  MouseAction* = enum maDown, maUp, maMove, maClick

  MutationScope* = enum
    msLocal = "local"
    msShared = "shared"

  InputEvent* = object
    case kind*: InputEventKind
    of iekKey:
      keyAction*: KeyAction
      key*, code*: string
      keyModifiers*: Modifiers
      repeat*: bool
    of iekMouse:
      mouseAction*: MouseAction
      button*: int
      mouseX*, mouseY*: int
      mouseModifiers*: Modifiers
    of iekScroll:
      scrollX*, scrollY*: int
      deltaX*, deltaY*: int
      scrollModifiers*: Modifiers
    of iekResize:
      width*, height*: int
    of iekFocus:
      focused*: bool
    of iekSelectStory:
      ## RS-M12. Editor → launcher: "the user picked this story; tear
      ## down the current root and mount the one keyed by ``storyId``".
      ## ``storyId`` is the canonical ``"<group> / <name>"`` identifier
      ## from ``task_app/core/story_ids.nim`` /
      ## ``settings_app/core/story_ids.nim``. ``group`` / ``name`` /
      ## ``storyKind`` carry the raw editor sidebar coordinates so the
      ## launcher can log / diagnose lookups without re-splitting the
      ## composite id. ``properties`` is the per-story configuration
      ## bag (optional; ``nil`` means "use the story's defaults").
      storyId*: string
      storyGroup*: string
      storyName*: string
      storyKind*: string
      properties*: JsonNode
    of iekApplyMutation:
      ## RS-M12. Editor → launcher: "the inspector committed an edit;
      ## apply ``(key, value)`` to the component at ``target``". The
      ## ``target`` string uses the same componentPath taxonomy the
      ## element-tree manifest emits (e.g.
      ## ``settings_app/views/Toggle#DarkMode``). ``scope`` mirrors
      ## the editor's ``pesLocal`` / ``pesShared`` distinction.
      mutationTarget*: string
      mutationKey*: string
      mutationValue*: JsonNode
      mutationScope*: MutationScope

  InputSink* = concept sink
    sink.submit(event: InputEvent)

  AnyInputSink* = ref object
    ## RS-M2 polymorphic wrapper for the inbound (`I` packet) leg of
    ## the bridge — the analogue to `AnyFrameSource` on the outbound
    ## side. Lets the bridge hand decoded `InputEvent`s to any sink
    ## (RS-M1's `BufferedInputSink`, RS-M2's GPUI input sink, future
    ## per-back-end sinks) without `bridge.nim` knowing the concrete
    ## sink type. The closure is tagged `gcsafe` so the bridge's
    ## `--threads:on` build passes the `serve` gcsafe check.
    submitImpl*: proc(event: InputEvent) {.closure, gcsafe.}

proc decodeMods(node: JsonNode): Modifiers =
  if node == nil or node.kind != JObject: return
  template flagOf(name: string): bool =
    (name in node) and node[name].kind == JBool and node[name].getBool
  result.ctrl = flagOf("ctrl")
  result.shift = flagOf("shift")
  result.alt = flagOf("alt")
  result.meta = flagOf("meta")

proc parseKeyAction(s: string): KeyAction =
  case s
  of "down": kaDown
  of "up": kaUp
  of "press": kaPress
  else:
    raise newException(PacketProtocolError,
      "unknown key action: " & s)

proc parseMouseAction(s: string): MouseAction =
  case s
  of "down": maDown
  of "up": maUp
  of "move": maMove
  of "click": maClick
  else:
    raise newException(PacketProtocolError,
      "unknown mouse action: " & s)

proc decodeInputEvent*(inp: InputPacket): InputEvent =
  ## Parse an I packet's JSON body into the typed variant. Raises
  ## `PacketProtocolError` on schema violation (unknown type,
  ## missing required field, bad value).
  var node: JsonNode
  try:
    node = parseJson(inp.json)
  except JsonParsingError as e:
    raise newException(PacketProtocolError,
      "I JSON parse error: " & e.msg)
  if node.kind != JObject:
    raise newException(PacketProtocolError,
      "I JSON root must be an object")
  if "type" notin node or node["type"].kind != JString:
    raise newException(PacketProtocolError,
      "I JSON missing string field 'type'")
  let kind = node["type"].getStr
  case kind
  of "key":
    if "action" notin node:
      raise newException(PacketProtocolError, "key: missing action")
    result = InputEvent(kind: iekKey,
      keyAction: parseKeyAction(node["action"].getStr),
      key: (if "key" in node: node["key"].getStr else: ""),
      code: (if "code" in node: node["code"].getStr else: ""),
      keyModifiers: decodeMods(if "modifiers" in node: node["modifiers"]
                                else: nil),
      repeat: (if "repeat" in node and node["repeat"].kind == JBool:
                 node["repeat"].getBool else: false))
  of "mouse":
    if "action" notin node:
      raise newException(PacketProtocolError, "mouse: missing action")
    result = InputEvent(kind: iekMouse,
      mouseAction: parseMouseAction(node["action"].getStr),
      button: (if "button" in node: node["button"].getInt else: 0),
      mouseX: (if "x" in node: node["x"].getInt else: 0),
      mouseY: (if "y" in node: node["y"].getInt else: 0),
      mouseModifiers: decodeMods(if "modifiers" in node:
                                   node["modifiers"] else: nil))
  of "scroll":
    result = InputEvent(kind: iekScroll,
      scrollX: (if "x" in node: node["x"].getInt else: 0),
      scrollY: (if "y" in node: node["y"].getInt else: 0),
      deltaX: (if "deltaX" in node: node["deltaX"].getInt else: 0),
      deltaY: (if "deltaY" in node: node["deltaY"].getInt else: 0),
      scrollModifiers: decodeMods(if "modifiers" in node:
                                    node["modifiers"] else: nil))
  of "resize":
    if "width" notin node or "height" notin node:
      raise newException(PacketProtocolError,
        "resize: missing width/height")
    result = InputEvent(kind: iekResize,
      width: node["width"].getInt,
      height: node["height"].getInt)
  of "focus":
    if "focused" notin node or node["focused"].kind != JBool:
      raise newException(PacketProtocolError, "focus: missing focused")
    result = InputEvent(kind: iekFocus, focused: node["focused"].getBool)
  of "select-story":
    ## RS-M12. ``select-story`` lays out as
    ## ``{type, group, name, kind, storyId, properties?}``. The four
    ## string fields are required; ``properties`` is optional (nil
    ## when the editor wants the launcher to fall back to per-story
    ## defaults).
    template strField(name: string): string =
      if name notin node or node[name].kind != JString:
        raise newException(PacketProtocolError,
          "select-story: missing string field '" & name & "'")
      node[name].getStr
    let props =
      if "properties" in node and node["properties"].kind != JNull:
        node["properties"]
      else:
        nil
    result = InputEvent(kind: iekSelectStory,
      storyGroup: strField("group"),
      storyName: strField("name"),
      storyKind: strField("kind"),
      storyId: strField("storyId"),
      properties: props)
  of "apply-mutation":
    ## RS-M12. ``apply-mutation`` lays out as
    ## ``{type, target, key, value, scope}``. ``value`` is an arbitrary
    ## JSON node (number / bool / string / object) — the launcher
    ## dispatches per (target, key) and is responsible for type
    ## coercion. ``scope`` is the string ``"local"`` or ``"shared"``;
    ## anything else surfaces as a protocol violation.
    template strField(name: string): string =
      if name notin node or node[name].kind != JString:
        raise newException(PacketProtocolError,
          "apply-mutation: missing string field '" & name & "'")
      node[name].getStr
    if "value" notin node:
      raise newException(PacketProtocolError,
        "apply-mutation: missing 'value'")
    let scopeStr = strField("scope")
    let scope =
      case scopeStr
      of "local": msLocal
      of "shared": msShared
      else:
        raise newException(PacketProtocolError,
          "apply-mutation: unknown scope '" & scopeStr & "'")
    result = InputEvent(kind: iekApplyMutation,
      mutationTarget: strField("target"),
      mutationKey: strField("key"),
      mutationValue: node["value"],
      mutationScope: scope)
  else:
    raise newException(PacketProtocolError,
      "unknown I JSON type: " & kind)

proc actionToStr(a: KeyAction): string =
  case a
  of kaDown: "down"
  of kaUp: "up"
  of kaPress: "press"

proc actionToStr(a: MouseAction): string =
  case a
  of maDown: "down"
  of maUp: "up"
  of maMove: "move"
  of maClick: "click"

proc modsToJson(m: Modifiers): JsonNode =
  result = newJObject()
  result["ctrl"] = newJBool(m.ctrl)
  result["shift"] = newJBool(m.shift)
  result["alt"] = newJBool(m.alt)
  result["meta"] = newJBool(m.meta)

proc encodeInputEvent*(ev: InputEvent): InputPacket =
  ## Inverse of `decodeInputEvent`. Used by tests / clients that
  ## build I packets from typed events.
  var node = newJObject()
  case ev.kind
  of iekKey:
    node["type"] = newJString("key")
    node["action"] = newJString(actionToStr(ev.keyAction))
    node["key"] = newJString(ev.key)
    node["code"] = newJString(ev.code)
    node["modifiers"] = modsToJson(ev.keyModifiers)
    node["repeat"] = newJBool(ev.repeat)
  of iekMouse:
    node["type"] = newJString("mouse")
    node["action"] = newJString(actionToStr(ev.mouseAction))
    node["button"] = newJInt(ev.button)
    node["x"] = newJInt(ev.mouseX)
    node["y"] = newJInt(ev.mouseY)
    node["modifiers"] = modsToJson(ev.mouseModifiers)
  of iekScroll:
    node["type"] = newJString("scroll")
    node["x"] = newJInt(ev.scrollX)
    node["y"] = newJInt(ev.scrollY)
    node["deltaX"] = newJInt(ev.deltaX)
    node["deltaY"] = newJInt(ev.deltaY)
    node["modifiers"] = modsToJson(ev.scrollModifiers)
  of iekResize:
    node["type"] = newJString("resize")
    node["width"] = newJInt(ev.width)
    node["height"] = newJInt(ev.height)
  of iekFocus:
    node["type"] = newJString("focus")
    node["focused"] = newJBool(ev.focused)
  of iekSelectStory:
    node["type"] = newJString("select-story")
    node["group"] = newJString(ev.storyGroup)
    node["name"] = newJString(ev.storyName)
    node["kind"] = newJString(ev.storyKind)
    node["storyId"] = newJString(ev.storyId)
    if ev.properties != nil:
      node["properties"] = ev.properties
  of iekApplyMutation:
    node["type"] = newJString("apply-mutation")
    node["target"] = newJString(ev.mutationTarget)
    node["key"] = newJString(ev.mutationKey)
    if ev.mutationValue != nil:
      node["value"] = ev.mutationValue
    else:
      node["value"] = newJNull()
    node["scope"] = newJString($ev.mutationScope)
  result = InputPacket(json: $node)

# ---------------------------------------------------------------------------
# RS-M12: stable, hand-rolled JSON serializer for the two new sub-kinds.
# Used by the editor's JS-side WebSocket send paths AND by the launcher-
# side reference encoding in the round-trip test, so the on-wire bytes
# are deterministic across Nim versions / std/json key ordering.
# ---------------------------------------------------------------------------

proc jsonEscape(s: string): string =
  ## Minimal RFC 8259 string escaper — sufficient for ASCII content
  ## the editor emits today (componentPaths, story names, property
  ## keys). Mirrors ``encodeElementTreeJson``'s escaper in packet.nim
  ## so RS-M12's JSON shape stays consistent with RS-M11's.
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ch.uint8 < 0x20'u8:
        const hexChars = "0123456789abcdef"
        result.add "\\u00"
        result.add hexChars[int(ch.uint8 shr 4)]
        result.add hexChars[int(ch.uint8 and 0x0F'u8)]
      else:
        result.add ch
  result.add '"'

proc encodeSelectStoryJson*(storyGroup, storyName, storyKind,
                            storyId: string;
                            properties: JsonNode = nil): string =
  ## Hand-rolled deterministic encoder for the ``select-story`` I-body.
  ## Field order locked to ``type, group, name, kind, storyId,
  ## properties?`` so the on-wire bytes are reproducible.
  result = newStringOfCap(96 + storyId.len + storyGroup.len +
                          storyName.len + storyKind.len)
  result.add "{\"type\":\"select-story\""
  result.add ",\"group\":"
  result.add jsonEscape(storyGroup)
  result.add ",\"name\":"
  result.add jsonEscape(storyName)
  result.add ",\"kind\":"
  result.add jsonEscape(storyKind)
  result.add ",\"storyId\":"
  result.add jsonEscape(storyId)
  if properties != nil:
    result.add ",\"properties\":"
    result.add $properties
  result.add "}"

proc encodeApplyMutationJson*(target, key: string; value: JsonNode;
                              scope: MutationScope): string =
  ## Hand-rolled deterministic encoder for the ``apply-mutation``
  ## I-body. Field order locked to ``type, target, key, value, scope``.
  result = newStringOfCap(96 + target.len + key.len)
  result.add "{\"type\":\"apply-mutation\""
  result.add ",\"target\":"
  result.add jsonEscape(target)
  result.add ",\"key\":"
  result.add jsonEscape(key)
  result.add ",\"value\":"
  if value == nil:
    result.add "null"
  else:
    result.add $value
  result.add ",\"scope\":"
  result.add jsonEscape($scope)
  result.add "}"

# ---------------------------------------------------------------------------
# Buffer-backed InputSink used by the stub backend + integration tests.
# ---------------------------------------------------------------------------

type
  BufferedInputSink* = ref object
    events*: seq[InputEvent]
    log*: seq[string]

proc newBufferedInputSink*(): BufferedInputSink =
  BufferedInputSink(events: @[], log: @[])

proc submit*(sink: BufferedInputSink; event: InputEvent) =
  sink.events.add event
  case event.kind
  of iekKey:
    sink.log.add "key " & actionToStr(event.keyAction) & " " & event.key
  of iekMouse:
    sink.log.add "mouse " & actionToStr(event.mouseAction) & " " &
      $event.button & " " & $event.mouseX & "," & $event.mouseY
  of iekScroll:
    sink.log.add "scroll " & $event.deltaX & "," & $event.deltaY
  of iekResize:
    sink.log.add "resize " & $event.width & "x" & $event.height
  of iekFocus:
    sink.log.add "focus " & (if event.focused: "true" else: "false")
  of iekSelectStory:
    sink.log.add "select-story " & event.storyId
  of iekApplyMutation:
    sink.log.add "apply-mutation " & event.mutationTarget & " " &
                 event.mutationKey & " scope=" & $event.mutationScope

# Convenience: render the structured log into a single string for
# test assertions.
proc joinLog*(sink: BufferedInputSink; sep: string = "\n"): string =
  sink.log.join(sep)

# ---------------------------------------------------------------------------
# Polymorphic wrapper (RS-M2)
# ---------------------------------------------------------------------------

proc newAnyInputSink*(submitImpl: proc(event: InputEvent)
                                     {.closure, gcsafe.}): AnyInputSink =
  AnyInputSink(submitImpl: submitImpl)

proc submit*(sink: AnyInputSink; event: InputEvent) =
  sink.submitImpl(event)

proc toAny*(s: BufferedInputSink): AnyInputSink =
  ## Wrap the RS-M1 buffered sink in a polymorphic `AnyInputSink`.
  ## Mirrors the `StubFrameSource.toAny` shape so call-sites that
  ## want the buffered behaviour can still drop into the broadened
  ## `BridgeConfig.inputSink` field.
  let captured = s
  newAnyInputSink(proc(event: InputEvent) {.gcsafe.} =
    {.cast(gcsafe).}: captured.submit(event))
