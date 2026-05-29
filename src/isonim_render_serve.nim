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
import ./isonim_render_serve/packet_video
import ./isonim_render_serve/ws_frame
import ./isonim_render_serve/event_dispatch
import ./isonim_render_serve/frame_source
import ./isonim_render_serve/diff_region
import ./isonim_render_serve/stub_frame_source
import ./isonim_render_serve/element_tree_attrs
import ./isonim_render_serve/story_dispatch
import ./isonim_render_serve/launcher_sinks
import ./isonim_render_serve/adapters/h264_videotoolbox_encoder

export packet, packet_video, ws_frame, event_dispatch, frame_source,
       diff_region, stub_frame_source, element_tree_attrs,
       story_dispatch, launcher_sinks, h264_videotoolbox_encoder

# The `bridge` module pulls `asyncdispatch` / `asynchttpserver` /
# `nativesockets` / `os` and other POSIX-only symbols. `nim js`
# cannot compile any of those, so we omit it under the JS target.
# JS callers (e.g. the IsoNim Editor bundle) only need the codec
# surfaces re-exported above; the bridge server logic is intrinsically
# native-only.
when not defined(js):
  import ./isonim_render_serve/bridge
  export bridge

when isMainModule:
  import std/[asyncdispatch, nativesockets, os, strutils]
  proc main() =
    ## RS-M7: the stub CLI now accepts `--backend <name>` so the
    ## IsoNim Editor's streaming-preview widget can spawn the bridge
    ## as a child process per the selected preview mode (stub /
    ## gpui / freya / cocoa / android) and confirm via the hello M
    ## packet that the bridge launched with the expected backend
    ## identifier. The flag is the same identifier the per-back-end
    ## adapter binaries (when shipped from `isonim-examples`)
    ## announce in their own hello packets.
    var port = 8765
    var staticDir = "static"
    var width = 256
    var height = 256
    var fps = 5
    var backend = "stub"
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
      of "--backend":
        inc i; backend = paramStr(i)
      else:
        quit("unknown arg: " & arg, 1)
      inc i
    let sink = newBufferedInputSink()
    let source = newStubFrameSource(width, height)
    let cfg = BridgeConfig(
      port: Port(port),
      staticDir: staticDir,
      backend: backend,
      frameIntervalMs: max(1, 1000 div fps),
      maxFrames: 0,
      inputSink: sink.toAny(),
      frameSource: source.toAny())
    let s = newServer(cfg)
    echo "isonim-render-serve listening on http://0.0.0.0:", port,
         " (", backend, " ", width, "x", height, " @ ", fps, " fps)"
    waitFor s.serve()
  main()
