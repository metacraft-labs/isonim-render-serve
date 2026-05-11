## isonim-render-serve — top-level facade.
##
## Re-exports the four building blocks:
##
##   * `packet`            — F/M/I wire codec (RS-M0 byte layout).
##   * `ws_frame`          — RFC 6455 frame codec (vendored from
##                           isonim-tui-serve).
##   * `event_dispatch`    — `InputEvent` variant + I JSON decode +
##                           `BufferedInputSink` reference impl.
##   * `stub_frame_source` — animated gradient `FrameSource`.
##   * `bridge`            — WS server + hello/F/M/I loop.
##
## Plus a tiny CLI that boots the bridge against the stub source on
## a configurable port.

import ./isonim_render_serve/packet
import ./isonim_render_serve/ws_frame
import ./isonim_render_serve/event_dispatch
import ./isonim_render_serve/frame_source
import ./isonim_render_serve/diff_region
import ./isonim_render_serve/stub_frame_source
import ./isonim_render_serve/bridge

export packet, ws_frame, event_dispatch, frame_source, diff_region,
       stub_frame_source, bridge

when isMainModule:
  import std/[asyncdispatch, nativesockets, os, strutils]
  proc main() =
    var port = 8765
    var staticDir = "static"
    var width = 256
    var height = 256
    var fps = 5
    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)
      case arg
      of "--port":
        inc i; port = parseInt(paramStr(i))
      of "--static":
        inc i; staticDir = paramStr(i)
      of "--width":
        inc i; width = parseInt(paramStr(i))
      of "--height":
        inc i; height = parseInt(paramStr(i))
      of "--fps":
        inc i; fps = parseInt(paramStr(i))
      else:
        quit("unknown arg: " & arg, 1)
      inc i
    let sink = newBufferedInputSink()
    let source = newStubFrameSource(width, height)
    let cfg = BridgeConfig(
      port: Port(port),
      staticDir: staticDir,
      backend: "stub",
      frameIntervalMs: max(1, 1000 div fps),
      maxFrames: 0,
      inputSink: sink.toAny(),
      frameSource: source.toAny())
    let s = newServer(cfg)
    echo "isonim-render-serve listening on http://0.0.0.0:", port,
         " (stub ", width, "x", height, " @ ", fps, " fps)"
    waitFor s.serve()
  main()
