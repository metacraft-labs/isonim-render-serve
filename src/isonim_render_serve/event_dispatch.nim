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
    iekKey, iekMouse, iekScroll, iekResize, iekFocus

  Modifiers* = object
    ctrl*, shift*, alt*, meta*: bool

  KeyAction* = enum kaDown, kaUp, kaPress
  MouseAction* = enum maDown, maUp, maMove, maClick

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

  InputSink* = concept sink
    sink.submit(event: InputEvent)

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
  result = InputPacket(json: $node)

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

# Convenience: render the structured log into a single string for
# test assertions.
proc joinLog*(sink: BufferedInputSink; sep: string = "\n"): string =
  sink.log.join(sep)
